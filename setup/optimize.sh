#!/usr/bin/env bash
# 系统级性能与存储优化。可以在现有的 Manjaro / CachyOS / Arch 上直接运行，也会被全新安装器调用。
#   sudo ./setup/optimize.sh            逐项询问
#   sudo ./setup/optimize.sh --all      全部采用推荐设置
#   sudo ./setup/optimize.sh --clean    只做一次存储清理
#   sudo ./setup/optimize.sh --ram      只精简开机常驻程序（省内存）
#   sudo ./setup/optimize.sh --remove-wine  删除 wine 和 32 位库（不用 Windows 程序时）
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

SWAPFILE_SIZE_GB="${SWAPFILE_SIZE_GB:-1}"   # zram 之外保留的小 swap 文件（兜底用；32G eMMC 上 1G 足够）
MODE=interactive
case "${1:-}" in
  --all) L4C_YES=1 ;;
  --clean) MODE=clean ;;
  --ram) MODE=ram ;;
  --remove-wine) REMOVE_WINE=1; MODE=wine ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  "") ;;
  *) die "未知参数: $1" ;;
esac

require_root

# ---------------------------------------------------------------- 内存 ----
step_zram() {
  confirm "启用 zram 压缩内存并缩小硬盘 swap？（强烈推荐）" y || return 0
  pkg_install zram-generator
  put_config systemd/zram-generator.conf /etc/systemd/zram-generator.conf
  put_config systemd/99-l4c-sysctl.conf /etc/sysctl.d/99-l4c.conf
  put_config systemd/l4c-mm.conf /etc/tmpfiles.d/l4c-mm.conf   # 透明大页 madvise + MGLRU 防卡顿
  add_kernel_params zswap.enabled=0   # zram 与 zswap 不要同时用
  if [[ $L4C_CHROOT == 1 ]]; then ok "zram 已配置（重启后生效）"; return 0; fi

  systemctl daemon-reload
  systemctl start systemd-zram-setup@zram0.service 2>/dev/null || warn "zram 将在重启后生效"
  sysctl --system >/dev/null
  systemd-tmpfiles --create /etc/tmpfiles.d/l4c-mm.conf 2>/dev/null || true
  echo 0 >/sys/module/zswap/parameters/enabled 2>/dev/null || true
  ok "zram 已启用：$(zramctl --noheadings --output DISKSIZE /dev/zram0 2>/dev/null | xargs) 压缩内存"
  shrink_swapfiles
}

shrink_swapfiles() {
  local name type size
  while read -r name type size; do
    [[ $type == file ]] || continue
    local want=$((SWAPFILE_SIZE_GB * 1024 * 1024 * 1024))
    ((size > want + 268435456)) || continue
    confirm "发现 $(human_size "$size") 的 swap 文件 $name，缩小为 ${SWAPFILE_SIZE_GB}G 以腾出硬盘空间？" y || continue
    info "正在把 swap 中的数据移回内存/zram，可能需要一两分钟……"
    if ! swapoff "$name"; then
      warn "内存不足，暂时无法关闭 $name。请关掉浏览器等程序或重启后再运行一次本步骤。"
      continue
    fi
    rm -f "$name"
    make_swapfile "$name" "$SWAPFILE_SIZE_GB"
    swapon --priority=-2 "$name"
    ok "swap 文件已缩小为 ${SWAPFILE_SIZE_GB}G，腾出约 $(human_size $((size - want)))"
  done < <(swapon --show=NAME,TYPE,SIZE --bytes --noheadings 2>/dev/null)
}

