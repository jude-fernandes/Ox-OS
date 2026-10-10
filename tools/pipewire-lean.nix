# Lean audio-only PipeWire for the Ox guest (musl aarch64 cross).
# Call with a pinned nixpkgs, e.g. from flake.nix:
#   callPackage ./tools/pipewire-lean.nix { nixpkgsPin = <pinned pkgs>; }
# or standalone: nix build --impure -f pipewire-lean.nix
{
  nixpkgsPin ? (builtins.getFlake "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674").legacyPackages.x86_64-linux,
}:
let
  pkgs = nixpkgsPin;
  lib = pkgs.lib;
  keep = [
    "glib"
    "dbus"
    "alsa-lib"
    "libsndfile"
    "ncurses"
    "readline"
    "libopus"
    "libusb"
  ];
  pw = pkgs.pkgsCross.aarch64-multiplatform-musl.pipewire.override {
    enableSystemd = false;
    vulkanSupport = false;
    zeroconfSupport = false;
    raopSupport = false;
    rocSupport = false;
    x11Support = false;
    ffadoSupport = false;
  };
in
pw.overrideAttrs (old: {
  buildInputs = builtins.filter
    (p: builtins.elem (p.pname or "") keep)
    (old.buildInputs or []);
  nativeBuildInputs = builtins.filter
    (p: !builtins.elem (p.pname or "") [
      "doxygen"
      "graphviz"
      "docutils"
      "makeFontsConf"
    ])
    (old.nativeBuildInputs or []);
  mesonFlags = (old.mesonFlags or []) ++ [
    (lib.mesonEnable "libcamera" false)
    (lib.mesonEnable "bluez5" false)
    (lib.mesonEnable "gstreamer" false)
    (lib.mesonEnable "gstreamer-device-provider" false)
    (lib.mesonEnable "vulkan" false)
    (lib.mesonEnable "roc" false)
    (lib.mesonEnable "jack" false)
    (lib.mesonEnable "raop" false)
    (lib.mesonEnable "tests" false)
    (lib.mesonEnable "examples" false)
    (lib.mesonEnable "man" false)
    (lib.mesonEnable "docs" false)
    (lib.mesonEnable "ffmpeg" false)
    (lib.mesonEnable "pw-cat-ffmpeg" false)
    (lib.mesonEnable "libpulse" false)
    (lib.mesonEnable "libmysofa" false)
    (lib.mesonEnable "compress-offload" false)
    (lib.mesonEnable "lv2" false)
    (lib.mesonEnable "echo-cancel-webrtc" false)
    (lib.mesonEnable "logind" false)
    (lib.mesonEnable "selinux" false)
  ];
  # docs/man/jack features are disabled; nix still requires the declared
  # outputs to exist.
  postInstall = (old.postInstall or "") + ''
    mkdir -p "$doc" "$man" "$jack" "$installedTests"
  '';
})
