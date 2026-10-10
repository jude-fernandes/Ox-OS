# Chunk-72 probe 4b: how does the pin's ubootPinebookPro wire BL31?
let
  f = (builtins.getFlake (toString /root/oxbuild)).inputs.nixpkgs
    .legacyPackages.x86_64-linux;
  u = f.ubootPinebookPro;
  interesting = builtins.filter (n:
    n == "makeFlags" || n == "extraMakeFlags" || n == "env"
    || n == "BL31" || n == "filesToInstall" || n == "extraConfig"
    || n == "patches") (builtins.attrNames u);
  show = n: n + " = " + builtins.toString u.${n};
in
builtins.concatStringsSep "\n" (map show interesting)
