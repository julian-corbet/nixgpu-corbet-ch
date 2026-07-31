# modules/displaylink/system-manager.nix — the Arch/CachyOS implementation of nixgpu.displaylink.
#
# Nothing here builds or runs the manager: on Arch, pacman owns the binary AND the systemd unit.
# This module's whole job is the two things pacman gets wrong on its own, plus the dependency
# override that keeps a container from destroying its own package management.
#
# ── 1. Arch never enables a pacman-shipped unit ──────────────────────────────────────────────
#
# Installing the package leaves `displaylink.service` present and dead, and system-manager has no
# declarative unit-enable of its own. So a companion oneshot starts it -- `wantedBy` gives it both
# a boot run and an activation run, which is what actually keeps the service up across reboots.
#
# `start`, not `restart`: the vendor's own udev rule already stops the service on unplug and starts
# it on hotplug, and restarting it out from under a live session would drop the dock's displays for
# no reason. This only has to cover the case udev does not -- a boot with the dock already
# attached.
#
# The absolute `/usr/bin/systemctl` is load-bearing, not style: system-manager gives every unit it
# declares a nix-store-ONLY PATH with no /usr/bin at all, so a bare `systemctl` would not resolve.
# And the `-` prefix on ExecStart is systemd's own "ignore a non-zero exit", which is what keeps a
# missing or failed unit from failing the whole activation on a box where the package is not
# installed yet or the dock has travelled to another machine.
#
# ── 2. THE DEPENDENCY OVERRIDE, and why it is the important half ─────────────────────────────
#
# See `nixgpu.displaylink.assumeEvdiInstalled` for the full account. In one line: the AUR package
# depends on `evdi<1.16`, a container satisfies that with the HOST's kernel module, pacman cannot
# see a host kernel, and its only other resolution -- a DKMS build -- can neither build nor load
# inside a container. Because nixarch runs ONE `paru -S` transaction under `set -eu`, that failure
# aborts the reconcile for EVERY AUR package on the box, forever, on every boot.
#
# ── 3. WHY THE nixarch WRITES ARE UNCONDITIONAL, AND WHAT probeFact IS ACTUALLY FOR ──────────
#
# `nixarch.packages.{aur,assumeInstalled}` are options nixarch DECLARES and this module SETS. A
# write needs no flake input and no probe -- it is the same direction `nixgpu.toolchain`'s Arch
# plane already writes `nixarch.packages.pacman`. What it does need is nixarch's `packages` module
# composed on the host, and THAT REQUIREMENT CANNOT BE MADE CONDITIONAL. Both ways of trying were
# measured on this nixpkgs (2026-07-31):
#
#   * `lib.mkIf false { nixarch.packages.aur = [ ]; }` still fails with "The option `nixarch' does
#     not exist" -- `mkIf` is pushed DOWN into each attribute before options are matched, so a
#     false condition removes the VALUE, never the attribute NAME.
#   * `lib.optionalAttrs (config ? nixarch) { ... }` is infinite recursion -- deciding an attribute
#     name of this module's `config` from the merged option set requires that set, which requires
#     this module's config attribute names.
#
# So importing this plane requires nixarch's `packages` module, and the option descriptions say so
# instead of leaving it to a module-system error.
#
# That leaves ONE genuine cross-repo READ, and it is the one this module cannot do without: is that
# reconciler actually turned ON. `nixarch.packages.enable` is a real state, independent of
# composition -- a host can compose the module and leave it disabled -- and if it is off, every
# declaration below is inert. That is the failure this whole repo keeps closing: a configuration
# that reads as done and does nothing.
#
# A bare `config.nixarch.packages.enable or false` cannot report it honestly, because it conflates
# "nixarch is not composed here" with "it is composed but `enable` moved, was renamed, or its value
# was rejected by its own type" -- see nixhost's `lib/facts.nix` header for the full defect class
# and the two evaluation traps a naive fix falls into. So the read goes through `lib.probeFact`,
# closed over in flake.nix as a plain function argument (nixarch's own `device-gids` uses the
# identical shape), which means a consumer importing this module sees an ordinary module function
# and never needs to know `probeFact` exists.
#
# Which of its three states are reachable HERE is worth stating precisely, because it is not all
# three: "absent" is unreachable in practice (the unconditional write above would already have
# failed), "unresolved" catches a rename inside a composed nixarch, and "resolved" is the state
# that carries the fact this module actually wants -- true, or the silent-no-op false.
{ probeFact }:
{ lib, config, ... }:
let
  cfg = config.nixgpu.displaylink;

  # Same-repo defensive read -- see modules/displaylink/nixos.nix for why `or` is the right tool
  # between two files that version together.
  evdiEnabled = config.nixgpu.evdi.enable or false;

  reconcilerProbe = probeFact {
    inherit config;
    namespace = "nixarch.packages";
    path = "enable";
    fallback = null;
  };
in
{
  config = lib.mkIf cfg.enable {
    nixarch.packages = {
      aur = [ cfg.archPackage ];

      # `evdi=<version>` -- a VIRTUAL package satisfying the AUR package's `depends=('evdi<1.16')`
      # without letting pacman resolve it to a DKMS build. Off unless asked: on a real Arch machine
      # the dependency is genuine and a `--assume-installed` there suppresses a requirement that
      # should be met, with no failure until the dock does nothing at runtime.
      assumeInstalled = lib.optional cfg.assumeEvdiInstalled "evdi=${cfg.evdiVirtualVersion}";
    };

    systemd.services.nixgpu-displaylink-ensure-running = {
      description = "Ensure the pacman-shipped ${cfg.archUnit} is running (Arch never enables a shipped unit)";

      # After the unit it starts, so a boot where systemd is already bringing it up does not race
      # this oneshot. And after modules-load when the kernel half is on THIS machine: on the Arch
      # plane evdi arrives via /etc/modules-load.d, so `systemd-modules-load.service` is the unit
      # that has actually loaded it. (The NixOS plane can be more precise and depend on
      # `modprobe@evdi.service`; system-manager configures a foreign distribution's running
      # systemd, where that template exists but naming the file-driven loader is the honest
      # statement of how the module actually gets in.)
      after = [ cfg.archUnit ] ++ lib.optional evdiEnabled "systemd-modules-load.service";

      # multi-user.target -- remapped to system-manager.target on a live system-manager machine --
      # so this runs on every activation as well as every boot. A sysinit-wanted unit would
      # silently never fire on activation, sysinit being long past by then.
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Leading `-`: ignore a non-zero exit (see this file's header). `--no-block` so a manager
        # that takes its time coming up does not stall activation behind it.
        ExecStart = "-/usr/bin/systemctl start --no-block ${cfg.archUnit}";
      };
    };

    warnings =
      reconcilerProbe.warnings
      ++ lib.optional (reconcilerProbe.state == "resolved" && reconcilerProbe.value != true) ''
        nixgpu.displaylink.enable is set, and this module has declared "${cfg.archPackage}" into
        nixarch.packages.aur -- but nixarch.packages.enable is false, so nothing reconciles that
        list and the package will never be installed.

        The companion unit below would then run on every boot and every activation, trying to start
        a ${cfg.archUnit} that pacman never installed. Its ExecStart ignores that failure by design
        (a travelling dock is a legitimate reason for the unit to be absent), so this
        misconfiguration has no runtime symptom at all beyond a dock that does nothing.

        Set `nixarch.packages.enable = true`, or install "${cfg.archPackage}" by some other means
        and stop declaring it here.
      '';
  };
}
