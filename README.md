# Datum Emergence

A minimal, opinionated Gentoo desktop by Datum Collective.

> Minimal by nature. Pre-riced by default. Gentoo underneath.

Datum Emergence is a reproducible, x86_64 Gentoo live system with a cohesive
Hyprland desktop. It is for people already comfortable with Gentoo and Linux
internals who want a small, deliberately configured desktop rather than a
generic distribution or an installer that hides the system.

It is not a beginner-focused Linux distribution, a snapshot of a developer's
laptop, a general-purpose desktop spin, or a replacement for Gentoo's normal
administration model.

## Status

The repository defines the first live-ISO milestone: a Catalyst
`livecd-stage1`/`livecd-stage2` pipeline based on a clean Gentoo stage3,
generic distribution kernel, Datum desktop configuration, and UEFI GRUB.
It intentionally has no installer or binary-package service yet.

The build is traceable rather than bit-for-bit reproducible: Gentoo rolling
inputs are recorded in `dist/emergence-build-info.txt`. Supply a fixed stage3
and Portage snapshot to reproduce a particular build.

## Architecture

```
fixed stage3 + fixed Portage snapshot
              | Catalyst livecd-stage1
              v
   Datum packages + sanitized Portage policy
              | Catalyst livecd-stage2
              v
generic kernel + UEFI GRUB + Datum root overlay
              v
dist/emergence-amd64.iso
```

The current baseline is UEFI x86_64. `linux-firmware` and the generic kernel
cover normal Intel, AMD, and nouveau-capable hardware. NVIDIA's proprietary
driver is deliberately not mandatory; it belongs in a future optional hardware
profile, not the universal live image.

## Build

Build on a Gentoo amd64 host with root access, loop mounts, and Catalyst 4.1.1
or compatible installed with its `iso` USE flag. Catalyst's dependencies
include GRUB EFI support, squashfs tools, xorriso/libisoburn, and mtools.
The reference machine's package is keyword-masked, so enable it explicitly on
the *builder* if necessary; do not change a target system merely to build it.

1. Obtain and verify a Gentoo `stage3-amd64-*.tar.*`, then prepare a local
   checked-out Gentoo Portage git tree at the exact commit you intend to use.
   Keep both outside this repository.
2. Export their paths and run the build as root:

```sh
export EMERGENCE_STAGE3=/srv/emergence-inputs/stage3-amd64-YYYYMMDD.tar.xz
export EMERGENCE_STAGE3_SHA512="<verified SHA512 digest>"
export EMERGENCE_PORTAGE_TREE=/srv/emergence-inputs/gentoo
sudo -E ./build.sh all
```

`./build.sh configure` validates the source tree without privileged work.
`stage` runs Catalyst stage 1; `iso` runs stage 2 and validates the resulting
ISO; `test` boots it in QEMU/KVM. `clean` requires `--yes` and only removes the
ignored `build`, `work`, and `dist` directories.

## Desktop and customization

The canonical desktop is Hyprland, Waybar, Wofi, Kitty, Dunst, Hyprpaper,
PipeWire/WirePlumber, NetworkManager, Thunar/Yazi, portals, greetd/tuigreet,
and a small set of screenshot/audio tools. Generic configuration is installed
from `/etc/skel`; no current username, display output, wallpaper path, SSH key,
browser profile, cache, account token, or machine ID is copied.
The live ISO intentionally auto-starts the ephemeral `emergence` desktop
session through greetd. Its password is locked; it is not an installed-user
model and is replaced by an eventual installer.

Edit `packages/emergence`, `config/`, and `etc/skel/` intentionally. Hardware
or personal changes should live in a separate profile or user configuration.

## Testing and installation

Run `./build.sh test` after an ISO build. It detects QEMU, KVM, and OVMF; it
uses UEFI when firmware is available. A successful file/ISO validation is not
a substitute for a QEMU boot. The image is currently a live environment; a
proper installer will come after this path is stable.

## Contributing and roadmap

Keep changes Gentoo-native, explicit, and small. Do not add personal workflow
packages by default, secrets, hardware-specific configuration, or opaque build
steps. Near-term work is a successful native Catalyst build and QEMU boot;
then automated validation and release artifacts. Installer UX, binhosts,
hardware profiles, filesystem experimentation, and agentic-workstation tuning
are deliberately out of scope for this milestone.
