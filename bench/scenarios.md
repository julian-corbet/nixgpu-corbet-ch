# Scenarios

Each scenario below maps to exactly one `run-bench.sh` subcommand and one (or
a small group of) CONTRACT.md behavior(s). This file is the precise
procedure + pass criteria; `bench/README.md` is the orientation and
how-to-run.

Every scenario:

- creates its own tenants in `$NAMESPACE` only, labeled
  `bench.nixgpu.corbet.ch/run=true`, and deletes them itself at the end
  (the `run-bench.sh` EXIT trap deletes them too, as a backstop, if the
  scenario aborts first);
- reads `$TELEMETRY_URL` as its measurement source for VRAM/GTT/kernel
  counters/tenant residency (see README for the exact JSON shape expected);
- treats every budget (`*_BUDGET_S`, `*_TTL_S`, `*_THRESHOLD_S`, ...) as a
  `bench.env` value, not a hardcoded constant — the numbers quoted below are
  CONTRACT.md's own numbers where it states one (e.g. the "~2-3s" model load
  behind `COLD_WAKE_BUDGET_S`), and a conservative placeholder everywhere
  else, meant to be replaced by `calibrate` (see the bottom of this file).

---

## S1 — co-residence (CONTRACT.md B1)

**Subcommand:** `run-bench.sh s1`

**Procedure:**
1. Snapshot kernel counters (`t_counters`) as the pre-run baseline.
2. Render and apply three `vram-hog.yaml` tenants from `bench.env`'s
   `S1_TENANT_{A,B,C}_GIB` / `S1_TENANT_{A,B,C}_PRIORITY` — sized to fit
   together comfortably under `CARD_VRAM_GIB`, at deliberately *mixed*
   priorities (the point of B1 is that priority does not matter while
   everything fits).
3. Wait for all three Deployments to report `Available`, each within
   `COLD_WAKE_BUDGET_S`.
4. Snapshot kernel counters again.
5. Check each Deployment's replica count.

**Pass criteria:**
- All three tenants reach `Available`.
- Zero Deployments were scaled to 0 (no evictions).
- Kernel counters (`page_fault`, `ring_timeout`, `gpu_reset`) are
  byte-identical before and after.

**Fails if:** any tenant never becomes Ready, any Deployment's replica count
reads 0 at the end, or any counter changed.

---

## S2 — contention (CONTRACT.md B2 / B11 / B12)

**Subcommand:** `run-bench.sh s2`

**Procedure:**
1. Snapshot kernel counters.
2. Apply a best-effort `vram-hog.yaml` sized by `S2_HOG_GIB` (large enough
   to leave no room for the next tenant — `bench.env` documents that
   `S2_HOG_GIB + S2_INTERACTIVE_GIB` must exceed `CARD_VRAM_GIB`). Wait for
   it to become Ready.
3. Apply a second `vram-hog.yaml` at `gpu-interactive` priority, sized by
   `S2_INTERACTIVE_GIB`. It cannot fit alongside the hog.
4. Poll the hog's Deployment replica count until it reads `0` (the watcher's
   scale-to-zero action), within `EVICTION_BUDGET_S` — this is B2's "the
   lowest-priority compute tenant yields" and B11's "yielding is
   time-bounded" in one measurement.
5. Wait for the interactive tenant to reach `Available`, within
   `COLD_WAKE_BUDGET_S` of the hog's VRAM actually landing free: the wake
   clock does **not** start at apply time — the driver snapshots `vram_used`
   at the full-card level (hog resident) and starts the clock only once
   telemetry shows `vram_used` dropping below it (replicas hitting 0
   precedes the allocator giving the memory back; B11's wake budget is
   about the latter). The drop-wait itself is bounded by
   `EVICTION_BUDGET_S`.
6. One-shot priority-inversion check at the end of the eviction window:
   with the yield complete and the wake budget spent, no lower-priority
   compute tenant may still read `ready: true` while a higher-priority one
   reads `ready: false` (during the window itself that pattern is the legal
   in-flight transient; at the end it has run out of excuses).
