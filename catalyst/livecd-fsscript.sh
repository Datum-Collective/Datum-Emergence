#!/bin/sh
set -eu

# This executes inside Catalyst's completed live root, after the root overlay.
# Enable only the services that are part of the intended live desktop.
systemctl enable NetworkManager.service
systemctl enable greetd.service
# Boot self-check: reports systemd/services/session/Hyprland status to the
# journal and the serial console. Used by automated QEMU boot validation.
systemctl enable datum-boot-probe.service
# PipeWire is socket-activated per user; the session manager is a user
# service. Neither is on by default, so without this the live session (and
# any installed system copied from it) has no audio. --global applies to the
# live user and to any user the installer creates later.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# Create the live-session account. Catalyst's livecdfs-update only creates
# live users for gentoo-release-* types (it overrides the user list
# internally); for generic-livecd the user list env var is empty and no
# account is created, so the distribution owns this step explicitly.
if ! getent passwd emergence >/dev/null 2>&1; then
  useradd -m -g users -G users,wheel,audio,video,render,input,plugdev,cdrom \
    -c 'Datum Emergence live session' -s /bin/bash emergence
fi
chown emergence:users /home/emergence
chmod 755 /home/emergence

# Catalyst's livecdfs-update creates /home/emergence BEFORE the root overlay
# is applied, so the live user would otherwise get an empty home without any
# Emergence desktop configuration. Sync the shipped skeleton now.
# (Also repairs ownership if the home directory predates the account.)
if test -d /etc/skel; then
  cp -a /etc/skel/. /home/emergence/
  chown -R emergence:users /home/emergence/
  chmod 755 /home/emergence
fi

# The session needs DRM/input device access beyond the groups above when they
# exist in the target (they come with udev/systemd). No-op if already set.
for g in video render input; do
  if getent group "$g" >/dev/null 2>&1; then
    usermod -aG "$g" emergence
  fi
done

# This is a live-session account, not an installable user identity. The
# greetd initial session logs it in automatically; lock password
# authentication. (Passwordless sudo for wheel, if sudo is installed, is left
# to livecdfs-update's sudoers handling.)
passwd -l emergence
