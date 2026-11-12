#requires -Version 5.1
Set-StrictMode -Version 2


function Test-Administrator {
    <#
    .SYNOPSIS
        Tests whether the current process runs with administrator rights.
    .EXAMPLE
        if (-not (Test-Administrator)) { 'Elevation required.' }
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


function Invoke-ElevatedScript {
    <#
    .SYNOPSIS
        Runs a script in an elevated Windows PowerShell process and waits for it to exit.
    .DESCRIPTION
        This is an explicitly interactive user launcher, not a background helper. It shows the
        UAC prompt and a normal window.
    .EXAMPLE
        $exitCode = Invoke-ElevatedScript -ScriptPath 'C:\ITBS\Install.ps1' -Arguments '-Interactive'
    .OUTPUTS
        System.Int32. The exit code of the elevated process.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        # The full path of the script to run.
        [string]
        $ScriptPath,

        # The arguments passed to the script, already formatted as a command-line string.
        [string]
        $Arguments
    )

    $nativeArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $Arguments
    $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $startParameters = @{
        FilePath     = $powerShellPath
        Verb         = 'RunAs'
        WindowStyle  = 'Normal'
        ArgumentList = $nativeArguments
        PassThru     = $true
    }
    $child = Start-Process @startParameters
    $child.WaitForExit()
    $child.ExitCode
}


$script:TestedCpu = 'Intel Core i5-12450H'


function ConvertTo-CpuInfo {
    <#
    .SYNOPSIS
        Builds a CPU information object and flags whether this exact CPU was tested.
    .EXAMPLE
        ConvertTo-CpuInfo -Name $name -Identifier $identifier -Vendor 'GenuineIntel' -LogicalProcessors 12
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The processor name string, for example from the registry.
        [string]
        $Name,

        # The processor identifier string (family, model and stepping).
        [string]
        $Identifier,

        # The vendor identifier string, for example GenuineIntel.
        [string]
        $Vendor,

        # The number of logical processors.
        [int]
        $LogicalProcessors
    )

    $isTested = $Name -match '\bi5-12450H\b' -and
        $Identifier -match 'Family 6 Model 154\b' -and
        $LogicalProcessors -eq 12
    [pscustomobject]@{
        Name              = $Name
        Identifier        = $Identifier
        Vendor            = $Vendor
        LogicalProcessors = $LogicalProcessors
        Tested            = $isTested
    }
}


function Get-CpuInfo {
    <#
    .SYNOPSIS
        Reads the CPU name, identifier, vendor and logical processor count from the registry.
    .EXAMPLE
        $info = Get-CpuInfo
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $processorRoot = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor'
    $key = Get-Item -LiteralPath $processorRoot
    $count = @(Get-ChildItem -LiteralPath $key.PSPath).Count
    $cpu = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    $name = ([string]$cpu.ProcessorNameString).Trim()
    $identifier = [string]$cpu.Identifier
    $vendor = [string]$cpu.VendorIdentifier
    ConvertTo-CpuInfo -Name $name -Identifier $identifier -Vendor $vendor -LogicalProcessors $count
}


function Assert-IntelCpu {
    <#
    .SYNOPSIS
        Throws unless the processor is an Intel CPU with 1 to 64 logical processors.
    .DESCRIPTION
        This is a hard gate: bit 38 of IA32_MISC_ENABLE is Intel-specific and msr-cmd is addressed
        at processor group 0 only (at most 64 logical processors). Other Intel CPUs are allowed
        after a warning; see Confirm-UntestedCpu.
    .EXAMPLE
        $cpu = Assert-IntelCpu
    .OUTPUTS
        System.Management.Automation.PSCustomObject. The validated CPU information.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The CPU information to validate. Defaults to the CPU of this computer.
        [pscustomobject]
        $Info = (Get-CpuInfo)
    )

    if ($Info.Vendor -ne 'GenuineIntel') {
        throw "This tool supports Intel processors only (found '$($Info.Vendor)')."
    }

    if ($Info.LogicalProcessors -lt 1 -or $Info.LogicalProcessors -gt 64) {
        $message = "Unsupported logical processor count ($($Info.LogicalProcessors)); " +
            'only 1-64 processors in group 0 are supported.'
        throw $message
    }

    $Info
}


