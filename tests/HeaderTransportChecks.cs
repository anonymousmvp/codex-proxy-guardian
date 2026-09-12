using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// These fixtures call only the header readers. They do not open sockets, inspect
// Windows proxy settings, read credentials, or start the installed guardian.
public static class GuardianTransportChecks {
    static readonly BindingFlags PrivateStatic = BindingFlags.NonPublic | BindingFlags.Static;

    public static void Run(Assembly assembly) {
        Type guardian = assembly.GetType("CodexProxyGuardian", true);
        MethodInfo requestReader = guardian.GetMethod("ReadHeader", PrivateStatic);
        MethodInfo responseReader = guardian.GetMethod("ReadResponseHeader", PrivateStatic);
        Require(requestReader != null && responseReader != null, "Header reader entry points are missing.");
        ParameterInfo[] parameters = requestReader.GetParameters();
        Require(parameters.Length == 2 && (int)parameters[1].DefaultValue == 20000,
            "Incoming requests and proxy CONNECT must retain their 20-second header limit.");

        // Run the real 21-second regression and its old 20-second failure in parallel.
        // The remaining cases use short delays to keep the entire suite near 21 seconds.
        Task.WhenAll(
            SlowResponseSurvives(responseReader),
            OldDeadlineStillFails(requestReader),
            FragmentedHeaderPreservesBody(responseReader, false),
            FragmentedHeaderPreservesBody(responseReader, true),
            ShortDeadlineStillFails(requestReader),
            DeadlineDoesNotResetOnProgress(requestReader),
            HeaderLimit(responseReader, 65536, true),
            HeaderLimit(responseReader, 65537, false),
            UnterminatedHeaderLimit(responseReader)
        ).GetAwaiter().GetResult();
    }

    static async Task SlowResponseSurvives(MethodInfo reader) {
        const string header = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n";
        using (var stream = new ChunkStream(new[] { Bytes(header + "ok") }, new[] { 21000 })) {
            object result = await Read(reader, stream);
            Require(HeaderText(result) == header, "A response arriving after 20 seconds was not preserved.");
            Require(Equal(Remainder(result), Bytes("ok")), "Delayed response body bytes changed.");
        }
    }

    static async Task OldDeadlineStillFails(MethodInfo reader) {
        using (var stream = new ChunkStream(new[] { Bytes("HTTP/1.1 200 OK\r\n\r\n") }, new[] { 21000 })) {
            await Expect<TimeoutException>(Read(reader, stream, Type.Missing),
                "The original 20-second limit no longer reproduces the delayed-response failure.");
        }
    }

    static async Task FragmentedHeaderPreservesBody(MethodInfo reader, bool upgrade) {
        string header = upgrade
            ? "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
            : "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
        byte[] body = upgrade
            ? new byte[] { 0x82, 0x04, 0x00, 0xff, 0x0d, 0x0a }
            : Bytes("4\r\ntest\r\n0\r\n\r\n");
        // Split every byte of CRLFCRLF across reads; the final read also contains
        // the first body bytes or WebSocket frame, which must remain untouched.
        byte[] last = new byte[body.Length + 1];
        last[0] = 10;
        Buffer.BlockCopy(body, 0, last, 1, body.Length);
        using (var stream = new ChunkStream(new[] {
            Bytes(header.Substring(0, header.Length - 4)),
            new byte[] { 13 }, new byte[] { 10 }, new byte[] { 13 }, last
        }, new int[5])) {
            object result = await Read(reader, stream);
            Require(HeaderText(result) == header, "Fragmented response headers changed.");
            Require(Equal(Remainder(result), body), upgrade
                ? "WebSocket upgrade lost or changed its initial binary frame."
                : "Chunked response lost or changed its body remainder.");
        }
    }

    static async Task ShortDeadlineStillFails(MethodInfo reader) {
        using (var stream = new ChunkStream(new[] { Bytes("GET / HTTP/1.1\r\n\r\n") }, new[] { 300 })) {
            await Expect<TimeoutException>(Read(reader, stream, 75), "A short header deadline was ignored.");
        }
    }

