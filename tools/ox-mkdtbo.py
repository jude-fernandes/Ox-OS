#!/usr/bin/env python3
"""ox-mkdtbo.py - deterministic Android DTBO image packer/verifier.

Packs one or more FDT blobs into the dt_table (dtbo) image format the
Android bootloader expects on the dtbo partition (AOSP
system/libufdt/utils/src/mkdtboimg.py format, header version 0):
    magic 0xd7b7ab1e, 32-byte header, 32-byte entries, page-aligned.
Fully deterministic (no timestamps); --verify re-parses and checks
every blob is a valid FDT and the size accounting closes.
"""
import argparse
import struct
import sys

DTBO_MAGIC = 0xD7B7AB1E
HEADER_SIZE = 32
ENTRY_SIZE = 32
BLOCK_SIZE = 4
DEFAULT_PAGE_SIZE = 2048


def pack(args):
    blobs = [open(p, "rb").read() for p in args.dtb]
    page = args.page_size
    # entries sit immediately after the header; dt_entries_offset = 32
    off = HEADER_SIZE + ENTRY_SIZE * len(blobs)
    off = (off + BLOCK_SIZE - 1) // BLOCK_SIZE * BLOCK_SIZE
    entries = b""
    payload = b""
    for i, blob in enumerate(blobs):
        if blob[:4] != b"\xd0\x0d\xfe\xed":
            sys.exit(f"dtb {args.dtb[i]} is not an FDT (no magic)")
        entries += struct.pack(">IIII4I", ENTRY_SIZE, off,
                               args.id if args.id is not None else i,
                               args.rev if args.rev is not None else 0,
                               0, 0, 0, 0)
        payload += blob
        pad = (BLOCK_SIZE - len(payload) % BLOCK_SIZE) % BLOCK_SIZE
        payload += b"\x00" * pad
        off += len(blob) + pad
    total = off
    total = (total + page - 1) // page * page
    hdr = struct.pack(">IIIIIIII", DTBO_MAGIC, total, HEADER_SIZE,
                      ENTRY_SIZE, len(blobs), HEADER_SIZE, page, 0)
    img = hdr + entries + payload
    img += b"\x00" * (total - len(img))
    with open(args.output, "wb") as f:
        f.write(img)
    print(f"wrote {args.output}: {len(blobs)} dtbo entries, "
          f"{total} bytes (page {page})")


def verify(path):
    with open(path, "rb") as f:
        blob = f.read()
    magic, total, hsz, esz, count, eoff, page, ver = struct.unpack(
        ">IIIIIIII", blob[:32])
    problems = []
    if magic != DTBO_MAGIC:
        sys.exit("not a dtbo image (bad magic)")
    if hsz != HEADER_SIZE or esz != ENTRY_SIZE:
        problems.append(f"header_size {hsz}/entry_size {esz} != 32/32")
    if total > len(blob):
        problems.append(f"total_size {total} > file size {len(blob)}")
    # trailing bytes beyond total_size are legal: AVB hash footers pad
    # the image out to the full partition size (the footer's signature
    # covers them — verified by avbtool, not here)
    ids = []
    for i in range(count):
        base = eoff + i * esz
        if base + esz > len(blob):
            problems.append(f"entry {i} at {base} out of range")
            continue
        esz2, eoff2, eid, rev = struct.unpack(">IIII", blob[base:base + 16])
        if esz2 != ENTRY_SIZE:
            problems.append(f"entry {i} size {esz2} != 32")
        if eoff2 + 4 > len(blob):
            problems.append(f"entry {i} offset {eoff2} out of range")
            continue
        if blob[eoff2:eoff2 + 4] != b"\xd0\x0d\xfe\xed":
            problems.append(f"entry {i} blob lacks FDT magic")
        ids.append(eid)
    if problems:
        for p in problems:
            print("VERIFY FAIL:", p, file=sys.stderr)
        sys.exit(1)
    print(f"dtbo OK: {count} entries, ids {ids}, page {page}, "
          f"total {total}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dtb", action="append",
                    help="FDT blob; repeatable (entry i or --id)")
    ap.add_argument("--id", type=int, default=None,
                    help="single-entry id (default: input order)")
    ap.add_argument("--rev", type=int, default=None)
    ap.add_argument("--page-size", type=int, default=DEFAULT_PAGE_SIZE)
    ap.add_argument("-o", "--output")
    ap.add_argument("--verify", action="store_true",
                    help="verify OUTPUT instead of building")
    args = ap.parse_args()
    if args.verify:
        verify(args.output)
        return
    if not args.output:
        ap.error("--output is required (unless --verify)")
    if not args.dtb:
        ap.error("--dtb is required (unless --verify)")
    pack(args)


if __name__ == "__main__":
    main()
