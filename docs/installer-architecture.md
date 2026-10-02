# Emergence installer architecture (installer-first)

This note records the installer design, the Omarchy lessons adopted or
rejected, the Hyprland root-cause finding, and the Gentoo-specific
constraints. It exists so the installer does not regress into one giant
fragile shell script, and so the live/install separation is never blurred
again.

## 1. Boundaries

```
Catalyst          = build the prepared Emergence OS (stage1 + live ISO)
ISO               = installer environment: installer UI + install payload
datum-install     = configure (TUI menu) + deploy (engine) to a target disk
target setup      = machine-specific state (fstab, hostname, machine-id,
                    bootloader, permanent user) inside the target root
installed system  = greetd -> tuigreet -> PAM user -> start-hyprland
                    -> Hyprland desktop (no installer, no live state)
```

The live ISO is NOT a desktop, NOT a login environment, and does NOT
create any user. It boots straight into the installer, which owns tty1.
The ISO already contains the prepared system (SquashFS), so installation
is a copy-and-configure deployment, never a package rebuild and never a
network download of the OS.

## 2. Omarchy study (what was adopted, rejected, adapted)

Studied: omarchy-iso (quattro branch) README and architecture.

Adopted principles:
- The ISO ships a configurator as its primary UI; install runs target
  setup in a chroot, creates the user, and validates before reboot.
- Configuration is collected first, then executed (configurator output
  acts as installer state; Emergence keeps it in-process: the TUI fills
  the same variables the engine consumes).
- Explicit destructive confirmation with disk model/size/plan shown first.
- Staged progress with real stage names, never fake percentages.
- User-facing error plus log-file diagnostics split; detailed installer
  log without credentials.
- Target self-validation (fstab UUIDs, bootloader, user, services,
  live-state removal) before declaring success.
- Offline install from the bundled payload (Omarchy: bundled mirror;
  Emergence: ISO SquashFS). No network fetch of the OS during install.
- cidata-style unattended installs are architecturally reserved
  (config-driven, password-hash based) but NOT implemented; the CLI flags
  plus EMERGENCE_INSTALL_PASSWORD remain the automation seam for tests.
- Acceptance testing drives the REAL interactive flow (Omarchy: QMP
  screendump+OCR; Emergence: serial markers + QEMU monitor typing).

Rejected / deferred:
- Arch-style online package installation: unnecessary; Catalyst already
  built the system.
- Full-disk encryption: full-disk ext4 + ESP is the supported path;
  encryption and dual-boot are explicit non-goals for this milestone.
  The architecture supports exactly one reliable full-disk install; dual
  boot can be added later without rewriting it.
- Graphical toolkit installer: the product is a terminal OS; the TUI is
  restrained monochrome box-drawing over a POSIX sh flow.
- Omarchy's bundled-mirror + pacman model: Gentoo/Catalyst model differs
  (tar copy of the prepared root instead of pacstrap/archinstall).

Adapted (Gentoo-specific):
- GRUB UEFI with NVRAM entry (best effort) plus mandatory removable
  BOOTX64.EFI fallback; UUID-enforced root; quiet target cmdline.
- systemd machine-id regeneration, NetworkManager/greetd enablement,
  PipeWire socket activation carried over via the image.
- Console keymap applied live with loadkeys, persisted to
  /etc/vconsole.conf, and mapped to the Hyprland kb_layout.

## 3. Why firstboot account creation was removed

The previous architecture booted the ISO into a live-user creation form
(firstboot), then a greeter login, then a live Hyprland desktop, and only
then could the user install. That made the ISO simultaneously an
installer, a desktop, and a login environment, which caused:

- systemd status mixing with the setup form (shared VT, no ownership);
- start-job text over tuigreet (probe in the boot transaction);
- a live account lifecycle (markers, adoption, cleanup) that could leak
  into the target;
- greetd/firstboot fighting over tty1;
- Hyprland tested on the live path, where virtual GPUs are fragile (see
  section 6), blocking installation behind compositor health.

The installer-first design deletes all of it: no live user, no live
greeter, no live desktop. The TUI collects the TARGET owner's account
before partitioning, the engine creates exactly one permanent user on
the target, and the installed system logs in through tuigreet + PAM.

## 4. User lifecycle (only two identities exist)

- root (live): runs the installer only; never runs a desktop.
- target permanent user: created by datum-install inside the target root
  (useradd -m from /etc/skel, fixed groups, installed password). The
  installed system has NO autologin: tuigreet + PAM authenticate this
  user on every boot.
- No live user, no emergence account, no default password, no root
  desktop, no hardcoded permanent user.

## 5. Live/target classification

- ISO-only: datum-installer.service, datum-install (TUI+engine),
  datum-diagnose, /etc/datum/live, installer log.
- Target-only: /etc/datum/installed, UUID fstab, installed machine-id,
  permanent user + password, quiet GRUB cmdline, tuigreet login.
- Both (copied then reconfigured): kernel/initramfs, GRUB, greetd base
  config (default_session only), desktop overlay, /etc/skel rice,
  datum-boot-probe (observes both), datum-diagnose.

