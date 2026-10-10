# Lean WirePlumber (PipeWire session manager) for the Ox guest.
# Binds against the lean PipeWire build, never the full nixpkgs pipewire
# (the full graph drags libcamera -> cross clang, a ~34h build).
# Standalone: nix build --impure -f wireplumber-lean.nix
{
  nixpkgsPin ? (builtins.getFlake "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674").legacyPackages.x86_64-linux,
}:
let
  pkgs = nixpkgsPin;
  lib = pkgs.lib;
  pipewireLean = import ./pipewire-lean.nix { inherit nixpkgsPin; };
  # Runtime deps only: glib (core), lua (scripting), pipewire (server ABI).
  # systemd/elogind/dbus are filtered out; the dbus-dependent monitors
  # disable themselves when dbus-1 is absent.
  keep = [
    "glib"
    "lua"
    "pipewire"
  ];
  wp = pkgs.pkgsCross.aarch64-multiplatform-musl.wireplumber.override {
    enableDocs = false;
    enableGI = false;
    pipewire = pipewireLean;
  };
in
wp.overrideAttrs (old: {
  buildInputs = builtins.filter
    (p: builtins.elem (p.pname or "") keep)
    (old.buildInputs or []);
  # glib-mkenums / gdbus-codegen are host build tools (meson find_program);
  # with docs+introspection disabled nothing else puts them on PATH.
  nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
    pkgs.buildPackages.glib.dev
  ];
  mesonFlags = (old.mesonFlags or []) ++ [
    (lib.mesonEnable "systemd" false)
    # wireplumber declares `tests` as a boolean option (not a feature).
    (lib.mesonBool "tests" false)
  ];
})
