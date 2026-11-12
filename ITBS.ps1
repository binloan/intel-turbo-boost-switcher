#requires -Version 5.1
<#
.SYNOPSIS
    Reads, enables or disables Intel Turbo Boost manually through a readable PowerShell controller.
.DESCRIPTION
    Elevates itself when needed, checks the CPU, refuses to write while the ITBS service is running or
    while competing tuning tools are open, and runs the selected operation inside a hardware session
    that uses a protected copy of the MSR engine. No custom EXE is involved.
.EXAMPLE
    .\ITBS.ps1 -Mode Read

    Shows the current Turbo disable bit of every logical processor.
.EXAMPLE
    .\ITBS.ps1 -Mode DisableTurbo -AcceptUntestedRisk

    Disables Turbo and accepts the warning about a CPU that has not been tested.
#>
[CmdletBinding()]
param (
    # The operation to run. Menu starts an interactive prompt.
    [ValidateSet('Menu', 'Read', 'EnableTurbo', 'DisableTurbo')]
    [string]
    $Mode = 'Menu',

    # Keeps the console open for prompts. Set automatically when the script relaunches itself elevated.
    [switch]
    $Interactive,

    # Accepts the risk of writing to a CPU that has not been tested, without asking.
    [switch]
    $AcceptUntestedRisk
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Common.psm1') -Force

if (-not (Test-Administrator)) {
    $elevatedArguments = '-Mode ' + $Mode + ' -Interactive'
    if ($AcceptUntestedRisk) {
        $elevatedArguments += ' -AcceptUntestedRisk'
    }
    exit (Invoke-ElevatedScript -ScriptPath $PSCommandPath -Arguments $elevatedArguments)
}


function Invoke-ManualOperation {
    <#
    .SYNOPSIS
        Runs one manual Turbo operation after the safety checks.
    .DESCRIPTION
        Warns or asks for confirmation on an untested CPU, refuses to write while the service or a competing
        tool is active, and then reads or writes the Turbo state inside a hardware session.
    .EXAMPLE
        Invoke-ManualOperation -Operation 'Read'
    #>
    [CmdletBinding()]
    param (
        # The operation to run: Read, EnableTurbo or DisableTurbo.
        [string]
        $Operation
    )

    $cpu = Assert-IntelCpu
    if (-not $cpu.Tested) {
        # Reads only warn; any write needs explicit acceptance (once per session).
        if ($Operation -eq 'Read') {
            if (-not $script:Warned) {
                Write-UntestedWarning -Info $cpu
                $script:Warned = $true
            }
        } elseif (-not $script:RiskAccepted) {
            Confirm-UntestedCpu -Info $cpu -AcceptRisk:$AcceptUntestedRisk
            $script:RiskAccepted = $true
        }
    }
    if ($Operation -ne 'Read') {
        $service = Get-Service -Name ITBS -ErrorAction SilentlyContinue
        if ($service) {
            try {
                if ($service.Status -ne 'Stopped') {
                    throw 'Stop the service before manual writes: Stop-Service ITBS'
                }
            } finally {
                $service.Dispose()
            }
        }
        $competing = @(Get-TuningProcesses)
        if ($competing.Count) {
            throw ('Close competing tools: ' + ($competing -join ', '))
        }
    }
    $dependencyFile = Join-Path -Path $PSScriptRoot -ChildPath 'dependencies.json'
    $dependency = (Get-Content -LiteralPath $dependencyFile -Raw | ConvertFrom-Json).msrUtility
    # Reuse engine\ only when running from an installed copy (marker beside it).
    $installRoot = Split-Path -Path $PSScriptRoot -Parent
    $installedEngine = Join-Path -Path $installRoot -ChildPath 'engine'
    $installedMarker = Join-Path -Path $installRoot -ChildPath 'install-info.json'
    if ((Test-Path -LiteralPath $installedMarker) -and (Test-Path -LiteralPath $installedEngine)) {
        Assert-Dependencies -Directory $installedEngine -Dependency $dependency
        $download = (Resolve-Path -LiteralPath $installedEngine).Path
    } else {
        $download = & (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Get-Dependencies.ps1')
    }
    $data = Join-Path -Path $env:ProgramData -ChildPath 'ITBS'
    $hardwareOperation = {
        # Elevated execution uses a protected copy, never an executable loaded
        # directly from a checkout writable by an unprivileged user.
        Set-ProtectedDirectory -Path $data
        $engine = Join-Path -Path $data -ChildPath 'manual-engine'
        Set-ProtectedDirectory -Path $engine
        foreach ($file in $dependency.files.PSObject.Properties) {
            $target = Join-Path -Path $engine -ChildPath $file.Name
            if (Test-Path -LiteralPath $target) {
                $attributes = (Get-Item -LiteralPath $target -Force).Attributes
                if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'Refusing redirected engine file.'
                }
            }
            if (
                -not (Test-Path -LiteralPath $target) -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.Value
            ) {
                $sourceFile = Join-Path -Path $download -ChildPath $file.Name
                Copy-Item -LiteralPath $sourceFile -Destination $target -Force
            }
        }
        Assert-Dependencies -Directory $engine -Dependency $dependency
        $runner = New-MsrRunner -Directory $engine
        if ($Operation -eq 'Read') {
            $rows = @(Read-TurboState -Runner $runner -ExpectedCount $cpu.LogicalProcessors)
        } else {
            $disableBit = if ($Operation -eq 'EnableTurbo') { 0 } else { 1 }
            $rows = @(
                Set-TurboState -DisableBit $disableBit -Runner $runner -ExpectedCount $cpu.LogicalProcessors
            )
        }
        $msrColumn = @{
            Name       = 'MSR_0x1A0'
            Expression = { '0x{0:X16}' -f $_.Value }
        }
        $rows | Select-Object -Property 'Cpu', $msrColumn, 'DisableBit' | Format-Table -AutoSize
        Write-Host -Object 'DisableBit 0 permits Turbo; 1 disables Turbo. No power or thermal limits were changed.'
    }.GetNewClosure()
    Invoke-HardwareSession -Operation $hardwareOperation
}


try {
    if ($Mode -ne 'Menu') {
        Invoke-ManualOperation -Operation $Mode
    } else {
        Write-Host -Object 'Intel TurboBoost Switcher manual controller - readable PowerShell; no custom EXE.'
        $menuCpu = Assert-IntelCpu
        if (-not $menuCpu.Tested) {
            Write-UntestedWarning -Info $menuCpu
            $script:Warned = $true
        }
        while ($true) {
            $choice = Read-Host -Prompt "`n1 Read  2 Enable Turbo  3 Disable Turbo  Q Quit"
            if ($choice -eq 'q') {
                break
            }
            try {
                switch ($choice) {
                    '1' {
                        Invoke-ManualOperation -Operation 'Read'
                    }
                    '2' {
                        Invoke-ManualOperation -Operation 'EnableTurbo'
                    }
                    '3' {
                        Invoke-ManualOperation -Operation 'DisableTurbo'
                    }
                    default {
                        Write-Host -Object 'Choose 1, 2, 3 or Q.'
                    }
                }
            } catch {
                $operationMessage = $_.Exception.Message
                Write-Host -Object $operationMessage -ForegroundColor Red
            }
        }
    }
} catch {
    $failureMessage = $_.Exception.Message
    Write-Host -Object $failureMessage -ForegroundColor Red
    if ($Interactive) {
        $null = Read-Host -Prompt 'Press Enter to close'
    }
    exit 1
}
if ($Interactive -and $Mode -ne 'Menu') {
    $null = Read-Host -Prompt 'Press Enter to close'
}
