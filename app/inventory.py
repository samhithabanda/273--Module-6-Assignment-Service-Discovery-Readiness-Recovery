"""Inventory Service - a tiny HTTP API used for the Module 6 lab.

Endpoints
  GET /items   -> inventory list + the name of the Pod that served the request
  GET /healthz -> liveness (always 200 while the process is up)
  GET /ready   -> readiness (503 while the file /tmp/not-ready exists)
"""
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
POD_IP = os.environ.get("POD_IP", "unknown")
NOT_READY_FLAG = "/tmp/not-ready"
PORT = int(os.environ.get("PORT", "8080"))

ITEMS = [
    {"sku": "SKU-1001", "name": "Laptop", "qty": 12},
    {"sku": "SKU-1002", "name": "Monitor", "qty": 30},
    {"sku": "SKU-1003", "name": "Keyboard", "qty": 54},
]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/items":
            self._send(200, {"served_by": POD_NAME, "pod_ip": POD_IP,
                             "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                             "items": ITEMS})
        elif self.path == "/healthz":
            self._send(200, {"status": "alive", "pod": POD_NAME})
        elif self.path == "/ready":
            if os.path.exists(NOT_READY_FLAG):
                self._send(503, {"status": "not-ready", "pod": POD_NAME})
            else:
                self._send(200, {"status": "ready", "pod": POD_NAME})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Skip probe noise; log real traffic so `kubectl logs` shows which Pod served what.
        if self.path == "/items":
            print(f"[{POD_NAME}] {self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"Inventory Service starting on :{PORT} as {POD_NAME} ({POD_IP})", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
