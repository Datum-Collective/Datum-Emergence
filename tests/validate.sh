#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$root/build.sh" configure
for script in "$root/build.sh" "$root/scripts/"*.sh "$root/overlay/usr/local/bin/"datum-*; do
  sh -n "$script"
done
grep -q '^livecd/root_overlay: @ROOT_OVERLAY@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^boot/kernel/gentoo/sources: sys-kernel/gentoo-kernel$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^livecd/users: emergence$' "$root/catalyst/specs/emergence-amd64.spec"
! grep -q '^livecd/depclean:' "$root/catalyst/specs/emergence-amd64.spec"
printf '%s\n' 'Static validation passed.'
