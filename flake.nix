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
      # nixidy modules (github:arnarg/nixidy) — imported into a nixidy env's
      # `modules` list and rendered to manifests for Argo CD (see the sibling
      # nixk3s project for the spine). Extracted from a production single-GPU
      # cluster; generalized forms not yet re-verified live.
      nixidyModules = {
        device-tokens = ./modules/device-tokens;
        priority-ladder = ./modules/priority-ladder;
        pressure-watcher = ./modules/pressure-watcher;
        ondemand-front = ./modules/ondemand-front;
      };

      # Planned NixOS-side module, not yet extracted:
      #   nixosModules.kernel - optional dmem accounting / TTM eviction-order patches
      #   (the pressure-watcher core runs on stock kernels reading sysfs)
      nixosModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
