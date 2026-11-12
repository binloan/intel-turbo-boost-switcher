#requires -Version 5.1
Set-StrictMode -Version 2

function Test-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Invoke-ElevatedScript {
    param([string]$ScriptPath, [string]$Arguments)
    $nativeArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath,$Arguments
    # This is an explicitly interactive user launcher, not a background helper.
    $child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -WindowStyle Normal -ArgumentList $nativeArguments -PassThru
    $child.WaitForExit()
    $child.ExitCode
}
$script:TestedCpu = 'Intel Core i5-12450H'
function ConvertTo-CpuInfo {
    param([string]$Name, [string]$Identifier, [string]$Vendor, [int]$LogicalProcessors)
    [pscustomobject]@{
        Name=$Name; Identifier=$Identifier; Vendor=$Vendor; LogicalProcessors=$LogicalProcessors
        Tested=($Name -match '\bi5-12450H\b' -and $Identifier -match 'Family 6 Model 154\b' -and $LogicalProcessors -eq 12)
    }
}
function Get-CpuInfo {
    $key = Get-Item -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor'
    $count = @(Get-ChildItem -LiteralPath $key.PSPath).Count
    $cpu = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    ConvertTo-CpuInfo ([string]$cpu.ProcessorNameString).Trim() ([string]$cpu.Identifier) ([string]$cpu.VendorIdentifier) $count
}
# Hard gate: bit 38 of IA32_MISC_ENABLE is Intel-specific and msr-cmd is addressed
# at processor group 0 only (at most 64 logical processors). Other Intel CPUs are
# allowed after a warning; see Confirm-UntestedCpu.
function Assert-IntelCpu {
    param([pscustomobject]$Info = (Get-CpuInfo))
    if ($Info.Vendor -ne 'GenuineIntel') { throw "This tool supports Intel processors only (found '$($Info.Vendor)')." }
    if ($Info.LogicalProcessors -lt 1 -or $Info.LogicalProcessors -gt 64) {
        throw "Unsupported logical processor count ($($Info.LogicalProcessors)); only 1-64 processors in group 0 are supported."
    }
    $Info
}
function Write-UntestedWarning {
    param([pscustomobject]$Info)
    Write-Host ''
    Write-Host 'WARNING: UNTESTED PROCESSOR' -ForegroundColor Yellow
    Write-Host ("Detected: {0} ({1}, {2} logical processors)." -f $Info.Name,$Info.Identifier,$Info.LogicalProcessors) -ForegroundColor Yellow
    Write-Host ("Intel TurboBoost Switcher has only ever been tested on the $script:TestedCpu with 12 logical processors.") -ForegroundColor Yellow
    Write-Host 'It was NEVER tested on this system. Writing a CPU model-specific register can cause' -ForegroundColor Yellow
    Write-Host 'instability, overheating, data loss or hardware problems. You use it entirely at your own risk;' -ForegroundColor Yellow
    Write-Host 'the software is provided without warranty (see LICENSE).' -ForegroundColor Yellow
    Write-Host ''
}
# Shows the warning and requires explicit acceptance on an untested CPU.
# -AcceptRisk is for unattended use and still prints the warning.
function Confirm-UntestedCpu {
    param([pscustomobject]$Info, [switch]$AcceptRisk)
    if ($Info.Tested) { return }
    Write-UntestedWarning $Info
    if ($AcceptRisk) { Write-Host 'Risk accepted with -AcceptUntestedRisk.' -ForegroundColor Yellow; return }
    $answer = $null
    try { $answer = Read-Host 'Type YES to continue at your own risk' } catch { }
    if ($answer -cne 'YES') { throw 'Cancelled: the untested-processor risk was not accepted. For unattended use, pass -AcceptUntestedRisk.' }
}
# What the service does when applying Turbo fails or is blocked: 'Retry' (after 1, 5, 15,
# then every 30 minutes) or 'Fail' (record the error and wait). Default is Retry; an
# interactive install asks.
function Resolve-FailurePolicy {
    param([string]$OnFailure, [switch]$Interactive)
    if ($OnFailure) { return $OnFailure }
    if (-not $Interactive) { return 'Retry' }
    $answer = $null
    try { $answer = Read-Host 'If applying Turbo fails, retry automatically (after 1, 5, 15, then every 30 minutes)? Press Enter for yes, or type N to fail without retrying' } catch { }
    if ($answer -match '^\s*n') { 'Fail' } else { 'Retry' }
}
function Write-ServiceConfig {
    param([string]$Path, [ValidateSet('Retry','Fail')][string]$OnFailure)
    ([ordered]@{ RetryOnFailure = ($OnFailure -eq 'Retry') } | ConvertTo-Json) | Set-Content -LiteralPath $Path -Encoding ASCII
}
# "Installed apps" (Apps and features) registration, so the tool can be removed from
# Windows Settings. Only an entry whose InstallLocation matches is ever changed or removed.
function New-UninstallEntry {
    param([string]$KeyPath, [string]$InstallRoot, [string]$UninstallString)
    $null = New-Item -Path $KeyPath -Force
    $strings = [ordered]@{ DisplayName='Intel TurboBoost Switcher'; InstallLocation=$InstallRoot
        UninstallString=$UninstallString; InstallDate=(Get-Date -Format 'yyyyMMdd') }
    foreach ($name in $strings.Keys) { $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value $strings[$name] -PropertyType String -Force }
    foreach ($name in 'NoModify','NoRepair') { $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value 1 -PropertyType DWord -Force }
}
function Remove-UninstallEntry {
    param([string]$KeyPath, [string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $KeyPath)) { return }
    $location = (Get-ItemProperty -LiteralPath $KeyPath -ErrorAction SilentlyContinue).InstallLocation
    if ($location -ne $InstallRoot) { Write-Warning "Leaving the registry entry ${KeyPath}: it does not belong to this installation."; return }
    Remove-Item -LiteralPath $KeyPath -Recurse -Force
}
function Get-TuningProcesses {
    @(Get-Process -Name ThrottleStop,QuickCPU,XTU,XTU3Service -ErrorAction SilentlyContinue |
        ForEach-Object { '{0} (PID {1})' -f $_.ProcessName,$_.Id })
}
function Set-ProtectedDirectory {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing redirected directory: $Path"
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($admins)
    foreach ($sid in @($admins,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit, ObjectInherit','None','Allow'))
    }
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users,'ReadAndExecute','ContainerInherit, ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-Dependencies {
    param([string]$Directory, $Dependency)
    foreach ($file in $Dependency.files.PSObject.Properties) {
        $path = Join-Path $Directory $file.Name
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) { throw "Dependency hash mismatch: $($file.Name)" }
    }
}
function ConvertFrom-MsrOutput {
    param([string]$Output, [int]$ExpectedCount = 0)
    $rows = @()
    foreach ($line in ($Output -split '\r?\n')) {
        if ($line -match '^\s*0\s+(\d+)\s+0x000001a0\s+0x([0-9a-f]{16})\s*$') {
            $value = [Convert]::ToUInt64($Matches[2],16)
            $rows += [pscustomobject]@{ Cpu=[int]$Matches[1]; Value=$value; DisableBit=[int](($value -shr 38) -band 1) }
        } elseif ($line.Trim() -and $line -notmatch '^\s*GROUP\s+CPU\s+REG\s+VAL\s*$') { throw "Unexpected msr-cmd output: $line" }
    }
    if ($rows.Count -eq 0 -or ($ExpectedCount -gt 0 -and $rows.Count -ne $ExpectedCount)) {
        throw "Expected exactly $(if ($ExpectedCount -gt 0) { $ExpectedCount } else { 'the reported' }) processor rows; found $($rows.Count)."
    }
    for ($index=0; $index -lt $rows.Count; $index++) {
        if (@($rows | Where-Object Cpu -eq $index).Count -ne 1) { throw "Missing or duplicate CPU $index." }
    }
    $rows | Sort-Object Cpu
}
function Read-TurboState {
    param([scriptblock]$Runner, [int]$ExpectedCount = 0)
    $output = & $Runner -Arguments @('-A','-l','read','0x1A0')
    ConvertFrom-MsrOutput -Output ($output -join "`n") -ExpectedCount $ExpectedCount
}
function Set-TurboState {
    param([ValidateSet(0,1)][int]$DisableBit, [scriptblock]$Runner, [int]$ExpectedCount = 0)
    $before = @(Read-TurboState -Runner $Runner -ExpectedCount $ExpectedCount)
    foreach ($row in $before) {
        if ($row.DisableBit -eq $DisableBit) { continue }
        $null = & $Runner -Arguments @('-g','0','-p',[string]$row.Cpu,'setbit','0x1A0','38',[string]$DisableBit)
    }
    $after = @(Read-TurboState -Runner $Runner -ExpectedCount $ExpectedCount)
    if ($after.Count -ne $before.Count) { throw 'The processor count changed during the operation.' }
    for ($index=0; $index -lt $before.Count; $index++) {
        if ($after[$index].DisableBit -ne $DisableBit) { throw "CPU ${index}: requested bit did not retain its value." }
        $otherBits = [UInt64]::MaxValue -bxor [UInt64]274877906944
        if ((($before[$index].Value -bxor $after[$index].Value) -band $otherBits) -ne 0) { throw "CPU ${index}: unrelated register bits changed." }
    }
    $after
}
function New-MsrRunner {
    param([string]$Directory)
    {
        param([string[]]$Arguments)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $Directory 'msr-cmd.exe'
        $start.WorkingDirectory=$Directory; $start.Arguments=$Arguments -join ' '
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $process = New-Object Diagnostics.Process
        $process.StartInfo=$start
        try {
            if (-not $process.Start()) { throw 'Could not start msr-cmd.' }
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) {
                $process.Kill(); $null=$process.WaitForExit(5000)
                throw 'msr-cmd timed out; some writes may have applied. Read the state before retrying.'
            }
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) { throw 'msr-cmd output did not close.' }
            if ($process.ExitCode -ne 0) { throw "msr-cmd failed ($($process.ExitCode)): $($stdout.Result) $($stderr.Result)" }
            $stdout.Result
        } finally { $process.Dispose() }
    }.GetNewClosure()
}
function Invoke-HardwareSession {
    param([scriptblock]$Operation)
    $security = New-Object Security.AccessControl.MutexSecurity
    foreach ($value in @('S-1-5-18','S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($value)
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($sid,'FullControl','Allow'))
    }
    $created=$false; $held=$false
    $mutex = [Threading.Mutex]::new($false,'Global\ITBS.Hardware',[ref]$created,$security)
    try {
        try { $held=$mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw 'Another ITBS operation is still running.' }
        & $Operation
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Test-RecordedBuild {
    param([string]$OutputDirectory, [string]$SourceDirectory, [string]$DependencyDirectory)
    $record=Get-Content -LiteralPath (Join-Path $OutputDirectory 'build-record.json') -Raw | ConvertFrom-Json
    if ($record.Version -ne 1 -or $record.Output.File -ne 'ITBS.Service.exe') { throw 'Unexpected build-record schema or output.' }
    $sourceRoot=[IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
    foreach ($input in $record.SourceInputs) {
        $path=[IO.Path]::GetFullPath((Join-Path $SourceDirectory $input.Path))
        if (-not $path.StartsWith($sourceRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Source record escapes its source directory.' }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $input.SHA256) { throw "Source hash mismatch: $($input.Path)" }
    }
    $exe=Join-Path $OutputDirectory 'ITBS.Service.exe'
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $record.Output.SHA256) { throw 'Service executable hash mismatch.' }
    Assert-Dependencies $DependencyDirectory $record.Dependency
    # Independently require that the record's pins match the readable manifest.
    $pins=(Get-Content -LiteralPath (Join-Path $SourceDirectory 'dependencies.json') -Raw | ConvertFrom-Json).msrUtility
    Assert-Dependencies $DependencyDirectory $pins
    Write-Host 'Source, locally generated service, and dependency hashes match the build record and manifest.'
}
Export-ModuleMember -Function *
