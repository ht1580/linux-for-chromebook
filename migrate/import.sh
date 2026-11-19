#!/usr/bin/env bash
# 导入程序：把 export.sh 生成的迁移包还原到新系统。
#
#   sudo ./migrate/import.sh /run/media/$USER/U盘/l4c-backup-xxx
#   选项：
#     --user NAME        还原到哪个用户（默认：运行 sudo 的用户 / 迁移包里的用户名）
#     --yes              不逐项询问，全部采用推荐选择
#     --skip-packages    不重装软件
#     --skip-home        不还原个人文件
#     --skip-system      不还原 Wi-Fi、蓝牙、主机名、时区等
#     --skip-flatpak     不重装 Flatpak 应用（Flatpak 很占空间）
#     --keep-hostname    保留新系统的主机名
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

SRC="" USER_NAME="" SKIP_PKG=0 SKIP_HOME=0 SKIP_SYS=0 SKIP_FLATPAK=0 KEEP_HOST=0
while (($#)); do
  case $1 in
    --user) USER_NAME=${2:?}; shift ;;
    --yes) L4C_YES=1 ;;
    --skip-packages) SKIP_PKG=1 ;;
    --skip-home) SKIP_HOME=1 ;;
    --skip-system) SKIP_SYS=1 ;;
    --skip-flatpak) SKIP_FLATPAK=1 ;;
    --keep-hostname) KEEP_HOST=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) die "未知参数: $1" ;;
    *) SRC=$1 ;;
  esac
  shift
done

require_root
have zstd || die "缺少 zstd：pacman -S zstd"
[[ -n $SRC && -f $SRC/manifest.env ]] || die "请指定迁移包目录（里面应该有 manifest.env）"
SRC=$(readlink -f "$SRC")
LOG=/var/log/l4c-import.log
exec > >(tee -a "$LOG") 2>&1

