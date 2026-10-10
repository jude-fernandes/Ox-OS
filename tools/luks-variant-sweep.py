#!/usr/bin/env python3
"""Sweep AF/XTS parameter variants against a cryptsetup-formatted test
container to find the combination the native unlocker must implement."""
import hashlib, json, struct, base64, subprocess, sys, itertools, re
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

IMG, KEY = "/tmp/ox-lukstest.img", "/tmp/ox-lukstest.key"
secret = open(KEY, "rb").read()

out = subprocess.run(["cryptsetup", "luksDump", "--dump-volume-key",
                      "--key-file", KEY, IMG], capture_output=True, text=True)
lines = out.stdout.splitlines()
vk = None
for idx, line in enumerate(lines):
    if "MK dump" in line or "Volume key" in line:
        parts = re.findall(r"[0-9a-f]{2}", line.split(":", 1)[-1])
        for cont in lines[idx + 1:]:
            t = re.findall(r"[0-9a-f]{2}", cont)
            if not t:
                break
            parts += t
        vk = bytes.fromhex("".join(parts))
        break

raw = open(IMG, "rb").read()
js = json.loads(raw[4096:4096 + 32768].split(b"\0", 1)[0].decode())
slot = js["keyslots"]["0"]
salt = base64.b64decode(slot["kdf"]["salt"])
iters = int(slot["kdf"]["iterations"])
area = slot["area"]
a_off, a_size = int(area["offset"]), int(area["size"])
a_keysize = int(area["key_size"])
key_size, stripes = int(slot["key_size"]), int(slot["af"]["stripes"])
dk = hashlib.pbkdf2_hmac("sha256", secret, salt, iters, a_keysize)

def xts_mul(tw):
    t = bytearray(tw)
    carry = 0
    for i in range(16):
        nc = (t[i] >> 7) & 1
        t[i] = ((t[i] << 1) | carry) & 0xFF
        carry = nc
    if carry:
        t[0] ^= 0x87
    return bytes(t)

def xts_area(ct, dk, base, unit=512, swap=False, be=False):
    data_key, tweak_key = (dk[32:64], dk[:32]) if swap else (dk[:32], dk[32:64])
    dec = Cipher(algorithms.AES(data_key), modes.ECB()).decryptor()
    out = bytearray()
    for s in range(len(ct) // unit):
        e = Cipher(algorithms.AES(tweak_key), modes.ECB()).encryptor()
        tw = bytearray(16)
        if be:
            tw[8:16] = struct.pack(">Q", base + s)
        else:
            tw[0:8] = struct.pack("<Q", base + s)
        tw = bytearray(e.update(bytes(tw)) + e.finalize())
        blk = bytearray(ct[s * unit:(s + 1) * unit])
        seq = [bytes(tw)]
        for _ in range(unit // 16 - 1):
            tw = xts_mul(tw)
            seq.append(bytes(tw))
        for j, off in enumerate(range(0, unit, 16)):
            for i in range(16):
                blk[off + i] ^= seq[j][i]
        pt = bytearray(dec.update(bytes(blk)) + dec.finalize())
        dec = Cipher(algorithms.AES(data_key), modes.ECB()).decryptor()
        for j, off in enumerate(range(0, unit, 16)):
            for i in range(16):
                pt[off + i] ^= seq[j][i]
        out += pt
    return bytes(out)

def merge(src, blocksize, blocknumbers, chunk, iv_global=False):
    def diffuse(buf, iv0):
        size = len(buf)
        tmp = bytearray(buf)
        blocks, padding = divmod(size, chunk)
        for i in range(blocks):
            iv = (iv0 + i) if iv_global else i
            d = hashlib.sha256(struct.pack(">I", iv) + bytes(tmp[i * chunk:(i + 1) * chunk])).digest()
            buf[i * chunk:(i + 1) * chunk] = d[:chunk]
        if padding:
            d = hashlib.sha256(struct.pack(">I", blocks) + bytes(tmp[blocks * chunk:])).digest()
            buf[blocks * chunk:] = d[:padding]
    bufblock = bytearray(blocksize)
    i = blocknumbers - 1  # C leaves the loop counter at blocknumbers-1 on exit
    for i in range(blocknumbers - 1):
        for j in range(blocksize):
            bufblock[j] ^= src[blocksize * i + j]
        diffuse(bufblock, i * (blocksize // chunk) if iv_global else 0)
    i = blocknumbers - 1
    dst = bytearray(blocksize)
    for j in range(blocksize):
        dst[j] = src[blocksize * i + j] ^ bufblock[j]
    return bytes(dst)

# digest formula sanity check with the true volume key
dig = js["digests"]["0"]
dsalt = base64.b64decode(dig["salt"])
dit = int(dig["iterations"])
want = base64.b64decode(dig["digest"])
print(f"digest: type={dig.get('type')} hash={dig.get('hash')} iters={dit}")
got = hashlib.pbkdf2_hmac(dig.get("hash", "sha256"), vk, dsalt, dit, len(want))
print("digest-of-vk:", "MATCH" if got == want else "MISMATCH")

area_ct = raw[a_off:a_off + a_size]
print("area json:", json.dumps(area))
found = []
for unit in (512, 4096):
    for swap in (False, True):
        for be in (False, True):
            pt = xts_area(area_ct, dk, 0, unit, swap, be)
            m = merge(pt, key_size, stripes, 32, False)
            tag = f"unit={unit} swap={swap} be={be}"
            if m == vk:
                found.append(tag)
            print(("MATCH " if m == vk else "no    ") + tag)
if not found:
    print("NO VARIANT MATCHED")
