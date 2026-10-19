/**
 * Traccar Live – QField Plugin  v0.7
 *
 * One time window drives everything: the tracks drawn on the map are the fixes
 * inside the window, and "Save tracks" / "Save positions" write exactly what is
 * shown. Live keeps a "Last …" window moving forward.
 *
 * Main dialog — time window, Live, what to show, devices, save buttons.
 * Settings    — a list of four short pages (Connection, Layers, Tag, Advanced);
 *               every change applies immediately.
 *
 * All layer writes go through _queueWrite(), which waits while QFieldCloud is busy.
 *
 * Copyright (C) 2026 TyHol
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import org.qfield
import org.qgis
import QtCore
import Theme

Item {
    id: plugin

    property var mainWindow:   iface.mainWindow()
    property var mapCanvas:    iface.mapCanvas()
    property var pointHandler: iface.findItemByObjectName("pointHandler")
    property var wgs84:        CoordinateReferenceSystemUtils.fromDescription("EPSG:4326")
    property var irishGridCrs: CoordinateReferenceSystemUtils.fromDescription("EPSG:29903")
    property var ukGridCrs:    CoordinateReferenceSystemUtils.fromDescription("EPSG:27700")

    // Dialog geometry: full screen on phones, floating panel on wider screens
    property bool phone:       mainWindow.width < 520
    property real topInset:    mainWindow.sceneTopMargin    || 0
    property real bottomInset: mainWindow.sceneBottomMargin || 0

    // ── Persistent settings ───────────────────────────────────────────────
    Settings {
        id: cfg
        category: "TraccarLive"
        property string serverUrl:      "https://server.traccar.org"
        property string username:       ""
        property string password:       ""

        // Time window: minutes > 0 = "Last N minutes", -1 = custom dates, -2 = from feature
        property int    windowMinutes:   60
        property string customFrom:      ""     // "YYYY-MM-DD HH:MM" local
        property string customTo:        ""
        property int    eventFeatureFid: -1     // selected feature for "From feature"
        property int    featureSpan:     0      // 0 = start→end, 1 = start + duration, 2 = end − duration
        property int    featureDuration: 120    // minutes

        // Live + overlay
        property bool   liveOn:          false
        property int    liveIntervalSec: 10
        property int    staleMinutes:    10     // marker turns grey when last fix is older
        property bool   showMarkers:     true
        property bool   showLabels:      true
        property bool   showAccuracy:    false
        property bool   showTrails:      true   // "Tracks" toggle
        property bool   showButton:      true   // toolbar button on the map canvas
        property string hiddenDevices:   ""     // comma-separated Traccar ids unticked in the device list
        property int    locationFormat:  0      // 0 = lat / long, 1 = Irish Grid, 2 = UK Grid, 3 = deg + min, 4 = project CRS

        // Geofences and points sent to Traccar
        property bool   showGeofences:   true
        property string hiddenGeofences: ""     // comma-separated Traccar geofence ids unticked in the list
        property string geofenceColor:   "#E65100"
        property int    circleRadius:    500    // metres, for circles and points sent as geofences
        property string sendUrl:         ""     // OsmAnd endpoint for points; blank = http://<server host>:5055
        property string lastSendName:    ""     // name offered first when sending a point
        property string deviceDetailsHidden:   ""   // detail lines left out of the device list ("speed,battery")
        property string geofenceDetailsHidden: ""   // … and of the geofence list

        // Layers (written only on Save)
        property string pointsLayerName: ""
        property string pointsNameField: ""     // extra text field to receive the device name
        property int    pointsMode:      0      // 0 = latest fix per device, 1 = every fix in window
        property string tracksLayerName: ""
        property string tracksNameField: ""
        property int    trackMode:       0      // 0 = add a new track per save, 1 = keep most recent only

        // Session tag
        property bool   incidentRefEnabled: false
        property bool   useDisplayAsTag:    false  // "From feature" → use the feature's display value as tag
        property string incidentRefField:   ""
        property string sessionTag:         ""

        // Event layer (time window "From feature")
        property string eventLayerName:    ""
        property string eventDisplayField: ""
        property string eventStartField:   ""
        property string eventEndField:     ""

        // Kept for migration only — no longer used
        property bool   v3Migrated:      false
        property bool   v4Migrated:      false
        property int    trailMinutes:    30
        property int    pointsPerDevice: 1
        property string liveLayerName:   ""
        property string appendLayerName: ""
        property string lineLayerName:   ""
        property string pointLayerName:  ""
    }

    // Time window choices. minutes -1 / -2 open inline controls in the main dialog.
    ListModel {
        id: windowModel
        ListElement { label: "Last 15 minutes"; minutes: 15     }
        ListElement { label: "Last 30 minutes"; minutes: 30     }
        ListElement { label: "Last 1 hour";     minutes: 60     }
        ListElement { label: "Last 2 hours";    minutes: 120    }
        ListElement { label: "Last 3 hours";    minutes: 180    }
        ListElement { label: "Last 6 hours";    minutes: 360    }
        ListElement { label: "Last 12 hours";   minutes: 720    }
        ListElement { label: "Last 1 day";      minutes: 1440   }
        ListElement { label: "Last 3 days";     minutes: 4320   }
        ListElement { label: "Last 1 week";     minutes: 10080  }
        ListElement { label: "Last 2 weeks";    minutes: 20160  }
        ListElement { label: "Last 1 month";    minutes: 43200  }
        ListElement { label: "Last 3 months";   minutes: 129600 }
        ListElement { label: "Custom dates…";   minutes: -1     }
        ListElement { label: "From feature…";   minutes: -2     }
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property var    deviceInfo:   ({})    // devId → {name, status}
    property var    win:          null    // window currently loaded — see _computeWindow()
    property var    tracks:       ({})    // devId → [positions in window], oldest first
    property var    latest:       ({})    // devId → latest position (current fix)
    property var    markerPos:    ({})    // devId → position drawn as the marker
    property var    deviceRows:   []      // device list in the main dialog
    property var    overlayModel: []      // markers
    property var    trackModel:   []      // track lines (decimated for drawing)
    property bool   loading:      false
    property double loadStarted:  0
    property int    loadGen:      0       // bumped by every load; late replies from older loads are ignored
    property string lastFetched:  ""
    property string liveError:    ""
    property string statusMsg:    ""      // window / loading hint under the time window
    property string connState:    ""      // "" unknown, "ok", or an error message
    property int    mapTick:      0       // bumped on pan / zoom / rotate → re-place overlay items
    property int    crsTick:      0       // bumped when the map CRS changes → re-project
    property var    geofences:    []      // Traccar geofences: {id, name, area, mine, raw, color, kind, coords, radius}
    property string drawMode:     ""      // "" or what a map tap adds: "point", "circle", "area", "line"
    property var    drawPts:      []      // corners tapped so far, {lon, lat}
    property var    groups:       []      // Traccar groups and calendars, for the send form
    property var    calendars:    []

    // Pending layer writes (held back while QFieldCloud is busy)
    property var    writeQueue:     []
    property double writeWaitStart: 0

    // ── Models for pickers ────────────────────────────────────────────────
    ListModel { id: ptLayerModel }
    ListModel { id: lnLayerModel }
    ListModel { id: ptNameFieldModel }  // text fields of the points layer
    ListModel { id: lnNameFieldModel }  // text fields of the tracks layer
    ListModel { id: fieldNameModel }    // fields of both layers (tag field picker)
    ListModel { id: allLayerModel }     // all vector layers (event layer picker)
    ListModel { id: eventFieldModel }   // fields of the event layer
    ListModel { id: eventFeatureModel } // features of the event layer

    // ── Reusable picker: models with roles name + isHeader ────────────────
    component PickCombo: ComboBox {
        id: pick
        Layout.fillWidth: true
        textRole: "name"
        delegate: ItemDelegate {
            width: pick.width
            enabled: !model.isHeader
            highlighted: pick.highlightedIndex === index
            contentItem: Text {
                text: model.name
                verticalAlignment: Text.AlignVCenter
                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                font.pixelSize: model.isHeader ? 11 : 14
                leftPadding: model.isHeader ? 4 : 8
                elide: Text.ElideRight
            }
        }
    }

    // ── Small grey hint text ──────────────────────────────────────────────
    component Hint: Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font.pixelSize: 12
        color: Theme.secondaryTextColor
    }

    // ── Dialog frame: rounded corners, green header with rounded top ──────
    readonly property real cornerRadius: 12

    component DialogBackground: Rectangle {
        color:  Theme.mainBackgroundColor
        radius: plugin.cornerRadius
    }

    component HeaderBar: ToolBar {
        background: Rectangle {
            color:  Theme.mainColor
            radius: plugin.cornerRadius
            // square off the bottom corners
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.radius
                color:  parent.color
            }
        }
    }

    // ── Compact checkbox for the "what to show" row ───────────────────────
    component ShowBox: CheckBox {
        topPadding:      2
        bottomPadding:   2
        topInset:        0
        bottomInset:     0
        spacing:         4
        font.pixelSize:  13
        indicator.scale: 0.8
    }

    // ── Small icon button in the device list ──────────────────────────────
    component RowButton: ToolButton {
        implicitWidth:  34
        implicitHeight: 34
        padding:        6
        icon.width:     18
        icon.height:    18
        background:     Item {}
    }

    // ── White icon button on the blue dialog headers ──────────────────────
    component HeaderButton: ToolButton {
        icon.color:  "white"
        icon.width:  22
        icon.height: 22
        background:  Item {}
    }

    // ── Row on the Settings list page ─────────────────────────────────────
    component SettingsRow: ItemDelegate {
        property string title
        property string summary
        property bool   warn: false
        Layout.fillWidth: true
        contentItem: RowLayout {
            spacing: 8
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Label { text: title; font.bold: true; font.pixelSize: 15 }
                Label {
                    Layout.fillWidth: true
                    text: summary
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: warn ? "#B71C1C" : Theme.secondaryTextColor
                }
            }
            Label { text: "›"; font.pixelSize: 24; color: Theme.secondaryTextColor }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PICKER HELPERS
    // ════════════════════════════════════════════════════════════════════════

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

    // Selected name from a picker; "" for the first ("none") entry or a header
    function pickedName(combo, model) {
        if (combo.currentIndex <= 0 || model.count === 0) return ""
        var item = model.get(combo.currentIndex)
        return (item && !item.isHeader) ? item.name : ""
    }

    // ── Text fields of a layer ────────────────────────────────────────────
    // QML only sees field *names* on a layer (QgsFields exposes no types), so the
    // types are read through QField's FeatureModel, whose Field role returns the
    // QgsField (role = Qt.UserRole + 3 in QField 3.3 → 4.3), and LayerUtils.fieldType().
    // Created at runtime so a QField version without it cannot stop the plugin
    // loading. Returns {names, filtered}; filtered = false → types unknown, all fields.
    function _textFieldNames(layerName) {
        var layers = layerName !== "" ? qgisProject.mapLayersByName(layerName) : []
        if (layers.length === 0) return { names: [], filtered: true }
        var lyr   = layers[0]
        var names = lyr.fields.names
        var fm    = null
        try {
            fm = Qt.createQmlObject("import org.qfield\nFeatureModel {}", plugin, "fieldTypeProbe")
            fm.currentLayer = lyr
            var out = []
            for (var i = 0; i < names.length; i++) {
                var fld = fm.data(fm.index(i, 0), 0x0100 + 3)   // FeatureModel::Field
                if (LayerUtils.fieldType(fld) === "QString") out.push(names[i])
            }
            fm.destroy()
            return { names: out, filtered: true }
        } catch(e) {
            try { if (fm) fm.destroy() } catch(e2) {}
        }
        return { names: names, filtered: false }
    }

    // ── Device-name field picker model for one layer ──────────────────────
    function populateNameFields(model, layerName) {
        model.clear()
        model.append({ name: "— only a field called 'name' —", isHeader: false })
        if (layerName === "") return
        var r = _textFieldNames(layerName)
        if (!r.filtered)
            model.append({ name: "— field types unknown: all fields shown —", isHeader: true })
        else if (r.names.length === 0)
            model.append({ name: "— no text fields in this layer —", isHeader: true })
        for (var i = 0; i < r.names.length; i++)
            model.append({ name: r.names[i], isHeader: false })
    }

    // ── Field names of the points + tracks layers (tag field picker) ──────
    function populateFieldNames(model, layerNames) {
        model.clear()
        model.append({ name: "— choose a field —", isHeader: false })
        var seen  = {}
        var names = []
        layerNames.forEach(function(ln) {
            if (ln === "") return
            var layers = qgisProject.mapLayersByName(ln)
            if (layers.length === 0) return
            var fnames = layers[0].fields.names
            for (var i = 0; i < fnames.length; i++) {
                if (!seen[fnames[i]]) { seen[fnames[i]] = true; names.push(fnames[i]) }
            }
        })
        if (names.length === 0) {
            model.append({ name: "— pick points / tracks layers first —", isHeader: true })
            return
        }
        for (var j = 0; j < names.length; j++)
            model.append({ name: names[j], isHeader: false })
    }

    // ── All vector layers (any geometry, including read-only) ─────────────
    function populateAllLayers(model) {
        model.clear()
        model.append({ name: "— none —", isHeader: false })
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
        for (var i = 0; i < names.length; i++)
            model.append({ name: names[i], isHeader: false })
    }

    // ── All fields of a named layer ───────────────────────────────────────
    function populateEventFields(model, layerName) {
        model.clear()
        model.append({ name: "— none —", isHeader: false })
        if (layerName === "") return
        var layers = qgisProject.mapLayersByName(layerName)
        if (layers.length === 0) {
            model.append({ name: "— layer not found —", isHeader: true })
            return
        }
        var fnames = layers[0].fields.names
        for (var i = 0; i < fnames.length; i++)
            model.append({ name: fnames[i], isHeader: false })
    }

    // ── Features of the event layer for "From feature" ────────────────────
    // Labels use the display field + local start/end, sorted newest first.
    function populateEventFeatures() {
        eventFeatureModel.clear()
        if (cfg.eventLayerName === "") {
            eventFeatureModel.append({ label: "— set up in Settings → Advanced —",
                                       startIso: "", endIso: "", fid: -1, disp: "" })
            return
        }
        var layers = qgisProject.mapLayersByName(cfg.eventLayerName)
        if (layers.length === 0) {
            eventFeatureModel.append({ label: "— layer '" + cfg.eventLayerName + "' not found —",
                                       startIso: "", endIso: "", fid: -1, disp: "" })
            return
        }
        var rows = []
        try {
            var iter = LayerUtils.createFeatureIterator(layers[0])
            while (iter.hasNext()) {
                var f = iter.next()
                var disp     = ""
                var startIso = ""   // normalised to UTC ISO so it sorts and parses reliably
                var endIso   = ""
                try { disp     = String(f.attribute(cfg.eventDisplayField) || "") } catch(e) {}
                if (cfg.eventStartField !== "")
                    try { startIso = _attrToIsoUtc(f.attribute(cfg.eventStartField)) } catch(e) {}
                if (cfg.eventEndField !== "")
                    try { endIso   = _attrToIsoUtc(f.attribute(cfg.eventEndField)) } catch(e) {}
                var label = (disp !== "" ? disp : ("#" + f.id))
                if (startIso !== "")
                    label += "  (" + _fmtLocal(startIso)
                           + (endIso !== "" ? " – " + _fmtLocal(endIso) : " – ongoing") + ")"
                rows.push({ label: label, startIso: startIso, endIso: endIso, fid: f.id, disp: disp })
            }
            iter.close()
        } catch(e) {
            eventFeatureModel.append({ label: "— error reading features: " + e + " —",
                                       startIso: "", endIso: "", fid: -1, disp: "" })
            return
        }
        rows.sort(function(a, b) {
            if (a.startIso !== "" && b.startIso !== "") return b.startIso.localeCompare(a.startIso)
            if (a.startIso !== "") return -1
            if (b.startIso !== "") return  1
            return b.fid - a.fid
        })
        if (rows.length === 0) {
            eventFeatureModel.append({ label: "— no features in layer —",
                                       startIso: "", endIso: "", fid: -1, disp: "" })
            return
        }
        for (var i = 0; i < rows.length; i++) eventFeatureModel.append(rows[i])
    }

    function _selectedEventFeature() {
        for (var i = 0; i < eventFeatureModel.count; i++) {
            var f = eventFeatureModel.get(i)
            if (f.fid >= 0 && f.fid === cfg.eventFeatureFid) return f
        }
        return null
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STARTUP
    // ════════════════════════════════════════════════════════════════════════
    Component.onCompleted: {
        iface.addItemToPluginsToolbar(pluginButton)

        // Migrate v0.2 layers A/B/C → points / tracks layers (once)
        if (!cfg.v3Migrated) {
            if (cfg.pointsLayerName === "")
                cfg.pointsLayerName = cfg.appendLayerName !== "" ? cfg.appendLayerName
                                    : cfg.liveLayerName   !== "" ? cfg.liveLayerName
                                    : cfg.pointLayerName
            if (cfg.tracksLayerName === "")
                cfg.tracksLayerName = cfg.lineLayerName
            cfg.v3Migrated = true
        }
        // Migrate v0.3 trail length / points-per-device (once)
        if (!cfg.v4Migrated) {
            if (cfg.trailMinutes > 0) cfg.windowMinutes = cfg.trailMinutes
            cfg.pointsMode = cfg.pointsPerDevice > 1 ? 1 : 0
            cfg.v4Migrated = true
        }

        // Tap a marker → device info toast
        try {
            if (pointHandler) {
                pointHandler.registerHandler("traccarlive", function(point, type, interactionType) {
                    if (interactionType !== "clicked") return false
                    return _onMapTap(point)
                })
            }
        } catch(e) { /* older QField without pointHandler.registerHandler */ }

        if (cfg.liveOn) Qt.callLater(loadWindow)
    }

    Component.onDestruction: {
        try { if (pointHandler) pointHandler.deregisterHandler("traccarlive") } catch(e) {}
    }

    QfToolButton {
        id:         pluginButton
        bgcolor:    Theme.mainColor
        round:      true
        iconSource: "traccar_icon.svg"
        visible:    cfg.showButton
        onClicked:  mainDialog.open()
    }

    // ── Plugin manager settings (QField shows a ⚙ icon when this exists) ──
    function configure() {
        pluginOptionsDialog.open()
    }

    Dialog {
        id:      pluginOptionsDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 12
        width:   Math.min(mainWindow.width * 0.9, 360)
        x:       (mainWindow.width - width) / 2
        y:       (mainWindow.height - height) / 2

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text: "Traccar Live"
                    color: "white"; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true
                }
                HeaderButton {
                    icon.source: "icons/close.svg"
                    onClicked: pluginOptionsDialog.close()
                }
            }
        }

        ColumnLayout {
            width:   parent.width
            spacing: 8

            Switch {
                text:             "Show icon on canvas"
                checked:          cfg.showButton
                onToggled:        cfg.showButton = checked
                Layout.fillWidth: true
            }
            Label {
                text:             "When hidden, open Traccar Live from here. Live tracking and markers keep running."
                wrapMode:         Text.WordWrap
                color:            "#666666"
                font.pixelSize:   12
                Layout.fillWidth: true
            }
            Button {
                text:             "Open Traccar Live"
                Layout.fillWidth: true
                onClicked:        { pluginOptionsDialog.close(); mainDialog.open() }
            }
        }
    }

    // ── Live refresh: only while the window is still moving ───────────────
    Timer {
        id:          liveTimer
        interval:    Math.max(2, cfg.liveIntervalSec) * 1000
        repeat:      true
        running:     cfg.liveOn && plugin.win !== null && plugin.win.moving
        onTriggered: pollLive()
    }

    // ── Re-place overlay items when the map moves ─────────────────────────
    Connections {
        target: plugin.mapCanvas ? plugin.mapCanvas.mapSettings : null
        function onExtentChanged()         { plugin.mapTick++ }
        function onRotationChanged()       { plugin.mapTick++ }
        function onOutputSizeChanged()     { plugin.mapTick++ }
        function onDestinationCrsChanged() { plugin.crsTick++; plugin.mapTick++ }
    }

    // ── Retry pending layer writes once QFieldCloud is idle ───────────────
    Timer {
        id:          cloudWaitTimer
        interval:    3000
        repeat:      true
        onTriggered: _drainWrites()
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MAP OVERLAY  (drawn on the map canvas — nothing written to file)
    // ════════════════════════════════════════════════════════════════════════

    Item {
        id:      overlayLayer
        parent:  plugin.mapCanvas
        anchors.fill: parent

        // ── Geofences: areas, lines, circles in their own colour ─────────
        //    (never grey — a geofence isn't a fix that gets old)
        Repeater {
            model: plugin.geofenceModel
            delegate: Item {
                id: gfItem
                anchors.fill: parent
                property var g:    modelData
                property var proj: { plugin.crsTick; return plugin._projectCoords(g.coords) }
                property var pts:  { plugin.mapTick; return plugin._toScreen(proj) }
                property point lp: {
                    plugin.mapTick; plugin.crsTick
                    var s = plugin.mapCanvas.mapSettings.coordinateToScreen(plugin._toMapPoint(g.labelLon, g.labelLat))
                    return Qt.point(s.x, s.y)
                }
                Shape {
                    anchors.fill: parent
                    visible: gfItem.pts.length > 1
                    ShapePath {
                        strokeColor: gfItem.g.color
                        strokeWidth: 2
                        fillColor:   gfItem.g.kind === "line" ? "transparent" : "#40" + gfItem.g.color.substr(1)
                        joinStyle:   ShapePath.RoundJoin
                        PathPolyline { path: gfItem.pts }
                    }
                }
                Label {
                    visible: cfg.showLabels && gfItem.g.name !== ""
                    x: gfItem.lp.x - width / 2
                    y: gfItem.lp.y - height / 2
                    text: gfItem.g.name
                    font.pixelSize: 12
                    font.italic: true
                    color: Qt.darker(gfItem.g.color, 1.4)
                    style: Text.Outline
                    styleColor: "white"
                }
            }
        }

        // ── Shape being drawn (Add area / line) ──────────────────────────
        Item {
            id: draft
            anchors.fill: parent
            visible: plugin.drawMode !== "" && plugin.drawPts.length > 0
            property var pts: {
                plugin.mapTick; plugin.crsTick
                var p = plugin._toScreen(plugin._projectCoords(plugin.drawPts))
                if (plugin.drawMode === "area" && p.length > 2) p = p.concat([p[0]])
                return p
            }
            Shape {
                anchors.fill: parent
                ShapePath {
                    strokeColor: cfg.geofenceColor
                    strokeWidth: 3
                    strokeStyle: ShapePath.DashLine
                    fillColor:   plugin.drawMode === "area" ? "#30" + cfg.geofenceColor.substr(1) : "transparent"
                    PathPolyline { path: draft.pts }
                }
            }
            Repeater {
                model: draft.pts
                delegate: Rectangle {
                    x: modelData.x - 6; y: modelData.y - 6
                    width: 12; height: 12; radius: 6
                    color: "white"
                    border.color: cfg.geofenceColor
                    border.width: 3
                }
            }
        }

        // ── Tracks: the fixes inside the time window ──────────────────────
        Repeater {
            model: cfg.showTrails ? plugin.trackModel : []
            delegate: Shape {
                id: trackShape
                anchors.fill: parent
                property var proj: { plugin.crsTick; return plugin._projectCoords(modelData.coords) }
                property var pts:  { plugin.mapTick; return plugin._toScreen(proj) }
                visible: pts.length > 1
                ShapePath {
                    strokeColor: "#AA" + modelData.color.substr(1)
                    strokeWidth: 3
                    fillColor:   "transparent"
                    capStyle:    ShapePath.RoundCap
                    joinStyle:   ShapePath.RoundJoin
                    PathPolyline { path: trackShape.pts }
                }
            }
        }

        // ── Device markers ────────────────────────────────────────────────
        Repeater {
            model: cfg.showMarkers ? plugin.overlayModel : []
            delegate: Item {
                id: marker
                property var   d:  modelData
                property var   mp: { plugin.crsTick; return plugin._toMapPoint(d.lon, d.lat) }
                property point sp: { plugin.mapTick; return plugin.mapCanvas.mapSettings.coordinateToScreen(mp) }
                property color c:  d.color
                x: sp.x
                y: sp.y
                width: 0; height: 0

                // Accuracy circle (only meaningful when map units are metres)
                Rectangle {
                    visible: cfg.showAccuracy && marker.d.acc > 0 && !plugin._mapIsGeographic()
                    width: {
                        plugin.mapTick
                        var mupp = plugin.mapCanvas.mapSettings.mapUnitsPerPoint
                        return mupp > 0 ? Math.min(4000, 2 * marker.d.acc / mupp) : 0
                    }
                    height: width
                    radius: width / 2
                    anchors.centerIn: parent
                    color:        Qt.rgba(marker.c.r, marker.c.g, marker.c.b, 0.15)
                    border.color: Qt.rgba(marker.c.r, marker.c.g, marker.c.b, 0.5)
                    border.width: 1
                }

                Rectangle {
                    width: 20; height: 20; radius: 10
                    anchors.centerIn: parent
                    color:        "white"
                    border.color: marker.c
                    border.width: 3
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.centerIn: parent
                        color: marker.c
                    }
                }

                Rectangle {
                    visible: cfg.showLabels
                    anchors.horizontalCenter: parent.horizontalCenter
                    y:      -32
                    width:  markerLabel.contentWidth + 6
                    height: markerLabel.contentHeight + 2
                    radius: 3
                    color:  "#E6FFFFFF"
                    Label {
                        id: markerLabel
                        anchors.centerIn: parent
                        text:           marker.d.name
                        font.pixelSize: 11
                        font.bold:      true
                        color:          marker.c
                    }
                }
            }
        }
    }

    // ── Overlay helpers ───────────────────────────────────────────────────
    function _toMapPoint(lon, lat) {
        return GeometryUtils.reprojectPoint(GeometryUtils.point(lon, lat), plugin.wgs84,
                                            plugin.mapCanvas.mapSettings.destinationCrs)
    }

    function _projectCoords(coords) {
        var out = []
        try {
            for (var i = 0; i < coords.length; i++)
                out.push(_toMapPoint(coords[i].lon, coords[i].lat))
        } catch(e) {}
        return out
    }

    function _toScreen(mapPoints) {
        var ms  = plugin.mapCanvas.mapSettings
        var out = []
        for (var i = 0; i < mapPoints.length; i++) {
            var s = ms.coordinateToScreen(mapPoints[i])
            // a vertex less than a pixel from the last one adds nothing to the line
            var q = out.length > 0 ? out[out.length - 1] : null
            if (q && i < mapPoints.length - 1 && Math.abs(s.x - q.x) < 1 && Math.abs(s.y - q.y) < 1) continue
            out.push(Qt.point(s.x, s.y))
        }
        return out
    }

    function _mapIsGeographic() {
        plugin.crsTick
        try { return plugin.mapCanvas.mapSettings.destinationCrs.isGeographic === true } catch(e) {}
        return false
    }

    function _isFresh(fixTime) {
        if (!fixTime) return false
        return (Date.now() - new Date(fixTime).getTime()) < cfg.staleMinutes * 60000
    }

    // Vertices for drawing (always keeps first and last). Fixes within ~1 m of the previous kept one
    // are dropped first — a parked device repeats its position — so moving fixes are kept and
    // corners aren't cut; only a track still over maxPts is thinned evenly.
    function _thin(coords, maxPts) {
        if (coords.length <= 2) return coords
        var out = [coords[0]]
        for (var i = 1; i < coords.length - 1; i++) {
            var q = out[out.length - 1]
            if (Math.abs(coords[i].lon - q.lon) > 1e-5 || Math.abs(coords[i].lat - q.lat) > 1e-5) out.push(coords[i])
        }
        out.push(coords[coords.length - 1])
        if (out.length <= maxPts) return out
        var even = []
        var step = (out.length - 1) / (maxPts - 1)
        for (var j = 0; j < maxPts; j++) even.push(out[Math.round(j * step)])
        return even
    }

    // Same colour for the same device name as the QGIS plugin Traccar Live (MD5 → hue)
    function _deviceColor(name) {
        var hue = parseInt(Qt.md5(String(name)).substr(0, 4), 16) % 360
        return String(Qt.hsva(hue / 360, 190 / 255, 200 / 255, 1))
    }

    // ── Devices unticked in the list: hidden on the map, left out of saving ──
    function _hiddenIds() {
        var out = {}
        cfg.hiddenDevices.split(",").forEach(function(s) { if (s !== "") out[s] = true })
        return out
    }

    function isHidden(id) {
        return _hiddenIds()[String(id)] === true
    }

    function _setHidden(ids) {
        cfg.hiddenDevices = Object.keys(ids).sort(function(a, b) { return a - b }).join(",")
        _rebuildAll()
    }

    function setDeviceShown(id, on) {
        var ids = _hiddenIds()
        if (on) delete ids[String(id)]
        else    ids[String(id)] = true
        _setHidden(ids)
    }

    function setAllShown(on) {
        var ids = {}
        if (!on) for (var devId in plugin.deviceInfo) ids[String(devId)] = true
        _setHidden(ids)
    }

    function _onMapTap(point) {
        if (plugin.drawMode !== "") { _drawTap(point); return true }
        if (!cfg.showMarkers) return false
        var ms = plugin.mapCanvas.mapSettings
        for (var i = 0; i < plugin.overlayModel.length; i++) {
            var d = plugin.overlayModel[i]
            var s = ms.coordinateToScreen(_toMapPoint(d.lon, d.lat))
            if (Math.abs(point.x - s.x) < 24 && Math.abs(point.y - s.y) < 24) {
                var msg = d.name + "\nFix " + _ageText(d.fixTime) + " ago"
                msg += "  •  " + Math.round((d.speed || 0) * 1.852) + " km/h"
                if (d.battery !== null && d.battery !== undefined) msg += "  •  battery " + d.battery + "%"
                mainWindow.displayToast(msg)
                return true
            }
        }
        return false
    }

    // ════════════════════════════════════════════════════════════════════════
    //  GEOFENCES AND POINTS IN TRACCAR
    //  Traccar keeps a geofence's shape as text with LATITUDE FIRST:
    //  "POLYGON ((52.1 -9.5, …))", "LINESTRING (…)", "CIRCLE (52.1 -9.5, 500)".
    //  Same rules as the QGIS plugin Traccar Live: geofences sent from either
    //  plugin carry the createdByTraccarLiveQgis attribute (sending the same name
    //  again replaces them), and points sent as devices get a "qgis-…" identifier.
    // ════════════════════════════════════════════════════════════════════════
    readonly property string geofenceMark:    "createdByTraccarLiveQgis"
    readonly property string defaultGfColor:  "#E65100"
    readonly property string sentPointPrefix: "qgis-"
    readonly property int    maxAreaChars:    4000      // Traccar keeps the area in a 4096-character column
    readonly property var    deviceCategories: ["default", "animal", "bicycle", "boat", "bus", "camper", "car",
        "crane", "helicopter", "motorcycle", "offroad", "person", "pickup", "plane", "scooter", "ship",
        "tractor", "train", "tram", "trolleybus", "truck", "van"]       // Traccar's map icons
    readonly property var    swatches: ["#E65100", "#C62828", "#AD1457", "#6A1B9A", "#1565C0",
                                        "#00838F", "#2E7D32", "#F9A825", "#4E342E", "#424242"]

    // Geofences drawn on the map: ticked ones, while Geofences is on under Show
    readonly property var geofenceModel: {
        if (!cfg.showGeofences) return []
        var hidden = _gfHiddenIds()
        return plugin.geofences.filter(function(g) { return !hidden[String(g.id)] && g.coords.length > 1 })
    }

    function _normColor(c) {
        var s = String(c || "").trim()
        if (/^#[0-9a-fA-F]{6}$/.test(s)) return s.toUpperCase()
        if (/^#[0-9a-fA-F]{3}$/.test(s)) return ("#" + s[1] + s[1] + s[2] + s[2] + s[3] + s[3]).toUpperCase()
        return ""
    }

    // Traccar area text → {kind: "polygon" | "line" | "circle", coords: [{lon, lat}], radius}, or null.
    // Circles come back as a 72-sided ring for drawing.
    function parseArea(area) {
        var s = String(area || "").trim()
        var num = "(-?\\d+(?:\\.\\d+)?)"
        var m = new RegExp("^CIRCLE\\s*\\(\\s*" + num + "\\s+" + num + "\\s*,\\s*" + num + "\\s*\\)", "i").exec(s)
        if (m) {
            var lat = parseFloat(m[1]), lon = parseFloat(m[2]), r = parseFloat(m[3])
            var k = 111320, kx = k * Math.max(Math.cos(lat * Math.PI / 180), 0.01)
            var ring = []
            for (var i = 0; i <= 72; i++) {
                var a = 2 * Math.PI * i / 72
                ring.push({ lon: lon + r * Math.sin(a) / kx, lat: lat + r * Math.cos(a) / k })
            }
            return { kind: "circle", coords: ring, radius: r, centre: { lon: lon, lat: lat } }
        }
        m = /^(POLYGON|LINESTRING)\s*\(+([\s\S]*?)\)+\s*$/i.exec(s)
        if (!m) return null
        var coords = []
        var pairs = m[2].split(",")
        for (var j = 0; j < pairs.length; j++) {
            var xy = pairs[j].trim().split(/\s+/)
            var la = parseFloat(xy[0]), lo = parseFloat(xy[1])
            if (!isFinite(la) || !isFinite(lo)) return null
            coords.push({ lon: lo, lat: la })
        }
        return { kind: m[1].toUpperCase() === "LINESTRING" ? "line" : "polygon", coords: coords, radius: 0 }
    }

    function _ll(lon, lat) { return lat.toFixed(6) + " " + lon.toFixed(6) }

    // Corners ({lon, lat}) → Traccar area text; very detailed shapes are thinned until they fit.
    // Returns {area, simplified}, or null when there is nothing Traccar can take.
    function areaText(kind, coords, radius) {
        if (kind === "circle")
            return coords.length > 0 ? { area: "CIRCLE (" + _ll(coords[0].lon, coords[0].lat) + ", "
                                                 + Number(radius).toFixed(1) + ")", simplified: false } : null
        var pts = coords.slice()
        if (kind === "polygon") {
            var f = pts[0], l = pts[pts.length - 1]
            if (pts.length > 0 && (f.lon !== l.lon || f.lat !== l.lat)) pts.push(f)
            if (pts.length < 4) return null
        } else if (pts.length < 2) return null
        var make = function(p) {
            var t = p.map(function(c) { return _ll(c.lon, c.lat) }).join(", ")
            return kind === "polygon" ? "POLYGON ((" + t + "))" : "LINESTRING (" + t + ")"
        }
        var text = make(pts), step = 1
        while (text.length > maxAreaChars && pts.length > 8) {
            step++
            var thin = []
            for (var i = 0; i < pts.length - 1; i += step) thin.push(pts[i])
            thin.push(pts[pts.length - 1])
            if (thin.length < (kind === "polygon" ? 4 : 2)) break
            text = make(thin)
        }
        return text.length <= maxAreaChars ? { area: text, simplified: step > 1 } : null
    }

    function geofenceType(g) {
        if (g.kind === "circle") return "Circle " + Math.round(g.radius) + " m"
        return g.kind === "line" ? "Line" : g.kind === "polygon" ? "Area" : "?"
    }

    function loadGeofences() {
        if (cfg.username === "") return
        _get("/api/geofences", function(data) {
            var out = []
            data.forEach(function(g) {
                var attrs  = g.attributes || {}
                var parsed = parseArea(g.area) || { kind: "", coords: [], radius: 0 }
                var c = parsed.coords
                var lp = parsed.kind === "circle" ? parsed.centre
                       : parsed.kind === "line"   ? c[Math.floor(c.length / 2)]
                       : _ringMiddle(c)
                out.push({ id: g.id, name: g.name || "", area: g.area || "", mine: attrs[geofenceMark] === true,
                           raw: g, color: _normColor(attrs.color) || defaultGfColor,
                           kind: parsed.kind, coords: c, radius: parsed.radius,
                           labelLon: lp ? lp.lon : 0, labelLat: lp ? lp.lat : 0, centre: parsed.centre || null,
                           description: g.description || "",
                           speedKmh: attrs.speedLimit ? Math.round(attrs.speedLimit * 1.852) : 0 })
            })
            out.sort(function(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()) })
            plugin.geofences = out
        }, function(msg) { console.log("Traccar Live: geofences: " + msg) })
        // For the send form; an account without access just gets empty lists
        var byName = function(a, b) { return String(a.name || "").toLowerCase().localeCompare(String(b.name || "").toLowerCase()) }
        _get("/api/groups",    function(d) { plugin.groups    = (d || []).sort(byName) }, function() {})
        _get("/api/calendars", function(d) { plugin.calendars = (d || []).sort(byName) }, function() {})
    }

    // Send-form values → the geofence fields besides name and area (as the QGIS plugin)
    function geofenceExtra(v) {
        var attrs = { color: v.color }
        if (v.speedKmh > 0)  attrs.speedLimit = Math.round(v.speedKmh / 1.852 * 100) / 100   // Traccar: knots
        if (v.corridorM > 0) attrs.polylineDistance = v.corridorM
        return { description: v.description || "", calendarId: v.calendarId || 0, attributes: attrs }
    }

    // Where a polygon's name goes: its centroid (area-weighted), else the middle of its corners
    function _ringMiddle(c) {
        if (!c || c.length === 0) return null
        var a = 0, x = 0, y = 0
        for (var i = 0; i < c.length - 1; i++) {
            var cr = c[i].lon * c[i + 1].lat - c[i + 1].lon * c[i].lat
            a += cr; x += (c[i].lon + c[i + 1].lon) * cr; y += (c[i].lat + c[i + 1].lat) * cr
        }
        if (Math.abs(a) > 1e-14) return { lon: x / (3 * a), lat: y / (3 * a) }
        var sx = 0, sy = 0
        c.forEach(function(p) { sx += p.lon; sy += p.lat })
        return { lon: sx / c.length, lat: sy / c.length }
    }

    // ── Geofences unticked in the list: not drawn (remembered) ────────────
    function _gfHiddenIds() {
        var out = {}
        cfg.hiddenGeofences.split(",").forEach(function(s) { if (s !== "") out[s] = true })
        return out
    }

    function setGeofenceShown(id, on) {
        var ids = _gfHiddenIds()
        if (on) delete ids[String(id)]
        else    ids[String(id)] = true
        cfg.hiddenGeofences = Object.keys(ids).sort(function(a, b) { return a - b }).join(",")
    }

    function setAllGeofencesShown(on) {
        cfg.hiddenGeofences = on ? "" : plugin.geofences.map(function(g) { return g.id }).join(",")
    }

    function _geofence(id) {
        for (var i = 0; i < plugin.geofences.length; i++) if (String(plugin.geofences[i].id) === String(id)) return plugin.geofences[i]
        return null
    }

    function zoomToGeofence(id) {
        var g = _geofence(id)
        if (!g) return
        setGeofenceShown(id, true)
        if (!cfg.showGeofences) cfg.showGeofences = true
        zoomToDevice({ longitude: g.labelLon, latitude: g.labelLat })
    }

    // ── Changes in Traccar ────────────────────────────────────────────────
    function setGeofenceColor(id, color) {
        var g = _geofence(id)
        if (!g) return
        var body  = JSON.parse(JSON.stringify(g.raw))
        body.attributes = body.attributes || {}
        body.attributes.color = color
        _send("PUT", "/api/geofences/" + g.id, body, function() {
            mainWindow.displayToast("Colour of '" + g.name + "' saved in Traccar")
            loadGeofences()
        }, function(msg) { mainWindow.displayToast("Couldn't change '" + g.name + "': " + msg) })
    }

    // The send form, filled in with the geofence's values (Save puts the changes in Traccar)
    function editGeofence(id) {
        var g = _geofence(id)
        if (!g) return
        mainDialog.close()
        sendDialog.mode   = g.kind === "polygon" ? "area" : g.kind === "line" ? "line" : g.kind === "circle" ? "circle" : "area"
        sendDialog.coords = g.kind === "circle" ? [g.centre] : g.coords
        sendDialog.editG  = g
        sendDialog.open()
    }

    // name, extra = geofenceExtra(form values); radius > 0: a circle's new radius. The shape stays.
    function updateGeofence(g, name, extra, radius) {
        var body  = JSON.parse(JSON.stringify(g.raw))
        var attrs = body.attributes || {}
        delete attrs.speedLimit
        delete attrs.polylineDistance
        for (var k in extra.attributes) attrs[k] = extra.attributes[k]
        body.attributes  = attrs
        body.name        = name
        body.description = extra.description
        body.calendarId  = extra.calendarId
        if (g.kind === "circle" && radius > 0) body.area = areaText("circle", [g.centre], radius).area
        _send("PUT", "/api/geofences/" + g.id, body, function() {
            mainWindow.displayToast("'" + name + "' saved in Traccar")
            loadGeofences()
        }, function(msg) { mainWindow.displayToast("Couldn't change '" + g.name + "': " + msg) })
    }

    function deleteGeofence(id) {
        var g = _geofence(id)
        if (!g) return
        _send("DELETE", "/api/geofences/" + g.id, null, function() {
            plugin.geofences = plugin.geofences.filter(function(x) { return x.id !== g.id })
            mainWindow.displayToast("Deleted '" + g.name + "' from Traccar")
        }, function(msg) { mainWindow.displayToast("Couldn't delete '" + g.name + "': " + msg) })
    }

    function deleteSentPoint(devId) {
        var info = plugin.deviceInfo[devId] || {}
        if (String(info.uniqueId || "").indexOf(sentPointPrefix) !== 0) return
        _send("DELETE", "/api/devices/" + devId, null, function() {
            var d = {}, t = {}, l = {}
            for (var k in plugin.deviceInfo) if (String(k) !== String(devId)) d[k] = plugin.deviceInfo[k]
            for (var k2 in plugin.tracks)    if (k2 !== String(devId)) t[k2] = plugin.tracks[k2]
            for (var k3 in plugin.latest)    if (k3 !== String(devId)) l[k3] = plugin.latest[k3]
            plugin.deviceInfo = d; plugin.tracks = t; plugin.latest = l
            _rebuildAll()
            mainWindow.displayToast("Deleted '" + info.name + "' from Traccar")
        }, function(msg) { mainWindow.displayToast("Couldn't delete '" + info.name + "': " + msg) })
    }

    // items: [{name, area}], all in one colour, with extra fields from the send form
    // ({description, calendarId, attributes}, optional). A geofence sent from QGIS / QField before
    // under the same name is replaced; anything else is added. done(added, replaced, errors) is optional.
    function upsertGeofences(items, color, extra, done) {
        if (items.length === 0) return
        _get("/api/geofences", function(existing) {
            var mine = {}
            existing.forEach(function(g) {
                if ((g.attributes || {})[geofenceMark] === true) mine[String(g.name || "").trim().toLowerCase()] = g
            })
            var st = { left: items.length, added: 0, replaced: 0, errors: [] }
            var finish = function() {
                if (--st.left > 0) return
                var msg = "Sent " + (st.added + st.replaced) + " geofence(s) to Traccar"
                if (st.replaced > 0) msg += " (" + st.replaced + " replaced)"
                if (st.errors.length > 0) msg += "; " + st.errors.length + " failed: " + st.errors[0]
                mainWindow.displayToast(msg)
                loadGeofences()
                if (done) done(st.added, st.replaced, st.errors)
            }
            items.forEach(function(it) {
                var old = mine[it.name.trim().toLowerCase()]
                var ok  = function() { if (old) st.replaced++; else st.added++; finish() }
                var bad = function(msg) { st.errors.push(it.name + ": " + msg); finish() }
                var attrs = {}
                var more  = (extra && extra.attributes) || {}
                for (var k in more) attrs[k] = more[k]
                attrs[geofenceMark] = true
                attrs.color = color
                var body = old ? JSON.parse(JSON.stringify(old)) : {}
                body.name = it.name; body.area = it.area
                if (extra && extra.description !== undefined) body.description = it.description || extra.description
                else if (it.description) body.description = it.description
                if (extra && extra.calendarId !== undefined) body.calendarId = extra.calendarId
                body.attributes = body.attributes || {}
                for (var a in attrs) body.attributes[a] = attrs[a]
                if (old) _send("PUT", "/api/geofences/" + old.id, body, ok, bad)
                else     _send("POST", "/api/geofences", body, ok, bad)
            })
        }, function(msg) { mainWindow.displayToast("Sending geofences needs your Traccar login: " + msg) })
    }

    // OsmAnd endpoint for points: Settings → Connection 'Send to', else http://<server host>:5055/
    function osmandUrl() {
        if (cfg.sendUrl.trim() !== "") {
            var u = cfg.sendUrl.trim()
            return u.indexOf("://") >= 0 ? u : "http://" + u
        }
        var m = /^[a-z]+:\/\/([^\/:?#]+)/i.exec(cfg.serverUrl)
        return m ? "http://" + m[1] + ":5055/" : ""
    }

    // Send lat / lon as a fix of the device called name (time = now). An existing device
    // (by name or identifier) moves there; a new name adds a device with a qgis-… identifier.
    // details (optional, for a new device): {uniqueId, category, groupId, phone, model, contact}
    function sendPoint(name, lon, lat, done, details) {
        var base = osmandUrl()
        if (base === "") { mainWindow.displayToast("Set up the connection first"); return }
        name = String(name).trim()
        var t = Math.floor(Date.now() / 1000)
        var fix = function(uid) {
            var url = base + (base.indexOf("?") >= 0 ? "&" : "?") + "id=" + encodeURIComponent(uid)
                      + "&lat=" + lat.toFixed(7) + "&lon=" + lon.toFixed(7) + "&timestamp=" + t + "&valid=true"
            var xhr = new XMLHttpRequest()
            xhr.open("GET", url, true)
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                if (xhr.status === 200) {
                    mainWindow.displayToast("Sent to Traccar as '" + name + "'")
                    if (plugin.win !== null && plugin.win.moving) sendRefresh.restart()
                    if (done) done(true)
                } else {
                    mainWindow.displayToast(xhr.status === 0
                        ? "Send point: no response from " + base + " — check 'Send points to' in Settings → Connection"
                        : "Traccar refused the point for '" + name + "' (HTTP " + xhr.status + ")")
                    if (done) done(false)
                }
            }
            xhr.send()
        }
        _get("/api/devices", function(devs) {
            var uid = null      // OsmAnd needs the device's identifier (uniqueId), not its name: accept either
            devs.forEach(function(d) { if (!uid && d.uniqueId && d.uniqueId === name) uid = d.uniqueId })
            devs.forEach(function(d) {
                if (!uid && d.uniqueId && String(d.name || "").trim().toLowerCase() === name.toLowerCase()) uid = d.uniqueId
            })
            if (uid) { fix(uid); return }
            var slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").substr(0, 30) || "point"
            var dt = details || {}
            var newUid = dt.uniqueId || (sentPointPrefix + slug + "-" + t)
            var body = { name: name, uniqueId: newUid, category: dt.category || "default" }
            if (dt.groupId) body.groupId = dt.groupId
            ;["phone", "model", "contact"].forEach(function(k) { if (dt[k]) body[k] = dt[k] })
            _send("POST", "/api/devices", body,
                  function(d) { fix((d && d.uniqueId) || newUid) },
                  function(msg) {
                      mainWindow.displayToast("Couldn't add '" + name + "' to Traccar (" + msg
                                              + ") — your account may not be allowed to add devices")
                      if (done) done(false)
                  })
        }, function(msg) { mainWindow.displayToast("Send point needs your Traccar login: " + msg) })
    }

    Timer { id: sendRefresh; interval: 2000; onTriggered: pollLive() }

    // ── Drawing on the map: tap to place a point / circle centre, or corners ──
    function startDraw(mode) {
        if (!plugin.isConnected()) { openSettings("connection"); return }
        plugin.drawPts  = []
        plugin.drawMode = mode
        mainDialog.close()
    }

    function cancelDraw() {
        plugin.drawMode = ""
        plugin.drawPts  = []
    }

    function _screenToLonLat(point) {
        var ms = plugin.mapCanvas.mapSettings
        var mp = ms.screenToCoordinate(point)
        var ll = GeometryUtils.reprojectPoint(GeometryUtils.point(mp.x, mp.y), ms.destinationCrs, plugin.wgs84)
        return { lon: ll.x, lat: ll.y }
    }

    function _drawTap(point) {
        addDrawPoint(_screenToLonLat(point))
    }

    function addDrawPoint(ll) {
        if (!ll || !isFinite(ll.lon) || !isFinite(ll.lat)) return
        plugin.drawPts = plugin.drawPts.concat([ll])
        if (plugin.drawMode === "point" || plugin.drawMode === "circle") finishDraw()
    }

    // The phone's GPS position, or null
    function gpsLonLat() {
        try {
            var ps = iface.findItemByObjectName("positionSource")
            var pi = ps ? ps.positionInformation : null
            if (pi && pi.latitudeValid && pi.longitudeValid) return { lon: pi.longitude, lat: pi.latitude }
        } catch(e) {}
        return null
    }

    function undoDraw() {
        plugin.drawPts = plugin.drawPts.slice(0, Math.max(0, plugin.drawPts.length - 1))
    }

    function canFinishDraw() {
        return plugin.drawPts.length >= (plugin.drawMode === "area" ? 3 : plugin.drawMode === "line" ? 2 : 1)
    }

    function finishDraw() {
        if (!canFinishDraw()) return
        sendDialog.mode   = plugin.drawMode
        sendDialog.coords = plugin.drawPts
        sendDialog.open()
    }

    // ── From a layer: its features become geofences (points: circles or points) ──
    // Geometry WKT (any CRS, Z / M, multipart) → [{kind: "polygon" | "line" | "point", coords: [{lon, lat}]}]
    // in WGS84. Polygons keep their outer ring only (Traccar has no holes); curves are not read.
    function wktParts(wkt, crs) {
        var s = String(wkt || "").trim()
        var head = /^(MULTI)?(POINT|LINESTRING|POLYGON)\s*(ZM|Z|M)?\s*\(/i.exec(s)
        if (!head) return []
        var type = head[2].toUpperCase()
        var toLl = function(text) {
            var out = []
            text.split(",").forEach(function(v) {
                var n = v.trim().split(/\s+/)
                var x = parseFloat(n[0]), y = parseFloat(n[1])
                if (!isFinite(x) || !isFinite(y)) return
                if (crs && crs.authid !== "EPSG:4326") {
                    var p = GeometryUtils.reprojectPoint(GeometryUtils.point(x, y), crs, plugin.wgs84)
                    x = p.x; y = p.y
                }
                out.push({ lon: x, lat: y })
            })
            return out
        }
        var parts = [], m
        if (type === "POLYGON") {
            var outer = /\(\s*\(\s*([^()]+)\)/g                 // first ring of each polygon
            while ((m = outer.exec(s)) !== null) parts.push({ kind: "polygon", coords: toLl(m[1]) })
        } else {
            var inner = /\(\s*([^()]+)\)/g                      // each innermost list
            while ((m = inner.exec(s)) !== null) {
                if (type === "LINESTRING") parts.push({ kind: "line", coords: toLl(m[1]) })
                else toLl(m[1]).forEach(function(c) { parts.push({ kind: "point", coords: [c] }) })
            }
        }
        return parts.filter(function(p) { return p.coords.length > 0 })
    }

    function _geomWkt(geom) {
        try { if (geom && geom.asWkt) return geom.asWkt(7) } catch(e) {}
        try { if (geom && geom.wkt)   return geom.wkt } catch(e2) {}
        return ""
    }

    // Every feature of the layer (or only fid) → sent to Traccar.
    // asPoints: point features become points (devices) instead of circles.
    // descField (optional): field whose value becomes each geofence's description
    function sendLayer(layerName, fid, nameField, fixedName, radius, color, asPoints, descField) {
        var lyr = _layerByName(layerName, "Send")
        if (!lyr) return
        var items = [], points = [], skipped = 0, n = 0
        try {
            var iter = LayerUtils.createFeatureIterator(lyr)
            while (iter.hasNext()) {
                var f = iter.next()
                if (fid >= 0 && f.id !== fid) continue
                n++
                var label = ""
                if (nameField !== "") {
                    var v = f.attribute(nameField)
                    label = (v === null || v === undefined) ? "" : String(v).trim()
                }
                if (label === "") label = (fixedName || layerName) + (fid >= 0 ? "" : " " + n)
                var desc = ""
                if (descField) {
                    var dv = f.attribute(descField)
                    desc = (dv === null || dv === undefined) ? "" : String(dv).trim()
                }
                var parts = wktParts(_geomWkt(f.geometry), lyr.crs)
                if (parts.length === 0) { skipped++; continue }
                for (var j = 0; j < parts.length; j++) {
                    var p = parts[j]
                    var nm = parts.length === 1 ? label : label + " (" + (j + 1) + ")"
                    if (p.kind === "point" && asPoints) { points.push({ name: nm, c: p.coords[0] }); continue }
                    var a = areaText(p.kind === "point" ? "circle" : p.kind, p.coords, radius)
                    if (a) items.push({ name: nm, area: a.area, description: desc })
                    else   skipped++
                }
            }
            iter.close()
        } catch(e) {
            mainWindow.displayToast("Couldn't read '" + layerName + "': " + e)
            return
        }
        if (skipped > 0) mainWindow.displayToast(skipped + " feature(s) skipped: no shape Traccar can take")
        if (items.length > 0) upsertGeofences(items, color)
        points.forEach(function(p) { sendPoint(p.name, p.c.lon, p.c.lat) })
        if (items.length === 0 && points.length === 0 && skipped === 0) mainWindow.displayToast("No features to send")
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MAIN DIALOG
    // ════════════════════════════════════════════════════════════════════════
    function _latLonText(p) {
        return p.latitude.toFixed(6) + ", " + p.longitude.toFixed(6)
    }

    // Grid letters — same as the QGIS plugin Traccar Live and the QField plugin Conversion_tools
    readonly property string osLetters: "ABCDEFGHJKLMNOPQRSTUVWXYZ"     // A–Z without I
    readonly property string igLetters: "VWXYZQRSTULMNOPFGHJKABCDE"     // Irish Grid, rows from the south

    function _pad5(v) { return ("0000" + (v % 100000)).slice(-5) }

    // Irish Grid (EPSG:29903) easting / northing → "O 15904 34671", or "" outside the grid
    function _irishGridRef(x, y) {
        x = Math.round(x); y = Math.round(y)
        if (!(x >= 0 && x < 500000 && y >= 0 && y < 500000)) return ""
        return igLetters[Math.floor(y / 100000) * 5 + Math.floor(x / 100000)] + " " + _pad5(x) + " " + _pad5(y)
    }

    // British National Grid (EPSG:27700) easting / northing → "NS 45140 72887", or "" outside the grid
    function _ukGridRef(x, y) {
        x = Math.round(x); y = Math.round(y)
        if (!(x >= 0 && x < 700000 && y >= 0 && y < 1300000)) return ""
        var e = Math.floor(x / 100000), n = 19 - Math.floor(y / 100000)
        var first  = n - n % 5 + Math.floor((e + 10) / 5)     // 500 km square
        var second = n * 5 % 25 + e % 5                       // 100 km square within it
        return osLetters[first] + osLetters[second] + " " + _pad5(x) + " " + _pad5(y)
    }

    // Degrees + minutes with N/S/E/W, as the QGIS plugin: "53° 21.900' N, 6° 18.600' W"
    function _dmText(lat, lon) {
        function one(v, hemi) {
            var total = Math.round(Math.abs(v) * 60000) / 1000      // rounded first: never shows 60.000'
            var deg   = Math.floor(total / 60)
            var mins  = (total - deg * 60).toFixed(3)
            return deg + "° " + (mins.length < 6 ? "0" : "") + mins + "' " + (v >= 0 ? hemi[0] : hemi[1])
        }
        return one(lat, "NS") + ", " + one(lon, "EW")
    }

    // Project CRS, falling back to the map's CRS
    function _projectCrs() {
        try { if (qgisProject.crs && qgisProject.crs.authid) return qgisProject.crs } catch(e) {}
        return plugin.mapCanvas.mapSettings.destinationCrs
    }

    // Location formats: value = cfg.locationFormat (kept stable), listed in this order
    readonly property var locationFormats: [
        { value: 0, label: "Lat / long" },
        { value: 3, label: "Degrees + minutes" },
        { value: 1, label: "Irish Grid" },
        { value: 2, label: "UK Grid" },
        { value: 4, label: "Project CRS" }
    ]

    function _locationLabel(v) {
        for (var i = 0; i < locationFormats.length; i++)
            if (locationFormats[i].value === v) return locationFormats[i].label
        return locationFormats[0].label
    }

    // A position in the format chosen in Settings → Advanced; lat / long outside the chosen grid
    function _locationText(p) {
        if (cfg.locationFormat === 3) return _dmText(p.latitude, p.longitude)
        if (cfg.locationFormat === 4) {
            try {
                var crs = _projectCrs()
                var xy  = GeometryUtils.reprojectPoint(GeometryUtils.point(p.longitude, p.latitude), plugin.wgs84, crs)
                if (crs.isGeographic) return xy.y.toFixed(6) + ", " + xy.x.toFixed(6)
                if (isFinite(xy.x) && isFinite(xy.y)) return xy.x.toFixed(1) + ", " + xy.y.toFixed(1)
            } catch(e2) {}
        }
        if (cfg.locationFormat === 1 || cfg.locationFormat === 2) {
            try {
                var irish = cfg.locationFormat === 1
                var g = GeometryUtils.reprojectPoint(GeometryUtils.point(p.longitude, p.latitude), plugin.wgs84,
                                                     irish ? plugin.irishGridCrs : plugin.ukGridCrs)
                var ref = irish ? _irishGridRef(g.x, g.y) : _ukGridRef(g.x, g.y)
                if (ref !== "") return ref
            } catch(e) {}
        }
        return _latLonText(p)
    }

    // QML has no clipboard API — copy through a hidden text field
    TextEdit { id: clipboardHelper; visible: false }
    function copyToClipboard(text) {
        clipboardHelper.text = text
        clipboardHelper.selectAll()
        clipboardHelper.copy()
        clipboardHelper.text = ""
    }

    Dialog {
        id:      mainDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 8
        width:   plugin.phone ? mainWindow.width * 0.93 : Math.min(mainWindow.width * 0.84, 428)
        // ~70% of the available height, so the map stays visible around it
        height:  plugin.phone ? (mainWindow.height - plugin.topInset - plugin.bottomInset) * 0.7
                              : Math.min(mainWindow.height * 0.63, 550)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset + (mainWindow.height - plugin.topInset - plugin.bottomInset - height) / 2
                              : (mainWindow.height - height) / 2

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text:             "Traccar Live"
                    color:            "white"
                    font.pixelSize:   17
                    font.bold:        true
                    Layout.fillWidth: true
                }
                ToolButton {
                    contentItem: Text {
                        text: "?"; color: "white"; font.pixelSize: 18; font.bold: true
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked: { mainDialog.close(); helpDialog.open() }
                }
                HeaderButton {
                    icon.source: "icons/settings.svg"
                    onClicked: openSettings("")
                }
                HeaderButton {
                    icon.source: "icons/close.svg"
                    onClicked: mainDialog.close()
                }
            }
        }

        onOpened: {
            windowCombo.currentIndex = _windowIndex(cfg.windowMinutes)
            fromDateField.text = cfg.customFrom !== "" ? cfg.customFrom : Qt.formatDate(new Date(), "yyyy-MM-dd") + " 00:00"
            toDateField.text   = cfg.customTo   !== "" ? cfg.customTo   : Qt.formatDate(new Date(), "yyyy-MM-dd") + " 23:59"
            featureSpanCombo.currentIndex = cfg.featureSpan
            durationSpin.value = cfg.featureDuration
            if (cfg.windowMinutes === -2) _refreshFeatureCombo()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 6

            // ── First-run checklist ───────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: !plugin.isConnected()
                color:   "#FFF8E1"
                radius:  4
                implicitHeight: setupCol.implicitHeight + 16
                ColumnLayout {
                    id: setupCol
                    anchors { fill: parent; margins: 8 }
                    spacing: 4
                    Label { text: "Getting started"; font.bold: true }
                    Hint { text: "1. Connect to your Traccar server.\n2. Choose where saved points and tracks go (optional)." }
                    Button { text: "Set up connection"; onClicked: openSettings("connection") }
                }
            }

            // ── Error banner (tap → Connection settings) ──────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: plugin.liveError !== ""
                color:   "#FFEBEE"
                radius:  4
                implicitHeight: errLabel.implicitHeight + 12
                Label {
                    id: errLabel
                    anchors { fill: parent; margins: 6 }
                    text: plugin.liveError + "  — tap to check settings"
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: "#B71C1C"
                }
                MouseArea { anchors.fill: parent; onClicked: openSettings("connection") }
            }

            // ── Time window ───────────────────────────────────────────────
            Label { text: "Time window"; font.bold: true }
            ComboBox {
                id: windowCombo
                Layout.fillWidth: true
                model:    windowModel
                textRole: "label"
                onActivated: {
                    var m = windowModel.get(currentIndex).minutes
                    cfg.windowMinutes = m
                    if (m === -2) _refreshFeatureCombo()
                    if (m > 0) reloadWindow()        // custom / feature wait for "Show"
                    else       plugin.statusMsg = "Set the window below, then tap Show"
                }
            }

            // Custom dates
            GridLayout {
                visible: cfg.windowMinutes === -1
                Layout.fillWidth: true
                columns: 2
                Label { text: "From" }
                TextField {
                    id: fromDateField
                    Layout.fillWidth: true
                    placeholderText:  "YYYY-MM-DD HH:MM"
                    inputMethodHints: Qt.ImhNoPredictiveText
                }
                Label { text: "To" }
                TextField {
                    id: toDateField
                    Layout.fillWidth: true
                    placeholderText:  "YYYY-MM-DD HH:MM"
                    inputMethodHints: Qt.ImhNoPredictiveText
                }
            }

            // From feature
            ColumnLayout {
                visible: cfg.windowMinutes === -2
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    ComboBox {
                        id: eventFeatureCombo
                        Layout.fillWidth: true
                        model:    eventFeatureModel
                        textRole: "label"
                        onActivated: cfg.eventFeatureFid = eventFeatureModel.get(currentIndex).fid
                    }
                    ToolButton {
                        icon.source: "icons/refresh.svg"
                        onClicked: _refreshFeatureCombo()
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    ComboBox {
                        id: featureSpanCombo
                        Layout.fillWidth: true
                        model: ["Its start → its end", "Its start + duration", "Its end − duration"]
                        onActivated: cfg.featureSpan = currentIndex
                    }
                    SpinBox {
                        id: durationSpin
                        visible: featureSpanCombo.currentIndex > 0
                        from: 1; to: 14400; stepSize: 15; editable: true
                        onValueModified: cfg.featureDuration = value
                    }
                    Label { visible: durationSpin.visible; text: "min" }
                }
            }

            Button {
                visible: cfg.windowMinutes < 0
                Layout.fillWidth: true
                text: "Show this window"
                onClicked: {
                    if (cfg.windowMinutes === -1) {
                        cfg.customFrom = fromDateField.text.trim()
                        cfg.customTo   = toDateField.text.trim()
                    }
                    reloadWindow()
                }
            }

            Hint { text: plugin.windowSummary(); visible: text !== "" }

            // ── Live / refresh / clear ────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    Layout.fillWidth: true
                    text: cfg.liveOn ? "Stop live" : "Live"
                    icon.source: cfg.liveOn ? "icons/stop.svg" : "icons/play.svg"
                    onClicked: {
                        cfg.liveOn = !cfg.liveOn
                        if (cfg.liveOn) loadWindow()
                    }
                }
                Button {
                    text: plugin.loading ? "…" : ""
                    icon.source: plugin.loading ? "" : "icons/refresh.svg"
                    enabled: !plugin.loading
                    onClicked: loadWindow()
                }
                Button {
                    text: "Clear"
                    enabled: plugin.win !== null
                    onClicked: { cfg.liveOn = false; clearWindow(); plugin.geofences = []; plugin.statusMsg = "" }
                }
                Button {                            // same Add menu as the QGIS plugin
                    id: addButton
                    text: "Add"
                    icon.source: "icons/add.svg"
                    onClicked: addMenu.open()
                    Menu {
                        id: addMenu
                        y: addButton.height
                        MenuItem { text: "Point";  onTriggered: plugin.startDraw("point") }
                        MenuItem { text: "Area";   onTriggered: plugin.startDraw("area") }
                        MenuItem { text: "Line";   onTriggered: plugin.startDraw("line") }
                        MenuItem { text: "Circle"; onTriggered: plugin.startDraw("circle") }
                        MenuSeparator {}
                        MenuItem { text: "From layer…"; onTriggered: { mainDialog.close(); layerSendDialog.open() } }
                    }
                }
            }

            // ── What to show ──────────────────────────────────────────────
            RowLayout {                             // one row; Accuracy circles: Settings → Advanced
                Layout.fillWidth: true
                spacing: 0
                ShowBox { text: "Markers";   checked: cfg.showMarkers;   onToggled: cfg.showMarkers   = checked }
                ShowBox { text: "Labels";    checked: cfg.showLabels;    onToggled: cfg.showLabels    = checked }
                ShowBox { text: "Tracks";    checked: cfg.showTrails;    onToggled: cfg.showTrails    = checked }
                ShowBox { text: "Geofences"; checked: cfg.showGeofences; onToggled: cfg.showGeofences = checked }
                Item { Layout.fillWidth: true }
            }

            // ── Devices | Geofences tabs ──────────────────────────────────
            TabBar {
                id: listTabs
                Layout.fillWidth: true
                TabButton {
                    text: "Devices" + (plugin.deviceRows.length > 0 ? " (" + plugin.deviceRows.length + ")" : "")
                }
                TabButton {
                    text: "Geofences" + (plugin.geofences.length > 0 ? " (" + plugin.geofences.length + ")" : "")
                }
            }
            StackLayout {
                Layout.fillWidth:  true
                Layout.fillHeight: true
                Layout.minimumHeight: 100
                currentIndex: listTabs.currentIndex

                // ── Devices ───────────────────────────────────────────────
                ColumnLayout {
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        ShowBox {
                            id: allDevicesBox
                            property int nShown: plugin.deviceRows.filter(function(r) { return r.shown }).length
                            Layout.fillWidth: true
                            font.bold: true
                            text: "Devices  (" + (nShown === plugin.deviceRows.length ? nShown
                                                  : nShown + " of " + plugin.deviceRows.length + " shown") + ")"
                            enabled: plugin.deviceRows.length > 0
                            checkState: nShown === 0 ? Qt.Unchecked
                                      : nShown === plugin.deviceRows.length ? Qt.Checked : Qt.PartiallyChecked
                            nextCheckState: function() { return nShown === plugin.deviceRows.length ? Qt.Unchecked : Qt.Checked }
                            onClicked: plugin.setAllShown(checkState === Qt.Checked)
                        }
                        Label {
                            visible: plugin.lastFetched !== ""
                            text: "updated " + plugin.lastFetched
                            font.pixelSize: 11
                            color: Theme.secondaryTextColor
                        }
                        DetailsButton { kind: "device" }
                    }
                    ListView {
                        Layout.fillWidth:  true
                        Layout.fillHeight: true
                        clip:  true
                        model: plugin.deviceRows
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Rectangle {
                            width:  ListView.view.width
                            height: Math.max(44, devCol.implicitHeight + 12)
                            color:  index % 2 === 0 ? "#F5F5F5" : "white"
                            property var row: modelData

                            RowLayout {
                                anchors { fill: parent; leftMargin: 0; rightMargin: 4 }
                                spacing: 4
                                ShowBox {
                                    checked: row.shown
                                    onToggled: plugin.setDeviceShown(row.id, checked)
                                }
                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    color: row.color
                                    opacity: row.shown ? 1 : 0.4
                                }
                                ColumnLayout {
                                    id: devCol
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 4
                                    spacing: 1
                                    opacity: row.shown ? 1 : 0.5
                                    Label {
                                        text: row.name
                                        font.bold: true
                                        font.pixelSize: 14
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        text: plugin.deviceLine(row)
                                        visible: text !== ""
                                        font.pixelSize: 11
                                        color: "#555"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        visible: row.pos !== null && plugin.detailShown("device", "location")
                                        text: { cfg.locationFormat; return row.pos ? _locationText(row.pos) : "" }
                                        font.pixelSize: 11
                                        color: "#1565C0"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }
                                RowButton {
                                    visible: row.pos !== null
                                    icon.source: "icons/copy.svg"
                                    onClicked: {
                                        var loc = _locationText(row.pos)
                                        copyToClipboard(loc)
                                        mainWindow.displayToast(row.name + ": " + loc + " copied")
                                    }
                                }
                                RowButton {
                                    visible: row.pos !== null
                                    icon.source: "icons/locate.svg"
                                    onClicked: { zoomToDevice(row.pos); mainDialog.close() }
                                }
                                RowButton {
                                    visible: row.sent             // only points added with Send point (qgis-…)
                                    icon.source: "icons/delete.svg"
                                    onClicked: plugin.confirm("Delete '" + row.name + "' from Traccar?\n\nIt disappears "
                                                              + "for everyone, with all its positions. This can't be undone.",
                                                              function() { plugin.deleteSentPoint(row.id) })
                                }
                            }
                        }
                    }
                }

                // ── Geofences ─────────────────────────────────────────────
                ColumnLayout {
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        ShowBox {
                            id: allGeofencesBox
                            enabled: cfg.showGeofences && plugin.geofences.length > 0
                            property int nShown: { var h = plugin._gfHiddenIds()
                                                   return plugin.geofences.filter(function(g) { return !h[String(g.id)] }).length }
                            Layout.fillWidth: true
                            font.bold: true
                            text: "Geofences  (" + (nShown === plugin.geofences.length ? nShown
                                                    : nShown + " of " + plugin.geofences.length + " shown") + ")"
                            checkState: nShown === 0 ? Qt.Unchecked
                                      : nShown === plugin.geofences.length ? Qt.Checked : Qt.PartiallyChecked
                            nextCheckState: function() { return nShown === plugin.geofences.length ? Qt.Unchecked : Qt.Checked }
                            onClicked: plugin.setAllGeofencesShown(checkState === Qt.Checked)
                        }
                        DetailsButton { kind: "geofence" }
                    }
                    Hint {
                        visible: plugin.geofences.length === 0
                        text: "No geofences in Traccar yet — add one with Add → Area, Line or Circle."
                    }
                    ListView {
                        id: geofenceList
                        enabled: cfg.showGeofences
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip:  true
                        model: plugin.geofences
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Rectangle {
                            width:  ListView.view.width
                            height: Math.max(44, gfCol.implicitHeight + 12)
                            color:  index % 2 === 0 ? "#F5F5F5" : "white"
                            property var g: modelData
                            property bool shown: { cfg.hiddenGeofences; return !plugin._gfHiddenIds()[String(g.id)] }

                            RowLayout {
                                anchors { fill: parent; leftMargin: 0; rightMargin: 4 }
                                spacing: 4
                                ShowBox {
                                    checked: shown
                                    onToggled: plugin.setGeofenceShown(g.id, checked)
                                }
                                Rectangle {                         // tap: change the colour
                                    width: 18; height: 18; radius: 4
                                    color: g.color
                                    opacity: shown ? 1 : 0.4
                                    MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: colorMenu.openFor(g) }
                                }
                                ColumnLayout {
                                    id: gfCol
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 4
                                    spacing: 1
                                    opacity: shown ? 1 : 0.5
                                    Label {
                                        text: g.name || "(no name)"
                                        font.bold: true
                                        font.pixelSize: 14
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        text: plugin.geofenceLine(g)
                                        visible: text !== ""
                                        font.pixelSize: 11
                                        color: "#555"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        visible: g.description !== "" && plugin.detailShown("geofence", "description")
                                        text: g.description
                                        font.pixelSize: 11
                                        color: "#1565C0"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }
                                RowButton {
                                    icon.source: "icons/locate.svg"
                                    onClicked: { plugin.zoomToGeofence(g.id); mainDialog.close() }
                                }
                                RowButton {
                                    icon.source: "icons/edit.svg"
                                    onClicked: plugin.editGeofence(g.id)
                                }
                                RowButton {
                                    icon.source: "icons/delete.svg"
                                    onClicked: plugin.confirm("Delete the geofence '" + g.name + "' from Traccar?\n\n"
                                                              + (g.mine ? "" : "It was made in Traccar, not sent from QGIS or "
                                                                               + "QField — Traccar alerts may use it.\n\n")
                                                              + "It disappears for everyone. This can't be undone.",
                                                              function() { plugin.deleteGeofence(g.id) })
                                }
                            }
                        }
                    }
                }
            }

            // ── Save ──────────────────────────────────────────────────────
            Label {
                visible:          plugin.writeQueue.length > 0
                text:             "Waiting for QFieldCloud sync to finish before saving…"
                font.pixelSize:   12
                color:            "#E65100"
                wrapMode:         Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    Layout.fillWidth: true
                    text: "Save positions"
                    icon.source: "icons/point.svg"
                    onClicked: savePositions()
                }
                Button {
                    Layout.fillWidth: true
                    text: "Save tracks"
                    icon.source: "icons/track.svg"
                    onClicked: saveTracks()
                }
            }
            Label {
                Layout.fillWidth: true
                text: plugin.savesToText()
                wrapMode: Text.WordWrap
                font.pixelSize: 11
                color: (cfg.pointsLayerName === "" && cfg.tracksLayerName === "")
                       ? "#B71C1C" : Theme.secondaryTextColor
                MouseArea { anchors.fill: parent; onClicked: openSettings("layers") }
            }
        }
    }

    function _windowIndex(minutes) {
        for (var i = 0; i < windowModel.count; i++)
            if (windowModel.get(i).minutes === minutes) return i
        return 2   // Last 1 hour
    }

    function _refreshFeatureCombo() {
        populateEventFeatures()
        eventFeatureCombo.currentIndex = 0
        for (var i = 0; i < eventFeatureModel.count; i++) {
            if (eventFeatureModel.get(i).fid === cfg.eventFeatureFid) {
                eventFeatureCombo.currentIndex = i
                break
            }
        }
        var f = eventFeatureModel.get(eventFeatureCombo.currentIndex)
        if (f) cfg.eventFeatureFid = f.fid
    }

    function isConnected() {
        return cfg.username !== "" && cfg.serverUrl !== ""
               && plugin.connState !== "wrong username or password"
    }

    function savesToText() {
        if (cfg.pointsLayerName === "" && cfg.tracksLayerName === "")
            return "No layers chosen to save to — tap here"
        var parts = []
        if (cfg.pointsLayerName !== "")
            parts.push("Positions → " + cfg.pointsLayerName
                       + (cfg.pointsMode === 1 ? " (every fix)" : " (latest fix)"))
        if (cfg.tracksLayerName !== "")
            parts.push("Tracks → " + cfg.tracksLayerName
                       + (cfg.trackMode === 1 ? " (keep most recent)" : " (add new)"))
        return parts.join("   ·   ") + "   ›"
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELP DIALOG
    // ════════════════════════════════════════════════════════════════════════
    // ════════════════════════════════════════════════════════════════════════
    //  ADD / CHANGE / DELETE IN TRACCAR — dialogs and the drawing bar
    // ════════════════════════════════════════════════════════════════════════

    // Yes / No before anything is deleted
    function confirm(text, action) {
        confirmDialog.text   = text
        confirmDialog.action = action
        confirmDialog.open()
    }

    Dialog {
        id:      confirmDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 12
        width:   Math.min(mainWindow.width * 0.9, 380)
        x:       (mainWindow.width - width) / 2
        y:       (mainWindow.height - height) / 2
        z:       10
        property string text: ""
        property var    action: null
        ColumnLayout {
            width: parent.width
            spacing: 12
            Label { text: confirmDialog.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; flat: true; onClicked: confirmDialog.close() }
                Button {
                    text: "Delete"
                    onClicked: {
                        var a = confirmDialog.action
                        confirmDialog.action = null
                        confirmDialog.close()
                        if (a) a()
                    }
                }
            }
        }
    }

    // ── Detail lines in the lists: chosen with ⋮ (remembered) ────────────
    readonly property var detailChoices: ({
        device:   [{ key: "fixes", label: "Fixes and time span" }, { key: "speed", label: "Speed" },
                   { key: "battery", label: "Battery" }, { key: "location", label: "Location" }],
        geofence: [{ key: "type", label: "Type" }, { key: "from", label: "Made in" },
                   { key: "speed", label: "Speed limit" }, { key: "description", label: "Description" }]
    })

    function detailShown(kind, key) {
        var hidden = kind === "device" ? cfg.deviceDetailsHidden : cfg.geofenceDetailsHidden
        return hidden.split(",").indexOf(key) < 0
    }

    function setDetailShown(kind, key, on) {
        var list = (kind === "device" ? cfg.deviceDetailsHidden : cfg.geofenceDetailsHidden)
                   .split(",").filter(function(k) { return k !== "" && k !== key })
        if (!on) list.push(key)
        if (kind === "device") cfg.deviceDetailsHidden = list.join(",")
        else                   cfg.geofenceDetailsHidden = list.join(",")
    }

    function deviceLine(row) {
        cfg.deviceDetailsHidden
        var p = row.parts || {}, out = []
        if (detailShown("device", "fixes") && p.fixes)     out.push(p.fixes)
        if (detailShown("device", "speed") && p.speed)     out.push(p.speed)
        if (detailShown("device", "battery") && p.battery) out.push(p.battery)
        return out.join("  ·  ")
    }

    function geofenceLine(g) {
        cfg.geofenceDetailsHidden
        var out = []
        if (detailShown("geofence", "type")) out.push(geofenceType(g))
        if (detailShown("geofence", "from")) out.push("from " + (g.mine ? "QGIS / QField" : "Traccar"))
        if (detailShown("geofence", "speed") && g.speedKmh) out.push("limit " + g.speedKmh + " km/h")
        return out.join("  ·  ")
    }

    component DetailsButton: ToolButton {
        property string kind: "device"
        text: "⋮"
        font.pixelSize: 18
        implicitWidth: 34
        background: Item {}
        onClicked: { detailsMenu.kind = kind; detailsMenu.open() }
    }

    Popup {
        id: detailsMenu
        parent: mainWindow.contentItem
        modal:  true
        padding: 10
        x: (mainWindow.width - width) / 2
        y: (mainWindow.height - height) / 2
        z: 10
        background: DialogBackground {}
        property string kind: "device"
        ColumnLayout {
            spacing: 0
            Label { text: "Show in the list"; font.bold: true; Layout.bottomMargin: 4 }
            Repeater {
                model: plugin.detailChoices[detailsMenu.kind]
                delegate: CheckBox {
                    text: modelData.label
                    checked: { cfg.deviceDetailsHidden; cfg.geofenceDetailsHidden
                               return plugin.detailShown(detailsMenu.kind, modelData.key) }
                    onToggled: plugin.setDetailShown(detailsMenu.kind, modelData.key, checked)
                }
            }
        }
    }

    // Tap a geofence's colour in the list → pick another (saved in Traccar)
    Popup {
        id: colorMenu
        parent: mainWindow.contentItem
        modal:  true
        padding: 8
        x: (mainWindow.width - width) / 2
        y: (mainWindow.height - height) / 2
        z: 10
        background: DialogBackground {}
        property var g: null
        function openFor(geofence) { g = geofence; open() }
        Flow {
            width: 5 * 40
            spacing: 4
            Repeater {
                model: plugin.swatches
                delegate: Rectangle {
                    width: 36; height: 36; radius: 6
                    color: modelData
                    border.width: colorMenu.g && colorMenu.g.color === modelData ? 3 : 0
                    border.color: "black"
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { var g = colorMenu.g; colorMenu.close(); if (g) plugin.setGeofenceColor(g.id, modelData) }
                    }
                }
            }
        }
    }

    // Row of colour swatches (geofence colour, remembered)
    component SwatchRow: Flow {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: plugin.swatches
            delegate: Rectangle {
                width: 30; height: 30; radius: 6
                color: modelData
                border.width: cfg.geofenceColor === modelData ? 3 : 0
                border.color: "black"
                MouseArea { anchors.fill: parent; onClicked: cfg.geofenceColor = modelData }
            }
        }
    }

    // ── Bar at the top of the map while drawing ───────────────────────────
    Rectangle {
        id: drawBar
        parent:  mainWindow.contentItem
        visible: plugin.drawMode !== "" && !sendDialog.visible
        z:       5
        x:       8
        y:       plugin.topInset + 8
        width:   mainWindow.width - 16
        height:  drawCol.implicitHeight + 16
        radius:  plugin.cornerRadius
        color:   "#F2FFFFFF"
        border.color: Theme.mainColor
        ColumnLayout {
            id: drawCol
            anchors { fill: parent; margins: 8 }
            spacing: 4
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.bold: true
                text: {
                    var n = plugin.drawPts.length
                    if (plugin.drawMode === "point")  return "Tap the map where the point goes"
                    if (plugin.drawMode === "circle") return "Tap the map at the centre of the circle"
                    var what = plugin.drawMode === "area" ? "area" : "line"
                    return n === 0 ? "Tap the map at each corner of the " + what
                                   : n + " corner" + (n === 1 ? "" : "s") + " — tap the next, then Done"
                }
            }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Button {
                    text: "My location"
                    flat: true
                    enabled: plugin.gpsLonLat() !== null
                    onClicked: plugin.addDrawPoint(plugin.gpsLonLat())
                }
                Button {
                    visible: plugin.drawMode === "area" || plugin.drawMode === "line"
                    text: "Undo"
                    flat: true
                    enabled: plugin.drawPts.length > 0
                    onClicked: plugin.undoDraw()
                }
                Button {
                    visible: plugin.drawMode === "area" || plugin.drawMode === "line"
                    text: "Done"
                    enabled: plugin.canFinishDraw()
                    onClicked: plugin.finishDraw()
                }
                Button { text: "Cancel"; flat: true; onClicked: plugin.cancelDraw() }
            }
        }
    }

    // ── Name and Traccar's fields, then send (same form as the QGIS plugin) ──
    Dialog {
        id:      sendDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 12
        width:   Math.min(mainWindow.width * 0.93, 420)
        height:  Math.min(mainWindow.height - plugin.topInset - plugin.bottomInset - 24, sendCol.implicitHeight + 90)
        x:       (mainWindow.width - width) / 2
        y:       plugin.topInset + 12
        property string mode: "point"     // point, circle, area, line
        property var    coords: []
        property bool   sent: false
        property var    editG: null       // a geofence being edited (from plugin.geofences), else null
        property string keepColor: ""     // colour for new geofences, put back after an edit
        property alias  nameText:        sendName.text
        property alias  descriptionText: sendDescription.text
        property alias  speedValue:      sendSpeed.value
        property alias  corridorValue:   sendCorridor.value
        property alias  calendarIndex:   sendCalendar.currentIndex
        property alias  uidText:         sendUid.text
        property alias  categoryIndex:   sendCategory.currentIndex
        property alias  groupIndex:      sendGroup.currentIndex
        property alias  phoneText:       sendPhone.text
        property alias  modelText:       sendModel.text
        property alias  contactText:     sendContact.text
        readonly property bool point: mode === "point"

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text: sendDialog.editG ? "Edit geofence"
                          : sendDialog.point ? "Send point" : "Send "
                          + ({ circle: "circle", area: "area", line: "line" })[sendDialog.mode] + " as a geofence"
                    color: "white"; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true
                }
                HeaderButton { icon.source: "icons/close.svg"; onClicked: sendDialog.close() }
            }
        }

        onOpened: sendName.forceActiveFocus()
        // Filled in as it opens (onOpened waits for the opening animation)
        onAboutToShow: {
            sent = false
            sendName.text = point ? cfg.lastSendName : ""
            sendRadius.value = cfg.circleRadius
            sendDescription.text = ""; sendSpeed.value = 0; sendCorridor.value = 0; sendCalendar.currentIndex = 0
            sendUid.text = ""; sendCategory.currentIndex = 0; sendGroup.currentIndex = 0
            sendPhone.text = ""; sendModel.text = ""; sendContact.text = ""
            if (editG) fillEdit(editG)
            sendScroll.ScrollBar.vertical.position = 0
        }
        // Closed without sending (Cancel / ✕): back to drawing — tap again, or the corners kept
        onClosed: {
            if (!editG && !sent && (mode === "point" || mode === "circle")) plugin.drawPts = []
            if (editG) { editG = null; cfg.geofenceColor = keepColor; mainDialog.open() }
        }

        // Edit: the geofence's current values into the form
        function fillEdit(g) {
            var raw = g.raw || {}, attrs = raw.attributes || {}
            sendName.text = g.name
            sendDescription.text = raw.description || ""
            sendSpeed.value = attrs.speedLimit ? Math.round(attrs.speedLimit * 1.852) : 0
            sendCorridor.value = attrs.polylineDistance ? Math.round(attrs.polylineDistance) : 0
            sendCalendar.currentIndex = 0
            for (var i = 0; i < plugin.calendars.length; i++)
                if (plugin.calendars[i].id === raw.calendarId) sendCalendar.currentIndex = i + 1
            if (g.kind === "circle") sendRadius.value = Math.round(g.radius)
            keepColor = cfg.geofenceColor
            cfg.geofenceColor = g.color
        }

        function send() {
            var name = sendName.text.trim()
            if (name === "") { mainWindow.displayToast("Give it a name first"); return }
            var extra = point ? null : plugin.geofenceExtra({
                color: cfg.geofenceColor, description: sendDescription.text.trim(), speedKmh: sendSpeed.value,
                corridorM: mode === "line" ? sendCorridor.value : 0,
                calendarId: sendCalendar.currentIndex > 0 ? plugin.calendars[sendCalendar.currentIndex - 1].id : 0 })
            if (editG) {
                plugin.updateGeofence(editG, name, extra, mode === "circle" ? sendRadius.value : 0)
                sent = true
                close()
                return
            }
            if (point) {
                cfg.lastSendName = name
                plugin.sendPoint(name, coords[0].lon, coords[0].lat, null, {
                    uniqueId: sendUid.text.trim(), category: plugin.deviceCategories[sendCategory.currentIndex],
                    groupId: sendGroup.currentIndex > 0 ? plugin.groups[sendGroup.currentIndex - 1].id : 0,
                    phone: sendPhone.text.trim(), model: sendModel.text.trim(), contact: sendContact.text.trim() })
            } else {
                cfg.circleRadius = sendRadius.value
                var a = plugin.areaText(mode === "area" ? "polygon" : mode, coords, sendRadius.value)
                if (!a) { mainWindow.displayToast("Not enough corners"); return }
                plugin.upsertGeofences([{ name: name, area: a.area }], cfg.geofenceColor, extra)
            }
            sent = true
            plugin.cancelDraw()
            close()
        }

        ScrollView {
            id: sendScroll
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                id: sendCol
                width: sendScroll.availableWidth
                spacing: 6
                Hint {
                    text: sendDialog.coords.length === 0 ? ""
                          : sendDialog.mode === "point" || sendDialog.mode === "circle"
                            ? (sendDialog.mode === "circle" ? "Centre: " : "At: ")
                              + plugin._locationText({ latitude: sendDialog.coords[0].lat, longitude: sendDialog.coords[0].lon })
                            : sendDialog.coords.length + " corners"
                }
                Label { text: "Name" }
                TextField {
                    id: sendName
                    Layout.fillWidth: true
                    placeholderText: sendDialog.point ? "e.g. Team 2 or Clue 4" : "e.g. Sector A"
                    onAccepted: sendDialog.send()
                }
                Hint {
                    visible: sendDialog.point
                    text: "A new name adds a new point (device) in Traccar; the name of an existing device moves it here. "
                          + "The details below are for a new point."
                }
                Hint {
                    visible: !sendDialog.point && !sendDialog.editG
                    text: "A geofence sent from QGIS or QField before with the same name is replaced."
                }

                // ── A new point (device) ──
                GridLayout {
                    visible: sendDialog.point
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8
                    Label { text: "Identifier" }
                    TextField { id: sendUid; Layout.fillWidth: true; placeholderText: "made from the name (qgis-…)"
                                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText }
                    Label { text: "Category" }
                    ComboBox {
                        id: sendCategory
                        Layout.fillWidth: true
                        model: plugin.deviceCategories.map(function(c) { return c.charAt(0).toUpperCase() + c.substr(1) })
                    }
                    Label { text: "Group" }
                    ComboBox {
                        id: sendGroup
                        Layout.fillWidth: true
                        model: ["— none —"].concat(plugin.groups.map(function(g) { return g.name || String(g.id) }))
                    }
                    Label { text: "Phone" }
                    TextField { id: sendPhone; Layout.fillWidth: true; inputMethodHints: Qt.ImhDialableCharactersOnly }
                    Label { text: "Model" }
                    TextField { id: sendModel; Layout.fillWidth: true }
                    Label { text: "Contact" }
                    TextField { id: sendContact; Layout.fillWidth: true }
                }

                // ── A geofence ──
                GridLayout {
                    visible: !sendDialog.point
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8
                    Label { text: "Description" }
                    TextField { id: sendDescription; Layout.fillWidth: true }
                    Label { visible: sendDialog.mode === "circle"; text: "Radius (m)" }
                    SpinBox {
                        id: sendRadius
                        visible: sendDialog.mode === "circle"
                        from: 10; to: 100000; stepSize: 50; editable: true
                        Layout.fillWidth: true
                    }
                    Item { visible: sendDialog.mode === "circle"; width: 1; height: 1 }
                    Flow {
                        visible: sendDialog.mode === "circle"
                        Layout.fillWidth: true
                        spacing: 4
                        Repeater {
                            model: [250, 500, 1000]
                            delegate: Button { text: modelData + " m"; flat: true; onClicked: sendRadius.value = modelData }
                        }
                    }
                    Label { visible: sendDialog.mode === "line"; text: "Corridor (m)" }
                    SpinBox {
                        id: sendCorridor
                        visible: sendDialog.mode === "line"
                        from: 0; to: 10000; stepSize: 5; editable: true
                        Layout.fillWidth: true
                        textFromValue: function(v) { return v === 0 ? "default" : String(v) }
                        valueFromText: function(t) { var n = parseInt(t); return isNaN(n) ? 0 : n }
                    }
                    Label { text: "Speed limit (km/h)" }
                    SpinBox {
                        id: sendSpeed
                        from: 0; to: 1000; stepSize: 5; editable: true
                        Layout.fillWidth: true
                        textFromValue: function(v) { return v === 0 ? "none" : String(v) }
                        valueFromText: function(t) { var n = parseInt(t); return isNaN(n) ? 0 : n }
                    }
                    Label { text: "Calendar" }
                    ComboBox {
                        id: sendCalendar
                        Layout.fillWidth: true
                        model: ["— always active —"].concat(plugin.calendars.map(function(c) { return c.name || String(c.id) }))
                    }
                }
                Hint {
                    visible: !sendDialog.point
                    text: (sendDialog.mode === "line" ? "Corridor: how close to the line a device must be to count as on it. " : "")
                          + "Speed limit: Traccar warns when a device goes faster inside. Calendar: active only at those times."
                }
                Label { visible: !sendDialog.point; text: "Colour" }
                SwatchRow { visible: !sendDialog.point }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    Item { Layout.fillWidth: true }
                    Button { text: "Cancel"; flat: true; onClicked: sendDialog.close() }
                    Button { text: sendDialog.editG ? "Save to Traccar" : "Send to Traccar"; onClicked: sendDialog.send() }
                }
            }
        }
    }

    // ── Send a layer's features ───────────────────────────────────────────
    ListModel { id: sendLayerModel }     // layers with points, lines or polygons
    ListModel { id: sendFieldModel }     // fields of that layer (name from)
    ListModel { id: sendFeatureModel }   // "All features" + each feature

    Dialog {
        id:      layerSendDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 10
        width:   plugin.phone ? mainWindow.width * 0.93 : Math.min(mainWindow.width * 0.84, 428)
        height:  Math.min(mainWindow.height - plugin.topInset - plugin.bottomInset - 24, 560)
        x:       (mainWindow.width - width) / 2
        y:       plugin.topInset + (mainWindow.height - plugin.topInset - plugin.bottomInset - height) / 2
        property string layerName: ""
        property int    geomType: -1

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                HeaderButton { icon.source: "icons/back.svg"; onClicked: layerSendDialog.close() }
                Label {
                    text: "Send from a layer"
                    color: "white"; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true
                }
            }
        }
        onOpened: {
            sendLayerModel.clear()
            sendLayerModel.append({ name: "— choose a layer —", isHeader: false })
            var layers = ProjectUtils.mapLayers(qgisProject), names = []
            for (var id in layers) {
                try {
                    var t = layers[id].geometryType()
                    if (t === Qgis.GeometryType.Point || t === Qgis.GeometryType.Line || t === Qgis.GeometryType.Polygon)
                        names.push(layers[id].name)
                } catch(e) {}
            }
            names.sort(function(a, b) { return a.localeCompare(b) })
            names.forEach(function(n) { sendLayerModel.append({ name: n, isHeader: false }) })
            restoreSelection(sendLayerCombo, sendLayerModel, layerName)
            if (sendLayerCombo.currentIndex < 0) sendLayerCombo.currentIndex = 0
            layerChosen()
            sendLayerRadius.value = cfg.circleRadius
        }
        onClosed: mainDialog.open()

        function layerChosen() {
            layerName = pickedName(sendLayerCombo, sendLayerModel)
            var layers = layerName !== "" ? qgisProject.mapLayersByName(layerName) : []
            geomType = layers.length > 0 ? layers[0].geometryType() : -1
            populateEventFields(sendFieldModel, layerName)
            var fn = layers.length > 0 ? layers[0].fields.names : []
            var guess = ["name", "title", "sector", "sector_id", "incident_ref"]
            sendFieldCombo.currentIndex = 0
            sendDescCombo.currentIndex = 0
            for (var i = 0; i < guess.length && sendFieldCombo.currentIndex === 0; i++)
                if (fn.indexOf(guess[i]) >= 0) restoreSelection(sendFieldCombo, sendFieldModel, guess[i])
            if (sendFieldCombo.currentIndex < 0) sendFieldCombo.currentIndex = 0
            fillFeatures()
        }

        function fillFeatures() {
            sendFeatureModel.clear()
            var layers = layerName !== "" ? qgisProject.mapLayersByName(layerName) : []
            if (layers.length === 0) return
            var field = pickedName(sendFieldCombo, sendFieldModel)
            var rows = []
            try {
                var iter = LayerUtils.createFeatureIterator(layers[0])
                while (iter.hasNext()) {
                    var f = iter.next()
                    var v = field !== "" ? f.attribute(field) : null
                    rows.push({ label: (v !== null && v !== undefined && String(v) !== "") ? String(v) : "#" + f.id, fid: f.id })
                }
                iter.close()
            } catch(e) {}
            sendFeatureModel.append({ label: "All " + rows.length + " feature(s)", fid: -1 })
            rows.forEach(function(r) { sendFeatureModel.append(r) })
            sendFeatureCombo.currentIndex = 0
        }

        ScrollView {
            id: layerSendScroll
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: layerSendScroll.availableWidth
                spacing: 6
                Hint { text: "Areas and lines become geofences in Traccar; points become circles or points (devices)." }
                Label { text: "Layer" }
                PickCombo {
                    id: sendLayerCombo
                    model: sendLayerModel
                    onActivated: layerSendDialog.layerChosen()
                }
                Label { text: "Name from field" }
                PickCombo {
                    id: sendFieldCombo
                    model: sendFieldModel
                    onActivated: layerSendDialog.fillFeatures()
                }
                Label { text: "… or name (numbered if several)" }
                TextField { id: sendLayerName; Layout.fillWidth: true; placeholderText: "the layer's name" }
                Label { text: "Description from field" }
                PickCombo {
                    id: sendDescCombo
                    model: sendFieldModel
                }
                Label { text: "Features" }
                ComboBox {
                    id: sendFeatureCombo
                    Layout.fillWidth: true
                    model: sendFeatureModel
                    textRole: "label"
                }
                ColumnLayout {
                    visible: layerSendDialog.geomType === Qgis.GeometryType.Point
                    Layout.fillWidth: true
                    spacing: 2
                    RadioButton { id: asCircles; text: "As circles (geofences)"; checked: true }
                    RadioButton { id: asPoints;  text: "As points (devices)" }
                    RowLayout {
                        visible: asCircles.checked
                        Label { text: "Radius" }
                        SpinBox { id: sendLayerRadius; from: 10; to: 100000; stepSize: 50; editable: true }
                        Label { text: "m" }
                    }
                }
                Label { visible: !(layerSendDialog.geomType === Qgis.GeometryType.Point && asPoints.checked); text: "Colour" }
                SwatchRow { visible: !(layerSendDialog.geomType === Qgis.GeometryType.Point && asPoints.checked) }
                Button {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    text: "Send to Traccar"
                    enabled: layerSendDialog.layerName !== ""
                    onClicked: {
                        var pt = layerSendDialog.geomType === Qgis.GeometryType.Point
                        if (pt && asCircles.checked) cfg.circleRadius = sendLayerRadius.value
                        var fid = sendFeatureCombo.currentIndex > 0 ? sendFeatureModel.get(sendFeatureCombo.currentIndex).fid : -1
                        plugin.sendLayer(layerSendDialog.layerName, fid, pickedName(sendFieldCombo, sendFieldModel),
                                         sendLayerName.text.trim(), sendLayerRadius.value, cfg.geofenceColor,
                                         pt && asPoints.checked, pickedName(sendDescCombo, sendFieldModel))
                        layerSendDialog.close()
                    }
                }
            }
        }
    }

    Dialog {
        id:      helpDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 10
        width:   plugin.phone ? mainWindow.width : Math.min(mainWindow.width * 0.9, 460)
        height:  plugin.phone ? mainWindow.height - plugin.topInset - plugin.bottomInset
                              : Math.min(mainWindow.height * 0.9, 780)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset : (mainWindow.height - height) / 2

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                HeaderButton {
                    icon.source: "icons/back.svg"
                    onClicked: helpDialog.close()
                }
                Label {
                    text: "Help"
                    color: "white"; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true
                }
            }
        }
        onClosed: mainDialog.open()

        ScrollView {
            id: helpScroll
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   helpScroll.availableWidth
                spacing: 6

                Label { text: "Getting started"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "1. Settings → Connection: enter your Traccar server and account, tap Test.\n" +
                          "2. Choose a time window and tap Live (or the refresh button to load it once).\n" +
                          "3. To keep what you see, pick layers in Settings → Layers and use the Save buttons."
                }

                Label { text: "Time window"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "One window controls everything: the tracks on the map are the fixes inside it, " +
                          "and the Save buttons save exactly that.\n" +
                          "• Last 15 min … Last 3 months — follows the current time.\n" +
                          "• Custom dates — enter From / To in local time, tap Show this window.\n" +
                          "• From feature — use the start/end times of a feature (e.g. an incident). " +
                          "Set the layer up once in Settings → Advanced.\n" +
                          "Each device row shows how many fixes it has in the window and their time span."
                }

                Label { text: "Live, Refresh and Clear"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Live refreshes every few seconds and keeps a 'Last …' window moving. " +
                          "A window that ends in the past cannot change, so Live pauses for it and markers " +
                          "show each device's last fix in that window.\n" +
                          "Refresh loads the window once.  Clear removes everything from the map.\n" +
                          "Nothing is written to your project until you tap a Save button."
                }

                Label { text: "On the map"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Each device has its own colour (the same as in the QGIS plugin Traccar Live); its " +
                          "marker and track turn grey when the last fix is older than the limit in Settings → Advanced. " +
                          "Tap a marker for name, fix age, speed and battery. " +
                          "Markers, Labels, Tracks and Geofences can each be switched on or off (GPS accuracy circles: " +
                          "Settings → Advanced).\n" +
                          "In the device list, untick a device to hide it from the map and leave it out of the " +
                          "Save buttons (remembered); the tick next to 'Devices' shows or hides them all. " +
                          "The target button centres the map on a device and the copy button copies its location — " +
                          "lat / long, degrees + minutes, Irish Grid, UK Grid or the project CRS (Settings → Advanced)."
                }

                Label { text: "Geofences and points in Traccar"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Traccar's geofences (areas, lines, circles) are drawn on the map in their own colour, " +
                          "with their names — they never go grey. Tick Geofences under Show to switch them all on " +
                          "or off; in the Geofences tab, untick one to hide it, tap its colour to change it " +
                          "(saved in Traccar), the pencil to edit its name, description, speed limit, corridor, " +
                          "calendar or radius, the target to centre the map on it, or the bin to delete it from " +
                          "Traccar (you're asked first). ⋮ on either tab chooses which details its list shows.\n" +
                          "Add (next to Clear) → Point / Circle: tap the map (or 'My location'), give a name. A point becomes a " +
                          "device in Traccar — a new name adds one, an existing device's name moves it there; for a " +
                          "new one you can set its identifier, category (icon), group, phone, model and contact. " +
                          "Points added this way can be deleted from the device list.\n" +
                          "Add → Area / Line: tap each corner, then Done. Geofences get a name, description, speed " +
                          "limit (Traccar warns when a device goes faster inside), corridor width for a line, a " +
                          "Traccar calendar (active only at those times) and a colour.\n" +
                          "Add → From layer: send a layer's features (all or one), named from a field — areas and " +
                          "lines become geofences, points become circles or points.\n" +
                          "Sending a geofence with the same name as one sent from QGIS or QField before replaces " +
                          "it. Adding and deleting needs a Traccar account that is allowed to change them."
                }

                Label { text: "Saving"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Only ticked devices are saved.\n" +
                          "Save positions — adds a point per device: its latest fix, or every fix in the " +
                          "window (Settings → Layers).\n" +
                          "Save tracks — adds one line per device for the window, or replaces that " +
                          "device's previous track if 'Keep most recent' is chosen.\n" +
                          "Fields are filled by name (device_id, name, fix_time, speed_kmh, battery, " +
                          "start_time, last_update, …); fields your layer doesn't have are skipped. " +
                          "You can also send the device name to any text field, e.g. 'title'.\n" +
                          "If QFieldCloud is syncing, the save waits and runs when it finishes."
                }

                Label { text: "Times"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Everything here is shown in your phone's local time, including summer time. " +
                          "Saved date/time fields are stored in UTC (QField forms show them as local time; " +
                          "QGIS desktop shows UTC). Optional text fields fix_local / start_local / last_local " +
                          "hold the local time as text."
                }

                Label { text: "Session tag"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Settings → Tag stamps a text such as FIRE-2026-001 onto everything you save. " +
                          "With 'From feature', the feature's display value can be used as the tag instead."
                }

                Label { text: "About"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Not an official Traccar product. Traccar Live is an independent, community-made " +
                          "plugin; it is not made, endorsed or supported by Traccar or its developers, and is not " +
                          "affiliated with them.\n" +
                          "Traccar (www.traccar.org) is open-source GPS tracking software created by Anton Tananaev " +
                          "and its contributors — all credit for Traccar (the server, apps, API and documentation) " +
                          "goes to them. This plugin only connects to a Traccar server you have access to, through " +
                          "the interfaces Traccar publishes."
                }
                Item { height: 8 }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SETTINGS DIALOG  — list of pages; every change applies immediately
    // ════════════════════════════════════════════════════════════════════════

    function openSettings(page) {
        mainDialog.close()
        settingsDialog.page = page
        settingsDialog.open()
    }

    Dialog {
        id:      settingsDialog
        background: DialogBackground {}
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 10
        width:   plugin.phone ? mainWindow.width * 0.93 : Math.min(mainWindow.width * 0.84, 428)
        height:  plugin.phone ? (mainWindow.height - plugin.topInset - plugin.bottomInset) * 0.7
                              : Math.min(mainWindow.height * 0.63, 550)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset + (mainWindow.height - plugin.topInset - plugin.bottomInset - height) / 2
                              : (mainWindow.height - height) / 2

        property string page: ""   // "" = list, "connection", "layers", "tag", "advanced"

        readonly property var titles: ({ "": "Settings", "connection": "Connection",
                                         "layers": "Layers", "tag": "Tag", "advanced": "Advanced" })

        header: HeaderBar {
            RowLayout {
                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                HeaderButton {
                    icon.source: "icons/back.svg"
                    onClicked: {
                        settingsDialog.commitText()
                        if (settingsDialog.page !== "") settingsDialog.page = ""
                        else                            settingsDialog.close()
                    }
                }
                Label {
                    text: settingsDialog.titles[settingsDialog.page]
                    color: "white"; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true
                }
                HeaderButton {
                    icon.source: "icons/close.svg"
                    onClicked: settingsDialog.close()
                }
            }
        }

        onOpened: loadControls()
        onPageChanged: if (visible) loadControls()
        onClosed: {
            commitText()
            mainDialog.open()
        }

        // Text fields apply when editing finishes; this catches a field still being edited
        function commitText() {
            var url = urlField.text.trim().replace(/\/+$/, "")
            if (url !== cfg.serverUrl || userField.text.trim() !== cfg.username
                    || passField.text !== cfg.password) {
                cfg.serverUrl = url
                cfg.username  = userField.text.trim()
                cfg.password  = passField.text
                plugin.connState = ""
            }
            if (sessionTagField.text.trim() !== cfg.sessionTag) cfg.sessionTag = sessionTagField.text.trim()
            if (sendUrlField.text.trim() !== cfg.sendUrl) cfg.sendUrl = sendUrlField.text.trim()
        }

        function loadControls() {
            urlField.text        = cfg.serverUrl
            userField.text       = cfg.username
            passField.text       = cfg.password
            sessionTagField.text = cfg.sessionTag
            sendUrlField.text    = cfg.sendUrl
            if (page === "layers") {
                populateLayers(ptLayerModel, Qgis.GeometryType.Point)
                restoreSelection(pointsLayerCombo, ptLayerModel, cfg.pointsLayerName)
                if (pointsLayerCombo.currentIndex < 0) pointsLayerCombo.currentIndex = 0
                populateLayers(lnLayerModel, Qgis.GeometryType.Line)
                restoreSelection(tracksLayerCombo, lnLayerModel, cfg.tracksLayerName)
                if (tracksLayerCombo.currentIndex < 0) tracksLayerCombo.currentIndex = 0
                refreshNameFields()
            } else if (page === "tag") {
                populateFieldNames(fieldNameModel, [cfg.pointsLayerName, cfg.tracksLayerName])
                restoreSelection(tagFieldCombo, fieldNameModel, cfg.incidentRefField)
                if (tagFieldCombo.currentIndex < 0) tagFieldCombo.currentIndex = 0
            } else if (page === "advanced") {
                populateAllLayers(allLayerModel)
                restoreSelection(eventLayerCombo, allLayerModel, cfg.eventLayerName)
                if (eventLayerCombo.currentIndex < 0) eventLayerCombo.currentIndex = 0
                refreshEventFields()
            }
        }

        function refreshNameFields() {
            populateNameFields(ptNameFieldModel, cfg.pointsLayerName)
            restoreSelection(pointsNameCombo, ptNameFieldModel, cfg.pointsNameField)
            if (pointsNameCombo.currentIndex < 0) pointsNameCombo.currentIndex = 0
            populateNameFields(lnNameFieldModel, cfg.tracksLayerName)
            restoreSelection(tracksNameCombo, lnNameFieldModel, cfg.tracksNameField)
            if (tracksNameCombo.currentIndex < 0) tracksNameCombo.currentIndex = 0
        }

        function refreshEventFields() {
            populateEventFields(eventFieldModel, cfg.eventLayerName)
            restoreSelection(eventDisplayCombo, eventFieldModel, cfg.eventDisplayField)
            if (eventDisplayCombo.currentIndex < 0) eventDisplayCombo.currentIndex = 0
            restoreSelection(eventStartCombo, eventFieldModel, cfg.eventStartField)
            if (eventStartCombo.currentIndex < 0) eventStartCombo.currentIndex = 0
            restoreSelection(eventEndCombo, eventFieldModel, cfg.eventEndField)
            if (eventEndCombo.currentIndex < 0) eventEndCombo.currentIndex = 0
        }

        ScrollView {
            id: settingsScroll
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   settingsScroll.availableWidth
                spacing: 6

                // ══ List of pages ══════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === ""
                    Layout.fillWidth: true
                    spacing: 0

                    SettingsRow {
                        title:   "Connection"
                        onClicked: settingsDialog.page = "connection"
                        warn:    !plugin.isConnected() || (plugin.connState !== "" && plugin.connState !== "ok")
                        summary: {
                            var host = cfg.serverUrl.replace(/^https?:\/\//, "")
                            if (cfg.username === "") return "Not set up — tap to connect"
                            var st = plugin.connState === "ok" ? "connected"
                                   : plugin.connState === ""   ? "not tested"
                                   : "Error: " + plugin.connState
                            return host + "  ·  " + cfg.username + "  ·  " + st
                        }
                    }
                    SettingsRow {
                        title:   "Layers"
                        onClicked: settingsDialog.page = "layers"
                        warn:    cfg.pointsLayerName === "" && cfg.tracksLayerName === ""
                        summary: {
                            if (cfg.pointsLayerName === "" && cfg.tracksLayerName === "")
                                return "Nothing to save to yet"
                            var p = cfg.pointsLayerName === "" ? "—" : cfg.pointsLayerName
                                    + (cfg.pointsNameField !== "" ? " (name → " + cfg.pointsNameField + ")" : "")
                            var t = cfg.tracksLayerName === "" ? "—" : cfg.tracksLayerName
                                    + (cfg.tracksNameField !== "" ? " (name → " + cfg.tracksNameField + ")" : "")
                            return "Positions → " + p + "\nTracks → " + t
                        }
                    }
                    SettingsRow {
                        title:   "Tag"
                        onClicked: settingsDialog.page = "tag"
                        summary: !cfg.incidentRefEnabled ? "Off"
                                 : (cfg.sessionTag !== "" ? cfg.sessionTag : "(no text)")
                                   + " → " + (cfg.incidentRefField !== "" ? cfg.incidentRefField : "no field")
                    }
                    SettingsRow {
                        title:   "Advanced"
                        onClicked: settingsDialog.page = "advanced"
                        summary: (cfg.showButton ? "" : "Map button hidden  ·  ")
                                 + plugin._locationLabel(cfg.locationFormat) + "  ·  "
                                 + "Refresh every " + cfg.liveIntervalSec + " s  ·  grey after "
                                 + cfg.staleMinutes + " min\nFrom feature: "
                                 + (cfg.eventLayerName !== "" ? cfg.eventLayerName : "not set up")
                    }
                    Hint {
                        Layout.topMargin: 10
                        text: "Changes apply straight away."
                    }
                }

                // ══ Connection ═════════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === "connection"
                    Layout.fillWidth: true
                    spacing: 4

                    Label { text: "Server URL" }
                    TextField {
                        id: urlField
                        Layout.fillWidth: true
                        placeholderText:  "https://server.traccar.org"
                        inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                        onEditingFinished: settingsDialog.commitText()
                    }
                    Label { text: "Email / username" }
                    TextField {
                        id: userField
                        Layout.fillWidth: true
                        inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                        onEditingFinished: settingsDialog.commitText()
                    }
                    Label { text: "Password" }
                    TextField {
                        id: passField
                        Layout.fillWidth: true
                        echoMode: TextInput.Password
                        onEditingFinished: settingsDialog.commitText()
                    }
                    Button {
                        Layout.fillWidth: true
                        text: "Test connection"
                        onClicked: { settingsDialog.commitText(); testConnection() }
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: plugin.connState !== ""
                        wrapMode: Text.WordWrap
                        text: plugin.connState === "ok" ? "Connected" : "Error: " + plugin.connState
                        color: plugin.connState === "ok" ? "#2E7D32" : "#B71C1C"
                    }
                    Hint { text: "Use the same address you open in a browser for Traccar." }
                    Label { text: "Send points to"; Layout.topMargin: 8 }
                    TextField {
                        id: sendUrlField
                        Layout.fillWidth: true
                        placeholderText:  plugin.osmandUrl() !== "" ? plugin.osmandUrl() : "http://<server>:5055"
                        inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                        onEditingFinished: settingsDialog.commitText()
                    }
                    Hint {
                        text: "Points (Add → Point) go to Traccar's OsmAnd port. Leave blank for port 5055 on the "
                              + "server above; fill it in if your server uses another port or address."
                    }
                }

                // ══ Layers ═════════════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === "layers"
                    Layout.fillWidth: true
                    spacing: 4

                    Label { text: "Positions"; font.bold: true; font.pixelSize: 15 }
                    Label { text: "Layer" }
                    PickCombo {
                        id: pointsLayerCombo
                        model: ptLayerModel
                        onActivated: {
                            cfg.pointsLayerName = pickedName(pointsLayerCombo, ptLayerModel)
                            settingsDialog.refreshNameFields()
                        }
                    }
                    Label { text: "Device name goes into"; visible: cfg.pointsLayerName !== "" }
                    PickCombo {
                        id: pointsNameCombo
                        visible: cfg.pointsLayerName !== ""
                        model: ptNameFieldModel
                        onActivated: cfg.pointsNameField = pickedName(pointsNameCombo, ptNameFieldModel)
                    }
                    ButtonGroup { id: pointsModeGroup }
                    RadioButton {
                        visible: cfg.pointsLayerName !== ""
                        text: "Save the latest fix per device"
                        ButtonGroup.group: pointsModeGroup
                        checked: cfg.pointsMode === 0
                        onToggled: if (checked) cfg.pointsMode = 0
                    }
                    RadioButton {
                        visible: cfg.pointsLayerName !== ""
                        text: "Save every fix in the time window"
                        ButtonGroup.group: pointsModeGroup
                        checked: cfg.pointsMode === 1
                        onToggled: if (checked) cfg.pointsMode = 1
                    }

                    Item { height: 8 }
                    Label { text: "Tracks"; font.bold: true; font.pixelSize: 15 }
                    Label { text: "Layer" }
                    PickCombo {
                        id: tracksLayerCombo
                        model: lnLayerModel
                        onActivated: {
                            cfg.tracksLayerName = pickedName(tracksLayerCombo, lnLayerModel)
                            settingsDialog.refreshNameFields()
                        }
                    }
                    Label { text: "Device name goes into"; visible: cfg.tracksLayerName !== "" }
                    PickCombo {
                        id: tracksNameCombo
                        visible: cfg.tracksLayerName !== ""
                        model: lnNameFieldModel
                        onActivated: cfg.tracksNameField = pickedName(tracksNameCombo, lnNameFieldModel)
                    }
                    ButtonGroup { id: trackModeGroup }
                    RadioButton {
                        visible: cfg.tracksLayerName !== ""
                        text: "Add a new track each save"
                        ButtonGroup.group: trackModeGroup
                        checked: cfg.trackMode === 0
                        onToggled: if (checked) cfg.trackMode = 0
                    }
                    RadioButton {
                        visible: cfg.tracksLayerName !== ""
                        text: "Keep only the most recent track"
                        ButtonGroup.group: trackModeGroup
                        checked: cfg.trackMode === 1
                        onToggled: if (checked) cfg.trackMode = 1
                    }
                    Hint {
                        visible: cfg.tracksLayerName !== "" && cfg.trackMode === 1
                        text: "Replaces that device's earlier tracks — matched by device_id, " +
                              "or by the device name field if the layer has no device_id."
                    }
                    Item { height: 6 }
                    Hint {
                        text: "Fields are filled when the layer has them: device_id, name, fix_time, " +
                              "fix_local, speed_kmh, course, altitude_m, accuracy_m, battery, address, motion, " +
                              "fetched_at (points); start_time, last_update, start_local, last_local, " +
                              "from_time, to_time, n_points, saved_at (tracks). " +
                              "traccar_template.gpkg has them all."
                    }
                }

                // ══ Tag ════════════════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === "tag"
                    Layout.fillWidth: true
                    spacing: 4

                    Hint { text: "Stamp a text, e.g. an incident number, onto every point and track you save." }
                    CheckBox {
                        text: "Tag saved features"
                        checked: cfg.incidentRefEnabled
                        onToggled: cfg.incidentRefEnabled = checked
                    }
                    Label { text: "Tag text"; enabled: cfg.incidentRefEnabled }
                    TextField {
                        id: sessionTagField
                        Layout.fillWidth: true
                        enabled: cfg.incidentRefEnabled
                        placeholderText: "e.g. FIRE-2026-001"
                        onEditingFinished: settingsDialog.commitText()
                    }
                    Label { text: "Write it into field"; enabled: cfg.incidentRefEnabled }
                    PickCombo {
                        id: tagFieldCombo
                        enabled: cfg.incidentRefEnabled
                        model: fieldNameModel
                        onActivated: cfg.incidentRefField = pickedName(tagFieldCombo, fieldNameModel)
                    }
                    CheckBox {
                        id: displayTagCheck
                        enabled: cfg.incidentRefEnabled
                        text: "With 'From feature', use the feature's display value instead"
                        checked: cfg.useDisplayAsTag
                        onToggled: cfg.useDisplayAsTag = checked
                        contentItem: Label {
                            leftPadding: displayTagCheck.indicator.width + displayTagCheck.spacing
                            text: displayTagCheck.text
                            wrapMode: Text.WordWrap
                            verticalAlignment: Text.AlignVCenter
                        }
                        Layout.fillWidth: true
                    }
                }

                // ══ Advanced ═══════════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === "advanced"
                    Layout.fillWidth: true
                    spacing: 4

                    Label { text: "Map button"; font.bold: true; font.pixelSize: 15 }
                    Switch {
                        text:    "Show button on the map"
                        checked: cfg.showButton
                        onToggled: cfg.showButton = checked
                        Layout.fillWidth: true
                    }
                    Hint { text: "When hidden, open Traccar Live from QField's Plugins list: tap the settings icon next to Traccar Live." }

                    Item { height: 8 }
                    Label { text: "On the map"; font.bold: true; font.pixelSize: 15 }
                    Switch {
                        text:    "GPS accuracy circles"
                        checked: cfg.showAccuracy
                        onToggled: cfg.showAccuracy = checked
                        Layout.fillWidth: true
                    }
                    Hint { text: "A circle round each marker as wide as the fix's reported accuracy." }

                    Item { height: 8 }
                    Label { text: "Location"; font.bold: true; font.pixelSize: 15 }
                    ComboBox {
                        id: locationCombo
                        Layout.fillWidth: true
                        model: plugin.locationFormats
                        textRole:  "label"
                        valueRole: "value"
                        currentIndex: Math.max(0, indexOfValue(cfg.locationFormat))
                        onActivated: cfg.locationFormat = currentValue
                    }
                    Hint {
                        text: "Shown under each device and copied by its copy button. "
                              + "Project CRS gives easting, northing (" + (plugin._projectCrs().authid || "?") + "). "
                              + "A position outside the Irish or UK grid is shown as lat / long."
                    }

                    Item { height: 8 }
                    Label { text: "Live"; font.bold: true; font.pixelSize: 15 }
                    RowLayout {
                        Label { text: "Refresh every"; Layout.fillWidth: true }
                        SpinBox {
                            from: 2; to: 300; editable: true
                            value: cfg.liveIntervalSec
                            onValueModified: cfg.liveIntervalSec = value
                        }
                        Label { text: "s" }
                    }
                    RowLayout {
                        Label { text: "Grey marker after"; Layout.fillWidth: true }
                        SpinBox {
                            from: 1; to: 1440; editable: true
                            value: cfg.staleMinutes
                            onValueModified: cfg.staleMinutes = value
                        }
                        Label { text: "min" }
                    }

                    Item { height: 8 }
                    Label { text: "Time window \"From feature\""; font.bold: true; font.pixelSize: 15 }
                    Hint { text: "Pick a layer whose features have start (and optional end) times, e.g. incidents." }
                    Label { text: "Layer" }
                    PickCombo {
                        id: eventLayerCombo
                        model: allLayerModel
                        onActivated: {
                            cfg.eventLayerName = pickedName(eventLayerCombo, allLayerModel)
                            settingsDialog.refreshEventFields()
                        }
                    }
                    Label { text: "Name shown in the list"; visible: cfg.eventLayerName !== "" }
                    PickCombo {
                        id: eventDisplayCombo
                        visible: cfg.eventLayerName !== ""
                        model: eventFieldModel
                        onActivated: cfg.eventDisplayField = pickedName(eventDisplayCombo, eventFieldModel)
                    }
                    Label { text: "Start time field"; visible: cfg.eventLayerName !== "" }
                    PickCombo {
                        id: eventStartCombo
                        visible: cfg.eventLayerName !== ""
                        model: eventFieldModel
                        onActivated: cfg.eventStartField = pickedName(eventStartCombo, eventFieldModel)
                    }
                    Label { text: "End time field (optional)"; visible: cfg.eventLayerName !== "" }
                    PickCombo {
                        id: eventEndCombo
                        visible: cfg.eventLayerName !== ""
                        model: eventFieldModel
                        onActivated: cfg.eventEndField = pickedName(eventEndCombo, eventFieldModel)
                    }
                }
                Item { height: 8 }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  TIME WINDOW
    // ════════════════════════════════════════════════════════════════════════

    // Returns {fromIso, toIso, endLimitIso, moving, trimMinutes, tag, label} or {error}
    //  moving      — window still includes "now": Live keeps adding fixes
    //  trimMinutes — "Last N" windows: drop fixes older than now − N on each refresh
    //  endLimitIso — moving window with a fixed end in the future ("" = none)
    function _computeWindow() {
        var m   = cfg.windowMinutes
        var now = new Date()
        if (m > 0) {
            return { fromIso: new Date(now.getTime() - m * 60000).toISOString(), toIso: now.toISOString(),
                     endLimitIso: "", moving: true, trimMinutes: m, tag: "",
                     label: windowModel.get(_windowIndex(m)).label }
        }
        var from, to, tag = ""
        if (m === -1) {
            from = _parseDate(cfg.customFrom)
            to   = _parseDate(cfg.customTo)
            if (!from || !to) return { error: "Enter From / To as YYYY-MM-DD HH:MM (time optional)" }
            // Date-only "To" → include the whole day
            if (cfg.customTo.trim().indexOf(" ") < 0)
                to = new Date(to.getFullYear(), to.getMonth(), to.getDate(), 23, 59, 59, 0)
        } else {
            if (eventFeatureModel.count === 0) populateEventFeatures()
            var f = _selectedEventFeature()
            if (!f) return { error: "Choose a feature (set the layer up in Settings → Advanced)" }
            var dur = cfg.featureDuration * 60000
            if (cfg.featureSpan === 2) {
                if (f.endIso === "") return { error: "That feature has no end time" }
                to   = new Date(f.endIso)
                from = new Date(to.getTime() - dur)
            } else {
                if (f.startIso === "") return { error: "That feature has no start time" }
                from = new Date(f.startIso)
                to   = cfg.featureSpan === 1 ? new Date(from.getTime() + dur)
                     : (f.endIso !== "" ? new Date(f.endIso) : null)   // null = ongoing
            }
            if (cfg.useDisplayAsTag && f.disp !== "") tag = f.disp
        }
        if (to !== null && from >= to) return { error: "'From' must be before 'To'" }
        var moving = to === null || to.getTime() > now.getTime()
        return {
            fromIso:     from.toISOString(),
            toIso:       moving ? now.toISOString() : to.toISOString(),
            endLimitIso: (moving && to !== null) ? to.toISOString() : "",
            moving:      moving,
            trimMinutes: 0,
            tag:         tag,
            label:       ""
        }
    }

    function windowSummary() {
        if (plugin.statusMsg !== "") return plugin.statusMsg
        var w = plugin.win
        if (w === null) {
            return cfg.liveOn ? "Loading…" : "Tap Live to follow devices, or Refresh to load this window once."
        }
        if (w.trimMinutes > 0)
            return _spanText(w.fromIso, w.toIso) + "  ·  " + (cfg.liveOn ? "updating live" : "Live is off")
        if (w.moving)
            return _spanText(w.fromIso, w.toIso) + " (still running)  ·  "
                   + (cfg.liveOn ? "updating live" : "Live is off")
        return _spanText(w.fromIso, w.toIso) + "  ·  past window" + (cfg.liveOn ? " — Live paused" : "")
    }

    // ── Parse "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" text into a local Date ─────
    function _parseDate(str) {
        var s = String(str || "").trim()
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

    // ════════════════════════════════════════════════════════════════════════
    //  LOADING  (map only — never writes to layers)
    // ════════════════════════════════════════════════════════════════════════

    function clearWindow() {
        plugin.win          = null
        plugin.tracks       = ({})
        plugin.latest       = ({})
        plugin.markerPos    = ({})
        plugin.deviceRows   = []
        plugin.overlayModel = []
        plugin.trackModel   = []
    }

    function reloadWindow() {
        clearWindow()
        loadWindow(true)
    }

    // Full load: devices, current fixes, and every fix in the window per device.
    // force = a new window was chosen: start over even if a load is still running.
    function loadWindow(force) {
        if (!force && plugin.loading && Date.now() - plugin.loadStarted < 60000) return
        var w = _computeWindow()
        if (w.error) { plugin.statusMsg = w.error; plugin.loading = false; return }
        var gen = ++plugin.loadGen
        plugin.statusMsg   = "Loading…"
        plugin.loading     = true
        plugin.loadStarted = Date.now()

        var onErr = function(msg) {
            if (gen !== plugin.loadGen) return
            plugin.loading   = false
            plugin.statusMsg = ""
            plugin.liveError = msg
        }

        _get("/api/devices", function(devData) {
            if (gen !== plugin.loadGen) return
            var lookup = _lookupFromDevices(devData)
            plugin.deviceInfo = lookup
            plugin.connState  = "ok"
            loadGeofences()
            _get("/api/positions", function(posData) {
                var latest = {}
                posData.forEach(function(p) { if (_valid(p)) latest[String(p.deviceId)] = p })
                var ids     = Object.keys(lookup)
                var byDev   = {}
                var failed  = 0
                var pending = ids.length
                var done = function() {
                    if (--pending > 0) return
                    if (gen !== plugin.loadGen) return      // superseded by a newer load
                    plugin.loading     = false
                    plugin.liveError   = failed > 0 ? failed + " device(s) could not be loaded" : ""
                    plugin.statusMsg   = ""
                    plugin.win         = w
                    plugin.tracks      = byDev
                    plugin.latest      = latest
                    plugin.lastFetched = Qt.formatTime(new Date(), "HH:mm:ss")
                    _rebuildAll()
                }
                if (pending === 0) { pending = 1; done(); return }
                ids.forEach(function(devId) {
                    _get("/api/positions?deviceId=" + devId
                            + "&from=" + encodeURIComponent(w.fromIso)
                            + "&to="   + encodeURIComponent(w.toIso),
                        function(hist) {
                            var valid = hist.filter(_valid)
                            valid.sort(_byFixTime)
                            if (valid.length > 0) byDev[String(devId)] = valid
                            done()
                        },
                        function(msg) { failed++; done() })
                })
            }, onErr)
        }, function(msg) {
            if (msg.indexOf("401") >= 0) plugin.connState = "wrong username or password"
            onErr(msg)
        })
    }

    // Live refresh: add each device's new fix to its track and move the window on
    function pollLive() {
        if (plugin.loading) return
        if (plugin.win === null) { loadWindow(); return }
        if (!plugin.win.moving) return

        var gen   = plugin.loadGen
        var stale = function() { return gen !== plugin.loadGen || plugin.loading || plugin.win === null }
        var onErr = function(msg) { if (!stale()) plugin.liveError = msg }
        _get("/api/devices", function(devData) {
            if (stale()) return
            plugin.deviceInfo = _lookupFromDevices(devData)
            _get("/api/positions", function(posData) {
                if (stale()) return                 // window changed while this was in flight
                var w      = plugin.win
                var now    = new Date()
                var endMs  = w.endLimitIso !== "" ? new Date(w.endLimitIso).getTime() : Infinity
                var fromMs = w.trimMinutes > 0 ? now.getTime() - w.trimMinutes * 60000
                                               : new Date(w.fromIso).getTime()
                var t = {}
                for (var k in plugin.tracks) t[k] = plugin.tracks[k]
                var latest = {}
                posData.forEach(function(p) {
                    if (!_valid(p)) return
                    var key = String(p.deviceId)
                    latest[key] = p
                    var ms = new Date(p.fixTime).getTime()
                    if (ms < fromMs || ms > endMs) return
                    var arr  = t[key] || []
                    var last = arr.length > 0 ? arr[arr.length - 1] : null
                    if (!last || new Date(last.fixTime).getTime() < ms) t[key] = arr.concat([p])
                })
                // Move a "Last N" window on: drop fixes that fell out of it
                if (w.trimMinutes > 0) {
                    for (var k2 in t) {
                        t[k2] = t[k2].filter(function(p) { return new Date(p.fixTime).getTime() >= fromMs })
                        if (t[k2].length === 0) delete t[k2]
                    }
                }
                var stillMoving = now.getTime() < endMs
                plugin.win = { fromIso: new Date(fromMs).toISOString(),
                               toIso: new Date(Math.min(now.getTime(), endMs)).toISOString(),
                               endLimitIso: w.endLimitIso, moving: stillMoving,
                               trimMinutes: w.trimMinutes, tag: w.tag, label: w.label }
                plugin.tracks      = t
                plugin.latest      = latest
                plugin.liveError   = ""
                plugin.lastFetched = Qt.formatTime(now, "HH:mm:ss")
                _rebuildAll()
            }, onErr)
        }, onErr)
    }

    function _valid(p) {
        return p && p.latitude !== undefined && p.longitude !== undefined && !!p.fixTime
    }

    function _byFixTime(a, b) {
        return new Date(a.fixTime).getTime() - new Date(b.fixTime).getTime()
    }

    function _lookupFromDevices(devData) {
        var lookup = {}
        devData.forEach(function(d) {
            lookup[d.id] = { name: d.name || String(d.id), status: d.status || "unknown", uniqueId: d.uniqueId || "" }
        })
        return lookup
    }

    // Markers, track lines and device rows from the loaded data
    function _rebuildAll() {
        var w = plugin.win
        // Markers: current fix while the window includes now, else the last fix in the window
        var mp = {}
        if (w !== null && w.moving) {
            for (var k in plugin.latest) mp[k] = plugin.latest[k]
        } else {
            for (var k2 in plugin.tracks) {
                var arr = plugin.tracks[k2]
                if (arr.length > 0) mp[k2] = arr[arr.length - 1]
            }
        }
        plugin.markerPos = mp

        var hidden = _hiddenIds()
        function colorOf(devId, fixTime) {
            if (!_isFresh(fixTime)) return "#9E9E9E"
            var info = plugin.deviceInfo[devId] || {}
            return _deviceColor(info.name || devId)
        }

        var markers = []
        for (var id in mp) {
            if (hidden[id]) continue
            var p     = mp[id]
            var info  = plugin.deviceInfo[id] || {}
            var attrs = p.attributes || {}
            markers.push({
                id:      id,
                name:    info.name || id,
                lon:     p.longitude,
                lat:     p.latitude,
                acc:     p.accuracy || 0,
                fixTime: p.fixTime,
                color:   colorOf(id, p.fixTime),
                speed:   p.speed || 0,
                battery: (attrs.batteryLevel !== undefined) ? attrs.batteryLevel : null
            })
        }
        plugin.overlayModel = markers

        var lines = []
        for (var tk in plugin.tracks) {
            var pts = plugin.tracks[tk]
            if (pts.length < 2 || hidden[tk]) continue
            var coords = pts.map(function(q) { return { lon: q.longitude, lat: q.latitude } })
            lines.push({ id: tk, color: colorOf(tk, pts[pts.length - 1].fixTime),
                         coords: _thin(coords, 5000) })   // saving always uses every fix
        }
        plugin.trackModel = lines

        var rows = []
        for (var devId in plugin.deviceInfo) {
            var key   = String(devId)
            var dname = plugin.deviceInfo[devId].name || key
            var tr    = plugin.tracks[key] || []
            var pos   = mp[key] || null
            var line  = tr.length > 0
                ? tr.length + " fix" + (tr.length !== 1 ? "es" : "") + "  ·  "
                  + (tr.length > 1 ? _spanText(tr[0].fixTime, tr[tr.length - 1].fixTime)
                                   : _fmtLocal(tr[0].fixTime))
                : "no fixes in window"
            var parts = { fixes: line, speed: "", battery: "" }
            if (pos) {
                parts.speed = Math.round((pos.speed || 0) * 1.852) + " km/h"
                line += "  ·  " + parts.speed
                var a = pos.attributes || {}
                if (a.batteryLevel !== undefined && a.batteryLevel !== null) {
                    parts.battery = "batt " + a.batteryLevel + "%"
                    line += "  ·  " + parts.battery
                }
            }
            rows.push({ id: key, name: dname, line: line, parts: parts, pos: pos, shown: !hidden[key],
                        color: pos ? colorOf(key, pos.fixTime) : "#9E9E9E",
                        sent: String(plugin.deviceInfo[devId].uniqueId || "").indexOf(sentPointPrefix) === 0 })
        }
        rows.sort(function(r1, r2) { return r1.name.localeCompare(r2.name) })
        plugin.deviceRows = rows
    }

    function testConnection() {
        plugin.connState = ""
        mainWindow.displayToast("Testing…")
        _get("/api/devices", function(data) {
            plugin.connState = "ok"
            plugin.liveError = ""
            mainWindow.displayToast("Connected — " + data.length + " device(s)")
        }, function(msg) {
            plugin.connState = msg.indexOf("401") >= 0 ? "wrong username or password" : msg
            mainWindow.displayToast(msg)
        })
    }

    function zoomToDevice(pos) {
        if (!pos || pos.longitude === undefined || pos.latitude === undefined) return
        try {
            var dst = plugin.mapCanvas.mapSettings.destinationCrs
            var rpt = GeometryUtils.reprojectPoint(
                GeometryUtils.point(pos.longitude, pos.latitude), plugin.wgs84, dst)
            plugin.mapCanvas.mapSettings.setCenter(rpt, true)
        } catch(e) {
            mainWindow.displayToast("Zoom error: " + e)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SAVE  — writes exactly what the time window shows
    // ════════════════════════════════════════════════════════════════════════

    function savePositions() {
        if (cfg.pointsLayerName === "") {
            mainWindow.displayToast("Choose a layer for positions first")
            openSettings("layers")
            return
        }
        if (plugin.win === null) { mainWindow.displayToast("Nothing loaded yet — tap Refresh or Live"); return }
        var positions = []
        var hidden    = _hiddenIds()
        if (cfg.pointsMode === 1) {
            for (var k in plugin.tracks) if (!hidden[k]) positions = positions.concat(plugin.tracks[k])
        } else {
            for (var k2 in plugin.markerPos) if (!hidden[k2]) positions.push(plugin.markerPos[k2])
        }
        if (positions.length === 0) { mainWindow.displayToast("No positions to save"); return }
        var lookup = plugin.deviceInfo
        var tag    = plugin.win.tag
        _queueWrite(function() {
            var lyr = _layerByName(cfg.pointsLayerName, "Positions")
            if (!lyr) return
            try {
                lyr.startEditing()
                var n = _writePointsToLayer(lyr, positions, lookup, tag)
                if (n === 0) throw "the layer did not accept the points"
                if (!lyr.commitChanges()) throw "the layer could not save the points"
                lyr.triggerRepaint()
                mainWindow.displayToast("Saved " + n + " point(s) to " + cfg.pointsLayerName)
            } catch(e) {
                try { lyr.rollBack() } catch(e2) {}
                mainWindow.displayToast("Positions layer error: " + e)
            }
        })
    }

    function saveTracks() {
        if (cfg.tracksLayerName === "") {
            mainWindow.displayToast("Choose a layer for tracks first")
            openSettings("layers")
            return
        }
        if (plugin.win === null) { mainWindow.displayToast("Nothing loaded yet — tap Refresh or Live"); return }
        var byDev  = {}
        var n      = 0
        var hidden = _hiddenIds()
        for (var k in plugin.tracks) {
            if (plugin.tracks[k].length > 0 && !hidden[k]) { byDev[k] = plugin.tracks[k]; n++ }
        }
        if (n === 0) { mainWindow.displayToast("No fixes in this window to save"); return }
        var info = { fromIso: plugin.win.fromIso, toIso: plugin.win.toIso,
                     lookup: plugin.deviceInfo, tag: plugin.win.tag }
        _queueWrite(function() {
            var written = _writeTracks(byDev, info)
            if (written >= 0) mainWindow.displayToast("Saved " + written + " track(s) to " + cfg.tracksLayerName)
        })
    }

    // Returns number of tracks written, or -1 on failure
    function _writeTracks(byDev, info) {
        var lyr = _layerByName(cfg.tracksLayerName, "Tracks")
        if (!lyr) return -1
        var fnames    = lyr.fields.names
        var nameField = _nameFieldFor(fnames, cfg.tracksNameField)

        // "Keep most recent": match earlier tracks by device_id, else by device name
        var replace    = cfg.trackMode === 1
        var matchField = fnames.indexOf("device_id") >= 0 ? "device_id" : nameField
        if (replace && matchField === "") {
            mainWindow.displayToast("Tracks layer has no device_id or device name field — adding instead of replacing")
            replace = false
        }
        var matchKeys = {}   // value in matchField → true, for the devices being saved
        for (var dk in byDev) {
            var dl = info.lookup[dk] || info.lookup[parseInt(dk)] || {}
            matchKeys[matchField === "device_id" ? String(parseInt(dk)) : String(dl.name || dk)] = true
        }

        var oldFids = []
        if (replace) {
            try {
                var iter = LayerUtils.createFeatureIterator(lyr)
                while (iter.hasNext()) {
                    var f = iter.next()
                    if (matchKeys[String(f.attribute(matchField))] === true) oldFids.push(f.id)
                }
                iter.close()
            } catch(e) {
                mainWindow.displayToast("Tracks layer read error: " + e)
                return -1
            }
        }

        var savedAt = new Date().toISOString()
        var written = 0
        try {
            lyr.startEditing()
            for (var i = 0; i < oldFids.length; i++) lyr.deleteFeature(oldFids[i])

            // QGIS adds a missing Z / M on commit but never drops one, so a ZM line is
            // rejected by a 2D (or Z-only) layer: build exactly the layer's dimensions.
            var dims = _layerDims(lyr)
            for (var devKey in byDev) {
                var pts = byDev[devKey]
                var verts = []
                for (var j = 0; j < pts.length; j++) {
                    var xy = _xyForLayer(lyr, pts[j].longitude, pts[j].latitude)
                    var v  = xy.x + " " + xy.y
                    if (dims.z) v += " " + (pts[j].altitude || 0)
                    if (dims.m) v += " " + Math.round(new Date(pts[j].fixTime).getTime() / 1000)
                    verts.push(v)
                }
                if (verts.length === 1) verts.push(verts[0])   // a line needs two vertices
                var geom  = GeometryUtils.createGeometryFromWkt(
                    "LineString" + dims.tag + " (" + verts.join(", ") + ")")
                var feat  = FeatureUtils.createFeature(lyr, geom)
                var dinfo = info.lookup[devKey] || info.lookup[parseInt(devKey)] || {}
                var vals = {
                    device_id:   parseInt(devKey),
                    name:        dinfo.name || devKey,
                    start_time:  _isoUtc(pts[0].fixTime),
                    last_update: _isoUtc(pts[pts.length - 1].fixTime),
                    from_time:   _isoUtc(info.fromIso),
                    to_time:     _isoUtc(info.toIso),
                    n_points:    pts.length,
                    saved_at:    savedAt,
                    // optional text fields: local wall-clock time on this device
                    start_local: _localText(pts[0].fixTime),
                    last_local:  _localText(pts[pts.length - 1].fixTime)
                }
                if (nameField !== "") vals[nameField] = vals.name
                _setAttributes(feat, fnames, vals, info.tag)
                if (LayerUtils.addFeature(lyr, feat)) written++
            }

            if (written === 0) throw "the layer did not accept the tracks"
            if (!lyr.commitChanges()) throw "the layer could not save the tracks"
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Tracks layer error: " + e)
            return -1
        }
        return written
    }

    // Returns number of points added
    function _writePointsToLayer(lyr, positions, deviceInfo, tag) {
        var fnames    = lyr.fields.names
        var nameField = _nameFieldFor(fnames, cfg.pointsNameField)
        var savedAt   = new Date().toISOString()
        var dims      = _layerDims(lyr)
        var added     = 0
        positions.forEach(function(pos) {
            var info  = deviceInfo[pos.deviceId] || {}
            var attrs = pos.attributes || {}
            var xy    = _xyForLayer(lyr, pos.longitude, pos.latitude)
            var v     = xy.x + " " + xy.y
            if (dims.z) v += " " + (pos.altitude || 0)
            if (dims.m) v += " " + Math.round(new Date(pos.fixTime).getTime() / 1000)
            var geom  = GeometryUtils.createGeometryFromWkt("Point" + dims.tag + " (" + v + ")")
            var feat  = FeatureUtils.createFeature(lyr, geom)
            var vals  = {
                device_id:  pos.deviceId || -1,
                name:       info.name || String(pos.deviceId),
                status:     info.status || "",
                speed_kmh:  Math.round((pos.speed || 0) * 1.852 * 10) / 10,
                course:     pos.course   || 0,
                altitude_m: pos.altitude || 0,
                accuracy_m: pos.accuracy || 0,
                fix_time:   _isoUtc(pos.fixTime),
                fix_local:  _localText(pos.fixTime),   // optional text field
                battery:    (attrs.batteryLevel !== undefined) ? attrs.batteryLevel : null,
                address:    pos.address || "",
                motion:     String(attrs.motion || ""),
                fetched_at: savedAt
            }
            if (nameField !== "") vals[nameField] = vals.name
            _setAttributes(feat, fnames, vals, tag)
            if (LayerUtils.addFeature(lyr, feat)) added++
        })
        return added
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SHARED WRITE HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _layerByName(name, label) {
        var layers = qgisProject.mapLayersByName(name)
        if (layers.length === 0) {
            mainWindow.displayToast(label + " layer '" + name + "' not found")
            return null
        }
        return layers[0]
    }

    // Field that receives the device name: the one picked in Settings if the layer
    // still has it, else a field called 'name', else "" (name not written)
    function _nameFieldFor(fnames, chosen) {
        if (chosen !== "" && fnames.indexOf(chosen) >= 0) return chosen
        return fnames.indexOf("name") >= 0 ? "name" : ""
    }

    // Fill fields by name; tagOverride (feature display value) beats cfg.sessionTag
    function _setAttributes(feat, fnames, vals, tagOverride) {
        var tagText  = (tagOverride && tagOverride !== "") ? tagOverride : cfg.sessionTag
        var tagValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== "" && tagText !== "")
                       ? tagText : null
        for (var i = 0; i < fnames.length; i++) {
            if (tagValue !== null && fnames[i] === cfg.incidentRefField)
                feat.setAttribute(i, tagValue)
            else if (vals[fnames[i]] !== undefined && vals[fnames[i]] !== null)
                feat.setAttribute(i, vals[fnames[i]])
        }
    }

    // ── Z / M of a layer's geometry type ──────────────────────────────────
    // Qgis.WkbType: +1000 = Z, +2000 = M, +3000 = ZM; 0x80000000 = old "25D" (Z)
    function _layerDims(lyr) {
        var t = 0
        try { t = Number(lyr.wkbType()) } catch(e) { t = 0 }
        var z = false, m = false
        if (t >= 0x80000000) { z = true; t -= 0x80000000 }
        if (t >= 3000 && t < 4000)      { z = true; m = true }
        else if (t >= 2000 && t < 3000) m = true
        else if (t >= 1000 && t < 2000) z = true
        return { z: z, m: m, tag: (z ? "Z" : "") + (m ? "M" : "") }
    }

    // ── Reproject lon/lat to the layer CRS ────────────────────────────────
    function _xyForLayer(lyr, lon, lat) {
        if (lyr.crs.authid === "EPSG:4326") return { x: lon, y: lat }
        var pt = GeometryUtils.reprojectPoint(GeometryUtils.point(lon, lat), plugin.wgs84, lyr.crs)
        return { x: pt.x, y: pt.y }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  TIME HANDLING
    //  Traccar  — API times are ISO 8601 in UTC ("2026-10-09T08:15:30.000+00:00").
    //  Storage  — always written as a UTC ISO string ("…Z"). A GeoPackage DateTime
    //             field parses it to UTC (and GPKG requires UTC); a Text field keeps
    //             an unambiguous timestamp. (A JS Date would arrive as a Qt LocalTime
    //             value, which a Text field would store without any offset.)
    //  Display  — Qt.formatDateTime() on a JS Date uses the device's time zone,
    //             including the summer-time rule for that particular date.
    //  *_local  — optional Text fields with the local wall-clock time at save time,
    //             for QGIS desktop / exports, which otherwise show DateTime as UTC.
    // ════════════════════════════════════════════════════════════════════════

    function _isoUtc(iso) {
        if (!iso) return null
        var d = new Date(iso)
        return isNaN(d.getTime()) ? null : d.toISOString()
    }

    function _localText(iso) {
        if (!iso) return null
        var d = new Date(iso)
        return isNaN(d.getTime()) ? null : Qt.formatDateTime(d, "yyyy-MM-dd HH:mm:ss t")
    }

    // Event-layer attribute (DateTime → JS Date, or text) → UTC ISO string, "" if empty/invalid.
    // Text without an offset (e.g. "2026-10-09 09:00") is read as local time.
    function _attrToIsoUtc(v) {
        if (v === null || v === undefined || v === "") return ""
        var s = String(v).trim()
        if (/^\d{4}-\d{2}-\d{2}$/.test(s)) s += "T00:00"   // date-only would otherwise parse as UTC
        var d = (v instanceof Date) ? v : new Date(s.replace(" ", "T"))
        return isNaN(d.getTime()) ? "" : d.toISOString()
    }

    function _fmtLocal(iso) {
        if (!iso) return "—"
        var d = new Date(iso)
        return isNaN(d.getTime()) ? String(iso) : Qt.formatDateTime(d, "dd MMM HH:mm")
    }

    // "09:09 – 09:22" (today), otherwise with dates; local time
    function _spanText(fromIso, toIso) {
        var a = new Date(fromIso), b = new Date(toIso)
        if (isNaN(a.getTime()) || isNaN(b.getTime())) return "—"
        var today   = Qt.formatDate(new Date(), "yyyy-MM-dd")
        var sameDay = Qt.formatDate(a, "yyyy-MM-dd") === Qt.formatDate(b, "yyyy-MM-dd")
        if (sameDay && Qt.formatDate(a, "yyyy-MM-dd") === today)
            return Qt.formatTime(a, "HH:mm") + " – " + Qt.formatTime(b, "HH:mm")
        if (sameDay)
            return Qt.formatDateTime(a, "dd MMM HH:mm") + " – " + Qt.formatTime(b, "HH:mm")
        return Qt.formatDateTime(a, "dd MMM HH:mm") + " – " + Qt.formatDateTime(b, "dd MMM HH:mm")
    }

    function _ageText(fixTime) {
        if (!fixTime) return "?"
        var s = Math.max(0, Math.floor((Date.now() - new Date(fixTime).getTime()) / 1000))
        if (s < 60)    return s + " s"
        if (s < 3600)  return Math.floor(s / 60) + " min"
        if (s < 86400) return Math.floor(s / 3600) + " h"
        return Math.floor(s / 86400) + " d"
    }

    // ════════════════════════════════════════════════════════════════════════
    //  QFIELDCLOUD GUARD
    //  Layer writes are queued and only run while QFieldCloud is idle, so we
    //  never call startEditing()/commitChanges() during a sync, download or
    //  push (QField 4.x can also auto-push on a timer).
    //
    //  Checked against QField source (v3.6 → v4.3.5):
    //   - objectName "cloudConnection" / "cloudProjectsModel" in the main QML
    //     (src/app/qml/QgisMobileapp.qml in 4.3; src/qml/qgismobileapp.qml before)
    //   - QfCloudConnection::ConnectionState { Idle = 0, Busy = 1 }
    //   - QfCloudProject::ProjectStatus — values shift between versions
    //     (4.3 added Creating, 4.0 added Pushing), so "Failing" is looked up by
    //     name; Idle is 0 in every version. Same rule as QField's own
    //     QfCloudProjectsModel::busyProjectIds(): busy = not Idle and not Failing.
    //   - iface.findItemByObjectName() is used because QML objects have no
    //     findChild() method (v0.2's guard silently never fired).
    //  Non-cloud projects: both lookups come back empty → never busy.
    // ════════════════════════════════════════════════════════════════════════

    function _cloudBusy() {
        try {
            var cc = iface.findItemByObjectName("cloudConnection")
            if (cc && cc.state === 1) return true          // ConnectionState::Busy
        } catch(e) {}
        try {
            var pm = iface.findItemByObjectName("cloudProjectsModel")
            var cp = pm ? pm.currentProject : null         // QField ≥ 3.6
            if (cp && cp.status !== undefined) {
                if (cp.status !== 0 && cp.status !== _cloudFailingStatus()) return true
            }
        } catch(e) {}
        return false
    }

    function _cloudFailingStatus() {
        try { return QFieldCloudProject.Failing } catch(e) {}   // legacy name, still registered in 4.3
        try { return QfCloudProject.Failing } catch(e) {}
        return -1
    }

    function _queueWrite(fn) {
        var q = plugin.writeQueue.slice()
        q.push(fn)
        plugin.writeQueue = q
        _drainWrites()
    }

    function _drainWrites() {
        if (plugin.writeQueue.length === 0) { cloudWaitTimer.stop(); return }
        if (_cloudBusy()) {
            if (!cloudWaitTimer.running) {
                plugin.writeWaitStart = Date.now()
                cloudWaitTimer.start()
                mainWindow.displayToast("QFieldCloud is syncing — will save when it finishes")
            } else if (Date.now() - plugin.writeWaitStart > 10 * 60000) {
                cloudWaitTimer.stop()
                plugin.writeQueue = []
                mainWindow.displayToast("Save cancelled — QFieldCloud still busy after 10 min")
            }
            return
        }
        cloudWaitTimer.stop()
        var q = plugin.writeQueue
        plugin.writeQueue = []
        for (var i = 0; i < q.length; i++) q[i]()
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
    //  onError(msg) is optional — without it the message is shown as a toast.
    // ════════════════════════════════════════════════════════════════════════

    function _get(path, callback, onError) {
        _send("GET", path, null, callback, onError)
    }

    // method: GET, POST, PUT or DELETE; body: object sent as JSON, or null.
    // callback gets the reply's JSON (null for an empty reply, e.g. after DELETE).
    function _send(method, path, body, callback, onError) {
        var fail = function(msg) {
            if (onError) onError(msg)
            else         mainWindow.displayToast(msg)
        }
        var xhr = new XMLHttpRequest()
        var url = cfg.serverUrl + path
        xhr.open(method, url, true)
        xhr.setRequestHeader("Authorization", "Basic " + _btoa(cfg.username + ":" + cfg.password))
        xhr.setRequestHeader("Accept",        "application/json")
        if (body !== null && body !== undefined) xhr.setRequestHeader("Content-Type", "application/json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status >= 200 && xhr.status < 300) {
                var data = null
                if (xhr.responseText !== "") {
                    try {
                        data = JSON.parse(xhr.responseText)
                    } catch(e) {
                        fail("Parse error: " + e)
                        return
                    }
                }
                callback(data)
            } else if (xhr.status === 0) {
                fail("No response — check server URL and connectivity")
            } else {
                fail("HTTP " + xhr.status +
                     (xhr.status === 401 ? " — wrong username/password"
                      : xhr.status === 400 && xhr.responseText ? ": " + xhr.responseText.split("\n")[0].substr(0, 120)
                      : " on " + path.split("?")[0]))
            }
        }
        xhr.send(body !== null && body !== undefined ? JSON.stringify(body) : null)
    }
}
