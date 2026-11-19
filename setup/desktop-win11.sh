#!/usr/bin/env bash
# 把 Xfce 调成 Windows 11 的使用习惯：居中任务栏、开始菜单、贴靠分屏、Win 快捷键、输入法。
#   ./setup/desktop-win11.sh                 在当前 Xfce 会话里应用（普通用户运行）
#   ./setup/desktop-win11.sh --theme         同时切换到 Fluent（Win11 风格）主题
#   ./setup/desktop-win11.sh --no-panel      不改任务栏，只改快捷键和窗口行为
#   ./setup/desktop-win11.sh --restore DIR   恢复之前备份的 Xfce 设置
#   sudo ./setup/desktop-win11.sh --install-theme   系统级安装 Fluent 主题和图标
#   ./setup/desktop-win11.sh --look          只换外观：壁纸、锁屏/屏保、通知位置、开始菜单、光标、合成器
#   sudo ./setup/desktop-win11.sh --system-look     系统级外观：Win11 登录界面、壁纸文件、开机菜单 1 秒、精简光标包
# 修改前会把原有 Xfce 设置备份到 ~/.local/share/l4c/xfce-backup-时间/
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

XFCONF_DIR="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
PANEL_DIR="$HOME/.config/xfce4/panel"
DO_PANEL=1 DO_THEME=0 FIRST_LOGIN=0

# ---------------------------------------------------------------- 主题 ----
install_theme_system() {
  require_root
  pkg_install git sassc
  local dir; dir=$(mktemp -d)
  info "安装 Fluent 主题（开源项目 vinceliuice/Fluent-gtk-theme）"
  if git clone --depth 1 https://github.com/vinceliuice/Fluent-gtk-theme "$dir/gtk"; then
    (cd "$dir/gtk" && ./install.sh -d /usr/share/themes >/dev/null) && ok "Fluent GTK 主题已安装" || warn "GTK 主题安装失败"
  fi
  if git clone --depth 1 https://github.com/vinceliuice/Fluent-icon-theme "$dir/icons"; then
    (cd "$dir/icons" && ./install.sh -d /usr/share/icons >/dev/null) && ok "Fluent 图标已安装" || warn "图标安装失败"
  fi
  rm -rf "$dir"
  install_system_look
}

