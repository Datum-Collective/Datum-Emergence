#!/bin/bash

choice=$(printf "⏻ Shutdown\n↻ Reboot\n⇦ Logout" | \
wofi --dmenu \
     --prompt "Power" \
     --style ~/.config/wofi/power.css \
     --width 320 \
     --height 210)

case "$choice" in
    "⏻ Shutdown")
        systemctl poweroff
        ;;
    "↻ Reboot")
        systemctl reboot
        ;;
    "⇦ Logout")
        # This Hyprland build's `hyprctl dispatch` takes a Lua chunk: a bare
        # `dispatch exit` is interpolated as hl.dispatch(exit) and fails
        # ("expected a dispatcher"). Verified working form below.
        hyprctl dispatch "hl.dsp.exit()"
        ;;
esac
