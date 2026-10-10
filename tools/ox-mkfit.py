#!/usr/bin/env python3
"""ox-mkfit.py - deterministic U-Boot FIT image builder for Ox OS.

Wraps kernel + initramfs + one or more DTBs into a single Flattened Image
Tree (.itb) for U-Boot `bootm`. Uses the system mkimage for FDT encoding;
the generated ITS is fully deterministic (no timestamps, stable node order).

Signing (chunk 72): pass --key-dir to sign every configuration
(sha256,rsa2048, required) with the dev FIT key and inject the public
half into the U-Boot control DTB (--key-dtb). The dev key is committed
under tools/dev-keys; owner-key enrollment in U-Boot proper is the M2
step of BRINGUP (the control DTB shipped here is the keyed artifact
that M1/M2 flash).
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile

ITS_TMPL = """
/dts-v1/;

/ {{
    description = "{desc}";
    #address-cells = <1>;

    images {{
        kernel-1 {{
            description = "Ox OS kernel";
            data = /incbin/("{kernel}");
            type = "kernel";
            arch = "{arch}";
            os = "linux";
            compression = "{kcomp}";
            load = <0x{load:x}>;
            entry = <0x{entry:x}>;
            hash-1 {{ algo = "sha256"; }};
        }};
        ramdisk-1 {{
            description = "Ox OS initramfs";
            data = /incbin/("{ramdisk}");
            type = "ramdisk";
            compression = "{rcomp}";
            hash-1 {{ algo = "sha256"; }};
        }};
{fdts}    }};

    configurations {{
        default = "conf-1";
{confs}    }};
}};
"""

FDT_NODE = """        fdt-{n} {{
            description = "{name}";
            data = /incbin/("{path}");
            type = "flat_dt";
            compression = "none";
            hash-1 {{ algo = "sha256"; }};
        }};
"""

CONF_NODE = """        conf-{n} {{
            description = "Ox OS on {name}";
            kernel = "kernel-1";
            ramdisk = "ramdisk-1";
            fdt = "fdt-{n}";
        }};
"""

# signing: the signature lives on the CONFIGURATION and covers every
# image it references (sign-images), so one verification at bootm time
# covers the whole payload. -r (mkimage) marks it required: U-Boot
# refuses an unsigned/failed verification.
CONF_NODE_SIGNED = """        conf-{n} {{
            description = "Ox OS on {name}";
            kernel = "kernel-1";
            ramdisk = "ramdisk-1";
            fdt = "fdt-{n}";
            signature-1 {{
                algo = "sha256,rsa2048";
                key-name-hint = "{hint}";
                sign-images = "kernel", "ramdisk", "fdt";
            }};
        }};
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb", action="append", required=True,
                    help="DTB file; repeatable")
    ap.add_argument("--description", default="Ox OS payload")
    ap.add_argument("--arch", default="arm64", choices=["arm64", "arm", "riscv"])
    ap.add_argument("--compression", default="gzip", choices=["gzip", "none"],
                    help="kernel+ramdisk compression as fed in")
    ap.add_argument("--load-addr", type=lambda x: int(x, 0),
                    default=0x08080000, help="kernel load address (BRINGUP)")
    ap.add_argument("--entry-addr", type=lambda x: int(x, 0),
                    default=0x08080000)
    ap.add_argument("--key-dir",
                    help="dir with <hint>.key/<hint>.crt; enables signing")
    ap.add_argument("--key-hint", default="fit-dev")
    ap.add_argument("--key-dtb",
                    help="U-Boot control DTB to inject the public key into")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    if not all(os.path.exists(p) for p in
               [args.kernel, args.ramdisk] + args.dtb):
        sys.exit("input file missing")

    confs = "".join(
        (CONF_NODE_SIGNED if args.key_dir else CONF_NODE).format(
            n=i + 1, name=os.path.basename(args.dtb[i]),
            hint=args.key_hint)
        for i in range(len(args.dtb)))
    rcomp = "none"  # initramfs gzip is opaque to U-Boot; keep none

    with tempfile.TemporaryDirectory() as td:
        # /incbin/ paths are relative to the ITS; symlink inputs flat & unique
        def link(src, name):
            dst = os.path.join(td, name)
            os.symlink(os.path.abspath(src), dst)
            return name

        k = link(args.kernel, "kernel.bin")
        r = link(args.ramdisk, "ramdisk.bin")
        ds = [link(p, "dtb%d.bin" % i) for i, p in enumerate(args.dtb)]
        its2 = ITS_TMPL.format(desc=args.description, kernel=k, ramdisk=r,
                               arch=args.arch, kcomp=args.compression,
                               rcomp=rcomp, load=args.load_addr,
                               entry=args.entry_addr,
                               fdts="".join(FDT_NODE.format(n=i + 1,
                                                            name=os.path.basename(args.dtb[i]),
                                                            path=ds[i])
                                            for i in range(len(ds))),
                               confs=confs)
        its_path = os.path.join(td, "ox.its")
        open(its_path, "w").write(its2)
        # mkimage stamps a `timestamp` property into the FIT from wall-clock
        # time — the classic reproducibility break. Pin it: honor an external
        # SOURCE_DATE_EPOCH, otherwise a fixed epoch (reproducible by default).
        env = dict(os.environ)
        env.setdefault("SOURCE_DATE_EPOCH", "0")
        cmd = ["mkimage", "-f", its_path]
        if args.key_dir:
            # -k key dir, -K control DTB (pubkey injection), -r required
            cmd += ["-k", args.key_dir]
            if args.key_dtb:
                cmd += ["-K", args.key_dtb]
            cmd += ["-r"]
        cmd += [args.output]
        rc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if rc.returncode != 0:
            sys.exit("mkimage failed:\n" + rc.stderr)

    chk = subprocess.run(["dumpimage", "-l", args.output],
                         capture_output=True, text=True)
    print(chk.stdout.strip())
    print(f"wrote {args.output}" +
          (" (signed, required)" if args.key_dir else " (unsigned)"))
    for p in [args.kernel, args.ramdisk] + args.dtb:
        print(f"  sha256 {sha256(p)[:16]}…  {p}")


if __name__ == "__main__":
    main()
