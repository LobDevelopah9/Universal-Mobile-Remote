"""A fake Roku that speaks enough ECP for integration tests and simulator demos.

    python3 tools/fake_tv/roku_ecp.py --port 8060

Serves /query/device-info, /query/apps and /query/icon/<id>, and accepts
POST /keypress|keydown|keyup/<key> and /launch/<id>. Test-only control endpoints:

    POST /_test/reset            clear the log and leave limited mode
    POST /_test/limited?on=1     answer commands with 403, like "Control by mobile apps: Limited"
    GET  /_test/log              JSON list of commands received, e.g. ["keypress/Up"]

Only the standard library is used. Style rules for this repo's Python:
no zip(), no `with` for file operations.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

FIXTURES = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "Packages", "RemoteKit", "Tests", "RemoteKitTests", "Fixtures")
)

DEVICE_INFO = """<?xml version="1.0" encoding="UTF-8" ?>
<device-info>
\t<serial-number>FAKE0000TEST</serial-number>
\t<vendor-name>Fake</vendor-name>
\t<model-name>Fake Roku TV</model-name>
\t<is-tv>true</is-tv>
\t<wifi-mac>02:00:00:aa:bb:cc</wifi-mac>
\t<friendly-device-name>Fake Roku</friendly-device-name>
\t<user-device-name>Fake Roku</user-device-name>
\t<power-mode>PowerOn</power-mode>
</device-info>
"""

# 1x1 transparent PNG.
ICON_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"
)

COMMAND_PREFIXES = ("keypress/", "keydown/", "keyup/", "launch/")


def read_file(path: str) -> bytes:
    fp = open(path, "rb")
    try:
        return fp.read()
    finally:
        fp.close()


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.log: list[str] = []
        self.limited = False

    def reset(self) -> None:
        self.lock.acquire()
        try:
            self.log = []
            self.limited = False
        finally:
            self.lock.release()

    def record(self, command: str) -> None:
        self.lock.acquire()
        try:
            self.log.append(command)
        finally:
            self.lock.release()

    def snapshot(self) -> list[str]:
        self.lock.acquire()
        try:
            return list(self.log)
        finally:
            self.lock.release()


STATE = State()


class Handler(BaseHTTPRequestHandler):
    server_version = "Roku/12.5.0 UPnP/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - BaseHTTPRequestHandler's signature
        if os.environ.get("FAKE_TV_VERBOSE"):
            sys.stderr.write("fake-roku: " + (format % args) + "\n")

    def send_body(self, status: int, body: bytes, content_type: str = "text/xml; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def drain_body(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def do_GET(self) -> None:  # noqa: N802 - http.server naming
        parts = urlsplit(self.path)
        path = parts.path
        if path == "/query/device-info":
            self.send_body(200, DEVICE_INFO.encode("utf-8"))
        elif path == "/query/apps":
            self.send_body(200, read_file(os.path.join(FIXTURES, "roku-apps.xml")))
        elif path.startswith("/query/icon/"):
            self.send_body(200, ICON_PNG, "image/png")
        elif path == "/_test/log":
            self.send_body(200, json.dumps(STATE.snapshot()).encode("utf-8"), "application/json")
        else:
            self.send_body(404, b"")

    def do_POST(self) -> None:  # noqa: N802 - http.server naming
        self.drain_body()
        parts = urlsplit(self.path)
        command = parts.path.lstrip("/")
        if command == "_test/reset":
            STATE.reset()
            self.send_body(200, b"")
            return
        if command == "_test/limited":
            enabled = parse_qs(parts.query).get("on", ["1"])[0] == "1"
            STATE.lock.acquire()
            try:
                STATE.limited = enabled
            finally:
                STATE.lock.release()
            self.send_body(200, b"")
            return
        if not command.startswith(COMMAND_PREFIXES):
            self.send_body(404, b"")
            return
        if STATE.limited:
            self.send_body(403, b"ECP command not allowed")
            return
        STATE.record(command)
        self.send_body(200, b"")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8060)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"fake Roku ECP listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
