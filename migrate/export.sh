#!/usr/bin/env bash
# 转换程序：把当前系统的软件、设置、个人文件、Wi-Fi、蓝牙配对等打包成一个迁移包。
# 迁移包可以用 import.sh 导入到新系统（全新安装时安装器也会自动导入）。
#
#   保存到 U 盘：           ./migrate/export.sh -o /run/media/$USER/U盘
#   通过局域网发给 Windows：./migrate/export.sh --send http://192.168.1.10:8848/口令
#                          （先在 Windows 上运行 windows\启动工具.bat → 启动传输服务）
#   选项：
#     -o, --output DIR     迁移包保存位置（必须是 U 盘/移动硬盘，重装会清空本机硬盘）
#     --send URL           边打包边通过局域网发送到 Windows 工具，本机不占用额外空间
#     --config-only        只备份设置（隐藏文件夹），不备份 文档/图片/下载 等个人文件
#     --exclude PATTERN    额外排除的文件（可重复），例如 --exclude 'Videos/*'
#     --no-wifi            不备份 Wi-Fi 密码
#     --list               只统计会备份多少数据，不真正打包
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

OUT="" SEND="" MODE=full WIFI=1 LIST_ONLY=0 EXTRA_EXCLUDES=()
while (($#)); do
  case $1 in
    -o|--output) OUT=${2:?}; shift ;;
    --send) SEND=${2:?}; shift ;;
    --config-only) MODE=config ;;
    --exclude) EXTRA_EXCLUDES+=("${2:?}"); shift ;;
    --no-wifi) WIFI=0 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

require_user
have zstd || die "缺少 zstd：sudo pacman -S zstd"
[[ -n $OUT || -n $SEND ]] || die "请用 -o 指定 U 盘目录，或用 --send 发送到 Windows 电脑"
[[ -z $OUT || -z $SEND ]] || die "-o 和 --send 只能选一个"

