# WinServBackup

Einfache, geplante Komplett-Backups für **Windows Server 2016 und neuer**. Das ganze System landet in **einer einzigen Datei** (`.wim`). Zum Zurückspielen startet man den Server von einem **Boot-Medium** (WinPE), das einen Assistenten mitbringt.

Seite: <https://fmatsch.ist/WinServBackup/>

## So funktioniert es

| Schritt | Was passiert |
|---|---|
| Snapshot | Alle zu sichernden Laufwerke bekommen gemeinsam einen VSS-Snapshot (`diskshadow`), mit VSS-Writern für anwendungskonsistente Daten. Der Server läuft währenddessen normal weiter. |
| Abbild | Aus dem Snapshot entsteht per DISM eine WIM-Datei: ein Abbild pro Laufwerk plus ein Manifest (Server, Datum, Laufwerke, Datenträger-Layout, UEFI/BIOS). |
| Prüfen | Erst nach erfolgreicher Prüfung wird die Datei umbenannt und erst dann werden ältere Sicherungen nach Anzahl gelöscht. Ein fehlgeschlagenes Backup löscht nie ein altes. |
| Zeitplan | Jeder Auftrag ist eine Aufgabe im Windows-Aufgabenplaner (als `SYSTEM`): täglich, wöchentlich, monatlich, alle X Stunden oder nur manuell. |
| Wiederherstellung | Vom Boot-Medium starten, Backup und Zieldatenträger wählen: Der Assistent partitioniert, spielt die Abbilder ein, richtet den Start (BCD) ein und übernimmt die Laufwerksbuchstaben. |

## Installation

Voraussetzung: Windows Server 2016 oder neuer mit Desktopdarstellung (für die Oberfläche), PowerShell 5.1 (ist enthalten). Auf Server Core lässt sich alles über die PowerShell-Befehle steuern (siehe unten).

- **`WinServBackup-Setup.exe`** (Release): installiert nach `C:\Program Files\WinServBackup`, legt die Startmenü-Verknüpfung an. Stille Installation: `WinServBackup-Setup.exe /silent` (optional `/desktop`).
- **`WinServBackup.zip`**: entpacken und `WinServBackup.exe` starten. Die EXE ist ein kleiner Starter, der die Oberfläche mit Administratorrechten und ohne Konsolenfenster öffnet.
- **Skript-Variante:** `powershell -ExecutionPolicy Bypass -File .\Install.ps1` (als Administrator).

