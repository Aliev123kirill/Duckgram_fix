using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    private const string TrayName = "Duckgram Fix Plus Tray";
    private const string FixExeName = "Duckgram fix plus.exe";

    private static NotifyIcon _tray;
    private static readonly List<Process> _openUi = new List<Process>();
    private static string _baseDir;

    [STAThread]
    private static int Main()
    {
        bool createdNew;
        using (var mutex = new Mutex(true, "DuckgramFixPlusTrayMutex", out createdNew))
        {
            if (!createdNew) return 0;

            _baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string exe = Path.Combine(_baseDir, FixExeName);
            if (!File.Exists(exe))
            {
                MessageBox.Show("Не найден файл " + FixExeName + " рядом с треем.", TrayName,
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 1;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            _tray = new NotifyIcon
            {
                Icon = MakeIcon(),
                Text = "Duckgram Fix Plus",
                Visible = true
            };

            var menu = new ContextMenuStrip();
            menu.Items.Add("Открыть fix", null, (s, e) => OpenFix());
            menu.Items.Add("Остановить", null, (s, e) => StopFix());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Закрыть", null, (s, e) => Application.Exit());
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => OpenFix();

            Application.Run();

            _tray.Visible = false;
            _tray.Dispose();
            KillUi();
            return 0;
        }
    }

    private static void OpenFix()
    {
        string exe = Path.Combine(_baseDir, FixExeName);
        if (!File.Exists(exe))
        {
            Balloon("Ошибка", "Файл " + FixExeName + " не найден.", ToolTipIcon.Error);
            return;
        }
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                WorkingDirectory = _baseDir,
                UseShellExecute = true,
                Verb = "runas"
            };
            Process p = Process.Start(psi);
            if (p != null)
            {
                lock (_openUi) _openUi.Add(p);
                p.EnableRaisingEvents = true;
                p.Exited += (s2, e2) => { lock (_openUi) _openUi.Remove(p); };
            }
        }
        catch
        {
            Balloon("Ошибка", "Не удалось запустить fix (UAC отменён?).", ToolTipIcon.Warning);
        }
    }

    private static void StopFix()
    {
        string exe = Path.Combine(_baseDir, FixExeName);
        if (!File.Exists(exe))
        {
            Balloon("Ошибка", "Файл " + FixExeName + " не найден.", ToolTipIcon.Error);
            return;
        }
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "disable-silent",
                WorkingDirectory = _baseDir,
                UseShellExecute = true,
                Verb = "runas"
            };
            using (Process p = Process.Start(psi))
            {
                if (p != null)
                {
                    if (!p.WaitForExit(60000))
                    {
                        Balloon("Duckgram", "Остановка fix: превышен таймаут (UAC не подтверждён?).", ToolTipIcon.Warning);
                        return;
                    }
                    if (p.ExitCode == 0)
                        Balloon("Duckgram", "Fix остановлен — записи удалены из hosts, DNS сброшен.", ToolTipIcon.Info);
                    else
                        Balloon("Duckgram", "Не удалось остановить fix (код " + p.ExitCode + ").", ToolTipIcon.Error);
                }
            }
        }
        catch
        {
            Balloon("Ошибка", "Не удалось остановить fix (UAC отменён?).", ToolTipIcon.Warning);
        }
    }

    private static void Balloon(string title, string text, ToolTipIcon iconKind)
    {
        if (_tray == null) return;
        try { _tray.ShowBalloonTip(4000, title, text, iconKind); } catch { }
    }

    private static void KillUi()
    {
        List<Process> copy;
        lock (_openUi) copy = new List<Process>(_openUi);
        foreach (Process p in copy)
        {
            try { if (!p.HasExited) p.Kill(); } catch { }
        }
    }

    private static Icon MakeIcon()
    {
        using (var bmp = new Bitmap(32, 32))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var br = new SolidBrush(Color.FromArgb(41, 128, 235)))
                    g.FillEllipse(br, 1, 1, 30, 30);
                using (var f = new Font("Segoe UI", 18, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var wb = new SolidBrush(Color.White))
                {
                    var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                    g.DrawString("D", f, wb, new RectangleF(0, 0, 32, 32), sf);
                    sf.Dispose();
                }
            }
            IntPtr h = bmp.GetHicon();
            try
            {
                using (var ic = Icon.FromHandle(h))
                    return (Icon)ic.Clone();
            }
            finally
            {
                DestroyIcon(h);
            }
        }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);
}