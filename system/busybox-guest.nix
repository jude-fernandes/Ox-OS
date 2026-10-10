# Static aarch64 busybox for the Ox OS guest rootfs.
# Mirrors tools/build-busybox.sh exactly: pinned upstream tarball (the same
# sha256 busybox.net publishes), arm64 defconfig with CONFIG_STATIC=y and
# CONFIG_TC off. Built under the HOST stdenv with the musl cross toolchain
# driven via CROSS_COMPILE — busybox's host tools (fixdep, kconfig) must
# compile and run on the build machine, so a cross stdenv (which replaces
# `gcc`) cannot be used here.
{
  lib,
  pkgs,
  stdenv,
}:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform-musl;
  prefix = cross.stdenv.cc.targetPrefix; # aarch64-unknown-linux-musl-
  ver = "1.36.1";
in
stdenv.mkDerivation {
  pname = "ox-busybox-aarch64";
  version = ver;

  src = pkgs.fetchurl {
    url = "https://busybox.net/downloads/busybox-${ver}.tar.bz2";
    sha256 = "b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314";
  };

  hardeningDisable = [ "all" ];
  nativeBuildInputs = [ cross.stdenv.cc ];

  postConfigure = ''
    make ARCH=arm64 CROSS_COMPILE=${prefix} defconfig
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    yes "" | make ARCH=arm64 CROSS_COMPILE=${prefix} oldconfig >/dev/null 2>&1 || true
  '';

  buildPhase = ''
    make ARCH=arm64 CROSS_COMPILE=${prefix} -j $NIX_BUILD_CORES
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp busybox $out/bin/busybox
    ${prefix}strip $out/bin/busybox || true
  '';

  meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
}
