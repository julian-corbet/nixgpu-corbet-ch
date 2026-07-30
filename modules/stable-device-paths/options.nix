# stable-device-paths — vendor-keyed /dev/dri symlinks, so a consumer never has to hardcode a
# numbered /dev/dri/cardN again.
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
#
# ── `devices`: the per-device inventory, and why it lives here now ──────────────────────────────
#
# Until now this module's only state was `vendors`, a hand-typed vendor-name -> PCI-ID map. That
# was a second, independently-maintained copy of a fact nixhost ALSO hand-declares as
# `resources.gpu.<name> = { vendor; pciId; vramMiB; }` -- the same silicon, typed twice, in two
# repos that can drift apart. This is the real-consequence half of that duplication: a production
# GPU-pod misrouting this week traced back to exactly this kind of device identity being
# addressed inconsistently.
#
# `devices` is now the one place that fact is typed: a per-device inventory (vendor, PCI ID,
# VRAM), keyed by a stable name -- the same shape and the same field names as nixhost's
# `resources.gpu.<name>`, on purpose, so a future `resources.gpu = config.nixgpu.stableDevicePaths.
# devices or { }` mirror in nixhost (nixhost's own repo, not touched here) is a straight read, not
# a reshaping exercise. `vendors` is then DERIVED from `devices` below rather than hand-settable --
# see its own description for why that is a breaking change this repo accepts on purpose.
#
# WHY THE INVENTORY LIVES INSIDE stableDevicePaths RATHER THAN AS ITS OWN nixosModule: this is the
# one place in nixgpu that already needs a vendor -> PCI-ID fact to generate udev rules from.
# Splitting "what GPUs exist" into a separate always-imported module would mean a host has to
# import two nixosModules in lockstep to get one coherent feature, for no consumer that exists
# yet -- YAGNI cuts the other way once there is a second real consumer (nixhost's mirror will read
# `config.nixgpu.stableDevicePaths.devices or { }` regardless of nesting depth; the defensive-read
# idiom does not care how deep the path is).
#
# WHY NO DEFAULT DEVICE: the old `vendors` default (`{ amd = "0x1002"; }`) baked one operator's
# hardware assumption into a public repo's default, which is exactly what this family's own rules
# say not to do (see nixhost's ASSERT-RESOLVED discussion and this project's "no fake data"
# convention). `devices` therefore defaults to `{ }` -- an empty inventory is a legitimate state
# (no GPU, or a GPU this repo hasn't been told about yet), unlike an empty `resources.cpu.cores`.
# A host that wants the AMD default back states it once: `nixgpu.stableDevicePaths.devices.gpu0 =
# { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };`.
#
# THE ONE THING THIS DOES NOT SOLVE: two devices sharing a vendor. A udev rule can only match
# `ATTRS{vendor}=="0x1002"` -- it has no way to further ask "which of the two 0x1002 cards is
# this", because PCI vendor ID is a property of the SILICON MAKER, not of the individual card.
# Keying the derived map by device NAME instead of vendor name would not fix this either: the
# match condition is still vendor-ID-only, so two rules for two devices that share a vendor would
# both match BOTH physical cards, and each card would end up wearing both symlinks -- silently
# wrong in a new way, not an improvement on today's silently-wrong-for-a-different-reason bug.
# A real fix needs a second, per-device match condition udev actually has (`KERNELS` on the PCI
# bus address / `ID_PATH`, not just `ATTRS{vendor}`), which is a real udev-rule change this task
# did not ask for and is left as follow-up work. What IS done here: `devices` can already express
# two same-vendor cards (they are just two entries with the same `vendor`/`pciId` and different
# names), and the assertion below REFUSES to generate rules for that case instead of silently
# emitting a rule pair that resolves to whichever card udev processed last. Loud beats quiet --
# see nixhost's own MIRROR + ASSERT-RESOLVED discussion for why a disappearing guard is worse than
# a blocked build.
#
# A concrete near-term case this shape has to cover, not just a hypothetical: a devhome-class host
# has an ASPEED/AST BMC framebuffer (PCI vendor `0x1a03`) alongside a real AMD card. Two DIFFERENT
# vendors on one host is the easy case (the assertion below is silent for it, and each gets its own
# unambiguous symlink pair) -- it is included in this file's `example` as data, not wired in as a
# default, because a public repo's default must not assume any operator's specific hardware.
{ lib, config, ... }:
let
  cfg = config.nixgpu.stableDevicePaths;

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
    cfg.devices;

  # How many inventory entries claim each vendor. Not wrong by itself -- an inventory is allowed
  # to record two identical-silicon cards, and nixhost's own `resources.gpu` table has no problem
  # with that -- but see the assertion below for why it stops being safe the moment
  # `stableDevicePaths.enable` turns it into a udev rule.
  vendorDeviceCounts = lib.foldlAttrs
    (acc: _deviceName: device: acc // { ${device.vendor} = (acc.${device.vendor} or 0) + 1; })
    { }
    cfg.devices;
  ambiguousVendors = lib.filterAttrs (_vendor: count: count > 1) vendorDeviceCounts;
in
{
  options.nixgpu.stableDevicePaths = {
    enable = lib.mkEnableOption "vendor-keyed /dev/dri/by-vendor symlinks (card + render), so device paths survive a DRM re-enumeration";

    devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          vendor = lib.mkOption {
            type = lib.types.str;
            example = "amd";
            description = ''
              The silicon vendor, in the operator's own words -- not a fixed enum here, because
              that catalogue belongs to whichever domain actually dispatches on it
              (`nixgpu.toolchain.vendor`'s `nvidia`/`amd`/`intel` enum, for the compute runtime).
              This field only needs to carry the fact and group devices that share silicon; two
              devices with the same `vendor` string are asserted to also share `pciId` below, so
              this is never just a free-text label -- it has to be the SAME word for the SAME PCI
              vendor ID every time it is used.
            '';
          };

          pciId = lib.mkOption {
            type = lib.types.str;
            example = "0x1002";
            description = ''
              The PCI vendor ID exactly as `/sys/class/drm/cardN/device/vendor` reports it (AMD is
              `0x1002`, Intel `0x8086`, NVIDIA `0x10de`, ASPEED/AST BMC framebuffers are `0x1a03` --
              catalogue facts about the hardware, not a choice this repo or any operator makes).
              This is the STABLE identity the generated udev rule actually matches on; `vendor`,
              above, is for humans reading the inventory, never for matching a device.
            '';
          };

          vramMiB = lib.mkOption {
            type = lib.types.ints.positive;
            example = 16384;
            description = ''
              VRAM actually on the device, in MiB. Recorded as a hardware fact only -- nothing in
              this module sums demand against it; that arbitration (VRAM pressure, eviction by
              priority) is `pressureWatcher`'s job, reading live sysfs counters, not a static
              table. Required, with no default: an inventory entry that cannot say how big the
              card is is not worth having, and a BMC/IPMI framebuffer still has a real number here
              (an ASPEED AST2500's embedded SDRAM is 16 MiB) -- there is no device this could
              legitimately be silent about.
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
          bmc0 = { vendor = "aspeed"; pciId = "0x1a03"; vramMiB = 16; };
        }
      '';
      description = ''
        The GPUs (and GPU-shaped devices -- a BMC/IPMI framebuffer included) this host actually
        has, keyed by a short stable name. This is nixgpu's single per-device inventory: the
        `vendors` map below is DERIVED from it rather than hand-typed, so a host's device identity
        is stated once, here, and everything else in this repo (or in nixhost's own
        `resources.gpu`, via that repo's own defensive read of this option) reads it rather than
        restating it.

        Empty (the default) for a host with no GPU recorded yet -- unlike `resources.cpu.cores`
        in nixhost, an empty inventory is a legitimate state, not a missing ceiling anything
        divides against, so this stays a plain default rather than needing nixhost's
        MIRROR + ASSERT-RESOLVED treatment.
      '';
    };

    vendors = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = derivedVendors;
      description = ''
        Vendor-name -> PCI-ID, DERIVED from `devices` above -- no longer hand-settable. This used
        to be the only state in this module (`{ amd = "0x1002"; }` by default); making it a
        read-only projection of `devices` is a breaking change this repo accepts on purpose (see
        this project's house rules on backwards compatibility at near-zero adoption): the old
        shape let the vendor->PCI-ID fact be typed independently of nixhost's `resources.gpu`
        table, which is the exact duplication this option now closes.

        One symlink pair is still generated per entry: `/dev/dri/by-vendor/<vendor>-card` and
        `-render`. Two `devices` entries that share a `vendor` collapse onto the SAME entry here
        (there is only one PCI vendor ID to key a udev rule on) -- see this file's header for why
        that is a real, documented limitation rather than something this module silently gets
        wrong, and the assertion below for what happens instead of silently picking one.
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
    lib.concatStrings (lib.mapAttrsToList
      (name: vendor: ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="${vendor}", SYMLINK+="dri/by-vendor/${name}-render"
      '')
      cfg.vendors);

  # Fires only when the ambiguity would actually reach a host: an inventory with two same-vendor
  # devices is inert data until `enable` turns it into a udev rule nothing can disambiguate. See
  # this file's header for why this is a hard failure rather than a warning -- the whole point of
  # this change is to stop a same-vendor collision from resolving to "whichever card udev
  # processed last" the way the pre-inventory `vendors` map always silently would have.
  config.assertions = lib.optional (cfg.enable && ambiguousVendors != { }) {
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
  };
}
