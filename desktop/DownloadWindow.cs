using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Text.RegularExpressions;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal sealed class DownloadWindow : Form
{
    private static readonly Uri Dashboard = new Uri("https://reforger.local/");
    private const string ProjectPage = "https://github.com/goranbalsic/arma-reforger-mod-downloader";
    private readonly string runtime;
    private readonly string locationFile = Path.Combine(Program.LocalFolder, "download-location.txt");
    private readonly Label location = new Label { AutoSize = true, MaximumSize = new Size(720, 0) };
    private readonly Button install = new Button { AutoSize = true, Text = "Install engine" };
    private readonly Button browse = new Button { AutoSize = true, Text = "Choose folder…" };
    private readonly ProgressBar setupProgress = new ProgressBar { Dock = DockStyle.Top, Height = 16, Visible = false, Style = ProgressBarStyle.Marquee };
    private readonly Label setupStatus = new Label { AutoSize = true, Visible = false, MaximumSize = new Size(720, 0) };
    private readonly LinkLabel setupDetails = new LinkLabel { Text = "Open setup log", AutoSize = true, Visible = false };
    private DateTime setupStarted;
    private TableLayoutPanel setup;
    private WebView2 view;
    private PowerShellHost backend;
    private string root;
    private readonly string steamEngine;
    private bool installing;

    internal DownloadWindow(string runtimePath)
    {
        runtime = runtimePath;
        root = FindDownloadFolder();
        steamEngine = SteamEngineDiscovery.Find();
        Text = Program.Title;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Segoe UI", 10);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(610, 460);
        ClientSize = new Size(1024, 740);
        ShowSetup();
        Shown += async (sender, args) =>
        {
            if (File.Exists(EnginePath(root)) || (steamEngine != null && File.Exists(Path.Combine(root, "data", "batch1-serverconfig.json"))))
                await OpenDashboardAsync();
        };
    }

    private string FindDownloadFolder()
    {
        string configured = Environment.GetEnvironmentVariable("RFMM_HOME");
        if (!String.IsNullOrWhiteSpace(configured))
            return Path.GetFullPath(configured);
        string sameFolder = AppDomain.CurrentDomain.BaseDirectory;
        if (File.Exists(EnginePath(sameFolder)) || Directory.Exists(Path.Combine(sameFolder, "data")))
            return sameFolder;
        DirectoryInfo parent = Directory.GetParent(sameFolder.TrimEnd(Path.DirectorySeparatorChar));
        if (parent != null && File.Exists(Path.Combine(parent.FullName, "download-web.ps1")) &&
            File.Exists(EnginePath(parent.FullName)))
            return parent.FullName;
        if (File.Exists(locationFile))
        {
            string saved = File.ReadAllText(locationFile).Trim();
            if (Path.IsPathRooted(saved)) return Path.GetFullPath(saved);
        }
        return Path.Combine(Program.LocalFolder, "downloads");
    }

    private static string EnginePath(string folder)
    {
        return Path.Combine(folder, "armar-server", "ArmaReforgerServer.exe");
    }

    private string ExistingEngine()
    {
        return File.Exists(EnginePath(root)) ? EnginePath(root) : steamEngine;
    }

    private bool EngineInstalled() { return File.Exists(ExistingEngine()); }

    private void ShowSetup()
    {
        setup = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(30),
            ColumnCount = 1,
            BackColor = Color.FromArgb(246, 247, 247)
        };
        setup.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        setup.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        setup.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        setup.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        setup.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        setup.Controls.Add(new Label { AutoSize = true, Font = new Font(Font.FontFamily, 19), Text = "Set up the download engine" });
        setup.Controls.Add(new Label
        {
            AutoSize = true,
            Margin = new Padding(3, 10, 3, 8),
            Text = "SteamCMD installs the free dedicated server. Allow about 20 GB of free space."
        });
        location.Margin = new Padding(3, 4, 3, 12);
        setup.Controls.Add(location);
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, 10) };
        buttons.Controls.Add(install);
        buttons.Controls.Add(browse);
        setup.Controls.Add(buttons);
        var progressPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        progressPanel.Controls.Add(setupStatus);
        setupDetails.LinkClicked += (sender, args) =>
        {
            string log = Path.Combine(Program.LocalFolder, "desktop.log");
            if (File.Exists(log)) Process.Start(new ProcessStartInfo(log) { UseShellExecute = true });
        };
        progressPanel.Controls.Add(setupDetails);
        var progressArea = new Panel { Dock = DockStyle.Top, Height = 85 };
        progressArea.Controls.Add(progressPanel);
        progressArea.Controls.Add(setupProgress);
        setup.Controls.Add(progressArea);
        Controls.Add(setup);
        RefreshSetupLocation();
        browse.Click += (sender, args) =>
        {
            using (var dialog = new FolderBrowserDialog { Description = "Choose where to store the download engine" })
            {
                if (Directory.Exists(root)) dialog.SelectedPath = root;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                root = dialog.SelectedPath;
                RefreshSetupLocation();
            }
        };
        install.Click += async (sender, args) =>
        {
            if (EngineInstalled()) await OpenDashboardAsync();
            else await InstallEngineAsync();
        };
    }

    private void RefreshSetupLocation()
    {
        string engine = ExistingEngine();
        location.Text = engine != null && engine == steamEngine
            ? "Downloader data: " + root + Environment.NewLine + "Steam dedicated server found: " + Path.GetDirectoryName(engine)
            : root;
        install.Text = EngineInstalled() ? "Open downloader" : "Install engine";
    }

    private async Task InstallEngineAsync()
    {
        installing = true;
        install.Enabled = browse.Enabled = false;
        install.Text = "Installing…";
        setupDetails.Hide();
        setupProgress.Value = 0;
        setupProgress.Style = ProgressBarStyle.Marquee;
        setupProgress.Show();
        setupStatus.Text = "Preparing the download…";
        setupStatus.Show();
        setupStarted = DateTime.UtcNow;
        using (var timer = new Timer { Interval = 1000 })
        {
            timer.Tick += (sender, args) => RefreshSetupProgress();
            try
            {
                Directory.CreateDirectory(root);
                RememberLocation();
                using (var engineSetup = new Process { StartInfo = PowerShellHost.StartInfo(runtime, root, "Setup.ps1", "") })
                {
                    engineSetup.OutputDataReceived += (sender, args) => PowerShellHost.Log(args.Data);
                    engineSetup.ErrorDataReceived += (sender, args) => PowerShellHost.Log(args.Data);
                    engineSetup.Start();
                    engineSetup.BeginOutputReadLine();
                    engineSetup.BeginErrorReadLine();
                    timer.Start();
                    await Task.Run(() => engineSetup.WaitForExit());
                    timer.Stop();
                    if (engineSetup.ExitCode != 0 || !EngineInstalled())
                        throw new IOException("Engine installation failed. Try again or open the setup log.");
                }
                await OpenDashboardAsync();
            }
            catch (Exception error)
            {
                ShowSetupError(error.Message);
            }
            finally
            {
                installing = false;
                install.Enabled = browse.Enabled = true;
                RefreshSetupLocation();
            }
        }
    }

    private void RefreshSetupProgress()
    {
        string path = Path.Combine(root, "steamcmd", "logs", "console_log.txt");
        try
        {
            if (File.GetLastWriteTimeUtc(path) < setupStarted) return;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                stream.Seek(Math.Max(0, stream.Length - 16384), SeekOrigin.Begin);
                using (var reader = new StreamReader(stream))
                {
                    var progress = Regex.Matches(reader.ReadToEnd(), @"Update state \([^)]+\)\s+([^,\r\n]+),\s*progress:\s*([0-9.]+)");
                    if (progress.Count == 0) return;
                    Match latest = progress[progress.Count - 1];
                    double percentage;
                    if (latest.Groups[1].Value.IndexOf("downloading", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        Double.TryParse(latest.Groups[2].Value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out percentage))
                    {
                        setupProgress.Style = ProgressBarStyle.Continuous;
                        setupProgress.Value = Math.Max(setupProgress.Value, (int)Math.Min(99, percentage));
                        setupStatus.Text = "Downloading engine… " + setupProgress.Value + "%";
                    }
                    else if (setupProgress.Style == ProgressBarStyle.Continuous)
                    {
                        setupProgress.Style = ProgressBarStyle.Marquee;
                        setupStatus.Text = "Finishing installation…";
                    }
                }
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void ShowSetupError(string message)
    {
        PowerShellHost.Log(message);
        setupProgress.Hide();
        setupStatus.Text = message;
        setupStatus.Show();
        setupDetails.Show();
    }
    private async Task OpenDashboardAsync()
    {
        install.Enabled = browse.Enabled = false;
        setup.Hide();
        view = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(view);
        view.BringToFront();
        try
        {
            Directory.CreateDirectory(root);
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Program.LocalFolder, "webview"));
            if (IsDisposed) return;
            await view.EnsureCoreWebView2Async(environment);
            CoreWebView2 core = view.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.NavigationStarting += (sender, args) => args.Cancel = !IsDashboardPage(args.Uri);
            core.NewWindowRequested += (sender, args) =>
            {
                args.Handled = true;
                if (args.IsUserInitiated && args.Uri == ProjectPage)
                    Process.Start(new ProcessStartInfo(ProjectPage) { UseShellExecute = true });
            };
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += ServeDashboard;
            backend = new PowerShellHost(runtime, root, ExistingEngine());
            RememberLocation();
            core.Navigate(Dashboard.AbsoluteUri);
        }
        catch (Exception error)
        {
            if (IsDisposed) return;
            PowerShellHost.Log(error.ToString());
            view.Dispose();
            setup.Show();
            install.Enabled = browse.Enabled = true;
            string guidance = error is WebView2RuntimeNotFoundException
                ? "Install Microsoft Edge WebView2 Runtime, then reopen the downloader."
                : "The downloader could not open. " + error.Message;
            ShowSetupError(guidance);
        }
    }

    private void RememberLocation()
    {
        if (String.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("RFMM_HOME")))
            File.WriteAllText(locationFile, root);
    }

    private static bool IsDashboardPage(string address)
    {
        Uri uri;
        return Uri.TryCreate(address, UriKind.Absolute, out uri) && Dashboard.IsBaseOf(uri)
            && uri.AbsolutePath == "/" && String.IsNullOrEmpty(uri.Query);
    }

    private async void ServeDashboard(object sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        CoreWebView2 core = (CoreWebView2)sender;
        using (CoreWebView2Deferral deferral = args.GetDeferral())
        {
            PowerShellHost.Reply reply;
            Uri uri = new Uri(args.Request.Uri);
            try
            {
                if (!Dashboard.IsBaseOf(uri))
                    reply = new PowerShellHost.Reply { status = 403, type = "text/plain", body = "Blocked" };
                else
                    reply = await backend.SendAsync(uri.PathAndQuery, args.Request.Method);
            }
            catch (Exception error)
            {
                PowerShellHost.Log(error.Message);
                reply = new PowerShellHost.Reply
                {
                    status = 503, type = "application/json",
                    body = new JavaScriptSerializer().Serialize(new { error = error.Message })
                };
            }
            if (IsDisposed) return;
            string headers = "Content-Type: " + reply.type + "; charset=utf-8\r\n"
                + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
                + "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; "
                + "style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'\r\n";
            var body = new MemoryStream(Encoding.UTF8.GetBytes(reply.body));
            args.Response = core.Environment.CreateWebResourceResponse(body, reply.status,
                reply.status < 400 ? "OK" : "Request failed", headers);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs args)
    {
        if (installing && args.CloseReason == CloseReason.UserClosing)
        {
            args.Cancel = true;
            MessageBox.Show(this, "Wait for the engine setup to finish before closing the downloader.",
                Program.Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        base.OnFormClosing(args);
    }

    protected override void OnFormClosed(FormClosedEventArgs args)
    {
        if (backend != null) backend.Dispose();
        base.OnFormClosed(args);
    }
}
