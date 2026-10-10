# Ox OS s6 supervision stack, built hermetically from the SAME pinned
# skarnet tarballs tools/build-s6-stack.sh uses (pins.env captured the
# versions + sha256 on first fetch; they are pinned here verbatim).
#
# Two builds from one recipe:
#   - guest (this derivation): fully static aarch64 musl runtime for the
#     rootfs (/usr/bin, /usr/libexec), prefix=/usr because s6-rc-compile
#     bakes the prefix into generated service scripts — they must resolve
#     identically inside the image.
#   - passthru.hostTools: native host build for DB compilation at image
#     build time (s6-rc-compile).
{
  lib,
  pkgs,
  stdenv,
}:
let
  pins = {
    skalibs = {
      ver = "2.15.1.0";
      sha = "f9c905e74935c6fe911c7e344e3e89d5fbd2014c1a04650b524b15ce9b5635d1";
    };
    execline = {
      ver = "2.9.9.2";
      sha = "908ed4db3a6b3a23a205d8fd4cf2a71089156f2aeae0f54656045aafad2dee32";
    };
    s6 = {
      ver = "2.15.1.0";
      sha = "eab9c46e22b66b16135f9a05ec68a0ea287d9060b84d10defaaa2caad158ab52";
    };
    s6-rc = {
      ver = "0.7.0.0";
      sha = "bf5b8ce0da5a4ee70d642b818b61d9916a7a9b64a457595f388113e54a188688";
    };
  };
  order = [ "skalibs" "execline" "s6" "s6-rc" ];
  tarball = name: pkgs.fetchurl {
    url = "https://skarnet.org/software/${name}/${name}-${pins.${name}.ver}.tar.gz";
    sha256 = pins.${name}.sha;
  };

  # One builder covering both toolchains; mirrors build_set() in
  # tools/build-s6-stack.sh (configure flags byte-for-byte where it matters).
  mkStack =
    {
      name,
      stdenv,
      ldFlags ? "",
      configureHost ? null,
      sysdepArgs ? "",
      extraPassthru ? { },
    }:
    stdenv.mkDerivation {
      pname = name;
      version = pins.s6.ver;

      # Four independent tarballs — unpack them ourselves (the stdenv
      # multi-src unpacker refuses to produce multiple top-level dirs).
      dontUnpack = true;

      nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
      # Mirror build-s6-stack.sh: CC="$CROSS-gcc -static -s" for the guest;
      # --enable-static-libc needs the libc static output on the link path
      # in BOTH stdenvs (host glibc ships libc.a in glibc.static).
      env = {
        NIX_LDFLAGS = ldFlags;
      } // lib.optionalAttrs (configureHost != null) {
        CC = "${stdenv.cc.targetPrefix}gcc -static -s";
      };

      dontConfigure = true; # configure runs inside buildPhase per package
      dontStrip = true; # guest bits are already `-s`-stripped via CC args

      buildPhase = ''
        TOP=$PWD
        STAGE=$TOP/stage
        mkdir -p "$STAGE"
        ${lib.concatMapStrings (pkg: ''
          mkdir -p "$TOP/${pkg}-src"
          tar -xzf ${tarball pkg} -C "$TOP/${pkg}-src" --strip-components=1
        '') order}
        for pkg in ${lib.concatStringsSep " " order}; do
          echo "=== building $pkg"
          BUILDDIR=$TOP/$pkg-build
          mkdir -p "$BUILDDIR"
          cp -a "$TOP/$pkg-src/." "$BUILDDIR"/
          cd "$BUILDDIR"
          ./configure --prefix=/usr --libexecdir=/usr/libexec \
              --disable-shared --enable-static-libc \
              --with-sysdeps=$STAGE/usr/lib/skalibs/sysdeps \
              --with-include=$STAGE/usr/include --with-lib=$STAGE/usr/lib \
              ${lib.optionalString (configureHost != null) "--host=${configureHost}"} \
              ${sysdepArgs} \
              > configure.log 2>&1 || { cat configure.log; exit 1; }
          make -j $NIX_BUILD_CORES > make.log 2>&1 || { tail -60 make.log; exit 1; }
          make install DESTDIR=$STAGE > install.log 2>&1 || { tail -40 install.log; exit 1; }
          cd "$TOP"
        done
      '';

      installPhase = ''
        mkdir -p $out
        cp -a $STAGE/usr/* $out/
      '';

      passthru = { inherit pins; } // extraPassthru;
    };

  hostTools = mkStack {
    name = "ox-s6-stack-host";
    stdenv = stdenv;
    ldFlags = "-L ${pkgs.glibc.static}/lib";
  };

  guest = mkStack {
    name = "ox-s6-stack-aarch64";
    # GNU cross stdenv — the exact toolchain build-s6-stack.sh validated
    # (aarch64-linux-gnu-gcc -static); the musl cross cc-wrapper does not
    # inject its libc into `-static` link lines (cannot find -lc).
    stdenv = pkgs.pkgsCross.aarch64-multiplatform.stdenv;
    # Host triplet must match the toolchain's binutils prefix (the cc
    # driver is aarch64-linux-gnu-gcc but ar/as/ld are
    # aarch64-unknown-linux-gnu-* — skaware derives tool names from --host).
    configureHost = "aarch64-unknown-linux-gnu";
    ldFlags = "-L ${pkgs.pkgsCross.aarch64-multiplatform.glibc}/lib"
      + " -L ${pkgs.pkgsCross.aarch64-multiplatform.glibc.static}/lib";
    # Probed sysdeps overrides from build-s6-stack.sh (TCG/virt target).
    sysdepArgs = "--with-sysdep-devurandom=yes --with-sysdep-posixspawn=no --with-sysdep-posixspawnearlyreturn=no --with-sysdep-procselfexe=/proc/self/exe --with-sysdep-selectinfinite=yes";
    extraPassthru = { inherit hostTools; };
  };
in
guest
