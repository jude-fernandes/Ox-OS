#!/usr/bin/env python3
"""BFS the 1.6.8 pipewire drv graph for the clang chain, then print the
current nixos-24.11 rev so the next eval can be pinned to it."""
import json, subprocess
from collections import deque

NIX = "/nix/var/nix/profiles/per-user/root/profile/bin/nix"
DRV = "/nix/store/4v6q0zmg2jln66i19bd009wzawhlhakn-pipewire-aarch64-unknown-linux-musl-1.6.8.drv"

meta = subprocess.run(
    [NIX, "flake", "metadata", "github:NixOS/nixpkgs/nixos-24.11", "--json"],
    capture_output=True, text=True, check=True).stdout
rev = json.loads(meta)["revision"]
print(f"nixos-24.11 rev: {rev}")

graph = subprocess.run(
    [NIX, "derivation", "show", "-r", DRV],
    capture_output=True, text=True, check=True).stdout
data = json.loads(graph)["derivations"]
print(f"graph: {len(data)} derivations")

def input_drvs(node):
    return list((node.get("inputDrvs") or {}).keys())

parents = {DRV: None}
queue = deque([DRV])
seen = {DRV}
targets = []
while queue and len(targets) < 3:
    cur = queue.popleft()
    node = data.get(cur)
    if node is None:
        continue
    for inp in input_drvs(node):
        name = inp.rsplit("/", 1)[-1]
        if "clang" in name and inp not in seen:
            parents[inp] = cur
            targets.append(inp)
            seen.add(inp)
            continue
        if inp not in seen:
            seen.add(inp)
            parents[inp] = cur
            queue.append(inp)

for t in targets:
    chain = []
    cur = t
    while cur:
        chain.append(cur.rsplit("/", 1)[-1].split(".drv")[0].split("-", 1)[-1])
        cur = parents.get(cur)
    print("CHAIN:", " -> ".join(reversed(chain)))
if not targets:
    print("no clang in graph")
