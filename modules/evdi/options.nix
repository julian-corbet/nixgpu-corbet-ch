# modules/evdi/options.nix — the virtual-DRM kernel module a DisplayLink dock needs, declared as
# what it actually is: a permanent DRM device this host owns, not a peripheral that comes and goes.
#
# LEVEL 1 (nixosModules/systemManagerModules): a fact about the host itself. Its userland half
# lives in modules/displaylink/, and the two are deliberately separate modules -- on the fleet this
# was extracted from they do not even run on the same system (the kernel module is on the metal;
# DisplayLinkManager runs in a container that shares that kernel and has `sys_module` dropped from
# its bounding set, so it could never load a module however it were configured). A single
# "displaylink" module would be unable to express that split at all.
#
# WHY THIS IS IN nixgpu AND NOT IN A DESKTOP OR DISTRO REPO: evdi is a DRM device. It takes a DRM
# minor, it renumbers every card after it (that is not hypothetical -- it is exactly how
# stable-device-paths' own header describes an RX 6800 moving from card1 to card2 on 2026-07-29),
# and it has to appear in `nixgpu.stableDevicePaths.devices` or a consumer computing the complement
# of a permitted device set will silently miss it. Everything about it is a GPU-contention fact.
#
# ── THE TRAPS, all of them load-bearing and all of them measured ─────────────────────────────
#
# ⚠ 1. THE MODULE PARAMETER IS NOT OPTIONAL. `initial_device_count` defaults to **0**, so loading
# evdi on its own registers NO DRM device at all (module/evdi_params.c:22-24, and evdi_init() at
# module/evdi_platform_drv.c:236-238 creates devices only `if (evdi_initial_device_count)`). A bare
# `boot.kernelModules = [ "evdi" ]` therefore succeeds, creates nothing, and leaves every consumer
# pointing at a device that does not exist -- a silent no-op, which is why this module always
# writes the parameter and why `deviceCount` cannot be set to 0 here.
#
# ⚠ 2. THE PRE-CREATED DEVICES ARE PERMANENT, AND THEIR USB LINK MUST NOT BE. The N devices are
# created at `module_init()` with no USB parent and therefore live for the life of the module --
# dock attached or not, forever. On dock removal evdi must detach the USB relationship while
# preserving those N cards; on the next attachment DisplayLinkManager can then reuse the same
# pre-created card. Two consequences follow, and both are the reason this shape was chosen over
# letting DisplayLinkManager mint devices on demand:
#
#   (a) ATTACHING A DOCK IS A CONNECTOR HOTPLUG, NOT A DEVICE HOTPLUG. The card is already there;
#       what arrives is a connected connector -- a udev "change" event with HOTPLUG=1 on an
#       existing DRM node. wlroots and Smithay both handle that generically, with no
#       DisplayLink-specific support anywhere, which is why "the dock works" needs no compositor
#       feature at all. A device that appeared at plug time would instead need the compositor to
#       adopt a new DRM device mid-session, which is the fragile path.
#   (b) THE NODE EXISTS BEFORE ANYTHING TRIES TO BIND IT. That is what makes a container bind, a
#       cgroup device allow-list, or a `WLR_DRM_DEVICES` allowlist expressible at all: each of
#       those is fixed when the consumer STARTS, so a node minted later would never appear inside
#       it. evdi's own attach path reuses a free pre-created device before allocating a new one
#       (evdi_platform_drv.c:130-149), so a fixed count is not merely compatible with on-demand
#       attach -- it is what that path expects.
#
#   evdi v1.15.0 BREAKS this contract: its usb_register_notify() callback compares the action to
#   BUS_NOTIFY_DEL_DEVICE instead of USB_DEVICE_REMOVE, so it skips removal entirely. The stale
#   evdi.0 remains linked to the departed dock and the next attachment allocates evdi.1 -- invisible
#   to any compositor, bind mount or DeviceAllow= pinned to the deliberately stable evdi.0. This
#   repo carries the two upstream PR #581 commits in `lib.evdiHotUnplug`; hosts must build their
#   kernel-specific package from that correction until evdi releases it.
#
# ⚠ 3. ONE evdi DEVICE = ONE CONNECTOR = ONE MONITOR. There is no multi-head evdi card. So
# `deviceCount` must be at least the maximum number of DisplayLink monitors that will ever be lit
# SIMULTANEOUSLY, counted across the whole system rather than per dock -- two docks with one
# monitor each need the same 2 as one dock with two.
#
# ⚠ 4. AN evdi OUTPUT CAN ONLY BE MATCHED BY CONNECTOR NAME. evdi exposes a ZERO-BYTE EDID, so the
# `"<make> <model> <serial>"` triple that both compositors in this family otherwise accept is
# unavailable for it -- there is nothing to build the triple out of. Any per-output configuration
# aimed at a DisplayLink monitor has to name the connector (evdi hardcodes
# `DRM_MODE_CONNECTOR_DVII`, so those names are `DVI-I-N`). Note what that costs: which physical
# monitor lands in which slot is decided by DisplayLinkManager's own enumeration order, so the
# slot is stable but the assignment is not guaranteed to be.
#
# ⚠ 5. evdi CAN NEVER HAVE A RENDER NODE. Its `drm_driver` never sets `DRIVER_RENDER` -- a
# compile-time property of the driver, true in every version and on every host. Declare it in the
# inventory as `hasRenderNode = false` (which is already the default for `bus = "platform"`), and
# never expect `/dev/dri/renderD*` to appear for it.
{ lib, config, ... }:
let
  cfg = config.nixgpu.evdi;

  # Same-repo defensive read: stable-device-paths is a sibling module in this flake, not
  # necessarily an imported one. `or { }` is the right tool HERE precisely because it is the same
  # repo -- the failure this guards against is "not imported", and there is no cross-repo rename
  # to be blind to (the option and its reader ship and version together).
  inventory = config.nixgpu.stableDevicePaths.devices or { };
  evdiDeclared = lib.any
    (d: (d.bus or "pci") == "platform" && (d.driver or null) == "evdi")
    (lib.attrValues inventory);
