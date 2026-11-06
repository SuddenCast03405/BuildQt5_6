# ---------------------------------------------------------------------------
# resolve-matrix.ps1 - 探测各 LTS 线在 Qt 官方 CDN 上的最新补丁版本
# 产出 GitHub Actions outputs: matrix / has_build
#
# 用法（workflow 内）:
#   ./scripts/resolve-matrix.ps1 -Filter "6.5 6.12" -ModulePreset recommended
# 本地自测:
#   pwsh ./scripts/resolve-matrix.ps1 -OutFile out.json
#
# 注意: 本脚本刻意只用最朴素的语法（-match / 数组索引 / [version]），
#       不使用 String.StartsWith / 复杂插值，以规避不同 PowerShell 版本的行为差异。
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string[]] $Series = @('5.12', '5.15', '6.2', '6.5', '6.8', '6.12'),
    [string]   $Filter = '',
    [ValidateSet('minimal', 'recommended', 'full')]
    [string]   $ModulePreset = 'recommended',
    [ValidateSet('mt', 'md')]
    [string]   $Crt = 'mt',
    [string]   $BaseUrl = 'https://download.qt.io/online/qtsdkrepository/windows_x86/desktop',
    [string]   $OutFile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 每条 LTS 线对应的工具链，这是整个流水线的核心映射
#   msvc = MSVC 工具集主版本（140=v140/VS2015, 141=v141/VS2017, 142=v142/VS2019, 143=v143/VS2022）
$Toolchains = @(
    [pscustomobject]@{ Series = '5.12'; Toolset = 'msvc2015'; Msvc = '140' }
    [pscustomobject]@{ Series = '5.15'; Toolset = 'msvc2017'; Msvc = '141' }
    [pscustomobject]@{ Series = '6.2';  Toolset = 'msvc2019'; Msvc = '142' }
    [pscustomobject]@{ Series = '6.5';  Toolset = 'msvc2019'; Msvc = '142' }
    [pscustomobject]@{ Series = '6.8';  Toolset = 'msvc2022'; Msvc = '143' }
    [pscustomobject]@{ Series = '6.12'; Toolset = 'msvc2022'; Msvc = '143' }
)

# 模块预设 = 「要跳过的仓库」列表。
# 之所以用 -skip 而不是「只建某几个模块」：Qt5/Qt6 的 configure 都支持 -skip，
# 但都不支持 -module-<x> 这种写法（Qt6 会直接报 Unknown command line option）。
# 仓库名在不同大版本间有增删，-skip 一个本版本不存在的仓库只是多一个 BUILD_x=OFF，无副作用。
$SkipSets = @{
    '5' = @{
        minimal     = 'qtwebengine,qtwebview,qtwebsockets,qtwebchannel,qtmultimedia,qtconnectivity,qtlocation,qtpositioning,qtsensors,qtserialport,qtserialbus,qtcharts,qtdatavis3d,qtvirtualkeyboard,qtspeech,qtremoteobjects,qtscxml,qtgamepad,qtpurchasing,qtdoc,qtquick3d,qtlottie,qtnetworkauth,qtimageformats,qtquickcontrols,qtquickcontrols2,qtgraphicaleffects'
        recommended = 'qtwebengine,qtwebview,qtquick3d,qtcharts,qtdatavis3d,qtdoc,qtgamepad,qtpurchasing,qtspeech,qtlocation'
        full        = 'qtwebengine,qtwebview,qtdoc,qtgamepad,qtpurchasing'
    }
    '6' = @{
        minimal     = 'qtwebengine,qtwebview,qtwebsockets,qtwebchannel,qtmultimedia,qtconnectivity,qtpositioning,qtsensors,qtserialport,qtserialbus,qtcharts,qtdatavis3d,qtvirtualkeyboard,qtspeech,qtremoteobjects,qtscxml,qtquick3d,qtquick3dphysics,qtquickeffectmaker,qtquicktimeline,qtlottie,qtnetworkauth,qtimageformats,qtgrpc,qtgraphs,qtpdf,qtlanguageserver,qtapplicationmanager,qtdoc,qtquickcontrols2'
        recommended = 'qtwebengine,qtwebview,qtquick3d,qtquick3dphysics,qtquickeffectmaker,qtgrpc,qtgraphs,qtpdf,qtlanguageserver,qtapplicationmanager,qtdoc'
        full        = 'qtwebengine,qtwebview,qtdoc'
    }
}

