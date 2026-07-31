# modules/evdi/nixos.nix — the NixOS implementation of nixgpu.evdi.
#
# Three statements, and each closes one of the three ways this fails silently (see
# options.nix's header for the measured detail behind each):
#
#   1. build the module against THIS kernel   -- boot.extraModulePackages
#   2. load it at boot                        -- boot.kernelModules
#   3. tell it to create devices              -- boot.extraModprobeConfig
#
# Miss (3) and the other two still succeed: the module loads, `lsmod` shows it, and there is no
# DRM node anywhere, because `initial_device_count` defaults to 0.
{ lib, config, ... }:
let
  cfg = config.nixgpu.evdi;

  # `boot.kernelPackages.evdi` and not a top-level `pkgs.evdi`: an out-of-tree module must be built
  # against the exact kernel that will load it, and `boot.kernelPackages` is the only attribute set
  # that tracks the host's actual choice of kernel. Overridable via `package` for the clang-built
  # kernel case documented on that option.
  evdiPackage = if cfg.package != null then cfg.package else config.boot.kernelPackages.evdi;
in
{
  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [ evdiPackage ];
    boot.kernelModules = [ "evdi" ];

    # `types.lines`, so this CONCATENATES with whatever else the host has to say to modprobe
    # (a ZFS ARC bound, an audio quirk) rather than conflicting with it.
    #
    # Written as a modprobe option rather than passed on the kernel command line because evdi is a
    # module and not built in: the parameter has to be present when modprobe loads it, including
    # when something loads it on demand later, and a command-line `evdi.initial_device_count=` only
    # applies to a built-in.
    boot.extraModprobeConfig = ''
      options evdi initial_device_count=${toString cfg.deviceCount}
    '';
  };
}
