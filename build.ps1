<#
.SYNOPSIS
    Builds the ITBS service and its tests locally, then records and verifies what was compiled.
.DESCRIPTION
    Resolves the pinned msr-utility dependency, checks its SHA-256 hashes, generates
    obj\DependencyHashes.g.cs, and compiles the service and the test executable with the inbox .NET Framework
    csc.exe. It then runs the tests, writes build-record.json next to the service executable, and verifies
    that record with Test-RecordedBuild. No service is installed and no CPU registers or security policies
    are changed.

    The default output is one line per step. Use -Verbose to see the details: the compiler command, the
    source list, the hashes, and the full output of the compiler and the tests. When something fails, the
    captured output of the failing tool is always printed.
.PARAMETER RefreshDownloads
    Forces scripts\Get-Dependencies.ps1 to download the pinned dependency archive again.
.PARAMETER DependencyDirectory
    A directory that already holds the verified dependency files. When omitted, the directory is resolved
    by scripts\Get-Dependencies.ps1.
.PARAMETER OutputDirectory
    The directory that receives ITBS.Service.exe and build-record.json. Defaults to obj\service.
.PARAMETER FromInstaller
    Set by Install.ps1: omits the standalone 'nothing was installed' note.
.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -RefreshDownloads
.EXAMPLE
    .\build.ps1 -Verbose
#>
#requires -Version 5.1
[CmdletBinding()]
param (
    # Forces the pinned dependency archive to be downloaded again.
    [switch]
    $RefreshDownloads,

    # A directory that already holds the verified dependency files.
    [string]
    $DependencyDirectory,

    # The directory that receives the compiled service and the build record.
    [string]
    $OutputDirectory,

    # Set by Install.ps1: omits the standalone 'nothing was installed' note.
    [switch]
    $FromInstaller
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module -Name (Join-Path -Path $root -ChildPath 'scripts\Common.psm1') -Force -Verbose:$false


function Stop-StepWithOutput {
    <#
    .SYNOPSIS
        Finishes the open step as failed, prints the captured output of the failing tool, and throws.
    .EXAMPLE
        Stop-StepWithOutput -Line $lines -Message 'Test compilation failed.'
    #>
    [CmdletBinding()]
    param (
        # The captured output of the failing tool.
        [string[]]
        $Line,

        # The exception message to throw.
        [Parameter(Mandatory = $true)]
        [string]
        $Message
    )

    $text = if ($Line) { $Line -join [Environment]::NewLine } else { '(The tool printed no output.)' }
    Write-StepFailure -Message $text
    throw $Message
}


function Invoke-Compiler {
    <#
    .SYNOPSIS
        Runs the C# compiler, keeps its output for -Verbose, and prints it only when the compilation fails.
    .EXAMPLE
        Invoke-Compiler -Path $compiler -Argument $arguments -FailureMessage 'Local service compilation failed.'
    #>
    [CmdletBinding()]
    param (
        # The full path of csc.exe.
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        # The compiler arguments.
        [Parameter(Mandatory = $true)]
        [string[]]
        $Argument,

        # The exception message to throw when the compiler fails.
        [Parameter(Mandatory = $true)]
        [string]
        $FailureMessage
    )

    Write-Verbose -Message "Compiler: $Path"
    Write-Verbose -Message "Arguments: $($Argument -join ' ')"
    $lines = @(& $Path @Argument | ForEach-Object -Process { "$_" })
    foreach ($line in $lines) {
        Write-Verbose -Message $line
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-StepWithOutput -Line $lines -Message $FailureMessage
    }
}


function Get-AssertionCount {
    <#
    .SYNOPSIS
        Reads the number of passed assertions from the PASS line of a test's output.
    .EXAMPLE
        Get-AssertionCount -Line $lines
    .OUTPUTS
        System.Int32. Nothing when the output has no PASS line with a count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        # The captured output of a test.
        [string[]]
        $Line
    )

    foreach ($text in $Line) {
        if ($text -match 'PASS: (\d+)') {
            [int]$Matches[1]
        }
    }
}


function Invoke-TestExecutable {
    <#
    .SYNOPSIS
        Runs the compiled C# tests, keeps their output for -Verbose, and prints it only when they fail.
    .EXAMPLE
        Invoke-TestExecutable -Path $testExe -DependencyDirectory $payload
    .OUTPUTS
        System.String. The captured output lines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        # The full path of the test executable.
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        # The verified dependency directory that the tests check.
        [Parameter(Mandatory = $true)]
        [string]
        $DependencyDirectory
    )

    # The test executable writes the failed assertion to stderr. Stop would turn that into an exception.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(
            & $Path $DependencyDirectory 2>&1 | ForEach-Object -Process {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            }
        )
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    foreach ($line in $lines) {
        Write-Verbose -Message $line
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-StepWithOutput -Line $lines -Message 'Service core tests failed.'
    }
    $lines
}