7. Poll the interactive tenant's pod `waiting.reason` for up to
   `OOM_RETRY_WINDOW_S`; it may show `CrashLoopBackOff` for a while (a
   legitimate OOM-retry cycle while it waits for the hog's VRAM to actually
   free) but must clear before the window elapses (B11: "no OOM crash and no
   card reset" as a *steady state*, not literally zero transient restarts).
8. Snapshot kernel counters a final time.

**Pass criteria:**
- The hog's Deployment reaches `replicas: 0` within `EVICTION_BUDGET_S`.
- The interactive tenant reaches `Available` within `COLD_WAKE_BUDGET_S` of
  the telemetry-observed VRAM drop.
- No priority inversion remains at the end-of-window one-shot check.
- Kernel counters unchanged start-to-finish (no card reset, per B2).
- The interactive pod is not still `CrashLoopBackOff` when
  `OOM_RETRY_WINDOW_S` elapses.

**Fails if:** the hog never yields, the interactive tenant never becomes
Ready, an inversion survives the end-of-window check, any kernel counter
changed, or the interactive pod is still crash-looping past the retry
window.

---

## S3 — swap + TTL (CONTRACT.md B5 / B6)

**Subcommand:** `run-bench.sh s3`

**Prerequisite:** `$MODEL_COLD` is a model name the OpenAI-compatible door
(`$OPENAI_URL`) recognizes but is **not** resident when the scenario starts.

**Procedure:**
1. Snapshot `vram_used` from telemetry (pre-request context only — the
   model is not resident yet, so this number is *recorded*, never asserted
   against).
2. Send one `chat/completions` request for `$MODEL_COLD`, measuring wall
   time from request start to the HTTP response completing
   (`request-to-first-response`).
3. Confirm the request succeeded (HTTP 200).
4. Snapshot `vram_used` again — the **resident** level, taken after the
   completion returned, i.e. with the model loaded. This is the TTL
   baseline: comparing the post-TTL level against the *pre-request*
   snapshot would demand the impossible (dropping below a level measured
   before the model ever occupied VRAM) whenever anything else was resident
   at start.
5. Sleep `IDLE_TTL_S` (must be ≥ the real idle-TTL your front/broker uses,
   ideally with a little margin — see `bench.env`'s comment on
   `IDLE_TTL_S`).
6. Snapshot `vram_used` a final time.

**Pass criteria:**
- The cold request returns HTTP 200 (B5: it loads from cache in seconds,
  regardless of the exact number — the number is recorded, not gated,
  because a cold swap may include an unload-then-load cycle).
- `vram_used` after the idle sleep is strictly lower than the **resident**
  snapshot from step 4 (B6: idle tenants scale to zero / models unload).

**Fails if:** the cold request fails, or VRAM does not drop below the
resident level after the idle period.

---

## S4 — same-model concurrency (CONTRACT.md B14a)

**Subcommand:** `run-bench.sh s4`

**Procedure:**
1. Baseline: send `CONCURRENT_REQUESTS` completion requests to
   `$MODEL_CONCURRENCY` **serially** (one after another); capture **every
   request's HTTP code**; time the whole batch; derive
   `serial_req_per_s = N / serial_wall_time`.
2. Send the same `N` requests **concurrently** (backgrounded, `wait`ed
   together); capture every HTTP code again; derive
   `concurrent_req_per_s = N / concurrent_wall_time`.
3. **HTTP gate before any comparison:** at least `S4_MIN_OK_COUNT`
   (default: all `N`) requests must have returned 200 in **each** phase.
   A throughput "win" built on instant error responses measures nothing
   but error-path speed, so failing the gate is a FAIL of the scenario —
   the throughput comparison is void, not attempted. (`calibrate` applies
   the same gate before recording its serial baseline: a baseline built
   from failing requests would poison every later assert against it.)

**Pass criteria:** the HTTP gate holds in both phases, and
`concurrent_req_per_s > serial_req_per_s` — continuous batching
interleaving concurrent requests into shared forward passes must win over
doing them one at a time.

**Fails if:** either phase produces fewer than `S4_MIN_OK_COUNT` HTTP 200s,
or concurrent throughput does not exceed the serial baseline.

---

## S5 — multi-model co-residency (CONTRACT.md B14b)

**Subcommand:** `run-bench.sh s5`

**Prerequisite:** `$MODEL_SMALL_A` and `$MODEL_SMALL_B` are two *different*
small models that are expected to fit together.

Telemetry is **pod-level, never model-level**: two models served by the
same broker pod are one `tenants[]` entry, so "both model names ready in
one snapshot" can never be observed there. Co-residency is instead
inferred from the `vram_used` plateau.

**Procedure:**
1. Snapshot `vram_used` (context baseline).
2. Send one completion request to `$MODEL_SMALL_A`; snapshot `vram_used`
   again — **A's plateau**.
3. Send one completion request to `$MODEL_SMALL_B`; snapshot `vram_used`
   again — the combined level.
4. Plateau check: the combined level must exceed A's plateau by at least
   `S5_CORESIDENCY_FLOOR_MIB` (a swap-in-place — B5's sequential fallback —
   keeps the plateau roughly flat instead of stacking B on top of A).
5. **After** the plateau check, send one more completion request to each
   model: both must still answer HTTP 200 (if loading B evicted A, A is no
   longer being *served in parallel*, whatever the plateau said).

**Pass criteria:** all four requests return HTTP 200, and the post-B
`vram_used` exceeds A's plateau by at least the configured floor.

**Fails if:** any request fails, or the plateau never rises by the floor
(the generator fell back to swap instead of co-residing).

---

## S6 — persistent VCN transcoder (CONTRACT.md B3)

**Subcommands:** `run-bench.sh s6-start` (before everything else),
`run-bench.sh s6-stop` (after everything else).

**Procedure:**
1. `s6-start` applies `tenants/vcn-transcoder.yaml` — a VAAPI ffmpeg loop
   transcoding a synthetic `lavfi testsrc` pattern, requesting the
   `$DEVICE_TOKEN_VCN` lane and carrying `$ENGINE_LABEL_KEY: $ENGINE_VCN_VALUE`
   (the pressure-watcher's compute-exemption label, per B3). Waits for it to
   become `Available`. If the apply itself is rejected, `s6-start` records
   `S6 = FAIL` immediately and every later VCN-dependent assertion is
   skipped (`s6-stop` records SKIP instead of judging a transcoder that
   never existed; S11 skips its per-tick VCN invariant with a notice).
2. Every other scenario runs (S1 through S11) while this pod keeps
   transcoding in the background — it is never told about, or coordinated
   with, anything else the bench does.
3. Throughout the run (checked at least once per `TICK_S` during S11, and
   once at `s6-stop`), the health check reads the pod's restart count and
   greps its log tail for the most recent `TRANSCODE LOOP` / ffmpeg
   `-progress` line. A pod that cannot be found at all is a violation in
   its own right (distinct from `restartCount: 0` — absent is not "never
   restarted").
4. Staleness state (the last distinct progress line and when it was first
   seen) is persisted to `$OUTPUT_DIR/vcn-progress.state` **between
   invocations** — `s6-start`, each scenario, and `s6-stop` are separate
   processes, so without the state file the final `s6-stop` check would
   start blind and accept a log that had been frozen for the entire run.
5. `s6-stop` runs one final health check, then deletes the transcoder.

**Pass criteria:**
- `restartCount` is `0` at every check, start to finish.
- A fresh progress line is always found — no gap longer than
  `VCN_STALL_THRESHOLD_S` between two consecutive progress log lines (B3:
  compute pressure never touches it; it is separate silicon and keeps
  running in parallel with whatever compute is doing).

**Fails if:** the container restarts even once, or progress logging stalls
past the threshold at any check.

---

## S7 — the honest wait (CONTRACT.md B7)

**Subcommand:** `run-bench.sh s7`

**Prerequisite:** `$PROBE_URL` fronts a scale-to-zero app (an
`ondemand-front`-style Sablier+Caddy front, or equivalent) currently at zero
replicas (cold), and `$WAITING_PAGE_MARKER` is a string that appears **only**
on that front's waiting page — never on the real app's response, and never
on an unrelated 404.

**Procedure:**
1. Poll `$PROBE_URL` every `PROBE_INTERVAL_S` seconds, up to
   `COLD_WAKE_BUDGET_S * 6` total.
2. Classify each sample: `OK:<code>` (an answered, non-waiting-page
   response), `MARKER:<code>` (the waiting page), or
   `UNANSWERED:rc=<curl_rc>` — **any** non-zero curl exit counts as
   unanswered, not just connection-refused (7) and timeout (28): DNS
   failure, TLS failure, a reset mid-body, ... all mean the user got no
   page, which is exactly what B7 forbids.
3. Track the unanswered streak by **wall-clock delta** from the first
   unanswered sample (each probe itself takes up to its own 3s timeout, so
   counting ticks × `PROBE_INTERVAL_S` undercounts real user-facing dead
   air). Any answered sample resets the streak.
4. An answered non-2xx **without** the waiting-page marker is an **opaque
   error** (a raw 502/503 leaking through the front — what the "one honest
   waiting page" exists to prevent). Each one is counted; the count is
   budgeted by `S7_OPAQUE_BUDGET` (default 0) and gates PASS.
5. Stop as soon as an `OK:2xx` sample is seen (the real app is up) or the
   overall wait budget elapses.

**Pass criteria:**
- No unanswered wall-clock streak ever exceeds `PROBE_GRACE_S`.
- The app eventually answers `OK:2xx` within the wait budget.
- The opaque-error count is ≤ `S7_OPAQUE_BUDGET`.

Every sample is appended to `$OUTPUT_DIR/invariants.log` regardless of
outcome, so a FAIL is always traceable to the exact sample(s) that broke it.

**Fails if:** any unanswered streak exceeds `PROBE_GRACE_S`, the app never
answers within the budget, or opaque errors exceed the budget.

---

## S9 — idempotent batch under forced preemption (CONTRACT.md B13)

**Subcommand:** `run-bench.sh s9`

**Procedure:**
1. Create an empty ConfigMap (`bench-s9-ledger`) as the external "done"
   record — this stands in for whatever a real batch driver would track
   completed items in (files on disk, a database row, ...).
2. Submit `BATCH_JOB_COUNT` bare Pods (`restartPolicy: Never`, best-effort
   priority), one per item index. Each item pod: checks whether its own key
   already exists in the ledger (idempotent no-op if so), otherwise
   simulates `BATCH_ITEM_WORK_SECONDS` of work and then patches its key into
   the ledger.
3. Partway through (`BATCH_ITEM_WORK_SECONDS / 2`), apply an
   interactive-priority `vram-hog.yaml` **sized from live telemetry**:
   `(vram_total - vram_used) + S9_FORCE_HOG_MARGIN_GIB` GiB, so it
   genuinely cannot fit and the pressure-watcher must reclaim (a fixed size
   silently under-pressures a mostly-empty card, and the scenario would
   "pass" without B13 ever being exercised). The item pods themselves hold
   **no device token and touch no GPU** — they are targeted because they
   carry the managed label at best-effort priority with no Deployment
   owner, which is exactly the population the watcher's documented fallback
   (pod delete instead of scale-to-0) selects its lowest-priority victim
   from.
4. Driver loop (this **is** the "idempotent batch driver" B13 describes —
   external to the platform): every `TICK_S`, check the ledger for missing
   entries; for each one whose pod is gone or `Failed`, resubmit a fresh pod
   at the same index, **counting every resubmission** (that count is the
   observed-preemption evidence the verdict requires). Continue until the
   ledger has all `BATCH_JOB_COUNT` entries or a generous deadline elapses.

**Pass criteria:** the ledger ends up with exactly `BATCH_JOB_COUNT` entries
— every item completed, exactly once recorded — **and at least one
resubmission was observed** (proof a preemption actually happened).

**Skips if:** the ledger completes with zero resubmissions — recorded as
SKIP "preemption never occurred", because a run in which nothing was ever
killed proves nothing about B13 (raise `S9_FORCE_HOG_MARGIN_GIB` or
`BATCH_ITEM_WORK_SECONDS` and rerun).

**Fails if:** the deadline elapses with any item still missing from the
ledger.

---

## S10 — oversized MoE model (CONTRACT.md B15)

**Subcommand:** `run-bench.sh s10`

**Prerequisite:** `$MODEL_MOE` names a Mixture-of-Experts model whose dense
GPU-resident footprint under expert offload fits VRAM, but whose *total*
weight size does not.

**Procedure:**
1. Snapshot kernel counters.
2. Send one completion request to `$MODEL_MOE`.
3. Snapshot kernel counters again.

**Pass criteria:** the request returns HTTP 200 (served via CPU expert
offload, per B15's fit gate — GPU-resident footprint ≤ VRAM AND expert
footprint ≤ free RAM), and kernel counters are unchanged (no card reset from
an oversized load attempt).

**Fails if:** the request fails, or any kernel counter changed.

---

## S11 — chaos

**Subcommand:** `run-bench.sh s11 [seed]`

**Procedure:**
1. Seed the bench's own PRNG (`$RANDOM`) — from the argument if given, else
   a fresh random seed (recorded in the result so a failing chaos run is
   reproducible).
2. Detect up front whether the S6 transcoder is actually running; if not,
   log a notice and skip the per-tick VCN invariant for the whole chaos run
   (one honest SKIP instead of a per-tick "no pod found" violation against
   a tenant that was never started).
3. Loop for `S11_CHAOS_DURATION_S`, once per `TICK_S`:
   - Fire one randomly-chosen scenario generator (S1, S2, S3, S4, S5, or S7)
     as a background subshell — chaos deliberately **overlaps** scenarios
     instead of serializing them, the way a real cluster's demand actually
     arrives. Each fired instance gets a **unique name suffix** (`-c<n>`,
     the chaos instance counter) threaded through every tenant it renders,
     and records its result under a **distinct chaos id** (`S11.S2#<n>`,
     `S11.S7#<n>`, ...) — overlapping instances of the same generator must
     never fight over one Deployment name, and chaos rows must never
     masquerade as the dedicated runs' rows in `results.json`.
   - Check every continuous invariant (below) and append any violation to
     `$OUTPUT_DIR/invariants.log`.
4. At the end of the duration, `wait` for any still-running background
   generator, then verdict on total violations.

**Continuous invariants, checked every tick:**
- **Kernel counters unchanged** from the pre-chaos baseline — any drift is
  an immediate violation (a card reset or fault during chaos is never
  acceptable, however busy the card is).
- **No priority inversion**: read telemetry's `tenants[]`; an inversion is
  a **lower**-priority compute tenant reading `ready: true` while a
  **higher**-priority one reads `ready: false` (excluding `engine == vcn`,
  which is orthogonal, per B3) — the watcher starving the very tenant it
  exists to protect. A single inverted snapshot is only a suspicion: an
  eviction/wake in flight legitimately looks inverted for a moment, and B11
  explicitly grants yielding a time budget. It becomes a hard FAIL only
  when the inversion **persists across ticks for ≥ `EVICTION_BUDGET_S`**
  of wall-clock (first sighting is logged as a notice; the violation is
  counted once per persistent episode). Note the direction: a
  higher-priority tenant ready while a lower one is down is the watcher
  *working* (it just evicted the loser) and is never flagged.
- **VCN pod untouched**: the same restart-count + progress-staleness check
  S6 uses, run inline every tick.
- **Every probe answered per S7**: one probe sample per tick, logged; a
  `REFUSED`/`TIMEOUT` here is logged but not itself fatal to chaos (S7's own
  dedicated run is the strict gate for the grace-period budget) — chaos logs
  it so the report's degradation-by-class narrative has the data even when
  it doesn't independently fail the scenario.

**Report requirement:** the human markdown report must show latency
degradation **ordered by priority class** across the chaos window — i.e.,
`gpu-besteffort` requests should show the most degradation, `gpu-interactive`
the least, under load. (`run-bench.sh` records raw measurements per fired
generator into `results.json`; deriving and rendering the ordered
percentile breakdown from that data is a documented next step — see
`bench/README.md`'s Status section — rather than a hardcoded assumption
about which fields a given telemetry backend exposes per request.)

**Pass criteria:** zero violations across the entire duration.

**Fails if:** any single violation is logged, at any tick.

---

## S8 — desktop session (CONTRACT.md B9) — NOT automated

There is no `run-bench.sh s8`. B9 requires an actual human sitting at the
desktop / playing a game — there is no synthetic substitute for real
graphics-VRAM pressure from a real compositor. Instead:

- Start `run-bench.sh s6-start` (or nothing at all) and leave the telemetry
  endpoint scraping as normal.
- Have the operator play a real game / run a real desktop session for a
  while.
- Watch (do not assert) the same signals the pressure-watcher itself reads:
  GTT-spill timeline (`gtt_used` over time, from telemetry's `history[]`)
  and any watcher shed-events logged during the session (lowest-priority
  in-cluster tenant scaled to zero while the desktop was active).

This is **operator-scheduled, human-observed, and recorded** — never
asserted pass/fail by this script. See `bench/README.md` for how to mark a
"desktop session" run in the report.

---

## Calibrate-then-assert

Any budget above without a CONTRACT.md-stated number (`EVICTION_BUDGET_S`,
`OOM_RETRY_WINDOW_S`, cold-request timing beyond the raw "~2-3s" load, ...)
is a placeholder meant to be replaced by real measurements from *your*
cluster:

```
./run-bench.sh calibrate
```

writes `$CALIBRATE_FILE` (default `bench-results/baseline.json`) with the
measured cold request-to-first-response time and the serial N-request
baseline. Nothing in this repo auto-tunes `bench.env` from that file —
review the numbers, then hand-adjust the relevant `*_BUDGET_S` values
yourself, the same way the pressure-watcher's own tunables (`hiWater`,
`gttDelta`, `graceTicks`) are documented as "deserve one real session on your
hardware to tune", not something to trust blind on someone else's card.
