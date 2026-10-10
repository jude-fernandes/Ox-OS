#!/bin/sh
# List pipewire's remaining build/native inputs after the lean filter,
# to find which one still drags clang/LLVM.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
EXPR='
  let
    flake = builtins.getFlake "github:NixOS/nixpkgs/nixos-24.11";
    pkgs = flake.legacyPackages.x86_64-linux;
    lib = pkgs.lib;
    drop = [
      "libcamera" "bluez" "sbc" "libfreeaptx" "liblc3" "fdk-aac" "ldacbt"
      "gstreamer" "gst-plugins-base" "gst-plugins-good" "webrtc-audio-processing"
      "vulkan-loader" "avahi" "libmysofa" "libcanberra" "roc-toolkit"
      "libjack2" "lilv" "libffado"
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
  in {
    buildInputs = map (p: p.pname or p.name or "?") (builtins.filter
      (p: !builtins.elem (p.pname or "") drop)
      (pw.buildInputs or []));
    nativeBuildInputs = map (p: p.pname or p.name or "?") (pw.nativeBuildInputs or []);
    propagatedBuildInputs = map (p: p.pname or p.name or "?") (pw.propagatedBuildInputs or []);
  }
'
"$NIX" eval --impure --json --expr "$EXPR"
