# 通过 Windows 11 电脑完成迁移和安装

整个流程：**Chromebook 数据 → Windows 电脑 → 制作安装 U 盘 → Chromebook 装新系统 → 数据转换后传回 Chromebook**。

```
 Chromebook（旧系统）            Windows 11 电脑                  Chromebook（新系统）
 ─────────────────────          ─────────────────────            ─────────────────────
 ① l4c export ──局域网/U盘──▶  ② 接收、校验迁移包
                                ③ 转换：加入 Windows 的
                                   Wi-Fi、文件夹
                                ④ 制作安装 U 盘 ───U 盘───────▶ ⑤ U 盘启动，运行安装器
                                   传输服务 ◀──────局域网─────── ⑥ 安装器边下载边导入
```

Windows 工具不需要安装任何软件，只用 Windows 11 自带的 PowerShell。

---

## 准备

在 Windows 电脑上下载本项目：打开 <https://github.com/ht1580/linux-for-chromebook> → 绿色的 **Code** 按钮 → **Download ZIP**，解压。

双击 `windows\启动工具.bat`，同意管理员权限（用于临时开放局域网端口，停止服务后自动关闭）。

```
  1) 启动传输服务（局域网接收 Chromebook 数据 / 安装时回传）
  2) 从 U 盘导入迁移包到这台电脑
  3) 校验迁移包
  4) 转换：把 Windows 的 Wi-Fi、文件夹加入迁移包
  5) 在 Windows 上浏览迁移包里的文件
  6) 制作 Chromebook 安装 U 盘
  7) 打开迁移包所在文件夹
```

迁移包保存在 `C:\Users\你的用户名\Chromebook迁移\`。

---

## ① 把 Chromebook 的数据传到 Windows

### 方式 A：局域网（推荐）

两台设备连同一个 Wi-Fi / 路由器。Windows 工具选 **1) 启动传输服务**，屏幕上会显示地址和要在 Chromebook 上输入的命令，例如：

```bash
l4c export --send http://192.168.1.10:8848/k3m9x2pq
```

Chromebook 上还没有 l4c 的话，工具也显示了一行“先下载工具再发送”的命令，直接复制即可（工具本身由 Windows 电脑提供，不需要访问 GitHub）。

- 边打包边发送，**Chromebook 上不需要额外空间**（这台机器硬盘只剩约 3G，放不下一份完整备份）
- 传完后 Windows 上显示收到的每个文件；按 **Q** 停止服务
- 地址最后一段是随机口令，每次启动服务都不同，别人猜不到

### 方式 B：U 盘

```bash
l4c export -o /run/media/$USER/你的U盘
```

U 盘建议格式化为 **exFAT**（Windows 和 Linux 都能读写，没有 4G 单文件限制）。如果是 FAT32，导出时会自动把大文件分卷，导入时自动合并。

然后在 Windows 工具选 **2) 从 U 盘导入迁移包**，选择 U 盘上的 `l4c-backup-…` 文件夹，复制完会自动校验。

> 用数据线把 Chromebook 和 Windows 直接连起来一般不能传文件（两边都是“主机”）。请用局域网或 U 盘。

## ② 校验

工具选 **3) 校验迁移包**，逐个文件比对 SHA256，确认传输没有出错。显示“全部 N 个文件完整”后再继续。

## ③ 转换：把 Windows 的东西也带过去

工具选 **4) 转换**：

| 选项 | 作用 |
|---|---|
| Wi-Fi | 把这台 Windows 电脑保存过的 Wi-Fi（家里、公司……）从 Windows 格式转换成 Linux 的 NetworkManager 格式，新系统自动连接，不用再输密码。支持 WPA2/WPA3 个人版和开放网络；企业认证的会跳过并提示 |
| 文件夹 | 选 Windows 上的文件夹（文档、照片等），新系统里会出现在 `~/来自Windows/` |

转换过程中导出的 Wi-Fi 明文密码只在临时文件夹里停留几秒，转换完立即删除。

**5) 在 Windows 上浏览迁移包里的文件**：把个人文件解压到一个单独的文件夹，方便在 Windows 上查看或取出某个文件（需要 Windows 11 自带的 tar 支持 zstd，较新版本都支持）。

## ④ 制作安装 U 盘

工具选 **6) 制作 Chromebook 安装 U 盘**，按提示：

1. 下载 [Ventoy](https://www.ventoy.net/cn/download.html)，运行里面的 `Ventoy2Disk.exe` 安装到 U 盘（**会清空 U 盘**）
2. 下载 [Manjaro Xfce 镜像](https://manjaro.org/products/download/x86)
3. 工具把镜像、本项目、（可选）迁移包复制到 U 盘

Ventoy 的好处是一个 U 盘同时放启动镜像和普通文件，不用每次重新写盘。

> 也可以用 Rufus 直接把镜像写入 U 盘，但这样 U 盘里放不了其他文件，迁移包和本工具需要通过局域网获取。

## ⑤ 在 Chromebook 上安装

1. 插入 U 盘，开机时按 **Esc**，选择 U 盘启动，在 Ventoy 菜单里选 Manjaro
2. 进入桌面后连接 Wi-Fi，打开终端，运行：

   ```bash
   sudo bash /run/media/manjaro/Ventoy/linux-for-chromebook/install/install.sh
   ```

   （U 盘名称不是 Ventoy 时替换成实际名称；没有把工具放进 U 盘的话，先在 Windows 工具里启动传输服务，然后：`mkdir l4c && curl -fsS http://IP:8848/口令/l4c.tar.gz | tar -xz -C l4c && sudo bash l4c/install/install.sh`）

## ⑥ 数据传回

安装器询问迁移包来源时：

```
  1) U 盘：/run/media/manjaro/Ventoy/l4c-backups/l4c-backup-…
  w) 从 Windows 电脑通过局域网获取
  0) 不导入，全新开始
```

- 迁移包在 U 盘上：选对应编号
- 迁移包在 Windows 上：先在 Windows 工具里 **1) 启动传输服务**，再选 **w**，输入工具显示的地址，然后选择迁移包

通过局域网导入时**边下载边解压**，不需要先把整个迁移包存到 Chromebook 上；下载完成后自动比对校验值。

安装器会自动：还原软件、个人文件、设置、Chromebook 原来的 Wi-Fi 和蓝牙配对，加上转换好的 Windows Wi-Fi 和文件夹。

已经装好的系统也可以随时再导入一次：

```bash
sudo l4c import http://192.168.1.10:8848/口令/l4c-backup-…
```

---

## 常见问题

**Chromebook 连不上 Windows 的地址**
- 两台设备要在同一个网络（同一个路由器），手机热点也可以
- Windows 网络设置为“公用网络”时，部分路由器会隔离设备；可以在 Windows 设置 → 网络 → 属性 改为“专用网络”
- 工具显示了多个地址时，换另一个试试
- 公司 / 学校网络可能禁止设备互访，改用 U 盘

**传到一半断了**：重新运行导出命令即可（会生成新的迁移包，旧的不完整迁移包可以在 Windows 上删掉）。

**Windows 提示无法运行脚本**：请用 `启动工具.bat` 启动，它会临时允许本脚本运行，不会修改系统设置。
