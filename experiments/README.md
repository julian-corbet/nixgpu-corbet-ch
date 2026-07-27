# Experiments

Runnable experiments with recorded results. Each experiment gets its own
directory with a README stating hypothesis, method, and outcome. Cross-linked
from studies/ where a study motivated it.

| File | What |
|---|---|
| `toolchain-eval.nix` | Confirms `nixgpu.toolchain` resolves to the right pacman names on the Arch plane, that `sdk = false` keeps monitoring rather than emptying the list, and that a disabled or vendorless module installs nothing. |

## Open questions

- **The NixOS vendor tables are not eval-tested.** Asserting on them would force those nixpkgs
  attributes to exist in whatever nixpkgs is in scope, turning a cheap eval into a package-set
  compatibility test against a moving target. Result: a rename in nixpkgs' `rocmPackages` or
  `cudaPackages` would be caught at build time by a consumer, not here. Worth revisiting if this
  project ever pins its own nixpkgs.
- **`intel` is declared but unexercised.** Both planes list Intel packages
  (`intel-compute-runtime` / `intel-oneapi-basekit`), reasoned from the vendor's own layout, but
  no Intel GPU has run this. The AMD and NVIDIA names carry over from a real deployment; the
  Intel ones do not.
