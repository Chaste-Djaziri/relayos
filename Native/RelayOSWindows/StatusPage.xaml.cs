using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml;
using System;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace RelayOSWindows;

public sealed partial class StatusPage : Page
{
    private readonly HttpClient _http = new();

    public StatusPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        var page = e.Parameter?.ToString() ?? "General";
        PageTitle.Text = page;
        PageDescription.Text = page switch
        {
            "Connections" => "Connected AI clients and OAuth access grants.",
            "Tools" => "Capabilities, project sessions, and persistent permissions.",
            "Ngrok" => "Public transport status and generated ngrok endpoint.",
            "Security" => "Emergency stop, approvals, and local security boundaries.",
            "Activity" => "Local metadata-only connection and action history.",
            _ => "RelayOS local services and public MCP connection status."
        };
        Endpoint.Text = "Loading endpoint…";
        GeneralPanel.Visibility = Visibility.Collapsed;
        ConnectionsPanel.Visibility = Visibility.Collapsed;
        ToolsPanel.Visibility = Visibility.Collapsed;
        NgrokPanel.Visibility = Visibility.Collapsed;
        SecurityPanel.Visibility = Visibility.Collapsed;
        ActivityPanel.Visibility = Visibility.Collapsed;
        switch (page)
        {
            case "Connections": ConnectionsPanel.Visibility = Visibility.Visible; break;
            case "Tools": ToolsPanel.Visibility = Visibility.Visible; break;
            case "Ngrok": NgrokPanel.Visibility = Visibility.Visible; break;
            case "Security": SecurityPanel.Visibility = Visibility.Visible; break;
            case "Activity": ActivityPanel.Visibility = Visibility.Visible; break;
            default: GeneralPanel.Visibility = Visibility.Visible; break;
        }
        _ = RefreshPageAsync(page);
        base.OnNavigatedTo(e);
    }

    private async Task RefreshPageAsync(string page)
    {
        await RefreshEndpointAsync();
        try
        {
            using var response = await _http.GetAsync(page == "Activity" ? "http://127.0.0.1:8765/control/activity" : "http://127.0.0.1:8765/control/status");
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var root = json.RootElement;
            if (page == "Connections") ConnectionsText.Text = FormatArray(root.GetProperty("connections"), "No connected AI clients.");
            if (page == "Tools") ToolsText.Text = $"Capabilities: {root.GetProperty("capabilities")}\n\nPermissions:\n{FormatArray(root.GetProperty("permissions"), "No persistent permissions.")}";
            if (page == "Ngrok") NgrokText.Text = $"Status: {(root.GetProperty("ngrok").GetProperty("enabled").GetBoolean() ? "Configured" : "Not configured")}\nEndpoint: {Endpoint.Text}";
            if (page == "Security") SecurityText.Text = $"Emergency stop: {(root.GetProperty("emergency_stop").GetBoolean() ? "Enabled" : "Disabled")}\nPending approvals: {root.GetProperty("pending_approvals").GetInt32()}";
            if (page == "Activity") ActivityText.Text = root.TryGetProperty("activity", out var activity) ? FormatArray(activity, "No activity recorded.") : "No activity recorded.";
        }
        catch { }
    }

    private static string FormatArray(JsonElement array, string empty)
    {
        if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() == 0) return empty;
        var lines = new System.Text.StringBuilder();
        foreach (var item in array.EnumerateArray()) lines.AppendLine(item.ToString());
        return lines.ToString();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshPageAsync(PageTitle.Text);

    private async void Reconnect_Click(object sender, RoutedEventArgs e)
    {
        try { await _http.PostAsync("http://127.0.0.1:8765/control/services/restart", null); } catch { }
        await RefreshPageAsync("Ngrok");
    }

    private async void EmergencyStop_Click(object sender, RoutedEventArgs e)
    {
        try { await _http.PostAsync("http://127.0.0.1:8765/control/emergency-stop", new StringContent("{\"enabled\":true}", System.Text.Encoding.UTF8, "application/json")); } catch { }
        await RefreshPageAsync("Security");
    }

    private async Task RefreshEndpointAsync()
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                var tokenPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".laptop-bridge", "control.token");
                if (File.Exists(tokenPath))
                {
                    _http.DefaultRequestHeaders.Remove("X-RelayOS-Control-Token");
                    _http.DefaultRequestHeaders.Add("X-RelayOS-Control-Token", File.ReadAllText(tokenPath).Trim());
                }
                using var response = await _http.GetAsync("http://127.0.0.1:8765/control/status");
                using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (json.RootElement.TryGetProperty("mcp_endpoint", out var endpoint) && endpoint.GetString() is { Length: > 0 } value)
                {
                    Endpoint.Text = value;
                    return;
                }
            }
            catch { }
            await Task.Delay(1000);
        }
        Endpoint.Text = "Not configured — complete ngrok setup";
    }
}
