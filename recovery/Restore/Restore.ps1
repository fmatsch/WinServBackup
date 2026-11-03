#Requires -Version 5.1
# WinServBackup - Wiederherstellungs-Assistent (laeuft im Boot-Medium / WinPE, funktioniert aber auch im Vollsystem)
param([switch]$SelfTest, [string]$ModulePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

if (-not $ModulePath) {
    $ModulePath = if (Test-Path (Join-Path $PSScriptRoot 'WinServBackup.psm1')) { Join-Path $PSScriptRoot 'WinServBackup.psm1' } else { Join-Path $PSScriptRoot '..\..\src\WinServBackup.psm1' }
}
Import-Module $ModulePath -Force
Set-WsbLogFile -Path (Join-Path ([IO.Path]::GetTempPath()) 'wsb-restore.log')

if (-not ('WsbItem' -as [type])) { Add-Type -TypeDefinition 'public class WsbItem { public string Text { get; set; } public int Number { get; set; } public override string ToString() { return Text; } }' }
$script:Backups = @()     # gefundene Dateien
$script:Info = $null      # gelesene Sicherung
$script:Combos = @{}      # Quelldatentraeger -> ComboBox
$script:Step = 1
$script:Busy = $false
$accent = [Drawing.Color]::FromArgb(37, 99, 235)
$font = New-Object Drawing.Font('Segoe UI', 10)
$fontBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)

# ------------------------------------------------------------ Hilfen

function New-Button {
    param([string]$Text, [int]$Width = 150, [switch]$Primary)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 34; $b.FlatStyle = 'Flat'; $b.Font = $font
    if ($Primary) { $b.BackColor = $accent; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.BorderColor = $accent }
    else { $b.BackColor = [Drawing.Color]::White; $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(213, 217, 223) }
    $b
}

function New-Label {
    param([string]$Text, [switch]$Bold, [int]$Height = 0)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = ($Height -eq 0); $l.Font = $(if ($Bold) { $fontBold } else { $font })
    if ($Height -gt 0) { $l.Height = $Height }
    $l
}

function Update-Ui { [Windows.Forms.Application]::DoEvents() }

function Get-BootMediaDisk {
    # Datentraeger, von dem das Boot-Medium stammt, soll nie als Ziel angeboten werden.
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.IsReady -and (Test-Path -LiteralPath ($d.Name + 'sources\boot.wim'))) {
                return [int](Get-Partition -DriveLetter $d.Name.Substring(0, 1) -ErrorAction Stop).DiskNumber
            }
        } catch { }
    }
    -1
}

function Find-Backups {
    $found = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -eq 'CDRom') { continue }
        if ($d.Name -eq "$($env:SystemDrive)\") { continue }
        foreach ($depth in 0, 1, 2) {
            try {
                $pat = $d.Name + ('*\' * $depth) + '*.wim'
                $found += @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '_\d{8}-\d{6}\.wim$' -and $_.Name -notmatch '\.partial\.wim$' })
            } catch { }
        }
    }
    @($found | Sort-Object LastWriteTime -Descending)
}

function Show-NetworkDialog {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Netzwerkfreigabe verbinden'; $f.ClientSize = '460,250'; $f.StartPosition = 'CenterParent'; $f.Font = $font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $y = 14
    $tb = @{}
    foreach ($row in @(@('Pfad (z. B. \\nas\backup)', 'path'), @('Benutzer (optional)', 'user'), @('Kennwort (optional)', 'pass'))) {
        $l = New-Label $row[0]; $l.Location = "16,$y"; $f.Controls.Add($l)
        $t = New-Object Windows.Forms.TextBox; $t.Location = "16,$($y + 24)"; $t.Width = 428
        if ($row[1] -eq 'pass') { $t.UseSystemPasswordChar = $true }
        $f.Controls.Add($t); $tb[$row[1]] = $t
        $y += 58
    }
    $ok = New-Button 'Verbinden' 120 -Primary; $ok.Location = '324,200'; $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $c = New-Button 'Abbrechen' 100; $c.Location = '212,200'; $c.DialogResult = 'Cancel'; $f.Controls.Add($c)
    if ($f.ShowDialog($form) -ne 'OK' -or -not $tb.path.Text.Trim()) { return }
    $path = $tb.path.Text.Trim()
    $letter = @(Get-WsbFreeLetter)[0]
    $a = @('use', "${letter}:", $path)
    if ($tb.user.Text) { $a += $tb.pass.Text; $a += "/user:$($tb.user.Text)" }
    $out = & net.exe @a 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { [Windows.Forms.MessageBox]::Show("Verbindung fehlgeschlagen:`n$out", 'Netzwerk', 'OK', 'Error') | Out-Null; return }
    Refresh-Backups
}

