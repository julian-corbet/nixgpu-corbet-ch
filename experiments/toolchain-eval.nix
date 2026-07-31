# Throwaway eval check for modules/toolchain -- NOT part of the module surface. Confirms the two
# plane implementations resolve the same declared intent into each platform's own package naming,
# and that the sdk/monitoring split actually separates. Safe to delete; nothing imports this file.
#
#   nix-instantiate --eval --strict experiments/toolchain-eval.nix -A ok
#
# Only the Arch plane is asserted on here. The NixOS side resolves to real nixpkgs derivations, so
# checking it would force those attributes to exist in whatever nixpkgs is in scope -- which turns
# a cheap eval into a package-set compatibility test against a moving target. The shapes are
# verified instead by the nixos.nix module parsing and by its own vendor table being total.
{ nixpkgs ? <nixpkgs> }:
let
  lib = (import nixpkgs { }).lib;

  # Stub of the one option the Arch plane writes into. In a real consumer this comes from
  # nixarch.systemManagerModules.packages, whose reconciler actually installs the list.
  pacmanStub = { lib, ... }: {
    options.nixarch.packages.pacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  arch = settings: (lib.evalModules {
    modules = [
      ../modules/toolchain/options.nix
      ../modules/toolchain/system-manager.nix
      pacmanStub
      { nixgpu.toolchain = settings; }
    ];
  }).config.nixarch.packages.pacman;
in
rec {
  amdFull = arch { enable = true; vendor = "amd"; };
  amdNoSdk = arch { enable = true; vendor = "amd"; sdk = false; };
  nvidiaFull = arch { enable = true; vendor = "nvidia"; };
  disabled = arch { enable = false; vendor = "amd"; };
  noVendor = arch { enable = true; };

  # Real vendor package names. If these drift, a real machine gets the wrong multi-gigabyte install.
  amdNamesIntact =
    lib.elem "rocm-hip-sdk" amdFull
    && lib.elem "rocm-opencl-sdk" amdFull
    && lib.elem "rocm-smi-lib" amdFull;
  nvidiaNamesIntact =
    lib.elem "cuda" nvidiaFull
    && lib.elem "cudnn" nvidiaFull
    && lib.elem "nvidia-utils" nvidiaFull;

  # The split is the point: dropping the SDK must leave monitoring behind, not empty the list.
  # A cluster node running prebuilt images wants exactly this shape.
  sdkSeparates = amdNoSdk == [ "rocm-smi-lib" ];

  # Importing the module must never be the thing that installs something.
  disabledIsInert = disabled == [ ];
  noVendorIsInert = noVendor == [ ];

  ok = amdNamesIntact && nvidiaNamesIntact && sdkSeparates && disabledIsInert && noVendorIsInert;
}
