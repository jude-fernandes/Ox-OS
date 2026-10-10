#!/usr/bin/env python3
"""Chunk-73 AVB smoketest: sign -> verify -> tamper -> verify-must-fail."""
import subprocess
import sys

AVB = "/tmp/avb-src/avbtool.py"
KEY = "/tmp/avbtest.pem"
PUB = "/tmp/avbtest.pub"
# verify_image resolves hash descriptors as <dir>/<partition_name><ext>:
# the file MUST be named boot.img for partition_name=boot (the same
# signed file is re-loaded for the descriptor check)
IMG = "/tmp/boot.img"

# self-contained: the keypair MUST come from the same avbtool generation
# (the vendored android-14 tool cannot read pubkeys written by the
# ML-DSA-era HEAD and vice versa)
subprocess.run(["openssl", "genrsa", "-out", KEY, "4096"],
               check=True, capture_output=True)
subprocess.run([sys.executable, AVB, "extract_public_key",
                "--key", KEY, "--output", PUB],
               check=True, capture_output=True)

with open(IMG, "wb") as f:
    f.write(b"ox-avb-smoketest-payload\n" * 32)

subprocess.run([sys.executable, AVB, "add_hash_footer",
                "--image", IMG, "--partition_name", "boot",
                "--partition_size", "73728",
                "--key", KEY, "--algorithm", "SHA256_RSA4096"],
               check=True, capture_output=True)

r = subprocess.run([sys.executable, AVB, "verify_image",
                    "--image", IMG, "--key", KEY],
                   capture_output=True, text=True)
print("clean verify rc:", r.returncode)

with open(IMG, "r+b") as f:
    f.seek(100)
    b = f.read(1)
    f.seek(100)
    f.write(bytes([b[0] ^ 0xFF]))

r = subprocess.run([sys.executable, AVB, "verify_image",
                    "--image", IMG, "--key", KEY],
                   capture_output=True, text=True)
print("tampered verify rc:", r.returncode)
tail = (r.stdout + r.stderr).strip().splitlines()
print("tampered last line:", tail[-1][:100] if tail else "(none)")
if r.returncode == 0:
    sys.exit("TAMPER NOT DETECTED - avbtool unusable")
print("AVB_SMOKE_OK")
