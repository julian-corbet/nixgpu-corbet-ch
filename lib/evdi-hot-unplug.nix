# Temporary carry for DisplayLink/evdi PR #581, against the current v1.15.0 release.
#
# v1.15.0 compares the USB notifier action with a bus-notifier constant. The numeric collision
# makes the handler run on USB addition and skip USB removal, so a pre-created evdi device remains
# linked to a departed dock. DisplayLinkManager then allocates evdi.1 on the next attachment while
# a compositor pinned to evdi.0 keeps watching the stale card.
#
# Keep the source correction in nixgpu, the owner of evdi behavior, while individual hosts remain
# responsible for how a corrected module is built for their kernel. Delete this carry once an evdi
# release containing both commits is the minimum supported version.
{ pkgs }:
let
  patches = [
    (pkgs.fetchurl {
      name = "evdi-usb-remove-notifier.patch";
      url = "https://github.com/DisplayLink/evdi/commit/f350c12774d7ad6184234194e838c10cf7fe7c9f.patch";
      hash = "sha256-tn0D4PR1W9M3joKIshob6ds7JwSBrzqPg6xHrTMRdyA=";
    })
    (pkgs.fetchurl {
      name = "evdi-destroy-dynamic-device-on-unplug.patch";
      url = "https://github.com/DisplayLink/evdi/commit/7c3c2bfec315861a6019e2b7bf92c8ac3bbaf45f.patch";
      hash = "sha256-TENy0gGI/pxeFpo2xfaFHhSlveb79+PylMlpZna36BA=";
    })
  ];
in
{
  inherit patches;

  apply = package:
    package.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ patches;
    });
}
