Set-StrictMode -Version Latest

function Get-VsWherePath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  throw 'vswhere.exe was not found. Run scripts/install-toolchain.ps1 first.'
}

function Get-VsVersionRange {
  param([Parameter(Mandatory)][string]$Toolset)

  switch ($Toolset) {
    'msvc2015' { return '[15.0,16.0)' }
    'msvc2017' { return '[15.0,16.0)' }
    'msvc2019' { return '[16.0,17.0)' }
    'msvc2022' { return '[17.0,18.0)' }
    default { throw "Unsupported toolset: $Toolset" }
  }
}

function Get-VsInstallPath {
  param([Parameter(Mandatory)][string]$Toolset)

  $vswhere = Get-VsWherePath
  $range = Get-VsVersionRange -Toolset $Toolset
  $paths = @(
    & $vswhere -products * -version $range -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  )
  if (-not $paths) {
    $paths = @(& $vswhere -products * -version $range -property installationPath)
  }
  $installPath = $paths | Where-Object { $_ } | Select-Object -First 1
  if (-not $installPath) {
    throw "No Visual Studio installation matching $Toolset ($range) was found."
  }
  $installPath = $installPath.Trim()

  if ($Toolset -eq 'msvc2015') {
    $v140 = Get-ChildItem -LiteralPath (Join-Path $installPath 'VC\Tools\MSVC') -Directory -Filter '14.00.*' -ErrorAction SilentlyContinue
    $standaloneV140 = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio 14.0\VC\bin\amd64\cl.exe'
    if (-not $v140 -and -not (Test-Path -LiteralPath $standaloneV140)) {
      throw "The v140 (MSVC 2015) toolset is missing from $installPath. Install component Microsoft.VisualStudio.Component.VC.140."
    }
  }

  return $installPath
}

function Get-VcVarsAll {
  param(
    [Parameter(Mandatory)][string]$InstallPath,
    [Parameter(Mandatory)][string]$Toolset
  )

  $candidates = @(
    (Join-Path $InstallPath 'VC\Auxiliary\Build\vcvarsall.bat'),
    (Join-Path $InstallPath 'VC\vcvarsall.bat')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  throw "vcvarsall.bat was not found under $InstallPath for $Toolset."
}

function Enter-MsvcEnvironment {
  param([Parameter(Mandatory)][string]$Toolset)

  $installPath = Get-VsInstallPath -Toolset $Toolset
  $vcvarsall = Get-VcVarsAll -InstallPath $installPath -Toolset $Toolset

  $vcvarsArgs = @('x64')
  if ($Toolset -eq 'msvc2015') {
    $vcvarsArgs += '-vcvars_ver=14.0'
  }

  $tempCmd = Join-Path $env:TEMP "vcvars-$([guid]::NewGuid().ToString('N')).cmd"
  @(
    '@echo off',
    "call `"$vcvarsall`" $($vcvarsArgs -join ' ') >nul 2>&1",
    'if errorlevel 1 exit /b 1',
    'set'
  ) | Set-Content -LiteralPath $tempCmd -Encoding ASCII

  try {
    $environmentLines = & cmd.exe /d /c $tempCmd
    $vcvarsExitCode = $LASTEXITCODE
  } finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
  }
  if ($vcvarsExitCode -ne 0) {
    throw "vcvarsall.bat failed: `"$vcvarsall`" $($vcvarsArgs -join ' ')"
  }

  $imported = 0
  foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') {
      [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [EnvironmentVariableTarget]::Process)
      $imported++
    }
  }
  if ($imported -lt 20) {
    throw "vcvarsall.bat produced an unexpected environment ($imported variables)."
  }

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $clPath = & where.exe cl.exe 2>$null | Select-Object -First 1
    if (-not $clPath) {
      throw 'cl.exe is not on PATH after loading the Visual Studio environment.'
    }

    $banner = & cl.exe 2>&1 | Out-String
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $match = [regex]::Match($banner, 'Version\s+(\d+\.\d+\.\d+)')
  $clVersion = if ($match.Success) { $match.Groups[1].Value } else { 'unknown' }

  $matchesExpected = switch ($Toolset) {
    'msvc2015' { $clVersion -match '^19\.00\.' }
    'msvc2017' { $clVersion -match '^19\.16\.' }
    'msvc2019' { $clVersion -match '^19\.2\d\.' }
    'msvc2022' { $clVersion -match '^19\.[34]\d\.' }
  }
  if (-not $matchesExpected) {
    throw "Expected a different MSVC version for $Toolset, but cl.exe reported $clVersion ($clPath)."
  }

  Write-Host "Visual Studio : $installPath"
  Write-Host "vcvarsall     : $vcvarsall $($vcvarsArgs -join ' ')"
  Write-Host "MSVC compiler : $clVersion ($clPath)"

  return [pscustomobject]@{
    InstallPath = $installPath
    VcVarsAll = $vcvarsall
    ClVersion = $clVersion
    ClPath = $clPath
  }
}
