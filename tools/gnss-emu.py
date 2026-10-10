#!/usr/bin/env python3
"""NMEA GNSS receiver emulator for Ox's virtual-target GNSS slot.

Listens on a unix socket; QEMU's virtio-serial chardev connects out to
it (server=off,reconnect=N in OX_QEMU_EXTRA). Emits a 1 Hz NMEA stream
on the port named "oxgnss.0":

  * for the first --nofix-secs after the guest connects: GGA with
    fix quality 0 and empty coordinates (receiver sees sky, no fix
    yet — the honest no-fix state ox-gnssd must journal),
  * then GGA fix + RMC valid at the configured coordinates, held
    static so gate assertions can compare exactly.

This emulates a UART GNSS module at NMEA level only. No satellite
exists on the virtual target; the emulator exists so the transport,
parser and permission layer are gate-verified before hardware (same
pattern as the AT modem slot).
"""
import argparse
import os
import socket
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--sock", default="/tmp/ox-gnss-emu.sock")
ap.add_argument("--log", default="/tmp/ox-gnss-emu.log")
ap.add_argument("--lat", type=float, default=37.774933)
ap.add_argument("--lon", type=float, default=-122.419416)
ap.add_argument("--alt", type=float, default=16.1)
ap.add_argument("--sats", type=int, default=9)
ap.add_argument("--hdop", type=float, default=0.9)
ap.add_argument("--nofix-secs", type=float, default=120.0)
ap.add_argument("--rate", type=float, default=1.0)
a = ap.parse_args()

logf = open(a.log, "wb", buffering=0)


def log(s):
    logf.write((s + "\n").encode())


def checksum(body):
    c = 0
    for ch in body:
        c ^= ord(ch)
    return "%02X" % c


def sentence(body):
    return "$%s*%s\r\n" % (body, checksum(body))


def dm(value, width):
    """degrees -> NMEA ddmm.mmmm (lat width=2, lon width=3)"""
    d = int(abs(value))
    m = (abs(value) - d) * 60.0
    return "%0*d%.4f" % (width, d, m)


def gga(now, fix):
    t = time.strftime("%H%M%S.00", time.gmtime(now))
    if fix:
        lat_h = "N" if a.lat >= 0 else "S"
        lon_h = "E" if a.lon >= 0 else "W"
        body = ("GPGGA,%s,%s,%s,%s,%s,1,%02d,%.1f,%.1f,M,-25.4,M,,"
                % (t, dm(a.lat, 2), lat_h, dm(a.lon, 3), lon_h,
                   a.sats, a.hdop, a.alt))
    else:
        body = "GPGGA,%s,,,,,0,00,99.99,,,,," % t
    return sentence(body)


def rmc(now):
    t = time.strftime("%H%M%S.00", time.gmtime(now))
    d = time.strftime("%d%m%y", time.gmtime(now))
    lat_h = "N" if a.lat >= 0 else "S"
    lon_h = "E" if a.lon >= 0 else "W"
    body = ("GPRMC,%s,A,%s,%s,%s,%s,0.05,122.4,%s,,,A"
            % (t, dm(a.lat, 2), lat_h, dm(a.lon, 3), lon_h, d))
    return sentence(body)


if os.path.exists(a.sock):
    os.unlink(a.sock)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(a.sock)
srv.listen(1)
log("emu listening on " + a.sock)
sys.stderr.write("[gnss-emu] listening on %s (fix at %+.6f,%+.6f after %.0fs)\n"
                 % (a.sock, a.lat, a.lon, a.nofix_secs))
while True:
    conn, _ = srv.accept()
    log("qemu connected")
    start = time.time()
    fix_announced = False
    try:
        while True:
            now = time.time()
            if now - start < a.nofix_secs:
                out = gga(now, fix=False).encode()
                log(">> nofix " + out.decode(errors="replace").strip())
            else:
                if not fix_announced:
                    log("FIX ACQUIRED lat=%+.6f lon=%+.6f" % (a.lat, a.lon))
                    fix_announced = True
                out = (gga(now, fix=True) + rmc(now)).encode()
                log(">> fix " + out.decode(errors="replace").strip().replace("\r\n", " | "))
            try:
                conn.sendall(out)
            except OSError:
                break
            time.sleep(a.rate)
    except Exception as e:
        log("emu error: %r" % e)
    finally:
        try:
            conn.close()
        except Exception:
            pass
