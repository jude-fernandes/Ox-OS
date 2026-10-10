#!/usr/bin/env python3
"""Format the data volume with 512-byte data sectors: cryptsetup auto-picks
4096 for file-backed images, and that non-default dm-crypt path crashes
crypt_ctr in the guest (R-23)."""

path = "tools/build-payload.sh"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \\
        --pbkdf-force-iterations 10000 --batch-mode \\
        --key-file "$OUT/data.img.key" "$OUT/data.img"'''
new = '''    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \\
        --pbkdf-force-iterations 10000 --batch-mode --sector-size 512 \\
        --key-file "$OUT/data.img.key" "$OUT/data.img"'''
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
