#!/usr/bin/env python3
"""Local HTTP server for the tests: echoes what it received. Prints the port.
Works with Python 3.6 and later. With a certificate and a key as arguments it serves https."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlsplit, parse_qs


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """http.server.ThreadingHTTPServer only exists from Python 3.7; RHEL 8 has 3.6."""
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, ctype, body, location=None):
        data = body.encode()
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        parts = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        if parts.path == "/text":
            return self._reply(200, "text/plain", "hello text")
        if parts.path == "/html":
            return self._reply(200, "text/html", "<h1>oi</h1>")
        if parts.path == "/empty":
            return self._reply(204, "text/plain", "")
        if parts.path.startswith("/status/"):
            code = int(parts.path.rsplit("/", 1)[1])
            return self._reply(code, "application/json", '{"status":%d}' % code)
        if parts.path == "/redirect":
            return self._reply(302, "text/plain", "moved", "/text")
        if parts.path == "/loop":
            return self._reply(302, "text/plain", "again", "/loop")
        if parts.path.startswith("/sleep/"):
            time.sleep(int(parts.path.rsplit("/", 1)[1]) / 1000.0)
            return self._reply(200, "text/plain", "slept")
        echo = {
            "method": self.command,
            "path": parts.path,
            "query": parse_qs(parts.query),
            "content_type": self.headers.get("Content-Type"),
            "x_test": self.headers.get("X-Test"),
            "body": raw,
        }
        self._reply(200, "application/json", json.dumps(echo))

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if len(sys.argv) == 3:      # mock_server.py <certificate> <key>: serve https instead
        import ssl
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1], sys.argv[2])
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
