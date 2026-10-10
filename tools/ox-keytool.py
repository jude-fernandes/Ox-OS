#!/usr/bin/env python3
"""Ox OS release keytool: ed25519 sign/verify via openssl CLI (no pip deps)."""
import argparse
import os
import subprocess
import sys
import tempfile


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def die(msg: str) -> None:
    print(f"ox-keytool: ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def cmd_gen(args) -> None:
    if os.path.exists(args.key) and not args.force:
        die(f"{args.key} exists (use --force)")
    r = run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", args.key])
    if r.returncode != 0:
        die(f"keygen failed: {r.stderr.strip()}")
    r = run(["openssl", "pkey", "-in", args.key, "-pubout", "-out", args.pub])
    if r.returncode != 0:
        die(f"pubkey export failed: {r.stderr.strip()}")
    os.chmod(args.key, 0o600)
    print(f"OXKEY gen ok key={args.key} pub={args.pub}")


def cmd_sign(args) -> None:
    if not os.path.exists(args.key):
        die(f"missing key {args.key}")
    if not os.path.exists(args.file):
        die(f"missing input {args.file}")
    r = run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", args.key,
             "-in", args.file, "-out", args.out])
    if r.returncode != 0:
        die(f"sign failed: {r.stderr.strip()}")
    print(f"OXKEY sign ok file={args.file} sig={args.out}")


def cmd_verify(args) -> int:
    for f in (args.file, args.sig, args.pub):
        if not os.path.exists(f):
            die(f"missing {f}")
    r = run(["openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
             "-inkey", args.pub, "-in", args.file, "-sigfile", args.sig])
    ok = r.returncode == 0
    print(f"OXKEY verify {'OK' if ok else 'FAIL'} file={args.file}")
    return 0 if ok else 1


def cmd_pub_raw(args) -> None:
    """Export the raw 32-byte Ed25519 public key (for initramfs embedding)."""
    if not os.path.exists(args.key):
        die(f"missing key {args.key}")
    r = run(["openssl", "pkey", "-in", args.key, "-pubout",
             "-outform", "DER", "-out", args.out + ".der"])
    if r.returncode != 0:
        die(f"pubkey export failed: {r.stderr.strip()}")
    der = open(args.out + ".der", "rb").read()
    os.unlink(args.out + ".der")
    # RFC 8410 SubjectPublicKeyInfo DER: 44 bytes total, raw key = last 32
    if len(der) != 44 or der[0] != 0x30:
        die(f"unexpected DER layout for ed25519 public key ({len(der)} bytes)")
    with open(args.out, "wb") as f:
        f.write(der[-32:])
    print(f"OXKEY pub-raw ok out={args.out}")


def cmd_selftest(_) -> int:
    with tempfile.TemporaryDirectory() as d:
        key, pub = os.path.join(d, "k.pem"), os.path.join(d, "k.pub")
        msg = os.path.join(d, "m.bin")
        sig = msg + ".sig"
        with open(msg, "wb") as f:
            f.write(os.urandom(1024))
        ns = argparse.Namespace(key=key, pub=pub, force=False)
        cmd_gen(ns)
        cmd_sign(argparse.Namespace(key=key, file=msg, out=sig))
        rc = cmd_verify(argparse.Namespace(file=msg, sig=sig, pub=pub))
        tampered = bytearray(open(msg, "rb").read())
        tampered[0] ^= 0xFF
        bad = os.path.join(d, "bad.bin")
        open(bad, "wb").write(bytes(tampered))
        rb = cmd_verify(argparse.Namespace(file=bad, sig=sig, pub=pub))
        if rc != 0 or rb == 0:
            die("selftest failed")
        print("OXKEY selftest OK")
        return 0


def main() -> None:
    p = argparse.ArgumentParser(prog="ox-keytool")
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--key", required=True)
    g.add_argument("--pub", required=True)
    g.add_argument("--force", action="store_true")
    s = sub.add_parser("sign")
    s.add_argument("--key", required=True)
    s.add_argument("--file", required=True)
    s.add_argument("--out", default=None)
    v = sub.add_parser("verify")
    v.add_argument("--pub", required=True)
    v.add_argument("--file", required=True)
    v.add_argument("--sig", required=True)
    sub.add_parser("selftest")
    pr = sub.add_parser("pub-raw")
    pr.add_argument("--key", required=True)
    pr.add_argument("--out", required=True)
    args = p.parse_args()
    if args.cmd == "sign" and args.out is None:
        args.out = args.file + ".sig"
    rc = {"gen": cmd_gen, "sign": cmd_sign, "verify": cmd_verify,
          "selftest": cmd_selftest, "pub-raw": cmd_pub_raw}[args.cmd](args)
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
