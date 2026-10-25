using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Dispatching;
using Windows.ApplicationModel.DataTransfer;

namespace RelayOSWindows;

public sealed partial class MainWindow : Window
{
    private readonly HttpClient _http = new();
    private Process? _python;
    private const string ControlUrl = "http://127.0.0.1:8765";
    private string _endpoint = "Not configured";
    private string _lastConfiguredEndpoint = "";
    private bool _backendStartedWithConfiguredEndpoint;
    private DispatcherQueueTimer? _approvalTimer;
    private bool _approvalDialogOpen;

    public MainWindow()
    {
        InitializeComponent();
        Closed += MainWindow_Closed;
        try
        {
            Navigation.SelectedItem = Navigation.MenuItems[0];
            ContentFrame.Navigate(typeof(StatusPage), "General");
        }
        catch (Exception error)
        {
            File.AppendAllText(Path.Combine(Path.GetTempPath(), "relayos-windows-startup.log"), error + Environment.NewLine);
        }
        StartBackend();
        _ = RefreshStatusAsync();
        _approvalTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _approvalTimer.Interval = TimeSpan.FromSeconds(1);
        _approvalTimer.Tick += async (_, _) => await PollApprovalsAsync();
        _approvalTimer.Start();
    }

    private void StartBackend()
    {
        var root = AppContext.BaseDirectory;
        var repo = FindRepositoryRoot(root);
        var backend = Path.Combine(root, "Runtime", "RelayOSServer.exe");
        var python = Path.Combine(root, "Runtime", "python.exe");
        var working = root;
        if (!File.Exists(backend))
        {
            backend = python;
            if (!File.Exists(backend)) { backend = Path.Combine(repo, ".venv", "Scripts", "python.exe"); working = repo; }
            if (!File.Exists(backend)) return;
        }
        _backendStartedWithConfiguredEndpoint = HasConfiguredPublicEndpoint();
        var arguments = backend.EndsWith("python.exe", StringComparison.OrdinalIgnoreCase) ? "-m laptop_bridge.server" : "";
        _python = new Process { StartInfo = new ProcessStartInfo(backend, arguments) { WorkingDirectory = working, UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true } };
        _python.StartInfo.Environment["LAPTOP_BRIDGE_MCP_PORT"] = "8765";
        _python.Start();
        _ = StartNgrokAsync();
    }

    private async Task StartNgrokAsync()
    {
        await Task.Delay(1500);
        LoadControlToken();
        try { await _http.PostAsync($"{ControlUrl}/control/services/start", null); } catch { }
        for (var i = 0; i < 20; i++) { await Task.Delay(1000); await RefreshStatusAsync(); }
    }

