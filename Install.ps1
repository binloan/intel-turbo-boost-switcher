#requires -Version 5.1
<#
.SYNOPSIS
    Installs, uninstalls or inspects the Intel TurboBoost Switcher (ITBS) Windows service.
.DESCRIPTION
    Elevates itself when needed. An install copies the source into a protected folder, compiles the
    service on this machine, registers it with recovery actions and waits until it reports that Turbo
    is enabled. An uninstall removes the service, the installed files and the Installed apps entry.
    Status and Verify do not need elevation.

    The default output is a short list of steps with their results. Use -Verbose to see the details.
.EXAMPLE
    .\Install.ps1

    Installs the service after the CPU checks.
.EXAMPLE
    .\Install.ps1 -Verbose

    Installs the service and shows the details of every step.
.EXAMPLE
    .\Install.ps1 -Action Uninstall

    Removes the service, the installed files and the Installed apps entry.
.EXAMPLE
    .\Install.ps1 -Action Status

    Shows the service state and the last recorded verification.
#>
[CmdletBinding()]
param (
    # The operation to run: Install, Uninstall, Status or Verify.
    [ValidateSet('Install', 'Uninstall', 'Status', 'Verify')]
    [string]
    $Action = 'Install',

    # Downloads the dependencies again even if a cached copy exists.
    [switch]
    $RefreshDownloads,

    # Keeps the console open for prompts. Set automatically when the script relaunches itself elevated.
    [switch]
    $Interactive,

    # Accepts the risk of installing on a CPU that has not been tested, without asking.
    [switch]
    $AcceptUntestedRisk,

    # What the service does when applying Turbo fails. Asked interactively when omitted.
    [ValidateSet('Retry', 'Fail')]
    [string]
    $OnFailure
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Common.psm1') -Force -Verbose:$false
$InstallRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'ITBS'
$ServiceExe = Join-Path -Path $InstallRoot -ChildPath 'ITBS.Service.exe'
$Data = Join-Path -Path $env:ProgramData -ChildPath 'ITBS'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ITBS'


function Assert-OwnedService {
    <#
    .SYNOPSIS
        Throws when the ITBS service name belongs to a different installation.
    .DESCRIPTION
        Compares the registered image path of the ITBS service with the executable of this installation.
        Does nothing when the service does not exist.
    .EXAMPLE
        Assert-OwnedService
    #>
    [CmdletBinding()]
    param ()

    $key = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\ITBS' -ErrorAction SilentlyContinue
    if ($key) {
        $expectedImagePath = '"{0}" --service' -f $ServiceExe
        Write-Verbose -Message "Service ImagePath: $($key.ImagePath); expected: $expectedImagePath"
        if ($key.ImagePath -ne $expectedImagePath) {
            throw 'The ITBS service name belongs to a different installation.'
        }
    }
}


function Get-LegacyInstallation {
    <#
    .SYNOPSIS
        Describes a pre-release installation under the old name, if one exists.
    .DESCRIPTION
        Pre-release builds used the name "StopThrottle". They are never touched automatically; this only
        detects them so the user can remove them deliberately. Emits a message string, or nothing.
    .EXAMPLE
        Get-LegacyInstallation
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $found = @()
    $legacyService = Get-Service -Name StopThrottle -ErrorAction SilentlyContinue
    if ($legacyService) {
        $legacyService.Dispose()
        $found += 'the Windows service "StopThrottle"'
    }
    if (Test-Path -LiteralPath (Join-Path -Path $env:ProgramFiles -ChildPath 'StopThrottle')) {
        $found += 'the folder "%ProgramFiles%\StopThrottle"'
    }
    Write-Verbose -Message "Pre-release installation items found: $($found.Count)"
    if ($found.Count) {
        'A pre-release installation under the old name was found: ' + ($found -join ' and ') +
            '. Remove it first from an elevated PowerShell: ' +
            'Stop-Service StopThrottle; sc.exe delete StopThrottle; then delete the folder. ' +
            'Its data under %ProgramData%\StopThrottle is not used anymore and may be deleted.'
    }
}


function Remove-OwnedInstallation {
    <#
    .SYNOPSIS
        Deletes the installation folder after verifying the target.
    .DESCRIPTION
        Refuses to delete anything but the expected folder under Program Files, and refuses a folder that
        is, or contains, a reparse point.
    .EXAMPLE
        Remove-OwnedInstallation
    #>
    [CmdletBinding()]
    param ()

    # Never hold the folder open: the uninstaller itself runs from inside it.
    Set-Location -LiteralPath $env:SystemRoot
    # Verify the absolute recursive-delete target and reject redirected children.
    $expected = [IO.Path]::GetFullPath((Join-Path -Path $env:ProgramFiles -ChildPath 'ITBS'))
    if ([IO.Path]::GetFullPath($InstallRoot) -ne $expected) {
        throw 'Unexpected uninstall target.'
    }
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        Write-Verbose -Message "Installation folder does not exist: $InstallRoot"
        return
    }
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing redirected uninstall target.'
    }
    $redirected = @(
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    )
    if ($redirected.Count) {
        throw 'Refusing to delete installation containing redirected files/directories.'
    }
    Write-Verbose -Message "Deleting the installation folder: $InstallRoot"
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}