function Invoke-TestScript {
    <#
    .SYNOPSIS
        Runs a PowerShell test script, keeps its output for -Verbose, and prints it only when it fails.
    .EXAMPLE
        Invoke-TestScript -Path $manualTests -FailureMessage 'Manual controller tests failed.'
    .OUTPUTS
        System.String. The captured output lines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        # The full path of the test script.
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        # The exception message to throw when the tests fail.
        [Parameter(Mandatory = $true)]
        [string]
        $FailureMessage
    )

    $lines = @()
    $global:LASTEXITCODE = 0
    try {
        $lines = @(& $Path *>&1 | ForEach-Object -Process { "$_" })
    } catch {
        # The test scripts throw the first failed assertion. Show it with the failure.
        $failure = $_.Exception.Message
        Stop-StepWithOutput -Line @($failure) -Message $FailureMessage
    }
    foreach ($line in $lines) {
        Write-Verbose -Message $line
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-StepWithOutput -Line $lines -Message $FailureMessage
    }
    $lines
}


# The template stays outside the try block because a here-string terminator cannot be indented.
$generatedTemplate = @'
namespace ITBS
{
    internal static partial class Payload
    {
        internal static readonly System.Collections.Generic.Dictionary<string, string> Hashes =
            new System.Collections.Generic.Dictionary<string, string>
            {
ENTRIES
            };
    }
}
'@

