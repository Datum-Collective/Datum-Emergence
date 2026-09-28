#!/bin/sh
set -eu

# This executes inside Catalyst's completed live root, after the root overlay.
# Enable only the services that are part of the intended live desktop.
systemctl enable NetworkManager.service
# The live user is created interactively by datum-firstboot-live, which then
# starts greetd itself. greetd stays disabled in the image on purpose: if it
# were enabled it would race firstboot and present a login screen before any
# valid account exists (previously papered over with a locked autologin
# account that left no usable credential path on failure).
systemctl disable greetd.service
systemctl enable datum-firstboot-live.service
# Boot self-check: reports systemd/services/session/Hyprland status to the
# journal and the serial console. Used by automated QEMU boot validation.
systemctl enable datum-boot-probe.service
# PipeWire is socket-activated per user; the session manager is a user
# service. Neither is on by default, so without this the live session (and
# any installed system copied from it) has no audio. --global applies to the
# live user and to any user the installer creates later.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# No preset live account is created here. Catalyst's livecdfs-update only
# creates live users for gentoo-release-* types; for generic-livecd no
# account is created, and that is what we want: datum-firstboot-live creates
# the real interactive live user at boot (with password, groups, and a home
# from /etc/skel via useradd -m). A hardcoded locked account previously left
# no usable credential path whenever autologin failed, so it is gone.
# (Passwordless sudo for wheel, if sudo is installed, is left to
# livecdfs-update's sudoers handling.)
