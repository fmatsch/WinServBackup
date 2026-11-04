<#
.SYNOPSIS
    Baut WinServBackup.exe (Starter), WinServBackup.zip und WinServBackup-Setup.exe (Installer) mit dem in Windows enthaltenen C#-Compiler.
.EXAMPLE
    .\build\Build-Exe.ps1 -Out dist
#>
param([string]$Out = 'dist')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe nicht gefunden: $csc" }
$Out = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
$stage = Join-Path $Out 'stage\WinServBackup'
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

function Invoke-Csc {
    param([string[]]$Arguments)
    $o = & $csc @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "csc fehlgeschlagen:`n$o" }
}
$common = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', "/win32icon:$root\assets\icon.ico", "/win32manifest:$root\build\app.manifest", '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll')

Write-Host 'Baue WinServBackup.exe ...'
Invoke-Csc ($common + @("/out:$stage\WinServBackup.exe", "$root\build\Launcher.cs"))

foreach ($i in 'src', 'recovery', 'assets', 'WinServBackup.ps1', 'Install.ps1', 'Uninstall.ps1', 'LICENSE', 'README.md') { Copy-Item -LiteralPath (Join-Path $root $i) -Destination $stage -Recurse }
Compress-Archive -Path (Join-Path $Out 'stage\WinServBackup') -DestinationPath (Join-Path $Out 'WinServBackup.zip')

Write-Host 'Baue WinServBackup-Setup.exe ...'
Invoke-Csc ($common + @('/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll', "/resource:$Out\WinServBackup.zip,WinServBackup.zip", "/out:$Out\WinServBackup-Setup.exe", "$root\build\Setup.cs"))

$sums = foreach ($f in 'WinServBackup-Setup.exe', 'WinServBackup.zip') { '{0}  {1}' -f (Get-FileHash (Join-Path $Out $f) -Algorithm SHA256).Hash.ToLower(), $f }
$sums | Set-Content (Join-Path $Out 'SHA256SUMS') -Encoding ASCII
Get-ChildItem $Out -File | ForEach-Object { Write-Host ('  {0}  {1:N1} MB' -f $_.Name, ($_.Length / 1MB)) }
