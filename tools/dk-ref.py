#!/usr/bin/env python3
"""Compute the LUKS2 keyslot derived key independently (reference)."""
import base64, hashlib, json, struct, sys

img = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ox-luks-test/data.img"
pw = open(img + ".key", "rb").read()

hdr = open(img, "rb").read(16384)
assert hdr[:6] == b"LUKS\xba\xbe"
js = hdr[4096:].split(b"\0")[0].decode()
meta = json.loads(js)

slot = meta["keyslots"]["0"]
salt = base64.b64decode(slot["kdf"]["salt"])
iters = int(slot["kdf"]["iterations"])
area_key_size = int(slot["area"]["key_size"])
dk_ref = hashlib.pbkdf2_hmac("sha256", pw, salt, iters, area_key_size)
print("salt_b64 :", slot["kdf"]["salt"])
print("iters    :", iters)
print("dk_ref   :", dk_ref.hex())
print("area_off :", int(slot["area"]["offset"], 0))
print("area_size:", int(slot["area"]["size"], 0))
