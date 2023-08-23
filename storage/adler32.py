#!/usr/bin/env python2

import sys
import socket
import time
from redis import Redis

if len(sys.argv) < 2:
    sys.exit(1)

name = sys.argv[1]

try:
    r = Redis()
except:
    sys.exit(1)

value = r.get(name)

if value and value != "00000001":
    print(value.decode("utf-8"))
    sys.exit(0)

servers = [
    "10.1.2.11",
    "10.1.2.12",
    "10.1.2.13",
]


def calculate():
    value = None

    for addr in servers:
        try:
            sock = socket.create_connection((addr, 9500), timeout=3)
        except:
            continue
        sock.settimeout(None)
        sock.send(("/storage/data/cms/" + name + "\n").encode("utf-8"))
        value = sock.recv(8)
        sock.close()
        if value:
            break

    return value


value = calculate()

if not value:
    sys.exit(1)

if value == "00000001":
    time.sleep(3)
    value = calculate()

if value != "00000001":
    r.set(name, value)

print(value.decode("utf-8"))
