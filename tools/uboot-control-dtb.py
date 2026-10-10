#!/usr/bin/env python3
"""uboot-control-dtb.py - extract U-Boot's control DTB.

Accepts either:
  u-boot.bin  — u-boot-nodtb.bin + flattened control DTB concatenated
                (binman); the DTB is the LAST FDT magic in the file.
  u-boot.itb  — the U-Boot FIT (u-boot + TF-A nodes); the "u-boot" image
                is extracted first (dumpimage), then scanned the same way.
The control DTB is what `mkimage -K` injects the FIT verification key
into (chunk 72 / BRINGUP M2) and what the target gate asserts.
"""
import struct
import subprocess
import sys
import tempfile
import os
import shutil


def scan_fdt(data, label):
    magic = b"\xd0\x0d\xfe\xed"
    pos = data.rfind(magic)
    if pos < 0 or pos % 4 != 0:
        sys.exit(f"no FDT magic in {label}")
    (totalsize,) = struct.unpack_from(">I", data, pos + 4)
    if pos + totalsize > len(data) or totalsize < 64:
        sys.exit(f"implausible FDT size {totalsize} at {pos} in {label}")
    return pos, data[pos:pos + totalsize]


def extract_uboot_image(itb):
    # older u-boot-tools dumpimage has no -n: extract by POSITION. The
    # control DTB may be its own FIT node (fdt-N, blob STARTS with the
    # FDT magic — the rk3399/pinephone-pro FIT layout) or concatenated
    # after u-boot-nodtb.bin inside the u-boot image (blob CONTAINS the
    # magic). Try every position; first FDT wins.
    last_err = "no position extracted"
    for pos in range(10):
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".img")
        tmp.close()
        rc = subprocess.run(
            ["dumpimage", "-T", "flat_dt", "-p", str(pos),
             "-o", tmp.name, itb],
            capture_output=True, text=True)
        if rc.returncode != 0 or os.path.getsize(tmp.name) == 0:
            last_err = f"pos {pos}: {rc.stderr.strip()}"
            os.unlink(tmp.name)
            continue
        data = open(tmp.name, "rb").read()
        os.unlink(tmp.name)
        if data[:4] == b"\xd0\x0d\xfe\xed":
            (totalsize,) = struct.unpack_from(">I", data, 4)
            print(f"FIT image {pos} IS the control DTB ({totalsize} bytes)")
            return 0, data[:totalsize]
        try:
            p, dtb = scan_fdt(data, f"FIT image {pos}")
            print(f"FIT image {pos} contains an FDT at +{p}")
            return p, dtb
        except SystemExit:
            last_err = f"pos {pos}: no FDT magic in {len(data)} bytes"
    sys.exit(f"no FIT image carries a control DTB: {last_err}")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: uboot-control-dtb.py <u-boot.bin|u-boot.itb> out.dtb")
    src = sys.argv[1]
    if src.endswith(".itb"):
        pos, dtb = extract_uboot_image(src)
    else:
        data = open(src, "rb").read()
        pos, dtb = scan_fdt(data, src)
    open(sys.argv[2], "wb").write(dtb)
    print(f"control dtb: {len(dtb)} bytes at offset {pos} -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
