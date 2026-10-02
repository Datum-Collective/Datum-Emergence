# Hyprland startup failure: root-cause evidence log

Date: 2026-09-29. Image: Datum Emergence v0.1.4 ISO
(`b2b2a9cc67fd1435fd20106abbcfd4c7b3ddce60e4dcab422498bdea61546611`).
Hyprland 0.56.2 (commit efb5099). Method: QEMU TCG + OVMF, full systemd
boot, firstboot typed via QEMU monitor, tuigreet login typed via monitor,
forensics over a serial-console login as the same user (full ASCII).

## Failing case: QEMU `-vga vmware`

Kernel: `vmwgfx 0000:00:02.0: [drm] *ERROR* vmwgfx seems to be running on
an unsupported hypervisor` ... `probe with driver vmwgfx failed with
error -38`. Result: `/dev/dri` does not exist at all.

Session (all correct):
`uid=1000 groups=wheel,audio,video,render,input,plugdev`,
logind sessions for greeter (tty1) and user, `/run/user/1000` owned
correctly, user manager running, start-datum marker in user journal:
`launching Hyprland for <user> runtime=/run/user/1000 session=tty`.

Failure: `systemd-coredump: Process 1210 (Hyprland) of user 1000 dumped
core` — `Signal: 6 (ABRT)`, `Command Line: Hyprland --watchdog-fd 4
--config /home/<user>/.config/hypr/hyprland.lua` (correct launcher path
through start-hyprland). No Wayland socket, no hyprland.log, session
returns to the greeter. A 6-line minimal config
(`hl.monitor({output="", mode="preferred", position="auto", scale="1"})`)
fails identically: coredump, no socket, no log.

## Working case: QEMU std VGA and virtio-gpu

`bochs-drm` binds (`Kernel driver in use: bochs-drm`), `/dev/dri/card0`
exists, same rice config, same session path: Hyprland RUNNING, Wayland
socket `/run/user/1000/wayland-1`, `hyprland.monitors=Monitor Virtual-1`,
no coredump. virtio-gpu behaves the same.

## Eliminated causes

- greetd/PAM/session: identical path in both cases; logind sessions,
  runtime dir, and user manager verified healthy in the failing case.
- XDG_RUNTIME_DIR: set and correct in the failing case.
- D-Bus: user bus sockets present; compositor dies before D-Bus matters.
- start-hyprland invocation: coredump command line shows the correct
  `--watchdog-fd 4 --config ...` launch.
- Rice config: minimal config fails identically (CASE 2).
- Missing libraries: `ldd /usr/bin/Hyprland` shows no `not found`.
- Permissions/groups: video/render present; polkit agent, wallpaper, and
  all config-referenced binaries present.
- Scheduling warning: best-effort `sched_setscheduler`, non-fatal.
- `XDG_SESSION_TYPE=tty` (set by the greeter session): present in the
  WORKING runs too, so not the cause.

## Conclusion

Hyprland 0.56.2 aborts during startup when the kernel presents zero DRM
devices (no software fallback in this backend path). The failure is
graphics-environment-specific. The VirtualBox VMSVGA report (late clean
exit rather than an early abort) is a different symptom on different
virtual hardware and was not reproducible here (no VirtualBox available);
diagnose it on that hardware with `datum-diagnose` (ships in the image).

## Follow-up: VT/stdin launch conditions (2026-10-02, installed system)

Same image (Hyprland 0.56.2/efb5099), QEMU default video (bochs-drm,
/dev/dri/card0 present), installed target booted via OVMF. Baseline
verified healthy in every run: datum uid 1000 + wheel/audio/video/render
groups, XDG_RUNTIME_DIR + D-Bus set, ldd clean, rice config present.

- Serial-getty session (logind Active=yes but VTNr=0, no VT): bare
  `Hyprland`, `start-hyprland`, minimal lua config, and rice config ALL
  abort identically -- `std::runtime_error: CBackend::create() failed!`,
  SIGABRT, no socket, no hyprland.log. Config/startup-path eliminated
  again; the compositor needs a VT-bound session, and without one it
  dumps core instead of saying so.
- VT1 getty session (Id=4, VTNr=1, tty1, Active=yes, active VT=tty1):
  launching from the interactive login shell with inherited stdin HANGS
  (process alive, no socket, script never progresses). Same session with
  stdin from /dev/null (E1): socket in 5s, state Rl+. With
  `setsid` + stdin null: same 5s success. Conclusion: the hang factor is
  the inherited live tty as stdin, not session leadership -- sharing the
  login shell's terminal deadlocks backend setup.
- Rice on VT1 (setsid + stdin null): socket in 5s, `hyprctl monitors`
  shows Virtual-1 1280x800, hyprpaper/waybar/dunst running, kitty spawned
  via `hyprctl dispatch "hl.dsp.exec_cmd('kitty')"` appears in clients,
  keys typed into the focused terminal arrive (`touch` proof file),
  `hyprctl hyprpaper listactive` shows the wallpaper on Virtual-1,
  `hyprctl dispatch "hl.dsp.exit()"` exits cleanly.
- Greetd path (unmodified image): tuigreet login -> session -> socket ->
  monitors; logout via dispatch exit; tuigreet returns; second login
  works (RELOGIN-OK).

Fixes shipped from these findings:

- `start-datum` detaches stdin (`< /dev/null` on both exec branches) so
  a manual TTY launch behaves like the greetd launch, and refuses VT-less
  sessions with a one-line diagnostic instead of a coredump.
- wofi power menu Logout now calls `hyprctl dispatch "hl.dsp.exit()"`
  (this build's hyprctl takes Lua chunks; bare `dispatch exit`
  interpolates to `hl.dispatch(exit)` and errors).
- `datum-boot-probe` runs hyprctl as root-with-env (no sudo rule ships;
  the old `sudo -n -u` form always failed silently, leaving monitors
  empty). Field-proven: `hyprland.monitors=Monitor Virtual-1 (ID 0):`.
- tests/validate.sh pins all three.
