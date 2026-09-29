subarch: amd64
version_stamp: @VERSION_STAMP@
target: livecd-stage2
rel_type: datum
profile: default/linux/amd64/23.0/desktop/systemd
snapshot_treeish: @SNAPSHOT_NAME@
source_subpath: datum/livecd-stage1-amd64-@VERSION_STAMP@
portage_confdir: @PROJECT_ROOT@/config
repos: @OVERLAY_REPOS@
livecd/fstype: squashfs
livecd/fsops: --compressor xz -b 1M -X x86
livecd/iso: @ISO_PATH@
livecd/root_overlay: @ROOT_OVERLAY@
livecd/fsscript: @PROJECT_ROOT@/catalyst/livecd-fsscript.sh
livecd/type: generic-livecd
livecd/volid: DATUM_EMERGENCE_AMD64
# Quiet, intentional boot: the live UI (firstboot installer, then tuigreet) must
# own tty1 exclusively. Without these flags systemd/dracut status floods the
# user-facing VT and mixes with the setup prompt (Failure A), and long probe
# jobs print "A start job is running ..." over tuigreet (Failure B).
# Serial/test markers are unaffected: datum-firstboot-live and datum-boot-probe
# write explicitly to /dev/kmsg and /dev/ttyS0, not via kernel console output.
livecd/bootargs: quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no udev.log_level=3
livecd/motd: @PROJECT_ROOT@/catalyst/motd
livecd/rm: /usr/src
boot/kernel: gentoo
boot/kernel/gentoo/sources: sys-kernel/gentoo-kernel
boot/kernel/gentoo/distkernel: yes
boot/kernel/gentoo/dracut_args: --no-hostonly --add dmsquash-live
boot/kernel/gentoo/use: dist-kernel
