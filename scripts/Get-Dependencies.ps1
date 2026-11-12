<#
.SYNOPSIS
    Resolves the pinned msr-utility engine directory, downloading and extracting it when needed.
.DESCRIPTION
    Reads the pinned dependency from dependencies.json, downloads the archive into the .deps cache when it is
    missing, and verifies the archive SHA-256 hash. It then checks the archive members, extracts the files
    that are missing or invalid with the Windows tar.exe, and verifies the SHA-256 hash of every extracted
    file. Redirected (reparse point) cache and payload locations are refused.
    Only the resolved engine directory is written to the success stream.
.PARAMETER RefreshDownloads
    Downloads the pinned archive again even when a cached copy exists.
.EXAMPLE
    $engineDirectory = .\scripts\Get-Dependencies.ps1
.EXAMPLE
    $engineDirectory = .\scripts\Get-Dependencies.ps1 -RefreshDownloads
.OUTPUTS
    System.String. The full path of the verified engine directory.
#>
#requires -Version 5.1
[CmdletBinding()]
[OutputType([string])]
param (
    # Downloads the pinned archive again even when a cached copy exists.
    [switch]
    $RefreshDownloads
)

$ErrorActionPreference = 'Stop'


function Assert-Hash {
    <#
    .SYNOPSIS
        Throws when the SHA-256 hash of a file does not match the expected hash.
    .PARAMETER Path
        The file to hash.
    .PARAMETER Expected
        The expected SHA-256 hash.
    .EXAMPLE
        Assert-Hash -Path $archive -Expected $dependency.sha256
    #>
    [CmdletBinding()]
    param (
        # The file to hash.
        [string]
        $Path,

        # The expected SHA-256 hash.
        [string]
        $Expected
    )

    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "SHA-256 mismatch: $Path"
    }
}


$root = Split-Path -Path $PSScriptRoot -Parent
$dependencyFile = Join-Path -Path $root -ChildPath 'dependencies.json'
$dependency = (Get-Content -LiteralPath $dependencyFile -Raw | ConvertFrom-Json).msrUtility
$cache = Join-Path -Path $root -ChildPath '.deps'
$payload = Join-Path -Path $cache -ChildPath ('msr-utility-' + $dependency.version)
$archive = Join-Path -Path $cache -ChildPath ('msr-utility-' + $dependency.version + '.7z')
foreach ($directory in @($cache, $payload)) {
    $isRedirected = (Test-Path -LiteralPath $directory) -and
        ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isRedirected) {
        throw "Refusing redirected download directory: $directory"
    }
}
New-Item -ItemType Directory -Path $cache, $payload -Force | Out-Null

if ($RefreshDownloads -or -not (Test-Path -LiteralPath $archive)) {
    $download = $archive + '.download'
    Write-Host -Object ('Downloading pinned msr-utility release ' + $dependency.version)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $dependency.url -OutFile $download
    Assert-Hash -Path $download -Expected $dependency.sha256
    Move-Item -LiteralPath $download -Destination $archive -Force
}
Assert-Hash -Path $archive -Expected $dependency.sha256

$tar = Join-Path -Path $env:SystemRoot -ChildPath 'System32\tar.exe'
$members = @(& $tar -tf $archive)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the dependency archive. Windows tar.exe is required.'
}
$expectedFiles = @($dependency.files.PSObject.Properties.Name | Sort-Object)
$memberList = ($members | Sort-Object) -join ','
$expectedList = $expectedFiles -join ','
if ($memberList -cne $expectedList) {
    throw 'Unexpected archive members; refusing extraction.'
}
foreach ($name in $expectedFiles) {
    $path = Join-Path -Path $payload -ChildPath $name
    $isRedirected = (Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isRedirected) {
        throw "Refusing redirected dependency: $path"
    }
}

$valid = $true
foreach ($file in $dependency.files.PSObject.Properties) {
    $path = Join-Path -Path $payload -ChildPath $file.Name
    if (-not (Test-Path -LiteralPath $path) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) {
        $valid = $false
    }
}
if (-not $valid) {
    & $tar -xf $archive -C $payload
    if ($LASTEXITCODE -ne 0) {
        throw 'Dependency extraction failed.'
    }
}
foreach ($file in $dependency.files.PSObject.Properties) {
    Assert-Hash -Path (Join-Path -Path $payload -ChildPath $file.Name) -Expected $file.Value
}

# Return only the resolved engine directory on the success stream.
(Resolve-Path -LiteralPath $payload).Path
