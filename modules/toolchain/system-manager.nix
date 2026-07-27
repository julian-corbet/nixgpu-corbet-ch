# modules/toolchain/system-manager.nix — the Arch/CachyOS implementation of nixgpu.toolchain.
#
# Feeds pacman package names into `nixarch.packages.pacman`, which is nixarch's own reconciler --
# this module declares WHAT, nixarch's mechanism installs it. Import alongside
# nixarch.systemManagerModules.packages; without it the list is computed and nothing acts on it.
#
# The names below are the genuinely hard part, and they are not guessable from the NixOS ones:
# ROCm is split across three separate Arch packages where nixpkgs has one attribute set, and the
# NVIDIA userspace driver (`nvidia-utils`) is a different package from the CUDA toolkit. Getting
# this wrong is a multi-gigabyte mistake in either direction.
{ lib, config, ... }:
let
  cfg = config.nixgpu.toolchain;

  # Per-vendor, split by what each part is FOR, so `sdk = false` and `monitoring = false` can each
  # drop their share without leaving a machine that cannot talk to its own card.
  vendors = {
    nvidia = {
      runtime = [ "nvidia-utils" ];
      sdk = [ "cuda" "cudnn" ];
      monitoring = [ "nvidia-settings" ];
    };
    amd = {
      # No runtime entry: the amdgpu kernel driver ships with the kernel and Mesa provides the
      # userspace, so an AMD card works for compute-adjacent work with nothing installed here.
      # Only the ROCm SDK is a real, separate, very large install.
      runtime = [ ];
      sdk = [ "rocm-hip-sdk" "rocm-opencl-sdk" ];
      monitoring = [ "rocm-smi-lib" ];
    };
    intel = {
      runtime = [ "intel-compute-runtime" ];
      sdk = [ "intel-oneapi-basekit" ];
      monitoring = [ "intel-gpu-tools" ];
    };
  };

  v = if cfg.vendor == null then null else vendors.${cfg.vendor};
in
{
  config = lib.mkIf (cfg.enable && v != null) {
    nixarch.packages.pacman =
      v.runtime
      ++ lib.optionals cfg.sdk v.sdk
      ++ lib.optionals cfg.monitoring v.monitoring
      ++ cfg.extraPackages;
  };
}
