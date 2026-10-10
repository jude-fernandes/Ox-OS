#!/usr/bin/env python3
"""Minimal AT modem emulator for Ox's virtual-target modem slot.

Listens on a unix socket; QEMU's virtio-serial chardev connects out to
it (server=off,reconnect=N in OX_QEMU_EXTRA). Speaks the V.250 subset
oxmodemd will rely on: ATE, AT+GMI/GMM/GMR, ATI, AT+CPIN?, AT+CSQ,
AT+CREG?, AT+COPS?. Everything else answers ERROR and is logged.

With --ctl PATH a control socket opens next to it: gates inject
inbound SMS ({"inject_sms": {"from": ..., "text": ...}}) — the
emulator stores them and raises +CMTI to the guest, which reads them
back with AT+CMGR and deletes with AT+CMGD (both implemented here).

This emulates a Quectel EG25-G personality at AT level only. No radio
exists on the virtual target; the emulator exists so the transport and
command layer are gate-verified before hardware (same pattern as
virtio-sound for audio).
"""
import argparse
import json
import os
import socket
import sys
import threading

ap = argparse.ArgumentParser()
ap.add_argument("--sock", default="/tmp/ox-modem-emu.sock")
ap.add_argument("--log", default="/tmp/ox-modem-emu.log")
ap.add_argument("--ctl", default=None, help="control socket for injections")
a = ap.parse_args()

logf = open(a.log, "wb", buffering=0)


def log(s):
    logf.write((s + "\n").encode())


ECHO = False
IN_CALL = None  # number currently dialed (voice call state)
# mobile-terminated call: None or {"number":..., "state": ringing|active}
MT_CALL = [None]

# inbound SMS store: idx -> (from, text); +CMTI raises idx to the guest
SMS_STORE = {}
SMS_NEXT = [1]
CONN = [None]  # the live modem connection (QEMU chardev), if any
WRITE_LOCK = threading.Lock()
PENDING_CMTI = []  # injected before the guest connected


def conn_send(conn, payload):
    with WRITE_LOCK:
        conn.sendall(payload)


def raise_cmti(idx):
    line = '+CMTI: "SM",%d\r\n' % idx
    if CONN[0] is not None:
        conn_send(CONN[0], line.encode())
        log(">> " + repr(line))
    else:
        PENDING_CMTI.append(line)
        log(">> (queued, no conn) " + repr(line))


def ring_loop():
    """RING every 2s while an MT call is ringing (network behavior)."""
    while True:
        mt = MT_CALL[0]
        if mt and mt["state"] == "ringing" and CONN[0] is not None:
            conn_send(CONN[0], b"RING\r\n")
            log(">> RING")
        threading.Event().wait(2.0)


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
                inj = req.get("inject_sms")
                call = req.get("inject_call")
                if call:
                    if MT_CALL[0] is not None:
                        log("CALL-INJECT refused (busy)")
                        try:
                            c.sendall(b'{"ok":false,"reason":"busy"}\n')
                        except OSError:
                            pass
                        continue
                    frm = str(call["from"])
                    MT_CALL[0] = {"number": frm, "state": "ringing"}
                    log("CALL-INCOMING from=%s" % frm)
                    try:
                        c.sendall(b'{"ok":true}\n')
                    except OSError:
                        pass
                    continue
                if not inj:
                    log("ctl unknown req: %r" % req)
                    continue
                idx = SMS_NEXT[0]
                SMS_NEXT[0] += 1
                SMS_STORE[idx] = (str(inj["from"]), str(inj["text"]))
                log("SMS-INJECT idx=%d from=%s text=%r" % (idx, inj["from"], inj["text"]))
                raise_cmti(idx)
                try:
                    c.sendall(b'{"ok":true,"idx":%d}\n' % idx)
                except OSError:
                    pass

    def loop():
        while True:
            c, _ = srv.accept()
            try:
                handle_ctl(c)
            except Exception as e:  # keep serving
                log("ctl error: %r" % e)
            finally:
                try:
                    c.close()
                except Exception:
                    pass

    threading.Thread(target=loop, daemon=True).start()


def respond(conn, lines, final="OK"):
    out = b""
    for l in lines:
        out += (l + "\r\n").encode()
    out += ("\r\n" + final + "\r\n").encode()
    log("<< " + repr(out))
    conn_send(conn, out)