# ------------------------------------------------------------ Fenster

$form = New-Object Windows.Forms.Form
$form.Text = 'WinServBackup - Wiederherstellung'
$form.ClientSize = '940,640'
$form.StartPosition = 'CenterScreen'
$form.Font = $font
$form.BackColor = [Drawing.Color]::White
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($wa.Width -lt 960 -or $wa.Height -lt 680) { $form.WindowState = 'Maximized' }

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 74; $header.BackColor = [Drawing.Color]::FromArgb(244, 245, 247)
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Location = '24,12'; $lblTitle.AutoSize = $true; $lblTitle.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$lblSub = New-Object Windows.Forms.Label
$lblSub.Location = '26,44'; $lblSub.AutoSize = $true; $lblSub.ForeColor = [Drawing.Color]::FromArgb(106, 114, 128)
$header.Controls.AddRange(@($lblTitle, $lblSub))

$footer = New-Object Windows.Forms.Panel
$footer.Dock = 'Bottom'; $footer.Height = 64; $footer.BackColor = [Drawing.Color]::FromArgb(244, 245, 247)
$btnBack = New-Button 'Zurück' 120
$btnNext = New-Button 'Weiter' 220 -Primary
$btnExit = New-Button 'Beenden' 120
$btnBack.Anchor = 'Top,Right'; $btnNext.Anchor = 'Top,Right'; $btnExit.Anchor = 'Top,Left'
$btnExit.Location = '24,15'
$footer.Controls.AddRange(@($btnBack, $btnNext, $btnExit))
$footer.Add_Resize({ $btnNext.Location = New-Object Drawing.Point(($footer.Width - 244), 15); $btnBack.Location = New-Object Drawing.Point(($footer.Width - 244 - 132), 15) })

$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'; $content.Padding = '24,16,24,8'
$form.Controls.Add($content); $form.Controls.Add($header); $form.Controls.Add($footer)
$content.BringToFront()

function New-Page { $p = New-Object Windows.Forms.Panel; $p.Dock = 'Fill'; $p.Visible = $false; $content.Controls.Add($p); $p }
$p1 = New-Page; $p2 = New-Page; $p3 = New-Page; $p4 = New-Page

# --- Seite 1: Sicherung waehlen
$lv = New-Object Windows.Forms.ListView
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.Dock = 'Fill'; $lv.Font = $font
[void]$lv.Columns.Add('Datei', 380); [void]$lv.Columns.Add('Datum', 150); [void]$lv.Columns.Add('Größe', 90); [void]$lv.Columns.Add('Ort', 220)
$bar1 = New-Object Windows.Forms.FlowLayoutPanel
$bar1.Dock = 'Bottom'; $bar1.Height = 48; $bar1.Padding = '0,10,0,0'
$btnScan = New-Button 'Erneut suchen' 140
$btnFile = New-Button 'Datei wählen ...' 150
$btnNet = New-Button 'Netzwerk ...' 140
$bar1.Controls.AddRange(@($btnScan, $btnFile, $btnNet))
$lbl1 = New-Label 'Backup-Dateien auf allen angeschlossenen Laufwerken:'
$lbl1.Dock = 'Top'; $lbl1.Height = 30
$p1.Controls.Add($lv); $p1.Controls.Add($bar1); $p1.Controls.Add($lbl1)
$lv.BringToFront()

