using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal sealed class PowerShellHost : IDisposable
{
    private readonly Process process;
    private readonly SemaphoreSlim requests = new SemaphoreSlim(1);
    private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue };
    private bool timedOut;

    internal sealed class Reply
    {
        public int status { get; set; }
        public string type { get; set; }
        public string body { get; set; }
        public string nonce { get; set; }
    }

    internal PowerShellHost(string runtime, string root, string engine, string sessionToken, bool readOnly = false)
    {
        // A second, read-only worker answers /status while the main worker runs a slow
        // action (search, verify, queue change), so live progress never freezes.
        var info = StartInfo(runtime, root, "download-web.ps1", readOnly ? "-Desktop -ReadOnly" : "-Desktop");
        info.EnvironmentVariables["RFMM_ENGINE_EXE"] = engine;
        info.EnvironmentVariables["RFMM_DESKTOP_SESSION_TOKEN"] = sessionToken;
        using (var owner = Process.GetCurrentProcess()) info.EnvironmentVariables["RFMM_DESKTOP_OWNER_PID"] = owner.Id.ToString();
        info.RedirectStandardInput = true;
        process = Process.Start(info);
        process.ErrorDataReceived += (sender, line) => Log(line.Data);
        process.BeginErrorReadLine();
    }

    internal static ProcessStartInfo StartInfo(string runtime, string root, string script, string options)
    {
        var info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(runtime, script) + "\" " + options,
            WorkingDirectory = runtime,
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        info.EnvironmentVariables["RFMM_HOME"] = root;
        if (String.IsNullOrEmpty(info.EnvironmentVariables["RFMM_DATA"]))
            info.EnvironmentVariables["RFMM_DATA"] = Path.Combine(root, "data");
        return info;
    }

    internal async Task<Reply> SendAsync(string path, string method)
    {
        await requests.WaitAsync();
        try
        {
            if (timedOut || process.HasExited)
                throw new IOException("The downloader stopped. Close and reopen the app.");
            await process.StandardInput.WriteLineAsync(json.Serialize(new { path = path, method = method }));
            var response = ReadReplyAsync();
            if (await Task.WhenAny(response, Task.Delay(TimeSpan.FromMinutes(3))) != response)
            {
                timedOut = true;
                throw new IOException("The downloader did not respond. Close and reopen the app.");
            }
            return await response;
        }
        finally
        {
            requests.Release();
        }
    }

    internal static async Task StopDownloadsAsync(string runtime, string root)
    {
        using (var shutdown = Process.Start(StartInfo(runtime, root, "download-web.ps1", "-DesktopStop")))
        {
            Task<string> output = shutdown.StandardOutput.ReadToEndAsync();
            Task<string> errors = shutdown.StandardError.ReadToEndAsync();
            await Task.Run(() => shutdown.WaitForExit());
            await output;
            string error = await errors;
            if (shutdown.ExitCode != 0)
                throw new IOException(String.IsNullOrWhiteSpace(error) ? "The downloader could not stop." : error.Trim());
        }
    }

    private async Task<Reply> ReadReplyAsync()
    {
        string line;
        while ((line = await process.StandardOutput.ReadLineAsync()) != null)
        {
            if (line.StartsWith("RFMM ", StringComparison.Ordinal))
                return json.Deserialize<Reply>(line.Substring(5));
            Log(line);
        }
        throw new IOException("The downloader stopped. See desktop.log in " + Program.LocalFolder);
    }

    private static readonly object logLock = new object();

    internal static void Log(string line)
    {
        if (String.IsNullOrWhiteSpace(line)) return;
        try
        {
            string path = Path.Combine(Program.LocalFolder, "desktop.log");
            lock (logLock)
            {
                // keep the log bounded: one previous file, rotate at 2 MB
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 2 * 1024 * 1024)
                {
                    string old = path + ".1";
                    try { File.Delete(old); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                    try { File.Move(path, old); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
                File.AppendAllText(path, DateTime.Now.ToString("s") + " " + line + Environment.NewLine);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        try { process.StandardInput.Close(); }
        catch (IOException) { }
        finally { process.Dispose(); }
    }
}