function Remove-OwnedService {
    <#
    .SYNOPSIS
        Stops and deletes the ITBS service when it belongs to this installation.
    .DESCRIPTION
        Does nothing when the service does not exist. Waits up to 35 seconds for the service to stop.
    .EXAMPLE
        Remove-OwnedService
    #>
    [CmdletBinding()]
    param ()

    $service = Get-Service -Name ITBS -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Verbose -Message 'The ITBS service does not exist.'
        return
    }
    try {
        Assert-OwnedService
        if ($service.Status -ne 'Stopped') {
            Write-Verbose -Message 'Stopping the ITBS service.'
            Stop-Service -Name ITBS
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(35))
        }
    } finally {
        $service.Dispose()
    }
    $result = & "$env:SystemRoot\System32\sc.exe" delete ITBS 2>&1
    Write-Verbose -Message "sc.exe delete ITBS (exit code $LASTEXITCODE): $result"
    if ($LASTEXITCODE -ne 0) {
        throw "Service removal failed: $result"
    }
}


function Show-Status {
    <#
    .SYNOPSIS
        Shows the service state and the last recorded verification.
    .DESCRIPTION
        Writes for the person at the console. The status is the last recorded verification, not the
        current hardware state.
    .EXAMPLE
        Show-Status
    #>
    [CmdletBinding()]
    param ()

    Write-Host -Object 'Intel TurboBoost Switcher - status'
    $service = Get-Service -Name ITBS -ErrorAction SilentlyContinue
    if ($service) {
        try {
            Write-Host -Object ('  Windows service: ' + $service.Status)
        } finally {
            $service.Dispose()
        }
    } else {
        Write-Host -Object '  The Intel TurboBoost Switcher service (ITBS) is not installed.'
    }
    $status = Join-Path -Path $Data -ChildPath 'status.json'
    if (Test-Path -LiteralPath $status) {
        $statusText = Get-Content -LiteralPath $status -Raw
        Write-Verbose -Message "Contents of ${status}:"
        Write-Verbose -Message "$statusText"
        try {
            $health = $statusText | ConvertFrom-Json
            Write-Host -Object (
                "  Last recorded verification: $($health.State) at $($health.AttemptUtc). $($health.Message)"
            )
        } catch {
            $statusFailure = $_.Exception.Message
            Write-Verbose -Message "Could not parse ${status}: $statusFailure"
            Write-Host -Object '  Last recorded verification: status.json is unreadable. Use -Verbose to see it.'
        }
    } else {
        Write-Host -Object '  No verification has been recorded yet.'
    }
    Write-Host -Object (
        '  Status is the last recorded verification. Use ITBS.ps1 -Mode Read for current hardware state.'
    )
}