# --- Seite 2: Ziel
$lbl2 = New-Label 'Wählen Sie für jeden gesicherten Datenträger, wohin er zurückgespielt wird. Der Zieldatenträger wird komplett überschrieben.' -Height 44
$lbl2.Dock = 'Top'
$pnlMap = New-Object Windows.Forms.Panel
$pnlMap.Dock = 'Fill'; $pnlMap.AutoScroll = $true
$opt = New-Object Windows.Forms.Panel
$opt.Dock = 'Bottom'; $opt.Height = 130
$lblFw = New-Label 'Startmodus des Zielservers:'; $lblFw.Location = '0,8'
$cmbFw = New-Object Windows.Forms.ComboBox; $cmbFw.DropDownStyle = 'DropDownList'; $cmbFw.Location = '230,4'; $cmbFw.Width = 260
[void]$cmbFw.Items.AddRange(@('UEFI', 'BIOS (Legacy)'))
$chkFill = New-Object Windows.Forms.CheckBox; $chkFill.Text = 'Letztes Laufwerk eines Datenträgers auf die volle Größe erweitern'; $chkFill.Checked = $true; $chkFill.AutoSize = $true; $chkFill.Location = '0,44'
$lblDrv = New-Label 'Treiberordner (optional, z. B. RAID- oder Netzwerktreiber):'; $lblDrv.Location = '0,78'
$txtDrv = New-Object Windows.Forms.TextBox; $txtDrv.Location = '0,100'; $txtDrv.Width = 520
$btnDrv = New-Button '...' 44; $btnDrv.Location = '530,97'; $btnDrv.Height = 28
$opt.Controls.AddRange(@($lblFw, $cmbFw, $chkFill, $lblDrv, $txtDrv, $btnDrv))
$p2.Controls.Add($pnlMap); $p2.Controls.Add($opt); $p2.Controls.Add($lbl2)
$pnlMap.BringToFront()

# --- Seite 3: Bestaetigen
$txtSum = New-Object Windows.Forms.TextBox
$txtSum.Multiline = $true; $txtSum.ReadOnly = $true; $txtSum.Dock = 'Fill'; $txtSum.Font = New-Object Drawing.Font('Consolas', 10); $txtSum.ScrollBars = 'Vertical'; $txtSum.BackColor = [Drawing.Color]::White
$conf = New-Object Windows.Forms.Panel
$conf.Dock = 'Bottom'; $conf.Height = 90
$lblConf = New-Label 'Zur Bestätigung WIEDERHERSTELLEN eintippen. Alle Daten auf den genannten Zieldatenträgern gehen verloren.'; $lblConf.Location = '0,10'; $lblConf.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
$txtConf = New-Object Windows.Forms.TextBox; $txtConf.Location = '0,44'; $txtConf.Width = 300
$conf.Controls.AddRange(@($lblConf, $txtConf))
$p3.Controls.Add($txtSum); $p3.Controls.Add($conf)
$txtSum.BringToFront()

# --- Seite 4: Ablauf
$pb = New-Object Windows.Forms.ProgressBar
$pb.Dock = 'Top'; $pb.Height = 26; $pb.Minimum = 0; $pb.Maximum = 100
$lblState = New-Label 'Bereit.'; $lblState.Dock = 'Top'; $lblState.Height = 34; $lblState.Padding = '0,8,0,0'
$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.Dock = 'Fill'; $txtLog.Font = New-Object Drawing.Font('Consolas', 9); $txtLog.ScrollBars = 'Vertical'; $txtLog.BackColor = [Drawing.Color]::White
$p4.Controls.Add($txtLog); $p4.Controls.Add($lblState); $p4.Controls.Add($pb)
$txtLog.BringToFront()

# ------------------------------------------------------------ Logik

function Refresh-Backups {
    $form.Cursor = 'WaitCursor'; Update-Ui
    try {
        $script:Backups = @(Find-Backups)
        $lv.Items.Clear()
        foreach ($f in $script:Backups) {
            $it = New-Object Windows.Forms.ListViewItem($f.Name)
            [void]$it.SubItems.Add($f.LastWriteTime.ToString('dd.MM.yyyy HH:mm'))
            [void]$it.SubItems.Add((Format-WsbSize $f.Length))
            [void]$it.SubItems.Add($f.DirectoryName)
            $it.Tag = $f.FullName
            [void]$lv.Items.Add($it)
        }
        if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
        $lbl1.Text = if ($lv.Items.Count -gt 0) { 'Backup-Dateien auf allen angeschlossenen Laufwerken:' } else { 'Keine Backup-Dateien gefunden. Schließen Sie das Backup-Laufwerk an, verbinden Sie eine Freigabe oder wählen Sie die Datei selbst.' }
    } finally { $form.Cursor = 'Default' }
}

