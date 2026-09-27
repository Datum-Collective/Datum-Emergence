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
livecd/users: emergence
livecd/volid: DATUM_EMERGENCE_AMD64
livecd/motd: @PROJECT_ROOT@/catalyst/motd
livecd/rm: /usr/src
boot/kernel: gentoo
boot/kernel/gentoo/sources: sys-kernel/gentoo-kernel
boot/kernel/gentoo/distkernel: yes
boot/kernel/gentoo/dracut_args: --no-hostonly --add dmsquash-live
boot/kernel/gentoo/use: dist-kernel
