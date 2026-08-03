# Evaluates modules/stable-device-paths/ for real: the device inventory's field guards, the derived
# vendor map, the generated udev rules, and the two ambiguity refusals.
#
# WHY THIS FILE EXISTS AT ALL: this repo's only check was `all-modules-render`, a nixidy render of
# `nixidyModules`. It never evaluates `nixosModules.stableDevicePaths` at any point, so the entire
# host-side plane -- including the inventory this module gained when it became the single owner of
# the vendor/PCI-ID fact -- shipped with `nix flake check` passing and covering none of it.
#
# The guards below are TYPE-level where the module system can express them and ASSERTION-level
# where it cannot (a field required only for one value of `bus` is not a type), and this check pins
# that distinction: a `config`-section assertion in this module only fires when something reads the
# option, and a facts-only host (inventory declared, no host plane enabled) reads nothing. Every
# case here is evaluated with `enable` unset unless the case is specifically about rule generation,
# for exactly that reason.
{ pkgs, lib ? pkgs.lib }:
let
  stubs = { lib, ... }: {
    options.assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
    options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
  };

  eval = settings: lib.evalModules {
    modules = [ stubs ../modules/stable-device-paths/options.nix { nixgpu.stableDevicePaths = settings; } ];
  };

  # Both fact modules together, which is how a real host declares them -- the vendor cross-check
  # spans the two.
  evalBoth = settings: lib.evalModules {
    modules = [
      stubs
      ../modules/stable-device-paths/options.nix
      ../modules/toolchain/options.nix
      settings
    ];
  };

  refusedBoth = settings:
    let
      r = builtins.tryEval (builtins.deepSeq
        (evalBoth settings).config.assertions
        (lib.filter (a: !a.assertion) (evalBoth settings).config.assertions));
    in
    !r.success || r.value != [ ];

  # Forces the inventory deeply, MINUS `cardPath`/`renderPath`/`cardNamePath`/`renderNamePath` --
  # so a device's this-devices'-shape correctness ("is `vendor`/`pciId`/`vramMiB`/... well-formed")
  # stays a separate question from "does a *derived path* resolve", which is the whole point of
  # `cardPath` (and its `by-name` counterpart `cardNamePath`) throwing lazily when `address` is
  # unset (see options.nix's own comment on that default). Every existing case below declares no
  # `address`, so a naive `deepSeq` over the untouched submodule would force that throw on every
  # one of them and report a well-formed device as REJECTED -- discovered by exactly that
  # regression the first time `accepts` was pointed at a device with `cardPath` added and no
  # `address` set.
  devicesSansPaths = settings:
    lib.mapAttrs (_name: d: builtins.removeAttrs d [ "cardPath" "renderPath" "cardNamePath" "renderNamePath" ])
      (eval settings).config.nixgpu.stableDevicePaths.devices;

  accepts = settings:
    (builtins.tryEval (builtins.deepSeq (devicesSansPaths settings) "ok")).success;

  # Forces the DERIVED map.
  vendorsOf = settings:
    builtins.tryEval (builtins.deepSeq
      (eval settings).config.nixgpu.stableDevicePaths.vendors
      (eval settings).config.nixgpu.stableDevicePaths.vendors);

  # The generated udev rules, as text. `rules` is `internal`/`readOnly` but is a plain option like
  # any other -- and it is the only place the module's actual OUTPUT can be inspected, so a check
  # that never reads it is checking the inventory and not the thing the inventory is for.
  rulesOf = settings: (eval settings).config.nixgpu.stableDevicePaths.rules;

  # One device's resolved submodule, for the per-bus defaults. Deliberately UNFORCED (a plain
  # attribute fetch, not a `deepSeq`) -- callers dereference exactly the field they want to test,
  # which is what lets `.cardPath`/`.renderPath` be tested for BOTH "resolves to X" and "throws"
  # without the fetch itself pre-empting either outcome.
  deviceOf = settings: name: (eval settings).config.nixgpu.stableDevicePaths.devices.${name};

  # Whether forcing a specific field of one device throws. Used for `cardPath`/`renderPath`'s
  # "throws when `address` is unset" behavior, which `accepts` (by design, see `devicesSansPaths`)
  # never exercises.
  throwsOn = settings: name: field:
    !(builtins.tryEval (deviceOf settings name).${field}).success;

  # Whether the config would be REFUSED on a real host -- either because reading the derived map
  # throws, or because a `config.assertions` entry is false.
  #
  # Checking `assertions` explicitly matters: `lib.evalModules` COLLECTS assertions but does not
  # enforce them (NixOS/system-manager do that in a later step), so a harness that only forces
  # values silently passes every assertion-based refusal in the module. Discovered by this check
  # failing on the same-vendor case, which the module does refuse -- via an assertion.
  refused = settings:
    let
      v = vendorsOf settings;
      failedAssertions =
        let r = builtins.tryEval (builtins.deepSeq
          (eval settings).config.assertions
          (lib.filter (a: !a.assertion) (eval settings).config.assertions));
        in if r.success then r.value else [ ];
    in
    !v.success || failedAssertions != [ ];

  # Failed assertions ONLY -- deliberately never forces `vendors`.
  #
  # `refused` above reads the derived map, which makes `readOnly` throw whenever a foreign
  # definition exists -- so it reports "refused" for a hand-set map even with the EAGER guard
  # disabled, and cannot tell the two apart. That is the exact defect the eager guard exists to
  # close (readOnly fires only at read time, and a facts-only host never reads), so testing it
  # requires a probe that reads nothing but the assertion list. Caught by disabling the guard and
  # watching the naive test still pass.
  assertionFailures = settings:
    let
      r = builtins.tryEval (builtins.deepSeq
        (eval settings).config.assertions
        (lib.filter (a: !a.assertion) (eval settings).config.assertions));
    in
    if r.success then r.value else [ { message = "eval threw"; } ];

  amd = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
  ast = { vendor = "aspeed"; pciId = "0x1a03"; vramMiB = 64; };
  # The device class the `bus` discriminator was added for: a virtual DRM device with no PCI parent
  # at all. Deliberately declares nothing but bus + driver -- that is the complete, correct entry.
  evdi = { bus = "platform"; driver = "evdi"; };

  results = {
    # ── ACCEPTED ────────────────────────────────────────────────────────────────────────────
    "a well-formed device is accepted" = accepts { devices.gpu0 = amd; };
    # The real near-term shape: an ASPEED BMC framebuffer beside a discrete AMD card. Two DIFFERENT
    # vendors on one host is the easy case and must stay silent.
    "an ASPEED BMC framebuffer beside an AMD card is accepted" =
      accepts { devices = { gpu0 = amd; ast = ast; }; };

    # ── REJECTED, and rejected with `enable` unset ──────────────────────────────────────────
    # Each of these previously produced a udev rule that parses, matches nothing, and fails silently
    # -- surfacing later as "the card moved" rather than as a config error.
    "an empty vendor is rejected" =
      !(accepts { devices.gpu0 = amd // { vendor = ""; }; });
    "a vendor containing a path separator is rejected" =
      !(accepts { devices.gpu0 = amd // { vendor = "a/b"; }; });
    "an empty pciId is rejected" =
      !(accepts { devices.gpu0 = amd // { pciId = ""; }; });
    "a pciId missing its 0x prefix is rejected" =
      !(accepts { devices.gpu0 = amd // { pciId = "1002"; }; });
    "an over-long pciId is rejected" =
      !(accepts { devices.gpu0 = amd // { pciId = "0x100200"; }; });
    "a zero vramMiB is rejected" =
      !(accepts { devices.gpu0 = amd // { vramMiB = 0; }; });
    "an unknown bus is rejected" =
      !(accepts { devices.gpu0 = amd // { bus = "usb"; }; });
    "an uppercase driver name is rejected" =
      !(accepts { devices.evdi = evdi // { driver = "EVDI"; }; });

    # ── THE PLATFORM BUS ────────────────────────────────────────────────────────────────────
    #
    # Before `bus` existed, this device was not merely awkward to declare -- it was UNDECLARABLE,
    # because every field the submodule required (vendor, pciId, vramMiB) is a PCI fact an `evdi`
    # device does not have. That was a correctness hole rather than a cosmetic gap: a consumer
    # restricting niri has to compute the COMPLEMENT of the permitted set, which it can only do
    # against this table, so an undeclarable device silently leaked into niri's enumeration.
    "a platform device with only bus + driver is accepted" =
      accepts { devices.evdi = evdi; };
    "a platform device beside a PCI card is accepted" =
      accepts { devices = { gpu0 = amd; evdi = evdi; }; };
    "a platform device needs no vramMiB" =
      !(refused { devices.evdi = evdi; });
    "a platform device MAY declare vramMiB (an SoC carveout)" =
      !(refused { devices.evdi = evdi // { vramMiB = 512; }; });
    "a platform device with no driver is refused" =
      refused { devices.evdi = { bus = "platform"; }; };
    # The reverse mistake, and the dangerous one: it reads as though the device were pinned by
    # vendor ID when in fact nothing can match it.
    "a platform device that also sets vendor/pciId is refused" =
      refused { devices.evdi = evdi // { vendor = "displaylink"; pciId = "0x17e9"; }; };

    # ── PER-BUS REQUIRED FIELDS (assertions, because no type can express them) ──────────────
    # Ungated on `enable`, like the toolchain cross-check: an inventory is a fact table other repos
    # mirror, so an entry that cannot say what it is is wrong data whether or not a rule is ever
    # generated from it.
    "a PCI device with no vendor is refused" =
      refused { devices.gpu0 = { pciId = "0x1002"; vramMiB = 8192; }; };
    "a PCI device with no pciId is refused" =
      refused { devices.gpu0 = { vendor = "amd"; vramMiB = 8192; }; };
    "a PCI device with no vramMiB is refused" =
      refused { devices.gpu0 = { vendor = "amd"; pciId = "0x1002"; }; };
    # ...and the same entry with `bus = "platform"` is fine, which is the whole point of the
    # discriminator: the fields are required per bus, not per module.
    "the same fieldless entry IS accepted on the platform bus" =
      !(refused { devices.evdi = { bus = "platform"; driver = "evdi"; }; });

    # ── sharedSystemMemory: the OTHER honest way for `vramMiB` to be null on a PCI device ────
    # An integrated GPU with no fixed VRAM (Intel Xe/Arc, AMD APUs) is still a real PCI device --
    # it has a real vendor/pciId -- so it cannot reach the platform-bus escape hatch without a
    # second, worse fabrication. This is the real, honest third state `missingPciVram` allows.
    "a PCI device with no vramMiB is refused by default (no sharedSystemMemory)" =
      refused { devices.gpu0 = { vendor = "intel"; pciId = "0x8086"; }; };
    "sharedSystemMemory = true accepts a PCI device with null vramMiB" =
      !(refused { devices.gpu0 = { vendor = "intel"; pciId = "0x8086"; sharedSystemMemory = true; }; });
    # The escape hatch is per-device, not global: a SECOND PCI device in the same inventory, still
    # without sharedSystemMemory, must still be refused -- proves the exemption did not leak.
    "sharedSystemMemory on one device does not exempt a different one" =
      refused {
        devices = {
          gpu0 = { vendor = "intel"; pciId = "0x8086"; sharedSystemMemory = true; };
          gpu1 = { vendor = "amd"; pciId = "0x1002"; };
        };
      };
    # sharedSystemMemory does not FORBID a real vramMiB -- an operator who sets both is stating an
    # unusual but not incoherent fact (the flag governs whether `null` is allowed, not whether a
    # number is).
    "sharedSystemMemory = true with a real vramMiB is still accepted" =
      !(refused { devices.gpu0 = { vendor = "intel"; pciId = "0x8086"; sharedSystemMemory = true; vramMiB = 512; }; });
    "sharedSystemMemory defaults to false" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").sharedSystemMemory == false;

    # ── hasRenderNode: a FACT, defaulted per bus ────────────────────────────────────────────
    # A DRM driver has a render node iff its `drm_driver` sets DRIVER_RENDER -- decided at compile
    # time, identical on every host running that driver. evdi never sets it, in any version.
    "hasRenderNode defaults true on the PCI bus" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").hasRenderNode == true;
    "hasRenderNode defaults false on the platform bus" =
      (deviceOf { devices.evdi = evdi; } "evdi").hasRenderNode == false;
    "hasRenderNode is still settable per device (a display-only PCI framebuffer)" =
      (deviceOf { devices.ast = ast // { hasRenderNode = false; }; } "ast").hasRenderNode == false;

    # ── role: recorded, never branched on ───────────────────────────────────────────────────
    "role defaults to null and takes free text" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").role == null
      && (deviceOf { devices.gpu0 = amd // { role = "desktop + compute"; }; } "gpu0").role == "desktop + compute";

    # ── THE DERIVED MAP ─────────────────────────────────────────────────────────────────────
    "vendors is derived from the inventory, not hand-typed" =
      let v = vendorsOf { devices = { gpu0 = amd; ast = ast; }; };
      in v.success && v.value == { amd = "0x1002"; aspeed = "0x1a03"; };

    # A platform device has no PCI vendor ID, so it cannot appear here -- and must not make the map
    # throw on the way past either.
    "a platform device does not enter the vendor map" =
      let v = vendorsOf { devices = { gpu0 = amd; evdi = evdi; }; };
      in v.success && v.value == { amd = "0x1002"; };
    "a platform-only inventory derives an empty vendor map" =
      let v = vendorsOf { devices.evdi = evdi; };
      in v.success && v.value == { };

    # ── THE GENERATED RULES ─────────────────────────────────────────────────────────────────
    #
    # The module's actual output. `ATTRS`/`DRIVERS` (plural) and not `ATTR`/`DRIVER` in both cases,
    # because the match lives on a PARENT: a DRM node carries neither a vendor attribute nor a
    # bound driver of its own.
    "a PCI device generates both symlink rules" =
      rulesOf { devices.gpu0 = amd; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-render"
      '';

    # One rule, not two: `hasRenderNode = false` means a renderD rule could never match anything,
    # and emitting one anyway would state a fact about the hardware that is not true.
    "a platform device generates a by-driver card rule and NO render rule" =
      rulesOf { devices.evdi = evdi; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="evdi", SYMLINK+="dri/by-driver/evdi-card"
      '';

    "a PCI device with no render node generates only its card rule" =
      rulesOf { devices.ast = ast // { hasRenderNode = false; }; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1a03", SYMLINK+="dri/by-vendor/aspeed-card"
      '';

    "both buses generate their rules side by side" =
      rulesOf { devices = { gpu0 = amd; evdi = evdi; }; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-render"
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="evdi", SYMLINK+="dri/by-driver/evdi-card"
      '';

    "an empty inventory generates no rules at all" =
      rulesOf { } == "";

    # ── AMBIGUITY, per bus ──────────────────────────────────────────────────────────────────
    #
    # Two devices sharing a vendor cannot be told apart by an `ATTRS{vendor}` match -- PCI vendor ID
    # identifies the silicon MAKER, not the card. The module refuses to generate rules for that
    # case rather than emitting one that silently binds the wrong card.
    # WITH `enable = true`, i.e. when rules would actually be generated. The refusal is gated on
    # `enable` deliberately -- see the case below.
    "two devices sharing a vendor are refused when generating rules" =
      refused {
        enable = true;
        devices = {
          gpu0 = amd;
          gpu1 = amd // { vramMiB = 8192; };
        };
      };

    # Same vendor NAME with a different PCI ID is a typo, not a second card, and must not silently
    # collapse into one map entry.
    "the same vendor name with a conflicting pciId is refused" =
      refused {
        enable = true;
        devices = {
          gpu0 = amd;
          gpu1 = { vendor = "amd"; pciId = "0x8086"; vramMiB = 8192; };
        };
      };

    # ...but a FACTS-ONLY host may hold two same-vendor cards. This is deliberate, not an
    # oversight: the inventory is a fact table that nixhost mirrors, and "this box has two AMD
    # cards" is simply true. What cannot be done is generate a distinct symlink pair for each, so
    # the refusal fires only when `enable` asks for rules. Pinned here so nobody "fixes" the
    # gating without noticing it is load-bearing.
    "a facts-only host may declare two same-vendor cards" =
      !(refused {
        devices = {
          gpu0 = amd;
          gpu1 = amd // { vramMiB = 8192; };
        };
      });

    # THE POINT OF THE SPLIT: the vendor refusal must not fire on platform devices, which have no
    # vendor at all. Before the buses were separated this fold read `d.vendor` for every entry and
    # would have collapsed two platform devices onto the `null` key.
    "the vendor ambiguity check does NOT fire for platform devices" =
      !(refused {
        enable = true;
        devices = {
          gpu0 = amd;
          evdi = evdi;
          other = { bus = "platform"; driver = "vkms"; };
        };
      });

    # The platform-bus counterpart, same limitation one bus over: `DRIVERS=="evdi"` matches every
    # device that driver owns. For evdi specifically, N devices is the NORMAL state (one per
    # monitor) and the correct declaration is ONE entry -- so this refusal is also how a consumer
    # is told not to enumerate them by hand.
    "two platform devices sharing a driver are refused when generating rules" =
      refused {
        enable = true;
        devices = {
          evdi0 = evdi;
          evdi1 = evdi;
        };
      };
    "a facts-only host may declare two same-driver platform devices" =
      !(refused { devices = { evdi0 = evdi; evdi1 = evdi; }; });

    # ── vendors is a projection, not a setting (eager, ungated) ─────────────────────────────
    # readOnly alone fires only when something READS the option, and on a facts-only host nothing
    # does -- so a stray assignment sat unread until someone enabled the module later.
    "hand-setting the derived vendors map is refused WITHOUT reading it" =
      assertionFailures { vendors.amd = "0xdead"; } != [ ];
    "it is refused even when the assigned value matches what would be derived" =
      assertionFailures { devices.gpu0 = amd; vendors.amd = "0x1002"; } != [ ];
    "a normal inventory does not trip the projection guard" =
      assertionFailures { devices.gpu0 = amd; } == [ ];
    "an empty config does not trip the projection guard" =
      assertionFailures { } == [ ];

    # ── address / cardPath / renderPath: the by-path physical-location facts ────────────────
    #
    # `address` is optional -- see options.nix's header for why -- so an inventory that never
    # sets it must still evaluate cleanly, INCLUDING through `accepts`, which is what
    # `devicesSansPaths` above exists to guarantee.
    "address defaults to null and does not prevent acceptance" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").address == null
      && accepts { devices.gpu0 = amd; };

    # Both bus forms, checked against the EXACT spellings read live off this estate's hosts
    # (`ls -l /dev/dri/by-path/`: `pci-0000:0a:00.0-card`, `pci-0000:0a:00.0-render`,
    # `platform-evdi.0-card`) -- not a format this check invents.
    "a PCI device's cardPath is the exact live by-path spelling" =
      (deviceOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; } "gpu0").cardPath
        == "/dev/dri/by-path/pci-0000:0a:00.0-card";
    "a PCI device's renderPath is the exact live by-path spelling" =
      (deviceOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; } "gpu0").renderPath
        == "/dev/dri/by-path/pci-0000:0a:00.0-render";
    "a platform device's cardPath is the exact live by-path spelling" =
      (deviceOf { devices.evdi = evdi // { address = "evdi.0"; }; } "evdi").cardPath
        == "/dev/dri/by-path/platform-evdi.0-card";

    # renderPath is null exactly when hasRenderNode is false -- a permanent driver fact, not an
    # error -- even though `address` IS set (evdi can never have a render node, on any host).
    "renderPath is null when hasRenderNode is false, even with address set" =
      (deviceOf { devices.evdi = evdi // { address = "evdi.0"; }; } "evdi").renderPath == null;
    "renderPath is null for a display-only PCI device with address set" =
      (deviceOf { devices.ast = ast // { address = "0000:05:00.0"; hasRenderNode = false; }; } "ast").renderPath
        == null;

    # The read-time enforcement itself: forcing cardPath/renderPath without an address throws,
    # rather than silently returning some other value -- "address is present whenever anything
    # reads cardPath" as a live check (see cardPath's own description for why this cannot be a
    # static `config.assertions` entry).
    "cardPath throws when address is unset" =
      throwsOn { devices.gpu0 = amd; } "gpu0" "cardPath";
    "renderPath throws when address is unset and hasRenderNode is true" =
      throwsOn { devices.gpu0 = amd; } "gpu0" "renderPath";
    # ...but NOT when hasRenderNode is false: there is nothing to throw about, the answer is
    # simply null regardless of address.
    "renderPath does NOT throw when hasRenderNode is false, address or not" =
      !(throwsOn { devices.evdi = evdi; } "evdi" "renderPath");

    # The type: each shape is well-formed for SOME bus, but a malformed string matches neither and
    # must be rejected regardless of which bus it is attached to.
    "a malformed address (neither PCI nor platform shaped) is rejected by the type" =
      !(accepts { devices.gpu0 = amd // { address = "not-an-address"; }; })
      && !(accepts { devices.evdi = evdi // { address = "not-an-address"; }; });
    "a PCI address missing its function suffix is rejected by the type" =
      !(accepts { devices.gpu0 = amd // { address = "0000:0a:00"; }; });
    "a PCI address with an out-of-range function digit is rejected by the type" =
      !(accepts { devices.gpu0 = amd // { address = "0000:0a:00.8"; }; });
    "a platform address with no instance number is rejected by the type" =
      !(accepts { devices.evdi = evdi // { address = "evdi"; }; });

    # A well-formed address of the CORRECT shape for its own bus is simply accepted.
    "a correctly-shaped PCI address is accepted" =
      accepts { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; };
    "a correctly-shaped platform address is accepted" =
      accepts { devices.evdi = evdi // { address = "evdi.0"; }; };

    # The bus/address cross-check: a string that is well-formed for the OTHER bus still passes the
    # type (the type cannot see `bus`), so this has to be an assertion, not a type failure --
    # `accepts` would report these as fine; `refused` is what actually catches them.
    "a PCI-shaped address on a platform device is refused" =
      refused { devices.evdi = evdi // { address = "0000:0a:00.0"; }; };
    "a platform-shaped address on a PCI device is refused" =
      refused { devices.gpu0 = amd // { address = "evdi.0"; }; };
    "matching shapes to their own bus does not trip the mismatch assertion" =
      !(refused {
        devices = {
          gpu0 = amd // { address = "0000:0a:00.0"; };
          evdi = evdi // { address = "evdi.0"; };
        };
      });

    # ── THE `by-name` FAMILY: colon-free, unambiguous, keyed on the device's own name ────────
    #
    # This is the family that actually goes in `WLR_DRM_DEVICES` -- see options.nix's header,
    # "A FOURTH SYMLINK FAMILY", for why `cardPath` (contains colons) and `by-vendor` (ambiguous
    # under a same-vendor collision) both fail that specific job.
    "a PCI device's cardNamePath is by-name, keyed on its own attrset key" =
      (deviceOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; } "gpu0").cardNamePath
        == "/dev/dri/by-name/gpu0-card";
    "a PCI device's renderNamePath is the by-name render counterpart" =
      (deviceOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; } "gpu0").renderNamePath
        == "/dev/dri/by-name/gpu0-render";
    "a platform device's cardNamePath uses its own key too, not the driver name" =
      (deviceOf { devices.dock = evdi // { address = "evdi.0"; }; } "dock").cardNamePath
        == "/dev/dri/by-name/dock-card";

    # renderNamePath is null exactly when hasRenderNode is false, same reasoning as renderPath.
    "renderNamePath is null when hasRenderNode is false, even with address set" =
      (deviceOf { devices.evdi = evdi // { address = "evdi.0"; }; } "evdi").renderNamePath == null;

    # Same read-time enforcement as cardPath/renderPath, for the same reason: a `by-name` symlink
    # this module did not generate a rule for (no `address`) must not be handed out as a live path.
    "cardNamePath throws when address is unset" =
      throwsOn { devices.gpu0 = amd; } "gpu0" "cardNamePath";
    "renderNamePath throws when address is unset and hasRenderNode is true" =
      throwsOn { devices.gpu0 = amd; } "gpu0" "renderNamePath";
    "renderNamePath does NOT throw when hasRenderNode is false, address or not" =
      !(throwsOn { devices.evdi = evdi; } "evdi" "renderNamePath");

    # The generated rule: bus-agnostic KERNELS match, no ATTRS/DRIVERS involved at all.
    "a PCI device with address generates a by-name card+render rule pair via KERNELS" =
      rulesOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-render"
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="0000:0a:00.0", SYMLINK+="dri/by-name/gpu0-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", KERNELS=="0000:0a:00.0", SYMLINK+="dri/by-name/gpu0-render"
      '';
    # No render rule when hasRenderNode is false -- same "don't emit a rule that can never match"
    # discipline as by-vendor/by-driver.
    "a by-name device with no render node generates only its card rule" =
      rulesOf { devices.ast = ast // { address = "0000:05:00.0"; hasRenderNode = false; }; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1a03", SYMLINK+="dri/by-vendor/aspeed-card"
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="0000:05:00.0", SYMLINK+="dri/by-name/ast-card"
      '';
    # A device with no `address` gets no by-name rule at all -- but keeps its by-vendor rule,
    # exactly like it keeps no cardPath (see that option's own default).
    "a device with no address generates by-vendor but no by-name rule" =
      rulesOf { devices.gpu0 = amd; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-render"
      '';
    "a platform device's by-name rule matches KERNELS on the instance name, not DRIVERS" =
      rulesOf { devices.dock = evdi // { address = "evdi.0"; }; } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="evdi", SYMLINK+="dri/by-driver/evdi-card"
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="evdi.0", SYMLINK+="dri/by-name/dock-card"
      '';

    # ── boundLocally: a consumer whose /dev is a renamed subset of the host's ─────────────────
    #
    # See options.nix's header, "A FIFTH STRUCTURAL LIMIT", for the full shape this closes: a
    # container that shares its host's sysfs unnamespaced (so the rule below still MATCHES) while
    # keeping a private /dev that never received this device's node at the number the rule would
    # derive. `boundLocally` defaults to `true`, so every case above -- none of which set it --
    # is the baseline this section's cases are diffed against.
    "boundLocally defaults to true" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").boundLocally == true;

    # THE POINT OF THE OPTION: `false` suppresses every rule family for this device -- by-vendor,
    # by-driver, by-name alike -- while the device stays in `devices` itself (forced deeply above
    # by `accepts`, which never touches `rules`).
    "boundLocally = false generates no by-vendor rule" =
      rulesOf { devices.gpu0 = amd // { boundLocally = false; }; } == "";
    "boundLocally = false generates no by-driver rule" =
      rulesOf { devices.dock = evdi // { boundLocally = false; }; } == "";
    "boundLocally = false generates no by-name rule even with address set" =
      rulesOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; boundLocally = false; }; } == "";
    "boundLocally = false does not remove the device from the inventory" =
      accepts { devices.gpu0 = amd // { boundLocally = false; }; }
      && (deviceOf { devices.gpu0 = amd // { boundLocally = false; }; } "gpu0").boundLocally == false;

    # A mixed inventory: only the bound-locally device gets rules, and the other's absence must
    # not disturb them (this is a real dual-GPU desktop shape -- one card genuinely reachable
    # here, one that is not).
    "boundLocally = false on one device leaves the other's rules untouched" =
      rulesOf {
        devices = {
          gpu0 = amd // { address = "0000:0a:00.0"; };
          ast = ast // { address = "0000:04:00.0"; hasRenderNode = false; boundLocally = false; };
        };
      } == ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/by-vendor/amd-render"
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="0000:0a:00.0", SYMLINK+="dri/by-name/gpu0-card"
        SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", KERNELS=="0000:0a:00.0", SYMLINK+="dri/by-name/gpu0-render"
      '';

    # `boundLocally = false` must not make an otherwise-invalid entry pass -- it is an exemption
    # from RULE GENERATION, never from the inventory's own correctness checks (the same relation
    # `sharedSystemMemory` has to `missingPciVram`).
    "boundLocally = false does not exempt a device from its own required fields" =
      refused { devices.gpu0 = { vendor = "amd"; boundLocally = false; }; };

    # boundLocally = false removes a device from the same-vendor AMBIGUITY check too, not only
    # from `rules` -- correct, because a device excluded from rule generation cannot collide with
    # a sibling's rule it will never produce.
    "two same-vendor devices, one boundLocally = false, are not ambiguous" =
      !(refused {
        enable = true;
        devices = {
          gpu0 = amd;
          gpu1 = amd // { vramMiB = 8192; boundLocally = false; };
        };
      });

    # THE POINT OF THE FAMILY: two devices sharing a vendor are refused a distinct `by-vendor`
    # symlink (see the ambiguity case below), but each still gets its OWN, unambiguous `by-name`
    # rule the moment each carries its own `address` -- because `KERNELS==` matches the SLOT, and
    # two cards never share a slot even when they are identical silicon.
    "two same-vendor devices each get a distinct by-name rule when both declare an address" =
      let
        r = rulesOf {
          devices = {
            gpu0 = amd // { address = "0000:0a:00.0"; };
            gpu1 = amd // { vramMiB = 8192; address = "0000:0b:00.0"; };
          };
        };
      in
      lib.hasInfix ''KERNELS=="0000:0a:00.0", SYMLINK+="dri/by-name/gpu0-card"'' r
      && lib.hasInfix ''KERNELS=="0000:0b:00.0", SYMLINK+="dri/by-name/gpu1-card"'' r;

    # ── THE DEVICE-NAME GUARD: a colon in the name must be refused, not silently reproduced ──
    #
    # This is the whole reason `by-name` is safe to put in `WLR_DRM_DEVICES` in the first place --
    # see options.nix's `unsafeDeviceNames` and its assertion for why this has to be an assertion
    # (an attrset KEY, unlike `vendor`, is not a `mkOption`-typed field a type can constrain).
    "a device name containing a colon is refused" =
      refused { devices."gp:u0" = amd // { address = "0000:0a:00.0"; }; };
    # Refused even with no `address` at all and no host plane enabled -- ungated, like the
    # required-field checks: wrong the moment it is written, not only once a rule is generated.
    "a device name containing a colon is refused even on a facts-only host" =
      refused { devices."gp:u0" = amd; };
    "a device name containing a slash is refused" =
      refused { devices."gp/u0" = amd; };
    # Letters, digits, underscore and hyphen are all the existing `vendor`/`driver` fields already
    # allow -- a device name is held to the identical bar, not a stricter one.
    "a device name using digits, underscore and hyphen is accepted" =
      !(refused { devices."gpu-0_1" = amd; });

    # ── secondaryFunctions: the OTHER PCI functions of the same physical card ──────────────
    #
    # Shipped 2026-08-01 (commit 3387b01) with no test at all -- this section is that gap
    # closed. The option records a FACT (another function of this card exists, at a sibling PCI
    # address) and derives a read-only `devicePath` from it; it generates no udev rule of its
    # own, which the last case below pins.
    "devicePath resolves the /dev/snd/by-path spelling for subsystem = sound" =
      (deviceOf {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = { address = "0000:0a:00.1"; subsystem = "sound"; };
        };
      } "gpu0").secondaryFunctions.audio.devicePath
        == "/dev/snd/by-path/pci-0000:0a:00.1";

    # A device with no secondaryFunctions declared is unaffected -- the default (`{ }`) is inert.
    "no secondaryFunctions declared defaults to an empty attrset" =
      (deviceOf { devices.gpu0 = amd; } "gpu0").secondaryFunctions == { };
    "a device with no secondaryFunctions is accepted exactly as before" =
      accepts { devices.gpu0 = amd; };

    # The enum rejects an unknown value at EVAL TIME, the same way `bus = "usb"` is rejected
    # above -- before `devicePath`'s own `throw` branch (dead code today; reachable only if the
    # enum ever grows a class with no matching `devicePath` branch) is ever in play.
    "an unknown subsystem is rejected by the enum at eval time" =
      !(accepts {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = { address = "0000:0a:00.1"; subsystem = "video"; };
        };
      });

    # THE SIBLING CHECK, tested both directions. A discrete GPU's audio function shares
    # domain:bus:device with its DRM function, differing only in the function digit -- that is
    # what "one PCI device, several functions" means in PCI config space, not a style preference
    # (see options.nix's `secondaryFunctionSiblingMismatches` for the full argument on why a
    # mismatch here is asserted rather than left as an unenforced description in the option's
    # doc comment).
    "a secondary function sharing the parent's domain:bus:device is accepted" =
      !(refused {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = { address = "0000:0a:00.1"; subsystem = "sound"; };
        };
      });
    "a secondary function on a different DEVICE than the parent's is refused" =
      refused {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = { address = "0000:0a:01.1"; subsystem = "sound"; };
        };
      };
    "a secondary function on a different BUS than the parent's is refused" =
      refused {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = { address = "0000:0b:00.1"; subsystem = "sound"; };
        };
      };
    # Negative-space confirmation that the check is keyed on domain:bus:device and NOT on the
    # whole address string differing at all: two functions that differ only in their function
    # digit -- the normal, expected shape -- must not trip it, including with a second sibling
    # beside the first.
    "differing only in the function digit does not trip the sibling check" =
      !(refused {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions = {
            audio = { address = "0000:0a:00.1"; subsystem = "sound"; };
            other = { address = "0000:0a:00.2"; subsystem = "sound"; };
          };
        };
      });
    # The check has nothing to compare against when the PARENT itself declares no `address` --
    # that gap is `address`'s own concern (it is optional; see that option's description), not
    # this check's to also demand.
    "the sibling check does not fire when the parent declares no address at all" =
      !(refused {
        devices.gpu0 = amd // {
          secondaryFunctions.audio = { address = "0000:0a:00.1"; subsystem = "sound"; };
        };
      });

    # THE POINT OF THE OPTION: it records a fact, it does not generate a rule. Declaring a
    # secondary function -- including its optional `role` -- must not change the emitted udev
    # rules by one byte, so nobody later "improves" this into generating a rule by accident.
    "declaring a secondary function does not change the emitted udev rules at all" =
      rulesOf {
        devices.gpu0 = amd // {
          address = "0000:0a:00.0";
          secondaryFunctions.audio = {
            address = "0000:0a:00.1";
            subsystem = "sound";
            role = "HDMI/DP audio out";
          };
        };
      } == rulesOf { devices.gpu0 = amd // { address = "0000:0a:00.0"; }; };

    # ── toolchain.vendor vs the inventory, compared by PCI ID ───────────────────────────────
    # The two fields use different vocabularies on purpose, so they reconcile through pciId.
    "a toolchain vendor with no matching card is refused" =
      refusedBoth {
        nixgpu.toolchain.vendor = "nvidia";
        nixgpu.stableDevicePaths.devices.gpu0 = amd;
      };
    "a toolchain vendor WITH a matching card is accepted" =
      !(refusedBoth {
        nixgpu.toolchain.vendor = "amd";
        nixgpu.stableDevicePaths.devices.gpu0 = amd;
      });
    # Free-form inventory naming must not break the match -- it is by pciId, never by name.
    "a differently-named but PCI-matching card is accepted" =
      !(refusedBoth {
        nixgpu.toolchain.vendor = "amd";
        nixgpu.stableDevicePaths.devices.gpu0 = amd // { vendor = "radeon"; };
      });
    # Silent when either side is absent: coherence check, not a completeness requirement.
    "a toolchain vendor with no inventory at all is accepted" =
      !(refusedBoth { nixgpu.toolchain.vendor = "amd"; });
    "an inventory with no toolchain vendor is accepted" =
      !(refusedBoth { nixgpu.stableDevicePaths.devices.gpu0 = amd; });
    # A platform-only inventory has no PCI ID to compare against, so the cross-check has nothing to
    # contradict -- and must not read the comparison as "your card is not in the inventory". This
    # is the real laptop shape: the DisplayLink card recorded, the iGPU not yet.
    "an inventory of only platform devices does not contradict a toolchain vendor" =
      !(refusedBoth {
        nixgpu.toolchain.vendor = "amd";
        nixgpu.stableDevicePaths.devices.evdi = evdi;
      });
    # The real dual-GPU desktop shape: ASPEED framebuffer + AMD card, toolchain wants AMD.
    "an ASPEED framebuffer beside the matching AMD card is accepted" =
      !(refusedBoth {
        nixgpu.toolchain.vendor = "amd";
        nixgpu.stableDevicePaths.devices = { gpu0 = amd; ast = ast; };
      });
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.runCommand "nixgpu-stable-device-paths-ok" { } "touch $out"
else throw ''
  nixgpu: stable-device-paths guards are wrong. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
