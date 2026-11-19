#!/usr/bin/env bash
# 由 install.sh 在新系统的 chroot 里调用，不要单独运行。
set -Eeuo pipefail
export L4C_CHROOT=1
source /opt/linux-for-chromebook/lib/common.sh
[[ -f /root/l4c-install.env ]] || die "只能由 install.sh 调用"

declare -A C=()
while IFS= read -r line; do
  [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] && C[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
done </root/l4c-install.env
U=${C[USERNAME_]}

info "时区、语言、主机名"
ln -sf "/usr/share/zoneinfo/${C[TIMEZONE_]}" /etc/localtime
hwclock --systohc 2>/dev/null || true
for l in en_US.UTF-8 "${C[LOCALE_]}"; do sed -i "s/^#\s*\(${l//./\\.}\s\)/\1/" /etc/locale.gen; done
locale-gen >/dev/null
echo "LANG=${C[LOCALE_]}" >/etc/locale.conf
echo "KEYMAP=us" >/etc/vconsole.conf
echo "${C[HOSTNAME_]}" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${C[HOSTNAME_]}.localdomain ${C[HOSTNAME_]}
EOF

info "创建用户 $U"
shell=${C[USER_SHELL]}; [[ -x $shell ]] || shell=/usr/bin/zsh; [[ -x $shell ]] || shell=/bin/bash
useradd -m -c "${C[FULLNAME_]}" -G wheel,video,audio,input,lp -s "$shell" "$U"
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-l4c-wheel
chmod 440 /etc/sudoers.d/10-l4c-wheel
until passwd "$U"; do warn "请重新输入"; done
passwd -l root >/dev/null   # 和 Windows 一样只用自己的账户 + 管理员授权（sudo）
[[ $shell == */zsh && ! -e /home/$U/.zshrc ]] && cat >"/home/$U/.zshrc" <<'EOF'
# 由 linux-for-chromebook 生成
HISTFILE=~/.zsh_history HISTSIZE=5000 SAVEHIST=5000
setopt share_history hist_ignore_dups autocd
autoload -Uz compinit && compinit
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
PROMPT='%F{blue}%~%f %# '
EOF
chown -R "$U:" "/home/$U"

info "引导程序"
sed -i -E 's/^#?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/; s/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
sed -i -E 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 nowatchdog zswap.enabled=0"/' /etc/default/grub
GRUB_EFI=(--target=x86_64-efi --efi-directory=/boot/efi)
if ! grub-install "${GRUB_EFI[@]}" --bootloader-id="${C[BOOT_ID]:-Linux}" --recheck; then
  # 原厂固件的 RW_LEGACY 模式有时不让写 UEFI 启动项；它本来就只认下面的默认路径
  warn "无法写入 UEFI 启动项，改为只安装引导文件"
  grub-install "${GRUB_EFI[@]}" --bootloader-id="${C[BOOT_ID]:-Linux}" --no-nvram
fi
# 默认路径 \EFI\BOOT\BOOTX64.EFI：原厂固件（RW_LEGACY）开机按 Ctrl+L 时就是从这里启动
if ! grub-install "${GRUB_EFI[@]}" --removable >/dev/null 2>&1; then
  if grep -qi '^Google_' /sys/class/dmi/id/bios_version 2>/dev/null; then
    die "默认引导路径安装失败。原厂固件只能从这个路径启动，继续的话新系统将无法开机"
  fi
  warn "默认引导路径安装失败（MrChromebox 固件一般仍可从 UEFI 启动项启动）"
fi
grub-mkconfig -o /boot/grub/grub.cfg

info "桌面与服务"
put_config lightdm/50-l4c.conf /etc/lightdm/lightdm.conf.d/50-l4c.conf
put_config autostart/l4c-polkit.desktop /etc/xdg/autostart/l4c-polkit.desktop
put_config fonts/64-l4c-cjk.conf /etc/fonts/conf.d/64-l4c-cjk.conf
if pkg_installed fcitx5; then
  set_block /etc/environment fcitx $'GTK_IM_MODULE=fcitx\nQT_IM_MODULE=fcitx\nXMODIFIERS=@im=fcitx\nSDL_IM_MODULE=fcitx'
fi
systemd_enable NetworkManager.service lightdm.service systemd-timesyncd.service bluetooth.service power-profiles-daemon.service

info "性能与存储优化"
L4C_YES=1 L4C_USER="$U" bash /opt/linux-for-chromebook/setup/optimize.sh   # L4C_USER：浏览器硬件解码等写进新用户目录
info "Chromebook 键盘"
bash /opt/linux-for-chromebook/setup/chromebook.sh keyboard || warn "键盘映射失败，进入系统后运行：sudo l4c keyboard"
if [[ ${C[AUDIO]} == y ]]; then
  bash /opt/linux-for-chromebook/setup/chromebook.sh audio || warn "声卡驱动安装失败，进入系统后运行：l4c audio"
fi

if [[ -n ${C[BACKUP]} ]]; then
  info "导入迁移包"
  bash /opt/linux-for-chromebook/migrate/import.sh "${C[BACKUP]}" --user "$U" --keep-hostname ||
    warn "迁移包导入时出现问题，可以进入系统后再运行：sudo l4c import <迁移包目录>"
fi

# 主题：迁移包里没有 Fluent 时才下载
if [[ ${C[WIN11]} == y ]] && ! ls -d /usr/share/themes/Fluent* "/home/$U/.themes"/Fluent* >/dev/null 2>&1; then
  bash /opt/linux-for-chromebook/setup/desktop-win11.sh --install-theme || warn "主题下载失败，之后可运行：sudo l4c theme"
fi

# 首次登录时在桌面会话里应用 Win11 布局
if [[ ${C[WIN11]} == y ]]; then
  install -d -o "$U" -g "$U" "/home/$U/.config" "/home/$U/.config/autostart" "/home/$U/.config/l4c"
  echo "--theme" >"/home/$U/.config/l4c/first-login.args"
  cat >"/home/$U/.config/autostart/l4c-first-login.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=linux-for-chromebook 首次设置
Exec=/opt/linux-for-chromebook/setup/desktop-win11.sh --first-login
OnlyShowIn=XFCE;
NoDisplay=true
EOF
  chown -R "$U:" "/home/$U/.config"
fi

rm -rf /var/cache/pacman/pkg/*   # 安装包缓存不再需要
ok "新系统配置完成"