function Write-UntestedWarning {
    <#
    .SYNOPSIS
        Writes the untested-processor warning to the console.
    .EXAMPLE
        Write-UntestedWarning -Info $cpu
    #>
    [CmdletBinding()]
    param (
        # The CPU information of the untested processor.
        [pscustomobject]
        $Info
    )

    $detected = 'Detected: {0} ({1}, {2} logical processors).' -f
        $Info.Name, $Info.Identifier, $Info.LogicalProcessors
    $tested = 'Intel TurboBoost Switcher has only ever been tested on the ' +
        "$script:TestedCpu with 12 logical processors."
    $warningLines = @(
        'WARNING: UNTESTED PROCESSOR',
        $detected,
        $tested,
        'It was NEVER tested on this system. Writing a CPU model-specific register can cause',
        'instability, overheating, data loss or hardware problems. You use it entirely at your own risk;',
        'the software is provided without warranty (see LICENSE).'
    )

    Write-Host -Object ''
    foreach ($warningLine in $warningLines) {
        Write-Host -Object $warningLine -ForegroundColor Yellow
    }

    Write-Host -Object ''
}


function Confirm-UntestedCpu {
    <#
    .SYNOPSIS
        Shows the warning and requires explicit acceptance on an untested CPU.
    .DESCRIPTION
        -AcceptRisk is for unattended use and still prints the warning.
    .EXAMPLE
        Confirm-UntestedCpu -Info $cpu -AcceptRisk
    #>
    [CmdletBinding()]
    param (
        # The CPU information to check. Tested CPUs return without a prompt.
        [pscustomobject]
        $Info,

        # Accepts the risk without prompting.
        [switch]
        $AcceptRisk
    )

    if ($Info.Tested) {
        return
    }

    Write-UntestedWarning -Info $Info
    if ($AcceptRisk) {
        Write-Host -Object 'Risk accepted with -AcceptUntestedRisk.' -ForegroundColor Yellow
        return
    }

    $answer = $null
    try {
        $answer = Read-Host -Prompt 'Type YES to continue at your own risk'
    } catch {
        # Read-Host fails when there is no console to prompt. Treat that as no answer, which cancels below.
    }

    if ($answer -cne 'YES') {
        $message = 'Cancelled: the untested-processor risk was not accepted. ' +
            'For unattended use, pass -AcceptUntestedRisk.'
        throw $message
    }
}


function Resolve-FailurePolicy {
    <#
    .SYNOPSIS
        Returns what the service does when applying Turbo fails or is blocked.
    .DESCRIPTION
        The policy is 'Retry' (after 1, 5, 15, then every 30 minutes) or 'Fail' (record the error
        and wait). The default is Retry; an interactive install asks.
    .EXAMPLE
        $policy = Resolve-FailurePolicy -OnFailure '' -Interactive
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        # The policy requested on the command line. A non-empty value wins without prompting.
        [string]
        $OnFailure,

        # Asks the person at the console when no policy was requested.
        [switch]
        $Interactive
    )

    if ($OnFailure) {
        return $OnFailure
    }

    if (-not $Interactive) {
        return 'Retry'
    }

    $prompt = 'If applying Turbo fails, retry automatically (after 1, 5, 15, then every 30 minutes)? ' +
        'Press Enter for yes, or type N to fail without retrying'
    $answer = $null
    try {
        $answer = Read-Host -Prompt $prompt
    } catch {
        # Read-Host fails when there is no console to prompt. Treat that as no answer, which retries.
    }

    if ($answer -match '^\s*n') {
        'Fail'
    } else {
        'Retry'
    }
}


function Write-ServiceConfig {
    <#
    .SYNOPSIS
        Writes the service configuration file.
    .EXAMPLE
        Write-ServiceConfig -Path 'C:\ProgramData\ITBS\config.json' -OnFailure 'Retry'
    #>
    [CmdletBinding()]
    param (
        # The full path of the configuration file.
        [string]
        $Path,

        # The failure policy to store.
        [ValidateSet('Retry', 'Fail')]
        [string]
        $OnFailure
    )

    $json = [ordered]@{ RetryOnFailure = ($OnFailure -eq 'Retry') } | ConvertTo-Json
    Set-Content -LiteralPath $Path -Value $json -Encoding ASCII
}


