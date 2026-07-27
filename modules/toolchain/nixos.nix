# modules/toolchain/nixos.nix — the NixOS implementation of nixgpu.toolchain.
#
# Sibling to system-manager.nix, and deliberately a separate real implementation rather than a
# shared list with a name-mapping table: the two platforms disagree about more than spelling.
# ROCm is three packages on Arch and one attribute set here; NVIDIA's userspace driver is a
# package on Arch but a HARDWARE option here (hardware.nvidia, driven by
# hardware.graphics/services.xserver), which is not something a package list can express at all.
#
# So this module installs the compute SDK and monitoring tools, and deliberately does NOT try to
# own driver enablement. Declaring `hardware.nvidia.*` from here would fight the host's own
# hardware configuration and silently override choices (open vs proprietary kernel module, power
# management, PRIME offload) that belong to whoever knows the machine. The module says so rather
# than guessing.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixgpu.toolchain;

  vendors = {
    nvidia = {
      sdk = with pkgs; [ cudatoolkit cudaPackages.cudnn ];
      monitoring = with pkgs; [ nvtopPackages.nvidia ];
    };
    amd = {
      sdk = with pkgs; [ rocmPackages.clr rocmPackages.rocm-runtime ];
      monitoring = with pkgs; [ rocmPackages.rocm-smi nvtopPackages.amd ];
    };
    intel = {
      sdk = with pkgs; [ intel-compute-runtime ];
      monitoring = with pkgs; [ intel-gpu-tools nvtopPackages.intel ];
    };
  };

  v = if cfg.vendor == null then null else vendors.${cfg.vendor};
in
{
  config = lib.mkIf (cfg.enable && v != null) {
    environment.systemPackages =
      lib.optionals cfg.sdk v.sdk
      ++ lib.optionals cfg.monitoring v.monitoring
      ++ map (p: pkgs.${p}) cfg.extraPackages;

    # Driver enablement is NOT set here -- see the header. A host wanting the proprietary NVIDIA
    # stack still declares hardware.nvidia itself; this module only adds the compute layer on top.
    warnings = lib.optional (cfg.vendor == "nvidia" && !(config.hardware.nvidia.modesetting.enable or false)) ''
      nixgpu.toolchain.vendor = "nvidia" installs the CUDA toolchain, but this host does not appear
      to enable the NVIDIA driver (hardware.nvidia.*). The toolkit will install and CUDA will find
      no device at runtime. This module deliberately does not configure hardware.nvidia -- driver
      choice (open vs proprietary, power management, PRIME) belongs to the host.
    '';
  };
}
