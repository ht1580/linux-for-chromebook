# 更新日志

## 未发布

- **支持 CachyOS 和 Arch**：安装器按启动 U 盘的发行版选择 basestrap / pacstrap、内核（linux618 / linux-cachyos / linux）、镜像工具；
  软件包列表拆成通用和各发行版专属；kexec 热启动认得 archiso（Arch / CachyOS）的 ISO；从 Manjaro 迁出时跳过 Manjaro 专属软件
- 全新安装的软件包加上 Win11 任务栏需要的 xfce4-genmon-plugin、xdotool（之前漏了）
- 浏览器省内存：Chrome / Chromium「节省内存」、Edge「睡眠标签页」系统级策略
- QQ、哔哩哔哩：从开始菜单启动时加内存软上限（总内存的 1/4，systemd MemoryHigh）和较低的后台 CPU 优先级；超出部分压缩进 zram，不会被强制结束
- 开机常驻再瘦身：可关掉 pamac 更新提醒托盘、蓝牙托盘（已配对设备照常连接）
- 任务栏插件改在任务栏进程里运行（用户目录放 X-XFCE-Internal=TRUE 的插件说明），少 7 个约 11 MB 的进程
- 屏蔽无障碍总线和 iPhone / 数码相机自动识别服务（不用读屏软件时）
- 拔电自动省电模式；删除 Intel 机器上用不到的 AMD 微码
- `optimize --remove-wine`：删除 wine 和全部 32 位库；wine 程序目录（个人数据）默认不删

## 0.2.0（2026-11-19）—— 第一次在真机上全新安装

在 HP Chromebook 11（Yavilla）上通过局域网 SSH 扫描、备份、擦盘、全新安装并逐项核对。

### 硬件适配（按实机扫描修正）

- 支持**原厂 Google 固件**（开发者模式 + RW_LEGACY）：引导文件装到固件唯一认的默认路径，写 UEFI 启动项失败时自动改用 `--no-nvram`；安装器和 `l4c info` 提醒开机按 Ctrl+L、不要按空格
- 新增 `setup/kexec-live.sh`：原厂固件不保存启动项、来不及按 Esc 时，从旧系统直接热启动到 U 盘上的 Live 系统
- 声卡：社区脚本固定到审阅过的版本并全自动运行；实测扬声器、耳机、HDMI、麦克风都出现在 PipeWire 里（旧系统完全没声音）
- 视频：改用 iHD 驱动，去掉 N100 用不了的 i965；Chrome / Edge 自动开启 VA-API
- 键盘：Alt + 亮度键 = 键盘背光；Wi-Fi 关闭省电（实测频繁丢信号）；可选 80% 充电上限

### 性能、内存、存储

- 透明大页 madvise、MGLRU `min_ttl_ms=1000`（ChromeOS 同款）；earlyoom 认识 QQ / Edge / 哔哩哔哩
- `l4c optimize --ram`：精简开机常驻程序（Proton VPN 后台改为按需启动、重复的剪贴板管理器等），实测可用内存多 55 MB；
  Proton VPN 后台用过一次就会常驻（峰值约 250 MB），现在不再开机常驻
- 开机不再等待联网（省 4.4 秒）；GRUB 隐藏菜单等待 1 秒；关闭 man-db 定时任务和空的 cronie
- 兜底 swap 改为 1G；光标包只留一个变体，删除用不到的主题；全新安装后硬盘占用从 93% 降到约 50%

### Windows 11 外观（`l4c look`）

- Win11 风格登录 / 锁屏界面、壁纸（可直接用你自己 Windows 里的原版壁纸和锁屏图）、白色光标
- 屏保改为空闲 5 分钟黑屏 + 唤醒要密码（原来是动画）；通知在右下角；开始菜单搜索在顶部
- 任务栏和 Win11 一样**靠左**：开始、搜索、应用；右侧 ^、中/英、Wi-Fi、音量、电池百分比、时间、通知
- **^ 弹出框**：托盘图标排成网格，圆角、阴影，鼠标移开自动收起
- 黄色文件夹图标、托盘深色图标、浅色半透明任务栏；只保留一个窗口合成器（picom）
- 修复中文环境下终端字间距过大（等宽字体被思源黑体抢先）

### 安装器与迁移

- 安装器：选盘时排除 eMMC 引导区和启动 U 盘；完整输出写入日志；`L4C_BACKUP_URL` 预先填好迁移包地址
- `lib/common.sh` 的 `set_block`：修复 awk 吃掉 `\[` 转义，导致 pacman.conf 设置放错位置
- 导入时不再把优化掉的服务和驱动从旧系统清单里装回来
- CI：shellcheck 覆盖所有脚本，修复全部告警

## 0.1.0

初始版本：迁移包导出 / 导入、Windows 工具、全新安装器、内存和存储优化、键盘和声卡适配、Win11 使用习惯。
