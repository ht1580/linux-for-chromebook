#!/usr/bin/env bash
# 全新安装：在 Manjaro 启动 U 盘（Live 系统）里运行，把优化版系统装到 Chromebook 的 eMMC 上。
#
#   sudo ./install/install.sh
#
# 与官方安装器的区别：
#   • btrfs + zstd 透明压缩（系统文件通常压缩到原来的 50~70%）
#   • 不建 8G swap，改用 zram 压缩内存 + 2G 兜底 swap 文件
#   • 精简的 Xfce 桌面，Windows 11 使用习惯，Chromebook 键盘/声卡适配
#   • 可以选择迁移包（export.sh 生成），自动还原软件、设置、个人文件、Wi-Fi
#
# 环境变量（可选）：KERNEL=linux618  MIRROR_COUNTRY=China  SWAP_GB=2
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

KERNEL="${KERNEL:-linux618}"
SWAP_GB="${SWAP_GB:-2}"
MNT=/mnt
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

require_root
[[ -d /sys/firmware/efi ]] || die "没有以 UEFI 模式启动。Chromebook 需要先刷 MrChromebox 的 UEFI 固件（mrchromebox.tech）。"
grep -qi manjaro /etc/os-release || die "请在 Manjaro 的启动 U 盘里运行本安装器。"
mountpoint -q "$MNT" && die "$MNT 已被挂载，请先卸载：umount -R $MNT"

cleanup() { umount -R "$MNT" 2>/dev/null || true; }
trap 'warn "安装中断。可以修正问题后重新运行。"; cleanup' ERR

echo "
  ┌──────────────────────────────────────────────────────┐
  │   linux-for-chromebook $L4C_VERSION 安装器                    │
  │   ！！！所选硬盘上的所有数据都会被清空！！！         │
  │   请先用 export.sh 把旧系统导出到 U 盘。             │
  └──────────────────────────────────────────────────────┘"

# ------------------------------------------------------------ 1. 网络 ----
info "检查网络"
until curl -fsS -m 10 -o /dev/null https://manjaro.org 2>/dev/null; do
  warn "无法联网。请点击右下角网络图标连接 Wi-Fi（或运行 nmtui）。"
  confirm "连好后按回车重试，输入 n 退出" y || die "需要网络才能安装"
done
ok "网络正常"

