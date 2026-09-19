#!/bin/sh
# Datum Emergence's Catalyst entrypoint. This never edits the host OS.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work="$root/work"
dist="$root/dist"
version_stamp=${EMERGENCE_VERSION_STAMP:-$(date -u +%Y%m%d)}

die() { printf '%s\n' "build: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need_root() { test "$(id -u)" -eq 0 || die "stage and ISO builds require root (Catalyst mounts/chroots); rerun with sudo -E"; }

configure() { "$root/scripts/configure.sh"; }

prepare_inputs() {
  : "${EMERGENCE_STAGE3:?set EMERGENCE_STAGE3 to a verified stage3 tarball}"
  : "${EMERGENCE_STAGE3_SHA512:?set EMERGENCE_STAGE3_SHA512 to the verified SHA512 of EMERGENCE_STAGE3}"
  : "${EMERGENCE_PORTAGE_TREE:?set EMERGENCE_PORTAGE_TREE to a pinned Gentoo git checkout}"
  test -f "$EMERGENCE_STAGE3" || die "stage3 not found: $EMERGENCE_STAGE3"
  test -d "$EMERGENCE_PORTAGE_TREE/.git" || die "not a Git checkout: $EMERGENCE_PORTAGE_TREE"
  need git
  need sha512sum
  actual_stage3_sha512=$(sha512sum "$EMERGENCE_STAGE3" | awk '{print $1}')
  test "$actual_stage3_sha512" = "$EMERGENCE_STAGE3_SHA512" || die "stage3 SHA512 does not match EMERGENCE_STAGE3_SHA512"
  test -z "$(git -C "$EMERGENCE_PORTAGE_TREE" status --porcelain)" || die "Portage checkout has uncommitted changes"
  snapshot_name=$(git -C "$EMERGENCE_PORTAGE_TREE" rev-parse HEAD)
  stage3_name=$(basename "$EMERGENCE_STAGE3")
  packages=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$root/packages/emergence" | tr '\n' ' ')
  mkdir -p "$work/catalyst/builds/datum" "$work/catalyst/repos" "$work/generated" "$work/root-overlay"
  cp -f -- "$EMERGENCE_STAGE3" "$work/catalyst/builds/datum/$stage3_name"
  rm -rf "$work/catalyst/repos/gentoo.git"
  git clone --bare --no-local "$EMERGENCE_PORTAGE_TREE" "$work/catalyst/repos/gentoo.git"
  rm -rf "$work/root-overlay"
  cp -a "$root/overlay" "$work/root-overlay"
  mkdir -p "$work/root-overlay/etc/skel" "$work/root-overlay/usr/share/backgrounds/datum-emergence"
  cp -a "$root/etc/skel/." "$work/root-overlay/etc/skel/"
  cp -a "$root/branding/wallpaper.svg" "$work/root-overlay/usr/share/backgrounds/datum-emergence/"
  chmod 0755 "$work/root-overlay/usr/local/bin/"datum-*
  export snapshot_name stage3_name packages actual_stage3_sha512
}

render() {
  template=$1 output=$2
  sed -e "s|@WORKDIR@|$work|g" -e "s|@PROJECT_ROOT@|$root|g" \
      -e "s|@ROOT_OVERLAY@|$work/root-overlay|g" -e "s|@VERSION_STAMP@|$version_stamp|g" \
      -e "s|@STAGE3_NAME@|$stage3_name|g" -e "s|@SNAPSHOT_NAME@|$snapshot_name|g" \
      -e "s|@ISO_PATH@|$dist/emergence-amd64.iso|g" -e "s|@PACKAGES@|$packages|g" "$template" > "$output"
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

run_stage() { catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage1.spec"; }

stage() { configure; prepare_catalyst; run_stage; }

iso() {
  configure; prepare_catalyst
  test -n "$(stage_artifact)" || run_stage
  mkdir -p "$dist"
  catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage2.spec"
  validate_iso
  build_info
}

validate_iso() {
  test -s "$dist/emergence-amd64.iso" || die "Catalyst finished without the expected ISO"
  file "$dist/emergence-amd64.iso" | grep -qi 'ISO 9660' || die "output is not an ISO 9660 image"
  if command -v xorriso >/dev/null 2>&1; then xorriso -indev "$dist/emergence-amd64.iso" -toc; fi
}

build_info() {
  { printf 'project_commit=%s\n' "$(git -C "$root" rev-parse HEAD 2>/dev/null || printf uncommitted)"
    printf 'stage3=%s\nstage3_sha512=%s\nportage_snapshot=%s\ncatalyst=%s\narchitecture=amd64\nprofile=%s\n' "$stage3_name" "$actual_stage3_sha512" "$snapshot_name" "$(catalyst -V)" 'default/linux/amd64/23.0/desktop/systemd'
    sha256sum "$root/packages/emergence" | sed 's/^/package_manifest_sha256=/'
  } > "$dist/emergence-build-info.txt"
}

test_iso() { "$root/scripts/test-iso.sh" "$dist/emergence-amd64.iso"; }

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
  all) configure; prepare_catalyst; run_stage; mkdir -p "$dist"; catalyst -c "$work/generated/catalyst.conf" -f "$work/generated/stage2.spec"; validate_iso; build_info ;;
  clean) clean "${2:-}" ;;
  *) printf '%s\n' 'usage: ./build.sh {audit|configure|stage|iso|test|all|clean --yes}' >&2; exit 2 ;;
esac
