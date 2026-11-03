#Requires -Version 5.1
# Entfernt WinServBackup samt geplanter Aufgaben. Auftraege und Protokolle bleiben, ausser mit -RemoveData.
param([string]$Path = (Join-Path $env:ProgramFiles 'WinServBackup'), [switch]$RemoveData)
$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Bitte als Administrator ausführen.'
}
Get-ScheduledTask -TaskPath '\WinServBackup\*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
foreach ($l in (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinServBackup.lnk'), (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WinServBackup.lnk')) {
    Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
}
# Das laufende Skript liegt evtl. selbst im Installationsordner - daher erst nach dem Beenden loeschbar.
if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
if ($RemoveData) { Remove-Item -LiteralPath (Join-Path $env:ProgramData 'WinServBackup') -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'WinServBackup wurde entfernt. Bereits erstellte Sicherungsdateien bleiben unberührt.'
