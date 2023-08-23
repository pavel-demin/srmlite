from functools import lru_cache
from http.server import BaseHTTPRequestHandler
from os.path import normpath
from random import choice
from socket import AF_INET6
from socketserver import TCPServer
from ssl import wrap_socket

servers = [
    "https://ingrid-se02.cism.ucl.ac.be:1094",
    "https://ingrid-se03.cism.ucl.ac.be:1094",
    "https://ingrid-se04.cism.ucl.ac.be:1094",
]


@lru_cache(maxsize=1000)
def location(path):
    return choice(servers) + path


class RequestHandler(BaseHTTPRequestHandler):
    def redirect(self, code):
        self.send_response_only(code)
        path = normpath(self.path).replace("//", "/")
        self.send_header("Location", location(path))
        self.end_headers()

    def do_OPTIONS(self):
        self.redirect(307)

    def do_HEAD(self):
        self.redirect(307)

    def do_PROPFIND(self):
        self.redirect(307)

    def do_MKCOL(self):
        self.redirect(307)

    def do_DELETE(self):
        self.redirect(307)

    def do_COPY(self):
        self.redirect(307)

    def do_PUT(self):
        self.redirect(307)

    def do_GET(self):
        self.redirect(302)


TCPServer.address_family = AF_INET6
httpd = TCPServer(("", 1094), RequestHandler)
httpd.socket = wrap_socket(
    httpd.socket,
    certfile="/etc/grid-security/xrd/xrdcert.pem",
    keyfile="/etc/grid-security/xrd/xrdkey.pem",
    server_side=True,
)

httpd.serve_forever()
