#!/usr/bin/env bash
# 全新安装：在 Manjaro、CachyOS 或 Arch 的启动 U 盘（Live 系统）里运行，把优化版系统装到 Chromebook 的 eMMC 上。
# 用哪个发行版的 U 盘启动，就装哪个发行版（CachyOS 会用按 x86-64-v3 编译的软件源）。
#
#   sudo ./install/install.sh
#
# 与官方安装器的区别：
#   • btrfs + zstd 透明压缩（系统文件通常压缩到原来的 50~70%）
#   • 不建 8G swap，改用 zram 压缩内存 + 1G 兜底 swap 文件
#   • 精简的 Xfce 桌面，Windows 11 使用习惯，Chromebook 键盘/声卡适配
#   • 可以选择迁移包（export.sh 生成），自动还原软件、设置、个人文件、Wi-Fi
#
# 环境变量（可选）：KERNEL=内核包名（默认 Manjaro linux618 / CachyOS linux-cachyos / Arch linux）
#   MIRROR_COUNTRY=China  SWAP_GB=1
#   L4C_BACKUP_URL=http://IP:8848/口令   预先填好迁移包地址（例如通过 ssh -R 隧道从 Windows 获取）
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

DISTRO=$(l4c_distro)
case $DISTRO in
  manjaro) DEF_KERNEL=linux618 BOOT_ID=Manjaro ;;
  cachyos) DEF_KERNEL=linux-cachyos BOOT_ID=CachyOS ;;
  arch)    DEF_KERNEL=linux BOOT_ID=Arch ;;
  *) die "请在 Manjaro、CachyOS 或 Arch 的启动 U 盘里运行本安装器（当前系统：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}")）。" ;;
esac
KERNEL="${KERNEL:-$DEF_KERNEL}"
SWAP_GB="${SWAP_GB:-1}"
MNT=/mnt
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

require_root
[[ -d /sys/firmware/efi ]] || die "没有以 UEFI 模式启动。原厂固件请在开发者模式下按 Ctrl+L 进入 RW_LEGACY（UEFI）再选 U 盘；或者刷 MrChromebox 的 UEFI 固件（mrchromebox.tech）。"
# 原厂固件（开发者模式 + RW_LEGACY）：固件在主板芯片里，清空 eMMC 不会影响它
STOCK_FW=0; grep -qi '^Google_' /sys/class/dmi/id/bios_version 2>/dev/null && STOCK_FW=1
mountpoint -q "$MNT" && die "$MNT 已被挂载，请先卸载：umount -R $MNT"

# 完整输出同时记到日志：出错时屏幕可能已经被清掉（例如在 screen 里运行），装完会复制到新系统的 /var/log
LOG=/tmp/l4c-install.log
exec > >(tee -a "$LOG") 2>&1
cleanup() { umount -R "$MNT" 2>/dev/null || true; }
# 只在主进程里报「中断」（子进程里的命令失败不代表安装失败）
trap '((BASH_SUBSHELL)) || { warn "安装中断，完整输出见 $LOG。可以修正问题后重新运行。"; cleanup; }' ERR

echo "
  ┌──────────────────────────────────────────────────────┐
  │   linux-for-chromebook $L4C_VERSION 安装器                    │
  │   ！！！所选硬盘上的所有数据都会被清空！！！         │
  │   请先用 export.sh 把旧系统导出到 U 盘。             │
  └──────────────────────────────────────────────────────┘"

