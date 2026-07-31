# Evaluates modules/displaylink/ on BOTH planes, against stub host planes.
#
# Same reasoning as checks/evdi.nix: the module's output is a small number of exact strings and one
# dependency edge, and the interesting failures are all silent ones -- a manager started without
# evdi sits there looking healthy with a dark dock; a `--assume-installed` entry that renders wrong
# suppresses a real dependency with no error until runtime.
#
# `probeFact` is passed in rather than imported, exactly as flake.nix passes it to the module: the
# system-manager plane is a function of it, so a check that stubbed it would be testing a different
# function than the one that ships.
{ pkgs, probeFact, lib ? pkgs.lib }:
let
  common = { lib, ... }: {
    options.assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
    options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    options.systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
  };

  nixosStub = { lib, ... }: {
    # Read (never written) by the NixOS plane, to refuse running beside nixpkgs' own X11-shaped
    # DisplayLink module.
    options.services.xserver.videoDrivers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    options.boot.kernelPackages = lib.mkOption { type = lib.types.attrs; default = { }; };
  };

  smStub = { lib, ... }: {
    options.nixarch.packages = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      assumeInstalled = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  # A real derivation, because `types.package` cannot be satisfied by a fake store path under a
  # pure flake evaluation. It also keeps the check away from `pkgs.displaylink`, which is BOTH
  # unfree and a `requireFile` -- forcing the module's own default here would fail evaluation on
  # the licence check before it ever got to the string being tested.
  driverPkg = pkgs.hello;

  evalNixos = modules: lib.evalModules {
    modules = [ common nixosStub ../modules/displaylink/options.nix ../modules/displaylink/nixos.nix ] ++ modules;
  };

  evalSm = modules: lib.evalModules {
    modules = [
      common
      smStub
      ../modules/displaylink/options.nix
      (import ../modules/displaylink/system-manager.nix { inherit probeFact; })
    ] ++ modules;
  };

  # With the evdi module's OPTIONS composed as well -- the shape of a laptop that owns both halves.
  # Only options.nix, deliberately: the dependency edge under test is expressed from the userland
  # side and reads nothing but `nixgpu.evdi.enable`.
  withEvdi = ../modules/evdi/options.nix;

  unitOf = c: c.systemd.services.displaylink-manager;
  smUnitOf = c: c.systemd.services.nixgpu-displaylink-ensure-running;

  failedAssertions = c: lib.filter (a: !a.assertion) c.assertions;

  results = {
    # ── THE BINARY THE UNIT ACTUALLY RUNS ───────────────────────────────────────────────────
    "ExecStart is derived from the package" =
      (unitOf (evalNixos [{ nixgpu.displaylink = { enable = true; package = driverPkg; }; }]).config).serviceConfig.ExecStart
      == "${driverPkg}/bin/DisplayLinkManager";

    # The escape hatch for a host where the binary is not a Nix package at all -- a vendor
    # installer's tree, or a pacman-owned path reached from a NixOS-side unit.
    "an explicit binary wins over the package" =
      (unitOf (evalNixos [{
        nixgpu.displaylink = { enable = true; package = driverPkg; binary = "/usr/bin/DisplayLinkManager"; };
      }]).config).serviceConfig.ExecStart == "/usr/bin/DisplayLinkManager";

    "a disabled module declares no unit" =
      (evalNixos [{ }]).config.systemd.services == { };

    # ── "evdi must be loaded", modelled ─────────────────────────────────────────────────────
    #
    # `modprobe@evdi.service` names THIS module, where a dependency on the whole
    # systemd-modules-load unit would be satisfied by that unit succeeding for unrelated reasons.
    # `requires` and not `wants`, because a manager that starts, finds no DRM device and reports
    # itself healthy is the silent failure this pair of modules exists to remove.
    "evdi on this host is a hard unit dependency" =
      let
        u = unitOf (evalNixos [
          withEvdi
          { nixgpu.displaylink = { enable = true; package = driverPkg; }; nixgpu.evdi.enable = true; }
        ]).config;
      in
      u.requires == [ "modprobe@evdi.service" ] && u.after == [ "modprobe@evdi.service" ];

    # THE CONTAINER CASE, and the reason the dependency is conditional at all: the kernel module
    # belongs to another system, so `modprobe@evdi.service` would FAIL here -- turning a correct
    # configuration into a hard boot failure.
    "evdi elsewhere means no local modprobe dependency" =
      let
        u = unitOf (evalNixos [
          withEvdi
          { nixgpu.displaylink = { enable = true; package = driverPkg; }; }
        ]).config;
      in
      u.requires == [ ] && u.after == [ ];

    "the userland warns when the kernel half is composed but off" =
      (evalNixos [
        withEvdi
        { nixgpu.displaylink = { enable = true; package = driverPkg; }; }
      ]).config.warnings != [ ];

    "it is silent once the kernel half is on" =
      (evalNixos [
        withEvdi
        { nixgpu.displaylink = { enable = true; package = driverPkg; }; nixgpu.evdi.enable = true; }
      ]).config.warnings == [ ];

    # Not composed at all is the deliberate split -- another system owns the kernel -- and must not
    # be nagged about. Only "composed and off" is ambiguous enough to be worth a word.
    "it is silent when nixgpu.evdi is not composed here at all" =
      (evalNixos [{ nixgpu.displaylink = { enable = true; package = driverPkg; }; }]).config.warnings == [ ];

    # ── REFUSING TO RUN BESIDE nixpkgs' OWN MODULE ──────────────────────────────────────────
    # Two DisplayLinkManagers on one USB device is not a supported state, and nixpkgs' module also
    # brings an X11 configuration that does not apply on the Wayland host this module is for.
    "activating nixpkgs' displaylink module too is refused" =
      failedAssertions (evalNixos [{
        nixgpu.displaylink = { enable = true; package = driverPkg; };
        services.xserver.videoDrivers = [ "displaylink" ];
      }]).config != [ ];

    "an unrelated videoDriver is fine" =
      failedAssertions (evalNixos [{
        nixgpu.displaylink = { enable = true; package = driverPkg; };
        services.xserver.videoDrivers = [ "amdgpu" ];
      }]).config == [ ];

    # ── THE ARCH PLANE: package + the dependency override ───────────────────────────────────
    "the AUR package is declared" =
      (evalSm [{ nixgpu.displaylink.enable = true; nixarch.packages.enable = true; }]).config.nixarch.packages.aur
      == [ "displaylink" ];

    # OFF by default, and that default is the safety property: on a real Arch machine the evdi
    # dependency is genuine, and a `--assume-installed` there suppresses a requirement that should
    # be met -- with no failure until the dock does nothing.
    "assumeEvdiInstalled is off by default" =
      (evalSm [{ nixgpu.displaylink.enable = true; nixarch.packages.enable = true; }]).config.nixarch.packages.assumeInstalled
      == [ ];

    # THE CONTAINER CASE. The AUR package declares `depends=('evdi<1.16')`; pacman cannot see the
    # host kernel that satisfies it, so its only other resolution is a DKMS build that can neither
    # build nor load in a container -- and because nixarch reconciles AUR packages in ONE `paru -S`
    # under `set -eu`, that failure aborts the reconcile for EVERY AUR package on the box.
    "assumeEvdiInstalled renders the virtual package pacman needs" =
      (evalSm [{
        nixgpu.displaylink = { enable = true; assumeEvdiInstalled = true; };
        nixarch.packages.enable = true;
      }]).config.nixarch.packages.assumeInstalled == [ "evdi=1.15.0" ];

    # The version is a RANGE decision (it must satisfy `evdi<1.16`), not a description of what is
    # loaded -- libevdi's own is_evdi_compatible() gates on major==1 && minor>=9.
    "the claimed version is settable" =
      (evalSm [{
        nixgpu.displaylink = { enable = true; assumeEvdiInstalled = true; evdiVirtualVersion = "1.14.15"; };
        nixarch.packages.enable = true;
      }]).config.nixarch.packages.assumeInstalled == [ "evdi=1.14.15" ];

    "a non-version string is refused" =
      !(builtins.tryEval (builtins.deepSeq
        (evalSm [{
          nixgpu.displaylink = { enable = true; evdiVirtualVersion = "1.15.0-beta"; };
        }]).config.nixgpu.displaylink.evdiVirtualVersion "ok")).success;

    # ── THE COMPANION ONESHOT ───────────────────────────────────────────────────────────────
    #
    # Arch never enables a pacman-shipped unit on install and system-manager has no declarative
    # unit-enable, so the shipped service sits installed and dead without this.
    #
    # The absolute /usr/bin/systemctl is load-bearing: system-manager gives every unit it declares
    # a nix-store-ONLY PATH with no /usr/bin at all. The leading `-` is systemd's own
    # ignore-a-failure, which is what keeps a travelling dock (or a box where the package is not
    # installed yet) from failing the whole activation.
    "the companion oneshot starts the pacman-shipped unit" =
      (smUnitOf (evalSm [{
        nixgpu.displaylink.enable = true;
        nixarch.packages.enable = true;
      }]).config).serviceConfig.ExecStart
      == "-/usr/bin/systemctl start --no-block displaylink.service";

    "a custom archUnit is carried through" =
      let
        c = (evalSm [{
          nixgpu.displaylink = { enable = true; archUnit = "dlm.service"; };
          nixarch.packages.enable = true;
        }]).config;
      in
      (smUnitOf c).serviceConfig.ExecStart == "-/usr/bin/systemctl start --no-block dlm.service"
      && lib.elem "dlm.service" (smUnitOf c).after;

    # On the Arch plane evdi arrives through /etc/modules-load.d, so the unit that has actually
    # loaded it is systemd-modules-load.service -- and only when the kernel half is on THIS box.
    "the oneshot waits for modules-load when evdi is local" =
      lib.elem "systemd-modules-load.service"
        (smUnitOf (evalSm [
          withEvdi
          { nixgpu.displaylink.enable = true; nixgpu.evdi.enable = true; nixarch.packages.enable = true; }
        ]).config).after;

    "it does not wait for modules-load when evdi is elsewhere" =
      !(lib.elem "systemd-modules-load.service"
        (smUnitOf (evalSm [
          withEvdi
          { nixgpu.displaylink.enable = true; nixarch.packages.enable = true; }
        ]).config).after);

    # ── THE ONE CROSS-REPO READ, through probeFact ──────────────────────────────────────────
    #
    # Declaring packages into a reconciler that is switched off is inert -- a configuration that
    # reads as done and does nothing, which is the failure class this repo keeps closing. The read
    # goes through `lib.probeFact` because a bare `or false` cannot tell "nixarch is not composed"
    # from "it is composed but `enable` moved" -- both land on the same fallback with no trace.
    "a disabled nixarch reconciler is reported" =
      (evalSm [{ nixgpu.displaylink.enable = true; nixarch.packages.enable = false; }]).config.warnings != [ ];

    "an enabled reconciler is silent" =
      (evalSm [{ nixgpu.displaylink.enable = true; nixarch.packages.enable = true; }]).config.warnings == [ ];

    "a disabled module declares nothing on the Arch plane either" =
      let c = (evalSm [{ nixarch.packages.enable = true; }]).config; in
      c.nixarch.packages.aur == [ ] && c.systemd.services == { } && c.warnings == [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.runCommand "nixgpu-displaylink-ok" { } "touch $out"
else
  throw ''
    nixgpu: displaylink module is wrong. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''
