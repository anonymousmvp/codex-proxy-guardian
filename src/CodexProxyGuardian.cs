// Codex-only reverse tunnel. No registry writes, process injection, or TLS interception.
// Build: .NET Framework csc /target:winexe /r:System.Web.Extensions.dll
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32;

public sealed class GuardianSettings {
    public int Port { get; set; }
    public string Route { get; set; }
}

public static class CodexProxyGuardian {
    static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
    static readonly object LogLock = new object();
    static readonly SemaphoreSlim Slots = new SemaphoreSlim(64);
    static GuardianSettings Settings;
    static long Requests, Upgrades, Failures, RemoteRequests, RemoteUpgrades;
    const string Destination = "chatgpt.com";

    [STAThread]
    public static int Main(string[] args) {
        try {
            Settings = new JavaScriptSerializer().Deserialize<GuardianSettings>(
                File.ReadAllText(Path.Combine(Root, "settings.json")));
            if (Settings == null || Settings.Port < 1024 || Settings.Port > 65535 ||
                Settings.Route == null || Settings.Route.Length < 32 ||
                !Settings.Route.All(Uri.IsHexDigit)) throw new Exception("Invalid settings");
        } catch (Exception ex) { Log("fatal", ex.GetType().Name); return 1; }
        bool first;
        using (var mutex = new Mutex(true, "Local\\CodexProxyGuardian-" + Settings.Port, out first)) {
            if (!first) return 0;
            try {
                Run().GetAwaiter().GetResult();
                return 0;
            } catch (Exception ex) { Log("fatal", ex.GetType().Name); return 1; }
        }
    }

    static async Task Run() {
        var listener = new TcpListener(IPAddress.Loopback, Settings.Port);
        listener.Server.ExclusiveAddressUse = true;
        listener.Start(64);
        Log("started", "127.0.0.1:" + Settings.Port);
        while (true) {
            var incoming = await listener.AcceptTcpClientAsync();
            if (!Slots.Wait(0)) { incoming.Close(); continue; }
            incoming.NoDelay = true;
            // Connection failures are handled inside Handle; the process remains available.
            var ignored = Handle(incoming);
        }
    }

    sealed class Header {
        public string Text;
        public byte[] Remainder;
    }

    static async Task<Header> ReadHeader(Stream stream) {
        using (var collected = new MemoryStream()) {
            var buffer = new byte[4096];
            while (collected.Length <= 65536) {
                var read = stream.ReadAsync(buffer, 0, buffer.Length);
                if (await Task.WhenAny(read, Task.Delay(20000)) != read)
                    throw new TimeoutException("Header timeout");
                int count = await read;
                if (count == 0) throw new EndOfStreamException();
                long before = collected.Length;
                collected.Write(buffer, 0, count);
                var data = collected.GetBuffer();
                for (int i = (int)Math.Max(0, before - 3); i + 3 < collected.Length; i++) {
                    if (data[i] == 13 && data[i+1] == 10 && data[i+2] == 13 && data[i+3] == 10) {
                        int end = i + 4;
                        var remainder = new byte[collected.Length - end];
                        Buffer.BlockCopy(data, end, remainder, 0, remainder.Length);
                        return new Header { Text = Encoding.ASCII.GetString(data, 0, end), Remainder = remainder };
                    }
                }
            }
        }
        throw new IOException("Header too large");
    }

    static async Task Connect(TcpClient client, string host, int port) {
        var attempt = client.ConnectAsync(host, port);
        if (await Task.WhenAny(attempt, Task.Delay(15000)) != attempt)
            throw new TimeoutException("Connect timeout");
        await attempt;
    }

