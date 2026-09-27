#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$root/build.sh" configure
for script in "$root/build.sh" "$root/scripts/"*.sh "$root/overlay/usr/local/bin/"*; do
  sh -n "$script"
done
grep -q '^livecd/root_overlay: @ROOT_OVERLAY@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^boot/kernel/gentoo/sources: sys-kernel/gentoo-kernel$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^boot/kernel/gentoo/distkernel: yes$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^livecd/rm: /usr/src$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^livecd/fstype: squashfs$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'compressor xz -b 1M -X x86' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'guard_stage2_resume' "$root/build.sh"
grep -q 'boot/grub/grub.cfg' "$root/build.sh"
grep -q '^livecd/users: emergence$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^repos: @OVERLAY_REPOS@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^repos: @OVERLAY_REPOS@$' "$root/catalyst/specs/emergence-amd64.stage1.spec"
grep -q '^snapshot_treeish: @SNAPSHOT_NAME@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^snapshot_treeish: @SNAPSHOT_NAME@$' "$root/catalyst/specs/emergence-amd64.stage1.spec"
! grep -q '^livecd/depclean:' "$root/catalyst/specs/emergence-amd64.spec"
# The pinned Gentoo snapshot no longer ships these; they must resolve via the
# pinned overlays (or their documented replacements), never silently vanish.
grep -q '^media-fonts/nerdfonts$' "$root/packages/emergence"
! grep -q 'nerd-fonts$' "$root/packages/emergence"
! grep -q 'brightnessctl' "$root/packages/emergence"
grep -q '^app-admin/sudo$' "$root/packages/emergence"
grep -q '^sys-fs/dosfstools$' "$root/packages/emergence"
grep -q '^sys-boot/efibootmgr$' "$root/packages/emergence"
grep -q 'media-fonts/nerdfonts' "$root/config/package.use/emergence"
grep -q 'gui-wm/hyprland' "$root/config/package.accept_keywords/emergence"
test -f "$root/overlay/etc/hostname"
test -f "$root/branding/wallpaper.png"
! test -f "$root/branding/wallpaper.svg"
grep -q 'wallpaper.png' "$root/etc/skel/.config/hypr/hyprpaper.conf"
grep -q 'user = "greetd"' "$root/overlay/etc/greetd/config.toml"
grep -q 'user = "emergence"' "$root/overlay/etc/greetd/config.toml"
grep -q 'start-datum' "$root/overlay/etc/greetd/config.toml"
# Rice fidelity: the session runs the rice Lua config via its launcher.
test -f "$root/etc/skel/.config/hypr/hyprland.lua"
! test -f "$root/etc/skel/.config/hypr/hyprland.conf"
test -f "$root/etc/skel/.config/wofi/power.sh"
test -f "$root/etc/skel/.config/wofi/power.css"
test -f "$root/etc/skel/.config/yazi/theme.toml"
test -f "$root/etc/skel/.config/starship.toml"
test -x "$root/overlay/usr/local/bin/record-screen"
test -x "$root/overlay/usr/local/bin/screenshot"
test -x "$root/overlay/usr/local/bin/start-datum"
grep -q '^app-shells/starship$' "$root/packages/emergence"
# No rice path leaks into system paths: skel/overlay must not hardcode the
# reference home directory.
! grep -Rq '/home/dan' "$root/etc/skel" "$root/overlay"
grep -q 'useradd' "$root/catalyst/livecd-fsscript.sh"
grep -q "getent passwd emergence" "$root/catalyst/livecd-fsscript.sh"
test -f "$root/config/bashrc"
bash -n "$root/config/bashrc"
grep -q 'sys-kernel/gentoo-kernel' "$root/config/bashrc"
printf '%s\n' 'Static validation passed.'
