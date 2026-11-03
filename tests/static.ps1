# Statische Pruefung: PowerShell-Syntax, UTF-8-BOM (Windows PowerShell 5.1 liest sonst Umlaute falsch), XAML-Wohlgeformtheit.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$failed = 0

foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\\.git\\' }) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $rel = $f.FullName.Substring($root.Length + 1)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) { Write-Host "FEHLT BOM: $rel" -ForegroundColor Red; $failed++ }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Host ("SYNTAX {0}:{1}  {2}" -f $rel, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
        $failed++
    } else { Write-Host "ok  $rel" }
}

foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -eq '.xaml' -and $_.FullName -notmatch '\\\.git\\' }) {
    $rel = $f.FullName.Substring($root.Length + 1)
    try {
        $styles = [IO.File]::ReadAllText((Join-Path $root 'src\Gui\Styles.inc.xml'), [Text.Encoding]::UTF8)
        $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Replace('<!--STYLES-->', $styles)
        [void][xml]$t
        Write-Host "ok  $rel"
    } catch { Write-Host "XAML $rel : $($_.Exception.Message)" -ForegroundColor Red; $failed++ }
}

if ($failed) { throw "$failed Pruefung(en) fehlgeschlagen." }
Write-Host 'Statische Pruefung bestanden.' -ForegroundColor Green
