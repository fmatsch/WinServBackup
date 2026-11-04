#Requires -Version 5.1
# WinServBackup - Kernfunktionen
# Auftraege, VSS-Snapshot, Sicherung in EINE WIM-Datei, Aufbewahrung, Zeitplan, Wiederherstellung.
# Laeuft unter Windows Server 2016+ (PowerShell 5.1) und in WinPE.

$script:ToolVersion = '0.1.0'
$script:DataRoot = if ($env:WSB_DATA) { $env:WSB_DATA } else { Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { "$env:SystemDrive\ProgramData" }) 'WinServBackup' }
$script:JobDir   = Join-Path $script:DataRoot 'jobs'
$script:LogDir   = Join-Path $script:DataRoot 'logs'
$script:StateDir = Join-Path $script:DataRoot 'state'
$script:LogFile  = $null
$script:TaskPath = '\WinServBackup\'

# ---------------------------------------------------------------- Grundlagen

function Get-WsbVersion { $script:ToolVersion }
function Get-WsbDataRoot { $script:DataRoot }
function Get-WsbLogDir { Initialize-WsbFolders; $script:LogDir }
function Set-WsbLogFile { param([string]$Path) $script:LogFile = $Path }

function Initialize-WsbFolders {
    foreach ($d in $script:DataRoot, $script:JobDir, $script:LogDir, $script:StateDir) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Write-WsbFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-WsbLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Test-WsbAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WsbSafeName {
    param([string]$Name)
    $n = ($Name -replace '[^\p{L}\p{Nd}\-]+', '_').Trim('_')
    if (-not $n) { $n = 'Backup' }
    $n
}

function Format-WsbSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Protect-WsbSecret {
    param([string]$Text)
    if (-not $Text) { return '' }
    Add-Type -AssemblyName System.Security
    $b = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
}

function Unprotect-WsbSecret {
    param([string]$Text)
    if (-not $Text) { return '' }
    Add-Type -AssemblyName System.Security
    $b = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [Text.Encoding]::UTF8.GetString($b)
}

function Get-WsbFirmware {
    if (-not ('WSB.Native' -as [type])) {
        Add-Type -Namespace WSB -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetFirmwareType(ref uint FirmwareType);'
    }
    try {
        [uint32]$t = 0
        if ([WSB.Native]::GetFirmwareType([ref]$t)) {
            if ($t -eq 2) { return 'UEFI' }
            if ($t -eq 1) { return 'BIOS' }
        }
    } catch { }
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        if ($v -eq 2) { return 'UEFI' }
    } catch { }
    'BIOS'
}

function Get-WsbFreeLetter {
    param([int]$Count = 1)
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $free = New-Object System.Collections.Generic.List[string]
    foreach ($c in 90..68) {
        $l = [string][char]$c
        if ($used -notcontains $l) { $free.Add($l) }
    }
    if ($free.Count -lt $Count) { throw 'Nicht genug freie Laufwerksbuchstaben.' }
    @($free | Select-Object -First $Count)
}

# ---------------------------------------------------------------- DISM

function Read-WsbDismPercent {
    param([string]$File)
    try {
        $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt 2048) { [void]$fs.Seek(-2048, 'End') }
            $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
        } finally { $fs.Dispose() }
        $m = [regex]::Matches($text, '(\d{1,3}(?:\.\d+)?)%')
        if ($m.Count -gt 0) { return [double]::Parse($m[$m.Count - 1].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
    } catch { }
    -1
}

function Invoke-WsbDism {
    # Startet dism.exe, meldet den Fortschritt (0-100) an $OnProgress und liefert ExitCode + Ausgabe.
    param([Parameter(Mandatory)][string]$Arguments, [scriptblock]$OnProgress, [switch]$ThrowOnError)
    $out = Join-Path ([IO.Path]::GetTempPath()) ('wsb-dism-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    Write-WsbLog "dism $Arguments"
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out
    $null = $p.Handle
    $last = -2
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 700
        $pct = Read-WsbDismPercent $out
        if ($OnProgress) { & $OnProgress $pct }
        $last = $pct
    }
    $p.WaitForExit()
    $text = ''
    try { $text = [IO.File]::ReadAllText($out) } catch { }
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $code = $p.ExitCode
    if ($code -ne 0) {
        $tail = (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 8) -join ' | '
        Write-WsbLog "dism beendet mit Code $code : $tail" 'ERROR'
        if ($ThrowOnError) { throw "DISM ist mit Fehlercode $code fehlgeschlagen. $tail" }
    }
    [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# ---------------------------------------------------------------- Zustand

function Set-WsbState {
    param([string]$JobId, [hashtable]$Values)
    Initialize-WsbFolders
    $path = Join-Path $script:StateDir "$JobId.json"
    $cur = @{}
    if (Test-Path -LiteralPath $path) {
        try { (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $cur[$_.Name] = $_.Value } } catch { }
    }
    foreach ($k in $Values.Keys) { $cur[$k] = $Values[$k] }
    Write-WsbFile $path ($cur | ConvertTo-Json)
}

function Get-WsbState {
    param([string]$JobId)
    $path = Join-Path $script:StateDir "$JobId.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $s = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($s.status -eq 'running' -and $s.pid) {
        if (-not (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue)) {
            $s.status = 'error'
            $s.message = 'Die Sicherung wurde unerwartet beendet.'
        }
    }
    $s
}

function Get-WsbHistory {
    param([int]$Last = 50)
    $f = Join-Path $script:LogDir 'history.jsonl'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $rows = @(Get-Content -LiteralPath $f -Encoding UTF8 -Tail $Last | Where-Object { $_.Trim() } | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { }
        })
    [array]::Reverse($rows)
    $rows
}

# ---------------------------------------------------------------- Auftraege

