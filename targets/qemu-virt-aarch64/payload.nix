# Ox OS signed boot payload for the QEMU virt-aarch64 target, assembled
# hermetically by Nix: runs tools/build-payload.sh (squashfs system image →
# dm-verity tree → signed manifest → deterministic initramfs) inside the
# sandbox. The ed25519 dev-release key is pinned in the repo (ox/keys/) so
# signing needs no network and no host state; all inputs are store paths.
{
  lib,
  stdenv,
  python3,
  cryptsetup,
  squashfsTools,
  erofs-utils,
  openssl,
  cpio,
  gzip,
  pkgs,
  rootfs,
  kernel,
}:
let
  # GNU cross cc: its wrapper resolves static glibc correctly when invoked
  # as aarch64-linux-gnu-gcc (the musl cross wrapper fails `-static` with
  # "cannot find -lc").
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  src = lib.cleanSource ./../..; # ox/ flake root
  # The pinned dev-release keypair — referenced directly because
  # lib.cleanSource drops the keys/ directory from the tree-wide src.
  keys = ./../../keys;
in
stdenv.mkDerivation {
  pname = "ox-payload-qemu";
  version = "0.1.0-phase1";

  inherit src;

  # erofs-utils is unused for the squashfs output but mksystem-image.sh
  # guards on `command -v mkfs.erofs` before the format branch; openssl is
  # the ed25519 backend of tools/ox-keytool.py.
  nativeBuildInputs = [
    python3 cryptsetup squashfsTools erofs-utils openssl cpio gzip
    cross.stdenv.cc
  ];

  dontUnpack = true;

  buildCommand = ''
    # Driver name varies across cross-gcc wrapper generations
    # (aarch64-linux-gnu-gcc vs aarch64-unknown-linux-gnu-gcc) — probe.
    # glibc's static output must be on the link path for `-static`
    # (same as system/s6-stack.nix; the cross wrapper does not add it).
    export NIX_LDFLAGS="$NIX_LDFLAGS -L ${pkgs.pkgsCross.aarch64-multiplatform.glibc}/lib -L ${pkgs.pkgsCross.aarch64-multiplatform.glibc.static}/lib"
    OX_CROSS_CC=""
    for c in aarch64-linux-gnu-gcc aarch64-unknown-linux-gnu-gcc; do
        if command -v "$c" >/dev/null 2>&1; then
            OX_CROSS_CC="$(command -v "$c")"
            break
        fi
    done
    [ -n "$OX_CROSS_CC" ] || { echo "ERROR: no aarch64 cross gcc on PATH" >&2; exit 5; }
    export OX_CROSS_CC
    # mksquashfs refuses SOURCE_DATE_EPOCH (set by the stdenv) alongside
    # mksystem-image.sh's explicit -all-time/-root-time/-mkfs-time 0 flags.
    unset SOURCE_DATE_EPOCH
    # Verbose cmdline (no `quiet`): kernel driver bring-up messages stay
    # visible on the serial log — the gates grep them. Revisit for release.
    export OX_VERBOSE=1
    mkdir -p $out
    bash ${src}/tools/build-payload.sh qemu-virt-aarch64 \
        ${rootfs} ${kernel}/Image $out ${keys}/dev-release.pem

    # Convenience launcher: the store payload dir is read-only and run-qemu
    # writes data.img next to the artifacts, so clone into scratch first.
    cat > $out/run-qemu <<'EOF'
    #!/bin/sh
    set -eu
    P=$(mktemp -d /tmp/ox-nix-payload.XXXXXX)
    cp -r ${placeholder "out"}/. "$P"/
    exec bash ${./run-qemu.sh} "$P" ${kernel}/Image "$@"
    EOF
    chmod +x $out/run-qemu
  '';

  passthru = {
    inherit rootfs kernel;
  };

  meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
}
