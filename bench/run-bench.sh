#!/usr/bin/env bash
# run-bench.sh — the nixgpu CONTRACT.md bench driver.
#
# bash + kubectl + curl + jq + envsubst only. No python on the driver side
# (a rendered tenant's OWN container may run python — see tenants/vram-hog.yaml
# — that is a world away from the driver depending on it).
#
# Every subcommand below is one scenario from bench/scenarios.md, mapped 1:1
# to a CONTRACT.md behavior. Shared machinery (telemetry snapshots, tenant
# render/apply/cleanup, wait-for-ready, eviction-event watching, the
# invariant checker) lives once, near the top, and every scenario function is
# short specifically because it stands on that machinery instead of
# reimplementing it.
#
# Fail-safe by construction: every bench object is applied through
# apply_tenant()/render_hog() into $NAMESPACE and carries the constant label
# `bench.nixgpu.corbet.ch/run=true`; the EXIT trap (cleanup_bench_objects,
# below) sweeps everything with that label on ANY exit path — normal
# completion, Ctrl-C, or a killed job. INT and TERM get their own handlers
# that sweep AND exit (130/143) immediately — a signal must never leave the
# script running its next phase against a production cluster. The sweep
# never touches any other namespace, and every other kubectl call in this
# script is read-only (get/logs/events) unless explicitly noted otherwise
# (tenant apply/delete, the S9 ledger ConfigMap, and pressure-watcher's own
# scale-to-0 actions, which are not this script's doing).
#
# Deliberately no `-e`: scenario functions are expected to see kubectl/curl
# calls fail mid-flight (that IS the contention/eviction being tested) and
# must record a FAIL result and move on, not abort the whole run.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BENCH_ENV:-$SELF_DIR/bench.env}"

# ---------------------------------------------------------------------------
# bootstrap: config, dependencies, output dir
# ---------------------------------------------------------------------------

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)Z] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)Z] WARN: $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"; }
for c in kubectl curl jq envsubst awk date mktemp; do need_cmd "$c"; done

[ -f "$ENV_FILE" ] || die "config not found: $ENV_FILE (copy bench.env.example -> bench.env and fill it in, or set BENCH_ENV=/path/to/file)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${NAMESPACE:?bench.env must set NAMESPACE}"
: "${TELEMETRY_URL:?bench.env must set TELEMETRY_URL}"
: "${OPENAI_URL:?bench.env must set OPENAI_URL}"

# Thresholds introduced by the hardened checks below. bench.env.example
# documents each; the fallbacks here match the example's values.
S4_MIN_OK_COUNT="${S4_MIN_OK_COUNT:-$CONCURRENT_REQUESTS}"
S5_CORESIDENCY_FLOOR_MIB="${S5_CORESIDENCY_FLOOR_MIB:-256}"
S7_OPAQUE_BUDGET="${S7_OPAQUE_BUDGET:-0}"
S9_FORCE_HOG_MARGIN_GIB="${S9_FORCE_HOG_MARGIN_GIB:-2}"

mkdir -p "$OUTPUT_DIR"
RESULTS_JSON="$OUTPUT_DIR/results.json"
REPORT_MD="$OUTPUT_DIR/report.md"
INVARIANT_LOG="$OUTPUT_DIR/invariants.log"
# Append, never truncate: the s6-start ... scenarios ... s6-stop flow spans
# several invocations that all share this file, and a CONCURRENT invocation
# may be writing it right now — truncating here would clobber both.
touch "$INVARIANT_LOG"
[ -f "$RESULTS_JSON" ] || echo "[]" > "$RESULTS_JSON"

KCTX_ARGS=()
[ -n "${KCTX:-}" ] && KCTX_ARGS=(--context "$KCTX")
kx() { kubectl "${KCTX_ARGS[@]}" "$@"; }

# ---------------------------------------------------------------------------
# chaos self-interference guards
#
# S11 fires the very scenario functions below as concurrent background
# subshells. Without a unique per-instance suffix threaded through every
# rendered tenant name (and every per-request scratch file), two overlapping
# instances of the same generator would apply/delete each other's
# Deployments and clobber each other's outputs; without a distinct scenario
# id, their results.json rows would be indistinguishable from the dedicated
# runs. Dedicated runs keep both empty.
# ---------------------------------------------------------------------------

BENCH_SUFFIX="${BENCH_SUFFIX:-}"
SCENARIO_ID_PREFIX="${SCENARIO_ID_PREFIX:-}"
SCENARIO_ID_SUFFIX="${SCENARIO_ID_SUFFIX:-}"
scenario_id() { echo "${SCENARIO_ID_PREFIX}$1${SCENARIO_ID_SUFFIX}"; }

# ---------------------------------------------------------------------------
# cleanup — the fail-safe trap. Runs on ANY exit path.
# ---------------------------------------------------------------------------

CLEANUP_DONE=0
cleanup_bench_objects() {
  [ "$CLEANUP_DONE" = 1 ] && return
  CLEANUP_DONE=1
  log "cleanup: sweeping every object labeled bench.nixgpu.corbet.ch/run=true in namespace $NAMESPACE"
  # Deployments, Pods, ConfigMaps — everything a scenario in this script
  # creates carries this constant label; nothing else in $NAMESPACE is
  # touched, and no other namespace is ever addressed here.
  kx -n "$NAMESPACE" delete deployment,pod,configmap,job \
    -l 'bench.nixgpu.corbet.ch/run=true' --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  [ -n "${RENDER_TMP_DIR:-}" ] && rm -rf "$RENDER_TMP_DIR"
}
# EXIT handles every normal path. INT/TERM must sweep AND terminate: a bare
# shared handler would run the sweep and then RESUME the interrupted script
# (bash returns to the command after the one the signal landed on), leaving
# a supposedly-cancelled bench still mutating a production namespace. The
# `trap - EXIT` prevents a double sweep (harmless but noisy) before exiting
# with the conventional 128+SIGNAL code.
trap cleanup_bench_objects EXIT
trap 'cleanup_bench_objects; trap - EXIT; exit 130' INT
trap 'cleanup_bench_objects; trap - EXIT; exit 143' TERM

# ---------------------------------------------------------------------------
# results / report
# ---------------------------------------------------------------------------

# RESULTS_JSON is a shared read-modify-write file, and S11 (chaos) fires
# several scenario functions as background subshells that can call
# record_result concurrently — a bare read-jq-write-mv would race and silently
# drop results. Guard it with a plain mkdir-based mutex (atomic, no extra
# dependency beyond coreutils). The holder records its PID inside the lock
# so a later invocation can tell a stale lock (crashed run, PID dead) from a
# LIVE concurrent invocation — only the former is swept.
RESULTS_LOCK="$OUTPUT_DIR/.results.lock"
if [ -d "$RESULTS_LOCK" ]; then
  lock_pid="$(cat "$RESULTS_LOCK/pid" 2>/dev/null || true)"
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    log "results lock is held by live PID $lock_pid (a concurrent invocation) — leaving it alone"
  else
    log "sweeping stale results lock (owner PID '${lock_pid:-unknown}' is gone)"
    rm -rf "$RESULTS_LOCK"
  fi
fi
lock_results() {
  until mkdir "$RESULTS_LOCK" 2>/dev/null; do sleep 0.1; done
  echo "$BASHPID" > "$RESULTS_LOCK/pid"
}
unlock_results() { rm -f "$RESULTS_LOCK/pid"; rmdir "$RESULTS_LOCK" 2>/dev/null || true; }

