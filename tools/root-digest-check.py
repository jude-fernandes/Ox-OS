#!/usr/bin/env python3
"""check how the root hash relates to the root block"""
import hashlib

imgdir = "/nix/store/5zpnjsmi6v8nzv7dqswa86mar3xfvlw4-image-pinephone-pro-0.1.0-chunk72"
tree = open(imgdir + "/system.hash.img", "rb").read()
salt = bytes.fromhex("10b14701c6d25daf5706c7cd630226514cc904bd0780cb2a8b9d7368a4425efb")
root = bytes.fromhex("92c438f22d40df5ff2d813b780bc9caad0ea98df74db481e3daa4a2b38a615d2")
rb = tree[0:4096]
print("sha256(root block) == table digest:",
      hashlib.sha256(rb).hexdigest() == root.hex())
print("sha256(salt+root block) == table digest:",
      hashlib.sha256(salt + rb).hexdigest() == root.hex())
# where does level0 start? try to locate: level0[0] = sha256(salt+data[0:4096])
sysimg = open(imgdir + "/system.img", "rb").read()
d0 = hashlib.sha256(salt + sysimg[0:4096]).digest()
idx = tree.find(d0)
print("level0[0] found at tree offset:", idx)
