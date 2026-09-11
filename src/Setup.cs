using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class SetupProgram {
    internal static readonly string[] ResourceNames = { "Guardian.exe", "install.ps1", "uninstall.ps1", "Config.psm1" };

    [STAThread]
    private static int Main(string[] args) {
        // Developer verification extracts the exact payload without installing anything.
        if (args.Length == 2 && args[0] == "--verify-package") {
            try { Extract(args[1]); File.WriteAllText(Path.Combine(args[1], "verified.txt"), "Package extracted successfully."); return 0; }
            catch { return 1; }
        }
        if (args.Length != 0) return 2;
        bool first;
        using (var singleton = new Mutex(true, "Local\\CodexProxyGuardian-Setup", out first)) {
            if (!first) return 0;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupWindow());
        }
        return 0;
    }

    internal static void Extract(string directory) {
        directory = Path.GetFullPath(directory);
        if (Directory.Exists(directory)) throw new IOException("Extraction directory already exists.");
        Directory.CreateDirectory(Path.Combine(directory, "scripts"));
        foreach (string name in ResourceNames) {
            string relative = name == "Config.psm1" ? Path.Combine("scripts", name) : name;
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                if (resource == null || resource.Length == 0) throw new IOException("Missing embedded file: " + name);
                using (var output = new FileStream(Path.Combine(directory, relative), FileMode.CreateNew, FileAccess.Write)) resource.CopyTo(output);
            }
        }
    }
}

internal sealed class SetupWindow : Form {
    private readonly Label title = new Label();
    private readonly Label detail = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button finish = new Button();
    private readonly Button logs = new Button();
    private bool installing = true;
    private string logPath;

    internal SetupWindow() {
        Text = "Codex 代理守护程序安装";
        ClientSize = new Size(550, 270);
        Font = new Font("Microsoft YaHei UI", 10F);
        BackColor = Color.White;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        title.SetBounds(28, 25, 490, 40);
        title.Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold);
        title.Text = "正在安装 Codex 代理守护程序";
        detail.SetBounds(30, 80, 490, 90);
        detail.Text = "正在配置当前 Windows 用户的后台程序和登录自启动。\r\n请稍候，无需打开命令行。";
        progress.SetBounds(30, 172, 490, 10);
        progress.Style = ProgressBarStyle.Marquee;
        finish.SetBounds(398, 210, 120, 34);
        finish.Text = "关闭";
        finish.Enabled = false;
        finish.Click += delegate { Close(); };
        logs.SetBounds(258, 210, 128, 34);
        logs.Text = "查看安装日志";
        logs.Visible = false;
        logs.Click += delegate {
            if (logPath != null && File.Exists(logPath)) Process.Start(new ProcessStartInfo("notepad.exe", "\"" + logPath + "\"") { UseShellExecute = true });
        };
        Controls.AddRange(new Control[] { title, detail, progress, finish, logs });
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (installing) e.Cancel = true; };
        Shown += async delegate {
            bool succeeded = await Task.Run(() => Install());
            installing = false;
            progress.Style = ProgressBarStyle.Blocks;
            progress.Value = 100;
            finish.Enabled = true;
            logs.Visible = logPath != null && File.Exists(logPath);
            title.Text = succeeded ? "安装完成" : "安装未完成";
            detail.Text = succeeded
                ? "请完整退出并重新打开 Codex。以后继续使用原来的图标。\r\n守护程序会在登录 Windows 后自动运行。\r\n请保持 Windows 系统代理开启。"
                : "请查看安装日志中的具体原因。\r\n本安装包需要 Windows 和 .NET Framework 4.8。";
        };
    }

    private bool Install() {
        try {
            string payload = Path.Combine(Path.GetTempPath(), "CodexProxyGuardian-Setup-" + Guid.NewGuid().ToString("N"));
            SetupProgram.Extract(payload);
            string destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "CodexProxyGuardian");
            Directory.CreateDirectory(destination);
            logPath = Path.Combine(destination, "setup.log");
            var start = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File \"" + Path.Combine(payload, "install.ps1") + "\" -PrebuiltExecutable \"" + Path.Combine(payload, "Guardian.exe") + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            string output, error;
            int result;
            using (Process child = Process.Start(start)) {
                Task<string> stdout = child.StandardOutput.ReadToEndAsync();
                Task<string> stderr = child.StandardError.ReadToEndAsync();
                if (!child.WaitForExit(180000)) { child.Kill(); throw new TimeoutException("Installation exceeded 3 minutes."); }
                output = stdout.GetAwaiter().GetResult();
                error = stderr.GetAwaiter().GetResult();
                result = child.ExitCode;
            }
            File.WriteAllText(logPath, DateTime.UtcNow.ToString("o") + Environment.NewLine + output + Environment.NewLine + error, new UTF8Encoding(false));
            if (result != 0) return false;
            // Keep a local uninstaller and its module; the temporary payload is never an autostart dependency.
            Directory.CreateDirectory(Path.Combine(destination, "scripts"));
            File.Copy(Path.Combine(payload, "uninstall.ps1"), Path.Combine(destination, "uninstall.ps1"), true);
            File.Copy(Path.Combine(payload, "scripts", "Config.psm1"), Path.Combine(destination, "scripts", "Config.psm1"), true);
            return true;
        } catch (Exception ex) {
            if (logPath == null) logPath = Path.Combine(Path.GetTempPath(), "CodexProxyGuardian-Setup-error.log");
            try { File.AppendAllText(logPath, ex.ToString()); } catch { }
            return false;
        }
    }
}
