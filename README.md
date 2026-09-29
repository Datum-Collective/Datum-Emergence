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

Testing ISO (v0.1.2 prerelease, UEFI x86_64 live + installer):

- [emergence-amd64.iso](https://github.com/Datum-Collective/Datum-Emergence/releases/latest/download/emergence-amd64.iso)
  (2,088,611,840 bytes, SHA256
  `612815ccc8e28190aa562a6594f45ef8d1825000df7eb09a1ea067c627979d7d`)

Verify after downloading (Linux):

```sh
sha256sum emergence-amd64.iso   # must match the checksum above
```

Write it to a USB drive (replace `sdX` with your device, triple-checked):

```sh
sudo dd if=emergence-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Or use Fedora Media Writer, Balena Etcher, or Ventoy. Then boot the machine
from USB: the first-boot setup asks for a username and password for the
live session, after which you log in and reach the Hyprland desktop. Run
the installer from the live desktop (see Install below).

## Status

The repository builds a Catalyst `livecd-stage1`/`livecd-stage2` pipeline
from a clean Gentoo stage3, ships a UEFI-bootable live ISO with a
first-boot user setup (you choose the live username and password, then log
in through greetd/tuigreet into Hyprland), and installs to disk with the
included `datum-install` tool. The full chain (clean inputs, stage1, ISO,
QEMU UEFI boot, firstboot setup, live desktop, install to a blank virtual
disk, boot of the installed system) has been tested end-to-end.

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

Automated boot check (headless QEMU/KVM, UEFI, serial console, ~7 minutes):

```sh
./build.sh test-ci
```

It drives the real firstboot lifecycle (username/password setup, tuigreet
login) and asserts systemd booted, NetworkManager and greetd are active,
the chosen live user session with Hyprland exists, and the Datum overlay
files are present. A VNC/screenshot run additionally confirmed the rendered
desktop (Waybar, cursor, no config errors).

Firstboot edge cases (invalid usernames, password confirmation, password
secrecy on the console) are covered separately:

```sh
./build.sh test-firstboot        # all scenarios (direct-kernel, serial console)
./build.sh test-firstboot passwords
```

Attach the ISO via virtio in VMs: the dist kernel does not enumerate QEMU's
legacy IDE CD-ROM in this configuration, while virtio-blk works.

## Install

> **DESTRUCTIVE OPERATION WARNING.** The installer completely overwrites the
> target disk: new GPT, new filesystems, all previous data destroyed. There
> is no undo. Double-check `--disk` with `lsblk` before confirming.
>
> - The installer refuses non-block devices, mounted partitions, disks
>   smaller than 10 GiB, and (best effort) the device the live image booted
>   from.
> - It still requires explicit `--yes`. Read the printed plan first.
> - Never aim it at a disk containing data you need. Unplug other drives
>   when installing on physical hardware if you are unsure.

From the booted live ISO, as root:

```sh
sudo datum-install --disk /dev/vdX --user datum --hostname emergence --yes
```

This creates a 512 MiB EFI System Partition plus an ext4 root, copies the
live system, removes the live-session account from the copy (the account
the firstboot setup created is live-only; the installer refuses to inherit
any unexpected account), writes UUID-based fstab, installs GRUB for UEFI
(NVRAM entry plus the removable `BOOTX64.EFI` fallback), creates the
permanent first local user (which the installed system autologs in),
sets the hostname/timezone, regenerates the machine ID, and strips all
live-firstboot state from the target. If the requested installed username
matches the live-session name, that account is adopted (password and groups
reset). Remove the ISO and boot the installed disk.

Fully automated VM test (blank 20 GiB disk, install, reboot from disk,
verify services/session/desktop/fstab/bootloader/live-user removal):

```sh
./build.sh test-install
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
