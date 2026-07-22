# nixgpu bench

The nixgpu [CONTRACT.md](../CONTRACT.md) behaviors, expressed as a runnable
bench against a live cluster. Where CONTRACT.md draws the line between
"automatable" and "observed / operational" (see its last section), this
bench implements every automatable behavior as a scenario with a pass/fail
verdict, and gives the one operational behavior that needs a human (B9, the
desktop) a clearly-marked manual mode instead of pretending to automate it.

This is a **template harness**, not a fleet-specific test suite: every
endpoint, namespace, model name, and image reference is a `bench.env`
variable (see `bench.env.example`) — nothing here points at any real cluster.
You bring the cluster; this repo brings the procedure.

## What this honestly requires

This bench is not a toy that runs anywhere — it is only meaningful against:

- **A live cluster running the nixgpu substrate** — `device-tokens`,
  `priority-ladder`, and `pressure-watcher` at minimum (see the repo README
  and each module's own README for what "running" means). Several scenarios
  specifically exercise the pressure-watcher's reactive eviction, so a
  cluster without it will fail S2/S9/S11 by construction, not by bug.
- **A telemetry HTTP JSON endpoint** — you supply its URL
  (`bench.env`'s `TELEMETRY_URL`). This bench does not ship a telemetry
  server; it is the measurement *consumer*. The endpoint must return:

  ```json
  {
    "vram_used": 0,
    "vram_total": 0,
    "gtt_used": 0,
    "counters": { "page_fault": 0, "ring_timeout": 0, "gpu_reset": 0 },
    "tenants": [
      { "ns": "example", "name": "example-pod", "priority": 1000, "ready": true, "engine": "compute" }
    ],
    "history": [[1234567890, 0, 0]]
  }
  ```

  (`vram_used`/`vram_total`/`gtt_used` in bytes; `history` entries are
  `[unix_timestamp, vram_used, gtt_used]`.) The bench treats this endpoint as
  its **single measurement source** and derives eviction events from
  `tenants[]` state transitions (a tenant flipping `ready: true -> false`
  while its Deployment's replica count also drops to 0) — it does not invent
  a second, independent way to measure the same card.

- **An OpenAI-compatible door** — the one shared LLM server CONTRACT.md's
  B4 requires (e.g. the sibling
  [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) broker, or any
  server speaking the same `/v1/chat/completions` shape). You supply its
  base URL (`OPENAI_URL`) and, if it requires one, a bearer token
  (`OPENAI_API_KEY`).
- **`kubectl` access** to the cluster, with permission to create/delete
  Deployments, Pods, and ConfigMaps in one namespace (`bench.env`'s
  `NAMESPACE`) and to read Nodes/Events/other pods' status read-only. S9
  additionally needs that namespace's ServiceAccount to be able to
  `get`/`patch` ConfigMaps in the same namespace (its item pods write their
  own completion ledger) — see `scenarios.md`'s S9 section.
- **`bash`, `kubectl`, `curl`, `jq`, `envsubst`** on whatever machine runs
  `run-bench.sh` — nothing else. No Python, no extra packages. (A rendered
  *tenant's own container* may run Python — see `tenants/vram-hog.yaml` — that
  is a dependency of the tenant image, not of the driver.)

If any of the above isn't true yet, this bench will fail loudly and early
(curl/kubectl errors), not silently pass.

## Scenario table

| ID | CONTRACT.md behavior(s) | What it proves | Subcommand |
|---|---|---|---|
| S1 | B1 | Whatever fits co-resides; zero evictions | `s1` |
| S2 | B2 / B11 / B12 | Priority decides who yields, cleanly and within budget | `s2` |
| S3 | B5 / B6 | On-demand model swap; idle tenants scale to zero | `s3` |
| S4 | B14a | Same-model concurrency beats serial | `s4` |
| S5 | B14b | Small models co-reside instead of swapping | `s5` |
| S6 | B3 | The media engine is never touched by compute pressure | `s6-start` / `s6-stop` |
| S7 | B7 | The user is never left with a silent hang | `s7` |
| S9 | B13 | An external idempotent driver survives forced preemption | `s9` |
| S10 | B15 | An oversized MoE model still serves, via CPU expert offload | `s10` |
| S11 | (all of the above) | Continuous invariants hold under chaos-level concurrent load | `s11 [seed]` |
| S8 | B9 (desktop) | **Not automated** — operator-scheduled, human-observed | *(none)* |

Precise per-scenario procedure and pass/fail criteria: see
[scenarios.md](scenarios.md).

## How to run

```sh
cd bench
cp bench.env.example bench.env
$EDITOR bench.env   # fill in YOUR telemetry URL, OpenAI door, namespace, model names, images

./run-bench.sh s1          # any single scenario
./run-bench.sh all         # s6-start, s1, s2, s3, s4, s5, s7, s9, s10, s11, s6-stop, then a report
./run-bench.sh report      # (re)render the markdown report from the last results.json
```

Results land in `bench.env`'s `OUTPUT_DIR` (default `./bench-results/`):
`results.json` (machine-readable, one entry per scenario:
`{scenario, status, message, measurements, at}`), `report.md` (the human
report — a status table, the measurements, and the full invariant log), and
`invariants.log` (every sample the S7/S11 continuous checks recorded, pass or
fail, so a FAIL is always traceable).

### As an in-cluster Job

Nothing about `run-bench.sh` assumes it runs on an operator's laptop — it is
equally at home as a one-shot Kubernetes `Job` in the target cluster,
carrying a ServiceAccount with the RBAC described above, `bench.env` mounted
as a ConfigMap/Secret, and this directory baked into (or mounted onto) an
image with `bash`+`kubectl`+`curl`+`jq`+`envsubst` (the same
`bitnami/kubectl`-class image the `pressure-watcher` module already uses
covers everything except which ships in `gettext-base`/`gettext`
on most base images — check yours). Running it from any kubectl-bearing
shell — a laptop, a bastion, a CI runner with cluster access — works
identically; the script has no notion of "where it runs", only of the
cluster and endpoints named in `bench.env`.

### Fail-safe cleanup

Every bench-created object (Deployments, Pods, ConfigMaps) carries the
constant label `bench.nixgpu.corbet.ch/run=true` in `$NAMESPACE`. An `EXIT`
trap sweeps everything with that label on **any** exit path — normal
completion, Ctrl-C, or a killed job — so an aborted run never leaves synthetic
hogs holding the card. The script never touches any namespace other than the
one you configured, and every other `kubectl` call it makes (reading pod
status, Events, Node allocatable, telemetry) is read-only.

## The calibrate-then-assert model

CONTRACT.md states real numbers for some behaviors (a model load "~2-3s"
from cache) and leaves others as qualitative claims ("a short grace period",
"driven idempotently"). Every budget this bench checks against
(`COLD_WAKE_BUDGET_S`, `EVICTION_BUDGET_S`, `OOM_RETRY_WINDOW_S`, ...) is a
`bench.env` value defaulted to the contract's own number where one exists,
and to a conservative placeholder otherwise — never a number silently baked
into the script.

Run `./run-bench.sh calibrate` on your own cluster first to record real
baselines (cold request latency, serial-throughput baseline) to
`$CALIBRATE_FILE`, review them, and hand-tune the corresponding `bench.env`
budgets to match your card, your models, and your network — the same
"tune on your own hardware" discipline the `pressure-watcher` module's own
README asks of `hiWater`/`gttDelta`/`graceTicks`. This bench does not
auto-tune itself from the calibrate file; it treats calibration as
information for the human adjusting `bench.env`, not as a live baseline it
re-derives every run.

## S8 (desktop, B9) — operator-scheduled, not automated

There is no automated path for B9: it requires a human actually using the
desktop (or playing a game) so real graphics VRAM spills to GTT under real
pressure — there is no honest synthetic substitute for that. `scenarios.md`
describes the "desktop session" mode: start telemetry scraping as normal,
have the operator use the machine for a while, and record (never assert) the
GTT-spill timeline and any watcher shed-events logged during that window.
Mark any report produced this way clearly as operator-scheduled — it is an
observation, not a bench verdict.

## Status

This is the first cut of the bench harness: every scenario in the table
above is implemented and runnable end-to-end against a real cluster with the
requirements above satisfied. Not yet done, and called out honestly rather
than silently assumed away:

- **S11's ordered-by-priority-class latency percentile report** — the chaos
  loop already logs every fired generator's raw measurements into
  `results.json`; deriving and rendering the percentile-by-class breakdown
  the report should show is a follow-up over that data, not yet wired into
  `emit_report`.
- The bench has not yet been run against a real cluster end-to-end (this is
  a freshly-written harness) — treat the first real run of `all` as itself
  a shakedown of the bench, the same honest posture the rest of this repo
  takes toward its own generalized modules.
