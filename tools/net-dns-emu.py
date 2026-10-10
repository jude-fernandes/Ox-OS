#!/usr/bin/env python3
"""Deterministic DNS responder for the network gate.

Listens on host 127.0.0.1:53 (UDP); the guest's netd forwards queries
to 10.0.2.2:53, which slirp routes here. Answers every A query with
192.0.2.1 (TEST-NET-1) so the gate never depends on real internet.
Logs every queried name for host-side cross-checking.
"""
import argparse
import os
import socket

ap = argparse.ArgumentParser()
ap.add_argument("--bind", default="127.0.0.1")
ap.add_argument("--port", type=int, default=53)
ap.add_argument("--log", default="/tmp/ox-netgate/dns-emu.log")
a = ap.parse_args()

os.makedirs(os.path.dirname(a.log), exist_ok=True)
logf = open(a.log, "wb", buffering=0)


def log(s):
    logf.write((s + "\n").encode())


def query_name(pkt):
    if len(pkt) < 12:
        return None
    i = 12
    labels = []
    while i < len(pkt):
        l = pkt[i]
        if l == 0:
            return ".".join(labels) if labels else None
        if l > 63 or i + 1 + l > len(pkt):
            return None
        labels.append(pkt[i + 1 : i + 1 + l].decode(errors="replace"))
        i += 1 + l
    return None


srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
srv.bind((a.bind, a.port))
log("dns-emu listening on %s:%d" % (a.bind, a.port))
print("[dns-emu] listening on %s:%d" % (a.bind, a.port), flush=True)
while True:
    data, src = srv.recvfrom(1500)
    name = query_name(data)
    log("QUERY %s from %s" % (name, src))
    if name is None or len(data) < 12:
        continue
    # response: id, QR|RD|RA|rcode0, qd=1, an=1, ns=0, ar=0
    resp = bytearray(data[:12])
    resp[2] = data[2] | 0x80 | 0x01  # QR=1, RD=1
    resp[3] = (data[3] & 0xF0) | 0x80  # RA=1, RCODE=0
    resp[4:12] = bytes([0, 1, 0, 1, 0, 0, 0, 0])
    resp += data[12:]  # question echoed
    # answer: pointer to qname, A, IN, ttl=60, rdlen=4, 192.0.2.1
    resp += bytes([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1])
    srv.sendto(bytes(resp), src)
