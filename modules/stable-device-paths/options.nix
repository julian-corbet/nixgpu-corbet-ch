# stable-device-paths — vendor-keyed /dev/dri symlinks, so a consumer never has to hardcode a
# numbered /dev/dri/cardN again.
#
# WHY: DRM minor numbers are enumeration-order-dependent, not vendor-dependent. A BMC/IPMI virtual
# VGA adapter frequently claims card0, pushing the real GPU to card1 or higher -- and that ordering
# is not guaranteed stable across a kernel update, a firmware update, or boot-to-boot under an
# async-probe kernel. Root-caused live 2026-07-24 on a production single-GPU cluster, then hit for
# real on 2026-07-29 when a DisplayLink dock's `evdi` module took card1 and moved an RX 6800 to
# card2 -- while a device-plugin was still binding a hardcoded /dev/dri/card1 into GPU pods.
#
# THE FIX: a udev rule keyed on PCI vendor ID instead of enumeration index.
# `/dev/dri/by-vendor/<name>-card` / `-render` always resolve to whichever node is actually backed
# by that vendor's silicon. A `mount --bind` / `stat()` on a symlink resolves to the real device, so
# both a device-plugin's cgroup rule and its bind-mount end up correct with nothing else changed.
#
# It also excludes virtual display devices for free: `evdi` is a PLATFORM device with no `vendor`
# attribute at all, so a vendor-keyed rule can never match it. Verified on real hardware.
#
# Options only -- the NixOS and system-manager planes each consume `rules` in their own way. Both
# planes exist because a GPU host is not necessarily a NixOS host: an Arch/CachyOS laptop with one
# real card hits the identical renumbering hazard the moment a dock is plugged in.
{ lib, config, ... }:
let
  cfg = config.nixgpu.stableDevicePaths;
in
{
  options.nixgpu.stableDevicePaths = {
    enable = lib.mkEnableOption "vendor-keyed /dev/dri/by-vendor symlinks (card + render), so device paths survive a DRM re-enumeration";

    vendors = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { amd = "0x1002"; };
      example = {
        amd = "0x1002";
        nvidia = "0x10de";
        intel = "0x8086";
      };
      description = ''
        Map of symlink-name-prefix -> PCI vendor ID, exactly as it reads in
        `/sys/class/drm/cardN/device/vendor`. One symlink pair is generated per
        entry: `/dev/dri/by-vendor/<name>-card` and `-render`. The default covers
        AMD only, matching nixgpu's ROCm/AMD scope -- add entries for a different
        make (an Intel laptop iGPU, a second card of another vendor in one box).
      '';
    };

    rules = lib.mkOption {
      type = lib.types.lines;
      internal = true;
      readOnly = true;
      description = ''
        The generated udev rules, consumed by whichever host plane is imported.
        Exposed as an option rather than recomputed per plane so both planes are
        guaranteed to emit byte-identical rules.
      '';
    };
  };

  config.nixgpu.stableDevicePaths.rules =
    lib.concatStrings (lib.mapAttrsToList (name: vendor: ''
      SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-card"
      SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-render"
    '') cfg.vendors);
}
