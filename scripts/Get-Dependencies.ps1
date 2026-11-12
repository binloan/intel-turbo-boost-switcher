#requires -Version 5.1
[CmdletBinding()]
param([switch]$RefreshDownloads)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dependency = (Get-Content -LiteralPath (Join-Path $root 'dependencies.json') -Raw | ConvertFrom-Json).msrUtility
$cache = Join-Path $root '.deps'
$payload = Join-Path $cache ('msr-utility-' + $dependency.version)
$archive = Join-Path $cache ('msr-utility-' + $dependency.version + '.7z')
foreach ($directory in @($cache,$payload)) {
    if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing redirected download directory: $directory"
    }
}
New-Item -ItemType Directory -Path $cache,$payload -Force | Out-Null
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "SHA-256 mismatch: $Path" }
}
if ($RefreshDownloads -or -not (Test-Path -LiteralPath $archive)) {
    $download = $archive + '.download'
    Write-Host ('Downloading pinned msr-utility release ' + $dependency.version)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $dependency.url -OutFile $download
    Assert-Hash $download $dependency.sha256
    Move-Item -LiteralPath $download -Destination $archive -Force
}
Assert-Hash $archive $dependency.sha256
$tar=Join-Path $env:SystemRoot 'System32\tar.exe'
$members = @(& $tar -tf $archive)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the dependency archive. Windows tar.exe is required.' }
$expectedFiles = @($dependency.files.PSObject.Properties.Name | Sort-Object)
if ((($members | Sort-Object) -join ',') -cne ($expectedFiles -join ',')) { throw 'Unexpected archive members; refusing extraction.' }
foreach ($name in $expectedFiles) {
    $path = Join-Path $payload $name
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing redirected dependency: $path"
    }
}
$valid = $true
foreach ($file in $dependency.files.PSObject.Properties) {
    $path = Join-Path $payload $file.Name
    if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) { $valid = $false }
}
if (-not $valid) {
    & $tar -xf $archive -C $payload
    if ($LASTEXITCODE -ne 0) { throw 'Dependency extraction failed.' }
}
foreach ($file in $dependency.files.PSObject.Properties) { Assert-Hash (Join-Path $payload $file.Name) $file.Value }
# Return only the resolved engine directory on the success stream.
(Resolve-Path -LiteralPath $payload).Path