Die EXE-Dateien sind nicht signiert; SmartScreen fragt deshalb einmal nach. Prüfsummen: `SHA256SUMS`. Gebaut werden sie mit `build\Build-Exe.ps1` (C#-Compiler aus Windows, keine Fremdwerkzeuge).

Danach im Startmenü **WinServBackup** öffnen:

1. **Aufträge → Neuer Auftrag**: Name, Ziel (lokaler Ordner oder `\\nas\freigabe`), Zeitplan, Aufbewahrung. Mit „Ziel testen“ prüfen.
2. **Wiederherstellung → Boot-Medium erstellen**: ISO oder USB-Stick. Dafür wird einmalig das kostenlose [Windows ADK mit WinPE-Add-on](https://learn.microsoft.com/windows-hardware/get-started/adk-install) gebraucht.
3. Fertig. Die Übersicht zeigt Status, nächste Sicherung und freien Platz.

## Wiederherstellen

1. Server vom Boot-Medium starten.
2. Der Assistent sucht `.wim`-Sicherungen auf allen Laufwerken. Netzwerkfreigaben lassen sich verbinden.
3. Backup wählen → Zieldatenträger wählen → mit `WIEDERHERSTELLEN` bestätigen.
4. Neu starten. Der Server läuft wie zum Zeitpunkt der Sicherung.

### Auf anderer Hardware (hardwareunabhängig)

Der Assistent hat dafür die Option **„Auf abweichender Hardware starten“** (standardmäßig an):

- Alle in Windows enthaltenen Speichertreiber (AHCI, NVMe, SAS/RAID-Klassiker, Hyper-V storvsc) werden in der wiederhergestellten Installation vor dem ersten Start als Boot-Treiber aktiviert. Das verhindert `INACCESSIBLE_BOOT_DEVICE` beim Wechsel z. B. von RAID-Controller zu NVMe oder auf eine VM.
- Zusätzliche Treiber (RAID, Netzwerk) werden aus einem frei gewählten Ordner eingespielt. Wer sie mit auf das Boot-Medium legen will: `New-RecoveryMedia.ps1 -ExtraDriverPath C:\Treiber`. Der Assistent nutzt `X:\WSB\Drivers` dann automatisch.
- Startmodus (UEFI/BIOS) und Partitionierung richten sich nach dem **Zielsystem**, nicht nach dem Original.

Danach: Netzwerkkarten sind neu und bekommen Standardeinstellungen (DHCP), die Windows-Aktivierung kann neu fällig werden, und Treiber der alten Hardware lassen sich anschließend deinstallieren. Ein echter Start auf abweichender Hardware ist nicht automatisiert getestet; die Registry-Anpassung ist es.

## Ohne Oberfläche (Server Core, Skripte)

```powershell
Import-Module "C:\Program Files\WinServBackup\src\WinServBackup.psm1"
$j = New-WsbJob
$j.name = 'Nachtsicherung'; $j.target.path = '\\nas\backup\srv1'; $j.keep = 14
$j.schedule.type = 'daily'; $j.schedule.time = '01:30'
Save-WsbJob $j            # speichert und legt die geplante Aufgabe an
Start-WsbBackup -Job $j   # sofort ausführen
Get-WsbHistory            # Verlauf
```

Wiederherstellung per Befehl (z. B. in WinPE): `Restore-WsbBackup -BackupFile D:\srv1_..._20261103-020000.wim -DiskMap @{ 0 = 1 }` (Quell-Datenträger 0 → Ziel-Datenträger 1).

## Grenzen (v0.1)

- Gesichert werden **NTFS**-Laufwerke. ReFS, Dynamische Datenträger, Storage Spaces und Software-RAID werden nicht abgebildet (Hardware-RAID erscheint als normaler Datenträger und geht).
- Jede Sicherung ist ein **Vollbackup** (komprimiert). Es gibt kein inkrementelles Backup und keine Verschlüsselung der Datei. Lege das Ziel passend ab.
- Wiederherstellen auf einen **kleineren** Datenträger als das Original ist nicht möglich; auf größere schon (das letzte Laufwerk wächst mit).
- Das Boot-Medium wird mit dem ADK gebaut und läuft deshalb auf x64-Hardware (UEFI und BIOS).
- Die Wiederherstellungsumgebung ist deutsch. Dateinamen und Pfade mit Sonderzeichen sind getestet.
- Getestet wird automatisch auf einem echten Windows-System (siehe `.github/workflows/ci.yml`): VSS-Backup, Aufbewahrung, Zeitplan, Restore auf einen leeren Datenträger inklusive BCD und Laufwerksbuchstaben. Ein vollständiger Boot eines wiederhergestellten Servers wurde **noch nicht** automatisiert geprüft. Probiere die Wiederherstellung vor dem Ernstfall einmal auf einer VM aus.

## Aufbau

```
src/WinServBackup.psm1    Kern: Aufträge, VSS, Sicherung, Aufbewahrung, Zeitplan, Restore
src/Invoke-Backup.ps1     Einstieg für Aufgabenplaner und Oberfläche
src/Gui/                  WPF-Oberfläche (XAML + PowerShell)
recovery/                 Boot-Medium-Bau (WinPE) und Wiederherstellungs-Assistent
build/                    Starter-EXE, Setup-EXE und Build-Skript
tests/                    Statische Prüfung, End-to-End-Test, EXE-Test
docs/                     GitHub Pages
```

Daten liegen unter `C:\ProgramData\WinServBackup` (Aufträge, Protokolle, Verlauf).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