    static async Task DeadlineDoesNotResetOnProgress(MethodInfo reader) {
        // Every individual read is faster than 200 ms, but the full header takes
        // 320 ms. A fresh timeout per read would incorrectly accept this stream.
        using (var stream = new ChunkStream(new[] {
            Bytes("GET / HTTP/1.1\r\n"), Bytes("X-Test: "), Bytes("value"), Bytes("\r\n\r\n")
        }, new[] { 80, 80, 80, 80 })) {
            await Expect<TimeoutException>(Read(reader, stream, 200),
                "Partial progress reset the total header deadline.");
        }
    }

    static async Task HeaderLimit(MethodInfo reader, int length, bool accepted) {
        const string prefix = "HTTP/1.1 200 OK\r\nX-Padding: ";
        string header = prefix + new string('a', length - prefix.Length - 4) + "\r\n\r\n";
        byte[] body = new byte[] { 0, 255, 128, 13, 10 };
        byte[] first = Bytes(header.Substring(0, 65535));
        byte[] ending = Bytes(header.Substring(65535));
        byte[] last = new byte[ending.Length + body.Length];
        Buffer.BlockCopy(ending, 0, last, 0, ending.Length);
        Buffer.BlockCopy(body, 0, last, ending.Length, body.Length);
        using (var stream = new ChunkStream(new[] { first, last }, new int[2])) {
            Task<object> read = Read(reader, stream);
            if (!accepted) {
                await Expect<IOException>(read, "A header over 64 KiB bypassed the limit by ending in the final read.");
                return;
            }
            object result = await read;
            Require(HeaderText(result) == header, "A valid header exactly at the 64 KiB limit was rejected or changed.");
            Require(Equal(Remainder(result), body), "Body bytes were counted as part of the header size limit.");
        }
    }

    static async Task UnterminatedHeaderLimit(MethodInfo reader) {
        using (var stream = new ChunkStream(new[] { Bytes(new string('a', 70000)) }, new int[1])) {
            await Expect<IOException>(Read(reader, stream), "An unterminated oversized header was accepted.");
            Require(stream.BytesRead <= 69632, "Oversized header reading continued beyond one buffer past the limit.");
        }
    }

    static async Task<object> Read(MethodInfo reader, Stream stream, params object[] arguments) {
        object[] all = new object[arguments.Length + 1];
        all[0] = stream;
        Array.Copy(arguments, 0, all, 1, arguments.Length);
        Task task = (Task)reader.Invoke(null, all);
        await task;
        return task.GetType().GetProperty("Result").GetValue(task, null);
    }

    static async Task Expect<T>(Task task, string message) where T : Exception {
        try { await task; }
        catch (T) { return; }
        throw new Exception(message);
    }

    static string HeaderText(object header) { return (string)header.GetType().GetField("Text").GetValue(header); }
    static byte[] Remainder(object header) { return (byte[])header.GetType().GetField("Remainder").GetValue(header); }
    static byte[] Bytes(string value) { return Encoding.ASCII.GetBytes(value); }
    static bool Equal(byte[] left, byte[] right) {
        if (left.Length != right.Length) return false;
        for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
        return true;
    }
    static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }

    sealed class ChunkStream : Stream {
        readonly byte[][] chunks;
        readonly int[] delays;
        int chunkIndex, chunkOffset;
        public int BytesRead { get; private set; }
        public ChunkStream(byte[][] chunks, int[] delays) { this.chunks = chunks; this.delays = delays; }
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) {
            if (chunkIndex == chunks.Length) return 0;
            if (chunkOffset == 0 && delays[chunkIndex] != 0)
                await Task.Delay(delays[chunkIndex], cancellationToken);
            int copied = Math.Min(count, chunks[chunkIndex].Length - chunkOffset);
            Buffer.BlockCopy(chunks[chunkIndex], chunkOffset, buffer, offset, copied);
            chunkOffset += copied;
            BytesRead += copied;
            if (chunkOffset == chunks[chunkIndex].Length) { chunkIndex++; chunkOffset = 0; }
            return copied;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        public override void Flush() { }
    }
}
