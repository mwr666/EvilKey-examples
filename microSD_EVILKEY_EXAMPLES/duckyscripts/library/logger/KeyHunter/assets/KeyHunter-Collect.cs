using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace KeyHunterTrainingCollector
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string collector = Path.Combine(root, "Collect-KeyHunter.ps1");
            string errorPath = Path.Combine(root, "collector-launch.error");
            try
            {
                if (!File.Exists(collector)) throw new FileNotFoundException("Local KeyHunter Collector is missing.", collector);
                if (File.Exists(errorPath)) File.Delete(errorPath);

                string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    @"System32\WindowsPowerShell\v1.0\powershell.exe");
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = powerShell;
                start.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -File \"" +
                    collector.Replace("\"", "\"\"") + "\"";
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                Process launched = Process.Start(start);
                if (launched == null) throw new InvalidOperationException("Windows PowerShell process was not created.");
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(errorPath, DateTime.Now.ToString("o") + Environment.NewLine + ex.ToString()); } catch { }
                MessageBox.Show("Could not start the local KeyHunter Collector.\n\n" + ex.Message,
                    "KeyHunter training", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Environment.ExitCode = 1;
            }
        }
    }
}
