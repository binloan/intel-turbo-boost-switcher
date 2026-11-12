#requires -Version 5.1
<#
.SYNOPSIS
    Tests the PowerShell logic in scripts\Common.psm1 without touching hardware or the service.
.DESCRIPTION
    Drives the MSR parsing and Turbo state functions through a fake msr-cmd runner, checks the CPU gate and
    the untested-processor prompts, the failure policy, the service configuration file, the Installed apps
    registration (a throwaway HKCU key) and the build-record verifier (text-only fixtures). The only real
    system access is a read-only comparison of the CPU registry values with CIM.
.EXAMPLE
    .\tests\Test-Manual.ps1

    Runs all assertions and prints a PASS line, or throws on the first failure.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\Common.psm1') -Force -Verbose:$false
$script:checks = 0

# All register bits except bit 38 (274877906944 is 1 shifted left by 38).
$otherBits = [UInt64]::MaxValue -bxor [UInt64]274877906944
$testRoot = [IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\obj'))


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


function Throws {
    <#
    .SYNOPSIS
        Asserts that a script block throws an error whose message matches a pattern.
    .EXAMPLE
        Throws -Action { Get-Thing } -Pattern 'not found'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        # The code that must fail.
        [scriptblock]
        $Action,

        # The regular expression that the error message must match.
        [string]
        $Pattern
    )

    try {
        & $Action
    } catch {
        $failure = $_
        Check -Condition ($failure.Exception.Message -match $Pattern) -Message $failure.Exception.Message
        return
    }

    throw "Expected failure: $Pattern"
}


function New-Fake {
    <#
    .SYNOPSIS
        Creates a fake msr-cmd runner for 12 logical processors and the state it operates on.
    .DESCRIPTION
        The state records every write and can reject writes, corrupt an unrelated bit after a write, or fail
        the write for one processor.
    .EXAMPLE
        $fake = New-Fake
    .OUTPUTS
        System.Collections.Hashtable. The keys are State and Runner.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $state = @{
        Values  = @{}
        Writes  = 0
        Reject  = $false
        Corrupt = $false
        FailCpu = -1
    }
    for ($i = 0; $i -lt 12; $i++) {
        $state.Values[$i] = [UInt64](0x851889 + $i) -bor ([UInt64]($i % 2) -shl 38)
    }

    $runner = {
        param (
            [string[]]
            $Arguments
        )

        if (($Arguments -join ' ') -eq '-A -l read 0x1A0') {
            $lines = @('GROUP CPU REG VAL')
            for ($i = 0; $i -lt 12; $i++) {
                $value = $state.Values[$i]
                if ($state.Corrupt -and $state.Writes -and $i -eq 0) {
                    $value = $value -bxor [UInt64]1
                }

                $lines += '0 {0} 0x000001a0 0x{1:x16}' -f $i, $value
            }

            return $lines -join "`n"
        }

        if (($Arguments -join ' ') -notmatch '^-g 0 -p (\d+) setbit 0x1A0 38 ([01])$') {
            throw 'Unexpected command.'
        }

        $cpu = [int]$Matches[1]
        $bit = [int]$Matches[2]
        if ($cpu -eq $state.FailCpu) {
            throw 'simulated failure'
        }

        $state.Writes++
        if (-not $state.Reject) {
            $keepBits = [UInt64]::MaxValue -bxor [UInt64]274877906944
            $cleared = $state.Values[$cpu] -band $keepBits
            $state.Values[$cpu] = $cleared -bor ([UInt64]$bit -shl 38)
        }

        'setbit readback ignored'
    }.GetNewClosure()

    @{
        State  = $state
        Runner = $runner
    }
}


