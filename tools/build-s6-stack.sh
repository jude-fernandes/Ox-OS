#!/usr/bin/env bash
# Build the skarnet s6 stack for Ox OS Phase 1.
#   host toolset  -> /tmp/ox-s6/host/bin     (s6-rc-compile: DB compile at build time)
#   guest runtime -> /tmp/ox-s6/aarch64/bin  (fully static arm64 binaries for the rootfs)
# Tarball versions+checksums are pinned on first successful fetch (pins.env) and
# reused thereafter, so repeat builds are bit-stable without re-crawling.
set -euo pipefail

OUT=/tmp/ox-s6
SRC=$OUT/src
HOSTP=$OUT/host
ARMP=$OUT/aarch64
CROSS=aarch64-linux-gnu
mkdir -p "$SRC"

PKGS="skalibs execline s6 s6-rc"
PIN_FILE=$OUT/pins.env

pin_field() { # pkg field(1=ver 2=file 3=alg 4=hash)
    awk -F'|' -v p="$1" -v f="$2" '$1==p{print $f}' "$PIN_FILE"
}

fetch_pin() {
    local pkg=$1 ver file hash html
    html=$(curl -fs "https://skarnet.org/software/$pkg/")
    file=$(printf '%s' "$html" | grep -oE "$pkg-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz" | head -1)
    [ -n "$file" ] || { echo "ERROR: no tarball link found for $pkg" >&2; return 1; }
    ver=${file%.tar.gz}; ver=${ver#$pkg-}
    hash=$(curl -fs "https://skarnet.org/software/$pkg/$file.sha256" | awk '{print $1}')
    [ -n "$hash" ] || { echo "ERROR: no checksum found for $pkg" >&2; return 1; }
    printf '%s|%s|%s|sha256|%s\n' "$pkg" "$ver" "$file" "$hash" >> "$PIN_FILE"
}

get_tarball() {
    local pkg=$1 dest="$SRC/$2"
    local ver file alg hash
    ver=$(pin_field "$1" 2); file=$(pin_field "$1" 3); alg=$(pin_field "$1" 4); hash=$(pin_field "$1" 5)
    local tgz="$SRC/$file"
    if [ ! -f "$tgz" ]; then
        curl -fs -o "$tgz" "https://skarnet.org/software/$1/$file"
    fi
    echo "$hash  $tgz" | "${alg}sum" -c --quiet >/dev/null \
        || { echo "ERROR: $alg mismatch for $1" >&2; exit 1; }
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xzf "$tgz" -C "$dest" --strip-components=1
}

build_set() { # $1=staging-dir $2=extra-configure-args
    local stage=$1; shift
    local pkg dir
    for pkg in $PKGS; do
        dir="$SRC/${pkg}-build-$(basename "$stage")"
        rm -rf "$dir"
        get_tarball "$pkg" "${pkg}-build-$(basename "$stage")"
        (
            cd "$dir"
            # prefix MUST be /usr: s6-rc-compile bakes it into generated service
            # scripts, which must resolve identically inside the Ox OS image.
            conf="./configure --prefix=/usr --libexecdir=/usr/libexec \
--disable-shared --enable-static-libc \
--with-sysdeps=$stage/usr/lib/skalibs/sysdeps \
--with-include=$stage/usr/include --with-lib=$stage/usr/lib $*"
            case "$(basename "$stage")" in
                *aarch64*) conf="$conf --host=$CROSS" ;;
            esac
            echo "=== building $pkg ($(basename "$stage"))"
            eval "$conf" >configure.log 2>&1 || { cat configure.log; exit 1; }
            make -j"$(nproc)" >make.log 2>&1 || { tail -n 60 make.log; exit 1; }
            make install DESTDIR="$stage" >install.log 2>&1 || { tail -n 40 install.log; exit 1; }
        )
    done
}

echo "== pins =="
if [ ! -f "$PIN_FILE" ]; then
    : > "$PIN_FILE"
    for p in $PKGS; do fetch_pin "$p"; done
fi
cat "$PIN_FILE"

echo "== native host toolset =="
[ -x "$HOSTP/usr/bin/s6-rc-compile" ] || build_set "$HOSTP"

echo "== static arm64 guest runtime =="
if [ ! -x "$ARMP/usr/bin/s6-svscan" ]; then
    CC="$CROSS-gcc -static -s" build_set "$ARMP" \
        --with-sysdep-devurandom=yes \
        --with-sysdep-posixspawn=no \
        --with-sysdep-posixspawnearlyreturn=no \
        --with-sysdep-procselfexe=/proc/self/exe \
        --with-sysdep-selectinfinite=yes
fi

echo "== sanity =="
[ -x "$HOSTP/usr/bin/s6-rc-compile" ] || { echo "ERROR: host s6-rc-compile missing" >&2; exit 1; }
file "$ARMP/usr/bin/s6-svscan" | grep -q 'ARM aarch64' || { echo "ERROR: arm binary invalid" >&2; exit 1; }

echo "S6 STACK OK: host=$HOSTP/usr/bin arm64=$ARMP/usr/bin"
