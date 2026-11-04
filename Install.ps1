#Requires -Version 5.1
<#
.SYNOPSIS
    Installiert WinServBackup nach "C:\Program Files\WinServBackup" und legt Startmenue-Verknuepfungen an.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1
#>
param([string]$Path = (Join-Path $env:ProgramFiles 'WinServBackup'), [switch]$DesktopShortcut)
$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Bitte als Administrator ausführen.'
}
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 oder neuer ist erforderlich (Windows Server 2016+, Windows 10/11).' }

Write-Host "Installiere nach $Path ..."
if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
foreach ($item in 'src', 'recovery', 'assets', 'WinServBackup.ps1', 'WinServBackup.exe', 'Uninstall.ps1', 'LICENSE', 'README.md') {
    $from = Join-Path $PSScriptRoot $item
    if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $Path -Recurse -Force }
}
Get-ChildItem -LiteralPath $Path -Recurse -File | Unblock-File

$ws = New-Object -ComObject WScript.Shell
function New-Shortcut {
    param([string]$File)
    $s = $ws.CreateShortcut($File)
    $exe = Join-Path $Path 'WinServBackup.exe'
    if (Test-Path -LiteralPath $exe) {
        $s.TargetPath = $exe
    } else {
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f (Join-Path $Path 'WinServBackup.ps1')
    }
    $s.WorkingDirectory = $Path
    $ico = Join-Path $Path 'assets\icon.ico'
    if (Test-Path -LiteralPath $ico) { $s.IconLocation = $ico }
    $s.Description = 'WinServBackup - Sicherung für Windows Server, 10 und 11'
    $s.Save()
}
New-Shortcut (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinServBackup.lnk')
if ($DesktopShortcut) { New-Shortcut (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WinServBackup.lnk') }

Write-Host 'Fertig. WinServBackup finden Sie im Startmenü.' -ForegroundColor Green
