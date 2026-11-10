#!/usr/bin/env python3
"""Local, credential-free two-account fixture for manual container verification."""
import argparse
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


class Accounts(BaseHTTPRequestHandler):
    def do_GET(self):
        cookies = SimpleCookie(self.headers.get("Cookie", ""))
        account = cookies["account"].value if "account" in cookies else ""
        if account not in ("A", "B"):
            account = ""
        status = f"Signed in as Account {account}" if account else "Signed out"
        body = f"""<!doctype html><meta charset="utf-8"><title>Container test — {status}</title>
<style>body{{font:18px system-ui;max-width:640px;margin:60px auto;padding:24px}}button,a{{margin:8px}}</style>
<h1>Container test</h1><h2>{status}</h2>
<form method="post"><button name="account" value="A">Sign in as A</button>
<button name="account" value="B">Sign in as B</button><button name="account" value="">Sign out</button></form>
<p id="storage"></p><a href="/details">Same-site details (Peek / Little Arc / Split)</a>
<p>Reload or restart the browser. Each container should retain its own account.</p>
<script>
const account = '{account}';
if (account) localStorage.setItem('account', account);
else localStorage.removeItem('account');
document.getElementById('storage').textContent = 'localStorage account: ' + (localStorage.getItem('account') || '(empty)');
</script>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1024:
            self.send_error(413)
            return
        account = parse_qs(self.rfile.read(length).decode()).get("account", [""])[0]
        if account not in ("A", "B", ""):
            self.send_error(400)
            return
        self.send_response(303)
        self.send_header("Set-Cookie", f"account={account}; Path=/; Max-Age={86400 if account else 0}; HttpOnly; SameSite=Lax")
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Accounts)
    print(f"Container test: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
