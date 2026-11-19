#!/usr/bin/env bash
# l4c 任务栏：Wi-Fi 指示（genmon 插件每 5 秒调用一次；--rescan no 只读缓存，不触发扫描）。点一下打开托盘弹出框里的网络图标
line=$(nmcli -t -f IN-USE,SIGNAL,SSID dev wifi list --rescan no 2>/dev/null | grep '^\*' | head -1)
sig=$(cut -d: -f2 <<<"$line"); ssid=$(cut -d: -f3- <<<"$line")
if [[ -z $line ]]; then
  if nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^ethernet:connected'; then icon=nm-device-wired; tip="已连接有线网络"
  else icon=nm-no-connection; tip="未连接网络"; fi
else
  if ((sig >= 80)); then icon=nm-signal-100; elif ((sig >= 55)); then icon=nm-signal-75
  elif ((sig >= 30)); then icon=nm-signal-50; elif ((sig >= 5)); then icon=nm-signal-25; else icon=nm-signal-00; fi
  tip="$ssid（信号 $sig%）"
fi
echo "<icon>$icon</icon><iconclick>$(dirname "$(readlink -f "$0")")/flyout.sh</iconclick><tool>$tip
单击打开网络和其他托盘图标</tool>"
