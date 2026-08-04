#
# The channel resolution: pure functions from a list of SELECTED catalogue entries (already
# flattened out of ../lib/catalogue.nix's capability -> vendor -> [ entries ] shape by
# ../modules/toolchain/options.nix) to the per-channel outputs a platform backend consumes.
#
# SAME SPLIT AS THE SIBLING nixfs/nixoffice REPOS, and for the same reason (see either's own
# lib/resolve.nix header): inline, the only input these could ever be tested against is the real
# catalogue, which is a table of what happens to be selected today, not a set of fixtures chosen to
# exercise every branch. ../checks/toolchain.nix feeds these fixture tables containing the entry
# shapes the real catalogue does not happen to exercise.
#
# EVERY CHANNEL IS INDEPENDENTLY NULLABLE, IN BOTH DIRECTIONS -- unlike nixfs (only `arch` is ever
# null in practice) this catalogue genuinely uses both: `nixpkgs = null` where only Arch has an
# equivalent (common here -- a chunk of "what a vendor needs" is either baked into nixpkgs' `mesa`
# already or is a NixOS *option*, not a package), `arch = null` where only nixpkgs would (none
# today, same as nixfs's own present catalogue, kept alive by fixtures). So neither channel's
# package name can serve as an entry's identity; `name` (attached by ../modules/toolchain/options.nix
# when it flattens the catalogue -- the entry's `arch` name if it has one, else its `nixpkgs` name)
# is what anything reporting about an entry reports it by.
{ lib }:
rec {
  # Official-repo pacman names. `aur = true` entries are held back for aurPackages below: `pacman
  # -S` cannot resolve an AUR name and fails the WHOLE transaction on "target not found", taking
  # every other package in the same converge with it.
  archPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && !(t.aur or false)) selected));

  aurPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && (t.aur or false)) selected));

  # nixpkgs attribute names -- what the NixOS backend installs. Gated on nixpkgs being present at
  # all: unlike nixfs, where every real entry carries one, this catalogue has genuine gaps
  # (gaming32's lib32-* entries, the Vulkan ICD entries, intel-npu-compiler) with nothing to name.
  packageNames = selected:
    lib.unique (map (t: t.nixpkgs) (lib.filter (t: (t.nixpkgs or null) != null) selected));

  # Selected entries with no Arch package at all (official repo or AUR) -- named by the entry's own
  # `name` (its catalogue identity), the same discipline nixfs's `unavailableOnArch` uses. Empty for
  # the real catalogue today; kept alive by a fixture in ../checks/toolchain.nix.
  unavailableOnArch = selected:
    lib.unique (map (t: t.name) (lib.filter (t: (t.arch or null) == null) selected));

  # The mirror image, named the same way nixoffice's sibling function is (see that repo's own
  # lib/resolve.nix header for the bug this split exists to prevent: a filter that names entries by
  # a channel they might not have cannot report the entries that lack it). NOT empty for the real
  # catalogue -- gaming32 and several `display` entries genuinely have no nixpkgs equivalent, which
  # is exactly the case nixfs never had to model at all.
  unavailableOnNixos = selected:
    lib.unique (map (t: t.name) (lib.filter (t: (t.nixpkgs or null) == null) selected));
}