    private void LoadControlToken()
    {
        var tokenPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".laptop-bridge", "control.token");
        if (!File.Exists(tokenPath)) return;
        _http.DefaultRequestHeaders.Remove("X-RelayOS-Control-Token");
        _http.DefaultRequestHeaders.Add("X-RelayOS-Control-Token", File.ReadAllText(tokenPath).Trim());
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item) ContentFrame.Navigate(typeof(StatusPage), item.Tag?.ToString() ?? "General");
    }

    private async Task RefreshStatusAsync()
    {
        try
        {
            await Task.Delay(500);
            LoadControlToken();
            using var response = await _http.GetAsync($"{ControlUrl}/control/status");
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var root = json.RootElement;
            _endpoint = root.TryGetProperty("mcp_endpoint", out var endpoint) && endpoint.GetString() is { Length: > 0 } value ? value : "Not configured";
            ServiceSummary.Text = $"Local server · ngrok · {_endpoint}";
            if (!_backendStartedWithConfiguredEndpoint && _endpoint.StartsWith("https://", StringComparison.Ordinal) && _endpoint != _lastConfiguredEndpoint)
            {
                _lastConfiguredEndpoint = _endpoint;
                _backendStartedWithConfiguredEndpoint = true;
                RestartPythonForPublicEndpoint();
            }
        }
        catch { ServiceSummary.Text = "Starting local services…"; }
    }

    private void RestartPythonForPublicEndpoint()
    {
        try { if (_python is { HasExited: false }) { _python.Kill(true); _python.WaitForExit(2000); } } catch { }
        _python?.Dispose();
        _python = null;
        var root = AppContext.BaseDirectory;
        var repo = FindRepositoryRoot(root);
        var backend = Path.Combine(root, "Runtime", "RelayOSServer.exe");
        var python = Path.Combine(root, "Runtime", "python.exe");
        var working = root;
        if (!File.Exists(backend))
        {
            backend = python;
            if (!File.Exists(backend)) { backend = Path.Combine(repo, ".venv", "Scripts", "python.exe"); working = repo; }
            if (!File.Exists(backend)) return;
        }
        var arguments = backend.EndsWith("python.exe", StringComparison.OrdinalIgnoreCase) ? "-m laptop_bridge.server" : "";
        _python = new Process { StartInfo = new ProcessStartInfo(backend, arguments) { WorkingDirectory = working, UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true } };
        _python.StartInfo.Environment["LAPTOP_BRIDGE_MCP_PORT"] = "8765";
        _python.Start();
    }

    private static string FindRepositoryRoot(string start)
    {
        var directory = new DirectoryInfo(start);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "pyproject.toml"))) return directory.FullName;
            directory = directory.Parent;
        }
        return start;
    }

    private static bool HasConfiguredPublicEndpoint()
    {
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".laptop-bridge", "config.json");
            if (!File.Exists(path)) return false;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.TryGetProperty("public_base_url", out var value)
                && !string.IsNullOrWhiteSpace(value.GetString());
        }
        catch { return false; }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        _approvalTimer?.Stop();
        try { if (_python is { HasExited: false }) { _python.Kill(true); _python.WaitForExit(2000); } } catch { }
        _python?.Dispose();
    }

    private async Task PollApprovalsAsync()
    {
        if (_approvalDialogOpen) return;
        try
        {
            LoadControlToken();
            using var response = await _http.GetAsync($"{ControlUrl}/control/pending-approvals");
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var isOAuth = json.RootElement.TryGetProperty("oauth", out var oauth) && oauth.GetArrayLength() > 0;
            var isAction = json.RootElement.TryGetProperty("actions", out var actions) && actions.GetArrayLength() > 0;
            if (!isOAuth && !isAction) return;
            var request = isOAuth ? oauth[0] : actions[0];
            var requestId = request.GetProperty("request_id").GetString();
            if (string.IsNullOrWhiteSpace(requestId)) return;
            _approvalDialogOpen = true;
            var kind = request.TryGetProperty("kind", out var kindValue) ? kindValue.GetString() : "action";
            var target = request.TryGetProperty("target", out var targetValue) ? targetValue.GetString() : "the requested operation";
            var dialog = new ContentDialog
            {
                Title = isOAuth ? "Approve MCP connection?" : "Approve RelayOS action?",
                Content = isOAuth
                    ? $"{request.GetProperty("client_name").GetString()} is requesting access to RelayOS. Approve only if you initiated this connection."
                    : $"RelayOS is requesting approval for {kind} on:\n{target}\n\nApprove only if you initiated this action.",
                PrimaryButtonText = "Approve",
                CloseButtonText = "Deny",
                XamlRoot = ContentFrame.XamlRoot
            };
            var result = await dialog.ShowAsync();
            var decisionPayload = JsonSerializer.Serialize(new
            {
                request_id = requestId,
                approved = result == ContentDialogResult.Primary,
            });
            var decision = new StringContent(decisionPayload, System.Text.Encoding.UTF8, "application/json");
            await _http.PostAsync($"{ControlUrl}/control/decide", decision);
        }
        catch { }
        finally { _approvalDialogOpen = false; }
    }

    private void CopyEndpoint_Click(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage(); package.SetText(_endpoint); Clipboard.SetContent(package);
    }

    private async void Restart_Click(object sender, RoutedEventArgs e)
    {
        try { await _http.PostAsync($"{ControlUrl}/control/services/restart", null); } catch { }
        await RefreshStatusAsync();
    }
}
