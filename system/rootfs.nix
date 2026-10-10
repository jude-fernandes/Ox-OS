# Ox OS guest rootfs tree for the QEMU virt-aarch64 target, assembled
# hermetically: Nix-built static busybox + s6 stack + the five guest Rust
# daemons, with ox-init-stage2 and the s6-rc service sources from the repo.
# Output contract mirrors tools/dev-pipeline.sh (bin/, sbin/, usr/bin/,
# etc/s6-rc/{source,compiled}).
{
  lib,
  stdenv,
  pkgs,
  oxBusybox,
  s6Stack,
  guestDaemons,
  sndTest,
  btProbe,
  pipewireLean,
  pipewireClosure,
  wireplumberLean,
  wireplumberClosure,
  eudev,
  eudevClosure,
  opensslAarch64,
  opensslClosure,
  wpaSupplicant,
  wpaClosure,
  hostapd,
  hostapdClosure,
  iw,
  iwClosure,
  wifiModules,
  btModules,
  cameraModules,
  bluez,
  bluezClosure,
  workspaceTest,
}:
stdenv.mkDerivation {
  pname = "ox-rootfs-qemu";
  version = "0.1.0-phase1";

  src = lib.cleanSource ./..; # flake root (ox/)

  # Host busybox is referenced by direct path (NOT buildInputs — putting it
  # on PATH shadows stdenv's find/coreutils hooks with busybox applets).
  buildInputs = [ ];

  phases = [ "unpackPhase" "buildPhase" "installPhase" "fixupPhase" ];

  # The rootfs is GUEST content: nothing here may be rewritten for the
  # build host. Without this, fixup patches `#!/bin/sh` shebangs to the
  # Nix store bash — which does not exist inside the image.
  dontFixup = true;

  buildPhase = ''
    # Unit tests gate the payload: the workspace suite must have passed
    # (this reference forces nix to build workspace-test first — a test
    # failure fails the rootfs, the payload, and every gate run).
    test -f ${workspaceTest}
    export PATH=${pkgs.python3}/bin:${pkgs.openssl}/bin:$PATH
    ROOTFS=$TMPDIR/rootfs
    mkdir -p $ROOTFS/bin $ROOTFS/sbin $ROOTFS/usr/bin $ROOTFS/usr/libexec \
             $ROOTFS/etc $ROOTFS/data $ROOTFS/dev $ROOTFS/proc $ROOTFS/sys \
             $ROOTFS/run $ROOTFS/tmp $ROOTFS/newroot
    chmod 1777 $ROOTFS/tmp

    # --- static busybox + applet links (applet list from the host busybox,
    #     same trick dev-pipeline.sh uses since aarch64 binaries cannot run
    #     on the build host) ---
    cp ${oxBusybox}/bin/busybox $ROOTFS/bin/busybox
    for applet in $(${pkgs.busybox}/bin/busybox --list); do
        [ "$applet" = busybox ] && continue
        ln -sf busybox $ROOTFS/bin/$applet
    done
    [ -L $ROOTFS/bin/sh ] && [ -e $ROOTFS/bin/sh ] \
        || { echo "ERROR: bin/sh applet link missing" >&2; exit 4; }

    # --- s6 stack (static aarch64, prefix baked as /usr) ---
    for f in ${s6Stack}/bin/*; do
        cp -L "$f" $ROOTFS/usr/bin/$(basename "$f")
    done
    [ -x $ROOTFS/usr/bin/s6-svscan ] || { echo "ERROR: s6-svscan missing" >&2; exit 4; }
    if [ -d ${s6Stack}/libexec ]; then
        cp -L ${s6Stack}/libexec/* $ROOTFS/usr/libexec/ 2>/dev/null || true
    fi

    # --- stage-2 init ---
    cp $src/system/sbin/ox-init-stage2 $ROOTFS/sbin/ox-init-stage2
    chmod +x $ROOTFS/sbin/ox-init-stage2
    cp $src/system/sbin/pw-debug-probe $ROOTFS/usr/bin/pw-debug-probe
    chmod +x $ROOTFS/usr/bin/pw-debug-probe
    # dev target: passwordless root login on the serial console so gates
    # can drive an interactive shell (no passwd -> busybox login denies).
    printf 'root::0:0:root:/:/bin/sh\n' > $ROOTFS/etc/passwd

    # --- guest Rust daemons (Nix-built static aarch64) ---
    for b in oxcom oxpaymentsd ox-status inputd powerd oxctl oxmodemd oxnetd oxresourced oxthermald ox-shell notifd permstored ox-intentd ox-settings ox-files ox-term ox-hello oxpkg ox-lockd ox-contactsd ox-locationd ox-messagesd oxwifid ox-btair ox-gnssd ox-camerad ox-camera ox-dialer ox-sms ox-nfcd ox-usbd; do
        cp ${guestDaemons}/bin/$b $ROOTFS/usr/bin/$b
        chmod +x $ROOTFS/usr/bin/$b
    done

    # --- staged .oxp packages (package-gate payload) ---
    # hello.oxp: a valid package (manifest + app binary) installed by
    # the pkg selftest at boot; broken.oxp: deliberately invalid, the
    # selftest requires intentd to refuse it.
    mkdir -p $ROOTFS/usr/share/ox/packages/hello.oxp $ROOTFS/usr/share/ox/packages/broken.oxp
    cp ${guestDaemons}/bin/ox-hello $ROOTFS/usr/share/ox/packages/hello.oxp/ox-hello
    chmod +x $ROOTFS/usr/share/ox/packages/hello.oxp/ox-hello
    printf '{"name":"Hello","bin":"ox-hello","version":"0.1.0","permissions":["post-notification"]}\n' \
        > $ROOTFS/usr/share/ox/packages/hello.oxp/manifest.json
    printf 'this is not a manifest\n' > $ROOTFS/usr/share/ox/packages/broken.oxp/junk.txt
    # --- package signing (dev key; ed25519 is deterministic, so the
    #     build stays bit-reproducible) ---
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/hello.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/hello.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/hello.oxp/manifest.sig
    # evil.oxp: structurally valid manifest carrying hello's signature
    # -> intentd MUST refuse it (signature does not match manifest)
    mkdir -p $ROOTFS/usr/share/ox/packages/evil.oxp
    printf '{"name":"Evil","bin":"ox-hello","version":"9.9.9"}\n' \
        > $ROOTFS/usr/share/ox/packages/evil.oxp/manifest.json
    cp $ROOTFS/usr/share/ox/packages/hello.oxp/manifest.sig \
        $ROOTFS/usr/share/ox/packages/evil.oxp/manifest.sig
    # impersonation.oxp (chunk 69): a VALIDLY SIGNED package declaring
    # bin=ox-settings — its spawned process's comm would impersonate a
    # system identity (chunk 68 made the comm the permission identity).
    # intentd MUST refuse it at install: reserved bin.
    mkdir -p $ROOTFS/usr/share/ox/packages/impersonation.oxp
    printf '{"name":"Imposter","bin":"ox-settings","version":"0.1.0","permissions":["contacts.read"]}\n' \
        > $ROOTFS/usr/share/ox/packages/impersonation.oxp/manifest.json
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/impersonation.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/impersonation.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/impersonation.oxp/manifest.sig
    # grid.oxp: a second valid package (name Gridtest, empty permission
    # set) installed AFTER unlock by the grid selftest — the shell must
    # refresh the home grid from the pkgs-changed event within ~2s, not
    # on the 5s poll fallback.
    mkdir -p $ROOTFS/usr/share/ox/packages/grid.oxp
    cp ${guestDaemons}/bin/ox-hello $ROOTFS/usr/share/ox/packages/grid.oxp/ox-hello
    chmod +x $ROOTFS/usr/share/ox/packages/grid.oxp/ox-hello
    printf '{"name":"Gridtest","bin":"ox-hello","version":"0.1.0","permissions":[]}\n' \
        > $ROOTFS/usr/share/ox/packages/grid.oxp/manifest.json
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/grid.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/grid.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/grid.oxp/manifest.sig
    # camera.oxp: the Camera app as a signed package — the dynamic-tile
    # flow installs it (camera-app selftest), the manifest binds
    # camera.read as deny, the user grant enables the viewfinder.
    mkdir -p $ROOTFS/usr/share/ox/packages/camera.oxp
    cp ${guestDaemons}/bin/ox-camera $ROOTFS/usr/share/ox/packages/camera.oxp/ox-camera
    chmod +x $ROOTFS/usr/share/ox/packages/camera.oxp/ox-camera
    printf '{"name":"Camera","bin":"ox-camera","version":"0.1.0","permissions":["camera.read"]}\n' \
        > $ROOTFS/usr/share/ox/packages/camera.oxp/manifest.json
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/camera.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/camera.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/camera.oxp/manifest.sig
    # dialer.oxp: the Dialer app as a signed package — manifest binds
    # telephony.dial as deny on install; the user grant enables real
    # dialing through oxmodemd (fake mode never touches the radio).
    mkdir -p $ROOTFS/usr/share/ox/packages/dialer.oxp
    cp ${guestDaemons}/bin/ox-dialer $ROOTFS/usr/share/ox/packages/dialer.oxp/ox-dialer
    chmod +x $ROOTFS/usr/share/ox/packages/dialer.oxp/ox-dialer
    printf '{"name":"Dialer","bin":"ox-dialer","version":"0.1.0","permissions":["telephony.dial"]}\n' \
        > $ROOTFS/usr/share/ox/packages/dialer.oxp/manifest.json
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/dialer.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/dialer.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/dialer.oxp/manifest.sig
    # sms.oxp: the Messaging app as a signed package — manifest binds
    # telephony.sms as deny on install; the user grant enables real
    # sends through oxmodemd (fake mode never touches the radio).
    mkdir -p $ROOTFS/usr/share/ox/packages/sms.oxp
    cp ${guestDaemons}/bin/ox-sms $ROOTFS/usr/share/ox/packages/sms.oxp/ox-sms
    chmod +x $ROOTFS/usr/share/ox/packages/sms.oxp/ox-sms
    printf '{"name":"Messaging","bin":"ox-sms","version":"0.1.0","permissions":["telephony.sms"]}\n' \
        > $ROOTFS/usr/share/ox/packages/sms.oxp/manifest.json
    python3 $src/tools/ox-keytool.py sign \
        --key $src/tools/dev-keys/package.pem \
        --file $ROOTFS/usr/share/ox/packages/sms.oxp/manifest.json \
        --out $ROOTFS/usr/share/ox/packages/sms.oxp/manifest.sig
    chmod 644 $ROOTFS/usr/share/ox/packages/sms.oxp/manifest.sig
    # the pinned package public key (verified against at install time)
    mkdir -p $ROOTFS/etc/ox
    cp $src/tools/dev-keys/package.pub $ROOTFS/etc/ox/packages.pub.pem
    # --- guest openssl (signature verifier): dynamically linked, so
    #     copy its WHOLE store closure preserving /nix/store paths (the
    #     pipewire pattern) — the binary's RPATH then resolves in-guest.
    #     NOTE: this block runs before the pipewire block creates
    #     $ROOTFS/nix/store, so create it here.
    mkdir -p $ROOTFS/nix/store
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${opensslClosure}/store-paths
    ln -sf ${opensslAarch64}/bin/openssl $ROOTFS/usr/bin/openssl

    # --- Phase-4 Wi-Fi: the REAL userspace wireless stack on the
    # virtual hwsim radios. wpa_supplicant (client) associates with a
    # hostapd AP over WPA2-PSK entirely inside the VM; both are dynamic
    # musl builds, so their store closures ship like pipewire's.
    mkdir -p $ROOTFS/nix/store
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${wpaClosure}/store-paths
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${hostapdClosure}/store-paths
    mkdir -p $ROOTFS/usr/bin
    for f in ${wpaSupplicant}/bin/*; do
        ln -sf "$f" $ROOTFS/usr/bin/$(basename "$f")
    done
    ln -sf ${hostapd}/bin/hostapd $ROOTFS/usr/bin/hostapd
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${iwClosure}/store-paths
    ln -sf ${iw}/bin/iw $ROOTFS/usr/bin/iw
    # the virtual AP (dev PSK, plaintext on the AP side by design —
    # the CLIENT side carries no factory credentials: joining is the
    # permission-checked oxwifid connect op)
    mkdir -p $ROOTFS/etc
    cat > $ROOTFS/etc/hostapd.conf <<'HAP'
interface=wlan1
driver=nl80211
ssid=ox-virt-ap
# channel 1 = 2412 MHz = hwsim radio0's DEFAULT channel — the client's
# channel context at boot. Auth on a mismatched channel needs a
# remain-on-channel window whose response under TCG load regularly
# misses the client ("authentication timed out"); on-channel auth is
# deterministic. Verified: ch1 association completed the full 4-way
# handshake (802.1X authorizing port) where ch6 timed out.
channel=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
wpa_passphrase=oxdevpass1
HAP
    cat > $ROOTFS/etc/wpa_supplicant.conf <<'WSC'
ctrl_interface=/run/wpa_ctrl
ap_scan=1
WSC
    # wireless kernel modules (insmod order: rfkill, cfg80211,
    # mac80211, mac80211_hwsim — see the wifi selftest)
    mkdir -p $ROOTFS/lib/modules
    for f in ${wifiModules}/*.ko; do
        cp "$f" $ROOTFS/lib/modules/ || exit 1
    done

    # --- Phase-4 Bluetooth: the REAL userspace on the virtual
    # controller. btvirt emulates two dual-mode radios (its virtual PHY
    # carries advertising between them); btmgmt drives the kernel mgmt
    # API, hcitool drives raw LE commands. Dynamic musl builds, so the
    # store closure ships like wpa_supplicant's.
    mkdir -p $ROOTFS/nix/store
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${bluezClosure}/store-paths
    for f in btmgmt btvirt hcitool hciconfig; do
        ln -sf ${bluez}/bin/$f $ROOTFS/usr/bin/$f
    done
    # bluetooth kernel modules (insmod order: rfkill, crc16, ecc,
    # ecdh_generic, bluetooth, hci_vhci — see the bt selftest)
    for f in ${btModules}/*.ko; do
        cp "$f" $ROOTFS/lib/modules/ || exit 1
    done

    # camera kernel modules (insmod order per vivid's modules.dep:
    # mc, videobuf2-common, memops, vmalloc, dma-contig, videobuf2-v4l2,
    # videodev, v4l2-dv-timings, cec, v4l2-tpg, vivid — see the camera
    # selftest)
    for f in ${cameraModules}/*.ko; do
        cp "$f" $ROOTFS/lib/modules/ || exit 1
    done

    # --- audio selftest player (static aarch64 C, see system/snd-test) ---
    cp ${sndTest}/bin/ox-snd-test $ROOTFS/usr/bin/ox-snd-test
    chmod +x $ROOTFS/usr/bin/ox-snd-test
    # --- bluetooth vhci attach probe (static aarch64 C, see bt-probe) ---
    cp ${btProbe}/bin/ox-bt-probe $ROOTFS/usr/bin/ox-bt-probe
    chmod +x $ROOTFS/usr/bin/ox-bt-probe
    # test tone for the pipewire playback gate (1 s, 440 Hz, 48 kHz mono)
    mkdir -p $ROOTFS/usr/share/ox
    cp $src/system/tone.wav $ROOTFS/usr/share/ox/tone.wav

    # --- PipeWire (dynamic aarch64) ---
    # First dynamically-linked guest component: copy the WHOLE runtime
    # closure preserving /nix/store paths so the ELF interpreter and every
    # DT_NEEDED entry resolve in-guest. The path list comes from
    # closureInfo (exportReferencesGraph), computed by the host nix.
    # alsa-ucm-conf is excluded: UCM data is per-device audio config
    # (useless on the QEMU card) and its "Librem 5.conf" filename with a
    # space breaks the payload's squashfs sort file.
    mkdir -p $ROOTFS/nix/store
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in *alsa-ucm-conf*) continue ;; esac
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${pipewireClosure}/store-paths
    # bin/ symlinks for humans and service scripts.
    mkdir -p $ROOTFS/usr/bin
    for f in ${pipewireLean}/bin/*; do
        ln -sf "$f" $ROOTFS/usr/bin/$(basename "$f")
    done
    # dlopen'd plugins are NOT part of the nix runtime closure (nothing
    # links them), so copy the module/SPA/share trees wholesale on top of
    # the closure copy — same store path inside the rootfs.
    PWDIR="$(ls -d $ROOTFS/nix/store/*pipewire-aarch64* | head -1)"
    chmod -R u+w "$PWDIR"
    cp -a ${pipewireLean}/lib/pipewire-0.3 "$PWDIR/lib/"
    cp -a ${pipewireLean}/lib/spa-0.2 "$PWDIR/lib/"
    cp -a ${pipewireLean}/share "$PWDIR/" 2>/dev/null || true
    # pw-play (client) resolves its config through /etc/pipewire; pw-cli
    # tolerates its absence but pw-play exited silently without it.
    mkdir -p $ROOTFS/etc/pipewire
    cp ${pipewireLean}/share/pipewire/client.conf $ROOTFS/etc/pipewire/
# No static ALSA sink in pipewire.conf.d: WirePlumber (below) owns
# device discovery and node creation now (monitor.alsa ->
# api.alsa.enum.udev, whose libudev dependency survived the lean
# filter -- see tools/wp-inspect4.sh evidence). A static node would
# race the monitor for the same PCM device.

    # --- WirePlumber (dynamic aarch64): the session manager. Same
    # store-preserving closure copy as pipewire; its closure re-mentions
    # pipewire paths already copied above and those merge harmlessly.
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in *alsa-ucm-conf*) continue ;; esac
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${wireplumberClosure}/store-paths
    for f in ${wireplumberLean}/bin/*; do
        ln -sf "$f" $ROOTFS/usr/bin/$(basename "$f")
    done
    # Insurance for dlopen-by-soname and Lua-script lookup: merge the
    # module + share trees onto the store copy (no-op when the closure
    # copy already contains them).
    WPDIR="$(ls -d $ROOTFS/nix/store/*wireplumber-aarch64* | head -1)"
    chmod -R u+w "$WPDIR"
    cp -a ${wireplumberLean}/lib/wireplumber-0.5 "$WPDIR/lib/" 2>/dev/null || true
    cp -a ${wireplumberLean}/share "$WPDIR/" 2>/dev/null || true

    # --- eudev (dynamic aarch64): the udev daemon. monitor.alsa's
    # enumerator skips every sound device without the udev-set ENV
    # SOUND_INITIALIZED (alsa-udev.c get_card_nr); only a udev daemon
    # applying rules can set it. Static closure copy + bin symlinks.
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in *alsa-ucm-conf*) continue ;; esac
        cp -r "$p" $ROOTFS/nix/store/ 2>/dev/null || true
    done < ${eudevClosure}/store-paths
    for d in bin sbin; do
        [ -d ${eudev}/$d ] || continue
        for f in ${eudev}/$d/*; do
            ln -sf "$f" $ROOTFS/usr/bin/$(basename "$f")
        done
    done
    # Rules dirs the daemon reads at runtime; 78-sound-card.rules (ships
    # with eudev) sets SOUND_INITIALIZED, 90-pipewire-alsa.rules (ships
    # with the lean pipewire) adds ACP quirks.
    mkdir -p $ROOTFS/etc/udev/rules.d $ROOTFS/run/udev $ROOTFS/var/lib/udev
    if [ -d ${eudev}/var/lib/udev/rules.d ]; then
        cp ${eudev}/var/lib/udev/rules.d/* $ROOTFS/etc/udev/rules.d/ 2>/dev/null || true
    fi
    cp ${pipewireLean}/lib/udev/rules.d/90-pipewire-alsa.rules $ROOTFS/etc/udev/rules.d/ 2>/dev/null || true
    # udev.conf: keep the kernel uevent socket path default; make the
    # children log to the console only on error.
    printf 'udev_log=err\n' > $ROOTFS/etc/udev/udev.conf

    # --- s6-rc service database (host compile of repo sources) ---
    # Compile from a scratch copy OUTSIDE the rootfs: s6-rc-compile makes
    # its source tree read-only in place, which would break the final
    # placement of the compiled DB.
    mkdir -p $TMPDIR/s6src
    cp -r $src/system/s6-rc-source/. $TMPDIR/s6src/
    ${s6Stack.hostTools}/bin/s6-rc-compile $TMPDIR/compiled.new $TMPDIR/s6src
    mkdir -p $ROOTFS/etc/s6-rc
    mv $TMPDIR/compiled.new $ROOTFS/etc/s6-rc/compiled
    mkdir -p $ROOTFS/etc/s6-rc/source
    cp -r $src/system/s6-rc-source/. $ROOTFS/etc/s6-rc/source/
  '';

  installPhase = ''
    # /build is a tmpfs while the store is not — mv would fall back to
    # copy+delete and choke on the read-only tree; copy instead.
    mkdir -p $out
    cp -a $TMPDIR/rootfs/. $out/
  '';

  passthru.initPath = "/sbin/ox-init-stage2";
}
