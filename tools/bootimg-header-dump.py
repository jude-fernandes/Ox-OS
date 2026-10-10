#!/usr/bin/env python3
"""Dump an Android boot image header (words at 8..44) + the verify's
section walk, to reconcile ox-mkbootimg verify vs the bytes on disk."""
import struct
import sys

path = sys.argv[1]
d = open(path, "rb").read()
print("file size:", len(d))
names = ["kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
         "second_size", "second_addr", "tags_addr", "page_size",
         "header_version", "os_version"]
for i, name in enumerate(names):
    off = 8 + i * 4
    val = struct.unpack_from("<I", d, off)[0]
    print(f"[{off}] {name} = {val} (0x{val:x})")
hv = struct.unpack_from("<I", d, 40)[0]
if hv >= 3:
    hs = struct.unpack_from("<I", d, 20)[0]
    print("header_size:", hs)
else:
    print("dtbo_size @1632:", struct.unpack_from("<I", d, 1632)[0])
    print("dtb_size  @1648:", struct.unpack_from("<I", d, 1648)[0])
