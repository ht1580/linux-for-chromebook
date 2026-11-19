# CLAUDE.md —— 给在 Windows 电脑（ht1580）上运行的 Claude Code 的说明

本仓库为**一台具体的 HP Chromebook** 定制系统和工具。最初的开发在云端 Linux 容器里完成；2026-11-18 起已通过局域网 SSH 在真机上扫描验证（见下表）。
接下来的会话会在用户的 Windows 11 电脑上运行，并通过局域网连接这台 Chromebook，扫描真实硬件后继续优化。

## 目标设备（2026-11-18 通过 SSH 实机扫描确认）

| 项目 | 实测 |
|---|---|
| 机型 | HP Chromebook 11，DMI `Google Yavilla`（product_family `Google_Nissa`，Alder Lake-N） |
| 固件 | **原厂 Google 固件** `Google_Yavilla.15217.864.0`（coreboot），开发者模式 + RW_LEGACY（EDK II UEFI）启动。**不是 MrChromebox**，eMMC 上没有也不需要 `*stock*.rom` |
| CPU / GPU | Intel N100 4 核（支持 x86-64-v3）；UHD 核显 8086:46d1，i915 + GuC/HuC 正常加载 |
| 内存 | 3.66 GiB；旧系统 zram 7.3G（zstd）+ `/swapfile` 512M；swappiness 100、page-cluster 3、THP always |
| 存储 | eMMC `MMC32G` 29.2 GiB，HS400 ES + CQE，寿命 0x02/0x02（已用 10~20%），pre_eol 正常；p1 vfat 300M（EFI），p2 ext4（93% 满） |
| 屏幕 / 背光 | 1366×768，`intel_backlight`；有键盘背光 `chromeos::kbd_backlight` |
| 键盘 | i8042 `AT Translated Set 2 keyboard`，keyd ID `0001:0001`；physmap `EA E7 91 92 93 94 95 A0 AE B0` = 返回 刷新 全屏 概览 截图 亮度- 亮度+ 静音 音量- 音量+ |
| 触控板 | Elan I2C 04f3:0140 |
| 声卡 | SOF IPC3 `sof-adl-n.ri` + 拓扑 `sof-adl-max98360a-rt5682.tplg`，codec RT5682S，功放 MAX98360A，声卡名 `sof-rt5682`。**旧系统没有 UCM → PipeWire 只有 auto_null（没声音）** |
| 网卡 | Intel CNVi 8086:54f0（iwlwifi，固件 89），省电模式开着时大量 missed beacons 告警 |
| 电池 | BAT0 支持 `charge_control_start/end_threshold`、`charge_behaviour`（cros_charge_control） |
| 系统 | Manjaro，内核 6.18.49，Xfce 4.20/X11 + picom，开机 10.2 秒（NetworkManager-wait-online 占 4.4 秒，被 zerotier-one 拖进关键路径） |
| 视频解码 | 旧系统只有 `libva-intel-driver`（i965，不支持 ADL-N），**没有 iHD → 没有硬件解码** |

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

已确认：固件类型（原厂 + RW_LEGACY，见上表）、键盘 physmap 与 keyd ID、eMMC 支持 discard（`DISC-GRAN 4M`）、声卡型号与缺 UCM 的原因、充电上限接口。

**2026-11-19 已在真机上全新安装并验证**（内核 6.18.55，btrfs 占用 51%，含 AUR 软件）：
- 安装器在 Live（kexec 启动）里跑通：basestrap / manjaro-chroot / fstabgen / btrfs mkswapfile / grub-install 两个路径都成功
- 声卡：Speaker、Headphones、HDMI1~4、Mic1/Mic2/Headset 都出现在 PipeWire 里（还没试听）
- 视频：vainfo 显示 iHD 26.3.5，H.264/HEVC 解码和编码；Xorg 用 modesetting
- 内存：zram 7.3G、THP madvise、MGLRU 1000、swappiness 180、page-cluster 0；Wi-Fi 省电关闭后开机 9 分钟内 0 条 missed beacons
- 已知坑：原厂固件的 RW_LEGACY 不保存 UEFI 变量（BootNext、新启动项重启即丢），Ctrl+L 后又来不及按 Esc，
  所以从 U 盘启动的可靠办法是在旧系统里 **kexec** 进 Live（见 `chromebook-scripts/l4c-kexec.sh` 的做法）；U 盘插着时固件有时会优先启动 U 盘
- 已知坑：新系统的 Wi-Fi 第一次会用随机 MAC 拿到新 IP；旧系统的 ufw 是 `ENABLED=no`，新系统同样未启用（已补 9993/udp 规则备用）

- [ ] `install/install.sh`：Manjaro Live 上 `basestrap` / `manjaro-chroot` / `fstabgen` 是否可用；btrfs `mkswapfile`；RW_LEGACY 下 `grub-install` 写 NVRAM 是否成功（失败会自动改 `--no-nvram`，`--removable` 默认路径是必须的）
- [ ] `install/packages/*.txt` 包名是否都在 Manjaro 源里（`pamac-gtk3`、`xfce4-docklike-plugin`、`adobe-source-han-sans-cn-fonts`、内核包名 `linux618`）
- [ ] 声卡：`l4c audio`（固定 chromebook-linux-audio 84b700e，自动选菜单 1）装完后 `pactl list short sinks` 不再只有 auto_null；扬声器、耳机、内置麦克风（`dmic_num=4`）都要试
- [ ] keyd：Alt+亮度键 = 键盘背光（`kbdillumdown/up`）在 xfce4-power-manager 下是否生效；Alt+F4、搜索键组合
- [ ] `wipe.sh disk`：eMMC 是否支持 `blkdiscard -s`；擦除后抽查结果
- [ ] Xfce 面板 XML（`setup/desktop-win11.sh`）：`p=8` 是否是底部、`length` 类型、docklike rc 键名、whiskermenu 属性名、clock `digital-layout` 枚举
- [ ] zram（`min(ram*2, 8192)`）+ earlyoom + MGLRU `min_ttl_ms=1000` 组合下，开 QQ + Chrome 时是否还会卡死
- [ ] Wi-Fi 关闭省电后 missed beacons 告警是否消失（`journalctl -k | grep missed`）
- [ ] Windows 工具 `windows/l4c-win.ps1`：**从未在真实 Windows 上运行过**；HttpListener + 防火墙、分块上传、中文路径、`netsh wlan export`、`tar.exe` zstd、BITS
- [ ] ChromeOS：`recovery2.json` 字段名和 SHA1 校验对象；ChromeOS Flex 下载地址
- [ ] 新系统里 `vainfo` 显示 iHD，Chrome 的 `chrome://gpu` 里 Video Decode 为硬件加速

## 本机已有的备份（在 Windows 的 `D:\Chromebook迁移`）

- `l4c-backup-<主机名>-20261118-2019/`：迁移包（home、system、软件清单、`extra/system-full.tar.zst` = 整个 /etc + ZeroTier 身份 + SSH 主机密钥 + /root + EFI）。安装器只自动导入 `system.tar.zst`，`extra/` 里的内容装好后手动放回
- `<主机名>-mmcblk0-20261118.img.zst`：整块 eMMC 的 zstd 镜像（文件系统冻结时制作），可原样恢复旧系统
- 注意：Windows 工具默认读 `%USERPROFILE%\Chromebook迁移`，不是 D 盘

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
