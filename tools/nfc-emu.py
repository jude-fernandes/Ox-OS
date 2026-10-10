#!/usr/bin/env python3
"""Virtual NFC reader for Ox's NFC slot.

Listens on a unix socket; QEMU's virtio-serial chardev connects out to
it (server=off,reconnect=N in OX_QEMU_EXTRA). While no tag is in
range it emits an idle frame (`$TGN,*XX`) every 2 s — the guest's
honest "no tag" state. With --ctl PATH a control socket accepts
{"present_tag": {"uid": <hex>, "text": <payload>}}; the emulator
validates, base64-encodes the text and sends ONE tagged frame
(`$TGC,<uid>,<b64>*XX` — NMEA framing, XOR checksum) to the guest.
"""
import argparse
import json
import os
import socket
import sys
import threading

ap = argparse.ArgumentParser()
ap.add_argument("--sock", default="/tmp/ox-nfc-emu.sock")
ap.add_argument("--log", default="/tmp/ox-nfc-emu.log")
ap.add_argument("--ctl", default=None, help="control socket for tag presentation")
a = ap.parse_args()

logf = open(a.log, "wb", buffering=0)


def log(s):
    logf.write((s + "\n").encode())


CONN = [None]
LOCK = threading.Lock()


def send_frame(conn, body):
    # XOR checksum over everything between '$' and '*'
    import functools
    import operator
    sum = functools.reduce(operator.xor, (ord(c) for c in body), 0)
    frame = "$%s*%02X\r\n" % (body, sum)
    with LOCK:
        conn.sendall(frame.encode())
    log(">> " + repr(frame))


def idle_loop():
    while True:
        c = CONN[0]
        if c is not None:
            try:
                send_frame(c, "TGN,")
            except OSError:
                pass
        threading.Event().wait(2.0)


def validate_tag(uid, text):
    if not (4 <= len(uid) <= 20) or not all(ch in "0123456789abcdefABCDEF" for ch in uid):
        return "uid must be 4..=20 hex chars"
    if not text or len(text) > 120:
        return "text must be 1..=120 bytes"
    if any(not (0x20 <= ord(ch) < 0x7f) for ch in text):
        return "text must be printable ASCII"
    return None


def ctl_serve(path):
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    log("ctl listening on " + path)

    def handle_ctl(c):
        buf = b""
        while True:
            try:
                data = c.recv(4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                try:
                    req = json.loads(raw.decode())
                except Exception:
                    log("ctl bad json: %r" % raw)
                    continue
                tag = req.get("present_tag")
                if not tag:
                    log("ctl unknown req: %r" % req)
                    continue
                uid = str(tag["uid"])
                text = str(tag["text"])
                err = validate_tag(uid, text)
                if err:
                    log("TAG-REFUSED %s: %s" % (uid, err))
                    try:
                        c.sendall(b'{"ok":false,"reason":"%s"}\n' % err.encode())
                    except OSError:
                        pass
                    continue
                b64 = __import__("base64").b64encode(text.encode()).decode()
                conn = CONN[0]
                if conn is None:
                    log("TAG-DROPPED (no conn) %s" % uid)
                    try:
                        c.sendall(b'{"ok":false,"reason":"no reader conn"}\n')
                    except OSError:
                        pass
                    continue
                send_frame(conn, "TGC,%s,%s" % (uid, b64))
                log("TAG-PRESENTED uid=%s text=%r" % (uid, text))
                try:
                    c.sendall(b'{"ok":true}\n')
                except OSError:
                    pass

    def loop():
        while True:
            c, _ = srv.accept()
            try:
                handle_ctl(c)
            except Exception as e:
                log("ctl error: %r" % e)
            finally:
                try:
                    c.close()
                except Exception:
                    pass

    threading.Thread(target=loop, daemon=True).start()


if os.path.exists(a.sock):
    os.unlink(a.sock)
if a.ctl:
    ctl_serve(a.ctl)
threading.Thread(target=idle_loop, daemon=True).start()
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(a.sock)
srv.listen(1)
log("emu listening on " + a.sock)
sys.stderr.write("[nfc-emu] listening on " + a.sock + "\n")
while True:
    conn, _ = srv.accept()
    log("qemu connected")
    CONN[0] = conn
    try:
        while True:
            data = conn.recv(1024)
            if not data:
                break
            log("guest said: %r" % data)
    except Exception as e:
        log("emu error: %r" % e)
    finally:
        CONN[0] = None
        try:
            conn.close()
        except Exception:
            pass
