# ---------------------------------------------------------------------------
# setup-msvc.ps1 — 在 windows-2022 runner 上激活指定版本的 MSVC 工具集
#
# 用法:
#   ./scripts/setup-msvc.ps1 -MsvcVersion 143 -Arch amd64
#   ./scripts/setup-msvc.ps1 -MsvcVersion 141 -Arch amd64 -Strict
#
# 设计要点:
#   * vcvarsall 的 -vcvars_ver 只认 "14.0 / 14.16 / 14.29 / 14.3x" 这种写法，
#     传 "140"/"141" 会匹配不到并**静默退回默认工具集**——所以这里做真实探测：
#     激活后读 VCToolsVersion，反推实际工具集，跟请求值比对。
#   * windows-2022 镜像只预装 v142/v143；v140/v141 需要额外装组件（或自托管 runner）。
#     找不到时默认回退到「更高一档」的工具集并打 ::warning::（MSVC v140~v143 的
#     C++ ABI 是兼容的），加 -Strict 则直接失败，绝不静默。
#   * 不同 step 之间 shell 环境不继承，激活后的环境写进 GITHUB_ENV。
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string] $MsvcVersion = '143',                     # 140 / 141 / 142 / 143
    [ValidateSet('amd64', 'x86', 'amd64_x86', 'x86_amd64')]
    [string] $Arch = 'amd64',
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 请求值 -> vcvarsall 的 -vcvars_ver 写法
$VcVarsVer = @{
    '140' = '14.0'
    '141' = '14.16'
    '142' = '14.29'
    '143' = '14.3'
}
if (-not $VcVarsVer.ContainsKey($MsvcVersion)) {
    throw "不支持的 -MsvcVersion: $MsvcVersion（可选 140/141/142/143）"
}
$WantVer = $VcVarsVer[$MsvcVersion]
$Order = @('140', '141', '142', '143')

Write-Host "== 请求 MSVC v$MsvcVersion ($Arch, vcvars_ver=$WantVer) =="

# ---------------------------------------------------------------------------
# 1) 枚举所有带 VC++ 工具的 VS 安装
# ---------------------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe 不存在：$vswhere" }

$installations = @()
$raw = & $vswhere -all -prerelease -products * -property installationPath 2>$null
foreach ($line in $raw) {
    $p = $line.Trim()
    if ($p -and (Test-Path (Join-Path $p 'VC\Auxiliary\Build\vcvarsall.bat'))) {
        $installations += $p
    }
}
if ($installations.Count -eq 0) { throw '未找到任何带 VC++ 工具的 Visual Studio 安装' }
Write-Host '候选 VS 安装:'
foreach ($i in $installations) { Write-Host "  - $i" }

# ---------------------------------------------------------------------------
# 2) 探测每个安装能切到哪些工具集
#    vcvarsall 激活后 dump 环境，用 VCToolsVersion 反推真实工具集
# ---------------------------------------------------------------------------
function Get-ToolsetLabel([string] $ToolsVersion) {
    if ([string]::IsNullOrEmpty($ToolsVersion)) { return 'unknown' }
    $parts = $ToolsVersion -split '\.'
    if ($parts.Length -lt 2) { return 'unknown' }
    $head = '{0}.{1}' -f $parts[0], $parts[1]
    if ($head -match '^14\.0') { return '140' }
    if ($head -match '^14\.1') { return '141' }
    if ($head -match '^14\.2') { return '142' }
    if ($head -match '^14\.')  { return '143' }
    return 'unknown'
}

