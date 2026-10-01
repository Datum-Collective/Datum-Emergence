#!/bin/sh
set -eu

# This executes inside Catalyst's completed live root, after the root overlay.
# The live ISO is an installer environment (not a live desktop): the only
# user-facing service is the guided installer on tty1.
systemctl enable NetworkManager.service
# No greeter on the live ISO: there is no live user to log in, and the
# installer (not a desktop session) is the product. The installed target
# gets greetd enabled by datum-install during installation.
systemctl disable greetd.service
# The installer owns tty1 from boot (conflicts with getty@tty1 itself).
systemctl enable datum-installer.service
# Boot self-check: reports systemd/service/session status to the journal and
# the serial console. Bounded and non-blocking (never orders anything after
# it; quiet cmdline suppresses status display). Used by automated QEMU boot
# validation on live and installed systems.
systemctl enable datum-boot-probe.service
# PipeWire is socket-activated per user; the session manager is a user
# service. Neither is on by default, so without this the installed desktop
# (copied from this image) has no audio. --global applies to the user the
# installer creates on the target.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# No live account of any kind is created here. Catalyst's livecdfs-update only
# creates live users for gentoo-release-* types; for generic-livecd no
# account is created, and that is what we want: the ISO never logs anyone
# in. The permanent user is created on the TARGET by datum-install.
# (Passwordless sudo for wheel, if sudo is installed, is left to
# livecdfs-update's sudoers handling.)
