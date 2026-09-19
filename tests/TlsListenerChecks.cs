using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;

// Minimal TLS client for the listener checks. It trusts only the thumbprint the
// check created, so the machine's certificate stores never influence the result.
public static class GuardianTlsChecks {
    public static string Request(int port, string expectedThumbprint, string raw, out string presentedThumbprint) {
        string presented = null;
        using (var client = new TcpClient()) {
            client.Connect("127.0.0.1", port);
            client.ReceiveTimeout = 10000;
            using (var tls = new SslStream(client.GetStream(), false, delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
                presented = certificate == null ? null : new X509Certificate2(certificate).Thumbprint;
                return string.Equals(presented, expectedThumbprint, StringComparison.OrdinalIgnoreCase);
            })) {
                tls.AuthenticateAsClient("127.0.0.1", null, SslProtocols.Tls12, false);
                byte[] bytes = Encoding.ASCII.GetBytes(raw);
                tls.Write(bytes, 0, bytes.Length);
                tls.Flush();
                presentedThumbprint = presented;
                return new StreamReader(tls, Encoding.ASCII).ReadLine();
            }
        }
    }

    public static bool PlainHttpRejected(int port) {
        using (var client = new TcpClient()) {
            client.Connect("127.0.0.1", port);
            client.ReceiveTimeout = 10000;
            NetworkStream stream = client.GetStream();
            byte[] bytes = Encoding.ASCII.GetBytes("GET /unrelated HTTP/1.1\r\nHost: localhost\r\n\r\n");
            stream.Write(bytes, 0, bytes.Length);
            var buffer = new byte[64];
            try {
                int read = stream.Read(buffer, 0, buffer.Length);
                // A TLS listener never answers plaintext with an HTTP status line.
                return read == 0 || !Encoding.ASCII.GetString(buffer, 0, read).StartsWith("HTTP/");
            } catch (IOException) { return true; }
        }
    }
}
