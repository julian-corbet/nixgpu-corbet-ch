# The arbitration model, and why admission stays reactive

A design record for how a single consumer GPU is shared under **permanent
oversubscription** — the decision *not* to build VRAM-aware admission, and why
the reactive measured-VRAM watcher is the correct permanent arbiter. Grounded
in live measurement on a 16 GiB RDNA2 card and a survey of the field.

## The setting

One consumer GPU. Many workloads. Contention is not a transient to be
engineered away — it is the permanent condition (add a second card and the
workload grows to fill it). Single operator, so multi-tenant *fairness* is a
non-goal; the goal is **priority-ordered degradation that never inverts and
never crashes the card**.

## Three layers, one arbiter

Sharing on this platform involves three mechanisms, and it is worth being
precise about which one actually arbitrates:

1. **Token admission (k8s scheduling).** A generic device plugin advertises a
   small integer count of `compute` tokens, all mapping to the *same* physical
   device. This is a **co-scheduling / blast-radius cap**, not a VRAM budget —
   the count bounds how many GPU pods co-schedule at once, nothing more.
2. **Priority preemption (k8s).** In principle, a higher-priority pod could
   preempt a lower one to claim a scarce token. **Measured live: this is inert
   for device-plugin extended-resource tokens.** An interactive pod did not
   preempt an idle best-effort token holder; it waited for a token to free
   naturally. So preemption does no arbitration here.
3. **The reactive pressure-watcher.** A small host-native controller reads
   *measured* VRAM/GTT from sysfs and, when the card is VRAM-full **and** a
   higher-priority GPU pod is starved **and** a lower-priority one is running,
   scales the lowest-priority Deployment to zero. This is the **sole active
   arbiter**, and it decides by measured VRAM — exactly the platform's stated
   "measure, don't declare budgets" philosophy.

Because (2) is inert, (3) is not a second-order safety net — it is *the*
mechanism. It was validated live: under a real contention stage (a best-effort
tenant filled the card to 88%, a higher-priority tenant then demanded VRAM it
could not get), the watcher selected the lowest-priority tenant, scaled it to
zero, and the higher-priority work got its VRAM — no priority inversion, no
card reset, within budget. The higher-priority tenant absorbed a few graceful
OOM-retries during the eviction window, which is the intended shape.

## The decision: keep admission reactive; do not build a VRAM-aware admitter

The tempting "correct" end-state is admission by *measured free VRAM* — admit a
pod only if it fits, making the token count irrelevant. **We reject this**, for
reasons that are specific and, we believe, durable:

- **No consumer-AMD mechanism can enforce a per-pod VRAM ceiling.** The mature
  fractional-GPU stack (HAMi) enforces via the CUDA driver ABI — it intercepts
  CUDA/NVML symbols to fake per-pod memory limits. There is no equivalent that
  runs on a consumer AMD card. The one AMD implementation is an unproven
  proof-of-concept against a *datacenter* MI300X using `LD_AUDIT` HIP
  interception plus CU-masking — untested on consumer RDNA-class silicon and a
  multi-week fork, not an install.
- **The kernel path exists but isn't usable for admission.** The `dmem` DRM
  cgroup controller gained amdgpu support on recent kernels and can *account*
  discrete VRAM — but nothing in kubelet/containerd/CRI maps a pod resource
  request to a `dmem.max` limit, and dmem does not cover GTT (system-RAM-backed)
  allocations. It can measure; it cannot admit or enforce.
- **A custom scheduler plugin buys nothing here.** The one production analogue
  (a `PostFilter` preemption plugin driving eviction from real utilization) is
  wired to NVIDIA DCGM and, more fundamentally, relies on preemption — which is
  inert for these tokens.
- **And crucially: enforcement is unnecessary.** A clean ROCm VRAM OOM is
  *graceful* — the allocation request errors and can retry; it does not reset
  the card. (Card resets are a separate, specific kernel-fault issue, unrelated
  to how many pods co-schedule.) So the worst case of "imperfect admission" is a
  retried request, not damage. For a single operator that is entirely
  acceptable — it *is* graceful degradation.

Put together: the machinery that would make admission VRAM-aware is either
impossible on this hardware, unwired, or unnecessary. The honest move is to
**perfect the one reactive arbiter**, not replace it.

## What that leaves as real, right-sized work

- **Document the two-arbiter model** (this file, plus a note in the contract):
  the token count is a co-scheduling / blast-radius cap; the pressure-watcher is
  the sole VRAM arbiter; preemption is inert by design here. Under-documenting
  this is what made the layering confusing in the first place.
- **The co-scheduling cap is a tuning knob, not a budget.** Raise it so the
  watcher (not an arbitrary integer) governs co-residence; keep it finite only
  to bound pathological scheduler churn when many pods are admitted at once.
  Validated safe by the graceful-OOM property.
- **Optional, later — measurement, never enforcement:** move the watcher's
  victim selection from the global sysfs VRAM figure to per-tenant `dmem`
  accounting, for sharper "who is actually holding VRAM." Behind a flag, with a
  clean fallback, because dmem has APU/GTT accounting edge cases.

## Deliberately *not* done (and why)

- **Shortening pod grace periods to "win the OOM race":** there is no card-crash
  race to win — OOM is graceful. Engineering fragile timing constants to chase a
  non-problem was proposed and rejected.
- **A broker-starvation side-signal** (polling a multi-model server's
  management API to detect "a model can't fit VRAM"): a real gap in principle —
  a multi-model server's pod stays Ready even when one model can't load, so that
  starvation is invisible to a readiness-based watcher — but low-impact today and
  version-fragile to detect. Noted, deferred.
- **Per-tenant VRAM quotas / declared budgets:** violates the measure-don't-
  declare principle; a single operator needs no fairness accounting.

## The through-line

On a permanently-oversubscribed single consumer GPU, "perfect" is not zero
degradation — it is *ordered, graceful* degradation. Measured-VRAM reactive
eviction delivers that with one small controller and no datacenter machinery.
The field's admission tooling is built for a different problem (multi-tenant
fairness on isolable datacenter silicon); importing it here would add machinery
this platform's own failure model makes unnecessary.
