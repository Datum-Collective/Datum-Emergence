#!/bin/sh
set -eu

# This executes inside Catalyst's completed live root, after the root overlay.
# Enable only the services that are part of the intended live desktop.
systemctl enable NetworkManager.service
systemctl enable greetd.service
# This is a live-session account, not an installable user identity. The initial
# greetd session logs it in automatically; lock password authentication.
passwd -l emergence
