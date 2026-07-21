# nixgpu — the behavior contract

This file is the **fixed target**: *what* a shared single-GPU platform must do.
The behaviors are the spec; the modules in this repo are one implementation.
When implementation and contract disagree, the contract wins — and if a goal
itself is wrong, fix it *here*, not in a chat log or a commit message.

Most behaviors are automatable and double as the public test suite (see the
last section). This contract was extracted from a production system that runs
all of it on a single 16 GiB RDNA2 card.

## The reality we build inside (constraints, not choices)

- **One consumer GPU with an in-kernel DRM driver.** No SR-IOV, no MIG, no
  second card. Reference hardware: 16 GiB RDNA2.
- **VRAM is the hard wall.** Compute can be oversubscribed freely — sharing
  often *raises* utilization; VRAM cannot. Every behavior below is ultimately
  about fitting VRAM.
- **Compute VRAM is pinned.** The kernel cannot evict or migrate a compute
  allocation. Reclaim means ending the tenant, not squeezing it. (Graphics
  VRAM — the desktop — *is* evictable: it spills to GTT/system RAM. The
  asymmetry drives the whole design.)
- **Two independent engines run in parallel:** `compute` (GPGPU — LLMs, image
  generation, desktop graphics) and the media engine (`vcn` on AMD — hardware
  video encode/decode). Work on one does not block the other.
- **Models live on disk and stay hot in the page/ARC cache**, so a model loads
  RAM→VRAM in seconds. Swapping is cheap; even fully sequential is fast enough.

## Principles that govern every "how" decision

- **Declarative & GitOps.** Everything the platform *is* — manifests, configs,
  docs — lives in a repo and is delivered git → deploy. No imperative drift.
- **Common sense wins.** Where rules are silent or in tension, do what a
  sensible engineer would.
- **Stand on industry FOSS; don't reinvent.** Adopt proven components
  (llama.cpp, llama-swap, a generic device plugin, Sablier, KEDA, kernel
  cgroups). Hand-roll only where nothing exists — the reactive
  pressure-watcher is the one accepted exception, because nothing ships
  reactive priority-eviction for consumer cards.

## Workload classes & priority (who yields first)

Three classes. **Priority is set by intent, not hardwired to the app** — a
throwaway render is best-effort; the same app running an overnight batch the
operator is waiting on is raised for its duration.

- **Interactive** — a user is waiting (a chat query; the desktop session).
  Latency-critical, bursty, idle between bursts. Preempts batch.
- **Batch** — long-running, throughput-oriented, latency-tolerant. Runs at
  low priority: it takes the card whenever higher-priority work is idle and
  yields — scaled to zero — the instant something higher needs it. **No
  starvation protection; that is what low priority is for, and it stays
  strong.** It completes because it is driven idempotently from outside (B13),
  not because the GPU app checkpoints.
- **Persistent** — the media engine (B3): separate silicon, always on,
  parallel to compute.

Default ladder: `desktop` > `interactive` > `besteffort`. The media lane is
orthogonal.

## Behaviors

**B1 — Co-reside whatever fits.**
If the desktop uses 1 GiB, an image app holds a 6 GiB model, and a 7 GiB LLM
is requested (total ≤ VRAM), all three run **in parallel** and nothing is
evicted.

**B2 — When it does not fit, priority decides who leaves.**
When the card is full and a higher-priority task needs VRAM, the
**lowest-priority compute tenant yields** (scales to zero / unloads) until the
new task fits — with **no OOM crash and no card reset**.

**B3 — A media-engine app may stay resident forever.**
Compute-side VRAM pressure never touches a `vcn` tenant — different engine; it
keeps running in parallel with whatever is on compute.

**B4 — One LLM server owns all LLMs; no app hogs VRAM.**
Every app needing chat / embeddings / reranking goes through **one shared LLM
server** that manages residency across its models. No app starts its own GPU
model server; no app reserves VRAM for itself.

**B5 — Models load on demand and swap cheaply.**
A non-resident model loads from cache in seconds; if room is needed first, the
least-needed / lowest-priority resident model unloads. Co-residence (B1) is
preferred when it fits; sequential swap is the acceptable fallback.

**B6 — Idle tenants scale to zero.**
Past its idle TTL, a model unloads and an app's pod scales to zero. Idle work
never holds the card. (This is what makes B1/B2 possible on 16 GiB.)

