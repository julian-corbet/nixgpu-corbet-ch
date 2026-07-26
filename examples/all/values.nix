# Placeholder values for every nixidy module in this repository — the file that
# makes the render check real. `nix flake check` renders all four arbiter modules
# from here, so a module that stops evaluating, or that grows a required value
# nobody supplies, fails in CI rather than in somebody's cluster.
#
# Nothing here is real: hostnames are under example.com, paths under
# /var/lib/example, and no credential appears in any form. Enabling all four at
# once is not a deployment anyone would want; it is a proof that each renders.
#
# Note how little this file contains. These modules are almost entirely
# knowledge — of the four, exactly one option in the whole repository has no
# default. That is the arbiter being genuinely self-contained: it describes how a
# card is shared, and that does not vary by site.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # Device lanes: how many concurrent holders the card is advertised as
  # supporting, and which device nodes they need.
  nixgpu.deviceTokens.enable = true;

  # Who wins a conflict, and who may preempt whom. The rungs come from the
  # module; a site overrides individual ones rather than restating the ladder.
  nixgpu.priorityLadder.enable = true;

  # Watches real VRAM pressure and evicts by priority when the card is
  # oversubscribed. Thresholds are knowledge, so nothing is set here.
  nixgpu.pressureWatcher.enable = true;

  # The waiting room: holds a request while a rested workload is brought up, and
  # is how the card returns to the pool when nothing wants it.
  nixgpu.ondemandFront = {
    enable = true;

    # The one option in this repository with no default. There is no portable
    # answer: the front serves a themed waiting page, and which build of the web
    # server does that is the operator's call.
    caddyImage = "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648";

    # At least one app, on purpose. `apps` defaults to empty, and an empty
    # front renders no per-app route or waiting page — so a check that left it
    # empty would pass while proving nothing about the interesting half of this
    # module.
    apps.example-gpu-app = {
      host = "gpu-app.example.com";
      upstream = "example-gpu-app.example-ns.svc.cluster.local";
      port = 8080;
      group = "example-gpu";
    };
  };
}
