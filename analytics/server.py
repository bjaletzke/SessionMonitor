"""Serve the local analytics workspace: python3 -m analytics.server."""

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sqlite3
from urllib.parse import parse_qs, urlsplit

from .data import Warehouse, rows
from .insights import build_insights


def handler_for(warehouse):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Query text and chat identities do not belong in access logs.

        def send(self, status, data, content_type="application/json; charset=utf-8"):
            if not isinstance(data, bytes):
                data = json.dumps(data, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
            self.end_headers()
            self.wfile.write(data)

        def local_request(self):
            expected = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
            host = self.headers.get("Host", "")
            origin = self.headers.get("Origin")
            if host not in expected or (origin and origin != f"http://{host}"):
                self.send(403, {"error": "Use this workspace from its local address."})
                return False
            return True

        def do_GET(self):
            if not self.local_request():
                return
            url = urlsplit(self.path)
            params = parse_qs(url.query)
            if url.path == "/api/data":
                self.send(200, warehouse.payload())
            elif url.path == "/api/chat":
                self.send(200, warehouse.detail(params.get("id", [""])[0]))
            elif url.path == "/api/search":
                q = params.get("q", [""])[0][:500]
                matches = rows(warehouse.db, "SELECT DISTINCT chat_id FROM messages WHERE instr(lower(text),lower(?))>0", (q,)) if q else []
                self.send(200, {"ids": [r["chat_id"] for r in matches]})
            elif url.path == "/api/events":
                self.send(200, rows(warehouse.db, "SELECT * FROM usage_events"))
            else:
                files = {"/": ("index.html", "text/html; charset=utf-8")}
                for name in ("app.js", "explorer.js", "constellation.js", "atlas.js", "conversations.js",
                             "vendor/d3.min.js", "vendor/three.module.js", "vendor/three.core.js", "vendor/three.OrbitControls.js"):
                    files["/" + name] = (name, "text/javascript; charset=utf-8")
                for name in ("style.css", "explorer.css", "constellation.css", "atlas.css", "conversations.css"):
                    files["/" + name] = (name, "text/css; charset=utf-8")
                for name in ("vendor/D3-LICENSE.txt", "vendor/three.LICENSE.txt", "vendor/three.NOTICE.txt"):
                    files["/" + name] = (name, "text/plain; charset=utf-8")
                if url.path not in files:
                    self.send(404, {"error": "Not found"})
                    return
                name, mime = files[url.path]
                path = Path(__file__).with_name("web").joinpath(name)
                if not path.is_file():
                    self.send(404, {"error": "Asset not available"})
                    return
                self.send(200, path.read_bytes(), mime)

        def do_POST(self):
            if not self.local_request():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 25000 or self.headers.get_content_type() != "application/json":
                    self.send(400, {"error": "Send application/json under 25,000 bytes."})
                    return
                payload = json.loads(self.rfile.read(length) or "{}")
                if not isinstance(payload, dict):
                    raise ValueError("Expected a JSON object")
                if self.path == "/api/query":
                    self.send(200, warehouse.query(payload.get("sql"), payload.get("filters")))
                elif self.path == "/api/scope":
                    scope = warehouse.scope(payload.get("filters"))
                    self.send(200, {**scope, **build_insights(scope["chats"])})
                elif self.path == "/api/refresh":
                    warehouse.refresh()
                    self.send(200, warehouse.payload())
                else:
                    self.send(404, {"error": "Not found"})
            except (ValueError, sqlite3.Error) as error:
                self.send(400, {"error": str(error)})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--limit", type=int, default=500, help="Recent chats per connection, 1–2000")
    parser.add_argument("--snapshot", action="append", default=[], type=Path, help="Existing Swift --snapshot JSON (repeatable)")
    for name in ("t3", "codex", "claude", "hermes", "harness"):
        parser.add_argument(f"--{name}-home", type=Path)
    args = parser.parse_args()
    warehouse = Warehouse(snapshots=args.snapshot, limit=args.limit,
                          path_overrides={k: getattr(args, k + "_home") for k in ("t3", "codex", "claude", "hermes", "harness") if getattr(args, k + "_home")})
    server = HTTPServer(("127.0.0.1", args.port), handler_for(warehouse))
    server.timeout = 10
    print(f"Session Monitor analytics: http://127.0.0.1:{server.server_port}", flush=True)
    print("Local read-only sources. Ctrl+C stops the workspace.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        warehouse.db.close()


if __name__ == "__main__":
    main()
