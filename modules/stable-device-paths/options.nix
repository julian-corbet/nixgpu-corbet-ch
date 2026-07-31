# stable-device-paths — the host's COMPLETE DRM device inventory, and stable /dev/dri symlinks
# generated from it, so a consumer never has to hardcode a numbered /dev/dri/cardN again.
#
# LEVEL 1 (nixosModules/systemManagerModules): a fact about the host itself -- true
# whether or not anything ever contends for the card. Not part of the Level 2 / edge
# arbitration modules (device-tokens, priority-ladder, pressure-watcher, ondemand-front);
# see the repo README's "Levels".
#
# WHY: DRM minor numbers are enumeration-order-dependent, not vendor-dependent. A BMC/IPMI virtual
# VGA adapter frequently claims card0, pushing the real GPU to card1 or higher -- and that ordering
# is not guaranteed stable across a kernel update, a firmware update, or boot-to-boot under an
# async-probe kernel. Root-caused live 2026-07-24 on a production single-GPU cluster, then hit for
# real on 2026-07-29 when a DisplayLink dock's `evdi` module took card1 and moved an RX 6800 to
# card2 -- while a device-plugin was still binding a hardcoded /dev/dri/card1 into GPU pods.
#
# THE FIX: a udev rule keyed on something the kernel derives from the hardware instead of on
# enumeration index. `/dev/dri/by-vendor/<name>-card` / `-render` (PCI) and
# `/dev/dri/by-driver/<driver>-card` (platform) always resolve to whichever node is actually backed
# by that silicon, or by that driver.
#
# ── WHY THE INVENTORY MUST BE COMPLETE, NOT JUST "THE CARDS THAT MATTER" ──────────────────────
#
# This table is not only the input to the symlink rules; it is the ONLY place this family states
# which DRM devices a host has. Consumers compute set operations over it, and one of them computes
# a COMPLEMENT: the two Wayland compositors in this family express device restriction in opposite
# directions -- wlroots takes an ALLOWLIST (`WLR_DRM_DEVICES`, colon-separated, first that opens is
# primary) while niri/Smithay has only a DENYLIST (`debug { ignore-drm-device }`, repeatable). To
# restrict niri to a permitted set, something has to enumerate everything ELSE. A device that
# physically exists but is missing from this table is therefore not a cosmetic gap: it silently
# leaks into niri's enumeration, and the restriction that was declared is not the restriction that
# runs.
#
# That is why `bus` exists. Until it did, this table could only describe PCI devices (its udev rule
# matched `ATTRS{vendor}`, a PCI attribute), so a PLATFORM DRM device -- `evdi`, the virtual card a
# DisplayLink dock drives -- was not merely inconvenient to declare, it was UNDECLARABLE. The one
# device class that appears and renumbers everything after it was the one class the inventory could
# not name.
#
# ── THE ONE THING THIS DOES NOT SOLVE: two devices that match identically ────────────────────
#
# A PCI rule can only match `ATTRS{vendor}=="0x1002"` -- it has no way to further ask "which of the
# two 0x1002 cards is this", because PCI vendor ID is a property of the SILICON MAKER, not of the
# individual card. A platform rule has the same shape one level over: `DRIVERS=="evdi"` matches
# every device that driver owns. A real fix needs a second, per-device match condition udev
# actually has (`KERNELS` on the PCI bus address / `ID_PATH`), which is left as follow-up work;
# until then the assertions below REFUSE to generate rules for such a collision rather than
# silently letting both nodes wear both symlinks.
#
# ⚠ evdi is the case where that limitation is NOT a defect to work around, and consumers must not
# try: `initial_device_count=N` creates N evdi devices, one connector each, all owned by the one
# driver, and there is no stable per-device identity to key a symlink on anyway. An evdi output is
# addressed by CONNECTOR NAME, never by node path -- evdi exposes a zero-byte EDID, so it cannot
# even be matched by the `"<make> <model> <serial>"` triple both compositors otherwise accept. One
# inventory entry describes the driver's devices as a class; that is the honest shape, and the
# `by-driver` symlink is a convenience for the single-device case, never an identity for N.
#
# Options only -- the NixOS and system-manager planes each consume `rules` in their own way. Both
# planes exist because a GPU host is not necessarily a NixOS host: an Arch/CachyOS laptop with one
# real card hits the identical renumbering hazard the moment a dock is plugged in.
#
# `devices` is the single per-device inventory the udev rules are generated from; `vendors` below
# is DERIVED from it, not hand-settable -- see that option's own description for the cross-repo
# duplication this closes.
{ lib, config, options, ... }:
let
  cfg = config.nixgpu.stableDevicePaths;

  # ── The two buses, split once here and used by everything below ─────────────────────────────
  #
  # Filtered rather than branched on per use-site so the pci-only derivations (the vendor map, the
  # same-vendor refusal) cannot accidentally see a platform device and try to read a `pciId` that
  # is legitimately null there.
  pciDevices = lib.filterAttrs (_name: d: d.bus == "pci") cfg.devices;
  platformDevices = lib.filterAttrs (_name: d: d.bus == "platform") cfg.devices;

  # Only the entries that actually carry the identity their bus needs. An entry missing it is
  # reported by an assertion below; excluding it here is what keeps that assertion the thing the
  # operator sees, instead of a raw `value is null while a string was expected` thrown out of a
  # fold two functions away.
  identifiedPciDevices = lib.filterAttrs (_name: d: d.vendor != null && d.pciId != null) pciDevices;
  identifiedPlatformDevices = lib.filterAttrs (_name: d: d.driver != null) platformDevices;

  # Collapse the per-device inventory onto a vendor-name -> PCI-ID map -- the shape `rules` below
  # has always consumed. A `foldlAttrs`, not a plain `mapAttrs`, because collapsing loses
  # information (which device contributed which entry) and the one thing worth checking before
  # throwing that away is internal consistency: a vendor name has exactly one real PCI vendor ID
  # (it comes from the silicon, not from anything an operator chooses), so two devices claiming
  # the same vendor name with two DIFFERENT PCI IDs is never a real hardware state -- it is a typo
  # in one of the two entries, and it is cheaper to catch here than to debug a udev rule later.
  derivedVendors = lib.foldlAttrs
    (acc: _deviceName: device:
      if acc ? ${device.vendor} && acc.${device.vendor} != device.pciId then
        throw ''
          nixgpu.stableDevicePaths.devices declares vendor "${device.vendor}" with two different
          PCI IDs (${acc.${device.vendor}} and ${device.pciId}). A vendor name has exactly one PCI
          vendor ID -- this is a typo in one of the conflicting device entries, not a real
          hardware state.
        ''
      else
        acc // { ${device.vendor} = device.pciId; })
    { }
    identifiedPciDevices;

  # Does the silicon behind a vendor name expose a render node at all? `hasRenderNode` is a
  # per-DEVICE fact (see its own description), but a udev rule is per-VENDOR, so it folds the same
  # way the PCI ID does. `||` rather than `&&`: emitting a rule that matches nothing is inert,
  # while omitting one that should have matched is a missing symlink a consumer then hardcodes
  # around. When two devices share a vendor the fold is moot anyway -- that config is refused
  # below before any rule is generated.
  vendorRenderNodes = lib.foldlAttrs
    (acc: _deviceName: device:
      acc // { ${device.vendor} = (acc.${device.vendor} or false) || device.hasRenderNode; })
    { }
    identifiedPciDevices;

  # The platform-bus counterpart of `derivedVendors`: driver name -> whether that driver's devices
  # have a render node. Deliberately NOT exposed as an option the way `vendors` is -- `vendors`
  # only still exists as an option because it predates the inventory and other code reads it;
  # there is no reason to mint a second hand-settable-looking projection now.
  derivedDrivers = lib.foldlAttrs
    (acc: _deviceName: device:
      acc // { ${device.driver} = (acc.${device.driver} or false) || device.hasRenderNode; })
    { }
    identifiedPlatformDevices;

  # How many inventory entries claim each vendor. Not wrong by itself -- an inventory is allowed
  # to record two identical-silicon cards, and nixhost's own `resources.gpu` table has no problem
  # with that -- but see the assertion below for why it stops being safe the moment
  # `stableDevicePaths.enable` turns it into a udev rule.
  vendorDeviceCounts = lib.foldlAttrs
    (acc: _deviceName: device: acc // { ${device.vendor} = (acc.${device.vendor} or 0) + 1; })
    { }
    identifiedPciDevices;
  ambiguousVendors = lib.filterAttrs (_vendor: count: count > 1) vendorDeviceCounts;

  # Same count, same reasoning, one bus over: two entries naming the same DRM driver cannot be
  # told apart by `DRIVERS=="<driver>"` either.
  driverDeviceCounts = lib.foldlAttrs
    (acc: _deviceName: device: acc // { ${device.driver} = (acc.${device.driver} or 0) + 1; })
    { }
    identifiedPlatformDevices;
  ambiguousDrivers = lib.filterAttrs (_driver: count: count > 1) driverDeviceCounts;

  # ── Per-bus required fields, as ASSERTIONS rather than types ────────────────────────────────
  #
  # `vendor`/`pciId`/`vramMiB` are required for `bus = "pci"` and meaningless for `bus =
  # "platform"`; `driver` is the reverse. The module system has no type that says "required
  # depending on a sibling field's value", so these three lists are what a discriminated union
  # costs here. They are UNGATED on `enable`, like the coherence checks in toolchain/options.nix:
  # an inventory is a fact table other repos mirror (nixhost reads it as `resources.gpu`), so an
  # entry that cannot say what it is is wrong data whether or not this host ever generates a rule.
  missingPciIdentity = lib.attrNames (lib.filterAttrs (_n: d: d.vendor == null || d.pciId == null) pciDevices);
  missingPciVram = lib.attrNames (lib.filterAttrs (_n: d: d.vramMiB == null) pciDevices);
  missingPlatformDriver = lib.attrNames (lib.filterAttrs (_n: d: d.driver == null) platformDevices);
  # The reverse mistake: PCI fields on a platform entry. Not a typo to shrug at -- it means the
  # operator believes udev will match on something it cannot see, so the device they think they
  # pinned is the device that will still renumber.
  platformWithPciFields = lib.attrNames (lib.filterAttrs (_n: d: d.vendor != null || d.pciId != null) platformDevices);

  # Definitions of `vendors` that did NOT come from this file.
  #
  # A `default` counts as a definition and is attributed to the declaring file, so a clean host
  # already has exactly one -- this module's own `default = derivedVendors`. Filtering by FILE
  # rather than counting is what distinguishes "derived, as designed" from "somebody assigned it",
  # and it stays correct if this module ever grows a second internal definition.
  ownFile = toString ./options.nix;
  foreignVendorDefs = lib.filter (d: toString d.file != ownFile)
    options.nixgpu.stableDevicePaths.vendors.definitionsWithLocations;

in
{
  options.nixgpu.stableDevicePaths = {
    enable = lib.mkEnableOption "stable /dev/dri symlinks (card + render), so device paths survive a DRM re-enumeration";

    devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
        options = {
          bus = lib.mkOption {
            type = lib.types.enum [ "pci" "platform" ];
            default = "pci";
            example = "platform";
            description = ''
              How the kernel attaches this DRM device, which decides the ONLY thing a udev rule
              can match it on -- and therefore which of the fields below are required.

              `"pci"` (the default, and every discrete card, iGPU and BMC framebuffer): the device
              hangs off the PCI bus and inherits `ATTRS{vendor}` from it, so `vendor` + `pciId`
              identify it. `"platform"`: there is no PCI parent and no vendor attribute anywhere
              up the chain -- a virtual DRM device (`evdi`) or an SoC display block -- so the
              driver name is the only handle, and `driver` identifies it instead.

              Defaulting to `"pci"` rather than requiring the field is deliberate: every entry
              that existed before this option did was a PCI device, and a discriminator whose
              common case has to be typed out is a discriminator people leave wrong.
            '';
          };

          vendor = lib.mkOption {
            # NOT bare `str`, which accepts "". This name becomes a path component in the generated
            # symlink (`/dev/dri/by-vendor/<vendor>-card`), so an empty or whitespace-bearing value
            # would produce a rule pointing at `/dev/dri/by-vendor/-card` -- syntactically valid
            # udev that silently means nothing. Constrained here rather than by an assertion so the
            # guard applies whether or not any host plane is enabled: an assertion in this module's
            # `config` section only fires when something reads it, and a facts-only host reads
            # nothing.
            type = lib.types.nullOr (lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*");
            default = null;
            example = "amd";
            description = ''
              The silicon vendor, in the operator's own words -- not a fixed enum here, because
              that catalogue belongs to whichever domain actually dispatches on it
              (`nixgpu.toolchain.vendor`'s `nvidia`/`amd`/`intel` enum, for the compute runtime).
              This field only needs to carry the fact and group devices that share silicon; two
              devices with the same `vendor` string are asserted to also share `pciId` below, so
              this is never just a free-text label -- it has to be the SAME word for the SAME PCI
              vendor ID every time it is used.

              REQUIRED for `bus = "pci"` and REFUSED for `bus = "platform"` (both by assertion --
              see this file's "Per-bus required fields"). A platform device has no PCI vendor
              attribute anywhere up its parent chain, so a vendor word there would describe
              something no rule can ever match.
            '';
          };

          pciId = lib.mkOption {
            # NOT bare `str`. A PCI vendor ID has exactly one shape -- `0x` plus four hex digits --
            # and this value is interpolated straight into the udev match condition
            # (`ATTRS{vendor}=="${pciId}"`). Every wrong shape fails the same silent way: the rule
            # parses, matches no device, and the symlink simply never appears, which surfaces later
            # as "the card moved" rather than as a config error. `""` is the worst case
            # (`ATTRS{vendor}==""`); nixhost relies on this type to reject it instead of an
            # assertion of its own, active here regardless of `enable`.
            type = lib.types.nullOr (lib.types.strMatching "0x[0-9a-fA-F]{4}");
            default = null;
            example = "0x1002";
            description = ''
              The PCI vendor ID exactly as `/sys/class/drm/cardN/device/vendor` reports it (AMD is
              `0x1002`, Intel `0x8086`, NVIDIA `0x10de`, ASPEED/AST BMC framebuffers are `0x1a03` --
              catalogue facts about the hardware, not a choice this repo or any operator makes).
              This is the STABLE identity the generated udev rule actually matches on; `vendor`,
              above, is for humans reading the inventory, never for matching a device.

              REQUIRED for `bus = "pci"`, REFUSED for `bus = "platform"` -- see `vendor`.
            '';
          };

          driver = lib.mkOption {
            # Kernel module naming: lowercase, digits, underscore, hyphen. Interpolated into
            # `DRIVERS=="${driver}"`, so the same silent-no-match failure applies as for pciId.
            type = lib.types.nullOr (lib.types.strMatching "[a-z0-9][a-z0-9_-]*");
            default = null;
            example = "evdi";
            description = ''
              The DRM driver that owns this device, as it appears in
              `/sys/class/drm/cardN/device/driver` -- `"evdi"` for a DisplayLink virtual card.
              This is what the generated rule matches (`DRIVERS=="<driver>"`, which walks the
              parent chain, because the DRM node itself carries no driver attribute).

              REQUIRED for `bus = "platform"`, and the reason that bus is expressible at all. Leave
              it null for `bus = "pci"`: a PCI device is matched by vendor ID, and a driver name
              there would be a second, weaker identity for the same card -- `amdgpu` is not a
              per-device fact, and pinning by it would break the moment a host has two AMD cards
              or the driver is renamed.
            '';
          };

          hasRenderNode = lib.mkOption {
            type = lib.types.bool;
            default = config.bus == "pci";
            defaultText = lib.literalExpression ''bus == "pci"'';
            description = ''
              Whether this device exposes a `/dev/dri/renderD*` node in addition to its `card*`
              node. A FACT about the driver, not a preference: a DRM driver gets a render node if
              and only if its `drm_driver` sets `DRIVER_RENDER`, which is decided at compile time
              and is therefore the same on every host running that driver.

              Two consumers need it and cannot derive it themselves. This module skips the
              `renderD*` half of the symlink pair when it is false, instead of emitting a rule
              that can never match. And a session that has to pick a renderer needs to know
              whether ANY device it is permitted to use can render at all -- if none can, the
              only correct answer is a software renderer, and finding that out at runtime means
              a compositor silently opening some other card's render node instead.

              The default follows the bus because that is where the two populations actually
              differ: a PCI GPU has one, and the display-only platform devices this option was
              added for do not. ⚠ `evdi` can NEVER have one -- its `drm_driver` never sets
              `DRIVER_RENDER`, anywhere, in any version. That is not this host's configuration,
              it is a property of the driver, so setting `hasRenderNode = true` on an evdi entry
              does not make a node appear; it only makes this table lie. The default is also
              wrong in the other direction for a display-only PCI part (an ASPEED/AST BMC
              framebuffer is `DRIVER_GEM | DRIVER_MODESET` and no more) -- say so explicitly
              there rather than letting a rule that matches nothing stand in for the fact.
            '';
          };

          vramMiB = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            example = 16384;
            description = ''
              VRAM actually on the device, in MiB. Recorded as a hardware fact only -- nothing in
              this module sums demand against it; that arbitration (VRAM pressure, eviction by
              priority) is `pressureWatcher`'s job, reading live sysfs counters, not a static
              table.

              REQUIRED for `bus = "pci"`: an inventory entry for a card that cannot say how big
              it is is not worth having, and even a BMC/IPMI framebuffer has a real number here
              (an ASPEED AST2500's embedded SDRAM is 16 MiB). Optional, and normally null, for
              `bus = "platform"`: a virtual DRM device has no dedicated video memory at all -- it
              composites into ordinary system RAM -- and null states that honestly, where any
              positive number would be an invention. Set it on a platform device only if one
              genuinely has a carveout.
            '';
          };

          role = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "desktop + compute";
            description = ''
              What this device is FOR, in the operator's own words. Never branched on by this
              module or by anything reading it -- same idiom, and same rule, as
              `nixstorage.disks.<name>.role`.

              It exists because an inventory keyed by short names is read by humans and by
              diagnostics, and "which of these three DRM devices is the one the desktop is
              supposed to be on" is a question `vendor = "amd"` answers badly. Deliberately free
              text and not an enum: the moment it became an enum something would start
              dispatching on it, and device POLICY -- who may use which card -- belongs to the
              consumer that claims the device, not to the table that records it exists.
            '';
          };
        };
      }));
      default = { };
      example = lib.literalExpression ''
        {
          gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; role = "desktop + compute"; };
          bmc0 = { vendor = "aspeed"; pciId = "0x1a03"; vramMiB = 16; hasRenderNode = false; role = "IPMI console"; };
          evdi0 = { bus = "platform"; driver = "evdi"; role = "DisplayLink dock"; };
        }
      '';
      description = ''
        Every DRM device this host actually has -- GPUs, GPU-shaped devices (a BMC/IPMI
        framebuffer), and virtual display devices (`evdi`) alike -- keyed by a short stable name.
        This is nixgpu's single per-device inventory: the `vendors` map below is DERIVED from it
        rather than hand-typed, so a host's device identity is stated once, here, and everything
        else in this repo (or in nixhost's own `resources.gpu`, via that repo's own defensive read
        of this option) reads it rather than restating it.

        COMPLETENESS IS PART OF THE CONTRACT, not a nicety -- see this file's header. A consumer
        that can only EXCLUDE devices (niri's `debug { ignore-drm-device }`) has to compute the
        complement of the permitted set, and it can only compute that against this table. An
        undeclared device is not absent from the machine; it is absent from the restriction.

        Empty (the default) for a host with no GPU recorded yet -- unlike `resources.cpu.cores`
        in nixhost, an empty inventory is a legitimate state, not a missing ceiling anything
        divides against, so this stays a plain default rather than needing nixhost's
        MIRROR + ASSERT-RESOLVED treatment. Note the consequence: "empty" and "complete" are
        indistinguishable from here, so a consumer computing a complement must decide for itself
        whether an empty table means "no devices" or "not tracked on this host".
      '';
    };

    vendors = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = derivedVendors;
      description = ''
        Vendor-name -> PCI-ID, DERIVED from the `bus = "pci"` entries of `devices` above -- no
        longer hand-settable. This used to be the only state in this module (`{ amd = "0x1002"; }`
        by default); making it a read-only projection of `devices` is a breaking change this repo
        accepts on purpose (see this project's house rules on backwards compatibility at near-zero
        adoption): the old shape let the vendor->PCI-ID fact be typed independently of nixhost's
        `resources.gpu` table, which is the exact duplication this option now closes.

        One symlink pair is still generated per entry: `/dev/dri/by-vendor/<vendor>-card` and
        `-render`. Two `devices` entries that share a `vendor` collapse onto the SAME entry here
        (there is only one PCI vendor ID to key a udev rule on) -- see this file's header for why
        that is a real, documented limitation rather than something this module silently gets
        wrong, and the assertion below for what happens instead of silently picking one.

        Platform devices are absent from this map by construction: they have no PCI vendor ID.
        They are not absent from `rules` -- see `rules` for the `by-driver` half.
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

  # PCI first, then platform -- the order is cosmetic (udev applies every matching rule), but a
  # stable order keeps a rendered rules file diffable across evaluations.
  #
  # `DRIVERS==` and not `DRIVER==` on the platform half, and the difference is the whole rule:
  # `DRIVER` matches the driver of the device being processed, and a DRM node has none -- the
  # driver is bound to its PARENT (the platform device). `DRIVERS` walks the parent chain, which
  # is where the match actually lives. Exactly the same reason `ATTRS{vendor}` (parents) is used
  # on the PCI half rather than `ATTR{vendor}` (this device only).
  config.nixgpu.stableDevicePaths.rules =
    lib.concatStrings (
      (lib.mapAttrsToList
        (name: vendor:
          ''
            SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-card"
          ''
          + lib.optionalString (vendorRenderNodes.${name} or true) ''
            SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-render"
          '')
        cfg.vendors)
      ++ (lib.mapAttrsToList
        (driver: hasRender:
          ''
            SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="${driver}", SYMLINK+="dri/by-driver/${driver}-card"
          ''
          + lib.optionalString hasRender ''
            SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", DRIVERS=="${driver}", SYMLINK+="dri/by-driver/${driver}-render"
          '')
        derivedDrivers)
    );

  # Fires only when the ambiguity would actually reach a host: an inventory with two same-vendor
  # devices is inert data until `enable` turns it into a udev rule nothing can disambiguate. See
  # this file's header for why this is a hard failure rather than a warning -- the whole point of
  # this change is to stop a same-vendor collision from resolving to "whichever card udev
  # processed last" the way the pre-inventory `vendors` map always silently would have.
  # `vendors` is readOnly, but readOnly is enforced at READ time -- the module system raises only
  # when something actually evaluates the option. The sole reader here is `rules`, which nothing
  # consumes unless a host plane is active, so on a facts-only host a stray
  # `stableDevicePaths.vendors.amd = "0xdead"` was silently accepted: the wrong value simply sat
  # there, unread, until the day someone enabled the module and got a hard error far from the edit
  # that caused it.
  #
  # An EAGER definition count closes that. `options...vendors.definitions` lists only explicit
  # definitions -- the `default = derivedVendors` is not one -- so a non-empty list means somebody
  # hand-set a derived option. Ungated on `enable`, deliberately: the point is to catch it on the
  # host where it was written, not on the host that later reads it.
  config.assertions = lib.optional (foreignVendorDefs != [ ]) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.vendors was set directly, in:
      ${lib.concatMapStringsSep "\n      " (d: "- ${toString d.file}") foreignVendorDefs}

      It is a read-only PROJECTION of `stableDevicePaths.devices` and cannot be assigned. It used
      to be this module's only state, a hand-typed vendor-name -> PCI-ID map, which is exactly the
      duplication the `devices` inventory replaced -- the same silicon was typeable here and again
      in nixhost's `resources.gpu`.

      Declare the card in `devices` instead, and this map follows:

        nixgpu.stableDevicePaths.devices.gpu0 = {
          vendor  = "amd";
          pciId   = "0x1002";
          vramMiB = 16384;
        };
    '';
  }
  ++ lib.optional (cfg.enable && ambiguousVendors != { }) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices has more than one device for vendor(s):
      ${lib.concatStringsSep ", " (lib.attrNames ambiguousVendors)}.

      A udev rule generated from this inventory matches on PCI vendor ID alone
      (ATTRS{vendor}=="0x...") -- it has no way to also ask "which card", so stableDevicePaths
      cannot generate a distinct symlink pair per device when two devices share a vendor: both
      cards would end up wearing both symlinks instead of one each. There is no per-device fix at
      the `devices` level; the real fix is a second, per-device match condition the generated
      rule does not carry yet (the PCI bus address / ID_PATH, not just the vendor ID). Until that
      exists, either drop `stableDevicePaths.enable` for a host with two same-vendor cards, or
      keep only one of the conflicting entries in `devices`.
    '';
  }
  ++ lib.optional (cfg.enable && ambiguousDrivers != { }) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices has more than one platform device for driver(s):
      ${lib.concatStringsSep ", " (lib.attrNames ambiguousDrivers)}.

      This is the same limitation as the same-vendor one, one bus over: the generated rule matches
      DRIVERS=="<driver>", which every device that driver owns satisfies, so two entries would
      wear each other's symlinks rather than one each.

      If these entries are meant to be the N devices of ONE multi-device driver -- `evdi` with
      `initial_device_count = N` is the case this module was widened for -- then one entry is the
      correct declaration, not N. Those devices have no stable per-device identity to key a
      symlink on in the first place, and a consumer addresses their outputs by CONNECTOR NAME
      (evdi exposes a zero-byte EDID, so not even a make/model/serial match is available). Declare
      the driver once and set `nixgpu.evdi.deviceCount` for how many there are.
    '';
  }
  ++ lib.optional (missingPciIdentity != [ ]) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices entr(ies) ${lib.concatStringsSep ", " missingPciIdentity}
      are on the PCI bus (`bus = "pci"`, the default) but do not declare both `vendor` and
      `pciId`.

      A PCI device is matched by `ATTRS{vendor}=="0x...."` and by nothing else this module can
      generate, so an entry without that pair produces no rule at all -- it would sit in the
      inventory looking declared while the device it names goes on renumbering.

      If this device is not on the PCI bus, say so instead: `bus = "platform"` takes a `driver`
      and no vendor.
    '';
  }
  ++ lib.optional (missingPciVram != [ ]) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices entr(ies) ${lib.concatStringsSep ", " missingPciVram}
      are on the PCI bus but do not declare `vramMiB`.

      Required for a PCI device, because there is no such device this could legitimately be silent
      about -- even a BMC/IPMI framebuffer has a real number (an ASPEED AST2500 has 16 MiB of
      embedded SDRAM). `null` is reserved for the case it genuinely describes: a `bus = "platform"`
      virtual device with no dedicated video memory at all.
    '';
  }
  ++ lib.optional (missingPlatformDriver != [ ]) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices entr(ies) ${lib.concatStringsSep ", " missingPlatformDriver}
      declare `bus = "platform"` but no `driver`.

      A platform DRM device has no PCI vendor attribute anywhere up its parent chain -- that is
      what makes it a platform device -- so the owning driver's name is the only handle udev has.
      Without it this entry can generate no rule.
    '';
  }
  ++ lib.optional (platformWithPciFields != [ ]) {
    assertion = false;
    message = ''
      nixgpu.stableDevicePaths.devices entr(ies) ${lib.concatStringsSep ", " platformWithPciFields}
      declare `bus = "platform"` but also set `vendor` and/or `pciId`.

      Those two fields are PCI attributes, and a platform device does not have them -- there is no
      `vendor` file anywhere in its sysfs parent chain for a rule to read. Keeping them would be
      worse than untidy: it reads as though the device were pinned by vendor ID when in fact
      nothing matches it, which is precisely the silent failure this module exists to remove.

      Drop them and keep `driver`, or change `bus` to `"pci"` if this really is a PCI device.
    '';
  };
}
