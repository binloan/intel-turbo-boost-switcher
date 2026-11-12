@echo off
cd /d "%SystemRoot%\System32"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Action Uninstall -Interactive & exit