# ------------------------------------------------------------ 2. 迁移包 --
BACKUP=""
mapfile -t found < <(find /run/media /media /mnt -maxdepth 4 -name manifest.env -path '*l4c-backup-*' -printf '%h\n' 2>/dev/null | sort -r)
if ((${#found[@]})); then
  echo "找到迁移包："; for i in "${!found[@]}"; do echo "  $((i + 1))) ${found[$i]}"; done
  sel=$(ask "导入哪一个？（输入编号，0 = 不导入）" 1)
  if [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#found[@]})); then BACKUP=${found[$((sel - 1))]}; fi
else
  p=$(ask "迁移包路径（没有就直接回车）" "")
  [[ -n $p ]] && { [[ -f $p/manifest.env ]] || die "$p 里没有 manifest.env"; BACKUP=$(readlink -f "$p"); }
fi
declare -A M=()
if [[ -n $BACKUP ]]; then
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] && M[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$BACKUP/manifest.env"
  ok "将导入：$BACKUP"
fi

# ------------------------------------------------------------ 3. 硬盘 ----
live_disk=""
src=$(findmnt -no SOURCE /run/miso/bootmnt 2>/dev/null || true)
[[ -n $src ]] && live_disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
mapfile -t disks < <(lsblk -dpno NAME,SIZE,TYPE,MODEL | awk '$3=="disk" && $1 !~ /(zram|loop|sr)/' | grep -v "^/dev/${live_disk:-NONE} ")
((${#disks[@]})) || die "找不到可安装的硬盘"
echo "可安装的硬盘："; for i in "${!disks[@]}"; do echo "  $((i + 1))) ${disks[$i]}"; done
def=1; for i in "${!disks[@]}"; do [[ ${disks[$i]} == /dev/mmcblk* ]] && def=$((i + 1)); done
sel=$(ask "安装到哪块硬盘？" "$def")
[[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#disks[@]})) || die "无效选择"
DISK=$(awk '{print $1}' <<<"${disks[$((sel - 1))]}")
part() { [[ $1 =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }
ESP=$(part "$DISK" 1) ROOT=$(part "$DISK" 2)

# ------------------------------------------------------------ 4. 设置 ----
HOSTNAME_=$(ask "电脑名称" "${M[HOSTNAME]:-chromebook}")
USERNAME_=$(ask "用户名（小写英文）" "${M[USERNAME]:-user}")
[[ $USERNAME_ =~ ^[a-z_][a-z0-9_-]*$ ]] || die "用户名只能用小写字母、数字、下划线"
FULLNAME_=$(ask "显示名称" "${M[FULLNAME]:-$USERNAME_}")
TIMEZONE_=$(ask "时区" "${M[TIMEZONE]:-Asia/Shanghai}")
[[ -e /usr/share/zoneinfo/$TIMEZONE_ ]] || die "无效时区 $TIMEZONE_"
LOCALE_=$(ask "系统语言" "${M[LOCALE]:-zh_CN.UTF-8}")
WIN11=y; [[ -n $BACKUP ]] && WIN11=n
confirm "启用 Windows 11 风格桌面（居中任务栏、Win 快捷键）？$([[ -n $BACKUP ]] && echo '选“否”则保留迁移包里你原来的桌面布局')" "$WIN11" && WIN11=y || WIN11=n
AUDIO=y; confirm "安装 Chromebook 声卡驱动（社区脚本）？" y || AUDIO=n

echo
echo "  硬盘:     $DISK （将被清空）"
echo "  电脑名称: $HOSTNAME_    用户: $USERNAME_    时区: $TIMEZONE_    语言: $LOCALE_"
echo "  内核:     $KERNEL       桌面: Xfce（Win11 风格: $WIN11）"
echo "  迁移包:   ${BACKUP:-无}"
echo
[[ $(ask "确认清空 $DISK 并安装？请输入大写 YES" "") == YES ]] || die "已取消，硬盘未做任何改动"
L4C_YES_SAVED=$L4C_YES

# ------------------------------------------------------------ 5. 分区 ----
info "分区并格式化 $DISK"
umount -R "$DISK"* 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK" >/dev/null
sfdisk --wipe always --label gpt "$DISK" >/dev/null <<EOF
,512M,U
,,L
EOF
udevadm settle; sleep 1
mkfs.fat -F32 -n EFI "$ESP" >/dev/null
mkfs.btrfs -f -L Manjaro "$ROOT" >/dev/null
mount "$ROOT" "$MNT"
for sv in @ @home @cache @log @swap; do btrfs subvolume create "$MNT/$sv" >/dev/null; done
umount "$MNT"
mount -o "$MOUNT_OPTS,subvol=@" "$ROOT" "$MNT"
mkdir -p "$MNT"/{boot/efi,home,var/cache,var/log,swap}
mount -o "$MOUNT_OPTS,subvol=@home" "$ROOT" "$MNT/home"
mount -o "$MOUNT_OPTS,subvol=@cache" "$ROOT" "$MNT/var/cache"
mount -o "$MOUNT_OPTS,subvol=@log" "$ROOT" "$MNT/var/log"
mount -o "noatime,subvol=@swap" "$ROOT" "$MNT/swap"
mount "$ESP" "$MNT/boot/efi"
ok "btrfs（zstd 压缩）分区完成"

# ------------------------------------------------------------ 6. 安装 ----
info "准备软件源"
if [[ -n ${MIRROR_COUNTRY:-} ]]; then pacman-mirrors -c "$MIRROR_COUNTRY" >/dev/null 2>&1 || true
else pacman-mirrors --fasttrack 5 >/dev/null 2>&1 || true
fi
pacman -Syy --noconfirm >/dev/null
pacman -Q manjaro-tools-base >/dev/null 2>&1 || pacman -S --noconfirm --needed manjaro-tools-base >/dev/null
have basestrap || die "缺少 basestrap（manjaro-tools-base）"

pkgs=()
mapfile -t -O 0 pkgs < <(read_list "$L4C_ROOT/install/packages/base.txt"; read_list "$L4C_ROOT/install/packages/desktop.txt")
pkgs+=("$KERNEL")
# 2025 年起 linux-firmware 拆分成按厂商的子包，只装 Intel 的能省几百 MB
if pacman -Si linux-firmware-intel >/dev/null 2>&1; then pkgs+=(linux-firmware-intel linux-firmware-whence)
else pkgs+=(linux-firmware)
fi
mapfile -t pkgs < <(pkg_filter_available "${pkgs[@]}")
printf '%s\n' "${pkgs[@]}" | grep -qx "$KERNEL" || die "软件源里没有内核 $KERNEL，请用 KERNEL=linuxXXX 指定（mhwd-kernel -l 查看）"

info "安装 ${#pkgs[@]} 个软件包（10~30 分钟，取决于网速）"
basestrap "$MNT" "${pkgs[@]}"
fstabgen -U "$MNT" >"$MNT/etc/fstab"

info "创建 ${SWAP_GB}G 兜底 swap 文件"
btrfs filesystem mkswapfile --size "${SWAP_GB}g" "$MNT/swap/swapfile" >/dev/null
echo "/swap/swapfile none swap defaults,pri=-2 0 0" >>"$MNT/etc/fstab"

# 把本项目复制进新系统，以后可以直接用 l4c 命令
mkdir -p "$MNT/opt"
cp -a "$L4C_ROOT" "$MNT/opt/linux-for-chromebook"
ln -sf /opt/linux-for-chromebook/bin/l4c "$MNT/usr/local/bin/l4c"

if [[ -n $BACKUP ]]; then
  mkdir -p "$MNT/mnt/l4c-backup"
  mount --bind "$BACKUP" "$MNT/mnt/l4c-backup"
fi

cat >"$MNT/root/l4c-install.env" <<EOF
HOSTNAME_=$HOSTNAME_
USERNAME_=$USERNAME_
FULLNAME_=$FULLNAME_
TIMEZONE_=$TIMEZONE_
LOCALE_=$LOCALE_
WIN11=$WIN11
AUDIO=$AUDIO
BACKUP=$([[ -n $BACKUP ]] && echo /mnt/l4c-backup)
USER_SHELL=${M[USER_SHELL]:-/usr/bin/zsh}
EOF

info "配置新系统"
L4C_YES=$L4C_YES_SAVED manjaro-chroot "$MNT" /opt/linux-for-chromebook/install/chroot-setup.sh

if [[ -n $BACKUP ]]; then umount "$MNT/mnt/l4c-backup" 2>/dev/null || true; fi
rm -f "$MNT/root/l4c-install.env"
trap - ERR
sync
cleanup
ok "安装完成！"
echo "拔掉 U 盘后重启。首次登录会自动应用设置，之后可以用 l4c 命令管理（l4c help）。"
if confirm "现在重启？" y; then reboot; fi
