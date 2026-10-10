# Chunk 73: Fairphone 5 IMAGE assembly — the second executed
# hardware-target build, first on the Android chain (ABL + AVB).
# Produced here, verified host-side by tools/target-fairphone5-gate.sh:
#   boot.img   — Android boot image v4 (gzipped kernel + initramfs),
#                AVB hash footer signed under the dev key
#   dtbo.img   — dt_table image carrying the QCM6490 board FDT, signed
#   vbmeta.img — the vbmeta root chaining boot + dtbo keys
#   avb-pkmd.bin — sha256(boot public key) = the re-lock enrollment value
#   + the verified system slot (the 16-gate-proven rootfs)
# The board remains for electrical bring-up (BRINGUP M1: unlock/relock
# with the user AVB key per the vendor fastboot flow).
{
  lib,
  stdenv,
  python3,
  openssl,
  kernel-fairphone5,
  payload-qemu,
}:
let
  src = lib.cleanSource ./../..;
  fitKeys = ./../../tools/dev-keys;
  dtb = "${kernel-fairphone5}/dtbs/qcom/qcm6490-fairphone-fp5.dtb";
in
stdenv.mkDerivation {
  pname = "image-fairphone5";
  version = "0.1.0-chunk73";

  inherit src;

  nativeBuildInputs = [ python3 openssl ];

  dontUnpack = true;

  buildCommand = ''
    mkdir -p $out
    K=${kernel-fairphone5}/Image
    R=${payload-qemu}/initramfs.img
    D=${dtb}
    [ -f "$K" ] || { echo "FATAL: kernel Image missing at $K"; exit 4; }
    [ -f "$R" ] || { echo "FATAL: initramfs missing at $R"; exit 4; }
    [ -f "$D" ] || { echo "FATAL: board dtb missing at $D"; exit 4; }

    export OX_AVB_KEY_DIR=${fitKeys}
    bash ${src}/targets/fairphone5/boot.pack "$K" "$R" "$D" $out

    # the verified system slot (the 16-gate-proven rootfs) + verity digest
    cp ${payload-qemu}/system.img $out/system.img
    cp ${payload-qemu}/system.hash.img $out/system.hash.img
    cp ${payload-qemu}/digest.env $out/digest.env

    cat > $out/README-FLASH.txt <<'EOF'
    Fairphone 5 artifacts (chunk 73) — flash via fastboot (BRINGUP.md):
      fastboot flash boot    boot.img    (boot image v4, AVB hash footer)
      fastboot flash dtbo    dtbo.img    (dt_table, AVB signed)
      fastboot flash vbmeta  vbmeta.img  (chain root: boot + dtbo keys)
      fastboot flash system  system.img  (erofs + dm-verity A/B slot)
    Re-lock enrollment (vendor flow): the user enrolls
    sha256(extracted boot public key) = avb-pkmd.bin
    Dev key until owner enrollment; rollback indexes are M2.
    EOF
    sha256sum $out/boot.img $out/dtbo.img $out/vbmeta.img $out/system.img \
        > $out/artifacts.sha256
    echo "image-fairphone5 assembled:"
    ls -la $out
  '';
}
