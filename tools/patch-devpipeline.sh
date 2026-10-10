#!/bin/sh
set -eu
p="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/dev-pipeline.sh"
python3 - "$p" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", newline="").read()
old = 'install_guest_bin "${OXPOWER_BIN:-/tmp/ox-rust/powerd}" powerd\n'
new = old + 'install_guest_bin "${OXCTL_BIN:-/tmp/ox-rust/oxctl}" oxctl\n'
if "oxctl" not in s:
    assert old in s, "anchor not found"
    s = s.replace(old, new)
    open(p, "w", encoding="utf-8", newline="").write(s)
    print("dev-pipeline updated")
else:
    print("already present")
PYEOF
sed -i 's/\r$//' "$p"
grep -n oxctl "$p"