$found = @{}
foreach ($vsPath in $installations) {
    $vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
    $argSets = @(
        @($Arch, "-vcvars_ver=$WantVer"),
        @($Arch)                                   # 不带版本参数 = 该 VS 的默认工具集
    )
    foreach ($argSet in $argSets) {
        $argLine = $argSet -join ' '
        $envLines = cmd /c "call `"$vcvarsall`" $argLine >nul 2>&1 && set" 2>&1

        $envMap = @{}
        foreach ($el in $envLines) {
            if ($el -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $envMap[$Matches[1]] = $Matches[2] }
        }
        if (-not $envMap.ContainsKey('VCToolsVersion')) { continue }

        $label = Get-ToolsetLabel $envMap['VCToolsVersion']
        Write-Host ("  探测 {0} [{1}] -> VCToolsVersion={2} => v{3}" -f $vsPath, $argLine, $envMap['VCToolsVersion'], $label)
        if ($label -eq 'unknown') { continue }
        if ($found.ContainsKey($label)) { continue }
        $found[$label] = [pscustomobject]@{
            Path    = $vsPath
            ArgLine = $argLine
            Env     = $envMap
        }
    }
}

if ($found.Count -eq 0) {
    throw "没有任何可用的 MSVC 工具集（vcvarsall 探测全部失败）"
}
Write-Host ('可用工具集: ' + (($found.Keys | Sort-Object) -join ', '))

# ---------------------------------------------------------------------------
# 3) 选目标工具集；缺失时按需回退
# ---------------------------------------------------------------------------
$chosenLabel = $null
if ($found.ContainsKey($MsvcVersion)) {
    $chosenLabel = $MsvcVersion
}
elseif ($Strict) {
    throw "runner 上没有 MSVC v$MsvcVersion（可用: $(($found.Keys | Sort-Object) -join ', ')）。`n" +
          "windows-2022 托管镜像只预装 v142/v143；v140/v141 需要 `n" +
          "  * 自托管 runner 装 VS2015/VS2017，或 `n" +
          "  * 用 vs_buildtools 手工加装对应组件。`n" +
          "去掉 -Strict 可回退到更高一档工具集（ABI 兼容）。"
}
else {
    # 取「比请求值高、且最接近」的可用工具集
    foreach ($cand in $Order) {
        if ($found.ContainsKey($cand) -and ([array]::IndexOf($Order, $cand) -ge [array]::IndexOf($Order, $MsvcVersion))) {
            $chosenLabel = $cand
            break
        }
    }
}

if (-not $chosenLabel) {
    throw "没有可用工具集（请求 v$MsvcVersion，可用: $(($found.Keys | Sort-Object) -join ', ')）"
}

$chosen = $found[$chosenLabel]

if ($chosenLabel -ne $MsvcVersion) {
    Write-Host ("::warning::请求 MSVC v{0}，runner 上只有 v{1}，已回退。v140-v143 的 C++ ABI 兼容，" -f $MsvcVersion, $chosenLabel) `
        + "但产物应给同样工具集的工程使用；要严格匹配请用自托管 runner 并加 -Strict。"
}

Write-Host ("OK: 使用 {0}（vcvarsall {1}，VCToolsVersion={2} => v{3}）" -f $chosen.Path, $chosen.ArgLine, $chosen.Env['VCToolsVersion'], $chosenLabel)

# ---------------------------------------------------------------------------
# 4) 把激活后的环境变量透传给后续 step
# ---------------------------------------------------------------------------
$passKeys = @(
    'PATH', 'INCLUDE', 'LIB', 'LIBPATH',
    'VCINSTALLDIR', 'VCToolsInstallDir', 'VCToolsVersion', 'VCToolsRedistDir',
    'VSINSTALLDIR', 'WindowsSdkDir', 'WindowsSDKVersion', 'UniversalCRTSdkDir',
    'UCRTVersion', 'WindowsSdkBinPath', 'WindowsSdkLibPath',
    'VSCMD_ARG_TGT_ARCH', 'VSCMD_VER', 'Platform', 'PlatformToolset'
)
foreach ($k in $passKeys) {
    if ($chosen.Env.ContainsKey($k)) {
        ('{0}={1}' -f $k, $chosen.Env[$k]) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
('MSVC_REQUESTED={0}' -f $MsvcVersion)   | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
('MSVC_EFFECTIVE={0}' -f $chosenLabel)   | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
('MSVC_VS_PATH={0}'   -f $chosen.Path)   | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8

# 本 step 内也设置一遍，方便同 step 后续命令直接用
$env:PATH = $chosen.Env['PATH']
if ($chosen.Env.ContainsKey('INCLUDE')) { $env:INCLUDE = $chosen.Env['INCLUDE'] }
if ($chosen.Env.ContainsKey('LIB'))     { $env:LIB = $chosen.Env['LIB'] }

# ---------------------------------------------------------------------------
# 5) 校验：cl 真的能跑，且版本落在预期区间
#    注意 cl 不带参数时只打横幅：
#      Microsoft (R) C/C++ Optimizing Compiler Version 19.29.30159 for x64
#    版本号形如 19.29.30159（三段），不是四段；用 19.xx 前缀判断工具集区间。
# ---------------------------------------------------------------------------
$clOut = cmd /c "call `"$($chosen.Path)\VC\Auxiliary\Build\vcvarsall.bat`" $($chosen.ArgLine) >nul 2>&1 && cl 2>&1" | Out-String
$clVer = $null
if ($clOut -match 'Compiler Version (\d+\.\d+\.\d+)') { $clVer = $Matches[1] }
if (-not $clVer) {
    Write-Host $clOut
    throw "cl.exe 无法运行（$($chosen.Path) / $($chosen.ArgLine)）"
}
Write-Host "cl.exe = $clVer"

# cl 19.0x -> v140 ; 19.1x -> v141 ; 19.2x -> v142 ; 19.3x+ -> v143
# 用 minor 的十位做映射（19.29 的 minor 是 29，不是个位数），不用 if 链：
# 各 PowerShell 版本对连续 elseif 的行为不完全一致，算术映射最稳。
$clMinor = [int]([version]$clVer).Minor
$tens = [math]::Floor($clMinor / 10)
$idx  = [math]::Min([math]::Max($tens, 0), 3)
$clLabel = [string](140 + $idx)
if ($clLabel -ne $chosenLabel) {
    throw "cl.exe 版本与探测结果不一致：cl=$clVer（应属 v$clLabel），探测得到 v$chosenLabel"
}
Write-Host ("工具集确认：cl {0} => v{1}" -f $clVer, $clLabel)

# ---------------------------------------------------------------------------
# 6) 确保 ATL 头文件可用
#
# 为什么需要：qtspeech 的 SAPI 插件（qtexttospeech_sapi.cpp）间接 include
# Windows SDK 的 sphelper.h，而它会 include atlbase.h。Qt 6.5 里这个插件在
# WIN32 下是**无条件编译**的（没有 feature 开关），所以没装 ATL 时构建会在
# 92% 处挂掉：fatal error C1083: Cannot open include file: 'atlbase.h'。
# （实测 6.5.3 在 8464/9185 处失败，白烧 76 分钟。）
#
# windows-2022 托管镜像默认不带 ATL，需要用 VS Installer 补装
# Microsoft.VisualStudio.Component.VC.ATL（会同时装 ATLMFC 的 x86/x64 库）。
# ---------------------------------------------------------------------------
$atlBase = Join-Path $chosen.Env['VCToolsInstallDir'] 'atlmfc\include\atlbase.h'
if (Test-Path $atlBase) {
    Write-Host "ATL 已就绪: $atlBase"
    ('ATL_STATUS=present') | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
else {
    Write-Host "ATL 缺失（$atlBase），开始补装 VC.ATL 组件"
    ('ATL_STATUS=installing') | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8

    # 走 VS Installer 的 setup.exe 而不是 vs_installer.exe：
    # 后者是 UI 启动器，在无交互的 CI 会话里常常「退出码 0 但什么都没装」；
    # setup.exe 才是真正的引导程序，支持 --quiet 完整安装。
    $setupCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_buildtools.exe"
    )
    $installer = $setupCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $installer) { throw '找不到 VS 安装器（setup.exe / vs_installer.exe / vs_buildtools.exe）' }
    Write-Host "使用 $installer"
    Write-Host "目标实例: $($chosen.Path)"

    $installArgs = @(
        'modify',
        '--installPath', "`"$($chosen.Path)`"",
        '--add', 'Microsoft.VisualStudio.Component.VC.ATL',
        '--quiet', '--norestart', '--nocache'
    )

    $found = $false
    for ($attempt = 1; $attempt -le 2 -and -not $found; $attempt++) {
        Write-Host "== ATL 安装尝试 $attempt =="
        $p = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
        Write-Host "安装器退出码: $($p.ExitCode)"

        # 安装器可能立刻返回 0 而把工作交给后台进程，轮询等文件真的出现
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $atlBase) { $found = $true; break }
            Start-Sleep -Seconds 10
        }
        if ($found) { break }
        Write-Host "  本轮未出现 atlbase.h，10 秒后重试"
        Start-Sleep -Seconds 10
    }

    # 还没出现就在整机范围内找一次：组件可能装到了另一套 MSVC 工具集目录下
    if (-not $found) {
        Write-Host '主路径仍无 atlbase.h，全盘搜索 atlmfc 目录'
        $hits = @(Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Directory -Recurse -Depth 6 `
                  -Filter 'atlmfc' -ErrorAction SilentlyContinue)
        foreach ($h in $hits) {
            $cand = Join-Path $h.FullName 'include\atlbase.h'
            if (Test-Path $cand) {
                Write-Host "  找到: $cand"
                $atlBase = $cand
                # 把包含 ATL 的那套 MSVC 的 include 加到 INCLUDE 最前面
                $msvcRoot = Split-Path -Parent $h.FullName
                $atlInc   = Join-Path $h.FullName 'include'
                $atlLib   = Join-Path $h.FullName 'lib\x64'
                Write-Host "  追加 INCLUDE: $atlInc"
                ('INCLUDE={0};{1}' -f $atlInc, $env:INCLUDE) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
                if (Test-Path $atlLib) {
                    ('LIB={0};{1}' -f $atlLib, $env:LIB) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
                }
                $found = $true
                break
            }
        }
    }

    if ($found) {
        Write-Host "ATL 就绪: $atlBase"
        ('ATL_STATUS=installed') | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
    else {
        # 兜底：SAPI 只是 TextToSpeech 的一个后端，丢掉它不影响 Core/Gui/Widgets 等主体。
        # 与其让 76 分钟的构建在第 8464 个编译单元上挂掉，不如提前把这个插件从构建里摘掉。
        # 注意：本脚本跑在 Fetch 源码之前，SRCDIR 还不存在，所以这里只记标记，
        # 真正的补丁由工作流里 Configure 之前的步骤完成（见 Patch out qtspeech SAPI）。
        Write-Host 'ATL 无法安装，将跳过 qtspeech 的 SAPI 语音后端'
        Write-Host '::warning::ATL 安装失败，稍后会从构建里移除 qtspeech SAPI 插件（其余功能不受影响）'
        ('ATL_STATUS=missing') | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
        ('SKIP_SPEECH_SAPI=true') | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
