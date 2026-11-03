#Requires -Version 5.1
# WinServBackup - Oberflaeche (WPF). Benoetigt Windows Server mit Desktopdarstellung und Administratorrechte.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Import-Module (Join-Path $PSScriptRoot '..\WinServBackup.psm1') -Force

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Runner = (Resolve-Path (Join-Path $PSScriptRoot '..\Invoke-Backup.ps1')).Path
$script:Tick = 0
$script:WasRunning = $false
$de = [Globalization.CultureInfo]::GetCultureInfo('de-DE')

# ------------------------------------------------------------ Hilfen

function Import-Xaml {
    param([string]$Name)
    $styles = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Styles.inc.xml'), [Text.Encoding]::UTF8)
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name), [Text.Encoding]::UTF8).Replace('<!--STYLES-->', $styles)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$text)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($m in [regex]::Matches($text, 'x:Name="(\w+)"')) { $ui[$m.Groups[1].Value] = $win.FindName($m.Groups[1].Value) }
    [pscustomobject]@{ Window = $win; Ui = $ui }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'WinServBackup', [string]$Buttons = 'OK', [string]$Icon = 'Information', $Owner)
    if ($Owner) { return [Windows.MessageBox]::Show($Owner, $Text, $Title, $Buttons, $Icon).ToString() }
    [Windows.MessageBox]::Show($Text, $Title, $Buttons, $Icon).ToString()
}

function Format-Ago {
    param([datetime]$When)
    $s = (Get-Date) - $When
    if ($s.TotalMinutes -lt 1) { return 'gerade eben' }
    if ($s.TotalHours -lt 1) { return 'vor {0} Min.' -f [int]$s.TotalMinutes }
    if ($s.TotalDays -lt 1) { return 'vor {0} Std.' -f [int]$s.TotalHours }
    if ($s.TotalDays -lt 2) { return 'gestern' }
    'vor {0} Tagen' -f [int]$s.TotalDays
}

function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -ge 3600) { return '{0} h {1} min' -f [int][math]::Floor($Seconds / 3600), [int][math]::Floor(($Seconds % 3600) / 60) }
    if ($Seconds -ge 60) { return '{0} min' -f [int][math]::Floor($Seconds / 60) }
    '{0} s' -f $Seconds
}

function Get-LocalFree {
    param([string]$Path)
    try {
        if ($Path -match '^[A-Za-z]:') { return (New-Object IO.DriveInfo($Path.Substring(0, 1))).AvailableFreeSpace }
    } catch { }
    $null
}

