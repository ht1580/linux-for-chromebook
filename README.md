# linux-for-chromebook

把 **HP Chromebook 11（主板代号 Yavilla，Intel N100，4G 内存，32G eMMC）** 变成一台
**省内存、省空间、用起来像 Windows 11** 的电脑，并且可以**完整迁移**旧系统里的软件、设置、个人文件和 Wi-Fi。

基于 Manjaro（Arch）+ 精简 Xfce。所有功能都是 shell 脚本，可以随时查看和修改。

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
l4c desktop       # Windows 11 风格任务栏和快捷键（会先备份你现在的桌面设置）
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
2. 用 [Manjaro Xfce 启动 U 盘](https://manjaro.org/products/download/x86) 启动 Chromebook（开机按 Esc 选 U 盘），连上 Wi-Fi
3. 打开终端：

   ```bash
   git clone https://github.com/ht1580/linux-for-chromebook && sudo bash linux-for-chromebook/install/install.sh
   ```

4. 按提示选择迁移包、硬盘、用户名，安装器自动完成分区、安装、键盘声卡适配、导入数据

---

## 做了哪些优化

### 内存（4G 不够用的主要原因）

| 优化 | 效果 |
|---|---|
| **zram** 压缩内存（zstd，最多 2×内存） | 同样的 4G 能多装约一倍程序，比往 eMMC 上写 swap 快几十倍 |
| 原来的 8G swap 文件缩小为 2G，只在 zram 用完时兜底 | 腾出约 6G 硬盘 |
| **earlyoom** | 内存耗尽时先结束最占内存的浏览器标签页，而不是整机卡死几分钟 |
| 内核参数（swappiness、page-cluster 等，针对 zram 调整） | 内存紧张时界面更跟手 |
| Firefox：内存缓存、低内存时自动休眠标签页、限制进程数 | 浏览器少占内存、少写硬盘 |
| Intel 硬件视频解码（VA-API） | 看视频 CPU 占用明显下降，更省电 |

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
- 可选关闭打印、局域网发现、4G 上网卡等用不上的服务

### Chromebook 硬件适配

- **键盘**（[keyd](https://github.com/rvaiya/keyd)）：自动读取本机顶排按键布局并生成映射，只作用于内置键盘：
  - 顶排按键：返回、刷新（F5）、全屏（F11）、窗口切换、亮度、音量
  - **搜索键 = Windows 键**；搜索键 + 顶排 = F1…F10
  - 补上 Chromebook 缺少的键：Alt+退格 = Delete，Alt+↑/↓ = PageUp/PageDown，Ctrl+Alt+↑/↓ = Home/End，Alt+搜索键 = CapsLock
- **声卡**：调用社区项目 [chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)（Linux 下 Chromebook 扬声器默认没有声音）
- **触控板**：轻触点击，两指点击 = 右键
- `l4c info` 查看机型、固件（MrChromebox）、顶排键布局

### 像 Windows 11 一样用

- **居中任务栏**：开始按钮 + 固定应用居中，托盘、音量、电量、时钟在右侧（[xfce4-docklike-plugin](https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin)）
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
l4c clean                 清理存储空间
l4c keyboard              键盘映射
l4c audio                 声卡驱动
l4c desktop [--theme]     Windows 11 风格桌面
l4c theme                 安装 Fluent 主题
l4c undo-desktop <目录>   恢复修改前的桌面
l4c install               全新安装（在启动 U 盘里）
l4c status                查看内存/存储状态
l4c info                  查看机型和固件
```

## 目录结构

```
bin/l4c                    命令入口
lib/common.sh              公共函数
setup/optimize.sh          内存、存储、eMMC、视频解码优化
setup/chromebook.sh        键盘映射、声卡、硬件信息
setup/desktop-win11.sh     Windows 11 风格桌面和快捷键
migrate/export.sh          转换程序：导出迁移包（U 盘 / 局域网发送）
migrate/import.sh          导入程序：还原迁移包（U 盘 / 局域网边下载边导入）
windows/启动工具.bat        Windows 工具：接收、校验、转换、回传迁移包，制作安装 U 盘
windows/l4c-win.ps1        Windows 工具本体（PowerShell）
install/install.sh         全新安装器（在 Manjaro 启动 U 盘里运行）
install/chroot-setup.sh    安装器在新系统里执行的配置步骤
install/packages/*.txt     全新安装的软件包列表（可自行增删）
config/                    各种配置文件
docs/                      快捷键表、迁移说明、Windows 流程
```

## 测试情况

- 所有脚本通过 `bash -n` 语法检查和 ShellCheck 静态检查（GitHub Actions 自动运行）
- 迁移包的导出 → 导入流程已在 Linux 环境中实际测试：U 盘方式、局域网边传边导入方式（用模拟的 Windows 传输服务）、FAT32 分卷、中文文件名、从 Windows 加入的文件和 Wi-Fi、用户名不同时的路径修正、完整性校验
- Windows 工具（PowerShell）做了结构检查和人工审阅，**尚未在真实 Windows 11 上运行过**
- 键盘映射生成、配置文件修改（pacman.conf、fstab、GRUB 参数）已测试，并且重复运行结果不变
- **尚未在 Yavilla 实机上完整测试全新安装流程**，如遇问题请把终端里的报错（会显示出错的脚本和行号）提交到 Issues

## 致谢

[Manjaro](https://manjaro.org) · [MrChromebox](https://mrchromebox.tech) · [keyd](https://github.com/rvaiya/keyd) ·
[chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) · [cros-keyboard-map](https://github.com/WeirdTreeThing/cros-keyboard-map)（顶排按键扫描码表参考） ·
[Fluent 主题](https://github.com/vinceliuice/Fluent-gtk-theme) · [zram-generator](https://github.com/systemd/zram-generator) · [earlyoom](https://github.com/rfjakob/earlyoom) · [Xfce](https://xfce.org)

## 许可证

MIT
