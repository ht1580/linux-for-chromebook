#!/usr/bin/env bash
# l4c 任务栏：输入法指示（genmon 插件每秒调用一次，瞬间完成）。点一下切换中/英，和 Win11 的“中/英”按钮一样
s=$(fcitx5-remote 2>/dev/null)
if [[ $s == 2 ]]; then t=中; tip="中文（拼音）"; else t=英; tip="英文"; fi
echo "<txt><span font_size='11pt'>$t</span></txt><txtclick>fcitx5-remote -t</txtclick><tool>输入法：$tip
单击或按 Shift 切换中/英</tool>"
