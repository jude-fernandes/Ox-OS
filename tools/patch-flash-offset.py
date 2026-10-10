#!/usr/bin/env python3
"""one-shot: add --offset-bytes to the ox-flash metadata write"""
p = "targets/pinephone-pro/ox-flash.sh"
s = open(p, encoding="utf-8").read()
old = '    python3 "$SELF/../../tools/ox-slotmeta.py" --write \\\n        --device "$DEV" \\'
new = ('    python3 "$SELF/../../tools/ox-slotmeta.py" --write \\\n'
       '        --device "$DEV" \\\n'
       '        --offset-bytes "$((META_START * 1024 * 1024))" \\')
assert old in s, "pattern not found"
s = s.replace(old, new)
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("patched:", "--offset-bytes" in open(p).read())