function New-WsbJob {
    [pscustomobject]@{
        id          = [guid]::NewGuid().ToString('N').Substring(0, 12)
        name        = 'Server-Sicherung'
        enabled     = $true
        volumes     = @()
        target      = [pscustomobject]@{ path = ''; user = ''; password = '' }
        compression = 'fast'
        keep        = 7
        schedule    = [pscustomobject]@{ type = 'daily'; time = '02:00'; everyHours = 6; days = @('Monday'); dayOfMonth = 1 }
        mail        = [pscustomobject]@{ enabled = $false; server = ''; port = 25; ssl = $false; from = ''; to = ''; user = ''; password = ''; onlyOnError = $true }
    }
}

function Get-WsbJob {
    param([string]$Id)
    Initialize-WsbFolders
    $jobs = @(Get-ChildItem -LiteralPath $script:JobDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
            try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Warning "Auftrag $($_.Name) ist beschaedigt." }
        })
    if ($Id) { $jobs = @($jobs | Where-Object { $_.id -eq $Id -or $_.name -eq $Id }) }
    @($jobs | Sort-Object name)
}

function Save-WsbJob {
    param([Parameter(Mandatory)]$Job, [switch]$NoTask)
    Initialize-WsbFolders
    Write-WsbFile (Join-Path $script:JobDir "$($Job.id).json") ($Job | ConvertTo-Json -Depth 6)
    if (-not $NoTask) { Register-WsbTask -Job $Job }
}

function Remove-WsbJob {
    param([Parameter(Mandatory)][string]$Id)
    Unregister-WsbTask -Id $Id
    Remove-Item -LiteralPath (Join-Path $script:JobDir "$Id.json") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $script:StateDir "$Id.json") -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- Zeitplan

$script:DayDe = [ordered]@{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }

function Get-WsbScheduleText {
    param($Job)
    $s = $Job.schedule
    switch ($s.type) {
        'daily'   { "Täglich um $($s.time) Uhr" }
        'weekly'  { 'Wöchentlich ' + ((@($s.days) | ForEach-Object { $script:DayDe[[string]$_] }) -join ', ') + " um $($s.time) Uhr" }
        'monthly' { if ([int]$s.dayOfMonth -ge 32) { "Monatlich am letzten Tag um $($s.time) Uhr" } else { "Monatlich am $($s.dayOfMonth). um $($s.time) Uhr" } }
        'hourly'  { "Alle $($s.everyHours) Stunden ab $($s.time) Uhr" }
        default   { 'Nur manuell' }
    }
}

function Get-WsbTaskName { param([string]$Id) "Job-$Id" }

function Register-WsbTask {
    param([Parameter(Mandatory)]$Job)
    Unregister-WsbTask -Id $Job.id
    $s = $Job.schedule
    if ($s.type -eq 'manual') { return }
    $time = [timespan]::Parse($s.time)
    $start = (Get-Date).Date.Add($time).ToString('yyyy-MM-ddTHH:mm:ss')
    $head = "<StartBoundary>$start</StartBoundary><Enabled>true</Enabled>"
    switch ($s.type) {
        'daily'   { $trigger = "<CalendarTrigger>$head<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>" }
        'hourly'  {
            $h = [Math]::Max(1, [int]$s.everyHours)
            $trigger = "<CalendarTrigger><Repetition><Interval>PT${h}H</Interval><Duration>P1D</Duration></Repetition>$head<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>"
        }
        'weekly'  {
            $days = (@($s.days) | ForEach-Object { "<$_ />" }) -join ''
            $trigger = "<CalendarTrigger>$head<ScheduleByWeek><DaysOfWeek>$days</DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>"
        }
        'monthly' {
            $day = if ([int]$s.dayOfMonth -ge 32) { 'Last' } else { [string][int]$s.dayOfMonth }
            $months = ('January February March April May June July August September October November December'.Split(' ') | ForEach-Object { "<$_ />" }) -join ''
            $trigger = "<CalendarTrigger>$head<ScheduleByMonth><DaysOfMonth><Day>$day</Day></DaysOfMonth><Months>$months</Months></ScheduleByMonth></CalendarTrigger>"
        }
        default { throw "Unbekannter Zeitplan: $($s.type)" }
    }
    $runner = Join-Path $PSScriptRoot 'Invoke-Backup.ps1'
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -JobId $($Job.id)"
    $enabled = if ($Job.enabled) { 'true' } else { 'false' }
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>WinServBackup: $([Security.SecurityElement]::Escape($Job.name))</Description><Author>WinServBackup</Author></RegistrationInfo>
  <Triggers>$trigger</Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>$enabled</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>P3D</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>$([Security.SecurityElement]::Escape($taskArgs))</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName (Get-WsbTaskName $Job.id) -TaskPath $script:TaskPath -Xml $xml -Force | Out-Null
}

function Unregister-WsbTask {
    param([string]$Id)
    try { Unregister-ScheduledTask -TaskName (Get-WsbTaskName $Id) -TaskPath $script:TaskPath -Confirm:$false -ErrorAction Stop } catch { }
}

function Get-WsbNextRun {
    param([string]$Id)
    try {
        $t = Get-ScheduledTask -TaskName (Get-WsbTaskName $Id) -TaskPath $script:TaskPath -ErrorAction Stop
        if ($t.State -eq 'Disabled') { return $null }
        $i = Get-ScheduledTaskInfo -TaskName (Get-WsbTaskName $Id) -TaskPath $script:TaskPath -ErrorAction Stop
        if ($i.NextRunTime -and $i.NextRunTime.Year -gt 2000) { return $i.NextRunTime }
    } catch { }
    $null
}

# ---------------------------------------------------------------- Datentraeger

