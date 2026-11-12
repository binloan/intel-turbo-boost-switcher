#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Common.psm1') -Force
$script:checks=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Throws([scriptblock]$Action,[string]$Pattern) {
    try { & $Action } catch { Check ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected failure: $Pattern"
}
function New-Fake {
    $state=@{ Values=@{}; Writes=0; Reject=$false; Corrupt=$false; FailCpu=-1 }
    for ($i=0; $i -lt 12; $i++) { $state.Values[$i]=([UInt64](0x851889+$i) -bor ([UInt64]($i%2) -shl 38)) }
    $runner={
        param([string[]]$Arguments)
        if (($Arguments -join ' ') -eq '-A -l read 0x1A0') {
            $lines=@('GROUP CPU REG VAL')
            for ($i=0; $i -lt 12; $i++) {
                $value=$state.Values[$i]
                if ($state.Corrupt -and $state.Writes -and $i -eq 0) { $value=$value -bxor [UInt64]1 }
                $lines+='0 {0} 0x000001a0 0x{1:x16}' -f $i,$value
            }
            return $lines -join "`n"
        }
        if (($Arguments -join ' ') -notmatch '^-g 0 -p (\d+) setbit 0x1A0 38 ([01])$') { throw 'Unexpected command.' }
        $cpu=[int]$Matches[1]; $bit=[int]$Matches[2]
        if ($cpu -eq $state.FailCpu) { throw 'simulated failure' }
        $state.Writes++
        if (-not $state.Reject) { $state.Values[$cpu]=($state.Values[$cpu] -band ([UInt64]::MaxValue -bxor [UInt64]274877906944)) -bor ([UInt64]$bit -shl 38) }
        'setbit readback ignored'
    }.GetNewClosure()
    @{ State=$state; Runner=$runner }
}
$fake=New-Fake
$before=@(Read-TurboState $fake.Runner)
Check ($before[0].DisableBit -eq 0 -and $before[1].DisableBit -eq 1) 'Wrong polarity.'
$after=@(Set-TurboState 0 $fake.Runner)
Check (@($after | Where-Object DisableBit -ne 0).Count -eq 0) 'Enable failed.'
Check ($fake.State.Writes -eq 6) 'Unnecessary writes.'
for ($i=0; $i -lt 12; $i++) { Check (($before[$i].Value -band ([UInt64]::MaxValue -bxor [UInt64]274877906944)) -eq ($after[$i].Value -band ([UInt64]::MaxValue -bxor [UInt64]274877906944))) 'Unrelated bits changed.' }
$null=Set-TurboState 0 $fake.Runner
Check ($fake.State.Writes -eq 6) 'Idempotent enable performed writes.'
$after=@(Set-TurboState 1 $fake.Runner)
Check (@($after | Where-Object DisableBit -ne 1).Count -eq 0) 'Disable failed.'
Throws { ConvertFrom-MsrOutput '' } 'Expected exactly'
$eight=(0..7 | ForEach-Object { '0 {0} 0x000001a0 0x0000000000851889' -f $_ }) -join "`n"
Check (@(ConvertFrom-MsrOutput $eight).Count -eq 8) 'Other processor counts should parse.'
Check (@(ConvertFrom-MsrOutput $eight 8).Count -eq 8) 'Matching expected count should parse.'
Throws { ConvertFrom-MsrOutput $eight 12 } 'Expected exactly'
Throws { ConvertFrom-MsrOutput ($eight -replace '0 7 ','0 9 ') } 'Missing or duplicate'
# CPU gate and untested-processor warning logic (pure functions; no registry or hardware access).
$tested=ConvertTo-CpuInfo '12th Gen Intel(R) Core(TM) i5-12450H' 'Intel64 Family 6 Model 154 Stepping 3' 'GenuineIntel' 12
$other=ConvertTo-CpuInfo 'Intel(R) Core(TM) i7-9750H' 'Intel64 Family 6 Model 158 Stepping 10' 'GenuineIntel' 12
$fewer=ConvertTo-CpuInfo '12th Gen Intel(R) Core(TM) i5-12450H' 'Intel64 Family 6 Model 154 Stepping 3' 'GenuineIntel' 8
$amd=ConvertTo-CpuInfo 'AMD Ryzen 7 5800H' 'AMD64 Family 25 Model 80 Stepping 0' 'AuthenticAMD' 16
$huge=ConvertTo-CpuInfo 'Intel(R) Xeon(R)' 'Intel64 Family 6 Model 143' 'GenuineIntel' 128
Check $tested.Tested 'The reference CPU should be recognized as tested.'
Check (-not $other.Tested -and -not $fewer.Tested) 'Other Intel CPUs and processor counts must count as untested.'
Check ((Assert-IntelCpu $other).Name -match 'i7-9750H') 'Other Intel CPUs must be allowed.'
Throws { Assert-IntelCpu $amd } 'Intel processors only'
Throws { Assert-IntelCpu $huge } 'Unsupported logical processor count'
# Real registry read, cross-checked against an independent source (CIM/WMI). Read-only.
$real=Get-CpuInfo
$cim=@(Get-CimInstance -ClassName Win32_Processor)
Check ($real.LogicalProcessors -eq [int](($cim | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)) 'Registry processor count disagrees with CIM.'
Check ($real.Name -eq ([string]$cim[0].Name).Trim()) 'Registry CPU name disagrees with CIM.'
Check ($real.Vendor -eq $cim[0].Manufacturer) 'Registry CPU vendor disagrees with CIM.'
Check ($real.Identifier -eq $cim[0].Caption) 'Registry CPU identifier disagrees with CIM.'
Check ($real.Tested -eq ($real.Name -match '\bi5-12450H\b' -and $real.Identifier -match 'Family 6 Model 154\b' -and $real.LogicalProcessors -eq 12)) 'Tested flag is inconsistent with the real CPU.'
if ($real.Vendor -eq 'GenuineIntel' -and $real.LogicalProcessors -le 64) { Check ((Assert-IntelCpu).LogicalProcessors -eq $real.LogicalProcessors) 'Assert-IntelCpu should accept this real CPU.' }
else { Throws { Assert-IntelCpu } 'Intel processors only|Unsupported logical processor count' }
Confirm-UntestedCpu $tested
$null=Confirm-UntestedCpu $other -AcceptRisk 6>$null
Check $true 'Tested CPUs and -AcceptRisk must not prompt.'
# Simulate the prompt (a global function shadows Read-Host only for this check).
function global:Read-Host { $script:fakeAnswer }
try {
    $script:fakeAnswer='yes'
    Throws { Confirm-UntestedCpu $other 6>$null } 'risk was not accepted'
    $script:fakeAnswer=''
    Throws { Confirm-UntestedCpu $other 6>$null } 'risk was not accepted'
    $script:fakeAnswer='YES'
    Confirm-UntestedCpu $other 6>$null
    Check $true 'Typing YES should accept the risk.'
} finally { Remove-Item Function:\Read-Host }

$text=& $fake.Runner -Arguments @('-A','-l','read','0x1A0')
Throws { ConvertFrom-MsrOutput ($text -replace '0 11 ','0 10 ') } 'Missing or duplicate'
Throws { ConvertFrom-MsrOutput ($text+'error') } 'Unexpected'
$fake=New-Fake; $fake.State.Reject=$true
Throws { Set-TurboState 0 $fake.Runner } 'did not retain'
$fake=New-Fake; $fake.State.Corrupt=$true
Throws { Set-TurboState 0 $fake.Runner } 'unrelated'
$fake=New-Fake; $fake.State.FailCpu=3
Throws { Set-TurboState 0 $fake.Runner } 'simulated failure'
Check ($fake.State.Writes -eq 1) 'Continued after failure.'

# Failure policy (retry or fail directly): explicit values, unattended default, interactive prompt.
Check ((Resolve-FailurePolicy 'Fail') -eq 'Fail' -and (Resolve-FailurePolicy 'Retry' -Interactive) -eq 'Retry') 'An explicit policy must win without prompting.'
Check ((Resolve-FailurePolicy '') -eq 'Retry') 'Unattended installs must default to Retry.'
function global:Read-Host { $script:fakeAnswer }
try {
    $script:fakeAnswer=''
    Check ((Resolve-FailurePolicy '' -Interactive 6>$null) -eq 'Retry') 'Pressing Enter should choose Retry.'
    $script:fakeAnswer='y'
    Check ((Resolve-FailurePolicy '' -Interactive 6>$null) -eq 'Retry') 'Anything but N should choose Retry.'
    $script:fakeAnswer='N'
    Check ((Resolve-FailurePolicy '' -Interactive 6>$null) -eq 'Fail') 'Typing N should choose Fail.'
    $script:fakeAnswer='no'
    Check ((Resolve-FailurePolicy '' -Interactive 6>$null) -eq 'Fail') 'Typing no should choose Fail.'
} finally { Remove-Item Function:Read-Host }
$configDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\obj'))) ('config-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $configPath=Join-Path $configDirectory 'config.json'
    Write-ServiceConfig $configPath 'Fail'
    Check ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).RetryOnFailure -eq $false) 'Fail must write RetryOnFailure=false.'
    Write-ServiceConfig $configPath 'Retry'
    Check ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).RetryOnFailure -eq $true) 'Retry must write RetryOnFailure=true.'
    Throws { Write-ServiceConfig $configPath 'Maybe' } 'Maybe'
} finally {
    if (Test-Path -LiteralPath $configDirectory) { Remove-Item -LiteralPath $configDirectory -Recurse -Force }
}

