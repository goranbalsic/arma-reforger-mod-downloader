using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    internal const string Title = "Arma Reforger Mod Downloader";
    internal static readonly string LocalFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Reforger Mod Downloader");

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool created;
        using (var instance = new Mutex(true, @"Local\ReforgerModDownloader.Desktop", out created))
        {
            if (!created)
            {
                MessageBox.Show("The downloader is already open.", Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                string runtime = InstallPayload(LocalFolder);
                AppDomain.CurrentDomain.AssemblyResolve += (sender, args) =>
                {
                    string name = new AssemblyName(args.Name).Name;
                    if (name == "Microsoft.Web.WebView2.Core" || name == "Microsoft.Web.WebView2.WinForms")
                        return Assembly.LoadFrom(Path.Combine(runtime, name + ".dll"));
                    return null;
                };
                if (LoadLibraryEx(Path.Combine(runtime, "WebView2Loader.dll"), IntPtr.Zero, 0x1100) == IntPtr.Zero)
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                RunWindow(runtime);
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    // Keep WebView types out of Main so assembly resolution is ready before JIT loads them.
    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    private static void RunWindow(string runtime)
    {
        Application.Run(new DownloadWindow(runtime));
    }

    private static string InstallPayload(string localFolder)
    {
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.zip"))
        using (var sha = SHA256.Create())
        {
            string revision = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "").Substring(0, 20);
            string runtime = Path.Combine(localFolder, "app", revision);
            Directory.CreateDirectory(runtime);
            payload.Position = 0;
            using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (String.IsNullOrEmpty(entry.Name) || entry.FullName != entry.Name)
                        throw new InvalidDataException("Invalid file in the application package.");
                    string target = Path.Combine(runtime, entry.Name);
                    if (PayloadMatches(entry, target, sha))
                        continue;
                    string temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try
                    {
                        entry.ExtractToFile(temporary);
                        if (File.Exists(target))
                            File.Replace(temporary, target, null);
                        else
                            File.Move(temporary, target);
                    }
                    finally
                    {
                        File.Delete(temporary);
                    }
                }
            }
            return runtime;
        }
    }

    private static bool PayloadMatches(ZipArchiveEntry entry, string target, SHA256 sha)
    {
        var file = new FileInfo(target);
        if (!file.Exists || file.Length != entry.Length)
            return false;
        using (Stream bundled = entry.Open())
        using (Stream installed = file.OpenRead())
            return sha.ComputeHash(bundled).SequenceEqual(sha.ComputeHash(installed));
    }
}
