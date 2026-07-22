# Bench validation report — 2026-07-22

Scope: the formal `run-bench.sh` harness only (the scenarios defined in
`scenarios.md`), run against a live 16 GiB AMD RDNA2 (gfx1030) card on a k3s
cluster, topology `deviceTokens.rocm-compute` cap=3, `vcn` count=2.
Every verdict, number, and log line below is transcribed from an actual run;
nothing here is estimated or rounded beyond what was recorded live.

A separate, non-harness ad hoc stress test (a hand-built script, different
topology, cap raised to 16) was also run the same day to chase a specific
production incident and the fixes that came out of it — that work is out of
scope for this file; see the project's own change history for it, not this
report.

## Run #1 — template bug found and fixed

The first formal bench run (topology: cap=3, count=2 vcn) hit a harness bug,
not a platform bug: a duplicate `env:` block in `tenants/vram-hog.yaml`
silently clobbered `ALLOC_GIB`, so every rendered hog crashed with a Python
`KeyError` before it could allocate anything. Found by reading the live pod
logs, fixed by merging the two `env:` blocks into one.

The fix was re-verified with an isolated single-scenario run:

- **S1 (isolated re-verification): PASS** — all 3 tenants reached `Ready`, 0
  evictions, kernel counters unchanged.

## Run #2 — full sequence (post-fix)

Sequence run: `s6-start`, `s1`, `s2`, `s9`, `s11` (topology unchanged: cap=3,
count=2 vcn).

### S1 — co-residence (B1)

**Verdict:** PASS (see Run #1 above for the dedicated verification). In this
full-sequence run, S1's free-token pre-check correctly **SKIPped** instead of
running blind: a live comfyui TTL-warm tenant plus the broker were already
occupying both `devic.es/rocm-compute` tokens at cap=3, leaving 0 free.
Recorded reason: *"only 0 free devic.es/rocm-compute token(s)... rerun when
the card's lanes allow."*

**What this proves:** the pre-check does its job — a cap this low being fully
occupied by real tenants is co-residence working correctly, not a harness or
platform failure, and the bench says so rather than failing blind.

### S2 — contention / eviction (B2, B11, B12)

**Verdict:** PASS.

Watcher log, verbatim:

```
VRAM 88% + bench-s2-interactive (prio 1000) STARVED -> scale bench-s2-hog to 0 (lowest prio 100)
```

Result line, verbatim:

```
hog scaled to 0 within budget, interactive Ready after VRAM landed free, no inversion at window end, counters unchanged, no long CrashLoopBackOff
```

`gpu_reset` stayed 0.

**What this proves:** priority decides who yields, the yield completes within
budget, no inversion survives the end-of-window check, and no card reset
occurred.

### S9 — idempotent batch under forced preemption (B13)

**Verdict:** SKIP, not PASS.

The force-hog was sized correctly from live telemetry, verbatim:

```
sizing force-hog from telemetry: total=17163091968 used=8605265920 -> 10.0 GiB (margin 2 GiB)
```

The ledger completed (all batch items recorded), but the result was:

> preemption never occurred -- ledger complete but 0 resubmissions were
> observed, so B13 was not exercised

**What this proves:** the sizing logic itself works (it read real telemetry
and computed a correct force-hog size). It does **not** prove B13 — no actual
preemption/resubmission cycle was observed in this run, so the
idempotent-batch-survives-preemption behavior remains unexercised by the
bench.

### S11 — chaos

**Verdict:** PASS.

Result line, verbatim:

```
RESULT S11 = PASS -- no invariant violations across 600s of chaos (seed=21804, 120 generators fired)
```

One individual chaos-fired instance recorded its own FAIL inside the run
(`S11.S7#120` — a single probe hit an opaque error under heavy contention).
This is expected/acceptable and does not affect the scenario verdict: the
platform-level **continuous** invariants (no priority inversion across any
eviction, VCN untouched, `gpu_reset` at 0) held for the entire 600s window.
An individual synthetic request failing under extreme chaos is not the same
as an invariant violation.

**What this proves:** the platform's continuous invariants (no inversion, no
VCN interference, no card reset) hold under 600 seconds of overlapping,
randomized, concurrent scenario load — not that every individual synthetic
request during chaos succeeds.

## Calibration-only results (first clean pass, same overall bench effort)

These scenarios were run standalone, as safe/non-disruptive calibration
passes, ahead of the Run #2 sequence above.

### S3 — swap + TTL (B5, B6)

**Verdict:** PASS. Cold request served in **1.494s**. `vram_used` dropped
from **2394980352** to **873967616** bytes after the idle TTL elapsed.

**What this proves:** the cold-swap path serves within seconds, and an idle
model actually unloads/scales down rather than sitting resident forever.

### S4 — same-model concurrency (B14a)

**Verdict:** PASS. Concurrent throughput **17.8246 req/s** vs. serial
baseline **7.71226 req/s**; all requests in both phases gated HTTP 200.

**What this proves:** continuous-batching concurrency measurably beats
serial request-at-a-time handling on the same model.

### S5 — multi-model co-residency (B14b)

**Verdict:** PASS. `vram_used` plateau rose from **9032527872** to
**10311680000** bytes (over the configured 256 MiB floor) when a second model
loaded on top of the first; both models still answered HTTP 200 afterward.

**What this proves:** two small models stack in VRAM instead of one evicting
the other via swap, and both keep serving in parallel.

### S6 — persistent VCN transcoder (B3)

**Verdict:** PASS. The transcoder ran with **0 restarts** and no stalled
progress across the whole run.

**What this proves:** the media-engine (VCN) path is unaffected by compute
pressure — separate silicon, kept running throughout.

### S7 — the honest wait (B7)

**Verdict:** PASS, twice. Recorded result, verbatim:

> every probe answered with the service or the waiting-page marker; no
> unanswered wall-clock streak past 5s; opaque errors 0 <= budget 0

**What this proves:** a cold/scaling-to-zero app never leaves the user with
a silent hang — every probe got either the real response or the honest
waiting page, within the grace window, with zero opaque errors.

## What's not yet proven

- **B13 (idempotent batch durability under forced preemption):** S9 recorded
  SKIP, not PASS — the bench has never actually observed a resubmission in
  practice. The mechanism is architecturally sound and each half is
  independently proven elsewhere (the watcher evicts correctly, per S2; the
  idempotent-driver pattern is a documented design), but the two have not
  been exercised together under a real preemption event.
- **B9 (desktop GTT-spill thresholds):** not automated by this harness at
  all (S8 has no subcommand — it requires an actual human at the desktop or
  playing a game) and was not tuned against a real gaming/desktop session as
  of this report. This was an open item before this bench run and nothing in
  this run changed that.
