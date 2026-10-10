#!/bin/sh
# GC roots for the current tree's builds (chunk 66): the Oct-3 nix-store
# loss (toolchain tarballs unreachable after sweeps' --no-link builds,
# with the weekly nix-collect-garbage task nearby) made --offline builds
# impossible for hours. Registering the outputs as indirect GC roots
# keeps the payload/kernel/workspace closures until the links move.
# Run after any successful build; nix-collect-garbage respects these.
# Chunk 75: the fleet targets joined the rooted set, plus the pinned
# kernel source tarball (a build-time-only input — outputs do not
# reference it, so plain GC would collect it and strand --offline
# kernel rebuilds).
set -e
cd /root/oxbuild
N=/nix/var/nix/profiles/per-user/root/profile/bin/nix
OUTS=$($N build .#payload-qemu .#kernel-qemu .#workspace-test \
    .#kernel-pinephone-pro .#uboot-pinephone-pro .#image-pinephone-pro \
    .#kernel-fairphone5 .#image-fairphone5 \
    .#kernel-oneplus9rt .#image-oneplus9rt \
    .#kernel-oneplus10pro .#image-oneplus10pro \
    --no-link --print-out-paths 2>/dev/null)
mkdir -p gcroots
for OUT in $OUTS; do
    LN=$(basename "$OUT" | cut -c1-40 | tr -c 'a-zA-Z0-9._' '-')
    ln -sfn "$OUT" "/root/oxbuild/gcroots/$LN"
done
# the pinned kernel source: root every copy in the store
for SRC in /nix/store/*-linux-6.18.48.tar.xz; do
    [ -e "$SRC" ] && ln -sfn "$SRC" \
        "/root/oxbuild/gcroots/src-$(basename "$SRC" | cut -c1-40)"
done
# chunk 76 lesson: output roots do NOT protect build-time inputs (the
# post-GC offline build rebuilt rustc + kernel-qemu + the musl
# cross-stdenv from source, ~13h). Rooting the .drv keeps its whole
# INPUT closure — build inputs survive every future GC.
i=0
for A in payload-qemu kernel-qemu workspace-test \
         kernel-pinephone-pro uboot-pinephone-pro image-pinephone-pro \
         kernel-fairphone5 image-fairphone5 \
         kernel-oneplus9rt image-oneplus9rt \
         kernel-oneplus10pro image-oneplus10pro; do
    DRV=$($N eval --raw ".#$A.drvPath" 2>/dev/null) || continue
    [ -e "$DRV" ] && ln -sfn "$DRV" "/root/oxbuild/gcroots/drv-$A"
    i=$((i + 1))
done
echo "gc-keep: rooted $(echo "$OUTS" | wc -w) outputs + $i drvs + kernel sources"
