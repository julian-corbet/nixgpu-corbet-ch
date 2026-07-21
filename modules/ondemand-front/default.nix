# ondemand-front — the user-facing half of scale-to-zero on a shared GPU: the honest waiting page.
#
# THE JOB: a card shared by a handful of infrequent, scale-to-zero apps (+ maybe a desktop session
# living outside k8s) means a sleeping app must wake on first request, and it may then WAIT for the
# GPU — because another app currently holds it (queueing / model-swap) or because a desktop session
# is using it directly. In every one of those cases the app's pod is simply NOT-READY, so ONE honest
# waiting page covers cold start, GPU contention, AND desktop-in-use at once. No silent hang, no
# opaque proxy error, no reverse-proxy timeout while the pod comes up.
#
# WHY raw-manifested (not the upstream helm chart): the chart exposes only `extraArgs` on the
# Sablier deployment — there is no volume-mount hook — and serving a CUSTOM THEME requires mounting
# one. The design (an on-brand, honest waiting page) leads over the chart's limits, so this module
# writes its own manifests instead of wrapping the chart. That also means the RBAC below is
# reproduced VERBATIM from the chart's own rbac.yaml rather than re-derived: Sablier's kubernetes
# provider does a startup discovery pass over every workload kind it *might* manage, and if any rule
# is missing for a kind actually present in the cluster (e.g. a CNPG `postgresql.cnpg.io` Cluster),
# that whole discovery call comes back FORBIDDEN and Sablier ends up managing NOTHING, not just the
# kind it couldn't see. Get the RBAC list right up front or debug a total silent failure later.
#
# ARCHITECTURE (single namespace holds both pieces of plumbing):
#   caller ─▶ Caddy (+ sablier plugin, compiled in) ─▶ Sablier API (scales the Deployment 0↔1)
#                  └── serves the themed waiting page until the target pod is Ready ──┘
# The Caddy image is NOT stock Caddy — the `sablier` directive is a compiled-in plugin, not
# something Caddy ships with. See the README for the `caddy.withPlugins` recipe; this module only
# consumes the resulting image reference (`caddyImage`, required — there is no honest default here).
#
# OPT-IN CONTRACT for an app that wants to scale to zero behind this front: its own Deployment
# carries two labels, `sablier.enable=true` and `sablier.group=<name>` (Sablier's own discovery
# labels, not anything private to this module). This module does not set those labels — they live
# on the app's Deployment, wherever that's authored — it only wires the Caddy route that references
# the same group name. One more consequence worth stating up front: a GPU-backed Deployment scaled
# 0↔1 like this should use `strategy.type = "Recreate"`, not the default `RollingUpdate`. A rolling
# update briefly wants OLD and NEW pod both scheduled, and on a card with no spare VRAM/compute
# headroom that second pod either fails to schedule or fights the first one for the device — for a
# scale-to-zero workload there is never a good reason to run two replicas at once anyway.
{ lib, config, ... }:
let
  cfg = config.nixgpu.ondemandFront;

  # One Caddy route per fronted app: intercept via the `sablier` plugin directive (which must be
  # ordered before `reverse_proxy` — Caddy doesn't know where a plugin directive falls in the
  # standard handler chain unless told), then hand off to the app's own Service once it's Ready.
  appRoute = name: app: ''
    @${name} host ${app.host}
    handle @${name} {
      sablier http://sablier.${cfg.namespace}.svc.cluster.local:10000 {
        group ${app.group}
        session_duration ${cfg.sessionDuration}
        dynamic {
          display_name "${name}"
          show_details true
          theme ondemand
          refresh_frequency ${cfg.refreshFrequency}
        }
      }
      reverse_proxy ${app.upstream}:${toString app.port}
    }
  '';

  caddyfile = ''
    {
      admin off
      auto_https off
      # See appRoute comment: the plugin directive must be declared in the global block or `handle`
      # will reject it as unknown.
      order sablier before reverse_proxy
    }

    :80 {
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList appRoute cfg.apps)}
      handle {
        # Unknown Host header: never proxy blind, never leak which apps exist behind this front —
        # a flat 404 for anything not explicitly listed in `apps`.
        respond "ondemand front - unknown host" 404
      }
    }
  '';
