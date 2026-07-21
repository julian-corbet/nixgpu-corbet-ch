# priority-ladder — the WHO-YIELDS-FIRST ladder for a shared GPU. Cluster-scoped Kubernetes
# `PriorityClass` objects (scheduling.k8s.io/v1); no Namespace involved, so this module emits
# no `namespace`/`createNamespace` for its own resources. Priority here is not a property of an
# app's *identity* — it is a property of the *intent* under which a pod is submitted right now.
# The same container image can be launched best-effort (a throwaway interactive render nobody
# is waiting on) or promoted to `gpu-interactive`/`gpu-desktop` for the duration of a specific
# job an operator is actively waiting on. This ladder is the vocabulary the platform's pressure
# watcher (a separate module) consults when it needs to decide who gets evicted to free VRAM:
# it walks priority low-to-high and reclaims from the bottom.
{ lib, config, ... }:
let
  cfg = config.nixgpu.priorityLadder;

  # nixidy's `yamls` escape hatch takes raw YAML document text; JSON is valid YAML, so
  # rendering each PriorityClass via toJSON keeps this a plain data transform with no
  # external formatter dependency (mirrors the raw-YAML house style, just generated
  # in-Nix instead of read from a checked-in file).
  toPriorityClass = name: c: builtins.toJSON {
    apiVersion = "scheduling.k8s.io/v1";
    kind = "PriorityClass";
    metadata.name = name;
    value = c.value;
    preemptionPolicy = c.preemptionPolicy;
    description = c.description;
  };
in
{
  options.nixgpu.priorityLadder = {
    enable = lib.mkEnableOption "the GPU priority-class ladder (who yields first under VRAM pressure)";

    project = lib.mkOption {
      type = lib.types.str;
      default = "platform";
      description = ''
        nixidy AppProject this application is filed under. PriorityClasses are cluster-scoped
        objects, so the project mainly governs RBAC/sync policy for this Argo Application, not
        any namespace.
      '';
    };

    classes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          value = lib.mkOption {
            type = lib.types.int;
            description = ''
              The PriorityClass numeric value. Higher always wins a scheduling conflict and can
              preempt lower-priority pods (subject to `preemptionPolicy`). Kubernetes reserves
              values >= 1000000000 for system use; keep application ladders well below that.
            '';
          };

          preemptionPolicy = lib.mkOption {
            type = lib.types.enum [ "PreemptLowerPriority" "Never" ];
            default = "PreemptLowerPriority";
            description = ''
              `PreemptLowerPriority` lets a pending pod at this priority evict running pods of
              lower priority to make room. `Never` means the pod waits in the scheduler queue
              instead of preempting anyone — appropriate for a class whose whole point is "I am
              disposable, don't hurt anyone else to run me".
            '';
          };

          description = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable rationale for this rung, surfaced on the PriorityClass object itself.";
          };
        };
      });
      default = {
        gpu-desktop = {
          value = 1000000;
          preemptionPolicy = "PreemptLowerPriority";
          description = "Desktop/interactive GPU session sharing the card from outside k8s — always wins";
        };
        gpu-interactive = {
          value = 1000;
          preemptionPolicy = "PreemptLowerPriority";
          description = "Latency-sensitive GPU serving";
        };
        gpu-besteffort = {
          value = 100;
          preemptionPolicy = "Never";
          description = "Best-effort GPU work — lowest, first reclaimed under VRAM pressure";
        };
      };
      description = ''
        The priority ladder itself, attrset keyed by PriorityClass name, highest-value rung wins.
        The default reproduces a production three-rung ladder (a host-side desktop/gaming session
        that always wins, an interactive serving tier, and a best-effort tier that never preempts
        and is reclaimed first). Consumers can rename, reorder, add, or drop rungs freely — the
        pressure watcher only cares about the resulting numeric ordering, not these specific names.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.priority-ladder = {
      createNamespace = false; # cluster-scoped PriorityClass objects only, no namespace here
      project = cfg.project;
      syncPolicy.syncOptions.serverSideApply = true;
      annotations."argocd.argoproj.io/compare-options" = "ServerSideDiff=true";
      yamls = lib.mapAttrsToList toPriorityClass cfg.classes;
    };
  };
}
