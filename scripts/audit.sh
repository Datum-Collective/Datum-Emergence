#!/bin/sh
set -eu
destination=${1:-/tmp/emergence-audit}
test -d "$destination" || { printf '%s\n' "audit directory not found: $destination" >&2; exit 1; }
printf '%s\n' "Reference audit is available at $destination"
for f in system.txt emerge-info.txt world.txt tooling-and-desktop-packages.txt hardware-boot.txt; do test -f "$destination/$f" && printf '%s\n' "  $destination/$f"; done
