# ---------------------------------------------------------------------------
# smoke-test.ps1 — 用一个最小 GUI 工程验证静态 Qt 真的能独立链接和运行
#
# 用法: ./scripts/smoke-test.ps1 -Prefix D:\Qt\6.5.3\..._static -Version 6.5.3 -Work D:\qtbuild\smoke
#
# 为什么必须做这一步：
#   configure / cmake --install 成功只说明库文件躺到了磁盘上。静态链接最容易出事的
#   地方恰恰是「下游工程真正链接时」：缺 zlib、缺 pcre、缺 windows 运行时、
#   .prl 指向错误路径。这里用一个带 Widgets 的小程序把它编出来跑一遍。
#
# 判定成功的标准：
#   * 编译 + 链接零错误
#   * 生成 exe
#   * exe 里没有 Qt6Core.dll / Qt5Core.dll 依赖（静态链接的铁证）
#   * exe 能启动并在无窗口环境下干净退出（用 -platform offscreen）
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Prefix,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][string] $Work
)

$ErrorActionPreference = 'Stop'

$isQt5 = $Version -match '^5\.'
Write-Host "== 静态链接自检 (Qt $Version) =="

if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory -Path $Work -Force | Out-Null

# ---------------------------------------------------------------------------
# 1) 生成最小工程
# ---------------------------------------------------------------------------
$cpp = @'
#include <QApplication>
#include <QLabel>
#include <QTimer>
#include <QTextStream>

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QLabel label(QStringLiteral("static-ok"));
    label.show();

    QTextStream out(stdout);
    out << "SMOKE_OK " << QT_VERSION_STR << "\n";
    out.flush();

    // 立即退出，不需要人工关窗
    QTimer::singleShot(0, &app, &QApplication::quit);
    return app.exec();
}
'@

# Qt5（尤其 5.12 + MSVC2015）不能开 c++17：msvc-version.conf 只在 19.13+ 才给
# -std:c++17，老工具集下 CONFIG+=c++17 会被忽略甚至报错，所以按大版本选标准。
$cxxStd = if ($isQt5) { 'c++14' } else { 'c++17' }
$pro = @"
QT += core gui widgets
CONFIG += console $cxxStd
CONFIG -= app_bundle
TARGET = smoke
TEMPLATE = app
SOURCES += main.cpp
"@

Set-Content -Path (Join-Path $Work 'main.cpp') -Value $cpp -Encoding utf8
Set-Content -Path (Join-Path $Work 'smoke.pro') -Value $pro -Encoding utf8

# ---------------------------------------------------------------------------
# 2) qmake + nmake
# ---------------------------------------------------------------------------
$qmake = Join-Path $Prefix 'bin\qmake.exe'
if (-not (Test-Path $qmake)) { throw "找不到 qmake: $qmake" }

Push-Location $Work
try {
    Write-Host '-- qmake --'
    & $qmake 'smoke.pro' 'CONFIG+=release'
    if ($LASTEXITCODE -ne 0) { throw "qmake 失败 (exit $LASTEXITCODE)" }

    # 生成的是 nmake 工程（mkspec 为 win32-msvc*）
    $makeProg = 'nmake'
    if (-not (Get-Command $makeProg -ErrorAction SilentlyContinue)) {
        $makeProg = 'jom'
    }
    Write-Host "-- $makeProg --"
    & $makeProg /NOLOGO 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$makeProg 失败 (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$exe = Join-Path $Work 'release\smoke.exe'
if (-not (Test-Path $exe)) {
    $exe = Join-Path $Work 'smoke.exe'
}
if (-not (Test-Path $exe)) { throw "没有生成 smoke.exe" }
Write-Host ("生成: {0}  ({1:n2} MB)" -f $exe, ((Get-Item $exe).Length / 1MB))

# ---------------------------------------------------------------------------
# 3) 确认没有动态 Qt 依赖
# ---------------------------------------------------------------------------
$libBase = if ($isQt5) { 'Qt5Core' } else { 'Qt6Core' }
Write-Host "-- 检查导入表里是否有 $libBase.dll --"
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbin) {
    $imports = (& dumpbin.exe /DEPENDENTS $exe 2>&1) -join "`n"
    if ($imports -match [regex]::Escape($libBase + '.dll')) {
        throw "smoke.exe 仍然依赖 $libBase.dll —— 这不是静态链接的产物"
    }
    Write-Host "  [OK] 导入表中没有 $libBase.dll"
    # 顺便确认 MSVCRT 依赖：静态 CRT 时应只有 api-ms-win-crt-* 或没有 ucrtbase
    if ($imports -match 'VCRUNTIME\d+\.dll') {
        Write-Warning 'smoke.exe 依赖 VCRUNTIME*.dll（如果目标是静态 CRT，说明 /MT 没生效）'
    }
}
else {
    Write-Warning '未找到 dumpbin，跳过导入表检查'
}

# ---------------------------------------------------------------------------
# 4) 真正运行一次（offscreen 平台插件，无需显示器）
# ---------------------------------------------------------------------------
Write-Host '-- 运行 smoke.exe --'
$outFile = Join-Path $Work 'run.out'
$errFile = Join-Path $Work 'run.err'
$p = Start-Process -FilePath $exe `
    -ArgumentList @('-platform', 'offscreen') `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
$stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
Write-Host "stdout: $stdout"
if ($stderr) { Write-Host "stderr: $stderr" }

if ($p.ExitCode -ne 0) {
    throw "smoke.exe 退出码 $($p.ExitCode)（静态链接成功但运行时失败，通常是缺插件或 CRT 不匹配）"
}
if ($stdout -notmatch 'SMOKE_OK') {
    throw "smoke.exe 没有输出 SMOKE_OK，输出为: $stdout"
}

Write-Host ''
Write-Host '静态链接自检通过。'
