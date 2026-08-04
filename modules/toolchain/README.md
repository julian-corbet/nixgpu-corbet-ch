# toolchain — vendor × capability × platform

`toolchain` answers, in full, the question this repo's own top-level README only half-answered
before this: **what do I install to actually USE this GPU?** Not "who gets it when it's contended"
(that's the Level 2/edge modules -- device-tokens, priority-ladder, pressure-watcher,
ondemand-front, unchanged by this document) -- what has to be on the box before any of that
matters at all.

## The three axes

1. **Vendor** -- `nixgpu.toolchain.vendor` (`"amd" | "intel" | "nvidia" | null`). Unchanged from
   this module's first version, including the PCI-ID coherence check against `stableDevicePaths`
   (see `./options.nix`). Not auto-detected, on purpose: a wrong guess installs several gigabytes
   of the wrong SDK, and declaring it is one line.

2. **Capability** -- `nixgpu.toolchain.capabilities.*`, one boolean per WORKLOAD: `display`,
   `videoAccel`, `compute`, `aiInference`, `gaming32`, `containerExposure`, `diagnostics`. This is
   the new axis. The old version of this module had exactly two booleans (`sdk`, `monitoring`) --
   coarse enough that the one real gap this catalogue closes (Intel VA-API on the elitebook) had
   to be declared through the `extraPackages` escape hatch rather than as a first-class selection.
   Each capability is defined once in `../../lib/catalogue.nix`, with a `summary` describing what
   it is for -- read that file for the packages, the evidence behind each one, and the notes on
   where a vendor genuinely has nothing to contribute.

3. **Platform** -- resolved per capability, per vendor, by `../../lib/catalogue.nix`'s
   `{ arch; nixpkgs; aur?; }` entries, in the SAME shape the sibling `nixfs`
   (`nixfs/lib/catalogue.nix`) and `nixdev` (`nixdev/lib/tools.nix`) catalogues already use for
   their own domains: `nixpkgs` names the top-level nixpkgs attribute path (dotted, e.g.
   `"rocmPackages.clr"`), `arch` names the pacman package, `aur = true` holds an entry back into
   `aurPackages` because `pacman -S` cannot resolve an AUR name and fails the whole transaction on
   "target not found". Genuinely new here, not present in either sibling: BOTH channels are
   independently nullable, not just `arch` -- see `../../lib/catalogue.nix`'s own header for why
   (nixpkgs has no combined "oneAPI basekit" bundle; several vendor Vulkan/32-bit driver packages
   are baked into nixpkgs' `mesa` already and have no separate attribute to name; `gaming32`'s
   NixOS answer is an option, not a package, at all).

   `./nixos.nix` installs every resolved `nixpkgs` name from `environment.systemPackages`.
   `./system-manager.nix` publishes every resolved `arch`/AUR name into
   `nixarch.packages.{pacman,aur}` and, structurally, never reaches into `pkgs` at all -- see that
   file's own header for why it deliberately does NOT mirror nixfs's nixpkgs-fallback for
   Arch-absent entries. **We do not shadow**: on the Arch plane a selected package comes from
   pacman/AUR and nothing installs a second copy from nixpkgs, full stop, not merely "empirically
   true of today's catalogue" the way it is for nixfs.

## The boundary against nixllm

**nixgpu owns the SUBSTRATE** (drivers, vendor runtimes/SDKs, diagnostics) — the layer that is
true of the machine whether or not any particular application is even installed yet.
**nixllm owns things that RUN ON it** (model servers, clients, python ML libraries) — the layer
that exists because someone wants to talk to a specific model. The test: *would this package still
make sense to install on a box with no LLM/AI application in mind at all?* If yes, it's substrate.
If the honest answer is "why would you have this without also wanting to run a model", it's the
app layer, and it goes in nixllm, however deep in C++ it happens to be written.

Worked examples, weakest case first:

- **`intel-media-driver`** (VA-API) -- substrate, obviously: any video app benefits, no model in
  sight. `videoAccel` capability.
