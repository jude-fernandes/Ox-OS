#!/usr/bin/env python3
"""ox-provision.py — the owner-key enrollment step (BRINGUP M1 step 1
for the Fairphone 5, M2 shape for both targets).

Takes the OWNER's AVB private key (generated once, kept by the owner),
extracts the public key with the vendored reference avbtool, computes
the pkmd (sha256 over the extracted key — the value enrolled at
bootloader re-lock), verifies it is NOT the dev key's, and writes a
provisioning log recording: pkmd, rollback index baseline, and the
artifact hashes of the image set being provisioned.

  usage: ox-provision.py --owner-key KEY.pem --image-dir DIR --out DIR

Exit 0 with the log written; non-zero on any mismatch.
"""
import argparse
import hashlib
import subprocess
import sys
import os

AVB = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "aosp", "avbtool.py")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--owner-key", required=True,
                    help="the owner's AVB private key (PEM, RSA4096)")
    ap.add_argument("--image-dir", required=True,
                    help="built image artifacts (with avb-pkmd.bin)")
    ap.add_argument("--out", required=True,
                    help="directory for the provisioning log")
    args = ap.parse_args()

    pub = os.path.join(args.out, "owner-avb.pub")
    os.makedirs(args.out, exist_ok=True)
    r = subprocess.run([sys.executable, AVB, "extract_public_key",
                        "--key", args.owner_key, "--output", pub],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"extract_public_key failed: {r.stderr.strip()}")

    pkmd = hashlib.sha256(open(pub, "rb").read()).hexdigest()
    dev_pkmd_path = os.path.join(args.image_dir, "avb-pkmd.bin")
    dev_pkmd = open(dev_pkmd_path).read().strip()
    if pkmd == dev_pkmd:
        sys.exit("REFUSING: the owner key IS the dev key — enrollment "
                 "would re-lock the device to the development identity")

    vbmeta = os.path.join(args.image_dir, "vbmeta.img")
    with open(vbmeta, "rb") as f:
        f.seek(112)  # AvbVBMetaImageHeader.rollback_index
        rollback = int.from_bytes(f.read(8), "little")

    log = os.path.join(args.out, "provisioning-log.txt")
    lines = [
        "# Ox OS provisioning log (owner enrollment)",
        f"owner_pkmd_sha256={pkmd}",
        "algorithm=SHA256_RSA4096",
        f"vbmeta_rollback_index={rollback}",
        f"dev_pkmd_sha256={dev_pkmd}",
        "# artifact hashes:",
    ]
    art = os.path.join(args.image_dir, "artifacts.sha256")
    if os.path.exists(art):
        for line in open(art):
            line = line.rstrip("\n")
            if line:
                name = line.split(maxsplit=1)[1].lstrip("*")
                lines.append(f"artifact[{os.path.basename(name)}]={line.split()[0]}")
    with open(log, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"provisioning log: {log}")
    print(f"enroll at re-lock: {pkmd}")
    print("OX_PROVISION_OK")


if __name__ == "__main__":
    main()