# record_result <scenario_id> <PASS|FAIL|SKIP> <one-line message> [measurements_json]
record_result() {
  local id="$1" status="$2" msg="$3" meas="${4:-null}"
  local tmp; tmp="$(mktemp)"
  lock_results
  jq --arg id "$id" --arg status "$status" --arg msg "$msg" --argjson meas "$meas" \
     --arg at "$(date -u +%FT%TZ)" \
     '. + [{scenario:$id, status:$status, message:$msg, measurements:$meas, at:$at}]' \
     "$RESULTS_JSON" > "$tmp" && mv "$tmp" "$RESULTS_JSON"
  unlock_results
  log "RESULT $id = $status — $msg"
}

emit_report() {
  {
    echo "# nixgpu bench report"
    echo
    echo "Generated $(date -u +%FT%TZ)"
    echo
    echo "| Scenario | Status | Message |"
    echo "|---|---|---|"
    jq -r '.[] | "| \(.scenario) | \(.status) | \(.message) |"' "$RESULTS_JSON"
    echo
    echo "## Measurements"
    echo
    echo '```json'
    jq '[.[] | {scenario, measurements}]' "$RESULTS_JSON"
    echo '```'
    echo
    echo "## Invariant log"
    echo
    echo '```'
    cat "$INVARIANT_LOG"
    echo '```'
  } > "$REPORT_MD"
  log "report written: $REPORT_MD (machine results: $RESULTS_JSON)"
}

# ---------------------------------------------------------------------------
# telemetry — the bench's single measurement source (see README for the
# expected JSON shape: vram_used/vram_total/gtt_used/counters/tenants/history)
# ---------------------------------------------------------------------------

telemetry() {
  curl -sf --max-time 10 "$TELEMETRY_URL" || { warn "telemetry fetch failed"; return 1; }
}

t_vram_used()  { telemetry | jq -r '.vram_used  // empty'; }
t_vram_total() { telemetry | jq -r '.vram_total // empty'; }
t_gtt_used()   { telemetry | jq -r '.gtt_used   // empty'; }
# No default object here on purpose: a telemetry payload MISSING .counters
# must yield an empty string, which counters_equal (below) always treats as
# a mismatch — an all-zeros default would silently pass every kernel-counter
# invariant during a telemetry regression.
t_counters()   { telemetry | jq -c '.counters   // empty'; }
t_tenants()    { telemetry | jq -c '.tenants    // []'; }

# tenant_ready <ns> <name> -> "true"/"false"/"" (absent) from telemetry's tenant list
tenant_ready() {
  local ns="$1" name="$2"
  t_tenants | jq -r --arg ns "$ns" --arg name "$name" \
    '(.[] | select(.ns==$ns and .name==$name) | .ready) // empty' | head -n1
}

counters_equal() {
  # $1, $2: two counters JSON blobs. Equal <=> every field byte-identical.
  # A telemetry fetch failure (or a payload missing .counters entirely)
  # produces an EMPTY string on one side — that must never compare "equal"
  # by accident (two empty strings are trivially identical), or a telemetry
  # outage would silently pass every kernel-counter invariant instead of
  # failing loudly. Empty on either side is always a mismatch.
  [ -n "$1" ] && [ -n "$2" ] && [ "$(echo "$1" | jq -S . 2>/dev/null)" = "$(echo "$2" | jq -S . 2>/dev/null)" ]
}

# inversion_now [tenants_json] -> "true"/"false".
# A priority INVERSION is: a LOWER-priority compute tenant is ready while a
# HIGHER-priority one is not (the watcher is starving the tenant it exists
# to protect). The opposite pattern — a higher-priority tenant ready while a
# lower one is down — is the watcher WORKING (it just evicted the loser) and
# must never be flagged. `priority` is the numeric PriorityClass value from
# telemetry's tenants[]; VCN-engine tenants are orthogonal (B3) and excluded.
# NOTE: an inversion snapshot is only a legal-transient signal — a tenant
# mid-wake after an eviction looks inverted for a few seconds. Callers must
# apply a persistence window (>= EVICTION_BUDGET_S) before calling it a
# violation; see s11_chaos.
inversion_now() {
  local tsnap="${1:-}"
  [ -n "$tsnap" ] || tsnap="$(t_tenants)"
  echo "$tsnap" | jq -r --arg eng "$ENGINE_VCN_VALUE" '
    (map(select(.engine != $eng))) as $compute
    | ($compute | map(select(.ready==false))) as $down
    | ($compute | map(select(.ready==true)))  as $up
    | any($down[]; . as $d | any($up[]; .priority < $d.priority))'
}

# ---------------------------------------------------------------------------
# tenant render / apply / delete
# ---------------------------------------------------------------------------

RENDER_TMP_DIR="$(mktemp -d)"

# render_tenant <template_path> <out_name> <VAR|VAR=VALUE ...>
# Restricts envsubst to exactly the named vars, as documented at the top of
# each template — anything else with a literal '$' in the template (shell
# loops, python) is left untouched.
#
# Every variable is passed to envsubst via an explicit `env` command prefix,
# NEVER via inherited export state: script-level globals like VCN_NAME are
# not exported (bench.env's `set -a` window closed long before they were
# assigned), so relying on the environment silently renders empty strings
# into names/labels. A bare VAR argument takes the current shell value of
# that variable; VAR=VALUE overrides it for this render only.
render_tenant() {
  local template="$1" out="$RENDER_TMP_DIR/$2"; shift 2
  local varlist="" envargs=() v name val
  for v in "$@"; do
    if [[ "$v" == *=* ]]; then name="${v%%=*}"; val="${v#*=}"; else name="$v"; val="${!name-}"; fi
    varlist="$varlist \$$name"
    envargs+=("$name=$val")
  done
  env "${envargs[@]}" envsubst "$varlist" < "$template" > "$out"
  echo "$out"
}

apply_tenant() { kx -n "$NAMESPACE" apply -f "$1" >/dev/null; }
delete_tenant_by_name() { kx -n "$NAMESPACE" delete "$1" "$2" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true; }

# render_hog <out_path> <deployment_name> <size_gib> <priority_class>
# The one place vram-hog.yaml is rendered; every scenario below that needs a
# synthetic compute tenant goes through this instead of hand-rolling its own
# envsubst call. Same explicit-env rule as render_tenant.
render_hog() {
  local out="$1" name="$2" gib="$3" prio="$4"
  env NAMESPACE="$NAMESPACE" HOG_NAME="$name" HOG_IMAGE="$HOG_IMAGE" HOG_SIZE_GIB="$gib" \
      PRIORITY_CLASS_NAME="$prio" MANAGED_LABEL_KEY="$MANAGED_LABEL_KEY" \
      DEVICE_TOKEN_COMPUTE="$DEVICE_TOKEN_COMPUTE" \
    envsubst '$NAMESPACE $HOG_NAME $HOG_IMAGE $HOG_SIZE_GIB $PRIORITY_CLASS_NAME $MANAGED_LABEL_KEY $DEVICE_TOKEN_COMPUTE' \
    < "$SELF_DIR/tenants/vram-hog.yaml" > "$out"
}

# wait_ready <deployment_name> <timeout_s>
wait_ready() {
  local name="$1" timeout="$2"
  kx -n "$NAMESPACE" wait "deployment/$name" --for=condition=Available --timeout="${timeout}s" >/dev/null 2>&1
}

# wait_scaled_zero <deployment_name> <timeout_s> — polls replica count, the
# ground truth for "the watcher scaled this to 0", independent of telemetry.
wait_scaled_zero() {
  local name="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local reps
    reps="$(kx -n "$NAMESPACE" get deployment "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo -1)"
    [ "$reps" = "0" ] && { echo "$waited"; return 0; }
    sleep "$TICK_S"; waited=$((waited + TICK_S))
  done
  return 1
}

