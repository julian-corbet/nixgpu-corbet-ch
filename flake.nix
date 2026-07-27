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
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # nixidy modules (github:arnarg/nixidy) — imported into a nixidy env's
      # `modules` list and rendered to manifests for Argo CD (see the sibling
      # nixk3s project for the spine). Extracted from a production single-GPU
      # cluster; generalized forms not yet re-verified live.
      #
      # All four are arbitration, and none of them uses the GPU: device-tokens
      # advertises the lanes, priority-ladder decides who wins a conflict,
      # pressure-watcher evicts by priority when the card is oversubscribed, and
      # ondemand-front is the waiting room that lets a rested workload give the
      # card back. An app that wants the card declares against these and
      # implements no part of them.
      nixidyModules = {
        device-tokens = ./modules/device-tokens;
        priority-ladder = ./modules/priority-ladder;
        pressure-watcher = ./modules/pressure-watcher;
        ondemand-front = ./modules/ondemand-front;
      };

      # HOST-SIDE modules. Everything above is about sharing a card that already works; these are
      # about the machine underneath it. Both planes are offered, because a GPU host is not
      # necessarily a NixOS host -- an Arch workstation with a real card is still a GPU host, and
      # until `toolchain` landed this project had nothing at all to say to one.
      nixosModules = {
        # vendor-keyed /dev/dri/by-vendor symlinks -- see modules/nixos/stable-device-paths.nix.
        # Host-side counterpart to device-tokens' `paths`: enable this on any node running that
        # module so its default paths resolve correctly regardless of DRM enumeration order.
        stableDevicePaths = ./modules/nixos/stable-device-paths.nix;

        # The vendor compute runtime (CUDA / ROCm / oneAPI class), resolved to nixpkgs attributes.
        toolchain = { ... }: {
          imports = [ ./modules/toolchain/options.nix ./modules/toolchain/nixos.nix ];
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

        default = self.systemManagerModules.toolchain;
      };

      # Planned NixOS-side module, not yet extracted:
      #   nixosModules.kernel - optional dmem accounting / TTM eviction-order patches
      #   (the pressure-watcher core runs on stock kernels reading sysfs)

      lib = { };

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
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
