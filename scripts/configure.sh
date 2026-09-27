#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf '%s\n' "configure: $*" >&2; exit 1; }
for f in packages/emergence config/make.conf catalyst/catalyst.conf catalyst/specs/emergence-amd64.stage1.spec catalyst/specs/emergence-amd64.spec; do test -f "$root/$f" || fail "missing $f"; done
for d in config/package.use config/package.accept_keywords config/package.mask config/package.unmask config/package.license config/repos.conf etc/skel overlay; do test -d "$root/$d" || fail "missing $d"; done
command -v python3 >/dev/null 2>&1 || fail "python3 is required for configuration validation"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$root/etc/skel/.config/waybar/config" || fail "invalid Waybar JSON"
python3 -c 'import tomllib, sys; tomllib.load(open(sys.argv[1], "rb"))' "$root/catalyst/catalyst.conf" || fail "invalid Catalyst TOML"
python3 -c 'import tomllib, sys; tomllib.load(open(sys.argv[1], "rb"))' "$root/overlay/etc/greetd/config.toml" || fail "invalid greetd TOML"
if ! awk '/^[[:space:]]*($|#)/ { next } !/^[a-z0-9+_.-]+\/[a-z0-9+_.-]+(:[a-z0-9+_.-]+)?$/ { exit 1 }' "$root/packages/emergence"; then fail "package manifest contains an invalid atom"; fi
secret_pattern='BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|password[[:space:]]*=[[:space:]]*[^#[:space:]]+'
machine_pattern='/home/(dan|[^$])|hades|eDP-1|nvidia'
# work/, dist/ and build/ hold generated build output (including the pinned
# overlay clones, which legitimately contain words like "password" in init
# scripts). The leak scan covers intentional source, not build products.
if command -v rg >/dev/null 2>&1; then
  if rg -n --hidden -i "$secret_pattern" "$root" --glob '!.git/**' --glob '!work/**' --glob '!dist/**' --glob '!build/**' --glob '!README.md' --glob '!scripts/configure.sh'; then fail "possible secret found"; fi
  if rg -n "$machine_pattern" "$root/etc" "$root/overlay" "$root/config"; then fail "machine-specific reference leaked"; fi
else
  if grep -RInE --exclude-dir=.git --exclude-dir=work --exclude-dir=dist --exclude-dir=build --exclude=README.md --exclude=configure.sh "$secret_pattern" "$root"; then fail "possible secret found"; fi
  if grep -RInE "$machine_pattern" "$root/etc" "$root/overlay" "$root/config"; then fail "machine-specific reference leaked"; fi
fi
printf '%s\n' 'Configuration is structurally valid and contains no detected reference-machine paths or common secrets.'
