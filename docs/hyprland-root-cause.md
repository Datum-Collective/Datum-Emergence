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
