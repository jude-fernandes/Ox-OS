# Ox OS kernel for the Fairphone 5 target (QCM6490 / SM7325 family).
# Chunk 73: the second executed hardware-target build, and the first on
# the Android boot chain (ABL + AVB). Same pinned kernel.org 6.18.48
# source, byte-identical storage/security policy; the board block adds
# the Qualcomm platform essentials (GENI console, UFS storage,
# DRM/MSI display, DWC3-QCOM USB, QRTR scaffold). NOTE: this is the
# MAINLINE kernel (postmarketOS path), not a GKI android-common build —
# the boot-image v4 container is GKI-shaped; GKI conformance itself is
# M1 on-device. Radios/camera/audio land with their own hardware gates.
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
  kernelPatches = [ ];
  autoModules = false;
  ignoreConfigErrors = true;
  structuredExtraConfig = with lib.kernel; {
    # supervision / scheduling (same policy as the other targets)
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

    # security posture (identical policy to the other targets)
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
    CRYPTO_AES_ARM64 = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE = lib.mkForce yes;
    CRYPTO_AES_ARM64_CE_BLK = lib.mkForce yes;
    CRYPTO_AES_ARM64_BS = lib.mkForce yes;

    # --- Fairphone 5 board essentials (QCM6490) ---
    ARCH_QCOM = lib.mkForce yes;
    # console: Qualcomm GENI UART (ttyMSM0)
    SERIAL_QCOM_GENI = lib.mkForce yes;
    SERIAL_QCOM_GENI_CONSOLE = lib.mkForce yes;
    # storage: UFS on the Qualcomm controller
    SCSI = lib.mkForce yes;
    BLK_DEV_SD = lib.mkForce yes;
    SCSI_UFSHCD = lib.mkForce yes;
    SCSI_UFSHCD_PLATFORM = lib.mkForce yes;
    SCSI_UFS_QCOM = lib.mkForce yes;
    # display: deliberately OUT of the chunk-73 build. MSM DRM selects a
    # closure that sits =m in the arm64 defconfig, and the interactive
    # merge rejects forcing them =y (the documented cfg80211 class in
    # kernel/kernel.nix) — shipping a per-target DRM module closure is
    # M1 scope, when the panel stack can be validated against the actual
    # device. The FP5 boot contract is the GENI serial console.
    FRAMEBUFFER_CONSOLE = lib.mkForce no;
    # input + I2C (touch controller lands with its M-gate)
    INPUT = lib.mkForce yes;
    INPUT_EVDEV = lib.mkForce yes;
    I2C = lib.mkForce yes;
    I2C_QCOM_GENI = lib.mkForce yes;
    # USB: DWC3 on the Qualcomm glue + PMIC type-C
    USB = lib.mkForce yes;
    USB_XHCI_HCD = lib.mkForce yes;
    USB_XHCI_PLATFORM = lib.mkForce yes;
    USB_DWC3 = lib.mkForce yes;
    USB_DWC3_QCOM = lib.mkForce yes;
    USB_STORAGE = lib.mkForce yes;
    TYPEC = lib.mkForce yes;
    # TYPEC_QCOM_PMIC deliberately out: same =m-capped class (its PMIC
    # glue deps sit =m in the defconfig) — type-C role switching is M1
    # hardware scope, the boot contract does not need it.
    # the integrated modem speaks QRTR/MHI: the transport scaffold only —
    # the radio policy stack is the M3+ radio gates' scope
    QRTR = lib.mkForce yes;
    # PMIC (pmk8350/pmr735a) + RTC
    RTC_CLASS = lib.mkForce yes;
    RTC_HCTOSYS = lib.mkForce yes;
    RTC_DRV_PM8XXX = lib.mkForce yes;
    REGULATOR = lib.mkForce yes;
    POWER_SUPPLY = lib.mkForce yes;
  };
}
