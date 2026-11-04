#Requires -Version 5.1
<#
.SYNOPSIS
    Erstellt das WinServBackup-Boot-Medium (WinPE) als ISO-Datei oder USB-Stick.
.DESCRIPTION
    Benoetigt das Windows ADK und das WinPE-Add-on (kostenlos von Microsoft). Das Skript baut ein WinPE-Abbild,
    fuegt PowerShell, den Wiederherstellungs-Assistenten und optional die Treiber dieses Servers hinzu.
.EXAMPLE
    .\New-RecoveryMedia.ps1 -IsoPath D:\WinServBackup-Recovery.iso -IncludeDrivers
.EXAMPLE
    .\New-RecoveryMedia.ps1 -UsbDrive E -IncludeDrivers
#>
param(
    [string]$IsoPath,
    [string]$UsbDrive,
    [switch]$IncludeDrivers,
    [string]$ExtraDriverPath,
    [string]$InputLocale = 'de-DE',
    [string]$WorkDir = (Join-Path $env:TEMP 'WinServBackup-WinPE'),
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mounted = $false

function Write-Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }

function Finish {
    param([int]$Code)
    if (-not $NoPause) { Read-Host 'Zum Schließen Enter drücken' | Out-Null }
    exit $Code
}

try {
    if (-not $IsoPath -and -not $UsbDrive) { throw 'Bitte -IsoPath oder -UsbDrive angeben.' }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Bitte als Administrator ausführen.' }

    # ADK suchen
    $kits = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
    if (-not $kits) { $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\' }
    $adk = Join-Path $kits 'Assessment and Deployment Kit'
    $envBat = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
    $peRoot = Join-Path $adk 'Windows Preinstallation Environment'
    $ocs = Join-Path $peRoot 'amd64\WinPE_OCs'
    if (-not (Test-Path -LiteralPath $envBat) -or -not (Test-Path -LiteralPath (Join-Path $peRoot 'amd64\en-us\winpe.wim'))) {
        Write-Host @'

Das Windows ADK mit dem WinPE-Add-on ist nicht installiert.
Bitte beides von Microsoft installieren (kostenlos):

  1. "Windows ADK"                  -> Bereitstellungstools
  2. "Windows PE Add-on für das ADK"

  https://learn.microsoft.com/windows-hardware/get-started/adk-install

Danach dieses Skript erneut starten.
'@ -ForegroundColor Yellow
        Finish 1
    }

    function Invoke-Adk {
        param([string]$Command)
        $bat = Join-Path $env:TEMP 'wsb-adk.cmd'
        [IO.File]::WriteAllText($bat, "@echo off`r`ncall `"$envBat`" >nul`r`n$Command`r`nexit /b %errorlevel%`r`n", [Text.Encoding]::ASCII)
        & $bat
        if ($LASTEXITCODE -ne 0) { throw "Befehl fehlgeschlagen ($LASTEXITCODE): $Command" }
    }
    function Dism {
        param([string[]]$Arguments, [switch]$Soft)
        Write-Host ('dism ' + ($Arguments -join ' ')) -ForegroundColor DarkGray
        & dism.exe @Arguments
        if ($LASTEXITCODE -ne 0) {
            if ($Soft) { Write-Host "Warnung: dism endete mit Code $LASTEXITCODE" -ForegroundColor Yellow } else { throw "dism endete mit Code $LASTEXITCODE" }
        }
    }

    Write-Step 'WinPE-Basis anlegen'
    if (Test-Path -LiteralPath $WorkDir) {
        & dism.exe /Unmount-Image /MountDir:"$WorkDir\mount" /Discard 2>&1 | Out-Null
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    Invoke-Adk "copype amd64 `"$WorkDir`""

    Write-Step 'Abbild einbinden'
    $mount = Join-Path $WorkDir 'mount'
    $bootWim = Join-Path $WorkDir 'media\sources\boot.wim'
    Dism @('/Mount-Image', "/ImageFile:$bootWim", '/Index:1', "/MountDir:$mount")
    $mounted = $true

    Write-Step 'PowerShell und Werkzeuge hinzufügen'
    $pk = 'WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets'
    foreach ($p in $pk) {
        Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$ocs\$p.cab")
        $lang = Join-Path $ocs "en-us\${p}_en-us.cab"
        if (Test-Path -LiteralPath $lang) { Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$lang") }
    }
    Dism @("/Image:$mount", "/Set-InputLocale:$InputLocale") -Soft

    Write-Step 'Wiederherstellungs-Assistent einfügen'
    $dest = Join-Path $mount 'WSB'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'src\WinServBackup.psm1') -Destination $dest
    Copy-Item -LiteralPath (Join-Path $repo 'recovery\Restore\Restore.ps1') -Destination $dest
    $startnet = @'
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\WSB\Restore.ps1
echo.
echo Der Wiederherstellungs-Assistent wurde beendet.
echo Neu starten: wpeutil reboot      Assistent erneut starten: powershell -ExecutionPolicy Bypass -File X:\WSB\Restore.ps1
echo.
'@
    [IO.File]::WriteAllText((Join-Path $mount 'Windows\System32\startnet.cmd'), ($startnet -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)

    $driverDirs = @()
    if ($IncludeDrivers) {
        Write-Step 'Treiber dieses Servers exportieren'
        $drv = Join-Path $WorkDir 'drivers'
        New-Item -ItemType Directory -Path $drv -Force | Out-Null
        Export-WindowsDriver -Online -Destination $drv | Out-Null
        $driverDirs += $drv
    }
    if ($ExtraDriverPath) { $driverDirs += $ExtraDriverPath }
    if ($ExtraDriverPath -and (Test-Path -LiteralPath $ExtraDriverPath)) {
        # zusaetzlich fuer das wiederhergestellte System bereithalten (Restore spielt X:\WSB\Drivers automatisch ein)
        Copy-Item -LiteralPath $ExtraDriverPath -Destination (Join-Path $dest 'Drivers') -Recurse -Force
    }
    foreach ($d in $driverDirs) {
        Write-Step "Treiber hinzufügen: $d"
        Dism @("/Image:$mount", '/Add-Driver', "/Driver:$d", '/Recurse') -Soft
    }

    Write-Step 'Abbild speichern'
    Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit')
    $mounted = $false

    if ($IsoPath) {
        Write-Step "ISO erstellen: $IsoPath"
        if (Test-Path -LiteralPath $IsoPath) { Remove-Item -LiteralPath $IsoPath -Force }
        Invoke-Adk "MakeWinPEMedia /ISO `"$WorkDir`" `"$IsoPath`""
        Write-Host "`nFertig: $IsoPath" -ForegroundColor Green
    } else {
        $u = $UsbDrive.TrimEnd(':', '\') + ':'
        Write-Step "USB-Stick $u erstellen (wird gelöscht)"
        Invoke-Adk "MakeWinPEMedia /UFD /F `"$WorkDir`" $u"
        Write-Host "`nFertig: Boot-Stick $u" -ForegroundColor Green
    }
    Write-Host 'Bewahren Sie das Medium sicher auf. Es enthält keine Daten Ihres Servers, nur die Wiederherstellungs-Werkzeuge.'
    Finish 0
} catch {
    Write-Host "`nFehler: $($_.Exception.Message)" -ForegroundColor Red
    if ($mounted) { & dism.exe /Unmount-Image /MountDir:"$WorkDir\mount" /Discard 2>&1 | Out-Null }
    Finish 1
}