# 系统级的 Win11 外观：壁纸、登录/锁屏界面、开机菜单，以及去掉用不到的大主题包。
# 全部只是配置和一张图片，不增加常驻程序；顺带腾出约 300 MB。
install_system_look() {
  require_root
  local bg=/usr/share/backgrounds/l4c
  mkdir -p "$bg"
  install -m 644 "$L4C_ROOT/config/wallpaper/l4c-win11.svg" "$bg/l4c-win11.svg"
  # 预先渲染成 PNG：每次开机/登录解码 PNG 比渲染 SVG 快得多
  if have rsvg-convert; then
    rsvg-convert -w 1920 -h 1080 -o "$bg/l4c-win11.png" "$bg/l4c-win11.svg" && ok "壁纸：$bg/l4c-win11.png"
  else
    cp "$bg/l4c-win11.svg" "$bg/l4c-win11.png.svg"; warn "没有 rsvg-convert，壁纸使用 SVG"
  fi

  if [[ -d /etc/lightdm ]]; then
    backup_file /etc/lightdm/lightdm-gtk-greeter.conf
    put_config lightdm/lightdm-gtk-greeter.conf /etc/lightdm/lightdm-gtk-greeter.conf
    [[ -f $bg/l4c-win11.png ]] || sed -i "s|^background=.*|background=$bg/l4c-win11.svg|" /etc/lightdm/lightdm-gtk-greeter.conf
    ok "登录界面：Win11 风格（重启或注销后可见）"
  fi

  # 开机：GRUB 菜单本来就隐藏，等待从 2 秒减到 1 秒（开机时按 Esc 仍可调出菜单）
  if [[ -f /etc/default/grub ]] && grep -q '^GRUB_TIMEOUT_STYLE=hidden' /etc/default/grub &&
     grep -qE '^GRUB_TIMEOUT=[2-9]' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
    { have update-grub && update-grub >/dev/null 2>&1; } || grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    ok "开机菜单等待改为 1 秒"
  fi

  # 光标包 bibata-cursor-theme-bin 带 12 个变体（约 320 MB），只留 Win11 风格的白色 Modern-Ice
  if pkg_installed bibata-cursor-theme-bin && [[ -d /usr/share/icons/Bibata-Modern-Ice ]] &&
     confirm "光标包有 12 个变体约 320 MB，只保留用到的白色光标（腾出约 290 MB）？" y; then
    local keep; keep=$(mktemp -d)
    cp -a /usr/share/icons/Bibata-Modern-Ice "$keep/" &&
      pacman -Rns --noconfirm bibata-cursor-theme-bin >/dev/null &&
      mv "$keep/Bibata-Modern-Ice" /usr/share/icons/ && ok "光标包已精简" || warn "光标包精简失败"
    rm -rf "$keep"
  fi
  # 旧系统带来的 Matcha 主题，Win11 外观用不到
  if pkg_installed matcha-gtk-theme && ! grep -rqs Matcha /home/*/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml &&
     confirm "删除用不到的 Matcha 主题（约 28 MB）？" y; then
    pacman -Rns --noconfirm matcha-gtk-theme >/dev/null && ok "Matcha 主题已删除"
  fi
}

first_existing() { # 在主题目录里找第一个存在的名字
  local kind=$1; shift
  local n d
  for n in "$@"; do
    for d in "$HOME/.themes" "$HOME/.local/share/$kind" "/usr/share/$kind"; do
      [[ -d $d/$n ]] && { echo "$n"; return 0; }
    done
  done
  return 1
}

# ---------------------------------------------------------------- 工具 ----
xset_() { # 通道 属性 类型 值
  xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4" 2>/dev/null ||
    xfconf-query -c "$1" -p "$2" -s "$4" 2>/dev/null || warn "无法设置 $1 $2"
}
xdel_() { xfconf-query -c "$1" -p "$2" -r 2>/dev/null || true; }

plugin_exists() { ls /usr/lib/xfce4/panel/plugins/lib"$1".so >/dev/null 2>&1 || ls /usr/lib/xfce4/panel/plugins/lib"$1"*.so >/dev/null 2>&1; }

backup_xfce() {
  local dst; dst="$HOME/.local/share/l4c/xfce-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dst"
  [[ -d $XFCONF_DIR ]] && cp -a "$XFCONF_DIR" "$dst/"
  [[ -d $PANEL_DIR ]] && cp -a "$PANEL_DIR" "$dst/"
  ok "原有 Xfce 设置已备份到 $dst"
}

restore_xfce() {
  local src=$1
  [[ -d $src/xfce-perchannel-xml ]] || die "$src 不是有效的备份目录"
  xfce4-panel --quit 2>/dev/null || true
  pkill -x xfconfd 2>/dev/null || true
  sleep 1
  mkdir -p "$XFCONF_DIR" "$PANEL_DIR"
  cp -a "$src/xfce-perchannel-xml/." "$XFCONF_DIR/"
  [[ -d $src/panel ]] && cp -a "$src/panel/." "$PANEL_DIR/"
  (setsid xfce4-panel >/dev/null 2>&1 &)
  xfwm4 --replace >/dev/null 2>&1 & disown
  ok "已恢复 $src，如有异常请注销后重新登录"
}

# ---------------------------------------------------------------- 快捷键 ----
# 格式：按键|命令   （Windows 11 同名快捷键）
COMMANDS=(
  "Super_L|xfce4-popup-whiskermenu"                       # Win        开始菜单
  "<Super>s|xfce4-popup-whiskermenu"                      # Win+S      搜索
  "<Super>e|thunar"                                       # Win+E      文件资源管理器
  "<Super>r|xfce4-appfinder --collapsed"                  # Win+R      运行
  "<Super>i|xfce4-settings-manager"                       # Win+I      设置
  "<Super>l|xflock4"                                      # Win+L      锁屏
  "<Super>v|xfce4-popup-clipman"                          # Win+V      剪贴板历史
  "<Super>x|xfce4-session-logout"                         # Win+X      关机/注销菜单
  "<Super>p|xfce4-display-settings --minimal"             # Win+P      投影/外接显示器
  "<Super><Shift>s|xfce4-screenshooter -r -c"             # Win+Shift+S 截图到剪贴板
  "Print|xfce4-screenshooter"                             # PrtSc      截图工具
  "<Primary><Shift>Escape|xfce4-taskmanager"              # Ctrl+Shift+Esc 任务管理器
  "<Primary><Alt>Delete|xfce4-session-logout"             # Ctrl+Alt+Del
  "<Primary><Alt>t|xfce4-terminal"                        # Ctrl+Alt+T 终端
)
# 格式：按键|xfwm4 动作
WM_KEYS=(
  "<Super>Left|tile_left_key"                 # Win+←  左半屏
  "<Super>Right|tile_right_key"               # Win+→  右半屏
  "<Super>Up|maximize_window_key"             # Win+↑  最大化
  "<Super>Down|hide_window_key"               # Win+↓  最小化
  "<Super><Alt>Left|tile_up_left_key"         # 左上 1/4
  "<Super><Alt>Right|tile_up_right_key"       # 右上 1/4
  "<Super><Alt><Shift>Left|tile_down_left_key"   # 左下 1/4
  "<Super><Alt><Shift>Right|tile_down_right_key" # 右下 1/4
  "<Super>d|show_desktop_key"                 # Win+D  显示桌面
  "<Super>m|show_desktop_key"                 # Win+M  全部最小化
  "<Super>Tab|switch_window_key"              # Win+Tab 任务视图
  "<Alt>Tab|cycle_windows_key"                # Alt+Tab
  "<Alt><Shift>Tab|cycle_reverse_windows_key"
  "<Alt>F4|close_window_key"                  # Alt+F4
  "<Super><Primary>Left|left_workspace_key"   # Win+Ctrl+← 上一个桌面
  "<Super><Primary>Right|right_workspace_key" # Win+Ctrl+→ 下一个桌面
  "<Super><Shift>Left|move_window_left_workspace_key"
  "<Super><Shift>Right|move_window_right_workspace_key"
)

apply_shortcuts() {
  local e key val
  for e in "${COMMANDS[@]}"; do
    key=${e%%|*}; val=${e#*|}
    xdel_ xfce4-keyboard-shortcuts "/xfwm4/custom/$key"
    xset_ xfce4-keyboard-shortcuts "/commands/custom/$key" string "$val"
  done
  for e in "${WM_KEYS[@]}"; do
    key=${e%%|*}; val=${e#*|}
    xdel_ xfce4-keyboard-shortcuts "/commands/custom/$key"
    xset_ xfce4-keyboard-shortcuts "/xfwm4/custom/$key" string "$val"
  done
  ok "Windows 快捷键已设置（完整列表见 docs/shortcuts.md）"
}

apply_wm() {
  xset_ xfwm4 /general/button_layout string "O|HMC"       # 最小化/最大化/关闭在右上角
  xset_ xfwm4 /general/title_alignment string "left"
  xset_ xfwm4 /general/tile_on_move bool true              # 拖到屏幕边缘自动分屏
  xset_ xfwm4 /general/snap_to_border bool true
  xset_ xfwm4 /general/snap_to_windows bool true
  xset_ xfwm4 /general/wrap_windows bool false
  xset_ xfwm4 /general/workspace_count int 4
  xset_ xfwm4 /general/cycle_preview bool true
  xset_ xfwm4 /general/cycle_tabwin_mode int 0
  xset_ xfwm4 /general/double_click_action string "maximize"
  apply_compositor
  xset_ xfwm4 /general/vblank_mode string "glx"
  xset_ xfwm4 /general/show_dock_shadow bool false
  xset_ xfce4-desktop /desktop-icons/style int 2
  xset_ xfce4-desktop /desktop-icons/file-icons/show-home bool true
  xset_ xfce4-desktop /desktop-icons/file-icons/show-trash bool true
  xset_ xfce4-desktop /desktop-icons/file-icons/show-filesystem bool false
  xset_ thunar /misc-single-click bool false
  xset_ thunar /last-view string "ThunarDetailsView"
  xset_ thunar /misc-thumbnail-max-file-size uint64 5242880   # 只给 5MB 以下的文件生成缩略图
  xset_ xfce4-power-manager /xfce4-power-manager/handle-brightness-keys bool true
  xset_ xfce4-power-manager /xfce4-power-manager/show-tray-icon bool false
  xset_ xsettings /Gtk/DecorationLayout string "menu:minimize,maximize,close"
  ok "窗口行为已设置：拖到边缘分屏、按钮在右上角"
}

apply_theme() {
  local t i c
  t=$(first_existing themes Fluent-Light Fluent Fluent-round-Light Fluent-round) || { warn "没找到 Fluent 主题，先运行：sudo l4c theme"; return 0; }
  xset_ xsettings /Net/ThemeName string "$t"
  xset_ xfwm4 /general/theme string "$t"
  if i=$(first_existing icons Fluent Fluent-light); then xset_ xsettings /Net/IconThemeName string "$i"; fi
  # Win11 的光标是白色箭头
  if c=$(first_existing icons Bibata-Modern-Ice Bibata-Modern-Classic); then xset_ xsettings /Gtk/CursorThemeName string "$c"; fi
  ok "主题已切换为 $t"
}

# 只能有一个合成器：用户自己开了 picom（圆角、阴影 = Win11 外观）就关掉 xfwm4 的合成，避免两份开销
apply_compositor() {
  local pc="$HOME/.config/picom/picom.conf" a
  for a in "$HOME"/.config/autostart/*picom*.desktop /etc/xdg/autostart/picom.desktop; do
    [[ -f $a ]] && ! grep -qi '^Hidden=true' "$a" && { USE_PICOM=1; break; }
  done
  if ((${USE_PICOM:-0})); then
    xset_ xfwm4 /general/use_compositing bool false
    # 非活动窗口半透明每帧都要多混合一次，Win11 也没有这个效果
    if [[ -f $pc ]] && grep -qE '^\s*inactive-opacity\s*=\s*0\.' "$pc"; then
      cp -n "$pc" "$pc.l4c-bak"
      sed -i -E 's/^(\s*inactive-opacity\s*=\s*)0\.[0-9]+/\11.0/' "$pc"
    fi
    ok "窗口合成：只用 picom（圆角 + 阴影），已关闭 xfwm4 自带合成"
  else
    xset_ xfwm4 /general/use_compositing bool true
  fi
}

# 壁纸：所有显示器、所有工作区
apply_wallpaper() {
  local img=/usr/share/backgrounds/l4c/l4c-win11.png mon ws props
  [[ -f $img ]] || img=/usr/share/backgrounds/l4c/l4c-win11.svg
  [[ -f $img ]] || { warn "没有 Win11 壁纸，先运行：sudo bash $L4C_ROOT/setup/desktop-win11.sh --system-look"; return 0; }
  props=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/workspace[0-9]+/last-image$' || true)
  if [[ -z $props ]] && have xrandr; then
    for mon in $(xrandr --listmonitors 2>/dev/null | awk 'NR>1 {print $NF}'); do
      for ws in 0 1 2 3; do props+="/backdrop/screen0/monitor$mon/workspace$ws/last-image"$'\n'; done
    done
  fi
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    xset_ xfce4-desktop "$p" string "$img"
    xset_ xfce4-desktop "${p%/last-image}/image-style" int 5   # 缩放填满
  done <<<"$props"
  ok "壁纸：Win11 风格"
}

# 屏保 / 锁屏：和 Win11 一样，空闲后直接黑屏（不放动画，省电），唤醒要输密码
apply_lockscreen() {
  have xfce4-screensaver || return 0
  xset_ xfce4-screensaver /saver/enabled bool true
  xset_ xfce4-screensaver /saver/mode int 0                 # 0 = 只黑屏
  xset_ xfce4-screensaver /saver/idle-activation/enabled bool true
  xset_ xfce4-screensaver /saver/idle-activation/delay int 5
  xset_ xfce4-screensaver /saver/fullscreen-inhibit bool true   # 全屏看视频时不黑屏
  xset_ xfce4-screensaver /lock/enabled bool true
  xset_ xfce4-screensaver /lock/saver-activation/enabled bool true
  xset_ xfce4-screensaver /lock/saver-activation/delay int 0
  xset_ xfce4-screensaver /lock/sleep-activation bool true      # 合盖/睡眠后要密码
  xset_ xfce4-screensaver /lock/status-messages/enabled bool false
  ok "屏保：空闲 5 分钟黑屏，唤醒需要密码（Win+L 立即锁屏）"
}

# 通知：右下角滑出，5 秒后消失
apply_notify() {
  xset_ xfce4-notifyd /notify-location uint 3
  xset_ xfce4-notifyd /do-slideout bool true
  xset_ xfce4-notifyd /expire-timeout int 5
}

# 开始菜单：搜索在顶部，先显示“已固定”，底部是电源/锁屏
apply_menu() {
  local id
  for id in $(xfconf-query -c xfce4-panel -lv 2>/dev/null | awk '$2=="whiskermenu" {sub(".*/plugin-","",$1); print $1}'); do
    local b=/plugins/plugin-$id
    xset_ xfce4-panel "$b/position-search-alternate" bool true
    xset_ xfce4-panel "$b/position-commands-alternate" bool true
    xset_ xfce4-panel "$b/default-category" int 0
    xset_ xfce4-panel "$b/category-show-name" bool true
    xset_ xfce4-panel "$b/show-button-title" bool false
    xset_ xfce4-panel "$b/profile-shape" int 0
    xset_ xfce4-panel "$b/recent-items-max" int 6
    xset_ xfce4-panel "$b/menu-width" int 620
    xset_ xfce4-panel "$b/menu-height" int 560
    local c; for c in lockscreen logoutuser restart shutdown settings; do xset_ xfce4-panel "$b/show-command-$c" bool true; done
    for c in switchuser suspend hibernate menueditor profile; do xset_ xfce4-panel "$b/show-command-$c" bool false; done
  done
  ok "开始菜单：搜索在顶部，已固定的应用在前，底部是锁屏/重启/关机"
}

