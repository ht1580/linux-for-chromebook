#!/usr/bin/env bash
# 临时开启 SSH，让 Windows 电脑（例如上面运行的 Claude Code）通过局域网连接这台 Chromebook。
#   sudo ./setup/remote.sh on                 开启（不会开机自启）
#   sudo ./setup/remote.sh on --key "ssh-ed25519 AAAA… 名字"   同时授权一个 Windows 公钥（免密码登录）
#   sudo ./setup/remote.sh off                关闭，并删除本工具授权的公钥
#   ./setup/remote.sh status
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

CONF=/etc/ssh/sshd_config.d/50-l4c.conf
MARK="l4c-remote"

user_ips() { ip -4 -br addr show scope global 2>/dev/null | awk '{print $1 ": " $3}' | sed 's|/[0-9]*||'; }

do_on() {
  require_root
  local key="" u h
  [[ ${1:-} == --key ]] && key=${2:?需要公钥内容}
  u=$(target_user); h=$(user_home "$u")
  pkg_installed openssh || pkg_install openssh
  mkdir -p /etc/ssh/sshd_config.d
  grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null ||
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  cat >"$CONF" <<EOF
# linux-for-chromebook：临时远程访问（sudo l4c remote off 关闭）
PermitRootLogin no
AllowUsers $u
PasswordAuthentication yes
MaxAuthTries 4
EOF
  if [[ -n $key ]]; then
    [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+)\ [A-Za-z0-9+/=]+ ]] || die "这不像一个 SSH 公钥"
    install -d -m 700 -o "$u" -g "$(id -gn "$u")" "$h/.ssh"
    grep -qF "${key%% *} $(awk '{print $2}' <<<"$key")" "$h/.ssh/authorized_keys" 2>/dev/null ||
      printf '%s %s\n' "$key" "$MARK" >>"$h/.ssh/authorized_keys"
    chown "$u:" "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
    ok "已授权公钥"
  fi
  [[ -n $(passwd -S "$u" 2>/dev/null | awk '$2=="P"') ]] || warn "用户 $u 没有设置密码，请先运行 passwd（启动 U 盘里的 Live 系统也需要）"
  systemctl restart sshd.service
  ok "SSH 已开启（只在本次开机期间有效，重启或 l4c remote off 后关闭）"
  echo
  echo "本机地址："; user_ips | sed 's/^/  /'
  local ip; ip=$(user_ips | head -1 | awk '{print $2}')
  cat <<EOF

在 Windows 上（PowerShell 或 Claude Code 的终端）连接：
  ssh $u@${ip:-本机IP}

想免密码登录：在 Windows 上运行  type \$env:USERPROFILE\\.ssh\\id_ed25519.pub
（没有的话先运行 ssh-keygen -t ed25519），把输出的一整行用下面的命令加进来：
  sudo l4c remote on --key "ssh-ed25519 AAAA…"
EOF
}

do_off() {
  require_root
  local u h; u=$(target_user); h=$(user_home "$u")
  systemctl disable --now sshd.service >/dev/null 2>&1 || true
  rm -f "$CONF"
  [[ -f $h/.ssh/authorized_keys ]] && sed -i "/ $MARK\$/d" "$h/.ssh/authorized_keys"
  ok "SSH 已关闭，本工具授权的公钥已删除"
}

do_status() {
  echo "SSH 服务：$(systemctl is-active sshd 2>/dev/null || true)"
  [[ -f $CONF ]] && echo "远程访问配置：已开启（$CONF）" || echo "远程访问配置：未开启"
  user_ips
}

case "${1:-}" in
  on) shift; do_on "$@" ;;
  off) do_off ;;
  status) do_status ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
