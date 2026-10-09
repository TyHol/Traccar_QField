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
            function coordinateToScreen(pt) { return Qt.point((pt.x + 9.52) * 20000, (52.08 - pt.y) * 20000) }
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

    QtObject {
        id: ifaceStub
        function mainWindow() { return root }
        function mapCanvas() { return canvas }
        function findItemByObjectName(n) {
            if (n === "pointHandler") return pointHandler
            if (n === "cloudConnection") return cloud
            return null
        }
        function addItemToPluginsToolbar(item) { item.parent = toolbarRow }
    }

    QtObject {
        id: projectStub
        property var layers: []
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
        var r = /^\s*(Point|LineString)\s*(ZM|Z|M)?\s*\(/i.exec(wkt)
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
    function opened() {
        var out = []
        var res = plugin.resources
        // Popups that are showing (visible is true at once; 'opened' waits for the animation)
        for (var i = 0; i < res.length; i++) if (res[i].open !== undefined && res[i].visible === true) out.push(res[i])
        return out
    }
    function localStr(d) { return Qt.formatDateTime(d, "yyyy-MM-dd HH:mm") }
    function devTrack(id) { return plugin.tracks[String(id)] || [] }
    function lastOf(lyr) { return lyr._committed[lyr._committed.length - 1] }

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
            check("marker tap handler registered", typeof pointHandler.handlers["traccarlive"] === "function")
            check("toolbar button added", toolbarRow.children.length === 1)
            cfg.serverUrl = serverUrl; cfg.username = "wrong"; cfg.password = "x"
            cfg.windowMinutes = 180
            plugin.reloadWindow()
            waitFor("load (wrong password)", function() { return !plugin.loading })
        },
        function() {
            check("wrong password → clear error", plugin.liveError.indexOf("401") >= 0 && plugin.win === null, plugin.liveError)
            cfg.username = "test@example.com"; cfg.password = "secret"
            plugin.reloadWindow()
            waitFor("load last 3 h", function() { return !plugin.loading })
        },
        function() {
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
            var pages = ["", "connection", "layers", "tag", "advanced"]
            for (var i = 0; i < pages.length; i++) {
                plugin.openSettings(pages[i])
                var o = opened()
                check("Settings page '" + (pages[i] || "list") + "' opens", o.length >= 1 && o[0].page === pages[i])
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