# ------------------------------------------------------------ 1. 网络 ----
info "检查网络"
net_ok() { local u; for u in https://manjaro.org https://archlinux.org https://cachyos.org; do curl -fsS -m 10 -o /dev/null "$u" 2>/dev/null && return 0; done; return 1; }
until net_ok; do
  warn "无法联网。请点击右下角网络图标连接 Wi-Fi（或运行 nmtui）。"
  confirm "连好后按回车重试，输入 n 退出" y || die "需要网络才能安装"
done
ok "网络正常"

# ------------------------------------------------------------ 2. 迁移包 --
# 来源：U 盘上的迁移包目录，或 Windows 工具通过局域网提供的地址（边下载边导入，不占 U 盘/内存）
BACKUP=""
mapfile -t found < <({ find /run/media /media /mnt -maxdepth 6 -name manifest.env -path '*l4c-backup-*' -printf '%h\n' 2>/dev/null || true; } | sort -r)
echo "迁移包来源："
for i in "${!found[@]}"; do echo "  $((i + 1))) U 盘：${found[$i]}"; done
echo "  w) 从 Windows 电脑通过局域网获取"
echo "  0) 不导入，全新开始"
sel=$(ask "请选择" "$([[ ${#found[@]} -gt 0 && -z ${L4C_BACKUP_URL:-} ]] && echo 1 || echo w)")
if [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#found[@]})); then
  BACKUP=${found[$((sel - 1))]}
elif [[ $sel == w || $sel == W ]]; then
  base=$(ask "Windows 工具里显示的地址（形如 http://192.168.1.10:8848/口令）" "${L4C_BACKUP_URL:-}")
  base=${base%/}
  [[ $base =~ ^https?:// ]] || die "地址格式不对"
  mapfile -t pk < <(curl -fsS -m 15 "$base/" | grep '^l4c-backup-' | sort -r) || true
  ((${#pk[@]})) || die "连不上 Windows 工具或里面没有迁移包。请确认工具正在运行、两台设备连着同一个 Wi-Fi。"
  for i in "${!pk[@]}"; do echo "  $((i + 1))) ${pk[$i]}"; done
  n=$(ask "导入哪一个？" 1)
  [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#pk[@]})) || die "无效选择"
  BACKUP="$base/${pk[$((n - 1))]}"
elif [[ $sel != 0 && -f $sel/manifest.env ]]; then
  BACKUP=$(readlink -f "$sel")
fi
declare -A M=()
if [[ -n $BACKUP ]]; then
  if [[ $BACKUP =~ ^https?:// ]]; then manifest=$(curl -fsS "$BACKUP/manifest.env") || die "无法读取迁移包"
  else manifest=$(cat "$BACKUP/manifest.env")
  fi
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] && M[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <<<"$manifest"
  ok "将导入：$BACKUP（来自 ${M[HOSTNAME]:-?}，用户 ${M[USERNAME]:-?}）"
fi

# ------------------------------------------------------------ 3. 硬盘 ----
live_disk=""
src=$(findmnt -no SOURCE "$(live_bootmnt)" 2>/dev/null || true)
if [[ -n $src ]]; then
  live_disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  # 整盘写入的 ISO（或 kexec 启动）时 bootmnt 直接是整块盘，没有父设备
  [[ -n $live_disk ]] || live_disk=$(basename "$src")
fi
# 排除 eMMC 的硬件引导区 mmcblkXbootY / rpmb：它们也显示为 disk，但只有几 MB，不能装系统
mapfile -t disks < <(lsblk -dpno NAME,SIZE,TYPE,MODEL | awk '$3=="disk" && $1 !~ /(zram|loop|sr|boot[0-9]+$|rpmb$)/' | grep -v "^/dev/${live_disk:-NONE} " || true)
((${#disks[@]})) || die "找不到可安装的硬盘"
echo "可安装的硬盘："; for i in "${!disks[@]}"; do echo "  $((i + 1))) ${disks[$i]}"; done
def=1; for i in "${!disks[@]}"; do [[ ${disks[$i]} == /dev/mmcblk* ]] && { def=$((i + 1)); break; }; done
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
confirm "启用 Windows 11 风格桌面（居中任务栏、Win 快捷键）？$([[ -n $BACKUP ]] && echo '选「否」则保留迁移包里你原来的桌面布局')" "$WIN11" && WIN11=y || WIN11=n
AUDIO=y; confirm "安装 Chromebook 声卡驱动（社区脚本）？" y || AUDIO=n

echo
echo "  硬盘:     $DISK （将被清空）"
echo "  电脑名称: $HOSTNAME_    用户: $USERNAME_    时区: $TIMEZONE_    语言: $LOCALE_"
echo "  内核:     $KERNEL       桌面: Xfce（Win11 风格: $WIN11）"
echo "  迁移包:   ${BACKUP:-无}"
echo
# 以后想装回原厂 ChromeOS 需要原厂固件备份；硬盘清空前提醒一次
if grep -qi mrchromebox /sys/class/dmi/id/bios_version 2>/dev/null; then
  has_fw=0
  if [[ $BACKUP =~ ^https?:// ]]; then curl -fsS "$BACKUP/" 2>/dev/null | grep -q '^firmware/' && has_fw=1
  elif [[ -n $BACKUP && -d $BACKUP/firmware ]]; then has_fw=1
  fi
  find /run/media -maxdepth 5 -iname '*stock*.rom' 2>/dev/null | grep -q . && has_fw=1
  if ((has_fw == 0)); then
    warn "没有在迁移包或 U 盘上找到原厂固件备份（*stock*.rom）。"
    warn "如果以后想装回原厂 ChromeOS（含安卓应用），需要这个备份；只装 ChromeOS Flex 则不需要。"
    confirm "仍然继续安装？" y || die "已取消。可以先在旧系统里运行 l4c chromeos backup-firmware"
  fi
fi
if ((STOCK_FW)); then
  warn "这台 Chromebook 是原厂固件（开发者模式启动 Linux）。装好后每次开机："
  warn "  出现「操作系统验证已关闭」时按 Ctrl+L 启动新系统；千万不要按空格，否则会恢复 ChromeOS 并清空硬盘。"
  warn "  想装回 ChromeOS 也很简单：用官方恢复 U 盘即可（l4c chromeos check）。"
fi
[[ $(ask "确认清空 $DISK 并安装？请输入大写 YES" "") == YES ]] || die "已取消，硬盘未做任何改动"
WIPE=n; confirm "安装前彻底擦除整块硬盘的旧数据（旧系统和个人文件将无法被恢复，约 1~10 分钟）？" y && WIPE=y
L4C_YES_SAVED=$L4C_YES

# ------------------------------------------------------------ 5. 分区 ----
umount -R "$DISK"* 2>/dev/null || true
swapoff -a 2>/dev/null || true
if [[ $WIPE == y ]]; then
  L4C_WIPE_CONFIRMED=1 bash "$L4C_ROOT/setup/wipe.sh" disk "$DISK"
fi
info "分区并格式化 $DISK"
wipefs -af "$DISK" >/dev/null
sfdisk --wipe always --label gpt "$DISK" >/dev/null <<EOF
,512M,U
,,L
EOF
udevadm settle; sleep 1
mkfs.fat -F32 -n EFI "$ESP" >/dev/null
mkfs.btrfs -f -L "$BOOT_ID" "$ROOT" >/dev/null
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
L4C_YES=1 bash "$L4C_ROOT/setup/wipe.sh" efi || warn "清理旧启动项失败，不影响安装"

# ------------------------------------------------------------ 6. 安装 ----
info "准备软件源（$DISTRO）"
# CachyOS 的启动 U 盘只配了通用的 [cachyos] 源，官方安装器装的时候才按 CPU 加优化源。
# N100 支持 x86-64-v3（AVX2），这里同样加上 v3 源，系统软件就会换成 v3 编译的版本；下面 pacstrap -P 会把这份配置带进新系统
cachyos_v3_repos() {
  /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3 (supported, searched)' ||
    { warn "CPU 不支持 x86-64-v3，使用通用软件源"; return 0; }
  grep -q '^\[cachyos-v3\]' /etc/pacman.conf && return 0
  [[ -f /etc/pacman.d/cachyos-v3-mirrorlist ]] || pacman -Sy --noconfirm --needed cachyos-v3-mirrorlist >/dev/null
  local r v3=""
  for r in cachyos-v3 cachyos-core-v3 cachyos-extra-v3; do v3+="[$r]"$'\n'"Include = /etc/pacman.d/cachyos-v3-mirrorlist"$'\n\n'; done
  V3=$v3 awk '/^\[(cachyos|core)\]/ && !d { printf "%s", ENVIRON["V3"]; d = 1 } { print }' /etc/pacman.conf >/tmp/l4c-pacman.conf
  cat /tmp/l4c-pacman.conf >/etc/pacman.conf
  ok "已启用 CachyOS x86-64-v3 优化软件源"
}
case $DISTRO in
  manjaro)
    if [[ -n ${MIRROR_COUNTRY:-} ]]; then pacman-mirrors -c "$MIRROR_COUNTRY" >/dev/null 2>&1 || true
    else pacman-mirrors --fasttrack 5 >/dev/null 2>&1 || true
    fi ;;
  arch)
    have reflector && reflector --latest 10 --protocol https --sort rate ${MIRROR_COUNTRY:+--country "$MIRROR_COUNTRY"} \
      --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 || true ;;
  cachyos)
    have cachyos-rate-mirrors && cachyos-rate-mirrors >/dev/null 2>&1 || true
    cachyos_v3_repos ;;
esac
pacman -Syy --noconfirm >/dev/null
# 装系统用的工具：Manjaro 是 basestrap / manjaro-chroot / fstabgen，Arch 系是 pacstrap / arch-chroot / genfstab
if [[ $DISTRO == manjaro ]]; then
  pacman -Q manjaro-tools-base >/dev/null 2>&1 || pacman -S --noconfirm --needed manjaro-tools-base >/dev/null
  STRAP=(basestrap) CHROOT=manjaro-chroot FSTAB=fstabgen
else
  # -K：给新系统初始化自己的密钥；-P：带上 Live 系统的软件源配置（包括上面加的 CachyOS v3 源）
  pacman -Q arch-install-scripts >/dev/null 2>&1 || pacman -S --noconfirm --needed arch-install-scripts >/dev/null
  STRAP=(pacstrap -K -P) CHROOT=arch-chroot FSTAB=genfstab
fi
have "${STRAP[0]}" || die "缺少 ${STRAP[0]}"

pkgs=()
mapfile -t -O 0 pkgs < <(for f in base "base-$DISTRO" desktop; do [[ -f $L4C_ROOT/install/packages/$f.txt ]] && read_list "$L4C_ROOT/install/packages/$f.txt"; done)
pkgs+=("$KERNEL")
# 2025 年起 linux-firmware 拆分成按厂商的子包，只装 Intel 的能省几百 MB
if pacman -Si linux-firmware-intel >/dev/null 2>&1; then pkgs+=(linux-firmware-intel linux-firmware-whence)
else pkgs+=(linux-firmware)
fi
mapfile -t pkgs < <(pkg_filter_available "${pkgs[@]}")
printf '%s\n' "${pkgs[@]}" | grep -qx "$KERNEL" || die "软件源里没有内核 $KERNEL，请用 KERNEL=内核包名 指定（pacman -Ss ^linux 查看）"

info "安装 ${#pkgs[@]} 个软件包（10~30 分钟，取决于网速）"
"${STRAP[@]}" "$MNT" "${pkgs[@]}"
"$FSTAB" -U "$MNT" >"$MNT/etc/fstab"
# pacstrap -K 给新系统建的是空密钥环，导入发行版的签名密钥，否则以后更新会校验失败
case $DISTRO in
  arch)    "$CHROOT" "$MNT" pacman-key --populate archlinux >/dev/null ;;
  cachyos)
    "$CHROOT" "$MNT" pacman-key --populate archlinux cachyos >/dev/null
    # Live 系统给 [cachyos] 源关了签名校验（TrustAll），新系统里恢复成默认的必须校验
    sed -i '/^SigLevel *= *Optional TrustAll$/d' "$MNT/etc/pacman.conf" ;;
esac

info "创建 ${SWAP_GB}G 兜底 swap 文件"
btrfs filesystem mkswapfile --size "${SWAP_GB}g" "$MNT/swap/swapfile" >/dev/null
echo "/swap/swapfile none swap defaults,pri=-2 0 0" >>"$MNT/etc/fstab"

# 把本项目复制进新系统，以后可以直接用 l4c 命令
mkdir -p "$MNT/opt"
cp -r "$L4C_ROOT" "$MNT/opt/linux-for-chromebook"   # 从 U 盘（exFAT）复制时没有权限位，下面补上
rm -rf "$MNT/opt/linux-for-chromebook/.git"
chmod -R u=rwX,go=rX "$MNT/opt/linux-for-chromebook"
chmod +x "$MNT"/opt/linux-for-chromebook/{bin/l4c,setup/*.sh,migrate/*.sh,install/*.sh}
ln -sf /opt/linux-for-chromebook/bin/l4c "$MNT/usr/local/bin/l4c"

if [[ -n $BACKUP && ! $BACKUP =~ ^https?:// ]]; then
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
BACKUP=$(if [[ $BACKUP =~ ^https?:// ]]; then echo "$BACKUP"; elif [[ -n $BACKUP ]]; then echo /mnt/l4c-backup; fi)
USER_SHELL=${M[USER_SHELL]:-/usr/bin/zsh}
BOOT_ID=$BOOT_ID
EOF

info "配置新系统"
L4C_YES=$L4C_YES_SAVED "$CHROOT" "$MNT" bash /opt/linux-for-chromebook/install/chroot-setup.sh

if [[ -n $BACKUP && ! $BACKUP =~ ^https?:// ]]; then umount "$MNT/mnt/l4c-backup" 2>/dev/null || true; fi
rm -f "$MNT/root/l4c-install.env"
trap - ERR
cp "$LOG" "$MNT/var/log/l4c-install.log" 2>/dev/null || true
sync
cleanup
ok "安装完成！"
echo "拔掉 U 盘后重启。首次登录会自动应用设置，之后可以用 l4c 命令管理（l4c help）。"
((STOCK_FW)) && echo "开机出现「操作系统验证已关闭」时按 Ctrl+L（不要按空格）。"
if confirm "现在重启？" y; then reboot; fi
