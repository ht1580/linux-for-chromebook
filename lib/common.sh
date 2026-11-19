# shellcheck shell=bash
# linux-for-chromebook 公共函数库。被各脚本 source，不要直接执行。

L4C_VERSION="0.1.0"
L4C_ROOT="${L4C_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
L4C_YES="${L4C_YES:-0}"        # 1 = 所有提问都采用默认答案
L4C_CHROOT="${L4C_CHROOT:-0}"  # 1 = 运行在安装器的 chroot 里（不启动服务、不动正在运行的系统）
export L4C_ROOT L4C_YES L4C_CHROOT

if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_0=$'\e[0m'
else
  C_R='' C_G='' C_Y='' C_B='' C_0=''
fi

info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s  ✗ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }
# 任何未处理的错误都打印出错位置，方便反馈问题
trap 'printf "%s  ✗ 出错：%s 第 %s 行：%s%s\n" "$C_R" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" "$C_0" >&2' ERR

# confirm "问题" [y|n]  —— 返回 0 表示“是”
confirm() {
  local q=$1 def=${2:-y} ans hint
  [[ $def == y ]] && hint="[Y/n]" || hint="[y/N]"
  if [[ $L4C_YES == 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    [[ $def == y ]]; return
  fi
  read -r -p "$q $hint " ans </dev/tty || ans=""
  [[ ${ans:-$def} =~ ^[Yy] ]]
}

# ask "问题" "默认值" —— 把答案打印到 stdout
ask() {
  local q=$1 def=${2:-} ans
  if [[ $L4C_YES == 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    printf '%s' "$def"; return
  fi
  read -r -p "$q [${def}] " ans </dev/tty || ans=""
  printf '%s' "${ans:-$def}"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_root() { [[ $EUID -eq 0 ]] || die "需要管理员权限，请用 sudo 运行。"; }
require_user() { [[ $EUID -ne 0 ]] || die "请用普通用户运行（不要加 sudo），需要时脚本会自己询问密码。"; }

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# 目标普通用户（sudo 运行时取 SUDO_USER）
target_user() {
  if [[ -n ${L4C_USER:-} ]]; then echo "$L4C_USER"
  elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then echo "$SUDO_USER"
  else id -un
  fi
}
user_home() { getent passwd "$1" | cut -d: -f6; }

backup_file() {
  [[ -e $1 ]] || return 0
  cp -a "$1" "$1.l4c-bak.$(date +%Y%m%d-%H%M%S)"
}

# 把仓库 config/ 里的文件装到系统位置
put_config() { # 相对 config/ 的路径  目标路径  [权限]
  install -Dm "${3:-644}" "$L4C_ROOT/config/$1" "$2"
}

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

# 只返回软件源里确实存在的包（应对改名/拆分）
pkg_filter_available() {
  local all
  all=$(pacman -Slq 2>/dev/null | sort -u)
  local p
  for p in "$@"; do
    if grep -qxF -- "$p" <<<"$all"; then echo "$p"; else warn "软件源里没有 $p，跳过"; fi
  done
}

pkg_install() {
  local missing=() p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  info "安装软件包: ${missing[*]}"
  as_root pacman -S --needed --noconfirm "${missing[@]}"
}

# 读取包列表文件（忽略注释和空行）
read_list() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# set_block 文件 名称 内容 [插入锚点正则]
# 在文件中维护一段 “# >>> l4c:名称 … # <<< l4c:名称” 的内容，可重复执行。
set_block() {
  local f=$1 name=$2 content=$3 anchor=${4:-} tmp
  tmp=$(mktemp)
  [[ -f $f ]] || : >"$f"
  awk -v b="# >>> l4c:$name" -v e="# <<< l4c:$name" -v a="$anchor" -v c="$content" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip {next}
    { print }
    a != "" && !done && $0 ~ a { print b; print c; print e; done=1 }
    END { if (a == "" || !done) { print b; print c; print e } }
  ' "$f" >"$tmp"
  cat "$tmp" >"$f"
  rm -f "$tmp"
}

systemd_enable() { # 服务…  （chroot 中只 enable，不 start）
  local s
  for s in "$@"; do
    if [[ $L4C_CHROOT == 1 ]]; then systemctl enable "$s" >/dev/null 2>&1 || warn "无法启用 $s"
    else systemctl enable --now "$s" >/dev/null 2>&1 || warn "无法启用 $s"
    fi
  done
}

human_size() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