# restart_count <app_label> -> a number, or "none" (query succeeded but no
# pod / no containerStatus exists yet), or "-1" (the query itself failed).
# "none" and "0" are deliberately DIFFERENT answers: a deployment whose pod
# vanished has not "never restarted" — treating absent as 0 would let a
# deleted transcoder pass S6's zero-restart check.
restart_count() {
  local out
  out="$(kx -n "$NAMESPACE" get pods -l "app=$1" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)" || { echo -1; return; }
  if [ -n "$out" ]; then echo "$out"; else echo none; fi
}

# ---------------------------------------------------------------------------
# S7 helper — probe a waking app: never left unanswered past PROBE_GRACE_S,
# and every answer is either the real service or the waiting page marker.
# ---------------------------------------------------------------------------

# probe_once -> "OK:<code>" | "MARKER:<code>" | "UNANSWERED:rc=<curl_rc>"
# ANY non-zero curl exit is "unanswered" — refused (7) and timeout (28) are
# just the two most common; DNS failure (6), TLS failure (35), reset mid-
# body (56), ... all mean the user got no page, which is exactly what B7
# forbids. Enumerating only 7/28 let every other failure mode fall through
# to the OK/MARKER classifier with a bogus code of 000.
probe_once() {
  local body code curl_rc
  body="$(mktemp)"
  code="$(curl -s -o "$body" -w '%{http_code}' --max-time 3 "$PROBE_URL" 2>/dev/null)"
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then rm -f "$body"; echo "UNANSWERED:rc=$curl_rc"; return; fi
  if grep -qF "$WAITING_PAGE_MARKER" "$body" 2>/dev/null; then
    echo "MARKER:$code"
  else
    echo "OK:$code"
  fi
  rm -f "$body"
}

# probe_watch_until_ready <max_wait_s> -> 0 if the app answered OK:2xx within
# the budget and no unanswered streak exceeded PROBE_GRACE_S, else 1.
#
# - The unanswered streak is measured by WALL-CLOCK delta from the first
#   unanswered sample (each probe itself takes up to 3s — counting ticks
#   * PROBE_INTERVAL_S undercounts real user-facing dead air badly).
# - An ANSWERED non-2xx without the waiting-page marker is an OPAQUE ERROR
#   (a raw 502/503 leaking through the front — exactly what B7's "one honest
#   waiting page" exists to prevent). Each one increments S7_OPAQUE_COUNT;
#   the caller gates PASS on S7_OPAQUE_BUDGET.
# Appends every sample to INVARIANT_LOG.
S7_OPAQUE_COUNT=0
probe_watch_until_ready() {
  local max_wait="$1" start now unanswered_since=0 last="" streak=0
  S7_OPAQUE_COUNT=0
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    [ "$((now - start))" -lt "$max_wait" ] || break
    last="$(probe_once)"
    echo "$(date -u +%H:%M:%S)Z S7 probe: $last" >> "$INVARIANT_LOG"
    case "$last" in
      UNANSWERED:*)
        [ "$unanswered_since" -eq 0 ] && unanswered_since="$now"
        streak=$(( $(date +%s) - unanswered_since ))
        if [ "$streak" -gt "$PROBE_GRACE_S" ]; then
          warn "S7: probe unanswered for ${streak}s wall-clock > PROBE_GRACE_S=${PROBE_GRACE_S}s"
          return 1
        fi
        ;;
      OK:2*)
        return 0 # the real service answered — waking succeeded
        ;;
      MARKER:*)
        unanswered_since=0 # the honest waiting page — resets the streak
        ;;
      OK:*)
        # Answered, but neither 2xx nor the waiting page: opaque error.
        unanswered_since=0
        S7_OPAQUE_COUNT=$((S7_OPAQUE_COUNT + 1))
        echo "$(date -u +%H:%M:%S)Z S7 OPAQUE-ERROR: answered '$last' without the waiting-page marker (count=$S7_OPAQUE_COUNT)" >> "$INVARIANT_LOG"
        ;;
    esac
    sleep "$PROBE_INTERVAL_S"
  done
  warn "S7: app never became Ready (last=$last) within ${max_wait}s"
  return 1
}

# ---------------------------------------------------------------------------
# S6 helper — VCN transcoder health (B3): zero restarts, progress not stalled
# ---------------------------------------------------------------------------

VCN_NAME="bench-vcn-transcoder"
# Staleness state persisted BETWEEN invocations: s6-start, each scenario, and
# s6-stop are separate processes, so in-memory globals alone would make the
# final s6-stop staleness check start blind every time (it would see "a new
# line" no matter how long the log had actually been frozen). Two lines:
# the last distinct progress line, and the epoch second it was first seen.
VCN_STATE_FILE="$OUTPUT_DIR/vcn-progress.state"

vcn_start() {
  log "S6: starting persistent VCN transcoder ($VCN_NAME) — runs across every other scenario"
  rm -f "$VCN_STATE_FILE"
  local f
  f="$(render_tenant "$SELF_DIR/tenants/vcn-transcoder.yaml" vcn.yaml \
    NAMESPACE VCN_NAME VCN_IMAGE VAAPI_RENDER_NODE DEVICE_TOKEN_VCN ENGINE_LABEL_KEY ENGINE_VCN_VALUE MANAGED_LABEL_KEY)"
  if ! apply_tenant "$f"; then
    record_result "S6" FAIL "transcoder apply failed (rendered manifest rejected) — S6 and every VCN invariant that depends on it is void this run"
    return 1
  fi
  wait_ready "$VCN_NAME" "$COLD_WAKE_BUDGET_S" || warn "S6: transcoder not Available within COLD_WAKE_BUDGET_S — health checks below will likely fail too"
}

# In-memory mirror of VCN_STATE_FILE for repeated calls within one process
# (the S11 tick loop). Loaded from the state file on first use.
VCN_LAST_LINE=""
VCN_LAST_LINE_AT=0

# vcn_health_check -> 0 if healthy: a pod exists, restarts==0, AND the most
# recent progress line has changed within VCN_STALL_THRESHOLD_S of the last
# time it changed (a log tail that never advances, even with restarts==0,
# means the loop genuinely stalled — a hung ffmpeg process still "running"
# but not progressing would otherwise pass a naive "any line at all" check).
vcn_health_check() {
  local rcnt log_tail last_line now
  if [ -z "$VCN_LAST_LINE" ] && [ -f "$VCN_STATE_FILE" ]; then
    VCN_LAST_LINE="$(awk 'NR==1' "$VCN_STATE_FILE")"
    VCN_LAST_LINE_AT="$(awk 'NR==2' "$VCN_STATE_FILE")"
    case "$VCN_LAST_LINE_AT" in ''|*[!0-9]*) VCN_LAST_LINE_AT=0 ;; esac
  fi
  rcnt="$(restart_count "$VCN_NAME")"
  case "$rcnt" in
    -1|none)
      echo "$(date -u +%H:%M:%S)Z S6 VIOLATION: no transcoder pod found (restart_count=$rcnt) — the transcoder is supposed to outlive everything (B3)" >> "$INVARIANT_LOG"
      return 1
      ;;
    0) : ;;
    *)
      echo "$(date -u +%H:%M:%S)Z S6 VIOLATION: vcn-transcoder restartCount=$rcnt (expected 0)" >> "$INVARIANT_LOG"
      return 1
      ;;
  esac
  log_tail="$(kx -n "$NAMESPACE" logs "deployment/$VCN_NAME" --tail=20 2>/dev/null || true)"
  last_line="$(echo "$log_tail" | grep -E 'TRANSCODE LOOP|frame=' | tail -n1)"
  if [ -z "$last_line" ]; then
    echo "$(date -u +%H:%M:%S)Z S6 VIOLATION: no progress line seen at all" >> "$INVARIANT_LOG"
    return 1
  fi
  now="$(date +%s)"
  if [ "$last_line" != "$VCN_LAST_LINE" ]; then
    VCN_LAST_LINE="$last_line"; VCN_LAST_LINE_AT="$now"
    printf '%s\n%s\n' "$VCN_LAST_LINE" "$VCN_LAST_LINE_AT" > "$VCN_STATE_FILE"
  elif [ "$VCN_LAST_LINE_AT" -gt 0 ] && [ "$((now - VCN_LAST_LINE_AT))" -gt "$VCN_STALL_THRESHOLD_S" ]; then
    echo "$(date -u +%H:%M:%S)Z S6 VIOLATION: progress line unchanged for $((now - VCN_LAST_LINE_AT))s > VCN_STALL_THRESHOLD_S=${VCN_STALL_THRESHOLD_S}s: '$last_line'" >> "$INVARIANT_LOG"
    return 1
  fi
  echo "$(date -u +%H:%M:%S)Z S6 ok: restarts=0 last='$last_line'" >> "$INVARIANT_LOG"
  return 0
}

