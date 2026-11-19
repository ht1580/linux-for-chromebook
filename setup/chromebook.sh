#!/usr/bin/env bash
# Chromebook 硬件适配。
#   sudo ./setup/chromebook.sh keyboard   顶排按键 + 缺失按键映射（Windows 习惯）
#   sudo ./setup/chromebook.sh audio      扬声器 / 麦克风驱动（社区脚本）
#        ./setup/chromebook.sh info       查看机型、固件信息
#   sudo ./setup/chromebook.sh all
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

KEYD_CONF=/etc/keyd/l4c-chromebook.conf
AUDIO_REPO=https://github.com/WeirdTreeThing/chromebook-linux-audio

# Chromebook 顶排按键的扫描码 → keyd 键名（来自 ChromeOS vivaldi 键盘规范）
declare -A VIVALDI=(
  [90]=previoussong [91]=zoom [92]=scale [93]=print [94]=brightnessdown
  [95]=brightnessup [97]=kbdillumdown [98]=kbdillumup [99]=nextsong
  [9A]=playpause [9B]=micmute [9E]=kbdillumtoggle [A0]=mute
  [AE]=volumedown [B0]=volumeup [E9]=forward [EA]=back [E7]=refresh
)
# 顶排“动作键”在 Windows 习惯下应该输出什么
declare -A WIN_ACTION=(
  [back]=A-left [forward]=A-right [refresh]=f5 [zoom]=f11 [scale]=M-tab [print]=print
)
# 没有 physmap 时的默认顶排（老款 Chromebook）
DEFAULT_ROW=(back forward refresh zoom scale brightnessdown brightnessup mute volumedown volumeup)

detect_keyboard_id() {
  awk '/^I:/{v=$3; p=$4} /^N: Name=/{n=$0}
       /^H: Handlers=.*kbd/ && n ~ /AT Translated Set 2|cros_ec|Google/ {
         sub("Vendor=","",v); sub("Product=","",p); print v ":" p; exit }' \
    /proc/bus/input/devices 2>/dev/null || true
}

detect_top_row() {
  local f codes c key row=()
  f=$(find /sys/devices/platform -name function_row_physmap 2>/dev/null | head -1)
  if [[ -z $f ]]; then echo "${DEFAULT_ROW[*]}"; return; fi
  read -r -a codes <"$f"
  for c in "${codes[@]}"; do
    c=${c^^}; c=${c: -2}
    key=${VIVALDI[$c]:-}
    [[ -n $key ]] || { warn "未知顶排扫描码 $c，该位置保持 F 键"; key=none; }
    row+=("$key")
  done
  echo "${row[*]}"
}

gen_keyd_conf() {
  local id row i key out main="" meta="" alt=""
  id=$(detect_keyboard_id); id=${id:-0001:0001}
  read -r -a row <<<"$(detect_top_row)"
  for i in "${!row[@]}"; do
    local n=$((i + 1)) key=${row[$i]}
    ((n <= 12)) || break
    if [[ $key == none ]]; then
      meta+="f$n = f$n"$'\n'; continue
    fi
    out=${WIN_ACTION[$key]:-$key}
    main+="f$n = $out"$'\n'
    [[ $out != "$key" ]] && main+="$key = $out"$'\n'
    meta+="f$n = f$n"$'\n'"$key = f$n"$'\n'
    if ((n == 4)); then alt+="f4 = A-f4"$'\n'"$key = A-f4"$'\n'; fi
  done
  cat <<EOF
# 由 linux-for-chromebook 自动生成，重新生成：sudo l4c keyboard
# 只作用于内置键盘（$id），外接键盘不受影响。
#
#   顶排按键      = 返回 / 刷新(F5) / 全屏(F11) / 窗口切换 / 亮度 / 音量 …
#   搜索键 + 顶排 = F1 … F10       搜索键 + - / = = F11 / F12
#   Alt + 第4个键 = Alt+F4 关闭窗口
#   Alt + 退格    = Delete         Alt + ↑/↓ = PageUp / PageDown
#   Ctrl+Alt+↑/↓  = Home / End     Alt + 搜索键 = 大写锁定 CapsLock
#   Ctrl+Alt+退格 = Ctrl+Alt+Delete
#   搜索键（单按）= Windows 键（开始菜单）

[ids]
$id

[main]
${main}
[meta]
${meta}minus = f11
equal = f12

[alt]
${alt}backspace = delete
up = pageup
down = pagedown
meta = capslock

[control+alt]
up = home
down = end
backspace = C-A-delete
EOF
}

