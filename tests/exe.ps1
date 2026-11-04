# Baut die EXE-Dateien und prueft Starter, Setup (silent), Installation und Deinstallation.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert { param([bool]$Cond, [string]$Msg) if (-not $Cond) { throw "ASSERT FAILED: $Msg" } else { Write-Host "  ok: $Msg" -ForegroundColor Green } }

& (Join-Path $root 'build\Build-Exe.ps1') -Out dist
$dist = Join-Path $root 'dist'
Assert (Test-Path "$dist\WinServBackup-Setup.exe") 'Setup-EXE gebaut'
Assert (Test-Path "$dist\stage\WinServBackup\WinServBackup.exe") 'Starter-EXE gebaut'

Write-Host "`n### Starter-EXE (Selbsttest der Oberflaeche)"
$p = Start-Process "$dist\stage\WinServBackup\WinServBackup.exe" -ArgumentList '-SelfTest' -Wait -PassThru
Assert ($p.ExitCode -eq 0) "Starter-EXE startet die Oberflaeche (Code $($p.ExitCode))"

Write-Host "`n### Setup-EXE (silent)"
$p = Start-Process "$dist\WinServBackup-Setup.exe" -ArgumentList '/silent' -Wait -PassThru
Assert ($p.ExitCode -eq 0) "Setup beendet mit Code $($p.ExitCode)"
$inst = Join-Path $env:ProgramFiles 'WinServBackup'
Assert (Test-Path "$inst\WinServBackup.exe") 'EXE ist installiert'
Assert (Test-Path "$inst\src\WinServBackup.psm1") 'Module sind installiert'
$lnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinServBackup.lnk'
Assert (Test-Path $lnk) 'Startmenue-Verknuepfung existiert'
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
Assert ($target -like '*WinServBackup.exe') "Verknuepfung zeigt auf die EXE ($target)"
$p = Start-Process "$inst\WinServBackup.exe" -ArgumentList '-SelfTest' -Wait -PassThru
Assert ($p.ExitCode -eq 0) 'installierte EXE startet'

Write-Host "`n### Deinstallation"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$inst\Uninstall.ps1" -RemoveData
Assert (-not (Test-Path $lnk)) 'Verknuepfung entfernt'
Write-Host "`nEXE-TESTS BESTANDEN" -ForegroundColor Green
