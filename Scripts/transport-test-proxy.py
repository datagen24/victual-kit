#!/usr/bin/env python3
"""Forwarding proxy for the transport test plan (docs/acceptance/transport-test-results.md).

Listens on one address for plain HTTP and for HTTPS with a self-signed
certificate, and forwards each request to the dev instance with the Host header
rewritten to the dev instance's name. Python 3 standard library only.

    VICTUAL_UPSTREAM_HOST=<dev instance host name> \\
    python3 Scripts/transport-test-proxy.py --bind <lan address> \\
        --cert cert.pem --key key.pem [--http-port 8080] [--https-port 8443]

The upstream host comes from the environment, so no host or key is stored here.
Requests are logged without their Authorization header.
"""
import argparse
import http.client
import os
import socket
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}
UPSTREAM = os.environ.get("VICTUAL_UPSTREAM_HOST", "")


class Forward(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Host"] = UPSTREAM
        scheme = "https" if isinstance(self.connection, ssl.SSLSocket) else "http"
        try:
            up = http.client.HTTPConnection(UPSTREAM, 80, timeout=20)
            up.request(self.command, self.path, body=body, headers=headers)
            resp = up.getresponse()
            data = resp.read()
        except Exception as exc:  # report the rig's own failure, not an app one
            msg = f"proxy upstream error: {exc}".encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return
        sys.stderr.write(f"{scheme} Host={self.headers.get('Host')} {self.command} {self.path} -> {resp.status}\n")
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _forward

    def log_message(self, *args):
        pass


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bind", action="append", required=True,
                   help="address to listen on; repeat for 127.0.0.1 or ::1, which a .local name also resolves to")
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--http-port", type=int, default=8080)
    p.add_argument("--https-port", type=int, default=8443)
    a = p.parse_args()
    if not UPSTREAM:
        sys.exit("set VICTUAL_UPSTREAM_HOST to the dev instance's host name")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(a.cert, a.key)
    servers = []
    for addr in a.bind:
        cls = V6Server if ":" in addr else ThreadingHTTPServer
        plain = cls((addr, a.http_port), Forward)
        secure = cls((addr, a.https_port), Forward)
        secure.socket = ctx.wrap_socket(secure.socket, server_side=True)
        servers += [plain, secure]
        print(f"http://{addr}:{a.http_port}  https://{addr}:{a.https_port}  -> {UPSTREAM}", flush=True)
    for srv in servers[1:]:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
