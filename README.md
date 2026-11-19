# linux-for-chromebook

把 **HP Chromebook 11（主板代号 Yavilla，Intel N100，4G 内存，32G eMMC）** 变成一台
**省内存、省空间、用起来像 Windows 11** 的电脑，并且可以**完整迁移**旧系统里的软件、设置、个人文件和 Wi-Fi。

基于 Manjaro（Arch）+ 精简 Xfce。所有功能都是 shell 脚本，可以随时查看和修改。

**2026-11 已在这台 Chromebook 上实机全新安装并逐项核对**，见 [更新日志](CHANGELOG.md)；接下来要做的见 [路线图](docs/roadmap.md)。

> 本项目改动的是系统设置，并且会格式化硬盘（仅全新安装时）。使用前请先导出迁移包，并阅读下面的说明。

---

## 三种用法

| | A. 在现有系统上优化 | B. 借助 Windows 11 电脑全新安装（推荐） | C. 只用 U 盘全新安装 |
|---|---|---|---|
| 风险 | 低，不重装，每一步都会询问并备份原文件 | 清空 Chromebook 硬盘，数据先存到 Windows 电脑 | 清空硬盘，数据先存到 U 盘 |
| 额外能做的 | — | 把 Windows 的 Wi-Fi、文件一起转换带过去；在 Windows 上校验/查看备份 | — |
| 腾出硬盘空间 | 约 6~8 GB（缩小 swap、删文档、清缓存） | 更多：btrfs 透明压缩，系统文件通常只占原来的 50~70% | 同 B |

### A. 在现有 Manjaro 上优化（不重装）

```bash
git clone https://github.com/ht1580/linux-for-chromebook
```

```bash
cd linux-for-chromebook && bash bin/l4c self-install
```

```bash
l4c optimize      # 内存、存储、eMMC、视频解码优化（逐项询问）
```

```bash
l4c keyboard      # Chromebook 键盘改成 Windows 习惯
```

```bash
l4c desktop       # Windows 11 使用习惯：任务栏和快捷键（会先备份你现在的桌面设置）
```

```bash
l4c look          # Windows 11 外观：登录/锁屏、壁纸、任务栏、^ 弹出框、开始菜单、光标
```

不满意可以恢复桌面：`l4c undo-desktop ~/.local/share/l4c/xfce-backup-时间`。

### B. 借助 Windows 11 电脑全新安装

**详细步骤见 [docs/windows.md](docs/windows.md)**，简要流程：

1. Windows 上下载本项目（Code → Download ZIP），双击 `windows\启动工具.bat`
2. 工具里「启动传输服务」，在 Chromebook 上运行工具显示的命令，数据通过局域网传到 Windows（也可以用 U 盘）
3. 「校验迁移包」→「转换」（可选：加入 Windows 的 Wi-Fi 和文件夹）
4. 「制作 Chromebook 安装 U 盘」（Ventoy + Manjaro 镜像 + 本工具）
5. Chromebook 用 U 盘启动，运行 `sudo bash /run/media/manjaro/Ventoy/linux-for-chromebook/install/install.sh`
6. 安装器询问迁移包来源时选「从 Windows 电脑获取」，边下载边导入
7. 重启，首次登录自动应用 Windows 11 风格

### C. 只用 U 盘全新安装

