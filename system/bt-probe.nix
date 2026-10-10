# ox-bt-probe: static aarch64 /dev/vhci attach probe (see bt-probe/ox-bt-probe.c).
# Same build shape as snd-test.nix (host stdenv + GNU cross, static glibc).
{
  lib,
  pkgs,
  stdenv,
}:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
in
stdenv.mkDerivation {
  pname = "ox-bt-probe";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ cross.stdenv.cc ];

  buildPhase = ''
    export NIX_LDFLAGS="$NIX_LDFLAGS -L ${cross.glibc}/lib -L ${cross.glibc.static}/lib"
    CCX=""
    for c in aarch64-linux-gnu-gcc aarch64-unknown-linux-gnu-gcc; do
        if command -v "$c" >/dev/null 2>&1; then CCX="$(command -v "$c")"; break; fi
    done
    [ -n "$CCX" ] || { echo "ERROR: no aarch64 cross gcc on PATH" >&2; exit 5; }
    "$CCX" -static -Os -s -o ox-bt-probe ${./bt-probe/ox-bt-probe.c}
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp ox-bt-probe $out/bin/
  '';

  meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
}