- **`openvino-bin`** -- substrate. It is the RUNTIME that lets code target Intel CPU/GPU/NPU
  through one API (`Provides: openvino-intel-gpu-plugin, openvino-intel-npu-plugin`, live-checked)
  -- the same role ROCm or CUDA plays for their vendors, just Intel's inference-shaped equivalent.
  Nothing about installing it presupposes a particular model or app. `aiInference` capability.
- **`intel-npu-compiler`** -- substrate, same reasoning as `openvino-bin`: it compiles models FOR
  the NPU, the same role ROCm's own HIP compiler or CUDA's `nvcc` play for their vendors. A
  build-time tool for the device, not a thing that runs a model itself.
- **`intel-oneapi-basekit-2025`** -- substrate. It's a driver-adjacent SDK (MKL, oneDNN, the
  DPC++ compiler, VTune, Advisor) that `python-pytorch` itself depends on (see the obsolescence
  section below) -- a framework needing it says nothing about which model anyone runs on top.
  `compute` capability.
- **`openvino-genai-bin`** -- THE FIRST HARD ONE, and it lands in nixllm. Its own AUR `Depends On`
  is `python`, `python-numpy` -- it is a Python **pipeline API for generative-AI inference
  specifically** (chat templates, sampling, KV-cache management), layered ON TOP of the
  `openvino-bin` runtime above, the same relationship llama.cpp has to a bare inference kernel.
  `Required By: intel-llm` (an app). The honest test question answers itself: nobody installs
  `openvino-genai-bin` except to run generative models.
- **`llama.cpp-sycl-bin`** -- THE HARDEST ONE, called out explicitly because it is genuinely an
  LLM tool built AGAINST a vendor runtime, which is exactly the shape that makes the boundary feel
  blurry. It is llama.cpp -- an LLM inference **server** -- compiled against Intel's SYCL/oneAPI
  backend instead of CPU or CUDA. Being vendor-specific does not make it substrate: CUDA's own
  `llama.cpp` build is not part of `nixgpu.toolchain` either, and this repo's own operator has
  already named the general shape ("llama.cpp being obviously an llm tool"). What makes it FEEL
  close to the line is that it needs the SYCL runtime present to execute -- but needing a runtime
  is true of every app in nixllm's catalogue (the shared LLM broker needs ROCm too, and nixllm is
  not part of nixgpu for that reason). nixllm's territory.
- **`intel-llm` / `intel-llm-convert`** -- easy once the above two land correctly: `intel-llm`'s
  own AUR `Depends On` is `llama.cpp-sycl-bin`, `openvino-genai-bin`, `python-huggingface-hub` --
  an orchestration app wrapping two other nixllm-side tools plus a model-hub client. Nothing here
  is a driver or an SDK. nixllm's territory, alongside the already-correctly-filed
  `anythingllm-cli-bin`, `litert-lm`, `python-openai`, `python-openai-whisper`, `python-tiktoken`,
  `python-transformers`, and `python-pyopencl` (a Python OpenCL BINDING -- something you script
  against, the same "documents" test `nixdev`'s own catalogue header already states for its Python
  library tables: "you script against these, you never look at them").

**Recommendation, not an edit made here** (out of this repo's scope; flag for whoever owns
`nixllm`): `openvino-genai-bin`, `intel-llm`, `intel-llm-convert`, `llama.cpp-sycl-bin`,
`litert-lm`, `anythingllm-cli-bin`, `python-openai`, `python-openai-whisper`, `python-pyopencl`,
`python-tiktoken`, `python-transformers` all belong in nixllm's own catalogue, not nixgpu's.
`openvino-bin`, `intel-npu-compiler` and `intel-oneapi-basekit-2025` are the three that move the
OTHER way -- out of the informal "nixllm — 14" bucket in infra's `docs/undeclared-packages.md` and
into this module's `aiInference`/`compute` capabilities, which is what actually declares them
(see the infra wiring below).

### A second boundary, found along the way: nixgpu vs nixgames

