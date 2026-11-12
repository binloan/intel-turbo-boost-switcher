#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Menu','Read','EnableTurbo','DisableTurbo')][string]$Mode = 'Menu', [switch]$Interactive, [switch]$AcceptUntestedRisk)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Common.psm1') -Force
if (-not (Test-Administrator)) {
    $elevatedArguments = '-Mode ' + $Mode + ' -Interactive'
    if ($AcceptUntestedRisk) { $elevatedArguments += ' -AcceptUntestedRisk' }
    exit (Invoke-ElevatedScript -ScriptPath $PSCommandPath -Arguments $elevatedArguments)
}
function Invoke-ManualOperation([string]$Operation) {
    $cpu = Assert-IntelCpu
    if (-not $cpu.Tested) {
        # Reads only warn; any write needs explicit acceptance (once per session).
        if ($Operation -eq 'Read') { if (-not $script:warned) { Write-UntestedWarning $cpu; $script:warned = $true } }
        elseif (-not $script:riskAccepted) { Confirm-UntestedCpu $cpu -AcceptRisk:$AcceptUntestedRisk; $script:riskAccepted = $true }
    }
    if ($Operation -ne 'Read') {
        $service = Get-Service -Name ITBS -ErrorAction SilentlyContinue
        if ($service) {
            try { if ($service.Status -ne 'Stopped') { throw 'Stop the service before manual writes: Stop-Service ITBS' } }
            finally { $service.Dispose() }
        }
        $competing = @(Get-TuningProcesses)
        if ($competing.Count) { throw ('Close competing tools: ' + ($competing -join ', ')) }
    }
    $dependency = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.json') -Raw | ConvertFrom-Json).msrUtility
    # Reuse engine\ only when running from an installed copy (marker beside it).
    $installRoot=Split-Path -Parent $PSScriptRoot
    $installedEngine=Join-Path $installRoot 'engine'
    if ((Test-Path -LiteralPath (Join-Path $installRoot 'install-info.json')) -and (Test-Path -LiteralPath $installedEngine)) { Assert-Dependencies $installedEngine $dependency; $download=(Resolve-Path -LiteralPath $installedEngine).Path }
    else { $download = & (Join-Path $PSScriptRoot 'scripts\Get-Dependencies.ps1') }
    $data = Join-Path $env:ProgramData 'ITBS'
    Invoke-HardwareSession -Operation ({
        # Elevated execution uses a protected copy, never an executable loaded
        # directly from a checkout writable by an unprivileged user.
        Set-ProtectedDirectory $data
        $engine=Join-Path $data 'manual-engine'
        Set-ProtectedDirectory $engine
        foreach ($file in $dependency.files.PSObject.Properties) {
            $target = Join-Path $engine $file.Name
            if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing redirected engine file.' }
            if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.Value) {
                Copy-Item -LiteralPath (Join-Path $download $file.Name) -Destination $target -Force
            }
        }
        Assert-Dependencies $engine $dependency
        $runner = New-MsrRunner $engine
        $rows = if ($Operation -eq 'Read') { @(Read-TurboState $runner $cpu.LogicalProcessors) }
                else { @(Set-TurboState -DisableBit $(if ($Operation -eq 'EnableTurbo') { 0 } else { 1 }) -Runner $runner -ExpectedCount $cpu.LogicalProcessors) }
        $rows | Select-Object Cpu,@{Name='MSR_0x1A0';Expression={'0x{0:X16}' -f $_.Value}},DisableBit | Format-Table -AutoSize
        Write-Host 'DisableBit 0 permits Turbo; 1 disables Turbo. No power or thermal limits were changed.'
    }.GetNewClosure())
}
try {
    if ($Mode -ne 'Menu') { Invoke-ManualOperation $Mode }
    else {
        Write-Host 'Intel TurboBoost Switcher manual controller - readable PowerShell; no custom EXE.'
        $menuCpu = Assert-IntelCpu
        if (-not $menuCpu.Tested) { Write-UntestedWarning $menuCpu; $script:warned = $true }
        while ($true) {
            $choice = Read-Host "`n1 Read  2 Enable Turbo  3 Disable Turbo  Q Quit"
            if ($choice -eq 'q') { break }
            try {
                switch ($choice) {
                    '1' { Invoke-ManualOperation 'Read' }
                    '2' { Invoke-ManualOperation 'EnableTurbo' }
                    '3' { Invoke-ManualOperation 'DisableTurbo' }
                    default { Write-Host 'Choose 1, 2, 3 or Q.' }
                }
            } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Interactive) { $null=Read-Host 'Press Enter to close' }
    exit 1
}
if ($Interactive -and $Mode -ne 'Menu') { $null=Read-Host 'Press Enter to close' }
