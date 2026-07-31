# modules/displaylink/nixos.nix — the NixOS implementation of nixgpu.displaylink.
#
# One long-running system service, and the interesting part is entirely in what it depends on.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixgpu.displaylink;

  # Same-repo defensive reads: `nixgpu.evdi` is a sibling module in this flake and a host may run
  # this userland WITHOUT it -- that is the container shape, where the kernel (and therefore the
  # module) belongs to another system entirely. `or` is the right tool for a same-repo read; the
  # cross-repo defect class it is blind to (an option renamed underneath a reader that ships
  # separately) cannot arise between two files that version together.
  evdiEnabled = config.nixgpu.evdi.enable or false;
  evdiComposed = config.nixgpu ? evdi;

  # The userland dlopen()s libevdi, so the two halves must agree. `is_evdi_compatible()` gates on
  # `major == 1 && minor >= 9` rather than an exact match, so this is not a version lockstep in the
  # strict sense -- but the pairing that is guaranteed correct is the one where both halves come
  # from the same evdi derivation, and taking it costs nothing. Falls back to the kernel's own
  # evdi, which is exactly what `nixgpu.evdi` would have used.
  evdiPackage =
    if (config.nixgpu.evdi.package or null) != null
    then config.nixgpu.evdi.package
    else config.boot.kernelPackages.evdi;

  package =
    if cfg.package != null
    then cfg.package
    else pkgs.displaylink.override { evdi = evdiPackage; };

  binary = if cfg.binary != null then cfg.binary else "${package}/bin/DisplayLinkManager";

  # nixpkgs ships its own DisplayLink module, keyed on this list. Two DisplayLinkManagers on one
  # USB device is not a supported state -- and the collision is not even the worst part; see the
  # assertion for what actually goes wrong.
  nixpkgsModuleActive = lib.elem "displaylink" (config.services.xserver.videoDrivers or [ ]);
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !nixpkgsModuleActive;
        message = ''
          nixgpu.displaylink.enable is set AND `services.xserver.videoDrivers` contains
          "displaylink", which activates nixpkgs' own DisplayLink module
          (nixos/modules/hardware/video/displaylink.nix). Pick one.

          They are not additive. nixpkgs' module runs its own `dlm.service` on the same binary and
          the same USB device, and it also sets up the X11 half -- an xorg.conf.d OutputClass, an
          `xrandr --setprovideroutputsource` session hook, a conflict with getty@tty7 -- none of
          which applies on a Wayland host, which is the reason this module exists at all.

          Keep `nixgpu.displaylink` on a Wayland host and drop "displaylink" from
          `services.xserver.videoDrivers`; on an X11 host, use nixpkgs' module and leave this one
          disabled.
        '';
      }
    ];

    warnings = lib.optional (evdiComposed && !evdiEnabled) ''
      nixgpu.displaylink.enable is set but nixgpu.evdi.enable is not, on the same system.

      DisplayLinkManager draws through the evdi virtual DRM device and does nothing without it.
      This is only correct if the kernel module comes from OUTSIDE this configuration -- the
      container case, where the host owns the kernel, loads evdi there, and passes the DRM node in.
      That split is supported and is why these are two modules; this warning exists because the
      other way to reach this state is simply forgetting the kernel half, and that failure is
      otherwise silent (the manager starts, finds no device, and the dock stays dark).
    '';

    # ── Modelling "evdi must be loaded" ────────────────────────────────────────────────────────
    #
    # `modprobe@evdi.service` is systemd's own templated one-shot (`modprobe -abq evdi`), shipped
    # upstream and enabled in NixOS -- the same mechanism nixpkgs' tee-supplicant and v4l2-relayd
    # modules use to state a module dependency. It is preferred over depending on
    # `systemd-modules-load.service` because it names THIS module: a dependency on the whole
    # modules-load unit is satisfied by that unit succeeding for unrelated reasons, and is failed
    # by any other module on the box failing.
    #
    # `requires` and not `wants`, because the failure modes are not symmetric: without evdi this
    # service cannot do anything at all, and a manager that starts, finds no DRM device and sits
    # there looking healthy is precisely the silent no-op this pair of modules is written to
    # eliminate. Let it fail where the cause is visible.
    #
    # Both are conditional on evdi being enabled HERE. When it is not, the module is loaded by
    # another system (the container case above) and `modprobe@evdi.service` would fail in this one
    # -- turning a correct configuration into a hard boot failure.
    systemd.services.displaylink-manager = {
      description = "DisplayLink Manager (userland for the evdi virtual DRM device)";
      wantedBy = [ "multi-user.target" ];
      after = lib.optional evdiEnabled "modprobe@evdi.service";
      requires = lib.optional evdiEnabled "modprobe@evdi.service";

      serviceConfig = {
        ExecStart = binary;
        # The dock is hot-pluggable and the manager is not: it exits on some USB transitions and is
        # expected to be brought back. Restart-always is what the vendor's own packaging assumes.
        Restart = "always";
        RestartSec = 5;
        # DisplayLinkManager writes its logs to a fixed directory and refuses to start without it.
        LogsDirectory = "displaylink";
      };
    };

    # ── Two things this module deliberately does NOT do ────────────────────────────────────────
    #
    # 1. No `services.udev.packages = [ package ]`. The vendor's rule file contains exactly one
    #    rule, `ENV{SYSTEMD_WANTS}="dlm.service"` on the DisplayLink USB vendor -- it starts a unit
    #    by a name this module does not use, and it would be doing so to start a service that is
    #    already running. Running the manager permanently (rather than USB-triggered) is the right
    #    shape here anyway: with `initial_device_count` the DRM devices are permanent, so there is
    #    no device to wait for, and a resident manager removes a whole class of "the dock was
    #    plugged in before/after X" ordering bugs.
    #
    # 2. No suspend/resume handshake. DisplayLinkManager takes suspend and resume notifications
    #    over an undocumented FIFO pair in /tmp (nixpkgs' module drives it from
    #    `powerManagement.powerDownCommands`). It is not wired here: it is a fragile,
    #    unversioned vendor protocol on world-writable paths, and DisplayLink-over-Wayland
    #    resume is documented-unreliable regardless of it -- a lock/unlock cycle is often needed
    #    to force a redraw either way. Stated as a known limitation rather than papered over with
    #    a handshake that does not actually fix the symptom.
  };
}