function New-UninstallEntry {
    <#
    .SYNOPSIS
        Registers the tool under "Installed apps" (Apps and features).
    .DESCRIPTION
        The registration lets the tool be removed from Windows Settings. Only an entry whose
        InstallLocation matches is ever changed or removed.
    .EXAMPLE
        New-UninstallEntry -KeyPath $key -InstallRoot 'C:\Program Files\ITBS' -UninstallString $command
    #>
    [CmdletBinding()]
    param (
        # The registry key path of the uninstall entry.
        [string]
        $KeyPath,

        # The installation directory, stored as InstallLocation.
        [string]
        $InstallRoot,

        # The command line that uninstalls the tool.
        [string]
        $UninstallString
    )

    $null = New-Item -Path $KeyPath -Force
    $strings = [ordered]@{
        DisplayName     = 'Intel TurboBoost Switcher'
        InstallLocation = $InstallRoot
        UninstallString = $UninstallString
        InstallDate     = (Get-Date -Format 'yyyyMMdd')
    }
    foreach ($name in $strings.Keys) {
        $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value $strings[$name] `
            -PropertyType String -Force
    }

    foreach ($name in 'NoModify', 'NoRepair') {
        $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value 1 -PropertyType DWord -Force
    }
}


function Remove-UninstallEntry {
    <#
    .SYNOPSIS
        Removes the "Installed apps" registration if it belongs to this installation.
    .EXAMPLE
        Remove-UninstallEntry -KeyPath $key -InstallRoot 'C:\Program Files\ITBS'
    #>
    [CmdletBinding()]
    param (
        # The registry key path of the uninstall entry.
        [string]
        $KeyPath,

        # The installation directory that the entry must match.
        [string]
        $InstallRoot
    )

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        return
    }

    $location = (Get-ItemProperty -LiteralPath $KeyPath -ErrorAction SilentlyContinue).InstallLocation
    if ($location -ne $InstallRoot) {
        Write-Warning -Message "Leaving the registry entry ${KeyPath}: it does not belong to this installation."
        return
    }

    Remove-Item -LiteralPath $KeyPath -Recurse -Force
}


function Get-TuningProcesses {
    <#
    .SYNOPSIS
        Lists running tools that also tune the CPU and compete for the same registers.
    .EXAMPLE
        $competing = @(Get-TuningProcesses)
    .OUTPUTS
        System.String. One "Name (PID n)" string per process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    @(
        Get-Process -Name ThrottleStop, QuickCPU, XTU, XTU3Service -ErrorAction SilentlyContinue |
            ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }
    )
}


function Set-ProtectedDirectory {
    <#
    .SYNOPSIS
        Creates a directory that only administrators and SYSTEM can change.
    .DESCRIPTION
        Refuses a directory that is a reparse point. Disables ACL inheritance, makes the
        Administrators group the owner, grants Administrators and SYSTEM full control, and
        grants Users read and execute.
    .EXAMPLE
        Set-ProtectedDirectory -Path 'C:\Program Files\ITBS\engine'
    #>
    [CmdletBinding()]
    param (
        # The full path of the directory.
        [string]
        $Path
    )

    if (Test-Path -LiteralPath $Path) {
        $attributes = (Get-Item -LiteralPath $Path -Force).Attributes
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing redirected directory: $Path"
        }
    }

    $null = New-Item -ItemType Directory -Path $Path -Force
    $acl = New-Object -TypeName Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = 'ContainerInherit, ObjectInherit'
    $acl.SetOwner($admins)
    foreach ($sid in @($admins, $system)) {
        $fullControl = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($fullControl)
    }

    $readRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $users, 'ReadAndExecute', $inheritance, 'None', 'Allow')
    $acl.AddAccessRule($readRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}


function Assert-Dependencies {
    <#
    .SYNOPSIS
        Throws unless every dependency file matches its pinned SHA-256 hash.
    .EXAMPLE
        Assert-Dependencies -Directory $engine -Dependency $dependency
    #>
    [CmdletBinding()]
    param (
        # The directory that holds the dependency files.
        [string]
        $Directory,

        # The dependency record. Its files property maps file names to SHA-256 hashes.
        $Dependency
    )

    foreach ($file in $Dependency.files.PSObject.Properties) {
        $path = Join-Path -Path $Directory -ChildPath $file.Name
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) {
            throw "Dependency hash mismatch: $($file.Name)"
        }
    }
}


function ConvertFrom-MsrOutput {
    <#
    .SYNOPSIS
        Parses the output of msr-cmd for register 0x1A0 into one object per logical processor.
    .EXAMPLE
        ConvertFrom-MsrOutput -Output $text -ExpectedCount 12
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Cpu, Value and DisableBit, sorted by Cpu.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The raw msr-cmd output text.
        [string]
        $Output,

        # The required number of processor rows. Zero accepts any count.
        [int]
        $ExpectedCount = 0
    )

    $rows = @()
    foreach ($line in ($Output -split '\r?\n')) {
        if ($line -match '^\s*0\s+(\d+)\s+0x000001a0\s+0x([0-9a-f]{16})\s*$') {
            $value = [Convert]::ToUInt64($Matches[2], 16)
            $rows += [pscustomobject]@{
                Cpu        = [int]$Matches[1]
                Value      = $value
                DisableBit = [int](($value -shr 38) -band 1)
            }
        } elseif ($line.Trim() -and $line -notmatch '^\s*GROUP\s+CPU\s+REG\s+VAL\s*$') {
            throw "Unexpected msr-cmd output: $line"
        }
    }

    if ($rows.Count -eq 0 -or ($ExpectedCount -gt 0 -and $rows.Count -ne $ExpectedCount)) {
        $expected = 'the reported'
        if ($ExpectedCount -gt 0) {
            $expected = $ExpectedCount
        }

        throw "Expected exactly $expected processor rows; found $($rows.Count)."
    }

    for ($index = 0; $index -lt $rows.Count; $index++) {
        if (@($rows | Where-Object -FilterScript { $_.Cpu -eq $index }).Count -ne 1) {
            throw "Missing or duplicate CPU $index."
        }
    }

    $rows | Sort-Object -Property Cpu
}


function Read-TurboState {
    <#
    .SYNOPSIS
        Reads the Turbo disable bit of every logical processor.
    .EXAMPLE
        Read-TurboState -Runner $runner -ExpectedCount 12
    .OUTPUTS
        System.Management.Automation.PSCustomObject. See ConvertFrom-MsrOutput.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The msr-cmd runner from New-MsrRunner.
        [scriptblock]
        $Runner,

        # The required number of processor rows. Zero accepts any count.
        [int]
        $ExpectedCount = 0
    )

    $output = & $Runner -Arguments @('-A', '-l', 'read', '0x1A0')
    ConvertFrom-MsrOutput -Output ($output -join "`n") -ExpectedCount $ExpectedCount
}


function Set-TurboState {
    <#
    .SYNOPSIS
        Sets the Turbo disable bit on every logical processor and verifies the result.
    .DESCRIPTION
        Writes only processors whose bit differs, then reads the state back. Throws if the processor
        count changed, the bit did not retain its value, or any other register bit changed.
    .EXAMPLE
        Set-TurboState -DisableBit 0 -Runner $runner -ExpectedCount 12
    .OUTPUTS
        System.Management.Automation.PSCustomObject. See ConvertFrom-MsrOutput.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The value of bit 38: 0 enables Turbo, 1 disables it.
        [ValidateSet(0, 1)]
        [int]
        $DisableBit,

        # The msr-cmd runner from New-MsrRunner.
        [scriptblock]
        $Runner,

        # The required number of processor rows. Zero accepts any count.
        [int]
        $ExpectedCount = 0
    )

    $before = @(Read-TurboState -Runner $Runner -ExpectedCount $ExpectedCount)
    foreach ($row in $before) {
        if ($row.DisableBit -eq $DisableBit) {
            continue
        }

        $writeArguments = @(
            '-g', '0', '-p', [string]$row.Cpu, 'setbit', '0x1A0', '38', [string]$DisableBit
        )
        $null = & $Runner -Arguments $writeArguments
    }

    $after = @(Read-TurboState -Runner $Runner -ExpectedCount $ExpectedCount)
    if ($after.Count -ne $before.Count) {
        throw 'The processor count changed during the operation.'
    }

    for ($index = 0; $index -lt $before.Count; $index++) {
        if ($after[$index].DisableBit -ne $DisableBit) {
            throw "CPU ${index}: requested bit did not retain its value."
        }

        # All bits except bit 38 (274877906944 is 1 shifted left by 38) must stay unchanged.
        $otherBits = [UInt64]::MaxValue -bxor [UInt64]274877906944
        $changedBits = ($before[$index].Value -bxor $after[$index].Value) -band $otherBits
        if ($changedBits -ne 0) {
            throw "CPU ${index}: unrelated register bits changed."
        }
    }

    $after
}