function Start-JobNow {
    param($Job)
    $st = Get-WsbState $Job.id
    if ($st -and $st.status -eq 'running') { Show-Message 'Dieser Auftrag läuft bereits.' | Out-Null; return }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:Runner`" -JobId $($Job.id)"
    Set-WsbState $Job.id @{ status = 'running'; phase = 'Wird gestartet'; percent = 0; pid = $p.Id; message = '' }
    Update-Run
}

# ------------------------------------------------------------ Hauptfenster

$main = Import-Xaml 'MainWindow.xaml'
$win = $main.Window
$ui = $main.Ui
$ui.VersionText.Text = 'Version ' + (Get-WsbVersion)

function Show-Page {
    param([string]$Name)
    foreach ($n in 'Overview', 'Jobs', 'Restore', 'Log') {
        $ui["Page$n"].Visibility = if ($n -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    switch ($Name) {
        'Overview' { Update-Overview }
        'Jobs' { Update-Jobs }
        'Log' { Update-Logs }
    }
}

function Update-Run {
    $running = $null
    foreach ($j in @(Get-WsbJob)) {
        $s = Get-WsbState $j.id
        if ($s -and $s.status -eq 'running') { $running = [pscustomobject]@{ Job = $j; State = $s }; break }
    }
    if ($running) {
        $ui.RunCard.Visibility = 'Visible'
        $pct = [int]$running.State.percent
        $phase = [string]$running.State.phase
        $ui.RunPhase.Text = if ($phase) { "$($running.Job.name): $phase" } else { $running.Job.name }
        $ui.RunPercent.Text = "$pct %"
        $ui.RunBar.Value = $pct
        $ui.StatusDot.Fill = '#2563EB'
        $ui.StatusTitle.Text = 'Sicherung läuft'
        $ui.StatusSub.Text = $running.Job.name
        $ui.BtnRunNow.IsEnabled = $false
    } else {
        $ui.RunCard.Visibility = 'Collapsed'
        $ui.BtnRunNow.IsEnabled = $true
    }
    $was = $script:WasRunning
    $script:WasRunning = [bool]$running
    if ($was -and -not $running) { Update-Overview }
}

function Update-Overview {
    $jobs = @(Get-WsbJob)
    $hist = @(Get-WsbHistory -Last 30)

    $ui.BtnRunNow.Content = if ($jobs.Count -eq 0) { 'Auftrag anlegen' } else { 'Jetzt sichern' }

    $rows = @()
    foreach ($h in $hist) {
        $when = try { ([datetime]$h.time).ToString('dd.MM.yyyy HH:mm', $de) } catch { [string]$h.time }
        $ok = ($h.status -eq 'ok')
        $rows += [pscustomobject]@{
            Color    = if ($ok) { '#16A34A' } else { '#DC2626' }
            When     = $when
            Text     = if ($ok) { "$($h.job) - erfolgreich" } else { "$($h.job) - $($h.message)" }
            Size     = if ($ok) { Format-WsbSize $h.size } else { '' }
            Duration = Format-Duration ([int]$h.duration)
        }
    }
    $ui.HistoryList.ItemsSource = $rows
    $ui.HistoryEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    # Gesamtstatus (laufende Sicherung setzt Update-Run)
    if (-not $script:WasRunning) {
        if ($jobs.Count -eq 0) {
            $ui.StatusDot.Fill = '#9CA3AF'; $ui.StatusTitle.Text = 'Noch kein Auftrag eingerichtet'
            $ui.StatusSub.Text = 'Legen Sie Ihre erste regelmäßige Sicherung an.'
        } elseif ($hist.Count -eq 0) {
            $ui.StatusDot.Fill = '#9CA3AF'; $ui.StatusTitle.Text = 'Bereit'
            $ui.StatusSub.Text = 'Es ist noch keine Sicherung gelaufen.'
        } elseif ($hist[0].status -eq 'ok') {
            $ui.StatusDot.Fill = '#16A34A'; $ui.StatusTitle.Text = 'Alles in Ordnung'
            $ui.StatusSub.Text = 'Letzte Sicherung ' + (Format-Ago ([datetime]$hist[0].time)) + ' (' + $hist[0].job + ')'
        } else {
            $ui.StatusDot.Fill = '#DC2626'; $ui.StatusTitle.Text = 'Die letzte Sicherung ist fehlgeschlagen'
            $ui.StatusSub.Text = [string]$hist[0].message
        }
    }

    $lastOk = $hist | Where-Object { $_.status -eq 'ok' } | Select-Object -First 1
    if ($lastOk) {
        $ui.CardLastValue.Text = Format-Ago ([datetime]$lastOk.time)
        $ui.CardLastSub.Text = ([datetime]$lastOk.time).ToString('dd.MM.yyyy HH:mm', $de) + ' · ' + (Format-WsbSize $lastOk.size)
    } else { $ui.CardLastValue.Text = '-'; $ui.CardLastSub.Text = 'noch keine erfolgreiche Sicherung' }

    $next = $null
    foreach ($j in ($jobs | Where-Object { $_.enabled })) {
        $n = Get-WsbNextRun $j.id
        if ($n -and (-not $next -or $n -lt $next.When)) { $next = [pscustomobject]@{ When = $n; Job = $j.name } }
    }
    if ($next) {
        $ui.CardNextValue.Text = $next.When.ToString('ddd dd.MM. HH:mm', $de)
        $ui.CardNextSub.Text = $next.Job
    } else { $ui.CardNextValue.Text = '-'; $ui.CardNextSub.Text = 'kein Zeitplan aktiv' }

    $first = $jobs | Where-Object { $_.enabled } | Select-Object -First 1
    if ($first) {
        $free = Get-LocalFree $first.target.path
        if ($null -ne $free) {
            $ui.CardSpaceValue.Text = (Format-WsbSize $free) + ' frei'
            $ui.CardSpaceSub.Text = $first.target.path
        } else { $ui.CardSpaceValue.Text = 'Netzwerkziel'; $ui.CardSpaceSub.Text = $first.target.path }
    } else { $ui.CardSpaceValue.Text = '-'; $ui.CardSpaceSub.Text = '' }
}

function Update-Jobs {
    $sel = if ($ui.JobList.SelectedItem) { $ui.JobList.SelectedItem.Id } else { $null }
    $items = @()
    foreach ($j in @(Get-WsbJob)) {
        $st = Get-WsbState $j.id
        $running = ($st -and $st.status -eq 'running')
        $next = if ($j.enabled -and $j.schedule.type -ne 'manual') { Get-WsbNextRun $j.id } else { $null }
        $vols = if (@($j.volumes).Count -gt 0) { (@($j.volumes) -join ', ') } else { 'alle Laufwerke' }
        $items += [pscustomobject]@{
            Id         = $j.id
            Name       = $j.name
            Schedule   = Get-WsbScheduleText $j
            Detail     = "Ziel: $($j.target.path)  ·  $vols  ·  $($j.keep) Sicherungen behalten"
            StateText  = if ($running) { 'LÄUFT' } elseif ($j.enabled) { 'AKTIV' } else { 'PAUSIERT' }
            StateColor = if ($running) { '#2563EB' } elseif ($j.enabled) { '#16A34A' } else { '#9CA3AF' }
            Next       = if ($next) { 'Nächste: ' + $next.ToString('ddd dd.MM. HH:mm', $de) } else { '' }
        }
    }
    $ui.JobList.ItemsSource = $items
    $ui.JobsEmpty.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    if ($sel) { $ui.JobList.SelectedItem = $items | Where-Object { $_.Id -eq $sel } | Select-Object -First 1 }
    $has = ($items.Count -gt 0)
    foreach ($b in 'BtnEditJob', 'BtnRunJob', 'BtnToggleJob', 'BtnDeleteJob') { $ui[$b].IsEnabled = $has }
}

function Get-SelectedJob {
    $it = $ui.JobList.SelectedItem
    if (-not $it) { Show-Message 'Bitte zuerst einen Auftrag in der Liste auswählen.' | Out-Null; return $null }
    @(Get-WsbJob -Id $it.Id)[0]
}

function Update-Logs {
    $files = @(Get-ChildItem -LiteralPath (Get-WsbLogDir) -Filter *.log -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 60)
    $ui.LogSelect.Items.Clear()
    foreach ($f in $files) {
        $i = New-Object Windows.Controls.ComboBoxItem
        $i.Content = '{0:dd.MM.yyyy HH:mm}  -  {1}' -f $f.LastWriteTime, $f.BaseName
        $i.Tag = $f.FullName
        [void]$ui.LogSelect.Items.Add($i)
    }
    if ($ui.LogSelect.Items.Count -gt 0) { $ui.LogSelect.SelectedIndex = 0 } else { $ui.LogText.Text = 'Noch keine Protokolle vorhanden.' }
}

# ------------------------------------------------------------ Auftrags-Editor

function Show-JobEditor {
    param($Job, [bool]$IsNew)
    $ed = Import-Xaml 'JobEditor.xaml'
    $w = $ed.Window; $e = $ed.Ui
    if (-not $SelfTest) { $w.Owner = $win }
    $w.Title = if ($IsNew) { 'Neuer Auftrag' } else { 'Auftrag bearbeiten' }
    $result = @{ Job = $null }

    $e.JobName.Text = $Job.name
    $e.TargetPath.Text = [string]$Job.target.path
    $e.TargetUser.Text = [string]$Job.target.user
    $e.TimeBox.Text = [string]$Job.schedule.time
    $e.HoursBox.Text = [string]$Job.schedule.everyHours
    $e.KeepBox.Text = [string]$Job.keep

    # Laufwerke
    $want = @($Job.volumes)
    foreach ($v in @(Get-WsbVolume)) {
        $cb = New-Object Windows.Controls.CheckBox
        $sys = if ($v.IsSystem) { ' · System' } else { '' }
        $lab = if ($v.Label) { " $($v.Label)" } else { '' }
        $cb.Content = "$($v.Drive)$lab$sys · $(Format-WsbSize $v.Size) · $(Format-WsbSize $v.Used) belegt" + $(if (-not $v.Supported) { " · $($v.FileSystem) wird nicht unterstützt" } else { '' })
        $cb.Tag = $v.Drive
        $cb.Margin = '0,4,0,0'
        $cb.IsEnabled = $v.Supported
        $cb.IsChecked = ($want -contains $v.Drive)
        [void]$e.VolumePanel.Children.Add($cb)
    }
    if ($want.Count -gt 0) { $e.RbSome.IsChecked = $true; $e.VolumePanel.IsEnabled = $true }
    $e.RbAll.Add_Checked({ $e.VolumePanel.IsEnabled = $false }.GetNewClosure())
    $e.RbSome.Add_Checked({ $e.VolumePanel.IsEnabled = $true }.GetNewClosure())

    # Zeitplan
    foreach ($d in 1..31) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = "$d."; $i.Tag = $d; [void]$e.DayOfMonthBox.Items.Add($i) }
    $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = 'Letzter Tag'; $i.Tag = 32; [void]$e.DayOfMonthBox.Items.Add($i)
    $dom = [int]$Job.schedule.dayOfMonth
    $e.DayOfMonthBox.SelectedItem = $e.DayOfMonthBox.Items | Where-Object { $_.Tag -eq $dom } | Select-Object -First 1
    if (-not $e.DayOfMonthBox.SelectedItem) { $e.DayOfMonthBox.SelectedIndex = 0 }
    foreach ($t in $e.DaysPanel.Children) { $t.IsChecked = (@($Job.schedule.days) -contains $t.Tag) }
    $e.ScheduleType.SelectedItem = $e.ScheduleType.Items | Where-Object { $_.Tag -eq $Job.schedule.type } | Select-Object -First 1
    $applySchedule = {
        $t = $e.ScheduleType.SelectedItem.Tag
        $e.RowTime.Visibility = if ($t -eq 'manual') { 'Collapsed' } else { 'Visible' }
        $e.RowHours.Visibility = if ($t -eq 'hourly') { 'Visible' } else { 'Collapsed' }
        $e.RowDays.Visibility = if ($t -eq 'weekly') { 'Visible' } else { 'Collapsed' }
        $e.RowMonth.Visibility = if ($t -eq 'monthly') { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()
    $e.ScheduleType.Add_SelectionChanged($applySchedule)
    & $applySchedule

    $e.CompBox.SelectedItem = $e.CompBox.Items | Where-Object { $_.Tag -eq $Job.compression } | Select-Object -First 1
    if (-not $e.CompBox.SelectedItem) { $e.CompBox.SelectedIndex = 0 }

    # Mail
    $m = $Job.mail
    $e.MailEnabled.IsChecked = [bool]$m.enabled
    $e.MailPanel.IsEnabled = [bool]$m.enabled
    $e.MailServer.Text = [string]$m.server; $e.MailPort.Text = [string]$m.port; $e.MailSsl.IsChecked = [bool]$m.ssl
    $e.MailFrom.Text = [string]$m.from; $e.MailTo.Text = [string]$m.to; $e.MailUser.Text = [string]$m.user
    $e.MailOnlyErr.IsChecked = [bool]$m.onlyOnError
    $e.MailEnabled.Add_Click({ $e.MailPanel.IsEnabled = [bool]$e.MailEnabled.IsChecked }.GetNewClosure())

    $e.BtnBrowse.Add_Click({
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = 'Zielordner für die Sicherungen wählen'
            if ($fb.ShowDialog() -eq 'OK') { $e.TargetPath.Text = $fb.SelectedPath }
        }.GetNewClosure())

    $e.BtnTestTarget.Add_Click({
            $e.TargetTestResult.Text = 'Teste ...'; $e.TargetTestResult.Foreground = '#6A7280'
            $tj = [pscustomobject]@{ target = [pscustomobject]@{ path = $e.TargetPath.Text; user = $e.TargetUser.Text; password = (Protect-WsbSecret $e.TargetPass.Password) } }
            if (-not $e.TargetPass.Password -and $Job.target.user -eq $e.TargetUser.Text) { $tj.target.password = $Job.target.password }
            try {
                $r = Test-WsbTarget -Job $tj
                $e.TargetTestResult.Text = "OK - $(Format-WsbSize $r.Free) frei"; $e.TargetTestResult.Foreground = '#16A34A'
            } catch {
                $e.TargetTestResult.Text = $_.Exception.Message; $e.TargetTestResult.Foreground = '#B91C1C'
            }
        }.GetNewClosure())

    $e.BtnCancel.Add_Click({ $w.DialogResult = $false }.GetNewClosure())
    $e.BtnSave.Add_Click({
            $err = $null
            $name = $e.JobName.Text.Trim()
            if (-not $name) { $err = 'Bitte einen Namen eingeben.' }
            elseif (-not $e.TargetPath.Text.Trim()) { $err = 'Bitte ein Sicherungsziel angeben.' }
            $type = $e.ScheduleType.SelectedItem.Tag
            $time = [timespan]::Zero
            if (-not $err -and $type -ne 'manual' -and -not [timespan]::TryParse($e.TimeBox.Text.Trim(), [ref]$time)) { $err = 'Die Uhrzeit muss im Format HH:mm angegeben werden, z. B. 02:00.' }
            $hours = 0; $keep = 0
            if (-not $err -and $type -eq 'hourly' -and (-not [int]::TryParse($e.HoursBox.Text, [ref]$hours) -or $hours -lt 1 -or $hours -gt 23)) { $err = 'Stunden: bitte eine Zahl von 1 bis 23.' }
            if (-not $err -and (-not [int]::TryParse($e.KeepBox.Text, [ref]$keep) -or $keep -lt 1)) { $err = 'Aufbewahrung: bitte eine Zahl ab 1.' }
            $days = @($e.DaysPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
            if (-not $err -and $type -eq 'weekly' -and $days.Count -eq 0) { $err = 'Bitte mindestens einen Wochentag wählen.' }
            $vols = @($e.VolumePanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
            if (-not $err -and $e.RbSome.IsChecked -and $vols.Count -eq 0) { $err = 'Bitte mindestens ein Laufwerk wählen.' }
            if (-not $err -and $e.MailEnabled.IsChecked -and (-not $e.MailServer.Text.Trim() -or -not $e.MailTo.Text.Trim())) { $err = 'E-Mail: Server und Empfänger sind nötig.' }
            if ($err) { $e.ErrorText.Text = $err; return }

            $j = $Job
            $j.name = $name
            $j.volumes = if ($e.RbSome.IsChecked) { $vols } else { @() }
            $j.target.path = $e.TargetPath.Text.Trim()
            if ($e.TargetPass.Password) { $j.target.password = Protect-WsbSecret $e.TargetPass.Password }
            if (-not $e.TargetUser.Text.Trim()) { $j.target.password = '' }
            $j.target.user = $e.TargetUser.Text.Trim()
            $j.schedule.type = [string]$type
            if ($type -ne 'manual') { $j.schedule.time = $time.ToString('hh\:mm') }
            if ($type -eq 'hourly') { $j.schedule.everyHours = $hours }
            $j.schedule.days = $days
            $j.schedule.dayOfMonth = [int]$e.DayOfMonthBox.SelectedItem.Tag
            $j.keep = $keep
            $j.compression = [string]$e.CompBox.SelectedItem.Tag
            $j.mail.enabled = [bool]$e.MailEnabled.IsChecked
            $j.mail.server = $e.MailServer.Text.Trim()
            $mp = 25; [void][int]::TryParse($e.MailPort.Text, [ref]$mp); $j.mail.port = $mp
            $j.mail.ssl = [bool]$e.MailSsl.IsChecked
            $j.mail.from = $e.MailFrom.Text.Trim(); $j.mail.to = $e.MailTo.Text.Trim(); $j.mail.user = $e.MailUser.Text.Trim()
            if ($e.MailPass.Password) { $j.mail.password = Protect-WsbSecret $e.MailPass.Password }
            $j.mail.onlyOnError = [bool]$e.MailOnlyErr.IsChecked
            $result.Job = $j
            $w.DialogResult = $true
        }.GetNewClosure())

    if ($SelfTest) { return $null }
    [void]$w.ShowDialog()
    $result.Job
}

# ------------------------------------------------------------ Boot-Medium

function Show-MediaDialog {
    $md = Import-Xaml 'MediaDialog.xaml'
    $w = $md.Window; $m = $md.Ui
    if (-not $SelfTest) { $w.Owner = $win }
    $m.IsoPath.Text = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WinServBackup-Recovery.iso'

    $usb = @()
    try {
        foreach ($d in @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })) {
            foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and [int]$_.DriveLetter -ne 0 })) {
                $usb += [pscustomobject]@{ Letter = [string]$p.DriveLetter; Text = "$($p.DriveLetter): - $($d.FriendlyName) - $(Format-WsbSize $d.Size)" }
            }
        }
    } catch { }
    foreach ($u in $usb) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $u.Text; $i.Tag = $u.Letter; [void]$m.UsbCombo.Items.Add($i) }
    if ($m.UsbCombo.Items.Count -gt 0) { $m.UsbCombo.SelectedIndex = 0 } else { $m.RbUsb.IsEnabled = $false; $m.RbUsb.Content = 'USB-Stick (kein USB-Datenträger gefunden)' }

    $m.RbIso.Add_Checked({ $m.IsoPath.IsEnabled = $true; $m.BtnIsoBrowse.IsEnabled = $true; $m.UsbCombo.IsEnabled = $false }.GetNewClosure())
    $m.RbUsb.Add_Checked({ $m.IsoPath.IsEnabled = $false; $m.BtnIsoBrowse.IsEnabled = $false; $m.UsbCombo.IsEnabled = $true }.GetNewClosure())
    $m.BtnIsoBrowse.Add_Click({
            $sf = New-Object System.Windows.Forms.SaveFileDialog
            $sf.Filter = 'ISO-Datei (*.iso)|*.iso'; $sf.FileName = 'WinServBackup-Recovery.iso'
            if ($sf.ShowDialog() -eq 'OK') { $m.IsoPath.Text = $sf.FileName }
        }.GetNewClosure())
    $m.BtnMediaCancel.Add_Click({ $w.Close() }.GetNewClosure())
    $m.BtnMediaCreate.Add_Click({
            $script = Join-Path $script:Root 'recovery\New-RecoveryMedia.ps1'
            $kb = $m.KbCombo.SelectedItem.Content
            $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -InputLocale $kb"
            if ($m.ChkDrivers.IsChecked) { $argList += ' -IncludeDrivers' }
            if ($m.RbUsb.IsChecked) {
                if (-not $m.UsbCombo.SelectedItem) { $m.MediaError.Text = 'Bitte einen USB-Stick wählen.'; return }
                $letter = $m.UsbCombo.SelectedItem.Tag
                $ask = Show-Message "Alle Daten auf $($letter): werden gelöscht. Fortfahren?" 'USB-Stick löschen' 'YesNo' 'Warning' $w
                if ($ask -ne 'Yes') { return }
                $argList += " -UsbDrive $letter"
            } else {
                if (-not $m.IsoPath.Text.Trim()) { $m.MediaError.Text = 'Bitte einen Dateinamen für die ISO angeben.'; return }
                $argList += " -IsoPath `"$($m.IsoPath.Text.Trim())`""
            }
            Start-Process powershell.exe -ArgumentList $argList
            $w.Close()
        }.GetNewClosure())
    if ($SelfTest) { return }
    [void]$w.ShowDialog()
}