PKG="l4c-backup-$(hostname | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')-$(date +%Y%m%d-%H%M)"
SPLIT=0
if [[ -n $SEND ]]; then
  [[ $SEND =~ ^https?://[^/]+/[^/]+ ]] || die "地址格式应为 http://IP:端口/口令（Windows 工具里显示的那一行）"
  SEND=${SEND%/}
  have curl || die "缺少 curl"
  curl -fsS -m 10 -o /dev/null "$SEND/" || die "连不上 $SEND ，请确认 Windows 工具已启动、两台设备在同一个网络、口令正确"
  STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
  DEST="$STAGE/$PKG"
else
  mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
  DEST="$OUT/$PKG"
  case $(findmnt -no FSTYPE -T "$OUT" 2>/dev/null) in
    vfat|msdos) SPLIT=1; warn "U 盘是 FAT32 格式（单个文件最大 4G），大文件会自动分卷。建议把 U 盘格式化为 exFAT。" ;;
  esac
fi

# 缓存、回收站、可以重新下载的大文件，一律不备份
EXCLUDES=(
  ./.cache ./.local/share/Trash ./.local/share/flatpak ./.var/app/*/cache
  ./.thumbnails ./.local/share/baloo ./.local/share/recently-used.xbel
  ./.mozilla/firefox/*/storage/temporary ./.mozilla/firefox/*/crashes
  './.config/*/Cache' './.config/*/Code Cache' './.config/*/GPUCache'
  './.config/*/*/Service Worker/CacheStorage' './.config/*/*/Cache'
  ./.npm/_cacache ./.cargo/registry ./.gradle/caches ./.local/share/Steam
  ./.xsession-errors* ./.local/share/l4c
)
if [[ -n $OUT && ( $OUT == "$HOME" || $OUT == "$HOME"/* ) ]]; then
  EXCLUDES+=("./${OUT#"$HOME"/}")
fi
EXCLUDES+=("${EXTRA_EXCLUDES[@]/#/./}")

tar_excludes() { local e; for e in "${EXCLUDES[@]}"; do printf -- '--exclude=%s\n' "$e"; done; }

home_items() {
  if [[ $MODE == full ]]; then echo .
  else
    (cd "$HOME" && find . -mindepth 1 -maxdepth 1 -name '.*' -printf '%p\n')
    local d; d=$(xdg-user-dir TEMPLATES 2>/dev/null || true)
    [[ -n $d && $d != "$HOME" && -d $d ]] && echo "./${d#"$HOME"/}"
    [[ -d $HOME/Desktop ]] && echo ./Desktop
  fi
  return 0
}

estimate() {
  local -a ex items
  mapfile -t ex < <(tar_excludes)
  mapfile -t items < <(home_items)
  (cd "$HOME" && du -scb "${ex[@]}" "${items[@]}" 2>/dev/null | tail -1 | cut -f1)
}

# emit 名称 —— 把标准输入写成迁移包里的一个文件：
#   局域网模式直接上传（同时计算校验值），FAT32 自动分卷，其他情况写普通文件
emit() {
  local name=$1
  if [[ -n $SEND ]]; then
    local hf="$STAGE/$name.sha256" i
    tee >(sha256sum | cut -d' ' -f1 >"$hf") |
      curl -fsS -T - -H 'Expect:' -o /dev/null "$SEND/$PKG/$name"
    for i in {1..100}; do [[ -s $hf ]] && break; sleep 0.1; done
    printf '%s  %s\n' "$(cat "$hf")" "$name" >>"$STAGE/stream.sums"
    rm -f "$hf"
  elif ((SPLIT)); then
    split -b 3900M -d -a 3 - "$DEST/$name.part"
  else
    cat >"$DEST/$name"
  fi
}

# ------------------------------------------------------------ 开始 ------
info "linux-for-chromebook 迁移包导出（模式：$([[ $MODE == full ]] && echo 全部个人文件 || echo 仅设置)）"
SIZE=$(estimate)
if [[ -n $SEND ]]; then
  info "需要备份的个人数据约 $(human_size "$SIZE")（压缩后通常更小），将发送到 Windows 电脑"
else
  if [[ $(stat -c %d "$OUT") == "$(stat -c %d /)" ]]; then
    warn "保存位置 $OUT 和系统在同一块硬盘上！重装系统时它会被清空。"
    confirm "确定要保存在这里吗？（只有不重装、只是备份时才这样做）" n || die "已取消。请插入 U 盘后用 -o 指定 U 盘路径，或用 --send 发送到 Windows。"
  fi
  FREE=$(df --output=avail -B1 "$OUT" | tail -1)
  info "需要备份的个人数据约 $(human_size "$SIZE")（压缩后通常更小），保存位置剩余 $(human_size "$FREE")"
  ((FREE > SIZE / 2 + 104857600)) || confirm "剩余空间可能不够，仍然继续？" n || die "已取消"
fi
((LIST_ONLY)) && exit 0

if pgrep -x 'firefox|chrome|chromium|msedge' >/dev/null 2>&1; then
  warn "检测到浏览器正在运行，建议先关闭浏览器，否则书签/密码可能备份不完整。"
fi

mkdir -p "$DEST"/{packages,hardware}
touch "$DEST"/packages/{native,foreign,flatpak,services}.txt
ZSTD=(zstd -T0 -6 -q)

# 1. 系统信息（新系统据此还原用户名、时区、语言等）
{
  echo "L4C_VERSION=$L4C_VERSION"
  echo "CREATED=$(date -Iseconds)"
  echo "MODE=$MODE"
  echo "HOSTNAME=$(cat /etc/hostname 2>/dev/null || hostname)"
  echo "USERNAME=$(id -un)"
  echo "USER_UID=$(id -u)"
  echo "FULLNAME=$(getent passwd "$(id -un)" | cut -d: -f5 | cut -d, -f1)"
  echo "USER_SHELL=$(getent passwd "$(id -un)" | cut -d: -f7)"
  echo "USER_GROUPS=$(id -nG | tr ' ' ',')"
  echo "HOME_DIR=$HOME"
  echo "TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
  echo "LOCALE=$(sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | tr -d '"')"
  echo "KEYMAP=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2>/dev/null)"
  echo "KERNEL=$(uname -r)"
  echo "DESKTOP=${XDG_CURRENT_DESKTOP:-}"
  echo "BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null)"
} >"$DEST/manifest.env"
ok "系统信息"

# 2. 软件清单
if have pacman; then
  pacman -Qqen >"$DEST/packages/native.txt"
  pacman -Qqem >"$DEST/packages/foreign.txt" || true
fi
if have flatpak; then
  flatpak list --app --columns=origin,application 2>/dev/null >"$DEST/packages/flatpak.txt" || true
fi
systemctl list-unit-files --state=enabled --type=service,timer,socket --no-legend 2>/dev/null |
  awk '{print $1}' >"$DEST/packages/services.txt" || true
ok "软件清单：$(grep -c . "$DEST/packages/native.txt" || true) 个官方软件、$(grep -c . "$DEST/packages/foreign.txt" || true) 个 AUR 软件、$(grep -c . "$DEST/packages/flatpak.txt" || true) 个 Flatpak 应用"

# 3. 硬件报告（方便以后排查问题）
{ have inxi && inxi -Fxz -c0; } >"$DEST/hardware/inxi.txt" 2>/dev/null || true
lspci -k >"$DEST/hardware/lspci.txt" 2>/dev/null || true
lsusb >"$DEST/hardware/lsusb.txt" 2>/dev/null || true
lsblk -f >"$DEST/hardware/lsblk.txt" 2>/dev/null || true
find /sys/devices/platform -name function_row_physmap -exec cat {} + >"$DEST/hardware/top-row-physmap.txt" 2>/dev/null || true

# 4. 系统设置（需要管理员权限：Wi-Fi、蓝牙配对、主机名等）
info "备份系统设置（需要输入密码）"
SYS_PATHS=(
  etc/hostname etc/locale.conf etc/vconsole.conf etc/environment etc/X11/xorg.conf.d
  etc/keyd etc/fstab etc/default/grub etc/pacman.conf etc/pacman.d/mirrorlist
  etc/systemd/zram-generator.conf etc/lightdm var/lib/bluetooth etc/sudoers.d
)
((WIFI)) && SYS_PATHS+=(etc/NetworkManager/system-connections)
EXIST=()
for p in "${SYS_PATHS[@]}"; do as_root test -e "/$p" && EXIST+=("$p"); done
as_root tar --create -C / -f - "${EXIST[@]}" 2>/dev/null | "${ZSTD[@]}" >"$DEST/system.tar.zst"
chmod 600 "$DEST/system.tar.zst"
ok "系统设置$( ((WIFI)) && echo '（含 Wi-Fi 密码，请妥善保管迁移包）')"

# 5. 不属于任何软件包的系统级主题/图标/字体/程序（例如手动安装的 Fluent 主题）
if have pacman; then
  info "查找手动安装的主题、图标、字体……"
  dirs=()
  for d in /usr/share/themes /usr/share/icons /usr/share/fonts /usr/local; do [[ -d $d ]] && dirs+=("$d"); done
  comm -23 \
    <(find "${dirs[@]}" -type f ! -name icon-theme.cache ! -name 'fonts.*' ! -name .uuid 2>/dev/null | sort) \
    <(pacman -Qlq 2>/dev/null | sort -u) | sed 's|^/||' >"$DEST/unowned.list"
  if [[ -s $DEST/unowned.list ]]; then
    tar --create -C / -T "$DEST/unowned.list" -f - 2>/dev/null | "${ZSTD[@]}" | emit unowned.tar.zst || true
    ok "手动安装的文件：$(wc -l <"$DEST/unowned.list") 个"
  fi
fi

# 5b. 原厂固件备份（以后装回原厂 ChromeOS 需要），单独放一份，方便在 Windows 上找到
mapfile -t ROMS < <(find "$HOME" -maxdepth 3 -type f -iname '*stock*.rom' 2>/dev/null || true)
if ((${#ROMS[@]})); then
  mkdir -p "$DEST/firmware"
  cp -n "${ROMS[@]}" "$DEST/firmware/"
  ok "原厂固件备份：${#ROMS[@]} 个（firmware/ 目录，请一直保留）"
elif grep -qi mrchromebox /sys/class/dmi/id/bios_version 2>/dev/null; then
  warn "没有在主目录里找到原厂固件备份（*stock*.rom）。如果它在 U 盘上，请妥善保存，以后装回原厂 ChromeOS 需要它。"
fi

# 6. 个人文件和设置（最大的一项，放在最后）
info "打包$([[ -n $SEND ]] && echo '并发送')个人文件和设置（可能需要几分钟到几十分钟）……"
mapfile -t EXARGS < <(tar_excludes)
mapfile -t ITEMS < <(home_items)
rc=0
(cd "$HOME" && tar --create --one-file-system --warning=no-file-changed --warning=no-file-ignored \
  "${EXARGS[@]}" -f - "${ITEMS[@]}") | "${ZSTD[@]}" | emit home.tar.zst || rc=$?
((rc <= 1)) || die "个人文件打包失败（错误码 $rc）$([[ -n $SEND ]] && echo '。请检查网络后重试，或改用 U 盘：-o <U盘目录>')"
ok "个人文件"

# 7. 校验文件；局域网模式下把小文件也发过去
if [[ -n $SEND ]]; then
  (cd "$DEST" && find . -type f -printf '%P\n' | sort | xargs -d '\n' sha256sum; cat "$STAGE/stream.sums") >"$STAGE/SHA256SUMS"
  while IFS= read -r f; do
    curl -fsS -T "$DEST/$f" -o /dev/null "$SEND/$PKG/$f" || die "发送 $f 失败"
  done < <(cd "$DEST" && find . -type f -printf '%P\n')
  curl -fsS -T "$STAGE/SHA256SUMS" -o /dev/null "$SEND/$PKG/SHA256SUMS" || die "发送校验文件失败"
  ok "迁移包已发送到 Windows：$PKG"
  cat <<EOF

下一步（在 Windows 工具里）：
  • 「校验迁移包」确认数据完整
  • 「转换」可以把 Windows 的 Wi-Fi、文件夹加进迁移包
  • 安装新系统时，在安装器里输入：$SEND/$PKG
EOF
else
  (cd "$DEST" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum >SHA256SUMS)
  ok "迁移包已完成：$DEST（共 $(du -sh "$DEST" | cut -f1)）"
  cat <<EOF

下一步：
  • 拷到 Windows：运行 windows\\启动工具.bat →「从 U 盘导入迁移包」
  • 全新安装：用安装 U 盘启动后运行 install/install.sh，安装时选择这个迁移包即可自动导入
  • 导入到已经装好的系统：sudo l4c import "$DEST"
EOF
fi
