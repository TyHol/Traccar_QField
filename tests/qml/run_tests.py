"""
Runs main.qml outside QField: stand-in QField modules (stubs/), a test driver
(Driver.qml) and a fake Traccar server. Any QML warning or JavaScript error is
reported and fails the run.

Needs PySide6 (pip install PySide6-Essentials). If it is installed somewhere
other than site-packages, set PYSIDE6_DIR to the folder that contains PySide6.

    python tests/qml/run_tests.py
"""

import base64
import hashlib
import json
import os
import sys
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

try:
    sys.stdout.reconfigure(encoding="utf-8")
except AttributeError:
    pass
if os.environ.get("PYSIDE6_DIR"):
    sys.path.insert(0, os.environ["PYSIDE6_DIR"])
os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["QT_QUICK_CONTROLS_STYLE"] = "Material"     # QField's style

from PySide6.QtCore import (QCoreApplication, QSettings, QUrl, QMetaObject, QTimer,  # noqa: E402
                            QtMsgType, qInstallMessageHandler)
from PySide6.QtGui import QColor, QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.environ.get("TRACCAR_MAIN_QML") or os.path.abspath(os.path.join(HERE, "..", "..", "main.qml"))

# ── Fake Traccar server ──────────────────────────────────────────────────────
NOW = datetime.now(timezone.utc).replace(microsecond=0)
USER, PWD = "test@example.com", "secret"  # pragma: allowlist secret  (fake server)
DEVICES = [{"id": 1, "name": "Phone A", "uniqueId": "352000000000001", "status": "online"},
           {"id": 2, "name": "Van 3", "uniqueId": "van3", "status": "offline"},
           {"id": 3, "name": "Spare", "uniqueId": "spare", "status": "unknown"}]


def _fix(dev, t, lon, lat, i):
    return {"id": dev * 100000 + i, "deviceId": dev, "fixTime": t.strftime("%Y-%m-%dT%H:%M:%S.000+00:00"),
            "latitude": lat, "longitude": lon, "altitude": 90.0 + i % 5, "speed": 2.5, "course": 45.0,
            "accuracy": 6.0, "address": None, "attributes": {"batteryLevel": 81, "motion": True}}


POS = {1: [], 2: [], 3: []}
for i in range(240):
    POS[1].append(_fix(1, NOW - timedelta(seconds=30 * (239 - i)), -6.33 + i * 0.0001, 53.355 + i * 0.00005, i))
VAN_START = NOW - timedelta(days=2)
for i in range(20):
    POS[2].append(_fix(2, VAN_START + timedelta(seconds=30 * i), -6.25 + i * 0.0002, 53.35, i))