# "Installed apps" registration, against a throwaway HKCU key (never the real HKLM entry).
$entryKey = 'HKCU:\Software\ITBS-Test-' + [Guid]::NewGuid().ToString('N')
try {
    New-UninstallEntry $entryKey 'C:\Fake\ITBS' '"C:\Fake\ITBS\source\Uninstall.cmd"'
    $entry = Get-ItemProperty -LiteralPath $entryKey
    Check ($entry.DisplayName -eq 'Intel TurboBoost Switcher' -and $entry.InstallLocation -eq 'C:\Fake\ITBS') 'The uninstall entry should name the product and its location.'
    Check ($entry.UninstallString -eq '"C:\Fake\ITBS\source\Uninstall.cmd"' -and $entry.NoModify -eq 1 -and $entry.NoRepair -eq 1) 'The uninstall entry should run Uninstall.cmd and hide Modify/Repair.'
    Remove-UninstallEntry $entryKey 'C:\Other\ITBS' 3>$null
    Check (Test-Path -LiteralPath $entryKey) 'An entry that belongs to another location must not be removed.'
    Remove-UninstallEntry $entryKey 'C:\Fake\ITBS'
    Check (-not (Test-Path -LiteralPath $entryKey)) 'The matching uninstall entry should be removed.'
    Remove-UninstallEntry $entryKey 'C:\Fake\ITBS'
    Check $true 'Removing a missing entry must not fail.'
} finally {
    if (Test-Path -LiteralPath $entryKey) { Remove-Item -LiteralPath $entryKey -Recurse -Force }
}

