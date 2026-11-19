#!/usr/bin/env bash
# shellcheck disable=SC2012
# 设备扫描：生成一份详细的硬件 / 存储 / 软件状态报告（Markdown），用于排查问题和针对性优化。
#   sudo ./setup/scan.sh                      报告保存到 ~/l4c-scan-主机名-时间.md
#   sudo ./setup/scan.sh --send http://IP:8848/口令   同时发送到 Windows 工具
# 报告不包含任何密码，但包含主机名、IP、MAC 地址等，分享前请自行检查。
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

SEND=""
case "${1:-}" in
  --send) SEND=${2:?需要地址}; SEND=${SEND%/} ;;
  -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
  "") ;;
  *) die "未知参数: $1" ;;
esac
require_root

U=$(target_user); H=$(user_home "$U")
SCAN_NAME="l4c-scan-$(hostname | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')-$(date +%Y%m%d-%H%M)"
OUT="$H/$SCAN_NAME.md"

sec() { printf '\n## %s\n\n' "$1"; }
code() { # 标题 命令…  —— 把命令输出放进代码块，失败也不中断
  printf '**%s**\n\n```\n' "$1"; shift
  "$@" 2>&1 | head -n 200 || true
  printf '```\n\n'
}
rd() { cat "$1" 2>/dev/null || echo "?"; }

