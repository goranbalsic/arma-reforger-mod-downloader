using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class AppUninstall
{
    internal static void WhenClosed(string runtime, string root, bool removeEngine)
    {
        string helper = Path.Combine(Path.GetTempPath(), "rfmm-uninstall-" + Guid.NewGuid().ToString("N") + ".ps1");
        File.Copy(Path.Combine(runtime, "Uninstall.ps1"), helper);
        try
        {
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + helper + "\"",
                WorkingDirectory = Path.GetTempPath(),
                CreateNoWindow = true,
                UseShellExecute = false
            };
            using (var owner = Process.GetCurrentProcess()) info.EnvironmentVariables["RFMM_UNINSTALL_PARENT"] = owner.Id.ToString();
            info.EnvironmentVariables["RFMM_UNINSTALL_ROOT"] = root;
            info.EnvironmentVariables["RFMM_UNINSTALL_EXE"] = Application.ExecutablePath;
            info.EnvironmentVariables["RFMM_UNINSTALL_ENGINE"] = removeEngine ? "1" : "0";
            using (var process = Process.Start(info)) { }
        }
        catch
        {
            File.Delete(helper);
            throw;
        }
    }
}
