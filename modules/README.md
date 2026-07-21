# Modules

Extraction targets, in order (each lands as a generalized module with neutral
defaults — see the repo README and CONTRACT.md):

1. `device-tokens/` — compute + media-engine lane split via a generic device plugin
2. `priority-ladder/` — the PriorityClass ladder
3. `pressure-watcher/` — reactive kill-reclaim DaemonSet (+ GTT spill + zombie guard)
4. `ondemand-front/` — Sablier + Caddy honest waiting front (B7)
5. `kernel/` — optional NixOS kernel-patch module (dmem accounting, TTM eviction order)
