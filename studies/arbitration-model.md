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
- **Per-tenant VRAM quotas / declared budgets:** violates the measure-don't-
  declare principle; a single operator needs no fairness accounting.

## 2026-07-22 — the reactive model, stress-tested

The two open questions this doc left hanging — is graceful-OOM degradation
actually true at real oversubscription, and is the "broker-starvation
side-signal" really the low-impact, deferrable gap it was guessed to be — were
both settled the same day, live on the 16 GiB RDNA2 card.

**Graceful degradation, confirmed at deliberate oversubscription.** A hand-built
stress test (separate from the formal contract-bench harness) raised the
`rocm-compute` token cap to 16 — pure co-scheduling headroom, per the model
above — and threw a thundering herd of 6 best-effort hogs at 3 GiB each, 18 GiB
of demand against 16 GiB of card. Over 120 seconds, VRAM plateaued around
15.1–15.2 GiB, the herd stayed at 6 Deployments the whole time, and at most 0–1
pods were in a crash/OOM-retry loop at any sampled instant. Kernel fault
counters — `page_fault`, `ring_timeout`, `gpu_reset` — stayed at 0 throughout. A
higher-priority interactive pod arriving mid-saturation still got served, in
15s, via the same watcher-scales-lowest-priority mechanism described above. This
is direct empirical support for the doc's central claim: enforcement is
unnecessary because the excess demand degrades by OOM-retry-loop, never by
damaging the card.

**Broker-blindness was real, not the low-impact gap this doc guessed.** The
same stress session reproduced the operator's actual worst case: a real
gemma-4-26b chat completion through the production LiteLLM door, sent while the
card was saturated with best-effort hogs, errored after 37 seconds — against a
3-second baseline on an empty card, proving the failure was contention-specific.
Reading the broker's own logs and `/running` status API showed why: llama-server
was repeatedly OOM-exiting trying to load the model, `/running` held
`state=starting` for a sustained ~24s across six consecutive polls, and the
watcher never saw any of it, because the broker's own pod — a multi-model
server — stayed Ready throughout; one model failing to load doesn't make the
pod not-Ready. That is exactly the gap this doc's "deliberately not done"
section once described, except it was user-facing and reproducible on the
platform's actual hardest scenario, not a theoretical, deferrable edge case.

**The fix stayed inside the model: a starvation signal, no new machinery for
enforcement.** `pressureWatcher` gained an opt-in `brokerStatusUrl` (polled each
tick; fail-open on curl/jq failure so a probe outage never fabricates
starvation) and a `brokerPriority` — a starved broker model is just another
starved tenant to the existing eviction logic, same priority-ordered scale-to-
zero as any other signal. That closed half the gap and was confirmed firing
live, but a second re-test still failed (59s this time): the real blocker was
that `gemma-4-26b` was generated to run fully on GPU (`-ngl 999`, no offload),
because its on-disk size fit under a static threshold computed at store-scan
time — even though at *runtime* the card had no room left, and freeing one
tenant per watcher cooldown couldn't clear enough for a model that size before
llama-swap's retry gave up.

The actual resolution is the cleanest confirmation of this doc's "stand on
FOSS, don't reinvent" stance available: llama.cpp already ships a runtime
VRAM-fit mechanism (`--fit`, reading live free VRAM via `hipMemGetInfo` and
offloading MoE experts and then layers to fit whatever's free *right now*,
entirely inside llama.cpp) — and the platform's static `-ngl 999` generator flag
was disabling it outright, because passing any explicit offload flag turns
fitting off for that parameter. The fix was to stop fighting the tool: the
generator now emits `--fit on --fit-target FIT_TARGET_MIB` for chat models
instead of a static full-GPU-or-all-CPU choice, reusing the existing VRAM
reserve constant as the fit headroom. Re-run end-to-end through the real
LiteLLM door, with the card filled to ~13.5 GiB by five best-effort hogs and
only ~2.5 GiB free: the model showed `starting` for 35s and reached `ready`
by +40s, and the chat completion served successfully after 44 seconds total
— `gpu_reset` stayed 0 throughout. Zero new components were added to close this gap: a
starvation *signal* feeding the existing watcher, and turning back on a fitting
feature the platform already had access to and was accidentally suppressing.

Left honestly open: idempotent-batch durability under *forced* preemption
(B13) has still never been exercised by the bench — the ledger's S9 scenario
completed without a single resubmission occurring, so it is a SKIP, not a
PASS, and the mechanism remains architecturally sound but unproven together
under real preemption. Desktop GTT-spill thresholds (B9) remain untuned
against a real session, unrelated to today's work. And all of the above is
same-day verification under deliberately adversarial synthetic load — zero
multi-day organic soak time exists yet for any of it.

## The through-line

On a permanently-oversubscribed single consumer GPU, "perfect" is not zero
degradation — it is *ordered, graceful* degradation. Measured-VRAM reactive
eviction delivers that with one small controller and no datacenter machinery.
The field's admission tooling is built for a different problem (multi-tenant
fairness on isolable datacenter silicon); importing it here would add machinery
this platform's own failure model makes unnecessary.
