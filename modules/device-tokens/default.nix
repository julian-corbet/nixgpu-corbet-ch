# device-tokens — the co-scheduling substrate: break one GPU with an in-kernel
# driver into counted extended-resource "tokens" (lanes), so independent
# engines (e.g. compute and a media/video engine) get their own small
# concurrency ceiling and can be scheduled in parallel instead of the whole
# card being claimed by whichever pod grabs the single vendor resource first.
#
# Ships as a DaemonSet wrapping squat/generic-device-plugin
# (https://github.com/squat/generic-device-plugin) — a generic Kubelet device
# plugin that advertises arbitrary host device groups as `devic.es/<name>`
# extended resources. We stand on it rather than reinventing a device plugin
# (nixgpu CONTRACT.md: "stand on industry FOSS; don't reinvent").
#
# Generalized from a production single-GPU cluster; this generalized form has
# not yet been re-verified live.
{ lib, config, ... }:
let
  cfg = config.nixgpu.deviceTokens;

  deviceModule = { ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = ''
          The lane name. Advertised to Kubernetes as the extended resource
          `<domain>/<name>` (generic-device-plugin's default domain is
          `devic.es`, e.g. `devic.es/rocm-compute`).
        '';
      };
      count = lib.mkOption {
        type = lib.types.ints.positive;
        description = ''
          How many concurrent slots this lane offers. This is a
          *concurrency ceiling*, not a VRAM reservation — the plugin has no
          idea what VRAM is; it just caps how many pods can simultaneously
          request this device group. Keep it small (2-4) for a single
          consumer card so co-scheduling stays meaningful.
        '';
      };
      paths = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        description = ''
          Host device node paths that make up one instance of this group.
          Every pod that gets a slot of this lane has every path in this
          list bind-mounted in. Typically a compute lane needs the kernel
          driver's compute node(s) plus a render node; a decode/encode lane
          may need only the render node.

          **Device indexes are NOT portable across machines.** `/dev/dri/cardN`
          numbering depends on enumeration order (a BMC/IPMI virtual VGA
          adapter frequently claims `card0`, pushing the real GPU to `card1`
          or higher; a second display adapter shifts it further). Never copy
          these defaults onto a new machine without checking that machine's
          own `/dev/dri` first (`ls /dev/dri`, cross-check against
          `cat /sys/class/drm/card*/device/uevent` or `lspci` to find which
          `cardN` is actually the GPU you mean to share). Injecting the
          wrong card is silent at apply time and only surfaces as "the
          plugin advertises devices that don't work" or, worse, "a
          management/console adapter got exposed to workloads".
        '';
      };
    };
  };
