{
  description = "nixgpu - priority-based sharing of one GPU across Kubernetes, containers, and the desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # Extraction in progress: this repo is being pulled out of a private
      # production configuration. CONTRACT.md (the behavior spec) is the first
      # real artifact. Planned module attrset, in extraction order:
      #
      #   kubernetesModules.device-tokens    - compute/vcn lane split (generic device plugin)
      #   kubernetesModules.priority-ladder  - the desktop > interactive > besteffort ladder
      #   kubernetesModules.pressure-watcher - reactive kill-reclaim + GTT spill detection
      #   kubernetesModules.ondemand-front   - Sablier + Caddy honest waiting page (B7)
      #   nixosModules.kernel                - optional dmem/TTM eviction-order patches
      #
      # Kubernetes modules target a nixidy-rendered, Argo CD-synced cluster
      # (see the sibling nixk3s project); NixOS modules target the host.
      kubernetesModules = { };
      nixosModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