Not asked for, but surfaced by the same audit: archlxc's `lib32-mesa`, `lib32-vulkan-radeon`,
`lib32-vulkan-icd-loader` (this module's `gaming32` capability) are the 32-bit **graphics driver**
a game needs; the sibling `nixgames` project already declares the 32-bit **gaming tools** on top
of it (`lib32-gamemode`, `lib32-mangohud`, `steam`, `cachyos-gaming-meta` -- see infra's
`hosts/archlxc/games.nix`). Same layering as the nixllm boundary, one level lower: driver vs. the
thing that uses it. Neither repo currently declares the other's half; this module closes nixgpu's.

## Packages NOT modelled here, and why

- **`chwd`** (CachyOS hardware detection) -- not a first-class install at all. Live-checked
  (`pacman -Qi chwd` on CORBET-ELITEBOOK): `Required By: cachyos-kernel-manager`, `Install Reason:
  Installed as a dependency for another package`. Per infra's own `docs/module-layout.md`
  ("dependencies are not declarations"), once `nixarch` declares `cachyos-kernel-manager`, `chwd`
  arrives transitively and needs no entry anywhere, nixgpu included.
- **`ddcutil`** (DDC/CI monitor control) -- genuinely undeclared (`Install Reason: Explicitly
  installed`, `Required By: None`), but not a GPU-substrate concern: it queries/sets MONITOR
  state over the DDC/CI protocol, consumed today only by infra's own `modules/shared/monitors.nix`
  / `layouts.nix` (input-source detection). That file's comment claiming it is "already declared"
  there is not accurate -- those files only reference `ddcutil getvcp 60` in a code comment, they
  install nothing -- but the fix belongs in `nixdesktop`, the repo that actually models monitors,
  not here.

## Obsolescence review

Every package the operator flagged as possibly-obsolete, checked live against CORBET-ELITEBOOK's
actual `pacman -Qi`/`paru -Si` output and this repo's pinned nixpkgs (`nix eval` against the exact
`flake.lock` revision), 2026-08-04:

| package | verdict | reason |
|---|---|---|
| `intel-npu-compiler` | **keep** | `Optional For: intel-npu-driver`; genuinely the NPU build-time compiler, no narrower or newer replacement found |
| `openvino-bin` | **keep** | the umbrella CPU/GPU/NPU inference runtime; nothing supersedes it |
| `openvino-genai-bin` | **keep, moves to nixllm** | real dependency of `intel-llm`; not obsolete, just misfiled |
| `intel-llm` / `intel-llm-convert` | **keep, moves to nixllm** | active app layer |
| `llama.cpp-sycl-bin` | **keep, moves to nixllm** | active LLM server build |
| `litert-lm` | **keep, moves to nixllm** | standalone, no deps, no evidence of being superseded |
| `python-pyopencl` | **keep, already correctly bucketed at nixllm** | scripting binding, no substitute needed |
| `chwd` | **no action** | transitive dependency, not a declaration target (see above) |
| `ddcutil` | **no action here, recommend nixdesktop** | not GPU substrate |
| `intel-oneapi-basekit-2025` | **keep installed; evidence gathered, no removal recommended** | see below |

### `intel-oneapi-basekit-2025` (11.39 GiB) -- the one the operator asked to flag prominently

Explicit instruction: do NOT remove it, and do NOT recommend removal without evidence. This is the
evidence, gathered live and cited so the removal decision (if ever made) is Julian's, not this
pass's:

- `pacman -Qi intel-oneapi-basekit-2025` → `Required By: python-pytorch`. It provides a long list
  of sub-components as one AUR meta-package (`Provides: intel-oneapi-mkl, intel-oneapi-dnnl,
  intel-oneapi-tbb, intel-oneapi-dpl, intel-oneapi-ccl, intel-oneapi-dpcpp-cpp-compiler,
  intel-oneapi-dal, ..., intel-oneapi-advisor, intel-oneapi-vtune, ...`).
- `pacman -Qi python-pytorch` → its OWN `Depends On` names `intel-oneapi-mkl`, never the basekit
  by name. The basekit satisfies that dependency only because it happens to `Provides:
  intel-oneapi-mkl` alongside everything else.
- The OFFICIAL (non-AUR) `intel-oneapi-mkl` package exists in both `extra` and
  `cachyos-extra-v3`, at **1.6 GiB** -- roughly 1/7th the size -- and provides exactly the same
  virtual package pytorch's own dependency line asks for.
