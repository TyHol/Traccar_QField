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
        property bool   fetchHistory:    false   // kept for migration only — no longer used
        property string liveLayerName:   ""     // A — truncated & repopulated each fetch
        property string appendLayerName: ""     // B — positions appended each fetch
        property string lineLayerName:   ""     // C — track line layer
        property string lastFetchIso:    ""     // kept for migration only — no longer used
        // kept for migration only — do not use directly
        property string pointLayerName:  ""
        property bool   appendMode:      false

        property int    fetchMaxPoints:  150  // Fetch Logs: cap on points written per device
        property bool   fetchLimitPts:   true  // Fetch Logs: whether the cap above is enforced

        // ── Layer B housekeeping (culling) ────────────────────────────────
        property bool   cullByCount:     false    // remove oldest points beyond cullMaxPerDevice (per device)
        property int    cullMaxPerDevice: 500     // points retained per device in layer B when cullByCount is on
        property bool   cullByAge:       false    // remove points older than cullAgeMinutes
        property int    cullAgeMinutes:  1440     // age cutoff in minutes (default 1 day) when cullByAge is on

        // ── Session tag ───────────────────────────────────────────────────
        property bool   incidentRefEnabled: false  // write sessionTag into incidentRefField on new features
        property bool   useDisplayAsTag:    false  // when fetching from a feature, use the display field value as the tag
        property string incidentRefField:   ""     // target field name (same on layers A/B/C)
        property string sessionTag:         ""     // plain text written verbatim into the field
        // kept for migration — no longer used as expression
        property string incidentRefExpr:    ""

        // ── Fetch from Feature ────────────────────────────────────────────
        property string eventLayerName:    ""   // layer to pick features from
        property string eventDisplayField: ""   // field shown in the feature combo label
        property string eventStartField:   ""   // datetime field: event start
        property string eventEndField:     ""   // datetime field: event end (optional)
    }

    // Shared timeframe presets — used by the Fetch Logs "Quick range" combo and
    // the "Cull by age" combo (Settings). minutes:0 = "— Select date range —"
    // (Fetch Logs only; treated as "no cutoff" if ever selected for cull-by-age).
    ListModel {
        id: timeframeModel
        ListElement { label: "— Select time period —"; minutes: 0    }
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
    property var    fetchLog:       []   // session history — see _addToFetchLog()
    property string fetchTagOverride: "" // set to feature's display value when fetching from a feature

    // ── Layer list models (for ComboBoxes in Settings) ─────────────────────
    ListModel { id: ptLayerModel }
    ListModel { id: lnLayerModel }
    ListModel { id: fetchDevsModel }    // device list for Fetch Logs dialog
    ListModel { id: fieldNameModel }    // field names of the append (B) layer
    ListModel { id: allLayerModel }     // all vector layers (event layer picker in Settings)
    ListModel { id: eventFieldModel }   // fields of the event layer (shared by 3 combos in Settings)
    ListModel { id: eventFeatureModel } // features of the event layer (Fetch Logs picker)

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

        // Always put "— no layer —" first so the user can de-select a layer
        model.append({ name: "— no layer —", isHeader: false })
        if (normal.length === 0 && priv.length === 0) {
            model.append({ name: "— no suitable layers in project —", isHeader: true })
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

    // ── All vector layers (any geometry, including read-only) ─────────────
    // Used for the event layer picker — we only read from it, not edit.
    function populateAllLayers(model) {
        model.clear()
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names  = []
        for (var id in layers) {
            var lyr = layers[id]
            try {
                // Use .names (JS array) not .count() (not callable in QML)
                if (lyr && lyr.fields && lyr.fields.names && lyr.fields.names.length > 0)
                    names.push(lyr.name)
            } catch(e) {}
        }
        names.sort(function(a, b) { return a.localeCompare(b) })
        model.append({ name: "— none —", isHeader: false })
        if (names.length === 0) return
        for (var i = 0; i < names.length; i++)
            model.append({ name: names[i], isHeader: false })
    }

    // ── All fields of a named layer (no type filter — user picks) ─────────
    function populateEventFields(model, layerName) {
        model.clear()
        model.append({ name: "— none —", isHeader: false })
        if (layerName === "" || layerName === "— none —") return
        var layers = qgisProject.mapLayersByName(layerName)
        if (layers.length === 0) {
            model.append({ name: "— layer not found —", isHeader: true })
            return
        }
        var fnames = layers[0].fields.names
        for (var i = 0; i < fnames.length; i++)
            model.append({ name: fnames[i], isHeader: false })
    }

    // ── Feature list for the Fetch Logs "From feature" picker ─────────────
    // Reads all features from cfg.eventLayerName, labels them using
    // cfg.eventDisplayField + formatted start/end times, sorts newest-first.
    function populateEventFeatures() {
        eventFeatureModel.clear()
        if (cfg.eventLayerName === "") {
            eventFeatureModel.append({ label: "— configure Event Layer in Settings —",
                                       startIso: "", endIso: "", fid: -1 })
            return
        }
        var layers = qgisProject.mapLayersByName(cfg.eventLayerName)
        if (layers.length === 0) {
            eventFeatureModel.append({ label: "— layer '" + cfg.eventLayerName + "' not found —",
                                       startIso: "", endIso: "", fid: -1 })
            return
        }
        var lyr  = layers[0]
        var rows = []
        try {
            var iter = LayerUtils.createFeatureIterator(lyr)
            while (iter.hasNext()) {
                var f = iter.next()
                var disp     = ""
                var startRaw = ""
                var endRaw   = ""
                try { disp     = String(f.attribute(cfg.eventDisplayField) || "") } catch(e) {}
                if (cfg.eventStartField !== "")
                    try { startRaw = String(f.attribute(cfg.eventStartField) || "") } catch(e) {}
                if (cfg.eventEndField !== "")
                    try { endRaw   = String(f.attribute(cfg.eventEndField)   || "") } catch(e) {}

                var label = (disp !== "" ? disp : ("#" + f.id))
                if (startRaw !== "") {
                    var sd = new Date(startRaw)
                    if (!isNaN(sd.getTime())) {
                        label += "  (" + Qt.formatDateTime(sd, "dd MMM HH:mm")
                        if (endRaw !== "") {
                            var ed = new Date(endRaw)
                            label += !isNaN(ed.getTime())
                                     ? " – " + Qt.formatDateTime(ed, "dd MMM HH:mm")
                                     : " – ongoing"
                        } else {
                            label += " – ongoing"
                        }
                        label += ")"
                    }
                }
                rows.push({ label: label, startIso: startRaw, endIso: endRaw, fid: f.id, disp: disp })
            }
            iter.close()
        } catch(e) {
            eventFeatureModel.append({ label: "— error reading features: " + e + " —",
                                       startIso: "", endIso: "", fid: -1 })
            return
        }
        // Newest first: start field descending, then feature id descending
        rows.sort(function(a, b) {
            if (a.startIso !== "" && b.startIso !== "")
                return b.startIso.localeCompare(a.startIso)
            if (a.startIso !== "") return -1
            if (b.startIso !== "") return  1
            return b.fid - a.fid
        })
        if (rows.length === 0) {
            eventFeatureModel.append({ label: "— no features in layer —",
                                       startIso: "", endIso: "", fid: -1 })
            return
        }
        for (var i = 0; i < rows.length; i++)
            eventFeatureModel.append(rows[i])
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
        y:       Math.max(52, (mainWindow.height - height) * 0.08)

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
                    text:    cfg.liveOn ? "⏹  Stop" : "▶  Start"
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
                Button {
                    text:    "Fetch"
                    onClicked: { mainDialog.close(); fetchLogsDialog.open() }
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
        y:       Math.max(52, (mainWindow.height - height) * 0.06)

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

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Buttons"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "▶ Start / ⏹ Stop — live tracking (auto-fetch every N min)\n" +
                          "↻ Now — single fetch immediately\n" +
                          "Fetch — open Fetch Logs to pull historical positions\n" +
                          "🔧 — Settings\n" +
                          "⌖ (device row) — pan map to that device"
                }

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Layers  (configure in 🔧 Settings → Layers)"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "A — Live points: replaced each fetch, one point per device\n" +
                          "B — Accumulated points: positions appended, never deleted\n" +
                          "C — Tracks: one line per device, grows with each fetch\n\n" +
                          "Any layer can be left unset — it will simply be skipped. " +
                          "Fields not in your layer are silently ignored."
                }

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Fetch Logs"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "Time period — preset window (last 15 min → last 3 months)\n" +
                          "Custom dates — enter YYYY-MM-DD or YYYY-MM-DD HH:MM\n" +
                          "From feature — time window taken from a layer feature's date fields\n\n" +
                          "All devices are fetched. Writes to whichever of B / C are set in Settings."
                }

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Session Tag  (Settings → Session Tag)"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "Stamps a text value onto every feature written to B and C. " +
                          "When fetching From feature, the feature's display field value " +
                          "is used automatically if 'Use display field as tag' is enabled."
                }

                Item { height: 2 }
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
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       Math.max(52, mainWindow.height * 0.04)  // clear status bar; near top so Save is reachable

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text:             "🔧  Settings"
                    color:            "white"
                    font.pixelSize:   16
                    font.bold:        true
                    Layout.fillWidth: true
                }
                ToolButton {
                    contentItem: Text {
                        text: "Fetch"
                        color: "white"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked: { settingsDialog.close(); fetchLogsDialog.open() }
                }
            }
        }

        property bool advancedOpen:    false
        property bool localUseDisplay: false   // shared between Feature page and Session Tag page

        footer: Item { height: 0 }

        // Populate controls from current config when dialog opens
        onOpened: {
            urlField.text      = cfg.serverUrl
            userField.text     = cfg.username
            passField.text     = cfg.password
            intervalSpin.value = cfg.intervalMin
            populateLayers(ptLayerModel, Qgis.GeometryType.Point)
            restoreSelection(liveLayerCombo,   ptLayerModel, cfg.liveLayerName)
            if (liveLayerCombo.currentIndex   < 0) liveLayerCombo.currentIndex   = 0
            restoreSelection(appendLayerCombo, ptLayerModel, cfg.appendLayerName)
            if (appendLayerCombo.currentIndex < 0) appendLayerCombo.currentIndex = 0
            populateLayers(lnLayerModel, Qgis.GeometryType.Line)
            restoreSelection(lnLayerCombo, lnLayerModel, cfg.lineLayerName)
            if (lnLayerCombo.currentIndex     < 0) lnLayerCombo.currentIndex     = 0
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
            incidentRefCheck.checked        = cfg.incidentRefEnabled
            settingsDialog.localUseDisplay  = cfg.useDisplayAsTag
            sessionTagField.text            = cfg.sessionTag
            populateFieldNames(fieldNameModel, cfg.appendLayerName)
            restoreSelection(incidentRefFieldCombo, fieldNameModel, cfg.incidentRefField)
            // Event Layer (Fetch from Feature)
            populateAllLayers(allLayerModel)
            restoreSelection(eventLayerCombo, allLayerModel, cfg.eventLayerName)
            if (eventLayerCombo.currentIndex < 0) eventLayerCombo.currentIndex = 0
            var _evItem = allLayerModel.get(eventLayerCombo.currentIndex)
            var _evName = (_evItem && !_evItem.isHeader && _evItem.name !== "— none —")
                          ? _evItem.name : ""
            populateEventFields(eventFieldModel, _evName)
            restoreSelection(eventDisplayFieldCombo, eventFieldModel, cfg.eventDisplayField)
            if (eventDisplayFieldCombo.currentIndex < 0) eventDisplayFieldCombo.currentIndex = 0
            restoreSelection(eventStartFieldCombo,   eventFieldModel, cfg.eventStartField)
            if (eventStartFieldCombo.currentIndex < 0) eventStartFieldCombo.currentIndex = 0
            restoreSelection(eventEndFieldCombo,     eventFieldModel, cfg.eventEndField)
            if (eventEndFieldCombo.currentIndex < 0) eventEndFieldCombo.currentIndex = 0
        }

        function saveSettings() {
            cfg.serverUrl   = urlField.text.trim().replace(/\/+$/, "")
            cfg.username    = userField.text.trim()
            cfg.password    = passField.text
            cfg.intervalMin = intervalSpin.value
            if (liveLayerCombo.currentIndex >= 0 && ptLayerModel.count > 0) {
                var liveItem = ptLayerModel.get(liveLayerCombo.currentIndex)
                cfg.liveLayerName = (liveItem && !liveItem.isHeader
                                     && liveItem.name !== "— no layer —")
                                    ? liveItem.name : ""
            }
            if (appendLayerCombo.currentIndex >= 0 && ptLayerModel.count > 0) {
                var appItem = ptLayerModel.get(appendLayerCombo.currentIndex)
                cfg.appendLayerName = (appItem && !appItem.isHeader
                                       && appItem.name !== "— no layer —")
                                      ? appItem.name : ""
            }
            if (lnLayerCombo.currentIndex >= 0 && lnLayerModel.count > 0) {
                var lnItem = lnLayerModel.get(lnLayerCombo.currentIndex)
                cfg.lineLayerName = (lnItem && !lnItem.isHeader
                                     && lnItem.name !== "— no layer —")
                                    ? lnItem.name : ""
            }
            cfg.cullByCount      = cullCountCheck.checked
            cfg.cullMaxPerDevice = cullMaxSpin.value
            cfg.cullByAge        = cullAgeCheck.checked
            if (cullAgeCombo.currentIndex >= 0)
                cfg.cullAgeMinutes = timeframeModel.get(cullAgeCombo.currentIndex).minutes
            cfg.incidentRefEnabled  = incidentRefCheck.checked
            cfg.useDisplayAsTag     = settingsDialog.localUseDisplay
            if (incidentRefFieldCombo.currentIndex >= 0 && fieldNameModel.count > 0) {
                var refItem = fieldNameModel.get(incidentRefFieldCombo.currentIndex)
                cfg.incidentRefField = (refItem && !refItem.isHeader) ? refItem.name : ""
            } else {
                cfg.incidentRefField = ""
            }
            cfg.sessionTag = sessionTagField.text.trim()
            // Event Layer (Fetch from Feature)
            var _evL = (eventLayerCombo.currentIndex >= 0 && allLayerModel.count > 0)
                       ? allLayerModel.get(eventLayerCombo.currentIndex) : null
            cfg.eventLayerName = (_evL && !_evL.isHeader && _evL.name !== "— none —")
                                 ? _evL.name : ""
            var _evD = (eventDisplayFieldCombo.currentIndex >= 0 && eventFieldModel.count > 0)
                       ? eventFieldModel.get(eventDisplayFieldCombo.currentIndex) : null
            cfg.eventDisplayField = (_evD && !_evD.isHeader && _evD.name !== "— none —")
                                    ? _evD.name : ""
            var _evS = (eventStartFieldCombo.currentIndex >= 0 && eventFieldModel.count > 0)
                       ? eventFieldModel.get(eventStartFieldCombo.currentIndex) : null
            cfg.eventStartField = (_evS && !_evS.isHeader && _evS.name !== "— none —")
                                  ? _evS.name : ""
            var _evE = (eventEndFieldCombo.currentIndex >= 0 && eventFieldModel.count > 0)
                       ? eventFieldModel.get(eventEndFieldCombo.currentIndex) : null
            cfg.eventEndField = (_evE && !_evE.isHeader && _evE.name !== "— none —")
                                ? _evE.name : ""
            if (refreshTimer.running) refreshTimer.restart()
            mainWindow.displayToast("Settings saved")
        }

        // ── Section selector + paged content ──────────────────────────────
        ButtonGroup { id: settingsSectionGroup }

        ScrollView {
            width:        parent.width
            height:       mainWindow.height * 0.78
            contentWidth: parent.width
            clip:         true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 4

                // ── Radio nav (2×2 grid) ───────────────────────────────────
                GridLayout {
                    Layout.fillWidth: true
                    columns:          2
                    columnSpacing:    0
                    rowSpacing:       0

                    RadioButton {
                        id:    s1Radio
                        text:  "Connection"
                        checked: true
                        ButtonGroup.group: settingsSectionGroup
                        Layout.fillWidth: true
                    }
                    RadioButton {
                        id:    s2Radio
                        text:  "Layers"
                        ButtonGroup.group: settingsSectionGroup
                        Layout.fillWidth: true
                    }
                    RadioButton {
                        id:    s3Radio
                        text:  "Feature"
                        ButtonGroup.group: settingsSectionGroup
                        Layout.fillWidth: true
                    }
                    RadioButton {
                        id:    s4Radio
                        text:  "Session Tag"
                        ButtonGroup.group: settingsSectionGroup
                        Layout.fillWidth: true
                    }
                }

                // ══ Page 1 — Connection ════════════════════════════════════
                ColumnLayout {
                    visible:          s1Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

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
                    Label {
                        Layout.fillWidth: true
                        wrapMode:         Text.WordWrap
                        font.pixelSize:   11
                        color:            Theme.secondaryTextColor
                        text: "Each refresh fetches the current position only (1 per device). " +
                              "Use the Fetch button for historical bulk pulls."
                    }
                    Button {
                        text:             "Test Connection"
                        Layout.fillWidth: true
                        onClicked: {
                            cfg.serverUrl = urlField.text.trim().replace(/\/+$/, "")
                            cfg.username  = userField.text.trim()
                            cfg.password  = passField.text
                            testConnection()
                        }
                    }
                }

                // ══ Page 2 — Layers ═══════════════════════════════════════
                ColumnLayout {
                    visible:          s2Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "A — Live points\nCleared and replaced on every fetch. One point per device."
                        wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 12
                    }
                    ComboBox {
                        id: liveLayerCombo; Layout.fillWidth: true
                        model: ptLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: liveLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: liveLayerCombo.highlightedIndex === index
                        }
                    }

                    Item { height: 2 }
                    Label {
                        text: "B — Accumulated points\nPositions appended on every fetch. Builds a full history."
                        wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 12
                    }
                    ComboBox {
                        id: appendLayerCombo; Layout.fillWidth: true
                        model: ptLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: appendLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: appendLayerCombo.highlightedIndex === index
                        }
                        onActivated: {
                            var item = (currentIndex >= 0 && ptLayerModel.count > 0)
                                ? ptLayerModel.get(currentIndex) : null
                            var layerName = (item && !item.isHeader) ? item.name : ""
                            var prevField = cfg.incidentRefField
                            populateFieldNames(fieldNameModel, layerName)
                            restoreSelection(incidentRefFieldCombo, fieldNameModel, prevField)
                        }
                    }

                    Item { height: 2 }
                    RowLayout {
                        CheckBox {
                            id: trackCheck; checked: cfg.appendTrack
                            onCheckedChanged: cfg.appendTrack = checked
                        }
                        Label {
                            text: "C — Tracks  (line layer, one per device)"
                            Layout.fillWidth: true; font.pixelSize: 12
                        }
                    }
                    ComboBox {
                        id: lnLayerCombo; Layout.fillWidth: true
                        enabled: cfg.appendTrack; model: lnLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: lnLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: lnLayerCombo.highlightedIndex === index
                        }
                    }

                    Label {
                        text: "Select '— no layer —' to disable a layer."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }

                    // Advanced — culling
                    Button {
                        Layout.fillWidth: true; flat: true
                        text: (settingsDialog.advancedOpen ? "-" : "+") + "  Advanced — layer B housekeeping"
                        onClicked: settingsDialog.advancedOpen = !settingsDialog.advancedOpen
                    }
                    ColumnLayout {
                        visible: settingsDialog.advancedOpen
                        Layout.fillWidth: true; spacing: 3
                        Label {
                            text: "Automatically trim layer B after each live fetch."
                            font.pixelSize: 11; color: Theme.secondaryTextColor
                            wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }
                        RowLayout {
                            CheckBox { id: cullCountCheck; checked: cfg.cullByCount }
                            Label { text: "Keep at most" }
                            SpinBox {
                                id: cullMaxSpin; from: 1; to: 100000; stepSize: 50
                                editable: true; value: cfg.cullMaxPerDevice
                                enabled: cullCountCheck.checked
                            }
                            Label {
                                text: "pts / device"; Layout.fillWidth: true
                                opacity: cullCountCheck.checked ? 1.0 : 0.6
                            }
                        }
                        RowLayout {
                            CheckBox { id: cullAgeCheck; checked: cfg.cullByAge }
                            Label { text: "Remove points older than:"; Layout.fillWidth: true }
                        }
                        ComboBox {
                            id: cullAgeCombo; Layout.fillWidth: true
                            enabled: cullAgeCheck.checked; opacity: enabled ? 1.0 : 0.6
                            model: timeframeModel; textRole: "label"
                            delegate: ItemDelegate {
                                width: cullAgeCombo.width
                                contentItem: Text {
                                    text: model.label; color: Theme.mainTextColor
                                    font.pixelSize: 13; verticalAlignment: Text.AlignVCenter
                                }
                                highlighted: cullAgeCombo.highlightedIndex === index
                            }
                        }
                        Label {
                            text: "Track layer (C) is never culled."
                            font.pixelSize: 11; color: Theme.secondaryTextColor
                            wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }
                    }
                }

                // ══ Page 3 — From Feature ═════════════════════════════════
                ColumnLayout {
                    visible:          s3Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "Pick a layer and date/time fields so Fetch Logs can derive " +
                              "its time window directly from a selected feature.\n\n" +
                              "When fetching from a feature the display field value " +
                              "(e.g. incident_ref) is automatically used as the session tag " +
                              "for those positions, if session tagging is enabled."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    Label { text: "Layer:" }
                    ComboBox {
                        id: eventLayerCombo; Layout.fillWidth: true
                        model: allLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: eventLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: eventLayerCombo.highlightedIndex === index
                        }
                        onActivated: {
                            var item = (currentIndex >= 0 && allLayerModel.count > 0)
                                       ? allLayerModel.get(currentIndex) : null
                            var lname = (item && !item.isHeader && item.name !== "— none —")
                                        ? item.name : ""
                            var prevD = cfg.eventDisplayField
                            var prevS = cfg.eventStartField
                            var prevE = cfg.eventEndField
                            populateEventFields(eventFieldModel, lname)
                            restoreSelection(eventDisplayFieldCombo, eventFieldModel, prevD)
                            if (eventDisplayFieldCombo.currentIndex < 0) eventDisplayFieldCombo.currentIndex = 0
                            restoreSelection(eventStartFieldCombo, eventFieldModel, prevS)
                            if (eventStartFieldCombo.currentIndex < 0) eventStartFieldCombo.currentIndex = 0
                            restoreSelection(eventEndFieldCombo, eventFieldModel, prevE)
                            if (eventEndFieldCombo.currentIndex < 0) eventEndFieldCombo.currentIndex = 0
                        }
                    }
                    Label { text: "Display field  (shown in the feature picker):" }
                    ComboBox {
                        id: eventDisplayFieldCombo; Layout.fillWidth: true
                        model: eventFieldModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: eventDisplayFieldCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: eventDisplayFieldCombo.highlightedIndex === index
                        }
                    }
                    Label { text: "Start time field:" }
                    ComboBox {
                        id: eventStartFieldCombo; Layout.fillWidth: true
                        model: eventFieldModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: eventStartFieldCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: eventStartFieldCombo.highlightedIndex === index
                        }
                    }
                    Label { text: "End time field  (optional):" }
                    ComboBox {
                        id: eventEndFieldCombo; Layout.fillWidth: true
                        model: eventFieldModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: eventEndFieldCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: eventEndFieldCombo.highlightedIndex === index
                        }
                    }

                    Item { height: 2 }
                    RowLayout {
                        CheckBox {
                            id: useAsTagCheck
                            checked: settingsDialog.localUseDisplay
                            onCheckedChanged: {
                                settingsDialog.localUseDisplay = checked
                                if (checked) incidentRefCheck.checked = true
                            }
                        }
                        Label {
                            text: "Use display field as session tag when fetching from this feature"
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                    Label {
                        visible: useAsTagCheck.checked
                        text: "The display field value (e.g. incident_ref) will be written into the " +
                              "tag field configured on the Session Tag page."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                }

                // ══ Page 4 — Session Tag ══════════════════════════════════
                ColumnLayout {
                    visible:          s4Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "Stamp a text tag on every point and track written to layers A, B and C."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    RowLayout {
                        CheckBox {
                            id: incidentRefCheck
                            checked: cfg.incidentRefEnabled
                        }
                        Label {
                            text: "Enable session tagging"
                            Layout.fillWidth: true
                        }
                    }
                    Label {
                        text: "Tag value  (stamped on every fetched feature):"
                        enabled: incidentRefCheck.checked
                        opacity: enabled ? 1.0 : 0.6
                    }
                    TextField {
                        id:              sessionTagField
                        Layout.fillWidth: true
                        placeholderText: "e.g. FIRE-2026-001"
                        enabled:         incidentRefCheck.checked
                        opacity:         enabled ? 1.0 : 0.6
                    }
                    Label {
                        text: "Write tag into field  (layer B — accumulated points):"
                        enabled: incidentRefCheck.checked
                        opacity: enabled ? 1.0 : 0.6
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    ComboBox {
                        id: incidentRefFieldCombo
                        Layout.fillWidth: true
                        enabled: incidentRefCheck.checked
                        opacity: enabled ? 1.0 : 0.6
                        model: fieldNameModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: incidentRefFieldCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: incidentRefFieldCombo.highlightedIndex === index
                        }
                    }
                    Item { height: 2 }
                    RowLayout {
                        enabled: incidentRefCheck.checked
                        opacity: enabled ? 1.0 : 0.6
                        CheckBox {
                            id: useDisplayFieldCheck
                            checked: settingsDialog.localUseDisplay
                            onCheckedChanged: settingsDialog.localUseDisplay = checked
                        }
                        Label {
                            text: "Use display field as tag when fetching from a feature"
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                    Label {
                        visible: settingsDialog.localUseDisplay && incidentRefCheck.checked
                        text: "When 'From Feature' is used in Fetch Logs, the selected feature's " +
                              "display field value overrides the tag value above."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                }   // end Session Tag ColumnLayout

                Item { height: 4 }
                Button {
                    Layout.fillWidth: true
                    text: "Save"
                    onClicked: settingsDialog.saveSettings()
                }
                Item { height: 8 }

            }   // end outer ColumnLayout
        }   // end ScrollView
    }   // end settingsDialog

    // ════════════════════════════════════════════════════════════════════════
    //  FETCH LOGS DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      fetchLogsDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        width:   Math.min(mainWindow.width * 0.92, 420)
        x:       (mainWindow.width  - width)  / 2
        y:       Math.max(52, (mainWindow.height - height) * 0.08)

        // Runtime state
        property var    fetchDevices:  []
        property bool   fetchLogBusy:  false
        property string fetchStatus:   "Loading devices…"
        property bool   advancedOpen:  false

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text:             "📅  Fetch Logs"
                    color:            "white"
                    font.pixelSize:   16
                    font.bold:        true
                    Layout.fillWidth: true
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
                    onClicked: { fetchLogsDialog.close(); settingsDialog.open() }
                    ToolTip.visible: hovered
                    ToolTip.text:    "Switch to Settings"
                }
            }
        }

        standardButtons: Dialog.Close
        onRejected: mainDialog.open()

        // Radio group: which time-window mode is active
        ButtonGroup { id: rangeMode }
        // Radio group: which direction when deriving window from a feature
        ButtonGroup { id: featureWindowGroup }

        onOpened: {
            var today = Qt.formatDate(new Date(), "yyyy-MM-dd")
            fromDateField.text = today
            toDateField.text   = today
            quickRangeCombo.currentIndex = 0
            populateEventFeatures()
            loadFetchDevices()
        }

        ScrollView {
            width:        parent.width
            height:       Math.min(implicitHeight, mainWindow.height * 0.7)
            contentWidth: parent.width
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 3

                // ── Time window ────────────────────────────────────────────
                Label {
                    text: "── Time Window ──"
                    font.bold: true
                }

                // Mode selector (2-column grid so labels don't truncate)
                GridLayout {
                    Layout.fillWidth: true
                    columns:      2
                    columnSpacing: 0
                    rowSpacing:    0
                    RadioButton {
                        id:    quickRangeRadio
                        text:  "Time period"
                        ButtonGroup.group: rangeMode
                        checked: true
                        Layout.fillWidth: true
                    }
                    RadioButton {
                        id:    customDatesRadio
                        text:  "Custom dates"
                        ButtonGroup.group: rangeMode
                        Layout.fillWidth: true
                    }
                    RadioButton {
                        id:    fromFeatureRadio
                        text:  "From feature"
                        ButtonGroup.group: rangeMode
                        Layout.fillWidth: true
                    }
                    Item { Layout.fillWidth: true }
                }

                // ── Time period ────────────────────────────────────────────
                ComboBox {
                    id:               quickRangeCombo
                    Layout.fillWidth: true
                    visible:          quickRangeRadio.checked
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

                // ── Custom dates ───────────────────────────────────────────
                Label {
                    text:    "From (date + time, local):"
                    visible: customDatesRadio.checked
                    font.pixelSize: 12
                }
                TextField {
                    id:               fromDateField
                    Layout.fillWidth: true
                    visible:          customDatesRadio.checked
                    placeholderText:  "YYYY-MM-DD HH:MM"
                    inputMethodHints: Qt.ImhNone
                }
                Label {
                    text:    "To (date + time, local):"
                    visible: customDatesRadio.checked
                    font.pixelSize: 12
                }
                TextField {
                    id:               toDateField
                    Layout.fillWidth: true
                    visible:          customDatesRadio.checked
                    placeholderText:  "YYYY-MM-DD HH:MM"
                    inputMethodHints: Qt.ImhNone
                }

                // ── From feature ───────────────────────────────────────────
                Label {
                    text:    "Feature:"
                    visible: fromFeatureRadio.checked
                }
                RowLayout {
                    visible:          fromFeatureRadio.checked
                    Layout.fillWidth: true
                    ComboBox {
                        id:               eventFeatureCombo
                        Layout.fillWidth: true
                        model:            eventFeatureModel
                        textRole:         "label"
                        delegate: ItemDelegate {
                            width: eventFeatureCombo.width
                            contentItem: Text {
                                text:              model.label
                                color:             model.fid < 0
                                                   ? Theme.secondaryTextColor
                                                   : Theme.mainTextColor
                                font.pixelSize:    12
                                verticalAlignment: Text.AlignVCenter
                                wrapMode:          Text.WordWrap
                                leftPadding:       4
                            }
                            highlighted: eventFeatureCombo.highlightedIndex === index
                        }
                    }
                    ToolButton {
                        contentItem: Text {
                            text: "🔄"; font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment:   Text.AlignVCenter
                        }
                        background: Item {}
                        onClicked:  populateEventFeatures()
                    }
                }

                Label {
                    text:    "Window:"
                    visible: fromFeatureRadio.checked
                }
                RadioButton {
                    id:    betweenRadio
                    text:  "Between start and end  (end blank → 'now')"
                    ButtonGroup.group: featureWindowGroup
                    checked: true
                    visible: fromFeatureRadio.checked
                    font.pixelSize: 12
                }
                RadioButton {
                    id:    forwardRadio
                    text:  "Forward from start +"
                    ButtonGroup.group: featureWindowGroup
                    visible: fromFeatureRadio.checked
                    font.pixelSize: 12
                }
                RadioButton {
                    id:    backwardRadio
                    text:  "Backward from end −"
                    ButtonGroup.group: featureWindowGroup
                    visible: fromFeatureRadio.checked
                    font.pixelSize: 12
                }
                RowLayout {
                    visible: fromFeatureRadio.checked &&
                             (forwardRadio.checked || backwardRadio.checked)
                    Layout.fillWidth: true
                    Label { text: "Duration:" }
                    SpinBox {
                        id:       featureDurationSpin
                        from:     1
                        to:       14400
                        stepSize: 15
                        value:    120
                        editable: true
                    }
                    Label { text: "min" }
                }
                Label {
                    visible: fromFeatureRadio.checked &&
                             (forwardRadio.checked || backwardRadio.checked)
                    text: "Tip: 60 = 1 hour,  120 = 2 hours,  1440 = 1 day"
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Output layers (read-only info) ─────────────────────────
                Item { height: 2 }
                Label {
                    text: {
                        var parts = []
                        if (cfg.appendLayerName !== "") parts.push("B — " + cfg.appendLayerName)
                        if (cfg.lineLayerName    !== "") parts.push("C — " + cfg.lineLayerName)
                        return parts.length > 0
                            ? "Writes to:  " + parts.join(",  ")
                            : "⚠  No output layers configured — set layers B / C in Settings"
                    }
                    color: (cfg.appendLayerName !== "" || cfg.lineLayerName !== "")
                           ? Theme.secondaryTextColor : "#B71C1C"
                    font.pixelSize:   11
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
                }

                // ── Advanced (point limit) ──────────────────────────────────
                Item { height: 2 }
                Button {
                    Layout.fillWidth: true
                    flat:    true
                    text:    (fetchLogsDialog.advancedOpen ? "-" : "+") + "  Advanced — point limit"
                    onClicked: fetchLogsDialog.advancedOpen = !fetchLogsDialog.advancedOpen
                }

                ColumnLayout {
                    visible:          fetchLogsDialog.advancedOpen
                    Layout.fillWidth: true
                    spacing:          3

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
                        text: "Caps the most-recent N positions per device written to B. Track layer (C) always gets the full set."
                        font.pixelSize:   11
                        color:            Theme.secondaryTextColor
                        wrapMode:         Text.WordWrap
                        Layout.fillWidth: true
                    }
                }

                // ── Status ─────────────────────────────────────────────────
                Item { height: 2 }
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

                // ── Session fetch history ───────────────────────────────────
                Item { height: 3 }
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "── Fetch History ──"; font.bold: true; Layout.fillWidth: true }
                    Button {
                        text: "Clear"; flat: true; font.pixelSize: 11
                        visible: plugin.fetchLog.length > 0
                        onClicked: plugin.fetchLog = []
                    }
                }

                Label {
                    visible:          plugin.fetchLog.length === 0
                    Layout.fillWidth: true
                    text:             "No fetches recorded yet this session."
                    font.pixelSize:   11
                    color:            Theme.secondaryTextColor
                }

                Repeater {
                    model: {
                        var arr = []
                        var log = plugin.fetchLog
                        for (var i = log.length - 1; i >= 0; i--) arr.push(log[i])
                        return arr
                    }
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight:   histCol.implicitHeight + 8
                        color:            index % 2 === 0 ? "#EEF2FF" : "white"

                        Column {
                            id:      histCol
                            anchors { fill: parent; margins: 5 }
                            spacing: 2

                            Label {
                                width:          parent.width
                                wrapMode:       Text.WordWrap
                                font.bold:      true
                                font.pixelSize: 11
                                text: {
                                    var tags = modelData.manual ? "manual" : "auto"
                                    if (modelData.hist) tags += ", history"
                                    return modelData.ts + "  [" + tags + "]"
                                        + "  " + modelData.nDevs + " dev"
                                        + (modelData.nDevs !== 1 ? "s" : "")
                                        + "  " + modelData.nOnline + " online"
                                        + "  " + modelData.nPts + " pts"
                                }
                            }
                            Repeater {
                                model: modelData.devs
                                delegate: Label {
                                    width:          parent.width
                                    wrapMode:       Text.WordWrap
                                    font.pixelSize: 10
                                    color: modelData.status === "online"
                                           ? Theme.mainTextColor : Theme.secondaryTextColor
                                    text: (modelData.status === "online" ? "● " : "○ ")
                                        + modelData.name
                                        + "  pts=" + modelData.pts
                                        + "  " + modelData.loc
                                        + "  " + modelData.fix
                                }
                            }
                        }
                    }
                }

                Item { height: 3 }
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

            // Always fetch current positions only — last known fix per device.
            // Bulk historical pulls are handled by the Fetch dialog, not here.
            _get("/api/positions", function(posData) {
                _finalizeFetch(posData, lookup, new Date().toISOString())
            })
        })
    }

    // ── Session fetch log ─────────────────────────────────────────────────
    // Records one entry per fetch (auto + manual) matching the summary format
    // used by the QGIS desktop plugin's Fetch Log tab.
    // positions  — the raw positions array for the fetch window
    // deviceInfo — {devId: {name, status}} lookup
    // isManual   — true for Fetch Logs dialog, false for timer-based auto fetch
    // isHist     — true when history mode (pulls a time window), false = snapshot
    // fromIso / toIso — the UTC range used (empty string if snapshot)
    function _addToFetchLog(positions, deviceInfo, isManual, isHist, fromIso, toIso) {
        var ptsByDev  = {}
        var lastByDev = {}
        positions.forEach(function(p) {
            var k = String(p.deviceId)
            ptsByDev[k] = (ptsByDev[k] || 0) + 1
            if (!lastByDev[k] || (p.fixTime || "") > (lastByDev[k].fixTime || ""))
                lastByDev[k] = p
        })
        var devRows = []
        var nOnline = 0
        for (var devId in deviceInfo) {
            var info = deviceInfo[devId]
            if ((info.status || "") === "online") nOnline++
            var last = lastByDev[String(devId)]
            devRows.push({
                name:   info.name   || String(devId),
                status: info.status || "unknown",
                pts:    ptsByDev[String(devId)] || 0,
                loc:    last ? (parseFloat(last.latitude).toFixed(5)
                                + ", " + parseFloat(last.longitude).toFixed(5)) : "—",
                fix:    last ? String(last.fixTime || "")
                                .substring(0, 19).replace("T", " ") : "—"
            })
        }
        devRows.sort(function(a, b) { return a.name.localeCompare(b.name) })

        var entry = {
            ts:      Qt.formatTime(new Date(), "HH:mm:ss"),
            manual:  isManual,
            hist:    isHist,
            nDevs:   devRows.length,
            nOnline: nOnline,
            nPts:    positions.length,
            fromIso: fromIso || "",
            toIso:   toIso   || "",
            devs:    devRows
        }
        var log = plugin.fetchLog.slice()
        log.push(entry)
        plugin.fetchLog = log
    }

    // Called when all position data (current or historical) is assembled.
    // liveData (optional) — last-known fix array from /api/positions with NO
    //   date range.  When provided (history mode) it is used for the device panel
    //   and layer A so offline devices that had no fixes in the history window
    //   still appear at their last known location.
    //   In current-positions-only mode liveData is undefined and `positions`
    //   already is the last-known-per-device data, so no extra handling needed.
    function _finalizeFetch(positions, deviceInfo, nowIso) {
        // positions = current fix per device from /api/positions (no date range)
        // Traccar returns exactly one entry per device — the last known fix.
        plugin.positions   = positions
        plugin.fetchBusy   = false
        plugin.lastFetched = Qt.formatTime(new Date(), "hh:mm:ss")
                           + "  -  " + positions.length + " device(s)"

        // A: replace with latest fix per device
        if (cfg.liveLayerName   !== "") _updateLiveLayer(positions, deviceInfo)
        // B: append latest fix per device
        if (cfg.appendLayerName !== "") {
            _updateAppendLayer(positions, deviceInfo)
            if (cfg.cullByCount || cfg.cullByAge) _cullAppendLayer()
        }
        // C: extend track with latest fix
        if (cfg.appendTrack && cfg.lineLayerName !== "") _updateLineLayer(positions, deviceInfo)

        // Record in session log
        _addToFetchLog(positions, deviceInfo, false, false, "", nowIso)
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

    // ── Parse "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" text into a local Date ─────
    // Date-only input → midnight local on that date.
    // Date+time input → that exact local minute.
    function _parseDate(str) {
        var s = str.trim()
        // Split off optional time part
        var tIdx = s.indexOf(" ")
        var timePart = (tIdx >= 0) ? s.substring(tIdx + 1).trim() : ""
        var datePart = (tIdx >= 0) ? s.substring(0, tIdx).trim()  : s

        var p = datePart.split("-")
        if (p.length !== 3) return null
        var y = parseInt(p[0]), m = parseInt(p[1]) - 1, d = parseInt(p[2])
        if (isNaN(y) || isNaN(m) || isNaN(d)) return null
        if (y < 2000 || y > 2099 || m < 0 || m > 11 || d < 1 || d > 31) return null

        var hr = 0, mn = 0
        if (timePart !== "") {
            var tp = timePart.split(":")
            hr = parseInt(tp[0]) || 0
            mn = parseInt(tp[1]) || 0
            if (isNaN(hr) || isNaN(mn) || hr < 0 || hr > 23 || mn < 0 || mn > 59)
                return null
        }
        return new Date(y, m, d, hr, mn, 0, 0)
    }

    // ── Fetch historical positions for a custom time period ────────────────
    function fetchLogs() {
        if (fetchLogsDialog.fetchLogBusy) return

        var fromIso, toIso

        if (quickRangeRadio.checked) {
            // ── Time period ───────────────────────────────────────────────
            var qrIdx     = quickRangeCombo.currentIndex
            var qrMinutes = (qrIdx > 0) ? timeframeModel.get(qrIdx).minutes : 0
            if (qrMinutes <= 0) {
                fetchLogsDialog.fetchStatus = "Select a time period or switch to Custom dates"
                return
            }
            var now = new Date()
            fromIso = new Date(now.getTime() - qrMinutes * 60000).toISOString()
            toIso   = now.toISOString()

        } else if (customDatesRadio.checked) {
            // ── Custom date range ─────────────────────────────────────────
            var fromDate = _parseDate(fromDateField.text)
            var toDate   = _parseDate(toDateField.text)
            if (!fromDate || !toDate) {
                fetchLogsDialog.fetchStatus = "Enter date/time as YYYY-MM-DD HH:MM (time optional)"
                return
            }
            // If the user entered a date-only "To" (no space → no time), extend to
            // 23:59:59 so the whole day is included.  If a time was provided, use it exactly.
            var toHasTime = toDateField.text.trim().indexOf(" ") >= 0
            var toDateEnd = toHasTime ? toDate
                          : new Date(toDate.getFullYear(), toDate.getMonth(),
                                     toDate.getDate(), 23, 59, 59, 0)
            if (fromDate > toDateEnd) {
                fetchLogsDialog.fetchStatus = "'From' must not be after 'To'"
                return
            }
            fromIso = fromDate.toISOString()
            toIso   = toDateEnd.toISOString()

        } else {
            // ── From feature ──────────────────────────────────────────────
            var fi = eventFeatureCombo.currentIndex
            if (fi < 0 || eventFeatureModel.count === 0) {
                fetchLogsDialog.fetchStatus = "Select a feature"
                return
            }
            var feat = eventFeatureModel.get(fi)
            if (feat.fid < 0) {
                fetchLogsDialog.fetchStatus = "Configure Event Layer in Settings first"
                return
            }
            if (betweenRadio.checked) {
                if (feat.startIso === "") {
                    fetchLogsDialog.fetchStatus = "Selected feature has no start time value"
                    return
                }
                fromIso = new Date(feat.startIso).toISOString()
                toIso   = feat.endIso !== ""
                          ? new Date(feat.endIso).toISOString()
                          : new Date().toISOString()
            } else if (forwardRadio.checked) {
                if (feat.startIso === "") {
                    fetchLogsDialog.fetchStatus = "Selected feature has no start time value"
                    return
                }
                var sd  = new Date(feat.startIso)
                fromIso = sd.toISOString()
                toIso   = new Date(sd.getTime() + featureDurationSpin.value * 60000).toISOString()
            } else {
                // backwardRadio
                if (feat.endIso === "") {
                    fetchLogsDialog.fetchStatus = "Selected feature has no end time value"
                    return
                }
                var ed  = new Date(feat.endIso)
                toIso   = ed.toISOString()
                fromIso = new Date(ed.getTime() - featureDurationSpin.value * 60000).toISOString()
            }
        }

        if (cfg.appendLayerName === "" && cfg.lineLayerName === "") {
            fetchLogsDialog.fetchStatus = "No output layers configured — set layers B / C in Settings"
            return
        }

        // Build device ID list and lookup — always all devices
        var devs      = fetchLogsDialog.fetchDevices
        var devIds    = []
        var devLookup = {}
        for (var i = 0; i < devs.length; i++) {
            devIds.push(devs[i].id)
            devLookup[devs[i].id] = {
                name:   devs[i].name   || String(devs[i].id),
                status: devs[i].status || ""
            }
        }

        if (devIds.length === 0) {
            fetchLogsDialog.fetchStatus = "No devices to fetch"
            return
        }

        fetchLogsDialog.fetchLogBusy = true
        fetchLogsDialog.fetchStatus  = "Fetching " + devIds.length + " device(s)…"

        // Capture display value for auto-tagging when fetching from a feature
        var featureDisplayValue = ""
        if (fromFeatureRadio.checked) {
            var _fi2 = eventFeatureCombo.currentIndex
            if (_fi2 >= 0 && eventFeatureModel.count > 0) {
                var _feat2 = eventFeatureModel.get(_fi2)
                if (_feat2 && _feat2.fid >= 0)
                    featureDisplayValue = _feat2.disp || ""
            }
        }

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
                        // Record in session log (even zero results, so user can see the attempt)
                        _addToFetchLog(allPos, devLookup, true, false, fromIso, toIso)
                        if (allPos.length === 0) {
                            fetchLogsDialog.fetchStatus =
                                "No positions found in this time range"
                            return
                        }

                        // Auto-tag: override session tag with the feature's display value
                        // (only when the user has enabled "Use display field as session tag")
                        if (cfg.useDisplayAsTag && featureDisplayValue !== "")
                            plugin.fetchTagOverride = featureDisplayValue

                        var written = []
                        if (cfg.appendLayerName !== "") {
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
                        if (cfg.lineLayerName !== "") {
                            _updateLineLayer(allPos, devLookup)
                            var nDevs = {}
                            for (var j = 0; j < allPos.length; j++)
                                nDevs[allPos[j].deviceId] = true
                            written.push(Object.keys(nDevs).length + " track(s) updated")
                        }

                        // Clear the override so normal fetches use cfg.sessionTag
                        plugin.fetchTagOverride = ""

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


    function _writePointsToLayer(lyr, positions, deviceInfo) {
        var _tagText = plugin.fetchTagOverride !== "" ? plugin.fetchTagOverride : cfg.sessionTag
        var incidentRefValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== ""
                                && _tagText !== "")
                               ? _tagText : null

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
    // ════════════════════════════════════════════════════════════════════════
    //  CLOUD SYNC GUARD
    //  QField exposes cloudConnection and cloudProjectsModel via objectName.
    //  We check cloudConnection.status before any layer write so we never
    //  call startEditing()/commitChanges() while a cloud sync is in progress.
    //  Returns true = sync in progress → caller should skip the write.
    //  Fails silently (returns false) if this is not a cloud project or the
    //  API is unavailable, so non-cloud use is unaffected.
    // ════════════════════════════════════════════════════════════════════════

    function _isSyncing() {
        try {
            // objectName "cloudConnection" confirmed in QField src/qml/qgismobileapp.qml
            var cc = mainWindow.findChild("cloudConnection")
            if (cc === null || cc === undefined) return false
            // QFieldCloudConnection::ConnectionState — src/core/qfieldcloud/qfieldcloudconnection.h
            //   Idle = 0, Busy = 1
            // state goes Busy during any cloud network operation (sync, upload, login).
            // ConnectionStatus (Disconnected/Connecting/LoggedIn) is a separate property
            // and has no Synchronizing value — state is the correct check.
            return cc.state === 1   // ConnectionState::Busy
        } catch(e) { /* not a cloud project or findChild not available in this build */ }
        return false
    }

    // ════════════════════════════════════════════════════════════════════════
    //  A: LIVE LAYER  — truncated and repopulated with latest fix per device
    // ════════════════════════════════════════════════════════════════════════

    function _updateLiveLayer(positions, deviceInfo) {
        if (cfg.liveLayerName === "") return
        if (_isSyncing()) { mainWindow.displayToast("Live layer skipped — cloud sync in progress"); return }
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
        if (_isSyncing()) { mainWindow.displayToast("Accumulated layer skipped — cloud sync in progress"); return }
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
        if (_isSyncing()) return   // silently skip cull — next fetch will retry
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
    //  device — all are appended in time order.
    // ════════════════════════════════════════════════════════════════════════

    function _updateLineLayer(allPositions, deviceInfo) {
        if (cfg.lineLayerName === "") return
        if (_isSyncing()) { mainWindow.displayToast("Track layer skipped — cloud sync in progress"); return }
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
        // Each point stores x/y (layer CRS), z (altitude m), m (epoch seconds),
        // and t (ISO fixTime string for field writes and sorting).
        var newByDevice = {}    // String(deviceId) → [{x, y, z, m, t}, ...]
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

            var pz = pos.altitude || 0
            var pm = pos.fixTime ? Math.round(new Date(pos.fixTime).getTime() / 1000) : 0
            if (!newByDevice[key]) newByDevice[key] = []
            newByDevice[key].push({ x: px, y: py, z: pz, m: pm, t: pos.fixTime || "" })
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

                // Parse existing WKT coords (handles 2D / Z / M / ZM gracefully)
                var oldCoords = _extractZMCoords(oldWkt)
                var allVerts  = []
                for (var oi = 0; oi < oldCoords.length; oi++) {
                    var oc = oldCoords[oi]
                    allVerts.push(oc.x + " " + oc.y + " " + oc.z + " " + oc.m)
                }
                for (var vi = 0; vi < pts.length; vi++) {
                    var pt = pts[vi]
                    allVerts.push(pt.x + " " + pt.y + " " + pt.z + " " + pt.m)
                }

                var newWkt
                if (allVerts.length >= 2) {
                    newWkt = "LineStringZM (" + allVerts.join(", ") + ")"
                } else if (allVerts.length === 1) {
                    newWkt = "LineStringZM (" + allVerts[0] + ", " + allVerts[0] + ")"
                } else {
                    continue   // nothing to write for this device
                }

                // pts is already sorted chronologically (Phase 2 sort above)
                _writeLineFeature(lyr, newWkt, parseInt(nk) || -1,
                                  info.name || nameByDevice[nk] || nk,
                                  pts)
            }

            // Devices NOT in this fetch — preserve their existing track unchanged
            // (no new positions so we pass null for timestamps — preserves existing)
            for (var ek in wktByDevice) {
                if (processedKeys[ek]) continue
                var ewkt = wktByDevice[ek]
                if (!ewkt || ewkt.indexOf("LineString") < 0) continue
                _writeLineFeature(lyr, ewkt, parseInt(ek) || -1, nameByDevice[ek] || ek, null)
            }

            lyr.commitChanges()
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Line layer error: " + e)
        }
    }

    // Helper: extract coordinates from any LineString WKT (2D, Z, M, or ZM).
    // Returns [{x, y, z, m}, ...] — missing z/m default to 0.
    // Used so old 2D tracks migrate cleanly into LineStringZM on next write.
    function _extractZMCoords(wkt) {
        if (!wkt || wkt.indexOf("LineString") < 0) return []
        var rx = wkt.match(/\(([^)]+)\)/)
        if (!rx) return []
        var parts = rx[1].trim().split(/\s*,\s*/)
        var coords = []
        for (var i = 0; i < parts.length; i++) {
            var nums = parts[i].trim().split(/\s+/)
            if (nums.length >= 2)
                coords.push({
                    x: parseFloat(nums[0]) || 0,
                    y: parseFloat(nums[1]) || 0,
                    z: nums.length >= 3 ? (parseFloat(nums[2]) || 0) : 0,
                    m: nums.length >= 4 ? (parseFloat(nums[3]) || 0) : 0
                })
        }
        return coords
    }

    // Helper: create and add one LineString feature.
    // Writes device_id, name, start_time, last_update (when those fields exist),
    // and the optional incident_ref field — matching the QGIS plugin schema.
    // positions — chronologically sorted array for this device (used for timestamps)
    function _writeLineFeature(lyr, wkt, deviceId, name, positions) {
        var geom   = GeometryUtils.createGeometryFromWkt(wkt)
        var nf     = FeatureUtils.createFeature(lyr, geom)
        var fnames = lyr.fields.names
        var _tagText = plugin.fetchTagOverride !== "" ? plugin.fetchTagOverride : cfg.sessionTag
        var incidentRefValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== ""
                                && _tagText !== "")
                               ? _tagText : null

        // Derive start_time / last_update from the positions array when available
        var startTime  = ""
        var lastUpdate = ""
        if (positions && positions.length > 0) {
            startTime  = String(positions[0].fixTime              || "").substring(0, 19).replace("T", " ")
            lastUpdate = String(positions[positions.length - 1].fixTime || "").substring(0, 19).replace("T", " ")
        }

        for (var i = 0; i < fnames.length; i++) {
            switch (fnames[i]) {
                case "device_id":   nf.setAttribute(i, deviceId);  break
                case "name":        nf.setAttribute(i, name);       break
                case "start_time":  if (startTime  !== "") nf.setAttribute(i, startTime);  break
                case "last_update": if (lastUpdate !== "") nf.setAttribute(i, lastUpdate); break
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
