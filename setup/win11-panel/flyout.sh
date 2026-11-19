#!/usr/bin/env bash
# shellcheck disable=SC2154
# （X、Y、F_X 等变量由 eval "$(xdotool ... --shell)" 设置，shellcheck 看不到）
# l4c 任务栏：显示/隐藏 Win11 式「隐藏的图标」弹出框（第二个小面板，里面是托盘网格）。
# 打开后鼠标离开弹出框约 1 秒自动收起（只在打开期间每 0.3 秒看一次鼠标位置）。
#   flyout.sh         切换    flyout.sh --hide   收起（登录时用）
W_CACHE=${XDG_RUNTIME_DIR:-/tmp}/l4c-flyout-win
SW=$(xdotool getdisplaygeometry | cut -d' ' -f1)

find_win() { # 托盘面板窗口：xfce4-panel 的窗口里宽度小于屏幕、最高的那个
  local w best="" bh=0 W H
  for w in $(xdotool search --classname xfce4-panel 2>/dev/null); do
    eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null | grep -E '^(WIDTH|HEIGHT)=')"
    W=${WIDTH:-0} H=${HEIGHT:-0}
    ((W < SW && W > 60 && H > 60 && H > bh)) && { best=$w; bh=$H; }
  done
  echo "$best"
}
W=$(cat "$W_CACHE" 2>/dev/null)
[[ -n $W ]] && xdotool getwindowgeometry "$W" >/dev/null 2>&1 || { W=$(find_win); echo "$W" >"$W_CACHE"; }
[[ -n $W ]] || exit 0
visible() { xdotool search --onlyvisible --classname xfce4-panel 2>/dev/null | grep -qx "$W"; }

if [[ ${1:-} == --hide ]] || visible; then
  xdotool windowunmap "$W"; exit 0
fi
# 摆到 ^ 正上方：以点击时的鼠标位置为中心，底边离任务栏 8 像素（和 Win11 一样）
eval "$(xdotool getmouselocation --shell)"
SH=$(xdotool getdisplaygeometry | cut -d' ' -f2)
eval "$(xdotool getwindowgeometry --shell "$W" | sed 's/^/F_/')"
NX=$((X - F_WIDTH / 2)); ((NX + F_WIDTH > SW - 8)) && NX=$((SW - 8 - F_WIDTH)); ((NX < 8)) && NX=8
NY=$((SH - 48 - 8 - F_HEIGHT))
xdotool windowmap "$W"; xdotool windowmove "$W" "$NX" "$NY"; xdotool windowraise "$W" 2>/dev/null
# 鼠标离开弹出框（以及右下角任务栏的托盘区）约 1 秒后自动收起
(
  away=0
  while visible; do
    sleep 0.3
    eval "$(xdotool getmouselocation --shell)"
    eval "$(xdotool getwindowgeometry --shell "$W" | sed 's/^/F_/')"
    if ((X >= F_X - 10 && X <= F_X + F_WIDTH + 10 && Y >= F_Y - 10)); then away=0
    else away=$((away + 1)); ((away >= 4)) && { xdotool windowunmap "$W"; break; }
    fi
  done
) >/dev/null 2>&1 &
