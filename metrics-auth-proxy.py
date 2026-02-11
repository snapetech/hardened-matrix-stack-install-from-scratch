#!/usr/bin/env python3
"""
Minimal auth proxy for Prometheus/Grafana: gate behind Synapse login.
Serves: /login (form), /login (POST -> Synapse, set cookie, redirect), /validate (for nginx auth_request).
Run on 127.0.0.1:9091; nginx auth_request calls /validate and proxies /metrics/ to Prometheus.
Requires: SYNAPSE_URL (e.g. https://matrix.example.com), COOKIE_NAME (default metrics_session).
"""
import os
import urllib.request
import urllib.error
import urllib.parse
import json
import ssl
from http.server import HTTPServer, BaseHTTPRequestHandler

SYNAPSE_URL = os.environ.get("SYNAPSE_URL", "https://matrix.example.com").rstrip("/")
COOKIE_NAME = os.environ.get("COOKIE_NAME", "metrics_session")
LISTEN = os.environ.get("LISTEN", "127.0.0.1:9091")
METRICS_PATH = os.environ.get("METRICS_PATH", "/metrics/")


def login_synapse(user: str, password: str):
    req = urllib.request.Request(
        f"{SYNAPSE_URL}/_matrix/client/r0/login",
        data=json.dumps({"type": "m.login.password", "user": user, "password": password}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
        return json.loads(r.read())


def whoami(token: str) -> bool:
    req = urllib.request.Request(
        f"{SYNAPSE_URL}/_matrix/client/v3/account/whoami",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=5, context=ctx) as r:
            return r.status == 200
    except urllib.error.HTTPError as e:
        return e.code == 200
    except Exception:
        return False


def parse_cookie(header: str) -> str:
    if not header:
        return ""
    for part in header.split(";"):
        part = part.strip()
        if part.startswith(f"{COOKIE_NAME}="):
            return part.split("=", 1)[1].strip().strip('"')
    return ""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics-auth/login" or self.path == "/metrics-auth/":
            self.send_login_page()
            return
        if self.path == "/metrics-auth/validate":
            self.send_validate()
            return
        if self.path == "/metrics-auth/logout":
            self.send_logout()
            return
        self.send_error(404)

    def do_POST(self):
        if self.path == "/metrics-auth/login":
            self.do_login()
            return
        self.send_error(404)

    def send_login_page(self):
        token = parse_cookie(self.headers.get("Cookie", ""))
        if token and whoami(token):
            self.send_redirect(METRICS_PATH)
            return
        html = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Metrics login</title></head><body>
<h1>Metrics dashboard</h1>
<p>Log in with your Matrix account.</p>
<form method="post" action="/metrics-auth/login">
  <label>Username: <input type="text" name="user" required></label><br>
  <label>Password: <input type="password" name="password" required></label><br>
  <button type="submit">Log in</button>
</form>
</body></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html.encode("utf-8"))))
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def do_login(self):
        clen = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(clen).decode("utf-8")
        params = {}
        for part in body.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                params[k] = urllib.parse.unquote_plus(v)
        user = params.get("user", "").strip()
        password = params.get("password", "")
        if not user or not password:
            self.send_response(400)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Missing user or password")
            return
        try:
            data = login_synapse(user, password)
        except urllib.error.HTTPError as e:
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Login failed: {e.code}".encode("utf-8"))
            return
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Error: {e}".encode("utf-8"))
            return
        token = data.get("access_token")
        if not token:
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Login failed: no token")
            return
        # Set cookie with token (httpOnly, Secure in production)
        cookie = f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400"
        if SYNAPSE_URL.startswith("https"):
            cookie += "; Secure"
        self.send_response(302)
        self.send_header("Location", METRICS_PATH)
        self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def send_validate(self):
        cookie_header = self.headers.get("Cookie", "")
        token = parse_cookie(cookie_header)
        if token and whoami(token):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def send_logout(self):
        cookie = f"{COOKIE_NAME}=; Path=/; HttpOnly; Max-Age=0"
        self.send_response(302)
        self.send_header("Location", "/metrics-auth/login")
        self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def send_redirect(self, location: str):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # quiet by default; set to super().log_message for debug


def main():
    host, _, port = LISTEN.rpartition(":")
    port = int(port or "9091")
    server = HTTPServer((host or "127.0.0.1", port), Handler)
    print(f"Metrics auth proxy on http://{host or '127.0.0.1'}:{port} (Synapse: {SYNAPSE_URL})")
    server.serve_forever()


if __name__ == "__main__":
    main()