**B7 — The user is always told what is happening.**
Cold start, queue, or eviction — the user sees a clear status ("loading
model…", "GPU busy — queued", "paused for a higher-priority task") and
**never a silent hang or an opaque error**. "What is happening, or why not"
is a first-class feature.

**B8 — Decisions use measured VRAM, not declared budgets.**
Fit decisions use **live measured VRAM** (DRM/dmem accounting, sysfs),
including non-LLM tenants (image apps, the desktop). No static per-app quotas
or reservations, ever.

**B9 — The desktop is the top interactive tenant.**
When the operator uses the desktop (or games), it reclaims the VRAM it needs —
graphics VRAM spills to GTT, the watcher reads the spill as starvation of the
top-priority tenant, and lower-priority compute yields. The desktop has **no
reserved floor**; it is demand-driven, just highest priority.

**B10 — The store IS the registry.**
Any correctly-formatted model file (GGUF) dropped in the store, of a size that
fits the card, in the conventional location that signals its serving mode
(`embeddings/` → embedder, `rerankers/` → reranker, else chat), becomes
callable **by name, loaded on demand** — with **no hand-maintained model
list**. Whatever per-model config the serving engine needs is **generated from
the store**: mode from the path, context + chat template from GGUF metadata,
the rest from sane defaults. The generated config is a derived, throwaway
artifact, never a source of truth. Oversized dense models are skipped (never
risk a card-reset load); oversized MoE models are served per B15; shard sets
collapse to their first member; stable app-facing names come from a one-line
alias file beside the model. "Add a model" = drop the file.

**B11 — Yielding is clean, time-bounded, and announced.**
A yielding tenant gets a **short grace period** to finish its current step,
then is killed. A fast step (one image) finishes and is saved; a slow step (a
video render) overruns the grace and dies — the arbiter is **the waiting
task's tolerated time**, not the batch's wish. Mechanism: the standard k8s
graceful-termination deadline → SIGKILL, no hand-rolled logic. Both yields are
announced (B7).

**B12 — Nothing on compute is permanently pinned by default.**
Every compute tenant is evictable by priority. "Stay warm" = high priority +
short TTL, never a fixed exemption. A job that genuinely must run
uninterrupted gets **raised priority for its duration**, not a pin. Only the
media engine (B3) is exempt — separate silicon.

**B13 — Batch durability is the caller's job, not the platform's.**
The platform guarantees clean yield (B11), cheap scale-from-zero (B5/B6), and
notification (B7). It does **not** checkpoint app-internal state and does
**not** shield low-priority work from starvation. A batch that must survive
preemption is driven idempotently from outside: a driver tracks done items
(e.g. completed outputs on disk) and resubmits only the unfinished ones.

**B14 — Concurrency is first-class, twice.**
(a) **Same-model:** concurrent requests to one resident model are interleaved
by continuous batching into shared forward passes — the biggest utilization
win. (b) **Multi-model co-residency:** several small models that fit together
are resident and served in parallel, not swapped. The generator co-resides
what fits and falls back to swap-one-at-a-time (B5) only when it must.

**B15 — MoE / partial offload: a model larger than VRAM is still servable.**
"Fits the card" (B10) means fits *given its serving config*, not raw file
size. A dense model needs its weights in VRAM; a Mixture-of-Experts model runs
with experts in CPU RAM and only attention/shared layers + KV on the GPU. The
generator detects MoE from GGUF metadata and emits an expert-offload config;
the fit gate becomes *(GPU-resident footprint ≤ VRAM) AND (expert footprint ≤
free RAM)*.

> B4/B10/B14/B15 concern the shared LLM serving lane. The lane itself ships as
> an app module in the sibling **nixapps** project; the behaviors stay in this
> contract because they are platform obligations — any serving lane on a
> `nixgpu` card must satisfy them.

## Which behaviors become automated tests vs. stay observed

- **Automatable** (real tests against a live card): B1, B2, B5, B6, B8, B12,
  B13, B14, B15.
- **Observed / operational** (need a real session): B3 (a live media app runs
  through a compute eviction), B7 (the status surfaces), B9 (a gaming session
  reclaims correctly).

## The proving ground

The originating system proved the contract with **four models contending for
16 GiB** — a RAG stack (embedder + reranker + large chat model) plus an image
generator — under real desktop use. A platform that satisfies B1–B10 under
that load generalizes to every tenant added later.
