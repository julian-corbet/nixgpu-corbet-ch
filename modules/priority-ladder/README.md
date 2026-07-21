# priority-ladder

A nixidy module that renders the cluster-scoped Kubernetes `PriorityClass`
ladder a shared GPU platform uses to decide **who yields first** when VRAM
gets tight.

The core idea: priority is a property of **intent**, not of an app's
identity. The exact same container image can be submitted at the lowest
rung — a throwaway render nobody is waiting on, safe to kill the instant
something more important needs the card — or promoted to a higher rung for
the duration of one specific run an operator is actively sitting in front
of, waiting for a result. Nothing about the app changes; only the priority
it is scheduled under changes, per-submission. This module does not decide
*which* rung any given workload uses — that's a per-app / per-submission
choice made elsewhere. It only defines the rungs that exist and their
ordering, which is the vocabulary a separate GPU pressure-watcher component
consults when it needs to reclaim VRAM: it walks the ladder from the
lowest-priority rung upward and evicts there first.

The default ladder reproduces a production three-rung ordering:

| Rung | Value | Preemption | Meaning |
|------|-------|------------|---------|
| `gpu-desktop` | 1000000 | `PreemptLowerPriority` | An interactive session sharing the card from outside k8s (e.g. a desktop/gaming session) — always wins |
| `gpu-interactive` | 1000 | `PreemptLowerPriority` | Latency-sensitive GPU serving |
| `gpu-besteffort` | 100 | `Never` | Best-effort GPU work — lowest, first reclaimed under pressure, never itself preempts anyone |

Consumers are free to rename, add, remove, or reorder rungs — only the
resulting numeric ordering matters to the pressure watcher, not these
specific names.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixgpu.priorityLadder.enable` | bool | `false` | Enable the module. |
| `nixgpu.priorityLadder.project` | str | `"platform"` | nixidy AppProject this Argo Application is filed under. |
| `nixgpu.priorityLadder.classes` | attrsOf submodule | the 3-rung ladder above | Ladder keyed by PriorityClass name; each entry sets `value` (int), `preemptionPolicy` (`PreemptLowerPriority` \| `Never`), and `description` (str). |

## Consumer example

```nix
{
  imports = [ inputs.nixgpu.nixidyModules.priority-ladder ];

  nixgpu.priorityLadder.enable = true;

  # Optional: extend the ladder with an extra rung, keeping the defaults for the rest.
  nixgpu.priorityLadder.classes.gpu-batch = {
    value = 500;
    preemptionPolicy = "Never";
    description = "Long-running batch job the operator is waiting on, but not latency-sensitive";
  };
}
```

## Status

Extracted from a production single-GPU cluster's `PriorityClass` definitions;
this generalized form has not yet been re-verified live. `PriorityClass` is
cluster-scoped, so this module emits no namespace of its own — the ladder
is meant to be applied once per cluster, alongside whatever workload-facing
namespaces reference it via `priorityClassName`.

Source lineage: generalized from a production single-GPU cluster.
