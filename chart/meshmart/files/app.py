"""MeshMart demo service.

One tiny, dependency-free HTTP service (Python stdlib only). Every backend in
the shop runs this same file; its behaviour is driven by environment variables:

  SERVICE_NAME  name reported in responses               (e.g. "catalog")
  VERSION       version reported in responses             (e.g. "v1")
  PORT          port to listen on                         (default 8080)
  UPSTREAMS     comma-separated URLs to call per request  (e.g. "http://inventory:8080/stock")
  REDIS_ADDR    host:port of Redis to INCR a counter on   (optional)
  FAIL_RATE     0..1 probability of answering HTTP 500    (default 0)
  DELAY_MS      artificial latency per request in ms      (default 0)

DO NOT MODIFY THIS FILE AS PART OF THE EXAM.
"""
import json
import os
import random
import socket
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ.get("SERVICE_NAME", "service")
VERSION = os.environ.get("VERSION", "v1")
PORT = int(os.environ.get("PORT", "8080"))
UPSTREAMS = [u.strip() for u in os.environ.get("UPSTREAMS", "").split(",") if u.strip()]
REDIS_ADDR = os.environ.get("REDIS_ADDR", "").strip()
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0") or 0)
DELAY_MS = int(os.environ.get("DELAY_MS", "0") or 0)
POD = socket.gethostname()

# Headers we copy from the incoming request onto outgoing calls.
# (Think about why a service mesh can't do this for you.)
PROPAGATE = [
    "x-request-id", "traceparent", "tracestate",
    "x-b3-traceid", "x-b3-spanid", "x-b3-parentspanid", "x-b3-sampled", "x-b3-flags", "b3",
    "x-canary",
]


def elapsed_ms(start):
    return round((time.time() - start) * 1000)


def call_http(url, headers):
    start = time.time()
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            raw = resp.read().decode(errors="replace")
            try:
                body = json.loads(raw)
            except ValueError:
                body = raw[:200]
            return {"target": url, "status": resp.status, "ms": elapsed_ms(start), "body": body}
    except urllib.error.HTTPError as e:
        return {"target": url, "status": e.code, "ms": elapsed_ms(start),
                "error": e.read().decode(errors="replace")[:200]}
    except Exception as e:  # connection reset, timeout, DNS ...
        return {"target": url, "status": 0, "ms": elapsed_ms(start),
                "error": f"{type(e).__name__}: {e}"}


def redis_incr(key):
    """Speak just enough of the Redis protocol (RESP) to run INCR <key>."""
    start = time.time()
    target = f"redis://{REDIS_ADDR}"
    try:
        host, port = REDIS_ADDR.rsplit(":", 1)
        with socket.create_connection((host, int(port)), timeout=2) as s:
            s.sendall(f"*2\r\n$4\r\nINCR\r\n${len(key)}\r\n{key}\r\n".encode())
            data = s.recv(128).decode(errors="replace").strip()
        if data.startswith(":"):
            return {"target": target, "status": "ok", "ms": elapsed_ms(start), "counter": int(data[1:])}
        return {"target": target, "status": "error", "ms": elapsed_ms(start),
                "error": data or "empty reply (connection closed by peer)"}
    except Exception as e:
        return {"target": target, "status": "error", "ms": elapsed_ms(start),
                "error": f"{type(e).__name__}: {e}"}


def caller_identity(xfcc):
    """Extract the caller's SPIFFE ID from X-Forwarded-Client-Cert, if present."""
    if not xfcc:
        return None
    last = xfcc.split(",")[-1]
    for part in last.split(";"):
        if part.startswith("URI="):
            return part[4:]
    return last[:200]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[{NAME}-{VERSION}] {self.address_string()} {fmt % args}", flush=True)

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            return self.send_json(200, {"status": "ok"})

        if DELAY_MS:
            time.sleep(DELAY_MS / 1000)

        result = {
            "service": NAME,
            "version": VERSION,
            "pod": POD,
            "path": self.path,
            "caller_identity": caller_identity(self.headers.get("x-forwarded-client-cert")),
        }

        if FAIL_RATE and random.random() < FAIL_RATE:
            result["error"] = "simulated failure (FAIL_RATE)"
            return self.send_json(500, result)

        fwd = {h: self.headers[h] for h in PROPAGATE if self.headers.get(h)}
        calls = [call_http(u, fwd) for u in UPSTREAMS]
        if REDIS_ADDR:
            calls.append(redis_incr(f"{NAME}_requests"))
        result["calls"] = calls

        healthy = all(c["status"] in (200, "ok") for c in calls)
        self.send_json(200 if healthy else 502, result)


if __name__ == "__main__":
    print(f"{NAME} {VERSION} listening on :{PORT} upstreams={UPSTREAMS} "
          f"redis={REDIS_ADDR or '-'} fail_rate={FAIL_RATE} delay_ms={DELAY_MS}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
