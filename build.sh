#!/bin/sh
# Datum Emergence's Catalyst entrypoint. This never edits the host OS.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Catalyst builds run as root while the input checkouts are typically owned by
# a regular user. Scope Git's ownership guard off for build subprocesses only
# (no host gitconfig is touched); the checkouts themselves are still verified
# clean and pinned by hash before use.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0='*'
work="$root/work"
dist="$root/dist"
version_stamp=${EMERGENCE_VERSION_STAMP:-$(date -u +%Y%m%d)}
# Parallel emerge jobs (also becomes MAKEOPTS -j). Default 6 is conservative
# for large C++/Rust packages on modest RAM; raise on bigger builders.
jobs=${EMERGENCE_JOBS:-6}

die() { printf '%s\n' "build: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need_root() { test "$(id -u)" -eq 0 || die "stage and ISO builds require root (Catalyst mounts/chroots); rerun with sudo -E"; }

configure() { "$root/scripts/configure.sh"; }

prepare_inputs() {
  : "${EMERGENCE_STAGE3:?set EMERGENCE_STAGE3 to a verified stage3 tarball}"
  : "${EMERGENCE_STAGE3_SHA512:?set EMERGENCE_STAGE3_SHA512 to the verified SHA512 of EMERGENCE_STAGE3}"
  : "${EMERGENCE_PORTAGE_TREE:?set EMERGENCE_PORTAGE_TREE to a pinned Gentoo git checkout}"
  # Pinned overlays. The pinned Gentoo snapshot no longer carries the Hyprland
  # stack or several desktop utilities (see README/docs), so two reviewed
  # overlays are pinned at fixed commits. Defaults are the commits tested on
  # the reference machine; override only with another reviewed commit.
  EMERGENCE_GURU_TREE=${EMERGENCE_GURU_TREE:-/var/db/repos/guru}
  EMERGENCE_HYPROVERLAY_TREE=${EMERGENCE_HYPROVERLAY_TREE:-/var/db/repos/hyproverlay}
  EMERGENCE_GURU_COMMIT=${EMERGENCE_GURU_COMMIT:-7a663f8a4a421866a67d7b43c24dbef5cf291756}
  EMERGENCE_HYPROVERLAY_COMMIT=${EMERGENCE_HYPROVERLAY_COMMIT:-f549c349eeb6ede7852cd0c56907449b055a7a0c}
  test -f "$EMERGENCE_STAGE3" || die "stage3 not found: $EMERGENCE_STAGE3"
  test -d "$EMERGENCE_PORTAGE_TREE/.git" || die "not a Git checkout: $EMERGENCE_PORTAGE_TREE"
  test -d "$EMERGENCE_GURU_TREE/.git" || die "not a Git checkout: $EMERGENCE_GURU_TREE"
  test -d "$EMERGENCE_HYPROVERLAY_TREE/.git" || die "not a Git checkout: $EMERGENCE_HYPROVERLAY_TREE"
  need git
  need sha512sum
  actual_stage3_sha512=$(sha512sum "$EMERGENCE_STAGE3" | awk '{print $1}')
  test "$actual_stage3_sha512" = "$EMERGENCE_STAGE3_SHA512" || die "stage3 SHA512 does not match EMERGENCE_STAGE3_SHA512"
  test -z "$(git -C "$EMERGENCE_PORTAGE_TREE" status --porcelain)" || die "Portage checkout has uncommitted changes"
  test -z "$(git -C "$EMERGENCE_GURU_TREE" status --porcelain)" || die "guru checkout has uncommitted changes"
  test -z "$(git -C "$EMERGENCE_HYPROVERLAY_TREE" status --porcelain)" || die "hyproverlay checkout has uncommitted changes"
  # The pinned commits must actually exist in the given checkouts.
  git -C "$EMERGENCE_GURU_TREE" cat-file -e "$EMERGENCE_GURU_COMMIT^{commit}" 2>/dev/null || die "guru commit not found: $EMERGENCE_GURU_COMMIT"
  git -C "$EMERGENCE_HYPROVERLAY_TREE" cat-file -e "$EMERGENCE_HYPROVERLAY_COMMIT^{commit}" 2>/dev/null || die "hyproverlay commit not found: $EMERGENCE_HYPROVERLAY_COMMIT"
  snapshot_name=$(git -C "$EMERGENCE_PORTAGE_TREE" rev-parse HEAD)
  guru_commit=$(git -C "$EMERGENCE_GURU_TREE" rev-parse "$EMERGENCE_GURU_COMMIT")
  hyproverlay_commit=$(git -C "$EMERGENCE_HYPROVERLAY_TREE" rev-parse "$EMERGENCE_HYPROVERLAY_COMMIT")
  stage3_name=$(basename "$EMERGENCE_STAGE3")
  manifest_packages=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$root/packages/emergence" | tr '\n' ' ')
  # No @world update: the stage3 is a console-only system (no x11/media/mesa
  # stack), so every graphical package is pulled fresh under the target
  # desktop/systemd profile, and every manifest atom is explicitly updated.
  # A full @world update inside the image build would couple the image to
  # unrelated tree drift (e.g. perl subslot bumps between the stage3 date and
  # the snapshot date) and fail on conflicts no image change can fix.
  packages="$manifest_packages"
  mkdir -p "$work/catalyst/builds/datum" "$work/catalyst/repos" "$work/generated" "$work/root-overlay" "$work/distfiles" "$work/logs"
  cp -f -- "$EMERGENCE_STAGE3" "$work/catalyst/builds/datum/$stage3_name"
  # NOTE: plain --bare (no --no-local) so Git hardlinks objects from the local
  # source instead of copying ~10 GB. The source checkout is verified clean
  # above and Catalyst only reads from the clone (git archive).
  rm -rf "$work/catalyst/repos/gentoo.git"
  git clone --bare "$EMERGENCE_PORTAGE_TREE" "$work/catalyst/repos/gentoo.git"
  # Isolated overlay checkouts at the pinned commits. Catalyst bind-mounts
  # these into the chroot, so build-local clones (not the host's live repos)
  # keep the build reproducible and keep any in-chroot writes off the host.
  rm -rf "$work/catalyst/repos/guru" "$work/catalyst/repos/hyproverlay"
  git clone -q "$EMERGENCE_GURU_TREE" "$work/catalyst/repos/guru"
  git -C "$work/catalyst/repos/guru" checkout -q "$guru_commit"
  git clone -q "$EMERGENCE_HYPROVERLAY_TREE" "$work/catalyst/repos/hyproverlay"
  git -C "$work/catalyst/repos/hyproverlay" checkout -q "$hyproverlay_commit"
  overlay_repos="$work/catalyst/repos/guru $work/catalyst/repos/hyproverlay"
  # Every manifest atom must resolve in exactly the trees Catalyst will see.
  # This fails fast here instead of hours into a Catalyst emerge.
  for atom in $manifest_packages; do
    found=0
    for tree in "$EMERGENCE_PORTAGE_TREE" "$work/catalyst/repos/guru" "$work/catalyst/repos/hyproverlay"; do
      if test -d "$tree/$atom"; then found=1; break; fi
    done
    test "$found" -eq 1 || die "manifest atom not found in pinned trees: $atom"
  done
  rm -rf "$work/root-overlay"
  cp -a "$root/overlay" "$work/root-overlay"
  mkdir -p "$work/root-overlay/etc/skel" "$work/root-overlay/usr/share/backgrounds/datum-emergence"
  cp -a "$root/etc/skel/." "$work/root-overlay/etc/skel/"
  cp -a "$root/etc/emergence/." "$work/root-overlay/etc/emergence/"
  # The wallpaper is the canonical rice asset (branding/wallpaper.png, a
  # byte-identical copy of the rice repository's wallpapers/3.png). PNG is
  # hyprpaper's best-tested path, so it ships as-is.
  cp -a "$root/branding/wallpaper.png" "$work/root-overlay/usr/share/backgrounds/datum-emergence/"
  chmod 0755 "$work/root-overlay/usr/local/bin/"*
  export snapshot_name stage3_name packages overlay_repos guru_commit hyproverlay_commit actual_stage3_sha512
}

render() {
  template=$1 output=$2
  sed -e "s|@WORKDIR@|$work|g" -e "s|@PROJECT_ROOT@|$root|g" \
      -e "s|@ROOT_OVERLAY@|$work/root-overlay|g" -e "s|@VERSION_STAMP@|$version_stamp|g" \
      -e "s|@STAGE3_NAME@|$stage3_name|g" -e "s|@SNAPSHOT_NAME@|$snapshot_name|g" \
      -e "s|@OVERLAY_REPOS@|$overlay_repos|g" \
      -e "s|@ISO_PATH@|$dist/emergence-amd64.iso|g" -e "s|@PACKAGES@|$packages|g" -e "s|@JOBS@|$jobs|g" "$template" > "$output"
}

prepare_catalyst() {
  need catalyst; need_root; prepare_inputs
  render "$root/catalyst/catalyst.conf" "$work/generated/catalyst.conf"
  render "$root/catalyst/specs/emergence-amd64.stage1.spec" "$work/generated/stage1.spec"
  render "$root/catalyst/specs/emergence-amd64.spec" "$work/generated/stage2.spec"
  catalyst -c "$work/generated/catalyst.conf" --snapshot "$snapshot_name"
}

stage_artifact() {
  find "$work/catalyst/builds/datum" -maxdepth 1 -type f \
    -name "livecd-stage1-amd64-$version_stamp.tar.*" ! -name '*.DIGESTS' ! -name '*.CONTENTS*' -print -quit
}

# Catalyst's livecd-stage2 unconditionally empties its target (staging) dir
# during startup, but autoresume skips the bootloader step that puts the
# kernel, initramfs and grub.cfg there. Resuming a stage2 run that already
# passed bootloader therefore produces a kernel-less ISO without any error.
# If such state exists, wipe the stage2 work area first so the run below is
# a fresh, complete stage2 in a single invocation.
guard_stage2_resume() {
  need_root
  resume_dir="$work/catalyst/tmp/datum/.autoresume-livecd-stage2-amd64-$version_stamp"
  if test -f "$resume_dir/bootloader"; then
    printf '%s\n' "build: stale stage2 state detected (previous run passed bootloader); restarting stage2 fresh" >&2
    rm -rf "$work/catalyst/tmp/datum/livecd-stage2-amd64-$version_stamp" \
           "$work/catalyst/tmp/datum/livecd-stage2-amd64-$version_stamp.lock" \
           "$resume_dir"
  fi
}

run_stage() { catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage1.spec"; }

stage() { configure; prepare_catalyst; run_stage; }

iso() {
  configure; guard_stage2_resume; prepare_catalyst
  test -n "$(stage_artifact)" || run_stage
  mkdir -p "$dist"
  catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage2.spec"
  validate_iso
  build_info
}

validate_iso() {
  test -s "$dist/emergence-amd64.iso" || die "Catalyst finished without the expected ISO"
  file "$dist/emergence-amd64.iso" | grep -qi 'ISO 9660' || die "output is not an ISO 9660 image"
  if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$dist/emergence-amd64.iso" -toc
    # A kernel-less ISO is the known failure mode of a resumed stage2
    # (staging dir wiped, bootloader step skipped). Refuse it loudly.
    iso_files=$(xorriso -indev "$dist/emergence-amd64.iso" -find / 2>/dev/null)
    printf '%s\n' "$iso_files" | grep -q '/boot/grub/grub.cfg' || die "ISO has no /boot/grub/grub.cfg (stale stage2 resume?)"
    printf '%s\n' "$iso_files" | grep -Eq '/boot/(gentoo|vmlinuz[^ ]*|kernel[^ ]*)' || die "ISO has no kernel in /boot (stale stage2 resume?)"
  fi
}

build_info() {
  project_commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || printf uncommitted)
  if test -n "$(git -C "$root" status --porcelain 2>/dev/null)"; then project_commit="$project_commit-dirty"; fi
  { printf 'project_commit=%s\n' "$project_commit"
    printf 'stage3=%s\nstage3_sha512=%s\nportage_snapshot=%s\nguru_commit=%s\nhyproverlay_commit=%s\ncatalyst=%s\narchitecture=amd64\nprofile=%s\n' "$stage3_name" "$actual_stage3_sha512" "$snapshot_name" "$guru_commit" "$hyproverlay_commit" "$(catalyst -V)" 'default/linux/amd64/23.0/desktop/systemd'
    sha256sum "$root/packages/emergence" | sed 's/^/package_manifest_sha256=/'
  } > "$dist/emergence-build-info.txt"
}

test_iso() { "$root/scripts/test-iso.sh" "$dist/emergence-amd64.iso"; }
# The live ISO has no usable account until the firstboot setup creates one,
# so a bare boot can never reach a desktop: CI drives the real lifecycle
# (firstboot typing, tuigreet login, desktop) through the actual GRUB boot
# path. Test credentials live only in this invocation, never in the image.
test_ci() { "$root/scripts/test-iso.sh" --firstboot "citest:citest123" --wait "${EMERGENCE_BOOT_WAIT:-900}" "$dist/emergence-amd64.iso"; }
test_firstboot() { "$root/scripts/test-firstboot-checks.sh" --scenario "${1:-all}" "$dist/emergence-amd64.iso"; }
test_install() { "$root/scripts/test-install.sh" --iso "$dist/emergence-amd64.iso"; }

clean() {
  test "${1:-}" = --yes || die "refusing to remove build artifacts; use './build.sh clean --yes'"
  rm -rf "$work" "$dist" "$root/build"
}

case ${1:-help} in
  audit) "$root/scripts/audit.sh" ;;
  configure) configure ;;
  stage) stage ;;
  iso) iso ;;
  test) test_iso ;;
  test-ci) test_ci ;;
  test-firstboot) test_firstboot "${2:-all}" ;;
  test-install) test_install ;;
  all) configure; prepare_catalyst; run_stage; mkdir -p "$dist"; guard_stage2_resume; catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage2.spec"; validate_iso; build_info ;;
  clean) clean "${2:-}" ;;
  *) printf '%s\n' 'usage: ./build.sh {audit|configure|stage|iso|test|test-ci|test-firstboot [scenario]|test-install|all|clean --yes}' >&2; exit 2 ;;
esac
