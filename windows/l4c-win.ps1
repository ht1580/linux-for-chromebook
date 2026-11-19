#Requires -Version 5.1
<#
  linux-for-chromebook Windows 工具
  在 Windows 11 电脑上：接收 / 校验 / 转换 / 回传 Chromebook 的迁移包，并制作安装 U 盘。
  使用方法：双击同目录下的「启动工具.bat」（会请求管理员权限，用于开放局域网端口）。
#>
param([int]$Port = 8848)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'linux-for-chromebook Windows 工具'

$Root    = Join-Path $env:USERPROFILE 'Chromebook迁移'
$RepoDir = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $Root | Out-Null

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  √ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Pause-Key { Write-Host ''; Read-Host '按回车返回菜单' | Out-Null }

function Test-Admin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-Port', $Port)
  exit
}

function Format-Size([double]$b) {
  if ($b -ge 1GB) { return '{0:N1} GB' -f ($b / 1GB) }
  if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
  return '{0:N0} KB' -f ($b / 1KB)
}

function Get-LanIPs {
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Select-Object -ExpandProperty IPAddress
}

function Get-Packages {
  @(Get-ChildItem -LiteralPath $Root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.env') } | Sort-Object Name -Descending)
}

function Read-Manifest($dir) {
  $m = @{}
  foreach ($l in [IO.File]::ReadAllLines((Join-Path $dir 'manifest.env'), $Utf8NoBom)) {
    if ($l -match '^([A-Z0-9_]+)=(.*)$') { $m[$Matches[1]] = $Matches[2] }
  }
  return $m
}

function Select-Package {
  $p = Get-Packages
  if ($p.Count -eq 0) { Warn "还没有迁移包（保存位置：$Root）"; return $null }
  for ($i = 0; $i -lt $p.Count; $i++) {
    $size = (Get-ChildItem -LiteralPath $p[$i].FullName -Recurse -File | Measure-Object Length -Sum).Sum
    Write-Host ("  {0}) {1}  ({2})" -f ($i + 1), $p[$i].Name, (Format-Size $size))
  }
  $s = Read-Host '选择编号（直接回车 = 1）'
  if ($s -eq '') { $s = '1' }
  $n = 0
  if (-not [int]::TryParse($s, [ref]$n) -or $n -lt 1 -or $n -gt $p.Count) { Warn '无效选择'; return $null }
  return $p[$n - 1]
}

function Select-Folder($desc) {
  Add-Type -AssemblyName System.Windows.Forms
  $d = New-Object System.Windows.Forms.FolderBrowserDialog
  $d.Description = $desc
  if ($d.ShowDialog() -eq 'OK') { return $d.SelectedPath }
  return $null
}

# ------------------------------------------------------------------ 校验 --
function Test-Package($dir) {
  $sums = Join-Path $dir 'SHA256SUMS'
  if (-not (Test-Path -LiteralPath $sums)) { Warn '迁移包里没有 SHA256SUMS，无法校验'; return $false }
  $bad = 0; $n = 0
  foreach ($line in [IO.File]::ReadAllLines($sums, $Utf8NoBom)) {
    if ($line -notmatch '^([0-9a-f]{64}) [ *](.+)$') { continue }
    $want = $Matches[1]; $rel = $Matches[2]
    $f = Join-Path $dir ($rel -replace '/', '\')
    $n++
    if (-not (Test-Path -LiteralPath $f)) { Warn "缺少文件：$rel"; $bad++; continue }
    Write-Host "  校验 $rel ..." -NoNewline
    $got = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    if ($got -eq $want) { Write-Host ' 正常' -ForegroundColor Green } else { Write-Host ' 损坏！' -ForegroundColor Red; $bad++ }
  }
  if ($bad -eq 0) { Ok "全部 $n 个文件完整"; return $true }
  Warn "$bad 个文件有问题，请重新传输"; return $false
}

function Show-PackageInfo($dir) {
  $m = Read-Manifest $dir
  Write-Host ''
  Write-Host "  迁移包：  $(Split-Path -Leaf $dir)"
  Write-Host "  来自：    $($m['HOSTNAME'])（用户 $($m['USERNAME'])，主板 $($m['BOARD'])）"
  Write-Host "  创建于：  $($m['CREATED'])"
  Write-Host "  时区语言：$($m['TIMEZONE'])  $($m['LOCALE'])"
  $native = Join-Path $dir 'packages\native.txt'
  if (Test-Path -LiteralPath $native) { Write-Host "  软件：    $(@(Get-Content -LiteralPath $native | Where-Object { $_ }).Count) 个" }
  $extra = Join-Path $dir 'extra'
  if (Test-Path -LiteralPath $extra) { Write-Host "  已加入的 Windows 文件：$(@(Get-ChildItem -LiteralPath $extra -Recurse -File).Count) 个" }
  $wifi = Join-Path $dir 'wifi-from-windows'
  if (Test-Path -LiteralPath $wifi) { Write-Host "  已转换的 Windows Wi-Fi：$(@(Get-ChildItem -LiteralPath $wifi -File).Count) 个" }
}

# ---------------------------------------------------------- 局域网传输 --
function Send-Text($ctx, [int]$code, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text)
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = 'text/plain; charset=utf-8'
  $ctx.Response.ContentLength64 = $b.Length
  $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  $ctx.Response.Close()
}

function Send-File($ctx, $path, $type) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $fs.Length
    $fs.CopyTo($ctx.Response.OutputStream, 1048576)
  } finally { $fs.Close(); $ctx.Response.Close() }
}

