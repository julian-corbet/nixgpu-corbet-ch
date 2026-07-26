# stable-device-paths — vendor-keyed /dev/dri symlinks, so device-tokens' `paths` never has to
# hardcode a numbered /dev/dri/cardN again.
#
# WHY: DRM minor numbers are enumeration-order-dependent, not vendor-dependent (see device-tokens'
# own `paths` option doc). A BMC/IPMI virtual VGA adapter frequently claims card0, pushing the real
# GPU to card1 or higher -- and that ordering is not guaranteed stable across a kernel update, a
# firmware update, or even boot-to-boot under an async-probe kernel. Root-caused live 2026-07-24 on
# a production single-GPU cluster during a crash investigation: a hardcoded `/dev/dri/card1` is a
# latent correctness landmine (silent at apply time, only surfaces as "the wrong adapter got
# exposed to workloads"), not a portable fact about the hardware.
#
# THE FIX: a udev rule that creates a symlink keyed by PCI vendor ID instead of enumeration index --
# `/dev/dri/by-vendor/<name>-card` / `-render` always resolve to whichever card/render node is
# actually backed by that vendor's silicon, however the kernel happened to number it this boot. A
# `mount --bind` / `stat()` on a symlink resolves to the real device it points at, so both the
# device-plugin's cgroup rule and its bind-mount end up correct automatically -- nothing downstream
# needs to change once `paths` points at the symlink instead of the numbered node.
{ lib, config, ... }:
let
  cfg = config.nixgpu.stableDevicePaths;
in
{
  options.nixgpu.stableDevicePaths = {
    enable = lib.mkEnableOption "vendor-keyed /dev/dri/by-vendor symlinks (card + render), so device-tokens paths survive a DRM re-enumeration";

    vendors = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { amd = "0x1002"; };
      example = { amd = "0x1002"; nvidia = "0x10de"; };
      description = ''
        Map of symlink-name-prefix -> PCI vendor ID, exactly as it reads in
        `/sys/class/drm/cardN/device/vendor`. One symlink pair is generated
        per entry: `/dev/dri/by-vendor/<name>-card` and `-render`. Default
        covers AMD only, matching nixgpu's ROCm/AMD scope -- add entries here
        if a fleet ever needs to pin a different vendor's node by the same
        mechanism (e.g. a second GPU of a different make in the same box).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.udev.extraRules = lib.concatStrings (lib.mapAttrsToList (name: vendor: ''
      SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-card"
      SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-render"
    '') cfg.vendors);
  };
}