vcn_stop() {
  log "S6: stopping persistent VCN transcoder"
  delete_tenant_by_name deployment "$VCN_NAME"
}

vcn_present() { kx -n "$NAMESPACE" get deployment "$VCN_NAME" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# OpenAI-compatible door helpers (S3/S4/S5/S10)
# ---------------------------------------------------------------------------

auth_header=(-H "Content-Type: application/json")
[ -n "${OPENAI_API_KEY:-}" ] && auth_header+=(-H "Authorization: Bearer $OPENAI_API_KEY")

# completion_request <model> -> prints "<wall_seconds> <http_code>"; body discarded to /dev/null
completion_request() {
  local model="$1" start end body
  body="$(jq -n --arg m "$model" --arg p "$COMPLETION_PROMPT" --argjson mt "${COMPLETION_MAX_TOKENS:-64}" \
    '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$mt}')"
  start="$(date +%s.%N)"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "${auth_header[@]}" \
    -X POST "$OPENAI_URL/chat/completions" -d "$body")"
  end="$(date +%s.%N)"
  awk -v s="$start" -v e="$end" -v c="$code" 'BEGIN{printf "%.3f %s\n", (e-s), c}'
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

# S1 (B1) — co-residence: three tenants at mixed priorities that fit together.
s1_coresidence() {
  local id; id="$(scenario_id S1)"
  local c0; c0="$(t_counters)"
  local names=("bench-s1-a$BENCH_SUFFIX" "bench-s1-b$BENCH_SUFFIX" "bench-s1-c$BENCH_SUFFIX")
  local sizes=("$S1_TENANT_A_GIB" "$S1_TENANT_B_GIB" "$S1_TENANT_C_GIB")
  local prios=("$S1_TENANT_A_PRIORITY" "$S1_TENANT_B_PRIORITY" "$S1_TENANT_C_PRIORITY")
  local i out
  for i in 0 1 2; do
    out="$RENDER_TMP_DIR/s1$BENCH_SUFFIX-$i.yaml"
    render_hog "$out" "${names[$i]}" "${sizes[$i]}" "${prios[$i]}"
    apply_tenant "$out"
  done

  local ok=1 name
  for name in "${names[@]}"; do
    wait_ready "$name" "$COLD_WAKE_BUDGET_S" || { ok=0; warn "S1: $name never became Ready"; }
  done

  local c1; c1="$(t_counters)"
  local evictions=0
  for name in "${names[@]}"; do
    local reps
    reps="$(kx -n "$NAMESPACE" get deployment "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    [ "$reps" = "0" ] && evictions=$((evictions + 1))
  done

  for name in "${names[@]}"; do delete_tenant_by_name deployment "$name"; done

  if [ "$ok" = 1 ] && [ "$evictions" -eq 0 ] && counters_equal "$c0" "$c1"; then
    record_result "$id" PASS "all 3 tenants Ready, 0 evictions, kernel counters unchanged" \
      "$(jq -n --argjson before "$c0" --argjson after "$c1" '{counters_before:$before, counters_after:$after}')"
  else
    record_result "$id" FAIL "ready=$ok evictions=$evictions counters_before=$c0 counters_after=$c1"
  fi
}

# S2 (B2/B11/B12) — contention: fill the card, then demand an interactive
# tenant that cannot fit; the hog must yield within EVICTION_BUDGET_S, the
# interactive tenant must become Ready, counters stay 0, and no
# CrashLoopBackOff longer than OOM_RETRY_WINDOW_S.
s2_contention() {
  local id; id="$(scenario_id S2)"
  local hog="bench-s2-hog$BENCH_SUFFIX" inter="bench-s2-interactive$BENCH_SUFFIX"
  local c0; c0="$(t_counters)"

  local hog_f="$RENDER_TMP_DIR/s2-hog$BENCH_SUFFIX.yaml" int_f="$RENDER_TMP_DIR/s2-int$BENCH_SUFFIX.yaml"
  render_hog "$hog_f" "$hog" "$S2_HOG_GIB" "$PRIORITY_BESTEFFORT"
  apply_tenant "$hog_f"
  wait_ready "$hog" "$COLD_WAKE_BUDGET_S" || warn "S2: hog never became Ready — continuing anyway"

  # The full-card level: the interactive tenant's wake clock starts when
  # vram_used drops below this (the hog's VRAM actually landing free), not
  # at apply time — replicas hitting 0 precedes the allocator giving the
  # memory back, and B11's wake budget is about the latter.
  local v_full; v_full="$(t_vram_used)"

  render_hog "$int_f" "$inter" "$S2_INTERACTIVE_GIB" "$PRIORITY_INTERACTIVE"
  apply_tenant "$int_f"

  # B11: yield is time-bounded — the hog's Deployment must be scaled to 0 by
  # the watcher within EVICTION_BUDGET_S.
  local hog_yielded=0
  wait_scaled_zero "$hog" "$EVICTION_BUDGET_S" >/dev/null && hog_yielded=1

  # Start the interactive wake clock only once telemetry shows vram_used
  # actually dropping below the full-card level (bounded by
  # EVICTION_BUDGET_S so a stuck allocator can't hang the scenario).
  local vram_dropped=0 dwaited=0
  if [ -n "$v_full" ]; then
    while [ "$dwaited" -lt "$EVICTION_BUDGET_S" ]; do
      local v_now; v_now="$(t_vram_used)"
      if [ -n "$v_now" ] && awk -v n="$v_now" -v f="$v_full" 'BEGIN{exit !(n<f)}'; then
        vram_dropped=1; break
      fi
      sleep "$TICK_S"; dwaited=$((dwaited + TICK_S))
    done
  fi
  [ "$vram_dropped" = 1 ] || warn "S2: telemetry vram_used never dropped below the full-card level ($v_full) within EVICTION_BUDGET_S — starting the wake clock anyway"

  local interactive_ready=0
  wait_ready "$inter" "$COLD_WAKE_BUDGET_S" && interactive_ready=1

  # One-shot inversion check at the end of the eviction window: with the
  # yield complete and the wake budget spent, no lower-priority tenant may
  # still be ready while a higher-priority one is not. (During the window
  # itself that pattern is the legal transient; here it has run out of
  # excuses.)
  local inversion_free=1
  [ "$(inversion_now)" = "true" ] && inversion_free=0

  # B11: a fast step finishes; a slow one dies. Either way, no pod may sit in
  # CrashLoopBackOff longer than OOM_RETRY_WINDOW_S.
  local crashloop_ok=1 waited=0
  while [ "$waited" -lt "$OOM_RETRY_WINDOW_S" ]; do
    local reason
    reason="$(kx -n "$NAMESPACE" get pods -l "app=$inter" \
      -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    [ "$reason" = "CrashLoopBackOff" ] || break
    sleep "$TICK_S"; waited=$((waited + TICK_S))
  done
  [ "$waited" -ge "$OOM_RETRY_WINDOW_S" ] && crashloop_ok=0

  local c1; c1="$(t_counters)"

  delete_tenant_by_name deployment "$hog"
  delete_tenant_by_name deployment "$inter"

  local meas
  meas="$(jq -n --argjson before "$c0" --argjson after "$c1" \
    --argjson vd "$vram_dropped" --argjson inv_free "$inversion_free" \
    '{counters_before:$before, counters_after:$after, vram_dropped:($vd==1), inversion_free_at_end:($inv_free==1)}' 2>/dev/null \
    || jq -n --argjson vd "$vram_dropped" --argjson inv_free "$inversion_free" \
      '{counters:"unavailable", vram_dropped:($vd==1), inversion_free_at_end:($inv_free==1)}')"
  if [ "$hog_yielded" = 1 ] && [ "$interactive_ready" = 1 ] && counters_equal "$c0" "$c1" \
     && [ "$crashloop_ok" = 1 ] && [ "$inversion_free" = 1 ]; then
    record_result "$id" PASS "hog scaled to 0 within budget, interactive Ready after VRAM landed free, no inversion at window end, counters unchanged, no long CrashLoopBackOff" "$meas"
  else
    record_result "$id" FAIL "hog_yielded=$hog_yielded interactive_ready=$interactive_ready crashloop_ok=$crashloop_ok inversion_free=$inversion_free vram_dropped=$vram_dropped counters_before=$c0 counters_after=$c1" "$meas"
  fi
}

# S3 (B5/B6) — swap + TTL: request a non-resident model, measure
# request-to-first-response, then idle past TTL and assert VRAM drops.
s3_swap_ttl() {
  local id; id="$(scenario_id S3)"
  local before resident after result rc rt
  before="$(t_vram_used)" # pre-request context only — the model is NOT resident yet
  result="$(completion_request "$MODEL_COLD")"
  rt="$(echo "$result" | awk '{print $1}')"
  rc="$(echo "$result" | awk '{print $2}')"

  if [ "$rc" != "200" ]; then
    record_result "$id" FAIL "cold request to $MODEL_COLD returned HTTP $rc"
    return
  fi

  # The TTL baseline is the RESIDENT level — snapshotted after the
  # completion returned, i.e. with the model loaded. Comparing the post-TTL
  # level against the PRE-request snapshot would demand the impossible
  # (dropping below a level measured before the model ever occupied VRAM)
  # whenever anything else was resident at start.
  resident="$(t_vram_used)"
  log "S3: request-to-first-response was ${rt}s (informational — cold swap may include an unload+load cycle per B5, so this is recorded, not gated on COLD_WAKE_BUDGET_S); resident vram_used=$resident (pre-request $before)"
  log "S3: sleeping IDLE_TTL_S=${IDLE_TTL_S}s for the model to go idle"
  sleep "$IDLE_TTL_S"
  after="$(t_vram_used)"

  local meas
  meas="$(jq -n --arg rt "$rt" --arg before "$before" --arg resident "$resident" --arg after "$after" \
    '{request_to_first_response_s:($rt|tonumber), vram_used_pre_request:($before|tonumber?), vram_used_resident:($resident|tonumber?), vram_used_after_ttl:($after|tonumber?)}')"

  if [ -n "$resident" ] && [ -n "$after" ] && awk -v a="$after" -v r="$resident" 'BEGIN{exit !(a<r)}'; then
    record_result "$id" PASS "served in ${rt}s, VRAM dropped after idle TTL (resident $resident -> $after)" "$meas"
  else
    record_result "$id" FAIL "served in ${rt}s, but VRAM did NOT drop below the resident level after IDLE_TTL_S (resident $resident -> $after)" "$meas"
  fi
}

# S4/S5 (B14) — concurrency, two ways.
s4_concurrency() {
  local id; id="$(scenario_id S4)"
  # Baseline: N requests run one after another. Every HTTP code is captured;
  # a throughput "comparison" between two piles of instant 500s would
  # measure nothing but error-path speed.
  local serial_start serial_end i out code serial_ok=0
  serial_start="$(date +%s.%N)"
  for i in $(seq 1 "$CONCURRENT_REQUESTS"); do
    out="$(completion_request "$MODEL_CONCURRENCY")"
    code="$(echo "$out" | awk '{print $2}')"
    [ "$code" = "200" ] && serial_ok=$((serial_ok + 1))
  done
  serial_end="$(date +%s.%N)"
  local serial_s; serial_s="$(awk -v s="$serial_start" -v e="$serial_end" 'BEGIN{print e-s}')"

  # Concurrent: N requests fired in parallel.
  local conc_start conc_end pids=() conc_ok=0
  conc_start="$(date +%s.%N)"
  for i in $(seq 1 "$CONCURRENT_REQUESTS"); do
    completion_request "$MODEL_CONCURRENCY" > "$RENDER_TMP_DIR/s4$BENCH_SUFFIX-$i.out" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  conc_end="$(date +%s.%N)"
  local conc_s; conc_s="$(awk -v s="$conc_start" -v e="$conc_end" 'BEGIN{print e-s}')"
  for i in $(seq 1 "$CONCURRENT_REQUESTS"); do
    code="$(awk '{print $2}' "$RENDER_TMP_DIR/s4$BENCH_SUFFIX-$i.out" 2>/dev/null)"
    [ "$code" = "200" ] && conc_ok=$((conc_ok + 1))
  done

  local serial_tput conc_tput
  serial_tput="$(awk -v n="$CONCURRENT_REQUESTS" -v t="$serial_s" 'BEGIN{print (t>0)? n/t : 0}')"
  conc_tput="$(awk -v n="$CONCURRENT_REQUESTS" -v t="$conc_s" 'BEGIN{print (t>0)? n/t : 0}')"

  local meas
  meas="$(jq -n --arg serial "$serial_tput" --arg conc "$conc_tput" --arg n "$CONCURRENT_REQUESTS" \
    --arg sok "$serial_ok" --arg cok "$conc_ok" --arg min "$S4_MIN_OK_COUNT" \
    '{n:($n|tonumber), serial_req_per_s:($serial|tonumber), concurrent_req_per_s:($conc|tonumber),
      serial_http_200:($sok|tonumber), concurrent_http_200:($cok|tonumber), min_ok_required:($min|tonumber)}')"

  # HTTP gate FIRST: both phases must produce >= S4_MIN_OK_COUNT (default:
  # all) 200s before the throughput numbers mean anything.
  if [ "$serial_ok" -lt "$S4_MIN_OK_COUNT" ] || [ "$conc_ok" -lt "$S4_MIN_OK_COUNT" ]; then
    record_result "$id" FAIL "HTTP gate: serial ${serial_ok}/${CONCURRENT_REQUESTS} and concurrent ${conc_ok}/${CONCURRENT_REQUESTS} requests returned 200 (need >= $S4_MIN_OK_COUNT in BOTH phases) — throughput comparison void" "$meas"
    return
  fi

  if awk -v c="$conc_tput" -v s="$serial_tput" 'BEGIN{exit !(c>s)}'; then
    record_result "$id" PASS "concurrent throughput ${conc_tput} req/s > serial baseline ${serial_tput} req/s (all requests gated 200)" "$meas"
  else
    record_result "$id" FAIL "concurrent throughput ${conc_tput} req/s did NOT exceed serial baseline ${serial_tput} req/s" "$meas"
  fi
}