# Check the build-record verifier with text-only fixtures; nothing is executed.
$testRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\obj'))
$fixture=Join-Path $testRoot ('verify-' + [Guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'source'; $engine=Join-Path $fixture 'engine'
try {
    New-Item -ItemType Directory -Path $source,$engine -Force | Out-Null
    $sourceFile=Join-Path $source 'fixture.ps1'
    $exeFile=Join-Path $fixture 'ITBS.Service.exe'
    $dependencyFile=Join-Path $engine 'fixture.dat'
    Set-Content -LiteralPath $sourceFile '# fixture' -Encoding ASCII
    Set-Content -LiteralPath $exeFile 'Not an executable; hash-verification fixture only.' -Encoding ASCII
    Set-Content -LiteralPath $dependencyFile 'fixture dependency' -Encoding ASCII
    $sourceHash=(Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $exeHash=(Get-FileHash -LiteralPath $exeFile -Algorithm SHA256).Hash
    $pins=[ordered]@{ files=[ordered]@{ 'fixture.dat'=(Get-FileHash -LiteralPath $dependencyFile -Algorithm SHA256).Hash } }
    @{msrUtility=$pins} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $source 'dependencies.json')
    $record=[ordered]@{ Version=1; SourceInputs=@(@{Path='fixture.ps1';SHA256=$sourceHash}); Dependency=$pins
        Output=@{File='ITBS.Service.exe';SHA256=$exeHash} }
    $recordPath=Join-Path $fixture 'build-record.json'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Test-RecordedBuild $fixture $source $engine
    Check $true 'A valid record should verify.'
    Add-Content -LiteralPath $sourceFile '# changed'
    Throws { Test-RecordedBuild $fixture $source $engine } 'Source hash mismatch'
    Set-Content -LiteralPath $sourceFile '# fixture' -Encoding ASCII
    Add-Content -LiteralPath $exeFile 'changed'
    Throws { Test-RecordedBuild $fixture $source $engine } 'executable hash mismatch'
    Set-Content -LiteralPath $exeFile 'Not an executable; hash-verification fixture only.' -Encoding ASCII
    Add-Content -LiteralPath $dependencyFile 'changed'
    Throws { Test-RecordedBuild $fixture $source $engine } 'Dependency hash mismatch'
    $record.SourceInputs=@(@{Path='..\outside.ps1';SHA256=$sourceHash})
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Throws { Test-RecordedBuild $fixture $source $engine } 'escapes'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($testRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup target.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "PASS: $script:checks PowerShell assertions; fake driver and build-record fixtures only."
