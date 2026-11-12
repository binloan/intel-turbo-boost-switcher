#requires -Version 5.1
# Runs the REAL Install.ps1 and ITBS.ps1 in child PowerShell processes against
# a stub scripts\Common.psm1. The stub records every call and performs no hardware,
# service, file-system or elevation action, so this checks the -AcceptUntestedRisk
# and untested-CPU wiring end to end without touching the machine.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }

$testRoot = [IO.Path]::GetFullPath((Join-Path $root 'obj'))
$fixture = Join-Path $testRoot ('scripts-' + [Guid]::NewGuid().ToString('N'))
$stubModule = @'
function Log([string]$Message) { Add-Content -LiteralPath $env:ITBS_TEST_LOG -Value $Message }
function Test-Administrator { $env:ITBS_TEST_ADMIN -eq '1' }
function Invoke-ElevatedScript { param([string]$ScriptPath, [string]$Arguments) Log "ELEVATE $Arguments"; 0 }
function Assert-IntelCpu {
    param($Info)
    Log 'INTEL'
    [pscustomobject]@{ Name='Fake CPU'; Identifier='Fake'; Vendor='GenuineIntel'; LogicalProcessors=8; Tested=($env:ITBS_TEST_TESTED -eq '1') }
}
function Write-UntestedWarning { param($Info) Log 'WARN' }
function Confirm-UntestedCpu {
    param($Info, [switch]$AcceptRisk)
    Log ('CONFIRM accept=' + [bool]$AcceptRisk)
    if ($env:ITBS_TEST_DECLINE -eq '1') { throw 'STOP: declined' }
    if ($env:ITBS_TEST_HALT -eq '1') { throw 'STOP: halted after confirmation' }
}
function Get-Service {
    [CmdletBinding()] param([string]$Name)
    Log "GET-SERVICE $Name"
    if ($env:ITBS_TEST_LEGACY -eq '1' -and $Name -eq 'StopThrottle') {
        return ([pscustomobject]@{ Name=$Name } | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru)
    }
    $null
}
function Get-TuningProcesses { @() }
function Invoke-HardwareSession { param([scriptblock]$Operation) Log 'HARDWARE-SESSION' }
function Set-ProtectedDirectory { param([string]$Path) throw 'STOP: unexpected mutating install step' }
function Assert-Dependencies { param($Directory, $Dependency) }
Export-ModuleMember -Function *
'@
$stubDependencies = @'
$fake = Join-Path $PSScriptRoot 'fake-engine'
$fake
'@

