using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

internal static class SteamEngineDiscovery
{
    internal static string FindInFolder(string folder)
    {
        string managed = Path.Combine(folder, "armar-server", "ArmaReforgerServer.exe");
        if (File.Exists(managed)) return managed;
        string direct = Path.Combine(folder, "ArmaReforgerServer.exe");
        return File.Exists(direct) ? direct : null;
    }

    internal static string Find()
    {
        var roots = new[]
        {
            ReadRegistry(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath"),
            ReadRegistry(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam")
        };
        return FindInLibraries(roots);
    }

    internal static string FindInLibraries(IEnumerable<string> roots)
    {
        var libraries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string root in roots)
        {
            if (String.IsNullOrEmpty(root) || !Path.IsPathRooted(root)) continue;
            libraries.Add(root);
            string folders = ReadFile(Path.Combine(root, "steamapps", "libraryfolders.vdf"));
            foreach (Match match in Regex.Matches(folders, @"""path""\s+""([^""]+)""", RegexOptions.IgnoreCase))
            {
                string library = match.Groups[1].Value.Replace(@"\\", @"\");
                if (Path.IsPathRooted(library)) libraries.Add(library);
            }
        }
        foreach (string library in libraries)
        {
            string steamapps = Path.Combine(library, "steamapps");
            string manifest = ReadFile(Path.Combine(steamapps, "appmanifest_1874900.acf"));
            Match install = Regex.Match(manifest, @"""installdir""\s+""([^""]+)""", RegexOptions.IgnoreCase);
            string folder = install.Groups[1].Value;
            if (install.Success && Regex.IsMatch(manifest, @"""appid""\s+""1874900""", RegexOptions.IgnoreCase) &&
                folder != "." && folder != ".." && folder.IndexOfAny(Path.GetInvalidFileNameChars()) < 0)
            {
                string executable = Path.Combine(steamapps, "common", folder, "ArmaReforgerServer.exe");
                if (File.Exists(executable)) return executable;
            }
            foreach (string name in new[] { "Arma Reforger Server", "Arma Reforger Dedicated Server" })
            {
                string executable = Path.Combine(steamapps, "common", name, "ArmaReforgerServer.exe");
                if (File.Exists(executable)) return executable;
            }
        }
        return null;
    }

    private static string ReadRegistry(string key, string value)
    {
        try { return Registry.GetValue(key, value, null) as string; }
        catch (UnauthorizedAccessException) { return null; }
        catch (System.Security.SecurityException) { return null; }
    }

    private static string ReadFile(string path)
    {
        try { return File.ReadAllText(path); }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
    }
}
