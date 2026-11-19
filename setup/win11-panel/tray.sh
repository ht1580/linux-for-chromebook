#!/usr/bin/env bash
# l4c 任务栏右侧的「中/英」和 Wi-Fi：合在一个 genmon 插件里（每个面板插件都是一个约 10 MB 的进程）。
# genmon 每 1.5 秒调用一次（实测每次约 8 毫秒），所以尽量只用 bash 内置功能：每次只启动一个 fcitx5-remote；Wi-Fi 每 5 秒才查一次，其余时候读缓存。
#   单击「中/英」切换输入法；单击 Wi-Fi 图标打开 ^ 弹出框（网络图标在里面）
D=${BASH_SOURCE[0]%/*}
C=${XDG_RUNTIME_DIR:-/tmp}/l4c-wifi-status
stamp=0 icon="" tip=""
[[ -f $C ]] && IFS='|' read -r stamp icon tip <"$C"
if ((EPOCHSECONDS - stamp >= 5)); then
  IFS='|' read -r icon tip < <("$D/wifi.sh" 2>/dev/null)
  printf '%s|%s|%s\n' "$EPOCHSECONDS" "$icon" "$tip" >"$C"
fi
if [[ $(fcitx5-remote 2>/dev/null) == 2 ]]; then t=中; ime="中文（拼音）"; else t=英; ime=英文; fi
printf '%s' "<icon>${icon:-nm-no-connection}</icon><iconclick>$D/flyout.sh</iconclick><txt><span font_size='11pt'> $t </span></txt><txtclick>fcitx5-remote -t</txtclick><tool>输入法：$ime（单击或按 Shift 切换）
网络：${tip:-未知}（单击图标打开网络和其他托盘图标）</tool>"
