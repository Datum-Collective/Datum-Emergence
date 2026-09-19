#!/bin/sh
set -eu

# This executes inside Catalyst's completed live root, after the root overlay.
# Enable only the services that are part of the intended live desktop.
systemctl enable NetworkManager.service
systemctl enable greetd.service
