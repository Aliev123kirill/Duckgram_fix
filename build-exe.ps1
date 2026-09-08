# Build a standalone Duckgram.exe (self-contained menu launcher).
# Requires: .NET Framework csc.exe (present on Windows). No NuGet/internet needed.
# Usage: powershell -ExecutionPolicy Bypass -File build-exe.ps1
#
# The resulting Duckgram.exe embeds utils/*.ps1 and lists/*.txt as resources,
# writes them to %TEMP%\Duckgram\ at runtime and invokes PowerShell (elevated) to work.
# Hosts apply/remove/verify are done natively in C#.

[CmdletBinding()]
param(
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'

# --- locate .NET Framework csc.exe ---
$csc = $null
foreach ($c in @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))) {
    if ($null -eq $csc -and (Test-Path -LiteralPath $c)) { $csc = $c }
}
if (-not $csc) {
    Write-Host 'Error: .NET Framework csc.exe not found. Cannot build EXE.' -ForegroundColor Red
    exit 1
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $Root 'utils'
$listDir = Join-Path $Root 'lists'

$psFiles = @('telegram-autodetect.ps1','update-ip-candidates.ps1','tg-hosts.ps1','set-console-ttf.ps1','ensure-console-ttf.ps1','_twfcon-types.ps1','twf-console-types-v2.dll')
$listFiles = @('telegram-hosts-domains.txt','telegram-ip-candidates.txt','telegram-cidr-official.txt','telegram-ip-failed.txt')

# --- build the resources dictionary lines ---
$sb = New-Object System.Text.StringBuilder
foreach ($f in $psFiles) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $srcDir $f))
    [void]$sb.AppendLine("            { `"$f`", `"" + [Convert]::ToBase64String($bytes) + "`" },")
}
foreach ($f in $listFiles) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $listDir $f))
    [void]$sb.AppendLine("            { `"$f`", `"" + [Convert]::ToBase64String($bytes) + "`" },")
}

# --- C# source template ---
$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

namespace Duckgram
{
    internal static class Resources
    {
        private static readonly Dictionary<string,string> R =
            new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
        {
__RESOURCES__
        };
        public static string[] Names()
        {
            var k = new string[R.Count]; R.Keys.CopyTo(k, 0); return k;
        }
        public static byte[] Get(string name) { return Convert.FromBase64String(R[name]); }
    }

    internal static class Program
    {
        private const string AppName = "Duckgram";
        private const string Marker = "# duckgram";
        private const string MarkerLegacy = "# telegram-web-fix";
        private static readonly string HostsPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts");
        private static string TempDir = Path.Combine(Path.GetTempPath(), "Duckgram");
        private static string _cfgFile;
        private static string _domainsFile;

        [STAThread]
        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = Encoding.UTF8; } catch { }
            try { Console.Title = AppName; } catch { }

            var exeDir = AppDomain.CurrentDomain.BaseDirectory;
            _cfgFile = Path.Combine(exeDir, "duckgram-ip.cfg");
            if (!File.Exists(_cfgFile)) _cfgFile = Path.Combine(TempDir, "duckgram-ip.cfg");
            _domainsFile = Pick("telegram-hosts-domains.txt", exeDir, TempDir);

