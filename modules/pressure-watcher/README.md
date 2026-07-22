# pressure-watcher

The reactive core of nixgpu: a per-GPU-node DaemonSet (plain bash + kubectl)
that arbitrates one shared GPU between Kubernetes pods and a desktop session —
purely from **observed** signals. **No budgets, no reservations**: no tenant
ever declares "I need N GiB", nothing is pre-carved, nothing is toggled by hand.
The watcher measures real VRAM/GTT counters and real pod readiness, and acts
only when pressure is demonstrably hurting someone (CONTRACT.md B2/B8).

## Why it must exist

On in-kernel-driver compute stacks (ROCm and friends), compute VRAM is
**pinned** — the kernel cannot evict it. A high-priority pod that cannot get its
VRAM does not slow down gracefully; it **OOMs and crash-loops** while a
lower-priority pod sits comfortably on the card. Nothing in stock Kubernetes
resolves this: the scheduler placed both pods long ago, and device plugins only
count device files, not bytes. Someone has to watch the card and evict the right
tenant. That someone is this module.

## The three signals

1. **Starved pod.** A managed GPU pod stays not-Ready for `graceTicks` ticks
   while the card is above `hiWater` full. If a *lower*-priority managed pod is
   running, the watcher scales that pod's owning Deployment to 0 (falling back
   to pod deletion when there is no Deployment owner), then holds a cooldown so
   the reclaimed (pinned) VRAM actually lands before it re-decides.
2. **Desktop GTT spill.** A desktop session shares the card from *outside*
   Kubernetes — e.g. a host compositor or a sibling container whose cgroup the
   pod cannot read — so it can never be watched per-process. But graphics VRAM,
   unlike compute VRAM, **spills to system RAM (GTT)** under pressure instead of
   OOMing. Global `gtt_used` rising (by more than `gttDelta` per tick) while
   VRAM is full *is* the desktop thrashing. The desktop is treated as a
   synthetic top-priority tenant (`desktopPriority`, above every PriorityClass):
   when it thrashes, the lowest-priority in-cluster GPU pod is shed —
   incrementally, until the spill stops. The desktop never declares a number and
   is never a victim. A light game never fills the card, so this never fires for
   it.
