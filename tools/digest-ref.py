#!/usr/bin/env python3
import base64, hashlib, json, sys

img = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ox-luks-test/data.img"
vk = bytes.fromhex(sys.argv[2])

meta = json.loads(open(img, "rb").read(16384)[4096:].split(b"\0")[0].decode())
d = meta["digests"]["0"]
salt = base64.b64decode(d["salt"])
iters = int(d["iterations"])
want = base64.b64decode(d["digest"])
got = hashlib.pbkdf2_hmac("sha256", vk, salt, iters, len(want))
print("iters :", iters)
print("digest:", got.hex())
print("want  :", want.hex())
print("MATCH " if got == want else "MISMATCH")
