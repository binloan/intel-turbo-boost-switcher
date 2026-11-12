<#
.SYNOPSIS
    Builds the ITBS service and its tests locally, then records and verifies what was compiled.
.DESCRIPTION
    Resolves the pinned msr-utility dependency, checks its SHA-256 hashes, generates
    obj\DependencyHashes.g.cs, and compiles the service and the test executable with the inbox .NET Framework
    csc.exe. It then runs the tests, writes build-record.json next to the service executable, and verifies
    that record with Test-RecordedBuild. No service is installed and no CPU registers or security policies
    are changed.
.PARAMETER RefreshDownloads
    Forces scripts\Get-Dependencies.ps1 to download the pinned dependency archive again.
.PARAMETER DependencyDirectory
    A directory that already holds the verified dependency files. When omitted, the directory is resolved
    by scripts\Get-Dependencies.ps1.
.PARAMETER OutputDirectory
    The directory that receives ITBS.Service.exe and build-record.json. Defaults to obj\service.
.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -RefreshDownloads
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
    $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dependencyFile = Join-Path -Path $root -ChildPath 'dependencies.json'
$dependency = (Get-Content -LiteralPath $dependencyFile -Raw | ConvertFrom-Json).msrUtility
if (-not $DependencyDirectory) {
    $dependencyScript = Join-Path -Path $root -ChildPath 'scripts\Get-Dependencies.ps1'
    $DependencyDirectory = & $dependencyScript -RefreshDownloads:$RefreshDownloads
}
$payload = (Resolve-Path -LiteralPath $DependencyDirectory).Path
foreach ($file in $dependency.files.PSObject.Properties) {
    $filePath = Join-Path -Path $payload -ChildPath $file.Name
    $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
    if ($actualHash -ne $file.Value) {
        throw "Dependency hash mismatch: $($file.Name)"
    }
}
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
$generated = @'
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
$generatedPath = Join-Path -Path $objectDirectory -ChildPath 'DependencyHashes.g.cs'
$entryText = $entries -join ",`r`n"
$generated.Replace('ENTRIES', $entryText) | Set-Content -LiteralPath $generatedPath -Encoding UTF8

$compiler = Join-Path -Path $env:SystemRoot -ChildPath 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The x64 .NET Framework C# compiler is required (.NET Framework 4.7.2+).'
}
$sourceFiles = Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'src') -Filter '*.cs' |
    Sort-Object -Property Name
$sources = @($sourceFiles.FullName) + @($generatedPath)
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
& $compiler @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Local service compilation failed.'
}

$testExe = Join-Path -Path $objectDirectory -ChildPath 'ITBS.Tests.exe'
$testSource = Join-Path -Path $root -ChildPath 'tests\Tests.cs'
$testArguments = $commonArguments + @(('/out:' + $testExe), '/main:ITBS.Tests') + $sources + @($testSource)
& $compiler @testArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Test compilation failed.'
}
& $testExe $payload
if ($LASTEXITCODE -ne 0) {
    throw 'Service core tests failed.'
}

$manualTests = Join-Path -Path $root -ChildPath 'tests\Test-Manual.ps1'
& $manualTests
if (-not $?) {
    throw 'Manual controller tests failed.'
}
$scriptTests = Join-Path -Path $root -ChildPath 'tests\Test-Scripts.ps1'
& $scriptTests
if (-not $?) {
    throw 'Script wiring tests failed.'
}

# Audit what this machine compiled. No dependency is embedded in our executable.
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
Import-Module -Name (Join-Path -Path $root -ChildPath 'scripts\Common.psm1') -Force
Test-RecordedBuild -OutputDirectory $output -SourceDirectory $root -DependencyDirectory $payload
Write-Host -Object "Locally compiled service: $exe"
Write-Host -Object 'No service was installed and no CPU registers or security policies were changed.'
