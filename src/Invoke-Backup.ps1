#Requires -Version 5.1
# Wird vom Windows-Aufgabenplaner (als SYSTEM) und von der Oberflaeche aufgerufen.
param([Parameter(Mandatory)][string]$JobId)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinServBackup.psm1') -Force
$job = @(Get-WsbJob -Id $JobId)[0]
if (-not $job) { Write-Error "Auftrag '$JobId' nicht gefunden."; exit 2 }
try {
    $r = Start-WsbBackup -Job $job
    if ($r.Status -eq 'ok') { exit 0 } else { exit 1 }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
