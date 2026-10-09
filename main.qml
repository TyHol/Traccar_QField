/**
 * Traccar Live – QField Plugin  v0.4
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
            eventFeatureModel.append({ label: "— set up in 🔧 Settings → Advanced —",
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
        onClicked:  mainDialog.open()
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
                    strokeColor: modelData.fresh ? "#AA1565C0" : "#AA9E9E9E"
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
                property color c:  d.fresh ? "#1565C0" : "#9E9E9E"
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

    // Keep at most maxPts vertices for drawing (always keeps first and last)
    function _decimate(coords, maxPts) {
        if (coords.length <= maxPts) return coords
        var out  = []
        var step = (coords.length - 1) / (maxPts - 1)
        for (var i = 0; i < maxPts; i++) out.push(coords[Math.round(i * step)])
        return out
    }

    function _onMapTap(point) {
        if (!cfg.showMarkers) return false
        var ms = plugin.mapCanvas.mapSettings
        for (var i = 0; i < plugin.overlayModel.length; i++) {
            var d = plugin.overlayModel[i]
            var s = ms.coordinateToScreen(_toMapPoint(d.lon, d.lat))
            if (Math.abs(point.x - s.x) < 24 && Math.abs(point.y - s.y) < 24) {
                var msg = d.name + "\nFix " + _ageText(d.fixTime) + " ago"
                msg += "  •  " + Math.round((d.speed || 0) * 1.852) + " km/h"
                if (d.battery !== null && d.battery !== undefined) msg += "  •  🔋" + d.battery + "%"
                mainWindow.displayToast(msg)
                return true
            }
        }
        return false
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MAIN DIALOG
    // ════════════════════════════════════════════════════════════════════════
    Dialog {
        id:      mainDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 8
        width:   plugin.phone ? mainWindow.width : Math.min(mainWindow.width * 0.9, 460)
        height:  plugin.phone ? mainWindow.height - plugin.topInset - plugin.bottomInset
                              : Math.min(mainWindow.height * 0.9, 780)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset : (mainWindow.height - height) / 2

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
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
                ToolButton {
                    contentItem: Text {
                        text: "🔧"; color: "white"; font.pixelSize: 18
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
                    onClicked: openSettings("")
                }
                ToolButton {
                    contentItem: Text {
                        text: "✕"; color: "white"; font.pixelSize: 18
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
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
                    text: "⚠  " + plugin.liveError + "  — tap to check settings"
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
                        text: "🔄"
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
                    text: cfg.liveOn ? "⏹  Stop live" : "▶  Live"
                    onClicked: {
                        cfg.liveOn = !cfg.liveOn
                        if (cfg.liveOn) loadWindow()
                    }
                }
                Button {
                    text: plugin.loading ? "…" : "🔄"
                    enabled: !plugin.loading
                    onClicked: loadWindow()
                }
                Button {
                    text: "Clear"
                    enabled: plugin.win !== null
                    onClicked: { cfg.liveOn = false; clearWindow(); plugin.statusMsg = "" }
                }
            }

            // ── What to show ──────────────────────────────────────────────
            Flow {
                Layout.fillWidth: true
                spacing: 0
                CheckBox { text: "Markers";  checked: cfg.showMarkers;  onToggled: cfg.showMarkers  = checked }
                CheckBox { text: "Labels";   checked: cfg.showLabels;   onToggled: cfg.showLabels   = checked }
                CheckBox { text: "Tracks";   checked: cfg.showTrails;   onToggled: cfg.showTrails   = checked }
                CheckBox { text: "Accuracy"; checked: cfg.showAccuracy; onToggled: cfg.showAccuracy = checked }
            }

            // ── Devices ───────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Label { text: "Devices  (" + plugin.deviceRows.length + ")"; font.bold: true; Layout.fillWidth: true }
                Label {
                    visible: plugin.lastFetched !== ""
                    text: "updated " + plugin.lastFetched
                    font.pixelSize: 11
                    color: Theme.secondaryTextColor
                }
            }
            ListView {
                Layout.fillWidth:  true
                Layout.fillHeight: true
                Layout.minimumHeight: 60
                clip:  true
                model: plugin.deviceRows

                delegate: Rectangle {
                    width:  ListView.view.width
                    height: 54
                    color:  index % 2 === 0 ? "#F5F5F5" : "white"
                    property var row: modelData

                    RowLayout {
                        anchors { fill: parent; leftMargin: 10; rightMargin: 4 }
                        spacing: 8
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: row.fresh ? "#4CAF50" : "#9E9E9E"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Label {
                                text: row.name
                                font.bold: true
                                font.pixelSize: 14
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Label {
                                text: row.line
                                font.pixelSize: 11
                                color: "#555"
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        ToolButton {
                            visible: row.pos !== null
                            contentItem: Text {
                                text: "⌖"; font.pixelSize: 20
                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                            }
                            background: Item {}
                            onClicked: { zoomToDevice(row.pos); mainDialog.close() }
                        }
                    }
                }
            }

            // ── Save ──────────────────────────────────────────────────────
            Label {
                visible:          plugin.writeQueue.length > 0
                text:             "⏳ Waiting for QFieldCloud sync to finish before saving…"
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
                    text: "📍 Save positions"
                    onClicked: savePositions()
                }
                Button {
                    Layout.fillWidth: true
                    text: "〰 Save tracks"
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
            return "⚠ No layers chosen to save to — tap here"
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
    Dialog {
        id:      helpDialog
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 10
        width:   plugin.phone ? mainWindow.width : Math.min(mainWindow.width * 0.9, 460)
        height:  plugin.phone ? mainWindow.height - plugin.topInset - plugin.bottomInset
                              : Math.min(mainWindow.height * 0.9, 780)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset : (mainWindow.height - height) / 2

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                ToolButton {
                    contentItem: Text {
                        text: "←"; color: "white"; font.pixelSize: 20
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
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
                    text: "1. 🔧 Settings → Connection: enter your Traccar server and account, tap Test.\n" +
                          "2. Choose a time window and tap ▶ Live (or 🔄 to load it once).\n" +
                          "3. To keep what you see, pick layers in 🔧 Settings → Layers and use the Save buttons."
                }

                Label { text: "Time window"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "One window controls everything: the tracks on the map are the fixes inside it, " +
                          "and the Save buttons save exactly that.\n" +
                          "• Last 15 min … Last 3 months — follows the current time.\n" +
                          "• Custom dates — enter From / To in local time, tap Show this window.\n" +
                          "• From feature — use the start/end times of a feature (e.g. an incident). " +
                          "Set the layer up once in 🔧 Settings → Advanced.\n" +
                          "Each device row shows how many fixes it has in the window and their time span."
                }

                Label { text: "Live, 🔄 and Clear"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "▶ Live refreshes every few seconds and keeps a 'Last …' window moving. " +
                          "A window that ends in the past cannot change, so Live pauses for it and markers " +
                          "show each device's last fix in that window.\n" +
                          "🔄 loads the window once.  Clear removes everything from the map.\n" +
                          "Nothing is written to your project until you tap a Save button."
                }

                Label { text: "On the map"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "Markers are blue when the last fix is recent and grey when it is older than the " +
                          "limit in Settings → Advanced. Tap a marker for name, fix age, speed and battery. " +
                          "Markers, Labels, Tracks and Accuracy circles can each be switched on or off. " +
                          "⌖ in the device list centres the map on that device."
                }

                Label { text: "Saving"; font.bold: true; font.pixelSize: 15 }
                Hint {
                    color: Theme.mainTextColor
                    text: "📍 Save positions — adds a point per device: its latest fix, or every fix in the " +
                          "window (Settings → Layers).\n" +
                          "〰 Save tracks — adds one line per device for the window, or replaces that " +
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
                    text: "🔧 Settings → Tag stamps a text such as FIRE-2026-001 onto everything you save. " +
                          "With 'From feature', the feature's display value can be used as the tag instead."
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
        parent:  mainWindow.contentItem
        visible: false
        modal:   true
        padding: 10
        width:   plugin.phone ? mainWindow.width : Math.min(mainWindow.width * 0.9, 460)
        height:  plugin.phone ? mainWindow.height - plugin.topInset - plugin.bottomInset
                              : Math.min(mainWindow.height * 0.9, 780)
        x:       (mainWindow.width - width) / 2
        y:       plugin.phone ? plugin.topInset : (mainWindow.height - height) / 2

        property string page: ""   // "" = list, "connection", "layers", "tag", "advanced"

        readonly property var titles: ({ "": "Settings", "connection": "Connection",
                                         "layers": "Layers", "tag": "Tag", "advanced": "Advanced" })

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                ToolButton {
                    contentItem: Text {
                        text: "←"; color: "white"; font.pixelSize: 20
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
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
                ToolButton {
                    contentItem: Text {
                        text: "✕"; color: "white"; font.pixelSize: 18
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Item {}
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
        }

        function loadControls() {
            urlField.text        = cfg.serverUrl
            userField.text       = cfg.username
            passField.text       = cfg.password
            sessionTagField.text = cfg.sessionTag
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
                            if (cfg.username === "") return "⚠ Not set up — tap to connect"
                            var st = plugin.connState === "ok" ? "✓ connected"
                                   : plugin.connState === ""   ? "not tested"
                                   : "✕ " + plugin.connState
                            return host + "  ·  " + cfg.username + "  ·  " + st
                        }
                    }
                    SettingsRow {
                        title:   "Layers"
                        onClicked: settingsDialog.page = "layers"
                        warn:    cfg.pointsLayerName === "" && cfg.tracksLayerName === ""
                        summary: {
                            if (cfg.pointsLayerName === "" && cfg.tracksLayerName === "")
                                return "⚠ Nothing to save to yet"
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
                                   + " → " + (cfg.incidentRefField !== "" ? cfg.incidentRefField : "⚠ no field")
                    }
                    SettingsRow {
                        title:   "Advanced"
                        onClicked: settingsDialog.page = "advanced"
                        summary: "Refresh every " + cfg.liveIntervalSec + " s  ·  grey after "
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
                        text: plugin.connState === "ok" ? "✓ Connected" : "✕ " + plugin.connState
                        color: plugin.connState === "ok" ? "#2E7D32" : "#B71C1C"
                    }
                    Hint { text: "Use the same address you open in a browser for Traccar." }
                }

                // ══ Layers ═════════════════════════════════════════════════
                ColumnLayout {
                    visible: settingsDialog.page === "layers"
                    Layout.fillWidth: true
                    spacing: 4

                    Label { text: "📍 Positions"; font.bold: true; font.pixelSize: 15 }
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
                    Label { text: "〰 Tracks"; font.bold: true; font.pixelSize: 15 }
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
            if (!f) return { error: "Choose a feature (set the layer up in 🔧 Settings → Advanced)" }
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
            return cfg.liveOn ? "Loading…" : "Tap ▶ Live to follow devices, or 🔄 to load this window once."
        }
        var spanMs = new Date(w.toIso).getTime() - new Date(w.fromIso).getTime()
        var big    = spanMs > 7 * 86400000 ? "\n⚠ Long window — loading and drawing may be slow." : ""
        if (w.trimMinutes > 0)
            return _spanText(w.fromIso, w.toIso) + "  ·  " + (cfg.liveOn ? "updating live" : "Live is off") + big
        if (w.moving)
            return _spanText(w.fromIso, w.toIso) + " (still running)  ·  "
                   + (cfg.liveOn ? "updating live" : "Live is off") + big
        return _spanText(w.fromIso, w.toIso) + "  ·  past window" + (cfg.liveOn ? " — Live paused" : "") + big
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
            lookup[d.id] = { name: d.name || String(d.id), status: d.status || "unknown" }
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

        var markers = []
        for (var id in mp) {
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
                fresh:   _isFresh(p.fixTime),
                speed:   p.speed || 0,
                battery: (attrs.batteryLevel !== undefined) ? attrs.batteryLevel : null
            })
        }
        plugin.overlayModel = markers

        var lines = []
        for (var tk in plugin.tracks) {
            var pts = plugin.tracks[tk]
            if (pts.length < 2) continue
            var coords = pts.map(function(q) { return { lon: q.longitude, lat: q.latitude } })
            lines.push({ id: tk, fresh: _isFresh(pts[pts.length - 1].fixTime),
                         coords: _decimate(coords, 1500) })   // saving always uses every fix
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
            if (pos) {
                line += "  ·  " + Math.round((pos.speed || 0) * 1.852) + " km/h"
                var a = pos.attributes || {}
                if (a.batteryLevel !== undefined && a.batteryLevel !== null) line += "  ·  🔋" + a.batteryLevel + "%"
            }
            rows.push({ name: dname, line: line, pos: pos, fresh: pos ? _isFresh(pos.fixTime) : false })
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
            mainWindow.displayToast("✓ Connected — " + data.length + " device(s)")
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
        if (plugin.win === null) { mainWindow.displayToast("Nothing loaded yet — tap 🔄 or ▶ Live"); return }
        var positions = []
        if (cfg.pointsMode === 1) {
            for (var k in plugin.tracks) positions = positions.concat(plugin.tracks[k])
        } else {
            for (var k2 in plugin.markerPos) positions.push(plugin.markerPos[k2])
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
                mainWindow.displayToast("✓ Saved " + n + " point(s) to " + cfg.pointsLayerName)
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
        if (plugin.win === null) { mainWindow.displayToast("Nothing loaded yet — tap 🔄 or ▶ Live"); return }
        var byDev = {}
        var n = 0
        for (var k in plugin.tracks) {
            if (plugin.tracks[k].length > 0) { byDev[k] = plugin.tracks[k]; n++ }
        }
        if (n === 0) { mainWindow.displayToast("No fixes in this window to save"); return }
        var info = { fromIso: plugin.win.fromIso, toIso: plugin.win.toIso,
                     lookup: plugin.deviceInfo, tag: plugin.win.tag }
        _queueWrite(function() {
            var written = _writeTracks(byDev, info)
            if (written >= 0) mainWindow.displayToast("✓ Saved " + written + " track(s) to " + cfg.tracksLayerName)
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
        var fail = function(msg) {
            if (onError) onError(msg)
            else         mainWindow.displayToast(msg)
        }
        var xhr = new XMLHttpRequest()
        var url = cfg.serverUrl + path
        xhr.open("GET", url, true)
        xhr.setRequestHeader("Authorization", "Basic " + _btoa(cfg.username + ":" + cfg.password))
        xhr.setRequestHeader("Accept",        "application/json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                var data
                try {
                    data = JSON.parse(xhr.responseText)
                } catch(e) {
                    fail("Parse error: " + e)
                    return
                }
                callback(data)
            } else if (xhr.status === 0) {
                fail("No response — check server URL and connectivity")
            } else {
                fail("HTTP " + xhr.status +
                     (xhr.status === 401 ? " — wrong username/password" : " on " + path.split("?")[0]))
            }
        }
        xhr.send()
    }
}