$fake = New-Fake
$before = @(Read-TurboState -Runner $fake.Runner)
Check -Condition ($before[0].DisableBit -eq 0 -and $before[1].DisableBit -eq 1) -Message 'Wrong polarity.'
$after = @(Set-TurboState -DisableBit 0 -Runner $fake.Runner)
Check -Condition (
    @($after | Where-Object -FilterScript { $_.DisableBit -ne 0 }).Count -eq 0
) -Message 'Enable failed.'
Check -Condition ($fake.State.Writes -eq 6) -Message 'Unnecessary writes.'
for ($i = 0; $i -lt 12; $i++) {
    $beforeOther = $before[$i].Value -band $otherBits
    $afterOther = $after[$i].Value -band $otherBits
    Check -Condition ($beforeOther -eq $afterOther) -Message 'Unrelated bits changed.'
}

$null = Set-TurboState -DisableBit 0 -Runner $fake.Runner
Check -Condition ($fake.State.Writes -eq 6) -Message 'Idempotent enable performed writes.'
$after = @(Set-TurboState -DisableBit 1 -Runner $fake.Runner)
Check -Condition (
    @($after | Where-Object -FilterScript { $_.DisableBit -ne 1 }).Count -eq 0
) -Message 'Disable failed.'
Throws -Action { ConvertFrom-MsrOutput -Output '' } -Pattern 'Expected exactly'
$eight = (0..7 | ForEach-Object -Process { '0 {0} 0x000001a0 0x0000000000851889' -f $_ }) -join "`n"
Check -Condition (
    @(ConvertFrom-MsrOutput -Output $eight).Count -eq 8
) -Message 'Other processor counts should parse.'
Check -Condition (
    @(ConvertFrom-MsrOutput -Output $eight -ExpectedCount 8).Count -eq 8
) -Message 'Matching expected count should parse.'
Throws -Action { ConvertFrom-MsrOutput -Output $eight -ExpectedCount 12 } -Pattern 'Expected exactly'
Throws -Action {
    ConvertFrom-MsrOutput -Output ($eight -replace '0 7 ', '0 9 ')
} -Pattern 'Missing or duplicate'

# CPU gate and untested-processor warning logic (pure functions; no registry or hardware access).
$testedArguments = @{
    Name              = '12th Gen Intel(R) Core(TM) i5-12450H'
    Identifier        = 'Intel64 Family 6 Model 154 Stepping 3'
    Vendor            = 'GenuineIntel'
    LogicalProcessors = 12
}
$tested = ConvertTo-CpuInfo @testedArguments
$otherArguments = @{
    Name              = 'Intel(R) Core(TM) i7-9750H'
    Identifier        = 'Intel64 Family 6 Model 158 Stepping 10'
    Vendor            = 'GenuineIntel'
    LogicalProcessors = 12
}
$other = ConvertTo-CpuInfo @otherArguments
$fewerArguments = @{
    Name              = '12th Gen Intel(R) Core(TM) i5-12450H'
    Identifier        = 'Intel64 Family 6 Model 154 Stepping 3'
    Vendor            = 'GenuineIntel'
    LogicalProcessors = 8
}
$fewer = ConvertTo-CpuInfo @fewerArguments
$amdArguments = @{
    Name              = 'AMD Ryzen 7 5800H'
    Identifier        = 'AMD64 Family 25 Model 80 Stepping 0'
    Vendor            = 'AuthenticAMD'
    LogicalProcessors = 16
}
$amd = ConvertTo-CpuInfo @amdArguments
$hugeArguments = @{
    Name              = 'Intel(R) Xeon(R)'
    Identifier        = 'Intel64 Family 6 Model 143'
    Vendor            = 'GenuineIntel'
    LogicalProcessors = 128
}
$huge = ConvertTo-CpuInfo @hugeArguments
Check -Condition $tested.Tested -Message 'The reference CPU should be recognized as tested.'
Check -Condition (
    -not $other.Tested -and -not $fewer.Tested
) -Message 'Other Intel CPUs and processor counts must count as untested.'
Check -Condition (
    (Assert-IntelCpu -Info $other).Name -match 'i7-9750H'
) -Message 'Other Intel CPUs must be allowed.'
Throws -Action { Assert-IntelCpu -Info $amd } -Pattern 'Intel processors only'
Throws -Action { Assert-IntelCpu -Info $huge } -Pattern 'Unsupported logical processor count'

