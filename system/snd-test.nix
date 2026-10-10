# ox-snd-test: static aarch64 audio selftest player (see snd-test/ox-snd-test.c).
# Host stdenv + GNU cross toolchain driven by driver-name probe; glibc's
# static output must be on the link path (see docs/process/reports/
# 2026-08-29-nix-image-pipeline.md discovery #4).
{
  lib,
  pkgs,
  stdenv,
}:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
in
stdenv.mkDerivation {
  pname = "ox-snd-test";
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
    "$CCX" -static -Os -s -o ox-snd-test ${./snd-test/ox-snd-test.c}
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp ox-snd-test $out/bin/
  '';

  meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
}
