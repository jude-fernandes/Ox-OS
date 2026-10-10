#!/usr/bin/env python3
"""Check whether the newest elogind drv pulls clang."""
import json, subprocess, glob, os

NIX = "/nix/var/nix/profiles/per-user/root/profile/bin/nix"
drvs = sorted(glob.glob("/nix/store/*elogind*.drv"), key=os.path.getmtime)
print("elogind drvs:", [d.rsplit("/", 1)[-1] for d in drvs[-2:]])
if not drvs:
    raise SystemExit(0)
out = subprocess.run([NIX, "derivation", "show", "-r", drvs[-1]],
                     capture_output=True, text=True).stdout
data = json.loads(out)["derivations"]
hits = [k.rsplit("/", 1)[-1] for k in data if "clang" in k.rsplit("/", 1)[-1]]
print("graph:", len(data), "clang hits:", hits[:3])
