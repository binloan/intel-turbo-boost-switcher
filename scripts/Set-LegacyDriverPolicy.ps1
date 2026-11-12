<#
.SYNOPSIS
    Reports, disables, or restores the Windows vulnerable-driver blocklist registry setting.
.DESCRIPTION
    This optional script manages the VulnerableDriverBlocklistEnable registry value under
    HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config. The Status action only reads the value. The
    DisableBlocklist action first saves the original state to a protected backup file in
    %ProgramData%\ITBS, then sets the value to 0 system-wide. The Restore action puts the original value
    (or its absence) back and removes the backup. DisableBlocklist and Restore require Administrator rights.
    The setting is reported as stored in the registry. It does not reflect the effective HVCI, App Control, or
    Secure Boot policy, or whether a driver can load.
.PARAMETER Action
    Status reports the registry setting, DisableBlocklist disables the blocklist after saving a backup, and
    Restore restores the backed-up original state. Defaults to Status.
.EXAMPLE
    .\scripts\Set-LegacyDriverPolicy.ps1
.EXAMPLE
    .\scripts\Set-LegacyDriverPolicy.ps1 -Action DisableBlocklist
.EXAMPLE
    .\scripts\Set-LegacyDriverPolicy.ps1 -Action Restore
.OUTPUTS
    System.String. Human-readable status messages.
#>
#requires -Version 5.1
[CmdletBinding()]
[OutputType([string])]
param (
    # The operation to perform: report the setting, disable the blocklist, or restore the original setting.
    [ValidateSet('Status', 'DisableBlocklist', 'Restore')]
    [string]
    $Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$policy = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'
$name = 'VulnerableDriverBlocklistEnable'
$data = Join-Path -Path $env:ProgramData -ChildPath 'ITBS'
$backup = Join-Path -Path $data -ChildPath 'legacy-driver-policy.json'

$current = $null
$registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\CI\Config')
if ($registryKey) {
    try {
        if ($registryKey.GetValueNames() -contains $name) {
            $current = [pscustomobject]@{
                Value = $registryKey.GetValue($name)
                Kind  = [string]$registryKey.GetValueKind($name)
            }
        }
    } finally {
        $registryKey.Dispose()
    }
}

if ($Action -eq 'Status') {
    if ($null -eq $current) {
        Write-Output -InputObject "$name is not explicitly set; Windows policy/defaults apply."
    } else {
        Write-Output -InputObject ('{0} = {1}' -f $name, $current.Value)
    }
    Write-Output -InputObject (
        'This reports the registry setting, not effective HVCI/App Control/Secure Boot policy ' +
        'or driver loadability.')
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this optional script as Administrator.'
}

# Refuse reparse points so a redirected directory cannot divert the backup or the access-control change.
if (Test-Path -LiteralPath $data) {
    if ((Get-Item -LiteralPath $data -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing redirected data directory.'
    }
}
New-Item -ItemType Directory -Path $data -Force | Out-Null

# Restrict the data directory to Administrators and SYSTEM, because it holds the policy backup.
$acl = New-Object -TypeName Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$admins = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
$system = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
$acl.SetOwner($admins)
foreach ($sid in @($admins, $system)) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $data -AclObject $acl

$machineId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
if (Test-Path -LiteralPath $backup) {
    if ((Get-Item -LiteralPath $backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing redirected policy backup.'
    }
}

if ($Action -eq 'DisableBlocklist') {
    if (-not (Test-Path -LiteralPath $backup)) {
        $kind = $null
        $currentValue = $null
        if ($current) {
            $kind = $current.Kind
            $currentValue = $current.Value
        }
        if ($current -and $kind -ne 'DWord') {
            throw 'Unexpected existing registry value kind; refusing to change it.'
        }
        $json = [ordered]@{
            Version   = 1
            MachineId = $machineId
            Existed   = ($null -ne $current)
            Value     = $currentValue
        } | ConvertTo-Json
        # CreateNew fails when the backup already exists, so an original backup is never overwritten.
        $backupStream = [IO.File]::Open($backup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $backupWriter = New-Object -TypeName IO.StreamWriter -ArgumentList $backupStream
        try {
            $backupWriter.Write($json)
        } finally {
            $backupWriter.Dispose()
        }
    } else {
        $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
        if ($saved.Version -ne 1 -or $saved.MachineId -ne $machineId) {
            throw 'Policy backup belongs to a different machine or schema.'
        }
    }
    Write-Warning -Message (
        'This explicitly disables the vulnerable-driver blocklist registry setting system-wide. ' +
        'It can allow other vulnerable drivers too.')
    New-Item -Path $policy -Force | Out-Null
    New-ItemProperty -LiteralPath $policy -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Output -InputObject (
        'Registry setting set to 0. Restart Windows before retesting. ' +
        'HVCI/App Control may still block the driver.')
} else {
    if (-not (Test-Path -LiteralPath $backup)) {
        throw 'No original-policy backup exists.'
    }
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    if ($saved.Version -ne 1 -or $saved.MachineId -ne $machineId -or $saved.Existed -isnot [bool]) {
        throw 'Invalid or mismatched backup.'
    }
    if ($saved.Existed) {
        $original = [Convert]::ToUInt32($saved.Value)
        New-Item -Path $policy -Force | Out-Null
        New-ItemProperty -LiteralPath $policy -Name $name -PropertyType DWord -Value $original -Force | Out-Null
    } elseif ($current) {
        Remove-ItemProperty -LiteralPath $policy -Name $name -ErrorAction Stop
    }
    Remove-Item -LiteralPath $backup
    Write-Output -InputObject 'Original registry value (or absence) restored. Restart Windows.'
}
