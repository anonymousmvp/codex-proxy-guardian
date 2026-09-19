using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class SetupProgram {
    internal static readonly string[] ResourceNames = { "Guardian.exe", "install.ps1", "uninstall.ps1", "Config.psm1", "Certificate.psm1" };

    [STAThread]
    private static int Main(string[] args) {
        // Developer verification extracts the exact payload without installing anything.
        if (args.Length == 2 && args[0] == "--verify-package") {
            try { Extract(args[1]); File.WriteAllText(Path.Combine(args[1], "verified.txt"), "Package extracted successfully."); return 0; }
            catch { return 1; }
        }
        // Silent mode for scripts and checks: --install|--uninstall [--skip-certificate] [-- <script parameters>]
        if (args.Length >= 1 && (args[0] == "--install" || args[0] == "--uninstall")) {
            bool skipCertificate = false;
            var extra = new List<string>();
            for (int i = 1; i < args.Length; i++) {
                if (args[i] == "--skip-certificate") skipCertificate = true;
                else if (args[i] == "--") { extra.AddRange(args.Skip(i + 1)); break; }
                else return 2;
            }
            SetupResult result = args[0] == "--install"
                ? SetupActions.Install(extra, !skipCertificate)
                : SetupActions.Uninstall(extra, !skipCertificate);
            return result.Succeeded ? 0 : 1;
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

    internal static string RelativePath(string name) {
        return name.EndsWith(".psm1", StringComparison.OrdinalIgnoreCase) ? Path.Combine("scripts", name) : name;
    }

    internal static void Extract(string directory) {
        directory = Path.GetFullPath(directory);
        if (Directory.Exists(directory)) throw new IOException("Extraction directory already exists.");
        Directory.CreateDirectory(Path.Combine(directory, "scripts"));
        foreach (string name in ResourceNames) {
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                if (resource == null || resource.Length == 0) throw new IOException("Missing embedded file: " + name);
                using (var output = new FileStream(Path.Combine(directory, RelativePath(name)), FileMode.CreateNew, FileAccess.Write)) resource.CopyTo(output);
            }
        }
    }
}

internal sealed class SetupResult {
    public bool Succeeded;
    public bool CertificatePending;
    public string Message = "";
    public string LogPath;
}

internal sealed class SetupState {
    public bool Installed;
    public int Port;
    public bool Running;
    public bool Trusted;
    public string Thumbprint;
}

internal sealed class GuardianSettingsFile {
    public int Port { get; set; }
    public string Route { get; set; }
    public string CodexConfigDirectory { get; set; }
    public string CertificateThumbprint { get; set; }
}

internal static class CertificateStore {
    static X509Certificate2Collection Find(StoreName name, string thumbprint, OpenFlags flags, out X509Store store) {
        store = new X509Store(name, StoreLocation.CurrentUser);
        store.Open(flags);
        return store.Certificates.Find(X509FindType.FindByThumbprint, thumbprint, false);
    }

    internal static bool IsTrusted(string thumbprint) {
        X509Store store;
        try { return Find(StoreName.Root, thumbprint, OpenFlags.ReadOnly, out store).Count > 0; }
        catch { return false; }
    }

    // Windows shows its own confirmation before a certificate enters the user's root store.
    internal static void Trust(string thumbprint) {
        X509Store personal;
        X509Certificate2Collection found = Find(StoreName.My, thumbprint, OpenFlags.ReadOnly, out personal);
        using (personal) {
            if (found.Count == 0) throw new InvalidOperationException("The local certificate was not created.");
            if (IsTrusted(thumbprint)) return;
            var publicPart = new X509Certificate2(found[0].Export(X509ContentType.Cert));
            using (var root = new X509Store(StoreName.Root, StoreLocation.CurrentUser)) {
                root.Open(OpenFlags.ReadWrite);
                root.Add(publicPart);
            }
        }
        if (!IsTrusted(thumbprint)) throw new InvalidOperationException("The certificate was not added to the trusted root store.");
    }

    internal static void Remove(string thumbprint) {
        foreach (StoreName name in new[] { StoreName.Root, StoreName.My }) {
            X509Store store;
            X509Certificate2Collection found = Find(name, thumbprint, OpenFlags.ReadWrite, out store);
            using (store) { foreach (X509Certificate2 certificate in found) store.Remove(certificate); }
        }
        if (IsTrusted(thumbprint)) throw new InvalidOperationException("The certificate is still trusted.");
    }
}

internal static class SetupActions {
    internal static readonly string DefaultInstallDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "CodexProxyGuardian");

    internal static string InstallDirectoryFrom(IList<string> extra) {
        for (int i = 0; i + 1 < extra.Count; i++) {
            if (extra[i].Equals("-InstallDirectory", StringComparison.OrdinalIgnoreCase)) return Path.GetFullPath(extra[i + 1]);
        }
        return DefaultInstallDirectory;
    }

    internal static GuardianSettingsFile ReadSettings(string installDirectory) {
        string path = Path.Combine(installDirectory, "settings.json");
        if (!File.Exists(path)) return null;
        try { return new JavaScriptSerializer().Deserialize<GuardianSettingsFile>(File.ReadAllText(path)); }
        catch { return null; }
    }

    internal static SetupState Detect(string installDirectory) {
        var state = new SetupState();
        GuardianSettingsFile settings = ReadSettings(installDirectory);
        if (settings == null) return state;
        state.Installed = true;
        state.Port = settings.Port;
        state.Thumbprint = settings.CertificateThumbprint;
        string executable = Path.Combine(installDirectory, "CodexProxyGuardian.exe");
        foreach (Process process in Process.GetProcessesByName("CodexProxyGuardian")) {
            try { if (string.Equals(process.MainModule.FileName, executable, StringComparison.OrdinalIgnoreCase)) state.Running = true; }
            catch { }
            finally { process.Dispose(); }
        }
        state.Trusted = !string.IsNullOrEmpty(state.Thumbprint) && CertificateStore.IsTrusted(state.Thumbprint);
        return state;
    }

    static string Quote(IEnumerable<string> values) {
        var text = new StringBuilder();
        foreach (string value in values) text.Append(" \"").Append(value.Replace("\"", "\\\"")).Append('"');
        return text.ToString();
    }

    static string PowerShellPath() {
        // A 32-bit host would be redirected to the 32-bit PowerShell; keep the native one.
        string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative")
            : Environment.GetFolderPath(Environment.SpecialFolder.System);
        return Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    static int RunScript(string script, string arguments, string logPath, string label) {
        var start = new ProcessStartInfo {
            FileName = PowerShellPath(),
            Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File \"" + script + "\"" + arguments,
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
            if (!child.WaitForExit(180000)) { child.Kill(); throw new TimeoutException(label + " exceeded 3 minutes."); }
            output = stdout.GetAwaiter().GetResult();
            error = stderr.GetAwaiter().GetResult();
            result = child.ExitCode;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(logPath));
        File.AppendAllText(logPath, "==== " + label + " " + DateTime.UtcNow.ToString("o") + " exit=" + result + Environment.NewLine + output + Environment.NewLine + error + Environment.NewLine, new UTF8Encoding(false));
        return result;
    }

    static string ExtractPayload() {
        string payload = Path.Combine(Path.GetTempPath(), "CodexProxyGuardian-Setup-" + Guid.NewGuid().ToString("N"));
        SetupProgram.Extract(payload);
        return payload;
    }

    static void LogFailure(string logPath, Exception ex) {
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));
            File.AppendAllText(logPath, DateTime.UtcNow.ToString("o") + " " + ex + Environment.NewLine, new UTF8Encoding(false));
        } catch { }
    }

    internal static SetupResult Install(IList<string> extra, bool trustCertificate) {
        string installDirectory = InstallDirectoryFrom(extra);
        var result = new SetupResult { LogPath = Path.Combine(installDirectory, "setup.log") };
        try {
            string payload = ExtractPayload();
            Directory.CreateDirectory(installDirectory);
            string arguments = " -PrebuiltExecutable \"" + Path.Combine(payload, "Guardian.exe") + "\" -SkipCertificateTrust" + Quote(extra);
            if (RunScript(Path.Combine(payload, "install.ps1"), arguments, result.LogPath, "install") != 0) {
                result.Message = "安装未完成，请点击“查看日志”了解原因。";
                return result;
            }
            // Keep a local uninstaller and its modules; the temporary payload is never an autostart dependency.
            Directory.CreateDirectory(Path.Combine(installDirectory, "scripts"));
            foreach (string name in SetupProgram.ResourceNames) {
                if (name == "Guardian.exe" || name == "install.ps1") continue;
                File.Copy(Path.Combine(payload, SetupProgram.RelativePath(name)), Path.Combine(installDirectory, SetupProgram.RelativePath(name)), true);
            }
            if (trustCertificate) {
                GuardianSettingsFile settings = ReadSettings(installDirectory);
                if (settings == null || string.IsNullOrEmpty(settings.CertificateThumbprint)) throw new InvalidOperationException("settings.json has no certificate thumbprint.");
                result.CertificatePending = true;
                CertificateStore.Trust(settings.CertificateThumbprint);
                result.CertificatePending = false;
            }
            result.Succeeded = true;
            result.Message = "安装完成。请完整退出并重新打开 Codex，之后继续使用原来的图标；请保持 Windows 系统代理开启。";
        } catch (Exception ex) {
            LogFailure(result.LogPath, ex);
            result.Message = result.CertificatePending
                ? "文件和自启动已安装，但本机证书没有被信任，Codex 暂时无法通过本程序连接。请再次点击“安装 / 升级”并在 Windows 提示时选择“是”，或点击“卸载”。"
                : "安装未完成：" + ex.Message;
        }
        return result;
    }

    internal static SetupResult Uninstall(IList<string> extra, bool removeCertificate) {
        string installDirectory = InstallDirectoryFrom(extra);
        var result = new SetupResult { LogPath = Path.Combine(installDirectory, "setup.log") };
        try {
            GuardianSettingsFile settings = ReadSettings(installDirectory);
            if (settings == null) { result.Message = "没有找到已安装的守护程序，无需卸载。"; return result; }
            string payload = ExtractPayload();
            string arguments = " -SkipCertificateRemoval -RemoveFiles" + Quote(extra);
            if (RunScript(Path.Combine(payload, "uninstall.ps1"), arguments, result.LogPath, "uninstall") != 0) {
                result.Message = "卸载未完成，请点击“查看日志”了解原因。";
                return result;
            }
            if (removeCertificate && !string.IsNullOrEmpty(settings.CertificateThumbprint)) {
                result.CertificatePending = true;
                CertificateStore.Remove(settings.CertificateThumbprint);
                result.CertificatePending = false;
            }
            result.Succeeded = true;
            result.Message = "卸载完成。Codex 已恢复原来的连接方式，请完整退出并重新打开 Codex。配置备份保留在 " + Path.Combine(installDirectory, "backups") + "。";
        } catch (Exception ex) {
            LogFailure(result.LogPath, ex);
            result.Message = result.CertificatePending
                ? "程序已卸载，但本机证书 “Codex Proxy Guardian” 仍保留在当前用户的证书存储中。可再次点击“卸载”并在 Windows 提示时选择“是”，或在 certmgr.msc 中手动删除。"
                : "卸载未完成：" + ex.Message;
        }
        return result;
    }
}