            if (Array.IndexOf(args, "enable") >= 0) return Silent(true);
            if (Array.IndexOf(args, "disable") >= 0) return Silent(false);

if (!IsAdmin())
            {
                Console.WriteLine("  " + AppName + ": нужны права администратора (UAC).");
                Elevate(string.Join(" ", CommandLineTail()));
                PressAny();
                return 0;
            }
            EnsureExtracted();
            SetupConsoleFont();
            PrintBanner();
            for (;;)
            {
                PrintMenu();
                string line;
                try { line = Console.ReadLine(); } catch { break; }
                if (line == null) break;
                line = line.Trim();
                string key = "";
                foreach (var ch in line) { if (char.IsDigit(ch)) { key = ch.ToString(); break; } }
                switch (key)
                {
                    case "1": Enable(); break;
                    case "2": Disable(); break;
                    case "3": ShowHosts(); break;
                    case "4": ScanIp(); break;
                    case "5": UpdateList(); break;
                    case "6": AutoSetup(); break;
                    case "0": Console.WriteLine("  Пока."); return 0;
                }
            }
            return 0;
        }

        private static string[] CommandLineTail()
        {
            var a = Environment.GetCommandLineArgs();
            var tail = new string[Math.Max(0, a.Length - 1)];
            for (int i = 0; i < tail.Length; i++) tail[i] = a[i + 1];
            return tail;
        }

        private static string Pick(string name, string exeDir, string altDir)
        {
            var local = Path.Combine(exeDir, name);
            if (File.Exists(local)) return local;
            return Path.Combine(altDir, name);
        }

        private static bool IsAdmin()
        {
            try { using (var id = WindowsIdentity.GetCurrent()) { return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator); } }
            catch { return false; }
        }

        private static void Elevate(string applicationArguments)
        {
            var p = new ProcessStartInfo();
            p.UseShellExecute = true;
            p.FileName = Process.GetCurrentProcess().MainModule.FileName;
            p.Verb = "runas";
            p.Arguments = applicationArguments;
            try { Process.Start(p); } catch { }
        }

        private static void EnsureExtracted()
        {
            try
            {
                Directory.CreateDirectory(TempDir);
                foreach (var name in Resources.Names())
                    File.WriteAllBytes(Path.Combine(TempDir, name), Resources.Get(name));
            }
            catch { }
        }

        private static void SetupConsoleFont()
        {
            // Force a TrueType console font so Cyrillic renders (raster fonts have no glyphs).
            var ttf = Path.Combine(TempDir, "ensure-console-ttf.ps1");
            if (!File.Exists(ttf)) return;
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -Command \"& '" + ttf + "'\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (var p = Process.Start(psi)) { if (p != null) p.WaitForExit(8000); }
            }
            catch { }
        }

        private static string ReadCfg()
        {
            foreach (var path in new[] { _cfgFile, Path.Combine(TempDir, "duckgram-ip.cfg") })
            {
                try
                {
                    if (File.Exists(path))
                        foreach (var ln in File.ReadAllLines(path)) { var t = ln.Trim(); if (IsIp(t)) return t; }
                }
                catch { }
            }
            return null;
        }

        private static void SyncCfgTempToLocal()
        {
            // autodetect.ps1 writes cfg next to itself (TempDir); mirror it to the exe folder.
            try
            {
                var tmp = Path.Combine(TempDir, "duckgram-ip.cfg");
                if (File.Exists(tmp))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(_cfgFile));
                    File.Copy(tmp, _cfgFile, true);
                }
            }
            catch { }
        }

        private static void WriteCfg(string ip)
        {
            try { Directory.CreateDirectory(Path.GetDirectoryName(_cfgFile)); } catch { }
            try { File.WriteAllText(_cfgFile, ip + Environment.NewLine, new UTF8Encoding(false)); } catch { }
        }

        private static bool IsIp(string s) { return s != null && Regex.IsMatch(s, @"^\d{1,3}(\.\d{1,3}){3}$"); }

        private static void PrintBanner()
        {
            Console.WriteLine();
            Console.WriteLine("  ===================================================================");
            Console.WriteLine("      D U C K G R A M   -  web.telegram.org через hosts");
            Console.WriteLine("  ===================================================================");
        }

        private static void PrintMenu()
        {
            var ip = ReadCfg();
            var on = HostsHasFix();
            Console.WriteLine();
            Console.WriteLine("  Состояние:");
            Console.WriteLine("    Фикс ........ " + (on ? "вкл" : "выкл"));
            Console.WriteLine("    IP .......... " + (ip ?? "не задан"));
            Console.WriteLine();
            Console.WriteLine("  Меню:");
            Console.WriteLine("    [1] Включить  - записать fix в hosts");
            Console.WriteLine("    [2] Выключить - убрать наши строки из hosts");
            Console.WriteLine("    [3] Просмотр  - строки про Telegram в hosts");
            Console.WriteLine("    [4] Поиск IP  - проверка DC :443");
            Console.WriteLine("    [5] Обновить список IP (cidr.txt с Telegram)");
            Console.WriteLine("    [6] Авто-настройка - всё сам (поиск+запись+проверка)");
            Console.WriteLine("    [0] Выход");
            Console.Write("  Выбор: > ");
        }

        private static void RunPs(string file, string args)
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + file + "\" " + args;
            psi.UseShellExecute = true;
            try
            {
                using (var p = Process.Start(psi)) { if (p != null) p.WaitForExit(); }
            }
            catch { }
        }

        private static void RunPsVisible(string file, string argLine)
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + file + "\" " + argLine;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = false;
            try
            {
                using (var p = Process.Start(psi)) { if (p != null) p.WaitForExit(); }
            }
            catch { }
        }

        private static void Enable()
        {
            var ip = ReadCfg();
            if (ip == null) { Console.WriteLine("  [!!] Run [4] Scan IP first."); PressAny(); return; }
            Console.WriteLine(ApplyHosts(ip) ? "  [OK] hosts updated" : "  [!!] cannot write hosts");
            if (HostsHasFix()) { try { FlushDns(); Console.WriteLine("  [OK] DNS flushed"); } catch { } }
            PressAny();
        }

        private static void Disable()
        {
            if (!HostsHasFix()) { Console.WriteLine("  No Duckgram lines in hosts - nothing to remove."); PressAny(); return; }
            Console.WriteLine(RemoveHosts() ? "  [OK] lines removed" : "  [!!] cannot write hosts");
            try { FlushDns(); Console.WriteLine("  [OK] DNS flushed"); } catch { }
            PressAny();
        }

        private static void ShowHosts()
        {
            try
            {
                int n = 0;
                foreach (var ln in File.ReadAllLines(HostsPath))
                    if (ln.IndexOf("telegram", StringComparison.OrdinalIgnoreCase) >= 0) { Console.WriteLine("    " + ln); n++; }
                if (n == 0) Console.WriteLine("  No Telegram lines in hosts.");
            }
            catch { Console.WriteLine("  Cannot read hosts."); }
            PressAny();
        }

        private static bool HostsHasFix()
        {
            try
            {
                foreach (var ln in File.ReadAllLines(HostsPath))
                {
                    var t = ln.Trim();
                    if (t == Marker || t == MarkerLegacy) return true;
                    if (Regex.IsMatch(t, "^\\d{1,3}(\\.\\d{1,3}){3}\\s+")) { foreach (var d in ReadDomains()) if (t.Contains(d)) return true; }
                }
            }
            catch { }
            return false;
        }

        private static bool ApplyHosts(string ip)
        {
            try
            {
                UnlockHosts();
                var lines = new List<string>(File.ReadAllLines(HostsPath, Encoding.UTF8));
                RemoveOurLines(lines);
                lines.Add(""); lines.Add(Marker);
                foreach (var d in ReadDomains()) lines.Add(ip + " " + d);
                File.WriteAllLines(HostsPath, lines, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        private static bool RemoveHosts()
        {
            try
            {
                UnlockHosts();
                var lines = new List<string>(File.ReadAllLines(HostsPath, Encoding.UTF8));
                RemoveOurLines(lines);
                File.WriteAllLines(HostsPath, lines, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        private static List<string> ReadDomains()
        {
            var list = new List<string>();
            try { foreach (var ln in File.ReadAllLines(_domainsFile)) { var t = ln.Trim(); if (t.Length > 0 && !t.StartsWith("#") && t.Contains(".")) list.Add(t); } }
            catch { }
            return list;
        }

        private static void RemoveOurLines(List<string> lines)
        {
            var domains = ReadDomains();
            var ipre = new Regex("^\\s*\\d{1,3}(\\.\\d{1,3}){3}\\s+");
            for (int i = lines.Count - 1; i >= 0; i--)
            {
                var t = lines[i].Trim();
                if (t == Marker || t == MarkerLegacy) { lines.RemoveAt(i); continue; }
                if (!ipre.IsMatch(t)) continue;
                foreach (var d in domains)
                {
                    if (t.IndexOf(d, StringComparison.OrdinalIgnoreCase) >= 0) { lines.RemoveAt(i); break; }
                }
            }
        }

        private static void UnlockHosts()
        {
            try { var fi = new FileInfo(HostsPath); if (fi.Exists && fi.IsReadOnly) fi.IsReadOnly = false; } catch { }
        }

        private static void FlushDns()
        {
            try { using (var p = Process.Start(new ProcessStartInfo("ipconfig.exe", "/flushdns") { UseShellExecute = false, CreateNoWindow = true })) { if (p != null) p.WaitForExit(15000); } } catch { }
        }

        private static void ScanIp()
        {
            Console.WriteLine("  Scanning TCP :443 (up to ~1-2 min)...");
            RunPsVisible(Path.Combine(TempDir, "telegram-autodetect.ps1"),
                "-LogFile \"" + Path.Combine(Path.GetTempPath(), "duckgram-scan.log") + "\" -ShowProgress");
            SyncCfgTempToLocal();
            var ip = ReadCfg();
            if (ip != null) Console.WriteLine("  Working IP: " + ip);
            else Console.WriteLine("  No IP found. Try [5], another network or VPN.");
            PressAny();
        }

        private static void UpdateList()
        {
            Console.WriteLine("  Refreshing IP list (cidr.txt from Telegram)...");
            RunPsVisible(Path.Combine(TempDir, "update-ip-candidates.ps1"), "");
            PressAny();
        }

        private static void ScanIpInternal()
        {
            RunPs(Path.Combine(TempDir, "telegram-autodetect.ps1"),
                "-LogFile \"" + Path.Combine(Path.GetTempPath(), "duckgram-scan.log") + "\"");
            SyncCfgTempToLocal();
        }

        private static void AutoSetup()
        {
            Console.WriteLine("  [Auto] Step 1/3: refresh IP list...");
            RunPs(Path.Combine(TempDir, "update-ip-candidates.ps1"), "");
            Console.WriteLine("  [Auto] Step 2/3: scan IP...");
            ScanIpInternal();
            var ip = ReadCfg();
            if (ip == null)
            {
                Console.WriteLine("  [Auto] No IP found - trying refresh + re-scan once...");
                RunPs(Path.Combine(TempDir, "update-ip-candidates.ps1"), "");
                ScanIpInternal();
                ip = ReadCfg();
            }
            if (ip == null)
            {
                Console.WriteLine("  [!!] IP not found - network/VPN/firewall is blocking Telegram DC.");
                PressAny();
                return;
            }
            Console.WriteLine("  [Auto] Working IP: " + ip);
            Console.WriteLine("  [Auto] Step 3/3: write hosts + verify...");
            Console.WriteLine(ApplyHosts(ip) ? "  [OK] hosts updated" : "  [!!] cannot write hosts");
            try { FlushDns(); Console.WriteLine("  [OK] DNS flushed"); } catch { }
            Console.WriteLine("  [Auto] Verify TLS accessibility...");
            CheckFinal(ip);
            Console.WriteLine("  AUTO SETUP DONE. Open web.telegram.org.");
            PressAny();
        }

        private static void CheckFinal(string ip)
        {
            string[] hosts = { "web.telegram.org", "kws2.web.telegram.org" };
            int ok = 0;
            var fail = new List<string>();
            foreach (var h in hosts)
            {
                try
                {
                    using (var c = new TcpClient())
                    {
                        var ar = c.BeginConnect(ip, 443, null, null);
                        if (!ar.AsyncWaitHandle.WaitOne(3000)) { fail.Add(h); continue; }
                        try { c.EndConnect(ar); } catch { fail.Add(h); continue; }
                        if (!c.Connected) { fail.Add(h); continue; }
                        using (var ssl = new SslStream(c.GetStream(), false))
                        {
                            var sar = ssl.BeginAuthenticateAsClient(h, null, null);
                            if (!sar.AsyncWaitHandle.WaitOne(8000)) { fail.Add(h); continue; }
                            try { ssl.EndAuthenticateAsClient(sar); } catch { fail.Add(h); continue; }
                            if (ssl.IsAuthenticated) ok++; else fail.Add(h);
                        }
                    }
                }
                catch { fail.Add(h); }
            }
            Console.WriteLine(ok == hosts.Length ? "  [OK] web.telegram.org and kws2 - TLS OK" : "  [FAIL] failed: " + string.Join(", ", fail));
        }

        private static void PressAny()
        {
            Console.WriteLine();
            Console.Write("  Press any key...");
            try { Console.ReadKey(true); } catch { }
            Console.WriteLine();
        }

        private static int Silent(bool enable)
        {
            if (!IsAdmin())
            {
                Elevate(enable ? "enable" : "disable");
                return 0;
            }
            EnsureExtracted();
            bool ok;
            if (enable) { var ip = ReadCfg(); if (ip == null) return 2; ok = ApplyHosts(ip); }
            else ok = RemoveHosts();
            if (ok) { try { FlushDns(); } catch { } return 0; }
            return 3;
        }
    }
}
'@

# replace placeholder with generated resources
$cs = $cs.Replace('__RESOURCES__', $sb.ToString().TrimEnd())

$srcPath = Join-Path ([System.IO.Path]::GetTempPath()) 'duckgram-src.cs'
# UTF-8 WITH BOM: csc.exe otherwise reads the file as ANSI (CP1251 on Russian Windows)
# and mangles Cyrillic string literals in the compiled EXE.
[System.IO.File]::WriteAllText($srcPath, $cs, (New-Object System.Text.UTF8Encoding($true)))

$outExe = if ($OutDir) { Join-Path $OutDir 'Duckgram.exe' } else { Join-Path $Root 'Duckgram.exe' }

$refs = @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Net.Http.dll')
$argsList = @('/nologo','/target:exe','/optimize+','/platform:anycpu',("/out:" + $outExe))
foreach ($r in $refs) { $argsList += ("/reference:" + $r) }
$argsList += $srcPath

Write-Host ("Compiling with " + $csc) -ForegroundColor Cyan
& $csc $argsList
if ($LASTEXITCODE -ne 0)
{
    Write-Host ("Build failed (csc exit " + $LASTEXITCODE + ").") -ForegroundColor Red
    exit $LASTEXITCODE
}

Remove-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("Build OK: " + $outExe + "  (" + (Get-Item -LiteralPath $outExe).Length + " bytes)") -ForegroundColor Green
Write-Host ("Run:  " + $outExe + "   (or enable/disable for silent mode)") -ForegroundColor Gray
exit 0
