#!/usr/bin/env python3
"""The one-byte fix: the dev key file must have NO trailing newline.
cryptsetup reads keyfile bytes verbatim; ox-init strips \\n — a 25-byte
file gave one side 25 and the other 24 bytes, so the derived area key
differed and every unlock failed the digest check."""

path = "tools/build-payload.sh"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''if [ ! -f "$OUT/data.img.key" ]; then
    printf 'ox-dev-data-passphrase-1\\n' >"$OUT/data.img.key"
    chmod 600 "$OUT/data.img.key"
fi'''
new = '''if [ ! -f "$OUT/data.img.key" ]; then
    # No trailing newline: cryptsetup uses keyfile bytes verbatim while
    # ox-init strips \\n — both must see the identical secret (R-22).
    printf '%s' 'ox-dev-data-passphrase-1' >"$OUT/data.img.key"
    chmod 600 "$OUT/data.img.key"
fi'''
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
