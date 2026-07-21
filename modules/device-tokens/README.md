# device-tokens

Splits one GPU with an in-kernel driver into counted extended-resource
"tokens" (lanes) via a DaemonSet wrapping
[squat/generic-device-plugin](https://github.com/squat/generic-device-plugin).
Instead of every pod fighting over a single vendor GPU resource, each
independent hardware engine (compute, a media/video codec engine, ...) gets
its own `devic.es/<lane-name>` extended resource with its own small
concurrency ceiling, so unrelated engines can co-schedule in parallel instead
of one claiming the whole card.

The default configuration models a typical AMD RDNA-class card: a
`rocm-compute` lane (ROCm/KFD compute) and a `vcn` lane (the video codec
engine), each capped at 2 concurrent slots.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixgpu.deviceTokens.enable` | bool | `false` | Enable the module. |
| `nixgpu.deviceTokens.namespace` | str | `"kube-system"` | Namespace for the DaemonSet — node/scheduling-critical infra, not an app. |
| `nixgpu.deviceTokens.project` | str | `"platform"` | Passed through as the nixidy `applications.<name>.project`; map it to whatever AppProject owns device-level infra in your GitOps scheme. |
| `nixgpu.deviceTokens.image` | str | `"squat/generic-device-plugin:0.2.0"` | Pinned to the one tagged release; `:latest` is an untagged `main` build and must never be used for node-critical infra. |
| `nixgpu.deviceTokens.imagePullPolicy` | enum | `"IfNotPresent"` | Never `Always` — node-critical, must not depend on a reachable registry to (re)start. |
| `nixgpu.deviceTokens.nodeSelector` | attrsOf str | `{ gpu = "amd"; }` | Restrict to nodes carrying the shared GPU; rename to your own node-label convention. |
| `nixgpu.deviceTokens.devices` | list of `{ name, count, paths }` | see below | The lanes to advertise. |
| `nixgpu.deviceTokens.priorityClassName` | str | `"system-node-critical"` | The plugin must be last to be evicted under kubelet pressure. |
| `nixgpu.deviceTokens.tolerations` | list of attrs | `[ { operator = "Exists"; } ]` | Tolerate all taints, like other node-critical DaemonSets. |

Each entry in `devices` is:

| Field | Type | Description |
|---|---|---|
| `name` | str | Lane name; advertised as `devic.es/<name>`. |
| `count` | positive int | Concurrency ceiling for this lane (not a VRAM budget — the plugin has no VRAM awareness). |
| `paths` | list of str | Host device node paths bind-mounted into a pod holding one slot of this lane. |

Default `devices`:

```nix
[
  { name = "rocm-compute"; count = 2; paths = [ "/dev/kfd" "/dev/dri/renderD128" "/dev/dri/card1" ]; }
  { name = "vcn";          count = 2; paths = [ "/dev/dri/renderD128" "/dev/dri/card1" ]; }
]
```

**Device indexes are not portable.** `/dev/dri/cardN` numbering depends on
enumeration order on the specific machine — a BMC/IPMI virtual VGA adapter
frequently claims `card0`, pushing the real GPU to `card1` or further. Before
using these defaults (or any `paths` override) on a new machine, check that
machine's own `/dev/dri` and cross-reference
`/sys/class/drm/card*/device/uevent` or `lspci` to confirm which `cardN` is
actually the GPU you mean to share. Getting this wrong is silent at apply
time.

## Consumer example

```nix
{
  imports = [ nixgpu.nixosModules.device-tokens ]; # or however your flake exposes it

  nixgpu.deviceTokens = {
    enable = true;
    project = "platform"; # map to your Argo AppProject for device infra
    # nodeSelector, devices, etc. left at defaults, or overridden per fleet
  };
}
```

## Status

Generalized from a production single-GPU cluster; the module form has not
yet been re-verified live end-to-end. The `args` rendering (one `--device`
flag with a multi-line YAML block per lane) intentionally mirrors the exact
form the source DaemonSet uses, to avoid an unrelated formatting change
causing a template diff — and therefore a rolling restart — on infrastructure
that removes every tenant's GPU access while it restarts.

Source lineage: generalized from a production single-GPU cluster.
