#!/usr/bin/env python3
"""Generate an XTS-AES-256 reference vector for the ox-init harness.

Prints C source lines defining key, tweak-unit, plaintext, ciphertext so the
C test can compare byte-for-byte against xts_decrypt().
"""
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

key = bytes(range(64))          # data = key[0:32], tweak = key[32:64] per Linux
unit = 0x1122334455667788
plain = bytes((i * 7 + 3) & 0xFF for i in range(512))

tweak_cipher = Cipher(algorithms.AES(key[32:]), modes.ECB())
data_cipher = Cipher(algorithms.AES(key[:32]), modes.ECB())

tw = bytearray(unit.to_bytes(16, "little"))
enc = tweak_cipher.encryptor()
tw = bytearray(enc.update(bytes(tw)) + enc.finalize())
print("tweak:", tw.hex())

out = bytearray()
for off in range(0, len(plain), 16):
    t = tw[:]
    blk = bytes(a ^ b for a, b in zip(plain[off:off+16], t))
    d = data_cipher.decryptor()
    blk = d.update(blk) + d.finalize()
    out += bytes(a ^ b for a, b in zip(blk, t))
    # multiply tw by x in GF(2^128) LE
    carry = 0
    for i in range(16):
        nc = (tw[i] >> 7) & 1
        tw[i] = ((tw[i] << 1) & 0xFF) | carry
        carry = nc
    if carry:
        tw[0] ^= 0x87

print("plain:", plain.hex())
print("cipher:", out.hex())
