#!/usr/bin/env python3
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    assert f.read(3).strip() == b"P6"
    dims = []
    while len(dims) < 2:
        line = f.readline()
        if line.startswith(b"#"):
            continue
        dims += [int(x) for x in line.split()]
    w, h = dims[:2]
    assert int(f.readline()) == 255
    raw = f.read()

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

rows = b"".join(b"\x00" + raw[y*w*3:(y+1)*w*3] for y in range(h))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows, 9))
png += chunk(b"IEND", b"")
open(dst, "wb").write(png)
print(f"wrote {dst} ({w}x{h})")
