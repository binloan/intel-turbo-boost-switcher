#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Status','DisableBlocklist','Restore')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
$policy = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'
$name = 'VulnerableDriverBlocklistEnable'
$data = Join-Path $env:ProgramData 'ITBS'
$backup = Join-Path $data 'legacy-driver-policy.json'
$current = $null
$registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\CI\Config')
if ($registryKey) {
    try {
        if ($registryKey.GetValueNames() -contains $name) {
            $current = [pscustomobject]@{ Value=$registryKey.GetValue($name); Kind=[string]$registryKey.GetValueKind($name) }
        }
    } finally { $registryKey.Dispose() }
}
if ($Action -eq 'Status') {
    if ($null -eq $current) { Write-Output "$name is not explicitly set; Windows policy/defaults apply." }
    else { Write-Output ('{0} = {1}' -f $name,$current.Value) }
    Write-Output 'This reports the registry setting, not effective HVCI/App Control/Secure Boot policy or driver loadability.'
    exit 0
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this optional script as Administrator.' }
if (Test-Path -LiteralPath $data) {
    if ((Get-Item -LiteralPath $data -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing redirected data directory.' }
}
New-Item -ItemType Directory -Path $data -Force | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
$system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
$acl.SetOwner($admins)
foreach ($sid in @($admins,$system)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit, ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $data -AclObject $acl
$machineId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
if (Test-Path -LiteralPath $backup) {
    if ((Get-Item -LiteralPath $backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing redirected policy backup.' }
}
if ($Action -eq 'DisableBlocklist') {
    if (-not (Test-Path -LiteralPath $backup)) {
        $kind = if ($current) { $current.Kind } else { $null }
        if ($current -and $kind -ne 'DWord') { throw 'Unexpected existing registry value kind; refusing to change it.' }
        $json = [ordered]@{ Version=1; MachineId=$machineId; Existed=($null -ne $current); Value=if ($current) { $current.Value } else { $null } } | ConvertTo-Json
        $backupStream = [IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $backupWriter = New-Object IO.StreamWriter($backupStream)
        try { $backupWriter.Write($json) } finally { $backupWriter.Dispose() }
    } else {
        $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
        if ($saved.Version -ne 1 -or $saved.MachineId -ne $machineId) { throw 'Policy backup belongs to a different machine or schema.' }
    }
    Write-Warning 'This explicitly disables the vulnerable-driver blocklist registry setting system-wide. It can allow other vulnerable drivers too.'
    New-Item -Path $policy -Force | Out-Null
    New-ItemProperty -LiteralPath $policy -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Output 'Registry setting set to 0. Restart Windows before retesting. HVCI/App Control may still block the driver.'
} else {
    if (-not (Test-Path -LiteralPath $backup)) { throw 'No original-policy backup exists.' }
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    if ($saved.Version -ne 1 -or $saved.MachineId -ne $machineId -or $saved.Existed -isnot [bool]) { throw 'Invalid or mismatched backup.' }
    if ($saved.Existed) {
        $original = [Convert]::ToUInt32($saved.Value)
        New-Item -Path $policy -Force | Out-Null
        New-ItemProperty -LiteralPath $policy -Name $name -PropertyType DWord -Value $original -Force | Out-Null
    } elseif ($current) { Remove-ItemProperty -LiteralPath $policy -Name $name -ErrorAction Stop }
    Remove-Item -LiteralPath $backup
    Write-Output 'Original registry value (or absence) restored. Restart Windows.'
}