in
{
  options.nixgpu.deviceTokens = {
    enable = lib.mkEnableOption "the device-tokens co-scheduling DaemonSet (generic-device-plugin)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "kube-system";
      description = ''
        Namespace the DaemonSet runs in. Defaults to `kube-system` because
        this is node/scheduling-critical infrastructure, on the same
        footing as other device plugins (e.g. the vendor's own GPU device
        plugin), not an application workload.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "platform";
      description = ''
        Logical grouping label for this application, passed straight
        through as the nixidy `applications.<name>.project` value. Map it
        to whatever your Argo CD AppProject scheme calls the tier that owns
        cluster/node-level device infrastructure (as opposed to end-user
        apps) — this module does not assume any particular AppProject
        exists.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "squat/generic-device-plugin:0.2.0";
      description = ''
        Container image for the device plugin. Pinned to the one tagged
        release the plugin has ever cut, because its `:latest` tag is an
        untagged, non-reproducible build off `main` — never use it for a
        component the node's scheduling correctness depends on. Bump this
        only to a newer tagged release, deliberately, and only if the CLI
        surface (in particular the `--device` YAML shape below) is
        unchanged or you have updated `devices` to match.
      '';
    };

    imagePullPolicy = lib.mkOption {
      type = lib.types.enum [ "Always" "IfNotPresent" "Never" ];
      default = "IfNotPresent";
      description = ''
        Kept off `Always`/registry-dependent behavior deliberately: this
        DaemonSet is node-critical (`priorityClassName`, below) and must
        never fail to (re)start because a registry happened to be
        unreachable. `IfNotPresent` means once the image is on the node it
        keeps working offline.
      '';
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { gpu = "amd"; };
      description = ''
        Node selector restricting the DaemonSet to nodes that actually
        carry the shared GPU. The default assumes a `gpu=amd` node label
        convention; rename the label/value to whatever your fleet uses to
        mark GPU-bearing nodes.
      '';
    };

    devices = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.submodule deviceModule);
      default = [
        {
          name = "rocm-compute";
          count = 2;
          paths = [
            "/dev/kfd"
            "/dev/dri/renderD128"
            "/dev/dri/card1"
          ];
        }
        {
          name = "vcn";
          count = 2;
          paths = [
            "/dev/dri/renderD128"
            "/dev/dri/card1"
          ];
        }
      ];
      description = ''
        The lanes to advertise. The default is two lanes matching an AMD
        RDNA-class card: `rocm-compute` (the ROCm/KFD compute path — needs
        `/dev/kfd` plus the render node and the card's DRM node) and `vcn`
        (the video codec engine — separate silicon, needs only the render
        and DRM nodes). These are independent hardware engines that run in
        parallel without contending with each other, which is the whole
        point of splitting them into separate lanes rather than one shared
        `gpu` resource.

        SEE THE `paths` OPTION DOC ABOVE: the `/dev/dri/cardN` index in
        these defaults is NOT portable. It was `card1` on the machine this
        was extracted from (whose `card0` was a BMC/management VGA
        adapter); your machine's numbering may differ or match by
        coincidence. Verify before trusting the default.
      '';
    };

    priorityClassName = lib.mkOption {
      type = lib.types.str;
      default = "system-node-critical";
      description = ''
        PriorityClass for the plugin pod. Defaults to the built-in
        `system-node-critical` class: if the kubelet is starved and has to
        pick what to evict, the device plugin that makes the GPU schedulable
        at all should be last to go.
      '';
    };

    tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ { operator = "Exists"; } ];
      description = ''
        Pod tolerations. Defaults to tolerate everything (`operator =
        "Exists"` with no key), matching node-critical DaemonSets like
        vendor CNI/CSI plugins that must run regardless of taints — a GPU
        node commonly carries other taints (dedicated workload nodes,
        NoSchedule cordons) that should not stop the device plugin itself
        from registering.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.device-tokens = {
      namespace = cfg.namespace;
      createNamespace = false; # kube-system (or whatever namespace is chosen) already exists
      project = cfg.project;

      resources.daemonSets.gpu-shares-device-plugin = {
        metadata.labels.app = "gpu-shares-device-plugin";
        spec = {
          selector.matchLabels.app = "gpu-shares-device-plugin";
          updateStrategy.type = "RollingUpdate";
          template = {
            metadata.labels.app = "gpu-shares-device-plugin";
            spec = {
              priorityClassName = cfg.priorityClassName;
              nodeSelector = cfg.nodeSelector;
              tolerations = cfg.tolerations;
              containers = [
                {
                  name = "gdp";
                  image = cfg.image;
                  imagePullPolicy = cfg.imagePullPolicy;
                  # NOTE: kept as one "--device" flag + one multi-line YAML block-scalar string
                  # PER lane (not folded into a single inline/flow-style blob). This mirrors the
                  # live form this was extracted from: the two forms parse to the identical
                  # device spec, but the multi-line form is what a running node's DaemonSet
                  # template already matches — switching styles would show up as a template
                  # diff and (on a scheduling-critical node-critical DaemonSet) trigger an
                  # unnecessary rolling restart that briefly strips GPU devices from every
                  # tenant on the node. Keep this form stable across edits; only change the
                  # *content* of a lane, never its rendering style, unless you intend the
                  # restart.
                  args = lib.concatMap
                    (d: [
                      "--device"
                      ''
                        name: ${d.name}
                        groups:
                          - count: ${toString d.count}
                            paths:
                        ${lib.concatMapStringsSep "\n" (p: "      - path: ${p}") d.paths}
                      ''
                    ])
                    cfg.devices;
                  resources = {
                    requests = { cpu = "50m"; memory = "10Mi"; };
                    limits = { cpu = "50m"; };
                  };
                  securityContext.privileged = true; # needs raw access to the host device nodes below
                  volumeMounts = [
                    { name = "device-plugin"; mountPath = "/var/lib/kubelet/device-plugins"; }
                    { name = "dev"; mountPath = "/dev"; }
                  ];
                }
              ];
              volumes = [
                { name = "device-plugin"; hostPath.path = "/var/lib/kubelet/device-plugins"; }
                { name = "dev"; hostPath.path = "/dev"; }
              ];
            };
          };
        };
      };
    };
  };
}