make_swapfile() { # 路径 大小GB
  local f=$1 gb=$2
  if [[ $(stat -f -c %T "$(dirname "$f")") == btrfs ]]; then
    btrfs filesystem mkswapfile --size "${gb}g" "$f" >/dev/null
  else
    fallocate -l "${gb}G" "$f" || dd if=/dev/zero of="$f" bs=1M count=$((gb * 1024)) status=none
    chmod 600 "$f"
    mkswap "$f" >/dev/null
  fi
  # fstab：替换旧条目，低优先级（zram 用完才会用它）
  backup_file /etc/fstab
  awk -v f="$f" '$1 != f' /etc/fstab >/etc/fstab.l4c-tmp
  printf '%s none swap defaults,pri=-2 0 0\n' "$f" >>/etc/fstab.l4c-tmp
  cat /etc/fstab.l4c-tmp >/etc/fstab && rm -f /etc/fstab.l4c-tmp
}

step_earlyoom() {
  confirm "启用 earlyoom（内存耗尽时结束最占内存的标签页，避免整机卡死）？" y || return 0
  pkg_install earlyoom
  put_config systemd/earlyoom /etc/default/earlyoom
  systemd_enable earlyoom.service
  [[ $L4C_CHROOT == 1 ]] || systemctl restart earlyoom.service
  ok "earlyoom 已启用"
}

# ---------------------------------------------------------------- 存储 ----
step_logs() {
  confirm "限制系统日志大小（50M）并关闭崩溃转储？" y || return 0
  put_config systemd/journald-size.conf /etc/systemd/journald.conf.d/50-l4c-size.conf
  put_config systemd/coredump-off.conf /etc/systemd/coredump.conf.d/50-l4c.conf
  if [[ $L4C_CHROOT != 1 ]]; then
    systemctl restart systemd-journald
    journalctl --vacuum-size=50M -q 2>/dev/null || true
    rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true
  fi
  ok "日志已限制"
}

step_pacman() {
  confirm "让 pacman 不再安装说明文档和多余语言包，并自动清理旧安装包缓存？" y || return 0
  pkg_install pacman-contrib
  backup_file /etc/pacman.conf
  set_block /etc/pacman.conf noextract "$(cat "$L4C_ROOT/config/pacman/noextract.conf")" '^\[options\]'
  put_config pacman/l4c-clean-cache.hook /etc/pacman.d/hooks/l4c-clean-cache.hook
  if grep -q '^#ParallelDownloads' /etc/pacman.conf; then
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
  fi
  ok "pacman 已配置"
  if [[ $L4C_CHROOT != 1 ]] && confirm "现在就删除已安装的说明文档和多余语言包？（不影响程序运行）" y; then
    local before; before=$(df --output=used -B1 / | tail -1)
    find /usr/share/doc /usr/share/gtk-doc /usr/share/man /usr/share/info -mindepth 1 -delete 2>/dev/null || true
    find /usr/share/help -mindepth 1 -maxdepth 1 ! -name C ! -name zh_CN -exec rm -rf {} + 2>/dev/null || true
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name zh_CN ! -name 'zh_Hans*' -exec rm -rf {} + 2>/dev/null || true
    ok "腾出 $(human_size $((before - $(df --output=used -B1 / | tail -1))))"
  fi
}

step_disk() {
  confirm "优化 eMMC 读写（noatime、bfq 调度器、定期 TRIM）？" y || return 0
  put_config systemd/60-l4c-ioscheduler.rules /etc/udev/rules.d/60-l4c-ioscheduler.rules
  backup_file /etc/fstab
  # 给 ext4/btrfs 分区加 noatime（去掉 relatime），每次读文件不再写一次硬盘
  awk 'BEGIN{OFS="\t"}
       $0 !~ /^[[:space:]]*#/ && ($3=="ext4" || $3=="btrfs") && $4 !~ /noatime/ {
         gsub(/(^|,)relatime/, "", $4); sub(/^,/, "", $4)
         $4 = ($4=="" ? "noatime" : $4 ",noatime")
       } {print}' /etc/fstab >/etc/fstab.l4c-tmp && cat /etc/fstab.l4c-tmp >/etc/fstab && rm -f /etc/fstab.l4c-tmp
  grep -q 'discard' /etc/fstab || systemd_enable fstrim.timer
  [[ $L4C_CHROOT == 1 ]] || udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
  ok "磁盘读写已优化"
}

