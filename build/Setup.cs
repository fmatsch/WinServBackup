// WinServBackup-Setup.exe - entpackt das eingebettete Paket und fuehrt Install.ps1 aus.
// Aufruf: WinServBackup-Setup.exe [/silent] [/desktop]
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

static class Setup
{
    [STAThread]
    static int Main(string[] args)
    {
        bool silent = args.Any(a => a.Equals("/silent", StringComparison.OrdinalIgnoreCase) || a.Equals("/S", StringComparison.OrdinalIgnoreCase));
        bool desktop = args.Any(a => a.Equals("/desktop", StringComparison.OrdinalIgnoreCase));
        string tmp = Path.Combine(Path.GetTempPath(), "WinServBackup-Setup-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(tmp);
            string zip = Path.Combine(tmp, "pkg.zip");
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WinServBackup.zip"))
            using (var f = File.Create(zip)) s.CopyTo(f);
            ZipFile.ExtractToDirectory(zip, tmp);

            string install = Path.Combine(tmp, "WinServBackup", "Install.ps1");
            var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"));
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + install + "\"" + (desktop ? " -DesktopShortcut" : "");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (var p = Process.Start(psi))
            {
                string err = p.StandardError.ReadToEnd();
                string outp = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0)
                {
                    if (!silent) MessageBox.Show("Die Installation ist fehlgeschlagen (Code " + p.ExitCode + ").\n\n" + (err + outp), "WinServBackup Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return p.ExitCode;
                }
            }
            if (!silent)
            {
                string exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WinServBackup", "WinServBackup.exe");
                if (MessageBox.Show("WinServBackup wurde installiert.\n\nJetzt starten?", "WinServBackup Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes && File.Exists(exe))
                    Process.Start(exe);
            }
            return 0;
        }
        catch (Exception e)
        {
            if (!silent) MessageBox.Show("Die Installation ist fehlgeschlagen:\n" + e.Message, "WinServBackup Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { Directory.Delete(tmp, true); } catch { }
        }
    }
}