try {
    $dependencyFile = Join-Path -Path $root -ChildPath 'dependencies.json'
    $dependency = (Get-Content -LiteralPath $dependencyFile -Raw | ConvertFrom-Json).msrUtility

    Write-Step -Message 'Verifying dependencies'
    if (-not $DependencyDirectory) {
        $dependencyScript = Join-Path -Path $root -ChildPath 'scripts\Get-Dependencies.ps1'
        $DependencyDirectory = & $dependencyScript -RefreshDownloads:$RefreshDownloads
    }
    $payload = (Resolve-Path -LiteralPath $DependencyDirectory).Path
    Write-Verbose -Message "Dependency directory: $payload"
    foreach ($file in $dependency.files.PSObject.Properties) {
        $filePath = Join-Path -Path $payload -ChildPath $file.Name
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if ($actualHash -ne $file.Value) {
            throw "Dependency hash mismatch: $($file.Name)"
        }
        Write-Verbose -Message "Hash verified: $($file.Name) $actualHash"
    }
    Write-StepResult -Detail "msr-utility $($dependency.version)"

    Write-Step -Message 'Compiling service'
    $objectDirectory = Join-Path -Path $root -ChildPath 'obj'
    if (-not $OutputDirectory) {
        $OutputDirectory = Join-Path -Path $objectDirectory -ChildPath 'service'
    }
    New-Item -ItemType Directory -Path $OutputDirectory, $objectDirectory -Force | Out-Null
    $output = (Resolve-Path -LiteralPath $OutputDirectory).Path

    # The generated C# targets the C# 5 compiler, so it avoids newer language features.
    $entries = @($dependency.files.PSObject.Properties | ForEach-Object -Process {
            '                {{ "{0}", "{1}" }}' -f $_.Name, $_.Value
        })
    $generatedPath = Join-Path -Path $objectDirectory -ChildPath 'DependencyHashes.g.cs'
    $entryText = $entries -join ",`r`n"
    $generatedTemplate.Replace('ENTRIES', $entryText) | Set-Content -LiteralPath $generatedPath -Encoding UTF8
    Write-Verbose -Message "Generated dependency hashes: $generatedPath"

    $compiler = Join-Path -Path $env:SystemRoot -ChildPath 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) {
        throw 'The x64 .NET Framework C# compiler is required (.NET Framework 4.7.2+).'
    }
    $sourceFiles = Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'src') -Filter '*.cs' |
        Sort-Object -Property Name
    $sources = @($sourceFiles.FullName) + @($generatedPath)
    foreach ($source in $sources) {
        Write-Verbose -Message "Source: $source"
    }
    $commonArguments = @(
        '/nologo',
        '/target:exe',
        '/platform:x64',
        '/optimize+',
        '/warn:4',
        '/warnaserror+',
        '/r:System.ServiceProcess.dll',
        '/r:System.Runtime.Serialization.dll'
    )
    $exe = Join-Path -Path $output -ChildPath 'ITBS.Service.exe'
    $manifest = Join-Path -Path $root -ChildPath 'src\app.manifest'
    $arguments = $commonArguments + @(('/out:' + $exe), ('/win32manifest:' + $manifest)) + $sources
    Invoke-Compiler -Path $compiler -Argument $arguments -FailureMessage 'Local service compilation failed.'
    Write-Verbose -Message "Service: $exe"
    Write-StepResult

    Write-Step -Message 'Running tests'
    $testExe = Join-Path -Path $objectDirectory -ChildPath 'ITBS.Tests.exe'
    $testSource = Join-Path -Path $root -ChildPath 'tests\Tests.cs'
    $testArguments = $commonArguments + @(('/out:' + $testExe), '/main:ITBS.Tests') + $sources + @($testSource)
    Invoke-Compiler -Path $compiler -Argument $testArguments -FailureMessage 'Test compilation failed.'
    $serviceTestLines = Invoke-TestExecutable -Path $testExe -DependencyDirectory $payload

    $manualTests = Join-Path -Path $root -ChildPath 'tests\Test-Manual.ps1'
    $manualTestLines = Invoke-TestScript -Path $manualTests -FailureMessage 'Manual controller tests failed.'
    $scriptTests = Join-Path -Path $root -ChildPath 'tests\Test-Scripts.ps1'
    $scriptTestLines = Invoke-TestScript -Path $scriptTests -FailureMessage 'Script wiring tests failed.'

    $countParts = @()
    $serviceCount = @(Get-AssertionCount -Line $serviceTestLines) | Select-Object -First 1
    if ($null -ne $serviceCount) {
        $countParts += "$serviceCount C#"
    }
    $manualCount = @(Get-AssertionCount -Line $manualTestLines) | Select-Object -First 1
    if ($null -ne $manualCount) {
        $countParts += "$manualCount PowerShell"
    }
    $scriptCount = @(Get-AssertionCount -Line $scriptTestLines) | Select-Object -First 1
    if ($null -ne $scriptCount) {
        $countParts += "$scriptCount wiring"
    }
    $countDetail = if ($countParts) { ($countParts -join ' + ') + ' assertions' } else { '' }
    Write-StepResult -Detail $countDetail

    # Audit what this machine compiled. No dependency is embedded in our executable.
    Write-Step -Message 'Verifying build record'
    $otherInputs = @(
        'src\app.manifest',
        'build.ps1',
        'dependencies.json',
        'Install.ps1',
        'Install.cmd',
        'Uninstall.cmd',
        'ITBS.ps1',
        'ITBS.cmd',
        'scripts\Common.psm1',
        'scripts\Get-Dependencies.ps1',
        'scripts\Set-LegacyDriverPolicy.ps1',
        'tests\Tests.cs',
        'tests\Test-Manual.ps1',
        'tests\Test-Scripts.ps1',
        'README.md',
        'LICENSE',
        'THIRD-PARTY-NOTICES.txt'
    )
    $inputPaths = @($sources) + @($otherInputs | ForEach-Object -Process { Join-Path -Path $root -ChildPath $_ })
    $inputs = @($inputPaths | ForEach-Object -Process {
            [ordered]@{
                Path   = $_.Substring($root.Length).TrimStart('\')
                SHA256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
            }
        })
    $record = [ordered]@{
        Version      = 1
        BuiltUtc     = [DateTime]::UtcNow.ToString('o')
        Compiler     = [ordered]@{
            Path    = $compiler
            SHA256  = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
            Version = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        }
        Arguments    = $arguments
        SourceInputs = $inputs
        Dependency   = $dependency
        Output       = [ordered]@{
            File   = 'ITBS.Service.exe'
            SHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        }
    }
    $recordPath = Join-Path -Path $output -ChildPath 'build-record.json'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    Write-Verbose -Message "Build record: $recordPath"
    Write-Verbose -Message "Service SHA-256: $($record.Output.SHA256)"
    $checkLines = @(
        Test-RecordedBuild -OutputDirectory $output -SourceDirectory $root -DependencyDirectory $payload 6>&1
    )
    foreach ($checkLine in $checkLines) {
        Write-Verbose -Message "$checkLine"
    }
    Write-StepResult

    if (-not $FromInstaller) {
        Write-Host -Object (
            "  Built $exe. Nothing was installed; " +
            'no CPU registers or security policies were changed.'
        )
    }
} catch {
    $failure = $_.Exception.Message
    if ($FromInstaller) {
        # Install.ps1 prints the message. Only close the open step here.
        Write-StepFailure -Message $failure -NoMessage
        throw
    }
    Write-StepFailure -Message $failure
    exit 1
}
