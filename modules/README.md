# Modules

Two levels (see the repo README's "Levels" section for the full rationale;
this table is the hook, not the argument):

**Level 2 / edge** — arbitration between `<host>.gpu.apps` (bare-metal/podman)
and `<host>.k3s.gpu.apps` (pods) contending for the same Level-1 card.
`nixidyModules`, rendered into a k3s environment. Extraction targets, in
order (each lands as a generalized module with neutral defaults — see the
repo README and CONTRACT.md):

1. `device-tokens/` — compute + media-engine lane split via a generic device plugin
2. `priority-ladder/` — the PriorityClass ladder
3. `pressure-watcher/` — reactive kill-reclaim DaemonSet (+ GTT spill + zombie guard)
4. `ondemand-front/` — Sablier + Caddy honest waiting front (B7)
5. `kernel/` — optional NixOS kernel-patch module (dmem accounting, TTM eviction order)

**Level 1** — the host itself, true whether or not anything ever contends
for the card. `nixosModules` / `systemManagerModules`:

- `stable-device-paths/` — vendor-keyed `/dev/dri/by-vendor` symlinks, so DRM
  re-enumeration never moves a device path out from under a consumer
- `toolchain/` — the vendor's compute runtime (CUDA/ROCm/oneAPI-class) plus
  its monitoring tool, resolved per host plane