# ------------------------------------------------------------ Ereignisse

$ui.NavOverview.Add_Checked({ Show-Page 'Overview' })
$ui.NavJobs.Add_Checked({ Show-Page 'Jobs' })
$ui.NavRestore.Add_Checked({ Show-Page 'Restore' })
$ui.NavLog.Add_Checked({ Show-Page 'Log' })

$ui.BtnNewJob.Add_Click({
        $j = Show-JobEditor -Job (New-WsbJob) -IsNew $true
        if ($j) { try { Save-WsbJob $j } catch { Show-Message "Der Zeitplan konnte nicht angelegt werden:`n$($_.Exception.Message)" 'Fehler' 'OK' 'Error' | Out-Null }; Update-Jobs; Update-Overview }
    })

$ui.BtnEditJob.Add_Click({
        $j = Get-SelectedJob; if (-not $j) { return }
        $j = Show-JobEditor -Job $j -IsNew $false
        if ($j) { try { Save-WsbJob $j } catch { Show-Message "Der Zeitplan konnte nicht aktualisiert werden:`n$($_.Exception.Message)" 'Fehler' 'OK' 'Error' | Out-Null }; Update-Jobs; Update-Overview }
    })

$ui.JobList.Add_MouseDoubleClick({ if ($ui.JobList.SelectedItem) { $ui.BtnEditJob.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })

$ui.BtnRunJob.Add_Click({ $j = Get-SelectedJob; if ($j) { Start-JobNow $j; Update-Jobs } })

$ui.BtnToggleJob.Add_Click({
        $j = Get-SelectedJob; if (-not $j) { return }
        $j.enabled = -not [bool]$j.enabled
        Save-WsbJob $j
        Update-Jobs; Update-Overview
    })

$ui.BtnDeleteJob.Add_Click({
        $j = Get-SelectedJob; if (-not $j) { return }
        $a = Show-Message "Auftrag „$($j.name)“ löschen?`nBereits erstellte Sicherungsdateien bleiben erhalten." 'Auftrag löschen' 'YesNo' 'Question' $win
        if ($a -eq 'Yes') { Remove-WsbJob -Id $j.id; Update-Jobs; Update-Overview }
    })

$ui.BtnRunNow.Add_Click({
        $jobs = @(Get-WsbJob)
        if ($jobs.Count -eq 0) { $ui.NavJobs.IsChecked = $true; $ui.BtnNewJob.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); return }
        if ($jobs.Count -eq 1) { Start-JobNow $jobs[0]; return }
        $menu = New-Object Windows.Controls.ContextMenu
        foreach ($j in $jobs) {
            $mi = New-Object Windows.Controls.MenuItem
            $mi.Header = $j.name
            $mi.Tag = $j.id
            $mi.Add_Click({ param($s, $ev) Start-JobNow (@(Get-WsbJob -Id $s.Tag)[0]) })
            [void]$menu.Items.Add($mi)
        }
        $menu.PlacementTarget = $ui.BtnRunNow
        $menu.IsOpen = $true
    })

