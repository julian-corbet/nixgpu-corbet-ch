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

## Modules

The first four modules have landed (see [CONTRACT.md](CONTRACT.md) for the
behavior spec they implement); the kernel module is still to come:

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
  (implements this contract's B4/B10/B14/B15).
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — the
  tenants: curated app modules (image generation, TTS, …) that consume
  `nixgpu`'s three-line GPU contract.
- [nixvibe](https://github.com/julian-corbet/nixvibe-corbet-ch) — a coding
  agent in a real browser terminal; an indirect consumer (HTTP only, no GPU
  device of its own).

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
