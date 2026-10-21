// Copyright (C) 2026 TyHol
// SPDX-License-Identifier: GPL-2.0-or-later
// Test driver: plays QField (main window, map canvas, project, cloud connection,
// point handler), loads ../../main.qml and runs it through every feature.
// Run via run_tests.py, which also provides a fake Traccar server.
import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: root
    width: 600; height: 800
    visible: true

    // ── QField's mainWindow API ───────────────────────────────────────────
    property real sceneTopMargin: 24
    property real sceneBottomMargin: 0
    property var  toasts: []
    function displayToast(msg) { toasts.push(String(msg)); console.log("TOAST " + msg) }

    property alias ifaceObj:   ifaceStub
    property alias projectObj: projectStub

    Row { id: toolbarRow }
    Row { id: canvasActionsRow }                        // QField's long-press map menu toolbar

    QtObject {                                          // QField's long-press map menu
        id: canvasMenuStub
        property var  point: null                       // the long-pressed spot, map CRS
        property bool closed: false
        function close() { closed = true }
    }

    Item {
        id: canvas
        width: 600; height: 500
        property QtObject mapSettings: QtObject {
            property var  destinationCrs: ({ authid: "EPSG:4326", isGeographic: true })
            property real mapUnitsPerPoint: 0.00002
            property var  lastCenter: null
            signal extentChanged()
            signal rotationChanged()
            signal outputSizeChanged()
            function coordinateToScreen(pt) { return Qt.point((pt.x + 6.35) * 20000, (53.38 - pt.y) * 20000) }
            function screenToCoordinate(p) { return { x: p.x / 20000 - 6.35, y: 53.38 - p.y / 20000 } }
            function setCenter(pt, handleMargins) { lastCenter = pt }
        }
    }

    QtObject {
        id: pointHandler
        property var handlers: ({})
        function registerHandler(name, fn) { handlers[name] = fn }
        function deregisterHandler(name) { delete handlers[name] }
    }

    QtObject { id: cloud; property int state: 0 }       // QfCloudConnection: 0 Idle, 1 Busy

    QtObject {                                          // QField's GPS
        id: positionSource
        property var positionInformation: ({ latitude: 53.361, longitude: -6.333,
                                             latitudeValid: true, longitudeValid: true })
    }

    QtObject {
        id: ifaceStub
        function mainWindow() { return root }
        function mapCanvas() { return canvas }
        function findItemByObjectName(n) {
            if (n === "pointHandler") return pointHandler
            if (n === "cloudConnection") return cloud
            if (n === "positionSource") return positionSource
            if (n === "canvasMenu") return canvasMenuStub
            return null
        }
        function addItemToPluginsToolbar(item) { item.parent = toolbarRow }
        function addItemToCanvasActionsToolbar(item) { item.parent = canvasActionsRow }
    }

    QtObject {
        id: projectStub
        property var layers: []
        property var crs: ({ authid: "EPSG:2157", isGeographic: false })   // ITM (faked in GeometryUtils)
        function mapLayersByName(n) { return layers.filter(function(l) { return l.name === n }) }
        function layersMap() {
            var m = {}
            for (var i = 0; i < layers.length; i++) m["L" + i] = layers[i]
            return m
        }
    }

    // ── Fake layers: QGIS-like edit buffer; Z / M added on commit, never dropped ──
    function dimsOfWkb(t) {
        var z = false, m = false
        if (t >= 3000 && t < 4000) { z = true; m = true }
        else if (t >= 2000 && t < 3000) m = true
        else if (t >= 1000 && t < 2000) z = true
        return { z: z, m: m }
    }
    function dimsOfWkt(wkt) {
        var r = /^\s*(Point|LineString|Polygon)\s*(ZM|Z|M)?\s*\(/i.exec(wkt)
        var s = r && r[2] ? r[2].toUpperCase() : ""
        return { z: s.indexOf("Z") >= 0, m: s.indexOf("M") >= 0, ok: !!r }
    }
    function makeLayer(name, geomType, wkb, fields, crs) {
        var lyr = {
            name: name, crs: { authid: crs || "EPSG:4326" }, supportsEditing: true, flags: 0,
            fields: { names: fields.map(function(f) { return f[0] }) },
            _types: fields.map(function(f) { return f[1] }),
            _editing: false, _buffer: [], _deleted: [], _committed: [], _nextId: 1, lastError: "",
            geometryType: function() { return geomType },
            wkbType: function() { return wkb },
            startEditing: function() { this._editing = true; return true },
            _add: function(f) { if (!this._editing) return false; this._buffer.push(f); return true },
            deleteFeature: function(fid) { if (!this._editing) return false; this._deleted.push(fid); return true },
            commitChanges: function() {
                var ld = root.dimsOfWkb(wkb)
                for (var i = 0; i < this._buffer.length; i++) {
                    var gd = root.dimsOfWkt(this._buffer[i].geometry.wkt)
                    if (!gd.ok || (gd.z && !ld.z) || (gd.m && !ld.m)) {
                        this.lastError = "geometry type is not compatible: " + this._buffer[i].geometry.wkt.substr(0, 20)
                        return false
                    }
                }
                var del = this._deleted
                this._committed = this._committed.filter(function(f) { return del.indexOf(f.id) < 0 })
                for (var j = 0; j < this._buffer.length; j++) {
                    this._buffer[j].id = this._nextId++
                    this._committed.push(this._buffer[j])
                }
                this._buffer = []; this._deleted = []; this._editing = false
                return true
            },
            rollBack: function() { this._buffer = []; this._deleted = []; this._editing = false; return true },
            triggerRepaint: function() {}
        }
        projectStub.layers.push(lyr)
        return lyr
    }

    // ── Test runner ───────────────────────────────────────────────────────
    property var  plugin: null
    property var  cfg: null
    property int  passed: 0
    property int  failed: 0
    property var  steps: []
    property int  stepIdx: 0
    property var  waitCond: null
    property real waitUntil: 0
    property string waitName: ""

    function check(name, ok, detail) {
        if (ok) passed++; else failed++
        console.log((ok ? "PASS  " : "FAIL  ") + name + (ok || detail === undefined ? "" : "   → " + detail))
    }
    function waitFor(name, cond, ms) { waitName = name; waitCond = cond; waitUntil = Date.now() + (ms || 8000) }
    function sleep(ms) { var t = Date.now() + ms; waitFor("sleep", function() { return Date.now() >= t }, ms + 1000) }

    Timer {
        id: ticker
        interval: 15; repeat: true
        onTriggered: {
            if (root.waitCond) {
                if (root.waitCond()) root.waitCond = null
                else if (Date.now() > root.waitUntil) { root.check("wait: " + root.waitName, false, "timed out"); root.waitCond = null }
                else return
            }
            if (root.stepIdx >= root.steps.length) { ticker.stop(); root.finish(); return }
            var s = root.steps[root.stepIdx++]
            try { s() } catch (e) { root.check("step " + root.stepIdx + " threw", false, e + "\n" + e.stack) }
        }
    }

    function finish() {
        console.log("RESULT " + passed + " / " + (passed + failed) + " passed")
        Qt.exit(failed === 0 ? 0 : 1)
    }

    function httpGet(path) {
        var x = new XMLHttpRequest()
        x.open("GET", serverUrl + path)
        x.send()
    }
    // What the fake server holds now → serverState (async; wait for it)
    property var serverState: null
    function fetchState() {
        serverState = null
        var x = new XMLHttpRequest()
        x.open("GET", serverUrl + "/test/state")
        x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) serverState = JSON.parse(x.responseText) }
        x.send()
        waitFor("server state", function() { return serverState !== null })
    }
    function tap(lon, lat) {
        var sp = canvas.mapSettings.coordinateToScreen({ x: lon, y: lat })
        return pointHandler.handlers["traccarlive"](Qt.point(sp.x, sp.y), null, "clicked")
    }
    // The confirmation dialog (Move it / Delete…) when it's showing, else undefined
    function confirmDlg() { return opened().filter(function(o) { return o.okText !== undefined })[0] }
    function sendDlg() { return opened().filter(function(o) { return o.nameText !== undefined })[0] }
    function gf(name) { return plugin.geofences.filter(function(g) { return g.name === name })[0] }
    function saved(name) { var g = gf(name); return g !== undefined && !g.pending }   // Traccar's copy
    function wktGeom(wkt) { return { wkt: wkt, asWkt: function(p) { return wkt } } }
    function opened() {
        var out = []
        var res = plugin.resources
        // Popups that are showing (visible is true at once; 'opened' waits for the animation)
        for (var i = 0; i < res.length; i++) if (res[i].open !== undefined && res[i].visible === true) out.push(res[i])
        return out
    }
    function localStr(d) { return Qt.formatDateTime(d, "yyyy-MM-dd HH:mm") }
    function devTrack(id) { return plugin.tracks[String(id)] || [] }
    // The first item called n inside item (a popup: its contentItem), else null
    function childByName(item, n) {
        if (!item) return null
        if (item.objectName === n) return item
        var ch = item.children || []
        for (var i = 0; i < ch.length; i++) {
            var r = childByName(ch[i], n)
            if (r) return r
        }
        return null
    }
    function lastOf(lyr) { return lyr._committed[lyr._committed.length - 1] }

    // Visible items of a dialog that stick out past its content's left / right edge
    function overflowing(dialog) {
        var content = dialog.contentItem, w = content.width, out = []
        function walk(item, depth) {
            if (!item || !item.visible || depth > 40) return
            var kids = item.children || []
            for (var i = 0; i < kids.length; i++) {
                var c = kids[i]
                if (!c || !c.visible || c.width <= 0 || c.opacity === 0) continue
                // what a person sees: controls and text (not Material's ripple / shadow effects)
                var seen = c.text !== undefined || c.checked !== undefined || c.icon !== undefined
                var p = c.mapToItem(content, 0, 0)
                // squeezed: a button / check box narrower than its own text and icon draws past its edge
                var wraps = c.contentItem && c.contentItem.wrapMode !== undefined && c.contentItem.wrapMode !== Text.NoWrap
                var squeezed = seen && c.contentItem !== undefined && c.elide === undefined && !wraps
                               && c.implicitWidth > c.width + 1
                if (seen && (p.x + c.width > w + 1 || p.x < -1 || squeezed))
                    out.push((c.text !== undefined && c.text !== "" ? "'" + c.text + "' " : "")
                             + String(c).split("(")[0] + " x=" + Math.round(p.x) + " w=" + Math.round(c.width)
                             + (squeezed ? " needs " + Math.round(c.implicitWidth) : "")
                             + " (room " + Math.round(w) + ")")
                else if (!seen || c.contentItem === undefined) walk(c, depth + 1)
            }
        }
        walk(content, 0)
        return out
    }
    function shot(item, name) {
        if (shotDir !== "") item.grabToImage(function(r) { r.saveToFile(shotDir + "/" + name + ".png") })
    }

    function startTests() {
        var comp = Qt.createComponent(mainQmlUrl)
        if (comp.status !== Component.Ready) { console.log("FAIL  load main.qml   → " + comp.errorString()); Qt.exit(2); return }
        plugin = comp.createObject(root)
        var res = plugin.resources
        for (var i = 0; i < res.length; i++) if (res[i].category === "TraccarLive") cfg = res[i]
        var L = {}

        steps = [
        function() {
            check("plugin loads", plugin !== null && cfg !== null)
            check("Live is on by default (remembered); nothing loads before a login", cfg.liveOn === true && !plugin.loading)
            cfg.liveOn = false                          // the tests start Live themselves
            check("marker tap handler registered", typeof pointHandler.handlers["traccarlive"] === "function")
            check("toolbar button added", toolbarRow.children.length === 1)
            cfg.serverUrl = serverUrl; cfg.username = "wrong"; cfg.password = "x"
            cfg.windowMinutes = 180
            plugin.reloadWindow()
            waitFor("load (wrong password)", function() { return !plugin.loading })
        },
        function() {
            check("wrong password → clear error", plugin.liveError.indexOf("401") >= 0 && plugin.win === null, plugin.liveError)
            cfg.username = "test@example.com"; cfg.password = "secret"   // pragma: allowlist secret (fake server)
            plugin.reloadWindow()
            waitFor("load last 3 h", function() { return !plugin.loading }, 20000)
        },
        function() { fetchState() },
        function() {
            check("a window loads with one route report for all devices (not one request per device)",
                  serverState.calls.route === 1 && serverState.calls.per_device === 0, JSON.stringify(serverState.calls))
            check("Phone A: 240 fixes in last 3 h", devTrack(1).length === 240, devTrack(1).length)
            check("markers for Phone A + Van 3", plugin.overlayModel.length === 2, plugin.overlayModel.length)
            check("one track line drawn", plugin.trackModel.length === 1)
            var spare = plugin.deviceRows.filter(function(r) { return r.name === "Spare" })[0]
            check("device list: 3 rows, Spare 'no fixes in window'",
                  plugin.deviceRows.length === 3 && spare && spare.line === "no fixes in window")
            toolbarRow.children[0].clicked()
            sleep(200)
        },
        function() {
            check("toolbar button opens the main window", opened().length === 1)
            opened()[0].close()
            // Race: a new window chosen while the previous load is still running
            cfg.windowMinutes = 60;  plugin.reloadWindow()
            cfg.windowMinutes = 180; plugin.reloadWindow()
            waitFor("race load", function() { return !plugin.loading })
        },
        function() { sleep(400) },          // let any late replies from the first load arrive
        function() {
            check("latest window choice wins when changed during a load",
                  plugin.win && plugin.win.trimMinutes === 180 && devTrack(1).length === 240,
                  (plugin.win ? plugin.win.trimMinutes : "null") + " / " + devTrack(1).length)
            httpGet("/test/addfix?dev=1")
            sleep(300)
        },
        function() {
            plugin.pollLive()
            waitFor("live poll appends", function() { return devTrack(1).length === 241 })
        },
        function() {
            check("Live: new fix appended", devTrack(1).length === 241)
            // Race: Live reply arriving after the window was changed
            plugin.pollLive()
            plugin.reloadWindow()
            waitFor("reload after poll", function() { return !plugin.loading })
        },
        function() { sleep(400) },
        function() {
            check("Live reply after a window change is ignored (no error)", plugin.win !== null && plugin.liveError === "",
                  plugin.liveError)
            // ── layers ──
            L.pts2d = makeLayer("pts2d", 0, 1, [["device_id", "int"], ["name", "QString"], ["fix_time", "QDateTime"],
                                                ["fix_local", "QString"], ["battery", "double"], ["tag", "QString"]])
            L.ptsZ  = makeLayer("ptsZ", 0, 1001, [["title", "QString"], ["color", "QString"]])
            L.trkZM = makeLayer("trkZM", 1, 3002, [["device_id", "int"], ["name", "QString"], ["start_time", "QDateTime"],
                                                   ["n_points", "int"], ["tag", "QString"]])
            L.trk2D = makeLayer("trk2D", 1, 2, [["title", "QString"], ["n", "int"], ["tag", "QString"]])
            L.trkZ  = makeLayer("trkZ", 1, 1002, [["name", "QString"]])
            L.trkITM = makeLayer("trkITM", 1, 3002, [["name", "QString"]], "EPSG:2157")
            cfg.pointsLayerName = "pts2d"; cfg.pointsMode = 0
            plugin.savePositions()
            var f = lastOf(L.pts2d)
            check("save latest positions → 2 points", L.pts2d._committed.length === 2, L.pts2d._committed.length)
            check("2D point layer gets 'Point (' geometry", f && f.geometry.wkt.indexOf("Point (") === 0, f && f.geometry.wkt)
            var a = L.pts2d._committed.filter(function(x) { return x.attribute("name") === "Phone A" })[0]
            check("fields filled: device_id, battery, fix_time (UTC ISO), fix_local",
                  a && a.attribute("device_id") === 1 && a.attribute("battery") === 81
                  && /Z$/.test(a.attribute("fix_time")) && a.attribute("fix_local") !== null)

            cfg.pointsLayerName = "ptsZ"; cfg.pointsNameField = "title"
            plugin.savePositions()
            f = lastOf(L.ptsZ)
            check("Point Z layer (like QField Notes): 'PointZ' with altitude", f && f.geometry.wkt.indexOf("PointZ (") === 0
                  && f.geometry.wkt.split(" ").length === 4, f && f.geometry.wkt)
            check("device name → title", L.ptsZ._committed.some(function(x) { return x.attribute("title") === "Phone A" }))

            cfg.pointsLayerName = "pts2d"; cfg.pointsMode = 1; cfg.pointsNameField = ""
            var n0 = L.pts2d._committed.length
            plugin.savePositions()
            check("every fix in window → 241 points", L.pts2d._committed.length - n0 === 241, L.pts2d._committed.length - n0)
            cfg.pointsMode = 0

            cfg.tracksLayerName = "trkZM"; cfg.trackMode = 0
            plugin.saveTracks()
            f = lastOf(L.trkZM)
            check("ZM track layer: 'LineStringZM', n_points, device_id",
                  f && f.geometry.wkt.indexOf("LineStringZM (") === 0 && f.attribute("n_points") === 241
                  && f.attribute("device_id") === 1, f && f.geometry.wkt.substr(0, 40))

            cfg.tracksLayerName = "trk2D"; cfg.tracksNameField = "title"; cfg.trackMode = 1
            plugin.saveTracks(); plugin.saveTracks()
            f = lastOf(L.trk2D)
            check("2D line layer (was rejected before): 'LineString (' saved", f && f.geometry.wkt.indexOf("LineString (") === 0,
                  f ? f.geometry.wkt.substr(0, 30) : L.trk2D.lastError)
            check("keep most recent, matched by name field (no device_id): 1 track", L.trk2D._committed.length === 1,
                  L.trk2D._committed.length)
            check("device name → title on tracks", f && f.attribute("title") === "Phone A")

            cfg.tracksLayerName = "trkZ"; cfg.tracksNameField = ""; cfg.trackMode = 0
            plugin.saveTracks()
            f = lastOf(L.trkZ)
            check("Z-only line layer: 'LineStringZ' (no M)", f && f.geometry.wkt.indexOf("LineStringZ (") === 0
                  && f.geometry.wkt.split(",")[0].trim().split(" ").length === 4, f ? f.geometry.wkt.substr(0, 40) : L.trkZ.lastError)

            cfg.tracksLayerName = "trkITM"
            plugin.saveTracks()
            f = lastOf(L.trkITM)
            var x0 = f ? parseFloat(f.geometry.wkt.split("(")[1]) : 0
            check("non-WGS84 layer: coordinates reprojected", Math.abs(x0) > 1000, x0)

            var tf = plugin._textFieldNames("trk2D")
            check("name picker lists only text fields", tf.filtered && tf.names.join(",") === "title,tag", tf.names.join(","))

            // QFieldCloud busy → save waits, then runs
            cloud.state = 1
            cfg.pointsLayerName = "pts2d"
            L.before = L.pts2d._committed.length
            plugin.savePositions()
            check("cloud syncing → save queued, not written", plugin.writeQueue.length === 1
                  && L.pts2d._committed.length === L.before)
            cloud.state = 0
            waitFor("queued save runs after sync", function() { return L.pts2d._committed.length === L.before + 2 }, 6000)
        },
        function() {
            check("queued save written once cloud is idle", plugin.writeQueue.length === 0)
            // ── every page of Settings, then every other dialog ──
            var pages = ["", "connection", "layers", "incident", "advanced"]
            for (var i = 0; i < pages.length; i++) {
                plugin.openSettings(pages[i])
                var o = opened()
                check("Settings page '" + (pages[i] || "list") + "' opens", o.length >= 1 && o[0].page === pages[i])
                if (pages[i] === "layers") {
                    var sw = childByName(o[0].contentItem, "autoSaveSwitch")
                    check("Layers: Automatic saving comes first", sw && sw.parent.children[1] === sw)
                }
                for (var k = 0; k < o.length; k++) o[k].close()
            }
            var res = plugin.resources
            for (var j = 0; j < res.length; j++)
                if (res[j].open !== undefined && res[j].visible === false) { res[j].open(); res[j].close() }
            var o2 = opened()
            for (var c = 0; c < o2.length; c++) o2[c].close()
            sleep(200)
        },
        function() {
            // ── colour per device (same as the QGIS plugin), grey when stale ──
            var phone = plugin.overlayModel.filter(function(m) { return m.name === "Phone A" })[0]
            var van   = plugin.overlayModel.filter(function(m) { return m.name === "Van 3" })[0]
            var c1 = Qt.lighter(phone.color, 1), c2 = Qt.lighter(phoneAColor, 1)
            check("device colour matches the QGIS plugin", Math.abs(c1.r - c2.r) < 0.01 && Math.abs(c1.g - c2.g) < 0.01
                  && Math.abs(c1.b - c2.b) < 0.01, phone.color + " vs " + phoneAColor)
            check("stale device grey; track takes the device colour", van.color === "#9E9E9E"
                  && plugin.trackModel[0].color === phone.color, van.color + " / " + plugin.trackModel[0].color)

            // ── grid references ──
            check("Irish Grid reference", plugin._irishGridRef(315904, 234671) === "O 15904 34671"
                  && plugin._irishGridRef(600000, 1) === "", plugin._irishGridRef(315904, 234671))
            check("UK Grid references", plugin._ukGridRef(245140, 672887) === "NS 45140 72887"
                  && plugin._ukGridRef(651409, 313177) === "TG 51409 13177" && plugin._ukGridRef(-5, 10) === "",
                  plugin._ukGridRef(245140, 672887) + " / " + plugin._ukGridRef(651409, 313177))
            var pa = plugin.markerPos["1"]
            cfg.locationFormat = 1
            var ig = plugin._locationText(pa)
            cfg.locationFormat = 2
            var uk = plugin._locationText(pa)
            var far = plugin._locationText({ longitude: 20, latitude: 0 })
            cfg.locationFormat = 0
            check("location as Irish Grid / UK Grid; lat / long outside the grid",
                  /^O \d{5} \d{5}$/.test(ig) && /^[A-Z]{2} \d{5} \d{5}$/.test(uk) && far === "0.000000, 20.000000",
                  ig + " | " + uk + " | " + far)
            cfg.locationFormat = 3
            var dm = plugin._locationText({ latitude: 53.365, longitude: -6.31 })
            var dmEdge = plugin._dmText(53.9999999, 0.5)
            cfg.locationFormat = 4
            var prj = plugin._locationText({ latitude: 53.365, longitude: -6.31 })
            cfg.locationFormat = 0
            check("degrees + minutes", dm === "53° 21.900' N, 6° 18.600' W" && dmEdge === "54° 00.000' N, 0° 30.000' E",
                  dm + " | " + dmEdge)
            check("project CRS: easting, northing", prj === "-631000.0, 5336500.0", prj)
            check("lat / long by default", plugin._locationText(pa) === pa.latitude.toFixed(6) + ", " + pa.longitude.toFixed(6))

            // ── thinning for drawing ──
            var line = [], parked = []
            for (var i = 0; i < 12000; i++) line.push({ lon: i * 0.001, lat: 53 })
            for (var j = 0; j < 3000; j++) parked.push({ lon: -6.3, lat: 53.3 })
            parked.push({ lon: -6.29, lat: 53.3 }, { lon: -6.28, lat: 53.31 })
            var t1 = plugin._thin(line, 5000), t2 = plugin._thin(parked, 5000)
            check("long track thinned to 5000, ends kept", t1.length === 5000 && t1[0].lon === 0
                  && t1[4999].lon === line[11999].lon, t1.length)
            check("parked fixes dropped, moving fixes all kept", t2.length === 3 && t2[2].lat === 53.31, t2.length)

            // ── per device show / hide ──
            plugin.setDeviceShown("1", false)
            var rowA = plugin.deviceRows.filter(function(r) { return r.name === "Phone A" })[0]
            check("untick Phone A: off the map, row unticked, remembered",
                  plugin.overlayModel.length === 1 && plugin.overlayModel[0].name === "Van 3"
                  && plugin.trackModel.length === 0 && rowA.shown === false && cfg.hiddenDevices === "1")
            cfg.pointsLayerName = "pts2d"; cfg.pointsMode = 0
            var n0 = L.pts2d._committed.length
            plugin.savePositions()
            check("hidden device not saved (positions)", L.pts2d._committed.length === n0 + 1
                  && lastOf(L.pts2d).attribute("name") === "Van 3")
            cfg.tracksLayerName = "trkZM"
            var n1 = L.trkZM._committed.length
            plugin.saveTracks()
            check("hidden device not saved (tracks)", L.trkZM._committed.length === n1)
            plugin.setAllShown(false)
            check("hide all", plugin.overlayModel.length === 0 && cfg.hiddenDevices === "1,2,3", cfg.hiddenDevices)
            plugin.setAllShown(true)
            check("show all", plugin.overlayModel.length === 2 && cfg.hiddenDevices === "")
            toolbarRow.children[0].clicked()     // draw the device list with a hidden device
            plugin.setDeviceShown("2", false)
            sleep(200)
        },
        function() {
            opened()[0].close()
            plugin.setAllShown(true)
            // ── geofences from Traccar ──
            plugin.loadGeofences()
            waitFor("geofences load", function() { return plugin.geofences.length === 2 })
        },
        function() {
            // ── phone width: nothing may stick out of the main window ──
            L.wideW = root.width
            L.font = root.font.pixelSize
            root.width = 360
            root.font.pixelSize = 17           // phone-sized text (Android, QField)
            toolbarRow.children[0].clicked()
            sleep(400)
        },
        function() {
            var d = opened()[0]
            var bad = overflowing(d)
            check("phone width (360): Devices tab fits the window", plugin.phone && bad.length === 0, bad.join(" | "))
            shot(d.contentChildren[0], "phone_devices")
            L.tabBar = null
            var find = function(it) { if (!it) return; if (String(it).indexOf("TabBar") === 0) L.tabBar = it
                                      var k = it.children || []; for (var i = 0; i < k.length; i++) find(k[i]) }
            find(d.contentItem)
            L.tabBar.currentIndex = 1
            sleep(300)
        },
        function() {
            var d = opened()[0]
            var bad = overflowing(d)
            check("phone width (360): Geofences tab fits the window", bad.length === 0, bad.join(" | "))
            shot(d.contentChildren[0], "phone_geofences")
            L.tabBar.currentIndex = 0
            d.close()
            // the other screens at phone width too
            plugin.editGeofence(8)                  // a line: description, corridor, speed, calendar, colour
            sleep(300)
        },
        function() {
            var bad = overflowing(sendDlg())
            check("phone width: geofence form fits", bad.length === 0, bad.join(" | "))
            sendDlg().close()
            plugin.startDraw("point")
            tap(-6.31, 53.36)
            sleep(300)
        },
        function() {
            var bad = overflowing(sendDlg())
            check("phone width: point form fits", bad.length === 0, bad.join(" | "))
            sendDlg().close()
            plugin.cancelDraw()
            var res = plugin.resources, layerDlg = null
            for (var i = 0; i < res.length; i++) if (res[i].layerName !== undefined && res[i].geomType !== undefined) layerDlg = res[i]
            L.layerDlg = layerDlg
            layerDlg.open()
            sleep(300)
        },
        function() {
            var bad = overflowing(L.layerDlg)
            check("phone width: From layer fits", bad.length === 0, bad.join(" | "))
            L.layerDlg.close()
            L.pages = ["", "connection", "layers", "incident", "advanced"]
            L.badPages = []
            sleep(200)
        },
        function() {
            opened().forEach(function(o) { o.close() })
            var page = L.pages.shift()
            plugin.openSettings(page)
            sleep(250)
        },
        function() {
            var o = opened().filter(function(x) { return x.page !== undefined })[0]
            var bad = overflowing(o)
            if (bad.length) L.badPages.push((o.page || "list") + ": " + bad.join(", "))
            o.close()
            if (L.pages.length > 0) { stepIdx -= 2; return }   // next page
            check("phone width: every Settings page fits", L.badPages.length === 0, L.badPages.join(" | "))
            opened().forEach(function(x) { x.close() })
            root.width = L.wideW
            root.font.pixelSize = L.font
            sleep(200)
        },
        function() {
            var lake = gf("Lake sector"), trail = gf("Trail")
            check("geofences listed by name, with type and origin",
                  plugin.geofences[0] === lake && lake.kind === "polygon" && !lake.mine
                  && trail.kind === "line" && trail.mine && plugin.geofenceType(trail) === "Line")
            check("each in its own colour: Traccar's 'color', else orange",
                  lake.color === "#1565C0" && trail.color === "#E65100", lake.color + " / " + trail.color)
            check("Traccar's latitude-first text read as lon / lat",
                  lake.coords[0].lon === -6.34 && lake.coords[0].lat === 53.36 && lake.coords.length === 5)
            check("name placed in the middle of the area", Math.abs(lake.labelLon + 6.33) < 1e-9
                  && Math.abs(lake.labelLat - 53.365) < 1e-9, lake.labelLon + ", " + lake.labelLat)
            check("both drawn on the map", plugin.geofenceModel.length === 2)
            var c = plugin.parseArea("CIRCLE (53.36 -6.33, 250)")
            check("circle → 73-point ring, radius kept", c.kind === "circle" && c.coords.length === 73
                  && c.radius === 250 && plugin.geofenceType(c) === "Circle 250 m")
            plugin.setGeofenceShown(7, false)
            check("untick one: hidden from the map, remembered",
                  plugin.geofenceModel.length === 1 && plugin.geofenceModel[0].name === "Trail" && cfg.hiddenGeofences === "7")
            cfg.showGeofences = false
            check("Geofences off under Show: none drawn", plugin.geofenceModel.length === 0)
            cfg.showGeofences = true
            plugin.setAllGeofencesShown(true)
            check("show all again", plugin.geofenceModel.length === 2 && cfg.hiddenGeofences === "")
            // ── shapes → Traccar text ──
            var a = plugin.areaText("polygon", [{ lon: -6.3, lat: 53.3 }, { lon: -6.2, lat: 53.3 }, { lon: -6.2, lat: 53.4 }], 0)
            check("area: latitude first, ring closed",
                  a.area === "POLYGON ((53.300000 -6.300000, 53.300000 -6.200000, 53.400000 -6.200000, 53.300000 -6.300000))",
                  a.area)
            check("too few corners → nothing", plugin.areaText("polygon", [{ lon: 1, lat: 1 }, { lon: 2, lat: 2 }], 0) === null)
            var big = []
            for (var i = 0; i < 400; i++) big.push({ lon: -6.3 + i * 0.0001, lat: 53.3 + (i % 2) * 0.001 })
            var bl = plugin.areaText("line", big, 0)
            check("long shape thinned to fit Traccar's 4096 characters", bl && bl.simplified && bl.area.length <= 4000,
                  bl ? bl.area.length : "null")
            var parts = plugin.wktParts("MultiPolygonZ (((1 2 9, 3 2 9, 3 4 9, 1 2 9), (1.5 2.5 0, 2 2.5 0, 2 3 0, 1.5 2.5 0)),"
                                        + " ((10 20 0, 11 20 0, 11 21 0, 10 20 0)))", { authid: "EPSG:4326" })
            check("multipolygon with a hole and Z: two parts, outer rings only",
                  parts.length === 2 && parts[0].coords.length === 4 && parts[1].coords[0].lon === 10, JSON.stringify(parts))
            var itm = plugin.wktParts("LineString (-630000 5335000, -629000 5336000)", { authid: "EPSG:2157" })
            check("other CRS reprojected to lon / lat", itm.length === 1 && itm[0].kind === "line"
                  && Math.abs(itm[0].coords[0].lon + 6.3) < 1e-9 && Math.abs(itm[0].coords[1].lat - 53.36) < 1e-9,
                  JSON.stringify(itm))
            var mp = plugin.wktParts("MultiPoint ((1 2), (3 4))", { authid: "EPSG:4326" })
            check("multipoint → one point each", mp.length === 2 && mp[1].kind === "point" && mp[1].coords[0].lat === 4)
            // ── change a colour (saved in Traccar) ──
            plugin.setGeofenceColor(7, "#2E7D32")
            waitFor("colour saved", function() { var g = gf("Lake sector"); return g && g.color === "#2E7D32" })
        },
        function() {
            fetchState()
        },
        function() {
            var lake = serverState.geofences.filter(function(g) { return g.id === 7 })[0]
            check("colour change keeps the rest of the geofence", lake.attributes.color === "#2E7D32"
                  && lake.area.indexOf("POLYGON") === 0 && lake.name === "Lake sector", JSON.stringify(lake))
            // ── draw an area on the map ──
            cfg.geofenceColor = "#6A1B9A"
            plugin.startDraw("area")
            check("Add → Area: drawing, map taps taken", plugin.drawMode === "area" && tap(-6.30, 53.37) === true)
            tap(-6.29, 53.37); tap(-6.29, 53.36)
            check("three corners, Done allowed", plugin.drawPts.length === 3 && plugin.canFinishDraw()
                  && Math.abs(plugin.drawPts[1].lon + 6.29) < 1e-9 && Math.abs(plugin.drawPts[1].lat - 53.37) < 1e-9,
                  JSON.stringify(plugin.drawPts))
            plugin.undoDraw()
            check("Undo removes the last corner", plugin.drawPts.length === 2 && !plugin.canFinishDraw())
            tap(-6.29, 53.36)
            plugin.finishDraw()
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("Done opens the name dialog for the area", d && d.mode === "area" && d.coords.length === 3)
            d.nameText = "Sector A"
            d.send()
            check("sent area shown at once (before Traccar replies), marked sending…",
                  gf("Sector A") && gf("Sector A").pending && gf("Sector A").coords.length === 4
                  && plugin.geofenceModel.some(function(g) { return g.name === "Sector A" })
                  && plugin.geofenceLine(gf("Sector A")).indexOf("sending…") >= 0, gf("Sector A") ? plugin.geofenceLine(gf("Sector A")) : "none")
            waitFor("area sent", function() { return saved("Sector A") })
        },
        function() {
            var s = gf("Sector A")
            check("area sent as a geofence in the chosen colour, marked as from QGIS / QField",
                  s.kind === "polygon" && s.coords.length === 4 && s.color === "#6A1B9A" && s.mine)
            check("drawing ends after sending", plugin.drawMode === "" && plugin.drawPts.length === 0)
            plugin.upsertGeofences([{ name: "sector a", area: "CIRCLE (53.36 -6.30, 300)" }], "#C62828")
            waitFor("re-sent", function() { var g = gf("sector a"); return g && g.kind === "circle" })
        },
        function() {
            check("same name again replaces it (no duplicate)", plugin.geofences.length === 3
                  && gf("sector a").color === "#C62828" && gf("Sector A") === undefined, plugin.geofences.length)
            // ── circle at my location ──
            plugin.startDraw("circle")
            plugin.addDrawPoint(plugin.gpsLonLat())
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("circle at 'My location' (GPS)", d && d.mode === "circle" && d.coords[0].lat === 53.361)
            d.nameText = "Base"
            d.send()
            waitFor("circle sent", function() { return saved("Base") })
        },
        function() {
            // ── on a phone: Add here at the crosshair; a finger tap without QField's point handler ──
            plugin.startDraw("area")
            plugin.addDrawPoint(plugin.mapCentreLonLat())
            var c = plugin.drawPts[0]
            check("Add corner: the map centre (crosshair)", c && Math.abs(c.lon + 6.335) < 1e-9
                  && Math.abs(c.lat - 53.3675) < 1e-9, JSON.stringify(c))
            plugin._drawTap(Qt.point(100, 100)); plugin._drawTap(Qt.point(101, 99))
            check("one tap reported twice (QField and the plugin) adds one corner", plugin.drawPts.length === 2,
                  plugin.drawPts.length)
            sleep(500)                                      // the main window finishes closing
        },
        function() {
            check("no dialog left over the map while adding", opened().length === 0)
            L.saveHandler = pointHandler.handlers["traccarlive"]
            delete pointHandler.handlers["traccarlive"]    // as QField 3.x: finger taps never reach plugins
            var sp = canvas.mapToItem(root.contentItem, 200, 300)
            finger.tap(Math.round(sp.x), Math.round(sp.y))
            sleep(300)
        },
        function() {
            pointHandler.handlers["traccarlive"] = L.saveHandler
            var c = plugin.drawPts[2]
            check("finger tap on the map adds a corner even when QField doesn't pass taps on",
                  plugin.drawPts.length === 3 && c && Math.abs(c.lon - (200 / 20000 - 6.35)) < 1e-6
                  && Math.abs(c.lat - (53.38 - 300 / 20000)) < 1e-6, JSON.stringify(plugin.drawPts))
            plugin.cancelDraw()
            sleep(100)
        },
        function() {
            // ── long-press (right-click) on the map → QField's map menu → Send to Traccar ──
            check("button added to QField's long-press map menu", canvasActionsRow.children.length === 1)
            canvasMenuStub.point = { x: -6.302, y: 53.361 }
            canvasActionsRow.children[0].clicked()
            check("map menu closed, Send to Traccar choices for that spot", canvasMenuStub.closed
                  && opened().some(function(o) { return o.ll !== undefined && Math.abs(o.ll.lon + 6.302) < 1e-9 }))
            plugin.canvasSendChoose("circle")
            sleep(300)
        },
        function() {
            var d = sendDlg()
            check("Circle here: the send form for a circle at the long-pressed spot",
                  d && d.mode === "circle" && Math.abs(d.coords[0].lat - 53.361) < 1e-9 && !d.editG)
            d.close()
            canvasMenuStub.point = { x: -6.31, y: 53.37 }
            canvasActionsRow.children[0].clicked()
            plugin.canvasSendChoose("area")
            check("Start an area here: drawing with that spot as the first corner",
                  plugin.drawMode === "area" && plugin.drawPts.length === 1 && plugin.drawPts[0].lat === 53.37)
            plugin.cancelDraw()
            sleep(300)
        },
        function() {
            check("circle geofence with the remembered radius", gf("Base").radius === cfg.circleRadius
                  && gf("Base").kind === "circle", gf("Base").radius)
            // ── send a point (device) ──
            cfg.sendUrl = serverUrl + "/osmand/"
            cfg.defaultNames = "Team 1, Team 2,, Clue "; cfg.lastSendName = ""
            plugin.startDraw("point")
            tap(-6.31, 53.362)
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("Add → Point: one tap opens the name dialog", d && d.mode === "point")
            var pick = childByName(d.contentItem, "sendNamePick")
            check("default names (comma-separated) are the name drop-down; the first is filled in",
                  pick && pick.visible && JSON.stringify(pick.model) === JSON.stringify(["Team 1", "Team 2", "Clue"])
                  && d.nameText === "Team 1", pick ? JSON.stringify(pick.model) + " " + d.nameText : "no drop-down")
            pick.activated(2)
            check("…picking one fills the name (any other can still be typed)", d.nameText === "Clue")
            cfg.defaultNames = ""
            d.nameText = "Clue 4"
            d.send()
            check("sent point shown at once: 'Clue 4 (sending…)' on the map",
                  plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" && m.confirmed === 0 }))
            waitFor("fix on the OsmAnd port", function() { return toasts[toasts.length - 1].indexOf("Clue 4") >= 0 })
        },
        function() {
            check("…still shown once Traccar accepts it",
                  plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" && m.confirmed > 0 }))
            sleep(50)
        },
        function() { fetchState() },
        function() {
            var dev = serverState.devices.filter(function(x) { return x.name === "Clue 4" })[0]
            check("new name → new device with a qgis-… identifier, fix sent",
                  dev && /^qgis-clue-4-\d+$/.test(dev.uniqueId) && serverState.osmand === 1, JSON.stringify(dev))
            check("name remembered for next time", cfg.lastSendName === "Clue 4")
            L.clueId = dev ? String(dev.id) : ""
            L.nFix = serverState.osmand
            plugin.sendPoint("Phone A", -6.32, 53.36)
            waitFor("asked before moving Phone A", function() { return confirmDlg() !== undefined })
        },
        function() {
            var c = confirmDlg()
            check("moving a device not added from QGIS / QField asks first",
                  c.okText === "Move it" && c.text.indexOf("Phone A") >= 0 && c.text.indexOf("real tracker") >= 0, c.text)
            c.onCancel(); c.onCancel = null; c.close()                 // Cancel
            sleep(300)
        },
        function() { fetchState() },
        function() {
            check("…Cancel: nothing sent, its stand-in gone", serverState.osmand === L.nFix
                  && !plugin.pendingPoints.some(function(m) { return m.name === "Phone A" }))
            plugin.sendPoint("Phone A", -6.32, 53.36)
            waitFor("asked again", function() { return confirmDlg() !== undefined })
        },
        function() {
            var c = confirmDlg(), a = c.action
            c.action = null; c.onCancel = null; c.close()
            a()                                                         // Move it
            sleep(400)
        },
        function() { fetchState() },
        function() {
            check("existing device's name → that device moves (no new device)",
                  serverState.devices.length === 4 && serverState.osmand === 2, serverState.devices.length)
            plugin.reloadWindow()
            waitFor("reload with the new point", function() { return !plugin.loading })
        },
        function() {
            var row = plugin.deviceRows.filter(function(r) { return r.name === "Clue 4" })[0]
            var ph  = plugin.deviceRows.filter(function(r) { return r.name === "Phone A" })[0]
            check("sent point listed and deletable; other devices not", row && row.sent && row.pos !== null && !ph.sent)
            check("…its stand-in gone after the refresh (the real marker is there)",
                  !plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" })
                  && plugin.overlayModel.some(function(m) { return m.name === "Clue 4" }))
            L.keepSendUrl = cfg.sendUrl
            cfg.sendUrl = serverUrl + "/nope/"         // not an OsmAnd port: the fix is refused
            plugin.sendPoint("Clue 4", -6.307, 53.364)     // a point added from QField: moves without asking
            check("refused point: shown while sending…", plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" })
                  && confirmDlg() === undefined)
            waitFor("refused point's marker gone", function() {
                return !plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" }) })
        },
        function() {
            plugin.sendPoint("Clue 6", -6.306, 53.363)     // new: a device is added, then its fix refused
            waitFor("refused new point's marker gone", function() {
                return !plugin.pendingPoints.some(function(m) { return m.name === "Clue 6" }) })
        },
        function() { sleep(300) },
        function() { fetchState() },
        function() {
            check("…the empty device added for a refused point is removed from Traccar",
                  !serverState.devices.some(function(x) { return x.name === "Clue 6" }),
                  serverState.devices.map(function(x) { return x.name }).join())
        },
        function() {
            cfg.sendUrl = L.keepSendUrl
            L.winSave = plugin.win
            var w = JSON.parse(JSON.stringify(plugin.win))
            w.moving = false                             // as a custom-dates window that ends in the past
            plugin.win = w
            plugin.sendPoint("Clue 4", -6.308, 53.365)
            waitFor("past window: stand-in goes once accepted", function() {
                return toasts.some(function(t) { return t.indexOf("not shown here") >= 0 })
                       && !plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" }) }, 8000)
        },
        function() {
            check("fixed past window: the stand-in goes once Traccar accepts the point",
                  !plugin.pendingPoints.some(function(m) { return m.name === "Clue 4" }))
            plugin.win = L.winSave
            toolbarRow.children[0].clicked()        // draw the lists with geofences and a sent point
            sleep(200)
        },
        function() {
            opened()[0].close()
            plugin.deleteSentPoint(L.clueId)
            plugin.deleteSentPoint("1")             // not a sent point: refused
            waitFor("point deleted", function() {
                return !plugin.deviceRows.some(function(r) { return r.name === "Clue 4" }) })
        },
        function() { sleep(300) },
        function() { fetchState() },
        function() {
            check("sent point deleted from Traccar; other devices never",
                  serverState.devices.length === 3 && serverState.devices.some(function(x) { return x.id === 1 }))
            plugin.deleteGeofence(7)
            waitFor("geofence deleted", function() { return gf("Lake sector") === undefined })
        },
        function() { fetchState() },
        function() {
            check("geofence made in Traccar deleted",
                  !serverState.geofences.some(function(g) { return g.id === 7 }))
            // ── from a layer: polygons in another CRS, points as circles / as points ──
            L.sec = makeLayer("sectors", 2, 6, [["sector", "QString"]], "EPSG:2157")
            var addF = function(lyr, id, attrs, wkt) {
                lyr._committed.push({ id: id, geometry: wktGeom(wkt),
                                      attribute: function(n) { return attrs[n] === undefined ? null : attrs[n] } })
            }
            addF(L.sec, 1, { sector: "S1" }, "MultiPolygon (((-630000 5336000, -629000 5336000, -629000 5337000, -630000 5336000)))")
            addF(L.sec, 2, { sector: "S2" }, "Polygon ((-628000 5336000, -627000 5336000, -627000 5337000, -628000 5336000))")
            addF(L.sec, 3, { sector: null }, "Polygon EMPTY")
            plugin.sendLayer("sectors", -1, "sector", "", 500, "#00838F", false)
            waitFor("layer sent", function() { return saved("S1") && saved("S2") })
        },
        function() {
            var s1 = gf("S1")
            check("layer's polygons → geofences named from a field, reprojected, in the colour",
                  s1.kind === "polygon" && Math.abs(s1.coords[0].lon + 6.3) < 1e-9 && s1.color === "#00838F")
            check("feature with no shape skipped and reported",
                  toasts.some(function(t) { return t.indexOf("1 feature(s) skipped") === 0 }))
            L.pois = makeLayer("pois", 0, 1, [["name", "QString"]])
            L.pois._committed.push({ id: 1, geometry: wktGeom("Point (-6.31 53.36)"),
                                     attribute: function(n) { return n === "name" ? "Hut" : null } })
            L.pois._committed.push({ id: 2, geometry: wktGeom("Point (-6.30 53.35)"),
                                     attribute: function(n) { return n === "name" ? "Car park" : null } })
            plugin.sendLayer("pois", 2, "name", "", 150, "#00838F", false)
            waitFor("one point as a circle", function() { return saved("Car park") })
        },
        function() {
            check("one chosen point → circle of the chosen radius", gf("Car park").radius === 150 && gf("Hut") === undefined)
            plugin.sendLayer("pois", 1, "name", "", 150, "#00838F", true)
            sleep(500)
        },
        function() { fetchState() },
        function() {
            check("point feature sent as a point (device)", serverState.devices.some(function(x) { return x.name === "Hut" }))
            sleep(200)
        },
        function() {
            // ── the send form's Traccar fields (same as the QGIS plugin) ──
            check("groups and calendars loaded for the send form",
                  plugin.groups.length === 1 && plugin.groups[0].name === "Search teams"
                  && plugin.calendars.length === 1 && plugin.calendars[0].id === 9)
            plugin.startDraw("line")
            tap(-6.30, 53.35); tap(-6.29, 53.355)
            plugin.finishDraw()
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("line form", d && d.mode === "line")
            d.nameText = "Track 3"; d.descriptionText = "Main track"
            d.corridorValue = 40; d.speedValue = 20; d.calendarIndex = 1
            d.send()
            waitFor("line sent", function() { return saved("Track 3") })
        },
        function() { fetchState() },
        function() {
            var t = serverState.geofences.filter(function(g) { return g.name === "Track 3" })[0]
            check("line sent with description, calendar, speed limit (knots) and corridor width",
                  t && t.description === "Main track" && t.calendarId === 9 && t.attributes.speedLimit === 10.8
                  && t.attributes.polylineDistance === 40 && t.area.indexOf("LINESTRING") === 0, JSON.stringify(t))
            check("speed limit read back in km/h", gf("Track 3").speedKmh === 20 && gf("Track 3").description === "Main track")
            plugin.startDraw("point")
            tap(-6.305, 53.358)
            sleep(200)
        },
        function() {
            var d = sendDlg()
            d.nameText = "Clue 7"
            d.categoryIndex = plugin.deviceCategories.indexOf("person")
            d.groupIndex = 1
            d.phoneText = "087 000"; d.contactText = "Team 2"
            d.send()
            waitFor("point with details sent", function() { return toasts[toasts.length - 1].indexOf("Clue 7") >= 0 })
        },
        function() { fetchState() },
        function() {
            var dev = serverState.devices.filter(function(x) { return x.name === "Clue 7" })[0]
            check("new point sent with category, group, phone and contact",
                  dev && dev.category === "person" && dev.groupId === 4 && dev.phone === "087 000"
                  && dev.contact === "Team 2" && dev.uniqueId.indexOf("qgis-clue-7-") === 0, JSON.stringify(dev))
            // ── detail lines in the lists ──
            plugin.reloadWindow()
            waitFor("reload", function() { return !plugin.loading })
        },
        function() {
            var row = plugin.deviceRows.filter(function(r) { return r.name === "Phone A" })[0]
            var full = plugin.deviceLine(row)
            plugin.setDetailShown("device", "speed", false)
            plugin.setDetailShown("device", "battery", false)
            var short = plugin.deviceLine(row)
            check("hide Speed and Battery from the device list (remembered)",
                  full.indexOf("km/h") > 0 && full.indexOf("batt") > 0 && short.indexOf("km/h") < 0
                  && short.indexOf("batt") < 0 && short.indexOf("fix") > 0 && cfg.deviceDetailsHidden === "speed,battery",
                  full + " | " + short + " | " + cfg.deviceDetailsHidden)
            plugin.setDetailShown("geofence", "type", false)
            check("hide Type from the geofence list", plugin.geofenceLine(gf("Track 3")) === "from QGIS / QField  ·  limit 20 km/h",
                  plugin.geofenceLine(gf("Track 3")))
            toolbarRow.children[0].clicked()        // draw the tabs with details hidden
            sleep(200)
        },
        function() {
            opened()[0].close()
            plugin.setDetailShown("device", "speed", true); plugin.setDetailShown("device", "battery", true)
            plugin.setDetailShown("geofence", "type", true)
            check("details shown again", cfg.deviceDetailsHidden === "" && cfg.geofenceDetailsHidden === "")
            plugin.sendLayer("sectors", 2, "sector", "", 500, "#00838F", false, "sector")
            waitFor("layer feature sent with a description", function() { var g = gf("S2"); return g && g.description === "S2" })
        },
        function() {
            check("From layer: description from a field", gf("S2").description === "S2")
            // ── Save geofences to layers ──
            var gfFields = [["geofence_id", "int"], ["name", "QString"], ["type", "QString"], ["radius_m", "double"],
                            ["color", "QString"], ["description", "QString"]]
            L.gfp = makeLayer("gf_poly", 2, 3, gfFields)
            L.gfl = makeLayer("gf_line", 1, 2, gfFields)
            cfg.geofencesLayerName = "gf_poly"; cfg.geofenceLinesLayerName = "gf_line"
            var areas = plugin.geofences.filter(function(g) { return !g.pending && (g.kind === "polygon" || g.kind === "circle") })
            var lines = plugin.geofences.filter(function(g) { return !g.pending && g.kind === "line" })
            plugin.saveGeofences(false)
            var circle = areas.filter(function(g) { return g.kind === "circle" })[0]
            var cf = L.gfp._committed.filter(function(f) { return f.attribute("geofence_id") === circle.id })[0]
            check("Save geofences: areas and circles → polygon layer, lines → line layer",
                  L.gfp._committed.length === areas.length && L.gfl._committed.length === lines.length
                  && areas.length > 0 && lines.length > 0, L.gfp._committed.length + "/" + areas.length + ", "
                  + L.gfl._committed.length + "/" + lines.length)
            check("geofence fields and shape: circle saved as a polygon with its radius",
                  cf && cf.attribute("type") === "circle" && cf.attribute("radius_m") === circle.radius
                  && cf.attribute("color") === circle.color && cf.geometry.wkt.indexOf("Polygon ((") === 0,
                  cf ? cf.geometry.wkt.substr(0, 30) : "none")
            plugin.saveGeofences(false)
            check("saving again replaces them (no duplicates)",
                  L.gfp._committed.length === areas.length && L.gfl._committed.length === lines.length)
            // ── automatic saving after every refresh ──
            L.ap = makeLayer("auto_pts", 0, 1, [["device_id", "int"], ["name", "QString"], ["fix_time", "QString"]])
            L.at = makeLayer("auto_trk", 1, 2, [["device_id", "int"], ["name", "QString"]])
            L.keepPts = cfg.pointsLayerName; L.keepTrk = cfg.tracksLayerName; L.keepMode = cfg.trackMode
            cfg.pointsLayerName = "auto_pts"; cfg.pointsMode = 0; cfg.tracksLayerName = "auto_trk"; cfg.trackMode = 0
            plugin.setAllShown(true)
            cfg.liveOn = false
            cfg.autoSave = true
            plugin.reloadWindow()
            waitFor("auto-save load", function() { return !plugin.loading }, 15000)
        },
        function() {
            L.nMarkers = plugin.overlayModel.length
            L.nTracks = Object.keys(plugin.tracks).filter(function(k) { return plugin.tracks[k].length > 0 }).length
            check("auto-save: the refresh saved each device's latest fix and its track",
                  L.ap._committed.length === L.nMarkers && L.at._committed.length === L.nTracks && L.nMarkers > 0,
                  L.ap._committed.length + "/" + L.nMarkers + ", " + L.at._committed.length + "/" + L.nTracks)
            plugin.loadWindow(true)
            waitFor("second refresh", function() { return !plugin.loading }, 15000)
        },
        function() {
            check("a refresh with nothing new saves nothing",
                  L.ap._committed.length === L.nMarkers && L.at._committed.length === L.nTracks,
                  L.ap._committed.length + ", " + L.at._committed.length)
            httpGet("/test/addfix?dev=1")
            sleep(300)
        },
        function() {
            plugin.pollLive()
            waitFor("new fix auto-saved", function() { return L.ap._committed.length === L.nMarkers + 1 })
        },
        function() {
            check("a new fix: one more point; that device's track replaced (still one per device)",
                  L.ap._committed.length === L.nMarkers + 1 && L.at._committed.length === L.nTracks,
                  L.ap._committed.length + ", " + L.at._committed.length)
            check("after a track rewrite the next waits 20x its time (here: short, at most 10 min)",
                  plugin.autoTrackNext >= Date.now() - 1000 && plugin.autoTrackNext <= Date.now() + 600000)
            L.trk1 = L.at._committed.filter(function(f) { return f.attribute("device_id") === 1 })[0]
            L.nPts = L.ap._committed.length
            plugin.autoTrackNext = Date.now() + 60000          // as after a slow rewrite of a long track
            httpGet("/test/addfix?dev=1")
            sleep(300)
        },
        function() {
            plugin.pollLive()
            waitFor("point saved while the track waits", function() { return L.ap._committed.length === L.nPts + 1 })
        },
        function() {
            check("backing off: the new fix is saved as a point, the track waits",
                  L.at._committed.filter(function(f) { return f.attribute("device_id") === 1 })[0] === L.trk1)
            plugin.autoTrackNext = 0
            plugin.pollLive()
            waitFor("track rewritten after the wait", function() {
                return L.at._committed.filter(function(f) { return f.attribute("device_id") === 1 })[0] !== L.trk1 })
        },
        function() {
            check("…and the next refresh after the wait rewrites the track with everything since",
                  L.at._committed.length === L.nTracks)
            // ── a wider time window: the earlier fixes are saved too (none twice); the track at once ──
            L.ap2 = makeLayer("auto_pts2", 0, 1, [["device_id", "int"], ["name", "QString"], ["fix_time", "QString"]])
            L.at2 = makeLayer("auto_trk2", 1, 2, [["device_id", "int"], ["name", "QString"], ["start_time", "QString"]])
            L.keepWin = cfg.windowMinutes
            cfg.pointsLayerName = "auto_pts2"; cfg.pointsMode = 1; cfg.tracksLayerName = "auto_trk2"
            plugin.autoTrackUpto = ({}); plugin.autoTrackNext = 0
            cfg.windowMinutes = 60; plugin.reloadWindow()
            waitFor("60 min window", function() { return !plugin.loading }, 15000)
        },
        function() {
            L.inWin = function() { var n = 0; for (var k in plugin.tracks) n += plugin.tracks[k].length; return n }
            L.start1 = function() {
                var f = L.at2._committed.filter(function(x) { return x.attribute("device_id") === 1 })
                return f.length === 1 ? new Date(f[0].attribute("start_time")).getTime() : NaN
            }
            L.n60 = L.inWin(); L.s60 = L.start1()
            check("every fix: the refresh saves each fix in the window", L.ap2._committed.length === L.n60 && L.n60 > 0,
                  L.ap2._committed.length + "/" + L.n60)
            plugin.autoTrackNext = 0
            cfg.windowMinutes = 180; plugin.reloadWindow()
            waitFor("180 min window", function() { return !plugin.loading }, 15000)
        },
        function() {
            L.n180 = L.inWin()
            check("a wider window: the earlier fixes are saved too, none twice",
                  L.ap2._committed.length === L.n180 && L.n180 > L.n60, L.ap2._committed.length + "/" + L.n180 + " (" + L.n60 + ")")
            check("…and each track is rewritten at once to start earlier (still one per device)",
                  L.start1() < L.s60 && L.at2._committed.length === L.nTracks, L.start1() + " vs " + L.s60)
            L.s180 = L.start1()
            plugin.autoTrackNext = 0
            cfg.windowMinutes = 60; plugin.reloadWindow()
            waitFor("60 min again", function() { return !plugin.loading }, 15000)
        },
        function() {
            check("a narrower window again: nothing saved twice", L.ap2._committed.length === L.n180, L.ap2._committed.length)
            check("…and the tracks are rewritten at once to the shorter window (no new fix needed)",
                  L.start1() > L.s180 && L.at2._committed.length === L.nTracks, L.start1() + " vs " + L.s180)
            plugin.autoSaved = ({ layer: "", devs: {} })        // as after a restart
            cfg.windowMinutes = 180; plugin.reloadWindow()
            waitFor("180 min after a restart", function() { return !plugin.loading }, 15000)
        },
        function() {
            check("…not even after a restart (what's in the layer is read first)", L.ap2._committed.length === L.n180,
                  L.ap2._committed.length)
            // ── only the saved fixes that could come up again are read, in one pass ──
            var oldIso = L.oldIso = new Date(Date.now() - 30 * 86400000).toISOString()
            L.ap2._committed.push({ id: 9999, geometry: { wkt: "Point (-6.3 53.3)" },
                                    attribute: function(n) { return n === "device_id" ? 1 : n === "fix_time" ? oldIso : null } })
            L.ap2._exprReads = []
            plugin.autoSaved = ({ layer: "", since: 0, devs: {} })
            cfg.windowMinutes = 60; plugin.reloadWindow()
            waitFor("60 min, reading what's saved", function() { return !plugin.loading }, 15000)
        },
        function() {
            var memo = plugin.autoSaved, sec = Math.floor(new Date(L.oldIso).getTime() / 1000)
            check("saved fixes read in one pass, only from the window's start on (a month-old one isn't)",
                  L.ap2._exprReads.length === 1 && L.ap2._exprReads[0].indexOf('"fix_time" >= to_datetime(') === 0
                  && !(memo.devs["1"] && memo.devs["1"][sec]) && Object.keys(memo.devs["1"] || {}).length > 0,
                  JSON.stringify(L.ap2._exprReads))
            L.since60 = memo.since
            cfg.windowMinutes = 180; plugin.reloadWindow()
            waitFor("180 min, reading the earlier part", function() { return !plugin.loading }, 15000)
        },
        function() {
            check("…a wider window reads just the earlier part, nothing saved twice",
                  L.ap2._exprReads.length === 2 && L.ap2._exprReads[1].indexOf('AND "fix_time" < to_datetime(') > 0
                  && plugin.autoSaved.since < L.since60 && L.ap2._committed.length === L.n180 + 1,
                  JSON.stringify(L.ap2._exprReads) + " " + L.ap2._committed.length)
            // ── QFieldCloud syncing: reading, choosing and writing wait; the layer is read again after ──
            L.sec = function(iso) { return Math.floor(new Date(String(iso)).getTime() / 1000) }
            L.marked = function(iso) { return !!(plugin.autoSaved.devs["1"] || {})[L.sec(iso)] }
            L.newest = function() { var tr = plugin.tracks["1"]; return tr[tr.length - 1].fixTime }
            L.n2 = L.ap2._committed.length
            cloud.state = 1
            httpGet("/test/addfix?dev=1")
            sleep(300)
        },
        function() {
            plugin.pollLive()
            waitFor("auto-save queued while syncing", function() { return plugin.writeQueue.length > 0 })
        },
        function() {
            L.newIso = L.newest()
            L.reads = L.ap2._exprReads.length
            check("syncing: auto-save waits — nothing read, written or counted as saved",
                  L.ap2._committed.length === L.n2 && !L.marked(L.newIso) && L.ap2._exprReads.length === 2,
                  L.ap2._committed.length + " " + L.ap2._exprReads.length)
            // the sync brings in that same fix, saved on another phone
            var synced = L.newIso
            L.ap2._committed.push({ id: 9998, geometry: { wkt: "Point (-6.31 53.365)" },
                                    attribute: function(n) { return n === "device_id" ? 1 : n === "fix_time" ? synced : null } })
            cloud.state = 0
            waitFor("queue runs after the sync", function() { return plugin.writeQueue.length === 0 }, 6000)
        },
        function() {
            var same = L.ap2._committed.filter(function(f) {
                return f.attribute("device_id") === 1 && L.sec(f.attribute("fix_time")) === L.sec(L.newIso) })
            check("after the sync the layer is read again: a fix the sync brought in isn't saved twice",
                  L.ap2._exprReads.length > L.reads && same.length === 1 && L.ap2._committed.length === L.n2 + 1
                  && L.marked(L.newIso), same.length + " " + L.ap2._committed.length + "/" + (L.n2 + 1))
            // ── a write the layer refuses isn't counted as saved ──
            L.n3 = L.ap2._committed.length
            L.origCommit = L.ap2.commitChanges
            L.ap2.commitChanges = function() { this._buffer = []; this._deleted = []; this._editing = false; return false }
            httpGet("/test/addfix?dev=1")
            sleep(300)
        },
        function() {
            plugin.pollLive()
            waitFor("the layer refuses the points", function() {
                return toasts.some(function(t) { return t.indexOf("could not save the points") >= 0 }) })
        },
        function() {
            L.newIso = L.newest()
            check("a failed write: nothing saved, the fix not counted as saved",
                  L.ap2._committed.length === L.n3 && !L.marked(L.newIso), L.ap2._committed.length)
            L.ap2.commitChanges = L.origCommit
            plugin.pollLive()                                   // no new fix this time
            waitFor("retried on the next refresh", function() { return L.ap2._committed.length === L.n3 + 1 })
        },
        function() {
            check("…so the next refresh saves it", L.ap2._committed.length === L.n3 + 1 && L.marked(L.newIso))
            // ── a reloaded project (new layer object, e.g. after a sync download): read again ──
            plugin.autoSaved.lyr = ({})
            L.reads = L.ap2._exprReads.length
            plugin.pollLive()
            waitFor("read again after a reload", function() { return L.ap2._exprReads.length > L.reads })
        },
        function() {
            check("a reloaded project: the layer is read again, nothing saved twice",
                  L.ap2._exprReads.length === L.reads + 1 && L.ap2._committed.length === L.n3 + 1,
                  L.ap2._exprReads.length + " " + L.ap2._committed.length)
            cfg.windowMinutes = L.keepWin
            var before = L.gfp._committed.length
            plugin.loadGeofences()
            sleep(500)
            L.gfBefore = before
        },
        function() {
            check("auto-save: unchanged geofences aren't written again", L.gfp._committed.length === L.gfBefore)
            cfg.autoSave = false
            cfg.pointsLayerName = L.keepPts; cfg.tracksLayerName = L.keepTrk; cfg.trackMode = L.keepMode
            // ── edit a geofence with the same form ──
            L.keep = cfg.geofenceColor
            plugin.editGeofence(gf("Track 3").id)
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("Edit opens the form filled in", d && d.editG && d.mode === "line" && d.nameText === "Track 3"
                  && d.descriptionText === "Main track" && d.speedValue === 20 && d.corridorValue === 40
                  && d.calendarIndex === 1, d ? [d.nameText, d.descriptionText, d.speedValue, d.corridorValue].join() : "none")
            d.nameText = "Track 4"; d.speedValue = 0; d.descriptionText = "Lower track"
            d.send()
            waitFor("edit saved", function() { return saved("Track 4") })
        },
        function() { fetchState() },
        function() {
            var t = serverState.geofences.filter(function(g) { return g.name === "Track 4" })[0]
            check("Edit saves name and description, clears the speed limit, keeps corridor, calendar and shape",
                  t && t.description === "Lower track" && t.attributes.speedLimit === undefined
                  && t.attributes.polylineDistance === 40 && t.calendarId === 9 && t.area.indexOf("LINESTRING") === 0
                  && plugin.geofences.length === serverState.geofences.length, JSON.stringify(t))
            check("colour for new geofences unchanged after an edit", cfg.geofenceColor === L.keep, cfg.geofenceColor)
            opened().forEach(function(o) { o.close() })
            plugin.editGeofence(gf("Base").id)
            sleep(200)
        },
        function() {
            var d = sendDlg()
            check("editing a circle shows its radius", d && d.mode === "circle")
            d.send()            // radius from the form (cfg default); name kept
            waitFor("circle saved", function() { return toasts[toasts.length - 1].indexOf("'Base' saved") === 0 })
        },
        function() {
            opened().forEach(function(o) { o.close() })
            sleep(200)
        },
        function() {
            // ── custom past window: Van 3, two days ago ──
            var vs = new Date(vanStartIso)
            cfg.windowMinutes = -1
            cfg.customFrom = localStr(new Date(vs.getTime() - 5 * 60000))
            cfg.customTo   = localStr(new Date(vs.getTime() + 30 * 60000))
            plugin.reloadWindow()
            waitFor("custom window load", function() { return !plugin.loading })
        },
        function() {
            check("custom past window: not moving, Van 3 has 20 fixes",
                  plugin.win && !plugin.win.moving && devTrack(2).length === 20 && devTrack(1).length === 0)
            check("past window → marker at last fix in window", Object.keys(plugin.markerPos).join() === "2")
            // marker tap → toast
            var m = plugin.overlayModel[0]
            var sp = canvas.mapSettings.coordinateToScreen({ x: m.lon, y: m.lat })
            var hit = pointHandler.handlers["traccarlive"](Qt.point(sp.x + 3, sp.y - 2), null, "clicked")
            check("tap on marker → handled, toast with name", hit === true && toasts[toasts.length - 1].indexOf("Van 3") === 0,
                  toasts[toasts.length - 1])
            // ── from feature, with its display value as tag ──
            var vs = new Date(vanStartIso)
            L.inc = makeLayer("incidents", 0, 1, [["ref", "QString"], ["start", "QDateTime"], ["end", "QDateTime"]])
            L.inc._committed.push({ id: 7, attribute: function(n) {
                return n === "ref" ? "INC-7" : n === "start" ? new Date(vs.getTime() - 60000)
                     : n === "end" ? new Date(vs.getTime() + 20 * 60000) : null } })
            cfg.eventLayerName = "incidents"; cfg.eventDisplayField = "ref"
            cfg.eventStartField = "start"; cfg.eventEndField = "end"; cfg.eventFeatureFid = 7; cfg.featureSpan = 0
            cfg.useDisplayAsTag = true; cfg.incidentRefEnabled = true; cfg.incidentRefField = "tag"; cfg.sessionTag = "X"
            cfg.windowMinutes = -2
            plugin.populateEventFeatures()
            plugin.reloadWindow()
            waitFor("from-feature load", function() { return !plugin.loading })
        },
        function() {
            check("from feature: Van 3's 20 fixes, tag = feature value",
                  devTrack(2).length === 20 && plugin.win && plugin.win.tag === "INC-7")
            cfg.tracksLayerName = "trk2D"; cfg.trackMode = 0
            plugin.saveTracks()
            check("saved track tagged INC-7", lastOf(L.trk2D).attribute("tag") === "INC-7", lastOf(L.trk2D).attribute("tag"))
            cfg.incidentRefEnabled = false
            // ── Live with a moving window: timer polls by itself ──
            cfg.windowMinutes = 60
            cfg.liveIntervalSec = 2
            cfg.liveOn = true
            plugin.reloadWindow()
            L.fetched = ""
            waitFor("live load", function() { return !plugin.loading })
        },
        function() {
            L.fetched = plugin.lastFetched
            sleep(2600)
        },
        function() {
            check("Live timer refreshes on its own", plugin.lastFetched !== L.fetched, L.fetched + " → " + plugin.lastFetched)
            cfg.liveOn = false
            plugin.clearWindow()
            check("Clear empties the map", plugin.overlayModel.length === 0 && plugin.trackModel.length === 0
                  && plugin.win === null)
            plugin.destroy()
            sleep(200)
        }
        ]
        ticker.start()
    }
}