1. 导出迁移包到 U 盘（建议 exFAT 格式）：`l4c export -o /run/media/$USER/你的U盘`
2. 用 [Manjaro Xfce 启动 U 盘](https://manjaro.org/products/download/x86) 启动 Chromebook，连上 Wi-Fi
   （开发者模式界面按 Ctrl+L，看到 UEFI 画面时按 Esc 选 U 盘；**原厂固件来不及按 Esc 时**，在旧系统里运行
   `sudo bash setup/kexec-live.sh` 直接热启动到 U 盘）
3. 打开终端：

   ```bash
   git clone https://github.com/ht1580/linux-for-chromebook && sudo bash linux-for-chromebook/install/install.sh
   ```

4. 按提示选择迁移包、硬盘、用户名，安装器自动完成分区、安装、键盘声卡适配、导入数据

### 清除残存信息、装回 ChromeOS

- `l4c wipe traces` 清除使用痕迹；全新安装前自动安全擦除整块 eMMC；`l4c wipe efi` 删除旧启动项；Windows 工具可删除迁移包
- `l4c chromeos check` 给出装回 ChromeOS 的路线：**ChromeOS Flex**（不用动固件）或**原厂 ChromeOS**（先恢复原厂固件）；Windows 工具可下载对应镜像
- 详见 **[docs/chromeos.md](docs/chromeos.md)**

### 扫描设备、远程连接

- `l4c scan` 生成详细报告：机型固件、内存占用、eMMC 健康度（寿命估计）、哪些目录/软件包最占空间、显卡解码、声卡、键盘、电池健康、启动耗时、错误日志
- `l4c remote on` 临时开启 SSH，方便在 Windows 电脑上（例如用 Claude Code）连接这台 Chromebook 排查和继续优化；`l4c remote off` 关闭

---

## 做了哪些优化

### 内存（4G 不够用的主要原因）

| 优化 | 效果 |
|---|---|
| **zram** 压缩内存（zstd，最多 2×内存） | 同样的 4G 能多装约一倍程序，比往 eMMC 上写 swap 快几十倍 |
| 原来的 8G swap 文件缩小为 1G，只在 zram 用完时兜底 | 腾出约 7G 硬盘 |
| **earlyoom** | 内存耗尽时先结束最占内存的浏览器标签页，而不是整机卡死几分钟 |
| 内核参数（swappiness、page-cluster 等，针对 zram 调整） | 内存紧张时界面更跟手 |
| 透明大页改为 madvise、MGLRU 保护最近 1 秒用过的内存（ChromeOS 同款） | 后台程序少占内存，内存紧张时不会反复卡顿 |
| Firefox：内存缓存、低内存时自动休眠标签页、限制进程数 | 浏览器少占内存、少写硬盘 |
| Chrome / Chromium「节省内存」、Edge「睡眠标签页」（系统级策略） | 后台标签页自动休眠，开多个标签页时省得最多 |
| Intel 硬件视频解码（VA-API，iHD 驱动；去掉 N100 用不了的 i965 旧驱动；Chrome/Edge 自动加开关） | 看视频 CPU 占用明显下降，更省电 |
| **开机常驻程序瘦身**（`l4c optimize --ram`）：任务栏插件合进任务栏进程、关掉无障碍总线和用不到的设备识别服务、Proton VPN 后台改为按需启动，关掉重复的剪贴板管理器、用不到的托盘小程序 | 实测可用内存多 55 MB；Proton VPN 后台用过一次就常驻（峰值约 250 MB），现在用完不再占着 |

### 存储（32G eMMC）

| 优化 | 效果 |
|---|---|
| btrfs + zstd 透明压缩（仅全新安装） | 系统文件通常只占原来的 50~70% |
| 不安装说明文档、多余语言包（只保留中英文） | 几百 MB，并且以后安装软件也不再带这些文件 |
| 只装 Intel 硬件固件，而不是所有厂商的固件 | 约 300~500 MB |
| 中文字体只装简体中文的思源黑体（替代完整的 Noto CJK） | 约 200 MB |
| 每次装软件后自动只保留最新一个安装包缓存 | 缓存不会越积越多 |
| 日志最多 50M，不保存崩溃转储 | 防止日志悄悄占满硬盘 |
| `l4c clean` 一键清理 | 安装包缓存、孤立依赖、日志、缩略图、回收站、无用 Flatpak 运行库 |

### eMMC 读写和其他

- `noatime`：读文件时不再顺带写一次硬盘
- eMMC 使用 bfq 调度器：后台装软件时前台不卡
- 定期 TRIM，延长 eMMC 寿命并保持速度
- 关闭硬件看门狗、精简开机日志：开机更快、更省电
- 开机不再等待 Wi-Fi 连上（实测省 4.4 秒）；文档不装了，man-db 定时索引也关掉
- 可选关闭打印、局域网发现、4G 上网卡、空的计划任务等用不上的服务
- Wi-Fi 关闭省电模式：实测 Intel 无线网卡省电时频繁丢信号（missed beacons）
- 可选充电上限 80%（Chromebook 的 EC 支持），常插电使用时延长电池寿命
- 拔掉电源自动切到省电模式，插上恢复平衡模式
- 不用 Windows 程序时：`sudo l4c optimize --remove-wine` 删除 wine 和全部 32 位库（几百 MB）

### Chromebook 硬件适配

- **键盘**（[keyd](https://github.com/rvaiya/keyd)）：自动读取本机顶排按键布局并生成映射，只作用于内置键盘：
  - 顶排按键：返回、刷新（F5）、全屏（F11）、窗口切换、亮度、音量
  - **搜索键 = Windows 键**；搜索键 + 顶排 = F1…F10
  - 补上 Chromebook 缺少的键：Alt+退格 = Delete，Alt+↑/↓ = PageUp/PageDown，Ctrl+Alt+↑/↓ = Home/End，Alt+搜索键 = CapsLock
  - 有键盘背光的机型：Alt+亮度键 = 背光调暗/调亮（和 ChromeOS 一样）
- **声卡**：调用社区项目 [chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)（固定到审阅过的版本，全自动运行）。实测本机声卡 `sof-rt5682`（RT5682S + MAX98360A）能被内核识别，但缺 UCM 配置，PipeWire 只有“虚拟输出”，即完全没声音
- **触控板**：轻触点击，两指点击 = 右键
- `l4c info` 查看机型、固件（原厂 RW_LEGACY / MrChromebox）、顶排键布局、充电上限
- **原厂固件也能装**：本机实测是原厂 Google 固件 + 开发者模式 + RW_LEGACY。安装器会把引导文件放到固件唯一认的默认路径；开机按 Ctrl+L，**不要按空格**（会恢复 ChromeOS 并清空硬盘）

### 像 Windows 11 一样用

- **任务栏**（和 Win11 一样靠左）：开始、搜索、固定的应用（[xfce4-docklike-plugin](https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin)，蓝色运行指示条）；
  右侧依次是 **^**、中/英（单击切换输入法）、Wi-Fi、音量、电池百分比、时间日期、通知、显示桌面
- **^ 弹出框**：其他托盘图标排成网格，圆角、阴影，出现在 ^ 正上方，鼠标移开自动收起（不常驻，只在打开时运行）
- **Win11 外观**：登录 / 锁屏界面、壁纸（可以直接用你自己 Windows 里的原版壁纸）、浅色半透明任务栏、黄色文件夹、白色光标、
  空闲黑屏的屏保、右下角通知、搜索在顶部的开始菜单 —— 全部是配置和样式，不增加常驻程序
- **贴靠分屏**：把窗口拖到屏幕边缘，或按 Win+←/→ 左右分屏，Win+Alt+方向键分成四分之一屏
- **Windows 快捷键**：Win+E、Win+D、Win+L、Win+V、Win+Shift+S、Ctrl+Shift+Esc、Alt+F4、Win+Ctrl+←/→ 虚拟桌面…… 见 **[完整快捷键表](docs/shortcuts.md)**
- 关闭/最大化/最小化按钮在右上角，双击标题栏最大化
- Fluent 主题和图标（开源的 Win11 风格主题 [vinceliuice/Fluent](https://github.com/vinceliuice/Fluent-gtk-theme)）
- **中文输入法**（fcitx5 拼音）：Shift 切换中英文，Win+空格开关输入法，和微软拼音一样
- 文件管理器右键 → 新建文档 → 新建文本文档
- 「添加/删除软件」应用商店（pamac）

---

## 迁移包里有什么

见 **[docs/migration.md](docs/migration.md)**。简单来说：

- 软件清单（官方软件自动装回来；AUR 和 Flatpak 软件给出清单或询问后安装）
- 整个个人文件夹（文档、图片、桌面、浏览器书签和密码、各软件设置、主题、字体、zsh 配置……），自动跳过缓存和回收站
- Wi-Fi 密码、蓝牙配对、主机名、时区、语言
- 手动安装到系统里的主题/图标/字体
- 硬件报告（排查问题用）
- SHA256 校验，导入前先检查文件有没有损坏

---

## 为什么还是基于 Linux

这台机器只能在 Linux（以及 ChromeOS）上获得完整的硬件驱动支持（Wi-Fi、显卡、扬声器、键盘）：

- **Windows 11**：要求至少 64G 存储（这台只有 32G），4G 内存会很吃力，Chromebook 的声卡还要另外购买第三方驱动
- **自己从零写一个系统**：没有可用的 Wi-Fi、显卡、声卡驱动，达不到日常使用的要求
- **ChromeOS**：可以恢复原厂系统，但无法迁移你现在的 Linux 软件和设置

所以本项目选择在 Manjaro 上做深度定制：硬件全部可用，同时尽量做到省资源、像 Windows。

---

## 命令速查

```
l4c export -o <U盘目录>   导出迁移包到 U 盘
l4c export --send <地址>  通过局域网发送到 Windows 工具
l4c import <目录或地址>   导入迁移包（U 盘目录或 Windows 工具的地址）
l4c optimize [--all]      系统优化
l4c optimize --ram        只精简开机常驻程序（省内存）
l4c clean                 清理存储空间
l4c keyboard              键盘映射
l4c audio                 声卡驱动
l4c desktop [--theme]     Windows 11 使用习惯（任务栏、快捷键）
l4c look                  Windows 11 外观（登录/锁屏、壁纸、任务栏、^ 弹出框）
l4c theme                 安装 Fluent 主题
l4c undo-desktop <目录>   恢复修改前的桌面
l4c install               全新安装（在启动 U 盘里）
l4c scan                  生成详细设备报告
l4c remote on|off         临时开启 / 关闭 SSH 远程连接
l4c wipe traces|efi|disk  清除残存信息
l4c chromeos check        装回 ChromeOS 的路线检查（还有 images / backup-firmware / firmware）
l4c status                查看内存/存储状态
l4c info                  查看机型和固件
```

## 目录结构

```
bin/l4c                    命令入口
lib/common.sh              公共函数
setup/optimize.sh          内存、存储、eMMC、视频解码优化
setup/chromebook.sh        键盘映射、声卡、硬件信息
setup/desktop-win11.sh     Windows 11 风格桌面、外观和快捷键
setup/win11-panel/         任务栏右侧的小部件：中/英 + Wi-Fi 指示、^ 弹出框
setup/kexec-live.sh        原厂固件下从旧系统热启动到 U 盘 Live 系统
setup/scan.sh              设备扫描报告
setup/remote.sh            临时 SSH 远程连接
setup/wipe.sh              清除残存信息、整盘安全擦除
setup/chromeos.sh          装回 ChromeOS（Flex / 原厂）
migrate/export.sh          转换程序：导出迁移包（U 盘 / 局域网发送）
migrate/import.sh          导入程序：还原迁移包（U 盘 / 局域网边下载边导入）
windows/启动工具.bat        Windows 工具：接收、校验、转换、回传迁移包，制作安装 U 盘
windows/l4c-win.ps1        Windows 工具本体（PowerShell）
install/install.sh         全新安装器（在 Manjaro 启动 U 盘里运行）
install/chroot-setup.sh    安装器在新系统里执行的配置步骤
install/packages/*.txt     全新安装的软件包列表（可自行增删）
config/                    各种配置文件
docs/                      快捷键表、迁移说明、Windows 流程、ChromeOS、路线图
CHANGELOG.md               更新日志
CLAUDE.md                  给后续 Claude Code 会话的说明（设备信息、待实机验证清单）
```

## 测试情况

- 所有脚本通过 `bash -n` 语法检查和 ShellCheck 静态检查（GitHub Actions 自动运行）
- 迁移包的导出 → 导入流程已在 Linux 环境中实际测试：U 盘方式、局域网边传边导入方式（用模拟的 Windows 传输服务）、FAT32 分卷、中文文件名、从 Windows 加入的文件和 Wi-Fi、用户名不同时的路径修正、完整性校验
- Windows 工具（PowerShell）做了结构检查和人工审阅，**尚未在真实 Windows 11 上运行过**
- 键盘映射生成、配置文件修改（pacman.conf、fstab、GRUB 参数）已测试，并且重复运行结果不变
- **2026-11-19 在 Yavilla 实机上完整走过一遍**：整盘镜像备份 → kexec 进 Live → 擦盘 → 全新安装（数据通过 SSH 隧道从 Windows 边下载边导入）→
  声卡、视频解码、内存参数、Win11 外观逐项截图核对；安装中发现的问题都已修复（见更新日志）
- 还没实际试听扬声器 / 耳机、没试键盘背光键，Windows 工具也还没在真实 Windows 上跑过（见[路线图](docs/roadmap.md)）
- 遇到问题请把终端里的报错（会显示出错的脚本和行号）和 `/tmp/l4c-install.log` 提交到 Issues

## 致谢

[Manjaro](https://manjaro.org) · [MrChromebox](https://mrchromebox.tech) · [keyd](https://github.com/rvaiya/keyd) ·
[chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) · [cros-keyboard-map](https://github.com/WeirdTreeThing/cros-keyboard-map)（顶排按键扫描码表参考） ·
[Fluent 主题](https://github.com/vinceliuice/Fluent-gtk-theme) · [zram-generator](https://github.com/systemd/zram-generator) · [earlyoom](https://github.com/rfjakob/earlyoom) · [Xfce](https://xfce.org)

## 许可证

MIT