function Invoke-Script {
    param([string]$Script, [string[]]$Arguments, [hashtable]$Environment)
    $log = Join-Path $fixture 'calls.log'
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
    $saved = @{}
    $settings = @{ ITBS_TEST_LOG=$log; ITBS_TEST_ADMIN='1'; ITBS_TEST_TESTED='0'; ITBS_TEST_DECLINE='0'; ITBS_TEST_HALT='0'; ITBS_TEST_LEGACY='0' }
    foreach ($key in $Environment.Keys) { $settings[$key] = $Environment[$key] }
    foreach ($key in $settings.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $settings[$key]) }
    try {
        $null = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture $Script) @Arguments | Out-String
        $exit = $LASTEXITCODE
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    $lines = @(); if (Test-Path -LiteralPath $log) { $lines = @(Get-Content -LiteralPath $log) }
    [pscustomobject]@{ Exit=$exit; Calls=$lines }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    foreach ($name in 'Install.ps1', 'ITBS.ps1', 'dependencies.json') { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $fixture }
    Set-Content -LiteralPath (Join-Path $fixture 'scripts\Common.psm1') -Value $stubModule -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $fixture 'scripts\Get-Dependencies.ps1') -Value $stubDependencies -Encoding ASCII

    # --- ITBS.ps1 (manual tool) ---
    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'Read')
    Check ($r.Exit -eq 0 -and $r.Calls -contains 'WARN' -and $r.Calls -contains 'HARDWARE-SESSION') 'Read on an untested CPU should warn and proceed.'
    Check (-not ($r.Calls -match '^CONFIRM')) 'Read must not require confirmation.'

    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'EnableTurbo')
    Check ($r.Exit -eq 0 -and $r.Calls -contains 'CONFIRM accept=False' -and $r.Calls -contains 'HARDWARE-SESSION') 'A write without the switch must ask for confirmation.'

    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'DisableTurbo', '-AcceptUntestedRisk')
    Check ($r.Exit -eq 0 -and $r.Calls -contains 'CONFIRM accept=True' -and $r.Calls -contains 'HARDWARE-SESSION') '-AcceptUntestedRisk must reach the confirmation.'

    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'EnableTurbo') @{ ITBS_TEST_DECLINE='1' }
    Check ($r.Exit -ne 0 -and $r.Calls -contains 'CONFIRM accept=False' -and -not ($r.Calls -contains 'HARDWARE-SESSION')) 'A declined confirmation must stop before any hardware session.'

    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'EnableTurbo') @{ ITBS_TEST_TESTED='1' }
    Check ($r.Exit -eq 0 -and -not ($r.Calls -contains 'WARN') -and -not ($r.Calls -match '^CONFIRM') -and $r.Calls -contains 'HARDWARE-SESSION') 'The tested CPU must not warn or prompt.'

    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'EnableTurbo', '-AcceptUntestedRisk') @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Mode EnableTurbo -Interactive -AcceptUntestedRisk') 'The elevated relaunch must carry -AcceptUntestedRisk.'
    $r = Invoke-Script 'ITBS.ps1' @('-Mode', 'EnableTurbo') @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Mode EnableTurbo -Interactive') 'The elevated relaunch must not add -AcceptUntestedRisk by itself.'

    # --- Install.ps1 (stops at the confirmation; every later step is unreachable) ---
    $r = Invoke-Script 'Install.ps1' @() @{ ITBS_TEST_HALT='1' }
    Check ($r.Exit -ne 0 -and $r.Calls -contains 'INTEL' -and $r.Calls -contains 'CONFIRM accept=False') 'Install must check the CPU and ask for confirmation.'
    $r = Invoke-Script 'Install.ps1' @('-AcceptUntestedRisk') @{ ITBS_TEST_HALT='1' }
    Check ($r.Calls -contains 'CONFIRM accept=True') 'Install must pass -AcceptUntestedRisk to the confirmation.'
    $r = Invoke-Script 'Install.ps1' @() @{ ITBS_TEST_DECLINE='1' }
    Check ($r.Exit -ne 0 -and -not ($r.Calls -match '^GET-SERVICE')) 'A declined install must stop before touching the service.'
    # A pre-release installation under the old name must stop the install before anything is changed.
    $r = Invoke-Script 'Install.ps1' @('-AcceptUntestedRisk') @{ ITBS_TEST_LEGACY='1' }
    Check ($r.Exit -ne 0 -and $r.Calls -contains 'GET-SERVICE StopThrottle' -and -not ($r.Calls -contains 'GET-SERVICE ITBS')) 'A legacy installation must block a new install.'
    $r = Invoke-Script 'Install.ps1' @('-AcceptUntestedRisk') @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Action Install -Interactive -AcceptUntestedRisk') 'Install relaunch must carry -AcceptUntestedRisk.'
    $r = Invoke-Script 'Install.ps1' @('-OnFailure', 'Fail') @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Action Install -Interactive -OnFailure Fail') 'Install relaunch must carry -OnFailure.'
    $r = Invoke-Script 'Install.ps1' @() @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Action Install -Interactive') 'Install relaunch must not add -AcceptUntestedRisk by itself.'

    # --- Uninstall.cmd ---
    $r = Invoke-Script 'Install.ps1' @('-Action', 'Uninstall') @{ ITBS_TEST_ADMIN='0' }
    Check ($r.Calls -contains 'ELEVATE -Action Uninstall -Interactive') 'Uninstall must relaunch elevated.'
    # Run the REAL Uninstall.cmd, started inside its own folder like a double-click, against a stub
    # Install.ps1 that deletes the whole folder. This proves the batch file can remove the install
    # directory it lives in without leaving the console with an error.
    $removable = Join-Path $testRoot ('uninstall-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $removable 'source') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'Uninstall.cmd') -Destination (Join-Path $removable 'source')
        Set-Content -LiteralPath (Join-Path $removable 'source\Install.ps1') -Encoding ASCII -Value @'
param([string]$Action, [switch]$Interactive)
if ($Action -ne 'Uninstall' -or -not $Interactive) { exit 2 }
Set-Location -LiteralPath $env:SystemRoot
Remove-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Recurse -Force
'@
        $outFile = Join-Path $testRoot ('uninstall-' + [Guid]::NewGuid().ToString('N') + '.out')
        $errFile = $outFile + '.err'
        $cmd = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', ('"' + (Join-Path $removable 'source\Uninstall.cmd') + '"') `
            -WorkingDirectory (Join-Path $removable 'source') -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        Check ($cmd.ExitCode -eq 0) 'Uninstall.cmd should exit cleanly after removing its own folder.'
        Check (-not (Test-Path -LiteralPath $removable)) 'Uninstall.cmd should be able to delete the folder it runs from.'
        $errText = [string](Get-Content -LiteralPath $errFile -Raw)
        Check ($errText -notmatch '\S') 'Uninstall.cmd should not print errors after the folder is gone.'
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $removable) { Remove-Item -LiteralPath $removable -Recurse -Force }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($testRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup target.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "PASS: $script:checks script-wiring assertions; stub module only, no hardware, service, or elevation."