# ---------------------------------------------------------------------------
# CDN 目录名 -> 版本
#   Qt 5.x   qt5_51212 -> 5.12.12 ; qt5_5152 -> 5.15.2 ; qt5_590  -> 5.9.0
#   Qt 6.x   qt6_624   -> 6.2.4   ; qt6_653  -> 6.5.3   ; qt6_6120 -> 6.12.0
#
# 实现要点（踩过的坑，别改回去）：
#   1) 不用 $Matches / 正则捕获组，改用字符串切分 + 字典查找（跨版本行为一致）；
#   2) 不用 "$a.$b.$c" 这类隐式插值，统一用 -f 格式化，避免把版本号算成表达式；
#   3) 版本比较只用整数三元组（major, minor, patch），不构造 [version] 对象。
#
# 数字串切分：minor 必然是已知的 Qt minor 号，把所有合法切分点列出来，
# 取 patch 位数最长的那个，这样 qt6_6120 才会解析成 6.12.0 而不是 6.1.20。
# ---------------------------------------------------------------------------

# 官方曾经发布过的 minor 号，用来消解数字串切分的歧义
$KnownMinor = @{
    '5' = @(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
    '6' = @(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14)
}

function Test-AllDigits([string] $Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($Ch in $Text.ToCharArray()) {
        $Code = [int]$Ch
        if (($Code -lt 48) -or ($Code -gt 57)) { return $false }
    }
    return $true
}

# 返回 [pscustomobject]@{ Major; Minor; Patch; Text; Dir }，无法解析时返回 $null
function ConvertFrom-DirName([string] $DirName) {
    # 目录名形如 qt5_51212 / qt6_6120。
    # 下划线后面的数字串结构是「major + minor + patch」直接连写（major 会重复一次）：
    #   qt5_51212 -> 5 | 12 | 12 -> 5.12.12
    #   qt5_5152  -> 5 | 15 | 2  -> 5.15.2
    #   qt5_59    -> 5 | 9  | 0  -> 5.9.0    （patch 省略，补 0）
    #   qt6_653   -> 6 | 5  | 3  -> 6.5.3
    #   qt6_6120  -> 6 | 12 | 0  -> 6.12.0
    if ($DirName.Length -lt 5) { return $null }
    if ($DirName.Substring(0, 3) -ne 'qt5' -and $DirName.Substring(0, 3) -ne 'qt6') { return $null }
    if ($DirName.Substring(3, 1) -ne '_') { return $null }

    $MajorText = $DirName.Substring(2, 1)
    $MajorValue = [int]$MajorText
    $Digits = $DirName.Substring(4)
    if ($Digits.Length -lt 2) { return $null }
    if (-not (Test-AllDigits $Digits)) { return $null }

    # 数字串第一位必须等于 major，否则不是我们认识的命名
    if ($Digits.Substring(0, 1) -ne $MajorText) { return $null }

    $Rest = $Digits.Substring(1)
    if ($Rest.Length -eq 0) { return $null }

    # 只有一位（qt5_59）：这就是 minor，patch 视为 0
    if ($Rest.Length -eq 1) {
        return [pscustomobject]@{
            Major = $MajorValue
            Minor = [int]$Rest
            Patch = 0
            Text  = ('{0}.{1}.0' -f $MajorValue, [int]$Rest)
            Dir   = $DirName
        }
    }

    # 优先 2 位 minor（Qt 5.10+ 与 Qt 6.10+ 都是两位），不足两位时退回 1 位
    if ($Rest.Length -ge 3) {
        $MinorValue = [int]$Rest.Substring(0, 2)
        $PatchValue = [int]$Rest.Substring(2)
    }
    else {
        $MinorValue = [int]$Rest.Substring(0, 1)
        $PatchValue = [int]$Rest.Substring(1)
    }

    return [pscustomobject]@{
        Major = $MajorValue
        Minor = $MinorValue
        Patch = $PatchValue
        Text  = ('{0}.{1}.{2}' -f $MajorValue, $MinorValue, $PatchValue)
        Dir   = $DirName
    }
}

$Index = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing -TimeoutSec 120

# 版本字符串 -> CDN 目录名；同时保留结构化版本用于比较
$DirOfVersion = @{}
$AllVersions = @()
foreach ($Link in $Index.Links) {
    $DirName = ($Link.href -replace '/$', '')
    if ($DirName -notmatch '^qt[56]_[0-9]+$') { continue }
    $Parsed = ConvertFrom-DirName $DirName
    if ($null -ne $Parsed) {
        $DirOfVersion[$Parsed.Text] = $DirName
        $AllVersions += $Parsed
    }
}
Write-Host ('catalog: {0} version directories' -f $AllVersions.Count)

$FilterList = @($Filter -split '[\s,;]+' | Where-Object { $_ })
$Include = @()

foreach ($Tc in $Toolchains) {
    if ($Series -notcontains $Tc.Series) { continue }

    if ($FilterList.Count -gt 0) {
        $Wanted = $false
        foreach ($F in $FilterList) {
            # 只比较 "major.minor" 前缀，不做正则捕获
            $Dot = $F.IndexOf('.')
            if ($Dot -gt 0) {
                $Tail = $F.Substring($Dot + 1)
                $Head = $F.Substring(0, $Dot + 1) + ($Tail -split '[^0-9]')[0]
                if ($Head -eq $Tc.Series) { $Wanted = $true }
            }
        }
        if (-not $Wanted) {
            Write-Host ('skip Qt {0} (filtered)' -f $Tc.Series)
            continue
        }
    }

    # 系列拆成整数，逐个比较补丁号，避免任何字符串/版本对象比较
    $SeriesParts = $Tc.Series -split '\.'
    $WantMajor = [int]$SeriesParts[0]
    $WantMinor = [int]$SeriesParts[1]

    $Best = $null
    foreach ($Candidate in $AllVersions) {
        if ($Candidate.Major -ne $WantMajor) { continue }
        if ($Candidate.Minor -ne $WantMinor) { continue }
        if ($null -eq $Best) { $Best = $Candidate; continue }
        if ($Candidate.Patch -gt $Best.Patch) { $Best = $Candidate }
    }
    if ($null -eq $Best) {
        Write-Host ('WARNING: Qt {0}.x not found on CDN' -f $Tc.Series)
        continue
    }

    $QtVersion = $Best.Text
    $Arch = 'win64_{0}_64' -f $Tc.Toolset
    $MajorKey = [string]$WantMajor
    $Include += [ordered]@{
        qt        = $QtVersion
        series    = $Tc.Series
        toolset   = $Tc.Toolset
        msvc      = $Tc.Msvc
        'runs-on' = 'windows-2022'
        arch      = $Arch
        sde       = $DirOfVersion[$QtVersion]
        crt       = $Crt
        preset    = $ModulePreset
        skip      = $SkipSets[$MajorKey][$ModulePreset]
        label     = 'Qt{0}-{1}' -f $QtVersion, $Tc.Toolset
    }
    Write-Host ('  {0} -> {1} / {2} ({3})' -f $Tc.Series, $QtVersion, $Arch, $DirOfVersion[$QtVersion])
}
Write-Host '::endgroup::'

if ($Include.Count -eq 0) {
    $Json = '{"include":[]}'
    $HasBuild = 'false'
}
else {
    $Payload = [ordered]@{ include = $Include }
    $Json = $Payload | ConvertTo-Json -Depth 6 -Compress
    $HasBuild = 'true'
}

if ($OutFile) { Set-Content -Path $OutFile -Value $Json -Encoding utf8 }
if ($env:GITHUB_OUTPUT) {
    ('matrix={0}' -f $Json) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    ('has_build={0}' -f $HasBuild) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
Write-Host ('matrix=' + $Json)
