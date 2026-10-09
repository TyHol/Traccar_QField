"""
Runs main.qml outside QField: stand-in QField modules (stubs/), a test driver
(Driver.qml) and a fake Traccar server. Any QML warning or JavaScript error is
reported and fails the run.

Needs PySide6 (pip install PySide6-Essentials). If it is installed somewhere
other than site-packages, set PYSIDE6_DIR to the folder that contains PySide6.

    python tests/qml/run_tests.py
"""

import base64
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
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.environ.get("TRACCAR_MAIN_QML") or os.path.abspath(os.path.join(HERE, "..", "..", "main.qml"))

# ── Fake Traccar server ──────────────────────────────────────────────────────
NOW = datetime.now(timezone.utc).replace(microsecond=0)
USER, PWD = "test@example.com", "secret"
DEVICES = [{"id": 1, "name": "Phone A", "status": "online"},
           {"id": 2, "name": "Van 3", "status": "offline"},
           {"id": 3, "name": "Spare", "status": "unknown"}]


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/test/addfix":                    # test hook: a new live fix
            d = int(q["dev"][0])
            n = len(POS[d])
            POS[d].append(_fix(d, datetime.now(timezone.utc) - timedelta(seconds=1), -6.31, 53.365, 1000 + n))
            return self._send(200, {})
        auth = "Basic " + base64.b64encode(("%s:%s" % (USER, PWD)).encode()).decode()
        if self.headers.get("Authorization", "") != auth:
            return self._send(401)
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
