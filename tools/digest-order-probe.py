#!/usr/bin/env python3
"""chunk-77 dig round 3: does the veritysetup-format hash tree use the
SUPERBLOCK variant? A superblock variant writes 4KiB of zeros/superblock
FIRST, then the tree — matching the observed 206-block file where the
tree head is NOT the level-0 head. Parse: tree starts after 4096 bytes;
also verify the root recomputed bottom-up matches OX_ROOT_HASH."""
import hashlib

imgdir = "/nix/store/5zpnjsmi6v8nzv7dqswa86mar3xfvlw4-image-pinephone-pro-0.1.0-chunk72"
sysimg = open(imgdir + "/system.img", "rb").read()
tree = open(imgdir + "/system.hash.img", "rb").read()
salt = bytes.fromhex("10b14701c6d25daf5706c7cd630226514cc904bd0780cb2a8b9d7368a4425efb")
root = bytes.fromhex("92c438f22d40df5ff2d813b780bc9caad0ea98df74db481e3daa4a2b38a615d2")

def h(b):
    return hashlib.sha256(b).digest()

nblocks = (len(sysimg) + 4095) // 4096
# level 0: salted digests of data blocks, zero-padded to block size
l0 = b""
for i in range(nblocks):
    blk = sysimg[i*4096:(i+1)*4096]
    blk = blk + b"\x00" * (4096 - len(blk))
    l0 += h(salt + blk)
while len(l0) % 4096:
    l0 += b"\x00"
print("level0 blocks:", len(l0) // 4096)

# walk up until one block
level = l0
lvl = 0
while len(level) > 4096:
    nxt = b""
    for i in range(0, len(level), 4096):
        nxt += h(salt + level[i:i+4096])
    while len(nxt) % 4096:
        nxt += b"\x00"
    level = nxt
    lvl += 1
print("root block after", lvl, "levels:",
      level[:32].hex(), "matches OX_ROOT_HASH?", level[:32] == root)

# does the file contain level0 at offset 4096 (superblock variant)?
print("tree[4096:4128] == level0[0:32]?", tree[4096:4128] == l0[:32])
print("tree[0:32] == level1-root?", tree[0:32] == level[:32])
print("tree size:", len(tree), "level0 size:", len(l0),
      "level0+1block:", len(l0) + 4096)
