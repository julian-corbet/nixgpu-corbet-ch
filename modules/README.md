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

- `stable-device-paths/` — the host's COMPLETE DRM device inventory (PCI *and*
  platform devices), plus the `by-vendor`/`by-driver` symlinks generated from
  it, so DRM re-enumeration never moves a device path out from under a consumer
  and no device is missing from the table a consumer computes a complement
  against. Also `by-name` (`cardNamePath`/`renderNamePath`), the family that is
  actually safe in `WLR_DRM_DEVICES` — colon-free unlike `by-path`, unambiguous
  unlike `by-vendor`
- `evdi/` — the virtual DRM device a DisplayLink dock draws through; its module
  parameter is not optional (upstream's default of 0 creates no device at all)
- `displaylink/` — DisplayLinkManager, evdi's proprietary userland. Separate
  from `evdi/` because the two halves are independently placeable — kernel on
  the metal, userland wherever the desktop is
- `toolchain/` — vendor × capability × platform: which silicon this host has
  and what it wants to DO with it (display, hardware video, compute, AI
  inference, 32-bit gaming, container exposure, probes, diagnostics), each resolved to
  real package names per host plane via `../lib/catalogue.nix`. See
  `toolchain/README.md` for the full design and the boundary against nixllm.
