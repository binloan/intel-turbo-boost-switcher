#requires -Version 5.1
<#
.SYNOPSIS
    Tests the wiring of Install.ps1, ITBS.ps1 and Uninstall.cmd against a stub scripts\Common.psm1.
.DESCRIPTION
    Runs the REAL Install.ps1 and ITBS.ps1 in child PowerShell processes against a stub
    scripts\Common.psm1. The stub records every call and performs no hardware, service, file-system or
    elevation action, so this checks the -AcceptUntestedRisk and untested-CPU wiring end to end without
    touching the machine. It also runs the real Uninstall.cmd against a stub Install.ps1 that deletes the
    folder the batch file lives in.
.EXAMPLE
    .\tests\Test-Scripts.ps1

    Runs all assertions and prints a PASS line, or throws on the first failure.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$script:checks = 0


function Check {
    <#
    .SYNOPSIS
        Counts an assertion and throws the message when the condition is false.
    .EXAMPLE
        Check -Condition ($value -eq 1) -Message 'The value should be 1.'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        # The condition that must be true.
        [bool]
        $Condition,

        # The failure message.
        [string]
        $Message
    )

    if (-not $Condition) {
        throw $Message
    }

    $script:checks++
}


$testRoot = [IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath 'obj'))
$fixture = Join-Path -Path $testRoot -ChildPath ('scripts-' + [Guid]::NewGuid().ToString('N'))
$stubModule = @'
function Log {
    <#
    .SYNOPSIS
        Appends a line to the call log.
    #>
    param (
        # The text to record.
        [string]
        $Message
    )

    Add-Content -LiteralPath $env:ITBS_TEST_LOG -Value $Message
}


function Test-Administrator {
    <#
    .SYNOPSIS
        Reports administrator rights as set by ITBS_TEST_ADMIN.
    #>
    $env:ITBS_TEST_ADMIN -eq '1'
}


function Invoke-ElevatedScript {
    <#
    .SYNOPSIS
        Records the elevation request instead of elevating.
    #>
    param (
        # The script that would be elevated.
        [string]
        $ScriptPath,

        # The arguments that would be passed.
        [string]
        $Arguments
    )

    Log "ELEVATE $Arguments"
    0
}


function Assert-IntelCpu {
    <#
    .SYNOPSIS
        Records the call and returns a fake CPU whose Tested flag comes from ITBS_TEST_TESTED.
    #>
    param (
        # The CPU information, ignored.
        $Info
    )

    Log 'INTEL'
    [pscustomobject]@{
        Name              = 'Fake CPU'
        Identifier        = 'Fake'
        Vendor            = 'GenuineIntel'
        LogicalProcessors = 8
        Tested            = ($env:ITBS_TEST_TESTED -eq '1')
    }
}


function Write-UntestedWarning {
    <#
    .SYNOPSIS
        Records the warning instead of printing it.
    #>
    param (
        # The CPU information, ignored.
        $Info
    )

    Log 'WARN'
}


function Confirm-UntestedCpu {
    <#
    .SYNOPSIS
        Records the confirmation and stops the script when ITBS_TEST_DECLINE or ITBS_TEST_HALT is set.
    #>
    param (
        # The CPU information, ignored.
        $Info,

        # Whether the risk was accepted on the command line.
        [switch]
        $AcceptRisk
    )

    Log ('CONFIRM accept=' + [bool]$AcceptRisk)
    if ($env:ITBS_TEST_DECLINE -eq '1') {
        throw 'STOP: declined'
    }

    if ($env:ITBS_TEST_HALT -eq '1') {
        throw 'STOP: halted after confirmation'
    }
}


function Get-Service {
    <#
    .SYNOPSIS
        Records the lookup and returns a fake legacy service when ITBS_TEST_LEGACY is set.
    #>
    [CmdletBinding()]
    param (
        # The service name.
        [string]
        $Name
    )

    Log "GET-SERVICE $Name"
    if ($env:ITBS_TEST_LEGACY -eq '1' -and $Name -eq 'StopThrottle') {
        $service = [pscustomobject]@{ Name = $Name }
        return ($service | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru)
    }

    $null
}


