#!/usr/bin/env bash
# 不经过固件，直接从当前系统「热启动」到 U 盘上的 Manjaro Live（kexec）。
# 原厂固件的 RW_LEGACY 不保存启动项，Ctrl+L 后又来不及按 Esc 时用它：sudo bash setup/kexec-live.sh
set -eu
ISO=/dev/sda1; M=/run/l4c-iso
LABEL=$(lsblk -no LABEL "$ISO")
[[ $LABEL == MANJARO_* ]] || { echo "没找到 Manjaro U 盘（$ISO 标签：$LABEL），已取消"; exit 1; }
pacman -Q kexec-tools >/dev/null 2>&1 || pacman -S --noconfirm --needed kexec-tools >/dev/null
mkdir -p "$M"; mountpoint -q "$M" || mount -o ro "$ISO" "$M"
# 找内核、initramfs、微码和 misobasedir（Manjaro ISO 的目录结构），只用 glob，不解析 ls 输出
first() { local f; for f in "$@"; do [[ -e $f ]] && { echo "$f"; return 0; }; done; return 0; }
K=$(first "$M/boot/vmlinuz-x86_64" "$M"/boot/vmlinuz*)
I=$(first "$M/boot/initramfs-x86_64.img" "$M"/boot/initramfs*[!k].img)
U=$(first "$M/boot/intel_ucode.img")
BASE=""; for d in "$M"/*/; do [[ -d $d/x86_64 ]] && { BASE=$(basename "$d"); break; }; done
echo "内核：$K"; echo "initramfs：$I"; echo "微码：${U:-无}"; echo "misobasedir：$BASE"
grep -rhoE 'misobasedir=[^ ]+|misolabel=[^ ]+|driver=[^ ]+' "$M"/boot/grub/*.cfg 2>/dev/null | sort -u | tr '\n' ' '; echo
[[ -n $K && -n $I && -n $BASE ]] || { echo "U 盘里的文件和预期不同，已取消"; exit 1; }
cat ${U:+"$U"} "$I" > /run/l4c-initrd.img
CMD="misobasedir=$BASE misolabel=$LABEL driver=free nouveau.modeset=1 i915.modeset=1 radeon.modeset=1 quiet"
echo "启动参数：$CMD"
kexec -l "$K" --initrd=/run/l4c-initrd.img --append="$CMD"
echo; echo "准备就绪。10 秒后切换到 U 盘系统（屏幕会黑一下），按 Ctrl+C 可以取消。"
sleep 10
systemctl kexec