- `openvino-bin`'s `Depends On` (`glibc gcc-libs pugixml ocl-icd ncurses`) and
  `intel-npu-compiler`'s (`glibc libgcc libstdc++ onetbb pugixml zlib zstd`) touch neither the
  basekit NOR MKL at all. **OpenVINO and NPU work need none of this package**, contrary to what
  might be assumed from it sitting next to them on disk.
- The basekit is `Optional For: intel-llm, llama.cpp-sycl-bin` (optional, not required) -- most
  plausibly for the SYCL/DPC++ runtime shared libraries a precompiled (`-bin`) SYCL binary needs
  present at EXECUTION time, though this evidence does not isolate which specific sub-component
  those two packages actually touch at runtime.

**Reading**: the basekit's ~11 GiB includes a full C++/DPC++ compiler toolchain plus two profilers
(VTune, Advisor) that nothing on this host appears to need merely to RUN (as opposed to build)
anything -- pytorch's real requirement is satisfiable by the narrow official `intel-oneapi-mkl`
alone, and OpenVINO/NPU inference need none of it. What is NOT established by this evidence: does
`llama.cpp-sycl-bin`'s SYCL backend need any basekit sub-component beyond what `intel-oneapi-mkl`
alone would provide (a shared SYCL/Level-Zero runtime library, distinct from the dev-tools
portion)? That would need a live test -- install the narrow package, remove the basekit, confirm
`llama.cpp-sycl-bin` still runs against the GPU -- which this pass does not perform, per
instruction. Recorded here as a finding for a future, deliberate, rollback-able pass.

## Bare-metal recommendation: corbet-server

The operator was explicit that the bare-metal (Level 1, host-side) policy for corbet-server was
undecided and asked for a researched recommendation, not a silent pick.

**Recommendation: `vendor = "amd"`, `capabilities.diagnostics.enable = true`, every other
capability off.**

Reasoning:

- Every GPU-consuming workload on corbet-server today runs as a **k3s pod** through this repo's
  own `device-tokens` module (`comfyui`, the shared `llm` broker, `rag` -- see infra's
  `kubernetes/corbet-devops/gpu-substrate.nix`), not as a bare-metal process. Container images
  carry their own ROCm/compute toolkit baked in -- this module's own pre-existing documentation
  already states the resulting design principle exactly: *"the right shape for a cluster node
  running prebuilt images, where the container carries its own toolkit and the host only has to
  expose a working device"*. `compute` off is that principle applied, not a new call.
- `display`, `gaming32`: this is a headless server (ASPEED BMC console only); no session ever runs
  on the metal. Off.
- `aiInference`: AMD vendor, no NPU on this hardware. `aiInference`'s AMD cell is empty regardless
  (see `../../lib/catalogue.nix`) -- enabling it would be a documented no-op.
- `containerExposure`: the AMD cell is also empty by design -- device exposure to k3s pods is
  ALREADY this repo's own `device-tokens` module's job (a different mechanism, Level 2, not a host
  package). Toggling this capability on AMD contributes nothing either way; leave it off for an
  honest config (nothing here would explain what it's for).
- `diagnostics`: **on**, and this is the one real, actionable change. Infra's `hosts/nixnas.nix`
  today hand-installs `radeontop amdgpu_top nvtopPackages.amd rocmPackages.rocm-smi` directly in
  `environment.systemPackages`, with a comment explaining they were added ad hoc on 2026-07-21
  "during the shared-GPU platform work" after a ComfyUI hang was invisible until someone SSH'd in
  and grepped `dmesg`. This module's `diagnostics`/`amd` catalogue cell now names exactly those
  four packages plus `rocminfo` and the three vendor-neutral tools (`mesa-demos`, `libva-utils`,
  `wayland-utils`) -- turning a hand-written list into a declared one, and adding a bit of real
  coverage (`rocminfo`, the neutral diagnostics) the hand-written list never had. See the infra
  reconciler delta below.

This recommendation is a judgment call about workload placement (bare-metal vs. pods), not a
mechanical fact the catalogue can derive -- flagged as such per this repo's own "no silent
defaults" discipline. If a future bare-metal (non-podded) GPU workload ever lands on
corbet-server, `compute` is one line to flip back on.
