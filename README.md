# Intel TurboBoost Switcher

Clears the Intel Turbo-disable bit from Windows, at boot or on demand.

Turbo Boost lets an Intel CPU run above its base clock. Some laptops and mini PCs,
notably from Chinese makers, ship firmware with no BIOS/UEFI setting for it and
may leave it off. This tool turns it back on from Windows. It changes only that one
CPU setting; power limits, voltages and thermal protection are untouched.

**If your BIOS has a Turbo Boost option, use that instead.**

Tested on one machine only: an Intel Core i5-12450H with 12
logical processors. On any other Intel CPU it runs after a warning and a typed
`YES`, entirely at your own risk. Windows x64 and Intel only; AMD is refused.

## Requirements

- Windows x64 with 64-bit Windows PowerShell 5.1 and .NET Framework 4.7.2+.
  No Visual Studio, WDK or NuGet packages are needed.
- An Intel CPU with 1-64 logical processors.
- Administrator rights.

## How it works

The tool clears `IA32_MISC_ENABLE` (`0x1A0`), **Turbo Mode Disable, bit 38**:
`0` permits Turbo, `1` disables it.

ITBS, short for Intel TurboBoost Switcher, is the name of the scripts, the Windows service
and the install folders.

The installer compiles the Windows service on your computer from the source it installs.
The manual controller is plain PowerShell.

## Install

1. Download or clone this repository.
2. Close any application that potentially accesses MSR settings (Intel XTU, etc.).
3. Run **Install.cmd** and accept the UAC prompt. If a warning is printed, verify
   compatibility and type `YES` to continue.

From an elevated terminal instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
# Unattended install on an untested CPU: accept the risk explicitly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -AcceptUntestedRisk
```

The installer downloads a pinned, hash-checked copy of msr-utility, copies the
source to `%ProgramFiles%\ITBS` (writable only by Administrators and SYSTEM),
compiles the service on your computer, and registers it as the automatic
**ITBS** Windows service ("Intel TurboBoost Switcher") under LocalSystem. If the
installation fails, it removes the service and installed files again and keeps the logs.

The service clears the Turbo-disable bit at startup and after every resume from sleep;
it does not poll. By default, if an attempt fails, or Intel XTU or a similar tool is
open, it retries after 1, 5 and 15 minutes and then every 30 minutes until it succeeds.
It does not re-check afterwards, so if another tool or the firmware changes the setting
later, run `Restart-Service ITBS` to apply it again.

Retrying is optional. **Install.cmd** asks (Enter keeps retrying, `N` turns it off).
From a terminal choose it with `-OnFailure`:

```powershell
# Default: retry a failed attempt with a growing delay
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -OnFailure Retry
# Fail directly: record the error in the status and logs, do not retry
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -OnFailure Fail
```

The choice is saved in `config.json` in the install folder, which only Administrators can
change. To switch later, set `"RetryOnFailure"` to `true` or `false` there and run
`Restart-Service ITBS`. When retrying is off and an attempt fails, the status shows
the error; fix the cause and run `Restart-Service ITBS`.

By default the installer prints a title, a short list of steps with their results, and
a short outcome. Add `-Verbose` to also see the details: paths, hashes, compiler
arguments and test output.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Verbose
```

Check that it worked:

```powershell
Get-Service ITBS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ITBS.ps1 -Mode Read
```

