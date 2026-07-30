# Evaluates modules/stable-device-paths/ for real: the device inventory's field guards, the derived
# vendor map, and the same-vendor refusal.
#
# WHY THIS FILE EXISTS AT ALL: this repo's only check was `all-modules-render`, a nixidy render of
# `nixidyModules`. It never evaluates `nixosModules.stableDevicePaths` at any point, so the entire
# host-side plane -- including the inventory this module gained when it became the single owner of
# the vendor/PCI-ID fact -- shipped with `nix flake check` passing and covering none of it.
#
# The guards below are TYPE-level rather than assertions, deliberately, and this check pins that
# distinction: a `config`-section assertion in this module only fires when something reads the
# option, and a facts-only host (inventory declared, no host plane enabled) reads nothing. Every
# case here is evaluated with `enable` unset for exactly that reason.
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

  # Forces the inventory deeply, so a type error cannot hide behind laziness.
  accepts = settings:
    (builtins.tryEval (builtins.deepSeq
      (eval settings).config.nixgpu.stableDevicePaths.devices "ok")).success;

  # Forces the DERIVED map.
  vendorsOf = settings:
    builtins.tryEval (builtins.deepSeq
      (eval settings).config.nixgpu.stableDevicePaths.vendors
      (eval settings).config.nixgpu.stableDevicePaths.vendors);

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

    # ── THE DERIVED MAP ─────────────────────────────────────────────────────────────────────
    "vendors is derived from the inventory, not hand-typed" =
      let v = vendorsOf { devices = { gpu0 = amd; ast = ast; }; };
      in v.success && v.value == { amd = "0x1002"; aspeed = "0x1a03"; };

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
    # The real devhome shape: ASPEED framebuffer + AMD card, toolchain wants AMD.
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
