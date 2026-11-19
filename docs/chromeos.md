# 清除残存信息 与 装回 ChromeOS

## 清除设备残存信息

| 场景 | 命令 | 做什么 |
|---|---|---|
| 日常 / 转手前清理正在用的系统 | `l4c wipe traces` | 逐项询问：命令历史、最近文件、缓存缩略图、回收站、本工具留下的备份、系统日志、软件包缓存；可选：浏览器数据、Wi-Fi 密码、蓝牙配对、SSH 密钥、钥匙环。最后执行 TRIM，让 eMMC 真正丢弃已删除的数据块 |
| 全新安装前 | 安装器自动询问 | 对整块 eMMC 做安全擦除（`blkdiscard --secure`，不支持则 TRIM 或全盘写零），并抽查 32 个位置确认已清空 |
| 手动整盘擦除 | 启动 U 盘里：`sudo bash …/setup/wipe.sh disk /dev/mmcblk0` | 同上，需输入大写 `WIPE` 确认；为安全起见只能在启动 U 盘里运行 |
| 删除旧的启动项 | `l4c wipe efi` | 删除指向已不存在分区的 UEFI 启动项（重装后开机菜单里不再出现旧系统） |
| Windows 电脑上 | Windows 工具 → 9 | 删除迁移包（含 Wi-Fi 密码等隐私）和浏览用的解压文件夹；原厂固件备份会先单独保留；可选用 `cipher /w` 覆盖空闲空间 |

## 装回 ChromeOS

先在 Chromebook 上运行：

```bash
l4c chromeos check
```

它会判断固件类型、查找原厂固件备份，并给出具体路线。

### 路线 A：ChromeOS Flex（简单，不用动固件）

1. Windows 工具 → **8) ChromeOS 恢复工具** → **1) 下载 ChromeOS Flex**
2. 按提示用「Chromebook 恢复实用工具」（齿轮 → 使用本地映像）或 Rufus 写入 U 盘
3. Chromebook 开机按 Esc 选 U 盘 → Install ChromeOS Flex

限制：没有安卓应用 / Play 商店；Google 未正式认证这款机型，个别硬件（比如扬声器）可能不工作。

### 路线 B：原厂 ChromeOS（功能完整）

需要**原厂固件备份**（当初刷 MrChromebox UEFI 固件时保存的 `stock-firmware-*.rom`）。

1. 确保备份安全：`l4c chromeos backup-firmware` 复制到 U 盘；迁移包导出时也会自动带上 `firmware/` 目录
2. 恢复原厂固件：`sudo l4c chromeos firmware`，在 MrChromebox 菜单里选择恢复原厂固件（**全程接电源**）
3. （推荐）按当初关闭写保护的方式恢复写保护
4. Windows 工具 → **8)** → **2) 下载本机型原厂恢复镜像**（自动按主板代号查找 Google 官方镜像并校验 SHA1）
5. 写入 U 盘，Chromebook 关机后按住 **Esc + 刷新键** 再按电源键进入恢复模式，插入 U 盘

原厂固件状态（没刷过 UEFI 固件）时直接从第 4 步开始。

> 刷固件有风险：中途断电或选错文件可能导致无法开机。请先阅读 <https://docs.mrchromebox.tech> 上本机型的说明。