# Real registry read, cross-checked against an independent source (CIM/WMI). Read-only.
$real = Get-CpuInfo
$cim = @(Get-CimInstance -ClassName Win32_Processor)
$cimCount = [int](($cim | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
Check -Condition ($real.LogicalProcessors -eq $cimCount) -Message 'Registry processor count disagrees with CIM.'
Check -Condition ($real.Name -eq ([string]$cim[0].Name).Trim()) -Message 'Registry CPU name disagrees with CIM.'
Check -Condition ($real.Vendor -eq $cim[0].Manufacturer) -Message 'Registry CPU vendor disagrees with CIM.'
Check -Condition ($real.Identifier -eq $cim[0].Caption) -Message 'Registry CPU identifier disagrees with CIM.'
$expectedTested = $real.Name -match '\bi5-12450H\b' -and
    $real.Identifier -match 'Family 6 Model 154\b' -and
    $real.LogicalProcessors -eq 12
Check -Condition ($real.Tested -eq $expectedTested) -Message 'Tested flag is inconsistent with the real CPU.'
if ($real.Vendor -eq 'GenuineIntel' -and $real.LogicalProcessors -le 64) {
    Check -Condition (
        (Assert-IntelCpu).LogicalProcessors -eq $real.LogicalProcessors
    ) -Message 'Assert-IntelCpu should accept this real CPU.'
} else {
    Throws -Action { Assert-IntelCpu } -Pattern 'Intel processors only|Unsupported logical processor count'
}

Confirm-UntestedCpu -Info $tested
$null = Confirm-UntestedCpu -Info $other -AcceptRisk 6>$null
Check -Condition $true -Message 'Tested CPUs and -AcceptRisk must not prompt.'

# Simulate the prompt (a global function shadows Read-Host only for this check).
function global:Read-Host {
    <#
    .SYNOPSIS
        Returns the canned answer in $script:fakeAnswer instead of prompting.
    .EXAMPLE
        Read-Host -Prompt 'Continue?'
    #>
    param (
        # The prompt text, ignored.
        $Prompt
    )

    $script:fakeAnswer
}


try {
    $script:fakeAnswer = 'yes'
    Throws -Action { Confirm-UntestedCpu -Info $other 6>$null } -Pattern 'risk was not accepted'
    $script:fakeAnswer = ''
    Throws -Action { Confirm-UntestedCpu -Info $other 6>$null } -Pattern 'risk was not accepted'
    $script:fakeAnswer = 'YES'
    Confirm-UntestedCpu -Info $other 6>$null
    Check -Condition $true -Message 'Typing YES should accept the risk.'
} finally {
    Remove-Item -Path 'Function:\Read-Host'
}

$text = & $fake.Runner -Arguments @('-A', '-l', 'read', '0x1A0')
Throws -Action {
    ConvertFrom-MsrOutput -Output ($text -replace '0 11 ', '0 10 ')
} -Pattern 'Missing or duplicate'
Throws -Action { ConvertFrom-MsrOutput -Output ($text + 'error') } -Pattern 'Unexpected'
$fake = New-Fake
$fake.State.Reject = $true
Throws -Action { Set-TurboState -DisableBit 0 -Runner $fake.Runner } -Pattern 'did not retain'
$fake = New-Fake
$fake.State.Corrupt = $true
Throws -Action { Set-TurboState -DisableBit 0 -Runner $fake.Runner } -Pattern 'unrelated'
$fake = New-Fake
$fake.State.FailCpu = 3
Throws -Action { Set-TurboState -DisableBit 0 -Runner $fake.Runner } -Pattern 'simulated failure'
Check -Condition ($fake.State.Writes -eq 1) -Message 'Continued after failure.'

# Failure policy (retry or fail directly): explicit values, unattended default, interactive prompt.
$explicitWins = (Resolve-FailurePolicy -OnFailure 'Fail') -eq 'Fail' -and
    (Resolve-FailurePolicy -OnFailure 'Retry' -Interactive) -eq 'Retry'
Check -Condition $explicitWins -Message 'An explicit policy must win without prompting.'
Check -Condition (
    (Resolve-FailurePolicy -OnFailure '') -eq 'Retry'
) -Message 'Unattended installs must default to Retry.'
function global:Read-Host {
    <#
    .SYNOPSIS
        Returns the canned answer in $script:fakeAnswer instead of prompting.
    .EXAMPLE
        Read-Host -Prompt 'Retry?'
    #>
    param (
        # The prompt text, ignored.
        $Prompt
    )

    $script:fakeAnswer
}


try {
    $script:fakeAnswer = ''
    Check -Condition (
        (Resolve-FailurePolicy -OnFailure '' -Interactive 6>$null) -eq 'Retry'
    ) -Message 'Pressing Enter should choose Retry.'
    $script:fakeAnswer = 'y'
    Check -Condition (
        (Resolve-FailurePolicy -OnFailure '' -Interactive 6>$null) -eq 'Retry'
    ) -Message 'Anything but N should choose Retry.'
    $script:fakeAnswer = 'N'
    Check -Condition (
        (Resolve-FailurePolicy -OnFailure '' -Interactive 6>$null) -eq 'Fail'
    ) -Message 'Typing N should choose Fail.'
    $script:fakeAnswer = 'no'
    Check -Condition (
        (Resolve-FailurePolicy -OnFailure '' -Interactive 6>$null) -eq 'Fail'
    ) -Message 'Typing no should choose Fail.'
} finally {
    Remove-Item -Path 'Function:Read-Host'
}

$configName = 'config-' + [Guid]::NewGuid().ToString('N')
$configDirectory = Join-Path -Path $testRoot -ChildPath $configName
try {
    $null = New-Item -ItemType Directory -Path $configDirectory -Force
    $configPath = Join-Path -Path $configDirectory -ChildPath 'config.json'
    Write-ServiceConfig -Path $configPath -OnFailure 'Fail'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Check -Condition ($config.RetryOnFailure -eq $false) -Message 'Fail must write RetryOnFailure=false.'
    Write-ServiceConfig -Path $configPath -OnFailure 'Retry'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Check -Condition ($config.RetryOnFailure -eq $true) -Message 'Retry must write RetryOnFailure=true.'
    Throws -Action { Write-ServiceConfig -Path $configPath -OnFailure 'Maybe' } -Pattern 'Maybe'
} finally {
    if (Test-Path -LiteralPath $configDirectory) {
        Remove-Item -LiteralPath $configDirectory -Recurse -Force
    }
}

# "Installed apps" registration, against a throwaway HKCU key (never the real HKLM entry).
$entryKey = 'HKCU:\Software\ITBS-Test-' + [Guid]::NewGuid().ToString('N')
try {
    $entryArguments = @{
        KeyPath         = $entryKey
        InstallRoot     = 'C:\Fake\ITBS'
        UninstallString = '"C:\Fake\ITBS\source\Uninstall.cmd"'
    }
    New-UninstallEntry @entryArguments
    $entry = Get-ItemProperty -LiteralPath $entryKey
    Check -Condition (
        $entry.DisplayName -eq 'Intel TurboBoost Switcher' -and $entry.InstallLocation -eq 'C:\Fake\ITBS'
    ) -Message 'The uninstall entry should name the product and its location.'
    Check -Condition (
        $entry.UninstallString -eq '"C:\Fake\ITBS\source\Uninstall.cmd"' -and
        $entry.NoModify -eq 1 -and
        $entry.NoRepair -eq 1
    ) -Message 'The uninstall entry should run Uninstall.cmd and hide Modify/Repair.'
    Remove-UninstallEntry -KeyPath $entryKey -InstallRoot 'C:\Other\ITBS' 3>$null
    Check -Condition (
        Test-Path -LiteralPath $entryKey
    ) -Message 'An entry that belongs to another location must not be removed.'
    Remove-UninstallEntry -KeyPath $entryKey -InstallRoot 'C:\Fake\ITBS'
    Check -Condition (
        -not (Test-Path -LiteralPath $entryKey)
    ) -Message 'The matching uninstall entry should be removed.'
    Remove-UninstallEntry -KeyPath $entryKey -InstallRoot 'C:\Fake\ITBS'
    Check -Condition $true -Message 'Removing a missing entry must not fail.'
} finally {
    if (Test-Path -LiteralPath $entryKey) {
        Remove-Item -LiteralPath $entryKey -Recurse -Force
    }
}

# Check the build-record verifier with text-only fixtures; nothing is executed.
$fixture = Join-Path -Path $testRoot -ChildPath ('verify-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path -Path $fixture -ChildPath 'source'
$engine = Join-Path -Path $fixture -ChildPath 'engine'
try {
    $null = New-Item -ItemType Directory -Path $source, $engine -Force
    $sourceFile = Join-Path -Path $source -ChildPath 'fixture.ps1'
    $exeFile = Join-Path -Path $fixture -ChildPath 'ITBS.Service.exe'
    $dependencyFile = Join-Path -Path $engine -ChildPath 'fixture.dat'
    $exeContent = 'Not an executable; hash-verification fixture only.'
    Set-Content -LiteralPath $sourceFile -Value '# fixture' -Encoding ASCII
    Set-Content -LiteralPath $exeFile -Value $exeContent -Encoding ASCII
    Set-Content -LiteralPath $dependencyFile -Value 'fixture dependency' -Encoding ASCII
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $exeHash = (Get-FileHash -LiteralPath $exeFile -Algorithm SHA256).Hash
    $dependencyHash = (Get-FileHash -LiteralPath $dependencyFile -Algorithm SHA256).Hash
    $pins = [ordered]@{
        files = [ordered]@{
            'fixture.dat' = $dependencyHash
        }
    }
    $dependencyPath = Join-Path -Path $source -ChildPath 'dependencies.json'
    @{ msrUtility = $pins } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $dependencyPath
    $record = [ordered]@{
        Version      = 1
        SourceInputs = @(
            @{
                Path   = 'fixture.ps1'
                SHA256 = $sourceHash
            }
        )
        Dependency   = $pins
        Output       = @{
            File   = 'ITBS.Service.exe'
            SHA256 = $exeHash
        }
    }
    $recordPath = Join-Path -Path $fixture -ChildPath 'build-record.json'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    $verifyArguments = @{
        OutputDirectory     = $fixture
        SourceDirectory     = $source
        DependencyDirectory = $engine
    }
    Test-RecordedBuild @verifyArguments
    Check -Condition $true -Message 'A valid record should verify.'
    Add-Content -LiteralPath $sourceFile -Value '# changed'
    Throws -Action { Test-RecordedBuild @verifyArguments } -Pattern 'Source hash mismatch'
    Set-Content -LiteralPath $sourceFile -Value '# fixture' -Encoding ASCII
    Add-Content -LiteralPath $exeFile -Value 'changed'
    Throws -Action { Test-RecordedBuild @verifyArguments } -Pattern 'executable hash mismatch'
    Set-Content -LiteralPath $exeFile -Value $exeContent -Encoding ASCII
    Add-Content -LiteralPath $dependencyFile -Value 'changed'
    Throws -Action { Test-RecordedBuild @verifyArguments } -Pattern 'Dependency hash mismatch'
    $record.SourceInputs = @(
        @{
            Path   = '..\outside.ps1'
            SHA256 = $sourceHash
        }
    )
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Throws -Action { Test-RecordedBuild @verifyArguments } -Pattern 'escapes'
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

Write-Host -Object "PASS: $script:checks PowerShell assertions; fake driver and build-record fixtures only."
