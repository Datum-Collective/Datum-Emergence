# Emergence installer architecture (v0.1.2 post-review note)

This note records the installer/firstboot design as implemented, the Omarchy
lessons adopted or rejected, and the Gentoo-specific constraints. It exists
so the installer does not regress into one giant fragile shell script.

## 1. Boundaries

```
Catalyst          = build the prepared Emergence OS (stage1 + live ISO)
ISO               = carry the prepared OS + live-only setup
datum-install     = deploy the prepared OS to a target disk (no rebuild)
target setup      = machine-specific state (fstab, hostname, machine-id,
                    bootloader, permanent user) inside the target root
firstboot         = owner-specific provisioning, live-only (live session
                    account creation before greetd)
desktop session   = greetd -> tuigreet -> authenticated user ->
                    dbus-run-session start-datum -> start-hyprland -> Hyprland
```

The ISO already contains a prepared system, so installation is a
copy-and-configure deployment, never a package rebuild. No network fetch
happens during install.

## 2. Omarchy study (what was adopted, rejected, adapted)

Read: omarchy-iso README/architecture, getting-started and
unattended-installs manuals.

Adopted:
- ISO ships the installer; install runs target setup in a chroot, creates
  the user, and validates before reboot.
- Explicit destructive confirmation with disk model/size/plan shown first.
- Staged progress with real stage names, never fake percentages.
- User-facing error plus log-file diagnostics split.
- Detailed installer log without credentials.
- Target self-validation (fstab UUIDs, bootloader, user, services,
  live-state removal) before declaring success.
- cidata-style unattended path is architecturally reserved (config-driven,
  password-hash based) but NOT implemented in v0.1.2; the CLI flags plus
  EMERGENCE_INSTALL_PASSWORD remain the automation seam.
- "Prepare for another owner" is supported structurally: the installer
  creates the permanent account, and live-firstboot state never leaks into
  the target, so imaging-then-handoff does not embed a personal account.

Rejected / deferred:
- Arch-style online package installation: unnecessary; Catalyst already
  built the system.
- Full-disk encryption in v0.1.2: full-disk ext4 + ESP is the excellent
  path; encryption and dual-boot are explicit non-goals for this milestone.
- Graphical toolkit installer: the product is a terminal OS; the TUI is
  restrained monochrome box-drawing over the existing shell flow.
- Omarchy's bundled-mirror + pacman model: Gentoo/Catalyst model differs.

Adapted (Gentoo-specific):
- tar copy of the live root (one filesystem, excluding virtual dirs)
  instead of pacstrap/archinstall.
- GRUB UEFI with NVRAM entry (best effort) plus mandatory removable
  BOOTX64.EFI fallback.
- systemd machine-id regeneration, NetworkManager/greetd enablement,
  PipeWire socket activation carried over via the image.

## 3. User lifecycle (identities never blur)

- root: runs firstboot and the installer only; never runs the desktop.
- greetd/greeter: owns the login prompt process only; never the session.
- live-session user: created interactively by datum-firstboot-live, recorded
  in /run/datum-live-user (authoritative) and /etc/datum/live-user
  (persistent copy for the installer). Live-only; removed from the target.
- target permanent user: created by datum-install inside the target root
  (adopted if the name matches the live user, otherwise the live account
  is deleted entry-by-entry). The installed system autologs this user via
  an appended greetd [initial_session]; the live image carries none.
- No default password, no hardcoded permanent user, no root desktop.

## 4. Live/target classification

- ISO-only: datum-firstboot-live (+ unit), /etc/datum/live-user,
  /run/datum-live-user, installer log at /var/log/emergence-installer.log
  (a sanitized copy is also left on the target for diagnostics).
- Target-only: [initial_session] autologin block, UUID fstab, installed
  machine-id, permanent user password.
- Both (copied then reconfigured): kernel/initramfs, GRUB, greetd base
  config, desktop overlay, /etc/skel rice.

## 5. Hyprland launch (root cause of the VirtualBox report)

The image ships /usr/bin/start-hyprland (watchdog binary) alongside
/usr/bin/Hyprland. start-datum previously exec'd Hyprland directly, which
produces the "launched without start-hyprland" warning and loses watchdog
supervision. start-datum now execs `start-hyprland -- --config ...` with a
direct-Hyprland fallback. All config-referenced binaries (kitty, wofi,
waybar, dunst, hyprpaper, polkit agent, screenshot/record helpers,
wallpaper, power.sh) were verified present in the shipped squashfs, so the
remaining "No such file or directory" in the VirtualBox report is an
environment/session issue (XDG_RUNTIME_DIR, D-Bus, GPU/KMS), not a missing
payload file; QEMU reports Hyprland=yes with a Wayland socket. VirtualBox
remains NOT TESTED in this environment (no VirtualBox available).

## 6. Testing contract

- tests/validate.sh: static contracts (spec compression, greetd, firstboot
  markers, installer lifecycle strings, start-hyprland usage, log path).
- scripts/test-iso.sh --firstboot: real firstboot typing + tuigreet login +
  probe verdict, with password-secrecy assertion.
- scripts/test-firstboot-checks.sh: invalid users, password mismatch rules.
- scripts/test-install.sh: blank-disk install + host-side target checks +
  installed-disk boot probe (fstab UUIDs, bootloader, live-user removal,
  Hyprland session).
- The "create user, login, Hyprland exits, back to tuigreet" failure is a
  regression case covered by the Hyprland=yes probe assertion; a future
  VirtualBox run must drive the same lifecycle there.