    static Uri ReadSystemProxy() {
        using (var key = Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Internet Settings")) {
            if (key != null && Convert.ToInt32(key.GetValue("ProxyEnable", 0)) == 1) {
                string server = Convert.ToString(key.GetValue("ProxyServer", "")).Trim();
                if (server.Contains("=")) {
                    string https = null, http = null;
                    foreach (string item in server.Split(';')) {
                        string[] pair = item.Split(new char[] {'='}, 2);
                        if (pair.Length != 2) continue;
                        if (pair[0].Trim().Equals("https", StringComparison.OrdinalIgnoreCase)) https = pair[1].Trim();
                        if (pair[0].Trim().Equals("http", StringComparison.OrdinalIgnoreCase)) http = pair[1].Trim();
                    }
                    server = https ?? http;
                }
                if (String.IsNullOrWhiteSpace(server)) throw new IOException("System proxy is incomplete");
                if (!server.Contains("://")) server = "http://" + server;
                var proxy = new Uri(server);
                if (proxy.Scheme != "http" || !String.IsNullOrEmpty(proxy.UserInfo))
                    throw new IOException("Only HTTP CONNECT system proxies are supported");
                return proxy;
            }
            if (key != null && !String.IsNullOrWhiteSpace(Convert.ToString(key.GetValue("AutoConfigURL", ""))))
                throw new IOException("PAC-only configuration is not supported");
        }
        // Fail closed instead of silently attempting direct access when the proxy is off.
        throw new IOException("Windows system proxy is disabled");
    }

    static async Task Send(Stream stream, string text) {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        await stream.WriteAsync(bytes, 0, bytes.Length);
    }

    static async Task Reply(Stream stream, int code, string message) {
        byte[] body = Encoding.UTF8.GetBytes(message);
        string reason = code == 400 ? "Bad Request" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : "Bad Gateway";
        await Send(stream, "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n");
        await stream.WriteAsync(body, 0, body.Length);
    }

    static string GetUpstreamPath(string target, string route) {
        string prefix = "/" + route + "/backend-api";
        if (!(target.StartsWith(prefix + "/", StringComparison.Ordinal) || target == prefix)) return null;
        return target.Substring(route.Length + 1);
    }

