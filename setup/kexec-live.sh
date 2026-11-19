#!/usr/bin/env bash
# 不经过固件，直接从当前系统“热启动”到 U 盘上的 Manjaro Live（kexec）。
# 原厂固件的 RW_LEGACY 不保存启动项，Ctrl+L 后又来不及按 Esc 时用它：sudo bash setup/kexec-live.sh
set -eu
ISO=/dev/sda1; M=/run/l4c-iso
LABEL=$(lsblk -no LABEL $ISO)
[[ $LABEL == MANJARO_* ]] || { echo "没找到 Manjaro U 盘（$ISO 标签：$LABEL），已取消"; exit 1; }
pacman -Q kexec-tools >/dev/null 2>&1 || pacman -S --noconfirm --needed kexec-tools >/dev/null
mkdir -p $M; mountpoint -q $M || mount -o ro $ISO $M
K=$(ls $M/boot/vmlinuz-x86_64 2>/dev/null || ls $M/boot/vmlinuz* | head -1)
I=$(ls $M/boot/initramfs-x86_64.img 2>/dev/null || ls $M/boot/initramfs*.img | grep -v fallback | head -1)
U=$(ls $M/boot/intel_ucode.img 2>/dev/null || true)
BASE=$(ls -d $M/*/ | xargs -n1 basename | while read -r d; do [ -d "$M/$d/x86_64" ] && echo "$d"; done | head -1)
echo "内核：$K"; echo "initramfs：$I"; echo "微码：${U:-无}"; echo "misobasedir：$BASE"
grep -rhoE 'misobasedir=[^ ]+|misolabel=[^ ]+|driver=[^ ]+' $M/boot/grub/*.cfg 2>/dev/null | sort -u | tr '\n' ' '; echo
[[ -n $K && -n $I && -n $BASE ]] || { echo "U 盘里的文件和预期不同，已取消"; exit 1; }
cat ${U:+"$U"} "$I" > /run/l4c-initrd.img
CMD="misobasedir=$BASE misolabel=$LABEL driver=free nouveau.modeset=1 i915.modeset=1 radeon.modeset=1 quiet"
echo "启动参数：$CMD"
kexec -l "$K" --initrd=/run/l4c-initrd.img --append="$CMD"
echo; echo "准备就绪。10 秒后切换到 U 盘系统（屏幕会黑一下），按 Ctrl+C 可以取消。"
sleep 10
systemctl kexec
