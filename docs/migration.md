# 迁移说明

> 通过 Windows 11 电脑中转的完整流程见 [windows.md](windows.md)。

## 导出（旧系统上）

```bash
l4c export -o /run/media/$USER/你的U盘          # 保存到 U 盘
```

```bash
l4c export --send http://192.168.1.10:8848/口令   # 通过局域网发给 Windows 工具
```

| 选项 | 说明 |
|---|---|
| `-o 目录` | 保存位置。**全新安装前必须保存到 U 盘或移动硬盘**，保存在本机上会提示确认。FAT32 U 盘会自动分卷（单文件 4G 限制） |
| `--send 地址` | 边打包边通过局域网发送到 Windows 工具，Chromebook 上不占额外空间 |
| `--config-only` | 只备份设置（主目录下所有隐藏文件夹 + 桌面 + 模板），不备份文档 / 图片 / 下载等 |
| `--exclude '模式'` | 额外跳过某些文件，例如 `--exclude 'Videos/*'`，可以写多次 |
| `--no-wifi` | 不备份 Wi-Fi 密码 |
| `--list` | 只统计要备份多少数据，不真正打包 |

导出前请**关闭浏览器**，否则书签和密码可能备份不完整。

### 迁移包结构

```
l4c-backup-电脑名-日期/
├── manifest.env          用户名、主机名、时区、语言、默认 shell 等
├── packages/
│   ├── native.txt        自己安装的官方软件（pacman -Qqen）
│   ├── foreign.txt       AUR 软件（pacman -Qqem）
│   ├── flatpak.txt       Flatpak 应用
│   └── services.txt      启用的系统服务
├── home.tar.zst          个人文件和设置（zstd 压缩）
├── system.tar.zst        Wi-Fi、蓝牙配对、主机名、Xorg、keyd、GRUB 等（仅 root 可读）
├── unowned.tar.zst       手动装到 /usr/share/{themes,icons,fonts} 和 /usr/local 的文件
├── unowned.list
├── extra/                （Windows 工具「转换」加入的文件夹 → 新系统 ~/来自Windows/）
├── wifi-from-windows/    （Windows 工具转换的 Wi-Fi，NetworkManager 格式）
├── hardware/             inxi、lspci、lsusb、lsblk、顶排按键布局
└── SHA256SUMS            完整性校验
```

### 不会备份的内容

缓存（`~/.cache`、浏览器缓存）、回收站、Flatpak 运行库（可以重新下载）、Steam 游戏、
npm / cargo / gradle 下载缓存、缩略图。

## 导入

全新安装时，安装器会自动找到 U 盘上的迁移包并导入。也可以导入到任何已经装好的 Manjaro：

```bash
sudo l4c import /run/media/$USER/你的U盘/l4c-backup-xxx            # 从 U 盘
```

```bash
sudo l4c import http://192.168.1.10:8848/口令/l4c-backup-xxx       # 从 Windows 工具（边下载边解压）
```

| 选项 | 说明 |
|---|---|
| `--user 名字` | 还原给哪个用户（默认当前用户）。用户名和旧系统不同也没关系，配置文件里的旧路径会自动改过来 |
| `--yes` | 不逐项询问 |
| `--skip-packages` / `--skip-home` / `--skip-system` / `--skip-flatpak` | 跳过某一部分 |
| `--keep-hostname` | 保留新系统的电脑名 |

### 导入时会做什么

1. 校验 SHA256，文件损坏会提示
2. 重装官方软件：内核、引导、旧的 swap 工具、完整版 Noto CJK 字体等已被本项目替换的包会跳过；软件源里找不到的包会列出来
3. AUR 软件：在主目录生成 `需要从AUR安装的软件.txt`，登录后运行 `pamac build $(cat ~/需要从AUR安装的软件.txt)`
4. Flatpak：提示会占用多少空间，确认后才安装
5. 还原个人文件，改正文件归属；用户名不同时修正配置里的旧路径
6. 还原 Wi-Fi、蓝牙配对（同一台机器的蓝牙芯片，耳机/鼠标不用重新配对）、时区、语言、主机名
7. 还原手动安装的主题、图标、字体（不覆盖已有文件）
8. 恢复默认 shell（例如 zsh），询问是否启用旧系统启用过的服务
9. 其余旧系统配置（fstab、GRUB、pacman.conf 等）保存在 `/var/lib/l4c/old-system/` 供参考，不会直接覆盖
10. 日志：`/var/log/l4c-import.log`

## 关于 Win11 桌面和迁移的桌面设置

迁移包里包含你原来的 Xfce 面板和快捷键。全新安装时：

- 选择导入迁移包时，安装器默认**保留你原来的桌面布局**
- 选择 Win11 风格时，首次登录会把任务栏和快捷键改成 Win11 风格，原设置备份在 `~/.local/share/l4c/`，可以用 `l4c undo-desktop` 恢复