function New-MsrRunner {
    <#
    .SYNOPSIS
        Creates a script block that runs msr-cmd.exe from the given directory.
    .DESCRIPTION
        The returned script block takes -Arguments (string[]), starts msr-cmd.exe without a
        window, and returns its standard output. It throws on timeout or a non-zero exit code.
        The directory is captured with GetNewClosure().
    .EXAMPLE
        $runner = New-MsrRunner -Directory $engine
    .OUTPUTS
        System.Management.Automation.ScriptBlock
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param (
        # The directory that contains msr-cmd.exe.
        [string]
        $Directory
    )

    $runner = {
        param([string[]]$Arguments)

        $start = New-Object -TypeName Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path -Path $Directory -ChildPath 'msr-cmd.exe'
        $start.WorkingDirectory = $Directory
        $start.Arguments = $Arguments -join ' '
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object -TypeName Diagnostics.Process
        $process.StartInfo = $start
        try {
            if (-not $process.Start()) {
                throw 'Could not start msr-cmd.'
            }

            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
                throw 'msr-cmd timed out; some writes may have applied. Read the state before retrying.'
            }

            $tasks = [Threading.Tasks.Task[]]@($stdout, $stderr)
            if (-not [Threading.Tasks.Task]::WaitAll($tasks, 5000)) {
                throw 'msr-cmd output did not close.'
            }

            if ($process.ExitCode -ne 0) {
                throw "msr-cmd failed ($($process.ExitCode)): $($stdout.Result) $($stderr.Result)"
            }

            $stdout.Result
        } finally {
            $process.Dispose()
        }
    }.GetNewClosure()
    $runner
}