internal sealed class SetupWindow : Form {
    private readonly Label title = new Label();
    private readonly Label status = new Label();
    private readonly Label detail = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button install = new Button();
    private readonly Button uninstall = new Button();
    private readonly Button logs = new Button();
    private readonly Button close = new Button();
    private bool busy;
    private string logPath = Path.Combine(SetupActions.DefaultInstallDirectory, "setup.log");

    internal SetupWindow() {
        Text = "Codex 代理守护程序";
        ClientSize = new Size(620, 380);
        Font = new Font("Microsoft YaHei UI", 10F);
        BackColor = Color.White;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        title.SetBounds(28, 22, 560, 40);
        title.Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold);
        title.Text = "Codex 代理守护程序";
        status.SetBounds(30, 68, 560, 26);
        status.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
        detail.SetBounds(30, 100, 560, 190);
        detail.Text = "安装 / 升级：把守护程序安装到当前 Windows 用户并设置登录自启动，让 Codex 的模型对话、远程控制和内置连接器都经过 Windows 系统代理。"
            + "安装过程中 Windows 会询问是否安装本机证书“Codex Proxy Guardian”，请选择“是”。\r\n\r\n"
            + "卸载：停止后台程序，删除自启动任务和本机证书，并把 Codex 配置恢复原样（配置备份保留）。\r\n\r\n"
            + "安装或卸载之后，请完整退出并重新打开 Codex。";
        progress.SetBounds(30, 296, 560, 8);
        progress.Style = ProgressBarStyle.Marquee;
        progress.Visible = false;
        install.SetBounds(30, 322, 150, 36);
        install.Text = "安装 / 升级";
        install.Click += async delegate { await RunInstall(); };
        uninstall.SetBounds(192, 322, 120, 36);
        uninstall.Text = "卸载";
        uninstall.Click += async delegate { await RunUninstall(); };
        logs.SetBounds(350, 322, 120, 36);
        logs.Text = "查看日志";
        logs.Click += delegate {
            if (File.Exists(logPath)) Process.Start(new ProcessStartInfo("notepad.exe", "\"" + logPath + "\"") { UseShellExecute = true });
            else MessageBox.Show(this, "还没有安装日志。", Text);
        };
        close.SetBounds(482, 322, 108, 36);
        close.Text = "关闭";
        close.Click += delegate { Close(); };
        Controls.AddRange(new Control[] { title, status, detail, progress, install, uninstall, logs, close });
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
        Shown += delegate { RefreshState(); };
    }

    private void RefreshState() {
        SetupState state = SetupActions.Detect(SetupActions.DefaultInstallDirectory);
        if (!state.Installed) {
            status.Text = "当前状态：未安装";
            uninstall.Enabled = false;
        } else {
            status.Text = "当前状态：已安装（本机端口 " + state.Port + "）· 后台程序" + (state.Running ? "运行中" : "未运行")
                + " · 证书" + (state.Trusted ? "已信任" : "未信任");
            uninstall.Enabled = true;
        }
        logs.Enabled = File.Exists(logPath);
    }

    private void SetBusy(bool value, string message) {
        busy = value;
        progress.Visible = value;
        install.Enabled = !value;
        uninstall.Enabled = !value;
        close.Enabled = !value;
        status.Text = message;
    }

    private async Task RunInstall() {
        SetBusy(true, "正在安装，请稍候……Windows 询问是否安装证书时请选择“是”。");
        // The script runs in the background; the certificate prompt is raised from the UI thread so it stays in front.
        SetupResult result = await Task.Run(() => SetupActions.Install(new string[0], false));
        if (result.Succeeded) {
            GuardianSettingsFile settings = SetupActions.ReadSettings(SetupActions.DefaultInstallDirectory);
            try {
                if (settings == null || string.IsNullOrEmpty(settings.CertificateThumbprint)) throw new InvalidOperationException("settings.json has no certificate thumbprint.");
                CertificateStore.Trust(settings.CertificateThumbprint);
            } catch (Exception ex) {
                result.Succeeded = false;
                result.Message = "文件和自启动已安装，但本机证书没有被信任（" + ex.Message + "）。Codex 暂时无法通过本程序连接：请再次点击“安装 / 升级”并在 Windows 提示时选择“是”，或点击“卸载”。";
            }
        }
        Finish(result, "安装完成", "安装未完成");
    }

    private async Task RunUninstall() {
        SetBusy(true, "正在卸载，请稍候……Windows 询问是否删除证书时请选择“是”。");
        GuardianSettingsFile settings = SetupActions.ReadSettings(SetupActions.DefaultInstallDirectory);
        SetupResult result = await Task.Run(() => SetupActions.Uninstall(new string[0], false));
        if (result.Succeeded && settings != null && !string.IsNullOrEmpty(settings.CertificateThumbprint)) {
            try { CertificateStore.Remove(settings.CertificateThumbprint); }
            catch (Exception ex) {
                result.Message = "程序已卸载，但本机证书 “Codex Proxy Guardian” 没有被删除（" + ex.Message + "）。可在 certmgr.msc 的“受信任的根证书颁发机构”和“个人”中手动删除。";
            }
        }
        Finish(result, "卸载完成", "卸载未完成");
    }

    private void Finish(SetupResult result, string succeeded, string failed) {
        SetBusy(false, "");
        detail.Text = result.Message;
        RefreshState();
        status.Text = (result.Succeeded ? succeeded : failed) + " · " + status.Text.Replace("当前状态：", "");
        logs.Enabled = File.Exists(logPath);
    }
}
