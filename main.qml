/**
 * Traccar Live – QField Plugin  v0.2
 * Patterns from Conversion_tools + GPX_Appender working plugins.
 */

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import QtCore
import Theme

Item {
    id: plugin

    property var mainWindow: iface.mainWindow()

    // ── Persistent settings ───────────────────────────────────────────────
    Settings {
        id: cfg
        category: "TraccarLive"
        property string serverUrl:      "https://server.traccar.org"
        property string username:       ""
        property string password:       ""
        property int    intervalMin:    3
        property bool   liveOn:         false
        property bool   appendTrack:     false   // append vertices to line layer
        property bool   fetchHistory:    false   // pull all positions since last fetch
        property string liveLayerName:   ""     // A — truncated & repopulated each fetch
        property string appendLayerName: ""     // B — positions appended each fetch
        property string lineLayerName:   ""     // C — track line layer
        property string lastFetchIso:    ""     // internal — timestamp of last successful fetch
        // kept for migration only — do not use directly
        property string pointLayerName:  ""
        property bool   appendMode:      false

        property int    fetchMaxPoints:  150     // Fetch Logs: cap on points written per device
        property bool   fetchLimitPts:   true     // Fetch Logs: whether the cap above is enforced

        // ── Layer B housekeeping (culling) ────────────────────────────────
        property bool   cullByCount:     false    // remove oldest points beyond cullMaxPerDevice (per device)
        property int    cullMaxPerDevice: 500     // points retained per device in layer B when cullByCount is on
        property bool   cullByAge:       false    // remove points older than cullAgeMinutes
        property int    cullAgeMinutes:  1440     // age cutoff in minutes (default 1 day) when cullByAge is on

        // ── Auto-fill field on new features ───────────────────────────────
        property bool   incidentRefEnabled: false  // write incidentRefExpr into incidentRefField on new features
        property string incidentRefField:   ""     // target field name (same on layers A/B/C)
        property string incidentRefExpr:    "'KMRT-' || format_date(now(),'ddd-dd/MM/yy')||'-1'"
    }

    // Shared timeframe presets — used by the Fetch Logs "Quick range" combo and
    // the "Cull by age" combo (Settings). minutes:0 = "— custom date range —"
    // (Fetch Logs only; treated as "no cutoff" if ever selected for cull-by-age).
    ListModel {
        id: timeframeModel
        ListElement { label: "— custom date range —"; minutes: 0    }
        ListElement { label: "Last 15 minutes";        minutes: 15   }
        ListElement { label: "Last 30 minutes";        minutes: 30   }
        ListElement { label: "Last 1 hour";            minutes: 60   }
        ListElement { label: "Last 2 hours";           minutes: 120  }
        ListElement { label: "Last 3 hours";           minutes: 180  }
        ListElement { label: "Last 6 hours";           minutes: 360  }
        ListElement { label: "Last 12 hours";          minutes: 720  }
        ListElement { label: "Last 18 hours";          minutes: 1080 }
        ListElement { label: "Last 1 day";             minutes: 1440 }
        ListElement { label: "Last 3 days";            minutes: 4320 }
        ListElement { label: "Last 1 week";            minutes: 10080 }
        ListElement { label: "Last 2 weeks";           minutes: 20160 }
        ListElement { label: "Last 1 month";           minutes: 43200 }
        ListElement { label: "Last 3 months";          minutes: 129600 }
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property var    deviceInfo:  ({})
    property var    positions:   []
    property string lastFetched: ""
    property bool   fetchBusy:   false

    // ── Layer list models (for ComboBoxes in Settings) ─────────────────────
    ListModel { id: ptLayerModel }
    ListModel { id: lnLayerModel }
    ListModel { id: fetchDevsModel }    // device list for Fetch Logs dialog
    ListModel { id: fieldNameModel }    // field names of the append (B) layer

    // ── Populate a layer model by geometry type ────────────────────────────
    function populateLayers(model, geomType) {
        model.clear()
        var layers  = ProjectUtils.mapLayers(qgisProject)
        var normal  = []
        var priv    = []
        for (var id in layers) {
            var lyr = layers[id]
            try {
                if (lyr && lyr.geometryType &&
                    lyr.geometryType() === geomType &&
                    lyr.supportsEditing === true) {
                    var isPriv = false
                    try { isPriv = (lyr.flags & 8) !== 0 } catch (e2) {}
                    if (isPriv) priv.push(lyr.name)
                    else        normal.push(lyr.name)
                }
            } catch (e) {}
        }
        normal.sort(function(a,b){ return a.localeCompare(b) })
        priv.sort  (function(a,b){ return a.localeCompare(b) })

        if (normal.length === 0 && priv.length === 0) {
            model.append({ name: "— no suitable layers —", isHeader: true })
            return
        }
        for (var i = 0; i < normal.length; i++)
            model.append({ name: normal[i], isHeader: false })
        if (priv.length > 0) {
            model.append({ name: "— Private Layers —", isHeader: true })
            for (var j = 0; j < priv.length; j++)
                model.append({ name: priv[j], isHeader: false })
        }
    }

    // ── Restore combo selection to a saved name ───────────────────────────
    function restoreSelection(combo, model, savedName) {
        for (var k = 0; k < model.count; k++) {
            var item = model.get(k)
            if (!item.isHeader && item.name === savedName) {
                combo.currentIndex = k
                return
            }
        }
        combo.currentIndex = -1
    }

    // ── Populate field-name model from a layer (by name) ──────────────────
    function populateFieldNames(model, layerName) {
        model.clear()
        if (layerName === "") {
            model.append({ name: "— select a History layer (B) above —", isHeader: true })
            return
        }
        var layers = qgisProject.mapLayersByName(layerName)
        if (layers.length === 0) {
            model.append({ name: "— layer not found —", isHeader: true })
            return
        }
        var fnames = layers[0].fields.names
        if (fnames.length === 0) {
            model.append({ name: "— no fields —", isHeader: true })
            return
        }
        for (var i = 0; i < fnames.length; i++)
            model.append({ name: fnames[i], isHeader: false })
    }

    // ── Register toolbar button ───────────────────────────────────────────
    Component.onCompleted: {
        iface.addItemToPluginsToolbar(pluginButton)
        // Migrate old pointLayerName/appendMode → liveLayerName/appendLayerName
        if (cfg.pointLayerName !== "" &&
                cfg.liveLayerName === "" && cfg.appendLayerName === "") {
            if (cfg.appendMode)
                cfg.appendLayerName = cfg.pointLayerName
            else
                cfg.liveLayerName = cfg.pointLayerName
            cfg.pointLayerName = ""
        }
    }

    QfToolButton {
        id:         pluginButton
        bgcolor:    Theme.mainColor
        round:      true
        iconSource: "traccar_icon.svg"
        onClicked:  mainDialog.open()
    }

    // ── Auto-refresh timer ────────────────────────────────────────────────
    Timer {
        id:          refreshTimer
        interval:    cfg.intervalMin * 60000
        repeat:      true
        running:     cfg.liveOn
        onTriggered: fetchAll()
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MAIN DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      mainDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       (mainWindow.height - height) * 0.08

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text:             "Traccar Live"
                    color:            "white"
                    font.pixelSize:   16
                    font.bold:        true
                    Layout.fillWidth: true
                }
                ToolButton {
                    contentItem: Text {
                        text: "?"
                        color: "white"
                        font.pixelSize: 16
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked:  { mainDialog.close(); helpDialog.open() }
                }
                ToolButton {
                    contentItem: Text {
                        text: "📅"
                        color: "white"
                        font.pixelSize: 16
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked:  { mainDialog.close(); fetchLogsDialog.open() }
                }
                ToolButton {
                    contentItem: Text {
                        text: "🔧"
                        color: "white"
                        font.pixelSize: 18
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked:  { mainDialog.close(); settingsDialog.open() }
                }
            }
        }

        footer: Item { height: 4 }

        ColumnLayout {
            width:   parent.width
            spacing: 0

            // Last-fetched banner
            Rectangle {
                Layout.fillWidth: true
                height:  visible ? 30 : 0
                visible: plugin.lastFetched !== ""
                color:   "#E3F2FD"
                Label {
                    anchors { fill: parent; leftMargin: 10 }
                    text:              "Last fetched:  " + plugin.lastFetched
                    verticalAlignment: Text.AlignVCenter
                    font.pixelSize:    12
                    color:             "#1565C0"
                }
            }

            // Controls
            RowLayout {
                Layout.fillWidth: true
                Layout.margins:   10
                spacing:          8
                Button {
                    Layout.fillWidth: true
                    text:    cfg.liveOn ? "⏹  Stop Live" : "▶  Start Live"
                    onClicked: {
                        cfg.liveOn = !cfg.liveOn
                        if (cfg.liveOn) fetchAll()
                        mainWindow.displayToast(cfg.liveOn ? "Live tracking started" : "Live tracking stopped")
                    }
                }
                Button {
                    text:    "↻ Now"
                    enabled: !plugin.fetchBusy
                    onClicked: fetchAll()
                }
            }

            Label {
                text:                "Devices  (" + plugin.positions.length + ")"
                font.bold:           true
                Layout.leftMargin:   12
                Layout.topMargin:    4
                Layout.bottomMargin: 2
            }

            // Device list
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(plugin.positions.length * 58, 290)
                clip:  true
                model: plugin.positions

                delegate: Rectangle {
                    width:  ListView.view.width
                    height: 58
                    color:  index % 2 === 0 ? "#F5F5F5" : "white"

                    property var pos:    modelData
                    property var info:   plugin.deviceInfo[pos.deviceId] || {}
                    property bool online: (info.status || "") === "online"

                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 8 }
                        spacing: 10
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: online ? "#4CAF50" : "#9E9E9E"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                text:             info.name || ("Device " + pos.deviceId)
                                font.bold:        true
                                font.pixelSize:   13
                                elide:            Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Label {
                                text: {
                                    var spd  = Math.round((pos.speed || 0) * 1.852)
                                    // fixTime = GPS fix time on the device (≠ fetch time)
                                    var date = pos.fixTime ? pos.fixTime.substring(0,10) : ""
                                    var time = pos.fixTime ? pos.fixTime.substring(11,19) : "—"
                                    var today = Qt.formatDate(new Date(), "yyyy-MM-dd")
                                    var timeStr = (date && date !== today) ? date + " " + time : time
                                    var bat  = (pos.attributes && pos.attributes.batteryLevel != null)
                                               ? "  🔋" + pos.attributes.batteryLevel + "%" : ""
                                    return spd + " km/h  •  GPS " + timeStr + bat
                                }
                                font.pixelSize: 11
                                color: "#555"
                            }
                        }
                        ToolButton {
                            contentItem: Text {
                                text: "⌖"; font.pixelSize: 18
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment:   Text.AlignVCenter
                            }
                            background: Item {}
                            onClicked: { zoomToDevice(pos); mainDialog.close() }
                        }
                    }
                }
            }

            Item { height: 6 }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELP DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      helpDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        title:   "Traccar Live — Help"
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       (mainWindow.height - height) * 0.06

        standardButtons: Dialog.Ok
        onAccepted: mainDialog.open()

        ScrollView {
            width:       parent.width
            height:      Math.min(implicitHeight, mainWindow.height * 0.72)
            contentWidth: parent.width
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 4

                // ▌ DEVICE LIST ────────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#1565C0"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Device List"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Green dot = device online (reporting to Traccar)\n" +
                          "Grey dot  = device offline\n\n" +
                          "Speed — km/h from the Traccar position record\n\n" +
                          "GPS time — when the device's GPS chip recorded that fix. " +
                          "This is NOT the last-fetch time. A device with poor satellite " +
                          "signal may show a time older than the fetch. " +
                          "The 'Last fetched' banner at the top shows when the plugin last " +
                          "contacted the server.\n\n" +
                          "Battery % — reported by the device (not all devices send this)\n\n" +
                          "Crosshair button — pans the map to that device"
                }

                Item { height: 6 }

                // ▌ CONTROLS ───────────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#1565C0"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Controls"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Start Live — auto-fetches every N minutes (set in Settings)\n\n" +
                          "Now — fetch once immediately\n\n" +
                          "Gear (Settings) — connection and layer setup\n\n" +
                          "? (Help) — this page"
                }

                Item { height: 6 }

                // ▌ SETTINGS — CONNECTION ──────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#1565C0"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Settings — Connection"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Server URL — full URL of your Traccar server, e.g. " +
                          "https://server.traccar.org  (no trailing slash needed)\n\n" +
                          "Email / Username — your Traccar account email\n\n" +
                          "Password — your Traccar password\n\n" +
                          "Interval — minutes between automatic fetches in Live mode\n\n" +
                          "Test Connection — saves credentials and contacts the server; " +
                          "reports devices found or an error (401 = wrong password, " +
                          "'No response' = bad URL or no network)"
                }

                Item { height: 6 }

                // ▌ SETTINGS — POINT LAYER ─────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#1565C0"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Settings — Point Layer"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Select an editable point layer to receive device positions.\n\n" +
                          "Replace mode — layer is cleared on each fetch, shows current positions only\n" +
                          "Append mode  — new points added each fetch, builds a history\n\n" +
                          "Fields written (include any subset in your layer):\n" +
                          "  device_id   integer  Traccar device ID\n" +
                          "  name        text     device name\n" +
                          "  status      text     online / offline / unknown\n" +
                          "  speed_kmh   real     speed in km/h\n" +
                          "  course      real     bearing in degrees\n" +
                          "  altitude_m  real     altitude in metres\n" +
                          "  fix_time    text     GPS fix timestamp (ISO 8601)\n" +
                          "  battery     real     battery level 0-100\n" +
                          "  address     text     reverse-geocoded address\n" +
                          "  motion      text     motion flag from device\n" +
                          "  fetched_at  text     time the plugin fetched this point\n\n" +
                          "Fields not present in your layer are silently skipped."
                }

                Item { height: 6 }

                // ▌ SETTINGS — TRACK LINE LAYER ────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#1565C0"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Settings — Track Line Layer"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Enable 'Append track line' to grow a polyline per device. " +
                          "Each fetch appends one new vertex to the device's line feature.\n\n" +
                          "Select an editable line layer. One feature per device is kept, " +
                          "identified by device_id.\n\n" +
                          "Required fields:\n" +
                          "  device_id  integer  links each line to a device\n" +
                          "  name       text     written on first creation\n\n" +
                          "On first sight of a device a placeholder line is created. " +
                          "Every subsequent fetch adds a vertex at the current position."
                }

                Item { height: 6 }

                // ▌ QUICK SETUP ────────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: "#546E7A"
                    radius: 3
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Quick Setup in QGIS"
                        color: "white"
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "1. In QGIS open the Traccar Live plugin and use " +
                          "'New GeoPackage...' to create point and track layers " +
                          "with all fields pre-configured.\n\n" +
                          "2. Sync your project to QField (QField Cloud or manual copy).\n\n" +
                          "3. In QField tap the Traccar button, then the gear icon. " +
                          "Enter server details and pick your layers from the dropdowns.\n\n" +
                          "4. Tap Test Connection to verify, then Save."
                }

                Item { height: 8 }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SETTINGS DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      settingsDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        title:   "Traccar Live — Settings"
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       mainWindow.height * 0.02     // near top so Save is reachable

        // No standardButtons — Save/Cancel live inside the ScrollView
        footer: Item { height: 0 }

        // Populate controls from current config when dialog opens
        onOpened: {
            urlField.text      = cfg.serverUrl
            userField.text     = cfg.username
            passField.text     = cfg.password
            intervalSpin.value = cfg.intervalMin
            populateLayers(ptLayerModel, Qgis.GeometryType.Point)
            restoreSelection(liveLayerCombo,   ptLayerModel, cfg.liveLayerName)
            restoreSelection(appendLayerCombo, ptLayerModel, cfg.appendLayerName)
            populateLayers(lnLayerModel, Qgis.GeometryType.Line)
            restoreSelection(lnLayerCombo, lnLayerModel, cfg.lineLayerName)
            cullCountCheck.checked = cfg.cullByCount
            cullMaxSpin.value      = cfg.cullMaxPerDevice
            cullAgeCheck.checked   = cfg.cullByAge
            cullAgeCombo.currentIndex = 0
            for (var ci = 0; ci < timeframeModel.count; ci++) {
                if (timeframeModel.get(ci).minutes === cfg.cullAgeMinutes) {
                    cullAgeCombo.currentIndex = ci
                    break
                }
            }
            incidentRefCheck.checked = cfg.incidentRefEnabled
            populateFieldNames(fieldNameModel, cfg.appendLayerName)
            restoreSelection(incidentRefFieldCombo, fieldNameModel, cfg.incidentRefField)
            incidentRefExprField.text = cfg.incidentRefExpr
        }

        function saveSettings() {
            cfg.serverUrl   = urlField.text.trim().replace(/\/+$/, "")
            cfg.username    = userField.text.trim()
            cfg.password    = passField.text
            cfg.intervalMin = intervalSpin.value
            if (liveLayerCombo.currentIndex >= 0 && ptLayerModel.count > 0) {
                var liveItem = ptLayerModel.get(liveLayerCombo.currentIndex)
                cfg.liveLayerName = (liveItem && !liveItem.isHeader) ? liveItem.name : ""
            }
            if (appendLayerCombo.currentIndex >= 0 && ptLayerModel.count > 0) {
                var appItem = ptLayerModel.get(appendLayerCombo.currentIndex)
                cfg.appendLayerName = (appItem && !appItem.isHeader) ? appItem.name : ""
            }
            if (lnLayerCombo.currentIndex >= 0 && lnLayerModel.count > 0) {
                var lnItem = lnLayerModel.get(lnLayerCombo.currentIndex)
                if (lnItem && !lnItem.isHeader) cfg.lineLayerName = lnItem.name
            }
            cfg.cullByCount      = cullCountCheck.checked
            cfg.cullMaxPerDevice = cullMaxSpin.value
            cfg.cullByAge        = cullAgeCheck.checked
            if (cullAgeCombo.currentIndex >= 0)
                cfg.cullAgeMinutes = timeframeModel.get(cullAgeCombo.currentIndex).minutes
            cfg.incidentRefEnabled = incidentRefCheck.checked
            if (incidentRefFieldCombo.currentIndex >= 0 && fieldNameModel.count > 0) {
                var refItem = fieldNameModel.get(incidentRefFieldCombo.currentIndex)
                cfg.incidentRefField = (refItem && !refItem.isHeader) ? refItem.name : ""
            } else {
                cfg.incidentRefField = ""
            }
            cfg.incidentRefExpr = incidentRefExprField.text
            if (refreshTimer.running) refreshTimer.restart()
            mainWindow.displayToast("Settings saved")
            settingsDialog.close()
            mainDialog.open()
        }

        // ── Scrollable content (Save/Cancel at bottom, always reachable) ──
        ScrollView {
            width:                  parent.width
            height:                 Math.min(implicitHeight, mainWindow.height * 0.88)
            contentWidth:           parent.width
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 6

                // ── Connection ─────────────────────────────────────────────
                Label { text: "── Connection ──"; font.bold: true }

                Label { text: "Server URL:" }
                TextField {
                    id:               urlField
                    Layout.fillWidth: true
                    placeholderText:  "https://server.traccar.org"
                    inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                }

                Label { text: "Email / Username:" }
                TextField {
                    id:               userField
                    Layout.fillWidth: true
                    inputMethodHints: Qt.ImhEmailCharactersOnly
                }

                Label { text: "Password:" }
                TextField {
                    id:       passField
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                }

                Label { text: "Auto-refresh:" }
                RowLayout {
                    SpinBox { id: intervalSpin; from: 1; to: 120; value: 3 }
                    Label   { text: "min" }
                }

                RowLayout {
                    CheckBox {
                        id: histCheck
                        checked: cfg.fetchHistory
                        onCheckedChanged: cfg.fetchHistory = checked
                    }
                    Label {
                        text: "Fetch full track history between refreshes"
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
                Label {
                    visible: cfg.fetchHistory
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: 11
                    color: Theme.secondaryTextColor
                    text: "When enabled, each fetch pulls every GPS fix recorded since " +
                          "the last fetch (one API call per device). " +
                          "All intermediate points are added to the point layer " +
                          "and as vertices to the track line. " +
                          "Disable to fetch current positions only."
                }

                Button {
                    text:             "Test Connection"
                    Layout.fillWidth: true
                    onClicked: {
                        // Save credentials first so test uses current values
                        cfg.serverUrl = urlField.text.trim().replace(/\/+$/, "")
                        cfg.username  = userField.text.trim()
                        cfg.password  = passField.text
                        testConnection()
                    }
                }

                // ── Point layers ───────────────────────────────────────────
                Item { height: 6 }
                Label { text: "── Point Layers ──"; font.bold: true }

                Label {
                    text: "A  Live layer  (cleared and repopulated each fetch — one point per device):"
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                ComboBox {
                    id:               liveLayerCombo
                    Layout.fillWidth: true
                    model:            ptLayerModel
                    textRole:         "name"
                    delegate: ItemDelegate {
                        width:   liveLayerCombo.width
                        enabled: !model.isHeader
                        contentItem: Text {
                            text:              model.name
                            color:             model.isHeader ? Theme.secondaryTextColor
                                                              : Theme.mainTextColor
                            font.pixelSize:    model.isHeader ? 10 : 13
                            verticalAlignment: Text.AlignVCenter
                            leftPadding:       model.isHeader ? 4 : 12
                        }
                        highlighted: liveLayerCombo.highlightedIndex === index
                    }
                }

                Item { height: 4 }
                Label {
                    text: "B  History layer  (all positions appended each fetch):"
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                ComboBox {
                    id:               appendLayerCombo
                    Layout.fillWidth: true
                    model:            ptLayerModel
                    textRole:         "name"
                    delegate: ItemDelegate {
                        width:   appendLayerCombo.width
                        enabled: !model.isHeader
                        contentItem: Text {
                            text:              model.name
                            color:             model.isHeader ? Theme.secondaryTextColor
                                                              : Theme.mainTextColor
                            font.pixelSize:    model.isHeader ? 10 : 13
                            verticalAlignment: Text.AlignVCenter
                            leftPadding:       model.isHeader ? 4 : 12
                        }
                        highlighted: appendLayerCombo.highlightedIndex === index
                    }
                    // Refresh the "Auto-fill Field" combo when the History
                    // layer (B) selection changes within this dialog session.
                    onActivated: {
                        var item = (currentIndex >= 0 && ptLayerModel.count > 0)
                            ? ptLayerModel.get(currentIndex) : null
                        var layerName = (item && !item.isHeader) ? item.name : ""
                        var prevField = cfg.incidentRefField
                        populateFieldNames(fieldNameModel, layerName)
                        restoreSelection(incidentRefFieldCombo, fieldNameModel, prevField)
                    }
                }
                Label {
                    text: "Leave either combo blank (no selection) to disable that layer."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Layer B housekeeping (culling) ──────────────────────────
                Item { height: 6 }
                Label { text: "── Layer B Housekeeping ──"; font.bold: true }
                Label {
                    text: "Optionally remove old points from the History layer (B) after each Live fetch."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                RowLayout {
                    CheckBox {
                        id:      cullCountCheck
                        checked: cfg.cullByCount
                    }
                    Label { text: "Keep at most" }
                    SpinBox {
                        id: cullMaxSpin
                        from: 1; to: 100000; stepSize: 50
                        editable: true
                        value:   cfg.cullMaxPerDevice
                        enabled: cullCountCheck.checked
                    }
                    Label {
                        text: "points / device"
                        Layout.fillWidth: true
                        opacity: cullCountCheck.checked ? 1.0 : 0.6
                    }
                }

                RowLayout {
                    CheckBox {
                        id:      cullAgeCheck
                        checked: cfg.cullByAge
                    }
                    Label { text: "Remove points older than:"; Layout.fillWidth: true }
                }
                ComboBox {
                    id:               cullAgeCombo
                    Layout.fillWidth: true
                    enabled:          cullAgeCheck.checked
                    opacity:          enabled ? 1.0 : 0.6
                    model:            timeframeModel
                    textRole:         "label"
                    delegate: ItemDelegate {
                        width: cullAgeCombo.width
                        contentItem: Text {
                            text:              model.label
                            color:             Theme.mainTextColor
                            font.pixelSize:    13
                            verticalAlignment: Text.AlignVCenter
                        }
                        highlighted: cullAgeCombo.highlightedIndex === index
                    }
                }
                Label {
                    text: "Both checks run after each Live fetch updates layer B (per device, by fix time). The track line layer (C) is never culled."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Auto-fill field on new features ─────────────────────────
                Item { height: 6 }
                Label { text: "── Auto-fill Field on New Features ──"; font.bold: true }
                Label {
                    text: "Optionally write an evaluated expression into a field on every new point/track feature created by this plugin (layers A, B and C)."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }
                RowLayout {
                    CheckBox {
                        id:      incidentRefCheck
                        checked: cfg.incidentRefEnabled
                    }
                    Label { text: "Auto-fill field"; Layout.fillWidth: true }
                }
                Label {
                    text:    "Field (from History layer B):"
                    enabled: incidentRefCheck.checked
                    color:   incidentRefCheck.checked ? Theme.mainTextColor : Theme.secondaryTextColor
                }
                ComboBox {
                    id:               incidentRefFieldCombo
                    Layout.fillWidth: true
                    enabled:          incidentRefCheck.checked
                    opacity:          enabled ? 1.0 : 0.6
                    model:            fieldNameModel
                    textRole:         "name"
                    delegate: ItemDelegate {
                        width:   incidentRefFieldCombo.width
                        enabled: !model.isHeader
                        contentItem: Text {
                            text:              model.name
                            color:             model.isHeader ? Theme.secondaryTextColor
                                                              : Theme.mainTextColor
                            font.pixelSize:    model.isHeader ? 10 : 13
                            verticalAlignment: Text.AlignVCenter
                            leftPadding:       model.isHeader ? 4 : 12
                        }
                        highlighted: incidentRefFieldCombo.highlightedIndex === index
                    }
                }
                Label {
                    text:    "Expression:"
                    enabled: incidentRefCheck.checked
                    color:   incidentRefCheck.checked ? Theme.mainTextColor : Theme.secondaryTextColor
                }
                TextField {
                    id:               incidentRefExprField
                    Layout.fillWidth: true
                    enabled:          incidentRefCheck.checked
                    opacity:          enabled ? 1.0 : 0.6
                    text:             cfg.incidentRefExpr
                    placeholderText:  "'KMRT-' || format_date(now(),'ddd-dd/MM/yy')||'-1'"
                    font.family:      "monospace"
                }
                Label {
                    text: "Subset of QGIS expressions: string literals ('...'), the || operator, and now() / today() / format_date(expr,'fmt')."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Line track layer ───────────────────────────────────────
                Item { height: 6 }
                Label { text: "── Track Line Layer ──"; font.bold: true }

                RowLayout {
                    CheckBox {
                        id:        trackCheck
                        checked:   cfg.appendTrack
                        onCheckedChanged: cfg.appendTrack = checked
                    }
                    Label { text: "Append vertex to line track layer" }
                }

                Label {
                    text:    "Line layer:"
                    enabled: cfg.appendTrack
                    color:   cfg.appendTrack ? Theme.mainTextColor : Theme.secondaryTextColor
                }
                ComboBox {
                    id:               lnLayerCombo
                    Layout.fillWidth: true
                    enabled:          cfg.appendTrack
                    model:            lnLayerModel
                    textRole:         "name"
                    delegate: ItemDelegate {
                        width:   lnLayerCombo.width
                        enabled: !model.isHeader
                        contentItem: Text {
                            text:              model.name
                            color:             model.isHeader ? Theme.secondaryTextColor
                                                              : Theme.mainTextColor
                            font.pixelSize:    model.isHeader ? 10 : 13
                            verticalAlignment: Text.AlignVCenter
                            leftPadding:       model.isHeader ? 4 : 12
                        }
                        highlighted: lnLayerCombo.highlightedIndex === index
                    }
                }

                Label {
                    text:       "Line layer fields expected:\ndevice_id (integer), name (text)"
                    font.pixelSize: 10
                    color:          Theme.secondaryTextColor
                    wrapMode:       Text.WordWrap
                    Layout.fillWidth: true
                    visible:    cfg.appendTrack
                }

                // ── Save / Cancel ──────────────────────────────────────────
                Item { height: 8 }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text:             "Cancel"
                        Layout.fillWidth: true
                        onClicked: {
                            settingsDialog.close()
                            mainDialog.open()
                        }
                    }
                    Button {
                        text:             "Save"
                        Layout.fillWidth: true
                        onClicked:        settingsDialog.saveSettings()
                    }
                }
                Item { height: 8 }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FETCH LOGS DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      fetchLogsDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        title:   "Traccar Live — Fetch Logs"
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       (mainWindow.height - height) * 0.08

        // Runtime state
        property var    fetchDevices: []
        property bool   fetchLogBusy: false
        property string fetchStatus:  "Loading devices…"

        standardButtons: Dialog.Close
        onRejected: mainDialog.open()

        onOpened: {
            var today = Qt.formatDate(new Date(), "yyyy-MM-dd")
            fromDateField.text = today
            toDateField.text   = today
            quickRangeCombo.currentIndex = 0
            loadFetchDevices()
        }

        ScrollView {
            width:        parent.width
            height:       Math.min(implicitHeight, mainWindow.height * 0.7)
            contentWidth: parent.width
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 6

                // ── Date range ─────────────────────────────────────────────
                Label {
                    text: "── Date Range  (full days, local time) ──"
                    font.bold: true
                }

                Label { text: "Quick range:" }
                ComboBox {
                    id:               quickRangeCombo
                    Layout.fillWidth: true
                    model:            timeframeModel
                    textRole:         "label"
                    delegate: ItemDelegate {
                        width: quickRangeCombo.width
                        contentItem: Text {
                            text:              model.label
                            color:             Theme.mainTextColor
                            font.pixelSize:    13
                            verticalAlignment: Text.AlignVCenter
                        }
                        highlighted: quickRangeCombo.highlightedIndex === index
                    }
                }

                Label {
                    text: "From date:"
                    opacity: quickRangeCombo.currentIndex === 0 ? 1.0 : 0.6
                }
                TextField {
                    id:               fromDateField
                    Layout.fillWidth: true
                    placeholderText:  "YYYY-MM-DD"
                    inputMethodHints: Qt.ImhDigitsOnly
                    enabled:          quickRangeCombo.currentIndex === 0
                    opacity:          enabled ? 1.0 : 0.6
                }

                Label {
                    text: "To date:"
                    opacity: quickRangeCombo.currentIndex === 0 ? 1.0 : 0.6
                }
                TextField {
                    id:               toDateField
                    Layout.fillWidth: true
                    placeholderText:  "YYYY-MM-DD"
                    inputMethodHints: Qt.ImhDigitsOnly
                    enabled:          quickRangeCombo.currentIndex === 0
                    opacity:          enabled ? 1.0 : 0.6
                }

                // ── Devices ────────────────────────────────────────────────
                Item { height: 4 }
                Label { text: "── Devices ──"; font.bold: true }

                RowLayout {
                    CheckBox {
                        id:      fetchAllDevsCheck
                        checked: true
                        onCheckedChanged: fetchDevCombo.enabled = !checked
                    }
                    Label {
                        text:             "All devices  (including offline)"
                        Layout.fillWidth: true
                    }
                }

                ComboBox {
                    id:               fetchDevCombo
                    Layout.fillWidth: true
                    enabled:          false
                    model:            fetchDevsModel
                    textRole:         "label"
                    delegate: ItemDelegate {
                        width:   fetchDevCombo.width
                        contentItem: Text {
                            text:              model.label
                            color:             Theme.mainTextColor
                            font.pixelSize:    13
                            verticalAlignment: Text.AlignVCenter
                        }
                        highlighted: fetchDevCombo.highlightedIndex === index
                    }
                }

                // ── Output layers ──────────────────────────────────────────
                Item { height: 4 }
                Label { text: "── Write to ──"; font.bold: true }

                RowLayout {
                    CheckBox {
                        id:      fetchWritePts
                        checked: cfg.appendLayerName !== ""
                        enabled: cfg.appendLayerName !== ""
                    }
                    Label {
                        text: cfg.appendLayerName !== ""
                              ? "B  History layer  (" + cfg.appendLayerName + ")"
                              : "B  History layer  (not configured)"
                        color: cfg.appendLayerName !== ""
                               ? Theme.mainTextColor
                               : Theme.secondaryTextColor
                        wrapMode:         Text.WordWrap
                        Layout.fillWidth: true
                    }
                }

                RowLayout {
                    CheckBox {
                        id:      fetchWriteLns
                        checked: cfg.lineLayerName !== ""
                        enabled: cfg.lineLayerName !== ""
                    }
                    Label {
                        text: cfg.lineLayerName !== ""
                              ? "C  Track line layer  (" + cfg.lineLayerName + ")"
                              : "C  Track line layer  (not configured)"
                        color: cfg.lineLayerName !== ""
                               ? Theme.mainTextColor
                               : Theme.secondaryTextColor
                        wrapMode:         Text.WordWrap
                        Layout.fillWidth: true
                    }
                }

                // ── Point layer limit ────────────────────────────────────────
                Item { height: 4 }
                Label { text: "── Point Layer Limit ──"; font.bold: true }

                RowLayout {
                    CheckBox {
                        id:      fetchLimitPtsCheck
                        checked: cfg.fetchLimitPts
                        onCheckedChanged: cfg.fetchLimitPts = checked
                    }
                    Label { text: "Limit points written per device"; Layout.fillWidth: true }
                }

                RowLayout {
                    Label {
                        text: "Most recent"
                        opacity: fetchLimitPtsCheck.checked ? 1.0 : 0.6
                    }
                    SpinBox {
                        id: fetchMaxPointsSpin
                        from: 1; to: 100000; stepSize: 50
                        editable: true
                        value:   cfg.fetchMaxPoints
                        enabled: fetchLimitPtsCheck.checked
                        onValueModified: cfg.fetchMaxPoints = value
                    }
                    Label {
                        text: "points"
                        opacity: fetchLimitPtsCheck.checked ? 1.0 : 0.6
                    }
                }

                Label {
                    text: "Caps how many of the most recent positions per device are written to the point layer (B). The track line layer (C) always uses the full set of positions fetched."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Status ─────────────────────────────────────────────────
                Item { height: 4 }
                Label {
                    text:             fetchLogsDialog.fetchStatus
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                    font.pixelSize:   12
                    color: fetchLogsDialog.fetchStatus.charAt(0) === "✓"
                           ? "#2E7D32"
                           : Theme.secondaryTextColor
                }

                // ── Fetch button ───────────────────────────────────────────
                Button {
                    text:             fetchLogsDialog.fetchLogBusy ? "Fetching…" : "Fetch"
                    Layout.fillWidth: true
                    enabled:          !fetchLogsDialog.fetchLogBusy &&
                                      fetchLogsDialog.fetchDevices.length > 0
                    onClicked:        fetchLogs()
                }

                Item { height: 8 }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FETCH LOGIC
    // ════════════════════════════════════════════════════════════════════════

    function fetchAll() {
        if (plugin.fetchBusy) return
        plugin.fetchBusy = true

        _get("/api/devices", function(devData) {
            var lookup = {}
            devData.forEach(function(d) {
                lookup[d.id] = { name: d.name || String(d.id), status: d.status || "unknown" }
            })
            plugin.deviceInfo = lookup

            var nowIso  = new Date().toISOString()
            var devIds  = Object.keys(lookup)

            // ── History mode: pull every fix since the last fetch ─────────
            if (cfg.fetchHistory && cfg.lastFetchIso !== "" && devIds.length > 0) {
                var allPos  = []
                var pending = devIds.length
                var fromEnc = encodeURIComponent(cfg.lastFetchIso)
                var toEnc   = encodeURIComponent(nowIso)

                devIds.forEach(function(rawId) {
                    // IIFE keeps rawId in closure correctly
                    ;(function(devId) {
                        _get("/api/positions?deviceId=" + devId
                                + "&from=" + fromEnc + "&to=" + toEnc,
                            function(hist) {
                                for (var i = 0; i < hist.length; i++) allPos.push(hist[i])
                                pending--
                                if (pending === 0) {
                                    // Always fetch last-known position for ALL devices
                                    // (incl. offline ones not in the history window) for
                                    // layer A and the device panel.
                                    _get("/api/positions", function(liveData) {
                                        _finalizeFetch(allPos, lookup, nowIso, liveData)
                                    })
                                }
                            }
                        )
                    })(rawId)
                })
            } else {
                // ── Current-positions-only mode ───────────────────────────
                // /api/positions (no range) already returns the last-known fix
                // for every device including offline — no extra call needed.
                _get("/api/positions", function(posData) {
                    _finalizeFetch(posData, lookup, nowIso)
                })
            }
        })
    }

    // Called when all position data (current or historical) is assembled.
    // liveData (optional) — last-known fix array from /api/positions with NO
    //   date range.  When provided (history mode) it is used for the device panel
    //   and layer A so offline devices that had no fixes in the history window
    //   still appear at their last known location.
    //   In current-positions-only mode liveData is undefined and `positions`
    //   already is the last-known-per-device data, so no extra handling needed.
    function _finalizeFetch(positions, deviceInfo, nowIso, liveData) {
        // Decide which data feeds the device panel and layer A.
        // liveData (if present) always contains exactly one last-known fix per
        // device — Traccar guarantees this from /api/positions with no filter.
        var liveSource = (liveData && liveData.length > 0) ? liveData : positions

        // Latest fix per device → shown in the device list
        var latestByDevice = {}
        for (var i = 0; i < liveSource.length; i++) {
            var pos = liveSource[i]
            var k   = pos.deviceId
            if (!latestByDevice[k] ||
                    (pos.fixTime || "") > (latestByDevice[k].fixTime || ""))
                latestByDevice[k] = pos
        }
        var latest = []
        for (var key in latestByDevice) latest.push(latestByDevice[key])

        plugin.positions   = latest
        plugin.fetchBusy   = false
        plugin.lastFetched = Qt.formatTime(new Date(), "hh:mm:ss")
                           + "  -  " + latest.length + " device(s)"
        if (positions.length > latest.length)
            plugin.lastFetched += "  (" + positions.length + " pts)"

        // A: live layer — always fed from last-known positions (incl. offline)
        if (cfg.liveLayerName   !== "") _updateLiveLayer(latest,    deviceInfo)
        // B+C: fed from the history range (or current positions in non-history mode)
        if (cfg.appendLayerName !== "") {
            _updateAppendLayer(positions, deviceInfo)
            if (cfg.cullByCount || cfg.cullByAge) _cullAppendLayer()
        }
        if (cfg.appendTrack && cfg.lineLayerName !== "") _updateLineLayer(positions, deviceInfo)

        cfg.lastFetchIso = nowIso
    }

    function testConnection() {
        mainWindow.displayToast("Testing…")
        _get("/api/devices", function(data) {
            mainWindow.displayToast("✓ Connected — " + data.length + " device(s)")
        })
    }

    // ── Load device list into the Fetch Logs dialog ───────────────────────
    function loadFetchDevices() {
        fetchLogsDialog.fetchStatus  = "Loading devices…"
        fetchLogsDialog.fetchDevices = []
        fetchDevsModel.clear()
        _get("/api/devices", function(data) {
            fetchLogsDialog.fetchDevices = data
            fetchDevsModel.clear()
            for (var i = 0; i < data.length; i++) {
                var d = data[i]
                fetchDevsModel.append({
                    label: (d.name || String(d.id)) + "  [" + (d.status || "?") + "]"
                })
            }
            if (data.length > 0) {
                fetchLogsDialog.fetchStatus =
                    data.length + " device(s) found — set time range and tap Fetch"
            } else {
                fetchLogsDialog.fetchStatus = "No devices found on server"
            }
        })
    }

    // ── Parse "YYYY-MM-DD" text into a local-midnight Date ───────────────
    function _parseDate(str) {
        var p = str.trim().split("-")
        if (p.length !== 3) return null
        var y = parseInt(p[0]), m = parseInt(p[1]) - 1, d = parseInt(p[2])
        if (isNaN(y) || isNaN(m) || isNaN(d)) return null
        if (y < 2000 || y > 2099 || m < 0 || m > 11 || d < 1 || d > 31) return null
        return new Date(y, m, d)
    }

    // ── Fetch historical positions for a custom date range ────────────────
    function fetchLogs() {
        if (fetchLogsDialog.fetchLogBusy) return

        var fromIso, toIso

        // ── Quick range (last X minutes/hours/days) takes precedence over the date fields ──
        var qrIdx     = quickRangeCombo.currentIndex
        var qrMinutes = (qrIdx > 0) ? timeframeModel.get(qrIdx).minutes : 0

        if (qrMinutes > 0) {
            var now    = new Date()
            var fromDt = new Date(now.getTime() - qrMinutes * 60000)
            fromIso = fromDt.toISOString()
            toIso   = now.toISOString()
        } else {
            var fromDate = _parseDate(fromDateField.text)
            var toDate   = _parseDate(toDateField.text)

            if (!fromDate || !toDate) {
                fetchLogsDialog.fetchStatus = "Enter dates as YYYY-MM-DD"
                return
            }

            // from = 00:00:00 local on from-date
            // to   = 23:59:59 local on to-date  (covers the whole to-day)
            var toDateEnd = new Date(toDate.getFullYear(), toDate.getMonth(),
                                     toDate.getDate(), 23, 59, 59, 0)

            if (fromDate > toDateEnd) {
                fetchLogsDialog.fetchStatus = "'From' must not be after 'To'"
                return
            }

            fromIso = fromDate.toISOString()
            toIso   = toDateEnd.toISOString()
        }

        if (!fetchWritePts.checked && !fetchWriteLns.checked) {
            fetchLogsDialog.fetchStatus = "Select at least one output layer"
            return
        }

        // Build device ID list and lookup
        var devs      = fetchLogsDialog.fetchDevices
        var devIds    = []
        var devLookup = {}
        if (fetchAllDevsCheck.checked) {
            for (var i = 0; i < devs.length; i++) {
                devIds.push(devs[i].id)
                devLookup[devs[i].id] = {
                    name:   devs[i].name   || String(devs[i].id),
                    status: devs[i].status || ""
                }
            }
        } else {
            var idx = fetchDevCombo.currentIndex
            if (idx >= 0 && idx < devs.length) {
                devIds.push(devs[idx].id)
                devLookup[devs[idx].id] = {
                    name:   devs[idx].name   || String(devs[idx].id),
                    status: devs[idx].status || ""
                }
            }
        }

        if (devIds.length === 0) {
            fetchLogsDialog.fetchStatus = "No devices to fetch"
            return
        }

        fetchLogsDialog.fetchLogBusy = true
        fetchLogsDialog.fetchStatus  = "Fetching " + devIds.length + " device(s)…"

        var fromEnc = encodeURIComponent(fromIso)
        var toEnc   = encodeURIComponent(toIso)
        var allPos  = []
        var pending = devIds.length

        devIds.forEach(function(rawId) {
            ;(function(devId) {
                _get("/api/positions?deviceId=" + devId
                        + "&from=" + fromEnc + "&to=" + toEnc,
                    function(hist) {
                        for (var i = 0; i < hist.length; i++) allPos.push(hist[i])
                        pending--
                        if (pending > 0) return   // wait for all devices

                        // All done — write to layers
                        fetchLogsDialog.fetchLogBusy = false
                        if (allPos.length === 0) {
                            fetchLogsDialog.fetchStatus =
                                "No positions found in this time range"
                            return
                        }
                        var written = []
                        if (fetchWritePts.checked && cfg.appendLayerName !== "") {
                            var ptsPos = allPos
                            if (fetchLimitPtsCheck.checked) {
                                var maxPts = fetchMaxPointsSpin.value
                                var byDev  = {}
                                allPos.forEach(function(p) {
                                    (byDev[p.deviceId] = byDev[p.deviceId] || []).push(p)
                                })
                                ptsPos = []
                                Object.keys(byDev).forEach(function(devId) {
                                    var arr = byDev[devId]
                                    arr.sort(function(a, b) {
                                        return new Date(b.fixTime) - new Date(a.fixTime)
                                    })
                                    ptsPos = ptsPos.concat(arr.slice(0, maxPts))
                                })
                            }
                            _updateAppendLayer(ptsPos, devLookup, true)
                            written.push(ptsPos.length + " point(s)"
                                         + (ptsPos.length !== allPos.length
                                            ? " of " + allPos.length
                                            : ""))
                        }
                        if (fetchWriteLns.checked && cfg.lineLayerName !== "") {
                            _updateLineLayer(allPos, devLookup)
                            var nDevs = {}
                            for (var j = 0; j < allPos.length; j++)
                                nDevs[allPos[j].deviceId] = true
                            written.push(Object.keys(nDevs).length + " track(s) updated")
                        }
                        fetchLogsDialog.fetchStatus =
                            "✓  Done — " + written.join(",  ")
                    }
                )
            })(rawId)
        })
    }

    function zoomToDevice(pos) {
        if (pos.longitude === undefined || pos.latitude === undefined) return
        try {
            var wgs = CoordinateReferenceSystemUtils.fromDescription("EPSG:4326")
            var dst = iface.mapCanvas().mapSettings.destinationCrs
            var rpt = GeometryUtils.reprojectPoint(
                GeometryUtils.point(pos.longitude, pos.latitude), wgs, dst)
            iface.mapCanvas().mapSettings.setCenter(rpt, true)
        } catch(e) {
            mainWindow.displayToast("Zoom error: " + e)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SHARED POINT-WRITE HELPER
    // ════════════════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════════════════
    //  MINI QGIS-EXPRESSION EVALUATOR (incident_ref auto-fill)
    //
    //  Supports a small subset of QGIS expression syntax: string literals
    //  ('...'), the '||' concatenation operator, and the functions
    //  now(), today(), and format_date(date_expr, 'format'). This is enough
    //  to evaluate the project's default expression for fields such as
    //  incident_ref:  'KMRT-' || format_date(now(),'ddd-dd/MM/yy') || '-1'
    // ════════════════════════════════════════════════════════════════════════

    readonly property var _exprDaysShort: ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
    readonly property var _exprDaysLong:  ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
    readonly property var _exprMonShort:  ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    readonly property var _exprMonLong:   ["January","February","March","April","May","June","July","August","September","October","November","December"]

    // Evaluate exprStr and return the resulting string, or null (with a
    // toast warning) if it cannot be parsed/evaluated. Empty/blank
    // expressions return null silently (treated as "nothing to write").
    function _evalIncidentRefExpr(exprStr) {
        if (!exprStr || exprStr.trim() === "") return null
        try {
            var tokens = _tokenizeQgisExpr(exprStr)
            if (tokens.length === 0) return null
            var result = _parseConcat(tokens, 0)
            if (result.pos !== tokens.length)
                throw new Error("unexpected trailing characters")
            return _exprToString(result.value)
        } catch (e) {
            mainWindow.displayToast("incident_ref expression error: " + e.message)
            return null
        }
    }

    // Convert an evaluated term (string or Date) to its string form.
    function _exprToString(v) {
        if (v === null || v === undefined) return ""
        if (v instanceof Date) return v.toISOString()
        return String(v)
    }

    // Split an expression string into STRING / CONCAT / LPAREN / RPAREN /
    // COMMA / IDENT tokens. Throws on unexpected characters.
    function _tokenizeQgisExpr(s) {
        var tokens = []
        var i = 0
        while (i < s.length) {
            var c = s[i]
            if (c === " " || c === "\t" || c === "\n" || c === "\r") { i++; continue }
            if (c === "'") {
                var j = i + 1
                var str = ""
                while (j < s.length) {
                    if (s[j] === "'") {
                        if (s[j+1] === "'") { str += "'"; j += 2; continue } // escaped '' -> '
                        break
                    }
                    str += s[j]; j++
                }
                if (j >= s.length) throw new Error("unterminated string literal")
                tokens.push({ type: "STRING", value: str })
                i = j + 1
                continue
            }
            if (c === "|" && s[i+1] === "|") { tokens.push({ type: "CONCAT" }); i += 2; continue }
            if (c === "(") { tokens.push({ type: "LPAREN" }); i++; continue }
            if (c === ")") { tokens.push({ type: "RPAREN" }); i++; continue }
            if (c === ",") { tokens.push({ type: "COMMA" }); i++; continue }
            if (/[A-Za-z_]/.test(c)) {
                var k = i + 1
                while (k < s.length && /[A-Za-z0-9_]/.test(s[k])) k++
                tokens.push({ type: "IDENT", value: s.substring(i, k) })
                i = k
                continue
            }
            throw new Error("unexpected character '" + c + "'")
        }
        return tokens
    }

    // term ('||' term)*
    function _parseConcat(tokens, pos) {
        var first = _parseTerm(tokens, pos)
        var value = first.value
        pos = first.pos
        while (pos < tokens.length && tokens[pos].type === "CONCAT") {
            var rhs = _parseTerm(tokens, pos + 1)
            value = _exprToString(value) + _exprToString(rhs.value)
            pos = rhs.pos
        }
        return { value: value, pos: pos }
    }

    // STRING | IDENT '(' (concat (',' concat)*)? ')' | '(' concat ')'
    function _parseTerm(tokens, pos) {
        if (pos >= tokens.length) throw new Error("unexpected end of expression")
        var tok = tokens[pos]
        if (tok.type === "STRING") return { value: tok.value, pos: pos + 1 }
        if (tok.type === "IDENT") {
            var name = tok.value.toLowerCase()
            pos++
            var args = []
            if (pos < tokens.length && tokens[pos].type === "LPAREN") {
                pos++
                if (pos < tokens.length && tokens[pos].type !== "RPAREN") {
                    while (true) {
                        var argRes = _parseConcat(tokens, pos)
                        args.push(argRes.value)
                        pos = argRes.pos
                        if (pos < tokens.length && tokens[pos].type === "COMMA") { pos++; continue }
                        break
                    }
                }
                if (pos >= tokens.length || tokens[pos].type !== "RPAREN")
                    throw new Error("expected ')' after arguments to " + name + "()")
                pos++
            }
            return { value: _callExprFunc(name, args), pos: pos }
        }
        if (tok.type === "LPAREN") {
            var inner = _parseConcat(tokens, pos + 1)
            if (inner.pos >= tokens.length || tokens[inner.pos].type !== "RPAREN")
                throw new Error("expected ')'")
            return { value: inner.value, pos: inner.pos + 1 }
        }
        throw new Error("unexpected token in expression")
    }

    // Dispatch supported function calls.
    function _callExprFunc(name, args) {
        switch (name) {
            case "now":
            case "today":
                return new Date()
            case "format_date":
                if (args.length < 2) throw new Error("format_date() requires 2 arguments")
                var d = args[0]
                if (!(d instanceof Date)) d = new Date(d)
                return _formatQgisDate(d, _exprToString(args[1]))
            default:
                throw new Error("unknown function " + name + "()")
        }
    }

    // Format a Date using QGIS-style format tokens.
    function _formatQgisDate(d, fmt) {
        var pad = function(n, w) {
            var s = String(n)
            while (s.length < w) s = "0" + s
            return s
        }
        var tokenRe = /yyyy|yy|MMMM|MMM|MM|M|dddd|ddd|dd|d|HH|H|hh|h|mm|m|ss|s/g
        return fmt.replace(tokenRe, function(tok) {
            switch (tok) {
                case "yyyy": return String(d.getFullYear())
                case "yy":   return pad(d.getFullYear() % 100, 2)
                case "MMMM": return _exprMonLong[d.getMonth()]
                case "MMM":  return _exprMonShort[d.getMonth()]
                case "MM":   return pad(d.getMonth() + 1, 2)
                case "M":    return String(d.getMonth() + 1)
                case "dddd": return _exprDaysLong[d.getDay()]
                case "ddd":  return _exprDaysShort[d.getDay()]
                case "dd":   return pad(d.getDate(), 2)
                case "d":    return String(d.getDate())
                case "HH":   return pad(d.getHours(), 2)
                case "H":    return String(d.getHours())
                case "hh":   return pad((d.getHours() % 12) || 12, 2)
                case "h":    return String((d.getHours() % 12) || 12)
                case "mm":   return pad(d.getMinutes(), 2)
                case "m":    return String(d.getMinutes())
                case "ss":   return pad(d.getSeconds(), 2)
                case "s":    return String(d.getSeconds())
                default:     return tok
            }
        })
    }

    function _writePointsToLayer(lyr, positions, deviceInfo) {
        // Evaluate the auto-fill expression once per call (not per-feature) —
        // now()/today() should reflect the time of this fetch, not drift
        // across hundreds of features.
        var incidentRefValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== "")
            ? _evalIncidentRefExpr(cfg.incidentRefExpr) : null

        positions.forEach(function(pos) {
            if (pos.latitude === undefined || pos.longitude === undefined) return
            var info     = deviceInfo[pos.deviceId] || {}
            var attrs    = pos.attributes || {}
            var speedKmh = Math.round((pos.speed || 0) * 1.852 * 10) / 10
            var battery  = (attrs.batteryLevel !== undefined) ? attrs.batteryLevel : null
            var geom     = _geomForLayer(lyr, pos.longitude, pos.latitude)
            var feat     = FeatureUtils.createFeature(lyr, geom)
            var fnames   = lyr.fields.names
            for (var i = 0; i < fnames.length; i++) {
                switch (fnames[i]) {
                    case "device_id":  feat.setAttribute(i, pos.deviceId || -1);                break
                    case "name":       feat.setAttribute(i, info.name || String(pos.deviceId)); break
                    case "status":     feat.setAttribute(i, info.status || "");                 break
                    case "speed_kmh":  feat.setAttribute(i, speedKmh);                          break
                    case "course":     feat.setAttribute(i, pos.course   || 0);                 break
                    case "altitude_m": feat.setAttribute(i, pos.altitude  || 0);                break
                    case "fix_time":   feat.setAttribute(i, pos.fixTime   || "");               break
                    case "battery":    feat.setAttribute(i, battery);                            break
                    case "address":    feat.setAttribute(i, pos.address   || "");               break
                    case "motion":     feat.setAttribute(i, String(attrs.motion || ""));         break
                    case "fetched_at": feat.setAttribute(i, new Date().toISOString());           break
                    default:
                        if (incidentRefValue !== null && fnames[i] === cfg.incidentRefField)
                            feat.setAttribute(i, incidentRefValue)
                        break
                }
            }
            LayerUtils.addFeature(lyr, feat)
        })
    }

    // ════════════════════════════════════════════════════════════════════════
    //  A: LIVE LAYER  — truncated and repopulated with latest fix per device
    // ════════════════════════════════════════════════════════════════════════

    function _updateLiveLayer(positions, deviceInfo) {
        if (cfg.liveLayerName === "") return
        var layers = qgisProject.mapLayersByName(cfg.liveLayerName)
        if (layers.length === 0) {
            mainWindow.displayToast("Live layer '" + cfg.liveLayerName + "' not found")
            return
        }
        var lyr = layers[0]
        try {
            lyr.startEditing()
            lyr.selectAll()
            lyr.deleteSelectedFeatures()
            _writePointsToLayer(lyr, positions, deviceInfo)
            lyr.commitChanges()
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Live layer error: " + e)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  B: APPEND/HISTORY LAYER  — positions added, never deleted
    //     forceAppend param kept for Fetch Logs compatibility (always true here)
    // ════════════════════════════════════════════════════════════════════════

    function _updateAppendLayer(positions, deviceInfo, forceAppend) {
        if (cfg.appendLayerName === "") return
        var layers = qgisProject.mapLayersByName(cfg.appendLayerName)
        if (layers.length === 0) {
            mainWindow.displayToast("History layer '" + cfg.appendLayerName + "' not found")
            return
        }
        var lyr = layers[0]
        try {
            lyr.startEditing()
            _writePointsToLayer(lyr, positions, deviceInfo)
            lyr.commitChanges()
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("History layer error: " + e)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  B: APPEND/HISTORY LAYER — housekeeping (cull old points)
    //  Runs after each Live fetch when "Layer B Housekeeping" is enabled:
    //    cullByCount — keep at most cullMaxPerDevice points per device (newest first)
    //    cullByAge   — drop points with fix_time older than "now - cullAgeMinutes"
    //  Both filters use the "fix_time" / "device_id" fields written by
    //  _writePointsToLayer. Uses the same read-all → clear → rebuild approach
    //  as _updateLineLayer below, since selecting/deleting individual features
    //  by id is not reliably available in QField's QML API.
    // ════════════════════════════════════════════════════════════════════════

    function _cullAppendLayer() {
        if (cfg.appendLayerName === "") return
        if (!cfg.cullByCount && !cfg.cullByAge) return
        var layers = qgisProject.mapLayersByName(cfg.appendLayerName)
        if (layers.length === 0) return
        var lyr    = layers[0]
        var fnames = lyr.fields.names
        if (fnames.indexOf("fix_time") < 0) return   // nothing to cull/sort on

        try {
            // ── Phase 1: read every existing feature ──────────────────────
            lyr.selectAll()
            var feats = lyr.selectedFeatures ? lyr.selectedFeatures() : []
            lyr.removeSelection()
            if (feats.length === 0) return

            var records = []
            for (var i = 0; i < feats.length; i++) {
                var f   = feats[i]
                var rec = { geom: null, attrs: {} }
                try { rec.geom = f.geometry.asWkt ? f.geometry.asWkt() : null } catch(eg) {}
                for (var fi = 0; fi < fnames.length; fi++) {
                    try { rec.attrs[fnames[fi]] = f.attribute(fnames[fi]) } catch(ea) {}
                }
                records.push(rec)
            }

            var keep    = records
            var removed = 0

            // ── Determine each device's newest record — always protected from ──
            // ── age-based culling, so every device retains at least one point ──
            var newestByDev = {}
            records.forEach(function(r) {
                var dev = String(r.attrs.device_id)
                var ft  = String(r.attrs.fix_time || "")
                if (!newestByDev[dev] || ft > String(newestByDev[dev].attrs.fix_time || ""))
                    newestByDev[dev] = r
            })
            var protectedRecs = Object.keys(newestByDev).map(function(k) { return newestByDev[k] })

            // ── Cull by age ───────────────────────────────────────────────
            if (cfg.cullByAge && cfg.cullAgeMinutes > 0) {
                var cutoffIso = new Date(Date.now() - cfg.cullAgeMinutes * 60000).toISOString()
                var beforeAge = keep.length
                keep = keep.filter(function(r) {
                    var ft = String(r.attrs.fix_time || "")
                    if (ft === "" || ft >= cutoffIso) return true
                    return protectedRecs.indexOf(r) >= 0   // keep each device's newest point
                })
                removed += beforeAge - keep.length
            }

            // ── Cull by count (per device, newest kept first) ───────────────
            if (cfg.cullByCount) {
                var byDev = {}
                keep.forEach(function(r) {
                    var dev = String(r.attrs.device_id)
                    ;(byDev[dev] = byDev[dev] || []).push(r)
                })
                var newKeep = []
                Object.keys(byDev).forEach(function(dev) {
                    var arr = byDev[dev]
                    arr.sort(function(a, b) {
                        var ta = String(a.attrs.fix_time || "")
                        var tb = String(b.attrs.fix_time || "")
                        return ta < tb ? 1 : (ta > tb ? -1 : 0)   // newest first
                    })
                    if (arr.length > cfg.cullMaxPerDevice) {
                        removed += arr.length - cfg.cullMaxPerDevice
                        arr = arr.slice(0, cfg.cullMaxPerDevice)
                    }
                    newKeep = newKeep.concat(arr)
                })
                keep = newKeep
            }

            if (removed === 0) return   // nothing to do — leave layer untouched

            // ── Phase 2: clear layer and rebuild with the kept records ───────
            lyr.startEditing()
            lyr.selectAll()
            lyr.deleteSelectedFeatures()
            keep.forEach(function(r) {
                if (!r.geom) return
                var geom = GeometryUtils.createGeometryFromWkt(r.geom)
                var feat = FeatureUtils.createFeature(lyr, geom)
                for (var fi = 0; fi < fnames.length; fi++)
                    feat.setAttribute(fi, r.attrs[fnames[fi]])
                LayerUtils.addFeature(lyr, feat)
            })
            lyr.commitChanges()
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Layer B cull error: " + e)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  LINE TRACK LAYER UPDATE
    //
    //  Strategy: read-all → clear-all → rebuild
    //  This avoids selectByExpression during editing (unreliable in QML).
    //  Accepts an array of positions which may contain multiple entries per
    //  device (when fetchHistory is enabled) — all are appended in time order.
    // ════════════════════════════════════════════════════════════════════════

    function _updateLineLayer(allPositions, deviceInfo) {
        if (cfg.lineLayerName === "") return
        var layers = qgisProject.mapLayersByName(cfg.lineLayerName)
        if (layers.length === 0) {
            mainWindow.displayToast("Line layer '" + cfg.lineLayerName + "' not found")
            return
        }
        var lyr = layers[0]

        // ── Phase 1: read every existing track WKT ────────────────────────
        var wktByDevice = {}       // String(deviceId) → WKT of existing line
        var nameByDevice = {}      // String(deviceId) → device name (for preservation)
        try {
            lyr.selectAll()
            var existing = lyr.selectedFeatures ? lyr.selectedFeatures() : []
            lyr.removeSelection()
            for (var fi = 0; fi < existing.length; fi++) {
                var f = existing[fi]
                try {
                    var did = String(f.attribute("device_id"))
                    if (did && did !== "null" && did !== "undefined") {
                        var w = ""
                        try { w = f.geometry.asWkt ? f.geometry.asWkt() : "" } catch(ew) {}
                        wktByDevice[did]  = w
                        try { nameByDevice[did] = String(f.attribute("name") || "") } catch(en) {}
                    }
                } catch(er) {}
            }
        } catch(e) {
            mainWindow.displayToast("Line read error: " + e); return
        }

        // ── Phase 2: group new positions by device, sorted by GPS time ────
        var newByDevice = {}    // String(deviceId) → [{x, y, fixTime}, ...]
        for (var pi = 0; pi < allPositions.length; pi++) {
            var pos = allPositions[pi]
            if (pos.latitude === undefined || pos.longitude === undefined) continue
            var key = String(pos.deviceId)

            // Reproject to layer CRS
            var px = pos.longitude, py = pos.latitude
            try {
                if (lyr.crs.authid !== "EPSG:4326") {
                    var wgsCrs = CoordinateReferenceSystemUtils.fromDescription("EPSG:4326")
                    var rpt    = GeometryUtils.reprojectPoint(
                        GeometryUtils.point(px, py), wgsCrs, lyr.crs)
                    px = rpt.x; py = rpt.y
                }
            } catch(ep) {}

            if (!newByDevice[key]) newByDevice[key] = []
            newByDevice[key].push({ x: px, y: py, t: pos.fixTime || "" })
        }
        // Sort each device's points chronologically
        for (var dk in newByDevice) {
            newByDevice[dk].sort(function(a, b) { return a.t < b.t ? -1 : 1 })
        }

        // ── Phase 3: clear layer and rebuild ─────────────────────────────
        try {
            lyr.startEditing()
            lyr.selectAll()
            lyr.deleteSelectedFeatures()

            var processedKeys = {}

            // Devices with new positions — extend existing track or create new
            for (var nk in newByDevice) {
                processedKeys[nk] = true
                var pts   = newByDevice[nk]
                var info  = deviceInfo[parseInt(nk)] || deviceInfo[nk] || {}
                var oldWkt = wktByDevice[nk] || ""

                // Build vertex string from new points
                var newVerts = []
                for (var vi = 0; vi < pts.length; vi++)
                    newVerts.push(pts[vi].x + " " + pts[vi].y)
                var vertStr = newVerts.join(", ")

                var newWkt
                if (oldWkt.indexOf("LineString") >= 0) {
                    // Append vertices to end of existing line
                    newWkt = oldWkt.replace(/\)\s*$/, ", " + vertStr + ")")
                } else if (newVerts.length >= 2) {
                    newWkt = "LineString (" + vertStr + ")"
                } else {
                    // Single point — degenerate 2-pt placeholder
                    newWkt = "LineString (" + vertStr + ", " + vertStr + ")"
                }

                _writeLineFeature(lyr, newWkt, parseInt(nk) || -1,
                                  info.name || nameByDevice[nk] || nk)
            }

            // Devices NOT in this fetch — preserve their existing track unchanged
            for (var ek in wktByDevice) {
                if (processedKeys[ek]) continue
                var ewkt = wktByDevice[ek]
                if (!ewkt || ewkt.indexOf("LineString") < 0) continue
                _writeLineFeature(lyr, ewkt, parseInt(ek) || -1, nameByDevice[ek] || ek)
            }

            lyr.commitChanges()
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Line layer error: " + e)
        }
    }

    // Helper: create and add one LineString feature
    function _writeLineFeature(lyr, wkt, deviceId, name) {
        var geom   = GeometryUtils.createGeometryFromWkt(wkt)
        var nf     = FeatureUtils.createFeature(lyr, geom)
        var fnames = lyr.fields.names
        var incidentRefValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== "")
            ? _evalIncidentRefExpr(cfg.incidentRefExpr) : null
        for (var i = 0; i < fnames.length; i++) {
            switch (fnames[i]) {
                case "device_id": nf.setAttribute(i, deviceId); break
                case "name":      nf.setAttribute(i, name);     break
                default:
                    if (incidentRefValue !== null && fnames[i] === cfg.incidentRefField)
                        nf.setAttribute(i, incidentRefValue)
                    break
            }
        }
        LayerUtils.addFeature(lyr, nf)
    }

    // ── Reproject point to layer CRS and return WKT geometry ─────────────
    function _geomForLayer(lyr, lon, lat) {
        if (lyr.crs.authid === "EPSG:4326") {
            return GeometryUtils.createGeometryFromWkt("POINT(" + lon + " " + lat + ")")
        }
        var wgs = CoordinateReferenceSystemUtils.fromDescription("EPSG:4326")
        var pt  = GeometryUtils.reprojectPoint(GeometryUtils.point(lon, lat), wgs, lyr.crs)
        return GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BASE64  — btoa() is not available in QField's QML JS engine
    // ════════════════════════════════════════════════════════════════════════

    function _btoa(input) {
        var key = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        var out = "", c1, c2, c3, e1, e2, e3, e4, i = 0
        while (i < input.length) {
            c1 = input.charCodeAt(i++)
            c2 = input.charCodeAt(i++)
            c3 = input.charCodeAt(i++)
            e1 =  c1 >> 2
            e2 = ((c1 & 3)  << 4) | (c2 >> 4)
            e3 = ((c2 & 15) << 2) | (c3 >> 6)
            e4 =   c3 & 63
            if (isNaN(c2)) { e3 = e4 = 64 }
            else if (isNaN(c3)) { e4 = 64 }
            out += key.charAt(e1) + key.charAt(e2) + key.charAt(e3) + key.charAt(e4)
        }
        return out
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HTTP HELPER
    // ════════════════════════════════════════════════════════════════════════

    function _get(path, callback) {
        var xhr = new XMLHttpRequest()
        var url = cfg.serverUrl + path
        xhr.open("GET", url, true)
        xhr.setRequestHeader("Authorization", "Basic " + _btoa(cfg.username + ":" + cfg.password))
        xhr.setRequestHeader("Accept",        "application/json")
        xhr.onerror = function() {
            plugin.fetchBusy = false
            mainWindow.displayToast("Network error — check URL and connectivity")
        }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    callback(JSON.parse(xhr.responseText))
                } catch(e) {
                    plugin.fetchBusy = false
                    mainWindow.displayToast("Parse error: " + e)
                }
            } else if (xhr.status === 0) {
                plugin.fetchBusy = false
                mainWindow.displayToast("No response — check server URL")
            } else {
                plugin.fetchBusy = false
                mainWindow.displayToast("HTTP " + xhr.status +
                    (xhr.status === 401 ? " — wrong username/password" : " on " + path))
            }
        }
        xhr.send()
    }
}
