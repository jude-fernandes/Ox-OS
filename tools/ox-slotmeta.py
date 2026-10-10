#!/usr/bin/env python3
"""ox-slotmeta.py — the A/B slot metadata format (chunk 76, M2
groundwork; BRINGUP.md: "metadata partition carries slot counters").

Layout (the first 4KiB of the ox-metadata partition, little-endian):

    offset  size  field
    0       4     magic b"OXSB"
    4       4     version (=1)
    8       4     active_slot (0 = a, 1 = b)
    12      4     boot_attempts (unconfirmed-boot counter for active)
    16      4     boot_count_a
    20      4     boot_count_b
    24      32    root_hash_a (dm-verity root of slot a system)
    56      32    root_hash_b (dm-verity root of slot b system)
    88      32    sha256 over bytes 0..88 (integrity)

Everything else on the partition is zero. Deterministic: no timestamps.
`--selftest` proves pack->read round-trips and tamper detection.
"""
import argparse
import hashlib
import os
import struct
import sys

MAGIC = b"OXSB"
VERSION = 1
SIZE = 136


def _h(b):
    return hashlib.sha256(b).digest()


def pack(active_slot=0, boot_attempts=0, boot_count_a=0, boot_count_b=0,
         root_hash_a=b"\x00" * 32, root_hash_b=b"\x00" * 32,
         data_blocks_a=0, data_blocks_b=0):
    assert active_slot in (0, 1)
    body = struct.pack("<4sIIIII32s32sQQ", MAGIC, VERSION, active_slot,
                       boot_attempts, boot_count_a, boot_count_b,
                       root_hash_a, root_hash_b,
                       data_blocks_a, data_blocks_b)
    return body + _h(body)


def read(blob):
    if len(blob) < SIZE:
        raise ValueError(f"metadata too small: {len(blob)} < {SIZE}")
    meta = blob[:SIZE]
    magic, version, active, attempts, ca, cb, ra, rb, ba, bb = \
        struct.unpack("<4sIIIII32s32sQQ", meta[:104])
    if magic != MAGIC:
        raise ValueError("not an ox slot-metadata block (bad magic)")
    if version != VERSION:
        raise ValueError(f"metadata version {version} != {VERSION}")
    if meta[104:] != _h(meta[:104]):
        raise ValueError("metadata integrity check failed (tampered?)")
    return {
        "active_slot": active,
        "boot_attempts": attempts,
        "boot_count_a": ca,
        "boot_count_b": cb,
        "root_hash_a": ra,
        "root_hash_b": rb,
        "data_blocks_a": ba,
        "data_blocks_b": bb,
    }


def selftest():
    a = pack(active_slot=0, boot_count_a=3, data_blocks_a=90000)
    m = read(a)
    assert m["active_slot"] == 0 and m["boot_count_a"] == 3
    assert m["root_hash_a"] == b"\x00" * 32
    assert m["data_blocks_a"] == 90000
    # flip one bit anywhere -> integrity check must fail
    bad = bytearray(a)
    bad[40] ^= 0xFF
    try:
        read(bytes(bad))
        sys.exit("SELFTEST FAIL: tampered metadata accepted")
    except ValueError as e:
        assert "integrity" in str(e)
    # a second block with different content must hash differently
    b = pack(active_slot=1, boot_count_b=1)
    assert a != b
    print("OX_SLOTMETA SELFTEST OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    if "--write" in sys.argv:
        ap = argparse.ArgumentParser()
        ap.add_argument("--device", required=True)
        ap.add_argument("--active", type=int, choices=[0, 1], required=True)
        ap.add_argument("--root-a", required=True, help="hex root hash slot a")
        ap.add_argument("--root-b", required=True, help="hex root hash slot b")
        ap.add_argument("--blocks-a", type=int, default=0,
                        help="dm-verity data blocks of slot a")
        ap.add_argument("--blocks-b", type=int, default=0,
                        help="dm-verity data blocks of slot b")
        ap.add_argument("--attempts", type=int, default=0,
                        help="pre-set the unconfirmed-boot counter "
                             "(rollback testing)")
        ap.add_argument("--count-a", type=int, default=0,
                        help="preserve boot_count_a across a rewrite "
                             "(a full write that drops it reads as a "
                             "slot that never booted)")
        ap.add_argument("--count-b", type=int, default=0,
                        help="preserve boot_count_b across a rewrite")
        ap.add_argument("--offset-bytes", type=int, default=0,
                        help="byte offset on --device (whole-disk writes "
                             "target the metadata partition region)")
        # parse_known_args: sys.argv still carries the --write selector
        args, _ = ap.parse_known_args()
        blob = pack(active_slot=args.active,
                    boot_attempts=args.attempts,
                    boot_count_a=args.count_a,
                    boot_count_b=args.count_b,
                    root_hash_a=bytes.fromhex(args.root_a),
                    root_hash_b=bytes.fromhex(args.root_b),
                    data_blocks_a=args.blocks_a,
                    data_blocks_b=args.blocks_b)
        # write into the FIRST 4KiB at --offset-bytes (default 0), leaving
        # the rest of the partition untouched
        with open(args.device, "r+b") as f:
            base = args.offset_bytes
            f.seek(base)
            old = f.read(4096)
            f.seek(base)
            f.write(blob + old[len(blob):4096 - len(blob) if len(blob) < 4096 else 0])
            f.flush()
            os.fsync(f.fileno())
        print(f"metadata written to {args.device} (active={args.active})")
        return
    if len(sys.argv) < 3:
        sys.exit("usage: ox-slotmeta.py read <file> | --write ... | --selftest")
    if sys.argv[1] == "read":
        meta = read(open(sys.argv[2], "rb").read(4096))
        for k, v in meta.items():
            if isinstance(v, bytes):
                print(f"{k}={v.hex()}")
            else:
                print(f"{k}={v}")


if __name__ == "__main__":
    main()
