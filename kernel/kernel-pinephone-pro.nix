# Ox OS kernel for the PinePhone Pro target (RK3399).
# Chunk 72: the FIRST executed hardware-target kernel build. Same pinned
# kernel.org source as the qemu target (the verity/erofs/dm-crypt rootfs
# contract and the security posture are byte-for-byte the same policy),
# with the board block (serial, eMMC/SD, display+touch, USB/modem bus,
# PMIC/RTC) built in. Radios/camera/audio land with their own hardware
# gates (M3+); this build boots the board to the verified rootfs.
# Scope + honest limits: kernel/fragments/pinephone-pro.config is the
# .config source of truth; the artifact gate proves structure, the
# electrical bring-up (M1) proves the board.
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
  # No Ox patches here: the hwsim/mac80211 lab instrumentation is
  # virtual-radio tooling, meaningless on real silicon.
  kernelPatches = [ ];
  autoModules = false;
  # nixpkgs' common-config names options that drift across kernel versions
  # (the qemu build already paid this lesson: VIVID -> VIDEO_VIVID in 6.18);
  # tolerate stale entries rather than failing config generation.
  ignoreConfigErrors = true;
  structuredExtraConfig = with lib.kernel; {
    # supervision / scheduling (same policy as the qemu target)
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

    # storage / integrity — the verified system slot contract
    DM = lib.mkForce yes;
    BLK_DEV_DM = lib.mkForce yes;
    DM_VERITY = lib.mkForce yes;
    DM_CRYPT = lib.mkForce yes;
    EROFS_FS = lib.mkForce yes;
    EROFS_FS_XATTR = lib.mkForce yes;
    EROFS_FS_SECURITY = lib.mkForce yes;
    SQUASHFS = lib.mkForce yes;
    SQUASHFS_ZSTD = lib.mkForce yes;

    # security posture (identical policy to the qemu target)
    RANDOMIZE_BASE = lib.mkForce yes;
    HARDENED_USERCOPY = lib.mkForce yes;
    FORTIFY_SOURCE = lib.mkForce yes;
    INIT_ON_ALLOC_DEFAULT_ON = lib.mkForce yes;
    INIT_ON_FREE_DEFAULT_ON = lib.mkForce yes;
    SLAB_FREELIST_RANDOM = lib.mkForce yes;
    SLAB_FREELIST_HARDENED = lib.mkForce yes;
    SHUFFLE_PAGE_ALLOCATOR = lib.mkForce yes;
    STACKPROTECTOR_STRONG = lib.mkForce yes;
    SECURITY_LANDLOCK = lib.mkForce yes;
    SECURITY_LOCKDOWN_LSM = lib.mkForce yes;
    SECURITY_LOCKDOWN_LSM_EARLY = lib.mkForce yes;
    LOCK_DOWN_KERNEL_FORCE_NONE = lib.mkForce yes;
    SECURITY = lib.mkForce yes;
    SECURITY_YAMA = lib.mkForce yes;
    IO_URING = lib.mkForce no;
    DEVMEM = lib.mkForce no;
    COMPAT_BRK = lib.mkForce no;
    RUST = lib.mkForce no;
    PRINTK_TIME = lib.mkForce yes;

    # guest userspace plumbing
    EXPERT = lib.mkForce yes;
    DEVTMPFS = lib.mkForce yes;
    DEVTMPFS_MOUNT = lib.mkForce yes;
    TMPFS = lib.mkForce yes;
    TMPFS_POSIX_ACL = lib.mkForce yes;
    BINFMT_ELF = lib.mkForce yes;
    BINFMT_SCRIPT = lib.mkForce yes;
    CRYPTO_SHA256 = lib.mkForce yes;
    CRYPTO_AES = lib.mkForce yes;
    CRYPTO_XTS = lib.mkForce yes;
    # dm-crypt's "aes" skcipher + the arm64 bit-sliced providers must be
    # built in (the qemu target paid for this lesson — keyslot ENOENT).
    CRYPTO_AES_ARM64 = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE_BLK = lib.mkForce yes;
    CRYPTO_AES_ARM64_BS = lib.mkForce yes;

    # --- PinePhone Pro board essentials (RK3399) ---
    ARCH_ROCKCHIP = lib.mkForce yes;
    # console: rk3399 UARTs are 8250 DesignWare (ttyS2)
    SERIAL_8250 = lib.mkForce yes;
    SERIAL_8250_CONSOLE = lib.mkForce yes;
    SERIAL_8250_DW = lib.mkForce yes;
    # eMMC (sdhci-arasan) + SD/SDIO (dw_mmc-rockchip)
    MMC = lib.mkForce yes;
    MMC_BLOCK = lib.mkForce yes;
    MMC_SDHCI = lib.mkForce yes;
    MMC_SDHCI_PLTFM = lib.mkForce yes;
    MMC_SDHCI_OF_ARASAN = lib.mkForce yes;
    MMC_DW = lib.mkForce yes;
    MMC_DW_ROCKCHIP = lib.mkForce yes;
    # display: Rockchip DRM + MIPI-DSI + the XBD599 panel
    DRM = lib.mkForce yes;
    DRM_ROCKCHIP = lib.mkForce yes;
    DRM_MIPI_DSI = lib.mkForce yes;
    ROCKCHIP_DW_MIPI_DSI = lib.mkForce yes;
    DRM_PANEL = lib.mkForce yes;
    DRM_PANEL_XINGBANGDA_XBD599 = lib.mkForce yes;
    DRM_FBDEV_EMULATION = lib.mkForce yes;
    FRAMEBUFFER_CONSOLE = lib.mkForce yes;
    FONT_SUPPORT = lib.mkForce yes;
    FONT_8x16 = lib.mkForce yes;
    BACKLIGHT_CLASS_DEVICE = lib.mkForce yes;
    # touch (Goodix over I2C) + GPIO keys
    INPUT = lib.mkForce yes;
    INPUT_EVDEV = lib.mkForce yes;
    TOUCHSCREEN_GOODIX = lib.mkForce yes;
    I2C = lib.mkForce yes;
    I2C_CHARDEV = lib.mkForce yes;
    I2C_RK3X = lib.mkForce yes;
    KEYBOARD_GPIO = lib.mkForce yes;
    # USB: DWC3 + type-C (FUSB302) + the modem bus (EG25: QMI + AT serial)
    USB = lib.mkForce yes;
    USB_XHCI_HCD = lib.mkForce yes;
    USB_XHCI_PLATFORM = lib.mkForce yes;
    USB_DWC3 = lib.mkForce yes;
    USB_DWC3_OF_SIMPLE = lib.mkForce yes;
    USB_STORAGE = lib.mkForce yes;
    USB_USBNET = lib.mkForce yes;
    USB_NET_QMI_WWAN = lib.mkForce yes;
    USB_SERIAL = lib.mkForce yes;
    USB_SERIAL_OPTION = lib.mkForce yes;
    USB_NET_CDCETHER = lib.mkForce yes;
    TYPEC = lib.mkForce yes;
    # FUSB302 hangs off the Type-C Port Controller Manager: the kconfig
    # merge demotes FUSB302 if TCPM is unset and DIES on the repeated
    # question (the 2026-10-05 config-log finding) — pin the chain.
    TYPEC_TCPM = lib.mkForce yes;
    TYPEC_FUSB302 = lib.mkForce yes;
    GENERIC_PHY = lib.mkForce yes;
    PHY_ROCKCHIP_INNO_USB2 = lib.mkForce yes;
    # PMIC (RK818) + RTC (+ battery scaffolding)
    MFD_RK8XX = lib.mkForce yes;
    MFD_RK8XX_I2C = lib.mkForce yes;
    REGULATOR = lib.mkForce yes;
    REGULATOR_RK808 = lib.mkForce yes;
    RTC_CLASS = lib.mkForce yes;
    RTC_HCTOSYS = lib.mkForce yes;
    RTC_DRV_RK808 = lib.mkForce yes;
    POWER_SUPPLY = lib.mkForce yes;
    CHARGER_RK818 = lib.mkForce yes;
  };
}