def handle(conn):
    global ECHO
    buf = b""
    prompt_mode = False
    prompt_cmd = b""
    body = b""
    sms_id = 0
    while True:
        try:
            data = conn.recv(1024)
        except OSError:
            break
        if not data:
            break
        buf += data
        if prompt_mode:
            # CMGS body: everything until Ctrl-Z (0x1a)
            if 0x1a in data:
                body += data.split(b"\x1a")[0]
                sms_id += 1
                num = prompt_cmd.decode(errors="replace")
                num = num.split("+CMGS=")[-1].strip().strip('"')
                text = body.decode(errors="replace")
                log("SMS-SENT to %s: %r" % (num, text))
                conn_send(conn, b"\r\n+CMGS: %d\r\n\r\nOK\r\n" % sms_id)
                prompt_mode = False
                prompt_cmd = b""
                body = b""
                buf = data.split(b"\x1a", 1)[1]
            else:
                body += data
                buf = b""
            continue
        while b"\r" in buf:
            raw, buf = buf.split(b"\r", 1)
            cmd = raw.decode(errors="replace").strip()
            if not cmd:
                continue
            log("AT " + repr(cmd))
            if ECHO:
                conn_send(conn, (cmd + "\r\n").encode())
            c = cmd.upper()
            if c.startswith("ATE"):
                ECHO = c != "ATE0"
                respond(conn, [])
            elif c == "AT+GMI":
                respond(conn, ["Quectel"])
            elif c == "AT+GMM":
                respond(conn, ["EG25-G"])
            elif c == "AT+GMR":
                respond(conn, ["EG25GGBR07A08M2G_OXEMU"])
            elif c == "ATI":
                respond(conn, ["Quectel", "EG25-G", "Revision: OXEMU"])
            elif c == "AT+CPIN?":
                respond(conn, ["+CPIN: READY"])
            elif c == "AT+CSQ":
                respond(conn, ["+CSQ: 24,0"])
            elif c == "AT+CREG?":
                respond(conn, ["+CREG: 0,1"])
            elif c == "AT+COPS?":
                respond(conn, ['+COPS: 0,0,"OxEmu",7'])
            elif c.startswith("ATD"):
                # mobile-originated voice call: number between ATD and
                # the trailing ';' — the emulator "connects" instantly
                num = cmd[3:].rstrip(";").strip()
                IN_CALL = num
                log("CALL-DIAL to %s" % num)
                respond(conn, [])
            elif c in ("ATH", "AT+CHUP"):
                mt = MT_CALL[0]
                if mt and mt["state"] == "ringing":
                    log("CALL-DECLINED (was %s)" % mt["number"])
                    MT_CALL[0] = None
                elif mt:
                    log("CALL-END (was %s)" % mt["number"])
                    MT_CALL[0] = None
                else:
                    log("CALL-END (was %s)" % (IN_CALL or "none"))
                    IN_CALL = None
                respond(conn, [])
            elif c == "ATA":
                mt = MT_CALL[0]
                if mt and mt["state"] == "ringing":
                    mt["state"] = "active"
                    log("CALL-ANSWER (was %s)" % mt["number"])
                    respond(conn, [])
                else:
                    log("ATA with no ringing call")
                    respond(conn, [], final="ERROR")
            elif c == "AT+CLCC":
                mt = MT_CALL[0]
                if mt and mt["state"] == "ringing":
                    respond(conn, ['+CLCC: 1,1,4,0,0,"%s",129' % mt["number"]])
                elif mt:
                    respond(conn, ['+CLCC: 1,1,0,0,0,"%s",129' % mt["number"]])
                elif IN_CALL:
                    respond(conn, ['+CLCC: 1,0,0,0,0,"%s",129' % IN_CALL])
                else:
                    respond(conn, [], final="OK")
            elif c.startswith("AT+CMGF"):
                respond(conn, [])
            elif c.startswith("AT+CMGS="):
                # two-phase: issue the prompt, wait for body+Ctrl-Z
                prompt_mode = True
                prompt_cmd = cmd.encode()
                body = b""
                log(">> prompt >")
                conn_send(conn, b"\r\n> ")
            elif c.startswith("AT+CMGR="):
                idx = int(c.split("=")[1].strip())
                if idx in SMS_STORE:
                    frm, text = SMS_STORE[idx]
                    log("SMS-READ idx=%d from=%s" % (idx, frm))
                    respond(conn, [
                        '+CMGR: "REC UNREAD","%s",,"26/09/10,12:00:00+08"' % frm,
                        text,
                    ])
                else:
                    log("SMS-READ idx=%d MISSING" % idx)
                    respond(conn, [], final="+CMS ERROR: 500")
            elif c.startswith("AT+CMGD="):
                idx = int(c.split("=")[1].strip())
                SMS_STORE.pop(idx, None)
                log("SMS-DELETE idx=%d" % idx)
                respond(conn, [])
            else:
                log("UNKNOWN " + c)
                respond(conn, [], final="ERROR")


if os.path.exists(a.sock):
    os.unlink(a.sock)
if a.ctl:
    ctl_serve(a.ctl)
threading.Thread(target=ring_loop, daemon=True).start()
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(a.sock)
srv.listen(1)
log("emu listening on " + a.sock)
sys.stderr.write("[modem-emu] listening on " + a.sock + "\n")
while True:
    conn, _ = srv.accept()
    log("qemu connected")
    CONN[0] = conn
    try:
        with WRITE_LOCK:
            for line in PENDING_CMTI:
                conn.sendall(line.encode())
        PENDING_CMTI.clear()
        handle(conn)
    except Exception as e:  # keep serving reconnects
        log("emu error: %r" % e)
    finally:
        CONN[0] = None
        try:
            conn.close()
        except Exception:
            pass