s5_multimodel() {
  local id; id="$(scenario_id S5)"
  # Telemetry is POD-level, never model-level: two models served by the same
  # broker pod are ONE tenants[] entry, so "both names ready in tenants[]"
  # can never be observed. Co-residency is inferred from the vram_used
  # plateau instead: with A resident, loading B must RAISE vram_used by at
  # least S5_CORESIDENCY_FLOOR_MIB above A's plateau (a swap-in-place keeps
  # the plateau roughly flat), and BOTH models must still answer 200 AFTER
  # that plateau check.
  local base resident_a resident_b
  base="$(t_vram_used)"
  local r_a code_a r_b code_b
  r_a="$(completion_request "$MODEL_SMALL_A")"; code_a="$(echo "$r_a" | awk '{print $2}')"
  resident_a="$(t_vram_used)" # A's plateau
  r_b="$(completion_request "$MODEL_SMALL_B")"; code_b="$(echo "$r_b" | awk '{print $2}')"
  resident_b="$(t_vram_used)" # must sit >= floor above A's plateau

  local floor_bytes plateau_ok=0
  floor_bytes="$(awk -v m="$S5_CORESIDENCY_FLOOR_MIB" 'BEGIN{printf "%d", m*1048576}')"
  if [ -n "$resident_a" ] && [ -n "$resident_b" ] && \
     awk -v a="$resident_a" -v b="$resident_b" -v f="$floor_bytes" 'BEGIN{exit !(b >= a + f)}'; then
    plateau_ok=1
  fi

  # Post-plateau proof both are still alive: if loading B evicted A, A's
  # re-ask here forces a visible reload (and a swap-thrashing generator will
  # show it in latency/failures across a chaos run).
  local r_a2 code_a2 r_b2 code_b2
  r_a2="$(completion_request "$MODEL_SMALL_A")"; code_a2="$(echo "$r_a2" | awk '{print $2}')"
  r_b2="$(completion_request "$MODEL_SMALL_B")"; code_b2="$(echo "$r_b2" | awk '{print $2}')"

  local meas
  meas="$(jq -n --arg ca "$code_a" --arg cb "$code_b" --arg ca2 "$code_a2" --arg cb2 "$code_b2" \
    --arg base "$base" --arg ra "$resident_a" --arg rb "$resident_b" --arg fl "$floor_bytes" \
    '{http_a:$ca, http_b:$cb, http_a_after_plateau:$ca2, http_b_after_plateau:$cb2,
      vram_used_base:($base|tonumber?), vram_used_after_a:($ra|tonumber?), vram_used_after_b:($rb|tonumber?),
      coresidency_floor_bytes:($fl|tonumber)}')"

  if [ "$code_a" = "200" ] && [ "$code_b" = "200" ] && [ "$plateau_ok" = 1 ] \
     && [ "$code_a2" = "200" ] && [ "$code_b2" = "200" ]; then
    record_result "$id" PASS "vram plateau rose >= ${S5_CORESIDENCY_FLOOR_MIB} MiB when B loaded on top of A ($resident_a -> $resident_b), and both models still answer 200" "$meas"
  else
    record_result "$id" FAIL "code_a=$code_a code_b=$code_b plateau_ok=$plateau_ok (after_a=$resident_a after_b=$resident_b floor=${floor_bytes}B) code_a_after=$code_a2 code_b_after=$code_b2" "$meas"
  fi
}

