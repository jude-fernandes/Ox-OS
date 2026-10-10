# Chunk 72: PinePhone Pro IMAGE assembly — the first executed
# hardware-target build. Every stage the board would boot, produced
# here and verified host-side by tools/target-pinephone-gate.sh:
#   - U-Boot stages (idbloader.img TPL+SPL, u-boot.itb) — pinephone-pro
#     defconfig; unsigned (owner-key enrollment is BRINGUP M2)
#   - ox.itb: the FIT, SIGNED with the dev key (sha256,rsa2048,
#     required) — public key injected into the control DTB pulled out
#     of U-Boot itself (the M1/M2 flashing artifact)
#   - the raw boot triple (Image / rk3399.dtb / initramfs) + boot.txt
#   - the verified system slot: the SAME erofs + dm-verity rootfs the
#     16-gate suite proves on the virtual target
# The board itself remains for electrical bring-up (BRINGUP M1).
{
  lib,
  stdenv,
  python3,
  ubootTools,
  dtc,
  openssl,
  kernel-pinephone-pro,
  uboot-pinephone-pro,
  payload-qemu,
}:
let
  src = lib.cleanSource ./../..;
  # cleanSource drops a tree-wide "keys/" dir; tools/dev-keys survives,
  # but reference the FIT dev keypair directly for a deterministic path.
  fitKeys = ./../../tools/dev-keys;
  dtb = "${kernel-pinephone-pro}/dtbs/rockchip/rk3399-pinephone-pro.dtb";
in
stdenv.mkDerivation {
  pname = "image-pinephone-pro";
  version = "0.1.0-chunk72";

  inherit src;

  nativeBuildInputs = [ python3 ubootTools dtc openssl ];

  dontUnpack = true;

  buildCommand = ''
    mkdir -p $out
    K=${kernel-pinephone-pro}/Image
    R=${payload-qemu}/initramfs.img
    D=${dtb}
    [ -f "$K" ] || { echo "FATAL: kernel Image missing at $K"; exit 4; }
    [ -f "$R" ] || { echo "FATAL: initramfs missing at $R"; exit 4; }
    [ -f "$D" ] || { echo "FATAL: board dtb missing at $D"; exit 4; }
    echo "control dtb source: u-boot.bin from ${uboot-pinephone-pro}"

    # 1) the control DTB: extracted from U-Boot itself (u-boot.bin when
    #    the output ships it, else the "u-boot" node of u-boot.itb), then
    #    the FIT public key is injected INTO it during signing below
    UBOOT_SRC=""
    for f in ${uboot-pinephone-pro}/u-boot.bin ${uboot-pinephone-pro}/u-boot.itb; do
        [ -f "$f" ] && UBOOT_SRC="$f" && break
    done
    [ -n "$UBOOT_SRC" ] || { echo "FATAL: no u-boot.bin/u-boot.itb in ${uboot-pinephone-pro}"; exit 4; }
    echo "control dtb source: $UBOOT_SRC"
    python3 ${src}/tools/uboot-control-dtb.py "$UBOOT_SRC" control.dtb

    # 2) pack + sign the FIT (required signatures; pubkey -> control dtb);
    #    kernel gzipped into the FIT (65MB raw exceeds the 64M boot part)
    OX_FIT_KEY_DIR=${fitKeys} OX_FIT_KEY_DTB=$PWD/control.dtb OX_FIT_GZIP=1 \
        bash ${src}/targets/pinephone-pro/boot.pack "$K" "$R" "$D" $out
    cp control.dtb $out/control-keyed.dtb

    # 3) U-Boot stages
    for f in u-boot.itb idbloader.img u-boot.bin; do
        [ -f "${uboot-pinephone-pro}/$f" ] && cp "${uboot-pinephone-pro}/$f" $out/ || true
    done

    # 4) the verified system slot (the 16-gate-proven rootfs) + the
    #    verity digest the host gate re-verifies (verify-host pattern)
    #    + the dev data-volume key the flash script LUKS-formats with (R-22)
    cp ${payload-qemu}/system.img $out/system.img
    cp ${payload-qemu}/system.hash.img $out/system.hash.img
    cp ${payload-qemu}/digest.env $out/digest.env
    cp ${payload-qemu}/data.img.key $out/data.img.key
    cp ${payload-qemu}/cmdline.txt $out/cmdline.txt 2>/dev/null || true

    # 5) flash layout + signing status (BRINGUP.md is the authority)
    cat > $out/README-FLASH.txt <<'EOF'
    PinePhone Pro artifacts (chunk 72) — flash offsets in BRINGUP.md:
      0x0        idbloader.img   (TPL+SPL, unsigned — M2 enrolls owner key)
      0x80000    u-boot.itb      (unsigned — M2)
      boot_a/b   ox.itb (SIGNED, required: sha256,rsa2048 dev key) or
                 the raw triple (Image + rk3399.dtb + initramfs.cpio.gz)
      system_a/b system.img (erofs + dm-verity, the 16-gate-proven rootfs)
      data       LUKS2 (created at first boot / provisioning)
    control-keyed.dtb carries the fit-dev public key U-Boot verifies
    ox.itb against; FIT addresses (0x08080000) are U-Boot distro defaults
    — confirm against the device env at bring-up (M1).
    EOF
    sha256sum $out/ox.itb $out/Image $out/rk3399.dtb $out/u-boot.itb \
        $out/idbloader.img $out/system.img > $out/artifacts.sha256
    echo "image-pinephone-pro assembled:"
    ls -la $out
  '';
}
