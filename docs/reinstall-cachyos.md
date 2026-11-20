# 从 Manjaro 换成 CachyOS + l4c（重装计划）

目标：系统底座换成 CachyOS（软件按 x86-64-v3 编译、BORE 调度器内核），l4c 的内存优化、Chromebook 适配、Win11 外观全部保留，
个人数据和软件原样迁回。整个过程走局域网，U 盘只用来启动 CachyOS 的 Live 系统。

> CachyOS 路径还**没有在真机上装过**。下面每一步都有回退办法；旧系统先做完整备份再动手。

## 回去前在 Windows 上准备（约 20 分钟，大部分是下载）

1. 到 CachyOS 官网下载 **Desktop 版 ISO**（约 3 GB）。
2. 用 Rufus 把 ISO 写进 U 盘，弹窗问写入方式时选 **DD 模式**（Ventoy 不行，`kexec-live.sh` 要认 U 盘上的 iso9660 分区）。
3. 确认 `D:\Chromebook迁移` 至少还有 20 GB 空间（新迁移包 + 可选的整盘镜像）。

## 连上以后的步骤

| # | 谁做 | 做什么 | 时间 |
|---|---|---|---|
| 1 | 你 | 开机进当前的 Manjaro，连 Wi-Fi，告诉我 IP；我用 SSH 连上 | 2 分钟 |
| 2 | 我 | 把仓库最新版放到 `/opt/linux-for-chromebook`，`l4c scan` 记录**换系统前的基准**：开机时间、空闲内存、硬盘占用、声卡、vainfo | 5 分钟 |
| 3 | 我 | **重新导出迁移包**到 `D:\Chromebook迁移`（11-19 之后的新文件、QQ 聊天记录、浏览器数据都在里面），逐个校验 SHA256 | 15~30 分钟 |
| 4 | 我（建议做） | 整块 eMMC 再做一份 zstd 镜像，装坏了可以原样恢复**现在这个** Manjaro | 20~40 分钟 |
| 5 | 你 | 插 U 盘，终端里输一条短命令（`sudo bash /opt/linux-for-chromebook/setup/kexec-live.sh`），输密码，10 秒后自动进入 CachyOS Live | 2 分钟 |
| 6 | 你 | Live 里连 Wi-Fi，开终端输 `passwd`（设临时密码）和 `sudo systemctl start sshd`，告诉我 IP | 2 分钟 |
| 7 | 我 | 运行安装器（迁移包地址预先填好）；你输入大写 YES 确认清空，再设一次登录密码 | 30~50 分钟 |
| 8 | 你 | 拔 U 盘重启，看到「操作系统验证已关闭」按 **Ctrl+L**（千万别按空格），登录 | 2 分钟 |
| 9 | 我 | `l4c look --system-look`、`l4c optimize --ram`；用 `paru` 装 AUR 软件（QQ、Chrome、Edge、哔哩哔哩、主题）；放回 ZeroTier 身份和 SSH 主机密钥 | 20~40 分钟 |
| 10 | 你 + 我 | 逐项核对（见下表），和第 2 步的基准对比，结果写进 README 和 CHANGELOG | 15 分钟 |

合计约 2~3 小时，你需要动手的只有第 1、5、6、7、8 步和最后试听。

## 安装器在 CachyOS 上会做的事

- 启动 U 盘只带通用的 `[cachyos]` 源；安装器检测到 CPU 支持 x86-64-v3 后，先加上 `[cachyos-v3]`、`[cachyos-core-v3]`、`[cachyos-extra-v3]`，
  所以新系统的 glibc、mesa、Xfce 等都是 v3 编译版本
- 内核 `linux-cachyos`（BORE 调度器）；GRUB 装到原厂固件唯一认的默认路径
- 不装 `cachyos-settings`（它的 zram、sysctl 设置和 l4c 重复，以 l4c 为准）；装 `paru` 用来装 AUR 软件
- Live 系统给 `[cachyos]` 源关了签名校验，装进新系统时恢复成必须校验
- 旧 Manjaro 独有的软件（pamac、mhwd、Manjaro 主题和壁纸、update-grub 等）导入时自动跳过；其余 200 多个软件在 Arch / CachyOS 源里都有

## 装完核对

| 项目 | 怎么看 | 合格标准 |
|---|---|---|
| 内核 | `uname -r` | 带 `cachyos` |
| v3 软件源 | `pacman -Si glibc xfwm4 \| grep -E '^(仓库\|Repository)'` | 仓库名带 `-v3` |
| 声卡 | `wpctl status` + 试听扬声器、耳机，试录麦克风 | 和 Manjaro 上一样有 Speaker / Headphones / Mic |
| 视频解码 | `vainfo` | iHD |
| 内存 | `free -m`、`zramctl`、`cat /sys/kernel/mm/lru_gen/min_ttl_ms` | zram 生效、1000 |
| Wi-Fi | `journalctl -k -b \| grep -c missed` | 0 |
| 外观 | 截图 | 任务栏、^ 弹出框、锁屏和现在一样 |
| 开机 / 空闲内存 / 硬盘 | `systemd-analyze`、`free -m`、`df -h /` | 和第 2 步基准对比，写进文档 |

## 出问题怎么办

- **安装中途失败**：硬盘上还没有能用的系统也没关系。把 `/tmp/l4c-install.log` 发给我，修好后在 Live 里重新运行安装器
- **装好但不满意**：同一个安装器用 Manjaro 的 U 盘再装一次（迁移包还在 D 盘），或者用第 4 步的镜像原样恢复
- **开机进不去**：Ctrl+L 没反应时，再用 U 盘 kexec 进 Live，我远程修引导
