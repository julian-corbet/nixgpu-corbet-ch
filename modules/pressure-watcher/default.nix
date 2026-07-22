# nixgpu.pressureWatcher — THE reactive core of the platform: a per-GPU-node DaemonSet that kills
# (scales to 0) the lowest-priority in-cluster GPU pod when a higher-priority tenant starves while
# the card is full, detects desktop thrash via the global GTT-spill counter in sysfs, and guards the
# device plugin against the kubelet registration-zombie (squat/generic-device-plugin#63).
#
# Purely reactive: no budgets, no per-job VRAM declaration, no reservation, no toggle. Decisions use
# MEASURED VRAM (CONTRACT.md B8), priority decides who leaves (B2), the media engine is exempt (B3).
#
# The bash algorithm is preserved exactly from the production original; only identifiers, label keys,
# and tunables were lifted into options. Do not "improve" the script without re-reading the design
# lessons comment inside it.
{ lib, config, ... }:
let
  cfg = config.nixgpu.pressureWatcher;

  # The engine label key is embedded in a kubectl jsonpath expression, where every dot inside a
  # label key MUST be backslash-escaped ({.metadata.labels.foo\.bar/engine}) — jsonpath otherwise
  # treats the dots as path separators and the field silently reads empty, which would make every
  # tenant look engine-less. Slashes need no escaping. Built here so consumers only ever set the
  # plain key.
  engineKeyJsonpath = lib.replaceStrings [ "." ] [ "\\." ] cfg.engineLabelKey;

  script = ''
    #!/bin/bash
    # gpu-pressure-watcher — the reactive core of the platform. Handles BOTH in-cluster pods and the
    # desktop, purely from OBSERVED signals. No budgets, no per-job VRAM declaration, no reservation,
    # no toggle.
    #
    # Cluster pods: in-kernel-driver compute VRAM (ROCm/CUDA-style) is PINNED — the kernel can't evict
    #   it, so a starved high-priority pod OOMs instead of slowing down. Signal = a higher-priority GPU
    #   pod stays not-Ready while the card is full. Action = kill (scale-to-0) the lowest-priority
    #   running GPU pod so the high one can retry+fit.
    #
    # Desktop (a desktop session sharing the card from OUTSIDE k8s — e.g. a host compositor or a
    #   sibling container whose cgroup this pod cannot read; dmem accounting isn't delegated to us):
    #   its VRAM is GRAPHICS, which — unlike compute — SPILLS to system RAM (GTT) under pressure
    #   instead of OOMing. So "the desktop is thrashing" shows up GLOBALLY as gtt_used rising while
    #   VRAM is full — exactly "when a container finds itself in RAM constantly it is just thrashing".
    #   The desktop is a synthetic TOP-priority tenant: when it thrashes, shed the lowest-priority
    #   in-cluster GPU pod. It never declares a number and is never a victim. A light game
    #   (flash/retro/indie) never fills the card, so this NEVER fires for it — only a heavy title that
    #   genuinely wants the card sheds cluster pods, and only incrementally, lowest-priority first,
    #   until the spill stops. An AI box first; entertainment that doesn't need the VRAM doesn't
    #   disturb it.
    #
    # Plain bash (the kubectl image is enough; no python dependency). Design lessons (AntMan/Ray/oomd):
    # grace before acting, must OUTRANK the victim, never act without a lower-priority candidate,
    # scale-to-0 the owning Deployment (stays down + a scale-from-zero front such as KEDA/Sablier
    # refills it on demand) rather than delete-and-respawn, cooldown so a kill lands first.
    set -u
    NODE="''${NODE_NAME:-}"
    HI="''${HI_WATER:-0.85}"               # VRAM-full gate (fraction of total): only treat starvation/spill as real when the card is genuinely full
    GRACE="''${GRACE_TICKS:-2}"            # a tenant must stay starved/spilling this many ticks before it justifies a kill (anti-flap)
    GTT_DELTA="''${GTT_DELTA:-67108864}"   # ignore GTT jitter below this (64 MiB) — a noise floor, NOT a per-app budget
    SLEEP="''${TICK:-6}"
    DESK_PRIO="''${DESKTOP_PRIORITY:-2000000}"   # the desktop outranks every PriorityClass (the ladder tops out at 1e6) — it always wins
    ENGINE_EXEMPT="''${ENGINE_EXEMPT:-vcn}"      # engine-label value marking exempt media-engine tenants (B3)
    GUARD_RESOURCES="''${GUARD_RESOURCES:-}"     # extended resources the device plugin must advertise (space-separated; empty = guard off)
    GUARD_LABEL="''${GUARD_LABEL:-app=gpu-shares-device-plugin}"
    GUARD_NS="''${GUARD_NS:-kube-system}"
    GUARD_GRACE="''${GUARD_GRACE:-5}"            # ticks a resource must read 0 before the bounce (anti-flap; a plugin rollout re-registers in seconds)
    BROKER_STATUS_URL="''${BROKER_STATUS_URL:-}"  # optional: a shared multi-model LLM server's status endpoint (e.g. llama-swap /running). Empty = off.
    BROKER_PRIO="''${BROKER_PRIO:-1000}"          # priority of the broker's model-load-starvation signal (default = interactive tier)
    KILL_COOLDOWN="''${KILL_COOLDOWN:-3}"         # ticks to wait after a kill for reclaimed VRAM to land before re-deciding. Lower = faster
                                                  # multi-evict convergence when ONE eviction isn't enough (a big model needing several lanes freed)
    declare -A starve

    log(){ echo "$(date -u +%H:%M:%S)Z $*"; }

    # NODE_NAME comes from the Downward API (fieldRef spec.nodeName). Never guess a node name: a wrong
    # guess would make every node query silently target the wrong (or no) node and neuter the watcher.
    if [ -z "$NODE" ]; then
      log "NODE_NAME is empty — it must be injected via fieldRef spec.nodeName; refusing to guess"
      exit 1
    fi

    # discover the discrete card's sysfs (biggest mem_info_vram_total) under the hostPath-mounted /host/sys
    CARD=""
    for c in /host/sys/class/drm/card*/device; do
      [ -r "$c/mem_info_vram_total" ] || continue
      t=$(cat "$c/mem_info_vram_total" 2>/dev/null); [ "''${t:-0}" -gt 1000000000 ] && CARD="$c"
    done
    [ -n "$CARD" ] && log "watching VRAM+GTT via $CARD" || log "card sysfs not visible here — pod starvation signal only (no desktop spill signal)"

    rd(){ cat "$CARD/$1" 2>/dev/null; }
    vfrac(){ [ -z "$CARD" ] && { echo 1; return; }
      u=$(rd mem_info_vram_used); t=$(rd mem_info_vram_total)
      awk "BEGIN{print ($t>0)? $u/$t : 0}"; }

    owner_deploy(){ # ns pod -> owning Deployment name (pod -> RS -> Deployment), else empty
      local ns=$1 p=$2 rs
      rs=$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null) || return
      [ -z "$rs" ] && return
      kubectl -n "$ns" get rs "$rs" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null
    }

    log "gpu-pressure-watcher up on $NODE — reactive kill-lowest-priority (cluster pods + desktop GTT-spill)"
    cd=0                                            # cooldown ticks after a kill: let the reclaimed (pinned) VRAM actually land before re-deciding
    guard_bad=0; guard_cd=0                         # registration-guard state: consecutive zero-ticks + post-bounce cooldown
    gtt_prev=$([ -n "$CARD" ] && rd mem_info_gtt_used || echo 0); gtt_prev=''${gtt_prev:-0}
    while true; do
      f=$(vfrac); press=$(awk "BEGIN{print ($f>$HI)?1:0}")
      # Select GPU pods by LABEL (${cfg.managedLabelKey}=true) so we see EVERY tenant regardless of
      # which device-plugin resource it uses (a whole-card resource or counted devic.es/* shares) —
      # B2. Read ${cfg.engineLabelKey} to exempt the media engine.
      data=$(kubectl get pods -A -l ${cfg.managedLabelKey}=true --field-selector "spec.nodeName=$NODE" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.priority}{"|"}{.status.containerStatuses[0].ready}{"|"}{.metadata.labels.${engineKeyJsonpath}}{"\n"}{end}' 2>/dev/null)
      hi_prio=-1; hi_pod=""
      lo_prio=9999999999; lo_pod=""; lo_ns=""
      while IFS='|' read -r ns name prio ready engine; do
        [ -z "$name" ] && continue
        [ "$engine" = "$ENGINE_EXEMPT" ] && continue  # the media engine is separate silicon (B3) — never a compute victim or trigger
        [ -z "$prio" ] && prio=0
        key="$ns/$name"
        if [ "$ready" = "false" ]; then            # starved candidate (OOM-restarting / not yet up)
          starve[$key]=$(( ''${starve[$key]:-0} + 1 ))
          [ "''${starve[$key]}" -ge "$GRACE" ] && [ "$prio" -gt "$hi_prio" ] && { hi_prio=$prio; hi_pod="$key"; }
        elif [ "$ready" = "true" ]; then           # running, holding VRAM
          starve[$key]=0
          [ "$prio" -lt "$lo_prio" ] && { lo_prio=$prio; lo_pod="$name"; lo_ns="$ns"; }
        fi
      done <<< "$data"

      # Desktop tenant: thrash = card full AND graphics spilling to system RAM (gtt_used rising past the noise floor).
      gtt_now=$([ -n "$CARD" ] && rd mem_info_gtt_used || echo 0); gtt_now=''${gtt_now:-0}
      if [ "$press" = 1 ] && [ "$gtt_now" -gt "$(( gtt_prev + GTT_DELTA ))" ]; then
        starve[__desktop__]=$(( ''${starve[__desktop__]:-0} + 1 ))
        [ "''${starve[__desktop__]}" -ge "$GRACE" ] && [ "$DESK_PRIO" -gt "$hi_prio" ] && { hi_prio=$DESK_PRIO; hi_pod="desktop(GTT-spill)"; }
      else
        starve[__desktop__]=0
      fi
      gtt_prev=$gtt_now

      # Broker starvation: a shared multi-model LLM server keeps its POD Ready even when a requested
      # model cannot fit VRAM — it holds that model in a non-"ready" state and retries the load — so
      # its starvation is INVISIBLE to the pod-readiness signal above (the pod never goes not-Ready).
      # Ask the server directly: a model stuck non-"ready" while the card is full means a
      # higher-priority tenant is starved for VRAM, so shed the lowest-priority compute tenant to free
      # room for the retry. Mirrors the desktop synthetic-tenant pattern. Optional (empty URL = off);
      # fail-open — an unreachable or unparseable response never fabricates starvation.
      if [ -n "$BROKER_STATUS_URL" ] && [ "$press" = 1 ]; then
        nstuck=$(curl -s --max-time 3 "$BROKER_STATUS_URL" 2>/dev/null | jq -r '[.running[]? | select(.state != "ready")] | length' 2>/dev/null)
        if [ -n "$nstuck" ] && [ "$nstuck" -gt 0 ] 2>/dev/null; then
          starve[__broker__]=$(( ''${starve[__broker__]:-0} + 1 ))
          [ "''${starve[__broker__]}" -ge "$GRACE" ] && [ "$BROKER_PRIO" -gt "$hi_prio" ] && { hi_prio=$BROKER_PRIO; hi_pod="broker(model-load starved)"; }
        else
          starve[__broker__]=0
        fi
      else
        starve[__broker__]=0
      fi

      if [ "$cd" -gt 0 ]; then
        cd=$((cd-1))                               # a kill is still landing — don't re-decide yet
      elif [ "$press" = 1 ] && [ -n "$hi_pod" ] && [ -n "$lo_pod" ] && [ "$hi_prio" -gt "$lo_prio" ]; then
        dep=$(owner_deploy "$lo_ns" "$lo_pod")
        pct=$(printf '%.0f' "$(awk "BEGIN{print $f*100}")")
        if [ -n "$dep" ]; then
          log "VRAM ''${pct}% + $hi_pod (prio $hi_prio) STARVED → scale $lo_ns/$dep to 0 (lowest prio $lo_prio)"
          kubectl -n "$lo_ns" scale deploy "$dep" --replicas=0 >/dev/null 2>&1
        else
          log "VRAM ''${pct}% + $hi_pod (prio $hi_prio) STARVED → delete lowest-pri pod $lo_ns/$lo_pod (prio $lo_prio)"
          kubectl -n "$lo_ns" delete pod "$lo_pod" --grace-period=5 >/dev/null 2>&1
        fi
        unset starve; declare -A starve           # reset grace counters after acting (anti-over-evict: re-observe from scratch after the freed VRAM lands)
        cd=$KILL_COOLDOWN                          # wait for the reclaimed VRAM to land before deciding again (default 3 ≈ 18s at a 6s tick; was a fixed 30s)
      fi

      # Registration guard (a real production incident): after a node/runtime crash the device plugin
      # can re-register into a ZOMBIE — the process logs "starting listwatch" and believes it is
      # healthy, but kubelet's device manager holds NO devices for it, so node allocatable sticks at 0
      # forever. The plugin can never see this itself: its only recovery trigger is its own socket
      # file vanishing, and a dead kubelet-side stream is invisible to it
      # (squat/generic-device-plugin#63, unfixed upstream). Cure is external observation: when a
      # guarded resource reads 0 (or is absent) while the plugin pod is Running, bounce the pod — the
      # fresh process re-registers under a NEW socket name and capacity returns in seconds.
      # Fail-closed: a FAILED node query is never treated as zero.
      if [ -n "$GUARD_RESOURCES" ]; then
        if [ "$guard_cd" -gt 0 ]; then
          guard_cd=$((guard_cd-1))                 # a bounce is still landing — don't re-judge yet
        elif alloc=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable}' 2>/dev/null) && [ -n "$alloc" ]; then
          zero=""
          for r in $GUARD_RESOURCES; do
            case "$alloc" in
              *"\"$r\":\"0\""*) zero="$zero $r" ;;  # advertised but ZERO — the zombie signature
              *"\"$r\":"*)      ;;                  # present and nonzero — healthy
              *)                zero="$zero $r" ;;  # absent entirely — plugin never (re)registered
            esac
          done
          if [ -n "$zero" ]; then
            guard_bad=$((guard_bad+1))
            if [ "$guard_bad" -ge "$GUARD_GRACE" ]; then
              phase=$(kubectl -n "$GUARD_NS" get pods -l "$GUARD_LABEL" --field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
              if [ "$phase" = "Running" ]; then
                log "registration-guard: allocatable ZERO for$zero while $GUARD_NS $GUARD_LABEL is Running → registration zombie, bouncing the plugin pod"
                kubectl -n "$GUARD_NS" delete pod -l "$GUARD_LABEL" --field-selector "spec.nodeName=$NODE" --grace-period=5 >/dev/null 2>&1
              else
                log "registration-guard: allocatable ZERO for$zero but plugin pod phase=''\'''${phase:-absent}' — kubelet/DaemonSet already on it, standing by"
              fi
              guard_bad=0; guard_cd=50             # ~5 min at the default 6s tick: let the fresh registration land before re-judging
            fi
          else
            guard_bad=0
          fi
        else
          log "registration-guard: node query failed — skipping this tick (a failed query is never zero)"
        fi
      fi
      sleep "$SLEEP"
    done
  '';
in
{
  options.nixgpu.pressureWatcher = {
    enable = lib.mkEnableOption
      "the GPU pressure watcher — reactive kill-lowest-priority under VRAM pressure, desktop GTT-spill detection, and the device-plugin registration guard";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "gpu-platform";
      description = "Namespace the watcher (ServiceAccount, DaemonSet, script ConfigMap) lives in.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this application creates its namespace. Set false if the namespace is created elsewhere in your environment.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "platform";
      description = "Argo CD AppProject for the application.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "bitnami/kubectl:latest";
      description = ''
        Container image for the watcher. Anything with bash + kubectl works. The `:latest` tag is
        inherited from the production source; pinning a specific kubectl version matching your
        cluster is wise.
      '';
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { gpu = "amd"; };
      description = "Node selector for the DaemonSet — run the watcher only on GPU nodes.";
    };

    managedLabelKey = lib.mkOption {
      type = lib.types.str;
      default = "nixgpu.corbet.ch/managed";
      description = ''
        Label key that marks a pod as a managed GPU tenant (value must be `"true"`). EVERY GPU
        tenant must carry this label or the watcher can neither protect nor evict it.
      '';
    };

    engineLabelKey = lib.mkOption {
      type = lib.types.str;
      default = "nixgpu.corbet.ch/engine";
      description = ''
        Label key naming which GPU engine a tenant uses. Tenants labeled with value `vcn` (the
        media engine — separate silicon) are exempt from compute-pressure decisions: never a victim,
        never a starvation trigger. Dots in this key are jsonpath-escaped automatically.
      '';
    };

    engineExemptValue = lib.mkOption {
      type = lib.types.str;
      default = "vcn";
      description = ''
        The engine-label value marking media-engine tenants that are never compute victims or
        triggers.
      '';
    };

    hiWater = lib.mkOption {
      # strMatching so a non-numeric value fails at eval time instead of inside awk at runtime.
      type = lib.types.strMatching "[0-9]*\\.?[0-9]+";
      default = "0.85";
      description = ''
        VRAM-full gate as a decimal fraction of total VRAM (string, passed verbatim to awk). Only
        when used/total exceeds this is starvation or GTT spill treated as real pressure.
      '';
    };

    graceTicks = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Ticks a tenant must stay starved/spilling before it justifies a kill (anti-flap).";
    };

    killCooldownTicks = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = ''
        Ticks to wait after a kill for the reclaimed (pinned) VRAM to actually land before the watcher
        re-decides. Must cover a pod's terminate-and-free time (~one grace period); lower values make
        multi-eviction converge faster when a single eviction does not free enough VRAM (e.g. a large
        model that needs several lanes freed at once). Default 3 (~18s at the 6s tick).
      '';
    };

    gttDelta = lib.mkOption {
      type = lib.types.int;
      default = 67108864;
      description = ''
        GTT growth per tick (bytes) below which spill is ignored — a noise floor (default 64 MiB),
        NOT a per-app budget.
      '';
    };

    tickSeconds = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Seconds between watcher ticks. Cooldowns are counted in ticks, so changing this rescales them.";
    };

    desktopPriority = lib.mkOption {
      type = lib.types.int;
      default = 2000000;
      description = ''
        Synthetic priority of the desktop tenant. Must outrank every in-cluster PriorityClass (the
        default ladder tops out at 1000000) so the desktop always wins and is never a victim.
      '';
    };

    brokerStatusUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Optional HTTP status endpoint of a shared multi-model LLM server (e.g. llama-swap's
        `/running`, returning `{"running":[{"model":..,"state":"ready"|"starting"|..}]}`). A shared
        server's pod stays Ready even when a requested model cannot fit VRAM, so its starvation is
        invisible to pod-readiness alone (B4/B8 gap). When set, the watcher polls this endpoint and
        treats a model stuck in a non-`ready` state — while the card is VRAM-full — as a starved
        higher-priority tenant, shedding the lowest-priority compute tenant to free room for the
        retry. Empty disables the check; fail-open (an unreachable/unparseable response never
        triggers a kill). Requires `curl` + `jq` in the watcher image (`bitnami/kubectl` has both).
      '';
    };

    brokerPriority = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = ''
        Synthetic priority of the broker's model-load-starvation signal (default 1000 = the
        interactive tier). Must exceed a best-effort tenant's priority for the watcher to evict it in
        the broker's favor.
      '';
    };

    guardResources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "devic.es/rocm-compute" "devic.es/vcn" ];
      description = ''
        Extended resources the device plugin must keep advertising with a nonzero count. When one
        reads 0 (or vanishes) while the plugin pod is Running, the plugin pod is bounced
        (registration-zombie cure, squat/generic-device-plugin#63). Empty list disables the guard.
      '';
    };

    guardLabel = lib.mkOption {
      type = lib.types.str;
      default = "app=gpu-shares-device-plugin";
      description = "Label selector locating the device-plugin pod to bounce.";
    };

    guardNamespace = lib.mkOption {
      type = lib.types.str;
      default = "kube-system";
      description = "Namespace of the device-plugin pod the guard watches.";
    };

    guardGraceTicks = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        Ticks a guarded resource must read zero/absent before the bounce (anti-flap — a legitimate
        plugin rollout re-registers within seconds).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.gpu-pressure-watcher = {
      namespace = cfg.namespace;
      createNamespace = cfg.createNamespace;
      project = cfg.project;

      resources = {
        serviceAccounts.gpu-pressure-watcher = { };

        # RBAC — replicated verbatim from the production source; it is the minimal set the script
        # uses: read+delete pods (victims + plugin bounce), read nodes (allocatable for the guard),
        # read replicasets (pod -> RS -> Deployment owner walk), scale deployments (the kill action).
        clusterRoles.gpu-pressure-watcher.rules = [
          { apiGroups = [ "" ]; resources = [ "pods" ]; verbs = [ "get" "list" "delete" ]; }
          { apiGroups = [ "" ]; resources = [ "nodes" ]; verbs = [ "get" ]; }
          { apiGroups = [ "apps" ]; resources = [ "replicasets" ]; verbs = [ "get" "list" ]; }
          {
            apiGroups = [ "apps" ];
            resources = [ "deployments" "deployments/scale" ];
            verbs = [ "get" "list" "patch" "update" ];
          }
        ];

        clusterRoleBindings.gpu-pressure-watcher = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = "gpu-pressure-watcher";
          };
          subjects = [{
            kind = "ServiceAccount";
            name = "gpu-pressure-watcher";
            namespace = cfg.namespace;
          }];
        };

        configMaps.pressure-watcher-script.data."pressure-watcher.sh" = script;

        daemonSets.gpu-pressure-watcher = {
          metadata.labels.app = "gpu-pressure-watcher";
          spec = {
            selector.matchLabels.app = "gpu-pressure-watcher";
            template = {
              metadata.labels.app = "gpu-pressure-watcher";
              spec = {
                serviceAccountName = "gpu-pressure-watcher";
                nodeSelector = cfg.nodeSelector;
                containers = [{
                  name = "watcher";
                  image = cfg.image;
                  command = [ "bash" "/script/pressure-watcher.sh" ];
                  env = [
                    # The script refuses to start without this — never hard-code a node name.
                    { name = "NODE_NAME"; valueFrom.fieldRef.fieldPath = "spec.nodeName"; }
                    { name = "HI_WATER"; value = cfg.hiWater; }
                    { name = "GRACE_TICKS"; value = toString cfg.graceTicks; }
                    { name = "KILL_COOLDOWN"; value = toString cfg.killCooldownTicks; }
                    { name = "GTT_DELTA"; value = toString cfg.gttDelta; }
                    { name = "TICK"; value = toString cfg.tickSeconds; }
                    { name = "DESKTOP_PRIORITY"; value = toString cfg.desktopPriority; }
                    { name = "ENGINE_EXEMPT"; value = cfg.engineExemptValue; }
                    { name = "BROKER_STATUS_URL"; value = cfg.brokerStatusUrl; }
                    { name = "BROKER_PRIO"; value = toString cfg.brokerPriority; }
                    # Bounce the device plugin when these stick at 0 (registration zombie); empty = guard off.
                    { name = "GUARD_RESOURCES"; value = lib.concatStringsSep " " cfg.guardResources; }
                    { name = "GUARD_LABEL"; value = cfg.guardLabel; }
                    { name = "GUARD_NS"; value = cfg.guardNamespace; }
                    { name = "GUARD_GRACE"; value = toString cfg.guardGraceTicks; }
                  ];
                  # privileged + root: the watcher reads the amdgpu sysfs counters through the
                  # hostPath-mounted /sys — the GTT-spill signal — which is not visible otherwise.
                  securityContext = { privileged = true; runAsUser = 0; };
                  volumeMounts = [
                    { name = "script"; mountPath = "/script"; }
                    { name = "sys"; mountPath = "/host/sys"; readOnly = true; }
                  ];
                }];
                volumes = [
                  { name = "script"; configMap.name = "pressure-watcher-script"; }
                  { name = "sys"; hostPath.path = "/sys"; }
                ];
              };
            };
          };
        };
      };
    };
  };
}
