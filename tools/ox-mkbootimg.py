#!/usr/bin/env python3
"""ox-mkbootimg.py - deterministic Android boot-image packager for Ox OS.

Writes Android boot images (header versions 0-4) plus optional vendor_boot
(v3/v4) so an Ox OS payload can be flashed on any bootloader that accepts
custom images via fastboot. Layouts follow AOSP system/tools/mkbootimg
bootimg.h (format is public; this implementation is original).

Design rules:
  * fully deterministic output (no timestamps, stable ordering)
  * --verify re-parses any produced image and recomputes checksums
  * stdlib only
"""
import argparse
import hashlib
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
VENDOR_MAGIC = b"VNDRBOOT"

HDR_V1 = 1648
HDR_V2 = 1660
HDR_V3 = 1580
HDR_V4 = 1584          # adds signature_size
HDR_V3_PAD = 4096      # v3+ pads header/data at a fixed 4096
VEND_HDR_V3 = 2112
VEND_HDR_V4 = 2128
VR_TABLE_ENTRY_V4 = 108   # size(4)+off(4)+type(4)+name(32)+board_id(16u32)
VR_TYPE_NONE, VR_TYPE_PLATFORM, VR_TYPE_RECOVERY, VR_TYPE_DLKM = 0, 1, 2, 3


def pad(out, alignment):
    rem = out.tell() % alignment
    if rem:
        out.write(b"\x00" * (alignment - rem))


def fsize(path_or_none):
    if path_or_none is None:
        return 0
    return len(path_or_none)


def readf(p):
    if p is None:
        return b""
    with open(p, "rb") as f:
        return f.read()


def parse_os_version(s):  # "12.1" / "15"
    parts = s.split(".")
    a, b, c = (int(x) for x in (parts + ["0", "0"])[:3])
    assert a < 128 and b < 128 and c < 128
    return (a << 14) | (b << 7) | c


def parse_patch_level(s):  # "2026-08" or "2026-08-05" -> y<<4|m (day dropped per AOSP)
    y, m = int(s[:4]), int(s[5:7])
    assert 2000 <= y < 2128 and 1 <= m <= 12
    return ((y - 2000) << 4) | m


def build_image(args, out):
    kernel = readf(args.kernel)
    ramdisk = readf(args.ramdisk)
    second = readf(args.second)
    dtbo = readf(args.recovery_dtbo)
    dtb = readf(args.dtb)
    hv = args.header_version

    cmdline = args.cmdline.encode()
    if len(cmdline) >= 512 + 1024:
        sys.exit("cmdline too long")
    if hv <= 2:
        c1, c2 = cmdline[:511], b"\x00" + cmdline[511:]
        extra = c2.ljust(1024, b"\x00")
        main = c1 + b"\x00"
    else:
        main = cmdline

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second) + ((dtbo,) if hv > 0 else ()) + \
                ((dtb,) if hv > 1 else ()):
        if blob or True:
            sha.update(blob)
            sha.update(struct.pack("<I", len(blob)))
    img_id = sha.digest()

    def w(fmt, *vals):
        out.write(struct.pack(fmt, *vals))

    if hv >= 3:
        hdr_size = HDR_V4 if hv == 4 else HDR_V3
        w("<8sIIII", BOOT_MAGIC, len(kernel), len(ramdisk),
          (args.os_version << 11) | args.os_patch_level, hdr_size)
        w("<4I", 0, 0, 0, 0)                      # reserved
        w("<I", hv)
        w("<%ds" % (512 + 1024), main.ljust(512 + 1024, b"\x00"))
        if hv == 4:
            w("<I", 0)                            # signature_size (no GKI sig)
        pad(out, HDR_V3_PAD)
        for blob in (kernel, ramdisk):
            out.write(blob)
            pad(out, HDR_V3_PAD)
        return img_id

    ramdisk_addr = args.base + args.ramdisk_offset if ramdisk else 0
    second_addr = args.base + args.second_offset if second else 0

    w("<8s", BOOT_MAGIC)
    w("<III", len(kernel), args.base + args.kernel_offset, len(ramdisk))
    w("<II", ramdisk_addr, len(second))
    w("<II", second_addr, args.base + args.tags_offset)
    w("<III", args.pagesize, hv,
      (args.os_version << 11) | args.os_patch_level)
    w("<16s", args.board.encode().ljust(16, b"\x00"))
    w("<512s", main.ljust(512, b"\x00"))
    w("<32s", img_id)
    w("<1024s", extra.ljust(1024, b"\x00"))

    if hv > 0:
        if dtbo:
            n_k = (len(kernel) + args.pagesize - 1) // args.pagesize
            n_r = (len(ramdisk) + args.pagesize - 1) // args.pagesize
            n_s = (len(second) + args.pagesize - 1) // args.pagesize
            off = args.pagesize * (1 + n_k + n_r + n_s)
            w("<IQ", len(dtbo), off)
        else:
            w("<IQ", 0, 0)
        w("<I", HDR_V1 if hv == 1 else HDR_V2)

    if hv > 1:
        if not dtb:
            sys.exit("header v2 requires a DTB")
        w("<I", len(dtb))
        w("<Q", args.base + args.dtb_offset)

    pad(out, args.pagesize)
    for blob in (kernel, ramdisk, second):
        out.write(blob)
        pad(out, args.pagesize)
    if 0 < hv < 3 and dtbo:
        out.write(dtbo)
        pad(out, args.pagesize)
    if hv == 2:
        out.write(dtb)
        pad(out, args.pagesize)
    return img_id