# S9 (B13) — idempotent batch driver: submit M small jobs (bare pods, no
# k8s-level auto-retry), force a mid-run preemption via the interactive hog,
# and confirm all M complete exactly once via an external ledger ConfigMap
# this script itself maintains — this IS "driven idempotently from outside",
# not the k8s Job controller's own retry logic.
s9_batch_idempotent() {
  local id="S9"
  local ledger="bench-s9-ledger"
  kx -n "$NAMESPACE" delete configmap "$ledger" --ignore-not-found=true >/dev/null 2>&1 || true
  kx -n "$NAMESPACE" create configmap "$ledger" >/dev/null
  kx -n "$NAMESPACE" label configmap "$ledger" 'bench.nixgpu.corbet.ch/run=true' --overwrite >/dev/null

  # RBAC note: the item pods below patch this ConfigMap themselves (kubectl
  # inside the item container, hence BATCH_ITEM_IMAGE must ship a kubectl
  # binary — see bench.env.example) — that requires a role bound to the bench
  # namespace's default ServiceAccount granting get/patch on configmaps. See
  # bench/README.md's requirements section; this script does not grant RBAC
  # itself (that is cluster setup, not the bench).
  submit_batch_item() {
    # Two statements on purpose: bash >= 5.3 expands every word of a single
    # `local` statement before the first assignment lands, so referencing
    # $idx in the same statement dies with `set -u`.
    local idx="$1"
    local name="bench-s9-item-$idx"
    kx -n "$NAMESPACE" delete pod "$name" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    cat <<EOF | kx -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app: $name
    bench.nixgpu.corbet.ch/run: "true"
    bench.nixgpu.corbet.ch/kind: batch-item
    $MANAGED_LABEL_KEY: "true"
spec:
  priorityClassName: $PRIORITY_BESTEFFORT
  restartPolicy: Never
  containers:
    - name: item
      image: $BATCH_ITEM_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          set -e
          if kubectl -n $NAMESPACE get configmap $ledger -o jsonpath="{.data.item-$idx}" 2>/dev/null | grep -q done; then
            echo "item $idx already done — idempotent no-op"; exit 0
          fi
          sleep $BATCH_ITEM_WORK_SECONDS
          kubectl -n $NAMESPACE patch configmap $ledger --type merge -p "{\"data\":{\"item-$idx\":\"done\"}}"
          echo "item $idx recorded done"
EOF
  }

  local i
  for i in $(seq 1 "$BATCH_JOB_COUNT"); do submit_batch_item "$i"; done

  # Force a mid-run preemption: start the interactive-priority hog partway
  # through so the pressure-watcher's fallback (delete the lowest-priority
  # managed pod when it has no Deployment owner — exactly these bare item
  # pods) kills at least one in-flight item.
  #
  # The hog is sized from LIVE telemetry — (free VRAM + margin) GiB — so it
  # genuinely cannot fit and starvation actually happens. A fixed size would
  # silently under-pressure a card that happens to be mostly empty at this
  # point in the suite (free 15 GiB, fixed 15 GiB hog -> it just fits -> no
  # preemption -> the scenario "passes" without testing B13 at all).
  local vt vu force_gib
  vt="$(t_vram_total)"; vu="$(t_vram_used)"
  if [ -n "$vt" ] && [ -n "$vu" ]; then
    force_gib="$(awk -v t="$vt" -v u="$vu" -v m="$S9_FORCE_HOG_MARGIN_GIB" \
      'BEGIN{g=(t-u)/1073741824 + m; if (g < 1) g = 1; printf "%.1f", g}')"
    log "S9: sizing force-hog from telemetry: total=$vt used=$vu -> ${force_gib} GiB (margin ${S9_FORCE_HOG_MARGIN_GIB} GiB)"
  else
    force_gib="$S2_HOG_GIB"
    warn "S9: telemetry unavailable — falling back to S2_HOG_GIB=$S2_HOG_GIB for the force-hog (preemption not guaranteed)"
  fi

  sleep "$((BATCH_ITEM_WORK_SECONDS / 2))"
  local force_f="$RENDER_TMP_DIR/s9-force.yaml"
  render_hog "$force_f" bench-s9-force-interactive "$force_gib" "$PRIORITY_INTERACTIVE"
  apply_tenant "$force_f"

  # Driver loop: resubmit anything gone-but-not-done, until the ledger has
  # all M entries or a generous overall timeout elapses. Every resubmission
  # is counted: it is the OBSERVED preemption evidence the verdict needs.
  local deadline=$((BATCH_JOB_COUNT * BATCH_ITEM_WORK_SECONDS * 3 + EVICTION_BUDGET_S))
  local waited=0 done_count=0 resubmissions=0
  while [ "$waited" -lt "$deadline" ]; do
    done_count="$(kx -n "$NAMESPACE" get configmap "$ledger" -o json 2>/dev/null | jq '(.data // {}) | length')"
    [ "$done_count" -ge "$BATCH_JOB_COUNT" ] && break
    for i in $(seq 1 "$BATCH_JOB_COUNT"); do
      local has_entry phase
      has_entry="$(kx -n "$NAMESPACE" get configmap "$ledger" -o jsonpath="{.data.item-$i}" 2>/dev/null || true)"
      [ "$has_entry" = "done" ] && continue
      phase="$(kx -n "$NAMESPACE" get pod "bench-s9-item-$i" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Absent")"
      if [ "$phase" = "Absent" ] || [ "$phase" = "Failed" ]; then
        log "S9: item $i missing/failed (phase=$phase) and not yet done — resubmitting"
        submit_batch_item "$i"
        resubmissions=$((resubmissions + 1))
      fi
    done
    sleep "$TICK_S"; waited=$((waited + TICK_S))
  done

  delete_tenant_by_name deployment bench-s9-force-interactive
  for i in $(seq 1 "$BATCH_JOB_COUNT"); do kx -n "$NAMESPACE" delete pod "bench-s9-item-$i" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true; done
  kx -n "$NAMESPACE" delete configmap "$ledger" --ignore-not-found=true >/dev/null 2>&1 || true

  local meas
  meas="$(jq -n --argjson done "$done_count" --argjson m "$BATCH_JOB_COUNT" \
    --argjson resub "$resubmissions" --arg fg "$force_gib" \
    '{done:$done, expected:$m, resubmissions:$resub, force_hog_gib:($fg|tonumber)}')"
  if [ "$done_count" -ge "$BATCH_JOB_COUNT" ] && [ "$resubmissions" -ge 1 ]; then
    record_result "$id" PASS "all $BATCH_JOB_COUNT batch items completed exactly once, surviving $resubmissions observed resubmission(s) after forced preemption" "$meas"
  elif [ "$done_count" -ge "$BATCH_JOB_COUNT" ]; then
    record_result "$id" SKIP "preemption never occurred — ledger complete but 0 resubmissions were observed, so B13 was not exercised (raise S9_FORCE_HOG_MARGIN_GIB or BATCH_ITEM_WORK_SECONDS)" "$meas"
  else
    record_result "$id" FAIL "only $done_count/$BATCH_JOB_COUNT items completed within the deadline ($resubmissions resubmissions)" "$meas"
  fi
}