function Get-RepoTarball {
  $t = Join-Path $env:TEMP 'l4c-repo.tar.gz'
  & tar.exe -czf $t -C $RepoDir --exclude=.git --exclude=windows . 2>$null
  if ($LASTEXITCODE -ne 0) { throw '打包工具失败' }
  return $t
}

function Invoke-Request($ctx, $token) {
  $req = $ctx.Request
  $path = [Uri]::UnescapeDataString($req.Url.AbsolutePath)
  $segs = @($path.Trim('/') -split '/' | Where-Object { $_ -ne '' })
  if ($segs.Count -eq 0 -or $segs[0] -ne $token) { Send-Text $ctx 403 "口令错误`n"; return }
  $rest = @($segs | Select-Object -Skip 1)
  foreach ($s in $rest) {
    if ($s -eq '..' -or $s -eq '.' -or $s -match '[\\:*?"<>|]') { Send-Text $ctx 400 "bad path`n"; return }
  }
  Write-Host ('  {0}  {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $req.HttpMethod, ($rest -join '/'))

  if ($rest.Count -eq 0) {
    Send-Text $ctx 200 ((@(Get-Packages | ForEach-Object { $_.Name }) -join "`n") + "`n"); return
  }
  if ($rest.Count -eq 1 -and $rest[0] -eq 'l4c.tar.gz' -and $req.HttpMethod -eq 'GET') {
    Send-File $ctx (Get-RepoTarball) 'application/gzip'; return
  }
  if ($rest[0] -notmatch '^l4c-backup-[A-Za-z0-9._-]+$') { Send-Text $ctx 400 "bad package name`n"; return }
  $pkgDir = Join-Path $Root $rest[0]
  $rel = (@($rest | Select-Object -Skip 1)) -join '\'

  switch ($req.HttpMethod) {
    'PUT' {
      if ($rel -eq '') { Send-Text $ctx 400 "missing file`n"; return }
      $file = Join-Path $pkgDir $rel
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
      $tmp = "$file.uploading"
      $fs = [IO.File]::Create($tmp)
      try { $req.InputStream.CopyTo($fs, 1048576) } finally { $fs.Close() }
      Move-Item -Force -LiteralPath $tmp -Destination $file
      Write-Host ('             已接收 {0}' -f (Format-Size (Get-Item -LiteralPath $file).Length)) -ForegroundColor DarkGray
      Send-Text $ctx 201 "ok`n"
    }
    'GET' {
      if ($rel -eq '') {
        if (-not (Test-Path -LiteralPath $pkgDir)) { Send-Text $ctx 404 "not found`n"; return }
        $list = Get-ChildItem -LiteralPath $pkgDir -Recurse -File | Where-Object { $_.Name -notlike '*.uploading' } |
          ForEach-Object { $_.FullName.Substring($pkgDir.Length + 1) -replace '\\', '/' }
        Send-Text $ctx 200 ((@($list) -join "`n") + "`n")
      } else {
        $file = Join-Path $pkgDir $rel
        if (Test-Path -LiteralPath $file -PathType Leaf) { Send-File $ctx $file 'application/octet-stream' }
        else { Send-Text $ctx 404 "not found`n" }
      }
    }
    default { Send-Text $ctx 405 "method not allowed`n" }
  }
}

function Start-TransferServer {
  $chars = 'abcdefghjkmnpqrstuvwxyz23456789'.ToCharArray()
  $token = -join (1..8 | ForEach-Object { $chars | Get-Random })
  $rule = 'linux-for-chromebook 传输'
  Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add("http://+:$Port/")
  try { $listener.Start() } catch { Warn "端口 $Port 无法使用：$($_.Exception.Message)"; Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue; return }

  $ips = @(Get-LanIPs)
  Clear-Host
  Say '传输服务已启动（Chromebook 和这台电脑需要连接同一个 Wi-Fi / 路由器）'
  Write-Host ''
  Write-Host '  本机地址（任选一个能连通的）：'
  foreach ($ip in $ips) { Write-Host "      http://${ip}:$Port/$token" -ForegroundColor White }
  $a = "http://$($ips[0]):$Port/$token"
  Write-Host ''
  Write-Host '  ① 在 Chromebook（旧系统）的终端里发送数据：' -ForegroundColor Cyan
  Write-Host "      l4c export --send $a"
  Write-Host '     还没装 l4c 的话，先下载工具：' -ForegroundColor DarkGray
  Write-Host "      mkdir -p ~/l4c && curl -fsS $a/l4c.tar.gz | tar -xz -C ~/l4c && bash ~/l4c/bin/l4c export --send $a"
  Write-Host ''
  Write-Host '  ② 安装新系统时取回数据：在安装器里选择「w) 从 Windows 电脑获取」，输入上面的地址' -ForegroundColor Cyan
  Write-Host "     已装好的系统也可以：sudo l4c import $a/迁移包名称"
  Write-Host ''
  Write-Host "  迁移包保存在：$Root（剩余空间 $(Format-Size (Get-PSDrive ($Root.Substring(0,1))).Free)）"
  Write-Host '  按 Q 键停止服务（停止后会自动关闭防火墙端口）' -ForegroundColor Yellow
  Write-Host ''
  $stop = $false
  try {
    while ($listener.IsListening -and -not $stop) {
      $task = $listener.GetContextAsync()
      while (-not $task.AsyncWaitHandle.WaitOne(300)) {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { $stop = $true; break }
      }
      if ($stop) { break }
      $ctx = $task.GetAwaiter().GetResult()
      try { Invoke-Request $ctx $token }
      catch {
        Warn "请求出错：$($_.Exception.Message)"
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch { }
      }
    }
  } finally {
    $listener.Stop(); $listener.Close()
    Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $env:TEMP 'l4c-repo.tar.gz') -ErrorAction SilentlyContinue
    Ok '传输服务已停止，防火墙端口已关闭'
  }
}

