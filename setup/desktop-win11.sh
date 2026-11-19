#!/usr/bin/env bash
# 把 Xfce 调成 Windows 11 的使用习惯：居中任务栏、开始菜单、贴靠分屏、Win 快捷键、输入法。
#   ./setup/desktop-win11.sh                 在当前 Xfce 会话里应用（普通用户运行）
#   ./setup/desktop-win11.sh --theme         同时切换到 Fluent（Win11 风格）主题
#   ./setup/desktop-win11.sh --no-panel      不改任务栏，只改快捷键和窗口行为
#   ./setup/desktop-win11.sh --restore DIR   恢复之前备份的 Xfce 设置
#   sudo ./setup/desktop-win11.sh --install-theme   系统级安装 Fluent 主题和图标
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
  xset_ xfwm4 /general/use_compositing bool true
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
  if c=$(first_existing icons Bibata-Modern-Classic Bibata-Modern-Ice); then xset_ xsettings /Gtk/CursorThemeName string "$c"; fi
  ok "主题已切换为 $t"
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
    --restore) restore_xfce "${2:?需要备份目录}"; exit 0 ;;
    --theme) DO_THEME=1 ;;
    --no-panel) DO_PANEL=0 ;;
    --first-login) FIRST_LOGIN=1; L4C_YES=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
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

info "应用 Windows 11 使用习惯"
backup_xfce
apply_shortcuts
apply_wm
((DO_THEME)) && apply_theme
apply_fcitx
add_templates
((DO_PANEL)) && apply_panel

if ((FIRST_LOGIN)); then
  rm -f "$HOME/.config/autostart/l4c-first-login.desktop" "$HOME/.config/l4c/first-login.args"
  have notify-send && notify-send -i start-here "欢迎使用" "已应用 Windows 11 使用习惯。快捷键说明：/opt/linux-for-chromebook/docs/shortcuts.md" || true
fi
ok "完成！个别设置（主题、输入法）注销后重新登录才完全生效。"