if ($Action -eq 'Status') {
    Show-Status
    return
}
if ($Action -eq 'Verify') {
    $verifyParameters = @{
        OutputDirectory     = $InstallRoot
        SourceDirectory     = Join-Path -Path $InstallRoot -ChildPath 'source'
        DependencyDirectory = Join-Path -Path $InstallRoot -ChildPath 'engine'
    }
    Write-Step -Message 'Verifying installed files against the build record'
    try {
        # The message that Test-RecordedBuild writes to the host would interrupt the step line.
        $verifyMessages = Test-RecordedBuild @verifyParameters 6>&1
    } catch {
        $failure = $_.Exception.Message
        Write-StepFailure -Message $failure
        exit 1
    }
    Write-Verbose -Message "$verifyMessages"
    Write-StepResult -Detail 'source, service and dependency hashes match'
    return
}
if (-not (Test-Administrator)) {
    $arguments = '-Action ' + $Action + ' -Interactive'
    if ($RefreshDownloads) {
        $arguments += ' -RefreshDownloads'
    }
    if ($AcceptUntestedRisk) {
        $arguments += ' -AcceptUntestedRisk'
    }
    if ($OnFailure) {
        $arguments += ' -OnFailure ' + $OnFailure
    }
    if ($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose']) {
        $arguments += ' -Verbose'
    }
    Write-Verbose -Message "Relaunching elevated: $arguments"
    exit (Invoke-ElevatedScript -ScriptPath $PSCommandPath -Arguments $arguments)
}
$createdService = $false
$createdDirectory = $false
try {
    if ($Action -eq 'Uninstall') {
        Write-Host -Object 'Intel TurboBoost Switcher - uninstall'
        if ($Interactive) {
            $uninstallPrompt = 'Press Enter to uninstall Intel TurboBoost Switcher (close this window to cancel)'
            $null = Read-Host -Prompt $uninstallPrompt
        }
        $legacy = Get-LegacyInstallation
        if ($legacy) {
            Write-Host -Object $legacy -ForegroundColor Yellow
        }
        Write-Step -Message 'Stopping and removing the service'
        Assert-OwnedService
        # A marker or a matching service registration is required before cleanup.
        $markerPath = Join-Path -Path $InstallRoot -ChildPath 'install-info.json'
        if ((Test-Path -LiteralPath $InstallRoot) -and -not (Test-Path -LiteralPath $markerPath)) {
            if (-not (Get-Service -Name ITBS -ErrorAction SilentlyContinue)) {
                throw 'No owned-installation marker or service exists; refusing directory deletion.'
            }
        }
        Remove-OwnedService
        Write-StepResult
        Write-Step -Message 'Removing installed files'
        Remove-OwnedInstallation
        Write-StepResult
        Write-Step -Message 'Removing the Installed apps entry'
        # A warning must not appear inside the open step, so it is captured and shown afterwards.
        $removeParameters = @{
            KeyPath         = $UninstallKey
            InstallRoot     = $InstallRoot
            WarningAction   = 'SilentlyContinue'
            WarningVariable = 'removeWarning'
        }
        Remove-UninstallEntry @removeParameters
        Write-StepResult
        foreach ($warningRecord in $removeWarning) {
            Write-Warning -Message $warningRecord.Message
        }
        Write-Host -Object 'Uninstalled. The current CPU Turbo bit state, logs and policy backups are retained.'
    } else {
        Write-Host -Object 'Intel TurboBoost Switcher - install'
        Write-Step -Message 'Checking processor'
        $cpu = Assert-IntelCpu
        $cpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        Write-StepResult -Detail ('{0}, {1} logical processors' -f $cpuName, $cpu.LogicalProcessors)
        # The untested-processor warning and its prompt must not appear inside an open step.
        Confirm-UntestedCpu -Info $cpu -AcceptRisk:$AcceptUntestedRisk
        Write-Step -Message 'Checking for competing tools and earlier installs'
        $competing = @(Get-TuningProcesses)
        Write-Verbose -Message "Competing tuning processes found: $($competing.Count)"
        if ($competing.Count) {
            throw ('Close competing tools: ' + ($competing -join ', '))
        }
        $legacy = Get-LegacyInstallation
        if ($legacy) {
            throw $legacy
        }
        $existing = Get-Service -Name ITBS -ErrorAction SilentlyContinue
        if ($existing) {
            $existing.Dispose()
            Assert-OwnedService
            throw (
                'Intel TurboBoost Switcher is already installed. ' +
                'Uninstall before installing a new locally compiled build.'
            )
        }
        if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count) {
            throw 'Installation directory is not empty. Run -Action Uninstall for an owned installation first.'
        }
        Write-StepResult
        # The failure-policy prompt must not appear inside an open step.
        $policy = Resolve-FailurePolicy -OnFailure $OnFailure -Interactive:$Interactive
        Write-Verbose -Message "Failure policy: $policy"
        Write-Step -Message 'Preparing engine (download if needed)'
        $dependenciesScript = Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Get-Dependencies.ps1'
        # The download message of the script would interrupt the step line.
        $download = & $dependenciesScript -RefreshDownloads:$RefreshDownloads 6>$null
        Write-Verbose -Message "Engine directory: $download"
        Write-StepResult
        Write-Step -Message 'Copying files'
        Write-Verbose -Message "Installation folder: $InstallRoot"
        Set-ProtectedDirectory -Path $InstallRoot
        $createdDirectory = $true
        $installInfo = [ordered]@{
            Type         = 'ITBSSourceInstall'
            Version      = 1
            InstalledUtc = [DateTime]::UtcNow.ToString('o')
        }
        $installInfo |
            ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path -Path $InstallRoot -ChildPath 'install-info.json') -Encoding UTF8
        $configPath = Join-Path -Path $InstallRoot -ChildPath 'config.json'
        Write-ServiceConfig -Path $configPath -OnFailure $policy
        Write-Verbose -Message "Wrote the service configuration: $configPath"
        $source = Join-Path -Path $InstallRoot -ChildPath 'source'
        Set-ProtectedDirectory -Path $source
        $files = @(
            'Install.ps1'
            'Install.cmd'
            'Uninstall.cmd'
            'ITBS.ps1'
            'ITBS.cmd'
            'build.ps1'
            'dependencies.json'
            'README.md'
            'LICENSE'
            'THIRD-PARTY-NOTICES.txt'
        )
        $files += @(
            'src\app.manifest'
            'scripts\Common.psm1'
            'scripts\Get-Dependencies.ps1'
            'scripts\Set-LegacyDriverPolicy.ps1'
            'tests\Tests.cs'
            'tests\Test-Manual.ps1'
            'tests\Test-Scripts.ps1'
        )
        $sourceFiles = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'src') -Filter '*.cs'
        $files += @($sourceFiles.Name | ForEach-Object { 'src\' + $_ })
        foreach ($relative in $files) {
            $target = Join-Path -Path $source -ChildPath $relative
            Write-Verbose -Message "Copying $relative to $target"
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
            Copy-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath $relative) -Destination $target
        }
        $noticesPath = Join-Path -Path $source -ChildPath 'THIRD-PARTY-NOTICES.txt'
        Copy-Item -LiteralPath $noticesPath -Destination $InstallRoot
        $engine = Join-Path -Path $InstallRoot -ChildPath 'engine'
        Set-ProtectedDirectory -Path $engine
        $dependencyFile = Join-Path -Path $source -ChildPath 'dependencies.json'
        $dependency = (Get-Content -LiteralPath $dependencyFile -Raw | ConvertFrom-Json).msrUtility
        foreach ($file in $dependency.files.PSObject.Properties) {
            Write-Verbose -Message "Copying engine file $($file.Name) to $engine"
            Copy-Item -LiteralPath (Join-Path -Path $download -ChildPath $file.Name) -Destination $engine
        }
        Assert-Dependencies -Directory $engine -Dependency $dependency
        Write-StepResult
        # Compile the protected, installed source on THIS machine. No project EXE
        # from a downloaded package or another build directory is accepted.
        $buildScript = Join-Path -Path $source -ChildPath 'build.ps1'
        Write-Host -Object 'Building and testing the service from source:'
        & $buildScript -DependencyDirectory $engine -OutputDirectory $InstallRoot -FromInstaller
        Write-Step -Message 'Registering and starting the service'
        Set-ProtectedDirectory -Path $Data
        $binary = '"{0}" --service' -f $ServiceExe
        $serviceParameters = @{
            Name           = 'ITBS'
            BinaryPathName = $binary
            DisplayName    = 'Intel TurboBoost Switcher'
            StartupType    = 'Automatic'
        }
        $newService = New-Service @serviceParameters
        $newService.Dispose()
        $createdService = $true
        $recoveryArguments = @(
            'failure'
            'ITBS'
            'reset='
            '86400'
            'actions='
            'restart/10000/restart/30000/restart/60000'
        )
        $result = & "$env:SystemRoot\System32\sc.exe" @recoveryArguments 2>&1
        Write-Verbose -Message "sc.exe failure ITBS (exit code $LASTEXITCODE): $result"
        if ($LASTEXITCODE -ne 0) {
            throw "Could not configure recovery: $result"
        }
        $since = [DateTime]::UtcNow.AddSeconds(-1)
        Start-Service -Name ITBS
        $service = Get-Service -Name ITBS
        try {
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        } finally {
            $service.Dispose()
        }
        Write-StepResult
        Write-Step -Message 'Verifying Turbo is enabled'
        $timeout = [Diagnostics.Stopwatch]::StartNew()
        $verified = $false
        while ($timeout.Elapsed.TotalSeconds -lt 45) {
            $statusPath = Join-Path -Path $Data -ChildPath 'status.json'
            if (Test-Path -LiteralPath $statusPath) {
                $health = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                if ([DateTime]::Parse($health.AttemptUtc).ToUniversalTime() -ge $since) {
                    if ($health.State -eq 'Enabled') {
                        $verified = $true
                        break
                    }
                    if ($health.State -in @('Error', 'Waiting')) {
                        throw $health.Message
                    }
                }
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $verified) {
            throw 'Service did not verify Turbo in time. Inspect ProgramData\ITBS\status.json.'
        }
        Write-Verbose -Message "Verified status: $($health.State). $($health.Message)"
        Write-StepResult -Detail 'verified on all logical processors'
        Write-Step -Message 'Registering in Installed apps'
        $uninstallCommand = '"{0}"' -f (Join-Path -Path $source -ChildPath 'Uninstall.cmd')
        New-UninstallEntry -KeyPath $UninstallKey -InstallRoot $InstallRoot -UninstallString $uninstallCommand
        Write-StepResult
        $policyDescription = if ($policy -eq 'Retry') { 'retry automatically' } else { 'fail directly, no retry' }
        $buildRecordPath = Join-Path -Path $InstallRoot -ChildPath 'build-record.json'
        Write-Verbose -Message "Installed locally compiled service. Source: $source"
        Write-Verbose -Message "If applying Turbo fails: $policyDescription. Setting: $configPath"
        Write-Verbose -Message "Build audit record: $buildRecordPath"
        $retryText = if ($policy -eq 'Retry') { 'on' } else { 'off' }
        Write-Host -Object "Installed. Turbo is enabled. Retry on failure: $retryText."
        Write-Host -Object 'Remove with Uninstall.cmd or Settings > Apps > Installed apps.'
    }
} catch {
    $failure = $_.Exception.Message
    # A warning of the rollback must not appear inside an open step, so it is shown after the failure.
    $rollbackWarning = @()
    if ($Action -eq 'Install' -and $createdDirectory) {
        try {
            if ($createdService) {
                Remove-OwnedService
            }
            Remove-OwnedInstallation
            $rollbackParameters = @{
                KeyPath         = $UninstallKey
                InstallRoot     = $InstallRoot
                WarningAction   = 'SilentlyContinue'
                WarningVariable = 'rollbackWarning'
            }
            Remove-UninstallEntry @rollbackParameters
        } catch {
            $rollbackMessage = $_.Exception.Message
            $failure += " Rollback incomplete: $rollbackMessage"
        }
    }
    Write-StepFailure -Message $failure
    foreach ($warningRecord in $rollbackWarning) {
        Write-Warning -Message $warningRecord.Message
    }
    if ($Interactive) {
        $null = Read-Host -Prompt 'Press Enter to close'
    }
    exit 1
}
if ($Interactive) {
    $null = Read-Host -Prompt 'Press Enter to close'
}