function Get-WsbVolume {
    # WSB_SYSTEM_DRIVE ist ein Testhaken, damit sich die Systemlaufwerk-Logik auch ohne echtes System pruefen laesst.
    $sys = $(if ($env:WSB_SYSTEM_DRIVE) { $env:WSB_SYSTEM_DRIVE } else { [string]$env:SystemDrive }).TrimEnd(':').ToUpper()
    Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
        $l = $_.DriveLetter.Substring(0, 1).ToUpper()
        $pi = $null
        try { $pi = Get-Partition -DriveLetter $l -ErrorAction Stop } catch { }
        $cap = [uint64]$_.Capacity
        $free = if ($null -ne $_.FreeSpace) { [uint64]$_.FreeSpace } else { [uint64]0 }
        [pscustomobject]@{
            Letter          = $l
            Drive           = "${l}:"
            Label           = [string]$_.Label
            FileSystem      = [string]$_.FileSystem
            Size            = $cap
            Used            = $cap - $free
            IsSystem        = ($l -eq $sys)
            Supported       = ($_.FileSystem -eq 'NTFS')
            DiskNumber      = if ($pi) { [int]$pi.DiskNumber } else { -1 }
            PartitionNumber = if ($pi) { [int]$pi.PartitionNumber } else { -1 }
            Offset          = if ($pi) { [uint64]$pi.Offset } else { [uint64]0 }
            PartitionSize   = if ($pi) { [uint64]$pi.Size } else { $cap }
            PartitionGuid   = if ($pi) { [string]$pi.Guid } else { '' }
        }
    }
}

function New-WsbManifest {
    param($Job, $Volumes, [string]$FirmwareOverride)
    $os = Get-CimInstance Win32_OperatingSystem
    $disks = @(Get-Disk | ForEach-Object {
            $d = $_
            [pscustomobject]@{
                number     = [int]$d.Number
                style      = [string]$d.PartitionStyle
                size       = [uint64]$d.Size
                model      = [string]$d.FriendlyName
                partitions = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
                        [pscustomobject]@{
                            number  = [int]$_.PartitionNumber
                            type    = [string]$_.Type
                            gptType = [string]$_.GptType
                            offset  = [uint64]$_.Offset
                            size    = [uint64]$_.Size
                            letter  = if ($_.DriveLetter -and [int]$_.DriveLetter -ne 0) { [string]$_.DriveLetter } else { '' }
                        }
                    })
            }
        })
    $vols = @(); $i = 2
    foreach ($v in $Volumes) {
        $vols += [pscustomobject]@{
            letter = $v.Letter; label = $v.Label; fs = $v.FileSystem; size = $v.PartitionSize; used = $v.Used
            diskNumber = $v.DiskNumber; partitionNumber = $v.PartitionNumber; offset = $v.Offset
            isSystem = [bool]$v.IsSystem; imageIndex = $i; imageName = "Vol-$($v.Letter)"
        }
        $i++
    }
    $fw = if ($FirmwareOverride) { $FirmwareOverride } else { Get-WsbFirmware }
    [pscustomobject]@{
        schema      = 1
        tool        = 'WinServBackup'
        toolVersion = $script:ToolVersion
        created     = (Get-Date).ToUniversalTime().ToString('o')
        host        = $env:COMPUTERNAME
        job         = $Job.name
        os          = [pscustomobject]@{ caption = [string]$os.Caption; version = [string]$os.Version; build = [string]$os.BuildNumber }
        firmware    = $fw
        disks       = $disks
        volumes     = $vols
    }
}

# ---------------------------------------------------------------- VSS (diskshadow)