3. **Registration zombie.** After a node/runtime crash, a device plugin can
   re-register into a zombie state: the plugin process believes it is healthy,
   but kubelet's device manager holds no devices for it, so node allocatable
   sticks at 0 forever — and the plugin *cannot* detect this itself
   ([squat/generic-device-plugin#63](https://github.com/squat/generic-device-plugin/issues/63),
   unfixed upstream). The guard cures it by external observation: when a
   resource in `guardResources` reads 0 (or is absent) for `guardGraceTicks`
   ticks while the plugin pod is Running, the plugin pod is bounced and
   capacity returns in seconds. A failed node query is never treated as zero
   (fail-closed). Empty `guardResources` disables the guard.

Design lessons baked into the script (from AntMan/Ray/oomd literature and
production incidents): grace before acting, the trigger must outrank the victim,
never act without a lower-priority candidate, scale-to-0 the owning Deployment
(stays down; a scale-from-zero front such as KEDA or Sablier brings it back on
demand) rather than delete-and-respawn, and cooldown after each action so it
lands before the next decision.

## Tenant labels

Every GPU tenant pod — regardless of which device-plugin resource it requests —
**must** carry `managedLabelKey` = `"true"`, or the watcher can neither protect
it (as a starvation trigger) nor evict it (as a victim). Tenants on the media
engine additionally carry `engineLabelKey` = `vcn`; they are separate silicon
(B3) and are exempt from all compute-pressure decisions.

Implementation note: the engine label key is embedded inside a kubectl jsonpath
expression, where dots inside a label key must be backslash-escaped
(`{.metadata.labels.nixgpu\.corbet\.ch/engine}`). The module builds the escaped
form from the option automatically — an unescaped dot would make jsonpath read
the field as empty and silently break engine discovery.

## Options (`nixgpu.pressureWatcher.*`)

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the pressure watcher application. |
| `namespace` | str | `"gpu-platform"` | Namespace for SA, DaemonSet, and script ConfigMap. |
| `createNamespace` | bool | `true` | Create the namespace (set `false` if another module owns it). |
| `project` | str | `"platform"` | Argo CD AppProject. |
| `image` | str | `"bitnami/kubectl:latest"` | Watcher image (needs bash + kubectl). `:latest` is inherited from the source system — pinning a version matching your cluster is wise. |
| `nodeSelector` | attrsOf str | `{ gpu = "amd"; }` | Run only on GPU nodes. |
| `managedLabelKey` | str | `"nixgpu.corbet.ch/managed"` | Label key marking every managed GPU tenant (value `"true"`). |
| `engineLabelKey` | str | `"nixgpu.corbet.ch/engine"` | Label key naming the tenant's GPU engine; value `engineExemptValue` = exempt media engine. |
| `engineExemptValue` | str | `"vcn"` | Engine-label value marking media-engine tenants that are never compute victims or triggers. |
| `hiWater` | strMatching `[0-9]*\.?[0-9]+` | `"0.85"` | VRAM-full gate, fraction of total (numeric string; non-numeric values fail at eval). Pressure is only "real" above this. |
| `graceTicks` | int | `2` | Ticks a tenant must stay starved/spilling before a kill (anti-flap). |
| `gttDelta` | int | `67108864` | GTT growth per tick (bytes) treated as noise (64 MiB). A noise floor, not a budget. |
| `tickSeconds` | int | `6` | Seconds per tick. Cooldowns are counted in ticks. |
| `desktopPriority` | int | `2000000` | Synthetic desktop priority; must outrank every PriorityClass. |
| `brokerStatusUrl` | str | `""` | Optional status endpoint of a shared multi-model LLM server (e.g. llama-swap `/running`). A shared server's pod stays Ready even when a model can't fit VRAM; set this and the watcher treats a model stuck non-`ready` while the card is full as a starved higher-priority tenant. Empty = off; fail-open; needs `curl`+`jq`. |
| `brokerPriority` | int | `1000` | Synthetic priority of the broker starvation signal (interactive tier). |
| `guardResources` | listOf str | `[ "devic.es/rocm-compute" "devic.es/vcn" ]` | Extended resources the registration guard watches; `[ ]` = guard off. |
| `guardLabel` | str | `"app=gpu-shares-device-plugin"` | Label selector for the device-plugin pod to bounce. |
| `guardNamespace` | str | `"kube-system"` | Namespace of the device-plugin pod. |
| `guardGraceTicks` | int | `5` | Zero-ticks before the bounce (anti-flap). |

## Usage

```nix
{
  imports = [ nixgpu.nixidyModules.pressure-watcher ];

  nixgpu.pressureWatcher = {
    enable = true;
    image = "bitnami/kubectl:1.31.2"; # pin to your cluster's minor version
    nodeSelector = { "example.com/gpu" = "true"; };
  };
}
```

The DaemonSet runs privileged as root with a read-only hostPath mount of `/sys`
— that is where the amdgpu `mem_info_vram_*` / `mem_info_gtt_used` counters
live. If the card's sysfs is not visible, the watcher degrades gracefully to
the pod-starvation signal only (no desktop spill detection). `NODE_NAME` is
injected via the Downward API; the script refuses to start (logs and exits 1)
if it is empty rather than guess a node name. The RBAC is the minimal set the
script uses, replicated verbatim from the source system.

## Status & tuning honesty

Extracted from a production system; this generalized form has not yet been
re-verified live. The default thresholds (`hiWater = 0.85`,
`gttDelta = 64 MiB`, `graceTicks = 2` at a 6 s tick) were tuned on a single
16 GiB RDNA2 card. The GTT-spill thresholds in particular deserve one real
gaming session on *your* hardware to tune: watch the log while a heavy title
runs and adjust `gttDelta`/`graceTicks` until light titles never trigger and
heavy ones shed exactly the lowest-priority pod.

Source lineage: generalized from a production single-GPU cluster.