function Invoke-HardwareSession {
    <#
    .SYNOPSIS
        Runs a script block while holding the machine-wide ITBS hardware mutex.
    .DESCRIPTION
        The mutex is accessible to SYSTEM and Administrators only. Throws if another ITBS
        operation holds it for longer than ten seconds. An abandoned mutex is taken over.
    .EXAMPLE
        Invoke-HardwareSession -Operation { Read-TurboState -Runner $runner }
    #>
    [CmdletBinding()]
    param (
        # The script block to run while the mutex is held.
        [scriptblock]
        $Operation
    )

    $security = New-Object -TypeName Security.AccessControl.MutexSecurity
    foreach ($value in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($value)
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($sid, 'FullControl', 'Allow'))
    }

    $created = $false
    $held = $false
    $mutex = [Threading.Mutex]::new($false, 'Global\ITBS.Hardware', [ref]$created, $security)
    try {
        try {
            $held = $mutex.WaitOne(10000)
        } catch [Threading.AbandonedMutexException] {
            # The previous owner exited without releasing. The mutex is ours now, so continue.
            $held = $true
        }

        if (-not $held) {
            throw 'Another ITBS operation is still running.'
        }

        & $Operation
    } finally {
        if ($held) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}


function Test-RecordedBuild {
    <#
    .SYNOPSIS
        Verifies the build record against the source, the service executable and the dependencies.
    .DESCRIPTION
        Checks every recorded source hash, the service executable hash and the dependency hashes.
        Also requires that the record's dependency pins match the readable dependencies.json manifest.
    .EXAMPLE
        Test-RecordedBuild -OutputDirectory $out -SourceDirectory $root -DependencyDirectory $payload
    #>
    [CmdletBinding()]
    param (
        # The directory that holds build-record.json and ITBS.Service.exe.
        [string]
        $OutputDirectory,

        # The source directory that the recorded source inputs are relative to.
        [string]
        $SourceDirectory,

        # The directory that holds the dependency files.
        [string]
        $DependencyDirectory
    )

    $recordPath = Join-Path -Path $OutputDirectory -ChildPath 'build-record.json'
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    if ($record.Version -ne 1 -or $record.Output.File -ne 'ITBS.Service.exe') {
        throw 'Unexpected build-record schema or output.'
    }

    $sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
    foreach ($sourceInput in $record.SourceInputs) {
        $inputPath = Join-Path -Path $SourceDirectory -ChildPath $sourceInput.Path
        $path = [IO.Path]::GetFullPath($inputPath)
        if (-not $path.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Source record escapes its source directory.'
        }

        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $sourceInput.SHA256) {
            throw "Source hash mismatch: $($sourceInput.Path)"
        }
    }

    $exe = Join-Path -Path $OutputDirectory -ChildPath 'ITBS.Service.exe'
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $record.Output.SHA256) {
        throw 'Service executable hash mismatch.'
    }

    Assert-Dependencies -Directory $DependencyDirectory -Dependency $record.Dependency

    # Independently require that the record's pins match the readable manifest.
    $manifestPath = Join-Path -Path $SourceDirectory -ChildPath 'dependencies.json'
    $pins = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).msrUtility
    Assert-Dependencies -Directory $DependencyDirectory -Dependency $pins
    $message = 'Source, locally generated service, and dependency hashes match the build record and manifest.'
    Write-Host -Object $message
}


Export-ModuleMember -Function *