# ---------------------------------------------------------------- 性能 ----
add_kernel_params() {
  local f=/etc/default/grub p line changed=0
  [[ -f $f ]] || return 0
  line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" || true)
  [[ -n $line ]] || { echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >>"$f"; line='GRUB_CMDLINE_LINUX_DEFAULT=""'; }
  for p in "$@"; do
    local cur=" ${line#*=} "; cur=${cur//\"/ }; cur=${cur//\'/ }
    [[ $cur == *" $p "* ]] && continue
    sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=[\"'])(.*)([\"'])$|\1\2 $p\3|" "$f"
    line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")
    changed=1
  done
  ((changed)) || return 0
  grub_regen || warn "重新生成 GRUB 菜单失败"
}

step_kernel() {
  confirm "关闭硬件看门狗等启动项（启动更快、更省电）？" y || return 0
  add_kernel_params nowatchdog loglevel=3
  printf 'blacklist iTCO_wdt\nblacklist iTCO_vendor_support\n' >/etc/modprobe.d/l4c-nowatchdog.conf
  ok "已设置（重启后生效）"
}

step_video() {
  confirm "启用 Intel 硬件视频解码（看视频 CPU 占用大幅下降）？" y || return 0
  pkg_install intel-media-driver
  set_block /etc/environment vaapi "LIBVA_DRIVER_NAME=iHD"
  # i965 旧驱动不支持 N100（Alder Lake-N），装着只会让程序选错驱动
  if pkg_installed libva-intel-driver && [[ $(lspci -n 2>/dev/null) == *8086:46d* ]]; then
    as_root pacman -Rns --noconfirm libva-intel-driver >/dev/null 2>&1 || true
  fi
  if [[ -d /usr/lib/firefox ]]; then
    put_config firefox/l4c-chromebook.js /usr/lib/firefox/defaults/pref/l4c-chromebook.js
    ok "Firefox 已改为内存缓存 + 硬件解码 + 低内存时自动休眠标签页"
  fi
  browser_vaapi_flags
  ok "硬件视频解码已启用"
}

# Chrome / Edge / Chromium 在 Linux 上默认不用 VA-API，需要用户目录里的 *-flags.conf 打开
browser_vaapi_flags() {
  local user home f p
  user=$(target_user); home=$(user_home "$user")
  [[ -n $home && -d $home && $user != root ]] || return 0
  [[ -d $home/.config ]] || { mkdir -p "$home/.config"; chown "$user:" "$home/.config"; }
  for f in chrome-flags.conf chromium-flags.conf microsoft-edge-stable-flags.conf; do
    p=$home/.config/$f
    if [[ -f $p ]] && grep -q -- '--enable-features' "$p"; then
      grep -q 'AcceleratedVideoDecodeLinuxGL' "$p" || warn "$p 里已有 --enable-features，请手动加上 AcceleratedVideoDecodeLinuxGL"
      continue
    fi
    cat "$L4C_ROOT/config/browser/chromium-vaapi-flags.conf" >>"$p"
    chown "$user:" "$p"
  done
  ok "Chrome / Edge 已开启硬件视频解码（重新打开浏览器后生效，可在 chrome://gpu 查看）"
}

# ---------------------------------------------------------------- 网络 ----
step_wifi() {
  [[ -d /etc/NetworkManager ]] || return 0
  confirm "关闭 Wi-Fi 省电模式？（本机实测省电模式下频繁丢信号；关闭后网络更稳定，待机耗电略增）" y || return 0
  put_config networkmanager/50-l4c-wifi-powersave.conf /etc/NetworkManager/conf.d/50-l4c-wifi-powersave.conf
  if [[ $L4C_CHROOT != 1 ]]; then
    local dev
    for dev in /sys/class/net/*/wireless; do
      dev=$(basename "$(dirname "$dev")")
      have iw && iw dev "$dev" set power_save off 2>/dev/null || true
    done
  fi
  ok "Wi-Fi 省电模式已关闭"
}

# ---------------------------------------------------------------- 电池 ----
# 新内核的 cros_charge_control 驱动可以让 Chromebook 的 EC 在指定电量停止充电
step_battery() {
  local b
  b=$(find /sys/class/power_supply/ -maxdepth 1 -name 'BAT*' 2>/dev/null | head -1)
  [[ -n $b && -e $b/charge_control_end_threshold ]] || return 0
  confirm "这台 Chromebook 常插着电源用吗？把充电上限设为 80% 可以明显延长电池寿命" n || return 0
  cat >/etc/udev/rules.d/61-l4c-battery.rules <<EOF
# l4c: 充到 80% 停止充电（删除本文件并重启即可恢复充满）
ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="$(basename "$b")", ATTR{charge_control_end_threshold}="80"
EOF
  [[ $L4C_CHROOT == 1 ]] || { echo 80 >"$b/charge_control_end_threshold"; } 2>/dev/null || warn "当前内核不接受这个设置，重启后再看"
  ok "充电上限：80%"
}

step_input() {
  confirm "设置触控板（轻触点击、两指点击 = 右键，和 Windows 一致）？" y || return 0
  put_config x11/30-l4c-touchpad.conf /etc/X11/xorg.conf.d/30-l4c-touchpad.conf
  ok "触控板已设置（重新登录后生效）"
}

# 浏览器省内存：Chrome / Chromium「节省内存」、Edge「睡眠标签页」，用系统级策略文件开启（浏览器里会显示「由组织管理」）
# 4G 内存里浏览器是最大的用户，后台标签页休眠后每个能省几十到几百 MB
step_browser_memory() {
  confirm "让 Chrome / Edge 的后台标签页自动休眠以节省内存（切回来时会重新加载）？" y || return 0
  local d
  for d in /etc/opt/chrome/policies/managed /etc/chromium/policies/managed; do
    install -Dm 644 "$L4C_ROOT/config/browser/chrome-memory-policy.json" "$d/l4c-memory.json"
  done
  install -Dm 644 "$L4C_ROOT/config/browser/edge-memory-policy.json" /etc/opt/edge/policies/managed/l4c-memory.json
  ok "浏览器：后台标签页自动休眠（重新打开浏览器后生效，chrome://policy 可以查看）"
}

# 拔掉电源自动切到省电模式，插上恢复平衡模式（power-profiles-daemon 本来就装着，只加一条 udev 规则）
step_power_profile() {
  have powerprofilesctl || return 0
  find /sys/class/power_supply/ -maxdepth 1 -name 'BAT*' 2>/dev/null | grep -q . || return 0
  confirm "拔掉电源时自动切到省电模式、插上电源恢复平衡模式？" y || return 0
  cat >/etc/udev/rules.d/62-l4c-power-profile.rules <<'EOF'
# l4c: 拔电省电，插电恢复平衡（删除本文件即可取消）
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/powerprofilesctl set power-saver"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/powerprofilesctl set balanced"
EOF
  [[ $L4C_CHROOT == 1 ]] || udevadm control --reload 2>/dev/null || true
  ok "电源模式：拔电自动省电，插电恢复平衡"
}

# 不是 AMD 处理器就不需要 AMD 微码（每次开机都会加载它）
step_microcode() {
  grep -q GenuineIntel /proc/cpuinfo 2>/dev/null && pkg_installed amd-ucode || return 0
  as_root pacman -Rns --noconfirm amd-ucode >/dev/null 2>&1 || return 0
  grub_regen || true
  ok "已删除用不到的 AMD 处理器微码"
}

# 不用 wine 时：wine 和它带进来的 32 位库（lib32-*）能腾出几百 MB。默认不删，或用 --remove-wine 指定
step_wine() {
  pkg_installed wine || return 0
  local user home pfx=() d
  user=$(target_user); home=$(user_home "$user")
  for d in "$home"/.wine "$home"/.wine-*; do [[ -d $d ]] && pfx+=("$d"); done
  echo "wine 程序目录：${pfx[*]:-无}"
  if [[ ${REMOVE_WINE:-0} != 1 ]]; then
    confirm "不再使用 Windows 程序（wine）？删除 wine 和全部 32 位库（lib32-*）" n || return 0
  fi
  local pk; mapfile -t pk < <(pacman -Qq | grep -E '^(wine|wine-gecko|wine-mono|winetricks|lib32-.+)$')
  local before; before=$(df --output=used -B1 / | tail -1)
  if as_root pacman -Rns --noconfirm "${pk[@]}" >/dev/null 2>&1; then
    ok "已删除 wine 和 32 位库（${#pk[@]} 个软件包），腾出 $(human_size $((before - $(df --output=used -B1 / | tail -1))))"
  else
    warn "有其他软件需要这些 32 位库（例如 Steam），没有删除"; return 0
  fi
  ((${#pfx[@]})) || return 0
  # 删程序目录是删个人数据：一律默认「否」，自动模式下也不删
  du -sh "${pfx[@]}" 2>/dev/null
  confirm "同时删除上面这些 wine 程序目录（里面装的 Windows 程序和数据，删除后无法恢复）？" n &&
    rm -rf "${pfx[@]}" && ok "已删除 wine 程序目录"
  return 0
}

# 吃内存的 Electron 应用（QQ、哔哩哔哩）：从开始菜单启动时放进一个有「内存软上限」的 systemd scope。
# 超过上限时系统优先把它闲置的内存压缩进 zram，而不是挤占浏览器和桌面；程序照常运行，不会被强制结束（不用 MemoryMax）。
# 做法：在 ~/.local/share/applications 放一份同名 .desktop，Exec 前面加 systemd-run（删掉这份文件即恢复）
step_app_limits() {
  local user home d src n app=() e
  user=$(target_user); home=$(user_home "$user")
  [[ -n $home && -d $home && $user != root ]] || return 0
  for e in qq bilibili; do
    for src in /usr/share/applications/*.desktop; do
      [[ -f $src ]] && grep -qiE "^Exec=.*(/opt/QQ/qq|/usr/bin/(linux)?qq|bilibili)" "$src" || continue
      case $e in qq) grep -qi 'qq' "$src" ;; *) grep -qi "$e" "$src" ;; esac && app+=("$src")
    done
  done
  mapfile -t app < <(printf '%s\n' "${app[@]}" | sort -u)
  [[ -n ${app[0]:-} ]] || return 0
  local ram_mb high; ram_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); high=$((ram_mb / 4))
  echo "找到：$(printf '%s ' "${app[@]##*/}")"
  confirm "给这些应用设内存软上限 ${high} MB（超出部分压缩进 zram，不会被强制结束）并降低后台 CPU 优先级？" y || return 0
  d="$home/.local/share/applications"; mkdir -p "$d"
  for src in "${app[@]}"; do
    n=${src##*/}
    sed -E "s|^Exec=(.*)$|Exec=systemd-run --user --scope --quiet -p MemoryHigh=${high}M -p CPUWeight=50 \1|" "$src" >"$d/$n"
    grep -q '^X-l4c=' "$d/$n" || echo "X-l4c=内存软上限（删除本文件即可恢复）" >>"$d/$n"
  done
  chown -R "$user:" "$home/.local/share/applications"
  ok "已给 ${#app[@]} 个应用设内存软上限 ${high} MB（下次从开始菜单启动时生效）"
}

# 开机常驻程序瘦身：4G 内存里，开机就常驻的程序能省则省
# （实测这台机器可用内存多出约 55 MB；Proton VPN 后台用过一次就会一直占着，峰值约 250 MB）
step_ram_apps() {
  # Proton VPN 的后台服务支持 D-Bus 按需启动：关掉开机常驻，打开 VPN 程序时会自动拉起
  if systemctl is-enabled proton.VPN.service >/dev/null 2>&1 &&
     compgen -G '/usr/share/dbus-1/system-services/me.proton.vpn.*.service' >/dev/null &&
     confirm "Proton VPN 后台服务改为用到时才启动（平时不常驻，用过 VPN 后它会占到约 250 MB；用 VPN 时不受影响）？" y; then
    systemctl disable proton.VPN.service >/dev/null 2>&1
    [[ $L4C_CHROOT == 1 ]] || systemctl stop proton.VPN.service 2>/dev/null || true
    ok "Proton VPN 后台服务：改为按需启动"
  fi

  # 桌面会话的自启动：在用户目录放一份 Hidden=true 的同名文件即可关掉（随时删掉这份文件就恢复）
  local user home; user=$(target_user); home=$(user_home "$user")
  [[ -n $home && -d $home && $user != root ]] || return 0
  local ad="$home/.config/autostart" off=() n f c e reason own
  # 名称|原因（只在条件满足时关）
  local -a cand=(
    "copyq|和 Xfce 自带的剪贴板历史（Win+V）重复"
    "pamac-tray|软件更新提醒（托盘图标和它拉起的后台服务，约 30 MB）；以后在「添加/删除软件」里手动检查更新"
    "blueman|蓝牙托盘（约 50 MB）；已配对的耳机、鼠标照常自动连接，配对新设备时从开始菜单打开「蓝牙管理器」"
    "remmina-applet|远程桌面的托盘图标，不影响使用远程桌面"
    "msm_notifier|Manjaro 设置提醒（新内核/语言包）"
    "xiccd|屏幕颜色配置守护进程，Chromebook 屏幕用不到"
    "xcape|单按 Win 键开菜单，Xfce 快捷键已经做了，重复"
    "picom|系统自带的 picom 自启动，用户目录里已经有自己的 picom"
  )
  for e in "${cand[@]}"; do
    n=${e%%|*}; reason=${e#*|}
    f=""; for c in "$ad/$n.desktop" "/etc/xdg/autostart/$n.desktop"; do [[ -f $c ]] && { f=$c; break; }; done
    [[ -n $f ]] || continue
    grep -qi '^Hidden=true' "$ad/$n.desktop" 2>/dev/null && continue
    case $n in
      copyq) [[ -e /etc/xdg/autostart/xfce4-clipman-plugin-autostart.desktop ]] || continue ;;
      picom) # 只有用户目录里另有自己的 picom 自启动（如 codex-picom.desktop）时才关系统那份
        own=0; for c in "$ad"/*picom*.desktop; do [[ -f $c && ${c##*/} != picom.desktop ]] && own=1; done
        [[ $f == /etc/* ]] && ((own)) || continue ;;
      xcape) systemctl is-active keyd >/dev/null 2>&1 || continue ;;
    esac
    off+=("$n|$reason")
  done
  if ((${#off[@]})); then
    echo "可以关掉的开机自启动程序（程序本身不删，随时能手动打开）："
    for e in "${off[@]}"; do echo "  • ${e%%|*}：${e#*|}"; done
    confirm "关掉这些开机自启动？" y && ram_autostart_off "$user" "$ad" "${off[@]}"
  fi
  ram_panel_internal "$user" "$home"
  ram_desktop_services "$user" "$home"
}

ram_autostart_off() { # 用户 自启动目录 「名称|原因」…
  local user=$1 ad=$2 e n; shift 2
  mkdir -p "$ad"
  for e in "$@"; do
    n=${e%%|*}
    { grep -v '^Hidden=' "$ad/$n.desktop" 2>/dev/null || grep -v '^Hidden=' /etc/xdg/autostart/"$n".desktop; echo "Hidden=true"; } >"$ad/$n.desktop.tmp"
    mv -f "$ad/$n.desktop.tmp" "$ad/$n.desktop"
  done
  chown -R "$user:" "$ad"
  ok "已关掉 $# 个开机自启动（下次登录生效）"
}

# 任务栏插件默认每个单独一个进程（wrapper-2.0，每个约 11 MB）。在用户目录放一份 X-XFCE-Internal=TRUE 的插件说明文件，
# 插件就改在任务栏进程里运行（实测这台机器有 7 个）。代价：某个插件崩溃会连带任务栏重启一下
ram_panel_internal() {
  local user=$1 home=$2 d="$2/.local/share/xfce4/panel/plugins" f n cnt=0
  local ext=()
  for f in /usr/share/xfce4/panel/plugins/*.desktop; do
    grep -q '^X-XFCE-Internal=TRUE' "$f" && continue
    n=$(sed -n 's/^X-XFCE-Module=//p' "$f"); [[ -n $n ]] || continue
    ext+=("$f")
  done
  ((${#ext[@]})) || return 0
  confirm "任务栏插件改在任务栏进程里运行（${#ext[@]} 个插件，少 ${#ext[@]} 个进程，约省 $((${#ext[@]} * 8)) MB；插件崩溃会连带任务栏重启一下）？" y || return 0
  mkdir -p "$d"
  for f in "${ext[@]}"; do
    { grep -v '^X-XFCE-Internal=' "$f"; echo "X-XFCE-Internal=TRUE"; } >"$d/${f##*/}"
    cnt=$((cnt + 1))
  done
  chown -R "$user:" "$home/.local/share/xfce4"
  ok "任务栏插件：$cnt 个改为在任务栏进程里运行（重新登录后生效）"
}