# 安全读取 manifest（不执行其中任何内容）
declare -A M
while IFS= read -r line; do
  [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] && M[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
done <"$SRC/manifest.env"
m() { echo "${M[$1]:-}"; }

info "导入迁移包 $SRC（创建于 $(m CREATED)，来自 $(m HOSTNAME)）"
info "校验文件完整性……"
(cd "$SRC" && sha256sum --quiet -c SHA256SUMS) || confirm "校验失败，文件可能损坏。仍然继续？" n || die "已取消"
ok "校验通过"

OLD_USER=$(m USERNAME)
if [[ -z $USER_NAME ]]; then
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then USER_NAME=$SUDO_USER; else USER_NAME=$OLD_USER; fi
fi
getent passwd "$USER_NAME" >/dev/null || die "用户 $USER_NAME 不存在，请先创建（或用 --user 指定）"
HOME_DIR=$(user_home "$USER_NAME")
USER_GROUP=$(id -gn "$USER_NAME")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 新系统已经替换/优化掉的软件，不再装回来
SKIP_RE='^(linux[0-9]+(-headers)?|linux|linux-lts|linux-firmware|grub|efibootmgr|os-prober|memtest86\+.*|mhwd.*|manjaro-.*-settings|calamares.*|noto-fonts-cjk|systemd-swap|zramswap|swapspace)$'

restore_packages() {
  [[ -s $SRC/packages/native.txt ]] || return 0
  info "重新安装软件"
  pacman -Sy --noconfirm >/dev/null 2>&1 || warn "软件源同步失败，请检查网络"
  local avail want=() missing=() p
  avail=$(pacman -Slq | sort -u)
  while read -r p; do
    [[ -z $p || $p =~ $SKIP_RE ]] && continue
    pkg_installed "$p" && continue
    if grep -qxF -- "$p" <<<"$avail"; then want+=("$p"); else missing+=("$p"); fi
  done <"$SRC/packages/native.txt"
  if ((${#want[@]})); then
    echo "将安装 ${#want[@]} 个软件：${want[*]}"
    if confirm "开始安装？" y; then
      if ! pacman -S --needed --noconfirm "${want[@]}"; then
        warn "批量安装失败，改为逐个安装……"
        for p in "${want[@]}"; do pacman -S --needed --noconfirm "$p" >/dev/null 2>&1 || missing+=("$p"); done
      fi
    fi
  fi
  # AUR 软件需要普通用户编译，留一个清单
  if [[ -s $SRC/packages/foreign.txt ]]; then
    install -o "$USER_NAME" -g "$USER_GROUP" -m 644 "$SRC/packages/foreign.txt" "$HOME_DIR/需要从AUR安装的软件.txt"
    warn "有 $(wc -l <"$SRC/packages/foreign.txt") 个 AUR 软件需要登录后安装，清单在 ~/需要从AUR安装的软件.txt"
    warn "安装方法：pamac build \$(cat ~/需要从AUR安装的软件.txt)   （或在「添加/删除软件」里启用 AUR）"
  fi
  ((${#missing[@]})) && warn "这些软件在新系统的软件源里找不到或安装失败：${missing[*]}"
  return 0
}

restore_flatpak() {
  ((SKIP_FLATPAK)) && return 0
  [[ -s $SRC/packages/flatpak.txt ]] || return 0
  echo "旧系统的 Flatpak 应用：$(awk '{print $2}' "$SRC/packages/flatpak.txt" | tr '\n' ' ')"
  warn "Flatpak 运行库通常要占 1~3 GB。能用官方软件源版本的，建议不要装 Flatpak 版。"
  confirm "仍然重新安装这些 Flatpak 应用？" n || return 0
  pkg_install flatpak
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  local origin app
  while read -r origin app; do
    [[ -n $app ]] || continue
    flatpak install -y --noninteractive "$origin" "$app" || warn "Flatpak $app 安装失败"
  done <"$SRC/packages/flatpak.txt"
}

restore_home() {
  [[ -f $SRC/home.tar.zst ]] || return 0
  info "还原个人文件和设置到 $HOME_DIR"
  zstd -dc "$SRC/home.tar.zst" | tar -x --no-same-owner --overwrite -C "$HOME_DIR" -f - || warn "部分文件还原失败"
  chown -R "$USER_NAME:$USER_GROUP" "$HOME_DIR"
  # 用户名不同：修正配置文件里的旧路径
  local old_home; old_home=$(m HOME_DIR)
  if [[ -n $old_home && $old_home != "$HOME_DIR" ]]; then
    info "修正配置里的旧路径 $old_home → $HOME_DIR"
    local d
    for d in .config .local/share/applications .zshrc .bashrc .profile .gtkrc-2.0 .mozilla; do
      [[ -e $HOME_DIR/$d ]] || continue
      grep -rlIZF -- "$old_home" "$HOME_DIR/$d" 2>/dev/null |
        xargs -0 -r sed -i "s|$old_home|$HOME_DIR|g" || true
    done
  fi
  ok "个人文件已还原"
}

restore_system() {
  [[ -f $SRC/system.tar.zst ]] || return 0
  info "还原系统设置"
  mkdir -p "$TMP/sys"
  zstd -dc "$SRC/system.tar.zst" | tar -x -C "$TMP/sys" -f -
  local s=$TMP/sys

  if [[ -d $s/etc/NetworkManager/system-connections ]]; then
    install -d -m 700 /etc/NetworkManager/system-connections
    cp -a "$s/etc/NetworkManager/system-connections/." /etc/NetworkManager/system-connections/
    chown -R root:root /etc/NetworkManager/system-connections
    chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
    ok "Wi-Fi：$(find /etc/NetworkManager/system-connections -type f | wc -l) 个网络"
  fi
  if [[ -d $s/var/lib/bluetooth ]]; then
    install -d -m 700 /var/lib/bluetooth
    cp -a "$s/var/lib/bluetooth/." /var/lib/bluetooth/
    ok "蓝牙配对（同一台机器的蓝牙芯片，配对的耳机/鼠标可以直接用）"
  fi
  if [[ -d $s/etc/X11/xorg.conf.d ]]; then
    local f
    for f in "$s"/etc/X11/xorg.conf.d/*; do
      [[ -e $f && ! -e /etc/X11/xorg.conf.d/$(basename "$f") ]] && install -Dm644 "$f" "/etc/X11/xorg.conf.d/$(basename "$f")"
    done
  fi
  if ((!KEEP_HOST)) && [[ -s $s/etc/hostname ]]; then
    install -m 644 "$s/etc/hostname" /etc/hostname
    ok "主机名：$(cat /etc/hostname)"
  fi
  local tz; tz=$(m TIMEZONE)
  if [[ -n $tz && -e /usr/share/zoneinfo/$tz ]]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    ok "时区：$tz"
  fi
  local loc; loc=$(m LOCALE)
  if [[ -n $loc ]] && ! grep -q "^LANG=$loc" /etc/locale.conf 2>/dev/null; then
    sed -i "s/^#\s*\(${loc//./\\.}\s\)/\1/" /etc/locale.gen
    locale-gen >/dev/null && echo "LANG=$loc" >/etc/locale.conf && ok "语言：$loc"
  fi
  # 原系统 keyd 配置只在本项目没有生成键盘映射时才使用
  if [[ -d $s/etc/keyd ]] && ! ls /etc/keyd/l4c-*.conf >/dev/null 2>&1; then
    cp -a "$s/etc/keyd/." /etc/keyd/
  fi
  # 其余文件只作参考保存
  mkdir -p /var/lib/l4c/old-system
  cp -a "$s/." /var/lib/l4c/old-system/
  rm -rf /var/lib/l4c/old-system/etc/NetworkManager
  chmod -R go-rwx /var/lib/l4c/old-system
}

restore_unowned() {
  [[ -f $SRC/unowned.tar.zst ]] || return 0
  info "还原手动安装的主题、图标、字体"
  zstd -dc "$SRC/unowned.tar.zst" |
    tar -x --no-same-owner --skip-old-files -C / -f - 2>/dev/null || true
  have fc-cache && fc-cache -f >/dev/null 2>&1 || true
  local d
  for d in /usr/share/icons/*/; do
    [[ -f $d/index.theme ]] && gtk-update-icon-cache -qf "$d" 2>/dev/null || true
  done
  ok "主题/图标/字体已还原"
}

restore_shell_services() {
  local sh; sh=$(m USER_SHELL)
  if [[ -n $sh && -x $sh && $(getent passwd "$USER_NAME" | cut -d: -f7) != "$sh" ]] && grep -qx "$sh" /etc/shells; then
    chsh -s "$sh" "$USER_NAME" >/dev/null && ok "默认 shell：$sh"
  fi
  [[ -s $SRC/packages/services.txt ]] || return 0
  local s enable=()
  while read -r s; do
    case $s in
      getty@*|systemd-*|display-manager*|dbus*|*@.service|cups*|avahi*|ModemManager*) continue ;;
    esac
    systemctl cat "$s" >/dev/null 2>&1 || continue
    systemctl is-enabled "$s" >/dev/null 2>&1 && continue
    enable+=("$s")
  done <"$SRC/packages/services.txt"
  if ((${#enable[@]})); then
    echo "旧系统还启用了这些服务：${enable[*]}"
    if confirm "在新系统中也启用？" y; then
      local x; for x in "${enable[@]}"; do systemctl enable "$x" >/dev/null 2>&1 || warn "无法启用 $x"; done
    fi
  fi
}

((SKIP_PKG)) || { restore_packages; restore_flatpak; }
((SKIP_HOME)) || restore_home
((SKIP_SYS)) || restore_system
restore_unowned
restore_shell_services
ok "导入完成！日志：$LOG"
echo "建议重启一次。若想把桌面改成 Windows 11 风格（会先备份当前设置）：登录后运行 l4c desktop"
