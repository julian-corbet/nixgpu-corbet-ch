#
# The vendor × capability catalogue: for each WORKLOAD a GPU host might want, what to install per
# vendor, per platform. This is the second axis nixgpu answers, sitting beside `vendor` in
# modules/toolchain/options.nix -- that option alone only ever answered "which vendor's runtime",
# never "for what". See modules/toolchain/README.md for the full design and the boundary this
# catalogue draws against nixllm.
#
# SAME SHAPE AS THE SIBLING nixfs/nixdev CATALOGUES, one layer deeper: nixfs keys an entry by
# `{ arch; nixpkgs; aur?; }` alone. Here every entry is ALSO scoped under a vendor, because "which
# package" genuinely depends on "which vendor" in a way nixfs's filesystem tools never do -- ROCm
# and oneAPI and CUDA are not the same tool spelled differently, they are different tools. So the
# shape is capability -> vendor -> [ entries ], and only the innermost list is the nixfs shape.
#
# BOTH CHANNELS ARE INDEPENDENTLY NULLABLE, in BOTH directions -- nixfs only ever needed `arch =
# null` (nixpkgs-only; every real nixfs entry has Arch coverage). This catalogue genuinely needs
# both: `arch = null` where only nixpkgs has an equivalent (none today -- every package below has
# live Arch/AUR coverage, same as nixfs's own present-day catalogue), and `nixpkgs = null` where
# only Arch does, which happens A LOT here because a chunk of "what a vendor's driver needs" is
# either baked into nixpkgs' `mesa` derivation already (so nothing to add) or is a NixOS *option*
# rather than a package at all (`hardware.graphics.enable32Bit`, handled by
# ../modules/toolchain/nixos.nix directly, never by this table -- same asymmetry
# docs/module-layout.md documents for nixdesktop's gvfs/portals roles in the infra repo: a package
# list on one plane, a real option on the other).
#
# EVERY PACKAGE NAME BELOW WAS VERIFIED LIVE against CORBET-ELITEBOOK's actual pacman/paru sync
# databases (cachyos + cachyos-extra-v3 + extra + multilib + AUR) and this repo's own pinned
# nixpkgs (`nix eval` against the exact `flake.lock` revision), 2026-08-04 -- not guessed, and not
# copied from the generic vendor advice that named some of these. Where that live check overturned
# the generic advice, the entry's own comment says so.
#
# NEUTRAL vs VENDOR. Most capabilities vary by vendor; `diagnostics` alone also carries a `neutral`
# bucket -- packages that query WHATEVER GPU is present (mesa-demos' glxinfo, libva-utils' vainfo,
# wayland-utils' wayland-info) and therefore apply regardless of `vendor`, even `vendor = null`.
# Nothing else in this table has a neutral bucket because nothing else is vendor-agnostic: a Vulkan
# ICD, a VA-API driver, a compute SDK are all real per-silicon artifacts.
#
{ ... }:
{
  display = {
    summary = "The Vulkan ICD for this vendor's card -- the loader every Vulkan consumer (games, a compositor's Vulkan renderer, `vulkaninfo`) queries to find a usable driver.";
    vendors = {
      amd.packages = [
        { arch = "vulkan-radeon"; nixpkgs = null; }
      ];
      amd.note = ''
        nixpkgs has no separate attribute: `hardware.graphics.enable` installs nixpkgs' `mesa`
        derivation, which bundles the `radv` Vulkan driver together with the OpenGL one in ONE
        build. Arch packages them apart (`mesa` vs `vulkan-radeon`) for historical
        packaging-granularity reasons, so only the Arch plane needs an explicit entry -- the same
        one-monolithic-package-vs-several-split-ones asymmetry `docs/module-layout.md` documents
        for `gvfs` in the infra repo, just running in the opposite direction (there nixpkgs is the
        monolith; here Arch is the split one).
      '';

      intel.packages = [
        { arch = "vulkan-intel"; nixpkgs = null; }
      ];
      intel.note = "Same reasoning as amd above: nixpkgs' mesa bundles the `anv` driver in; Arch splits it into its own package.";

      nvidia.packages = [ ];
      nvidia.note = "The proprietary driver (this module's unconditional `nvidia-utils` runtime baseline) ships its own Vulkan ICD; nothing to add here.";
    };
  };

  videoAccel = {
    summary = "Hardware video encode/decode (VA-API) -- the driver `vainfo`, ffmpeg's `-hwaccel vaapi`, and hardware-accelerated browser video all query.";
    vendors = {
      amd.packages = [ ];
      amd.note = "Mesa's own `radeonsi` VA-API driver ships inside the `mesa` build on both planes; nothing extra to install.";

      intel.packages = [
        { arch = "intel-media-driver"; nixpkgs = "intel-media-driver"; }
      ];
      intel.note = ''
        The iHD driver (Broadwell and newer). LIVE-VERIFIED on CORBET-ELITEBOOK (2026-08-02):
        `vainfo` reports the iHD driver with a full modern profile list (HEVC/VP9/AV1), confirming
        it was needed AND already installed by hand -- this is the one entry that closes a real,
        confirmed gap rather than a hypothetical one. The legacy i965 driver (`libva-intel-driver`)
        is deliberately NOT modelled: its supported-hardware list stops well before Lunar
        Lake/Xe2-class silicon, so it would not even claim a device this new -- only create the
        `LIBVA_DRIVER_NAME` ambiguity two VAAPI drivers invites, for zero functional gain.
      '';

      nvidia.packages = [ ];
      nvidia.note = "NVENC/NVDEC are proprietary and not exposed through VA-API; the driver runtime baseline (nvidia-utils) talks to them directly. No VA-API package exists for this vendor without a third-party shim (nvidia-vaapi-driver), not carried here for lack of evidence anything needs it.";
    };
  };

  compute = {
    summary = ''
      The vendor compute SDK on top of the plain driver runtime -- ROCm / oneAPI / CUDA -- for
      BUILDING or RUNNING OpenCL/SYCL/HIP workloads on this box directly. Corresponds to the old
      `toolchain.sdk` boolean, generalized into one capability among several. Skip this on a
      cluster node whose pods carry their own toolkit inside the container image -- see this
      catalogue's own header and modules/toolchain/README.md's bare-metal guidance.
    '';
    vendors = {
      amd.packages = [
        { arch = "rocm-hip-sdk"; nixpkgs = "rocmPackages.clr"; }
        { arch = "rocm-opencl-sdk"; nixpkgs = "rocmPackages.rocm-runtime"; }
      ];

      intel.packages = [
        # AUR, VERSIONED. The unversioned `intel-oneapi-basekit` is NOT a resolvable pacman sync
        # target -- confirmed live, `pacman -Si intel-oneapi-basekit` reports nothing -- it only
        # ever "worked" on a host where the versioned package below happened to already be
        # installed and `Provides:` the unversioned name. This entry fixes that latent catalogue
        # bug: the real, live, resolvable name is the dated one.
        { arch = "intel-oneapi-basekit-2025"; aur = true; nixpkgs = null; }
        # nixpkgs has no equivalent BUNDLE (no combined oneAPI basekit derivation exists there at
        # all), so the two runtime libraries most workloads actually reach for are named
        # separately instead of left absent. This is not a 1:1 substitute for the Arch entry above
        # -- the AUR basekit also carries the DPC++ compiler, the DPC++ debugger, VTune and
        # Advisor (development/profiling tools, ~11 GiB combined), none of which nixpkgs packages
        # at all, so a NixOS host declaring this capability gets the RUNTIME libraries a workload
        # links against, not a devtools bundle -- a real, accepted platform gap, not an oversight.
        { arch = null; nixpkgs = "mkl"; }
        { arch = null; nixpkgs = "oneDNN"; }
      ];
      intel.note = ''
        LIVE EVIDENCE (CORBET-ELITEBOOK, 2026-08-04, `pacman -Qi`): `intel-oneapi-basekit-2025`'s
        own `Required By` is `python-pytorch` -- and python-pytorch's own `Depends On` names
        `intel-oneapi-mkl`, not the basekit. The basekit satisfies that dependency only because it
        `Provides: intel-oneapi-mkl` alongside everything else it bundles; the OFFICIAL, non-AUR
        `intel-oneapi-mkl` package (1.6 GiB, in both `extra` and `cachyos-extra-v3`) provides the
        exact same virtual package on its own. Separately, `openvino-bin`'s own `Depends On` names
        neither the basekit nor MKL at all (glibc/gcc-libs/pugixml/ocl-icd/ncurses only), and
        `intel-npu-compiler`'s `Depends On` likewise never touches it -- so OpenVINO and NPU work
        need NONE of this 11.39 GiB package. The basekit is `Optional For: intel-llm,
        llama.cpp-sycl-bin` (not required), most plausibly for the SYCL/DPC++ RUNTIME shared
        libraries those precompiled (`-bin`) binaries need to execute against the GPU at runtime --
        which the evidence gathered here does not isolate from the rest of the bundle.

        This is evidence, not a removal recommendation: whether swapping to the narrow
        `intel-oneapi-mkl` still lets `llama.cpp-sycl-bin` run has not been tested, and this pass
        does not touch what is installed on the live host either way -- see
        modules/toolchain/README.md's obsolescence section for the full writeup.
      '';

      nvidia.packages = [
        { arch = "cuda"; nixpkgs = "cudatoolkit"; }
        { arch = "cudnn"; nixpkgs = "cudaPackages.cudnn"; }
      ];
    };
  };

  aiInference = {
    summary = ''
      NPU / dedicated-inference-silicon runtime -- OpenVINO plus its NPU compiler, for running
      quantized models on inference hardware separate from the general compute engine. New
      capability; nothing in the old sdk/monitoring split had anywhere to put this.
    '';
    vendors = {
      amd.packages = [ ];
      amd.note = "No NPU on the reference hardware this catalogue is built against. AMD's GPU-inference story runs through the `compute` capability above (ROCm), not a separate inference runtime.";

      intel.packages = [
        # `openvino-bin` provides `openvino`, `openvino-intel-gpu-plugin`, `openvino-intel-npu-plugin`
        # and `python-openvino` all at once (AUR `Provides:`, live-checked) -- the umbrella runtime
        # that lets code target Intel CPU, GPU *and* NPU through one API. nixpkgs' top-level
        # `openvino` attribute is the same project's own runtime build (confirmed present in the
        # pinned nixpkgs via `nix eval`), so the two sides are a real match here, unlike most of
        # this table.
        { arch = "openvino-bin"; aur = true; nixpkgs = "openvino"; }
        # The NPU compiler is a separate AUR package from the driver: `intel-npu-compiler` compiles
        # models for the NPU (analogous to ROCm's own HIP compiler, or CUDA's nvcc -- a build-time
        # tool, not the thing that talks to the device at runtime); `intel-npu-driver` (also AUR,
        # NOT modelled as its own entry here -- it arrives as a dependency already, see this
        # catalogue's own README pointer) is the runtime piece. nixpkgs has no equivalent compiler
        # package at all (checked live against the pinned revision) -- a real gap, not an omission.
        { arch = "intel-npu-compiler"; aur = true; nixpkgs = null; }
      ];
      intel.note = ''
        Deliberately STOPS here. `openvino-genai-bin` (the LLM-pipeline API layered on top of this
        runtime, req'd by `intel-llm`), `intel-llm`/`intel-llm-convert` (apps), and
        `llama.cpp-sycl-bin` (an LLM server, just SYCL-backend) are things that RUN ON this runtime,
        not the runtime itself -- nixllm territory. See modules/toolchain/README.md's boundary
        test for the full argument, including these exact packages worked through.
      '';

      nvidia.packages = [ ];
      nvidia.note = "No distinct AI-inference package family beyond the compute/CUDA stack above (TensorRT would be the analogous piece if this ever mattered); not modelled for lack of any host that needs it.";
    };
  };

  gaming32 = {
    summary = ''
      The 32-bit (multilib) GRAPHICS DRIVER stack a native Linux game or a Proton title needs
      beneath it. NOT the gaming tools themselves (Steam, gamemode, mangohud, cachyos-gaming-meta)
      -- those are the sibling nixgames project's job; this is one layer lower, the driver a 32-bit
      process actually loads. See modules/toolchain/README.md's boundary note.
    '';
    vendors = {
      amd.packages = [
        { arch = "lib32-mesa"; nixpkgs = null; }
        { arch = "lib32-vulkan-radeon"; nixpkgs = null; }
        { arch = "lib32-vulkan-icd-loader"; nixpkgs = null; }
      ];
      intel.packages = [
        { arch = "lib32-mesa"; nixpkgs = null; }
        { arch = "lib32-vulkan-intel"; nixpkgs = null; }
        { arch = "lib32-vulkan-icd-loader"; nixpkgs = null; }
      ];
      nvidia.packages = [
        { arch = "lib32-nvidia-utils"; nixpkgs = null; }
      ];
    };
    # Every `nixpkgs` field above is null ON PURPOSE, for every vendor -- there is no per-package
    # NixOS equivalent to name. The real NixOS answer is `hardware.graphics.enable32Bit = true;`,
    # a single vendor-neutral OPTION that makes `hardware.graphics` install the 32-bit variant of
    # whichever driver it already resolved (and which `hardware.nvidia` itself also respects for
    # the proprietary stack). ../modules/toolchain/nixos.nix sets that option directly when this
    # capability is enabled, instead of walking a package list that would have nothing real in it
    # -- the same "package list on Arch, real option on NixOS" split docs/module-layout.md
    # documents for nixdesktop's portals/gvfs roles in the infra repo.
    nixosOption = [ "hardware" "graphics" "enable32Bit" ];
  };

  containerExposure = {
    summary = "What a container runtime (podman, or a k3s node) needs BEYOND an exposed device node to actually use this GPU from inside a container.";
    vendors = {
      amd.packages = [ ];
      amd.note = "The in-kernel amdgpu driver plus an exposed /dev/kfd + renderD* node is sufficient; nothing extra to install at the OS level. The k8s-side device exposure itself is this repo's own device-tokens module (Level 2), a different mechanism entirely from a host package.";

      intel.packages = [ ];
      intel.note = "Same reasoning as amd: an exposed renderD* node is sufficient for VA-API/OpenCL inside a container.";

      nvidia.packages = [
        { arch = "nvidia-container-toolkit"; nixpkgs = "nvidia-container-toolkit"; }
      ];
      nvidia.note = "The one vendor where this genuinely differs: the proprietary userspace libraries are not in the container image by default, so the container runtime needs the toolkit's hook to inject them at start time.";
    };
  };

  diagnostics = {
    summary = "Ask the card what it is actually doing -- the first thing any contention investigation reaches for, and the reason this project's own README opens with a VRAM-pressure story.";
    # Applies to EVERY host with this capability enabled, regardless of `vendor` (even `vendor =
    # null`) -- these tools query whatever GPU is present, not one vendor's silicon.
    neutral.packages = [
      # Arch names the project "mesa-utils" (glxinfo/glxgears); nixpkgs renamed its own package to
      # follow upstream's own rename to "mesa-demos" and dropped the old attribute entirely
      # (confirmed live: `mesa-utils` does not resolve in the pinned nixpkgs, `mesa-demos` does) --
      # the exact same shape as nixfs's documented ntfs3g/ntfs-3g divergence, just the other
      # direction (nixpkgs renamed, Arch did not follow).
      { arch = "mesa-utils"; nixpkgs = "mesa-demos"; }
      { arch = "libva-utils"; nixpkgs = "libva-utils"; }
      { arch = "wayland-utils"; nixpkgs = "wayland-utils"; }
    ];
    vendors = {
      amd.packages = [
        { arch = "rocm-smi-lib"; nixpkgs = "rocmPackages.rocm-smi"; }
        { arch = "rocminfo"; nixpkgs = "rocmPackages.rocminfo"; }
        # Not in the old toolchain.monitoring table at all -- these two are corbet-devops' own
        # hand-written GPU-observability list (infra `hosts/nixnas.nix`, added 2026-07-21 "during
        # the shared-GPU platform work", after a ComfyUI ring-timeout hang was invisible until
        # someone SSH'd in and grepped dmesg). Folding them in here is what lets that host file
        # drop its raw package list for this module -- see this repo's own README bare-metal
        # section and the infra reconciler delta for corbet-server.
        { arch = "radeontop"; nixpkgs = "radeontop"; }
        { arch = "amdgpu_top"; nixpkgs = "amdgpu_top"; }
        { arch = "nvtop"; nixpkgs = "nvtopPackages.amd"; }
      ];

      intel.packages = [
        { arch = "intel-gpu-tools"; nixpkgs = "intel-gpu-tools"; }
        { arch = "nvtop"; nixpkgs = "nvtopPackages.intel"; }
      ];
      intel.note = ''
        `intel-gpu-tools`' flagship tool, `intel_gpu_top`, does NOT support the `xe` kernel driver
        (Lunar Lake/Battlemage-class hardware and newer) -- live-tested against CORBET-ELITEBOOK's
        actual device: `intel_gpu_top -L` finds "Intel Lunarlake (Gen20)" fine, but sampling fails
        with "Failed to detect engines! ... Kernel 4.16 or newer is required for i915 PMU support",
        an i915-only code path upstream has confirmed will not be fixed in this tool (Xe monitoring
        is being built as a separate `gputop` tool in the same package instead, igt-dev, March
        2025). i915-class hosts (older than Lunar Lake) are unaffected. A host on the `xe` driver
        should leave this whole capability's Intel entry disabled via `extraPackages`-style
        exclusion or accept it as a diagnostic tool that cannot currently diagnose its own card;
        `nvtop`'s Intel backend is a separate code path and unaffected either way.
      '';

      nvidia.packages = [
        # No standalone nixpkgs attribute for nvidia-settings -- it does not exist at nixpkgs' top
        # level (checked live) because it has to match the driver version selected via
        # `hardware.nvidia.package`, which is exactly why NVIDIA driver choice is a NixOS *option*
        # rather than a plain package everywhere else in this repo (see
        # ../modules/toolchain/nixos.nix's own header). Real on Arch, where the package is
        # standalone.
        { arch = "nvidia-settings"; nixpkgs = null; }
        { arch = "nvtop"; nixpkgs = "nvtopPackages.nvidia"; }
      ];
    };
  };
}