do_keyboard() {
  require_root
  info "配置 Chromebook 键盘（Windows 习惯）"
  pkg_install keyd
  mkdir -p /etc/keyd
  [[ -f /etc/keyd/default.conf ]] && grep -q '^\*' /etc/keyd/default.conf 2>/dev/null &&
    warn "/etc/keyd/default.conf 作用于所有键盘，可能与本配置冲突"
  gen_keyd_conf >"$KEYD_CONF"
  ok "已生成 $KEYD_CONF（顶排: $(detect_top_row)）"
  systemd_enable keyd.service
  [[ $L4C_CHROOT == 1 ]] || keyd reload 2>/dev/null || systemctl restart keyd.service || true
  ok "键盘映射已生效"
}

do_audio() {
  info "安装 Chromebook 声卡驱动（社区项目 chromebook-linux-audio）"
  warn "该脚本来自 $AUDIO_REPO ，会安装 SOF 固件和 UCM 配置，并可能提示扬声器音量风险，请阅读它的提示。"
  confirm "继续？" y || return 0
  have git || pkg_install git
  local dir user; dir=$(mktemp -d)
  git clone --depth 1 "$AUDIO_REPO" "$dir/audio" || die "下载失败，请检查网络"
  user=$(target_user)
  chmod -R a+rX "$dir"; [[ $user == root ]] || chown -R "$user" "$dir"
  if [[ $EUID -eq 0 && $user != root && $L4C_CHROOT != 1 ]]; then
    (cd "$dir/audio" && sudo -u "$user" ./setup-audio) || warn "声卡脚本返回错误，请查看上面的输出"
  else
    (cd "$dir/audio" && ./setup-audio) || warn "声卡脚本返回错误，可以重启后运行：l4c audio"
  fi
  rm -rf "$dir"
  ok "完成后请重启，然后在右下角音量图标里检查输出设备"
}

do_info() {
  local dmi=/sys/class/dmi/id
  echo "机型:     $(cat $dmi/sys_vendor 2>/dev/null) $(cat $dmi/product_name 2>/dev/null) ($(cat $dmi/product_version 2>/dev/null))"
  echo "主板代号: $(cat $dmi/board_name 2>/dev/null)"
  echo "固件:     $(cat $dmi/bios_vendor 2>/dev/null) $(cat $dmi/bios_version 2>/dev/null) ($(cat $dmi/bios_date 2>/dev/null))"
  echo "CPU:      $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  echo "内存:     $(free -h | awk '/^Mem:/{print $2}')（焊在主板上，无法升级）"
  echo "存储:     $(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk" && $1 !~ /^(zram|loop)/{printf "%s %s  ", $1, $2}')"
  echo "顶排按键: $(detect_top_row)"
  echo "内置键盘: $(detect_keyboard_id)"
  if grep -qi mrchromebox $dmi/bios_version 2>/dev/null; then
    echo "固件状态: MrChromebox UEFI ✓  （更新固件：https://mrchromebox.tech 的 firmware-util.sh，请务必先阅读说明）"
  else
    echo "固件状态: 不是 MrChromebox UEFI 固件，部分功能可能不同"
  fi
}

case "${1:-}" in
  keyboard) do_keyboard ;;
  audio) do_audio ;;
  info) do_info ;;
  gen-keyd) gen_keyd_conf ;;
  all) do_keyboard; do_audio ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
