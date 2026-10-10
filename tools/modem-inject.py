#!/usr/bin/env python3
"""Inject through modem-emu's control socket.

usage: modem-inject.py CTL_SOCK FROM TEXT      (inbound SMS)
       modem-inject.py CTL_SOCK '<json>'       (raw request, e.g.
        '{"inject_call":{"from":"+15550003"}}')
Sends the request and prints the emulator's reply; exits 0 only when
the emulator confirmed.
"""
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
if sys.argv[2].startswith("{"):
    payload = sys.argv[2]
else:
    payload = json.dumps(
        {"inject_sms": {"from": sys.argv[2], "text": sys.argv[3]}}
    )
s.sendall((payload + "\n").encode())
buf = b""
while b"\n" not in buf:
    data = s.recv(4096)
    if not data:
        break
    buf += data
reply = json.loads(buf.split(b"\n")[0].decode())
if not reply.get("ok"):
    sys.stderr.write("inject refused: %r\n" % reply)
    sys.exit(1)
print("injected: %s" % reply)
