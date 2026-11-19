#!/usr/bin/env bash
# 清除设备残存信息。
#   sudo ./setup/wipe.sh traces          清除使用痕迹（历史记录、缓存、日志、本工具的备份文件……），逐项询问
#   sudo ./setup/wipe.sh efi             删除指向已不存在分区的旧 UEFI 启动项
#   sudo ./setup/wipe.sh disk /dev/xxx   彻底擦除整块硬盘（只能在启动 U 盘里运行，数据无法恢复）
#   sudo ./setup/wipe.sh verify /dev/xxx 抽查硬盘是否已擦除干净
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root

freed_start=$(df --output=used -B1 / | tail -1)

rm_ask() { # 说明 默认 路径…
  local desc=$1 def=$2; shift 2
  local exist=() p
  for p in "$@"; do [[ -e $p || -L $p ]] && exist+=("$p"); done
  ((${#exist[@]})) || return 0
  confirm "清除 $desc？" "$def" || return 0
  rm -rf -- "${exist[@]}"
  ok "已清除 $desc"
}

do_traces() {
  local u h; u=$(target_user); h=$(user_home "$u")
  info "清除使用痕迹（用户 $u）"
  rm_ask "终端命令历史" y "$h"/.bash_history "$h"/.zsh_history "$h"/.histfile "$h"/.python_history \
    "$h"/.node_repl_history "$h"/.lesshst "$h"/.viminfo "$h"/.wget-hsts "$h"/.sqlite_history /root/.bash_history /root/.zsh_history
  rm_ask "最近打开的文件记录" y "$h"/.local/share/recently-used.xbel "$h"/.recently-used
  rm_ask "缓存和缩略图" y "$h"/.cache "$h"/.thumbnails
  rm_ask "回收站" y "$h"/.local/share/Trash
  rm_ask "本工具留下的迁移备份（旧系统配置、导入日志、桌面设置备份）" y \
    /var/lib/l4c/old-system /var/log/l4c-import.log "$h"/.local/share/l4c "$h"/需要从AUR安装的软件.txt "$h"/l4c-scan-*.md
  local baks; mapfile -t baks < <(find /etc -name '*.l4c-bak.*' 2>/dev/null)
  ((${#baks[@]})) && rm_ask "修改系统配置前留下的 ${#baks[@]} 个备份文件" y "${baks[@]}"
  rm_ask "浏览器数据（历史、Cookie、保存的密码，等于重置浏览器）" n \
    "$h"/.mozilla "$h"/.config/chromium "$h"/.config/google-chrome "$h"/.config/microsoft-edge
  rm_ask "保存的 Wi-Fi 网络和密码" n /etc/NetworkManager/system-connections/*
  rm_ask "蓝牙配对记录" n /var/lib/bluetooth/*
  rm_ask "SSH 密钥和已知主机" n "$h"/.ssh
  rm_ask "钥匙环（应用保存的密码）" n "$h"/.local/share/keyrings
  if confirm "清除系统日志和崩溃记录？" y; then
    journalctl --rotate -q 2>/dev/null || true
    journalctl --vacuum-time=1s -q 2>/dev/null || true
    rm -rf /var/lib/systemd/coredump/* /var/tmp/* 2>/dev/null || true
    find /var/log -type f \( -name '*.old' -o -name '*.[0-9]' -o -name '*.gz' \) -delete 2>/dev/null || true
    ok "已清除日志"
  fi
  if confirm "清除软件包缓存？" y; then
    pacman -Scc --noconfirm >/dev/null 2>&1 || true
    rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
    ok "已清除软件包缓存"
  fi
  # 删除的文件在 eMMC 上仍可能被恢复；TRIM 让控制器真正丢弃这些数据块
  info "通知硬盘丢弃已删除的数据块（TRIM）"
  fstrim -av 2>/dev/null | sed 's/^/  /' || warn "这块硬盘不支持 TRIM"
  local freed=$((freed_start - $(df --output=used -B1 / | tail -1)))
  ok "完成，腾出 $(human_size $((freed > 0 ? freed : 0)))"
}

do_efi() {
  have efibootmgr || pkg_install efibootmgr
  [[ -d /sys/firmware/efi ]] || die "不是 UEFI 启动"
  local live; live=$(lsblk -rno PARTUUID 2>/dev/null | tr 'A-F' 'a-f' | grep . || true)
  local line num label guid n=0
  info "检查 UEFI 启动项"
  while IFS= read -r line; do
    [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(.*)$ ]] || continue
    num=${BASH_REMATCH[1]} label=${BASH_REMATCH[2]}
    [[ $label =~ HD\([0-9]+,GPT,([0-9a-fA-F-]{36}) ]] || continue   # 只处理指向硬盘分区的启动项
    guid=${BASH_REMATCH[1],,}
    grep -qx "$guid" <<<"$live" && continue
    echo "  Boot$num  ${label%%	*}"
    if confirm "    这个启动项指向的分区已经不存在，删除？" y; then
      efibootmgr -q -b "$num" -B && n=$((n + 1))
    fi
  done < <(efibootmgr -v 2>/dev/null)
  ok "删除了 $n 个失效的启动项"
}

is_live() { [[ -d /run/miso ]] || grep -qE '(^| )(misobasedir|archisobasedir)=' /proc/cmdline; }

do_disk() {
  local dev=${1:?需要硬盘设备，例如 /dev/mmcblk0}
  [[ -b $dev && $(lsblk -dno TYPE "$dev") == disk ]] || die "$dev 不是一块硬盘"
  is_live || die "为了安全，整盘擦除只能在启动 U 盘（Live 系统）里运行"
  local root_disk; root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/miso/bootmnt 2>/dev/null)" 2>/dev/null || true)
  [[ /dev/$root_disk != "$dev" ]] || die "$dev 是当前启动用的 U 盘"
  if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
    warn "$dev 上有已挂载的分区，正在卸载"
    umount -R "$dev"* 2>/dev/null || true
    swapoff -a 2>/dev/null || true
  fi
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$dev"
  if [[ ${L4C_WIPE_CONFIRMED:-0} != 1 ]]; then
    warn "将彻底擦除 $dev 上的所有数据（包括旧系统、个人文件、恢复分区），无法恢复！"
    [[ $(ask "确认请输入大写 WIPE" "") == WIPE ]] || die "已取消，未做任何改动"
  fi
  info "擦除 $dev"
  wipefs -af "$dev" >/dev/null 2>&1 || true
  if blkdiscard -f -s "$dev" 2>/dev/null; then
    ok "已完成安全擦除（eMMC secure erase，数据块被物理清除）"
  elif blkdiscard -f "$dev" 2>/dev/null; then
    ok "已完成 TRIM 擦除（控制器已丢弃全部数据块）"
  else
    warn "这块硬盘不支持快速擦除，改为全盘写零（32G 约需 5~15 分钟）"
    dd if=/dev/zero of="$dev" bs=4M status=progress oflag=direct 2>&1 || true
    sync
    ok "已全盘写零"
  fi
  do_verify "$dev"
}

do_verify() {
  local dev=${1:?需要硬盘设备}
  local size blocks i off bad=0
  size=$(blockdev --getsize64 "$dev"); blocks=$((size / 1048576))
  for i in $(seq 0 31); do
    off=$(( (blocks - 1) * i / 31 ))
    if [[ -n $(dd if="$dev" bs=1M skip="$off" count=1 status=none 2>/dev/null | tr -d '\0' | head -c 1) ]]; then
      bad=$((bad + 1))
    fi
  done
  if ((bad == 0)); then ok "抽查 32 个位置，均已清空"
  else warn "抽查 32 个位置，有 $bad 个仍有数据（部分 eMMC 擦除后返回非零内容属正常，若担心可再执行一次写零）"
  fi
}

case "${1:-}" in
  traces) do_traces ;;
  efi) do_efi ;;
  disk) do_disk "${2:-}" ;;
  verify) do_verify "${2:-}" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
