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
! grep -q '^livecd/users:' "$root/catalyst/specs/emergence-amd64.spec"
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
! grep -q 'initial_session' "$root/overlay/etc/greetd/config.toml"
! grep -q 'emergence' "$root/overlay/etc/greetd/config.toml"
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
# No preset live account anywhere: firstboot creates the real user.
! grep -q 'useradd.*emergence' "$root/catalyst/livecd-fsscript.sh"
! grep -q 'passwd -l emergence' "$root/catalyst/livecd-fsscript.sh"
grep -q 'datum-firstboot-live' "$root/catalyst/livecd-fsscript.sh"
# Firstboot service, script, and state contract.
test -f "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
test -f "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'Before=greetd.service' "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
grep -q 'TTYPath=/dev/tty1' "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
grep -q 'datum-live-user' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'datum-live-user' "$root/overlay/usr/local/bin/datum-boot-probe"
# Probe must not hardcode a session username.
! grep -q 'emergence datum' "$root/overlay/usr/local/bin/datum-boot-probe"
! grep -q 'user.emergence' "$root/overlay/usr/local/bin/datum-boot-probe"
grep -q 'firstboot.status' "$root/overlay/usr/local/bin/datum-boot-probe"
# Installer keeps installed systems on the permanent-user flow.
grep -q 'disable datum-firstboot-live' "$root/overlay/usr/local/bin/datum-install"
# Session launcher must use the Hyprland watchdog (the direct-Hyprland
# invocation warns "launched without start-hyprland" and loses supervision).
grep -q 'start-hyprland' "$root/overlay/usr/local/bin/start-datum"
# Session environment contract (Failure C): Wayland/desktop defaults plus a
# loud refusal outside a logind session, with journal evidence, never VT spam.
grep -q 'XDG_SESSION_TYPE:=wayland' "$root/overlay/usr/local/bin/start-datum"
grep -q 'XDG_CURRENT_DESKTOP:=Hyprland' "$root/overlay/usr/local/bin/start-datum"
grep -q 'XDG_RUNTIME_DIR is unset' "$root/overlay/usr/local/bin/start-datum"
# Quiet deterministic boot (Failures A/B): kernel cmdline silences status,
# firstboot owns the VT, probe never blocks the login path.
grep -q 'livecd/bootargs' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'systemd.show_status=no' "$root/catalyst/specs/emergence-amd64.spec"
grep -q 'switch = true' "$root/overlay/etc/greetd/config.toml"
grep -q 'systemd-vconsole-setup' "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
grep -q 'chvt 1' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'StandardOutput=null' "$root/overlay/etc/systemd/system/datum-boot-probe.service"
grep -q 'After=multi-user.target' "$root/overlay/etc/systemd/system/datum-boot-probe.service"
# Guided installer contract: no-arg TUI (account/host/timezone/disk/confirm),
# masked passwords, live-media hiding, explicit INSTALL confirmation.
grep -q 'With no arguments and a terminal attached' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Step 1/5: account' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Step 5/5: confirm' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Type INSTALL to proceed' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Installation complete' "$root/overlay/usr/local/bin/datum-install"
# Installer stages, logging, and target validation (no fake percentages,
# no credential logging, self-check before reboot).
grep -q 'STAGE_TOTAL=8' "$root/overlay/usr/local/bin/datum-install"
grep -q 'emergence-installer.log' "$root/overlay/usr/local/bin/datum-install"
grep -q 'validate_target' "$root/overlay/usr/local/bin/datum-install"
grep -q 'Validating installation' "$root/overlay/usr/local/bin/datum-install"
# Firstboot is a branded TUI loop, never a raw shell on error.
grep -q 'DATUM  EMERGENCE' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'show_error' "$root/overlay/usr/local/bin/datum-firstboot-live"
# Live/install user lifecycle contract.
grep -q 'PERSISTENT_STATE_FILE=/etc/datum/live-user' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'no-block start greetd' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'starting greetd' "$root/overlay/usr/local/bin/datum-firstboot-live"
grep -q 'StandardOutput=tty' "$root/overlay/etc/systemd/system/datum-firstboot-live.service"
grep -q '/etc/datum/live-user' "$root/overlay/usr/local/bin/datum-install"
grep -q 'STRAY_USERS' "$root/overlay/usr/local/bin/datum-install"
grep -q 'initial_session' "$root/overlay/usr/local/bin/datum-install"
grep -q 'MNT/usr/local/bin/datum-firstboot-live' "$root/overlay/usr/local/bin/datum-install"
! grep -q 'passwd emergence' "$root/overlay/usr/local/bin/datum-install"
! grep -q 'user = "emergence"' "$root/overlay/usr/local/bin/datum-install"
! grep -q 'datum-firstboot.service' "$root/overlay/usr/local/bin/datum-boot-probe"
grep -q 'installer.live-user-removed' "$root/overlay/usr/local/bin/datum-boot-probe"
! grep -q 'getent passwd emergence' "$root/overlay/usr/local/bin/datum-boot-probe"
# Firstboot test harnesses: verdict must read the serial log before cleanup,
# and the driver must wait for the probe instead of killing QEMU right after
# typing the login.
grep -q 'DATUM_PROBE end' "$root/scripts/test-iso.sh"
# Firstboot mode boots its own QEMU; the plain CI boot block is ci-only.
grep -q 'if test "$MODE" = ci; then' "$root/scripts/test-iso.sh"
grep -q 'Simulate the live firstboot lifecycle' "$root/scripts/test-install.sh"
# Phase A uses a TCP serial console (unix serial delivered zero bytes here;
# monitor sendkey cannot reach a serial shell) with telnet filtering and
# echo-safe completion tags.
grep -q 'telnet:127.0.0.1' "$root/scripts/test-install.sh"
grep -q 'installed Datum Emergence' "$root/scripts/test-install.sh"
grep -q 'loop,ro,offset' "$root/scripts/test-install.sh"
! grep -q 'unix:$SOCK' "$root/scripts/test-install.sh"
# The guest transcript must survive the run in the invoking directory even
# if the workdir is cleaned before the verdict runs.
grep -q 'emergence-install-serial-live.log' "$root/scripts/test-install.sh"
test -f "$root/config/bashrc"
bash -n "$root/config/bashrc"
grep -q 'sys-kernel/gentoo-kernel' "$root/config/bashrc"
printf '%s\n' 'Static validation passed.'
