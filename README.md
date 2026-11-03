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

```powershell
# als Administrator, im entpackten Ordner
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

Danach im Startmenü **WinServBackup** öffnen:

1. **Aufträge → Neuer Auftrag**: Name, Ziel (lokaler Ordner oder `\\nas\freigabe`), Zeitplan, Aufbewahrung. Mit „Ziel testen“ prüfen.
2. **Wiederherstellung → Boot-Medium erstellen**: ISO oder USB-Stick. Dafür wird einmalig das kostenlose [Windows ADK mit WinPE-Add-on](https://learn.microsoft.com/windows-hardware/get-started/adk-install) gebraucht.
3. Fertig. Die Übersicht zeigt Status, nächste Sicherung und freien Platz.

## Wiederherstellen

1. Server vom Boot-Medium starten.
2. Der Assistent sucht `.wim`-Sicherungen auf allen Laufwerken. Netzwerkfreigaben lassen sich verbinden.
3. Backup wählen → Zieldatenträger wählen → mit `WIEDERHERSTELLEN` bestätigen.
4. Neu starten. Der Server läuft wie zum Zeitpunkt der Sicherung.

Wiederherstellen auf anderer Hardware: Im Assistenten lässt sich ein Treiberordner angeben (RAID, Netzwerk). Beim Erstellen des Boot-Mediums können die Treiber des aktuellen Servers eingebunden werden.

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
tests/                    Statische Prüfung und End-to-End-Test
docs/                     GitHub Pages
```

Daten liegen unter `C:\ProgramData\WinServBackup` (Aufträge, Protokolle, Verlauf).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
