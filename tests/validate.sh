#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf '%s\n' "validate: $*" >&2; exit 1; }
# Negative assertions must not use a leading `!`: POSIX shells ignore
# `set -e` for commands whose status is inverted with `!`, so `! grep -q`
# can never fail the script (several historic checks were silently vacant
# for exactly this reason). These helpers are errexit-safe instead.
no_match() {
  # $1 = ERE pattern, rest = files/dirs that must not contain it.
  pat=$1; shift
  if grep -Rq "$pat" "$@"; then
    fail "forbidden pattern '$pat' found"
  fi
}
no_file() {
  # each argument is a path that must not exist.
  for f in "$@"; do
    if test -e "$f"; then
      fail "forbidden file exists: $f"
    fi
  done
}
"$root/build.sh" configure
for script in "$root/build.sh" "$root/scripts/"*.sh "$root/overlay/usr/local/bin/"*; do
  sh -n "$script"
done
grep -q '^livecd/root_overlay: @ROOT_OVERLAY@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^boot/kernel/gentoo/sources: sys-kernel/gentoo-kernel$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^boot/kernel/gentoo/distkernel: yes$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^livecd/rm: /usr/src$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^livecd/fstype: squashfs$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'compressor xz -b 1M -Xbcj x86' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'guard_stage2_resume' "$root/build.sh"
grep -q 'boot/grub/grub.cfg' "$root/build.sh"
# The ISO validator must resolve every grub-referenced kernel/initramfs path
# against the ISO file list: a prefix match once let a kernel-less ISO
# through (the initramfs gentoo.igz satisfied a naive "gentoo" pattern).
grep -q 'grub-referenced file' "$root/build.sh"
no_match '^livecd/users:' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^repos: @OVERLAY_REPOS@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^repos: @OVERLAY_REPOS@$' "$root/catalyst/specs/emergence-amd64.stage1.spec"
grep -q '^snapshot_treeish: @SNAPSHOT_NAME@$' "$root/catalyst/specs/emergence-amd64.spec"
grep -q '^snapshot_treeish: @SNAPSHOT_NAME@$' "$root/catalyst/specs/emergence-amd64.stage1.spec"
no_match '^livecd/depclean:' "$root/catalyst/specs/emergence-amd64.spec"
# The pinned Gentoo snapshot no longer ships these; they must resolve via the
# pinned overlays (or their documented replacements), never silently vanish.
grep -q '^media-fonts/nerdfonts$' "$root/packages/emergence"
no_match 'nerd-fonts$' "$root/packages/emergence"
no_match 'brightnessctl' "$root/packages/emergence"
grep -q '^app-admin/sudo$' "$root/packages/emergence"
grep -q '^sys-fs/dosfstools$' "$root/packages/emergence"
grep -q '^sys-boot/efibootmgr$' "$root/packages/emergence"
grep -q 'media-fonts/nerdfonts' "$root/config/package.use/emergence"
grep -q 'gui-wm/hyprland' "$root/config/package.accept_keywords/emergence"
test -f "$root/overlay/etc/hostname"
test -f "$root/branding/wallpaper.png"
no_file "$root/branding/wallpaper.svg"
grep -q 'wallpaper.png' "$root/etc/skel/.config/hypr/hyprpaper.conf"
grep -q 'user = "greetd"' "$root/overlay/etc/greetd/config.toml"
no_match '^\[initial_session\]' "$root/overlay/etc/greetd/config.toml"
no_match 'emergence' "$root/overlay/etc/greetd/config.toml"
grep -q 'start-datum' "$root/overlay/etc/greetd/config.toml"
# Rice fidelity: the session runs the rice Lua config via its launcher.
test -f "$root/etc/skel/.config/hypr/hyprland.lua"
no_file "$root/etc/skel/.config/hypr/hyprland.conf"
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
no_match '/home/dan' "$root/etc/skel" "$root/overlay"
# No preset live account anywhere: the ISO never creates any user.
no_match 'useradd.*emergence' "$root/catalyst/livecd-fsscript.sh"
no_match 'passwd -l emergence' "$root/catalyst/livecd-fsscript.sh"
no_match 'datum-firstboot-live' "$root/catalyst/livecd-fsscript.sh"
grep -q 'datum-installer.service' "$root/catalyst/livecd-fsscript.sh"
# No firstboot leftovers: the installer-first architecture has no live user,
# no live greeter flow, and no live-user markers.
no_file "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
no_file "$root/overlay/usr/local/bin/datum-firstboot-live"
no_match 'datum-live-user' "$root/overlay" "$root/catalyst" "$root/scripts" "$root/docs"
no_match 'firstboot-live' "$root/overlay" "$root/catalyst" "$root/scripts" "$root/docs"
# Installer owns tty1 on live media and restarts until an install completes.
test -f "$root/overlay/etc/systemd/system/datum-installer.service"
grep -q 'TTYPath=/dev/tty1' "$root/overlay/etc/systemd/system/datum-installer.service"
grep -q 'Conflicts=getty@tty1.service' "$root/overlay/etc/systemd/system/datum-installer.service"
grep -q 'Restart=always' "$root/overlay/etc/systemd/system/datum-installer.service"
grep -q 'StandardOutput=tty' "$root/overlay/etc/systemd/system/datum-installer.service"
# Live/install state markers are explicit files, never account names.
test -f "$root/overlay/etc/datum/live"
grep -q 'etc/datum/installed' "$root/overlay/usr/local/bin/datum-install"
# Probe must not hardcode a session username.
no_match 'emergence datum' "$root/overlay/usr/local/bin/datum-boot-probe"
no_match 'user.emergence' "$root/overlay/usr/local/bin/datum-boot-probe"
grep -q 'installer.installed-marker' "$root/overlay/usr/local/bin/datum-boot-probe"
grep -q 'gpu.dri' "$root/overlay/usr/local/bin/datum-boot-probe"
# Installed systems always use tuigreet + real PAM login, never autologin:
# the target validation explicitly rejects an initial_session block.
grep -q 'disable datum-installer.service' "$root/overlay/usr/local/bin/datum-install"
grep -q 'no initial_session autologin' "$root/overlay/usr/local/bin/datum-install"
# Session launcher must use the Hyprland watchdog (the direct-Hyprland
# invocation warns "launched without start-hyprland" and loses supervision).
grep -q 'start-hyprland' "$root/overlay/usr/local/bin/start-datum"
# Session environment contract: Wayland/desktop defaults plus a loud refusal
# outside a logind session, with journal evidence, never VT spam.
grep -q 'XDG_SESSION_TYPE:=wayland' "$root/overlay/usr/local/bin/start-datum"
grep -q 'XDG_CURRENT_DESKTOP:=Hyprland' "$root/overlay/usr/local/bin/start-datum"
grep -q 'XDG_RUNTIME_DIR is unset' "$root/overlay/usr/local/bin/start-datum"
# Compositor stdin/session hardening (established by experiment): Hyprland
# deadlocks when it inherits a live login tty as stdin, and aborts with no
# VT at all -- so the launcher detaches stdin and refuses VT-less sessions
# with a diagnostic instead of a coredump.
grep -q '< /dev/null' "$root/overlay/usr/local/bin/start-datum"
grep -q 'no virtual terminal in this session' "$root/overlay/usr/local/bin/start-datum"
# This Hyprland build's hyprctl takes Lua chunks: a bare `dispatch exit`
# interpolates to hl.dispatch(exit) and fails; the power menu must use the
# verified hl.dsp.exit() form.
grep -q 'hl.dsp.exit()' "$root/etc/skel/.config/wofi/power.sh"
no_match 'hyprctl dispatch exit$' "$root/etc/skel/.config/wofi/power.sh"
# The boot probe talks to the compositor as root-with-env (no sudo rule
# ships on the image; `sudo -n -u` always failed silently).
no_match 'sudo -n -u' "$root/overlay/usr/local/bin/datum-boot-probe"
grep -q 'HYPRLAND_INSTANCE_SIGNATURE=$SIG' "$root/overlay/usr/local/bin/datum-boot-probe"
# Quiet deterministic boot: kernel cmdline silences status, the installer
# owns the live VT, the probe never blocks the login path.
grep -q 'livecd/bootargs' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'systemd.show_status=no' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'switch = true' "$root/overlay/etc/greetd/config.toml"
grep -q 'systemd-vconsole-setup' "$root/overlay/etc/systemd/system/datum-installer.service"
grep -q 'StandardOutput=null' "$root/overlay/etc/systemd/system/datum-boot-probe.service"
grep -q 'After=multi-user.target' "$root/overlay/etc/systemd/system/datum-boot-probe.service"
# Guided installer contract: menu, keyboard, account, host/timezone, summary,
# disk with partitions shown, deliberate confirmation, quiet engine.
grep -q 'tui_menu' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Step 1/7: keyboard' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Step 2/7: user account' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Step 7/7: confirm' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Installation complete' "$root/overlay/usr/local/bin/datum-install"
grep -q 'run_engine' "$root/overlay/usr/local/bin/datum-install"
grep -q 'runlog' "$root/overlay/usr/local/bin/datum-install"
grep -q 'vconsole.conf' "$root/overlay/usr/local/bin/datum-install"
grep -q 'GRUB_CMDLINE_LINUX' "$root/overlay/usr/local/bin/datum-install"
# Installer stages, logging, and target validation (no fake percentages,
# no credential logging, self-check before reboot).
grep -q 'STAGE_TOTAL=8' "$root/overlay/usr/local/bin/datum-install"
grep -q 'emergence-installer.log' "$root/overlay/usr/local/bin/datum-install"
grep -q 'validate_target' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Validating installation' "$root/overlay/usr/local/bin/datum-install"
# The installer TUI is never a raw shell on error.
grep -q 'DATUM  EMERGENCE' "$root/overlay/usr/local/bin/datum-install"
# Live/install user lifecycle contract: the target gets exactly one
# permanent user; no live identity can leak (there is none on live media).
grep -q 'STRAY_USERS' "$root/overlay/usr/local/bin/datum-install"
grep -q 'MNT/usr/local/bin/datum-install' "$root/overlay/usr/local/bin/datum-install"
no_match 'passwd emergence' "$root/overlay/usr/local/bin/datum-install"
no_match 'user = "emergence"' "$root/overlay/usr/local/bin/datum-install"
no_match 'datum-firstboot.service' "$root/overlay/usr/local/bin/datum-boot-probe"
no_match 'getent passwd emergence' "$root/overlay/usr/local/bin/datum-boot-probe"
# Installer test harnesses: the verdict must read the serial log, and drivers
# must wait for the probe instead of killing QEMU right after typing.
grep -q 'DATUM_PROBE end' "$root/scripts/test-installer-tui.sh"
grep -q 'DATUM_PROBE end' "$root/scripts/test-install.sh"
# The automated engine path is driven over a TCP serial console (unix serial
# delivered zero bytes here; monitor sendkey cannot reach a serial shell)
# with telnet filtering and echo-safe completion tags.
grep -q 'python3 -u - ' "$root/scripts/test-install.sh"
grep -q 'python3 -u - ' "$root/scripts/test-installer-tui.sh"
# Both automated install harnesses refuse to start on a cramped /tmp
# (a full tmpfs once produced a flaky engine failure instead of an error).
grep -q 'less than 6GiB free on /tmp' "$root/scripts/test-install.sh"
grep -q 'less than 6GiB free on /tmp' "$root/scripts/test-installer-tui.sh"
# Driver statuses must be captured errexit-safely (`|| RC=$?` on the
# invocation line): a bare `RC=$?` after an embedded python driver never
# runs under `set -e`, so failures skipped the verdict tail and cleaned
# the workdir with no message.
grep -q "|| RC=\$?" "$root/scripts/test-install.sh"
grep -q "|| RC_B=\$?" "$root/scripts/test-install.sh"
grep -q "|| RC=\$?" "$root/scripts/test-installer-tui.sh"
! grep -q '^RC=\$?' "$root/scripts/test-install.sh"
! grep -q '^RC_B=\$?' "$root/scripts/test-install.sh"
! grep -q '^RC=\$?' "$root/scripts/test-installer-tui.sh"
grep -q 'telnet:127.0.0.1' "$root/scripts/test-install.sh"
grep -q 'installed Datum Emergence' "$root/scripts/test-install.sh"
grep -q 'loop,ro,offset' "$root/scripts/test-install.sh"
# The guest transcript must survive the run in the invoking directory even
# if the workdir is cleaned before the verdict runs.
grep -q 'emergence-install-serial-live.log' "$root/scripts/test-install.sh"
# Installed systems use real tuigreet login (no autologin): Phase B types it
# through the QEMU monitor like a human would.
grep -q 'installed tuigreet login' "$root/scripts/test-install.sh"
test -f "$root/config/bashrc"
bash -n "$root/config/bashrc"
grep -q 'sys-kernel/gentoo-kernel' "$root/config/bashrc"
printf '%s\n' 'Static validation passed.'
