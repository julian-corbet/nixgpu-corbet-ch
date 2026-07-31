# Evaluates modules/evdi/ on BOTH planes, against stub host planes.
#
# WHY A STUB AND NOT A REAL nixosSystem: what is worth pinning about this module is a handful of
# exact STRINGS, and every one of them fails silently when it is wrong. `initial_device_count`
# defaults to 0 upstream, so a modprobe line that is missing, misspelled or written to a path
# nothing reads produces a module that loads, appears in `lsmod`, and creates no DRM device at all
# -- and every other signal on the box says it worked. A real backend eval would prove the same
# strings at the cost of two backends' closures and (for system-manager) an input this repo does
# not otherwise need.
#
# So both planes are evaluated against the smallest option surface that makes their writes
# meaningful, and the check reads the RESULTING VALUES rather than asserting that evaluation
# succeeded -- an eval that succeeds and produces the wrong text is precisely the failure being
# guarded against.
{ pkgs, lib ? pkgs.lib }:
let
  common = { lib, ... }: {
    options.assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
    options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
  };

  # The NixOS surface this module writes to. `boot.extraModprobeConfig` is `types.lines` for the
  # same reason it is on NixOS: the real host has other things to say to modprobe (a ZFS ARC bound,
  # an audio quirk) and these have to CONCATENATE rather than conflict.
  nixosStub = { lib, ... }: {
    options.boot = {
      kernelModules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      extraModulePackages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      extraModprobeConfig = lib.mkOption { type = lib.types.lines; default = ""; };
      kernelPackages = lib.mkOption { type = lib.types.attrs; default = { }; };
    };
    # Stands in for `pkgs.linuxPackages.evdi` -- a real derivation, because `types.package` cannot
    # be satisfied by a fake store path under a pure flake evaluation (`toDerivation` would call
    # `builtins.storePath`, which pure mode forbids). Any small free package proves the plumbing;
    # what is being checked is WHICH package ends up in extraModulePackages, not what it contains.
    config.boot.kernelPackages = { evdi = kernelEvdi; };
  };

  # The system-manager surface. `environment.etc` entries are modelled loosely (an attrset per
  # destination) because this check is about the destination paths and their content, not about
  # system-manager's own entry schema.
  smStub = { lib, ... }: {
    options.environment.etc = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    options.nixarch.packages = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      assumeInstalled = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  kernelEvdi = pkgs.hello;
  customEvdi = pkgs.coreutils;

  evalNixos = settings: lib.evalModules {
    modules = [
      common
      nixosStub
      ../modules/evdi/options.nix
      ../modules/evdi/nixos.nix
      { nixgpu.evdi = settings; }
    ];
  };

  evalSm = settings: lib.evalModules {
    modules = [
      common
      smStub
      ../modules/evdi/options.nix
      ../modules/evdi/system-manager.nix
      { nixgpu.evdi = settings; }
    ];
  };

  # With the inventory module composed too, which is how a host that declares its DRM devices
  # actually looks -- the completeness warning spans the two.
  evalWithInventory = settings: lib.evalModules {
    modules = [
      common
      nixosStub
      ../modules/stable-device-paths/options.nix
      ../modules/evdi/options.nix
      ../modules/evdi/nixos.nix
      settings
    ];
  };

  # Forces the modprobe line, which is the one value that READS `deviceCount` -- so a value its
  # type rejects surfaces here rather than hiding behind laziness.
  #
  # Deliberately NOT `deepSeq config.boot`: `boot.kernelPackages` and `boot.extraModulePackages`
  # hold real derivations, and deep-forcing a derivation walks its self-referential attributes
  # (`out`, `all`, `override`, ...) until the evaluator runs out of stack. The check would then
  # fail on its own harness rather than on the module.
  accepts = settings: (builtins.tryEval (builtins.deepSeq (evalNixos settings).config.boot.extraModprobeConfig "ok")).success;

  results = {
    # ── THE MODPROBE LINE: the one string whose absence is a silent no-op ───────────────────
    #
    # evdi's `initial_device_count` defaults to 0 (module/evdi_params.c), and `evdi_init()` creates
    # devices only when it is non-zero. A bare `boot.kernelModules = [ "evdi" ]` therefore succeeds
    # and registers NOTHING. This module always writes the parameter; this case is what proves the
    # text is the text modprobe actually parses.
    "deviceCount renders the modprobe option line" =
      (evalNixos { enable = true; deviceCount = 4; }).config.boot.extraModprobeConfig
      == "options evdi initial_device_count=4\n";

    "the default deviceCount is 1, and it is still written explicitly" =
      (evalNixos { enable = true; }).config.boot.extraModprobeConfig
      == "options evdi initial_device_count=1\n";

    # Disabled means disabled: no parameter, no module load, nothing to explain later.
    "a disabled module writes nothing at all" =
      let c = (evalNixos { }).config; in
      c.boot.extraModprobeConfig == "" && c.boot.kernelModules == [ ] && c.boot.extraModulePackages == [ ];

    "the module is loaded at boot" =
      (evalNixos { enable = true; }).config.boot.kernelModules == [ "evdi" ];

    # ── deviceCount's range ─────────────────────────────────────────────────────────────────
    # 0 is REFUSED although it is upstream's own default -- "load the module and create nothing" is
    # never a state worth declaring, and accepting it here would reintroduce the exact silent no-op
    # this module exists to remove. 16 is upstream's EVDI_DEVICE_COUNT_MAX.
    "deviceCount = 0 is refused" = !(accepts { enable = true; deviceCount = 0; });
    "deviceCount = 16 is accepted" = accepts { enable = true; deviceCount = 16; };
    "deviceCount = 17 is refused" = !(accepts { enable = true; deviceCount = 17; });

    # ── WHICH evdi PACKAGE ──────────────────────────────────────────────────────────────────
    # An out-of-tree module must be built against the kernel that will load it, so the default has
    # to come from `boot.kernelPackages` and not from a top-level `pkgs.evdi`.
    "package = null builds the kernel's own evdi" =
      (evalNixos { enable = true; }).config.boot.extraModulePackages == [ kernelEvdi ];
    "an explicit package wins (the clang-built-kernel override case)" =
      (evalNixos { enable = true; package = customEvdi; }).config.boot.extraModulePackages == [ customEvdi ];

    # ── THE ARCH PLANE ──────────────────────────────────────────────────────────────────────
    # system-manager has no `boot.*` at all, so the same two facts become the two files that
    # modprobe and systemd-modules-load already read.
    "the Arch plane writes the same modprobe parameter to /etc/modprobe.d" =
      let e = (evalSm { enable = true; deviceCount = 3; }).config.environment.etc; in
      lib.hasInfix "options evdi initial_device_count=3" e."modprobe.d/nixgpu-evdi.conf".text;

    "the Arch plane asks systemd-modules-load to load it" =
      lib.hasInfix "evdi"
        (evalSm { enable = true; }).config.environment.etc."modules-load.d/nixgpu-evdi.conf".text;

    # ⚠ Not boilerplate: without `replaceExisting`, system-manager SILENTLY DECLINES to write a
    # destination that already exists -- no error, no warning, a module that applies cleanly and
    # changes nothing.
    "both Arch entries take over an existing file" =
      let e = (evalSm { enable = true; }).config.environment.etc; in
      e."modprobe.d/nixgpu-evdi.conf".replaceExisting == true
      && e."modules-load.d/nixgpu-evdi.conf".replaceExisting == true;

    "the Arch plane declares the DKMS package by default" =
      (evalSm { enable = true; }).config.nixarch.packages.aur == [ "evdi-dkms" ];

    # The container shape: the module is loaded by a kernel pacman cannot see, so there is nothing
    # for it to install and declaring one would drag in a DKMS build that can neither build nor
    # load there.
    "archPackage = null declares no package" =
      (evalSm { enable = true; archPackage = null; }).config.nixarch.packages.aur == [ ];

    "a disabled Arch plane writes no files and declares no packages" =
      let c = (evalSm { }).config; in
      c.environment.etc == { } && c.nixarch.packages.aur == [ ];

    # ── THE INVENTORY-COMPLETENESS WARNING ──────────────────────────────────────────────────
    #
    # A non-empty `stableDevicePaths.devices` reads as a COMPLETE list of the host's DRM devices --
    # that is the property a consumer computing the complement of a permitted set depends on. This
    # module is about to create a device; if the table does not name it, the complement is wrong
    # and the restriction that was declared is not the restriction that runs.
    "creating evdi devices against a non-empty inventory that omits them warns" =
      (evalWithInventory {
        nixgpu.evdi.enable = true;
        nixgpu.stableDevicePaths.devices.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      }).config.warnings != [ ];

    # Silent once it IS declared -- and note the shape it has to be declared in: platform bus,
    # driver "evdi", no vendor/pciId anywhere.
    "declaring the evdi device silences it" =
      (evalWithInventory {
        nixgpu.evdi.enable = true;
        nixgpu.stableDevicePaths.devices = {
          gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
          evdi = { bus = "platform"; driver = "evdi"; };
        };
      }).config.warnings == [ ];

    # An EMPTY inventory is a legitimate state ("this host does not track its DRM devices"), not an
    # incomplete one, so it claims nothing and must stay silent. Warning here would make the
    # inventory option unadoptable, which is the failure mode that keeps guards from being written.
    "an empty inventory is silent" =
      (evalWithInventory { nixgpu.evdi.enable = true; }).config.warnings == [ ];

    "a disabled evdi is silent whatever the inventory says" =
      (evalWithInventory {
        nixgpu.stableDevicePaths.devices.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      }).config.warnings == [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.runCommand "nixgpu-evdi-ok" { } "touch $out"
else
  throw ''
    nixgpu: evdi module is wrong. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''
