from http.server import BaseHTTPRequestHandler
from random import choice
from socketserver import TCPServer
from ssl import wrap_socket

# list of servers for metadata operations
meta = [
    "https://ingrid-se02.cism.ucl.ac.be:1094",
]

# list of servers for data transfer operations
data = [
    "https://ingrid-se03.cism.ucl.ac.be:1094",
    "https://ingrid-se04.cism.ucl.ac.be:1094",
]


class RequestHandler(BaseHTTPRequestHandler):
    def redirect(self, code, servers):
        location = choice(servers) + self.path
        self.send_response_only(code)
        self.send_header("Server", self.version_string())
        self.send_header("Location", location)
        self.end_headers()

    def do_OPTIONS(self):
        self.redirect(307, meta)

    def do_HEAD(self):
        self.redirect(307, meta)

    def do_PROPFIND(self):
        self.redirect(307, meta)

    def do_MKCOL(self):
        self.redirect(307, meta)

    def do_DELETE(self):
        self.redirect(307, meta)

    def do_COPY(self):
        self.redirect(307, meta)

    def do_PUT(self):
        self.redirect(307, data)

    def do_GET(self):
        self.redirect(302, data)


httpd = TCPServer(("0.0.0.0", 443), RequestHandler)
httpd.socket = wrap_socket(
    httpd.socket,
    certfile="/etc/grid-security/xrd/xrdcert.pem",
    keyfile="/etc/grid-security/xrd/xrdkey.pem",
    server_side=True,
)

httpd.serve_forever()
