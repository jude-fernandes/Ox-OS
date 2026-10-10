# Chunk 75: OnePlus 10 Pro (SM8450) image assembly — Android chain
# (header v4 + vendor_boot carrying the FDT, AVB-signed). Produced
# here, verified host-side by tools/target-android-gate.sh. The board
# FDT is the first-found of the device DTS or the SoC reference
# (qrd/hdk/mtp): mainline's OnePlus DTS status is an M1 question with
# the board; the gate asserts FDT validity, not the vendor name. The
# system slot is the SAME verified rootfs as every other target.
{
  lib,
  stdenv,
  python3,
  openssl,
  kernel-oneplus10pro,
  payload-qemu,
}:
let
  src = lib.cleanSource ./../..;
  dtbDir = "${kernel-oneplus10pro}/dtbs/qcom";
in
stdenv.mkDerivation {
  pname = "image-oneplus10pro";
  version = "0.1.0-chunk75";

  inherit src;

  nativeBuildInputs = [ python3 openssl ];

  dontUnpack = true;

  buildCommand = ''
    mkdir -p $out
    K=${kernel-oneplus10pro}/Image
    R=${payload-qemu}/initramfs.img
    D=""
    for name in sm8450-oneplus-pingpang sm8450-qrd sm8450-hdk sm8450-mtp; do
        [ -f "${dtbDir}/$name.dtb" ] && D="${dtbDir}/$name.dtb" && break
    done
    [ -n "$D" ] || { echo "FATAL: no SM8450 dtb in ${dtbDir}"; ls "${dtbDir}" | head; exit 4; }
    [ -f "$K" ] || { echo "FATAL: kernel Image missing at $K"; exit 4; }
    [ -f "$R" ] || { echo "FATAL: initramfs missing at $R"; exit 4; }
    echo "board dtb: $D"

    export OX_AVB_KEY=${./../../tools/dev-keys/avb-dev.pem}
    bash ${src}/targets/oneplus10pro-sm8450/boot.pack "$K" "$R" "$D" $out

    # the verified system slot + verity digest
    cp ${payload-qemu}/system.img $out/system.img
    cp ${payload-qemu}/system.hash.img $out/system.hash.img
    cp ${payload-qemu}/digest.env $out/digest.env

    cat > $out/README-FLASH.txt <<'EOF'
    OnePlus 10 Pro artifacts (chunk 75) — flash via fastboot:
      fastboot flash boot         boot.img         (header v4, AVB)
      fastboot flash vendor_boot  vendor_boot.img  (FDT, AVB)
      fastboot flash vbmeta       vbmeta.img       (chain root)
      fastboot flash system       system.img       (erofs + dm-verity)
    Re-lock enrollment: sha256(boot public key) = avb-pkmd.bin.
    Dev key until owner enrollment (M2).
    EOF
    sha256sum $out/boot.img $out/vendor_boot.img $out/vbmeta.img \
        $out/system.img > $out/artifacts.sha256
    echo "image-oneplus10pro assembled:"
    ls -la $out
  '';
}
