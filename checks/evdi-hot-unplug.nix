# Apply the exact temporary upstream carry to the exact evdi release that needs it, then assert the
# behavior at source level. This is intentionally stronger than proving that two URLs fetch: both
# patches must still apply in order, the USB notifier must react to removal, and dynamically-created
# devices must be destroyed while pre-created devices remain available for stable DRM paths.
{ pkgs }:
let
  fix = import ../lib/evdi-hot-unplug.nix { inherit pkgs; };
  evdiSource = pkgs.fetchurl {
    url = "https://github.com/DisplayLink/evdi/archive/refs/tags/v1.15.0.tar.gz";
    hash = "sha256-wZzREgtDoNiOkc3Yk7WSpWuakE6tJeqCmetLRR9kmJk=";
  };
in
pkgs.runCommand "nixgpu-evdi-hot-unplug-ok"
  {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gnugrep pkgs.patch ];
  }
  ''
    mkdir source
    tar -xzf ${evdiSource} -C source --strip-components=1
    chmod -R u+w source
    cd source

    ${pkgs.lib.concatMapStringsSep "\n" (patch: "patch -Np1 < ${patch}") fix.patches}

    grep -F 'action != USB_DEVICE_REMOVE' module/evdi_platform_drv.c
    grep -F 'i >= evdi_initial_device_count' module/evdi_platform_drv.c
    grep -F 'bool evdi_platform_device_unlink_if_linked_with' module/evdi_platform_dev.c

    touch "$out"
  ''
