#requires -Version 5.1
[CmdletBinding()]
param([switch]$RefreshDownloads, [string]$DependencyDirectory, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dependency = (Get-Content -LiteralPath (Join-Path $root 'dependencies.json') -Raw | ConvertFrom-Json).msrUtility
if (-not $DependencyDirectory) { $DependencyDirectory = & (Join-Path $root 'scripts\Get-Dependencies.ps1') -RefreshDownloads:$RefreshDownloads }
$payload = (Resolve-Path -LiteralPath $DependencyDirectory).Path
foreach ($file in $dependency.files.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $payload $file.Name) -Algorithm SHA256).Hash -ne $file.Value) { throw "Dependency hash mismatch: $($file.Name)" }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'obj\service' }
New-Item -ItemType Directory -Path $OutputDirectory,(Join-Path $root 'obj') -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$entries = @($dependency.files.PSObject.Properties | ForEach-Object { '            { "' + $_.Name + '", "' + $_.Value + '" }' })
$generated = @'
namespace ITBS {
    internal static partial class Payload {
        internal static readonly System.Collections.Generic.Dictionary<string,string> Hashes =
            new System.Collections.Generic.Dictionary<string,string> {
ENTRIES
        };
    }
}
'@
$generatedPath = Join-Path $root 'obj\DependencyHashes.g.cs'
$generated.Replace('ENTRIES',($entries -join ",`r`n")) | Set-Content -LiteralPath $generatedPath -Encoding UTF8
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework C# compiler is required (.NET Framework 4.7.2+).' }
$sources = @((Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.cs' | Sort-Object Name).FullName) + @($generatedPath)
$common = @('/nologo','/target:exe','/platform:x64','/optimize+','/warn:4','/warnaserror+',
    '/r:System.ServiceProcess.dll','/r:System.Runtime.Serialization.dll')
$exe = Join-Path $output 'ITBS.Service.exe'
$arguments = $common + @(('/out:' + $exe), ('/win32manifest:' + (Join-Path $root 'src\app.manifest'))) + $sources
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Local service compilation failed.' }
$testExe = Join-Path $root 'obj\ITBS.Tests.exe'
& $compiler @common ('/out:' + $testExe) '/main:ITBS.Tests' @sources (Join-Path $root 'tests\Tests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Test compilation failed.' }
& $testExe $payload
if ($LASTEXITCODE -ne 0) { throw 'Service core tests failed.' }
& (Join-Path $root 'tests\Test-Manual.ps1')
if (-not $?) { throw 'Manual controller tests failed.' }
& (Join-Path $root 'tests\Test-Scripts.ps1')
if (-not $?) { throw 'Script wiring tests failed.' }

# Audit what this machine compiled. No dependency is embedded in our executable.
$otherInputs=@('src\app.manifest','build.ps1','dependencies.json','Install.ps1','Install.cmd','Uninstall.cmd','ITBS.ps1','ITBS.cmd',
    'scripts\Common.psm1','scripts\Get-Dependencies.ps1','scripts\Set-LegacyDriverPolicy.ps1','tests\Tests.cs','tests\Test-Manual.ps1','tests\Test-Scripts.ps1',
    'README.md','LICENSE','THIRD-PARTY-NOTICES.txt')
$inputPaths = @($sources) + @($otherInputs | ForEach-Object { Join-Path $root $_ })
$inputs = @($inputPaths | ForEach-Object {
    [ordered]@{ Path=$_.Substring($root.Length).TrimStart('\'); SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$record = [ordered]@{
    Version=1; BuiltUtc=[DateTime]::UtcNow.ToString('o')
    Compiler=[ordered]@{ Path=$compiler; SHA256=(Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash; Version=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion }
    Arguments=$arguments; SourceInputs=$inputs; Dependency=$dependency
    Output=[ordered]@{ File='ITBS.Service.exe'; SHA256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash }
}
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'build-record.json') -Encoding UTF8
Import-Module (Join-Path $root 'scripts\Common.psm1') -Force
Test-RecordedBuild -OutputDirectory $output -SourceDirectory $root -DependencyDirectory $payload
Write-Host "Locally compiled service: $exe"
Write-Host 'No service was installed and no CPU registers or security policies were changed.'
