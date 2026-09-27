#!/bin/sh
# Build-host entry point for installation matters.
#
# The actual installer is overlay/usr/local/bin/datum-install, which ships
# inside the live ISO and runs on the live system:
#
#   sudo datum-install --disk /dev/vdX --user datum --yes
#
# See datum-install --help and the README for the full workflow. There is
# nothing to "install" from the build host itself.
set -eu
printf '%s\n' 'Run this from the booted live ISO: sudo datum-install --disk DEVICE --yes' >&2
printf '%s\n' 'The installer implementation lives at overlay/usr/local/bin/datum-install.' >&2
exit 2
