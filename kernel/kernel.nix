# Ox OS kernel for the QEMU virt-aarch64 target.
# Cross-built by Nix from the SAME pinned kernel.org source the manual
# pipeline uses (tools/build-kernel.sh verified 6.18.48 against
# kernel.org's sha256sums.asc; that hash is pinned here), with the Ox
# structured config fragments applied on top of the arm64 defconfig.
{
  lib,
  pkgs,
}:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  ver = "6.18.48";
  sha256 = "5ebdadb10a4b5708fc6b1c457764a110bc49f8150cc3502c59b921ead8c6fc8c";
in
cross.buildLinux {
  version = ver;
  modDirVersion = ver;
  src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${ver}.tar.xz";
    inherit sha256;
  };
  # R-23 experiment (kept for the next session, see
  # reports/2026-09-01-luks-data-volume.md): dropping dm-crypt's
  # ALLOCATES_MEMORY mask makes the lookup return a NULL alg (guest panic)
  # instead of ENOENT — the registered xts(aes) is invisible to the lookup
  # itself. Disabled until that is live-debugged in the guest.
  # Ox dev (chunk 52/53): hwsim unicast-delivery instrumentation — logs
  # WHY each unicast frame is skipped per radio (idle / channel miss),
  # and now also every unicast TX entering the delivery loop.
  # Enabled at runtime via /sys/module/mac80211_hwsim/parameters/ox_debug_unicast.
  # Ox dev (chunk 53): the diagnostic run proved the residual "auth
  # timed out" race is a TIMING loss, not a frame drop: hostapd logs
  # the auth reply while the client's fixed 200ms mac80211 auth window
  # closes during concurrent boot-selftest stalls (resourced drill
  # drop_caches under TCG). The second patch makes the six
  # auth/assoc response timeouts module params (defaults unchanged);
  # lab boots raise them via the kernel cmdline.
  kernelPatches = [
    { name = "ox-hwsim-debug"; patch = ./ox-hwsim-debug.patch; }
    { name = "ox-mac80211-lab-timing"; patch = ./ox-mac80211-lab-timing.patch; }
  ];
  autoModules = false;
  # nixpkgs' common-config names options that drift across kernel versions
  # (e.g. XFS_* renamed in 6.18); tolerate the stale entries rather than
  # failing the whole config generation on them.
  ignoreConfigErrors = true;
  structuredExtraConfig = with lib.kernel; {
    # supervision / scheduling
    PREEMPT_DYNAMIC = lib.mkForce yes;
    NO_HZ_IDLE = lib.mkForce yes;
    HIGH_RES_TIMERS = lib.mkForce yes;
    SCHED_AUTOGROUP = lib.mkForce yes;

    # cgroups + memory
    CGROUPS = lib.mkForce yes;
    CGROUP_FREEZER = lib.mkForce yes;
    CGROUP_DEVICE = lib.mkForce yes;
    CGROUP_CPUACCT = lib.mkForce yes;
    CGROUP_PIDS = lib.mkForce yes;
    MEMCG = lib.mkForce yes;
    PSI = lib.mkForce yes;

    LRU_GEN = lib.mkForce yes;
    LRU_GEN_ENABLED = lib.mkForce yes;
    ZRAM = lib.mkForce yes;
    ZSMALLOC = lib.mkForce yes;

    # storage / integrity
    DM = lib.mkForce yes;
    BLK_DEV_DM = lib.mkForce yes;
    DM_VERITY = lib.mkForce yes;
    DM_CRYPT = lib.mkForce yes;
    EROFS_FS = lib.mkForce yes;
    SQUASHFS = lib.mkForce yes;
    SQUASHFS_ZSTD = lib.mkForce yes;
    BTRFS_FS = lib.mkForce yes;

    # security posture (ADR-005/security-architecture)
    RANDOMIZE_BASE = lib.mkForce yes;    HARDENED_USERCOPY = lib.mkForce yes;
    FORTIFY_SOURCE = lib.mkForce yes;
    INIT_ON_ALLOC_DEFAULT_ON = lib.mkForce yes;
    INIT_ON_FREE_DEFAULT_ON = lib.mkForce yes;
    SLAB_FREELIST_RANDOM = lib.mkForce yes;
    SLAB_FREELIST_HARDENED = lib.mkForce yes;
    SHUFFLE_PAGE_ALLOCATOR = lib.mkForce yes;
    STACKPROTECTOR_STRONG = lib.mkForce yes;
    SECURITY_LANDLOCK = lib.mkForce yes;
    SECURITY_LOCKDOWN_LSM = lib.mkForce yes;
    IO_URING = lib.mkForce no;
    DEVMEM = lib.mkForce no;
    COMPAT_BRK = lib.mkForce no;

    # No Rust drivers in Phase 1: nixpkgs turns RUST on by default, which
    # drags in rust-bindgen -> clang -> a from-source LLVM chain with no
    # binary-cache substitutes for this channel pin.
    RUST = lib.mkForce no;

    # WP-7 groundwork
    ANDROID_BINDER_IPC = lib.mkForce yes;
    ANDROID_BINDERFS = lib.mkForce yes;

    # QEMU virt target hardware (mirrors kernel/fragments/qemu-virt-aarch64.config)
    ARCH_VEXPRESS = lib.mkForce yes;
    PCI = lib.mkForce yes;
    PCI_HOST_GENERIC = lib.mkForce yes;
    VIRTIO_MENU = lib.mkForce yes;
    VIRTIO_PCI = lib.mkForce yes;
    VIRTIO_BLK = lib.mkForce yes;
    VIRTIO_MMIO = lib.mkForce yes;
    VIRTIO_NET = lib.mkForce yes;
    VIRTIO_INPUT = lib.mkForce yes; # virtio-keyboard / virtio-tablet
    # virtio-serial = the virtual target's "modem slot": an AT/QMI chardev
    # piped to a host-side modem emulator (real radio never exists on the
    # virtual target). VIRTIO_CONSOLE=y so /dev/vport* exists without
    # modules (none are shipped).
    VIRTIO_CONSOLE = lib.mkForce yes;
    SERIAL_AMBA_PL011 = lib.mkForce yes;
    SERIAL_AMBA_PL011_CONSOLE = lib.mkForce yes;
    RTC_CLASS = lib.mkForce yes;
    RTC_DRV_PL031 = lib.mkForce yes;
    CPU_IDLE = lib.mkForce yes;
    ARM_PSCI_CPUIDLE = lib.mkForce yes;

    # compositor display chain (DRM/virtio-gpu + fbcon)
    DRM = lib.mkForce yes;
    DRM_VIRTIO_GPU = lib.mkForce yes;
    DRM_FBDEV_EMULATION = lib.mkForce yes;
    FRAMEBUFFER_CONSOLE = lib.mkForce yes;
    FONT_SUPPORT = lib.mkForce yes;
    FONT_8x16 = lib.mkForce yes;

    # guest userspace plumbing (base-mobile fragment)
    EXPERT = lib.mkForce yes;
    DEVTMPFS = lib.mkForce yes;
    DEVTMPFS_MOUNT = lib.mkForce yes;
    TMPFS = lib.mkForce yes;
    TMPFS_POSIX_ACL = lib.mkForce yes;
    BLK_CGROUP = lib.mkForce yes;
    CFS_BANDWIDTH = lib.mkForce yes;
    SCHED_MC = lib.mkForce yes;
    ENERGY_MODEL = lib.mkForce yes;
    ZRAM_WRITEBACK = lib.mkForce no;
    PSI_DEFAULT_DISABLED = lib.mkForce no;
    EROFS_FS_XATTR = lib.mkForce yes;
    EROFS_FS_SECURITY = lib.mkForce yes;
    SQUASHFS_FILE_DIRECT = lib.mkForce yes;
    CRYPTO_SHA256 = lib.mkForce yes;
    CRYPTO_AES = lib.mkForce yes;
    CRYPTO_XTS = lib.mkForce yes;
    # dm-crypt allocates "xts(aes)" — an skcipher named "aes". The generic
    # AES is cipher-type only and the arm64 BS provider defaults to a module
    # the initramfs cannot load, so both must be built in or the keyslot
    # table load fails with ENOENT.
    CRYPTO_AES_ARM64 = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE_BLK = lib.mkForce yes;
    CRYPTO_AES_ARM64_BS = lib.mkForce yes;
    BINFMT_ELF = lib.mkForce yes;
    BINFMT_SCRIPT = lib.mkForce yes;
    SECURITY = lib.mkForce yes;
    SECURITY_YAMA = lib.mkForce yes;
    SECURITY_LOCKDOWN_LSM_EARLY = lib.mkForce yes;
    LOCK_DOWN_KERNEL_FORCE_NONE = lib.mkForce yes;
    PRINTK_TIME = lib.mkForce yes;
    DYNAMIC_DEBUG = lib.mkForce no;
    VFAT_FS = lib.mkForce no;

    # audio: virtio-sound device + ALSA core + OSS emulation (/dev/dsp) so a
    # tiny static player can exercise the path without libasound
    SOUND = lib.mkForce yes;
    SND = lib.mkForce yes;
    SND_TIMER = lib.mkForce yes;
    SND_PCM = lib.mkForce yes;
    SND_VIRTIO = lib.mkForce yes;
    SND_OSSEMUL = lib.mkForce yes;
    SND_PCM_OSS = lib.mkForce yes;

    # Phase-4 Wi-Fi: the REAL wireless stack (cfg80211 + mac80211) with
    # mac80211_hwsim as the virtual radio — two in-guest wlan interfaces
    # (boot cmdline: mac80211_hwsim.radios=2) so wpa_supplicant can
    # associate over WPA2 to a hostapd AP entirely inside the VM. The
    # userspace (wpa_supplicant/hostapd) is identical to what real
    # hardware runs; only the radio is virtual. Built as MODULES (the
    # config merge cannot force =y: cfg80211 selects symbols that are
    # =m in the base config, and the interactive merge rejects the
    # upgrade mid-flight); the four .ko files ship in the rootfs and
    # the wifi selftest insmods them in dependency order.
    CFG80211 = lib.mkForce module;
    MAC80211 = lib.mkForce module;
    MAC80211_HWSIM = lib.mkForce module;
    # 802.11 link crypto (CCMP/GCMP) through the kernel crypto API —
    # built in, since crypto modules are not shipped. ARC4 is required
    # by mac80211's TKIP code path (symbol-referenced at module load).
    CRYPTO_CCM = lib.mkForce yes;
    CRYPTO_GCM = lib.mkForce yes;
    CRYPTO_CTR = lib.mkForce yes;
    CRYPTO_GHASH = lib.mkForce yes;
    CRYPTO_MICHAEL_MIC = lib.mkForce yes;
    CRYPTO_ARC4 = lib.mkForce yes;

    # Phase-4 Bluetooth: BT core + the virtual-HCI host-side driver.
    # Same split as Wi-Fi — real kernel stack, virtual radio — except
    # the CONTROLLER itself is userspace here: bluez's btvirt emulator
    # attaches to /dev/vhci (created by hci_vhci) and emulates the
    # radios; its virtual PHY (UDP loopback) carries advertising
    # between controllers, so two local radios really see each other.
    # Modules for the same kconfig-merge reason as cfg80211; the bt
    # selftest insmods rfkill -> bluetooth -> hci_vhci.
    BT = lib.mkForce module;
    BT_HCIVHCI = lib.mkForce module;
    # bluez's btvirt emulates controller crypto (btdev LE paths) through
    # the kernel AF_ALG user API: ecb(aes) + cmac(aes) skciphers. The
    # dev config lacks USER_API_SKCIPHER entirely — btvirt then fails
    # every btdev_create and no radio survives. Built in (=y): the
    # boot selftest suspend makes late module loads racy anyway.
    CRYPTO_USER_API = lib.mkForce yes;
    CRYPTO_USER_API_SKCIPHER = lib.mkForce yes;
    CRYPTO_CMAC = lib.mkForce yes;

    # Phase-4 Camera: the REAL V4L2 stack with vivid as the virtual
    # sensor — the userspace capture path (open, format, read) is
    # identical to real hardware; only the sensor is a test pattern.
    # Modules for the same kconfig-merge reason as cfg80211/BT; the
    # camera selftest insmods them in dependency order (vivid needs
    # FONT_8x16, already built in above, for its OSD).
    MEDIA_SUPPORT = lib.mkForce module;
    MEDIA_CAMERA_SUPPORT = lib.mkForce yes;
    MEDIA_TEST_SUPPORT = lib.mkForce yes;
    VIDEO_DEV = lib.mkForce module;
    # the test-driver menu gates default to N; without them VIDEO_VIVID
    # is unreachable and silently dropped
    V4L_TEST_DRIVERS = lib.mkForce yes;
    # 6.18 renamed the media driver symbols (VIVID -> VIDEO_VIVID as part
    # of the media kconfig rework — the old name is silently dropped by
    # ignoreConfigErrors, so the rename cost one kernel rebuild)
    VIDEO_VIVID = lib.mkForce module;
    VIDEOBUF2_CORE = lib.mkForce module;
    VIDEOBUF2_VMALLOC = lib.mkForce module;
    VIDEOBUF2_DMA_CONTIG = lib.mkForce module;
    VIDEO_V4L2_TPG = lib.mkForce module;

    # NOTE: modules stay enabled in the Nix build — nixpkgs' common config
    # sets many drivers to `=m`, which is unanswerable under MODULES=no and
    # kills the interactive config generator. Everything the boot needs
    # (virtio, PL011, dm-verity, squashfs) is `=y` above; module closures
    # for wifi/bt/camera are shipped explicitly by their derivations.
  };
}
