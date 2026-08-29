# nixgpu

**Share one GPU between Kubernetes, containers, and your desktop — by priority,
reactively, with no budgets, no quotas, and no reservations.**

Homelab GPU sharing for cards with an **in-kernel DRM driver** (AMD today;
Intel is structurally compatible; NVIDIA is excluded until an in-tree driver
stack matures). One physical card, many consumers: k8s pods, an LLM server, an
image generator, a video transcoder, and the interactive desktop — all
co-residing when they fit, yielding by priority when they don't.

## The pitch

Everyone sharing a single consumer GPU hits the same wall: compute VRAM is
**pinned** — the kernel cannot evict or swap it. Static partitioning wastes the
card; per-app VRAM budgets are a fool's errand; and nothing turnkey exists for
consumer AMD/Intel silicon (MIG-class isolation is datacenter-only).

`nixgpu` ships the sharing substrate that emerged from running exactly this in
production, distilled to its mechanisms:

- **Co-reside whatever fits.** Nothing is declared, capped, or reserved.
- **When it doesn't fit, priority decides who leaves.** The lowest-priority
  compute tenant is scaled to zero — the only way to free pinned VRAM.
- **The desktop is just the top-priority tenant.** Its graphics VRAM spills to
  GTT under pressure; the watcher reads that global signal from sysfs and sheds
  k8s tenants lowest-first. No host-side agent, no reservation.
- **Video is separate silicon.** The VCN/media engine gets its own scheduling
  lane and is never evicted for compute VRAM pressure.
- **The user is always told what is happening.** Cold start, contention, or
  desktop-in-use — one honest waiting page, never a silent hang.

Why in-kernel drivers only: the whole mechanism stands on what the kernel
exposes natively — sysfs VRAM/GTT counters, DRM cgroup accounting, device
files a plain device plugin can hand out. Out-of-tree proprietary stacks
don't provide that surface.

## Levels

`nixgpu` answers two different questions about one physical card, and the
repo's own export shape already splits them along the boundary the
`nixhost` namespace design draws between a host and what stands on it (one
addressable graph, hostname-rooted: `<host>.resources.*` is the machine
itself, `<host>.environments.<name>.*` is a projection standing on it):

- **Level 1 — the host.** Does this machine have a working GPU at all: the
  right vendor compute runtime installed, device nodes that don't move under
  it. True of a single-user desktop with no cluster in sight — it has
  nothing to do with sharing. Ships as `nixosModules` /
  `systemManagerModules` (`stableDevicePaths`, `toolchain`).
- **Level 2 / edge — who gets it.** Given a card that works, arbitrate
  between everything that wants it. Bare-metal/podman apps and Kubernetes
  pods are two independent consumer sets standing on the *same* Level-1
  resource — `<host>.gpu.apps` and `<host>.k3s.gpu.apps` in `nixhost`'s
  address space — and something has to decide who yields when both want the
  card at once. That something is the four modules below: an edge property
  connecting the two consumer branches, never a fact about either branch
  alone. Ships as `nixidyModules`, rendered into the k3s environment.

Neither level substitutes for the other: a host with a flawless toolchain
still needs an arbiter the instant two tenants contend for the same VRAM, and
an arbiter has nothing to arbitrate on a host where the card doesn't work in
the first place.

### Why one repo, not two

The honest split is Level 1 vs. Level 2/edge — not "this repo" vs. "a
sibling arbiter repo". Two things decided it stays one:

1. **The export types already are the two levels.** `nixosModules` /
   `systemManagerModules` render into a machine's own configuration;
   `nixidyModules` render into a k3s environment's manifests. Nix's module
   system already refuses to let one leak into the other — a second repo
   would enforce, at real coordination cost, a boundary the flake outputs
   already enforce for free.
2. **Splitting a tested, dogfooded arbiter costs more than it clarifies.**
   The four Level-2 modules are one contract-tested unit ([CONTRACT.md](CONTRACT.md),
   [studies/](studies/), [bench/](bench/)) that runs together in production
   today, and they already coordinate only through Kubernetes objects
   (labels, `PriorityClass` values) — never through Nix. Filing them behind
   a second flake input would not remove any coupling between
   `device-tokens`, `priority-ladder`, `pressure-watcher`, and
   `ondemand-front`; it would only add a version-pinning seam every consumer
   has to keep in lockstep, for no mechanical benefit.

A site that wants one level without the other already gets that for free —
`nixosModules`/`systemManagerModules` and `nixidyModules` are independent
export sets; nothing here requires importing both.

## Modules

The first four (**Level 2 / edge**) modules have landed (see
[CONTRACT.md](CONTRACT.md) for the behavior spec they implement); the kernel
module is still to come:

- **`device-tokens`** — split one card into parallel scheduling lanes
  (`compute` + `vcn` media engine) via a generic device plugin; co-scheduling
  with a small concurrency ceiling per lane. The ceiling is a blast-radius
  tuning knob, not a VRAM budget — it has been run live at 2, 3, and 16 on the
  same 16 GiB card, including a deliberate 18 GiB-of-demand stress test at
  count=16 that degraded by OOM-retry-loop rather than a card reset.