in
{
  options.nixgpu.evdi = {
    enable = lib.mkEnableOption ''
      the evdi virtual-DRM kernel module, which is what a DisplayLink USB dock actually draws
      through. Its proprietary userland is a separate module (`nixgpu.displaylink`) and may not
      even run on this machine
    '';

    deviceCount = lib.mkOption {
      # 1..16: upstream caps it at EVDI_DEVICE_COUNT_MAX (module/evdi_platform_drv.c:29), and 0 is
      # excluded on purpose -- it is upstream's own default and the silent no-op described in trap
      # 1 above. "Load the module but create nothing" is never a state worth declaring; a host
      # that wants no evdi devices sets `enable = false`, which says the same thing without
      # leaving a loaded module that looks like it did something.
      type = lib.types.ints.between 1 16;
      default = 1;
      example = 2;
      description = ''
        How many evdi DRM devices to pre-create at module load
        (`options evdi initial_device_count=N`).

        ONE PER SIMULTANEOUS DisplayLink MONITOR, system-wide -- one evdi device drives exactly one
        connector, and there is no multi-head evdi card (trap 3 in this file's header). Count the
        monitors, not the docks: two docks with one screen each need 2, the same as one dock
        driving two.

        Raising it is not free of consequence downstream, and the consequences are all
        enumeration-shaped. Each device takes the next free DRM minor, so raising the count
        renumbers every card probed after evdi -- which is the exact hazard
        `nixgpu.stableDevicePaths` exists to absorb, and the reason a host running evdi should be
        running that module too. A consumer that pins device nodes by NUMBER (a container bind, a
        cgroup `DeviceAllow=`) has to be regenerated in lockstep; one that pins by the symlinks
        this repo generates does not.

        The value is written unconditionally whenever this module is enabled, never left to the
        kernel default. See trap 1: that default is 0, and it fails by creating nothing at all
        while every other sign says the module loaded fine.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "config.boot.kernelPackages.evdi";
      example = lib.literalExpression ''
        config.boot.kernelPackages.evdi.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + '''
            substituteInPlace Makefile \
              --replace-fail "FLAGS=-Werror" \
                             "FLAGS=-Wno-unknown-warning-option -Werror" \
              --replace-fail "FLAGS_CXX=\$(FLAGS)" \
                             "FLAGS_CXX=\$(FLAGS) -Wno-vla-cxx-extension"
          ''';
        })
      '';
      description = ''
        The evdi kernel-module package to build against this host's kernel, or null (the default)
        to take `config.boot.kernelPackages.evdi` -- the one that already tracks whichever kernel
        this host runs. NixOS plane only: on the Arch plane a kernel module is a pacman/DKMS
        package, named by `archPackage` below, because a string is all pacman can be handed.

        ⚠ WHY THIS IS OVERRIDABLE AT ALL, and the exact override to use: evdi is written for GCC
        and its top-level Makefile promotes every diagnostic to an error (line 5 begins
        `FLAGS=-Werror`). On a CLANG-BUILT KERNEL -- out-of-tree modules are compiled with the
        kernel's own toolchain, so this is not exotic -- two independent GCC assumptions bite, in
        sequence:

          1. `-Werror=discarded-qualifiers` is a GCC-only warning NAME. clang does not know it, and
             `-Werror` promotes clang's own "unknown warning option" diagnostic to an error, so
             EVERY object fails. The log looks catastrophic (evdi_cursor.o, evdi_debug.o, ...) for
             what is really one bad flag.
          2. `pyevdi/PyEvdi.cpp` declares `char buffer[size]` -- a C++ variable-length array, a GCC
             extension. clang diagnoses it as `-Wvla-cxx-extension`, promoted by the same
             `-Werror`. The kernel module itself has already built by that point; it is the Python
             bindings that fail.

        The example above is the fix, and it is deliberately an EXAMPLE rather than something this
        module applies for you: it disables two diagnostics instead of deleting the strictness, and
        it is inert on a GCC-built kernel (GCC ignores unrecognised `-Wno-*` options), but a
        module that silently patched a package it does not own would be doing so on every host,
        including the ones where the strictness is load-bearing. `--replace-fail` is what keeps
        the override honest: it fails loudly if upstream's Makefile ever changes shape.
      '';
    };

    archPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "evdi-dkms";
      example = null;
      description = ''
        Arch/CachyOS plane only: the pacman/AUR package that provides the evdi kernel module,
        appended to `nixarch.packages.aur`. Null declares nothing -- correct when the module comes
        from somewhere pacman cannot see, which is the ordinary case for a CONTAINER whose kernel
        (and therefore whose modules) belongs to the host.

        A separate option from `package` above, rather than one field accepting either, because
        the two planes disagree about what a kernel-module package even IS: on NixOS it is a
        derivation built against a specific kernel and this module can hand it to
        `boot.extraModulePackages`; on Arch it is a name, and what is behind it is a DKMS build
        performed at install time against whatever kernel is running then. Same split, and same
        reason, as `nixgpu.toolchain`'s two plane implementations.

        ⚠ A DKMS build inherits the running kernel's toolchain, so the clang `-Werror` trap
        documented under `package` above applies to it as well -- with no override hook, because
        the build happens inside pacman. On a clang-built kernel, verify the package actually
        built rather than assuming the transaction's exit code covered it.
      '';
    };
  };

  # The inventory-completeness nudge, and the one place this module talks to stable-device-paths.
  #
  # A WARNING and not an assertion, deliberately, and the line is exactly where the two options'
  # own contracts put it: `devices` is allowed to be empty (a host that does not track its DRM
  # devices at all is a legitimate, silent state), so an empty inventory says nothing and is left
  # alone. A NON-EMPTY inventory, however, is a claim to be complete -- that is the property a
  # consumer computing the complement of a permitted device set depends on -- and one that omits a
  # device this very configuration is about to create is exactly the silent hole that makes such a
  # complement wrong. Not fatal, because the inventory is data other repos mirror rather than a
  # mechanism this module needs, and failing a build over a missing FACT would make the fact
  # unadoptable.
  config.warnings = lib.optional (cfg.enable && inventory != { } && !evdiDeclared) ''
    nixgpu.evdi.enable is set, so this host will create ${toString cfg.deviceCount} evdi DRM
    device(s) at boot -- but nixgpu.stableDevicePaths.devices is non-empty and declares none of
    them.

    A non-empty inventory reads as a COMPLETE list of this host's DRM devices, and consumers treat
    it that way: restricting niri to a permitted set is done by excluding everything else, which
    can only be computed against this table. An undeclared device is not excluded from that
    computation -- it silently leaks into the compositor's enumeration, and the restriction that
    was declared is not the restriction that runs.

    Declare it:

      nixgpu.stableDevicePaths.devices.evdi = {
        bus    = "platform";   # no PCI parent, so no vendor/pciId
        driver = "evdi";
        role   = "DisplayLink dock";
      };

    One entry, not one per device: the N devices this module creates share a driver and have no
    per-device identity to tell them apart (see modules/stable-device-paths/options.nix).
  '';
}
