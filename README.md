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

## Planned modules

Extraction targets, in order (see [CONTRACT.md](CONTRACT.md) for the behavior
spec they implement):

- **`device-tokens`** — split one card into parallel scheduling lanes
  (`compute` + `vcn` media engine) via a generic device plugin; co-scheduling
  with a small concurrency ceiling per lane.
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
- **`kernel`** *(optional)* — DRM cgroup (dmem) accounting and TTM
  eviction-order patches for kernels that lack them. The watcher core runs on
  stock kernels reading sysfs.

## Status

**Pre-alpha, extraction not started.** The mechanisms are real and proven in
production on a 16 GiB RDNA2 card (continuous batching, VCN-parallel video,
reactive kill-reclaim, desktop spill-shedding — all verified live). This repo
is the generalization of that system; no module has been extracted yet.
[CONTRACT.md](CONTRACT.md) — the behavior contract the platform is built and
tested against — is the first real artifact.

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
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — the
  tenants: curated app modules (LLM serving, image generation, …) that consume
  `nixgpu`'s three-line GPU contract.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
