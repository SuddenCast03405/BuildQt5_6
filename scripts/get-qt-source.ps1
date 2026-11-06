# ---------------------------------------------------------------------------
# get-qt-source.ps1 — 取指定版本的 Qt 源码，解压到 -Dest（-Dest 下直接是 qtbase/ ...）
#
# 用法:
#   ./scripts/get-qt-source.ps1 -Version 6.5.3    -Dest C:\qt-src -Repo official
#   ./scripts/get-qt-source.ps1 -Version 5.12.12  -Dest C:\qt-src -Exclude qtwebengine,qtwebview
#
# 源码来源按版本分流（2026-11 实测，别凭印象改）：
#   * 5.12.x : 只在 qtsdkrepository 有，而且是「一个模块一个 7z」的拆分包，没有 everywhere
#              整树包；download.qt.io/archive 与各镜像站都已下架 5.12 的单包
#   * 5.15 / 6.2 / 6.5 / 6.8 : download.qt.io/archive/qt/<series>/<ver>/single/*.tar.xz
#   * 6.10+  : download.qt.io/official_releases/qt/<series>/<ver>/single/*.tar.xz
#              （老版本被 Qt 从 official_releases 清理掉了）
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][string] $Dest,
    [ValidateSet('official', 'mirrors')][string] $Repo = 'official',
    # 逗号分隔的模块名，5.12 的拆分包模式下用来少下载几个模块（单包模式忽略）
    [string] $Exclude = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BaseMap = @{
    official = @{
        Qtsdk = 'https://download.qt.io/online/qtsdkrepository/windows_x86/desktop'
        Arch  = 'https://download.qt.io/archive/qt'
        Rel   = 'https://download.qt.io/official_releases/qt'
    }
    mirrors  = @{
        Qtsdk = 'https://mirrors.tuna.tsinghua.edu.cn/qt/online/qtsdkrepository/windows_x86/desktop'
        Arch  = 'https://mirrors.tuna.tsinghua.edu.cn/qt/archive/qt'
        Rel   = 'https://mirrors.tuna.tsinghua.edu.cn/qt/official_releases/qt'
    }
}
$Base = $BaseMap[$Repo]

$vParts = $Version -split '\.'
if ($vParts.Length -lt 3) { throw "版本号格式不对: $Version（需要 x.y.z）" }
$Major = [int]$vParts[0]
$Series = '{0}.{1}' -f $vParts[0], $vParts[1]

$ExcludeList = @($Exclude -split '[,;\s]+' | Where-Object { $_ })

# qtsdkrepository 目录名 = "qt" + major + "_" + (major/minor/patch 三段连写)
#   5.12.12 -> qt5_51212 ; 6.12.0 -> qt6_6120
function Get-SdkTag([string] $Ver) {
    $p = $Ver -split '\.'
    return ('{0}_{0}{1}{2}' -f $p[0], $p[1], $p[2])
}

function Expand-SevenZip([string] $Archive, [string] $Target) {
    $sevenZip = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sevenZip) {
        $cmd = Get-Command 7z -ErrorAction SilentlyContinue
        if ($cmd) { $sevenZip = $cmd.Source }
    }
    if (-not $sevenZip) { throw '未找到 7z.exe（windows runner 上应已预装 7-Zip）' }
    & $sevenZip x $Archive ("-o" + $Target) -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw "7z 解压失败: $Archive (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# 0) 准备目录
# ---------------------------------------------------------------------------
if (Test-Path $Dest) {
    Write-Host "清理已存在的目录 $Dest"
    Remove-Item -Path $Dest -Recurse -Force
}
New-Item -ItemType Directory -Path $Dest -Force | Out-Null