def write_vendor_boot(args):
    """vendor_ramdisk kept empty by default; all initramfs lives in boot.img."""
    with open(args.vendor_boot, "wb") as vb:
        vr = readf(args.vendor_ramdisk)
        dtb = readf(args.dtb) if args.header_version > 3 else b""
        hdr = VEND_HDR_V4 if args.header_version == 4 else VEND_HDR_V3
        vb.write(struct.pack("<8sIIIII", VENDOR_MAGIC, args.header_version,
                             args.pagesize, args.base + args.kernel_offset,
                             args.base + args.ramdisk_offset, len(vr)))
        vcmd = args.vendor_cmdline.encode()[:2048]
        vb.write(struct.pack("<2048s", vcmd.ljust(2048, b"\x00")))
        vb.write(struct.pack("<I", args.base + args.tags_offset))
        vb.write(struct.pack("<16s",
                             args.board.encode().ljust(16, b"\x00")))
        vb.write(struct.pack("<I", hdr))
        vb.write(struct.pack("<I", len(dtb)))
        vb.write(struct.pack("<Q", args.base + args.dtb_offset))
        if args.header_version == 4:
            entries = [(len(vr), 0, VR_TYPE_PLATFORM)] if vr else []
            vb.write(struct.pack("<III", len(entries) * VR_TABLE_ENTRY_V4,
                                 len(entries), VR_TABLE_ENTRY_V4))
            vb.write(struct.pack("<I", 0))        # bootconfig section size
        pad(vb, args.pagesize)
        if args.header_version > 3:
            vb.write(vr)
            pad(vb, args.pagesize)
            vb.write(dtb)
            pad(vb, args.pagesize)
            for sz, off, typ in entries:
                vb.write(struct.pack("<III", sz, off, typ))
                vb.write(b"ox-default".ljust(32, b"\x00"))
                vb.write(struct.pack("<16I", *([0] * 16)))
            pad(vb, args.pagesize)
        else:
            vb.write(vr)
            pad(vb, args.pagesize)
            vb.write(dtb)
            pad(vb, args.pagesize)


