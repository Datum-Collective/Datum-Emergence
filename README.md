# Datum Emergence

A minimal, opinionated Gentoo desktop by Datum Collective.

> Minimal by nature. Pre-riced by default. Gentoo underneath.

Datum Emergence is a reproducible, x86_64 Gentoo live system with the Datum
rice (Hyprland desktop) preinstalled. It is for people already comfortable
with Gentoo and Linux internals who want a small, deliberately configured
desktop rather than a generic distribution or an installer that hides the
system.

It is not a beginner-focused Linux distribution, a snapshot of a developer's
laptop, a general-purpose desktop spin, or a replacement for Gentoo's normal
administration model.

## Download

Testing ISO (v0.1.4 prerelease, UEFI x86_64 installer):

- [emergence-amd64.iso](https://github.com/Datum-Collective/Datum-Emergence/releases/latest/download/emergence-amd64.iso)
  (2,088,611,840 bytes, SHA256
  `b2b2a9cc67fd1435fd20106abbcfd4c7b3ddce60e4dcab422498bdea61546611`)

Verify after downloading (Linux):

```sh
sha256sum emergence-amd64.iso   # must match the checksum above
```

Write it to a USB drive (replace `sdX` with your device, triple-checked):

```sh
sudo dd if=emergence-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Or use Fedora Media Writer, Balena Etcher, or Ventoy. Then boot the machine
from USB: the ISO boots straight into the Datum Emergence installer
(keyboard, user account, hostname, timezone, disk, confirmation), installs
to the chosen disk, and reboots into the installed system, where you log in
through greetd/tuigreet into the Hyprland desktop. There is no live login:
the ISO is an installer environment.

## Status

The repository builds a Catalyst `livecd-stage1`/`livecd-stage2` pipeline
from a clean Gentoo stage3 and ships a UEFI-bootable installer ISO. The
full chain (clean inputs, stage1, ISO, QEMU UEFI boot into the installer,
guided install to a blank virtual disk, boot of the installed system,
tuigreet login, Hyprland desktop) is tested end-to-end; see
`docs/installer-architecture.md`.

The build is traceable rather than bit-for-bit reproducible: Gentoo rolling
inputs are recorded in `dist/emergence-build-info.txt`. Supply a fixed stage3
and Portage snapshot to reproduce a particular build.

## Architecture

```
fixed stage3 + fixed Portage snapshot + pinned overlays
              | Catalyst livecd-stage1
              v
   Datum packages + sanitized Portage policy
              | Catalyst livecd-stage2
              v
dist-kernel + dracut live initramfs + UEFI GRUB + Datum root overlay
              v
dist/emergence-amd64.iso
```

The current baseline is UEFI x86_64. `linux-firmware` and the generic kernel
cover normal Intel, AMD, and nouveau-capable hardware. NVIDIA's proprietary
driver is deliberately not mandatory; it belongs in a future optional hardware
profile, not the universal live image.

The desktop configuration (Hyprland Lua config, hyprpaper, Waybar, Wofi,
Kitty, Dunst, Yazi theme, Starship theme, helper scripts, and the `3.png`
wallpaper) is taken from the canonical Datum rice, adapted only where a
reference path must become a system path (`~/.local/bin/*` tools live in
`/usr/local/bin`, the wallpaper lives under `/usr/share/backgrounds/`).
No `/home/dan` paths, accounts, caches, or machine state are copied.

## Host requirements

Build on a Gentoo amd64 host with root access (or another route to root;
the project itself never edits the host OS), loop mounts, and Catalyst
4.1.1 with its `iso` USE flag. Catalyst's dependencies include GRUB EFI
support, squashfs tools, xorriso/libisoburn, mtools, and tar2sqfs.

Build tooling used by `build.sh` beyond Catalyst: `git`, `sha512sum`,
`python3`, `xorriso` (ISO validation), and `rsvg-convert` only if you
re-render branding (the committed PNG ships as-is).

For boot testing: `app-emulation/qemu` (the `virgl` USE flag helps if you
want guest GL), `sys-firmware/edk2-bin` (OVMF UEFI firmware), and KVM
access (`/dev/kvm`, usually the `kvm` group).

## Inputs

Three pinned inputs live outside this repository:

- `EMERGENCE_STAGE3`: a verified Gentoo `stage3-amd64-systemd-*.tar.xz`.
- `EMERGENCE_STAGE3_SHA512`: its verified SHA512 digest. Obtain it from the
  official Gentoo `.DIGESTS` file for that stage3 and cross-check it; the
  build refuses to run on mismatch.
- `EMERGENCE_PORTAGE_TREE`: a clean Gentoo Portage git checkout. The exact
  commit used is recorded in the build info.

Two pinned overlays (the pinned Gentoo snapshot no longer carries the
Hyprland stack or some desktop utilities, so these are required, not
optional):

- `EMERGENCE_GURU_TREE` (default `/var/db/repos/guru`) at
  `EMERGENCE_GURU_COMMIT`.
- `EMERGENCE_HYPROVERLAY_TREE` (default `/var/db/repos/hyproverlay`) at
  `EMERGENCE_HYPROVERLAY_COMMIT`.

Defaults for the overlay commits are the reviewed combination recorded in
`dist/emergence-build-info.txt`. Override them only with another reviewed
commit. The build verifies every package-manifest atom resolves in exactly
these trees before starting Catalyst, so a bad pin fails fast.

Optional tuning: `EMERGENCE_VERSION_STAMP` (default: UTC date; set it
explicitly for reproducible artifact names across midnight boundaries) and
`EMERGENCE_JOBS` (default 6; parallel emerge jobs, also MAKEOPTS).

## Build

```sh
export EMERGENCE_STAGE3=/srv/emergence-inputs/stage3-amd64-YYYYMMDD.tar.xz
export EMERGENCE_STAGE3_SHA512="<verified SHA512 digest>"
export EMERGENCE_PORTAGE_TREE=/srv/emergence-inputs/gentoo
export EMERGENCE_VERSION_STAMP=20260926   # recommended: pin it
sudo -E ./build.sh all
```

Stages individually:

- `./build.sh configure` validates the source tree (no privilege needed).
- `sudo -E ./build.sh stage` runs Catalyst stage 1 (unpacks the stage3,
  merges the Emergence manifest).
- `sudo -E ./build.sh iso` runs Catalyst stage 2 (dist-kernel, dracut live
  initramfs, bootloader, squashfs, ISO) and validates the result, refusing
  kernel-less ISOs.
- `./build.sh test` boots the ISO interactively in QEMU (UEFI when OVMF is
  present).
- `./build.sh test-ci` boots headless and checks the in-image boot probe.
- `./build.sh test-install` runs the full install-to-VM test (see below).
- `./build.sh clean --yes` removes only the ignored `build`, `work`, and
  `dist` directories.

Notes:

- Stage 2 must complete in one invocation. If a stage 2 run is interrupted
  after its bootloader step, resuming would silently produce a kernel-less
  ISO (Catalyst empties its staging dir on startup but skips completed
  steps); `build.sh` detects that state and restarts stage 2 fresh instead.
- The kernel image is normalized to `vmlinuz-<version>` by
  `config/bashrc` because Gentoo's installkernel installs it as
  `kernel-<version>`, which Catalyst's kernel packaging would otherwise
  silently omit.
- `sys-power/acpilight` stands in for `brightnessctl` (not in the pinned
  tree; also absent on the reference machine) and `media-fonts/nerdfonts`
  (guru) replaces the removed `media-fonts/nerd-fonts`.

## Validate and boot-test

Structural checks:

```sh
./tests/validate.sh
file dist/emergence-amd64.iso        # ISO 9660, bootable, DATUM_EMERGENCE_AMD64
```

Automated boot check (headless QEMU/KVM, UEFI, serial console):

```sh
./build.sh test-ci
```

It boots the installer ISO headless and asserts the installer service is
active, the live marker is present, no login session exists on live media,
and the installer menu was reached. The interactive installer itself is
driven like a human through the QEMU monitor:

```sh
sudo ./build.sh test-installer-tui   # guided install incl. input validation
```

Attach the ISO via virtio in VMs: the dist kernel does not enumerate QEMU's
legacy IDE CD-ROM in this configuration, while virtio-blk works. The ISO
drive is attached read-only in tests so a disk-selection bug cannot harm
the medium.

## Install

> **DESTRUCTIVE OPERATION WARNING.** The installer completely overwrites the
> target disk: new GPT, new filesystems, all previous data destroyed. There
> is no undo. Double-check `--disk` with `lsblk` before confirming.
>
> - The installer refuses non-block devices, optical drives, the device the
>   live image booted from, mounted partitions, and disks smaller than
>   10 GiB.
> - The guided installer requires typing `yes` at the confirmation screen;
>   flags mode still requires explicit `--yes`. Read the plan first.
> - Never aim it at a disk containing data you need. Unplug other drives
>   when installing on physical hardware if you are unsure.

Boot the ISO: the installer menu offers Install / Shell / Reboot /
Power off. The guided flow collects keyboard, user account (typed twice,
masked), hostname, timezone, shows a summary, lists disks with their
partitions (live media hidden), requires explicit confirmation, installs
with staged progress, and validates the target before declaring success.

Non-interactive (automation only):

```sh
sudo datum-install --disk /dev/vdX --user datum --hostname emergence --yes
```

This creates a 512 MiB EFI System Partition plus an ext4 root, copies the
live system, writes UUID-based fstab, installs GRUB for UEFI (NVRAM entry
plus the removable `BOOTX64.EFI` fallback), creates exactly one permanent
target user (the live ISO never has any user, so there is nothing to
adopt or leak), sets hostname/timezone/keyboard, configures a quiet boot,
enables greetd with the tuigreet login (no autologin), regenerates the
machine ID, writes the installed-state marker, and strips all
live-installer state from the target. Remove the ISO and boot the
installed disk; log in as the created user to reach Hyprland.

Fully automated VM tests (blank 20 GiB disk, install, reboot from disk,
real tuigreet login, desktop session, fstab/bootloader/marker checks):

```sh
sudo ./build.sh test-installer-tui   # interactive TUI path
./build.sh test-install               # flags/engine path
```

## Desktop and customization

The canonical desktop is Hyprland (Lua config, launched via `start-datum`
through greetd), Waybar, Wofi (+ power menu), Kitty, Dunst, Hyprpaper,
PipeWire/WirePlumber (socket-activated), NetworkManager, Thunar/Yazi,
portals, greetd/tuigreet, Starship prompt config, and small screenshot/audio
helpers. Generic configuration is installed from `/etc/skel`; no current
username, display output, SSH key, browser profile, cache, account token, or
machine ID is copied.

Edit `packages/emergence`, `config/`, and `etc/skel/` intentionally. Hardware
or personal changes should live in a separate profile or user configuration.

Shell prompt: add `eval "$(starship init bash)"` to your interactive shell
(same as the rice instructs).

## Known gaps and limitations

- `app-shells/starship` is in the package manifest but its binary postdates
  the current stage1 artifact; it arrives with the next stage1 run. Its
  config already ships.
- QEMU software rendering (llvmpipe, no virgl device) may not display the
  hyprpaper wallpaper in the VM even though the rice configuration is
  byte-identical to the reference setup that displays it on real hardware.
  Session, compositor, and clients are verified working regardless.
- Hyprland 0.56 requires a kernel DRM device: it runs on QEMU std VGA
  (bochs-drm) and virtio-gpu, but aborts at startup on GPUs that present
  no DRM (e.g. vmware-SVGA-on-QEMU, where vmwgfx refuses the hypervisor).
  See `docs/hyprland-root-cause.md`. Physical hardware with working DRM
  is the acceptance target; VirtualBox VMSVGA is untested here.
- QEMU legacy IDE CD-ROM is not enumerated by the dist kernel in this
  configuration; attach the ISO via virtio in VMs. Real SATA/USB hardware
  uses built-in drivers.
- No binary-package service or hardware profiles yet; NVIDIA's proprietary
  driver, Secure Boot signing, and non-UEFI boot are out of scope for this
  milestone.

## Contributing and roadmap

Keep changes Gentoo-native, explicit, and small. Do not add personal workflow
packages by default, secrets, hardware-specific configuration, or opaque build
steps. Near-term work is release automation and hardware-profile experiments;
installer UX polish, binhosts, and filesystem experimentation remain
deliberately out of scope for this milestone.