# 用不到的桌面后台服务：无障碍总线（读屏软件用）、iPhone / 数码相机的自动识别。
# 用 ~/.config/systemd/user 里指向 /dev/null 的同名文件屏蔽（删掉这些文件即可恢复）
ram_desktop_services() {
  local user=$1 home=$2 u="$2/.config/systemd/user" s n=0
  confirm "关掉无障碍总线（不用读屏软件时）和 iPhone、数码相机的自动识别服务（约省 15 MB）？" y || return 0
  mkdir -p "$u"
  for s in at-spi-dbus-bus.service gvfs-afc-volume-monitor.service gvfs-gphoto2-volume-monitor.service; do
    [[ -e /usr/lib/systemd/user/$s ]] || continue
    ln -sf /dev/null "$u/$s"; n=$((n + 1))
  done
  chown -R "$user:" "$home/.config/systemd"
  # GTK 程序启动时也会尝试连无障碍总线，告诉它们不用连
  set_block /etc/environment a11y $'NO_AT_BRIDGE=1\nGTK_A11Y=none'
  local ad="$home/.config/autostart"
  if [[ -f /etc/xdg/autostart/at-spi-dbus-bus.desktop ]]; then
    { grep -v '^Hidden=' /etc/xdg/autostart/at-spi-dbus-bus.desktop; echo "Hidden=true"; } >"$ad/at-spi-dbus-bus.desktop"
    chown "$user:" "$ad/at-spi-dbus-bus.desktop"
  fi
  ok "已关掉 $n 个桌面后台服务和无障碍总线（重新登录后生效）"
}

