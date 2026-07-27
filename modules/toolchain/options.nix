# modules/toolchain/options.nix — the HOST-side GPU compute toolchain: which vendor's runtime a
# machine needs on the metal, declared once and resolved per platform.
#
# WHY THIS BELONGS IN nixgpu. Everything else here is about SHARING a GPU that already works --
# advertising lanes (device-tokens), ordering claimants (priority-ladder), evicting under pressure
# (pressure-watcher), queuing (ondemand-front), and keeping device paths stable
# (stable-device-paths). All of it presupposes a working vendor runtime, and none of it installs
# one. That gap meant nixgpu had nothing to say to a machine that is not already a Kubernetes node
# -- an Arch workstation with an RX 6800 got no help from the GPU project at all.
#
# This module closes that. It is deliberately the SMALLEST possible statement: which vendor, and
# whether to include the compute SDK on top of the plain runtime. It does not curate a persona, an
# editor list, or a Python stack -- those are a machine class, not a GPU concern, and they live in
# nixdev.
#
# PLANE IMPLEMENTATIONS live beside this file: nixos.nix resolves to nixpkgs attributes,
# system-manager.nix to pacman names. Package names are not portable across platforms and this is
# the one place in nixgpu where that bites, so each plane carries its own real implementation
# rather than a shim over a shared list. Same shape nixram and nixdev already use.
#
# HISTORY: the pacman half of this started life as nixarch's `ai-workstation` profile, whose own
# header called the GPU package names "the one genuinely hard-to-get-right bit and the main reason
# this profile exists". That was true, and it was the only part worth keeping -- but a GPU runtime
# is a GPU concern, not an Arch-packaging concern, so it moved here and the profile dissolved.
{ lib, ... }:
{
  options.nixgpu.toolchain = {
    enable = lib.mkEnableOption ''
      installing a GPU vendor's compute runtime on this host.

      Off by default: plenty of machines have a GPU they only ever use for display, and a compute
      SDK is a large install to happen by accident
    '';

    vendor = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "nvidia" "amd" "intel" ]);
      default = null;
      description = ''
        Which vendor's compute runtime this host needs, or null for none.

        Deliberately not auto-detected. Detection would have to run at evaluation time, on a
        machine that may not be the target, and a wrong guess installs several gigabytes of the
        wrong SDK. Declaring it is one line and is always correct.
      '';
    };

    sdk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include the full compute SDK (CUDA / ROCm / oneAPI-class), not just the userspace driver
        runtime.

        Set false on a host that only needs to RUN GPU workloads built elsewhere -- a Kubernetes
        node pulling prebuilt images, for instance, where the container carries its own toolkit and
        the host only has to expose a working device. That is the common case for a cluster member
        and the reason this is separable at all.
      '';
    };

    monitoring = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include the vendor's own monitoring/query tool (nvidia-smi, rocm-smi, intel_gpu_top class).

        On by default because every other module in this project is about contention, and the
        first question any contention investigation asks is "what is on the card right now" --
        which needs this tool present before the incident, not after.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: additional package names appended verbatim, in whatever naming the active
        plane uses (nixpkgs attribute paths on NixOS, pacman names on Arch). Portability of these
        is the consumer's problem -- the tables above stay curated.
      '';
    };
  };
}
