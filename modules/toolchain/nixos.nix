# modules/toolchain/nixos.nix — the NixOS implementation of nixgpu.toolchain.
#
# Sibling to system-manager.nix, and deliberately a separate real implementation rather than a
# shared list with a name-mapping table: the two platforms disagree about more than spelling.
# ROCm is three packages on Arch and one attribute set here; NVIDIA's userspace driver is a
# package on Arch but a HARDWARE option here (hardware.nvidia, driven by
# hardware.graphics/services.xserver), which is not something a package list can express at all.
#
# So this module installs the vendor's baseline runtime plus every resolved capability package,
# and deliberately does NOT try to own driver enablement. Declaring `hardware.nvidia.*` from here
# would fight the host's own hardware configuration and silently override choices (open vs
# proprietary kernel module, power management, PRIME offload) that belong to whoever knows the
# machine. The module says so rather than guessing.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixgpu.toolchain;

  # The vendor's baseline runtime -- installed UNCONDITIONALLY whenever `enable && vendor != null`,
  # regardless of which capabilities (if any) are selected, because every capability presupposes
  # the card works at all. AMD needs nothing extra here: the in-kernel amdgpu driver plus Mesa's
  # own userspace already cover it. Unchanged from this module's first version.
  runtimeBaseline = {
    amd = [ ];
    intel = with pkgs; [ intel-compute-runtime ];
    nvidia = with pkgs; [ nvidia-utils ];
  };

  runtime = if cfg.vendor == null then [ ] else runtimeBaseline.${cfg.vendor} or [ ];

  path = name: lib.splitString "." name;
  resolves = name: lib.hasAttrByPath (path name) pkgs;
  missing = lib.filter (n: !(resolves n)) cfg.packageNames;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixgpu.toolchain: ${toString (builtins.length missing)} nixpkgs package(s) do not exist
          in this nixpkgs: ${lib.concatStringsSep ", " missing}.

          This is a catalogue problem, not a host problem -- see ../../lib/catalogue.nix. Fix the
          catalogue so every host gets the correction, rather than pinning an older nixpkgs.
        '';
      }
    ];

    environment.systemPackages =
      runtime
      ++ map (n: lib.getAttrFromPath (path n) pkgs) cfg.packageNames
      ++ map (n: pkgs.${n}) cfg.extraPackages;

    # `gaming32` is the one capability with no per-package nixpkgs answer AT ALL (see
    # ../../lib/catalogue.nix's own `nixosOption` note on that entry): the real equivalent is this
    # single vendor-neutral option, which makes `hardware.graphics` (and, for the proprietary
    # stack, `hardware.nvidia`) install the 32-bit variant of whichever driver it already resolved.
    # Every OTHER capability resolves through the ordinary `packageNames` list above; this is the
    # one deliberate exception, not a pattern to extend casually -- see docs/module-layout.md in
    # the infra repo for the same "package list on Arch, real option on NixOS" split, documented
    # there for nixdesktop's own portals/gvfs roles.
    hardware.graphics.enable32Bit = lib.mkIf cfg.capabilities.gaming32.enable true;

    # Driver enablement is NOT set here -- see the header. A host wanting the proprietary NVIDIA
    # stack still declares hardware.nvidia itself; this module only adds the compute layer on top.
    #
    # `services.xserver.videoDrivers` is the real signal, not `hardware.nvidia.modesetting.enable`
    # (this module's first version checked that instead -- LIVE-CONFIRMED BROKEN against this
    # repo's own pinned nixpkgs: `modesetting.enable` now defaults to `true` unconditionally,
    # whether or not the NVIDIA driver is ever actually selected, so the old check could never
    # fire; caught by ../../checks/toolchain.nix's `nixos/nvidia-without-hardware-nvidia-warns`).
    # `videoDrivers` containing `"nvidia"` is the actual, canonical way a NixOS host turns the
    # driver on.
    warnings = lib.optional (cfg.vendor == "nvidia" && !(lib.elem "nvidia" (config.services.xserver.videoDrivers or [ ]))) ''
      nixgpu.toolchain.vendor = "nvidia" installs the CUDA/NVIDIA toolchain, but this host does not
      appear to enable the NVIDIA driver (services.xserver.videoDrivers does not contain "nvidia").
      The toolkit will install and CUDA will find no device at runtime. This module deliberately
      does not configure hardware.nvidia -- driver choice (open vs proprietary, power management,
      PRIME) belongs to the host.
    '';
  };
}
