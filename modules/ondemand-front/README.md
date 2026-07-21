# ondemand-front

The honest waiting page for scale-to-zero apps on a shared GPU. A handful of infrequent apps sit
at zero replicas until requested; when a request arrives the app may need a few seconds to cold
start, or it may need to wait behind another workload holding the GPU (queueing / model-swap), or
behind a desktop session using the card directly outside k8s. All three situations look identical
from the outside — the target pod is simply not Ready — so one themed waiting page in front of
everything covers all of them: no silent hang, no opaque proxy error, no timeout while the pod
comes up.

This module raw-manifests [Sablier](https://github.com/sablierapp/sablier) (server + RBAC) and a
Caddy front carrying the `sablier` plugin, instead of using Sablier's helm chart, because the chart
only exposes `--strategy...` flags via `extraArgs` — it has no hook to mount a *custom theme*. Since
the whole point here is an honest, on-brand waiting page, the chart's limits lose to the design; the
RBAC is reproduced from the chart's own `rbac.yaml` (see the comments in `default.nix` for why every
rule matters — Sablier's discovery pass aborts entirely, for every workload kind, if it's missing
permission on any one kind actually present in the cluster).

An app opts in by carrying two labels on its own Deployment: `sablier.enable=true` and
`sablier.group=<name>` (Sablier's own discovery labels — this module doesn't set them, it only
wires a Caddy route that references the same group name). A GPU-backed Deployment scaled 0↔1 like
this should also set `strategy.type = "Recreate"`: the default `RollingUpdate` briefly wants both
an old and a new pod scheduled, and on a card with no spare headroom the second pod either fails to
schedule or fights the first for the device — with replicas capped at 0 or 1 there's never a good
reason to run two at once anyway.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixgpu.ondemandFront.enable` | bool | `false` | Enable the module. |
| `nixgpu.ondemandFront.namespace` | str | `"autoscale"` | Namespace for both the Sablier server and the Caddy front. |
| `nixgpu.ondemandFront.createNamespace` | bool | `true` | Whether this module creates `namespace`. |
| `nixgpu.ondemandFront.project` | str | `"platform"` | nixidy AppProject for both Argo Applications. |
| `nixgpu.ondemandFront.sablierImage` | str | `"sablierapp/sablier:1.15.0"` | Sablier server image. |
| `nixgpu.ondemandFront.caddyImage` | str | *(required)* | Caddy image with the `sablier` plugin compiled in. No sane default exists — see the recipe below. |
| `nixgpu.ondemandFront.caddyImagePullPolicy` | enum: `Always` \| `IfNotPresent` \| `Never` | `"IfNotPresent"` | Set to `"Never"` if `caddyImage` is imported straight into the node's runtime instead of pulled from a registry. |
| `nixgpu.ondemandFront.apps` | attrsOf submodule | `{}` | One entry per fronted app: `{ host, displayName, group, upstream, port }`. `displayName` defaults to the attribute name and is what the waiting page shows while the app starts. Generates one Caddyfile `sablier` + `reverse_proxy` block each. |
| `nixgpu.ondemandFront.sessionDuration` | str | `"30m"` | Idle time before Sablier scales an app back to zero. |
| `nixgpu.ondemandFront.refreshFrequency` | str | `"3s"` | Waiting-page auto-refresh / Sablier poll interval. |
| `nixgpu.ondemandFront.theme` | str (HTML) | a neutral dark waiting page | Sablier custom theme (Go `html/template`). Override wholesale to reskin. |

Any Host header not listed in `apps` gets a flat `404` from the Caddy front — this module never
proxies a guess, and never leaks which apps exist behind it via error content.

## Building `caddyImage`

There is no default `caddyImage` because stock Caddy does not ship the `sablier` plugin — shipping
any concrete image reference here would be a fleet-specific value pretending to be generic. Build
one with `xcaddy`/nix, e.g.:

```nix
pkgs.caddy.withPlugins {
  plugins = [ "github.com/sablierapp/sablier/plugins/caddy@v1.15.0" ]; # keep in sync with sablierImage's tag
  hash = "sha256-..."; # nix will tell you the right hash on first build; re-fetch it whenever you bump the version
}
```

Push the result to a registry, or — if your cluster's container runtime supports it — import the
derivation directly as an OCI image and skip the registry entirely (in which case set
`caddyImagePullPolicy = "Never"`, so the kubelet doesn't waste time trying, and failing, to pull an
image that will never exist in any registry).

## Example

```nix
{
  nixgpu.ondemandFront = {
    enable = true;
    caddyImage = "your-registry/caddy-sablier:1.0.0";
    apps = {
      image-gen = {
        host = "image-gen.example.com";
        group = "image-gen";       # must match the app Deployment's sablier.group label
        upstream = "image-gen.image-gen.svc.cluster.local";
        port = 8188;
      };
    };
  };
}
```

## Status

Generalized from a production single-GPU cluster where this exact wiring has been serving one
scale-to-zero app since mid-2026. This generalized form (theme rewritten to be site-neutral, no
hardcoded Service IP) has not yet been re-verified live — review before first deploy.