def _p(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


GEOFENCES = [   # one made in Traccar (own colour), one sent from QGIS before
    {"id": 7, "name": "Lake sector", "description": "", "calendarId": 0,
     "area": "POLYGON ((53.36 -6.34, 53.37 -6.34, 53.37 -6.32, 53.36 -6.32, 53.36 -6.34))",
     "attributes": {"color": "#1565c0"}},
    {"id": 8, "name": "Trail", "description": "", "calendarId": 0,
     "area": "LINESTRING (53.35 -6.30, 53.355 -6.29)", "attributes": {"createdByTraccarLiveQgis": True}},
]
OSMAND = []     # fixes received on the OsmAnd port


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        auth = "Basic " + base64.b64encode(("%s:%s" % (USER, PWD)).encode()).decode()
        if self.headers.get("Authorization", "") == auth:
            return True
        self._send(401)
        return False

    def _body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"null")

    def do_POST(self):
        if not self._authed():
            return
        body = self._body()
        if self.path == "/api/geofences":
            g = dict(body, id=max([g["id"] for g in GEOFENCES] + [0]) + 1)
            GEOFENCES.append(g)
            return self._send(200, g)
        if self.path == "/api/devices":
            d = {"id": max(d["id"] for d in DEVICES) + 1, "name": body["name"], "uniqueId": body["uniqueId"],
                 "status": "unknown"}
            DEVICES.append(d)
            POS[d["id"]] = []
            return self._send(200, d)
        self._send(404)

    def do_PUT(self):
        if not self._authed():
            return
        gid = int(self.path.rsplit("/", 1)[-1]) if self.path.startswith("/api/geofences/") else None
        for i, g in enumerate(GEOFENCES):
            if g["id"] == gid:
                GEOFENCES[i] = self._body()
                return self._send(200, GEOFENCES[i])
        self._send(404)

    def do_DELETE(self):
        if not self._authed():
            return
        kind, _, num = self.path.rpartition("/")
        if kind == "/api/geofences":
            GEOFENCES[:] = [g for g in GEOFENCES if g["id"] != int(num)]
        elif kind == "/api/devices":
            DEVICES[:] = [d for d in DEVICES if d["id"] != int(num)]
            POS.pop(int(num), None)
        else:
            return self._send(404)
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/osmand/":                        # Traccar's OsmAnd port: no login, device by identifier
            d = next((d for d in DEVICES if d.get("uniqueId") == q.get("id", [""])[0]), None)
            if d is None:
                return self._send(400)
            t = datetime.fromtimestamp(int(q["timestamp"][0]), timezone.utc)
            OSMAND.append(q)
            POS[d["id"]].append(_fix(d["id"], t, float(q["lon"][0]), float(q["lat"][0]), len(POS[d["id"]])))
            return self._send(200)
        if u.path == "/test/state":                     # test hook: what the server holds now
            return self._send(200, {"geofences": GEOFENCES, "devices": DEVICES, "osmand": len(OSMAND)})
        if u.path == "/test/addfix":                    # test hook: a new live fix
            d = int(q["dev"][0])
            n = len(POS[d])
            last = _p(POS[d][-1]["fixTime"]) if POS[d] else NOW
            t = max(datetime.now(timezone.utc) - timedelta(seconds=1), last + timedelta(seconds=1))
            POS[d].append(_fix(d, t, -6.31, 53.365, 1000 + n))
            return self._send(200, {})
        if not self._authed():
            return
        if u.path == "/api/geofences":
            return self._send(200, GEOFENCES)
        if u.path == "/api/devices":
            return self._send(200, DEVICES)
        if u.path == "/api/positions" and "deviceId" in q:
            d = int(q["deviceId"][0])
            frm, to = _p(q["from"][0]), _p(q["to"][0])
            return self._send(200, [p for p in POS.get(d, []) if frm <= _p(p["fixTime"]) <= to])
        if u.path == "/api/positions":
            return self._send(200, [v[-1] for v in POS.values() if v])
        self._send(404)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d" % server.server_address[1]

# ── QML engine ───────────────────────────────────────────────────────────────
LOG = []


def handler(mode, ctx, msg):
    LOG.append((mode, msg, "%s:%s" % (ctx.file, ctx.line) if ctx.file else ""))


qInstallMessageHandler(handler)
TMP = tempfile.mkdtemp(prefix="traccar_qml_")
QSettings.setDefaultFormat(QSettings.Format.IniFormat)
QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, TMP)
QCoreApplication.setOrganizationName("TraccarTest")
QCoreApplication.setApplicationName("harness")
app = QGuiApplication(sys.argv)

engine = QQmlApplicationEngine()
engine.addImportPath(os.path.join(HERE, "stubs"))
ctx = engine.rootContext()
ctx.setContextProperty("serverUrl", URL)
ctx.setContextProperty("mainQmlUrl", QUrl.fromLocalFile(MAIN).toString())
ctx.setContextProperty("vanStartIso", VAN_START.isoformat())
# Device colour as the QGIS plugin Traccar Live makes it (MD5 of the name → hue)
ctx.setContextProperty("phoneAColor", QColor.fromHsv(
    int(hashlib.md5(b"Phone A", usedforsecurity=False).hexdigest()[:4], 16) % 360, 190, 200).name())
engine.load(QUrl.fromLocalFile(os.path.join(HERE, "Driver.qml")))
if not engine.rootObjects():
    for m in LOG:
        print(m[1], m[2])
    sys.exit("Driver.qml failed to load")
root = engine.rootObjects()[0]
ctx.setContextProperty("iface", root.property("ifaceObj"))
ctx.setContextProperty("qgisProject", root.property("projectObj"))
QTimer.singleShot(180000, lambda: (print("FAIL  timeout"), app.exit(3)))
QMetaObject.invokeMethod(root, "startTests")
rc = app.exec()
server.shutdown()

# ── Report ───────────────────────────────────────────────────────────────────
problems = []
for mode, msg, where in LOG:
    if msg.startswith(("PASS", "FAIL", "RESULT")):
        print(msg)
    elif msg.startswith("TOAST") or msg.startswith("QFontDatabase"):   # no fonts bundled with PySide6
        continue
    elif mode in (QtMsgType.QtWarningMsg, QtMsgType.QtCriticalMsg, QtMsgType.QtFatalMsg):
        problems.append("%s  (%s)" % (msg, where))
if problems:
    print("\nQML warnings / errors (%d):" % len(problems))
    for p in problems:
        print("  " + p)
print("\nExit code %d, %d QML warning(s)/error(s)" % (rc, len(problems)))
sys.exit(1 if rc or problems else 0)
