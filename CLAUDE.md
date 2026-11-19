# CLAUDE.md —— 给在 Windows 电脑（ht1580）上运行的 Claude Code 的说明

本仓库为**一台具体的 HP Chromebook** 定制系统和工具。之前的开发在云端 Linux 容器里完成，**没有接触过真机**。
接下来的会话会在用户的 Windows 11 电脑上运行，并通过局域网连接这台 Chromebook，扫描真实硬件后继续优化。

## 目标设备（来自用户提供的 fastfetch 输出，未经实机扫描验证）

| 项目 | 已知信息 |
|---|---|
| 机型 | HP Chromebook 11（Host 显示 `Yavilla (rev3)`，Google Nissa 平台） |
| CPU / GPU | Intel N100，4 核；Intel UHD 核显 |
| 内存 | 3.66 GiB（焊死）；当时已用 90%，swap 7.83 GiB 已用 5.46 GiB |
| 存储 | 根分区 ext4 28.28 GiB，已用 89%（推测 32G eMMC；swap 可能是根分区上的 swap 文件） |
| 屏幕 | 1366×768，12 寸 |
| 网卡 | `wlp0s20f3`（PCI 00:14.3，推测 Intel CNVi） |
| 系统 | Manjaro stable，内核 6.18.49-1-MANJARO，Xfce 4.20 / X11，zsh，Fluent 主题，Bibata 光标，Noto Sans CJK SC，locale zh_CN.utf8 |
| 固件 | 能装 Manjaro，推测是 MrChromebox UEFI 完整固件，**未确认** |
| 软件 | pacman 1238 个，flatpak 6 个 |

## 用户的计划与要求

1. Chromebook 数据 → 局域网或 U 盘 → Windows 电脑（`windows/启动工具.bat`）
2. Windows 上校验、转换（加入 Windows 的 Wi-Fi 和文件夹），制作 Ventoy 安装 U 盘
3. Chromebook 全新安装（`install/install.sh`），数据从 Windows 局域网回传、边下载边导入
4. 清除设备残存信息（`setup/wipe.sh`，Windows 工具菜单 9）
5. 必要时装回 ChromeOS（`setup/chromeos.sh`，Windows 工具菜单 8）
6. 对 Windows 11 用户友好（快捷键、分屏、任务栏），省内存、省存储

用户偏好：中文交流；节省用量、高效；不要过度询问，但破坏性操作必须确认。

## 连接 Chromebook

在 Chromebook 上（旧系统或启动 U 盘的 Live 系统）：

```bash
sudo bash linux-for-chromebook/bin/l4c remote on      # 或已安装时：l4c remote on
```

然后在 Windows 上 `ssh 用户名@IP`。可以用 `l4c remote on --key "<Windows 的 id_ed25519.pub 内容>"` 配置免密码登录，
用完 `sudo l4c remote off`。Live 系统需要先 `passwd` 设置密码。

## 第一件事：扫描真机

```bash
sudo l4c scan            # 生成 ~/l4c-scan-*.md
```

用报告核对并修正下面“待实机验证”的每一项。不要把扫描报告或迁移包提交进仓库（含 IP、MAC、主机名，迁移包含密码），`.gitignore` 已排除。

## 待实机验证（按风险排序）

- [ ] 固件类型（`l4c chromeos check`）：是不是 MrChromebox UEFI；有没有原厂固件备份 `*stock*.rom`——**全新安装会擦除整盘，备份若只在 eMMC 上就会永久丢失**
- [ ] `install/install.sh`：Manjaro Live 上 `basestrap` / `manjaro-chroot` / `fstabgen` 是否可用；`pacman-mirrors` 用法；btrfs `mkswapfile`；GRUB 在 MrChromebox 上能否启动（同时装了 `--removable` 兜底）
- [ ] `install/packages/*.txt` 包名是否都在 Manjaro 源里（`linux-firmware-intel` 拆分、`pamac-gtk3`、`xfce4-docklike-plugin`、`adobe-source-han-sans-cn-fonts`、内核包名 `linux618`），安装器会跳过不存在的包并告警
- [ ] `wipe.sh disk`：eMMC 是否支持 `blkdiscard -s`；擦除后抽查结果
- [ ] 键盘：`/sys/devices/platform/**/function_row_physmap` 是否存在、内容格式；内置键盘的 keyd ID（默认 `0001:0001`）；Alt+F4、搜索键组合是否如预期
- [ ] 声卡：WeirdTreeThing/chromebook-linux-audio 对 Nissa/Yavilla 是否有效；在 root / chroot 下能否运行
- [ ] Xfce 面板 XML（`setup/desktop-win11.sh`）：`p=8` 是否是底部、`length` 类型（uint/double）、docklike rc 键名、whiskermenu xfconf 属性名、clock `digital-layout` 枚举
- [ ] zram 大小（`min(ram*2, 8192)`）与 earlyoom 阈值是否合适，结合扫描报告里的内存占用调整
- [ ] Windows 工具 `windows/l4c-win.ps1`：**从未在真实 Windows 上运行过**；需测试 HttpListener + 防火墙规则、大文件上传（分块）、中文路径、`netsh wlan export` 转换、`tar.exe` 是否支持 zstd、BITS 下载
- [ ] ChromeOS：`recovery2.json` 的字段名（`hwidmatch`、`url`、`sha1`、`zipfilesize`、`name`、`version`）和 SHA1 校验对象（压缩包还是镜像）；ChromeOS Flex 下载地址
- [ ] `vainfo` 是否显示 iHD 驱动和 H264/HEVC/VP9/AV1 解码

## 代码约定

- 全部是 bash：`set -Eeuo pipefail`，`source lib/common.sh`；用户可见文字用中文
- 用 `confirm` / `ask` 提问（`L4C_YES=1` 时采用默认值）；破坏性操作（擦盘、刷固件、删除）默认“否”或要求输入大写确认词
- 修改系统文件用 `backup_file` 先备份；在文件里追加内容用 `set_block`（可重复执行）
- 脚本之间用 `bash 路径` 调用，不依赖可执行权限（从 exFAT U 盘或 Windows 复制时权限会丢失）
- `L4C_CHROOT=1` 时不启动服务、不动正在运行的系统
- Linux 脚本保持 LF 换行；`.ps1` 是 UTF-8 **带 BOM** + CRLF（Windows PowerShell 5.1 需要 BOM 才能正确读取中文）
- 提交前运行：`shellcheck -f gcc bin/l4c lib/*.sh setup/*.sh migrate/*.sh install/*.sh`（配置见 `.shellcheckrc`）

## 安全规则

- **不要在没有用户明确同意的情况下**：刷写固件（`l4c chromeos firmware`）、擦除硬盘（`l4c wipe disk`）、运行全新安装、关闭写保护
- 动手前先确认原厂固件备份和迁移包都已安全保存在 Windows 电脑上
- 迁移包含 Wi-Fi 明文密码、浏览器数据，不要上传到任何外部服务

## 局域网传输协议（Windows 工具 ↔ Linux 脚本）

`http://IP:8848/<口令>/` —— GET 列出迁移包；`/<口令>/<包名>/` GET 列出文件（相对路径，`/` 分隔）；
`/<口令>/<包名>/<路径>` PUT 上传（支持分块）、GET 下载；`/<口令>/l4c.tar.gz` 下载本工具。
包名必须匹配 `l4c-(backup|scan)-[A-Za-z0-9._-]+`。