# S10 (B15) — oversized MoE model: must serve (CPU expert offload) without
# kernel events.
s10_moe() {
  if [ -z "${MODEL_MOE:-}" ]; then
    record_result S10 SKIP "MODEL_MOE unset — no MoE alias configured (see bench.env)"
    return 0
  fi
  local id="S10"
  local c0; c0="$(t_counters)"
  local result rc rt
  result="$(completion_request "$MODEL_MOE")"
  rt="$(echo "$result" | awk '{print $1}')"; rc="$(echo "$result" | awk '{print $2}')"
  local c1; c1="$(t_counters)"

  local meas; meas="$(jq -n --arg rt "$rt" --argjson before "${c0:-null}" --argjson after "${c1:-null}" \
    '{response_s:($rt|tonumber), counters_before:$before, counters_after:$after}')"

  if [ "$rc" = "200" ] && counters_equal "$c0" "$c1"; then
    record_result "$id" PASS "MoE model $MODEL_MOE served in ${rt}s with zero kernel events" "$meas"
  else
    record_result "$id" FAIL "http=$rc counters_before=$c0 counters_after=$c1" "$meas"
  fi
}

# S7 (B7) — standalone: force the fronted app to zero, then probe
# continuously while it wakes.
s7_wake_probe() {
  local id; id="$(scenario_id S7)"
  local ok=1
  probe_watch_until_ready "$((COLD_WAKE_BUDGET_S * 6))" || ok=0
  local meas
  meas="$(jq -n --argjson o "$S7_OPAQUE_COUNT" --argjson b "$S7_OPAQUE_BUDGET" \
    '{opaque_errors:$o, opaque_error_budget:$b}')"
  if [ "$ok" = 1 ] && [ "$S7_OPAQUE_COUNT" -le "$S7_OPAQUE_BUDGET" ]; then
    record_result "$id" PASS "every probe answered with the service or the waiting-page marker; no unanswered wall-clock streak past ${PROBE_GRACE_S}s; opaque errors $S7_OPAQUE_COUNT <= budget $S7_OPAQUE_BUDGET" "$meas"
  else
    record_result "$id" FAIL "unanswered streak exceeded PROBE_GRACE_S, the app never became Ready, or opaque errors $S7_OPAQUE_COUNT > budget $S7_OPAQUE_BUDGET — see $INVARIANT_LOG" "$meas"
  fi
}

