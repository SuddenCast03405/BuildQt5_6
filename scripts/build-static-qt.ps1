[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('msvc2015', 'msvc2017', 'msvc2019', 'msvc2022')]
  [string]$Toolset,

  [Parameter(Mandatory)]
  [ValidatePattern('^(latest|\d+\.\d+\.\d+)$')]
  [string]$QtVersion,

  [string]$SkipModules = 'qtwebengine qtwebview qt3d qtquick3d qtquick3dphysics qtcharts qtdatavis3d qtgraphs',
  [int]$Parallel = [Environment]::ProcessorCount,
  [string]$Mirror = 'https://download.qt.io',
  [switch]$KeepPdb
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'vs-env.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $repoRoot 'artifacts'
$qtRoot = 'C:\qt'
$srcRoot = Join-Path $qtRoot 'src'
$buildRoot = Join-Path $qtRoot 'build'
$installRoot = Join-Path $qtRoot 'install'

foreach ($directory in @($artifacts, $srcRoot, $buildRoot, $installRoot)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$Mirror = $Mirror.TrimEnd('/')

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "`n==== $Message ====" -ForegroundColor Cyan
}

function Get-7ZipPath {
  $candidates = @(
    (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
    (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  throw '7z.exe was not found. Run scripts/install-toolchain.ps1 first.'
}

function Get-RemoteText {
  param([Parameter(Mandatory)][string]$Url)

  $text = & curl.exe -fsSL --retry 3 --retry-delay 3 --max-time 90 $Url
  if ($LASTEXITCODE -ne 0) { throw "GET $Url failed (curl exit $LASTEXITCODE)." }
  return ($text -join "`n")
}

function Test-RemoteFile {
  param([Parameter(Mandatory)][string]$Url)

  & curl.exe -fsIL --retry 2 --max-time 45 $Url *> $null
  if ($LASTEXITCODE -eq 0) { return $true }

  & curl.exe -fsL --range 0-0 -o NUL --max-time 45 $Url *> $null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-QtLatest {
  Write-Step 'Resolving the latest public Qt 6 release'
  $index = Get-RemoteText "$Mirror/archive/qt/"
  $minors = [regex]::Matches($index, 'href="(6\.\d+)/"') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object { [version]$_ } -Descending

  foreach ($minor in $minors) {
    try {
      $minorIndex = Get-RemoteText "$Mirror/archive/qt/$minor/"
    } catch {
      continue
    }
    $patches = [regex]::Matches($minorIndex, 'href="(' + [regex]::Escape($minor) + '\.\d+)/"') |
      ForEach-Object { $_.Groups[1].Value } |
      Sort-Object { [version]$_ } -Descending

    foreach ($patch in $patches) {
      $probeUrl = "$Mirror/archive/qt/$minor/$patch/single/qt-everywhere-src-$patch.tar.xz"
      if (Test-RemoteFile -Url $probeUrl) {
        Write-Host "Resolved latest Qt: $patch"
        return $patch
      }
    }
  }
  throw 'Unable to resolve the latest public Qt 6 source release. Pin a version explicitly.'
}

if ($QtVersion -eq 'latest') {
  $QtVersion = Resolve-QtLatest
}

$qtVer = [version]$QtVersion
$isQt5 = $qtVer.Major -eq 5
$series = '{0}.{1}' -f $qtVer.Major, $qtVer.Minor

$archiveName = "qt-everywhere-src-$QtVersion.tar.xz"
$archivePath = Join-Path $srcRoot $archiveName
$archiveUrl = "$Mirror/archive/qt/$series/$QtVersion/single/$archiveName"
$srcDir = Join-Path $srcRoot "qt-everywhere-src-$QtVersion"
$buildDir = Join-Path $buildRoot "$Toolset-$QtVersion"
$prefix = Join-Path $installRoot "$Toolset-$QtVersion"
$sevenZip = Get-7ZipPath

Write-Step "Activator: $Toolset"
$envInfo = Enter-MsvcEnvironment -Toolset $Toolset

if ($isQt5 -and $qtVer -lt [version]'5.15.0') {
  $python2 = 'C:\Python27\python.exe'
  if (Test-Path -LiteralPath $python2) {
    $env:Path = "C:\Python27;$env:Path"
    Write-Host "Using Python 2.7 for the Qt 5.12 build"
  } else {
    Write-Warning 'Python 2.7 was not found; Qt 5.12 may fail during configure.'
  }
}

if (-not (Test-Path -LiteralPath $archivePath)) {
  Write-Step "Downloading $archiveName"
  & curl.exe -fL --retry 5 --retry-delay 5 -o $archivePath $archiveUrl
  if ($LASTEXITCODE -ne 0) {
    throw "Download failed: $archiveUrl (curl exit $LASTEXITCODE)."
  }
}

$expectedMd5 = $null
try {
  $md5Text = Get-RemoteText "$Mirror/archive/qt/$series/$QtVersion/single/md5sums.txt"
  $entry = ($md5Text -split "`n") |
    Where-Object { $_ -match [regex]::Escape($archiveName) } |
    Select-Object -First 1
  if ($entry -match '^([0-9a-fA-F]{32})') {
    $expectedMd5 = $matches[1].ToLowerInvariant()
  }
} catch {
  Write-Warning "Could not download md5sums.txt: $($_.Exception.Message)"
}
if ($expectedMd5) {
  $actualMd5 = (Get-FileHash -LiteralPath $archivePath -Algorithm MD5).Hash.ToLowerInvariant()
  if ($actualMd5 -ne $expectedMd5) {
    throw "MD5 mismatch for $archiveName (expected $expectedMd5, got $actualMd5)."
  }
  Write-Host "MD5 verified: $actualMd5"
} else {
  Write-Warning "No MD5 checksum available for $archiveName"
}

if (-not (Test-Path -LiteralPath $srcDir)) {
  Write-Step 'Extracting Qt source'
  $tempDir = Join-Path $srcRoot '_extract'
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

  & $sevenZip x $archivePath "-o$tempDir" -y -bso0 -bsp0
  if ($LASTEXITCODE -ne 0) { throw '7-Zip failed to extract the .tar.xz archive.' }

  $tarPath = Join-Path $tempDir ($archiveName.Substring(0, $archiveName.Length - 3))
  & $sevenZip x $tarPath "-o$srcRoot" -y -bso0 -bsp0
  if ($LASTEXITCODE -ne 0) { throw '7-Zip failed to extract the .tar archive.' }

  Remove-Item -LiteralPath $tempDir -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'configure.bat'))) {
  throw "Qt source tree not found: $srcDir"
}

Write-Step 'Reading available configure options'
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $helpText = (& "$srcDir\configure.bat" -help 2>&1 | Out-String)
} finally {
  $ErrorActionPreference = $previousErrorAction
}

$configureArgs = @(
  '-prefix', $prefix,
  '-static',
  '-release',
  '-opensource',
  '-confirm-license',
  '-nomake', 'examples',
  '-nomake', 'tests'
)

if ($helpText -match 'static-runtime') {
  $configureArgs += '-static-runtime'
} else {
  Write-Warning 'This Qt version has no -static-runtime option; the CRT will be dynamic (/MD).'
}

if ($helpText -match '(?m)^\s*-opengl\b') {
  $configureArgs += @('-opengl', 'desktop')
}

if ($isQt5 -and $helpText -match '(?m)^\s*-openssl\b') {
  $configureArgs += '-no-openssl'
}

$skipped = @()
foreach ($module in ($SkipModules -split '[,;\s]+' | Where-Object { $_ })) {
  if (Test-Path -LiteralPath (Join-Path $srcDir $module)) {
    $configureArgs += @('-skip', $module)
    $skipped += $module
  }
}
Write-Host "Skipped modules: $($skipped -join ', ')"

if (Test-Path -LiteralPath $buildDir) {
  Remove-Item -LiteralPath $buildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

Write-Step "Configuring Qt $QtVersion"
Write-Host "configure $($configureArgs -join ' ')"
$configureLog = Join-Path $artifacts "configure-$Toolset-$QtVersion.log"
Push-Location $buildDir
try {
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & "$srcDir\configure.bat" @configureArgs 2>&1 | Tee-Object -FilePath $configureLog
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Qt configure failed (exit $LASTEXITCODE). See $configureLog"
  }
} finally {
  Pop-Location
}

Push-Location $buildDir
try {
  if ($isQt5) {
    $jom = Get-Command jom.exe -ErrorAction SilentlyContinue
    if ($jom) {
      Write-Step "Building Qt with jom -j $Parallel"
      & $jom.Source '-j' "$Parallel"
      if ($LASTEXITCODE -ne 0) { throw "jom failed (exit $LASTEXITCODE)." }

      Write-Step 'Installing Qt'
      & $jom.Source 'install'
      if ($LASTEXITCODE -ne 0) { throw "jom install failed (exit $LASTEXITCODE)." }
    } else {
      Write-Step 'Building Qt with nmake'
      & nmake.exe /NOLOGO
      if ($LASTEXITCODE -ne 0) { throw "nmake failed (exit $LASTEXITCODE)." }

      Write-Step 'Installing Qt'
      & nmake.exe /NOLOGO install
      if ($LASTEXITCODE -ne 0) { throw "nmake install failed (exit $LASTEXITCODE)." }
    }
  } else {
    Write-Step "Building Qt with CMake/Ninja (-j $Parallel)"
    & cmake.exe --build . --parallel $Parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake --build failed (exit $LASTEXITCODE)." }

    Write-Step 'Installing Qt'
    & cmake.exe --install .
    if ($LASTEXITCODE -ne 0) { throw "cmake --install failed (exit $LASTEXITCODE)." }
  }
} finally {
  Pop-Location
}

$qmake = Join-Path $prefix 'bin\qmake.exe'
if (-not (Test-Path -LiteralPath $qmake)) {
  throw "Qt install is incomplete: $qmake is missing."
}

if (-not $KeepPdb) {
  Write-Step 'Removing PDB files'
  Get-ChildItem -LiteralPath $prefix -Recurse -File -Filter '*.pdb' |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
foreach ($directory in @('doc', 'examples', 'tests')) {
  Remove-Item -LiteralPath (Join-Path $prefix $directory) -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step 'Making the install tree relocatable'
@(
  '[Paths]',
  'Prefix=..'
) | Set-Content -LiteralPath (Join-Path $prefix 'bin\qt.conf') -Encoding ASCII

Write-Step 'Writing build manifest'
$qmakeQuery = (& $qmake -query 2>&1 | Out-String).Trim()
$manifest = @(
  "Qt version: $QtVersion",
  "Toolset: $Toolset",
  "MSVC: $($envInfo.ClVersion) ($($envInfo.ClPath))",
  "Visual Studio: $($envInfo.InstallPath)",
  "Configure: $($configureArgs -join ' ')",
  "Skipped modules: $($skipped -join ', ')",
  "Built: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')",
  '',
  $qmakeQuery
)
$manifestPath = Join-Path $prefix 'BUILD-INFO.txt'
$manifest | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifestArtifact = Join-Path $artifacts "qt-$QtVersion-static-$Toolset-x64.txt"
Copy-Item -LiteralPath $manifestPath -Destination $manifestArtifact -Force

Write-Step 'Packaging artifact'
$zipName = "qt-$QtVersion-static-$Toolset-x64.zip"
$zipPath = Join-Path $artifacts $zipName
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

Push-Location $prefix
try {
  & $sevenZip a -tzip -mx=5 $zipPath '*'
  if ($LASTEXITCODE -ne 0) { throw "7-Zip packaging failed (exit $LASTEXITCODE)." }
} finally {
  Pop-Location
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $zipName" | Set-Content -LiteralPath "$zipPath.sha256" -Encoding ASCII
$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)

Write-Host ''
Write-Host "Artifact : $zipPath"
Write-Host "Size     : $sizeMb MB"
Write-Host "SHA256   : $hash"
