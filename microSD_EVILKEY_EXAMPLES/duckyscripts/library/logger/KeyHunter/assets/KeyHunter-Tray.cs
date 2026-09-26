using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace KeyHunterTraining
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool createdNew;
            string mutexName = Environment.GetEnvironmentVariable("KEYHUNTER_TRAY_MUTEX");
            if (String.IsNullOrWhiteSpace(mutexName)) mutexName = @"Local\KeyHunterTrainingTray";
            using (Mutex mutex = new Mutex(true, mutexName, out createdNew))
            {
                if (!createdNew) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayContext());
            }
        }
    }

    internal sealed class TrayContext : ApplicationContext
    {
        private readonly string root;
        private readonly string stopFlag;
        private readonly string trayPid;
        private readonly DateTime installedAt;
        private readonly NotifyIcon tray;
        private readonly System.Windows.Forms.Timer stateTimer;
        private readonly CounterForm counter;
        private Process agent;

        public TrayContext()
        {
            root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            stopFlag = Path.Combine(root, "stop.flag");
            trayPid = Path.Combine(root, "tray.pid");
            installedAt = ReadInstallTime();
            File.WriteAllText(trayPid, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));

            counter = new CounterForm(installedAt);
            counter.FormClosing += delegate(object sender, FormClosingEventArgs args) {
                if (args.CloseReason == CloseReason.UserClosing) {
                    args.Cancel = true;
                    counter.Hide();
                }
            };

            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem open = new ToolStripMenuItem("Open counter");
            open.Click += delegate { ShowCounter(); };
            menu.Items.Add(open);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("KeyHunter training", null, delegate { ShowCounter(); }));

            tray = new NotifyIcon();
            tray.Icon = CreateSubtleTrainingIcon();
            tray.Text = "KeyHunter training";
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            tray.DoubleClick += delegate { ShowCounter(); };

            StartAgentIfNeeded();

            stateTimer = new System.Windows.Forms.Timer();
            stateTimer.Interval = 500;
            stateTimer.Tick += delegate {
                if (File.Exists(stopFlag)) Shutdown();
            };
            stateTimer.Start();
        }

        private DateTime ReadInstallTime()
        {
            string path = Path.Combine(root, "installed-at.txt");
            DateTime parsed;
            if (File.Exists(path) && DateTime.TryParse(File.ReadAllText(path).Trim(), CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out parsed)) return parsed.ToLocalTime();
            return DateTime.Now;
        }

        private void StartAgentIfNeeded()
        {
            string agentPath = Path.Combine(root, "KeyHunter-Agent.ps1");
            if (!File.Exists(agentPath)) return;

            // Always attempt a start. agent.ready can legitimately survive a
            // reboot, while the agent process cannot. The agent's own named
            // mutex makes this idempotent if an instance is already running.

            string skipInjected = "true";
            string settingPath = Path.Combine(root, "skip-injected.txt");
            if (File.Exists(settingPath)) {
                string candidate = File.ReadAllText(settingPath).Trim();
                if (candidate.Equals("false", StringComparison.OrdinalIgnoreCase)) skipInjected = "false";
            }

            string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powerShell;
            start.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
                agentPath.Replace("\"", "\"\"") + "\" -SkipInjected \"" + skipInjected + "\"";
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            agent = Process.Start(start);
        }

        private void ShowCounter()
        {
            counter.RefreshElapsed();
            counter.Show();
            counter.WindowState = FormWindowState.Normal;
            counter.Activate();
        }

        private static Icon CreateSubtleTrainingIcon()
        {
            Bitmap bitmap = new Bitmap(16, 16, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (Graphics graphics = Graphics.FromImage(bitmap))
            using (Pen pen = new Pen(Color.FromArgb(150, 112, 120, 128), 1.0f))
            using (Brush brush = new SolidBrush(Color.FromArgb(120, 112, 120, 128)))
            {
                graphics.Clear(Color.Transparent);
                graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                graphics.DrawEllipse(pen, 5, 5, 6, 6);
                graphics.FillEllipse(brush, 7, 7, 2, 2);
            }
            IntPtr handle = bitmap.GetHicon();
            Icon icon = (Icon)Icon.FromHandle(handle).Clone();
            NativeMethods.DestroyIcon(handle);
            bitmap.Dispose();
            return icon;
        }

        private void Shutdown()
        {
            stateTimer.Stop();
            tray.Visible = false;
            tray.Dispose();
            counter.Dispose();
            try { File.Delete(trayPid); } catch { }
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) {
                if (stateTimer != null) stateTimer.Dispose();
                if (tray != null) tray.Dispose();
                if (counter != null) counter.Dispose();
                try { File.Delete(trayPid); } catch { }
            }
            base.Dispose(disposing);
        }
    }

    internal sealed class CounterForm : Form
    {
        private readonly DateTime installedAt;
        private readonly Label elapsed;
        private readonly Label installed;
        private readonly System.Windows.Forms.Timer timer;

        public CounterForm(DateTime installedAtValue)
        {
            installedAt = installedAtValue;
            Text = "KeyHunter training exercise";
            ClientSize = new Size(430, 205);
            MinimumSize = new Size(430, 205);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(22, 25, 29);
            ForeColor = Color.WhiteSmoke;
            ShowInTaskbar = true;

            Label title = new Label();
            title.Text = "KEYHUNTER TRAINING";
            title.Font = new Font("Segoe UI Semibold", 11.0f, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(60, 220, 190);
            title.Location = new Point(24, 20);
            title.AutoSize = true;
            Controls.Add(title);

            Label caption = new Label();
            caption.Text = "Time since installation";
            caption.Font = new Font("Segoe UI", 9.0f);
            caption.ForeColor = Color.FromArgb(170, 178, 188);
            caption.Location = new Point(26, 57);
            caption.AutoSize = true;
            Controls.Add(caption);

            elapsed = new Label();
            elapsed.Font = new Font("Consolas", 28.0f, FontStyle.Bold);
            elapsed.ForeColor = Color.White;
            elapsed.Location = new Point(22, 76);
            elapsed.Size = new Size(385, 52);
            Controls.Add(elapsed);

            installed = new Label();
            installed.Font = new Font("Segoe UI", 8.5f);
            installed.ForeColor = Color.FromArgb(150, 158, 168);
            installed.Location = new Point(27, 140);
            installed.AutoSize = true;
            installed.Text = "Active since: " + installedAt.ToString("yyyy-MM-dd HH:mm:ss");
            Controls.Add(installed);

            Label hint = new Label();
            hint.Text = "Closing this window hides the counter in the tray.";
            hint.Font = new Font("Segoe UI", 8.0f);
            hint.ForeColor = Color.FromArgb(120, 128, 138);
            hint.Location = new Point(27, 168);
            hint.AutoSize = true;
            Controls.Add(hint);

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 1000;
            timer.Tick += delegate { RefreshElapsed(); };
            timer.Start();
            RefreshElapsed();
        }

        public void RefreshElapsed()
        {
            TimeSpan span = DateTime.Now - installedAt;
            if (span < TimeSpan.Zero) span = TimeSpan.Zero;
            elapsed.Text = string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}:{3:00}",
                (int)span.TotalDays, span.Hours, span.Minutes, span.Seconds);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && timer != null) timer.Dispose();
            base.Dispose(disposing);
        }
    }

    internal static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        internal static extern bool DestroyIcon(IntPtr handle);
    }
}
