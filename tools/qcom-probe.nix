# Chunk-73 probe 2: python package set for mkbootimg/avb, and does
# android-tools bundle avbtool?
let
  f = (builtins.getFlake (toString /root/oxbuild)).inputs.nixpkgs
    .legacyPackages.x86_64-linux;
  pyp = f.python3Packages;
  pyprobe = n: n + "=" + (if pyp ? ${n} then "attr" else "MISSING");
  a = f.android-tools;
  bins = builtins.filter (n:
    n == "avbtool" || n == "mkbootimg" || n == "unpack_bootimg" || n == "avb")
    (builtins.attrNames a);
in
builtins.concatStringsSep "," (map pyprobe [
  "mkbootimg" "avbtool" "pyelftools" "cryptography" "attrs"
])
+ "\nandroid-tools-bins: " + builtins.concatStringsSep "," bins
+ "\nandroid-tools-out: " + toString a
