#!/usr/bin/env bash
# 装回 ChromeOS 的工具。
#   ./setup/chromeos.sh check            检查当前固件状态，给出装回 ChromeOS 的具体路线
#   ./setup/chromeos.sh images [主板]     列出本机型可用的原厂 ChromeOS 恢复镜像（含下载地址和校验值）
#   ./setup/chromeos.sh backup-firmware  把找到的原厂固件备份复制到迁移包/U 盘以免丢失
#   sudo ./setup/chromeos.sh firmware    启动 MrChromebox 固件工具（恢复原厂固件用，务必先读说明）
#
# 两条路线：
#   A. ChromeOS Flex：不用动固件，直接用 U 盘安装。没有安卓应用 / Play 商店。
#   B. 原厂 ChromeOS：完整功能（安卓应用、自动更新），但必须先把固件恢复成原厂固件。
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

RECOVERY_JSON=https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json
FLEX_URL=https://dl.google.com/chromeos-flex/images/latest.bin.zip
MRCB=https://mrchromebox.tech/firmware-util.sh
DMI=/sys/class/dmi/id

board() { local b; b=$(cat "$DMI/board_name" 2>/dev/null) || b=UNKNOWN; echo "${b^^}"; }
fw_type() {
  local v; v=$(cat "$DMI/bios_version" 2>/dev/null || true)
  if [[ $v == *MrChromebox* ]]; then echo uefi
  elif [[ $v == Google_* ]]; then echo stock
  else echo unknown
  fi
}
find_stock_backups() {
  find "$(user_home "$(target_user)")" /run/media /media /mnt -maxdepth 5 -type f \
    \( -iname 'stock-firmware*.rom' -o -iname '*stock*.rom' -o -iname "*$(board)*.rom" \) 2>/dev/null | sort -u || true
}

do_check() {
  local t b backups
  t=$(fw_type); b=$(board)
  echo "机型主板：$b"
  echo "当前固件：$(cat "$DMI/bios_vendor" 2>/dev/null) $(cat "$DMI/bios_version" 2>/dev/null)"
  backups=$(find_stock_backups)
  echo "原厂固件备份：${backups:-没有找到}"
  echo
  case $t in
    stock)
      cat <<EOF
✓ 你的固件仍是原厂固件，装回 ChromeOS 很简单：
  1. 在 Windows 上用工具「ChromeOS 恢复工具」下载本机型（$b）的恢复镜像并写入 U 盘
     或用 Chrome 浏览器的「Chromebook 恢复实用工具」直接制作
  2. 关机，按住 Esc + 刷新键，再按电源键，进入恢复模式，插入 U 盘
  3. 按屏幕提示完成恢复（会清空硬盘）
EOF
      ;;
    uefi)
      cat <<EOF
你的 Chromebook 刷了 MrChromebox UEFI 完整固件，有两条路线：

A. ChromeOS Flex（推荐先试，简单、安全，不用动固件）
   1. Windows 工具 → 「ChromeOS 恢复工具」→ 下载 ChromeOS Flex，写入 U 盘
   2. Chromebook 开机按 Esc 选 U 盘启动 → 安装 ChromeOS Flex（会清空硬盘）
   注意：Flex 没有安卓应用和 Play 商店；Google 未正式认证此机型，个别硬件（如扬声器）可能不工作。

B. 原厂 ChromeOS（完整功能）
   1. 恢复原厂固件：sudo l4c chromeos firmware → 在 MrChromebox 菜单里选择恢复原厂固件
      $( [[ -n $backups ]] && echo "会用到你的备份：$backups" || echo "⚠ 没找到你的原厂固件备份。刷 UEFI 固件时工具通常会让你把备份存到 U 盘，请先找到它。
      没有备份时，MrChromebox 工具对部分机型可以下载原厂固件，请以工具菜单显示为准。" )
   2. 按当初关闭写保护的方式恢复写保护（可选，但推荐，ChromeOS 自动更新更可靠）
   3. 在 Windows 上下载本机型（$b）的原厂恢复镜像并写入 U 盘（Windows 工具「ChromeOS 恢复工具」）
   4. 关机，按住 Esc + 刷新键，再按电源键进入恢复模式，插入 U 盘完成恢复

⚠ 刷固件有风险：过程中断电或选错文件可能导致无法开机（需要用编程器修复）。
  请全程插着电源，并在 https://docs.mrchromebox.tech 阅读本机型说明。
EOF
      ;;
    *)
      echo "无法识别固件类型。请运行 sudo l4c info 查看，或参考 https://docs.mrchromebox.tech"
      ;;
  esac
}

do_images() {
  local b=${1:-$(board)}
  have curl || die "需要 curl"
  have python3 || die "需要 python3"
  info "查询 Google 官方恢复镜像列表（主板 $b）"
  local json; json=$(curl -fsSL -m 60 "$RECOVERY_JSON") || die "无法访问 Google 恢复镜像列表（网络受限时可以在 Windows 工具里下载，或用 Chromebook 恢复实用工具）"
  python3 -c '
import json, sys
b = sys.argv[1].upper()
rows = [r for r in json.load(sys.stdin)
        if b in (r.get("hwidmatch", "") + " " + r.get("name", "") + " " + r.get("file", "")).upper()]
if not rows:
    print("没有找到主板 %s 的恢复镜像。可在 Chromebook 恢复实用工具里按型号手动选择。" % b); sys.exit(1)
for r in rows:
    print("型号:   %s" % r.get("name", "?"))
    print("版本:   %s  (%s)" % (r.get("version", "?"), r.get("channel", "?")))
    print("地址:   %s" % r.get("url", "?"))
    print("SHA1:   %s" % r.get("sha1", "?"))
    print("大小:   %s 字节（解压后 %s）" % (r.get("zipfilesize", "?"), r.get("filesize", "?")))
    print()
' "$b" <<<"$json" || true
  echo "ChromeOS Flex（通用版）：$FLEX_URL"
}

do_backup_firmware() {
  local backups dst
  backups=$(find_stock_backups)
  [[ -n $backups ]] || die "没有找到原厂固件备份（*.rom）"
  dst=$(ask "复制到哪个目录（U 盘或迁移包目录）？" "/run/media/$(target_user)")
  [[ -d $dst ]] || die "$dst 不存在"
  mkdir -p "$dst/chromebook-stock-firmware"
  while IFS= read -r f; do
    cp -n "$f" "$dst/chromebook-stock-firmware/" && sha256sum "$f" >>"$dst/chromebook-stock-firmware/SHA256SUMS"
  done <<<"$backups"
  ok "已复制到 $dst/chromebook-stock-firmware（请同时在 Windows 电脑上留一份）"
}

do_firmware() {
  require_root
  cat <<EOF
即将运行 MrChromebox 固件工具（$MRCB）。
  • 这是社区维护的开源工具，Chromebook 刷 UEFI 固件 / 恢复原厂固件都用它
  • 恢复原厂固件时请选择菜单里的「Restore Stock Firmware」，按提示选择你的原厂固件备份
  • 全程插着电源，不要中途关机
  • 恢复原厂固件后，Linux 将无法启动，下一步要用恢复 U 盘装回 ChromeOS
EOF
  confirm "已阅读说明并确认继续？" n || exit 0
  local dir; dir=$(mktemp -d)
  curl -fsSL -o "$dir/firmware-util.sh" "$MRCB" || die "下载失败"
  ( cd "$dir" && bash firmware-util.sh )
  rm -rf "$dir"
}

case "${1:-}" in
  check) do_check ;;
  images) do_images "${2:-}" ;;
  backup-firmware) do_backup_firmware ;;
  firmware) do_firmware ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
