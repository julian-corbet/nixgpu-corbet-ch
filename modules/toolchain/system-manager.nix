# modules/toolchain/system-manager.nix — the Arch/CachyOS implementation of nixgpu.toolchain.
#
# Feeds pacman/AUR package names into `nixarch.packages.pacman`/`.aur`, which is nixarch's own
# reconciler -- this module declares WHAT, nixarch's mechanism installs it. Import alongside
# nixarch.systemManagerModules.packages; without it the lists are computed and nothing acts on them.
#
# THE HARD INVARIANT: this backend NEVER touches `pkgs`, structurally, not just empirically.
# Every selected entry with an Arch/AUR name goes to `nixarch.packages.{pacman,aur}`; entries with
# none (`nixgpu.toolchain.unavailableOnArch`, published read-only by ./options.nix) are surfaced
# for visibility and installed from NOWHERE here -- deliberately UNLIKE the sibling nixfs's own
# arch.nix, which does fall back to nixpkgs for its own `unavailableOnArch` list. That fallback is
# correct for nixfs (a genuine "Arch has nothing at all" gap) but would be WRONG here: this
# catalogue's nixpkgs-only entries exist because nixpkgs has no combined-bundle equivalent to an
# AUR package that already covers the same ground on Arch by a different name -- `compute`'s
# `intel` cell resolves to the AUR `intel-oneapi-basekit-2025` (which `Provides: intel-oneapi-mkl,
# intel-oneapi-dnnl, ...`, live-confirmed) PLUS two nixpkgs-only entries (`mkl`, `oneDNN`) that
# exist purely so a NixOS host -- which has no such bundle to reach for -- still gets those
# runtime libraries. Falling back to nixpkgs for those same two entries HERE would install a
# second, redundant copy of functionality the AUR package already provides under Arch's own
# packaging, on a plane where nixfs's PATH-precedence argument does not even apply (these are
# libraries an application links against, not commands competing for a PATH slot) -- duplication
# nixfs's mechanism was never built to distinguish from a genuine gap. So: no fallback, ever.
# `unavailableOnArch` stays a published fact a reader can act on, not a silent auto-install.
{ lib, config, ... }:
let
  cfg = config.nixgpu.toolchain;

  # The vendor's baseline runtime -- installed UNCONDITIONALLY whenever `enable && vendor != null`,
  # mirroring ./nixos.nix's own baseline. Unchanged from this module's first version.
  runtimeBaseline = {
    amd = [ ]; # amdgpu is in-kernel and Mesa provides the userspace; nothing to add.
    intel = [ "intel-compute-runtime" ];
    nvidia = [ "nvidia-utils" ];
  };

  runtime = if cfg.vendor == null then [ ] else runtimeBaseline.${cfg.vendor} or [ ];
in
{
  config = lib.mkIf cfg.enable {
    nixarch.packages.pacman = runtime ++ cfg.archPackages ++ cfg.extraPackages;
    nixarch.packages.aur = cfg.aurPackages;

    warnings = lib.optional (cfg.unavailableOnArch != [ ]) ''
      nixgpu.toolchain: ${toString (builtins.length cfg.unavailableOnArch)} selected package(s)
      have no Arch/AUR source and install NOTHING on this host:
      ${lib.concatStringsSep ", " cfg.unavailableOnArch}. This is expected where the equivalent is
      already bundled into another selected AUR package under a different name (see this file's
      own header) or genuinely does not exist on Arch yet -- not a silently dropped capability.
    '';
  };
}
