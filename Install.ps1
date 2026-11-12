#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Install','Uninstall','Status','Verify')][string]$Action = 'Install',
    [switch]$RefreshDownloads, [switch]$Interactive, [switch]$AcceptUntestedRisk,
    [ValidateSet('Retry','Fail')][string]$OnFailure)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Common.psm1') -Force
$installRoot=Join-Path $env:ProgramFiles 'ITBS'
$serviceExe=Join-Path $installRoot 'ITBS.Service.exe'
$data=Join-Path $env:ProgramData 'ITBS'
$uninstallKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ITBS'

function Assert-OwnedService {
    $key=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\ITBS' -ErrorAction SilentlyContinue
    if ($key) {
        if ($key.ImagePath -ne ('"{0}" --service' -f $serviceExe)) { throw 'The ITBS service name belongs to a different installation.' }
    }
}
# Pre-release builds used the name "StopThrottle". They are never touched automatically;
# this only detects them so the user can remove them deliberately.
function Get-LegacyInstallation {
    $found=@()
    $legacyService=Get-Service -Name StopThrottle -ErrorAction SilentlyContinue
    if ($legacyService) { $legacyService.Dispose(); $found+='the Windows service "StopThrottle"' }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'StopThrottle')) { $found+='the folder "%ProgramFiles%\StopThrottle"' }
    if ($found.Count) {
        'A pre-release installation under the old name was found: ' + ($found -join ' and ') + '. Remove it first from an elevated PowerShell: ' +
        'Stop-Service StopThrottle; sc.exe delete StopThrottle; then delete the folder. Its data under %ProgramData%\StopThrottle is not used anymore and may be deleted.'
    }
}
function Remove-OwnedInstallation {
    # Never hold the folder open: the uninstaller itself runs from inside it.
    Set-Location -LiteralPath $env:SystemRoot
    # Verify the absolute recursive-delete target and reject redirected children.
    $expected=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'ITBS'))
    if ([IO.Path]::GetFullPath($installRoot) -ne $expected) { throw 'Unexpected uninstall target.' }
    if (-not (Test-Path -LiteralPath $installRoot)) { return }
    $rootItem=Get-Item -LiteralPath $installRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing redirected uninstall target.' }
    $redirected=@(Get-ChildItem -LiteralPath $installRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($redirected.Count) { throw 'Refusing to delete installation containing redirected files/directories.' }
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
function Remove-OwnedService {
    $service=Get-Service -Name ITBS -ErrorAction SilentlyContinue
    if (-not $service) { return }
    try {
        Assert-OwnedService
        if ($service.Status -ne 'Stopped') {
            Stop-Service ITBS
            $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(35))
        }
    } finally { $service.Dispose() }
    $result=& "$env:SystemRoot\System32\sc.exe" delete ITBS 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Service removal failed: $result" }
}
function Show-Status {
    $service=Get-Service -Name ITBS -ErrorAction SilentlyContinue
    if ($service) { try { Write-Host ('Windows service: ' + $service.Status) } finally { $service.Dispose() } }
    else { Write-Host 'The Intel TurboBoost Switcher service (ITBS) is not installed.' }
    $status=Join-Path $data 'status.json'
    if (Test-Path -LiteralPath $status) { Get-Content -LiteralPath $status }
    Write-Host 'Status is the last recorded verification. Use ITBS.ps1 -Mode Read for current hardware state.'
}
if ($Action -eq 'Status') { Show-Status; return }
if ($Action -eq 'Verify') {
    Test-RecordedBuild -OutputDirectory $installRoot -SourceDirectory (Join-Path $installRoot 'source') -DependencyDirectory (Join-Path $installRoot 'engine')
    return
}
if (-not (Test-Administrator)) {
    $arguments='-Action ' + $Action + ' -Interactive'
    if ($RefreshDownloads) { $arguments+=' -RefreshDownloads' }
    if ($AcceptUntestedRisk) { $arguments+=' -AcceptUntestedRisk' }
    if ($OnFailure) { $arguments+=' -OnFailure ' + $OnFailure }
    exit (Invoke-ElevatedScript -ScriptPath $PSCommandPath -Arguments $arguments)
}
$createdService=$false; $createdDirectory=$false
try {
    if ($Action -eq 'Uninstall') {
        if ($Interactive) { $null=Read-Host 'Press Enter to uninstall Intel TurboBoost Switcher (close this window to cancel)' }
        $legacy=Get-LegacyInstallation
        if ($legacy) { Write-Host $legacy -ForegroundColor Yellow }
        Assert-OwnedService
        # A marker or a matching service registration is required before cleanup.
        if ((Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'install-info.json'))) {
            if (-not (Get-Service -Name ITBS -ErrorAction SilentlyContinue)) { throw 'No owned-installation marker or service exists; refusing directory deletion.' }
        }
        Remove-OwnedService
        Remove-OwnedInstallation
        Remove-UninstallEntry $uninstallKey $installRoot
        Write-Host 'Service, installed files and the Installed apps entry removed. Current CPU bit state, logs, and optional policy backups are retained.'
    } else {
        $cpu=Assert-IntelCpu
        Confirm-UntestedCpu $cpu -AcceptRisk:$AcceptUntestedRisk
        $competing=@(Get-TuningProcesses)
        if ($competing.Count) { throw ('Close competing tools: ' + ($competing -join ', ')) }
        $legacy=Get-LegacyInstallation
        if ($legacy) { throw $legacy }
        $existing=Get-Service -Name ITBS -ErrorAction SilentlyContinue
        if ($existing) { $existing.Dispose(); Assert-OwnedService; throw 'Intel TurboBoost Switcher is already installed. Uninstall before installing a new locally compiled build.' }
        if ((Test-Path -LiteralPath $installRoot) -and @(Get-ChildItem -LiteralPath $installRoot -Force).Count) { throw 'Installation directory is not empty. Run -Action Uninstall for an owned installation first.' }
        $policy=Resolve-FailurePolicy $OnFailure -Interactive:$Interactive
        $download=& (Join-Path $PSScriptRoot 'scripts\Get-Dependencies.ps1') -RefreshDownloads:$RefreshDownloads
        Set-ProtectedDirectory $installRoot
        $createdDirectory=$true
        [ordered]@{ Type='ITBSSourceInstall'; Version=1; InstalledUtc=[DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'install-info.json') -Encoding UTF8
        Write-ServiceConfig (Join-Path $installRoot 'config.json') $policy
        $source=Join-Path $installRoot 'source'
        Set-ProtectedDirectory $source
        $files=@('Install.ps1','Install.cmd','Uninstall.cmd','ITBS.ps1','ITBS.cmd','build.ps1','dependencies.json','README.md','LICENSE','THIRD-PARTY-NOTICES.txt')
        $files+=@('src\app.manifest','scripts\Common.psm1','scripts\Get-Dependencies.ps1','scripts\Set-LegacyDriverPolicy.ps1','tests\Tests.cs','tests\Test-Manual.ps1','tests\Test-Scripts.ps1')
        $files+=@((Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs').Name | ForEach-Object { 'src\' + $_ })
        foreach ($relative in $files) {
            $target=Join-Path $source $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path $source 'THIRD-PARTY-NOTICES.txt') -Destination $installRoot
        $engine=Join-Path $installRoot 'engine'
        Set-ProtectedDirectory $engine
        $dependency=(Get-Content -LiteralPath (Join-Path $source 'dependencies.json') -Raw | ConvertFrom-Json).msrUtility
        foreach ($file in $dependency.files.PSObject.Properties) { Copy-Item -LiteralPath (Join-Path $download $file.Name) -Destination $engine }
        Assert-Dependencies $engine $dependency
        # Compile the protected, installed source on THIS machine. No project EXE
        # from a downloaded package or another build directory is accepted.
        & (Join-Path $source 'build.ps1') -DependencyDirectory $engine -OutputDirectory $installRoot
        Set-ProtectedDirectory $data
        $binary='"{0}" --service' -f $serviceExe
        $newService=New-Service -Name ITBS -BinaryPathName $binary -DisplayName 'Intel TurboBoost Switcher' -StartupType Automatic
        $newService.Dispose()
        $createdService=$true
        $result=& "$env:SystemRoot\System32\sc.exe" failure ITBS reset= 86400 actions= restart/10000/restart/30000/restart/60000 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not configure recovery: $result" }
        $since=[DateTime]::UtcNow.AddSeconds(-1)
        Start-Service ITBS
        $service=Get-Service ITBS
        try { $service.WaitForStatus('Running',[TimeSpan]::FromSeconds(30)) } finally { $service.Dispose() }
        $timeout=[Diagnostics.Stopwatch]::StartNew()
        $verified=$false
        while ($timeout.Elapsed.TotalSeconds -lt 45) {
            $statusPath=Join-Path $data 'status.json'
            if (Test-Path -LiteralPath $statusPath) {
                $health=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                if ([DateTime]::Parse($health.AttemptUtc).ToUniversalTime() -ge $since) {
                    if ($health.State -eq 'Enabled') { $verified=$true; break }
                    if ($health.State -in @('Error','Waiting')) { throw $health.Message }
                }
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $verified) { throw 'Service did not verify Turbo in time. Inspect ProgramData\ITBS\status.json.' }
        New-UninstallEntry $uninstallKey $installRoot ('"{0}"' -f (Join-Path $source 'Uninstall.cmd'))
        Write-Host "Installed locally compiled service. Source: $source"
        Write-Host 'To remove it: run Uninstall.cmd, or use Settings > Apps > Installed apps > Intel TurboBoost Switcher.'
        Write-Host "If applying Turbo fails: $(if ($policy -eq 'Retry') { 'retry automatically' } else { 'fail directly, no retry' }). Setting: $(Join-Path $installRoot 'config.json')"
        Write-Host "Build audit record: $(Join-Path $installRoot 'build-record.json')"
    }
} catch {
    $failure=$_.Exception.Message
    if ($Action -eq 'Install' -and $createdDirectory) {
        try { if ($createdService) { Remove-OwnedService }; Remove-OwnedInstallation; Remove-UninstallEntry $uninstallKey $installRoot }
        catch { $failure+=" Rollback incomplete: $($_.Exception.Message)" }
    }
    Write-Host $failure -ForegroundColor Red
    if ($Interactive) { $null=Read-Host 'Press Enter to close' }
    exit 1
}
if ($Interactive) { $null=Read-Host 'Press Enter to close' }
