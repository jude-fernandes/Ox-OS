#!/usr/bin/env python3
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

key = bytes(range(64))
unit = 0x1122334455667788
c0 = bytes.fromhex("67a10aa7562de089f6e44d47f1aef68a")

tw_enc = Cipher(algorithms.AES(key[32:]), modes.ECB()).encryptor()
T = bytearray(unit.to_bytes(16, "little"))
T = bytearray(tw_enc.update(bytes(T)) + tw_enc.finalize())
print("T      :", T.hex())

x = bytes(a ^ b for a, b in zip(c0, T))
print("C0^T   :", x.hex())

dec = Cipher(algorithms.AES(key[:32]), modes.ECB()).decryptor()
d = bytearray(dec.update(x) + dec.finalize())
print("DEC    :", d.hex())

p0 = bytes(a ^ b for a, b in zip(d, T))
print("P0     :", p0.hex())
