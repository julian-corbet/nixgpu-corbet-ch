# What would it mean to prove this contract?

`CONTRACT.md` states fifteen behaviors as if they were binary pass/fail
properties of the system. Most of them are not, once you have to check them
against a live card instead of reasoning about them on paper. This study is
the investigation that had to happen before writing a bench: what would
"works perfectly" even mean for a reactive, single-fault-domain, single-GPU
platform, what is actually proven about the running system today versus
merely designed, and what a bench can and cannot tell you as a result. It
motivates `bench/` (see that directory's `README.md` for the harness itself)
and should be read alongside `CONTRACT.md`, which stays the fixed target.

## "Works perfectly" is the wrong frame

A shared-nothing multi-tenant system can sensibly promise zero degradation to
tenants that don't touch each other. `nixgpu` cannot promise that, by design:
there is one card, one VRAM pool, and Behavior B2 is explicitly "the
lowest-priority tenant yields" — degradation for *someone* is the mechanism,
not a bug. So the only coherent multiuser pass criterion is not "nothing got
worse" but **ordered degradation**: when the card is under pressure, the
tenants that get worse are the low-priority ones, in priority order, and the
high-priority ones don't notice. A bench that reports a single aggregate
"did it pass" number for a contention scenario is asking the wrong question.
The right question is a per-priority-class breakdown: did `desktop` and
`interactive` latency stay flat while `besteffort` got shed? If a
lower-priority tenant kept running while a higher-priority one starved, that
is not "some degradation" — it is a priority inversion, and it is the one
failure mode this whole platform exists to prevent. This is why the bench
scenario for chaos (S11 in the bench spec) treats "no priority inversion in
evictions" as a continuous invariant, checked every tick, rather than a
one-time assertion at the end of a run — an inversion can happen and self-
correct within a tick window that an end-of-run check would miss entirely.

The corollary: a passing bench run is not a claim that the platform is free
of degradation. It's a claim that the degradation that did happen was
ordered correctly, stayed within the announced grace windows (B11), was
never silent (B7), and never crossed the one boundary that must never move —
the media engine (B3) and the kernel-level fault counters.

## What is actually proven, and by what kind of evidence

The contract's own "Automatable vs. Observed" split (CONTRACT.md, bottom
section) says which behaviors a test *can* mechanically check. That is a
different question from which behaviors have actually *been* checked, on the
real 16 GiB RDNA2 card, and what kind of check it was. Three tiers, and the
gap between them is the whole reason this bench needs to exist rather than
being declared unnecessary because "it's dogfooded":

**Proven on the real card, repeatedly, under real load:**

- **Co-scheduling of independent engines (B1, the compute/vcn split
  underlying B3).** The production system runs `device-tokens`' two lanes
  (`rocm-compute` + `vcn`) concurrently as its normal operating state, not as
  a one-off test — every day it runs a RAG stack plus a transcoding job on
  the same card. This is the best-proven claim in the whole contract because
  it's also the one load-bearing for the operator's daily use, so any
  regression would have surfaced already.
- **VCN parallelism specifically (B3).** The transcode lane staying up and
  making progress while compute-side pressure comes and goes is observed
  behavior on every production day, not a synthetic construction.
- **Continuous batching (B14a).** The shared LLM broker (`nixllm`, the
  sibling project) has served concurrent same-model requests in production;
  the throughput win over serial dispatch is a property of llama.cpp's own
  batching, not something `nixgpu` implements, but the fact that concurrent
  requests actually reach the resident model through this platform's
  scheduling (rather than queueing one-at-a-time behind a device token) has
  been observed live.
- **One synthetic kill-reclaim loop.** The pressure-watcher's core
  mechanism — starved higher-priority pod detected, lowest-priority managed
  Deployment scaled to zero, cooldown, re-check — has been exercised and
  confirmed to work *once*, in a constructed scenario, not as an emergent
  property of unrelated daily traffic. This is meaningfully different from
  the co-scheduling proof above: co-scheduling is proven by volume of
  incidental real-world repetition; the kill-reclaim loop is proven by a
  single deliberate trial. One green run of a mechanism whose entire job is
  to handle an adversarial edge case is evidence, not confidence.

