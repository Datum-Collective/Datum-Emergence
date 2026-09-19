# Reference audit summary

Audit date: 2026-09-19. Detailed host reports are deliberately outside the
repository at `/tmp/emergence-audit/` because they identify a developer host.

The reference is Gentoo 2.18 on amd64, profile
`default/linux/amd64/23.0/desktop/systemd`, systemd 261, and a Gentoo
distribution kernel. Its chosen desktop stack is Hyprland, Waybar, Wofi,
Kitty, Dunst, Hyprpaper, Thunar/Yazi, PipeWire/WirePlumber, NetworkManager,
portals, greetd/tuigreet, Bibata cursors, and Nerd/Noto fonts.

The reference hardware is an Intel laptop with an NVIDIA RTX 4060 Mobile, Intel
Wi-Fi, Realtek Ethernet, NVMe, and an internal `eDP-1` panel. None of these
identifiers are encoded in the baseline. NVIDIA and personal tools (Docker,
browsers, Slack, Obsidian, MPD/Cava, Rust, archive/novelty utilities) were
classified as non-base. The reference had no installed Catalyst; the builder
was designed against Gentoo Catalyst 4.1.1 source and templates.

The original rice repository was used only as a configuration reference.
Emergence contains rewritten generic configuration and original SVG branding;
it does not import its PNG wallpaper, user account state, or home directory.

Catalyst, rather than an rsync configuration copied from the reference host,
supplies the immutable Portage snapshot during an Emergence build.