`ITBS.ps1 -Mode Read` prints a sentence such as "Turbo is enabled on all N logical
processors." Add `-Verbose` to also see the per-processor `DisableBit` table (0 means
Turbo is permitted). To remove the service, see [Uninstall](#uninstall). To reinstall,
uninstall first.

Upgrading from an early pre-release build that used the old name `StopThrottle`? The
installer detects it and stops with the commands to remove it. It never deletes it for you.

## Manual use

Either run **ITBS.cmd** for a menu, or use an elevated terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ITBS.ps1 -Mode Read
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ITBS.ps1 -Mode EnableTurbo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ITBS.ps1 -Mode DisableTurbo
```

On an untested CPU it prints the warning when it opens and asks for `YES` (or
`-AcceptUntestedRisk`) before the first write.

Like the installer, it prints a short list of steps with results. Add `-Verbose` to
also see the register table and engine details.

Manual writes refuse to run while the ITBS service or another recognized
tuning tool is active. For an A/B test, stop the service.

```powershell
Stop-Service ITBS
# Test DisableTurbo, then EnableTurbo.
Start-Service ITBS
```

Both the service and the manual tool write only bit 38, then read the full register
back on every logical processor and check that no other bit changed. A partial
failure stops further writes; read the current state before retrying. Actual clocks
still depend on the CPU's other limits.

## Uninstall

Any of these removes ITBS:

- Open **Settings > Apps > Installed apps**, find **Intel TurboBoost Switcher** and
  choose Uninstall.
- Run **Uninstall.cmd**, from this repository or from `%ProgramFiles%\ITBS\source`, and
  accept the UAC prompt. It asks for a final Enter before removing anything.
- Or use an elevated terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Uninstall
```

This stops and removes the service, deletes its installation directory and removes the
Installed apps entry. It checks the absolute deletion target and refuses redirected
files or directories. If another program holds a driver file open, cleanup can fail:
close it or reboot, then retry. Shared WinRing0 driver registrations are not forcibly
removed.

The current CPU setting, logs, manual-engine files and optional policy backups under
`%ProgramData%` are kept. Uninstalling does not force Turbo off; firmware and other
startup tools decide the state after the next reboot.

## Important notes

**msr-utility, which does the actual hardware access.** The scripts download the
pinned **20230811** release of [msr-utility](https://github.com/cocafe/msr-utility)
from GitHub, verify the archive SHA-256 **before extraction**, accept exactly the three
expected files, and verify each file again before use. The pins are in
[dependencies.json](dependencies.json). These files stay separate under `engine\`
and are never embedded in the compiled service. The WinRing0 driver is signed; the
msr-cmd EXE and DLL are unsigned. Hashes prove the files are the pinned bytes. They
do not prove the files are free of vulnerabilities, or that upstream builds are
reproducible. Please be careful to validate that the GitHub repository is still
legitimate.

**The WinRing0 driver is a known vulnerable-driver concern.** Read
[Microsoft's WinRing0 notice](https://support.microsoft.com/en-au/windows/security/threat-malware-protection/microsoft-defender-antivirus-alert-vulnerabledriver-winnt-winring0)
before installing. A readable wrapper does not make that driver safe. This project
makes no claim about security or compatibility.

**The compiled service.** It is unsigned user-mode code generated on your computer.
Windows or organization application-control policy may restrict it, and driver-signing
rules still apply to WinRing0.

## Inspect and verify an installation

```text
%ProgramFiles%\ITBS\
  source\                    Readable source, scripts, dependency manifest, tests
  engine\                    Separately downloaded msr-cmd / WinRing0 files
  ITBS.Service.exe           Generated locally from source\src\*.cs
  build-record.json          Build inputs, compiler command, and output hashes
  install-info.json          Installation ownership marker
  config.json                Service setting: retry after a failure or not
  THIRD-PARTY-NOTICES.txt
```

```powershell
# Check source, generated service, and native files against the local build record.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Verify

# Last recorded service result; does not read CPU registers.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Status
```

Runtime status and rotating logs are in `%ProgramData%\ITBS\status.json` and
`service.log`. Last attempt and last success are separate fields, and the status is
not a fresh hardware reading; use `-Mode Read` for that.

## Optional: driver policy script

Installing and using the tool leave Windows security policy unchanged. If Windows
blocks WinRing0, first look at the Defender and Code Integrity events. The msr-utility
README suggests setting
`HKLM\SYSTEM\CurrentControlSet\Control\CI\Config\VulnerableDriverBlocklistEnable`
to `0`. That **system-wide** change also lets other vulnerable drivers load.

```powershell
# Read-only; the default action.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-LegacyDriverPolicy.ps1 -Action Status
# Explicit opt-in: backs up the original value (or its absence), then writes DWORD 0.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-LegacyDriverPolicy.ps1 -Action DisableBlocklist
# Restore the original value or absence.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-LegacyDriverPolicy.ps1 -Action Restore
```

Disable and restore need elevation and a restart. They do not guarantee the driver
loads: HVCI, Smart App Control, App Control and other policies may still block it. The
script does not turn those off, change Secure Boot, add antivirus exclusions, or
restart the computer. See
[Microsoft's driver block rules](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/microsoft-recommended-driver-block-rules).
The `-ExecutionPolicy Bypass` argument affects only the process it launches;
organization policy can still block scripts.

## Development

These commands are for development only.

```powershell
# Download and verify dependencies, compile into obj\service, run the simulated tests.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# Fetch the pinned archive again; the expected hashes do not change.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -RefreshDownloads
# Also show paths, hashes, compiler arguments and test output.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Verbose
```

## License

MIT; see [LICENSE](LICENSE). Keep [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt)
when distributing the native files. Intel TurboBoost Switcher is not affiliated with
Intel or with the authors of msr-utility.