**Designed, plausible, but not measured on the real card:**

- **Real-contention eviction under adversarial load (B2, B11, B12).** The
  *mechanism* (grace period, SIGKILL, scale-the-owning-Deployment) is
  implemented and reads sensibly against the AntMan/Ray/oomd literature the
  module README cites, but nobody has actually filled the card with a
  best-effort hog and timed how long the interactive tenant waits versus the
  watcher's `graceTicks`/`tickSeconds`/cooldown parameters under realistic
  jitter. The one proven kill-reclaim trial above does not establish this —
  it establishes the mechanism fires at all, not that it fires within budget
  under contention that looks like the S2 bench scenario.
- **Desktop GTT-spill thresholds and grace timing (B9, B11).** The
  pressure-watcher README says this outright: `hiWater`, `gttDelta`, and
  `graceTicks` were tuned once, on one card, and "deserve one real gaming
  session on your hardware to tune." Nobody has yet run a session where a
  light game correctly triggers nothing and a heavy game correctly sheds
  exactly the lowest-priority pod, with the shed timed and the false-positive
  rate on light titles checked. This is the contract's B9 in full, and it is
  the one behavior in the whole document explicitly marked "cannot be
  automated" (it needs a human at a keyboard) — which is exactly why S8 in
  the bench spec is an operator-scheduled observation mode, not a scenario
  the driver runs unattended.
- **Co-residency packing at the fitting boundary (B1, B14b).** Running three
  small things that trivially fit is proven (see above). Running the
  *largest* combination that still just barely fits — the actual edge the
  fit-gate math has to get right — has not been deliberately constructed and
  measured. The gap between "fits comfortably" and "fits exactly" is where
  measured-VRAM (B8) accounting errors would show up, and nothing has
  exercised that edge yet.
- **MoE-under-contention (B15 combined with B2).** The generator's
  expert-offload fit gate — `(GPU-resident footprint ≤ VRAM) AND (expert
  footprint ≤ free RAM)` — has not been tried while something else is
  simultaneously pressuring VRAM, only in isolation. Whether the fit-gate
  math holds when the "free RAM" side of the inequality is itself moving
  because another tenant is being evicted concurrently is untested.

**Not exercised at all:**

- **Any genuinely multi-user behavior.** Every proof above — including the
  daily-driven ones — is single-operator: one person's RAG stack, one
  person's transcode job, one person's desktop session, sequentially or
  incidentally concurrently, but never two independent humans issuing
  requests that actually contend with unpredictable timing. The priority
  ladder is designed to handle this (priority is set by intent, not by
  which human sent the request), but "designed to" and "observed to" are
  different verbs, and this contract has only ever been proven against the
  latter for a single user.

Being explicit about this tiering matters more than the bench itself: a
bench that quietly reports "S1 through S10: PASS" without distinguishing
"this scenario reconfirms something proven daily" from "this scenario is the
first time this has ever been checked" would flatten the most important
signal the exercise produces.

## What a bench measures but cannot fix

Two properties of the design are boundaries, not bugs, and no amount of
bench coverage changes them — the bench's job for these is to *confirm the
boundary holds where documented*, never to push past it:

