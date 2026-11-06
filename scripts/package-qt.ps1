# ---------------------------------------------------------------------------
# package-qt.ps1 — 把静态安装目录打成一个可分发的 7z 包
#
# 用法: ./scripts/package-qt.ps1 -Prefix D:\Qt\6.5.3\..._static -Version 6.5.3 `
#          -Arch win64_msvc2019_64 -Vcvars 142 -Crt mt -OutDir D:\staging
#
# 产物命名: qt-<ver>-static-<arch>-<crt>-windows-x64.7z
#   例:      qt-6.5.3-static-win64_msvc2019_64-mt-windows-x64.7z
#
# 打包前的取舍：
#   * 删掉 .pdb —— 静态 Qt 的 pdb 动辄几个 GB，对绝大多数使用者没价值；
#   * 删掉 src / 构建中间物 —— prefix 里本来不该有，保险起见清一遍；
#   * 保留 bin/*.exe 工具（moc/rcc/uic/qmake），下游 qmake 工程需要；
#   * 保留 mkspecs 与 .prl，否则 qmake 工程无法正确链接。
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Prefix,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][string] $Arch,
    [string] $Vcvars = '143',
    [string] $Crt = 'mt',
    [Parameter(Mandatory = $true)][string] $OutDir,
    [switch] $KeepPdb
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$crtTag = if ($Crt -eq 'mt' -or $Crt -eq 'ON') { 'mt' } else { 'md' }
$baseName = 'qt-{0}-static-{1}-{2}-windows-x64' -f $Version, $Arch, $crtTag
$archive = Join-Path $OutDir ($baseName + '.7z')

Write-Host "== 打包 Qt $Version ($Arch, CRT=$crtTag) =="

# ---------------------------------------------------------------------------
# 1) 清理无关文件
# ---------------------------------------------------------------------------
if (-not $KeepPdb) {
    $pdbs = Get-ChildItem $Prefix -Recurse -Filter '*.pdb' -ErrorAction SilentlyContinue -File
    if ($pdbs.Count -gt 0) {
        $savedMB = ($pdbs | Measure-Object -Property Length -Sum).Sum / 1MB
        Write-Host ("删除 {0} 个 .pdb，节省 {1:n0} MB" -f $pdbs.Count, $savedMB)
        $pdbs | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

foreach ($junk in @('src', '.git', 'doc')) {
    $p = Join-Path $Prefix $junk
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 2) 写一份构建信息，方便使用者核对
# ---------------------------------------------------------------------------
$info = @(
    "qt_version = $Version"
    "arch       = $Arch"
    "static     = true"
    "runtime    = $crtTag"
    "toolset    = v$Vcvars"
    "built_at   = $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "built_on   = $env:RUNNER_NAME"
    "commit     = $env:GITHUB_SHA"
) -join "`r`n"
Set-Content -Path (Join-Path $Prefix 'BUILDINFO.txt') -Value $info -Encoding utf8

# ---------------------------------------------------------------------------
# 3) 用 7z 压缩
# ---------------------------------------------------------------------------
$sevenZip = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenZip) {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { $sevenZip = $cmd.Source }
}
if (-not $sevenZip) { throw '未找到 7z.exe' }

$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "压缩中 -> $archive"
# -mx=9 太慢，静态 Qt 体积大，mx=7 性价比最好；-mmt=on 用满核
& $sevenZip a $archive ($Prefix + '\*') -mx=7 -mmt=on -bso0 -bsp0 -y
if ($LASTEXITCODE -ne 0) { throw "7z 压缩失败 (exit $LASTEXITCODE)" }
$sw.Stop()

$archiveItem = Get-Item $archive
Write-Host ("完成: {0}  ({1:n1} MB, 用时 {2:n1} 分钟)" -f $archiveItem.FullName, ($archiveItem.Length / 1MB), $sw.Elapsed.TotalMinutes)

# ---------------------------------------------------------------------------
# 4) 生成 sha256，供 release 页面校验
# ---------------------------------------------------------------------------
$hash = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLower()
$sumLine = '{0}  {1}' -f $hash, $archiveItem.Name
Write-Host $sumLine
Set-Content -Path (Join-Path $OutDir ($baseName + '.sha256')) -Value $sumLine -Encoding ascii

# 供 workflow 后续步骤引用
if ($env:GITHUB_ENV) {
    ("QT_ARCHIVE_NAME={0}" -f $archiveItem.Name) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