info "扫描设备，请稍候（约 1 分钟）……"
# 报告尽力而为：某一项读不到不影响其他项
set +e +o pipefail; trap - ERR
{
  echo "# 设备扫描报告：$(hostname)"
  echo
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')　工具版本：linux-for-chromebook $L4C_VERSION"

  sec "概要"
  d=/sys/class/dmi/id
  echo "| 项目 | 值 |"
  echo "|---|---|"
  echo "| 机型 | $(rd $d/sys_vendor) $(rd $d/product_name) ($(rd $d/product_version)) |"
  echo "| 主板代号 | $(rd $d/board_name) |"
  echo "| 固件 | $(rd $d/bios_vendor) $(rd $d/bios_version) ($(rd $d/bios_date)) |"
  echo "| 系统 | $(. /etc/os-release; echo "$PRETTY_NAME") |"
  echo "| 内核 | $(uname -r) |"
  echo "| 启动参数 | \`$(cat /proc/cmdline)\` |"
  echo "| CPU | $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) × $(nproc) |"
  echo "| 内存 | $(free -h | awk '/^Mem:/{print $2 " 总，" $3 " 已用，" $7 " 可用"}') |"
  echo "| 根分区 | $(df -h --output=fstype,size,used,avail,pcent / | tail -1 | awk '{print $1 "，" $2 " 总，" $3 " 已用，" $4 " 可用（" $5 "）"}') |"
  echo "| 桌面 | ${XDG_CURRENT_DESKTOP:-$(ls /usr/share/xsessions 2>/dev/null | tr '\n' ' ')} |"
  echo "| 软件包 | $(pacman -Qq 2>/dev/null | wc -l) 个（手动安装 $(pacman -Qqe 2>/dev/null | wc -l)，AUR $(pacman -Qqm 2>/dev/null | wc -l)）$(have flatpak && echo "，Flatpak $(flatpak list --app 2>/dev/null | wc -l)") |"

  sec "固件与启动"
  if grep -qi mrchromebox $d/bios_version 2>/dev/null; then
    echo "- 固件类型：MrChromebox UEFI 完整固件（已替换原厂固件；恢复原厂 ChromeOS 需要先恢复原厂固件）"
  elif grep -qi '^Google_' $d/bios_version 2>/dev/null; then
    echo "- 固件类型：原厂 ChromeOS 固件（RW_LEGACY / 开发者模式启动）"
  else
    echo "- 固件类型：未知"
  fi
  echo "- UEFI 启动：$([[ -d /sys/firmware/efi ]] && echo 是 || echo 否)"
  stock=$(find "$H" /run/media -maxdepth 4 -iname '*stock*.rom' 2>/dev/null | head -5 | tr '\n' ' ')
  echo "- 原厂固件备份：${stock:-未在主目录 / U 盘上找到（恢复原厂 ChromeOS 时需要，见 l4c chromeos check）}"
  echo
  have efibootmgr && code "UEFI 启动项" efibootmgr -v

  sec "内存"
  code "内存与 swap" free -h
  code "zram" zramctl
  code "swap 设备" swapon --show
  code "内存占用前 15 的进程（RSS 单位 KB）" bash -c "ps -eo pid,user,rss,pmem,comm --sort=-rss | head -16"
  code "内核内存参数" sysctl vm.swappiness vm.page-cluster vm.vfs_cache_pressure vm.watermark_scale_factor
  echo "- zswap：$(rd /sys/module/zswap/parameters/enabled)　earlyoom：$(systemctl is-active earlyoom 2>/dev/null || true)"

  sec "存储"
  code "磁盘与分区" lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,DISC-GRAN
  code "文件系统使用" df -hT -x tmpfs -x devtmpfs -x efivarfs
  code "挂载选项" findmnt -no TARGET,FSTYPE,OPTIONS -t ext4,btrfs,vfat,exfat
  for m in /sys/class/mmc_host/mmc*/mmc*; do
    [[ -e $m/type && $(cat "$m/type") == MMC ]] || continue
    echo "**eMMC 健康状况（$(basename "$m")：$(rd "$m/name")）**"
    echo
    echo "- 寿命估计 life_time（A / B，0x01 = 已用 0-10%，0x0B = 已超出寿命）：$(rd "$m/life_time")"
    echo "- 预留块状态 pre_eol_info（0x01 正常，0x02 警告，0x03 紧急）：$(rd "$m/pre_eol_info")"
    echo "- 生产日期：$(rd "$m/date")　厂商 ID：$(rd "$m/manfid")"
    echo
  done
  [[ $(findmnt -no FSTYPE /) == btrfs ]] && have compsize && code "btrfs 压缩效果" compsize -x /
  code "根分区占用最大的目录（前 25）" bash -c "du -xh --max-depth=3 / 2>/dev/null | sort -rh | head -25"
  code "主目录占用最大的目录（前 20）" bash -c "du -xh --max-depth=2 '$H' 2>/dev/null | sort -rh | head -20"
  code "占空间最大的软件包（前 25）" bash -c "LC_ALL=C pacman -Qi 2>/dev/null | awk -F': ' '/^Name/{n=\$2} /^Installed Size/{s=\$2; split(s,a,\" \"); v=a[1]; u=a[2]; m=(u==\"GiB\")?1024:(u==\"MiB\")?1:(u==\"KiB\")?1/1024:1/1048576; printf \"%8.1f MiB  %s\n\", v*m, n}' | sort -rn | head -25"
  echo "- 软件包缓存：$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)　系统日志：$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)　用户缓存：$(du -sh "$H/.cache" 2>/dev/null | cut -f1)"
  have flatpak && code "Flatpak 应用和运行库" flatpak list --columns=application,size

  sec "显卡与视频解码"
  code "显卡" bash -c "lspci -k | grep -A3 -Ei 'vga|3d|display'"
  have vainfo && code "VA-API 硬件解码" bash -c "vainfo 2>&1 | grep -E 'Driver|VAProfile(H264|HEVC|VP9|AV1)' | head -20"
  code "显示器" bash -c "cat /sys/class/drm/*/modes 2>/dev/null | head -3; ls /sys/class/drm | grep -v version"

  sec "声卡"
  code "声卡设备" bash -c "cat /proc/asound/cards; echo; aplay -l 2>/dev/null"
  code "声卡驱动日志" bash -c "dmesg 2>/dev/null | grep -Ei 'sof|snd|audio|max98|rt56|da7219|cs35|cs42' | tail -25"
  have pactl && code "PipeWire 输出设备" bash -c "sudo -u '$U' XDG_RUNTIME_DIR=/run/user/$(id -u "$U") pactl list short sinks 2>&1"

  sec "网络与蓝牙"
  code "网卡" bash -c "lspci -k | grep -A3 -Ei 'network|wireless|ethernet'; ip -br link"
  have nmcli && code "NetworkManager" nmcli -f DEVICE,TYPE,STATE,CONNECTION device
  have bluetoothctl && code "蓝牙" bash -c "bluetoothctl show 2>&1 | head -8"

  sec "键盘与触控板"
  f=$(find /sys/devices/platform -name function_row_physmap 2>/dev/null | head -1)
  echo "- 顶排按键扫描码（function_row_physmap）：\`$(rd "${f:-/nonexistent}")\`"
  echo "- keyd：$(systemctl is-active keyd 2>/dev/null || true)，配置：$(ls /etc/keyd/ 2>/dev/null | tr '\n' ' ')"
  echo
  code "输入设备" bash -c "grep -E '^(N|I|H):' /proc/bus/input/devices"

  sec "电池与温度"
  for b in /sys/class/power_supply/*; do
    [[ $(rd "$b/type") == Battery ]] || continue
    full=$(rd "$b/energy_full"); design=$(rd "$b/energy_full_design")
    [[ $full == "?" ]] && { full=$(rd "$b/charge_full"); design=$(rd "$b/charge_full_design"); }
    health="?"; [[ $full =~ ^[0-9]+$ && $design =~ ^[0-9]+$ && $design -gt 0 ]] && health="$((full * 100 / design))%"
    echo "- $(basename "$b")：电量 $(rd "$b/capacity")%，状态 $(rd "$b/status")，电池健康 $health，循环次数 $(rd "$b/cycle_count")"
  done
  for z in /sys/class/thermal/thermal_zone*; do
    t=$(rd "$z/temp"); [[ $t =~ ^[0-9]+$ ]] && echo "- 温度 $(rd "$z/type")：$((t / 1000))°C"
  done

  sec "服务与启动速度"
  code "启动耗时" systemd-analyze
  code "最慢的启动项（前 15）" bash -c "systemd-analyze blame 2>/dev/null | head -15"
  code "失败的服务" systemctl --failed --no-legend
  code "已启用的服务" bash -c "systemctl list-unit-files --state=enabled --no-legend | awk '{print \$1}' | tr '\n' ' '"
  code "开机自启的桌面程序" bash -c "ls /etc/xdg/autostart '$H/.config/autostart' 2>/dev/null"

  sec "linux-for-chromebook 优化状态"
  for f in /etc/systemd/zram-generator.conf /etc/sysctl.d/99-l4c.conf /etc/default/earlyoom \
           /etc/systemd/journald.conf.d/50-l4c-size.conf /etc/pacman.d/hooks/l4c-clean-cache.hook \
           /etc/udev/rules.d/60-l4c-ioscheduler.rules /etc/keyd/l4c-chromebook.conf \
           /etc/X11/xorg.conf.d/30-l4c-touchpad.conf /usr/lib/firefox/defaults/pref/l4c-chromebook.js; do
    echo "- $([[ -e $f ]] && echo '✓' || echo '✗') \`$f\`"
  done
  echo "- pacman NoExtract：$(grep -q 'l4c:noextract' /etc/pacman.conf 2>/dev/null && echo '✓' || echo '✗')"

  sec "最近的错误日志"
  code "本次启动的错误（最后 40 条）" journalctl -b -p err --no-pager -q -n 40
} >"$OUT" 2>/dev/null
set -e -o pipefail

chown "$U:" "$OUT"
ok "报告已保存：$OUT（$(wc -l <"$OUT") 行）"
if [[ -n $SEND ]]; then
  curl -fsS -T "$OUT" -o /dev/null "$SEND/$SCAN_NAME/report.md" && ok "已发送到 Windows 工具（$SCAN_NAME）" || warn "发送失败"
fi