function Remove-WsbSnapshot {
    param([string[]]$Exposed)
    if (-not $Exposed) { return }
    $f = Join-Path ([IO.Path]::GetTempPath()) ('wsb-ds-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($f, ((@($Exposed) | ForEach-Object { "DELETE SHADOWS EXPOSED $_" }) -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    try {
        $o = & diskshadow.exe /s $f 2>&1
        if ($LASTEXITCODE -ne 0) { Write-WsbLog ("Snapshot-Aufräumen meldet Code $LASTEXITCODE : " + (($o | Out-String).Trim() -replace '\s+', ' ')) 'WARN' }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function New-WsbSnapshot {
    # Legt fuer alle Volumes ZUSAMMEN einen persistenten Schattenkopie-Satz an und bindet jede Kopie als Laufwerk ein.
    # Rueckgabe: Hashtable  'C:' -> 'Y:'
    param([Parameter(Mandatory)][string[]]$Volumes)
    $letters = @(Get-WsbFreeLetter -Count $Volumes.Count)
    $map = [ordered]@{}
    for ($i = 0; $i -lt $Volumes.Count; $i++) { $map[$Volumes[$i]] = "$($letters[$i]):" }

    foreach ($mode in 'writers', 'plain') {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('SET CONTEXT PERSISTENT'); $lines.Add('SET VERBOSE ON')
        if ($mode -eq 'writers') { $lines.Add('BEGIN BACKUP') }
        $i = 0
        foreach ($v in $map.Keys) { $lines.Add("ADD VOLUME $v ALIAS V$i"); $i++ }
        $lines.Add('CREATE')
        $i = 0
        foreach ($v in $map.Keys) { $lines.Add("EXPOSE %V$i% $($map[$v])"); $i++ }
        if ($mode -eq 'writers') { $lines.Add('END BACKUP') }
        $f = Join-Path ([IO.Path]::GetTempPath()) ('wsb-ds-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($f, ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
        try {
            $o = & diskshadow.exe /s $f 2>&1
            $code = $LASTEXITCODE
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        $ok = ($code -eq 0)
        foreach ($l in $map.Values) { if (-not (Test-Path -LiteralPath "$l\")) { $ok = $false } }
        if ($ok) {
            if ($mode -eq 'plain') { Write-WsbLog 'Snapshot ohne VSS-Writer erstellt (absturzkonsistent, nicht anwendungskonsistent).' 'WARN' }
            return $map
        }
        Write-WsbLog ("Snapshot ($mode) fehlgeschlagen, Code $code : " + (($o | Out-String).Trim() -replace '\s+', ' ')) 'WARN'
        Remove-WsbSnapshot -Exposed @($map.Values)
    }
    throw 'Der VSS-Snapshot konnte nicht erstellt werden. Details stehen im Protokoll.'
}

# ---------------------------------------------------------------- Ziel

function Connect-WsbTarget {
    # Liefert den lokal nutzbaren Zielpfad. Netzwerkfreigaben werden auf einen Laufwerksbuchstaben abgebildet.
    param($Job)
    $p = ([string]$Job.target.path).Trim().TrimEnd('\')
    if (-not $p) { throw 'Es ist kein Sicherungsziel eingestellt.' }
    if ($p -notlike '\\*') {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        return [pscustomobject]@{ Path = $p; Mapped = $null }
    }
    $parts = @($p.TrimStart('\') -split '\\')
    if ($parts.Count -lt 2) { throw "Ungültiger Netzwerkpfad: $p" }
    $share = "\\$($parts[0])\$($parts[1])"
    $sub = ($parts | Select-Object -Skip 2) -join '\'
    $l = @(Get-WsbFreeLetter)[0]
    $a = @{ LocalPath = "${l}:"; RemotePath = $share; Persistent = $false }
    if ($Job.target.user) { $a.UserName = $Job.target.user; $a.Password = (Unprotect-WsbSecret $Job.target.password) }
    try { New-SmbMapping @a -ErrorAction Stop | Out-Null } catch { throw "Die Freigabe $share ließ sich nicht verbinden: $($_.Exception.Message)" }
    $path = "${l}:\" + $sub
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    [pscustomobject]@{ Path = $path.TrimEnd('\'); Mapped = "${l}:" }
}

function Disconnect-WsbTarget {
    param($Target)
    if ($Target -and $Target.Mapped) { try { Remove-SmbMapping -LocalPath $Target.Mapped -Force -UpdateProfile -ErrorAction Stop } catch { } }
}

function Test-WsbTarget {
    # Prueft, ob der Auftrag ins Ziel schreiben kann. Wirft bei Fehlern.
    param($Job)
    $t = Connect-WsbTarget -Job $Job
    try {
        $f = Join-Path $t.Path ('.wsb-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($f, 'test'); Remove-Item -LiteralPath $f -Force
        $root = [IO.Path]::GetPathRoot($t.Path)
        $di = New-Object IO.DriveInfo($root)
        [pscustomobject]@{ Path = $t.Path; Free = [uint64]$di.AvailableFreeSpace }
    } finally { Disconnect-WsbTarget $t }
}

# ---------------------------------------------------------------- Backup-Dateien

function Get-WsbBackupInfo {
    param([Parameter(Mandatory)][string]$Path)
    $imgs = @(Get-WindowsImage -ImagePath $Path -ErrorAction Stop)
    $meta = $imgs | Where-Object { $_.ImageName -eq 'WSB-META' } | Select-Object -First 1
    if (-not $meta) { throw 'Das ist keine WinServBackup-Datei.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wsb-meta-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $null = Invoke-WsbDism "/Apply-Image /ImageFile:`"$Path`" /Index:$($meta.ImageIndex) /ApplyDir:`"$tmp`"" -ThrowOnError
        $json = Join-Path $tmp 'manifest.json'
        if (-not (Test-Path -LiteralPath $json)) { throw 'In der Datei fehlt das Manifest.' }
        $man = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{
        Path      = $Path
        SizeBytes = (Get-Item -LiteralPath $Path).Length
        Manifest  = $man
        Images    = $imgs
    }
}

function Get-WsbBackupFile {
    # Listet Sicherungsdateien in einem Ordner (ohne sie zu oeffnen).
    param([Parameter(Mandatory)][string]$Folder)
    @(Get-ChildItem -LiteralPath $Folder -Filter *.wim -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '_\d{8}-\d{6}\.wim$' -and $_.Name -notmatch '\.partial\.wim$' } |
            Sort-Object LastWriteTime -Descending)
}

function Invoke-WsbRetention {
    param([string]$Folder, [string]$Prefix, [int]$Keep)
    $re = '^' + [regex]::Escape($Prefix) + '\d{8}-\d{6}\.wim$'
    $old = @(Get-ChildItem -LiteralPath $Folder -Filter "$Prefix*.wim" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $re } | Sort-Object Name -Descending | Select-Object -Skip $Keep)
    foreach ($f in $old) {
        try { Remove-Item -LiteralPath $f.FullName -Force; Write-WsbLog "Alte Sicherung gelöscht: $($f.Name)" }
        catch { Write-WsbLog "Konnte $($f.Name) nicht löschen: $($_.Exception.Message)" 'WARN' }
    }
}

# ---------------------------------------------------------------- Mail

function Send-WsbMail {
    param($Job, [string]$Subject, [string]$Body)
    $m = $Job.mail
    if (-not $m -or -not $m.enabled -or -not $m.server -or -not $m.to) { return }
    try {
        $sp = @{ SmtpServer = $m.server; Port = [int]$m.port; From = $m.from; To = @($m.to -split '[,;]\s*' | Where-Object { $_ }); Subject = $Subject; Body = $Body; Encoding = [Text.Encoding]::UTF8; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($m.ssl) { $sp.UseSsl = $true }
        if ($m.user) { $sp.Credential = New-Object Management.Automation.PSCredential($m.user, (ConvertTo-SecureString (Unprotect-WsbSecret $m.password) -AsPlainText -Force)) }
        Send-MailMessage @sp
    } catch { Write-WsbLog "E-Mail konnte nicht gesendet werden: $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------- Sicherung

function Start-WsbBackup {
    param([Parameter(Mandatory)]$Job)
    Initialize-WsbFolders
    $started = Get-Date
    $safe = Get-WsbSafeName $Job.name
    $script:LogFile = Join-Path $script:LogDir ('{0}_{1:yyyyMMdd-HHmmss}.log' -f $safe, $started)
    $id = $Job.id
    $mutex = New-Object Threading.Mutex($false, 'Global\WinServBackup-Run')
    $locked = $false
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) {
        Write-WsbLog 'Es läuft bereits eine andere Sicherung.' 'ERROR'
        return [pscustomobject]@{ Status = 'error'; Message = 'Es läuft bereits eine andere Sicherung.'; File = $null }
    }

    $snap = $null; $target = $null; $partial = $null; $final = $null; $metaDir = $null; $cfg = $null
    $status = 'error'; $message = ''; $size = [uint64]0
    try {
        Set-WsbState $id @{ status = 'running'; phase = 'Vorbereitung'; percent = 0; started = $started.ToString('o'); pid = $PID; message = ''; log = $script:LogFile }
        Write-WsbLog "WinServBackup $script:ToolVersion - Auftrag '$($Job.name)'"
        if (-not (Test-WsbAdmin)) { throw 'Administratorrechte sind erforderlich.' }

        # Volumes bestimmen
        $all = @(Get-WsbVolume | Where-Object { $_.Supported })
        $want = @($Job.volumes | Where-Object { $_ })
        $vols = @(if ($want.Count -gt 0) { $all | Where-Object { $want -contains $_.Drive } } else { $all })
        if ($vols.Count -eq 0) { throw 'Keine passenden NTFS-Laufwerke zum Sichern gefunden.' }
        if ($want.Count -gt 0 -and $vols.Count -ne $want.Count) {
            $missing = $want | Where-Object { $_ -notin $vols.Drive }
            throw "Laufwerk nicht gefunden oder nicht NTFS: $($missing -join ', ')"
        }
        Write-WsbLog ('Zu sichern: ' + (($vols | ForEach-Object { "$($_.Drive) ($(Format-WsbSize $_.Used) belegt)" }) -join ', '))

        # Ziel
        $target = Connect-WsbTarget -Job $Job
        $folder = $target.Path
        $prefix = '{0}_{1}_' -f $env:COMPUTERNAME, $safe
        $final = Join-Path $folder ('{0}{1:yyyyMMdd-HHmmss}.wim' -f $prefix, $started)
        $partial = [IO.Path]::ChangeExtension($final, 'partial.wim')
        $di = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($folder))
        $needed = ($vols | Measure-Object -Property Used -Sum).Sum
        Write-WsbLog "Ziel: $($Job.target.path) - frei: $(Format-WsbSize $di.AvailableFreeSpace)"
        if ($di.AvailableFreeSpace -lt 1GB) { throw 'Im Ziel sind weniger als 1 GB frei.' }
        if ($di.AvailableFreeSpace -lt $needed * 0.5) { Write-WsbLog "Achtung: Der freie Platz ($(Format-WsbSize $di.AvailableFreeSpace)) ist klein gegenüber den belegten Daten ($(Format-WsbSize $needed))." 'WARN' }
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

        # Snapshot
        Set-WsbState $id @{ phase = 'Snapshot wird erstellt'; percent = 2 }
        Write-WsbLog 'Erstelle VSS-Snapshot ...'
        $snap = New-WsbSnapshot -Volumes @($vols.Drive)

        # Manifest + Ausschlussliste
        $metaDir = Join-Path ([IO.Path]::GetTempPath()) ('wsb-meta-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
        $man = New-WsbManifest -Job $Job -Volumes $vols
        Write-WsbFile (Join-Path $metaDir 'manifest.json') ($man | ConvertTo-Json -Depth 8)

        $excl = @('\$ntfs.log', '\hiberfil.sys', '\pagefile.sys', '\swapfile.sys', '\System Volume Information', '\RECYCLER', '\$Recycle.Bin', '\Windows\CSC')
        $tp = $folder
        if ($tp.Length -ge 3 -and $tp[1] -eq ':') { $excl += '\' + $tp.Substring(3).Trim('\') }
        $cfg = Join-Path ([IO.Path]::GetTempPath()) ('wsb-wimscript-{0}.ini' -f [guid]::NewGuid().ToString('N'))
        $ini = "[ExclusionList]`r`n" + (($excl | Where-Object { $_ -ne '\' } | ForEach-Object { $_ }) -join "`r`n") + "`r`n"
        [IO.File]::WriteAllText($cfg, $ini, [Text.Encoding]::Unicode)

        $comp = switch ($Job.compression) { 'max' { 'maximum' } 'none' { 'none' } default { 'fast' } }

        # Manifest als erstes Image
        Set-WsbState $id @{ phase = 'Metadaten'; percent = 6 }
        $null = Invoke-WsbDism "/Capture-Image /ImageFile:`"$partial`" /CaptureDir:`"$metaDir`" /Name:`"WSB-META`" /Description:`"WinServBackup Manifest`" /Compress:$comp /NoRpFix" -ThrowOnError

        # Volumes als weitere Images
        $total = [Math]::Max(1, [double]$needed)
        $base = 8.0; $span = 87.0
        $done = 0.0
        foreach ($v in $vols) {
            $share = $span * ([double]$v.Used / $total)
            $b = $base + $span * ($done / $total)
            $lbl = ($v.Label -replace '[^\p{L}\p{Nd} \-_.]', '')
            Set-WsbState $id @{ phase = "Sichere $($v.Drive)"; percent = [int]$b }
            Write-WsbLog "Sichere $($v.Drive) ..."
            $cb = {
                param($pct)
                if ($pct -ge 0) { Set-WsbState $id @{ percent = [int]($b + $share * $pct / 100.0); phase = "Sichere $($v.Drive) ($([int]$pct) %)" } }
            }.GetNewClosure()
            $null = Invoke-WsbDism "/Append-Image /ImageFile:`"$partial`" /CaptureDir:$($snap[$v.Drive])\ /Name:`"Vol-$($v.Letter)`" /Description:`"WinServBackup Laufwerk $($v.Drive) $lbl`" /ConfigFile:`"$cfg`" /NoRpFix /Verify" -OnProgress $cb -ThrowOnError
            $done += [double]$v.Used
        }

        # Snapshot freigeben, bevor es ans Pruefen geht
        Set-WsbState $id @{ phase = 'Snapshot wird entfernt'; percent = 95 }
        Remove-WsbSnapshot -Exposed @($snap.Values); $snap = $null

        # Pruefen
        Set-WsbState $id @{ phase = 'Prüfe Sicherung'; percent = 96 }
        $imgs = @(Get-WindowsImage -ImagePath $partial -ErrorAction Stop)
        if ($imgs.Count -ne $vols.Count + 1) { throw "Prüfung fehlgeschlagen: erwartet $($vols.Count + 1) Abbilder, gefunden $($imgs.Count)." }
        Move-Item -LiteralPath $partial -Destination $final -Force
        $size = [uint64](Get-Item -LiteralPath $final).Length
        Write-WsbLog "Fertig: $final ($(Format-WsbSize $size))"

        # Aufbewahrung
        Set-WsbState $id @{ phase = 'Alte Sicherungen aufräumen'; percent = 98 }
        Invoke-WsbRetention -Folder $folder -Prefix $prefix -Keep ([Math]::Max(1, [int]$Job.keep))

        $status = 'ok'; $message = "Sicherung abgeschlossen ($(Format-WsbSize $size))."
    } catch {
        $message = $_.Exception.Message
        Write-WsbLog "Fehler: $message" 'ERROR'
    } finally {
        if ($snap) { Remove-WsbSnapshot -Exposed @($snap.Values) }
        foreach ($t in $partial, $cfg) { if ($t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } }
        if ($metaDir) { Remove-Item -LiteralPath $metaDir -Recurse -Force -ErrorAction SilentlyContinue }
        Disconnect-WsbTarget $target
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }

    $dur = [int]((Get-Date) - $started).TotalSeconds
    Set-WsbState $id @{ status = $status; phase = ''; percent = $(if ($status -eq 'ok') { 100 } else { 0 }); message = $message; finished = (Get-Date).ToString('o'); lastFile = $(if ($status -eq 'ok') { $final } else { $null }); lastSize = $size; duration = $dur }
    $rec = [pscustomobject]@{ time = $started.ToString('o'); job = $Job.name; jobId = $id; status = $status; duration = $dur; size = $size; file = $(if ($status -eq 'ok') { $final } else { '' }); message = $message; log = $script:LogFile }
    [IO.File]::AppendAllText((Join-Path $script:LogDir 'history.jsonl'), (($rec | ConvertTo-Json -Compress) + "`r`n"), (New-Object Text.UTF8Encoding($false)))

    if ($status -eq 'error' -or -not $Job.mail.onlyOnError) {
        $subj = "[WinServBackup] $env:COMPUTERNAME - $($Job.name): " + $(if ($status -eq 'ok') { 'erfolgreich' } else { 'FEHLGESCHLAGEN' })
        Send-WsbMail -Job $Job -Subject $subj -Body "$message`r`n`r`nDauer: $dur s`r`nProtokoll: $script:LogFile"
    }
    [pscustomobject]@{ Status = $status; Message = $message; File = $(if ($status -eq 'ok') { $final } else { $null }); Size = $size; Duration = $dur }
}

# ---------------------------------------------------------------- Wiederherstellung

function Invoke-WsbDiskpart {
    param([string[]]$Lines)
    $f = Join-Path ([IO.Path]::GetTempPath()) ('wsb-dp-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($f, ($Lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    try {
        $o = & diskpart.exe /s $f 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Write-WsbLog ('diskpart: ' + ($o.Trim() -replace '\s+', ' '))
    if ($code -ne 0) { throw "diskpart ist mit Code $code fehlgeschlagen." }
}

function Dismount-WsbHive {
    # Entlaedt einen Registry-Hive; offene .NET-Handles werden freigegeben, bei Bedarf wird wiederholt.
    param([string]$Name)
    $o = ''
    foreach ($i in 1..10) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        $o = & reg.exe unload $Name 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Write-WsbLog "Registry-Hive $Name ließ sich nicht entladen: $($o.Trim())" 'WARN'
}

function Set-WsbMountedDevices {
    # Schreibt die Laufwerksbuchstaben in die (offline eingehaengte) SYSTEM-Registry der wiederhergestellten Installation.
    param([string]$WindowsRoot, [object[]]$Entries = @(), [switch]$EnableBootDrivers)
    $hive = Join-Path $WindowsRoot 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -LiteralPath $hive)) { throw "Registry-Hive nicht gefunden: $hive" }
    & reg.exe load HKLM\WSB_TARGET $hive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Die Registry der wiederhergestellten Installation ließ sich nicht laden.' }
    $changed = @()
    try {
        if ($Entries.Count -gt 0) {
            $key = Get-Item -LiteralPath 'HKLM:\WSB_TARGET\MountedDevices'
            foreach ($n in $key.GetValueNames()) { Remove-ItemProperty -LiteralPath $key.PSPath -Name $n -ErrorAction SilentlyContinue }
            foreach ($e in $Entries) {
                New-ItemProperty -LiteralPath 'HKLM:\WSB_TARGET\MountedDevices' -Name ('\DosDevices\' + $e.Letter + ':') -PropertyType Binary -Value ([byte[]]$e.Bytes) -Force | Out-Null
            }
        }
        if ($EnableBootDrivers) { $changed = @(Set-WsbBootDriverStart) }
    } finally {
        $key = $null
        Dismount-WsbHive 'HKLM\WSB_TARGET'
    }
    @($changed)
}

function Set-WsbBootDriverStart {
    # Arbeitet auf dem bereits eingehaengten Hive HKLM:\WSB_TARGET. Liefert die umgestellten Dienste.
    $services = 'atapi', 'intelide', 'pciide', 'amdide', 'aliide', 'cmdide', 'viaide', 'msahci', 'storahci', 'stornvme', 'storvsc', 'vmbus',
        'LSI_SAS', 'LSI_SAS2i', 'LSI_SAS3i', 'LSI_SCSI', 'LSI_FC', 'megasas', 'megasas2i', 'megasr', 'SymMC', 'symc8xx', 'sym_hi', 'sym_u3',
        'aic78xx', 'arcsas', 'adp94xx', 'adpahci', 'adpu320', 'hpsa', 'hpcisss', 'ql2300', 'ql40xx', 'elxstor', 'percsas', 'pvscsi', 'vhdmp'
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($cs in @(Get-ChildItem 'HKLM:\WSB_TARGET' | Where-Object { $_.PSChildName -match '^ControlSet\d+$' })) {
        foreach ($svc in $services) {
            $k = "HKLM:\WSB_TARGET\$($cs.PSChildName)\Services\$svc"
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $cur = (Get-ItemProperty -LiteralPath $k -Name Start -ErrorAction SilentlyContinue).Start
            if ($null -ne $cur -and $cur -ne 0) {
                Set-ItemProperty -LiteralPath $k -Name Start -Value 0 -Type DWord
                if (-not $changed.Contains($svc)) { $changed.Add($svc) }
            }
        }
    }
    Write-WsbLog ('Boot-Treiber aktiviert: ' + $(if ($changed.Count) { $changed -join ', ' } else { '(keine Änderung nötig)' }))
    @($changed)
}

function Get-WsbMountedDeviceBytes {
    param([int]$DiskNumber, [string]$TempLetter)
    $disk = Get-Disk -Number $DiskNumber
    $part = Get-Partition -DriveLetter $TempLetter
    if ([string]$disk.PartitionStyle -eq 'GPT') {
        $g = [guid]($part.Guid.Trim('{', '}'))
        return [byte[]]([Text.Encoding]::ASCII.GetBytes('DMIO:ID:') + $g.ToByteArray())
    }
    [byte[]]([BitConverter]::GetBytes([uint32]$disk.Signature) + [BitConverter]::GetBytes([uint64]$part.Offset))
}

function Restore-WsbBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupFile,
        [Parameter(Mandatory)][hashtable]$DiskMap,
        [string]$Firmware,
        [string]$DriverPath,
        [bool]$FillLastVolume = $true,
        [bool]$KeepLetters = $false,
        [bool]$HardwareIndependent = $true,
        [scriptblock]$OnProgress
    )
    function Step([int]$p, [string]$m) { Write-WsbLog $m; if ($OnProgress) { & $OnProgress $p $m } }

    if (-not $Firmware) { $Firmware = Get-WsbFirmware }
    Step 1 'Lese Sicherung ...'
    $info = Get-WsbBackupInfo -Path $BackupFile
    $man = $info.Manifest
    $vols = @($man.volumes)
    if ($vols.Count -eq 0) { throw 'Die Sicherung enthält keine Laufwerke.' }

    $backupDisk = -1
    if ($BackupFile -match '^[A-Za-z]:') { try { $backupDisk = [int](Get-Partition -DriveLetter $BackupFile.Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { } }

    $srcDisks = @($vols | ForEach-Object { [int]$_.diskNumber } | Sort-Object -Unique)
    $sysVol = $vols | Where-Object { $_.isSystem } | Select-Object -First 1
    $sysDisk = if ($sysVol) { [int]$sysVol.diskNumber } else { -1 }
    if ($sysVol -and -not $DiskMap.Contains($sysDisk)) { throw 'Für den Datenträger mit dem Betriebssystem ist kein Ziel gewählt.' }
    $targets = @($DiskMap.Values | ForEach-Object { [int]$_ })
    if (@($targets | Sort-Object -Unique).Count -ne $targets.Count) { throw 'Ein Zieldatenträger darf nur einmal gewählt werden.' }
    if ($targets -contains $backupDisk) { throw 'Der Datenträger, auf dem die Sicherung liegt, kann nicht als Ziel dienen.' }

    # Planung
    $plans = @()
    $espMB = 260; $msrMB = 16; $resMB = 500
    foreach ($sd in $srcDisks) {
        if (-not $DiskMap.Contains($sd)) { Write-WsbLog "Datenträger $sd wird übersprungen."; continue }
        $td = [int]$DiskMap[$sd]
        $disk = Get-Disk -Number $td -ErrorAction Stop
        $dv = @($vols | Where-Object { [int]$_.diskNumber -eq $sd } | Sort-Object { [uint64]$_.offset })
        $isSys = ($sd -eq $sysDisk)
        $srcStyle = [string](@($man.disks | Where-Object { [int]$_.number -eq $sd })[0].style)
        $style = if ($isSys) { if ($Firmware -eq 'UEFI') { 'GPT' } else { 'MBR' } } elseif ($srcStyle -eq 'MBR' -and $disk.Size -lt 2TB) { 'MBR' } else { 'GPT' }
        if ($style -eq 'MBR' -and $dv.Count + $(if ($isSys) { 1 } else { 0 }) -gt 4) { throw 'Mit BIOS/MBR sind höchstens 4 Partitionen pro Datenträger möglich.' }
        $over = if ($isSys) { if ($Firmware -eq 'UEFI') { $espMB + $msrMB } else { $resMB } } else { 0 }
        $needMB = $over + 8 + (($dv | ForEach-Object { [math]::Floor([uint64]$_.size / 1MB) } | Measure-Object -Sum).Sum)
        if ($disk.Size / 1MB -lt $needMB) { throw "Zieldatenträger $td ist zu klein: benötigt $needMB MB, vorhanden $([int]($disk.Size / 1MB)) MB." }
        $plans += [pscustomobject]@{ Source = $sd; Target = $td; Style = $style; IsSystem = $isSys; Volumes = $dv }
    }

    $need = 1 + (@($plans | ForEach-Object { $_.Volumes.Count } | Measure-Object -Sum).Sum)
    $letters = @(Get-WsbFreeLetter -Count $need)
    $li = 0
    $assign = @{}   # 'sd:letter' -> temp letter
    $sysPart = $null
    $enabled = @()
    $lines = @()
    foreach ($p in $plans) {
        $lines += "select disk $($p.Target)", 'online disk noerr', 'attributes disk clear readonly noerr', 'clean', ('convert ' + $p.Style.ToLower())
        if ($p.IsSystem) {
            $sysPart = $letters[$li]; $li++
            if ($Firmware -eq 'UEFI') {
                $lines += "create partition efi size=$espMB", 'format quick fs=fat32 label="System"', "assign letter=$sysPart", "create partition msr size=$msrMB"
            } else {
                $lines += "create partition primary size=$resMB", 'format quick fs=ntfs label="System Reserved"', 'active', "assign letter=$sysPart"
            }
        }
        for ($i = 0; $i -lt $p.Volumes.Count; $i++) {
            $v = $p.Volumes[$i]
            $t = $letters[$li]; $li++
            $assign["$($p.Source):$($v.letter)"] = $t
            $isLast = ($i -eq $p.Volumes.Count - 1)
            $sz = if ($isLast -and $FillLastVolume) { '' } else { ' size=' + [math]::Floor([uint64]$v.size / 1MB) }
            $lab = ([string]$v.label -replace '[^\p{L}\p{Nd} \-_.]', '')
            $labArg = if ($lab) { " label=`"$lab`"" } else { '' }
            $lines += "create partition primary$sz", "format quick fs=ntfs$labArg", "assign letter=$t"
        }
    }
    Step 3 'Partitioniere Zieldatenträger ...'
    Invoke-WsbDiskpart -Lines $lines
    if (Get-Command Update-HostStorageCache -ErrorAction SilentlyContinue) { Update-HostStorageCache }
    Start-Sleep -Seconds 2
    foreach ($t in $assign.Values) { if (-not (Test-Path -LiteralPath "${t}:\")) { throw "Das Laufwerk ${t}: wurde nach dem Partitionieren nicht bereitgestellt." } }

    # Abbilder einspielen
    $totalUsed = [math]::Max(1, [double](($vols | Measure-Object -Property used -Sum).Sum))
    $done = 0.0
    $order = @($vols | Where-Object { $assign.ContainsKey("$([int]$_.diskNumber):$($_.letter)") } | Sort-Object { -[int][bool]$_.isSystem })
    foreach ($v in $order) {
        $t = $assign["$([int]$v.diskNumber):$($v.letter)"]
        $b = 5 + 85 * ($done / $totalUsed)
        $share = 85 * ([double]$v.used / $totalUsed)
        Step ([int]$b) "Spiele $($v.letter): ein (Laufwerk ${t}:) ..."
        $cb = {
            param($pct)
            if ($OnProgress -and $pct -ge 0) { & $OnProgress ([int]($b + $share * $pct / 100.0)) "Spiele $($v.letter): ein ($([int]$pct) %)" }
        }.GetNewClosure()
        $null = Invoke-WsbDism "/Apply-Image /ImageFile:`"$BackupFile`" /Index:$($v.imageIndex) /ApplyDir:${t}:\ /Verify /NoRpFix" -OnProgress $cb -ThrowOnError
        $done += [double]$v.used
    }

    # Start einrichten
    if ($sysVol) {
        $w = $assign["${sysDisk}:$($sysVol.letter)"]
        Step 91 'Richte den Start ein (BCD) ...'
        $fw = if ($Firmware -eq 'UEFI') { 'UEFI' } else { 'BIOS' }
        $o = & bcdboot.exe "${w}:\Windows" /s "${sysPart}:" /f $fw 2>&1 | Out-String
        Write-WsbLog ('bcdboot: ' + ($o.Trim() -replace '\s+', ' '))
        if ($LASTEXITCODE -ne 0) { throw "bcdboot ist mit Code $LASTEXITCODE fehlgeschlagen." }
        if ($Firmware -eq 'UEFI') {
            $src = "${sysPart}:\EFI\Microsoft\Boot\bootmgfw.efi"
            $dst = "${sysPart}:\EFI\Boot\bootx64.efi"
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Force
            }
        }

        Step 94 'Übernehme Laufwerksbuchstaben und aktiviere Speichertreiber ...'
        $enabled = @()
        try {
            $entries = @()
            foreach ($v in $order) {
                $t = $assign["$([int]$v.diskNumber):$($v.letter)"]
                $td = [int]$DiskMap[[int]$v.diskNumber]
                $entries += [pscustomobject]@{ Letter = $v.letter; Bytes = (Get-WsbMountedDeviceBytes -DiskNumber $td -TempLetter $t) }
            }
            $enabled = @(Set-WsbMountedDevices -WindowsRoot "${w}:\" -Entries $entries -EnableBootDrivers:$HardwareIndependent)
        } catch { Write-WsbLog "Laufwerksbuchstaben/Treiber konnten nicht übernommen werden (Windows vergibt neu): $($_.Exception.Message)" 'WARN' }

        $drvPaths = @($DriverPath, (Join-Path $PSScriptRoot 'Drivers')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        foreach ($dp in $drvPaths) {
            Step 96 "Füge Treiber hinzu: $dp"
            $scratch = "${w}:\wsb-scratch"
            New-Item -ItemType Directory -Path $scratch -Force | Out-Null
            $r = Invoke-WsbDism "/Image:${w}:\ /ScratchDir:$scratch /Add-Driver /Driver:`"$dp`" /Recurse"
            if ($r.ExitCode -ne 0) { Write-WsbLog 'Nicht alle Treiber konnten hinzugefügt werden.' 'WARN' }
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-WsbLog 'Die Sicherung enthält kein Systemlaufwerk - es wurden nur Daten wiederhergestellt.' 'WARN'
    }

    $result = [pscustomobject]@{ Letters = $assign; BootLetter = $sysPart; DriversEnabled = @($enabled) }
    if (-not $KeepLetters) {
        foreach ($t in @($assign.Values) + @($sysPart)) {
            if ($t) { try { $pp = Get-Partition -DriveLetter $t -ErrorAction Stop; Remove-PartitionAccessPath -DiskNumber $pp.DiskNumber -PartitionNumber $pp.PartitionNumber -AccessPath "${t}:\" -ErrorAction Stop } catch { } }
        }
    }
    Step 100 'Wiederherstellung abgeschlossen.'
    $result
}

Export-ModuleMember -Function *-Wsb*
