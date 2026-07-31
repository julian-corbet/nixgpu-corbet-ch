# modules/toolchain/options.nix — the HOST-side GPU compute toolchain: which vendor's runtime a
# machine needs on the metal, declared once and resolved per platform.
#
# LEVEL 1 (nixosModules/systemManagerModules): a fact about the host itself -- true
# whether or not anything ever contends for the card. Not part of the Level 2 / edge
# arbitration modules (device-tokens, priority-ladder, pressure-watcher, ondemand-front);
# see the repo README's "Levels".
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
{ lib, config, ... }:
let
  # Canonical PCI vendor IDs for the vendors this module's enum dispatches on. Catalogue facts
  # about the hardware, not a choice: these are what `/sys/class/drm/cardN/device/vendor` reports.
  #
  # Needed because `vendor` here and `stableDevicePaths.devices.<name>.vendor` are two DIFFERENT
  # vocabularies on purpose -- this one is a closed enum because this module dispatches on it to
  # pick a runtime, while the inventory's is free-form because it only groups devices that share
  # silicon and belongs to the operator ("amd", "AMD", "radeon" are all fine there). So the two
  # cannot be compared as strings; they are reconciled through the PCI ID, which is the one stable
  # identity both sides ultimately mean.
  toolchainPciIds = {
    amd = "0x1002";
    intel = "0x8086";
    nvidia = "0x10de";
  };

  # Read DEFENSIVELY: stableDevicePaths may not be imported at all, and this module must not
  # require it. An empty inventory means "no facts to check against", never a failure.
  inventory = config.nixgpu.stableDevicePaths.devices or { };

  # PCI entries only, nulls filtered out. Since the inventory gained a `bus` discriminator it also
  # holds PLATFORM devices (`evdi`, the virtual card a DisplayLink dock drives), which have no PCI
  # vendor ID at all and carry `pciId = null` by design. Two things break without this filter: the
  # message below interpolates a null, and -- the real one -- a host whose inventory lists only
  # platform devices would read as "an inventory that does not contain your card" when what it
  # actually is is an inventory with nothing PCI in it to compare against.
  pciInventory = lib.filterAttrs (_: d: (d.pciId or null) != null) inventory;
  inventoryPciIds = lib.mapAttrsToList (_: d: d.pciId) pciInventory;

  wantedPciId =
    if config.nixgpu.toolchain.vendor == null then null
    else toolchainPciIds.${config.nixgpu.toolchain.vendor} or null;

  # Only a real contradiction: both sides declared, and the vendor this host wants a runtime for
  # has no card in the host's own inventory.
  vendorContradiction =
    wantedPciId != null
    && inventoryPciIds != [ ]
    && !(lib.elem wantedPciId inventoryPciIds);
in
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

  # ── The one cross-check ─────────────────────────────────────────────────────────────────────
  #
  # `vendor` above and `stableDevicePaths.devices.<name>.vendor` are two statements about the same
  # silicon, and until this assertion existed nothing compared them: `toolchain.vendor = "nvidia"`
  # beside an inventory containing only `pciId = "0x1002"` evaluated completely clean, and the host
  # installed CUDA for a card it does not have.
  #
  # NOT gated on either module's `enable`. Both are fact declarations that other repos mirror
  # (nixhost reads the inventory as `resources.gpu`), so an incoherent pair is wrong data whether or
  # not this host ever installs a runtime or generates a udev rule. Gating a coherence check on a
  # mechanism switch is what left the same-vendor refusal and the `vendors` readOnly guard inert on
  # facts-only hosts.
  #
  # Silent whenever either side is absent -- no PCI inventory, or no vendor -- because then there
  # is genuinely nothing to contradict. This is a coherence check, not a completeness requirement:
  # a host may legitimately declare a compute vendor with no inventory at all, or an inventory
  # made up entirely of platform devices (a laptop that has recorded its DisplayLink `evdi` card
  # and not yet its iGPU).
  config.assertions = lib.optional vendorContradiction {
    assertion = false;
    message = ''
      nixgpu.toolchain.vendor = "${config.nixgpu.toolchain.vendor}" wants the
      ${config.nixgpu.toolchain.vendor} compute runtime (PCI vendor ${wantedPciId}), but
      nixgpu.stableDevicePaths.devices lists no device with that PCI vendor ID.

      Declared PCI inventory: ${lib.concatStringsSep ", " (lib.mapAttrsToList (n: d: "${n} = ${d.pciId}") pciInventory)}

      These are two statements about the same silicon and they disagree. One of them is a typo --
      most often a host declaration copy-pasted from a machine with a different card, where the
      inventory was updated for the new hardware and the toolchain vendor was not, or the reverse.

      Note the two fields use different vocabularies deliberately, so they are compared by PCI ID,
      not by name: `toolchain.vendor` is a closed enum this module dispatches on to pick a runtime,
      while `devices.<name>.vendor` is the operator's own free-form grouping word. Fix whichever of
      the two is wrong about the hardware; do not rename a device to match.
    '';
  };
}
