#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$root/build.sh" configure
for script in "$root/build.sh" "$root/scripts/"*.sh "$root/overlay/usr/local/bin/"datum-*; do
  sh -n "$script"
done
printf '%s\n' 'Static validation passed.'
