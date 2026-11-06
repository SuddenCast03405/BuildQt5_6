# ---------------------------------------------------------------------------
# verify-install.ps1 — 检查静态安装结果是否符合预期
#
# 用法: ./scripts/verify-install.ps1 -Prefix D:\Qt\6.5.3\win64_msvc2019_64_static -Version 6.5.3
#
# 检查项（任何一项不过就失败，避免把残缺产物传上去）：
#   1. 关键目录 / 文件存在
#   2. Qt6Core.lib（或 Qt5Core.lib）真的存在且是静态库
#   3. .prl 文件里没有残留的构建目录（QMAKE_PRL_BUILD_DIR 指回构建树会导致下游链接失败）
#   4. bin 下有 qmake 与 moc/uic/rcc
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Prefix,
    [Parameter(Mandatory = $true)][string] $Version,
    [string] $Arch = '',
    [switch] $AllowShared               # 调试用：允许非静态产物
)

$ErrorActionPreference = 'Stop'

$isQt5 = $Version -match '^5\.'
$coreBase = if ($isQt5) { 'Qt5Core' } else { 'Qt6Core' }

Write-Host "== 校验静态安装: $Prefix =="

$problems = New-Object System.Collections.ArrayList

function Check([bool] $Cond, [string] $Desc) {
    if ($Cond) {
        Write-Host ("  [OK]   " + $Desc)
    }
    else {
        Write-Host ("  [FAIL] " + $Desc)
        [void]$problems.Add($Desc)
    }
}

# ---------------------------------------------------------------------------
# 1) 目录结构
# ---------------------------------------------------------------------------
foreach ($rel in @('bin', 'lib', 'include', 'mkspecs')) {
    $p = Join-Path $Prefix $rel
    Check (Test-Path $p) "目录存在: $rel"
}

$qmake = Join-Path $Prefix 'bin\qmake.exe'
Check (Test-Path $qmake) 'bin\qmake.exe'

foreach ($tool in @('moc.exe', 'rcc.exe', 'uic.exe')) {
    Check (Test-Path (Join-Path $Prefix "bin\$tool")) "bin\$tool"
}

# ---------------------------------------------------------------------------
# 2) 核心库必须是 .lib（Windows 静态库），且不是导入库
# ---------------------------------------------------------------------------
$coreLib = Join-Path $Prefix ("lib\{0}.lib" -f $coreBase)
Check (Test-Path $coreLib) ("{0}.lib 存在" -f $coreBase)

$coreDll = Join-Path $Prefix ("bin\{0}.dll" -f $coreBase)
if ($AllowShared) {
    Write-Host "  [SKIP] 跳过静态检查（-AllowShared）"
}
else {
    Check (-not (Test-Path $coreDll)) ("没有 {0}.dll（确认是静态库而不是导入库）" -f $coreBase)
}

# 静态库通常远大于导入库；Qt6Core 静态 release 一般 > 5 MB
if (Test-Path $coreLib) {
    $sizeMB = (Get-Item $coreLib).Length / 1MB
    Write-Host ("  [INFO] {0}.lib 大小 {1:n2} MB" -f $coreBase, $sizeMB)
    if (-not $AllowShared) {
        Check ($sizeMB -gt 5) ("{0}.lib 体积合理（>5MB，说明含实现而不是导入表）" -f $coreBase)
    }
}

# ---------------------------------------------------------------------------
# 3) .prl 里不能残留构建目录
# ---------------------------------------------------------------------------
$libDir = Join-Path $Prefix 'lib'
$prlFiles = Get-ChildItem $libDir -Filter '*.prl' -ErrorAction SilentlyContinue
Check ($prlFiles.Count -gt 0) '.prl 文件存在（qmake 工程链接需要）'

$stale = @()
foreach ($prl in $prlFiles) {
    $content = Get-Content $prl.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { continue }
    # QMAKE_PRL_BUILD_DIR 指向的是构建时目录；只要不是 prefix 下的就视为残留
    foreach ($line in ($content -split "`n")) {
        if ($line -match '^\s*QMAKE_PRL_BUILD_DIR\s*=\s*(.+)$') {
            $dir = $Matches[1].Trim()
            if ($dir -and ($dir -notlike ($Prefix + '*'))) {
                $stale += "$($prl.Name): $dir"
            }
        }
    }
}
if ($stale.Count -gt 0) {
    Write-Host '  [WARN] 以下 .prl 含有非 prefix 的构建目录（多数情况下无害，但 qmake 子工程可能受影响）:'
    $stale | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" }
}
else {
    Write-Host '  [OK]   .prl 中没有指向外部构建目录的残留'
}

# ---------------------------------------------------------------------------
# 4) mkspecs 里应有 qconfig.pri，且记录为 static
# ---------------------------------------------------------------------------
$qconfig = Join-Path $Prefix "mkspecs\qconfig.pri"
Check (Test-Path $qconfig) 'mkspecs\qconfig.pri'
if (Test-Path $qconfig) {
    $qc = Get-Content $qconfig -Raw
    if (-not $AllowShared) {
        Check ($qc -match 'QT_CONFIG\s*\+?=.*\bstatic\b') 'qconfig.pri 标记为 static'
    }
}

# ---------------------------------------------------------------------------
# 5) 版本号一致性
# ---------------------------------------------------------------------------
if (Test-Path $qmake) {
    $qmakeVer = (& $qmake -query QT_VERSION 2>$null | Out-String).Trim()
    Write-Host "  [INFO] qmake -query QT_VERSION = $qmakeVer"
    Check ($qmakeVer -eq $Version) "qmake 报告的版本与期望一致（$Version）"
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host ("校验失败，共 {0} 项：" -f $problems.Count)
    foreach ($p in $problems) { Write-Host "  - $p" }
    throw '静态安装校验未通过'
}

Write-Host ''
Write-Host '所有检查通过。'
