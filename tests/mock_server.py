from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, ctype, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        parts = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        if parts.path == "/text":
            return self._reply(200, "text/plain", "olá texto")
        if parts.path == "/html":
            return self._reply(200, "text/html", "<h1>oi</h1>")
        if parts.path == "/empty":
            return self._reply(204, "text/plain", "")
        if parts.path.startswith("/status/"):
            code = int(parts.path.rsplit("/", 1)[1])
            return self._reply(code, "application/json", '{"status":%d}' % code)
        echo = {
            "method": self.command,
            "path": parts.path,
            "query": parse_qs(parts.query),
            "content_type": self.headers.get("Content-Type"),
            "x_test": self.headers.get("X-Test"),
            "body": raw,
        }
        self._reply(200, "application/json", json.dumps(echo))

    do_GET = do_POST = do_PUT = do_DELETE = _handle

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