# ---------------------------------------------------------------- verify ---
def verify(path):
    with open(path, "rb") as f:
        blob = f.read()
    problems = []
    if blob[:8] not in (BOOT_MAGIC, VENDOR_MAGIC):
        sys.exit("not a boot/vendor_boot image")
    hv = struct.unpack_from("<I", blob, 40)[0]
    if blob[:8] == VENDOR_MAGIC:
        hv = struct.unpack_from("<I", blob, 8)[0]
        base = 24  # vendor_ramdisk_size lives here
        page = struct.unpack_from("<I", blob, 12)[0]
        vr_size = struct.unpack_from("<I", blob, base)[0]
        # magic(8)+ver(4)+page(4)+3 addr(12)+vr_size(4)=28; +cmdline(2048)
        # +tags(4)+name(16) -> header_size at 2096
        hdr = struct.unpack_from("<I", blob, 2096)[0]
        exp_hdr = VEND_HDR_V4 if hv == 4 else VEND_HDR_V3
        if hdr != exp_hdr:
            problems.append(f"vendor header_size {hdr}!={exp_hdr}")
        print(f"vendor_boot v{hv} page={page} vendor_ramdisk={vr_size}")
    else:
        # v0-v2 layout: ramdisk_size at 16 (12 is kernel_addr). The
        # chunk-73 offset fix was for the v3+ layout only — applying it
        # here made v2 verification read kernel_addr and fail every
        # SHA1 (the chunk-75 9RT finding).
        ksz = struct.unpack_from("<I", blob, 8)[0]
        rsz = struct.unpack_from("<I", blob, 16)[0]
        page = struct.unpack_from("<I", blob, 36)[0]
        stored_hv = hv
        if stored_hv >= 3:
            hdr_size = struct.unpack_from("<I", blob, 20)[0]
            exp = HDR_V4 if stored_hv == 4 else HDR_V3
            if hdr_size != exp:
                problems.append(f"header_size {hdr_size}!={exp}")
            pg = HDR_V3_PAD
            off = pg
            kern = blob[off:off + ksz]
            off += (ksz + pg - 1) // pg * pg
            rd = blob[off:off + rsz]
            print(f"boot v{stored_hv} page={pg} kernel={ksz} "
                  f"ramdisk={rsz} cmdline={blob[44:44+1536].rstrip(bytes(1)).decode(errors='replace')[:80]}")
        else:
            ssz = struct.unpack_from("<I", blob, 24)[0]
            dtbsz = struct.unpack_from("<I", blob, 1648)[0] if stored_hv > 1 else 0
            sha = hashlib.sha1()

            def feed(b):
                sha.update(b)
                sha.update(struct.pack("<I", len(b)))

            pg = page
            off = pg
            kern = blob[off:off + ksz]
            feed(kern)
            off += (ksz + pg - 1) // pg * pg
            rd = blob[off:off + rsz]
            feed(rd)
            off += (rsz + pg - 1) // pg * pg
            sec = blob[off:off + ssz]
            feed(sec)
            off += (ssz + pg - 1) // pg * pg
            if 0 < stored_hv < 3:
                dsz = struct.unpack_from("<I", blob, 1632)[0]
                d = blob[off:off + dsz]
                feed(d)
                off += (dsz + pg - 1) // pg * pg
            if stored_hv == 2:
                d = blob[off:off + dtbsz]
                feed(d)
                off += (dtbsz + pg - 1) // pg * pg
            want = blob[576:596]
            got = sha.digest()
            if want != got:
                problems.append(f"SHA1 mismatch stored={want.hex()} "
                                f"computed={got.hex()}")
            # NOTE: no trailing-garbage check — post-AVB images carry the
            # hash footer + padding after the payload sections (legal;
            # the footer's signature covers them, verified by avbtool).
            cmd = blob[64:64 + 511].split(b"\x00")[0].decode(errors="replace")
            print(f"boot v{stored_hv} page={pg} kernel={ksz} ramdisk={rsz} "
                  f"second={ssz} dtb={dtbsz}")
            print(f"cmdline={cmd[:100]}")
    if problems:
        for p in problems:
            print("VERIFY FAIL:", p, file=sys.stderr)
        sys.exit(1)
    print("verify OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", default=None)
    ap.add_argument("--ramdisk")
    ap.add_argument("--second")
    ap.add_argument("--dtb")
    ap.add_argument("--recovery-dtbo", dest="recovery_dtbo")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--vendor-cmdline", dest="vendor_cmdline", default="")
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x10000000)
    ap.add_argument("--kernel-offset", type=lambda x: int(x, 0),
                    default=0x00080000)
    ap.add_argument("--ramdisk-offset", type=lambda x: int(x, 0),
                    default=0x01000000)
    ap.add_argument("--second-offset", type=lambda x: int(x, 0),
                    default=0x00F00000)
    ap.add_argument("--tags-offset", type=lambda x: int(x, 0),
                    default=0x00000100)
    ap.add_argument("--dtb-offset", type=lambda x: int(x, 0),
                    default=0x01F00000)
    ap.add_argument("--pagesize", type=int,
                    choices=[2 ** i for i in range(11, 15)], default=4096)
    ap.add_argument("--board", default="")
    ap.add_argument("--os-version", type=parse_os_version, default=None,
                    help='e.g. "15"')
    ap.add_argument("--os-patch-level", type=parse_patch_level,
                    default=None, help='e.g. "2026-08"')
    ap.add_argument("--header-version", type=int, default=2)
    ap.add_argument("--id", action="store_true",
                    help="print image id on stdout")
    ap.add_argument("--vendor-boot")
    ap.add_argument("--vendor-ramdisk")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--verify", action="store_true",
                    help="verify OUTPUT instead of building")
    args = ap.parse_args()
    if not args.verify and not args.kernel:
        ap.error("--kernel is required (unless --verify)")
    if args.verify:
        verify(args.output)
        return
    if args.os_version is None:
        args.os_version = 0
    if args.os_patch_level is None:
        args.os_patch_level = 0
    if args.header_version > 2:
        if args.second or args.recovery_dtbo:
            sys.exit("--second/--recovery-dtbo invalid for header v3+")
    if args.os_version >> 25:
        sys.exit("os_version overflow")
    with open(args.output, "wb") as out:
        img_id = build_image(args, out)
    if args.vendor_boot:
        write_vendor_boot(args)
    if args.id:
        print("0x" + img_id.hex())
    print(f"wrote {args.output} (header v{args.header_version}, "
          f"pagesize {args.pagesize})")


if __name__ == "__main__":
    main()
