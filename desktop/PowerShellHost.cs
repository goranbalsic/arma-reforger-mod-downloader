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
    }

    internal PowerShellHost(string runtime, string root)
    {
        var info = StartInfo(runtime, root, "download-web.ps1", "-Desktop");
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

    internal static void Log(string line)
    {
        if (String.IsNullOrWhiteSpace(line)) return;
        try
        {
            File.AppendAllText(Path.Combine(Program.LocalFolder, "desktop.log"),
                DateTime.Now.ToString("s") + " " + line + Environment.NewLine);
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