step_services() {
  local s
  # 开机等联网：只有网络硬盘才需要。本机实测它让开机多等 4.4 秒（ZeroTier 等服务会拖着它）
  if systemctl is-enabled NetworkManager-wait-online.service >/dev/null 2>&1 &&
     ! grep -qE '^[^#]*[[:space:]](nfs4?|cifs|smb3|fuse\.sshfs)[[:space:]]' /etc/fstab 2>/dev/null; then
    confirm "开机时不再等待 Wi-Fi 连上（开机快约 4 秒，联网照常在后台完成）？" y &&
      systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 && ok "已关闭开机等待联网"
  fi
  # 说明文档已经不安装了（NoExtract），每天重建 man 索引只是白白读写硬盘
  if grep -q 'l4c:noextract' /etc/pacman.conf 2>/dev/null && systemctl is-enabled man-db.timer >/dev/null 2>&1; then
    systemctl disable man-db.timer >/dev/null 2>&1 && ok "已关闭 man-db 索引定时任务"
  fi
  [[ $L4C_CHROOT == 1 ]] && return 0
  if systemctl is-enabled cronie.service >/dev/null 2>&1 && [[ -z $(find /var/spool/cron -type f 2>/dev/null) ]] &&
     confirm "没有计划任务，关闭 cronie 服务？" y; then
    systemctl disable --now cronie.service >/dev/null 2>&1 && ok "已关闭 cronie.service"
  fi
  for s in cups.service cups.socket avahi-daemon.service ModemManager.service; do
    systemctl is-enabled "$s" >/dev/null 2>&1 || continue
    case $s in
      cups*) confirm "关闭打印服务 $s？（不用打印机就关掉）" n || continue ;;
      avahi*) confirm "关闭局域网发现服务 $s？" y || continue ;;
      ModemManager*) confirm "关闭 4G 上网卡服务 $s？（Chromebook 一般没有）" y || continue ;;
    esac
    systemctl disable --now "$s" >/dev/null 2>&1 && ok "已关闭 $s"
  done
  if ! pkg_installed tlp && ! pkg_installed auto-cpufreq; then
    pkg_install power-profiles-daemon && systemd_enable power-profiles-daemon.service
  fi
}