$ui.BtnMedia.Add_Click({ Show-MediaDialog })

$ui.BtnInspect.Add_Click({
        $of = New-Object System.Windows.Forms.OpenFileDialog
        $of.Filter = 'WinServBackup-Sicherung (*.wim)|*.wim'
        if ($of.ShowDialog() -ne 'OK') { return }
        $ui.InspectResult.Text = 'Lese Datei ...'
        $win.Cursor = [Windows.Input.Cursors]::Wait
        try {
            $i = Get-WsbBackupInfo -Path $of.FileName
            $mf = $i.Manifest
            $lines = @(
                "Server:      $($mf.host)",
                "Erstellt:    $(([datetime]$mf.created).ToLocalTime().ToString('dd.MM.yyyy HH:mm', $de))",
                "System:      $($mf.os.caption) (Build $($mf.os.build))",
                "Start:       $($mf.firmware)",
                "Dateigröße:  $(Format-WsbSize $i.SizeBytes)",
                'Laufwerke:'
            )
            foreach ($v in @($mf.volumes)) { $lines += "  $($v.letter):  $(Format-WsbSize $v.size)  ($(Format-WsbSize $v.used) belegt)" + $(if ($v.isSystem) { '  [System]' } else { '' }) }
            $ui.InspectResult.Text = $lines -join "`n"
        } catch { $ui.InspectResult.Text = 'Die Datei konnte nicht gelesen werden: ' + $_.Exception.Message }
        finally { $win.Cursor = $null }
    })

$ui.LogSelect.Add_SelectionChanged({
        $it = $ui.LogSelect.SelectedItem
        if ($it) {
            try { $ui.LogText.Text = [IO.File]::ReadAllText($it.Tag); $ui.LogText.ScrollToEnd() } catch { $ui.LogText.Text = $_.Exception.Message }
        }
    })
$ui.BtnOpenLogs.Add_Click({ Start-Process explorer.exe (Get-WsbLogDir) })

# ------------------------------------------------------------ Start

Update-Overview
Update-Run
Update-Jobs

if ($SelfTest) {
    [void](Show-JobEditor -Job (New-WsbJob) -IsNew $true)
    Show-MediaDialog
    Write-Host 'SELFTEST OK'
    return
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [timespan]::FromSeconds(1)
$timer.Add_Tick({
        $script:Tick++
        Update-Run
        if ($script:Tick % 30 -eq 0 -and $ui.PageOverview.Visibility -eq 'Visible') { Update-Overview }
        if ($ui.PageJobs.Visibility -eq 'Visible' -and $script:Tick % 3 -eq 0) { Update-Jobs }
    })
$timer.Start()
[void]$win.ShowDialog()
$timer.Stop()
