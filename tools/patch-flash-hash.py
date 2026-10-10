#!/usr/bin/env python3
"""one-shot: add the verity hash write to ox-flash slot-a provisioning"""
p = "targets/pinephone-pro/ox-flash.sh"
s = open(p, encoding="utf-8").read()
old = ('# 4. slot contents (slot _a only; _b is the updater\'s, M2)\n'
       'dd if="$IMG/ox.itb" of="$DEV" bs=1M seek="$BOOT_START" conv=notrunc status=none\n'
       'dd if="$IMG/system.img" of="$DEV" bs=1M seek="$SYSA_START" conv=notrunc status=none')
new = ('# 4. slot contents (slot _a only; _b is the updater\'s, M2): system at\n'
       '    # the partition start, the verity hash tree at the in-slot offset\n'
       '    # (the C reader\'s OX_SLOT_HASH_OFF_B — same convention as ox-update)\n'
       'dd if="$IMG/ox.itb" of="$DEV" bs=1M seek="$BOOT_START" conv=notrunc status=none\n'
       'dd if="$IMG/system.img" of="$DEV" bs=1M seek="$SYSA_START" conv=notrunc status=none\n'
       'dd if="$IMG/system.hash.img" of="$DEV" bs=1M seek="$((SYSA_START + 2944))" conv=notrunc status=none')
assert old in s, "pattern not found"
s = s.replace(old, new)
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("patched:", "system.hash.img" in open(p).read())