in
{
  options.nixgpu.ondemandFront = {
    enable = lib.mkEnableOption "the honest scale-to-zero waiting page (Sablier + a themed Caddy front)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "autoscale";
      description = "Namespace both the Sablier server and its Caddy front are deployed into.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this module should create `namespace`. Disable if another module already owns it.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "platform";
      description = ''
        nixidy AppProject both Argo Applications (the Sablier server, the Caddy front) are filed
        under. This is autoscale *plumbing* — it manages scale-to-zero for GPU-adjacent apps, it
        does not itself burn the GPU.
      '';
    };

    sablierImage = lib.mkOption {
      type = lib.types.str;
      default = "sablierapp/sablier:1.15.0";
      description = "Sablier server image. Pinned upstream tag; bump deliberately.";
    };

    caddyImage = lib.mkOption {
      type = lib.types.str;
      description = ''
        Caddy image with the sablier plugin COMPILED IN. There is no default: stock Caddy does not
        have this plugin, and shipping a real registry reference here would be a fleet-specific
        value pretending to be a generic default. Build one yourself — see the README for the
        `caddy.withPlugins` recipe — and point this at the result (a nix-built image imported
        directly into the cluster's container runtime, or a real registry push; either way the
        image must exist before this module is deployed).
      '';
    };

    caddyImagePullPolicy = lib.mkOption {
      type = lib.types.str;
      default = "IfNotPresent";
      description = ''
        Set to `Never` if `caddyImage` is a nix-built image imported straight into the node's
        container runtime rather than pulled from a registry — that avoids the kubelet wasting time
        (and failing) on a pull for an image that will never appear in any registry.
      '';
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Hostname this app is reached at; matched against the request's Host header.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            description = ''
              Sablier group name. Must match the `sablier.group` label on the app's own Deployment —
              this is how Sablier's kubernetes provider knows which workload this route's waiting
              page is waiting for.
            '';
          };

          upstream = lib.mkOption {
            type = lib.types.str;
            description = "Cluster-internal address (typically a Service DNS name) to proxy to once the pod is Ready.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            description = "Port on `upstream` to proxy to.";
          };
        };
      });
      default = { };
      description = ''
        One entry per app fronted by this waiting page. Each entry generates a Caddyfile
        `sablier` + `reverse_proxy` block. Any host not listed here falls through to a flat 404 —
        see the module comment on why that matters.
      '';
    };

    sessionDuration = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = "How long an app may sit idle (Ready, no traffic) before Sablier scales it back to zero.";
    };

    refreshFrequency = lib.mkOption {
      type = lib.types.str;
      default = "3s";
      description = "How often the waiting page's meta-refresh (and Sablier's own dynamic-strategy poll) fires while a pod is not yet Ready.";
    };

    theme = lib.mkOption {
      type = lib.types.str;
      default = ''
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
            <meta name="robots" content="noindex, nofollow" />
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
            <meta http-equiv="refresh" content="{{ .RefreshFrequency }}" />
            <title>{{ if .DisplayName }}Starting {{ .DisplayName }}{{ else }}Starting up{{ end }}</title>
            <style>
                :root { color-scheme: dark; }
                * { box-sizing: border-box; }
                html, body { height: 100%; margin: 0; }
                body {
                    background: #0e0e11; color: #e8e8ea;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 24px;
                }
                .card { width: 100%; max-width: 520px; text-align: center; }
                .spinner {
                    width: 46px; height: 46px; margin: 0 auto 28px; border-radius: 50%;
                    border: 3px solid rgba(255, 255, 255, 0.12); border-top-color: #5b8cff;
                    animation: spin 0.9s linear infinite;
                }
                @keyframes spin { to { transform: rotate(360deg); } }
                h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; letter-spacing: 0.2px; }
                p { margin: 0 auto 14px; font-size: 15px; line-height: 1.55; color: #b6b7bd; max-width: 46ch; }
                p.muted { color: #85868e; font-size: 13px; }
                .status {
                    margin-top: 24px; display: inline-block; text-align: left; font-size: 12.5px;
                    color: #9a9ba3; font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
                }
                .status .row { padding: 2px 0; }
                .status .name { color: #c9cace; padding-right: 0.75em; }
                .status .ok { color: #5fd39a; }
                .status .err { color: #e7625f; }
            </style>
        </head>
        <body>
            <div class="card">
                <div class="spinner" aria-hidden="true"></div>
                <h1>{{ if .DisplayName }}Starting {{ .DisplayName }}{{ else }}Starting up{{ end }}</h1>
                <p>This is an on-demand service running on a shared GPU. Starting it up can take a moment &mdash; this is not an error, and the page will continue on its own.</p>
                <p class="muted">If it does not load shortly, the GPU may be busy with other workloads (including a live desktop session) &mdash; it will become available once that finishes. Idle sessions stop automatically after {{ .SessionDuration }} of inactivity.</p>
                <div class="status">
                    {{- range $i, $instance := .InstanceStates }}
                    <div class="row">
                        <span class="name">{{ $instance.Name }}</span>
                        {{- if $instance.Error }}
                        <span class="err">{{ $instance.Error }}</span>
                        {{- else }}
                        <span class="ok">{{ $instance.Status }} ({{ $instance.CurrentReplicas }}/{{ $instance.DesiredReplicas }})</span>
                        {{- end }}
                    </div>
                    {{ end -}}
                </div>
            </div>
        </body>
        </html>
      '';
      description = ''
        The Sablier custom theme (Go html/template), loaded via
        `--strategy.dynamic.custom-themes-path` with theme name `ondemand`. The default is a neutral,
        professional waiting page: a status heading, one honest sentence that this is "on-demand,
        warming up, not broken", and an auto-refreshing status block — no site-specific copy, no
        personal or company names, no cream/beige backgrounds. Override wholesale to reskin; the
        template variables (`.DisplayName`, `.SessionDuration`, `.RefreshFrequency`,
        `.InstanceStates`) are Sablier's own, not this module's.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.sablier = {
      project = cfg.project;
      namespace = cfg.namespace;
      createNamespace = cfg.createNamespace;

      resources.serviceAccounts.sablier = { };

      # RBAC copied verbatim from the upstream chart's rbac.yaml, PLUS the CNPG rule the chart only
      # adds when a `rbac.cnpg`-style flag is set. See the module comment: without every rule for
      # every kind actually present in the cluster, Sablier's startup discovery pass aborts entirely
      # and it manages nothing. Add a rule here for any other custom resource kind your Sablier
      # groups need to hibernate.
      resources.clusterRoles.sablier.rules = [
        {
          apiGroups = [ "apps" "" ];
          resources = [ "deployments" "deployments/scale" "statefulsets" "statefulsets/scale" ];
          verbs = [ "patch" "get" "update" "list" "watch" ];
        }
        {
          apiGroups = [ "postgresql.cnpg.io" ];
          resources = [ "clusters" ];
          verbs = [ "get" "list" "watch" "patch" ]; # patch = Sablier can hibernate an idle CNPG cluster
        }
      ];

      resources.clusterRoleBindings.sablier = {
        roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "ClusterRole"; name = "sablier"; };
        subjects = [{ kind = "ServiceAccount"; name = "sablier"; namespace = cfg.namespace; }];
      };

      # `cfg.theme` filename stem becomes the theme name Sablier looks up ("ondemand.html" → "ondemand").
      resources.configMaps.sablier-themes.data."ondemand.html" = cfg.theme;

      resources.deployments.sablier.spec = {
        replicas = 1;
        selector.matchLabels.app = "sablier";
        template = {
          metadata.labels.app = "sablier";
          spec = {
            serviceAccountName = "sablier";
            containers = [{
              name = "sablier";
              image = cfg.sablierImage;
              args = [
                "start"
                "--provider.name=kubernetes"
                "--strategy.dynamic.custom-themes-path=/themes"
                "--strategy.dynamic.default-theme=ondemand"
                "--strategy.dynamic.default-refresh-frequency=${cfg.refreshFrequency}"
                "--logging.level=info"
              ];
              ports = [{ name = "http"; containerPort = 10000; }];
              volumeMounts = [{ name = "themes"; mountPath = "/themes"; readOnly = true; }];
              livenessProbe.httpGet = { path = "/health"; port = 10000; };
              readinessProbe.httpGet = { path = "/health"; port = 10000; };
              resources = {
                requests = { cpu = "25m"; memory = "48Mi"; };
                limits = { cpu = "250m"; memory = "128Mi"; };
              };
            }];
            volumes = [{ name = "themes"; configMap.name = "sablier-themes"; }];
          };
        };
      };

      resources.services.sablier.spec = {
        type = "ClusterIP";
        selector.app = "sablier";
        ports = [{ name = "http"; port = 10000; targetPort = 10000; }];
      };
    };

    applications.sablier-caddy = {
      project = cfg.project;
      namespace = cfg.namespace;
      createNamespace = false; # the `sablier` application above owns the namespace

      resources.configMaps.sablier-caddy-config.data."Caddyfile" = caddyfile;

      resources.deployments.sablier-caddy.spec = {
        replicas = 1;
        selector.matchLabels.app = "sablier-caddy";
        template = {
          metadata.labels.app = "sablier-caddy";
          spec = {
            containers = [{
              name = "caddy";
              image = cfg.caddyImage;
              imagePullPolicy = cfg.caddyImagePullPolicy;
              ports = [{ name = "http"; containerPort = 80; }];
              args = [ "run" "--config" "/etc/caddy/Caddyfile" "--adapter" "caddyfile" ];
              volumeMounts = [{ name = "config"; mountPath = "/etc/caddy"; }];
              resources = {
                requests = { cpu = "25m"; memory = "48Mi"; };
                limits = { cpu = "500m"; memory = "128Mi"; };
              };
            }];
            volumes = [{ name = "config"; configMap.name = "sablier-caddy-config"; }];
          };
        };
      };

      resources.services.sablier-caddy.spec = {
        type = "ClusterIP";
        selector.app = "sablier-caddy";
        ports = [{ name = "http"; port = 80; targetPort = 80; }];
      };
    };
  };
}