function Get-TargetDisks {
    $boot = Get-BootMediaDisk
    $bk = -1
    $sel = $lv.SelectedItems
    if ($sel.Count -gt 0 -and ([string]$sel[0].Tag) -match '^[A-Za-z]:') { try { $bk = [int](Get-Partition -DriveLetter ([string]$sel[0].Tag).Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { } }
    @(Get-Disk | Where-Object { $_.Size -gt 0 -and $_.Number -ne $boot -and $_.Number -ne $bk } | Sort-Object Number)
}

function Build-MapPage {
    $pnlMap.Controls.Clear(); $script:Combos = @{}
    $m = $script:Info.Manifest
    $targets = @(Get-TargetDisks)
    $y = 4
    $srcDisks = @(@($m.volumes) | ForEach-Object { [int]$_.diskNumber } | Sort-Object -Unique)
    $sysDisk = @(@($m.volumes) | Where-Object { $_.isSystem } | ForEach-Object { [int]$_.diskNumber })
    foreach ($sd in $srcDisks) {
        $vols = @(@($m.volumes) | Where-Object { [int]$_.diskNumber -eq $sd })
        $desc = ($vols | ForEach-Object { "$($_.letter): $(Format-WsbSize $_.size)" }) -join ', '
        $l = New-Label ("Gesicherter Datenträger $sd" + $(if ($sysDisk -contains $sd) { ' (System)' } else { '' }) + ":  $desc") -Bold
        $l.Location = "0,$y"; $pnlMap.Controls.Add($l)
        $c = New-Object Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'; $c.Location = "0,$($y + 28)"; $c.Width = 640
        if ($sysDisk -notcontains $sd) { [void]$c.Items.Add((New-Object WsbItem -Property @{ Text = '- nicht wiederherstellen -'; Number = -1 })) }
        foreach ($t in $targets) { [void]$c.Items.Add((New-Object WsbItem -Property @{ Text = "Datenträger $($t.Number)  -  $(Format-WsbSize $t.Size)  -  $($t.FriendlyName)"; Number = [int]$t.Number })) }
        $c.SelectedIndex = -1
        $pnlMap.Controls.Add($c)
        $script:Combos[$sd] = $c
        $y += 80
    }
    # sinnvolle Vorbelegung: kleinster passender Datentraeger fuer die Systemplatte, falls nur einer in Frage kommt
    if ($srcDisks.Count -eq 1 -and $script:Combos[$srcDisks[0]].Items.Count -eq 1) { $script:Combos[$srcDisks[0]].SelectedIndex = 0 }
    $cmbFw.SelectedIndex = $(if ((Get-WsbFirmware) -eq 'UEFI') { 0 } else { 1 })
}

function Get-DiskMap {
    $map = @{}
    foreach ($sd in $script:Combos.Keys) {
        $it = $script:Combos[$sd].SelectedItem
        if ($it -and $it.Number -ge 0) { $map[[int]$sd] = [int]$it.Number }
    }
    $map
}

function Show-Step {
    param([int]$N)
    $script:Step = $N
    $p1.Visible = ($N -eq 1); $p2.Visible = ($N -eq 2); $p3.Visible = ($N -eq 3); $p4.Visible = ($N -eq 4)
    switch ($N) {
        1 { $lblTitle.Text = '1  Sicherung wählen'; $lblSub.Text = 'Welches Backup soll eingespielt werden?'; $btnBack.Visible = $false; $btnNext.Text = 'Weiter'; $btnNext.Enabled = $true }
        2 { $lblTitle.Text = '2  Ziel wählen'; $lblSub.Text = 'Wohin soll zurückgespielt werden?'; $btnBack.Visible = $true; $btnNext.Text = 'Weiter'; $btnNext.Enabled = $true }
        3 { $lblTitle.Text = '3  Prüfen und bestätigen'; $lblSub.Text = 'Das Zurückspielen löscht die Zieldatenträger.'; $btnBack.Visible = $true; $btnNext.Text = 'WIEDERHERSTELLEN'; $btnNext.BackColor = [Drawing.Color]::FromArgb(185, 28, 28); $btnNext.FlatAppearance.BorderColor = $btnNext.BackColor; $btnNext.Enabled = $false; $txtConf.Text = '' }
        4 { $lblTitle.Text = '4  Wiederherstellung läuft'; $lblSub.Text = 'Bitte den Server nicht ausschalten.'; $btnBack.Visible = $false; $btnNext.Visible = $false; $btnExit.Enabled = $false }
    }
    if ($N -ne 3) { $btnNext.BackColor = $accent; $btnNext.FlatAppearance.BorderColor = $accent }
}

function Invoke-Restore {
    $script:Busy = $true
    $map = Get-DiskMap
    $fw = if ($cmbFw.SelectedIndex -eq 0) { 'UEFI' } else { 'BIOS' }
    $cb = {
        param($pct, $msg)
        $pb.Value = [math]::Min(100, [math]::Max(0, [int]$pct))
        $lblState.Text = $msg
        try { $txtLog.Text = [IO.File]::ReadAllText((Join-Path ([IO.Path]::GetTempPath()) 'wsb-restore.log')); $txtLog.SelectionStart = $txtLog.Text.Length; $txtLog.ScrollToCaret() } catch { }
        Update-Ui
    }
    try {
        Add-Content -Path (Join-Path ([IO.Path]::GetTempPath()) 'wsb-restore.log') -Value "Start $(Get-Date)" -ErrorAction SilentlyContinue
        $null = Restore-WsbBackup -BackupFile $script:Info.Path -DiskMap $map -Firmware $fw -DriverPath $txtDrv.Text.Trim() -FillLastVolume $chkFill.Checked -KeepLetters $true -OnProgress $cb
        $pb.Value = 100
        $lblState.Text = 'Fertig. Entfernen Sie das Boot-Medium und starten Sie den Server neu.'
        $lblState.ForeColor = [Drawing.Color]::FromArgb(22, 163, 74)
        $btnNext.Text = 'Neu starten'; $btnNext.Visible = $true; $btnNext.Enabled = $true
        $btnNext.Tag = 'reboot'
    } catch {
        $lblState.Text = 'Fehler: ' + $_.Exception.Message
        $lblState.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
        $btnBack.Text = 'Zurück zur Auswahl'; $btnBack.Visible = $true
    } finally {
        $script:Busy = $false
        $btnExit.Enabled = $true
        try { $txtLog.Text = [IO.File]::ReadAllText((Join-Path ([IO.Path]::GetTempPath()) 'wsb-restore.log')); $txtLog.SelectionStart = $txtLog.Text.Length; $txtLog.ScrollToCaret() } catch { }
    }
}

$btnScan.Add_Click({ Refresh-Backups })
$btnNet.Add_Click({ Show-NetworkDialog })
$btnFile.Add_Click({
        $of = New-Object Windows.Forms.OpenFileDialog
        $of.Filter = 'WinServBackup-Sicherung (*.wim)|*.wim'
        if ($of.ShowDialog() -eq 'OK') {
            $it = New-Object Windows.Forms.ListViewItem((Split-Path $of.FileName -Leaf))
            $fi = Get-Item -LiteralPath $of.FileName
            [void]$it.SubItems.Add($fi.LastWriteTime.ToString('dd.MM.yyyy HH:mm')); [void]$it.SubItems.Add((Format-WsbSize $fi.Length)); [void]$it.SubItems.Add($fi.DirectoryName)
            $it.Tag = $of.FileName
            [void]$lv.Items.Insert(0, $it); $it.Selected = $true
        }
    })
$btnDrv.Add_Click({ $fb = New-Object Windows.Forms.FolderBrowserDialog; if ($fb.ShowDialog() -eq 'OK') { $txtDrv.Text = $fb.SelectedPath } })
$txtConf.Add_TextChanged({ $btnNext.Enabled = ($txtConf.Text.Trim().ToUpper() -eq 'WIEDERHERSTELLEN') })

$btnBack.Add_Click({
        if ($script:Busy) { return }
        if ($script:Step -eq 4) { $btnBack.Text = 'Zurück'; $lblState.ForeColor = [Drawing.Color]::Black; $btnNext.Visible = $true; Show-Step 2; return }
        Show-Step ($script:Step - 1)
    })

$btnNext.Add_Click({
        if ($script:Busy) { return }
        if ($btnNext.Tag -eq 'reboot') { & wpeutil.exe reboot 2>$null; if ($LASTEXITCODE -ne 0) { Restart-Computer -Force }; return }
        switch ($script:Step) {
            1 {
                if ($lv.SelectedItems.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Bitte eine Sicherung auswählen.', 'Hinweis') | Out-Null; return }
                $form.Cursor = 'WaitCursor'; $lblSub.Text = 'Lese die Sicherung ...'; Update-Ui
                try { $script:Info = Get-WsbBackupInfo -Path ([string]$lv.SelectedItems[0].Tag) }
                catch { [Windows.Forms.MessageBox]::Show("Die Datei konnte nicht gelesen werden:`n$($_.Exception.Message)", 'Fehler', 'OK', 'Error') | Out-Null; return }
                finally { $form.Cursor = 'Default'; $lblSub.Text = 'Welches Backup soll eingespielt werden?' }
                Build-MapPage
                Show-Step 2
            }
            2 {
                $map = Get-DiskMap
                $m = $script:Info.Manifest
                $sysDisks = @(@($m.volumes) | Where-Object { $_.isSystem } | ForEach-Object { [int]$_.diskNumber })
                if ($map.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Bitte mindestens einen Zieldatenträger wählen.', 'Hinweis') | Out-Null; return }
                foreach ($sd in $sysDisks) { if (-not $map.ContainsKey($sd)) { [Windows.Forms.MessageBox]::Show('Für den System-Datenträger muss ein Ziel gewählt werden.', 'Hinweis') | Out-Null; return } }
                if (@($map.Values | Sort-Object -Unique).Count -ne $map.Count) { [Windows.Forms.MessageBox]::Show('Ein Zieldatenträger kann nur einmal verwendet werden.', 'Hinweis') | Out-Null; return }
                $created = try { ([datetime]$m.created).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } catch { $m.created }
                $t = New-Object System.Text.StringBuilder
                [void]$t.AppendLine("Sicherung:  $($script:Info.Path)")
                [void]$t.AppendLine("Server:     $($m.host)   erstellt $created")
                [void]$t.AppendLine("System:     $($m.os.caption)")
                [void]$t.AppendLine("Startmodus: $(if ($cmbFw.SelectedIndex -eq 0) { 'UEFI' } else { 'BIOS (Legacy)' })")
                [void]$t.AppendLine('')
                foreach ($sd in ($map.Keys | Sort-Object)) {
                    $d = Get-Disk -Number $map[$sd]
                    $vs = (@($m.volumes) | Where-Object { [int]$_.diskNumber -eq [int]$sd } | ForEach-Object { "$($_.letter):" }) -join ' '
                    [void]$t.AppendLine("Gesicherter Datenträger $sd ($vs)")
                    [void]$t.AppendLine("   ->  Datenträger $($d.Number), $(Format-WsbSize $d.Size), $($d.FriendlyName)")
                    [void]$t.AppendLine('       ALLE DATEN DARAUF WERDEN GELÖSCHT.')
                    [void]$t.AppendLine('')
                }
                $txtSum.Text = $t.ToString()
                Show-Step 3
            }
            3 {
                Show-Step 4
                Invoke-Restore
            }
        }
    })

$btnExit.Add_Click({ if (-not $script:Busy) { $form.Close() } })
$form.Add_FormClosing({ if ($script:Busy) { $_.Cancel = $true } })

$form.Add_Shown({ Refresh-Backups })

Show-Step 1
if ($SelfTest) { Write-Host 'SELFTEST OK'; $form.Dispose(); return }
[void]$form.ShowDialog()
