#!/usr/bin/env python3
"""Ground-truth check: does openssl accept the manifest signature, and does
the extracted raw public key match the PEM's public key?"""
import subprocess, sys
from cryptography.hazmat.primitives import serialization

key_path = sys.argv[1] if len(sys.argv) > 1 else \
    "/tmp/ox-boot/keys/dev-release.pem"
mf = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ox-attack/payload/manifest.bin"
sig = mf + ".sig"

priv = serialization.load_pem_private_key(open(key_path, "rb").read(), None)
pub_raw = priv.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print("python pub:", pub_raw.hex())

embedded = open("/tmp/ox-attack/payload/initramfs.dir/ox-release.pub", "rb").read()
print("embed  pub:", embedded.hex())
print("pub match:", pub_raw == embedded)

msg = open(mf, "rb").read()
signature = open(sig, "rb").read()
print("msg_len:", len(msg), "sig_len:", len(signature))
try:
    priv.public_key().verify(signature, msg)
    print("openssl verify: VALID")
except Exception:
    print("openssl verify: INVALID")
