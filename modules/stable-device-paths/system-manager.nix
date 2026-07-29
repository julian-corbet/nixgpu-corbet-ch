# Arch/CachyOS plane: system-manager has no `services.udev`, so write the rules file directly.
# udev reads /etc/udev/rules.d, so an `environment.etc` entry is the whole mechanism.
#
# After a first apply the rules are not retroactive -- existing device nodes keep the symlinks they
# already have (or lack). Either replug the device or run:
#   udevadm control --reload-rules && udevadm trigger --subsystem-match=drm
{ lib, config, ... }:
let
  cfg = config.nixgpu.stableDevicePaths;
in
{
  config = lib.mkIf cfg.enable {
    environment.etc."udev/rules.d/70-nixgpu-by-vendor.rules".text = cfg.rules;
  };
}
