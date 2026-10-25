[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('msvc2015', 'msvc2017', 'msvc2019', 'msvc2022')]
  [string]$Toolset
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'vs-env.ps1')

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The CircleCI Windows runner must run as a local administrator.'
  }
}

function Invoke-Choco {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$Description
  )

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host ">>> choco $($Arguments -join ' ') (attempt $attempt/3)"
    & choco.exe @Arguments
    if ($LASTEXITCODE -eq 0) { return }
    if ($attempt -eq 3) {
      throw "$Description failed after 3 attempts (choco exit $LASTEXITCODE)."
    }
    Start-Sleep -Seconds (15 * $attempt)
  }
}

function Install-ChocoPackage {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$PackageParameters,
    [int]$ExecutionTimeoutSeconds
  )

  $chocoArgs = @('install', $Name, '-y', '--no-progress')
  if ($PackageParameters) {
    $chocoArgs += "--package-parameters=$PackageParameters"
  }
  if ($ExecutionTimeoutSeconds -gt 0) {
    $chocoArgs += "--execution-timeout=$ExecutionTimeoutSeconds"
  }
  Invoke-Choco -Arguments $chocoArgs -Description "Installing $Name"
}

Assert-Administrator

Write-Host "Installing common build dependencies"
Install-ChocoPackage -Name '7zip'
Install-ChocoPackage -Name 'jom'
Install-ChocoPackage -Name 'ninja'
Install-ChocoPackage -Name 'cmake'
Install-ChocoPackage -Name 'python'
if ($Toolset -eq 'msvc2015') {
  try {
    Install-ChocoPackage -Name 'python2'
  } catch {
    Write-Warning "Python 2 could not be installed: $($_.Exception.Message)"
    Write-Warning 'Qt 5.12 configure may require it outside the skipped modules.'
  }
}

if ($Toolset -in @('msvc2015', 'msvc2017')) {
  $vsParameters = '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --wait --norestart'
  if ($Toolset -eq 'msvc2015') {
    $vsParameters += ' --add Microsoft.VisualStudio.Component.VC.140'
  }
  Install-ChocoPackage -Name 'visualstudio2017buildtools' -PackageParameters $vsParameters -ExecutionTimeoutSeconds 7200
} else {
  try {
    $null = Get-VsInstallPath -Toolset $Toolset
  } catch {
    $package = if ($Toolset -eq 'msvc2019') { 'visualstudio2019buildtools' } else { 'visualstudio2022buildtools' }
    $vsParameters = '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --wait --norestart'
    Install-ChocoPackage -Name $package -PackageParameters $vsParameters -ExecutionTimeoutSeconds 7200
  }
}

Write-Host "Validating the $Toolset compiler environment"
$null = Enter-MsvcEnvironment -Toolset $Toolset

Write-Host "Toolchain ready for $Toolset"