# ---------------------------------------------------------- U 盘导入 ----
function Import-FromUsb {
  Say '选择 U 盘上的迁移包文件夹（名字以 l4c-backup- 开头），或者包含它的上一级文件夹'
  $src = Select-Folder '选择迁移包文件夹'
  if (-not $src) { return }
  $cands = @()
  if (Test-Path -LiteralPath (Join-Path $src 'manifest.env')) { $cands += Get-Item -LiteralPath $src }
  else { $cands = @(Get-ChildItem -LiteralPath $src -Directory -Filter 'l4c-backup-*' | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.env') }) }
  if ($cands.Count -eq 0) { Warn '这里没有迁移包'; return }
  foreach ($c in $cands) {
    $dst = Join-Path $Root $c.Name
    Say "复制 $($c.Name) 到 $dst"
    & robocopy.exe $c.FullName $dst /E /NJH /NJS /NDL /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) { Warn "复制失败（robocopy 错误码 $LASTEXITCODE）"; continue }
    Ok '复制完成'
    Test-Package $dst | Out-Null
  }
}

# ---------------------------------------------------------- 转换 --------
function Convert-WindowsWifi($pkgDir) {
  $tmp = Join-Path $env:TEMP ('l4c-wifi-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    & netsh.exe wlan export profile key=clear folder="$tmp" | Out-Null
    $out = Join-Path $pkgDir 'wifi-from-windows'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $n = 0; $skip = @()
    foreach ($x in Get-ChildItem -LiteralPath $tmp -Filter '*.xml') {
      [xml]$doc = [IO.File]::ReadAllText($x.FullName)
      $p = $doc.WLANProfile
      $ssid = [string]$p.SSIDConfig.SSID.name
      $auth = [string]$p.MSM.security.authEncryption.authentication
      $key  = [string]$p.MSM.security.sharedKey.keyMaterial
      if (-not $ssid) { continue }
      $sec = $null
      if ($auth -match '^(WPA2PSK|WPAPSK)$') { $sec = "[wifi-security]`nkey-mgmt=wpa-psk`npsk=$key`n" }
      elseif ($auth -eq 'WPA3SAE') { $sec = "[wifi-security]`nkey-mgmt=sae`npsk=$key`n" }
      elseif ($auth -eq 'open') { $sec = '' }
      if ($null -eq $sec) { $skip += "$ssid（$auth）"; continue }
      $text = "[connection]`nid=$ssid`nuuid=$([guid]::NewGuid())`ntype=wifi`n`n[wifi]`nmode=infrastructure`nssid=$ssid`n`n$sec`n[ipv4]`nmethod=auto`n`n[ipv6]`nmethod=auto`n"
      $name = ($ssid -replace '[\\/:*?"<>|\s]', '_') + '.nmconnection'
      [IO.File]::WriteAllText((Join-Path $out $name), $text, $Utf8NoBom)
      $n++
    }
    Ok "已转换 $n 个 Wi-Fi（Windows 格式 → Linux NetworkManager 格式）"
    if ($skip.Count) { Warn "企业认证等无法自动转换，已跳过：$($skip -join '、')" }
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue   # 里面有明文密码
  }
}

function Add-WindowsFolders($pkgDir) {
  $extra = Join-Path $pkgDir 'extra'
  while ($true) {
    $f = Select-Folder '选择要带到 Chromebook 的文件夹（会出现在新系统的「来自Windows」文件夹里）'
    if (-not $f) { break }
    $leaf = Split-Path -Leaf $f
    if (-not $leaf) { $leaf = 'Drive' }
    $size = (Get-ChildItem -LiteralPath $f -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host "  $f （$(Format-Size $size)）"
    if ($size -gt 8GB) { Warn 'Chromebook 硬盘只有 32G，文件太大可能放不下' }
    & robocopy.exe $f (Join-Path $extra $leaf) /E /NJH /NJS /NDL /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) { Warn '复制失败' } else { Ok "已加入 $leaf" }
    if ((Read-Host '继续添加其他文件夹？(y/N)') -notmatch '^[Yy]') { break }
  }
}

function Invoke-Convert {
  $p = Select-Package; if (-not $p) { return }
  Show-PackageInfo $p.FullName
  Write-Host ''
  Write-Host '  1) 把这台 Windows 电脑保存的 Wi-Fi 转换后加入（新系统自动连接，无需再输密码）'
  Write-Host '  2) 把 Windows 上的文件夹加入（例如 文档、图片）'
  Write-Host '  3) 两项都做'
  $c = Read-Host '选择'
  if ($c -eq '1' -or $c -eq '3') { Convert-WindowsWifi $p.FullName }
  if ($c -eq '2' -or $c -eq '3') { Add-WindowsFolders $p.FullName }
}

function Open-PackageFiles {
  $p = Select-Package; if (-not $p) { return }
  $dir = $p.FullName
  $arc = Join-Path $dir 'home.tar.zst'
  $parts = @(Get-ChildItem -LiteralPath $dir -Filter 'home.tar.zst.part*' | Sort-Object Name)
  $cleanup = $false
  if (-not (Test-Path -LiteralPath $arc) -and $parts.Count) {
    Say '合并分卷……'
    $arc = Join-Path $env:TEMP 'l4c-home.tar.zst'
    $out = [IO.File]::Create($arc)
    try { foreach ($pt in $parts) { $in = [IO.File]::OpenRead($pt.FullName); try { $in.CopyTo($out) } finally { $in.Close() } } } finally { $out.Close() }
    $cleanup = $true
  }
  if (-not (Test-Path -LiteralPath $arc)) { Warn '迁移包里没有个人文件'; return }
  $ver = (& tar.exe --version) -join ' '
  if ($ver -notmatch 'zstd') { Warn '这台电脑自带的 tar 不支持 zstd 格式。请升级到较新的 Windows 11，或安装 7-Zip ZS 后手动解压 home.tar.zst'; return }
  $dst = Join-Path $Root ($p.Name + '-浏览')
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Say "解压到 $dst（只读查看用，修改这里的文件不会影响迁移包）"
  & tar.exe -xf $arc -C $dst 2>$null
  if ($cleanup) { Remove-Item -Force $arc }
  Ok '完成。Linux 的隐藏文件夹以 . 开头；个别 Windows 不允许的文件名会被跳过。'
  Start-Process explorer.exe $dst
}

# ---------------------------------------------------------- 安装 U 盘 ----
function Get-UsbVolumes {
  @(Get-Volume | Where-Object {
      $_.DriveLetter -and (
        $_.DriveType -eq 'Removable' -or
        ((Get-Partition -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue).BusType -eq 'USB'))
    })
}

function New-InstallUsb {
  Say '制作 Chromebook 安装 U 盘（推荐 Ventoy：一个 U 盘同时放系统镜像、本工具和迁移包）'
  Write-Host @'

  第一次使用请先准备：
    1. 下载 Ventoy（开源免费）并把它安装到 U 盘（会清空 U 盘）：https://www.ventoy.net/cn/download.html
    2. 下载 Manjaro Xfce 镜像（.iso 文件）：https://manjaro.org/products/download/x86
  准备好后继续。

'@
  if ((Read-Host '打开这两个下载页面？(y/N)') -match '^[Yy]') {
    Start-Process 'https://www.ventoy.net/cn/download.html'; Start-Process 'https://manjaro.org/products/download/x86'
    Read-Host '装好 Ventoy、下载好镜像后按回车继续' | Out-Null
  }
  $vols = Get-UsbVolumes
  if ($vols.Count -eq 0) { Warn '没有找到 U 盘'; return }
  for ($i = 0; $i -lt $vols.Count; $i++) {
    $v = $vols[$i]
    Write-Host ('  {0}) {1}:  {2}  {3}  剩余 {4}' -f ($i + 1), $v.DriveLetter, $v.FileSystemLabel, $v.FileSystem, (Format-Size $v.SizeRemaining))
  }
  $n = 0
  if (-not [int]::TryParse((Read-Host '选择 U 盘'), [ref]$n) -or $n -lt 1 -or $n -gt $vols.Count) { Warn '无效选择'; return }
  $v = $vols[$n - 1]; $drive = "$($v.DriveLetter):\"
  if ($v.FileSystemLabel -ne 'Ventoy') { Warn '这个 U 盘看起来没有安装 Ventoy，复制进去的镜像可能无法启动。' }
  if ($v.FileSystem -eq 'FAT32') { Warn 'U 盘是 FAT32，单个文件不能超过 4G；迁移包大文件请改用局域网传输。' }

  $iso = Get-ChildItem -LiteralPath $drive -Filter 'manjaro*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($iso) { Ok "U 盘里已有镜像 $($iso.Name)" }
  else {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Manjaro 镜像 (*.iso)|*.iso'; $dlg.InitialDirectory = (Join-Path $env:USERPROFILE 'Downloads')
    if ($dlg.ShowDialog() -eq 'OK') {
      Say "复制镜像到 U 盘（约 4GB，需要几分钟）……"
      Copy-Item -LiteralPath $dlg.FileName -Destination $drive
      Ok '镜像已复制'
    } else { Warn '没有选择镜像，跳过' }
  }

  Say '复制 linux-for-chromebook 工具到 U 盘'
  & robocopy.exe $RepoDir (Join-Path $drive 'linux-for-chromebook') /E /XD .git /NJH /NJS /NDL /NC /NS | Out-Null
  Ok "已复制到 ${drive}linux-for-chromebook"

  $p = @(Get-Packages)
  if ($p.Count -and (Read-Host '把迁移包也复制到 U 盘？（不复制也可以安装时通过局域网获取）(y/N)') -match '^[Yy]') {
    $pk = Select-Package
    if ($pk) {
      $big = Get-ChildItem -LiteralPath $pk.FullName -Recurse -File | Where-Object { $_.Length -ge 4GB }
      if ($v.FileSystem -eq 'FAT32' -and $big) { Warn '迁移包里有超过 4G 的文件，FAT32 U 盘放不下，请改用局域网传输' }
      else {
        & robocopy.exe $pk.FullName (Join-Path $drive "l4c-backups\$($pk.Name)") /E /NJH /NJS /NDL /NC /NS | Out-Null
        Ok '迁移包已复制'
      }
    }
  }
  Write-Host @"

  U 盘准备好了。接下来在 Chromebook 上：
    1. 插入 U 盘，开机时按 Esc 选择 U 盘启动，在 Ventoy 菜单里选 Manjaro
    2. 进入桌面后连接 Wi-Fi，打开终端，输入：
         sudo bash /run/media/manjaro/Ventoy/linux-for-chromebook/install/install.sh
       （U 盘名称不是 Ventoy 时，把路径里的 Ventoy 换成 U 盘名称）
    3. 按提示选择迁移包来源：U 盘上的迁移包，或「w) 从 Windows 电脑获取」
"@
}

