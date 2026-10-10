{
  description = "Ox OS — sovereign Linux mobile operating system (hermetic build)";

  inputs = {
    # Pinned by rev: the branch moved under us mid-build once (pipewire
    # 1.2.7 -> 1.6.8 changed the dependency graph between two evals).
    nixpkgs.url = "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674";
    # Prebuilt rustup-style toolchains. nixpkgs' own rustPlatform compiles
    # LLVM and rustc from source — no binary-cache substitutes exist for this
    # channel (every llvm-18.1.8 output 404s on cache.nixos.org), so a
    # guest-daemons build turns into a multi-hour dependency chain.
    # rust-bin downloads the exact 1.82.0 toolchain rust-toolchain.toml pins
    # as prebuilt binaries, so both build paths now pin the same rustc.
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    { self, nixpkgs, rust-overlay }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      # crates.io 403s default-UA fetchers; static.crates.io serves the same
      # tarballs without UA filtering — rewrite at the fetchurl layer.
      crateMirror = final: prev: {
        fetchurl = args: if builtins.isAttrs args && args ? url then
          prev.fetchurl (args // {
            url = builtins.replaceStrings
              [ "https://crates.io/api/v1/crates" ]
              [ "https://static.crates.io/crates" ]
              args.url;
          })
        else
          prev.fetchurl args;
      };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (sys:
        f (import nixpkgs {
          system = sys;
          overlays = [ rust-overlay.overlays.default crateMirror ];
        }));
    in
    {
      packages = forAllSystems (pkgs:
        let
          # Pure-Nix vendoring of the registry deps from Cargo.lock — no
          # nixpkgs cargo anywhere in the closure (that is what drags in
          # the from-source LLVM/rustc chain). Shared by the guest
          # cross-build and the host-side workspace test run.
          cargoVendorDir = pkgs.rustPlatform.importCargoLock {
            lockFile = ./rust/Cargo.lock;
          };
        in {
        # The executed hermetic build: guest Rust daemons cross-compiled to
        # static aarch64 musl, sandboxed, from the committed Cargo.lock.
        # Mirrors tools/build-oxcom.sh: cargo with the toolchain's own
        # rust-lld (the musl target's default linker is the host cc, which
        # cannot link aarch64 CRT objects).
        guest-daemons =
          let
            target = "aarch64-unknown-linux-musl";
            toolchain = pkgs.rust-bin.stable."1.82.0".minimal.override {
              targets = [ target ];
            };
            hostTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;
            src = pkgs.lib.cleanSource ./rust;
          in
          pkgs.stdenv.mkDerivation {
            pname = "ox-guest-daemons";
            version = "0.1.0";

            inherit src cargoVendorDir;

            nativeBuildInputs = [ toolchain ];

            buildPhase = ''
              # Overriding the buildPhase attr skips the default preBuild
              # hook, so the environment setup lives here.
              export CARGO_HOME=$PWD/.cargo-home
              mkdir -p "$CARGO_HOME"
              cat > "$CARGO_HOME/config.toml" <<CFG
              [source.crates-io]
              replace-with = "vendored-sources"
              [source.vendored-sources]
              directory = "${cargoVendorDir}"
              CFG

              RUSTLLD="${toolchain}/lib/rustlib/${hostTriple}/bin/rust-lld"
              test -x "$RUSTLLD" || { echo "rust-lld missing at $RUSTLLD" >&2; exit 3; }
              export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$RUSTLLD"
              export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C linker-flavor=ld.lld"
              export CARGO_TARGET_DIR=$PWD/target

              echo "CARGO_HOME=$CARGO_HOME"
              echo "vendor: $(ls "$cargoVendorDir" | head -3 | tr '\n' ' ')"
              cargo build --release --locked --offline --target ${target} -p oxcom --features gui
              cargo build --release --locked --offline --target ${target} \
                -p oxpaymentsd -p ox-status -p inputd -p powerd -p oxctl -p oxmodemd -p oxnetd -p oxresourced -p oxthermald -p ox-shell -p notifd -p permstored -p ox-intentd -p ox-settings -p ox-files -p ox-term -p ox-hello -p oxpkg -p ox-lockd -p ox-contactsd -p ox-locationd -p ox-messagesd -p oxwifid -p ox-btair -p ox-gnssd -p ox-camerad -p ox-camera -p ox-dialer -p ox-sms -p ox-nfcd -p ox-usbd
            '';

            installPhase = ''
              mkdir -p $out/bin
              for b in oxcom oxpaymentsd ox-status inputd powerd oxctl oxmodemd oxnetd oxresourced oxthermald ox-shell notifd permstored ox-intentd ox-settings ox-files ox-term ox-hello oxpkg ox-lockd ox-contactsd ox-locationd ox-messagesd oxwifid ox-btair ox-gnssd ox-camerad ox-camera ox-dialer ox-sms ox-nfcd ox-usbd; do
                cp "target/${target}/release/$b" $out/bin/
              done
            '';

            meta = with pkgs.lib; {
              description = "Ox OS guest daemons (oxcom, oxpaymentsd, ox-status, inputd, powerd)";
              platforms = systems;
            };
          };

        # Workspace unit tests on the HOST toolchain, sandboxed and
        # offline from the same vendored deps. The guest cross-build
        # compiles but never RUNS tests — this is the gate that makes
        # unit tests (UI hit-mapping, store invariants, manifest
        # validation) actually count. Run via tools/test-gate.sh.
        workspace-test =
          let
            toolchain = pkgs.rust-bin.stable."1.82.0".minimal;
          in
          pkgs.stdenv.mkDerivation {
            name = "ox-workspace-test";
            src = pkgs.lib.cleanSource ./rust;
            inherit cargoVendorDir;
            nativeBuildInputs = [ toolchain ];
            phases = [ "unpackPhase" "buildPhase" "installPhase" ];
            buildPhase = ''
              export CARGO_HOME=$PWD/.cargo-home
              mkdir -p "$CARGO_HOME"
              cat > "$CARGO_HOME/config.toml" <<CFG
              [source.crates-io]
              replace-with = "vendored-sources"
              [source.vendored-sources]
              directory = "${cargoVendorDir}"
              CFG
              cargo test --release --locked --offline --workspace
            '';
            installPhase = ''
              echo "workspace tests passed" > $out
            '';
          };

        # Structured mirrors of the image pipeline (placeholders pending their
        # first executed run).
        kernel-qemu = pkgs.callPackage ./kernel/kernel.nix { };

        # Chunk 72: the PinePhone Pro target — the FIRST executed
        # hardware-target build (kernel + U-Boot + signed FIT + slot images,
        # all host-verified by tools/target-pinephone-gate.sh).
        kernel-pinephone-pro = pkgs.callPackage ./kernel/kernel-pinephone-pro.nix { };
        # RK3399 U-Boot from the PinebookPro package (the same RK3399
        # U-Boot source in this pin) with the pinephone-pro defconfig.
        # TF-A for rk3399 carries Rockchip's binary blob -> license
        # unfreeRedistributable; scoped allowUnfree for exactly that
        # package (documented deviation, R-24: redistribution permitted,
        # provenance Rockchip; every mainline rk3399 boot includes it).
        uboot-pinephone-pro =
          let
            upkgs = import nixpkgs {
              system = pkgs.system;
              config.allowUnfreePredicate = p:
                (p.pname or "") == "arm-trusted-firmware-rk3399";
            };
          in
          # rk3399 U-Boot + its TF-A are written for an aarch64-compiler
          # stdenv (CROSS_COMPILE empty, meta.platforms = aarch64-linux):
          # take the PinebookPro package — the same RK3399 U-Boot source —
          # from the aarch64-multiplatform CROSS set, where plain gcc IS
          # the aarch64 cross-compiler, with the pinephone-pro defconfig.
          upkgs.pkgsCross.aarch64-multiplatform.ubootPinebookPro.override {
            defconfig = "pinephone-pro-rk3399_defconfig";
          };
        image-pinephone-pro = pkgs.callPackage ./targets/pinephone-pro/image.nix {
          kernel-pinephone-pro = self.packages.${pkgs.system}.kernel-pinephone-pro;
          uboot-pinephone-pro = self.packages.${pkgs.system}.uboot-pinephone-pro;
          payload-qemu = self.packages.${pkgs.system}.payload-qemu;
        };

        # Chunk 73: the Fairphone 5 target — second executed hardware
        # build, first on the Android chain (ABL + AVB under the user
        # key; BRINGUP.md primary target).
        kernel-fairphone5 = pkgs.callPackage ./kernel/kernel-fairphone5.nix { };
        image-fairphone5 = pkgs.callPackage ./targets/fairphone5/image.nix {
          kernel-fairphone5 = self.packages.${pkgs.system}.kernel-fairphone5;
          payload-qemu = self.packages.${pkgs.system}.payload-qemu;
        };

        # Chunk 75: the OnePlus Android-chain targets — third/fourth
        # executed hardware builds (shared qcom boot-essentials kernel;
        # the display/radio scope lands with its own hardware gates).
        kernel-oneplus9rt = pkgs.callPackage ./kernel/kernel-oneplus-qcom.nix { soc = "sm8350"; };
        kernel-oneplus10pro = pkgs.callPackage ./kernel/kernel-oneplus-qcom.nix { soc = "sm8450"; };
        image-oneplus9rt = pkgs.callPackage ./targets/oneplus9rt-sm8350/image.nix {
          kernel-oneplus9rt = self.packages.${pkgs.system}.kernel-oneplus9rt;
          payload-qemu = self.packages.${pkgs.system}.payload-qemu;
        };
        image-oneplus10pro = pkgs.callPackage ./targets/oneplus10pro-sm8450/image.nix {
          kernel-oneplus10pro = self.packages.${pkgs.system}.kernel-oneplus10pro;
          payload-qemu = self.packages.${pkgs.system}.payload-qemu;
        };

        wifi-modules = pkgs.runCommand "ox-wifi-modules" {
          kout = self.packages.${pkgs.system}.kernel-qemu;
          kdev = self.packages.${pkgs.system}.kernel-qemu.dev;
        } ''
          mkdir -p $out
          # kernel modules ship xz-compressed; busybox insmod needs raw
          for base in $kout $kdev; do
            find $base -name "*.ko.xz" -o -name "*.ko" 2>/dev/null
          done | grep -E "/(cfg80211|mac80211|mac80211_hwsim|rfkill)[.]ko" | sort -u | while read -r f; do
            case "$f" in
              *.xz) xz -dc "$f" > "$out/$(basename "$f" .xz)" ;;
              *) cp "$f" "$out/$(basename "$f")" ;;
            esac
          done
        '';

        # Bluetooth counterpart of wifi-modules: BT core + virtual-HCI
        # driver, xz-decompressed for busybox insmod. Dependency
        # closure is static (modinfo-verified): bluetooth depends on
        # ecdh_generic + rfkill; hci_vhci depends on bluetooth;
        # ecdh_generic on ecc (shipped only if the kernel built it =m).
        bt-modules = pkgs.runCommand "ox-bt-modules" {
          kout = self.packages.${pkgs.system}.kernel-qemu;
          kdev = self.packages.${pkgs.system}.kernel-qemu.dev;
        } ''
          mkdir -p $out
          for base in $kout $kdev; do
            find $base -name "*.ko.xz" -o -name "*.ko" 2>/dev/null
          done > all.txt
          for n in bluetooth hci_vhci ecdh_generic ecc; do
            f=$(grep -E "/$n[.]ko" all.txt | head -1 || true)
            if [ -n "$f" ]; then
              case "$f" in
                *.xz) xz -dc "$f" > "$out/$n.ko" ;;
                *) cp "$f" "$out/$n.ko" ;;
              esac
            fi
          done
          ls -la $out
        '';

        # camera kernel modules: the V4L2 stack + vivid (the virtual
        # sensor). Same xz-decompress + static-list shape as bt-modules.
        camera-modules = pkgs.runCommand "ox-camera-modules" {
          kout = self.packages.${pkgs.system}.kernel-qemu;
          kdev = self.packages.${pkgs.system}.kernel-qemu.dev;
        } ''
          mkdir -p $out
          for base in $kout $kdev; do
            find $base -name "*.ko.xz" -o -name "*.ko" 2>/dev/null
          done > all.txt
          for n in mc videobuf2-common videobuf2-memops videobuf2-vmalloc videobuf2-dma-contig videobuf2-v4l2 videodev v4l2-dv-timings cec v4l2-tpg vivid; do
            f=$(grep -E "/$n[.]ko" all.txt | head -1 || true)
            if [ -n "$f" ]; then
              case "$f" in
                *.xz) xz -dc "$f" > "$out/$n.ko" ;;
                *) cp "$f" "$out/$n.ko" ;;
              esac
            fi
          done
          ls -la $out
        '';

        # BlueZ userspace for the guest with the btvirt emulator built in.
        # Upstream gates btvirt behind --enable-testing and marks it
        # noinst, so we install that one binary on top of the regular
        # tools (btmgmt, hcitool ship in bin already).
        bluez-bt = (pkgs.pkgsCross.aarch64-multiplatform-musl.bluez.override {
          # installTests pulls gobject-introspection + the whole cairo
          # stack; we only need the tools and the btvirt emulator
          installTests = false;
        }).overrideAttrs (old: {
          patches = (old.patches or []) ++ [ ./system/btvirt-vhci-retry.patch ];
          configureFlags = old.configureFlags ++ [ "--enable-testing" ];
          postInstall = (old.postInstall or "") + ''
            cp emulator/btvirt $out/bin/btvirt
          '';
        });


        # Guest-side primitives, exposed for debugging and rootfs composition.
        busybox-aarch64 = pkgs.callPackage ./system/busybox-guest.nix { };
        s6-stack = pkgs.callPackage ./system/s6-stack.nix { };
        bt-probe = pkgs.callPackage ./system/bt-probe.nix { };

        # Lean audio-only PipeWire, cross-built to dynamic musl aarch64.
        # Uses a second pinned nixpkgs (the rev the verified build used);
        # 55-path closure ~15-20 MiB, designed for store-path-preserving
        # copy into the guest rootfs.
        pipewire-lean = pkgs.callPackage ./tools/pipewire-lean.nix {
          nixpkgsPin = (import nixpkgs { system = "x86_64-linux"; });
        };

        # Session manager on top of pipewire-lean: stream<->sink linking
        # and dynamic ALSA device discovery. Same store-preserving-copy
        # deployment as pipewire-lean.
        wireplumber-lean = pkgs.callPackage ./tools/wireplumber-lean.nix {
          nixpkgsPin = (import nixpkgs { system = "x86_64-linux"; });
        };

        # udev daemon for the guest: monitor.alsa's enumerator skips any
        # sound device without the udev-set ENV SOUND_INITIALIZED
        # (alsa-udev.c get_card_nr); only a udev daemon applying
        # 78-sound-card.rules can set it.
        eudev = pkgs.pkgsCross.aarch64-multiplatform-musl.eudev;

        # Static aarch64 openssl: the guest-side package-signature
        # verifier (same primitive the host keytool uses; no pip, no
        # new Rust crypto deps).
        openssl-aarch64 = pkgs.pkgsCross.aarch64-multiplatform-musl.openssl;

        # Structured mirrors of the image pipeline.
        rootfs-qemu = pkgs.callPackage ./system/rootfs.nix {
          oxBusybox = pkgs.callPackage ./system/busybox-guest.nix { };
          s6Stack = pkgs.callPackage ./system/s6-stack.nix { };
          guestDaemons = self.packages.${pkgs.system}.guest-daemons;
          sndTest = pkgs.callPackage ./system/snd-test.nix { };
          btProbe = pkgs.callPackage ./system/bt-probe.nix { };
          pipewireLean = self.packages.${pkgs.system}.pipewire-lean;
          pipewireClosure = pkgs.closureInfo {
            rootPaths = [ self.packages.${pkgs.system}.pipewire-lean ];
          };
          wireplumberLean = self.packages.${pkgs.system}.wireplumber-lean;
          wireplumberClosure = pkgs.closureInfo {
            rootPaths = [ self.packages.${pkgs.system}.wireplumber-lean ];
          };
          eudev = self.packages.${pkgs.system}.eudev;
          eudevClosure = pkgs.closureInfo {
            rootPaths = [ self.packages.${pkgs.system}.eudev ];
          };
          opensslAarch64 = self.packages.${pkgs.system}.openssl-aarch64;
          opensslClosure = pkgs.closureInfo {
            rootPaths = [ self.packages.${pkgs.system}.openssl-aarch64.bin ];
          };
          wifiModules = self.packages.${pkgs.system}.wifi-modules;
          wpaSupplicant = pkgs.pkgsCross.aarch64-multiplatform-musl.wpa_supplicant;
          wpaClosure = pkgs.closureInfo {
            rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.wpa_supplicant ];
          };
          hostapd = pkgs.pkgsCross.aarch64-multiplatform-musl.hostapd;
          hostapdClosure = pkgs.closureInfo {
            rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.hostapd ];
          };
          iw = pkgs.pkgsCross.aarch64-multiplatform-musl.iw;
          iwClosure = pkgs.closureInfo {
            rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.iw ];
          };
          btModules = self.packages.${pkgs.system}.bt-modules;
          cameraModules = self.packages.${pkgs.system}.camera-modules;
          bluez = self.packages.${pkgs.system}.bluez-bt;
          bluezClosure = pkgs.closureInfo {
            rootPaths = [ self.packages.${pkgs.system}.bluez-bt ];
          };
          workspaceTest = self.packages.${pkgs.system}.workspace-test;
        };

        payload-qemu = pkgs.callPackage ./targets/qemu-virt-aarch64/payload.nix {
          rootfs = pkgs.callPackage ./system/rootfs.nix {
            oxBusybox = pkgs.callPackage ./system/busybox-guest.nix { };
            s6Stack = pkgs.callPackage ./system/s6-stack.nix { };
            guestDaemons = self.packages.${pkgs.system}.guest-daemons;
            sndTest = pkgs.callPackage ./system/snd-test.nix { };
          btProbe = pkgs.callPackage ./system/bt-probe.nix { };
            pipewireLean = self.packages.${pkgs.system}.pipewire-lean;
            pipewireClosure = pkgs.closureInfo {
              rootPaths = [ self.packages.${pkgs.system}.pipewire-lean ];
            };
            wireplumberLean = self.packages.${pkgs.system}.wireplumber-lean;
            wireplumberClosure = pkgs.closureInfo {
              rootPaths = [ self.packages.${pkgs.system}.wireplumber-lean ];
            };
            eudev = self.packages.${pkgs.system}.eudev;
            eudevClosure = pkgs.closureInfo {
              rootPaths = [ self.packages.${pkgs.system}.eudev ];
            };
            opensslAarch64 = self.packages.${pkgs.system}.openssl-aarch64;
            opensslClosure = pkgs.closureInfo {
              rootPaths = [ self.packages.${pkgs.system}.openssl-aarch64.bin ];
            };
            wifiModules = self.packages.${pkgs.system}.wifi-modules;
            wpaSupplicant = pkgs.pkgsCross.aarch64-multiplatform-musl.wpa_supplicant;
            wpaClosure = pkgs.closureInfo {
              rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.wpa_supplicant ];
            };
            hostapd = pkgs.pkgsCross.aarch64-multiplatform-musl.hostapd;
            hostapdClosure = pkgs.closureInfo {
              rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.hostapd ];
            };
            iw = pkgs.pkgsCross.aarch64-multiplatform-musl.iw;
            iwClosure = pkgs.closureInfo {
              rootPaths = [ pkgs.pkgsCross.aarch64-multiplatform-musl.iw ];
            };
            btModules = self.packages.${pkgs.system}.bt-modules;
            cameraModules = self.packages.${pkgs.system}.camera-modules;
            bluez = self.packages.${pkgs.system}.bluez-bt;
            bluezClosure = pkgs.closureInfo {
              rootPaths = [ self.packages.${pkgs.system}.bluez-bt ];
            };
            workspaceTest = self.packages.${pkgs.system}.workspace-test;
          };
          kernel = pkgs.callPackage ./kernel/kernel.nix { };
        };
      });

      # CI entry point: `nix flake check` runs the workspace unit-test
      # suite (and evaluates every other output for errors).
      checks = forAllSystems (pkgs: {
        workspace-tests = self.packages.${pkgs.system}.workspace-test;
      });

      apps = forAllSystems (pkgs: {
        qemu.type = "app";
        qemu.program = "${self.packages.${pkgs.system}.payload-qemu}/bin/run-qemu";
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            erofs-utils
            cryptsetup
            openssl
            python3
            busybox
            s6
            s6-rc
            execline
            qemu
            shellcheck
          ];
        };
      });
    };
}
