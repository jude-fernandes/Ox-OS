# WirePlumber milestone — session manager + dynamic audio discovery

Date: 2026-09-04
Status: **DONE — WIREPLUMBER GATE ALL GREEN** (`tools/wireplumber-gate.sh`:
pipewire-up + wireplumber-up + wp-played + host wav RMS 3089, 222899
frames). Discovered sink in-guest: `* 42. VirtIO SoundCard Stereo
[vol: 0.40]` — udev-enumerated, acp-profiled, default-selected by
WirePlumber. No static nodes anywhere.

## What this milestone is

PipeWire alone does not link streams to devices — that is the session
manager's job (see the 2026-09-03/04 handoff: pw-play hung `suspended`
forever with no session manager, and the shipped workaround used a
server-side audiotestsrc linked by hand). This milestone adds:

- **WirePlumber 0.5.8** (`tools/wireplumber-lean.nix`), cross-built to
  aarch64 musl against the lean PipeWire build — stream linking, default
  device policy, device profile/routes management.
- **Dynamic ALSA device discovery** via WirePlumber's `monitor.alsa` →
  spa `api.alsa.enum.udev`. The static `pipewire.conf.d/10-ox-alsa.conf`
  sink workaround is REMOVED: no static nodes anywhere.
- **eudev 3.2.14** in the guest (udev daemon), because dynamic discovery
  requires a running udev (see root cause below).
- s6 services: `udev` (daemon + warmplug + settle, milestone `udev-ready`)
  and `wireplumber` (deps: pipewire + udev; milestones `wireplumber-up`,
  `wp-played`).

## Build (tools/wireplumber-lean.nix)

Stock nixpkgs wireplumber overridden: `enableDocs=false`, `enableGI=false`,
`pipewire = pipewireLean` (the full nixpkgs pipewire graph drags libcamera →
cross clang ≈ 34h), buildInputs filtered to `glib, lua, pipewire`,
`-Dsystemd=disabled`, `-Dtests=false` (boolean option, not a feature —
meson errors on `-Dtests=disabled`), plus host `glib.dev` in
nativeBuildInputs (meson `find_program('glib-mkenums')` — with docs/GI
disabled nothing else provides it). Output 3.4 MiB; RUNPATHs baked to the
lean pipewire / glib / musl store paths; interp = store musl.

## Integration (system/rootfs.nix)

Same store-preserving closure-copy pattern as pipewire (closureInfo →
`/nix/store`, `-dev` outputs filtered from the runtime globs, alsa-ucm-conf
excluded — "Librem 5.conf" space breaks the squashfs sort file). Bin
symlinks: `wireplumber`, `wpctl`, `wpexec`. `share/wireplumber` (config +
Lua scripts) and `lib/wireplumber-0.5` (modules) ride inside the store
copy. No /etc/wireplumber overrides — stock config, profile `main`.

## Root cause: why dynamic discovery needed a udev daemon (source-level)

First gate boot: `pipewire-up` ✓, `wireplumber-up` ✓ (wpctl saw the
WirePlumber clients), but `wpctl status` showed **zero Devices/Sinks** and
pw-play failed with `no target node available`. Every other monitor logged
its SPA-missing notice (bluez, libcamera) — the ALSA monitor was silent.

`spa/plugins/alsa/alsa-udev.c` (pipewire 1.2.7), `get_card_nr()`:

    if (udev_device_get_property_value(udev_device, "SOUND_INITIALIZED") == NULL)
        return SPA_ID_INVALID;

`SOUND_INITIALIZED` is set only by udev rules (`78-sound-card.rules`,
`ENV{SOUND_INITIALIZED}="1"`). The busybox guest had no udev daemon, so
no device ever carried the property and the enumerator skipped everything.
The enumeration code itself is sysfs-based and udevd-independent — the
property gate is the blocker.

## eudev (the fix)

- `flake.nix` package `eudev = pkgs.pkgsCross.aarch64-multiplatform-musl.eudev`
  (3.2.14; buildInputs kmod + util-linux — cross-built clean).
- Rootfs: closure copy + `/usr/bin` symlinks (`udevd`, `udevadm`),
  `/etc/udev/rules.d/` seeded with eudev's stock rules (incl.
  78-sound-card.rules) + pipewire's `90-pipewire-alsa.rules` (ACP quirks),
  `udev_log=err`.
- s6 service `udev` (longrun): `udevd --daemon`, `udevadm trigger
  --action=change --subsystem-match=sound`, `udevadm settle --timeout=15`,
  milestone `udev-ready` (or `udev-empty` if the db stayed empty), park.
- `wireplumber` depends on `pipewire` + `udev` in s6-rc.

## Honest scope

- No dbus in the guest: `support.dbus`, portal-permissionstore,
  reserve-device and logind components skip themselves (expected, logged).
- QEMU target = virtio-sound card; UCM data (alsa-ucm-conf) stays excluded
  and is deferred to hardware targets.
- TCG QEMU: no performance claims (R-20).
- `pipewire-gate.sh` is superseded by `tools/wireplumber-gate.sh` (the
  old `pipewire-played` milestone disappeared with the static sink).

## Verdict

**WIREPLUMBER GATE ALL GREEN — twice** (`tools/wp-gate-run.sh` build boot:
222899 frames RMS 3089; `tools/wp-gate-rerun.sh` confirmation boot against
the same payload: 188735 frames RMS 3357).

    [ox-wp] pipewire server up (native-protocol round trip ok)
    [ox-wp] wireplumber up (session objects visible to wpctl)
    [ox-wp] client stream linked and completed (pw-play, no manual linking)
    [ox-wp] captured wav: 188735 frames @ 44100 Hz, RMS 3357   (boot 2)
    [ox-wp] wav dump non-silent — audio reached the host
    WIREPLUMBER GATE ALL GREEN

Sequence in one boot: userspace-ready → udev-ready → pipewire-up →
wireplumber-up → wp-played. The audio stack is now the real product
shape: server (lean PipeWire) + session manager (WirePlumber) + device
discovery (eudev → spa udev enum → acp profiles) + an ordinary app
stream (`pw-play`, no flags) reaching hardware-emulated audio.
