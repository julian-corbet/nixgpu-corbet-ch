{
  description = "nixgpu - priority-based sharing of one GPU across Kubernetes, containers, and the desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders the modules below to Argo CD manifests. A real input, not
    # just a name in a comment: without it there is no module system to evaluate
    # these against, and `nix flake check` passes by checking nothing.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixhost is an input for EXACTLY ONE THING: `lib.probeFact` (`lib/facts.nix`) -- the shared,
    # plain-function fix for the cross-namespace defensive-read defect class, where a bare
    # `config.nixfoo.bar or fallback` cannot tell "nixfoo is not composed here" (legitimate,
    # silent) from "nixfoo IS composed but `bar` moved, was renamed, or its value was rejected by
    # its own type" (a defect that hides exactly as silently). The one place this repo has such a
    # read is modules/displaylink/system-manager.nix, asking whether nixarch's package reconciler
    # is actually enabled -- see that file's header for why that single fact is worth an input.
    #
    # nixhost is the namespace hub, not a sibling domain, and this stays a one-way edge: nixhost
    # reads THIS repo's device inventory through the same `probeFact`, and takes no flake input on
    # nixgpu to do it. Closed over in the module outputs below as a plain function argument, never
    # `_module.args`, so a consumer importing a module here sees an ordinary module function and
    # never needs to know `probeFact` exists.
    nixhost = {
      url = "github:julian-corbet/nixhost-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixhost }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      inherit (nixhost.lib) probeFact;
    in
    {
      # LEVEL 2 / EDGE modules (nixhost vocabulary: an `environments.<name>` is
      # Level 2, a projection of a Level-1 host resource). `<host>.gpu.apps`
      # (bare-metal/podman tenants) and `<host>.k3s.gpu.apps` (pod tenants) are two
      # independent consumer sets standing on the SAME Level-1 `<host>.resources.gpu`
      # — these four modules are the edge property between those two branches, not a
      # part of either one. They render as nixidy modules (github:arnarg/nixidy),
      # imported into a nixidy env's `modules` list and rendered to manifests for
      # Argo CD (see the sibling nixk3s project for the spine). Extracted from a
      # production single-GPU cluster; the generalized forms have been running
      # live there since 2026-07-22, adopted back in-place — see README.md's
      # Status section for the verification detail (bench + adversarial stress).
      #
      # All four are arbitration, and none of them uses the GPU: device-tokens
      # advertises the lanes, priority-ladder decides who wins a conflict,
      # pressure-watcher evicts by priority when the card is oversubscribed, and
      # ondemand-front is the waiting room that lets a rested workload give the
      # card back. An app that wants the card declares against these and
      # implements no part of them.
      #
      # Why these stay in the same repo as the Level-1 modules below rather than a
      # separate arbiter repo: see README.md "Why one repo, not two".
      nixidyModules = {
        device-tokens = ./modules/device-tokens;
        priority-ladder = ./modules/priority-ladder;
        pressure-watcher = ./modules/pressure-watcher;
        ondemand-front = ./modules/ondemand-front;
      };

      # LEVEL 1 modules (nixhost vocabulary: the host itself, `<host>.resources.gpu`
      # -- true of the machine whether or not anything ever contends for the card).
      # Everything above is Level 2 / edge, about sharing a card that already works;
      # these are about the machine underneath it. Both planes are offered, because a
      # GPU host is not necessarily a NixOS host -- an Arch workstation with a real
      # card is still a GPU host, and until `toolchain` landed this project had
      # nothing at all to say to one.
      nixosModules = {
        # The host's COMPLETE DRM device inventory + stable /dev/dri symlinks generated from it --
        # see modules/stable-device-paths/. Host-side counterpart to device-tokens' `paths`: enable
        # this on any node running that module so its default paths resolve correctly regardless of
        # DRM enumeration order. Offered on BOTH planes (see systemManagerModules below) -- an Arch
        # laptop with a single card hits the identical hazard the moment a DisplayLink dock adds an
        # `evdi` node.
        stableDevicePaths = { ... }: {
          imports = [ ./modules/stable-device-paths/options.nix ./modules/stable-device-paths/nixos.nix ];
        };

        # The vendor compute runtime (CUDA / ROCm / oneAPI class), resolved to nixpkgs attributes.
        toolchain = { ... }: {
          imports = [ ./modules/toolchain/options.nix ./modules/toolchain/nixos.nix ];
        };

        # evdi: the virtual DRM device a DisplayLink dock draws through. A GPU-contention fact,
        # not a peripheral -- it takes DRM minors and renumbers every card probed after it.
        evdi = { ... }: {
          imports = [ ./modules/evdi/options.nix ./modules/evdi/nixos.nix ];
        };

        # DisplayLinkManager: evdi's proprietary userland. A SEPARATE module from `evdi` on
        # purpose -- the two halves are independently placeable, and in the container case they do
        # not even run on the same system.
        displaylink = { ... }: {
          imports = [ ./modules/displaylink/options.nix ./modules/displaylink/nixos.nix ];
        };

        default = self.nixosModules.stableDevicePaths;
      };

      # Arch/CachyOS plane. `toolchain` declares pacman names into nixarch.packages.pacman, so it
      # pairs with nixarch.systemManagerModules.packages: this module says WHAT, nixarch's own
      # reconciler installs it. Only one module in the class, so it is trivially the default.
      systemManagerModules = {
        toolchain = { ... }: {
          imports = [ ./modules/toolchain/options.nix ./modules/toolchain/system-manager.nix ];
        };

        # Same mechanism as nixosModules.stableDevicePaths, written through environment.etc
        # because system-manager has no services.udev. A single-GPU laptop is not exempt from
        # DRM renumbering -- a DisplayLink dock inserts an `evdi` node and shifts everything
        # after it, which is exactly how this surfaced on a two-GPU host on 2026-07-29.
        stableDevicePaths = { ... }: {
          imports = [ ./modules/stable-device-paths/options.nix ./modules/stable-device-paths/system-manager.nix ];
        };

        # evdi on a foreign distribution: the module parameter and the load-at-boot instruction as
        # ordinary /etc files, plus the pacman name of the DKMS package. Requires
        # nixarch.systemManagerModules.packages -- see that plane's header for why that
        # requirement cannot be made conditional.
        evdi = { ... }: {
          imports = [ ./modules/evdi/options.nix ./modules/evdi/system-manager.nix ];
        };

        # DisplayLinkManager on Arch, where pacman owns the binary and the unit. `probeFact` is
        # closed over HERE, before the module system ever sees the result, so the exported value
        # is a plain module function taking the usual `{ config, lib, ... }`.
        displaylink = { ... }: {
          imports = [
            ./modules/displaylink/options.nix
            (import ./modules/displaylink/system-manager.nix { inherit probeFact; })
          ];
        };

        default = self.systemManagerModules.toolchain;
      };

      # Planned NixOS-side module, not yet extracted:
      #   nixosModules.kernel - optional dmem accounting / TTM eviction-order patches
      #   (the pressure-watcher core runs on stock kernels reading sysfs)

      lib = {
        # Temporary source-level correction for evdi v1.15.0's broken USB-removal path. Host
        # modules decide how to build against their exact kernel; this repo owns the behavior and
        # the pinned upstream commits. See lib/evdi-hot-unplug.nix.
        evdiHotUnplug = { pkgs }: import ./lib/evdi-hot-unplug.nix { inherit pkgs; };
      };

      # Renders every nixidy module here against the real module system it
      # targets, from the placeholder values in `examples/all`. This is what makes
      # "these modules evaluate" a checkable claim instead of an assertion in a
      # README.
      #
      # It does NOT prove the modules arbitrate correctly on real hardware. That
      # needs a card and a contended workload; this needs neither. The two claims
      # are kept apart deliberately — see the README's status section.
      checks = forAllSystems (system:
        let
          env = nixidy.lib.mkEnv {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = nixpkgs.lib.attrValues self.nixidyModules
              ++ [ ./examples/all/values.nix ];
          };
        in
        {
          all-modules-render = env.environmentPackage;

          # The host-side plane, which `all-modules-render` does not touch at all: that check
          # renders `nixidyModules` only, so `nixosModules.stableDevicePaths` -- and the device
          # inventory that is now the single owner of the vendor/PCI-ID fact -- had `nix flake
          # check` passing while covering none of it.
          stable-device-paths = import ./checks/stable-device-paths.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };

          # The DisplayLink pair, both planes each. Evaluated against stub host planes rather than
          # a real NixOS/system-manager eval: what is worth pinning here is the exact TEXT these
          # modules generate (a modprobe line whose absence is a silent no-op, an ExecStart), and
          # a stub gets at those values without either backend's closure.
          evdi = import ./checks/evdi.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };

          evdi-hot-unplug = import ./checks/evdi-hot-unplug.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };

          displaylink = import ./checks/displaylink.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit probeFact;
          };

          # The vendor × capability × platform model (../lib/catalogue.nix, ../lib/resolve.nix,
          # ./modules/toolchain/). Not covered by any check above -- `all-modules-render` renders
          # only `nixidyModules` (Level 2/edge), and `toolchain` is Level 1, offered on both the
          # NixOS and system-manager planes like stableDevicePaths/evdi/displaylink above.
          toolchain = import ./checks/toolchain.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit nixpkgs system;
          };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
