#!/usr/bin/env bash
# l4c 任务栏：查询 Wi-Fi 状态，输出「图标名|提示文字」（由 tray.sh 每 5 秒调用一次；--rescan no 只读缓存，不触发扫描）
line=$(nmcli -t -f IN-USE,SIGNAL,SSID dev wifi list --rescan no 2>/dev/null | grep '^\*' | head -1)
sig=$(cut -d: -f2 <<<"$line"); ssid=$(cut -d: -f3- <<<"$line")
if [[ -z $line ]]; then
  if nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^ethernet:connected'; then echo "nm-device-wired|已连接有线网络"
  else echo "nm-no-connection|未连接网络"; fi
  exit 0
fi
if ((sig >= 80)); then icon=nm-signal-100; elif ((sig >= 55)); then icon=nm-signal-75
elif ((sig >= 30)); then icon=nm-signal-50; elif ((sig >= 5)); then icon=nm-signal-25; else icon=nm-signal-00; fi
echo "$icon|$ssid（信号 $sig%）"
