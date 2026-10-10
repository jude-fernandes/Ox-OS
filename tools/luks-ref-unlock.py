#!/usr/bin/env python3
"""Full reference LUKS2 unlock in Python: establishes ground truth for
the keyslot area decryption + AF merge, independent of ox-init.c."""
import base64, hashlib, hmac as hmac_mod, json, struct, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

img = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ox-luks-test/data.img"
pw = open(img + ".key", "rb").read()

hdr = open(img, "rb").read(16384)
meta = json.loads(hdr[4096:].split(b"\0")[0].decode())
slot = meta["keyslots"]["0"]

salt = base64.b64decode(slot["kdf"]["salt"])
iters = int(slot["kdf"]["iterations"])
a_off = int(slot["area"]["offset"], 0)
a_size = int(slot["area"]["size"], 0)
a_ks = int(slot["area"]["key_size"])
stripes = int(slot["af"]["stripes"])
enc = slot["area"]["encryption"]
print("area:", enc, a_off, a_size, a_ks, stripes)

dk = hashlib.pbkdf2_hmac("sha256", pw, salt, iters, a_ks)

raw = open(img, "rb")
raw.seek(a_off)
ct = raw.read(a_size)

def xts_xt(block_key, tweak_key, data, first_sector):
    out = bytearray()
    for s in range(len(data) // 512):
        tw_enc = Cipher(algorithms.AES(tweak_key), modes.ECB()).encryptor()
        T = bytearray((first_sector + s).to_bytes(16, "little"))
        T = bytearray(tw_enc.update(bytes(T)) + tw_enc.finalize())
        dec = Cipher(algorithms.AES(block_key), modes.ECB()).decryptor()
        for off in range(0, 512, 16):
            blk = bytes(a ^ b for a, b in zip(data[s*512+off:s*512+off+16], T))
            blk = dec.update(blk)
            out += bytes(a ^ b for a, b in zip(blk, T))
            carry = 0
            for i in range(16):
                nc = (T[i] >> 7) & 1
                T[i] = ((T[i] << 1) & 0xFF) | carry
                carry = nc
            if carry:
                T[0] ^= 0x87
    return bytes(out)

def diffuse(buf):
    out = bytearray()
    blocks = len(buf) // 32
    padding = len(buf) % 32
    for i in range(blocks):
        h = hashlib.sha256(struct.pack(">I", i) + buf[i*32:(i+1)*32]).digest()
        out += h
    if padding:
        h = hashlib.sha256(struct.pack(">I", blocks) +
                           buf[blocks*32:len(buf)]).digest()
        out += h[:padding]
    return bytes(out)

def af_merge(src, blocksize, blocknumbers):
    bufblock = bytes(blocksize)
    for i in range(blocknumbers - 1):
        bufblock = bytes(a ^ b for a, b in zip(src[i*blocksize:(i+1)*blocksize],
                                               bufblock))
        bufblock = diffuse(bufblock)
    tail = src[(blocknumbers-1)*blocksize:blocknumbers*blocksize]
    return bytes(a ^ b for a, b in zip(tail, bufblock))

ref_vk_file = open("/tmp/mkdump.txt", "rb").read().strip() if False else None

for label, bk, tk in [("data=first", dk[:32], dk[32:]),
                      ("data=second", dk[32:], dk[:32])]:
    pt_area = xts_xt(bk, tk, ct, 0)
    vk = af_merge(pt_area[:4000*64], 64, 4000)
    print(label, "vk:", vk.hex())

# ground truth from cryptsetup
import subprocess
mk = subprocess.run(["cryptsetup", "luksDump", "--dump-volume-key",
                     "--key-file", img + ".key", img],
                    capture_output=True, text=True).stdout
hexstr = "".join(mk.split()).split("MKdump:")[1][:128]
print("REF      :", hexstr)
