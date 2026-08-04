# modules/toolchain/options.nix — the HOST-side GPU compute toolchain: two questions about one
# card, both declared once and resolved per platform. See ./README.md for the full design (the
# vendor × capability × platform model, and the boundary this module draws against nixllm).
#
# LEVEL 1 (nixosModules/systemManagerModules): a fact about the host itself -- true
# whether or not anything ever contends for the card. Not part of the Level 2 / edge
# arbitration modules (device-tokens, priority-ladder, pressure-watcher, ondemand-front);
# see the repo README's "Levels".
#
# TWO AXES, NOT ONE. `vendor` answers "which silicon" -- unchanged from this module's first
# version, including the PCI-ID coherence check against `stableDevicePaths` below. `capabilities.*`
# answers "for what": display, hardware video, compute, AI inference, 32-bit gaming, container
# exposure, diagnostics -- see ../../lib/catalogue.nix for the vendor × platform table each one
# resolves through. The OLD version of this option only ever answered "which vendor, plus one
# binary sdk/monitoring toggle" -- too coarse to say "give me VA-API but not the multi-gigabyte
# ROCm SDK" without reaching for the `extraPackages` escape hatch (which is exactly how the one
# real VA-API gap this catalogue closes -- intel-media-driver -- was declared before this module
# grew a `videoAccel` capability of its own).
#
# EVERY CAPABILITY DEFAULTS OFF, deliberately DIFFERENT from the two booleans it replaces (`sdk`
# and `monitoring` both defaulted ON). With two flags, "everything on once you opt in" was a
# reasonable floor. With seven -- several of them situational (gaming32, containerExposure) rather
# than broadly useful -- the same default would hand every host that enables this module a 32-bit
# gaming stack and a container runtime hook it never asked for. This module's own catalogue is
# closer in spirit to nixfs's `filesystems` option (declare what you actually need) than to its
# `tools.*` (a generic toolkit everyone wants); see ../../lib/catalogue.nix's own header. No live
# host depended on the old default -- CORBET-ELITEBOOK already overrides both flags to `false`
# explicitly, and no other host composes this module yet -- so flipping it costs nothing today.
{ lib, config, ... }:
let
  cfg = config.nixgpu.toolchain;

  catalogue = import ../../lib/catalogue.nix { };
  resolve = import ../../lib/resolve.nix { inherit lib; };

  capabilityNames = lib.attrNames catalogue;

  mkCapabilityOption = name: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        ${catalogue.${name}.summary}

        Off by default -- see this file's own header for why every capability here starts off
        rather than mirroring the old sdk/monitoring pair's "everything on once enabled" default.
      '';
    };
  };

  # Attaches an identity: the entry's own `arch` name if it has one, else its `nixpkgs` name.
  # Neither channel is guaranteed present (see ../../lib/catalogue.nix's own header -- this
  # catalogue genuinely uses `arch = null` and `nixpkgs = null` both), so neither can be assumed;
  # exactly one of them always is, for every real entry in the catalogue today.
  withIdentity = entry: entry // {
    name = if (entry.arch or null) != null then entry.arch else entry.nixpkgs;
  };

  enabledCapabilities = lib.filter (c: cfg.capabilities.${c}.enable) capabilityNames;

  # Vendor-neutral entries: apply whenever the capability is enabled, regardless of `vendor` --
  # today only `diagnostics` carries any (mesa-demos/libva-utils/wayland-utils query whatever GPU
  # is present). `or [ ]` catches every capability that has no `neutral` bucket at all, which Nix's
  # `or` resolves across the WHOLE chain (`catalogue.${cap}.neutral.packages`), not just its last
  # segment -- verified: a missing `neutral` attribute falls through exactly the same as a missing
  # `packages` attribute under a present one.
  neutralEntries = cap: map withIdentity (catalogue.${cap}.neutral.packages or [ ]);

  # Vendor-specific entries: nothing at all when `vendor == null` -- an unselected vendor
  # contributes nothing, by construction, not by a filter that could be forgotten.
  vendorEntries = cap:
    if cfg.vendor == null then [ ]
    else map withIdentity (catalogue.${cap}.vendors.${cfg.vendor}.packages or [ ]);

  selectedEntries = lib.unique (
    lib.concatMap (cap: neutralEntries cap ++ vendorEntries cap) enabledCapabilities
  );

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
      installing a GPU vendor's compute runtime and/or workload capabilities on this host.

      Off by default: plenty of machines have a GPU they only ever use for display, and a compute
      SDK is a large install to happen by accident
    '';

    vendor = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "nvidia" "amd" "intel" ]);
      default = null;
      description = ''
        Which vendor's silicon this host has, or null for none.

        Deliberately not auto-detected. Detection would have to run at evaluation time, on a
        machine that may not be the target, and a wrong guess installs several gigabytes of the
        wrong SDK. Declaring it is one line and is always correct.

        Gates every `capabilities.*` entry's VENDOR-SPECIFIC packages (../../lib/catalogue.nix):
        `vendor = null` with any capability enabled installs only that capability's vendor-neutral
        entries, if it has any -- an unselected vendor contributes nothing, never a guess.
      '';
    };

    capabilities = lib.genAttrs capabilityNames mkCapabilityOption;

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: additional package names appended verbatim, in whatever naming the active
        plane uses (nixpkgs attribute paths on NixOS, pacman names on Arch). Portability of these
        is the consumer's problem -- the catalogue above stays curated.
      '';
    };

    # ── Computed, read-only ──────────────────────────────────────────────────────────────────
    want = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Resolved entries from ../../lib/catalogue.nix; the contract a platform backend consumes.";
    };

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The resolved selection as nixpkgs attribute paths (dot-separated, e.g.
        "rocmPackages.clr"). The contract ./nixos.nix consumes.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected packages as official-repo pacman names, for the host's own reconciler. This
        module's ./system-manager.nix already wires this into `nixarch.packages.pacman` directly
        (unlike the sibling nixfs, which publishes and leaves wiring to the host -- see that
        module's own header for why nixfs decouples and why this one does not need to: toolchain
        has done the direct wiring since its first version, and no consumer benefits from breaking
        that now). Published anyway, read-only, so a host or a check can see what it will install
        without instantiating anything.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found".
        `intel-oneapi-basekit-2025` and `openvino-bin` are AUR today; wired into
        `nixarch.packages.aur` the same way `archPackages` is wired into `nixarch.packages.pacman`.
      '';
    };

    unavailableOnArch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected entries with no Arch package at all (official repo or AUR), named by catalogue
        identity. Empty for the real catalogue today -- every entry has a live Arch/AUR source --
        kept alive by a fixture in ../../checks/toolchain.nix, same mechanism as nixfs.
      '';
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected entries with no nixpkgs attribute at all, named by catalogue identity. NOT empty
        for the real catalogue -- `gaming32` and several `display` entries genuinely have no
        nixpkgs package (the NixOS answer is an option, not a package; see ./nixos.nix and
        ../../lib/catalogue.nix's own header) -- so a NixOS host enabling one of those capabilities
        sees exactly which of its selected entries install nothing on that plane, and why, rather
        than a silent gap.
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
  config = {
    assertions = lib.optional vendorContradiction {
      assertion = false;
      message = ''
        nixgpu.toolchain.vendor = "${config.nixgpu.toolchain.vendor}" wants the
        ${config.nixgpu.toolchain.vendor} runtime (PCI vendor ${wantedPciId}), but
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

    nixgpu.toolchain.want = selectedEntries;
    nixgpu.toolchain.packageNames = resolve.packageNames selectedEntries;
    nixgpu.toolchain.archPackages = resolve.archPackages selectedEntries;
    nixgpu.toolchain.aurPackages = resolve.aurPackages selectedEntries;
    nixgpu.toolchain.unavailableOnArch = resolve.unavailableOnArch selectedEntries;
    nixgpu.toolchain.unavailableOnNixos = resolve.unavailableOnNixos selectedEntries;
  };
}