- **Single fault domain.** One card, one kernel driver, one reset domain.
  An in-process GPU fault in *any* tenant — a driver bug tickled by one
  pod's kernel launch, a bad ROCm build, a genuinely hostile workload — can
  still reset the card for every tenant simultaneously, including ones the
  priority ladder was protecting. Nothing in `nixgpu`'s design changes this,
  because nothing at the k8s/scheduling layer *can* change it: isolation at
  this level would require SR-IOV or MIG-class hardware partitioning, which
  is explicitly out of scope (see the README: "MIG-class isolation is
  datacenter-only"). The bench's kernel fault counters
  (`page_fault`/`ring_timeout`/`gpu_reset`) exist to make this boundary
  *visible* whenever it is crossed, across every scenario, continuously —
  not to prevent it from being crossed.
- **Reclaim-by-kill loses in-flight work, by design.** B11 and B13 are
  explicit about this: yielding means the victim is killed after a grace
  period, and the platform does not checkpoint app-internal state. A batch
  job mid-inference when evicted loses that inference. This is not a gap to
  close — B13 states plainly that durability is the caller's job, and the
  correct pattern is an idempotent external driver that tracks completed
  work on disk and resubmits only what's unfinished. The bench's batch
  scenario (S9) exists to confirm *that pattern* survives forced preemption
  (all M jobs complete exactly once across an interruption), not to confirm
  that the platform preserves in-flight state — it deliberately doesn't, and
  a bench that expected it to would be testing the wrong contract.

Any future finding along these lines belongs back in `CONTRACT.md` as an
explicit constraint (it already covers both), not as a "known bug" — the
distinction matters because it changes what a red bench result even means:
a fault-domain crossing outside of an intentionally-injected fault is a real
regression; a lost in-flight batch item during an *unprotected* preemption
(one the driver hasn't yet resubmitted) is expected behavior working as
specified.

## Measurement philosophy

Three choices shape the bench, all downstream of the "ordered degradation,
not zero degradation" framing above:

**The telemetry endpoint is the sole source of truth.** Every scenario reads
one HTTP JSON surface (`{vram_used, vram_total, gtt_used, counters, tenants,
history}`) rather than each scenario independently parsing sysfs, kubectl
output, or log lines. This is not a convenience choice: B8 requires that the
*platform itself* decide fit using measured VRAM, not declared budgets, so a
bench that validated the platform's decisions using a different measurement
path than the platform uses internally would only be checking whether two
independently-fallible measurement methods happen to agree — not whether the
platform's actual decision-making is correct. Eviction events are derived
from tenant-state transitions in this same feed (Ready → not-Ready →
replicas 0) rather than from a separate eviction log, for the same reason:
one source, one ground truth, no reconciliation problem between two
telemetry paths that could silently drift apart.

**Calibrate, then assert.** Where CONTRACT.md gives a number (model load
"~2-3s" → a 10 s cold-wake budget default), the bench can assert against it
directly. Where it doesn't — desktop GTT-spill thresholds, exactly how long
a hog takes to visibly scale to zero on a given card generation, what
"aggregate throughput exceeds single-stream baseline" means in absolute
terms — a fixed threshold picked without ever having run the scenario is a
number invented to make a test pass, not a measurement. The bench's
"calibrate mode" runs the scenario, records what actually happened to a
baseline JSON file, and only later runs assert against *that* file. This
matters most exactly where the contract is honest about not having a number
yet (the pressure-watcher README's own "deserves one real gaming session to
tune" is the same admission in different words) — calibrate mode is how a
bench avoids manufacturing false confidence in the gap between "designed"
and "measured" that the tiering above spent so much effort keeping honest.

**Priority-ordered degradation is the pass criterion for every multiuser
scenario, not an afterthought metric.** Concretely: per-priority-class
latency percentiles, reported so degradation ordering is visible at a
glance, not buried in an aggregate. A scenario where `besteffort` p99
degrades 40x while `interactive` p99 is untouched is the system working
exactly as designed and should read as an unambiguous PASS; a scenario where
they degrade together, or in reverse order, is the failure this entire
contract exists to prevent, no matter what the aggregate throughput number
says. This is why S11's continuous invariant checking (rather than an
end-of-run summary) and B2/B12's priority framing are treated as the same
concern throughout the bench, not two separate checklist items.

## Cross-references

- [`CONTRACT.md`](../CONTRACT.md) — the fixed behavior target this bench
  measures against; every scenario maps 1:1 to one or more numbered
  behaviors (B1–B15).
- [`bench/README.md`](../bench/README.md) — the harness itself: scenario
  definitions, telemetry contract, calibrate/assert modes, and the
  results-JSON/markdown-report format this study's measurement philosophy
  motivates.