function Get-TuningProcesses {
    <#
    .SYNOPSIS
        Returns no competing tuning processes.
    #>
    @()
}


function Invoke-HardwareSession {
    <#
    .SYNOPSIS
        Records the session instead of touching the hardware.
    #>
    param (
        # The operation that would run, ignored.
        [scriptblock]
        $Operation
    )

    Log 'HARDWARE-SESSION'
}


function Set-ProtectedDirectory {
    <#
    .SYNOPSIS
        Fails the test when an install reaches a mutating step.
    #>
    param (
        # The directory that would be protected.
        [string]
        $Path
    )

    throw 'STOP: unexpected mutating install step'
}


function Assert-Dependencies {
    <#
    .SYNOPSIS
        Accepts any dependencies.
    #>
    param (
        # The dependency directory, ignored.
        $Directory,

        # The dependency pins, ignored.
        $Dependency
    )

    # Intentionally empty: the stub trusts everything.
}


function Write-Step {
    <#
    .SYNOPSIS
        Does nothing; the real helper prints a step line.
    #>
    param (
        # The step text, ignored.
        [string]
        $Message
    )
}


function Write-StepResult {
    <#
    .SYNOPSIS
        Does nothing; the real helper prints a step result.
    #>
    param (
        # The result status, ignored.
        [string]
        $Status = 'OK',

        # The result detail, ignored.
        [string]
        $Detail
    )
}


function Write-StepFailure {
    <#
    .SYNOPSIS
        Prints the failure message so it stays visible in the test output.
    #>
    param (
        # The failure message.
        [string]
        $Message
    )

    Write-Host -Object $Message
}


function Get-TurboSummary {
    <#
    .SYNOPSIS
        Returns a fixed summary instead of reading the register row.
    #>
    param (
        # The register row, ignored.
        $Row
    )

    'Turbo summary (stub).'
}


Export-ModuleMember -Function *
'@
$stubDependencies = @'
$fake = Join-Path -Path $PSScriptRoot -ChildPath 'fake-engine'
$fake
'@
$stubUninstaller = @'
param (
    [string]
    $Action,

    [switch]
    $Interactive
)

if ($Action -ne 'Uninstall' -or -not $Interactive) {
    exit 2
}

Set-Location -LiteralPath $env:SystemRoot
Remove-Item -LiteralPath (Split-Path -Path $PSScriptRoot -Parent) -Recurse -Force
'@


function Invoke-Script {
    <#
    .SYNOPSIS
        Runs a script from the fixture in a child PowerShell process and returns its exit code and call log.
    .DESCRIPTION
        Sets the ITBS_TEST_* environment variables for the child, then restores them. The Environment
        parameter overrides the defaults (administrator, untested CPU, no decline, no halt, no legacy).
    .EXAMPLE
        Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'Read') -Environment @{ ITBS_TEST_ADMIN = '0' }
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Exit and Calls.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The file name of the script inside the fixture.
        [string]
        $Script,

        # The arguments passed to the script.
        [string[]]
        $Arguments = @(),

        # Environment variable overrides for the stub module.
        [hashtable]
        $Environment = @{}
    )

    $log = Join-Path -Path $fixture -ChildPath 'calls.log'
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log
    }

    $saved = @{}
    $settings = @{
        ITBS_TEST_LOG     = $log
        ITBS_TEST_ADMIN   = '1'
        ITBS_TEST_TESTED  = '0'
        ITBS_TEST_DECLINE = '0'
        ITBS_TEST_HALT    = '0'
        ITBS_TEST_LEGACY  = '0'
    }
    foreach ($key in $Environment.Keys) {
        $settings[$key] = $Environment[$key]
    }

    foreach ($key in $settings.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $settings[$key])
    }

    try {
        $powerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptPath = Join-Path -Path $fixture -ChildPath $Script
        $null = & $powerShell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments | Out-String
        $exit = $LASTEXITCODE
    } finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key])
        }
    }

    $lines = @()
    if (Test-Path -LiteralPath $log) {
        $lines = @(Get-Content -LiteralPath $log)
    }

    [pscustomobject]@{
        Exit  = $exit
        Calls = $lines
    }
}


