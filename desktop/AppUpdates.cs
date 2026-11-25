using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class AppUpdates
{
    internal const string Repo = "goxy701/arma-reforger-mod-downloader";
    private const long RepoId = 1459406111;
    private const string Api = "https://api.github.com/";
    private const string AssetName = "ReforgerModDownloader.exe";
    private static readonly HttpClient Http = CreateClient();

    internal sealed class Release
    {
        public string url { get; set; }
        public string tag_name { get; set; }
        public bool draft { get; set; }
        public bool prerelease { get; set; }
        public Asset[] assets { get; set; }
    }

    internal sealed class Repository
    {
        public long id { get; set; }
        public string full_name { get; set; }
    }

    internal sealed class Asset
    {
        public string name { get; set; }
        public string browser_download_url { get; set; }
        public string digest { get; set; }
        public string state { get; set; }
        public long size { get; set; }
    }

    internal sealed class Pending
    {
        internal Version Version;
        internal string Digest;
    }

    private static HttpClient CreateClient()
    {
        // This executable uses the .NET Framework compiler, whose legacy TLS defaults can reject GitHub.
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });
        client.Timeout = TimeSpan.FromSeconds(30);
        client.MaxResponseContentBufferSize = 16 * 1024 * 1024;
        client.DefaultRequestHeaders.UserAgent.ParseAdd("ReforgerModDownloader/1.0");
        return client;
    }

    internal static Version NewerVersion(Release release, Version current)
    {
        Version version;
        if (release == null || release.draft || release.prerelease ||
            !Regex.IsMatch(release.tag_name ?? "", @"^v\d+\.\d+\.\d+$") ||
            !Version.TryParse(release.tag_name.Substring(1), out version))
            return null;
        version = new Version(version.Major, version.Minor, version.Build, 0);
        return version > current ? version : null;
    }

    private static void ValidateRepository(Repository repository)
    {
        if (repository == null || repository.id != RepoId || repository.full_name != Repo)
            throw new InvalidDataException("GitHub returned a different repository for this update.");
    }

    internal static Asset SelectAsset(Release release, Repository repository)
    {
        ValidateRepository(repository);
        if (release == null || !Regex.IsMatch(release.url ?? "",
                "^" + Regex.Escape(Api + "repos/" + Repo + "/releases/") + @"[1-9][0-9]*$"))
            throw new InvalidDataException("GitHub returned a release outside the update repository.");
        string url = "https://github.com/" + Repo + "/releases/download/" + release.tag_name + "/" + AssetName;
        var assets = (release.assets ?? new Asset[0]).Where(asset => asset != null && asset.name == AssetName &&
            asset.state == "uploaded" && asset.browser_download_url == url && asset.size > 0 &&
            asset.size <= 16 * 1024 * 1024 &&
            Regex.IsMatch(asset.digest ?? "", @"^sha256:[0-9a-fA-F]{64}$")).ToArray();
        if (assets.Length != 1)
            throw new InvalidDataException("The release has no Windows executable with a SHA-256 digest.");
        return assets[0];
    }

    internal static async Task<Pending> CheckAsync()
    {
        string endpoint = Api + "repositories/" + RepoId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var json = new JavaScriptSerializer();
        var repository = json.Deserialize<Repository>(System.Text.Encoding.UTF8.GetString(
            await DownloadAsync(new Uri(endpoint), false)));
        ValidateRepository(repository);
        var release = json.Deserialize<Release>(System.Text.Encoding.UTF8.GetString(
            await DownloadAsync(new Uri(endpoint + "/releases/latest"), false)));
        Version version = NewerVersion(release, Assembly.GetExecutingAssembly().GetName().Version);
        if (version == null) return null;
        Asset asset = SelectAsset(release, repository);
        byte[] payload = await DownloadAsync(new Uri(asset.browser_download_url), true);
        string digest = asset.digest.Substring(7);
        using (var sha = SHA256.Create())
        {
            string calculated = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "");
            if (payload.LongLength != asset.size || !String.Equals(calculated, digest, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The downloaded update did not match GitHub's SHA-256 digest.");
        }
        string pending = Application.ExecutablePath + ".update";
        try
        {
            File.WriteAllBytes(pending, payload);
            if (AssemblyName.GetAssemblyName(pending).Version != version)
                throw new InvalidDataException("The downloaded executable did not match the release version.");
        }
        catch
        {
            try { File.Delete(pending); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            throw;
        }
        return new Pending { Version = version, Digest = digest };
    }

    private static async Task<byte[]> DownloadAsync(Uri uri, bool asset)
    {
        for (int hop = 0; hop < 4; hop++)
        {
            bool trustedHost = !asset ? uri.Host == "api.github.com"
                : hop == 0 ? uri.Host == "github.com"
                : uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com";
            if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || !trustedHost)
                throw new InvalidDataException("GitHub redirected the update to an unexpected URL.");
            using (HttpResponseMessage response = await Http.GetAsync(uri))
            {
                int status = (int)response.StatusCode;
                if (status >= 300 && status < 400 && response.Headers.Location != null)
                {
                    if (!asset)
                        throw new InvalidDataException("GitHub redirected the update repository.");
                    uri = new Uri(uri, response.Headers.Location);
                    continue;
                }
                response.EnsureSuccessStatusCode();
                return await response.Content.ReadAsByteArrayAsync();
            }
        }
        throw new IOException("Too many redirects while checking for updates.");
    }

    internal static void ApplyWhenClosed(string runtime, Pending pending, bool restart)
    {
        var info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(runtime, "Apply-AppUpdate.ps1") + "\"",
            WorkingDirectory = runtime,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        info.EnvironmentVariables["RFMM_UPDATE_RESTART"] = restart ? "1" : "0";
        info.EnvironmentVariables["RFMM_UPDATE_TARGET"] = Application.ExecutablePath;
        info.EnvironmentVariables["RFMM_UPDATE_DIGEST"] = pending.Digest;
        using (var owner = Process.GetCurrentProcess()) info.EnvironmentVariables["RFMM_UPDATE_PARENT"] = owner.Id.ToString();
        Process.Start(info).Dispose();
    }
}