# ---------------------------------------------------------------- 清理 ----
step_clean() {
  local before after user home
  before=$(df --output=used -B1 / | tail -1)
  info "清理存储空间"
  if have paccache; then paccache -rqk1 2>/dev/null || true; paccache -ruqk0 2>/dev/null || true
  else pacman -Sc --noconfirm >/dev/null 2>&1 || true
  fi
  local orphans; orphans=$(pacman -Qtdq 2>/dev/null || true)
  if [[ -n $orphans ]]; then
    echo "不再被需要的软件包: $(echo "$orphans" | tr '\n' ' ')"
    if confirm "删除这些软件包？" y; then
      # shellcheck disable=SC2086
      pacman -Rns --noconfirm $orphans >/dev/null || warn "部分软件包删除失败"
    fi
  fi
  journalctl --vacuum-size=50M -q 2>/dev/null || true
  rm -rf /var/lib/systemd/coredump/* /var/tmp/* 2>/dev/null || true
  have flatpak && flatpak uninstall --unused -y --noninteractive >/dev/null 2>&1 || true
  user=$(target_user); home=$(user_home "$user")
  if [[ -n $home && $user != root ]]; then
    rm -rf "$home/.cache/thumbnails" "$home/.cache/mozilla/firefox"/*/cache2 2>/dev/null || true
    rm -rf "$home/.local/share/Trash/files"/* "$home/.local/share/Trash/info"/* 2>/dev/null || true
  fi
  after=$(df --output=used -B1 / | tail -1)
  ok "共腾出 $(human_size $((before > after ? before - after : 0)))，当前可用 $(df -h --output=avail / | tail -1 | xargs)"
}

if [[ $MODE == clean ]]; then step_clean; exit 0; fi
if [[ $MODE == ram ]]; then step_ram_apps; step_app_limits; step_browser_memory; exit 0; fi
if [[ $MODE == wine ]]; then step_wine; exit 0; fi

info "linux-for-chromebook $L4C_VERSION 系统优化"
step_zram
step_earlyoom
step_logs
step_pacman
step_disk
step_kernel
step_video
step_browser_memory
step_app_limits
step_input
step_wifi
step_battery
step_power_profile
step_microcode
step_wine
step_ram_apps
step_services
if [[ $L4C_CHROOT != 1 ]] && confirm "最后做一次存储清理？" y; then step_clean; fi
ok "优化完成。建议重启一次让所有设置生效。"