## 6. Hyprland root cause (established by experiment, 2026-09-29)

Symptom: compositor starts, then exits; session returns to tuigreet.
A direct TTY launch also failed, proving greetd was not the sole cause.

Matrix run on the v0.1.4 ISO (Hyprland 0.56.2, same image, same
firstboot/login path, same rice config throughout):

- QEMU std VGA (bochs-drm binds, /dev/dri/card0 present): Hyprland
  RUNS, Wayland socket exists, monitor detected (also with virtio-gpu).
- QEMU vmware VGA (vmwgfx refuses the hypervisor: "probe failed with
  error -38", NO /dev/dri at all): Hyprland SIGABRTs (coredump,
  signal 6), no socket, no hyprland.log — with the full rice config AND
  with a 6-line minimal config.

Conclusion: Hyprland 0.56.2 aborts at startup when the system presents
zero DRM devices. Case closed as graphics-environment-specific: NOT
greetd, NOT PAM, NOT XDG_RUNTIME_DIR (correct in all runs), NOT D-Bus,
NOT start-hyprland (command line verified in the coredump), NOT the
rice (minimal config fails identically), NOT missing libraries (ldd
clean), NOT permissions (video/render groups present). The scheduling
("Failed to change process scheduling strategy") warning is non-fatal
best-effort output, not the cause. The user-visible VirtualBox failure
is a different symptom (late clean exit on VMSVGA, untestable here: no
VirtualBox in this environment) and must be diagnosed separately on
hardware or VirtualBox with datum-diagnose.

Consequences for the product:
- The live ISO must not depend on a working compositor (it no longer
  starts one at all).
- The installed desktop requires real DRM (physical hardware or a VM
  GPU that binds: bochs/virtio-gpu proven; vmware-SVGA-on-QEMU and
  untested VMSVGA are out of scope for automated acceptance).
- Launch conditions (established 2026-10-02 on the installed system):
  the compositor needs a VT-bound logind session (greetd/VT-getty both
  fine); with no VT it aborts in CBackend::create, and with a live login
  tty inherited as stdin it deadlocks instead of starting. `start-datum`
  therefore detaches stdin on both exec branches and refuses VT-less
  sessions with a diagnostic rather than a coredump. Manual TTY launch
  goes through `start-datum`, never bare `Hyprland`.
- This build's `hyprctl dispatch` takes Lua chunks
  (`hl.dsp.exec_cmd(...)`, `hl.dsp.exit()`); bare words fail. The wofi
  power menu uses the verified form.
- datum-diagnose ships on live and installed systems so any future
  compositor failure can be captured the same way (session, env,
  runtime dir, lspci, /dev/dri, binaries, pgrep, sockets, coredumps,
  journals, config path).

## 7. Boot flow (one VT owner per phase)

Live: firmware/GRUB -> quiet boot -> datum-installer owns tty1
(getty@tty1 conflicted, vconsole settled, status suppressed) ->
installer menu -> install -> success -> reboot.

Installed: firmware/GRUB -> quiet boot -> greetd owns tty1
(vt=1, switch=true) -> tuigreet -> PAM -> start-datum ->
start-hyprland -> Hyprland desktop.

datum-boot-probe observes from the side on both (journal, result file,
kmsg, serial; stdout null; bounded polls; nothing ordered after it).

## 8. Testing contract

- tests/validate.sh: static contracts (spec compression, installer
  service, no-firstboot, marker files, tuigreet-no-autologin, quiet
  target grub, TUI/engine split, log path).
- scripts/test-iso.sh --ci: live boot health (installer active, live
  marker, no session, menu reached).
- scripts/test-installer-tui.sh: real TUI drive (invalid username and
  password-mismatch retries, disk hiding, confirmation identity check,
  install, poweroff) + host target checks + password-secrecy assertion.
- scripts/test-install.sh: engine path (flags) + host target checks +
  installed-disk boot with real tuigreet login + desktop session probe
  (Hyprland=yes, Wayland socket required).
- The "login -> Hyprland exits -> login" regression is covered by the
  Hyprland=yes + wayland-socket assertions on the installed boot.

## 9. Build hygiene (learned the hard way)

- Stage 2 ALWAYS runs fresh (guard_stage2_resume wipes unconditionally).
  Resuming once produced a kernel-less ISO with no error: kmerge re-ran
  against a chroot whose /boot no longer held images (the kernel emerge
  with --update was a no-op, so installkernel never re-placed them),
  kmerge's own tar failures are non-fatal there, and the ISO assembly
  continued regardless.
- validate_iso resolves EVERY grub-referenced kernel/initramfs path
  against the ISO file list. The previous prefix check let the bad ISO
  through: the initramfs `gentoo.igz` satisfies a naive `gentoo`
  pattern while the kernel image itself is missing.
- tests/validate.sh negative assertions must never use a leading `!`:
  POSIX shells ignore `set -e` for `!`-inverted commands, so every such
  check was silently vacant (including historic ones). Use the
  no_match/no_file helpers instead.
