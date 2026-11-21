using System;
using System.Diagnostics;
using System.Drawing;
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
    private readonly RichTextBox setupOutput = new RichTextBox { ReadOnly = true, Dock = DockStyle.Fill, Visible = false };
    private TableLayoutPanel setup;
    private WebView2 view;
    private PowerShellHost backend;
    private string root;
    private bool installing;

    internal DownloadWindow(string runtimePath)
    {
        runtime = runtimePath;
        root = FindDownloadFolder();
        Text = Program.Title;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Segoe UI", 10);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(610, 460);
        ClientSize = new Size(1024, 740);
        ShowSetup();
        Shown += async (sender, args) =>
        {
            if (EngineInstalled()) await OpenDashboardAsync();
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

    private bool EngineInstalled() { return File.Exists(EnginePath(root)); }

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
        setup.Controls.Add(setupOutput);
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
        location.Text = root;
        install.Text = EngineInstalled() ? "Open downloader" : "Install engine";
    }

    private async Task InstallEngineAsync()
    {
        installing = true;
        install.Enabled = browse.Enabled = false;
        install.Text = "Installing…";
        setupOutput.Clear();
        setupOutput.Visible = true;
        try
        {
            Directory.CreateDirectory(root);
            RememberLocation();
            using (var engineSetup = new Process { StartInfo = PowerShellHost.StartInfo(runtime, root, "Setup.ps1", "") })
            {
                engineSetup.OutputDataReceived += (sender, args) => ShowSetupLine(args.Data);
                engineSetup.ErrorDataReceived += (sender, args) => ShowSetupLine(args.Data);
                engineSetup.Start();
                engineSetup.BeginOutputReadLine();
                engineSetup.BeginErrorReadLine();
                await Task.Run(() => engineSetup.WaitForExit());
                if (engineSetup.ExitCode != 0 || !EngineInstalled())
                    throw new IOException("Setup did not finish. Review the output above, then try again.");
            }
            await OpenDashboardAsync();
        }
        catch (Exception error)
        {
            ShowSetupLine(error.Message);
        }
        finally
        {
            installing = false;
            install.Enabled = browse.Enabled = true;
            RefreshSetupLocation();
        }
    }

    private void ShowSetupLine(string line)
    {
        if (line == null) return;
        PowerShellHost.Log(line);
        BeginInvoke((Action)(() => setupOutput.AppendText(line + Environment.NewLine)));
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
            backend = new PowerShellHost(runtime, root);
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
            setupOutput.Visible = true;
            string guidance = error is WebView2RuntimeNotFoundException
                ? "Install Microsoft Edge WebView2 Runtime, then reopen the downloader."
                : "The downloader could not open. " + error.Message;
            ShowSetupLine(guidance);
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