# 只换外观（主题、壁纸、锁屏、通知、开始菜单、合成器），不动任务栏和快捷键
apply_look() {
  apply_theme
  apply_compositor
  apply_wallpaper
  apply_lockscreen
  apply_notify
  apply_menu
}

apply_fcitx() {
  have fcitx5 || return 0
  local cfg="$HOME/.config/fcitx5"
  mkdir -p "$cfg"
  if [[ ! -f $cfg/profile ]] && [[ -n $(ls /usr/lib/fcitx5/*pinyin* 2>/dev/null) ]]; then
    cat >"$cfg/profile" <<'EOF'
[Groups/0]
Name=默认
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=默认
EOF
  fi
  if [[ ! -f $cfg/config ]]; then
    cat >"$cfg/config" <<'EOF'
[Hotkey]
EnumerateWithTriggerKeys=True

[Hotkey/TriggerKeys]
0=Control+space
1=Super+space

[Hotkey/AltTriggerKeys]
0=Shift_L
EOF
  fi
  ok "输入法：Shift 切换中/英，Win+空格 或 Ctrl+空格 开关拼音"
}

add_templates() {
  local t
  t=$(xdg-user-dir TEMPLATES 2>/dev/null || echo "$HOME/Templates")
  [[ $t == "$HOME" ]] && t="$HOME/Templates"
  mkdir -p "$t"
  [[ -e $t/新建文本文档.txt ]] || : >"$t/新建文本文档.txt"
  ok "文件管理器右键 → 新建文档 → 新建文本文档"
}

# ---------------------------------------------------------------- 任务栏 ----
apply_panel() {
  local menu=whiskermenu tasks=docklike p
  plugin_exists whiskermenu || { warn "没装 whiskermenu，开始菜单改用经典菜单"; menu=applicationsmenu; }
  plugin_exists docklike || { warn "没装 xfce4-docklike-plugin，任务栏改用经典窗口按钮"; tasks=tasklist; }

  xfce4-panel --quit 2>/dev/null || true
  pkill -x xfconfd 2>/dev/null || true
  sleep 1
  mkdir -p "$XFCONF_DIR" "$PANEL_DIR"
  rm -f "$PANEL_DIR"/docklike-*.rc "$PANEL_DIR"/whiskermenu-*.rc

  local pinned=""
  for p in firefox thunar xfce4-terminal mousepad; do
    [[ -f /usr/share/applications/$p.desktop ]] && pinned+="/usr/share/applications/$p.desktop;"
  done
  if [[ $tasks == docklike ]]; then
    cat >"$PANEL_DIR/docklike-3.rc" <<EOF
[user]
pinned=$pinned
keyboardShortcuts=true
showPreviews=true
noWindowsListIfSingle=true
onlyDisplayScreen=false
indicatorOrientation=0
EOF
  fi

  cat >"$XFCONF_DIR/xfce4-panel.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- 由 linux-for-chromebook 生成：Windows 11 风格居中任务栏 -->
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="40"/>
      <property name="icon-size" type="uint" value="24"/>
      <property name="enable-struts" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/><value type="int" value="2"/><value type="int" value="3"/>
        <value type="int" value="4"/><value type="int" value="5"/><value type="int" value="6"/>
        <value type="int" value="7"/><value type="int" value="8"/><value type="int" value="9"/>
        <value type="int" value="10"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-2" type="string" value="$menu">
      <property name="show-button-title" type="bool" value="false"/>
      <property name="button-icon" type="string" value="start-here"/>
      <property name="position-search-alternate" type="bool" value="true"/>
      <property name="position-commands-alternate" type="bool" value="true"/>
      <property name="menu-width" type="int" value="600"/>
      <property name="menu-height" type="int" value="520"/>
    </property>
    <property name="plugin-3" type="string" value="$tasks">
      <property name="show-labels" type="bool" value="false"/>
      <property name="grouping" type="uint" value="1"/>
      <property name="flat-buttons" type="bool" value="true"/>
    </property>
    <property name="plugin-4" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-5" type="string" value="systray">
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-6" type="string" value="pulseaudio">
      <property name="enable-keyboard-shortcuts" type="bool" value="true"/>
    </property>
    <property name="plugin-7" type="string" value="power-manager-plugin"/>
    <property name="plugin-8" type="string" value="notification-plugin"/>
    <property name="plugin-9" type="string" value="clock">
      <property name="mode" type="uint" value="2"/>
      <property name="digital-layout" type="uint" value="1"/>
      <property name="digital-time-format" type="string" value="%H:%M"/>
      <property name="digital-date-format" type="string" value="%Y/%m/%d"/>
      <property name="tooltip-format" type="string" value="%Y年%m月%d日 %A"/>
    </property>
    <property name="plugin-10" type="string" value="showdesktop"/>
  </property>
</channel>
EOF
  (setsid xfce4-panel >/dev/null 2>&1 &)
  ok "已设置 Windows 11 风格任务栏：居中开始菜单 + 固定应用（Win+1…9 打开第几个），右侧托盘和时钟"
}

# ---------------------------------------------------------------- 主流程 ----
ARGS=()
while (($#)); do
  case $1 in
    --install-theme) install_theme_system; exit 0 ;;
    --system-look) install_system_look; exit 0 ;;
    --look) DO_LOOK_ONLY=1 ;;
    --restore) restore_xfce "${2:?需要备份目录}"; exit 0 ;;
    --theme) DO_THEME=1 ;;
    --no-panel) DO_PANEL=0 ;;
    --first-login) FIRST_LOGIN=1; L4C_YES=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
((${#ARGS[@]} == 0)) || die "未知参数: ${ARGS[*]}"

require_user
have xfconf-query || die "没找到 xfconf-query，本脚本只支持 Xfce 桌面"
[[ -n ${DISPLAY:-} ]] || die "请在桌面环境的终端里运行（需要图形会话）"

if ((FIRST_LOGIN)); then
  sleep 8   # 等桌面完全启动
  [[ -f $HOME/.config/l4c/first-login.args ]] && read -r -a extra <"$HOME/.config/l4c/first-login.args" || extra=()
  for a in "${extra[@]}"; do
    case $a in --theme) DO_THEME=1 ;; --no-panel) DO_PANEL=0 ;; esac
  done
fi

if ((${DO_LOOK_ONLY:-0})); then
  info "应用 Windows 11 外观"
  backup_xfce
  apply_look
  pgrep -x picom >/dev/null && ((${USE_PICOM:-0})) && { pkill -USR1 -x picom 2>/dev/null || true; }   # 让 picom 重新读配置
  ok "完成！登录界面在注销或重启后可见。"
  exit 0
fi

info "应用 Windows 11 使用习惯"
backup_xfce
apply_shortcuts
apply_wm
((DO_THEME)) && apply_look
apply_fcitx
add_templates
((DO_PANEL)) && apply_panel
((DO_THEME)) && apply_menu   # 新生成的任务栏也要套上开始菜单样式

if ((FIRST_LOGIN)); then
  rm -f "$HOME/.config/autostart/l4c-first-login.desktop" "$HOME/.config/l4c/first-login.args"
  have notify-send && notify-send -i start-here "欢迎使用" "已应用 Windows 11 使用习惯。快捷键说明：/opt/linux-for-chromebook/docs/shortcuts.md" || true
fi
ok "完成！个别设置（主题、输入法）注销后重新登录才完全生效。"
