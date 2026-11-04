// WinServBackup.exe - startet die Oberflaeche (PowerShell/WPF) ohne Konsolenfenster und mit Administratorrechten.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "WinServBackup.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("WinServBackup.ps1 wurde nicht neben der EXE gefunden:\n" + dir, "WinServBackup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"));
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"" + (args.Length > 0 ? " " + string.Join(" ", args) : "");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardError = true;
        try
        {
            using (var p = Process.Start(psi))
            {
                string err = p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0)
                {
                    MessageBox.Show("WinServBackup konnte nicht starten (Code " + p.ExitCode + ").\n\n" + (err.Length > 1500 ? err.Substring(0, 1500) : err), "WinServBackup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return p.ExitCode;
            }
        }
        catch (Exception e)
        {
            MessageBox.Show("PowerShell konnte nicht gestartet werden:\n" + e.Message, "WinServBackup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