try {
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $fixture -ChildPath 'scripts') -Force
    foreach ($name in 'Install.ps1', 'ITBS.ps1', 'dependencies.json') {
        Copy-Item -LiteralPath (Join-Path -Path $root -ChildPath $name) -Destination $fixture
    }

    $stubModulePath = Join-Path -Path $fixture -ChildPath 'scripts\Common.psm1'
    $stubDependenciesPath = Join-Path -Path $fixture -ChildPath 'scripts\Get-Dependencies.ps1'
    Set-Content -LiteralPath $stubModulePath -Value $stubModule -Encoding ASCII
    Set-Content -LiteralPath $stubDependenciesPath -Value $stubDependencies -Encoding ASCII

    # --- ITBS.ps1 (manual tool) ---
    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'Read')
    Check -Condition (
        $r.Exit -eq 0 -and $r.Calls -contains 'WARN' -and $r.Calls -contains 'HARDWARE-SESSION'
    ) -Message 'Read on an untested CPU should warn and proceed.'
    Check -Condition (-not ($r.Calls -match '^CONFIRM')) -Message 'Read must not require confirmation.'

    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'EnableTurbo')
    Check -Condition (
        $r.Exit -eq 0 -and $r.Calls -contains 'CONFIRM accept=False' -and $r.Calls -contains 'HARDWARE-SESSION'
    ) -Message 'A write without the switch must ask for confirmation.'

    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'DisableTurbo', '-AcceptUntestedRisk')
    Check -Condition (
        $r.Exit -eq 0 -and $r.Calls -contains 'CONFIRM accept=True' -and $r.Calls -contains 'HARDWARE-SESSION'
    ) -Message '-AcceptUntestedRisk must reach the confirmation.'

    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'EnableTurbo') -Environment @{
        ITBS_TEST_DECLINE = '1'
    }
    Check -Condition (
        $r.Exit -ne 0 -and
        $r.Calls -contains 'CONFIRM accept=False' -and
        -not ($r.Calls -contains 'HARDWARE-SESSION')
    ) -Message 'A declined confirmation must stop before any hardware session.'

    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'EnableTurbo') -Environment @{
        ITBS_TEST_TESTED = '1'
    }
    Check -Condition (
        $r.Exit -eq 0 -and
        -not ($r.Calls -contains 'WARN') -and
        -not ($r.Calls -match '^CONFIRM') -and
        $r.Calls -contains 'HARDWARE-SESSION'
    ) -Message 'The tested CPU must not warn or prompt.'

    $acceptArguments = @('-Mode', 'EnableTurbo', '-AcceptUntestedRisk')
    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments $acceptArguments -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Mode EnableTurbo -Interactive -AcceptUntestedRisk'
    ) -Message 'The elevated relaunch must carry -AcceptUntestedRisk.'
    $r = Invoke-Script -Script 'ITBS.ps1' -Arguments @('-Mode', 'EnableTurbo') -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Mode EnableTurbo -Interactive'
    ) -Message 'The elevated relaunch must not add -AcceptUntestedRisk by itself.'

    # --- Install.ps1 (stops at the confirmation; every later step is unreachable) ---
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @() -Environment @{
        ITBS_TEST_HALT = '1'
    }
    Check -Condition (
        $r.Exit -ne 0 -and $r.Calls -contains 'INTEL' -and $r.Calls -contains 'CONFIRM accept=False'
    ) -Message 'Install must check the CPU and ask for confirmation.'
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @('-AcceptUntestedRisk') -Environment @{
        ITBS_TEST_HALT = '1'
    }
    Check -Condition (
        $r.Calls -contains 'CONFIRM accept=True'
    ) -Message 'Install must pass -AcceptUntestedRisk to the confirmation.'
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @() -Environment @{
        ITBS_TEST_DECLINE = '1'
    }
    Check -Condition (
        $r.Exit -ne 0 -and -not ($r.Calls -match '^GET-SERVICE')
    ) -Message 'A declined install must stop before touching the service.'
    # A pre-release installation under the old name must stop the install before anything is changed.
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @('-AcceptUntestedRisk') -Environment @{
        ITBS_TEST_LEGACY = '1'
    }
    Check -Condition (
        $r.Exit -ne 0 -and
        $r.Calls -contains 'GET-SERVICE StopThrottle' -and
        -not ($r.Calls -contains 'GET-SERVICE ITBS')
    ) -Message 'A legacy installation must block a new install.'
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @('-AcceptUntestedRisk') -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Action Install -Interactive -AcceptUntestedRisk'
    ) -Message 'Install relaunch must carry -AcceptUntestedRisk.'
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @('-OnFailure', 'Fail') -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Action Install -Interactive -OnFailure Fail'
    ) -Message 'Install relaunch must carry -OnFailure.'
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @() -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Action Install -Interactive'
    ) -Message 'Install relaunch must not add -AcceptUntestedRisk by itself.'

    # --- Uninstall.cmd ---
    $r = Invoke-Script -Script 'Install.ps1' -Arguments @('-Action', 'Uninstall') -Environment @{
        ITBS_TEST_ADMIN = '0'
    }
    Check -Condition (
        $r.Calls -contains 'ELEVATE -Action Uninstall -Interactive'
    ) -Message 'Uninstall must relaunch elevated.'

    # Run the REAL Uninstall.cmd, started inside its own folder like a double-click, against a stub
    # Install.ps1 that deletes the whole folder. This proves the batch file can remove the install
    # directory it lives in without leaving the console with an error.
    $removable = Join-Path -Path $testRoot -ChildPath ('uninstall-' + [Guid]::NewGuid().ToString('N'))
    try {
        $removableSource = Join-Path -Path $removable -ChildPath 'source'
        $null = New-Item -ItemType Directory -Path $removableSource -Force
        Copy-Item -LiteralPath (Join-Path -Path $root -ChildPath 'Uninstall.cmd') -Destination $removableSource
        $uninstallerPath = Join-Path -Path $removableSource -ChildPath 'Install.ps1'
        Set-Content -LiteralPath $uninstallerPath -Encoding ASCII -Value $stubUninstaller
        $outFile = Join-Path -Path $testRoot -ChildPath ('uninstall-' + [Guid]::NewGuid().ToString('N') + '.out')
        $errFile = $outFile + '.err'
        $uninstallCmd = Join-Path -Path $removableSource -ChildPath 'Uninstall.cmd'
        $startArguments = @{
            FilePath               = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
            ArgumentList           = '/c', ('"' + $uninstallCmd + '"')
            WorkingDirectory       = $removableSource
            Wait                   = $true
            PassThru               = $true
            WindowStyle            = 'Hidden'
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        $cmd = Start-Process @startArguments
        Check -Condition (
            $cmd.ExitCode -eq 0
        ) -Message 'Uninstall.cmd should exit cleanly after removing its own folder.'
        Check -Condition (
            -not (Test-Path -LiteralPath $removable)
        ) -Message 'Uninstall.cmd should be able to delete the folder it runs from.'
        $errText = [string](Get-Content -LiteralPath $errFile -Raw)
        Check -Condition (
            $errText -notmatch '\S'
        ) -Message 'Uninstall.cmd should not print errors after the folder is gone.'
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $removable) {
            Remove-Item -LiteralPath $removable -Recurse -Force
        }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $rootPrefix = $testRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected test cleanup target.'
    }

    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

$summary = "PASS: $script:checks script-wiring assertions; stub module only, no hardware, service, or elevation."
Write-Host -Object $summary
