#!/usr/bin/env python3
import sys
from cryptography.hazmat.primitives import serialization

key = "/tmp/ox-attack/keys/dev-release.pem"
mf = "/tmp/ox-attack/payload/manifest.bin"
sig = mf.replace(".bin", ".sig")

priv = serialization.load_pem_private_key(open(key, "rb").read(), None)
msg = open(mf, "rb").read()
signature = open(sig, "rb").read()
print("msg", len(msg), "sig", len(sig))
try:
    priv.public_key().verify(signature, msg)
    print("openssl verify VALID")
except Exception as exc:
    print("openssl verify INVALID:", exc)

embedded = open("/tmp/ox-attack/payload/initramfs.dir/ox-release.pub", "rb").read()
pub_raw = priv.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print("embed==signing-pub:", embedded == pub_raw)
