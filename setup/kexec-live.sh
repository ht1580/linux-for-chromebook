#!/usr/bin/env bash
# 不经过固件，直接从当前系统「热启动」到 U 盘上的 Live 系统（kexec）。
# 原厂固件的 RW_LEGACY 不保存启动项，Ctrl+L 后又来不及按 Esc 时用它：sudo bash setup/kexec-live.sh
# 支持 Manjaro 的 ISO（miso）和 Arch / CachyOS 的 ISO（archiso）。镜像要直接写进 U 盘（dd，或 Rufus 的 DD 模式）；
# 放在 Ventoy 里的 ISO 文件不支持。
set -eu
M=/run/l4c-iso

# 找 U 盘上的 ISO 分区（文件系统是 iso9660），不假定它一定是 /dev/sda1
ISO=$(lsblk -rpno NAME,FSTYPE,TRAN | awk '$2=="iso9660" {print $1; exit}')
[[ -n $ISO ]] || { echo "没找到写入了 Linux 安装镜像的 U 盘（iso9660 分区），已取消"; exit 1; }
LABEL=$(lsblk -no LABEL "$ISO")
echo "U 盘：$ISO（标签：$LABEL）"

pacman -Q kexec-tools >/dev/null 2>&1 || pacman -S --noconfirm --needed kexec-tools >/dev/null
mkdir -p "$M"; mountpoint -q "$M" || mount -o ro "$ISO" "$M"

first() { local f; for f in "$@"; do [[ -e $f ]] && { echo "$f"; return 0; }; done; return 0; }
K="" I="" U="" CMD=""
if [[ -d $M/arch/boot/x86_64 ]]; then
  # archiso（Arch、CachyOS 等）：/arch/boot/x86_64/vmlinuz-linux*，参数 archisobasedir / archisolabel
  # CachyOS 的 ISO 里有 linux-cachyos 和 linux-cachyos-lts 两个内核：优先用前者，initramfs 按内核名配对
  K=$(first "$M/arch/boot/x86_64/vmlinuz-linux-cachyos" "$M/arch/boot/x86_64/vmlinuz-linux" "$M"/arch/boot/x86_64/vmlinuz-*)
  [[ -n $K ]] && I=$(first "$M/arch/boot/x86_64/initramfs-${K##*/vmlinuz-}.img")
  U=$(first "$M/arch/boot/intel-ucode.img" "$M/boot/intel-ucode.img")
  # copytoram=n：不把 2~3 GB 的系统镜像复制进内存（这台只有 4G，U 盘一直插着）；cow_spacesize：Live 里装软件的临时空间
  CMD="archisobasedir=arch archisolabel=$LABEL copytoram=n cow_spacesize=1G i915.modeset=1 quiet"
else
  # miso（Manjaro）：/boot/vmlinuz-x86_64，参数 misobasedir / misolabel
  K=$(first "$M/boot/vmlinuz-x86_64" "$M"/boot/vmlinuz*)
  I=$(first "$M/boot/initramfs-x86_64.img" "$M"/boot/initramfs*[!k].img)
  U=$(first "$M/boot/intel_ucode.img")
  BASE=""; for d in "$M"/*/; do [[ -d $d/x86_64 ]] && { BASE=$(basename "$d"); break; }; done
  [[ -n $BASE ]] && CMD="misobasedir=$BASE misolabel=$LABEL driver=free i915.modeset=1 quiet"
fi
echo "内核：${K:-?}"; echo "initramfs：${I:-?}"; echo "微码：${U:-无}"
[[ -n $K && -n $I && -n $CMD ]] || { echo "U 盘里的文件和预期不同（不是 Manjaro / Arch / CachyOS 的安装镜像？），已取消"; exit 1; }

cat ${U:+"$U"} "$I" > /run/l4c-initrd.img
echo "启动参数：$CMD"
kexec -l "$K" --initrd=/run/l4c-initrd.img --append="$CMD"
echo; echo "准备就绪。10 秒后切换到 U 盘系统（屏幕会黑一下），按 Ctrl+C 可以取消。"
sleep 10
systemctl kexec
