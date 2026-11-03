# End-to-End-Test auf einem echten Windows-System (GitHub Actions: windows-latest, Administrator).
# Legt virtuelle Datentraeger an, sichert per VSS in eine WIM-Datei, prueft Aufbewahrung und Zeitplan
# und spielt die Sicherung auf einen zweiten, leeren virtuellen Datentraeger zurueck.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $base ('wsb-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:WSB_DATA = Join-Path $work 'data'
Import-Module (Join-Path $root 'src\WinServBackup.psm1') -Force

function Assert { param([bool]$Cond, [string]$Msg) if (-not $Cond) { throw "ASSERT FAILED: $Msg" } else { Write-Host "  ok: $Msg" -ForegroundColor Green } }
function Section { param([string]$T) Write-Host "`n### $T" -ForegroundColor Cyan }

function Invoke-Dp {
    param([string[]]$Lines)
    $f = Join-Path $work ('dp-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($f, ($Lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    $o = & diskpart.exe /s $f | Out-String
    if ($LASTEXITCODE -ne 0) { throw "diskpart: $o" }
    $o
}

function New-TestVhd {
    param([string]$Name, [int]$SizeMB, [string]$Letter, [string]$Label)
    $vhd = Join-Path $work "$Name.vhdx"
    $l = @("create vdisk file=`"$vhd`" maximum=$SizeMB type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk')
    if ($Letter) { $l += 'create partition primary', "format quick fs=ntfs label=$Label", "assign letter=$Letter" }
    [void](Invoke-Dp $l)
    Start-Sleep -Seconds 2
    $vhd
}

function Remove-TestVhd {
    param([string]$Vhd)
    try { [void](Invoke-Dp @("select vdisk file=`"$Vhd`"", 'detach vdisk')) } catch { Write-Host "detach: $_" }
}

$vhds = @()
try {
    # ------------------------------------------------------------ Vorbereitung
    Section 'Quell-Datentraeger anlegen'
    $srcLetter = 'V'
    $vhds += ($srcVhd = New-TestVhd -Name 'src' -SizeMB 700 -Letter $srcLetter -Label 'QUELLE')
    New-Item -ItemType Directory -Path 'V:\Daten\Unter ordner', 'V:\Ümläute' -Force | Out-Null
    Set-Content -Path 'V:\Daten\hallo.txt' -Value 'Hallo Welt äöü' -Encoding UTF8
    Set-Content -Path 'V:\Ümläute\größe.txt' -Value 'Umlaute im Pfad' -Encoding UTF8
    $rnd = New-Object byte[] (24MB); (New-Object Random 42).NextBytes($rnd)
    [IO.File]::WriteAllBytes('V:\Daten\Unter ordner\zufall.bin', $rnd)
    [IO.File]::WriteAllBytes('V:\leer.bin', @())
    $hidden = Get-Item 'V:\Daten\hallo.txt'; $hidden.Attributes = 'Hidden'
    $srcHash = @{}
    Get-ChildItem 'V:\' -Recurse -File -Force | Where-Object { $_.FullName -notmatch 'System Volume Information' } | ForEach-Object { $srcHash[$_.FullName.Substring(3)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    Assert ($srcHash.Count -ge 4) "Testdateien angelegt ($($srcHash.Count))"

    Section 'Volumes erkennen'
    $vol = @(Get-WsbVolume) | Where-Object { $_.Letter -eq $srcLetter }
    Assert ($null -ne $vol -and $vol.Supported) 'V: wird als NTFS erkannt'

    # ------------------------------------------------------------ Auftrag + Zeitplan
    Section 'Auftrag und Zeitplan'
    $target = Join-Path $work 'target'
    $job = New-WsbJob
    $job.name = 'CI Test Ä'
    $job.volumes = @('V:')
    $job.target.path = $target
    $job.keep = 2
    $job.schedule.type = 'daily'; $job.schedule.time = '03:30'
    Save-WsbJob $job
    $task = Get-ScheduledTask -TaskName (Get-WsbTaskName $job.id) -TaskPath '\WinServBackup\' -ErrorAction Stop
    Assert ($task.Principal.UserId -match 'SYSTEM|S-1-5-18') 'Aufgabe laeuft als SYSTEM'
    Assert ($null -ne (Get-WsbNextRun $job.id)) 'naechster Lauf ist berechnet'
    foreach ($t in @(
            @{ type = 'weekly'; days = @('Monday', 'Friday') },
            @{ type = 'monthly'; dayOfMonth = 1 },
            @{ type = 'monthly'; dayOfMonth = 32 },
            @{ type = 'hourly'; everyHours = 6 })) {
        $j2 = New-WsbJob; $j2.name = "Zeitplan-$($t.type)"; $j2.target.path = $target
        foreach ($k in $t.Keys) { $j2.schedule.$k = $t[$k] }
        Save-WsbJob $j2
        Assert ($null -ne (Get-ScheduledTask -TaskName (Get-WsbTaskName $j2.id) -TaskPath '\WinServBackup\')) "Zeitplan '$(Get-WsbScheduleText $j2)' registriert"
        Remove-WsbJob -Id $j2.id
    }
    Assert (@(Get-WsbJob).Count -eq 1) 'Auftragsliste enthaelt genau den Testauftrag'

    # ------------------------------------------------------------ Backup
    Section 'Backup 1'
    $r = Start-WsbBackup -Job $job
    Assert ($r.Status -eq 'ok') "Backup erfolgreich ($($r.Message))"
    Assert (Test-Path -LiteralPath $r.File) 'WIM-Datei existiert'
    $info = Get-WsbBackupInfo -Path $r.File
    Assert ($info.Manifest.host -eq $env:COMPUTERNAME) 'Manifest enthaelt den Servernamen'
    Assert (@($info.Manifest.volumes).Count -eq 1 -and $info.Manifest.volumes[0].letter -eq 'V') 'Manifest enthaelt Laufwerk V'
    Assert (@($info.Images).Count -eq 2) 'Datei enthaelt Manifest- und Laufwerks-Abbild'
    Assert ((Get-WsbState $job.id).status -eq 'ok') 'Status ok'
    Assert (@(Get-WsbHistory).Count -eq 1) 'Verlauf hat einen Eintrag'

    Section 'Backup 2 und 3 (Aufbewahrung = 2)'
    Start-Sleep -Seconds 2; [void](Start-WsbBackup -Job $job)
    Start-Sleep -Seconds 2; $last = Start-WsbBackup -Job $job
    Assert ($last.Status -eq 'ok') 'dritte Sicherung erfolgreich'
    $files = @(Get-WsbBackupFile -Folder $target)
    Assert ($files.Count -eq 2) "nur 2 Sicherungen bleiben ($($files.Count))"
    Assert (-not (Get-ChildItem $target -Filter *.partial.wim)) 'keine halbfertigen Dateien'
    Assert (-not (Test-Path 'Y:\') -and -not (Test-Path 'Z:\')) 'Snapshot-Laufwerke wurden wieder entfernt'

    Section 'Fehlerfall: Ziel nicht beschreibbar'
    $bad = New-WsbJob; $bad.name = 'Fehler'; $bad.volumes = @('Q:'); $bad.target.path = $target
    $br = Start-WsbBackup -Job $bad
    Assert ($br.Status -eq 'error') "fehlendes Laufwerk wird als Fehler gemeldet ($($br.Message))"

    # ------------------------------------------------------------ Restore
    Section 'Wiederherstellung auf leeren Datentraeger'
    $vhds += ($dstVhd = New-TestVhd -Name 'dst' -SizeMB 1000 -Letter $null -Label '')
    $dstDisk = (Get-DiskImage -ImagePath $dstVhd | Get-Disk).Number
    $srcDisk = [int]$info.Manifest.volumes[0].diskNumber
    $newest = (Get-WsbBackupFile -Folder $target | Select-Object -First 1).FullName
    $res = Restore-WsbBackup -BackupFile $newest -DiskMap @{ $srcDisk = [int]$dstDisk } -Firmware UEFI -KeepLetters $true
    $tmpLetter = $res.Letters["${srcDisk}:V"]
    Assert ($tmpLetter) "Zielvolume hat Laufwerk $tmpLetter"
    $bad = 0
    foreach ($k in $srcHash.Keys) {
        $p = "${tmpLetter}:\$k"
        if (-not (Test-Path -LiteralPath $p -Force)) { Write-Host "  fehlt: $k" -ForegroundColor Red; $bad++; continue }
        if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $srcHash[$k]) { Write-Host "  Hash: $k" -ForegroundColor Red; $bad++ }
    }
    Assert ($bad -eq 0) "alle $($srcHash.Count) Dateien identisch wiederhergestellt"
    Assert ((Get-Volume -DriveLetter $tmpLetter).FileSystemLabel -eq 'QUELLE') 'Volume-Bezeichnung uebernommen'

    # ------------------------------------------------------------ Systemlaufwerk simulieren (Bootdateien, bcdboot, MountedDevices)
    Section 'Wiederherstellung mit Systemlaufwerk (simuliert)'
    $env:WSB_SYSTEM_DRIVE = 'V'
    $sysSrc = 'V:\Windows'
    New-Item -ItemType Directory -Path "$sysSrc\System32\config" -Force | Out-Null
    & reg.exe save HKLM\SYSTEM "$sysSrc\System32\config\SYSTEM" /y | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'SYSTEM-Hive exportiert'
    Copy-Item -LiteralPath "$env:SystemRoot\Boot" -Destination "$sysSrc\Boot" -Recurse -Force
    foreach ($f in 'winload.efi', 'winload.exe', 'ntoskrnl.exe', 'hal.dll') {
        if (Test-Path "$env:SystemRoot\System32\$f") { Copy-Item "$env:SystemRoot\System32\$f" "$sysSrc\System32\$f" -Force }
    }
    $sj = New-WsbJob; $sj.name = 'System'; $sj.volumes = @('V:'); $sj.target.path = $target; $sj.keep = 5
    $sr = Start-WsbBackup -Job $sj
    Assert ($sr.Status -eq 'ok') "Sicherung mit simuliertem System ($($sr.Message))"
    $sInfo = Get-WsbBackupInfo -Path $sr.File
    Assert ($sInfo.Manifest.volumes[0].isSystem) 'Laufwerk ist als System markiert'
    Remove-TestVhd $dstVhd; Remove-Item $dstVhd -Force
    $vhds = @($srcVhd)
    $vhds += ($dst2 = New-TestVhd -Name 'dst2' -SizeMB 1200 -Letter $null -Label '')
    $dstDisk2 = (Get-DiskImage -ImagePath $dst2 | Get-Disk).Number
    $res2 = Restore-WsbBackup -BackupFile $sr.File -DiskMap @{ $srcDisk = [int]$dstDisk2 } -Firmware UEFI -KeepLetters $true
    Assert ($res2.BootLetter) "EFI-Partition hat Laufwerk $($res2.BootLetter)"
    Assert (Test-Path "$($res2.BootLetter):\EFI\Microsoft\Boot\BCD") 'BCD-Speicher wurde angelegt'
    Assert (Test-Path "$($res2.BootLetter):\EFI\Boot\bootx64.efi") 'EFI-Fallback-Starter vorhanden'
    $part = Get-Partition -DiskNumber $dstDisk2 | Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
    Assert ($null -ne $part) 'Datentraeger ist GPT mit EFI-Systempartition'
    # MountedDevices im wiederhergestellten System pruefen
    $osLetter = $res2.Letters["${srcDisk}:V"]
    & reg.exe load HKLM\WSB_CHECK "${osLetter}:\Windows\System32\config\SYSTEM" | Out-Null
    try {
        $v = (Get-ItemProperty 'HKLM:\WSB_CHECK\MountedDevices' -ErrorAction Stop).'\DosDevices\V:'
        Assert ($v -and $v.Length -eq 24 -and [Text.Encoding]::ASCII.GetString($v, 0, 8) -eq 'DMIO:ID:') 'MountedDevices: V: zeigt auf die neue GPT-Partition'
    } finally { [gc]::Collect(); [gc]::WaitForPendingFinalizers(); & reg.exe unload HKLM\WSB_CHECK | Out-Null }

    Write-Host "`nALLE TESTS BESTANDEN" -ForegroundColor Green
} catch {
    Write-Host "`nTEST FEHLGESCHLAGEN: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    foreach ($l in Get-ChildItem (Get-WsbLogDir) -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 2) {
        Write-Host "---- $($l.Name)"; Get-Content $l.FullName | Select-Object -Last 40
    }
    $exit = 1
} finally {
    foreach ($j in @(Get-WsbJob)) { Remove-WsbJob -Id $j.id }
    foreach ($v in $vhds) { Remove-TestVhd $v }
    Remove-Item Env:\WSB_SYSTEM_DRIVE -ErrorAction SilentlyContinue
}
if ($exit) { exit $exit }
