/**
 * Traccar Live – QField Plugin  v0.3
 *
 * Live overlay  — device markers + recent trails drawn on top of the map,
 *                 refreshed every few seconds. Nothing is written to file.
 * Save positions — on demand: latest fix (or last N fixes) per device → points layer.
 * Save tracks    — on demand: one line per device for a chosen time window → tracks layer.
 *
 * All layer writes go through _queueWrite(), which waits while QFieldCloud is busy.
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

    // ── Persistent settings ───────────────────────────────────────────────
    Settings {
        id: cfg
        category: "TraccarLive"
        property string serverUrl:      "https://server.traccar.org"
        property string username:       ""
        property string password:       ""

        // Live overlay
        property bool   liveOn:          false  // overlay polling running
        property int    liveIntervalSec: 10     // overlay refresh interval
        property int    trailMinutes:    30     // length of the on-screen trail
        property int    staleMinutes:    10     // marker turns grey when last fix is older
        property bool   showMarkers:     true
        property bool   showLabels:      true
        property bool   showAccuracy:    false
        property bool   showTrails:      true
        property bool   showPreview:     true   // tracks fetched in the Save Tracks dialog

        // File layers (written only on demand)
        property string pointsLayerName: ""
        property int    pointsPerDevice: 1      // 1 = latest fix; N = most recent N fixes (last 24 h)
        property string tracksLayerName: ""
        property int    trackMode:       0      // 0 = add a new track per save, 1 = keep most recent only
        property string pointsNameField: ""     // extra text field to receive the device name ("" = only a 'name' field)
        property string tracksNameField: ""

        // Session tag
        property bool   incidentRefEnabled: false  // write sessionTag into incidentRefField on new features
        property bool   useDisplayAsTag:    false  // when fetching from a feature, use the display field value as the tag
        property string incidentRefField:   ""     // target field name (same on both layers)
        property string sessionTag:         ""     // plain text written verbatim into the field

        // Event layer (Save Tracks → From feature)
        property string eventLayerName:    ""   // layer to pick features from
        property string eventDisplayField: ""   // field shown in the feature combo label
        property string eventStartField:   ""   // datetime field: event start
        property string eventEndField:     ""   // datetime field: event end (optional)

        // Kept for migration from v0.2 only — no longer used
        property bool   v3Migrated:      false
        property string liveLayerName:   ""
        property string appendLayerName: ""
        property string lineLayerName:   ""
        property string pointLayerName:  ""
    }

    // Shared timeframe presets — used by the Save Tracks "Time period" combo
    // and the overlay trail length combo. minutes:0 = "— Select time period —".
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
    property var    deviceInfo:  ({})   // devId → {name, status}
    property var    positions:   []     // latest fix per device (device list)
    property string lastFetched: ""
    property string liveError:   ""
    property bool   fetchBusy:   false
    property double fetchStarted: 0
    property bool   saveBusy:    false
    property var    fetchLog:       []   // session history — see _addToFetchLog()
    property string fetchTagOverride: "" // set to feature's display value when fetching from a feature

    // Overlay data
    property var    overlayModel: []    // [{id, name, lon, lat, acc, fixTime, fresh, speed, battery}]
    property var    trails:       ({})  // devId → [{lon, lat, t}]  (in memory only)
    property bool   trailsSeeded: false
    property var    trailModel:   []    // [{id, fresh, coords:[{lon,lat}]}]
    property var    preview:      ({})  // devId → [positions] from the last Save Tracks fetch
    property var    previewInfo:  null  // {fromIso, toIso, lookup, tag, nPts}
    property var    previewModel: []    // [{id, coords:[{lon,lat}]}]  (decimated for drawing)
    property int    mapTick:      0     // bumped on pan / zoom / rotate → re-place overlay items
    property int    crsTick:      0     // bumped when the map CRS changes → re-project

    // Pending layer writes (held back while QFieldCloud is busy)
    property var    writeQueue:     []
    property double writeWaitStart: 0

    // ── Layer list models (for ComboBoxes in Settings) ─────────────────────
    ListModel { id: ptLayerModel }
    ListModel { id: lnLayerModel }
    ListModel { id: fieldNameModel }    // field names of the points + tracks layers (tag field picker)
    ListModel { id: ptNameFieldModel }  // text fields of the points layer (device name picker)
    ListModel { id: lnNameFieldModel }  // text fields of the tracks layer (device name picker)
    ListModel { id: allLayerModel }     // all vector layers (event layer picker in Settings)
    ListModel { id: eventFieldModel }   // fields of the event layer (shared by 3 combos in Settings)
    ListModel { id: eventFeatureModel } // features of the event layer (Save Tracks picker)

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

    // ── Selected layer name from a layer combo ("" for none / header) ─────
    function comboLayerName(combo, model) {
        if (combo.currentIndex < 0 || model.count === 0) return ""
        var item = model.get(combo.currentIndex)
        return (item && !item.isHeader && item.name !== "— no layer —") ? item.name : ""
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
        model.append({ name: "— none (only a field called 'name') —", isHeader: false })
        if (layerName === "") return
        var r = _textFieldNames(layerName)
        if (!r.filtered)
            model.append({ name: "— field types unknown: all fields shown —", isHeader: true })
        else if (r.names.length === 0)
            model.append({ name: "— no text fields in this layer —", isHeader: true })
        for (var i = 0; i < r.names.length; i++)
            model.append({ name: r.names[i], isHeader: false })
    }

    function comboNameField(combo, model) {
        if (combo.currentIndex <= 0 || model.count === 0) return ""
        var item = model.get(combo.currentIndex)
        return (item && !item.isHeader) ? item.name : ""
    }

    // ── Field names of the points + tracks layers (tag field picker) ──────
    function populateFieldNames(model, layerNames) {
        model.clear()
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
            model.append({ name: "— select points / tracks layers first —", isHeader: true })
            return
        }
        for (var j = 0; j < names.length; j++)
            model.append({ name: names[j], isHeader: false })
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

    // ── Feature list for the Save Tracks "From feature" picker ────────────
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
                var startIso = ""   // normalised to UTC ISO so it sorts and parses reliably
                var endIso   = ""
                try { disp     = String(f.attribute(cfg.eventDisplayField) || "") } catch(e) {}
                if (cfg.eventStartField !== "")
                    try { startIso = _attrToIsoUtc(f.attribute(cfg.eventStartField)) } catch(e) {}
                if (cfg.eventEndField !== "")
                    try { endIso   = _attrToIsoUtc(f.attribute(cfg.eventEndField)) } catch(e) {}

                var label = (disp !== "" ? disp : ("#" + f.id))
                if (startIso !== "") {
                    label += "  (" + _fmtLocal(startIso)
                           + (endIso !== "" ? " – " + _fmtLocal(endIso) : " – ongoing") + ")"
                }
                rows.push({ label: label, startIso: startIso, endIso: endIso, fid: f.id, disp: disp })
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

    // ── Startup ───────────────────────────────────────────────────────────
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

        // Tap a marker → device info toast
        try {
            if (pointHandler) {
                pointHandler.registerHandler("traccarlive", function(point, type, interactionType) {
                    if (interactionType !== "clicked") return false
                    return _onMapTap(point)
                })
            }
        } catch(e) { /* older QField without pointHandler.registerHandler */ }
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

    // ── Live overlay refresh timer ────────────────────────────────────────
    Timer {
        id:               refreshTimer
        interval:         Math.max(2, cfg.liveIntervalSec) * 1000
        repeat:           true
        running:          cfg.liveOn
        triggeredOnStart: true
        onTriggered:      fetchAll()
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

        // ── Saved-tracks preview (dashed orange) ──────────────────────────
        Repeater {
            model: cfg.showPreview ? plugin.previewModel : []
            delegate: Shape {
                id: previewShape
                anchors.fill: parent
                property var proj: { plugin.crsTick; return plugin._projectCoords(modelData.coords) }
                property var pts:  { plugin.mapTick; return plugin._toScreen(proj) }
                visible: pts.length > 1
                ShapePath {
                    strokeColor: "#E65100"
                    strokeWidth: 3
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 2]
                    fillColor:   "transparent"
                    capStyle:    ShapePath.RoundCap
                    joinStyle:   ShapePath.RoundJoin
                    PathPolyline { path: previewShape.pts }
                }
            }
        }

        // ── Live trails ───────────────────────────────────────────────────
        Repeater {
            model: (cfg.liveOn && cfg.showTrails) ? plugin.trailModel : []
            delegate: Shape {
                id: trailShape
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
                    PathPolyline { path: trailShape.pts }
                }
            }
        }

        // ── Device markers ────────────────────────────────────────────────
        Repeater {
            model: (cfg.liveOn && cfg.showMarkers) ? plugin.overlayModel : []
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
        if (!cfg.liveOn || !cfg.showMarkers) return false
        var ms = plugin.mapCanvas.mapSettings
        for (var i = 0; i < plugin.overlayModel.length; i++) {
            var d = plugin.overlayModel[i]
            var s = ms.coordinateToScreen(_toMapPoint(d.lon, d.lat))
            if (Math.abs(point.x - s.x) < 24 && Math.abs(point.y - s.y) < 24) {
                var msg = d.name + "\nLast fix " + _ageText(d.fixTime) + " ago"
                msg += "  •  " + Math.round((d.speed || 0) * 1.852) + " km/h"
                if (d.battery !== null && d.battery !== undefined) msg += "  •  🔋" + d.battery + "%"
                mainWindow.displayToast(msg)
                return true
            }
        }
        return false
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

            // Status banner
            Rectangle {
                Layout.fillWidth: true
                height:  visible ? 30 : 0
                visible: plugin.lastFetched !== "" || plugin.liveError !== ""
                color:   plugin.liveError !== "" ? "#FFEBEE" : "#E3F2FD"
                Label {
                    anchors { fill: parent; leftMargin: 10 }
                    text: plugin.liveError !== "" ? "⚠  " + plugin.liveError
                                                  : "Last update:  " + plugin.lastFetched
                    verticalAlignment: Text.AlignVCenter
                    elide:             Text.ElideRight
                    font.pixelSize:    12
                    color: plugin.liveError !== "" ? "#B71C1C" : "#1565C0"
                }
            }

            // Live overlay controls
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin:  10
                Layout.rightMargin: 10
                Layout.topMargin:   8
                spacing:          8
                Button {
                    Layout.fillWidth: true
                    text:    cfg.liveOn ? "⏹  Stop live" : "▶  Start live"
                    onClicked: {
                        cfg.liveOn = !cfg.liveOn
                        if (!cfg.liveOn) {
                            plugin.trails       = ({})
                            plugin.trailModel   = []
                            plugin.trailsSeeded = false
                            plugin.liveError    = ""
                        }
                        mainWindow.displayToast(cfg.liveOn ? "Live overlay started" : "Live overlay stopped")
                    }
                }
                Button {
                    text:    "🔄 Now"
                    enabled: !plugin.fetchBusy
                    onClicked: fetchAll()
                }
            }

            // Overlay toggles
            Label {
                text:                "Show on map"
                font.pixelSize:      11
                color:               Theme.secondaryTextColor
                Layout.leftMargin:   12
                Layout.topMargin:    4
            }
            GridLayout {
                Layout.fillWidth:   true
                Layout.leftMargin:  4
                Layout.rightMargin: 4
                columns:       3
                columnSpacing: 0
                rowSpacing:    0
                CheckBox {
                    text: "Markers"; font.pixelSize: 12; Layout.fillWidth: true
                    checked: cfg.showMarkers; onToggled: cfg.showMarkers = checked
                }
                CheckBox {
                    text: "Labels"; font.pixelSize: 12; Layout.fillWidth: true
                    checked: cfg.showLabels; onToggled: cfg.showLabels = checked
                }
                CheckBox {
                    text: "Accuracy"; font.pixelSize: 12; Layout.fillWidth: true
                    checked: cfg.showAccuracy; onToggled: cfg.showAccuracy = checked
                }
                CheckBox {
                    text: "Trails"; font.pixelSize: 12; Layout.fillWidth: true
                    checked: cfg.showTrails
                    onToggled: {
                        cfg.showTrails = checked
                        if (checked && cfg.liveOn) seedTrails()
                    }
                }
                CheckBox {
                    text: "Preview"; font.pixelSize: 12; Layout.fillWidth: true
                    checked: cfg.showPreview; onToggled: cfg.showPreview = checked
                }
                Item { Layout.fillWidth: true }
            }

            // Save to file (on demand)
            Label {
                text:                "Save to layers"
                font.pixelSize:      11
                color:               Theme.secondaryTextColor
                Layout.leftMargin:   12
                Layout.topMargin:    4
            }
            RowLayout {
                Layout.fillWidth:   true
                Layout.leftMargin:  10
                Layout.rightMargin: 10
                spacing:            8
                Button {
                    Layout.fillWidth: true
                    text:    plugin.saveBusy ? "Saving…" : "📍 Save positions"
                    enabled: !plugin.saveBusy
                    onClicked: savePositions()
                }
                Button {
                    Layout.fillWidth: true
                    text:    "〰 Save tracks…"
                    onClicked: { mainDialog.close(); fetchLogsDialog.open() }
                }
            }
            Label {
                visible:           plugin.writeQueue.length > 0
                text:              "⏳ Waiting for QFieldCloud sync to finish before saving…"
                font.pixelSize:    11
                color:             "#E65100"
                wrapMode:          Text.WordWrap
                Layout.fillWidth:  true
                Layout.leftMargin: 12
            }

            Label {
                text:                "Devices  (" + plugin.positions.length + ")"
                font.bold:           true
                Layout.leftMargin:   12
                Layout.topMargin:    8
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
                    property bool fresh: plugin._isFresh(pos.fixTime)

                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 8 }
                        spacing: 10
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: fresh ? "#4CAF50" : "#9E9E9E"
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
                                    var spd = Math.round((pos.speed || 0) * 1.852)
                                    var bat = (pos.attributes && pos.attributes.batteryLevel != null)
                                              ? "  🔋" + pos.attributes.batteryLevel + "%" : ""
                                    // fixTime = GPS fix time on the device (≠ fetch time)
                                    return spd + " km/h  •  fix " + plugin._ageText(pos.fixTime) + " ago" + bat
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
                    text: "Live overlay"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "▶ Start live — draws devices on the map, refreshed every few seconds. " +
                          "Nothing is written to your project.\n" +
                          "Markers turn grey when the last fix is older than the stale limit. " +
                          "Tap a marker for name, fix age, speed and battery.\n" +
                          "Each overlay (markers, labels, accuracy, trails, preview) can be switched on or off."
                }

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Saving to layers  (choose layers in 🔧 Settings → Layers)"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "📍 Save positions — adds the latest fix (or last N fixes) of every device " +
                          "to the points layer.\n" +
                          "〰 Save tracks — pick a time window, Fetch to preview it on the map, " +
                          "then Save: one line per device is added to the tracks layer " +
                          "(or replaces that device's previous track, if set in Settings).\n\n" +
                          "Fields are matched by name; fields not in your layer are skipped. " +
                          "Saves wait automatically while QFieldCloud is syncing."
                }

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.bold: true
                    text: "Session Tag  (Settings → Session Tag)"
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "Stamps a text value onto every saved point and track. " +
                          "When saving tracks From feature, the feature's display field value " +
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
                        text: "Tracks"
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

        property bool localUseDisplay: false   // shared between Feature page and Session Tag page

        footer: Item { height: 0 }

        // Populate controls from current config when dialog opens
        onOpened: {
            urlField.text      = cfg.serverUrl
            userField.text     = cfg.username
            passField.text     = cfg.password
            // Overlay
            liveIntervalSpin.value = cfg.liveIntervalSec
            staleSpin.value        = cfg.staleMinutes
            trailCombo.currentIndex = 2
            for (var ti = 1; ti < timeframeModel.count; ti++) {
                if (timeframeModel.get(ti).minutes === cfg.trailMinutes) {
                    trailCombo.currentIndex = ti
                    break
                }
            }
            // Layers
            populateLayers(ptLayerModel, Qgis.GeometryType.Point)
            restoreSelection(pointsLayerCombo, ptLayerModel, cfg.pointsLayerName)
            if (pointsLayerCombo.currentIndex < 0) pointsLayerCombo.currentIndex = 0
            pointsPerDeviceSpin.value = cfg.pointsPerDevice
            populateLayers(lnLayerModel, Qgis.GeometryType.Line)
            restoreSelection(tracksLayerCombo, lnLayerModel, cfg.tracksLayerName)
            if (tracksLayerCombo.currentIndex < 0) tracksLayerCombo.currentIndex = 0
            trackAddRadio.checked     = cfg.trackMode === 0
            trackReplaceRadio.checked = cfg.trackMode === 1
            populateNameFields(ptNameFieldModel, cfg.pointsLayerName)
            restoreSelection(pointsNameCombo, ptNameFieldModel, cfg.pointsNameField)
            if (pointsNameCombo.currentIndex < 0) pointsNameCombo.currentIndex = 0
            populateNameFields(lnNameFieldModel, cfg.tracksLayerName)
            restoreSelection(tracksNameCombo, lnNameFieldModel, cfg.tracksNameField)
            if (tracksNameCombo.currentIndex < 0) tracksNameCombo.currentIndex = 0
            // Session tag
            incidentRefCheck.checked        = cfg.incidentRefEnabled
            settingsDialog.localUseDisplay  = cfg.useDisplayAsTag
            sessionTagField.text            = cfg.sessionTag
            populateFieldNames(fieldNameModel, [cfg.pointsLayerName, cfg.tracksLayerName])
            restoreSelection(incidentRefFieldCombo, fieldNameModel, cfg.incidentRefField)
            // Event Layer (Save Tracks → From feature)
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

        function refreshTagFields() {
            var prev = cfg.incidentRefField
            populateFieldNames(fieldNameModel, [comboLayerName(pointsLayerCombo, ptLayerModel),
                                                comboLayerName(tracksLayerCombo, lnLayerModel)])
            restoreSelection(incidentRefFieldCombo, fieldNameModel, prev)
        }

        // Re-list text fields after a layer change, keeping the choice if that field still exists
        function refreshNameFields(combo, model, layerCombo, layerModel, prev) {
            populateNameFields(model, comboLayerName(layerCombo, layerModel))
            restoreSelection(combo, model, prev)
            if (combo.currentIndex < 0) combo.currentIndex = 0
        }

        function saveSettings() {
            cfg.serverUrl   = urlField.text.trim().replace(/\/+$/, "")
            cfg.username    = userField.text.trim()
            cfg.password    = passField.text
            // Overlay
            cfg.liveIntervalSec = liveIntervalSpin.value
            cfg.staleMinutes    = staleSpin.value
            var newTrail = (trailCombo.currentIndex > 0)
                           ? timeframeModel.get(trailCombo.currentIndex).minutes : 30
            var trailChanged = newTrail !== cfg.trailMinutes
            cfg.trailMinutes = newTrail
            // Layers
            cfg.pointsLayerName = comboLayerName(pointsLayerCombo, ptLayerModel)
            cfg.pointsPerDevice = pointsPerDeviceSpin.value
            cfg.tracksLayerName = comboLayerName(tracksLayerCombo, lnLayerModel)
            cfg.trackMode       = trackReplaceRadio.checked ? 1 : 0
            cfg.pointsNameField = comboNameField(pointsNameCombo, ptNameFieldModel)
            cfg.tracksNameField = comboNameField(tracksNameCombo, lnNameFieldModel)
            // Session tag
            cfg.incidentRefEnabled  = incidentRefCheck.checked
            cfg.useDisplayAsTag     = settingsDialog.localUseDisplay
            if (incidentRefFieldCombo.currentIndex >= 0 && fieldNameModel.count > 0) {
                var refItem = fieldNameModel.get(incidentRefFieldCombo.currentIndex)
                cfg.incidentRefField = (refItem && !refItem.isHeader) ? refItem.name : ""
            } else {
                cfg.incidentRefField = ""
            }
            cfg.sessionTag = sessionTagField.text.trim()
            // Event Layer (Save Tracks → From feature)
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
            if (trailChanged && cfg.liveOn) seedTrails()
            mainWindow.displayToast("Settings saved")
        }

        // ── Section selector + paged content ──────────────────────────────
        ButtonGroup { id: settingsSectionGroup }
        ButtonGroup { id: trackModeGroup }

        ScrollView {
            width:        parent.width
            height:       mainWindow.height * 0.78
            contentWidth: parent.width
            clip:         true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width:   parent.width
                spacing: 4

                // ── Radio nav (2-column grid) ──────────────────────────────
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
                        id:    s5Radio
                        text:  "Overlay"
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

                // ══ Page 2 — Overlay ══════════════════════════════════════
                ColumnLayout {
                    visible:          s5Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "The live overlay is drawn on top of the map and never written to file. " +
                              "Switch individual overlays on/off from the main dialog."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    Label { text: "Refresh every:" }
                    RowLayout {
                        SpinBox { id: liveIntervalSpin; from: 2; to: 300; value: 10; editable: true }
                        Label   { text: "seconds" }
                    }
                    Label { text: "Trail length:" }
                    ComboBox {
                        id: trailCombo; Layout.fillWidth: true
                        model: timeframeModel; textRole: "label"
                        delegate: ItemDelegate {
                            width: trailCombo.width
                            enabled: model.minutes > 0 && model.minutes <= 1440
                            contentItem: Text {
                                text: model.label; verticalAlignment: Text.AlignVCenter
                                color: parent.enabled ? Theme.mainTextColor : Theme.secondaryTextColor
                                font.pixelSize: 13
                            }
                            highlighted: trailCombo.highlightedIndex === index
                        }
                    }
                    Label { text: "Grey marker when last fix is older than:" }
                    RowLayout {
                        SpinBox { id: staleSpin; from: 1; to: 1440; value: 10; editable: true }
                        Label   { text: "min" }
                    }
                }

                // ══ Page 3 — Layers ═══════════════════════════════════════
                ColumnLayout {
                    visible:          s2Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "Layers are only written when you press Save positions / Save tracks."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    Label {
                        text: "Points layer"
                        font.bold: true; Layout.fillWidth: true
                    }
                    ComboBox {
                        id: pointsLayerCombo; Layout.fillWidth: true
                        model: ptLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: pointsLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: pointsLayerCombo.highlightedIndex === index
                        }
                        onActivated: {
                            settingsDialog.refreshTagFields()
                            settingsDialog.refreshNameFields(pointsNameCombo, ptNameFieldModel,
                                pointsLayerCombo, ptLayerModel, cfg.pointsNameField)
                        }
                    }
                    Label { text: "Write device name into:"; font.pixelSize: 12 }
                    ComboBox {
                        id: pointsNameCombo; Layout.fillWidth: true
                        model: ptNameFieldModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: pointsNameCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: pointsNameCombo.highlightedIndex === index
                        }
                    }
                    RowLayout {
                        Label { text: "Points per device per save:" }
                        SpinBox { id: pointsPerDeviceSpin; from: 1; to: 1000; value: 1; editable: true }
                    }
                    Label {
                        text: "1 = current position only.  More = the most recent fixes from the last 24 h."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }

                    Item { height: 4 }
                    Label {
                        text: "Tracks layer"
                        font.bold: true; Layout.fillWidth: true
                    }
                    ComboBox {
                        id: tracksLayerCombo; Layout.fillWidth: true
                        model: lnLayerModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: tracksLayerCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: tracksLayerCombo.highlightedIndex === index
                        }
                        onActivated: {
                            settingsDialog.refreshTagFields()
                            settingsDialog.refreshNameFields(tracksNameCombo, lnNameFieldModel,
                                tracksLayerCombo, lnLayerModel, cfg.tracksNameField)
                        }
                    }
                    Label { text: "Write device name into:"; font.pixelSize: 12 }
                    ComboBox {
                        id: tracksNameCombo; Layout.fillWidth: true
                        model: lnNameFieldModel; textRole: "name"
                        delegate: ItemDelegate {
                            width: tracksNameCombo.width; enabled: !model.isHeader
                            contentItem: Text {
                                text: model.name; verticalAlignment: Text.AlignVCenter
                                color: model.isHeader ? Theme.secondaryTextColor : Theme.mainTextColor
                                font.pixelSize: model.isHeader ? 10 : 13
                                leftPadding: model.isHeader ? 4 : 12
                            }
                            highlighted: tracksNameCombo.highlightedIndex === index
                        }
                    }
                    Label { text: "On each save:"; font.pixelSize: 12 }
                    RadioButton {
                        id:    trackAddRadio
                        text:  "Add a new track per device (keep all)"
                        ButtonGroup.group: trackModeGroup
                        checked: true
                        font.pixelSize: 12
                    }
                    RadioButton {
                        id:    trackReplaceRadio
                        text:  "Keep only the most recent track per device"
                        ButtonGroup.group: trackModeGroup
                        font.pixelSize: 12
                    }
                    Label {
                        visible: trackReplaceRadio.checked
                        text: "Saving replaces every earlier track of that device in the layer. " +
                              "Devices are matched by device_id, or by the device name field " +
                              "if the layer has no device_id."
                        font.pixelSize: 11; color: "#E65100"
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }

                    Item { height: 2 }
                    Label {
                        text: "Fields filled when present — points: device_id, name, status, fix_time, " +
                              "fix_local, speed_kmh, course, altitude_m, accuracy_m, battery, address, motion, " +
                              "fetched_at.  Tracks: device_id, name, start_time, last_update, start_local, " +
                              "last_local, from_time, to_time, n_points, saved_at.  " +
                              "Times are stored in UTC; *_local fields hold local time as text.  " +
                              "Select '— no layer —' to disable a layer."
                        font.pixelSize: 11; color: Theme.secondaryTextColor
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                }

                // ══ Page 4 — From Feature ═════════════════════════════════
                ColumnLayout {
                    visible:          s3Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "Pick a layer and date/time fields so Save Tracks can derive " +
                              "its time window directly from a selected feature.\n\n" +
                              "When fetching from a feature the display field value " +
                              "(e.g. incident_ref) is automatically used as the session tag " +
                              "for those tracks, if session tagging is enabled."
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

                // ══ Page 5 — Session Tag ══════════════════════════════════
                ColumnLayout {
                    visible:          s4Radio.checked
                    Layout.fillWidth: true
                    spacing:          3

                    Label {
                        text: "Stamp a text tag on every point and track saved to the points and tracks layers."
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
                        text: "Tag value  (stamped on every saved feature):"
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
                        text: "Write tag into field  (same field name on both layers):"
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
                        text: "When 'From feature' is used in Save Tracks, the selected feature's " +
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
    //  SAVE TRACKS DIALOG
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

        header: ToolBar {
            background: Rectangle { color: "#1565C0" }
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                Label {
                    text:             "〰  Save Tracks"
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
            if (fromDateField.text === "") fromDateField.text = today
            if (toDateField.text   === "") toDateField.text   = today
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

                // ── Output layer (read-only info) ──────────────────────────
                Item { height: 2 }
                Label {
                    text: cfg.tracksLayerName !== ""
                          ? "Saves to:  " + cfg.tracksLayerName + "  ("
                            + (cfg.trackMode === 1 ? "replaces each device's previous track"
                                                   : "adds a new track per device") + ")"
                          : "⚠  No tracks layer configured — set it in Settings → Layers"
                    color: cfg.tracksLayerName !== "" ? Theme.secondaryTextColor : "#B71C1C"
                    font.pixelSize:   11
                    wrapMode:         Text.WordWrap
                    Layout.fillWidth: true
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

                // ── Step 1: fetch + preview   Step 2: save ──────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text:             fetchLogsDialog.fetchLogBusy ? "Fetching…" : "1. Fetch & preview"
                        Layout.fillWidth: true
                        enabled:          !fetchLogsDialog.fetchLogBusy &&
                                          fetchLogsDialog.fetchDevices.length > 0
                        onClicked:        fetchLogs()
                    }
                    Button {
                        text:             "2. Save"
                        Layout.fillWidth: true
                        enabled:          !fetchLogsDialog.fetchLogBusy &&
                                          plugin.previewInfo !== null &&
                                          cfg.tracksLayerName !== ""
                        onClicked:        saveTracks()
                    }
                }
                Button {
                    visible: plugin.previewInfo !== null
                    Layout.fillWidth: true
                    flat: true; font.pixelSize: 11
                    text: "Clear preview"
                    onClicked: clearPreview()
                }

                // ── Session save history ────────────────────────────────────
                Item { height: 3 }
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "── History ──"; font.bold: true; Layout.fillWidth: true }
                    Button {
                        text: "Clear"; flat: true; font.pixelSize: 11
                        visible: plugin.fetchLog.length > 0
                        onClicked: plugin.fetchLog = []
                    }
                }

                Label {
                    visible:          plugin.fetchLog.length === 0
                    Layout.fillWidth: true
                    text:             "Nothing fetched or saved yet this session."
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
                                text: modelData.ts + "  [" + modelData.kind + "]"
                                    + "  " + modelData.nDevs + " dev"
                                    + (modelData.nDevs !== 1 ? "s" : "")
                                    + "  " + modelData.nPts + " pts"
                                    + (modelData.fromIso !== ""
                                       ? "\n" + _fmtLocal(modelData.fromIso) + " → " + _fmtLocal(modelData.toIso)
                                       : "")
                            }
                            Repeater {
                                model: modelData.devs
                                delegate: Label {
                                    width:          parent.width
                                    wrapMode:       Text.WordWrap
                                    font.pixelSize: 10
                                    color: modelData.pts > 0
                                           ? Theme.mainTextColor : Theme.secondaryTextColor
                                    text: (modelData.pts > 0 ? "● " : "○ ")
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
    //  LIVE FETCH  (overlay only — never writes to layers)
    // ════════════════════════════════════════════════════════════════════════

    function fetchAll() {
        // Watchdog: a request that never returned must not block polling forever
        if (plugin.fetchBusy && Date.now() - plugin.fetchStarted < 30000) return
        plugin.fetchBusy    = true
        plugin.fetchStarted = Date.now()

        var onErr = function(msg) {
            plugin.fetchBusy = false
            if (plugin.liveError === "") mainWindow.displayToast(msg)   // toast once per error streak
            plugin.liveError = msg
        }

        _get("/api/devices", function(devData) {
            var lookup = _lookupFromDevices(devData)
            plugin.deviceInfo = lookup
            // Current positions only — last known fix per device
            _get("/api/positions", function(posData) {
                plugin.fetchBusy = false
                plugin.liveError = ""
                _onLivePositions(posData, lookup)
            }, onErr)
        }, onErr)
    }

    function _lookupFromDevices(devData) {
        var lookup = {}
        devData.forEach(function(d) {
            lookup[d.id] = { name: d.name || String(d.id), status: d.status || "unknown" }
        })
        return lookup
    }

    function _onLivePositions(posData, lookup) {
        plugin.positions   = posData
        plugin.lastFetched = Qt.formatTime(new Date(), "hh:mm:ss")
                           + "  -  " + posData.length + " device(s)"

        var model = []
        posData.forEach(function(p) {
            if (p.latitude === undefined || p.longitude === undefined) return
            var info  = lookup[p.deviceId] || {}
            var attrs = p.attributes || {}
            model.push({
                id:      p.deviceId,
                name:    info.name || String(p.deviceId),
                lon:     p.longitude,
                lat:     p.latitude,
                acc:     p.accuracy || 0,
                fixTime: p.fixTime || "",
                fresh:   _isFresh(p.fixTime),
                speed:   p.speed || 0,
                battery: (attrs.batteryLevel !== undefined) ? attrs.batteryLevel : null
            })
        })
        plugin.overlayModel = model

        if (cfg.showTrails) {
            if (!plugin.trailsSeeded) seedTrails()
            else                      _extendTrails(posData)
        }
    }

    // ── Trails: fill from server history, then extend with each poll ──────
    function seedTrails() {
        var ids = Object.keys(plugin.deviceInfo)
        if (ids.length === 0) return
        plugin.trailsSeeded = true
        var toIso   = new Date().toISOString()
        var fromIso = new Date(Date.now() - cfg.trailMinutes * 60000).toISOString()
        var fresh   = {}
        var pending = ids.length
        var done = function() {
            if (--pending > 0) return
            plugin.trails = _trimTrails(fresh)
            _rebuildTrailModel()
        }
        ids.forEach(function(devId) {
            _get("/api/positions?deviceId=" + devId
                    + "&from=" + encodeURIComponent(fromIso)
                    + "&to="   + encodeURIComponent(toIso),
                function(hist) {
                    hist.sort(function(a, b) { return (a.fixTime || "") < (b.fixTime || "") ? -1 : 1 })
                    fresh[String(devId)] = hist
                        .filter(function(p) { return p.latitude !== undefined && p.longitude !== undefined })
                        .map(function(p) { return { lon: p.longitude, lat: p.latitude, t: p.fixTime || "" } })
                    done()
                },
                function(msg) { done() })   // a failed device just has no trail yet
        })
    }

    function _extendTrails(posData) {
        var t = {}
        for (var k in plugin.trails) t[k] = plugin.trails[k]
        posData.forEach(function(p) {
            if (p.latitude === undefined || p.longitude === undefined) return
            var key  = String(p.deviceId)
            var arr  = (t[key] || []).slice()
            var last = arr.length > 0 ? arr[arr.length - 1] : null
            if (!last || last.t !== (p.fixTime || "")) {
                arr.push({ lon: p.longitude, lat: p.latitude, t: p.fixTime || "" })
                t[key] = arr
            }
        })
        plugin.trails = _trimTrails(t)
        _rebuildTrailModel()
    }

    function _trimTrails(t) {
        var cutoff = Date.now() - cfg.trailMinutes * 60000
        var out = {}
        for (var k in t) {
            out[k] = t[k].filter(function(v) {
                return v.t === "" || new Date(v.t).getTime() >= cutoff
            })
        }
        return out
    }

    function _rebuildTrailModel() {
        var model = []
        for (var k in plugin.trails) {
            var arr = plugin.trails[k]
            if (arr.length < 2) continue
            model.push({
                id:     k,
                fresh:  _isFresh(arr[arr.length - 1].t),
                coords: _decimate(arr, 1000)
            })
        }
        plugin.trailModel = model
    }

    function testConnection() {
        mainWindow.displayToast("Testing…")
        _get("/api/devices", function(data) {
            mainWindow.displayToast("✓ Connected — " + data.length + " device(s)")
        })
    }

    function zoomToDevice(pos) {
        if (pos.longitude === undefined || pos.latitude === undefined) return
        try {
            var dst = plugin.mapCanvas.mapSettings.destinationCrs
            var rpt = GeometryUtils.reprojectPoint(
                GeometryUtils.point(pos.longitude, pos.latitude), plugin.wgs84, dst)
            plugin.mapCanvas.mapSettings.setCenter(rpt, true)
        } catch(e) {
            mainWindow.displayToast("Zoom error: " + e)
        }
    }

    // ── Session history ───────────────────────────────────────────────────
    // kind — "positions saved" / "tracks fetched" / "tracks saved"
    // fromIso / toIso — the UTC window used (empty string for a snapshot)
    function _addToFetchLog(positions, deviceInfo, kind, fromIso, toIso) {
        var ptsByDev   = {}
        var firstByDev = {}
        var lastByDev  = {}
        positions.forEach(function(p) {
            var k = String(p.deviceId)
            ptsByDev[k] = (ptsByDev[k] || 0) + 1
            if (!firstByDev[k] || (p.fixTime || "") < (firstByDev[k].fixTime || ""))
                firstByDev[k] = p
            if (!lastByDev[k] || (p.fixTime || "") > (lastByDev[k].fixTime || ""))
                lastByDev[k] = p
        })
        var devRows = []
        for (var devId in deviceInfo) {
            var info  = deviceInfo[devId]
            var first = firstByDev[String(devId)]
            var last  = lastByDev[String(devId)]
            devRows.push({
                name:   info.name   || String(devId),
                pts:    ptsByDev[String(devId)] || 0,
                loc:    last ? (parseFloat(last.latitude).toFixed(5)
                                + ", " + parseFloat(last.longitude).toFixed(5)) : "—",
                // single fix → its time; several → first–last fix time
                fix:    !last ? "—"
                        : (ptsByDev[String(devId)] > 1 ? _spanText(first.fixTime, last.fixTime)
                                                        : _fmtLocal(last.fixTime))
            })
        }
        devRows.sort(function(a, b) { return a.name.localeCompare(b.name) })

        var log = plugin.fetchLog.slice()
        log.push({
            ts:      Qt.formatTime(new Date(), "HH:mm:ss"),
            kind:    kind,
            nDevs:   devRows.length,
            nPts:    positions.length,
            fromIso: fromIso || "",
            toIso:   toIso   || "",
            devs:    devRows
        })
        plugin.fetchLog = log
    }

    // "09:09 – 09:22" (same day as today), otherwise with dates; local time
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

    // One line per device for the fetch result: what each device actually has in the window
    function _deviceSpanLines(byDev, devLookup) {
        var rows = []
        for (var devId in devLookup) {
            var name = devLookup[devId].name || String(devId)
            var pts  = byDev[String(devId)]
            rows.push({ name: name, text: (pts && pts.length > 0)
                ? "• " + name + ": " + pts.length + " pts, "
                  + _spanText(pts[0].fixTime, pts[pts.length - 1].fixTime)
                : "• " + name + ": no fixes in this window" })
        }
        rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
        return rows.map(function(r) { return r.text }).join("\n")
    }

    function _fmtLocal(iso) {
        if (!iso) return "—"
        var d = new Date(iso)
        return isNaN(d.getTime()) ? String(iso) : Qt.formatDateTime(d, "dd MMM HH:mm")
    }

    // ── Load device list into the Save Tracks dialog ──────────────────────
    function loadFetchDevices() {
        if (plugin.previewInfo === null) fetchLogsDialog.fetchStatus = "Loading devices…"
        fetchLogsDialog.fetchDevices = []
        _get("/api/devices", function(data) {
            fetchLogsDialog.fetchDevices = data
            if (plugin.previewInfo !== null) return   // keep showing what is ready to save
            fetchLogsDialog.fetchStatus = data.length > 0
                ? data.length + " device(s) found — set a time window and tap Fetch"
                : "No devices found on server"
        }, function(msg) {
            fetchLogsDialog.fetchStatus = msg
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

    // ════════════════════════════════════════════════════════════════════════
    //  SAVE TRACKS — step 1: fetch the window and preview it on the map
    // ════════════════════════════════════════════════════════════════════════

    // Returns {fromIso, toIso, featureDisplay} or {error}
    function _resolveWindow() {
        if (quickRangeRadio.checked) {
            // ── Time period ───────────────────────────────────────────────
            var qrIdx     = quickRangeCombo.currentIndex
            var qrMinutes = (qrIdx > 0) ? timeframeModel.get(qrIdx).minutes : 0
            if (qrMinutes <= 0) return { error: "Select a time period or switch to Custom dates" }
            var now = new Date()
            return { fromIso: new Date(now.getTime() - qrMinutes * 60000).toISOString(),
                     toIso:   now.toISOString(), featureDisplay: "" }
        }

        if (customDatesRadio.checked) {
            // ── Custom date range ─────────────────────────────────────────
            var fromDate = _parseDate(fromDateField.text)
            var toDate   = _parseDate(toDateField.text)
            if (!fromDate || !toDate)
                return { error: "Enter date/time as YYYY-MM-DD HH:MM (time optional)" }
            // If the user entered a date-only "To" (no space → no time), extend to
            // 23:59:59 so the whole day is included.  If a time was provided, use it exactly.
            var toHasTime = toDateField.text.trim().indexOf(" ") >= 0
            var toDateEnd = toHasTime ? toDate
                          : new Date(toDate.getFullYear(), toDate.getMonth(),
                                     toDate.getDate(), 23, 59, 59, 0)
            if (fromDate > toDateEnd) return { error: "'From' must not be after 'To'" }
            return { fromIso: fromDate.toISOString(), toIso: toDateEnd.toISOString(), featureDisplay: "" }
        }

        // ── From feature ──────────────────────────────────────────────────
        var fi = eventFeatureCombo.currentIndex
        if (fi < 0 || eventFeatureModel.count === 0) return { error: "Select a feature" }
        var feat = eventFeatureModel.get(fi)
        if (feat.fid < 0) return { error: "Configure Event Layer in Settings first" }
        var disp = feat.disp || ""
        if (betweenRadio.checked) {
            if (feat.startIso === "") return { error: "Selected feature has no start time value" }
            return { fromIso: new Date(feat.startIso).toISOString(),
                     toIso:   feat.endIso !== "" ? new Date(feat.endIso).toISOString()
                                                 : new Date().toISOString(),
                     featureDisplay: disp }
        }
        if (forwardRadio.checked) {
            if (feat.startIso === "") return { error: "Selected feature has no start time value" }
            var sd = new Date(feat.startIso)
            return { fromIso: sd.toISOString(),
                     toIso:   new Date(sd.getTime() + featureDurationSpin.value * 60000).toISOString(),
                     featureDisplay: disp }
        }
        // backwardRadio
        if (feat.endIso === "") return { error: "Selected feature has no end time value" }
        var ed = new Date(feat.endIso)
        return { fromIso: new Date(ed.getTime() - featureDurationSpin.value * 60000).toISOString(),
                 toIso:   ed.toISOString(), featureDisplay: disp }
    }

    function fetchLogs() {
        if (fetchLogsDialog.fetchLogBusy) return
        var win = _resolveWindow()
        if (win.error) { fetchLogsDialog.fetchStatus = win.error; return }

        // Build device ID list and lookup — always all devices
        var devs      = fetchLogsDialog.fetchDevices
        var devLookup = {}
        for (var i = 0; i < devs.length; i++) {
            devLookup[devs[i].id] = {
                name:   devs[i].name   || String(devs[i].id),
                status: devs[i].status || ""
            }
        }
        var devIds = Object.keys(devLookup)
        if (devIds.length === 0) { fetchLogsDialog.fetchStatus = "No devices to fetch"; return }

        fetchLogsDialog.fetchLogBusy = true
        fetchLogsDialog.fetchStatus  = "Fetching " + devIds.length + " device(s)…"

        var fromEnc = encodeURIComponent(win.fromIso)
        var toEnc   = encodeURIComponent(win.toIso)
        var byDev   = {}
        var allPos  = []
        var failed  = 0
        var pending = devIds.length

        var done = function() {
            if (--pending > 0) return   // wait for all devices
            fetchLogsDialog.fetchLogBusy = false
            _addToFetchLog(allPos, devLookup, "tracks fetched", win.fromIso, win.toIso)
            if (allPos.length === 0) {
                clearPreview()
                fetchLogsDialog.fetchStatus = "No positions found in this time range"
                    + (failed > 0 ? "  (" + failed + " device request(s) failed)" : "")
                return
            }
            // Session tag: feature display value overrides the configured tag
            // (only when the user has enabled "Use display field as session tag")
            var tag = (cfg.useDisplayAsTag && win.featureDisplay !== "") ? win.featureDisplay : ""
            plugin.preview     = byDev
            plugin.previewInfo = { fromIso: win.fromIso, toIso: win.toIso, lookup: devLookup,
                                   tag: tag, nPts: allPos.length }
            _rebuildPreviewModel()
            if (!cfg.showPreview) cfg.showPreview = true
            var nTracks = Object.keys(byDev).length
            fetchLogsDialog.fetchStatus = nTracks + " track(s), " + allPos.length + " pts — "
                + _fmtLocal(win.fromIso) + " → " + _fmtLocal(win.toIso)
                + (failed > 0 ? "  (" + failed + " device request(s) failed)" : "")
                + "\n" + _deviceSpanLines(byDev, devLookup)
                + "\nShown dashed on the map. Tap Save to write to the tracks layer."
        }

        devIds.forEach(function(devId) {
            _get("/api/positions?deviceId=" + devId + "&from=" + fromEnc + "&to=" + toEnc,
                function(hist) {
                    var valid = hist.filter(function(p) {
                        return p.latitude !== undefined && p.longitude !== undefined
                    })
                    valid.sort(function(a, b) { return (a.fixTime || "") < (b.fixTime || "") ? -1 : 1 })
                    if (valid.length > 0) byDev[String(devId)] = valid
                    for (var j = 0; j < valid.length; j++) allPos.push(valid[j])
                    done()
                },
                function(msg) { failed++; done() })
        })
    }

    function _rebuildPreviewModel() {
        var model = []
        for (var k in plugin.preview) {
            var coords = plugin.preview[k].map(function(p) { return { lon: p.longitude, lat: p.latitude } })
            if (coords.length < 2) continue
            model.push({ id: k, coords: _decimate(coords, 1500) })   // full set is still saved
        }
        plugin.previewModel = model
    }

    function clearPreview() {
        plugin.preview      = ({})
        plugin.previewInfo  = null
        plugin.previewModel = []
        fetchLogsDialog.fetchStatus = "Preview cleared"
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SAVE TRACKS — step 2: write the previewed tracks to the tracks layer
    // ════════════════════════════════════════════════════════════════════════

    function saveTracks() {
        if (plugin.previewInfo === null) return
        var byDev = plugin.preview
        var info  = plugin.previewInfo
        fetchLogsDialog.fetchStatus = "Saving…"
        _queueWrite(function() {
            var n = _writeTracks(byDev, info)
            if (n < 0) {
                fetchLogsDialog.fetchStatus = "Save failed — see message"
                return
            }
            var all = []
            for (var k in byDev) all = all.concat(byDev[k])
            _addToFetchLog(all, info.lookup, "tracks saved", info.fromIso, info.toIso)
            fetchLogsDialog.fetchStatus = "✓  Saved " + n + " track(s) to " + cfg.tracksLayerName
            mainWindow.displayToast("✓ Saved " + n + " track(s)")
        })
    }

    // Returns number of tracks written, or -1 on failure
    function _writeTracks(byDev, info) {
        var lyr = _layerByName(cfg.tracksLayerName, "Tracks")
        if (!lyr) return -1
        var fnames = lyr.fields.names
        var nameField = _nameFieldFor(fnames, cfg.tracksNameField)

        // "Keep most recent": match earlier tracks by device_id, else by device name
        var replace = cfg.trackMode === 1
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

        // Collect feature ids of earlier tracks for the devices being saved
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

            for (var devKey in byDev) {
                var pts = byDev[devKey]
                if (pts.length === 0) continue
                var verts = []
                for (var j = 0; j < pts.length; j++) {
                    var xy = _xyForLayer(lyr, pts[j].longitude, pts[j].latitude)
                    var z  = pts[j].altitude || 0
                    var m  = pts[j].fixTime ? Math.round(new Date(pts[j].fixTime).getTime() / 1000) : 0
                    verts.push(xy.x + " " + xy.y + " " + z + " " + m)
                }
                if (verts.length === 1) verts.push(verts[0])   // a line needs two vertices
                var geom = GeometryUtils.createGeometryFromWkt("LineStringZM (" + verts.join(", ") + ")")
                var feat = FeatureUtils.createFeature(lyr, geom)
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

            if (!lyr.commitChanges()) throw "commit failed"
            lyr.triggerRepaint()
        } catch(e) {
            try { lyr.rollBack() } catch(e2) {}
            mainWindow.displayToast("Tracks layer error: " + e)
            return -1
        }
        return written
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SAVE POSITIONS — latest fix (or most recent N fixes) per device
    // ════════════════════════════════════════════════════════════════════════

    function savePositions() {
        if (cfg.pointsLayerName === "") {
            mainWindow.displayToast("Choose a points layer in Settings → Layers")
            return
        }
        if (plugin.saveBusy) return
        plugin.saveBusy = true

        var onErr = function(msg) {
            plugin.saveBusy = false
            mainWindow.displayToast(msg)
        }

        _get("/api/devices", function(devData) {
            var lookup = _lookupFromDevices(devData)
            _get("/api/positions", function(latest) {
                var n = Math.max(1, cfg.pointsPerDevice)
                if (n === 1) { _finishSavePositions(latest, lookup); return }

                // N > 1: most recent N fixes per device from the last 24 h
                var ids = Object.keys(lookup)
                if (ids.length === 0) { _finishSavePositions([], lookup); return }
                var toIso   = new Date().toISOString()
                var fromIso = new Date(Date.now() - 24 * 3600000).toISOString()
                var all     = []
                var pending = ids.length
                ids.forEach(function(devId) {
                    var useLatest = function() {
                        // Fallback: device has no history in 24 h → keep its last known fix
                        for (var i = 0; i < latest.length; i++)
                            if (String(latest[i].deviceId) === String(devId)) all.push(latest[i])
                    }
                    _get("/api/positions?deviceId=" + devId
                            + "&from=" + encodeURIComponent(fromIso)
                            + "&to="   + encodeURIComponent(toIso),
                        function(hist) {
                            hist.sort(function(a, b) { return (a.fixTime || "") < (b.fixTime || "") ? -1 : 1 })
                            var lastN = hist.slice(-n)
                            if (lastN.length === 0) useLatest()
                            else all = all.concat(lastN)
                            if (--pending === 0) _finishSavePositions(all, lookup)
                        },
                        function(msg) {
                            useLatest()
                            if (--pending === 0) _finishSavePositions(all, lookup)
                        })
                })
            }, onErr)
        }, onErr)
    }

    function _finishSavePositions(positions, lookup) {
        var valid = positions.filter(function(p) {
            return p.latitude !== undefined && p.longitude !== undefined
        })
        if (valid.length === 0) {
            plugin.saveBusy = false
            mainWindow.displayToast("No positions to save")
            return
        }
        _queueWrite(function() {
            plugin.saveBusy = false
            var lyr = _layerByName(cfg.pointsLayerName, "Points")
            if (!lyr) return
            try {
                lyr.startEditing()
                var n = _writePointsToLayer(lyr, valid, lookup)
                if (!lyr.commitChanges()) throw "commit failed"
                lyr.triggerRepaint()
                _addToFetchLog(valid, lookup, "positions saved", "", "")
                mainWindow.displayToast("✓ Saved " + n + " point(s) to " + cfg.pointsLayerName)
            } catch(e) {
                try { lyr.rollBack() } catch(e2) {}
                mainWindow.displayToast("Points layer error: " + e)
            }
        })
        // If the write is waiting for QFieldCloud, let the user carry on
        if (plugin.writeQueue.length > 0) plugin.saveBusy = false
    }

    // Returns number of points added
    function _writePointsToLayer(lyr, positions, deviceInfo) {
        var fnames    = lyr.fields.names
        var nameField = _nameFieldFor(fnames, cfg.pointsNameField)
        var savedAt   = new Date().toISOString()
        var added     = 0
        positions.forEach(function(pos) {
            var info  = deviceInfo[pos.deviceId] || {}
            var attrs = pos.attributes || {}
            var xy    = _xyForLayer(lyr, pos.longitude, pos.latitude)
            var geom  = GeometryUtils.createGeometryFromWkt("POINT(" + xy.x + " " + xy.y + ")")
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
            _setAttributes(feat, fnames, vals, "")
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
        var tagText = (tagOverride && tagOverride !== "") ? tagOverride : cfg.sessionTag
        var tagValue = (cfg.incidentRefEnabled && cfg.incidentRefField !== "" && tagText !== "")
                       ? tagText : null
        for (var i = 0; i < fnames.length; i++) {
            if (tagValue !== null && fnames[i] === cfg.incidentRefField)
                feat.setAttribute(i, tagValue)
            else if (vals[fnames[i]] !== undefined && vals[fnames[i]] !== null)
                feat.setAttribute(i, vals[fnames[i]])
        }
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

    // ── Reproject lon/lat to the layer CRS ────────────────────────────────
    function _xyForLayer(lyr, lon, lat) {
        if (lyr.crs.authid === "EPSG:4326") return { x: lon, y: lat }
        var pt = GeometryUtils.reprojectPoint(GeometryUtils.point(lon, lat), plugin.wgs84, lyr.crs)
        return { x: pt.x, y: pt.y }
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
                plugin.saveBusy   = false
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