$Work = Join-Path $env:RUNNER_TEMP 'qt-src-download'
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$Stage = Join-Path $Work 'stage'
if (Test-Path $Stage) { Remove-Item -Path $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

$sw = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# 1) 5.12：qtsdkrepository 的「每模块一个 7z」拆分包
# ---------------------------------------------------------------------------
if ($Major -eq 5 -and $Series -eq '5.12') {
    $Tag = Get-SdkTag $Version                        # 5_51212
    # 包名保留完整数字串（含 major 的重复）：qt.qt5.51212.src
    $PkgVer = ($Tag -split '_')[1]
    $PkgRoot = '{0}/qt{1}_src_doc_examples/qt.qt{2}.{3}.src' -f $Base.Qtsdk, $Tag, $Major, $PkgVer
    Write-Host "qtsdk 源码包目录: $PkgRoot"

    $index = Invoke-WebRequest -Uri $PkgRoot -UseBasicParsing -TimeoutSec 120
    $archives = @()
    foreach ($link in $index.Links) {
        $href = $link.href
        if ($href -match '\.7z$') { $archives += $href }
    }
    if ($archives.Count -eq 0) { throw "在 $PkgRoot 下没有找到任何 .7z" }
    Write-Host ("目录下共 {0} 个包，按模块名筛选" -f $archives.Count)

    # 文件名形如 5.12.12-0-202111241638qtbase-everywhere-src-5.12.12.7z
    #   "^[0-9.]+-\d+-<14位时间戳><模块名>-everywhere-src-<版本>.7z"
    $got = 0
    foreach ($a in $archives) {
        $name = Split-Path $a -Leaf
        $m = [regex]::Match($name, '-([0-9]{6,})(qt[a-z0-9]+)-everywhere-src-')
        if (-not $m.Success) { continue }             # meta.7z 之类，跳过
        $mod = $m.Groups[2].Value

        if ($ExcludeList -contains $mod) {
            Write-Host "  跳过 $mod（-Exclude）"
            continue
        }

        $local = Join-Path $Work $name
        if (-not (Test-Path $local)) {
            $url = '{0}/{1}' -f $PkgRoot, $name
            Write-Host "下载 $name"
            Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -TimeoutSec 3600
        }
        Expand-SevenZip $local $Stage
        $got++
    }
    if ($got -eq 0) { throw '没有下载到任何模块源码包（检查 -Exclude 是否把 qtbase 也排除了）' }
    Write-Host ("解压了 {0} 个模块包" -f $got)
}
# ---------------------------------------------------------------------------
# 2) 其它版本：整树单包（tar.xz）
# ---------------------------------------------------------------------------
else {
    $useRel = $false
    if ($Major -ge 6) {
        $mm = [int]$vParts[1]
        if ($mm -ge 10) { $useRel = $true }
    }

    $fileName = 'qt-everywhere-src-{0}.tar.xz' -f $Version
    $candidates = @()
    if ($useRel) {
        $candidates += '{0}/{1}/{2}/single/{3}' -f $Base.Rel, $Series, $Version, $fileName
    }
    else {
        $candidates += '{0}/{1}/{2}/single/{3}' -f $Base.Arch, $Series, $Version, $fileName
        $candidates += '{0}/{1}/{2}/single/{3}' -f $Base.Rel, $Series, $Version, $fileName
    }

    $local = Join-Path $Work $fileName
    $ok = $false
    foreach ($url in $candidates) {
        if (Test-Path $local) { Remove-Item $local -Force }
        try {
            Write-Host "下载 $url"
            Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -TimeoutSec 7200
            if ((Get-Item $local).Length -gt 10MB) { $ok = $true; break }
            Write-Host '  文件过小，视为失败'
        }
        catch {
            Write-Host ('  失败: {0}' -f $_.Exception.Message)
        }
    }
    if (-not $ok) { throw "无法下载 Qt $Version 源码（尝试过: $($candidates -join ' | ')）" }

    Write-Host ("解压 {0}（{1:n1} MB）" -f $fileName, ((Get-Item $local).Length / 1MB))
    & tar -xf $local -C $Stage                # windows runner 自带 bsdtar
    if ($LASTEXITCODE -ne 0) { throw "tar 解压失败 (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# 3) 归位：把「qtbase 所在目录」下的所有模块铺到 -Dest
#    实际遇到的两种布局：
#      整树 tar.xz : stage/qt-everywhere-src-6.5.3/{qtbase,qtdeclarative,...}
#      5.12 拆分包 : stage/5.12.12/Src/{qtbase,...}   （每个模块包都解到同一层，天然合并）
# ---------------------------------------------------------------------------
$qtbaseDir = Get-ChildItem $Stage -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'qtbase' } | Select-Object -First 1
if (-not $qtbaseDir) { throw "解压后在 $Stage 下找不到 qtbase 目录（源码包结构可能变了）" }

$realRoot = $qtbaseDir.Parent.FullName
Write-Host ("源码根目录: {0}" -f $realRoot)

foreach ($item in Get-ChildItem $realRoot) {
    Move-Item -Path $item.FullName -Destination $Dest -Force
}

# ---------------------------------------------------------------------------
# 4) 校验源码结构
# ---------------------------------------------------------------------------
$qtbase = Join-Path $Dest 'qtbase'
if (-not (Test-Path $qtbase)) { throw "源码结构不对，缺少 qtbase：$Dest" }

$topConfigure = Join-Path $Dest 'configure.bat'
$qtbaseConfigure = Join-Path $qtbase 'configure.bat'
if (Test-Path $topConfigure) {
    Write-Host '源码形态: 整树包（顶层有 configure.bat）'
}
elseif (Test-Path $qtbaseConfigure) {
    Write-Host '源码形态: 模块拆分树（configure.bat 在 qtbase/ 下，需要逐模块构建）'
}
else {
    throw "源码里没有 configure.bat：$Dest"
}

$moduleDirs = @(Get-ChildItem $Dest -Directory | Where-Object {
    $_.Name -ne 'qtbase' -and (Test-Path (Join-Path $_.FullName '.qmake.conf'))
})
Write-Host ("识别到 {0} 个可构建模块" -f $moduleDirs.Count)
Write-Host ("模块: " + (($moduleDirs | ForEach-Object { $_.Name }) -join ', '))

$sw.Stop()
Write-Host ("源码就绪: {0}  用时 {1:n1} 分钟" -f $Dest, $sw.Elapsed.TotalMinutes)
Write-Host ("总大小 {0:n0} MB" -f ((Get-ChildItem $Dest -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB))
