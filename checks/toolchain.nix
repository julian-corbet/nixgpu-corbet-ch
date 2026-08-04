# checks/toolchain.nix — EVAL-TIME tests for the vendor × capability × platform model
# (../modules/toolchain/, ../lib/catalogue.nix, ../lib/resolve.nix). Same three-layer split as the
# sibling nixfs/nixoffice repos' own checks/default.nix:
#
#   1. ../lib/resolve.nix driven with FIXTURE entry tables, independent of the real catalogue --
#      including the bidirectional-nullability branches (both `arch = null` AND `nixpkgs = null`)
#      the real catalogue does not happen to exercise on the Arch-absent side today.
#   2. ../modules/toolchain/options.nix (policy only) against the REAL catalogue, via
#      `lib.evalModules` -- vendor selection, capability selection, and the claim this file exists
#      to prove: an unselected vendor contributes nothing.
#   3. The two real backends -- ../modules/toolchain/nixos.nix through NixOS's own
#      eval-config.nix, ../modules/toolchain/system-manager.nix through plain `lib.evalModules`
#      WITHOUT a `pkgs` module argument at all, which is this repo's actual proof of the anti-
#      shadowing invariant: unlike nixfs (whose arch.nix backend takes `pkgs` for its own
#      nixpkgs-fallback branch and has to be checked empirically), this backend's module signature
#      never asks for `pkgs`, so an eval that succeeds with none supplied is a STRUCTURAL proof it
#      never could have reached into it -- not a claim about today's catalogue contents, a claim
#      about what the code can even do.
#
# THE HARD INVARIANT, restated for this file specifically (see ../modules/toolchain/system-
# manager.nix's own header for the full argument against mirroring nixfs's nixpkgs-fallback here):
# on the Arch plane, a selected package comes from pacman/AUR and NOTHING is ever installed from
# nixpkgs. Proven twice below -- structurally (no `pkgs` argument) and by value (`unavailableOnArch`
# entries appear in neither `nixarch.packages.pacman` nor `.aur`, and are merely reported).
{ pkgs, lib ? pkgs.lib, nixpkgs, system }:
let
  catalogue = import ../lib/catalogue.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  capabilityNames = lib.attrNames catalogue;

  check = name: ok: detail: { inherit name ok detail; };
  sorted = lib.sort (a: b: a < b);

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 1: ../lib/resolve.nix against fixtures, independent of the real catalogue.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  repoEntry = { name = "repoapp"; arch = "repoapp"; nixpkgs = "repoapp"; };
  aurEntry = { name = "aurapp"; arch = "aurapp"; aur = true; nixpkgs = "aurapp"; };
  archOnlyEntry = { name = "archonly"; arch = "archonly"; nixpkgs = null; };
  nixpkgsOnlyEntry = { name = "onlyapp"; arch = null; nixpkgs = "onlyapp"; };
  neitherEntry = { name = "neither"; arch = null; nixpkgs = null; };

  allFixtures = [ repoEntry aurEntry archOnlyEntry nixpkgsOnlyEntry ];

  resolveChecks = [
    (check "resolve/arch-excludes-aur-and-nixpkgs-only-entries"
      (resolve.archPackages allFixtures == [ "repoapp" "archonly" ])
      "got: ${builtins.toJSON (resolve.archPackages allFixtures)}")

    (check "resolve/aur-holds-only-aur-entries"
      (resolve.aurPackages allFixtures == [ "aurapp" ])
      "got: ${builtins.toJSON (resolve.aurPackages allFixtures)}")

    (check "resolve/package-names-excludes-arch-only-entries"
      (resolve.packageNames allFixtures == [ "repoapp" "aurapp" "onlyapp" ])
      "got: ${builtins.toJSON (resolve.packageNames allFixtures)}")

    (check "resolve/arch-and-aur-never-emit-a-null"
      (!(builtins.elem null (resolve.archPackages allFixtures))
        && !(builtins.elem null (resolve.aurPackages allFixtures)))
      "arch: ${builtins.toJSON (resolve.archPackages allFixtures)} aur: ${builtins.toJSON (resolve.aurPackages allFixtures)}")

    (check "resolve/package-names-never-emits-a-null"
      (!(builtins.elem null (resolve.packageNames allFixtures)))
      "got: ${builtins.toJSON (resolve.packageNames allFixtures)}")

    (check "resolve/unavailable-on-arch-reports-the-nixpkgs-only-entry-by-catalogue-name"
      (resolve.unavailableOnArch [ nixpkgsOnlyEntry ] == [ "onlyapp" ])
      "got: ${builtins.toJSON (resolve.unavailableOnArch [ nixpkgsOnlyEntry ])}")

    (check "resolve/unavailable-on-nixos-reports-the-arch-only-entry-by-catalogue-name"
      (resolve.unavailableOnNixos [ archOnlyEntry ] == [ "archonly" ])
      "got: ${builtins.toJSON (resolve.unavailableOnNixos [ archOnlyEntry ])}")

    # THE genuinely new branch nixfs never needed: an entry with NEITHER channel must be reported
    # on BOTH absence lists, and must never appear on either install list.
    (check "resolve/an-entry-with-neither-channel-is-unavailable-on-both-planes"
      (resolve.unavailableOnArch [ neitherEntry ] == [ "neither" ]
        && resolve.unavailableOnNixos [ neitherEntry ] == [ "neither" ]
        && resolve.archPackages [ neitherEntry ] == [ ]
        && resolve.aurPackages [ neitherEntry ] == [ ]
        && resolve.packageNames [ neitherEntry ] == [ ])
      "an entry naming neither arch nor nixpkgs leaked onto an install list")

    # THE anti-shadowing invariant, at the resolution level: whatever has an Arch source and
    # whatever has none partition on the same boolean, so their identities can never intersect --
    # same shape as nixfs's own equivalent check, now proven in both directions.
    (check "resolve/arch-covered-and-arch-absent-partition-is-disjoint"
      (
        let namesWithArch = map (t: t.name) (lib.filter (t: t.arch != null) allFixtures);
        in lib.intersectLists namesWithArch (resolve.unavailableOnArch allFixtures) == [ ]
      )
      "arch-covered names and arch-absent names overlapped")

    (check "resolve/nixpkgs-covered-and-nixpkgs-absent-partition-is-disjoint"
      (
        let namesWithNixpkgs = map (t: t.name) (lib.filter (t: t.nixpkgs != null) allFixtures);
        in lib.intersectLists namesWithNixpkgs (resolve.unavailableOnNixos allFixtures) == [ ]
      )
      "nixpkgs-covered names and nixpkgs-absent names overlapped")

    (check "resolve/empty-selection-resolves-to-empty-everywhere"
      (resolve.archPackages [ ] == [ ] && resolve.aurPackages [ ] == [ ]
        && resolve.packageNames [ ] == [ ]
        && resolve.unavailableOnArch [ ] == [ ] && resolve.unavailableOnNixos [ ] == [ ])
      "one of the resolve functions returned non-empty on an empty selection")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 2a: ../modules/toolchain/options.nix (policy only) against the REAL catalogue, via
  # lib.evalModules. NOTE: options.nix's module signature is `{ lib, config, ... }` -- no `pkgs`,
  # by construction, so this whole layer never supplies one, which is already half the anti-
  # shadowing proof (the other half is Layer 3's system-manager eval below).
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  assertionOptions = { lib, ... }: {
    options = {
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalPolicy = extraConfig: (lib.evalModules {
    modules = [ ../modules/toolchain/options.nix assertionOptions extraConfig ];
  }).config;

  policyBare = evalPolicy { };
  policyAmdCompute = evalPolicy { nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.compute.enable = true; };
  policyIntelCompute = evalPolicy { nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.compute.enable = true; };
  policyNvidiaCompute = evalPolicy { nixgpu.toolchain.vendor = "nvidia"; nixgpu.toolchain.capabilities.compute.enable = true; };
  policyNoVendorProbes = evalPolicy { nixgpu.toolchain.capabilities.probes.enable = true; };
  policyIntelProbes = evalPolicy { nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.probes.enable = true; };
  policyAmdDiagnostics = evalPolicy { nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.diagnostics.enable = true; };
  policyEverything = evalPolicy {
    nixgpu.toolchain.vendor = "intel";
    nixgpu.toolchain.capabilities = lib.genAttrs capabilityNames (_: { enable = true; });
  };

  policyChecks = [
    # ── bare enable: no vendor, no capabilities -- must resolve to nothing at all ────────────
    (check "policy/bare-enable-wants-nothing"
      (policyBare.nixgpu.toolchain.want == [ ])
      "want: ${builtins.toJSON policyBare.nixgpu.toolchain.want}")

    # ── VENDOR SELECTION: the same capability resolves to DIFFERENT packages per vendor ──────
    (check "policy/compute-amd-resolves-to-rocm"
      (lib.elem "rocm-hip-sdk" policyAmdCompute.nixgpu.toolchain.archPackages
        && !(lib.elem "cuda" policyAmdCompute.nixgpu.toolchain.archPackages)
        && !(lib.elem "intel-oneapi-basekit-2025" policyAmdCompute.nixgpu.toolchain.aurPackages))
      "archPackages: ${builtins.toJSON policyAmdCompute.nixgpu.toolchain.archPackages}")

    (check "policy/compute-intel-resolves-to-oneapi-basekit-versioned-name"
      (lib.elem "intel-oneapi-basekit-2025" policyIntelCompute.nixgpu.toolchain.aurPackages
        && !(lib.elem "intel-oneapi-basekit" policyIntelCompute.nixgpu.toolchain.aurPackages)
        && !(lib.elem "rocm-hip-sdk" policyIntelCompute.nixgpu.toolchain.archPackages))
      "aurPackages: ${builtins.toJSON policyIntelCompute.nixgpu.toolchain.aurPackages}, archPackages: ${builtins.toJSON policyIntelCompute.nixgpu.toolchain.archPackages}")

    (check "policy/compute-intel-mkl-and-onednn-are-nixpkgs-only"
      (lib.elem "mkl" policyIntelCompute.nixgpu.toolchain.packageNames
        && lib.elem "oneDNN" policyIntelCompute.nixgpu.toolchain.packageNames
        && lib.elem "mkl" policyIntelCompute.nixgpu.toolchain.unavailableOnArch
        && lib.elem "oneDNN" policyIntelCompute.nixgpu.toolchain.unavailableOnArch)
      "packageNames: ${builtins.toJSON policyIntelCompute.nixgpu.toolchain.packageNames}, unavailableOnArch: ${builtins.toJSON policyIntelCompute.nixgpu.toolchain.unavailableOnArch}")

    (check "policy/compute-nvidia-resolves-to-cuda"
      (lib.elem "cuda" policyNvidiaCompute.nixgpu.toolchain.archPackages
        && lib.elem "cudatoolkit" policyNvidiaCompute.nixgpu.toolchain.packageNames)
      "archPackages: ${builtins.toJSON policyNvidiaCompute.nixgpu.toolchain.archPackages}")

    # ── THE CLAIM THIS FILE EXISTS TO PROVE: an unselected/null vendor contributes nothing ───
    (check "policy/null-vendor-with-vendor-only-capability-contributes-nothing"
      (
        let p = evalPolicy { nixgpu.toolchain.capabilities.compute.enable = true; };
        in p.nixgpu.toolchain.want == [ ]
      )
      "vendor = null (the default) still resolved compute packages")

    (check "policy/a-vendor-with-no-cell-for-a-capability-contributes-nothing"
      (
        # aiInference's amd/nvidia cells are both deliberately empty (see ../lib/catalogue.nix) --
        # enabling the capability with either vendor selected must resolve to nothing.
        let
          p = evalPolicy { nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.aiInference.enable = true; };
        in p.nixgpu.toolchain.want == [ ]
      )
      "amd + aiInference resolved a non-empty want, but the catalogue's amd.aiInference cell is empty")

    # ── neutral probes apply regardless of vendor, while diagnostics remains vendor-specific ──
    (check "policy/probes-neutral-entries-apply-with-no-vendor-selected"
      (lib.elem "mesa-demos" policyNoVendorProbes.nixgpu.toolchain.packageNames
        && lib.elem "libva-utils" policyNoVendorProbes.nixgpu.toolchain.packageNames
        && lib.elem "wayland-utils" policyNoVendorProbes.nixgpu.toolchain.packageNames)
      "packageNames: ${builtins.toJSON policyNoVendorProbes.nixgpu.toolchain.packageNames}")

    (check "policy/probes-never-pull-intel-diagnostics"
      (!(lib.elem "intel-gpu-tools" policyIntelProbes.nixgpu.toolchain.archPackages))
      "archPackages: ${builtins.toJSON policyIntelProbes.nixgpu.toolchain.archPackages}")

    (check "policy/diagnostics-adds-only-vendor-entries-once-a-vendor-is-set"
      (!(lib.elem "mesa-demos" policyAmdDiagnostics.nixgpu.toolchain.packageNames)
        && lib.elem "rocminfo" policyAmdDiagnostics.nixgpu.toolchain.archPackages
        && lib.elem "radeontop" policyAmdDiagnostics.nixgpu.toolchain.archPackages)
      "packageNames: ${builtins.toJSON policyAmdDiagnostics.nixgpu.toolchain.packageNames}, archPackages: ${builtins.toJSON policyAmdDiagnostics.nixgpu.toolchain.archPackages}")

    # ── CAPABILITY SELECTION: turning ONE capability on adds exactly that capability's ───────
    #    packages, and turning it off (the default) adds nothing -- proven per capability.
  ]
  ++ map
    (cap:
      let
        on = evalPolicy { nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.${cap}.enable = true; };
        off = evalPolicy { nixgpu.toolchain.vendor = "intel"; };
        expectedNames = map
          (e: if (e.arch or null) != null then e.arch else e.nixpkgs)
          ((catalogue.${cap}.neutral.packages or [ ]) ++ (catalogue.${cap}.vendors.intel.packages or [ ]));
      in
      check "capability/${cap}-on-adds-exactly-its-own-entries-off-adds-none"
        (
          sorted (map (e: e.name) on.nixgpu.toolchain.want) == sorted (lib.unique expectedNames)
          && off.nixgpu.toolchain.want == [ ]
        )
        "on.want names: ${builtins.toJSON (map (e: e.name) on.nixgpu.toolchain.want)}, expected: ${builtins.toJSON (lib.unique expectedNames)}")
    capabilityNames
  ++ [
    # ── everything on, one vendor: every published list is internally consistent ─────────────
    (check "policy/everything-on-archPackages-and-aurPackages-are-disjoint"
      (lib.intersectLists policyEverything.nixgpu.toolchain.archPackages policyEverything.nixgpu.toolchain.aurPackages == [ ])
      "archPackages: ${builtins.toJSON policyEverything.nixgpu.toolchain.archPackages}, aurPackages: ${builtins.toJSON policyEverything.nixgpu.toolchain.aurPackages}")

    (check "policy/everything-on-arch-and-nixpkgs-only-lists-never-overlap-with-covered-names"
      (
        let
          coveredNames = map (t: t.name) (lib.filter (t: t.arch != null) policyEverything.nixgpu.toolchain.want);
        in
        lib.intersectLists coveredNames policyEverything.nixgpu.toolchain.unavailableOnArch == [ ]
      )
      "an entry's name appeared both arch-covered and in unavailableOnArch")

    (check "policy/extraPackages-passes-through-to-both-published-lists-independent-of-catalogue"
      (
        let p = evalPolicy { nixgpu.toolchain.extraPackages = [ "some-extra-tool" ]; };
        in p.nixgpu.toolchain.extraPackages == [ "some-extra-tool" ]
      )
      "extraPackages did not round-trip")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 3a: ../modules/toolchain/nixos.nix, through NixOS's real eval-config.nix.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalNixos = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        ../modules/toolchain/options.nix
        ../modules/toolchain/nixos.nix
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  nixosBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixos extraConfig).system.build.toplevel true)).success;

  outPathOf = n: (lib.getAttrFromPath (lib.splitString "." n) pkgs).outPath;

  cfg-nixos-amd-compute = evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.compute.enable = true; };
  cfg-nixos-gaming32 = evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.gaming32.enable = true; };
  cfg-nixos-intel-probes = evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.probes.enable = true; };

  nixosChecks = [
    (check "nixos/installs-the-runtime-baseline-and-every-resolved-package"
      (
        let installedOutPaths = map (p: p.outPath) cfg-nixos-amd-compute.environment.systemPackages;
        in lib.all (n: lib.elem (outPathOf n) installedOutPaths) cfg-nixos-amd-compute.nixgpu.toolchain.packageNames
      )
      "environment.systemPackages does not contain every resolved package")

    (check "nixos/disabled-installs-nothing"
      (
        let c = evalNixos {
          nixgpu.toolchain.enable = lib.mkForce false;
          nixgpu.toolchain.vendor = "amd";
          nixgpu.toolchain.capabilities.compute.enable = true;
        };
        in !(lib.elem pkgs.rocmPackages.clr c.environment.systemPackages)
      )
      "nixgpu.toolchain.enable = false still installed the compute SDK")

    (check "nixos/gaming32-sets-enable32Bit-and-nothing-else-does"
      (cfg-nixos-gaming32.hardware.graphics.enable32Bit == true
        && cfg-nixos-amd-compute.hardware.graphics.enable32Bit == false)
      "gaming32 host enable32Bit: ${toString cfg-nixos-gaming32.hardware.graphics.enable32Bit}, compute-only host enable32Bit: ${toString cfg-nixos-amd-compute.hardware.graphics.enable32Bit}")

    (check "nixos/probes-install-neutral-tools-without-intel-diagnostics"
      (
        let installedOutPaths = map (p: p.outPath) cfg-nixos-intel-probes.environment.systemPackages;
        in lib.all (n: lib.elem (outPathOf n) installedOutPaths) [ "mesa-demos" "libva-utils" "wayland-utils" ]
          && !(lib.elem pkgs.intel-gpu-tools cfg-nixos-intel-probes.environment.systemPackages)
      )
      "environment.systemPackages did not contain exactly the neutral probes")

    (check "nixos/nvidia-without-hardware-nvidia-warns"
      (
        let c = evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "nvidia"; };
        in lib.any (w: lib.hasInfix "hardware.nvidia" w) c.warnings
      )
      "expected a warning naming hardware.nvidia")

    (check "nixos/amd-never-warns-about-hardware-nvidia"
      (
        let c = evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "amd"; };
        in c.warnings == [ ]
      )
      "warnings: ${builtins.toJSON (evalNixos { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "amd"; }).warnings}")

    # `extraPackages` is a raw, unvalidated escape hatch (same as the module's first version --
    # ../../modules/toolchain/nixos.nix resolves it as a plain `pkgs.${p}` map with no assertion,
    # deliberately: it is the consumer's own responsibility, same as `with pkgs; [ ... ]` anywhere
    # else). So a bogus NAME there fails only when the derivation is actually realised, not at this
    # shallow eval layer -- not tested here for that reason. What IS this layer's job: a bogus
    # CATALOGUE entry (../../lib/catalogue.nix) must fail loudly via the explicit assertion this
    # module carries for exactly that (`missing` in ./nixos.nix), never resolve to a silent gap.
    # Proven by deliberately breaking the catalogue and observing this exact assertion fire -- see
    # this repo's commit history / the operator's own break-restore record for that run, since a
    # broken catalogue cannot be a fixture INSIDE this file without duplicating the whole table.
    (check "nixos/the-missing-package-assertion-is-wired-and-forces-cleanly-when-nothing-is-missing"
      (!(nixosBuildFails {
        nixgpu.toolchain.enable = true;
        nixgpu.toolchain.vendor = "amd";
        nixgpu.toolchain.capabilities = lib.genAttrs capabilityNames (_: { enable = true; });
      }))
      "the real catalogue, fully enabled, failed the build -- every packageNames entry should resolve in this pinned nixpkgs")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 3b: ../modules/toolchain/system-manager.nix, through plain lib.evalModules WITH NO
  # `pkgs` MODULE ARGUMENT AT ALL. This is the structural half of the anti-shadowing proof: the
  # module's own signature is `{ lib, config, ... }` -- if a future edit ever added a `pkgs.foo`
  # reference to install something from nixpkgs on this plane, THIS eval would fail with
  # "undefined variable 'pkgs'" the moment that branch is forced, not silently pass.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  smStubOptions = { lib, ... }: {
    options.nixarch.packages = {
      pacman = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalSm = extraConfig: (lib.evalModules {
    modules = [
      smStubOptions
      assertionOptions
      ../modules/toolchain/options.nix
      ../modules/toolchain/system-manager.nix
      extraConfig
    ];
    # Deliberately no `specialArgs.pkgs` — see this section's own header.
  }).config;

  # Forces the one value this eval could plausibly need `pkgs` for, if it ever reached toward it.
  smAccepts = extraConfig: (builtins.tryEval (builtins.deepSeq (evalSm extraConfig).nixarch.packages "ok")).success;

  smChecks = [
    (check "arch/never-declares-a-pkgs-module-argument-structurally"
      (smAccepts {
        nixgpu.toolchain.enable = true;
        nixgpu.toolchain.vendor = "intel";
        nixgpu.toolchain.capabilities = lib.genAttrs capabilityNames (_: { enable = true; });
      })
      "the Arch backend eval failed with everything enabled and no `pkgs` supplied -- it reached for `pkgs` somewhere")

    (check "arch/publishes-archPackages-into-nixarch-packages-pacman"
      (
        let c = evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.compute.enable = true; };
        in lib.elem "rocm-hip-sdk" c.nixarch.packages.pacman
      )
      "nixarch.packages.pacman did not contain rocm-hip-sdk")

    (check "arch/probes-publish-neutral-tools-without-intel-diagnostics"
      (
        let c = evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.probes.enable = true; };
        in lib.all (p: lib.elem p c.nixarch.packages.pacman) [ "mesa-utils" "libva-utils" "wayland-utils" ]
          && !(lib.elem "intel-gpu-tools" c.nixarch.packages.pacman)
      )
      "nixarch.packages.pacman leaked vendor telemetry into probes")

    (check "arch/publishes-aurPackages-into-nixarch-packages-aur-not-pacman"
      (
        let c = evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.compute.enable = true; };
        in lib.elem "intel-oneapi-basekit-2025" c.nixarch.packages.aur
          && !(lib.elem "intel-oneapi-basekit-2025" c.nixarch.packages.pacman)
      )
      "nixarch.packages.aur/pacman: ${builtins.toJSON (evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.compute.enable = true; }).nixarch.packages}")

    (check "arch/an-unavailableOnArch-entry-never-appears-in-pacman-or-aur"
      (
        let c = evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.compute.enable = true; };
        in !(lib.elem "mkl" c.nixarch.packages.pacman) && !(lib.elem "mkl" c.nixarch.packages.aur)
          && !(lib.elem "oneDNN" c.nixarch.packages.pacman) && !(lib.elem "oneDNN" c.nixarch.packages.aur)
      )
      "an entry with no Arch source leaked into a package list — the anti-shadow invariant this whole layer exists to prove is broken")

    (check "arch/warns-about-unavailableOnArch-entries-rather-than-silently-dropping-them"
      (
        let c = evalSm { nixgpu.toolchain.enable = true; nixgpu.toolchain.vendor = "intel"; nixgpu.toolchain.capabilities.compute.enable = true; };
        in lib.any (w: lib.hasInfix "mkl" w) c.warnings
      )
      "expected a warning naming the unavailableOnArch entries")

    (check "arch/disabled-declares-nothing"
      (
        let c = evalSm { nixgpu.toolchain.vendor = "amd"; nixgpu.toolchain.capabilities.compute.enable = true; };
        in c.nixarch.packages.pacman == [ ] && c.nixarch.packages.aur == [ ]
      )
      "nixgpu.toolchain.enable = false (the default) still declared packages")
  ];

  results = resolveChecks ++ policyChecks ++ nixosChecks ++ smChecks;

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixgpu toolchain eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else
  pkgs.runCommand "nixgpu-toolchain-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixgpu toolchain eval tests passed"
      touch $out
    ''
