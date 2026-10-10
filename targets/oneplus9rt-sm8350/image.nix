# Chunk 75: OnePlus 9RT (SM8350) image assembly — Android chain
# (header v2, dtb embedded in boot.img, AVB-signed). Produced here,
# verified host-side by tools/target-android-gate.sh. The board FDT is
# the first-found of the device DTS or the SoC reference (mtp/qrd):
# mainline's OnePlus DTS status is an M1 question with the board; the
# gate asserts FDT validity, not the vendor name. The system slot is
# the SAME verified rootfs as every other target.
{
  lib,
  stdenv,
  python3,
  openssl,
  kernel-oneplus9rt,
  payload-qemu,
}:
let
  src = lib.cleanSource ./../..;
  dtbDir = "${kernel-oneplus9rt}/dtbs/qcom";
in
stdenv.mkDerivation {
  pname = "image-oneplus9rt";
  version = "0.1.0-chunk75";

  inherit src;

  nativeBuildInputs = [ python3 openssl ];

  dontUnpack = true;

  buildCommand = ''
    mkdir -p $out
    K=${kernel-oneplus9rt}/Image
    R=${payload-qemu}/initramfs.img
    D=""
    for name in sm8350-oneplus-le2100 sm8350-mtp sm8350-qrd; do
        [ -f "${dtbDir}/$name.dtb" ] && D="${dtbDir}/$name.dtb" && break
    done
    [ -n "$D" ] || { echo "FATAL: no SM8350 dtb in ${dtbDir}"; ls "${dtbDir}" | head; exit 4; }
    [ -f "$K" ] || { echo "FATAL: kernel Image missing at $K"; exit 4; }
    [ -f "$R" ] || { echo "FATAL: initramfs missing at $R"; exit 4; }
    echo "board dtb: $D"

    export OX_AVB_KEY=${./../../tools/dev-keys/avb-dev.pem}
    bash ${src}/targets/oneplus9rt-sm8350/boot.pack "$K" "$R" "$D" $out

    # the verified system slot + verity digest
    cp ${payload-qemu}/system.img $out/system.img
    cp ${payload-qemu}/system.hash.img $out/system.hash.img
    cp ${payload-qemu}/digest.env $out/digest.env

    cat > $out/README-FLASH.txt <<'EOF'
    OnePlus 9RT artifacts (chunk 75) — flash via fastboot:
      fastboot flash boot    boot.img    (header v2, dtb embedded, AVB)
      fastboot flash vbmeta  vbmeta.img  (chain root)
      fastboot flash system  system.img  (erofs + dm-verity A/B slot)
    Re-lock enrollment: sha256(boot public key) = avb-pkmd.bin.
    Dev key until owner enrollment (M2).
    EOF
    sha256sum $out/boot.img $out/vbmeta.img $out/system.img \
        > $out/artifacts.sha256
    echo "image-oneplus9rt assembled:"
    ls -la $out
  '';
}