- **`priority-ladder`** — the PriorityClass set (`desktop` > `interactive` >
  `besteffort`) that defines who yields first. Priority is set by intent, not
  hardwired to an app.
- **`pressure-watcher`** — the one hand-rolled piece: a small host-native
  DaemonSet that watches VRAM pressure + starvation and reclaims by scaling
  the lowest-priority tenant to zero. Includes desktop GTT-spill detection and
  a device-plugin registration-zombie guard (both battle-tested).
- **`ondemand-front`** — scale-to-zero front (Sablier + Caddy) serving one
  honest status page while a pod is not-Ready: cold start, GPU contention, and
  desktop-in-use are the same wait-state, announced the same way.
- **`kernel`** *(optional, not yet extracted)* — DRM cgroup (dmem) accounting
  and TTM eviction-order patches for kernels that lack them. The watcher core
  runs on stock kernels reading sysfs.

### Host-side (Level 1)

Everything above is Level 2 / edge — about **sharing** a card that already works.
These are about the machine underneath it — and they are offered on both the
NixOS and the Arch/CachyOS plane, because a GPU host is not necessarily a
NixOS host.

- **`stableDevicePaths`** *(NixOS + system-manager, options-only in Home
  Manager)* — the host's **complete DRM
  device inventory**, and stable `/dev/dri` symlinks generated from it, so
  `device-tokens`' paths resolve regardless of DRM enumeration order.

  The Home Manager projection exposes the identical typed inventory and
  derived paths for user-session translators such as compositor config
  generators. It never writes udev rules; only the host plane does that.

  ```nix
  nixgpu.stableDevicePaths.devices = {
    gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
    bmc0 = { vendor = "aspeed"; pciId = "0x1a03"; vramMiB = 16; hasRenderNode = false; };
    dock = { bus = "platform"; driver = "evdi"; };   # no PCI parent at all
  };
  ```

  `bus` is a discriminator, not decoration: a PCI device is matched on
  `ATTRS{vendor}` and a platform device on `DRIVERS`, and until that split
  existed a virtual DRM device (`evdi`) was **undeclarable**. That was a
  correctness hole rather than a cosmetic gap — the inventory is the only place
  this family states which DRM devices a host has, and a consumer that can only
  *exclude* devices has to compute the complement of the permitted set against
  it. An undeclared device is not absent from the machine; it is absent from the
  restriction. `hasRenderNode` is a fact about the driver (set at compile time
  by `DRIVER_RENDER`), not a preference, and decides whether a `renderD*` rule
  is worth emitting at all.

  Set `address` (a device's PCI `domain:bus:device.function` or platform instance name) on an
  entry and it also gets `cardNamePath`/`renderNamePath` — a fourth symlink family,
  `/dev/dri/by-name/<key>-card`/`-render`, keyed on the device's own attrset key. This is the one
  that is actually safe to put in `WLR_DRM_DEVICES`: wlroots splits that variable on a bare colon
  with no escaping, so `cardPath`'s `pci-0000:0a:00.0-card` spelling silently breaks into three
  nonexistent paths, and `by-vendor` (colon-free) is ambiguous the moment two devices share a
  vendor. `by-name` is both colon-free and, because an attrset key can't collide, unambiguous even
  between identical cards. See `modules/stable-device-paths/options.nix` for the full argument.
- **`evdi`** *(NixOS + system-manager)* — the virtual DRM device a DisplayLink
  dock draws through. ⚠ `initial_device_count` defaults to **0** upstream, so a
  bare module load registers no device at all and every other signal says it
  worked; this module always writes the parameter. The N devices are created at
  `module_init()` and survive dock removal, while their USB relationship must be
  detached so the same card can be reused. evdi v1.15.0 gets that notifier wrong
  and leaks a stale card; `lib.evdiHotUnplug` carries the two upstream PR #581
  commits until a release contains them. With that correction, plugging a dock is
  a **connector** hotplug on a card that is already there. One evdi device = one
  connector = one monitor.
- **`displaylink`** *(NixOS + system-manager)* — DisplayLinkManager, evdi's
  proprietary userland, modelled with its real dependency on the module being
  loaded. Deliberately a separate module from `evdi`: the two halves are
  independently placeable, and in the container case they do not even run on the
  same system. The NixOS plane is Wayland-shaped and refuses to run beside
  nixpkgs' own X11-keyed DisplayLink module; the Arch plane carries the
  dependency override that stops one unsatisfiable `evdi` dependency from
  aborting the AUR reconcile for every package on the box, and replaces the
  vendor unit's impossible container-local `modprobe` with a condition on the
  host-owned module visible through `/sys`.
- **`toolchain`** *(NixOS + system-manager)* — **vendor × capability × platform**: which
  silicon this host has, and what it wants to DO with it (display, hardware
  video, compute, AI inference, 32-bit gaming, container exposure, probes, diagnostics),
  resolved to real package names per plane. See
  [modules/toolchain/README.md](modules/toolchain/README.md) for the full design
  and the boundary this module draws against the sibling
  [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) project.

  ```nix
  nixgpu.toolchain = {
    enable = true;
    vendor = "amd";
    capabilities.compute.enable = true;   # ROCm, on top of the plain driver runtime
    capabilities.probes.enable = true;      # glxinfo, vainfo, wayland-info
    capabilities.diagnostics.enable = true; # rocm-smi, rocminfo, radeontop, ...
  };
  ```

  Every capability defaults OFF — a cluster node running prebuilt images (whose
  containers carry their own toolkit) wants `probes` and `diagnostics` only, not the
  multi-gigabyte compute SDK; a workstation wants more. See
  `lib/catalogue.nix` for what each capability installs, per vendor, per plane,
  and why.

  Each plane carries its own real implementation rather than a shared list with
  a translation table, because the platforms disagree about more than spelling:
  ROCm is three packages on Arch and one attribute set in nixpkgs, and NVIDIA's
  userspace driver is a package on Arch but a *hardware option* on NixOS. The
  NixOS module deliberately does not configure `hardware.nvidia` — driver choice
  belongs to whoever knows the machine — and warns if the toolkit would install
  with no driver behind it. On the Arch plane, this module never reaches into
  nixpkgs at all: a selected package comes from pacman/AUR, structurally, not
  merely by convention — see `modules/toolchain/system-manager.nix`'s own header.

## Status

**Pre-alpha, and fully dogfooded: the originating production cluster runs
ALL FOUR modules.** `device-tokens`, `priority-ladder`, `pressure-watcher`,
and `ondemand-front` were adopted back into the production single-GPU cluster
they were extracted from (in-place, no object recreation) — the generalized
forms are **live-verified on the real 16 GiB RDNA2 card**, scheduling,
guarding, and fronting real tenants today (even the tenant label domain runs
on this repo's `nixgpu.corbet.ch/*` defaults). Each module directory
documents its options (`nixidyModules.*`). [CONTRACT.md](CONTRACT.md) is the
behavior contract the platform is built and tested against.

The repository can now also demonstrate that on its own: `nix flake check`
renders **all four modules** through real nixidy, from the placeholder values in
[examples/all](examples/all). That is a narrow claim on purpose — it proves the
modules evaluate and render, not that they arbitrate correctly, which is what the
live dogfooding above is evidence for. Until this landed, `nixidy` was not even a
flake input here, so nothing in CI evaluated these modules at all.

Worth noting what that check needed: of every option across all four modules,
**exactly one has no default** (`ondemandFront.caddyImage`). The arbiter is
almost entirely knowledge, because how a card is shared does not vary by site.

The token cap is proven across a real range on that card, not just at one
setting: raised live from 2 to 3 to 16, with a deliberate thundering-herd
stress test at 16 (six best-effort tenants demanding 18 GiB on a 16 GiB card)
holding `gpu_reset` at 0 throughout — the excess demand degrades by
OOM-retry-loop, never a reset. A real broker-blindness gap under contention
(a multi-model LLM server whose pod stayed Ready while a specific model
starved for VRAM) was also found and closed the same day, end to end through
the production request path, and is what motivated `pressure-watcher`'s
`brokerStatusUrl` and `killCooldownTicks` options below.

None of this is a claim of "production-hardened" or "no known issues": every
fix above shipped and was verified today, under deliberately adversarial
synthetic load, with zero multi-day organic soak time yet. Idempotent-batch
durability under forced preemption (contract B13) remains architecturally
sound but unexercised by the bench (a SKIP, not a PASS), and desktop
GTT-spill thresholds (B9) are still untuned against a real gaming session —
see the [`pressure-watcher` README](modules/pressure-watcher/README.md) for
both.

## Requirements (deliberate, not negotiable)

`nixgpu` is built for a declarative GitOps cluster: **nixidy-rendered
manifests synced by Argo CD** — the spine that the sibling
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) project ships. If
you hand-apply YAML, this project is not for you; the manifests are rendered,
versioned, and reconciled, and the modules assume that delivery path.

## Related projects

Part of an interoperating set — usable independently, designed together:

- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — the ground:
  bare-metal k3s on NixOS + the nixidy → Argo CD GitOps spine.
- [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — the serving
  lane: one shared LLM broker where the model store IS the registry
  (implements this contract's B4/B10/B14/B15). Its generator mirrors this
  repo's `nixgpu.sysfs.vramTotalAttr` (see `pressure-watcher`'s README) for
  live VRAM size, instead of hardcoding amdgpu's attribute name a second time.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — the
  tenants: curated app modules (image generation, TTS, …) that consume
  `nixgpu`'s three-line GPU contract.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
