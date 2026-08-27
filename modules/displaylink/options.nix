# modules/displaylink/options.nix — DisplayLinkManager, the proprietary userland half of a
# DisplayLink dock. The kernel half is `nixgpu.evdi`, and it may not be on the same machine.
#
# LEVEL 1 (nixosModules/systemManagerModules). It lives in nixgpu because a DisplayLink dock is a
# DRM device with a userspace driver attached: it takes DRM minors, it renumbers the cards probed
# after it, its outputs compete for the same compositor that drives the real GPU, and its transport
# is CPU readback plus USB compression -- so it is GPU-adjacent software all the way down, and
# every consequence of running it is a GPU-contention consequence. Splitting it into a desktop or
# distro repo would put the userland in a different project from the DRM device it creates.
#
# ── THE SPLIT, and why this is a separate module from `nixgpu.evdi` ──────────────────────────
#
# The kernel module and this binary are independently placeable, and on the fleet this was
# extracted from they are not even on the same system: evdi is loaded on the metal, while
# DisplayLinkManager runs inside a container that shares that kernel and has `sys_module` dropped
# from its bounding set -- it can never load a module, however it is configured. The DRM node is
# passed in; the two halves are joined by a device bind and nothing else. One combined module could
# not express that at all. So: `nixgpu.evdi` on whichever system owns the kernel, this module on
# whichever system runs the userland, and on an ordinary laptop those are the same system.
#
# ── WHAT THIS MODULE IS FOR, given nixpkgs already ships a DisplayLink module ────────────────
#
# nixpkgs' `nixos/modules/hardware/video/displaylink.nix` is keyed on
# `services.xserver.videoDrivers = [ "displaylink" ]` and is X11-shaped throughout: it writes an
# xorg.conf.d OutputClass, calls `xrandr --setprovideroutputsource` from a display-manager session
# hook, and conflicts with `getty@tty7`. On a Wayland host none of that applies, and asking for it
# to get the daemon drags in an X server's worth of configuration to run one binary. This module is
# the Wayland-shaped statement of the same thing: run the manager, model its real dependency on
# evdi, and stop. The NixOS plane ASSERTS that the two are not both active -- two
# DisplayLinkManagers on one USB device is not a supported state.
{ lib, ... }:
{
  options.nixgpu.displaylink = {
    enable = lib.mkEnableOption ''
      DisplayLinkManager, the proprietary userland that drives a DisplayLink USB dock through the
      evdi virtual DRM device. Requires evdi to be loaded -- by `nixgpu.evdi` on this system, or by
      whatever owns the kernel if this one is a container
    '';

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "pkgs.displaylink";
      description = ''
        NixOS plane only: the DisplayLink driver package, or null (the default) for
        `pkgs.displaylink` with its `evdi` input overridden to match this host's kernel module --
        see modules/displaylink/nixos.nix for why that override is not optional.

        ⚠ `pkgs.displaylink` is a `requireFile`: the vendor's EULA forbids redistribution, so
        nixpkgs cannot fetch the archive and the build fails with instructions until it has been
        added to the store by hand. That is a property of the software, not of this module, and it
        fails at BUILD time rather than at evaluation -- so a configuration referencing it
        evaluates cleanly on a machine that has never downloaded it.
      '';
    };

    binary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      defaultText = lib.literalExpression ''"''${package}/bin/DisplayLinkManager"'';
      example = "/usr/bin/DisplayLinkManager";
      description = ''
        Absolute path to the manager binary, or null (the default) to derive it from `package`.

        The escape hatch for a host where the binary is genuinely not a Nix package -- an Arch box
        where pacman owns it, a vendor installer's own tree. Kept as a plain string rather than a
        path so it can name a location outside the store without anything trying to copy that
        location into it.
      '';
    };

    archPackage = lib.mkOption {
      type = lib.types.str;
      default = "displaylink";
      description = ''
        Arch/CachyOS plane only: the AUR package that provides DisplayLinkManager and its systemd
        unit, appended to `nixarch.packages.aur`.

        A separate option from `package`, and a string rather than a derivation, for the same
        reason `nixgpu.toolchain` carries a real implementation per plane: pacman takes names, Nix
        takes derivations, and no shim over one list expresses both.
      '';
    };

    archUnit = lib.mkOption {
      type = lib.types.str;
      default = "displaylink.service";
      description = ''
        Arch/CachyOS plane only: the systemd unit the `archPackage` ships. Declared alongside the
        package name rather than hardcoded because the two are one fact -- change the package and
        the unit name can change with it, and a hardcoded name would then silently start nothing.

        Arch never enables a pacman-shipped unit on install, and system-manager has no declarative
        unit-enable of its own, so the Arch plane starts this unit from a companion oneshot. See
        that plane for why it uses `start` and not `restart`.
      '';
    };

    assumeEvdiInstalled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Arch/CachyOS plane only. Declare evdi's pacman dependency satisfied by a VIRTUAL package
        (`nixarch.packages.assumeInstalled`, i.e. pacman's `--assume-installed`) instead of by a
        real one.

        ⚠ SET THIS ONLY IN A CONTAINER, OR WHEREVER evdi COMES FROM OUTSIDE pacman's VIEW. Default
        false, because on an ordinary Arch machine the dependency is real and should be resolved
        normally -- a `--assume-installed` there suppresses a genuine requirement, and that
        failure does not surface at install time. It surfaces at runtime, as a dock that does
        nothing.

        ── THE CASE IT EXISTS FOR, and why it is worth an option ──

        The AUR `displaylink` package declares `depends=('evdi<1.16')`. In a container that
        dependency is genuinely satisfied -- by the HOST's kernel module -- but pacman cannot see a
        host kernel from inside a container, so left alone it resolves the only way it knows and
        pulls in a DKMS evdi package. That package then tries to build against a kernel the
        container does not own (typically: no dkms, no headers, and a /lib/modules tree that is a
        stale copy of the host's), and could never load the result anyway, because `sys_module` is
        dropped from a container's bounding set.

        This also replaces the pacman unit's local `modprobe evdi` pre-start with a condition on
        `/sys/module/evdi`: the container must observe the host-owned module, but must never try to
        load it itself.

        THE BLAST RADIUS IS WHY THIS IS NOT A FOOTNOTE. nixarch reconciles AUR packages in ONE
        `paru -S` transaction under `set -eu`. A failing DKMS build therefore aborts the reconcile
        for EVERY AUR package on the box -- the fonts, the office suite, the entire dev toolbox --
        on every activation and every boot, not just for DisplayLink. One unsatisfiable dependency
        takes down declarative package management wholesale.
      '';
    };

    evdiVirtualVersion = lib.mkOption {
      type = lib.types.strMatching "[0-9]+(\\.[0-9]+)*";
      default = "1.15.0";
      description = ''
        The version claimed for the virtual evdi package when `assumeEvdiInstalled` is set --
        rendered as `evdi=<version>` into `nixarch.packages.assumeInstalled`.

        It has to satisfy the AUR package's `depends=('evdi<1.16')` constraint, so it is a version
        RANGE decision and not a description of what is installed. The default is what the AUR
        `evdi-dkms` package provides, which is the value pacman would have seen had it resolved the
        dependency itself.

        The number deliberately need not equal the version actually loaded, and that is safe for a
        reason worth recording rather than assumed: libevdi's own `is_evdi_compatible()` gates on
        `major == 1 && minor >= 9` (library/evdi_lib.c), not on an exact match. So any 1.9+ module
        satisfies the userland regardless of what this string says; this string only has to satisfy
        PACMAN. (For calibration: DisplayLink 6.3 states it bundles evdi "v1.14.14-5 (3dafd62)",
        and commit 3dafd62 is tag v1.14.15 -- so a host on nixpkgs' evdi 1.14.15 is running
        precisely the vintage the driver was tested against, not merely a compatible one.)
      '';
    };
  };
}
