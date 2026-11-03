#Requires -Version 5.1
# WinServBackup starten (fordert bei Bedarf Administratorrechte an).
param([switch]$SelfTest)
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $PSCommandPath)
    return
}
& (Join-Path $PSScriptRoot 'src\Gui\App.ps1') -SelfTest:$SelfTest