    static async Task Handle(TcpClient incoming) {
        bool responseStarted = false;
        TcpClient remote = null;
        SslStream secure = null;
        try {
            var local = incoming.GetStream();
            Header request = await ReadHeader(local);
            string[] lines = request.Text.Split(new string[] {"\r\n"}, StringSplitOptions.None);
            string[] first = lines[0].Split(' ');
            if (first.Length != 3 || !first[2].Equals("HTTP/1.1")) {
                await Reply(local, 400, "HTTP/1.1 required"); return;
            }
            // This listener is not a forward proxy and never accepts arbitrary destinations.
            string path = GetUpstreamPath(first[1], Settings.Route);
            if (path == null) {
                await Reply(local, 404, "Not found"); return;
            }
            bool remoteControl = path.StartsWith("/backend-api/wham/remote/control/", StringComparison.Ordinal);
            var headers = new List<KeyValuePair<string,string>>();
            bool upgrade = false;
            foreach (string line in lines.Skip(1)) {
                if (line.Length == 0) continue;
                int colon = line.IndexOf(':');
                if (colon <= 0) { await Reply(local, 400, "Invalid header"); return; }
                string name = line.Substring(0, colon).Trim();
                string value = line.Substring(colon+1).Trim();
                if (name.Equals("Origin", StringComparison.OrdinalIgnoreCase)) {
                    await Reply(local, 403, "Browser-origin requests are not accepted"); return;
                }
                if (name.Equals("Upgrade", StringComparison.OrdinalIgnoreCase) && value.Equals("websocket", StringComparison.OrdinalIgnoreCase)) upgrade = true;
                headers.Add(new KeyValuePair<string,string>(name,value));
            }
            Interlocked.Increment(ref Requests);
            if (remoteControl) Interlocked.Increment(ref RemoteRequests);
            Uri proxy = ReadSystemProxy();
            remote = new TcpClient();
            remote.NoDelay = true;
            await Connect(remote, proxy.Host, proxy.Port);
            var transport = remote.GetStream();
            await Send(transport, "CONNECT " + Destination + ":443 HTTP/1.1\r\nHost: " + Destination + ":443\r\n\r\n");
            Header connected = await ReadHeader(transport);
            string[] connectLine = connected.Text.Split('\r')[0].Split(' ');
            if (connectLine.Length < 2 || connectLine[1] != "200" || connected.Remainder.Length != 0)
                throw new IOException("System proxy refused CONNECT");
            // Default SslStream validation: certificate chain + chatgpt.com hostname.
            secure = new SslStream(transport, false);
            var tls = secure.AuthenticateAsClientAsync(Destination, null, SslProtocols.Tls12, true);
            if (await Task.WhenAny(tls, Task.Delay(20000)) != tls) throw new TimeoutException("TLS timeout");
            await tls;
            var outgoing = new StringBuilder(first[0] + " " + path + " HTTP/1.1\r\nHost: " + Destination + "\r\n");
            foreach (var header in headers) {
                string name = header.Key;
                if (name.Equals("Host", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("Proxy-Authorization", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("Proxy-Connection", StringComparison.OrdinalIgnoreCase) ||
                    (!upgrade && name.Equals("Connection", StringComparison.OrdinalIgnoreCase))) continue;
                outgoing.Append(name).Append(": ").Append(header.Value).Append("\r\n");
            }
            if (!upgrade) outgoing.Append("Connection: close\r\n");
            outgoing.Append("\r\n");
            await Send(secure, outgoing.ToString());
            if (request.Remainder.Length > 0) await secure.WriteAsync(request.Remainder, 0, request.Remainder.Length);
            Log("connected", "proxy=" + proxy.Host + ":" + proxy.Port + " websocket=" + upgrade + " remoteControl=" + remoteControl);
            // Stream response headers explicitly so successful WebSocket upgrades are verifiable.
            Task upload = local.CopyToAsync(secure);
            Header response = await ReadHeader(secure);
            string status = response.Text.Split('\r')[0];
            if (status.StartsWith("HTTP/1.1 101 ")) {
                Interlocked.Increment(ref Upgrades);
                if (remoteControl) Interlocked.Increment(ref RemoteUpgrades);
            }
            Log("response", status + " remoteControl=" + remoteControl);
            await Send(local, response.Text);
            responseStarted = true;
            if (response.Remainder.Length > 0) await local.WriteAsync(response.Remainder, 0, response.Remainder.Length);
            Task download = secure.CopyToAsync(local);
            await Task.WhenAny(upload, download);
        } catch (Exception ex) {
            Interlocked.Increment(ref Failures);
            Log("request-error", ex.GetType().Name);
            if (!responseStarted) try { Reply(incoming.GetStream(), 502, "Codex proxy connection failed. Check the Windows system proxy.").GetAwaiter().GetResult(); } catch { }
        } finally {
            if (secure != null) secure.Dispose();
            if (remote != null) remote.Close();
            incoming.Close();
            Slots.Release();
        }
    }

    static void Log(string kind, string detail) {
        lock (LogLock) {
            try {
                string path = Path.Combine(Root, "guardian.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1048576) File.WriteAllText(path, "");
                File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + kind + " " + detail + Environment.NewLine);
                File.WriteAllText(Path.Combine(Root, "status.json"), new JavaScriptSerializer().Serialize(new {
                    updatedUtc = DateTime.UtcNow.ToString("o"), requests = Interlocked.Read(ref Requests),
                    websocketUpgrades = Interlocked.Read(ref Upgrades), failures = Interlocked.Read(ref Failures),
                    remoteControlRequests = Interlocked.Read(ref RemoteRequests), remoteControlUpgrades = Interlocked.Read(ref RemoteUpgrades),
                    lastEvent = kind
                }));
            } catch { }
        }
    }
}