# ---------------------------------------------------------- 主菜单 ------
while ($true) {
  Clear-Host
  Write-Host ''
  Write-Host '  ┌───────────────────────────────────────────────┐' -ForegroundColor Cyan
  Write-Host '  │   linux-for-chromebook Windows 工具           │' -ForegroundColor Cyan
  Write-Host '  └───────────────────────────────────────────────┘' -ForegroundColor Cyan
  Write-Host "  迁移包保存位置：$Root"
  Write-Host ''
  Write-Host '  1) 启动传输服务（局域网接收 Chromebook 数据 / 安装时回传）'
  Write-Host '  2) 从 U 盘导入迁移包到这台电脑'
  Write-Host '  3) 校验迁移包'
  Write-Host '  4) 转换：把 Windows 的 Wi-Fi、文件夹加入迁移包'
  Write-Host '  5) 在 Windows 上浏览迁移包里的文件'
  Write-Host '  6) 制作 Chromebook 安装 U 盘'
  Write-Host '  7) 打开迁移包所在文件夹'
  Write-Host '  0) 退出'
  Write-Host ''
  $c = Read-Host '请选择'
  try {
    switch ($c) {
      '1' { Start-TransferServer; Pause-Key }
      '2' { Import-FromUsb; Pause-Key }
      '3' { $p = Select-Package; if ($p) { Show-PackageInfo $p.FullName; Test-Package $p.FullName | Out-Null }; Pause-Key }
      '4' { Invoke-Convert; Pause-Key }
      '5' { Open-PackageFiles; Pause-Key }
      '6' { New-InstallUsb; Pause-Key }
      '7' { Start-Process explorer.exe $Root }
      '0' { exit }
    }
  } catch {
    Warn "出错：$($_.Exception.Message)"
    Pause-Key
  }
}