# S11 — chaos: seeded-random interleaving of S1-S7 event generators for
# S11_CHAOS_DURATION_S, with continuous invariants checked every tick.
s11_chaos() {
  local id="S11"
  local seed="${1:-$RANDOM}"
  log "S11: chaos seed=$seed duration=${S11_CHAOS_DURATION_S}s"
  RANDOM=$seed

  # The VCN invariant only means something if the transcoder is actually
  # there — detect its absence up front instead of logging one identical
  # "no pod found" violation per tick against a tenant that was never
  # started (operator forgot s6-start, or vcn_start hard-failed).
  local vcn_ok=1
  if ! vcn_present; then
    vcn_ok=0
    warn "S11: VCN transcoder '$VCN_NAME' is not running — per-tick VCN invariant SKIPPED (run s6-start first for full B3 coverage)"
    echo "$(date -u +%H:%M:%S)Z S11 notice: transcoder absent — VCN invariant skipped for this chaos run" >> "$INVARIANT_LOG"
  fi

  local c_base; c_base="$(t_counters)"
  local violations=0
  local elapsed=0 n=0
  local inversion_since=0 inversion_counted=0
  local generators=(s1_coresidence s2_contention s3_swap_ttl s4_concurrency s5_multimodel s7_wake_probe)

  while [ "$elapsed" -lt "$S11_CHAOS_DURATION_S" ]; do
    # Fire one random scenario generator in the background per tick; chaos
    # deliberately overlaps scenarios instead of serializing them. Each
    # instance gets a unique name suffix and a distinct chaos result id
    # (S11.<scenario>#<n>) so overlapping instances of the SAME generator
    # never fight over one Deployment name, and their rows never masquerade
    # as the dedicated runs'.
    local pick=$((RANDOM % ${#generators[@]}))
    n=$((n + 1))
    log "S11: tick $elapsed -> firing ${generators[$pick]} as instance #$n"
    (
      BENCH_SUFFIX="-c$n"
      SCENARIO_ID_PREFIX="S11."
      SCENARIO_ID_SUFFIX="#$n"
      "${generators[$pick]}"
    ) &

    # --- continuous invariants (this tick) ---
    local c_now; c_now="$(t_counters)"
    if ! counters_equal "$c_base" "$c_now"; then
      echo "$(date -u +%H:%M:%S)Z S11 VIOLATION: kernel counters changed ($c_base -> $c_now)" >> "$INVARIANT_LOG"
      violations=$((violations + 1))
    fi

    # No priority inversion: a LOWER-priority compute tenant ready while a
    # HIGHER-priority one is not. One snapshot is only a suspicion — an
    # eviction/wake legitimately looks inverted while in flight (B11 grants
    # yielding a time budget), so it becomes a violation only after
    # persisting for >= EVICTION_BUDGET_S of wall-clock across ticks.
    local tsnap inversion now_e
    tsnap="$(t_tenants)"
    inversion="$(inversion_now "$tsnap")"
    now_e="$(date +%s)"
    if [ "$inversion" = "true" ]; then
      if [ "$inversion_since" -eq 0 ]; then
        inversion_since="$now_e"; inversion_counted=0
        echo "$(date -u +%H:%M:%S)Z S11 notice: priority inversion observed (legal transient while an eviction/wake is in flight; violation if it persists >= EVICTION_BUDGET_S=${EVICTION_BUDGET_S}s): $tsnap" >> "$INVARIANT_LOG"
      elif [ "$inversion_counted" -eq 0 ] && [ "$((now_e - inversion_since))" -ge "$EVICTION_BUDGET_S" ]; then
        echo "$(date -u +%H:%M:%S)Z S11 VIOLATION: priority inversion persisted $((now_e - inversion_since))s >= EVICTION_BUDGET_S=${EVICTION_BUDGET_S}s: $tsnap" >> "$INVARIANT_LOG"
        violations=$((violations + 1))
        inversion_counted=1
      fi
    else
      inversion_since=0; inversion_counted=0
    fi

    if [ "$vcn_ok" = 1 ]; then
      vcn_health_check || violations=$((violations + 1))
    fi

    local probe_r; probe_r="$(probe_once)"
    case "$probe_r" in
      UNANSWERED:*) echo "$(date -u +%H:%M:%S)Z S11: probe $probe_r (grace-tolerated, see S7 for the strict check)" >> "$INVARIANT_LOG" ;;
      *) : ;;
    esac

    sleep "$TICK_S"; elapsed=$((elapsed + TICK_S))
  done

  wait # let any still-running background generator finish before verdict

  local meas; meas="$(jq -n --argjson v "$violations" --arg seed "$seed" --argjson fired "$n" '{violations:$v, seed:$seed, generators_fired:$fired}')"
  if [ "$violations" -eq 0 ]; then
    record_result "$id" PASS "no invariant violations across ${S11_CHAOS_DURATION_S}s of chaos (seed=$seed, $n generators fired)" "$meas"
  else
    record_result "$id" FAIL "$violations invariant violation(s) — see $INVARIANT_LOG" "$meas"
  fi
}

# calibrate — record baselines (no contract number exists for these) to
# CALIBRATE_FILE; later runs may assert against it instead of a hardcoded
# budget.
calibrate() {
  log "calibrate: recording baselines to $CALIBRATE_FILE"
  local cold_result cold_code
  cold_result="$(completion_request "$MODEL_COLD")"
  cold_code="$(echo "$cold_result" | awk '{print $2}')"
  [ "$cold_code" = "200" ] || die "calibrate: cold request to $MODEL_COLD returned HTTP $cold_code — refusing to record a baseline from a failing request"

  # Same HTTP gate as S4: a serial baseline built from instant error
  # responses would poison every later assert against it.
  local serial_start serial_end i out code ok_count=0
  serial_start="$(date +%s.%N)"
  for i in $(seq 1 "$CONCURRENT_REQUESTS"); do
    out="$(completion_request "$MODEL_CONCURRENCY")"
    code="$(echo "$out" | awk '{print $2}')"
    [ "$code" = "200" ] && ok_count=$((ok_count + 1))
  done
  serial_end="$(date +%s.%N)"
  [ "$ok_count" -ge "$S4_MIN_OK_COUNT" ] || \
    die "calibrate: only $ok_count/$CONCURRENT_REQUESTS serial requests returned 200 (need >= $S4_MIN_OK_COUNT) — refusing to record a baseline from failing requests"

  jq -n \
    --arg cold_rt "$(echo "$cold_result" | awk '{print $1}')" \
    --arg serial_s "$(awk -v s="$serial_start" -v e="$serial_end" 'BEGIN{print e-s}')" \
    --arg ok "$ok_count" \
    --arg at "$(date -u +%FT%TZ)" \
    '{recorded_at:$at, cold_request_to_first_response_s:($cold_rt|tonumber), serial_baseline_s_for_n_requests:($serial_s|tonumber), serial_http_200:($ok|tonumber)}' \
    > "$CALIBRATE_FILE"
  log "calibrate: wrote $CALIBRATE_FILE"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 <subcommand> [args]

Subcommands (one per bench/scenarios.md scenario):
  s1            co-residence (B1)
  s2            contention + eviction (B2/B11/B12)
  s3            swap + TTL (B5/B6)
  s4            same-model concurrency (B14a)
  s5            multi-model co-residency (B14b)
  s6-start      start the persistent VCN transcoder (run BEFORE everything else)
  s6-stop       stop it and report its health (run AFTER everything else)
  s7            wake-probe (B7)
  s9            idempotent batch under forced preemption (B13)
  s10           oversized MoE model (B15)
  s11 [seed]    chaos: random interleaving + continuous invariants
  calibrate     record baselines to \$CALIBRATE_FILE
  all           s6-start, s1, s2, s3, s4, s5, s7, s9, s10, s11, s6-stop, then report
  report        (re)write the markdown report from the current results.json

S8 (desktop, B9) is NOT a subcommand here — it is operator-scheduled only.
See bench/scenarios.md.

Config: $ENV_FILE (override with BENCH_ENV=/path/to/file)
Output: $OUTPUT_DIR
EOF
}

cmd="${1:-}"
case "$cmd" in
  s1) s1_coresidence ;;
  s2) s2_contention ;;
  s3) s3_swap_ttl ;;
  s4) s4_concurrency ;;
  s5) s5_multimodel ;;
  s6-start) vcn_start ;;
  s6-stop)
    if ! vcn_present; then
      record_result "S6" SKIP "transcoder deployment '$VCN_NAME' not found — s6-start failed or was never run, so there is no health to report"
    else
      vcn_health_check
      healthy=$?
      vcn_stop
      if [ "$healthy" = 0 ]; then
        record_result "S6" PASS "vcn-transcoder ran with 0 restarts and no stalled progress across the run"
      else
        record_result "S6" FAIL "vcn-transcoder health check failed — see $INVARIANT_LOG"
      fi
    fi
    ;;
  s7) s7_wake_probe ;;
  s9) s9_batch_idempotent ;;
  s10) s10_moe ;;
  s11) s11_chaos "${2:-}" ;;
  calibrate) calibrate ;;
  report) emit_report ;;
  all)
    vcn_started=1
    vcn_start || vcn_started=0 # on failure vcn_start already recorded S6=FAIL; dependent checks below are skipped
    s1_coresidence
    s2_contention
    s3_swap_ttl
    s4_concurrency
    s5_multimodel
    s7_wake_probe
    s9_batch_idempotent
    s10_moe
    s11_chaos
    if [ "$vcn_started" = 1 ]; then
      vcn_health_check; healthy=$?
      vcn_stop
      if [ "$healthy" = 0 ]; then
        record_result "S6" PASS "vcn-transcoder ran with 0 restarts and no stalled progress across the whole suite"
      else
        record_result "S6" FAIL "vcn-transcoder health check failed — see $INVARIANT_LOG"
      fi
    else
      log "S6: skipping final transcoder health check — vcn_start already recorded the FAIL"
    fi
    emit_report
    ;;
  ""|help|-h|--help) usage ;;
  *) usage; die "unknown subcommand: $cmd" ;;
esac
