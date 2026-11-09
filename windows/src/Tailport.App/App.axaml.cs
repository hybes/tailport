using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;

namespace Tailport.App;

public partial class App : Application
{
    MainViewModel? viewModel;
    Updater? updater;
    MainWindow? window;
    TrayIcon? tray;
    bool quitting;
    string? trayKey;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
        // TAILPORT_THEME=light|dark forces an appearance, for screenshots and testing.
        RequestedThemeVariant = Environment.GetEnvironmentVariable("TAILPORT_THEME")?.ToLowerInvariant() switch
        {
            "light" => Avalonia.Styling.ThemeVariant.Light,
            "dark" => Avalonia.Styling.ThemeVariant.Dark,
            _ => RequestedThemeVariant,
        };
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var model = new AppModel(SettingsStore.Default());
            var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Tailport.exe");
            Updater.CleanUp(exe);
            updater = new Updater(model, OperatingSystem.IsWindows() ? UpdateSource.RunningVersion() : null, exe);
            updater.Installed += Restart;
            viewModel = new MainViewModel(model, updater);
            window = new MainWindow { DataContext = viewModel };
            // Closing the window keeps forwarding running; quit from the tray icon.
            window.Closing += (_, e) =>
            {
                if (quitting) return;
                e.Cancel = true;
                window.Hide();
            };
            desktop.MainWindow = window;
            window.Show();

            tray = new TrayIcon
            {
                Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Tailport/Assets/tailport.ico"))),
                ToolTipText = "Tailport",
                Menu = new NativeMenu(),
            };
            tray.Clicked += (_, _) => ShowWindow();
            TrayIcon.SetIcons(this, [tray]);
            model.Changed += BuildTrayMenu;
            updater.Changed += BuildTrayMenu;
            BuildTrayMenu();
            model.Start();
            updater.Start();
        }
        base.OnFrameworkInitializationCompleted();
    }

    void ShowWindow()
    {
        if (window is null) return;
        window.Show();
        window.WindowState = window.WindowState == WindowState.Minimized ? WindowState.Normal : window.WindowState;
        window.Activate();
    }

    async void Quit() => await QuitAsync();

    async Task QuitAsync()
    {
        if (viewModel is null || ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop) return;
        quitting = true;
        updater?.Stop();
        await viewModel.Model.ShutdownAsync();
        tray?.Dispose();
        desktop.Shutdown();
    }

    /// <summary>Starts the updated Tailport.exe once this one has closed its tunnels, so their ports are free.</summary>
    async void Restart()
    {
        if (updater is null) return;
        var exe = updater.ExePath;
        await QuitAsync();
        try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false }); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    /// <summary>The tray menu mirrors the macOS menu bar item.</summary>
    void BuildTrayMenu()
    {
        if (tray?.Menu is not { } menu || viewModel is null) return;
        var model = viewModel.Model;
        // Rebuild only when something in the menu changes; refreshes otherwise churn the system tray.
        var key = string.Join("|", viewModel.TrayTitle, model.Router?.Target, model.RoutingBusy, model.HasAnyForwards,
            updater?.State.Kind, updater?.State.Release?.Version, updater?.Automatic,
            string.Join(",", model.Routers.Select(p => $"{p.Target}:{p.Online}:{p.Routes.Count}")));
        if (key == trayKey) return;
        trayKey = key;
        menu.Items.Clear();
        menu.Items.Add(new NativeMenuItem(viewModel.TrayTitle) { IsEnabled = false });
        if (updater?.State is { Kind: UpdateKind.Available, Release: { } release })
        {
            var install = new NativeMenuItem($"Install Tailport {release.Version} and restart");
            install.Click += (_, _) => _ = updater.InstallAsync(release);
            menu.Items.Add(install);
        }

        var routes = new NativeMenu();
        void AddRoute(string label, string? target, bool enabled = true)
        {
            var item = new NativeMenuItem(label)
            {
                ToggleType = NativeMenuItemToggleType.Radio,
                IsChecked = model.Router?.Target == target,
                IsEnabled = enabled && !model.RoutingBusy,
            };
            item.Click += (_, _) => _ = model.RouteThroughAsync(target);
            routes.Items.Add(item);
        }
        AddRoute("Off", null);
        foreach (var peer in model.Routers)
            AddRoute(peer.DisplayName + (peer.Routes.Count > 0 ? $" · {string.Join(", ", peer.Routes)}" : "") + (peer.Online ? "" : " · Offline"), peer.Target);
        menu.Items.Add(new NativeMenuItem("Route traffic through") { Menu = routes, IsEnabled = model.Routers.Count > 0 || model.Router is not null });

        var open = new NativeMenuItem("Open Tailport");
        open.Click += (_, _) => ShowWindow();
        menu.Items.Add(open);
        if (updater is { Enabled: true } checker)
        {
            var updates = new NativeMenu();
            var check = new NativeMenuItem("Check now") { IsEnabled = checker.State.Kind is not (UpdateKind.Checking or UpdateKind.Installing) };
            check.Click += (_, _) => { ShowWindow(); _ = checker.CheckAsync(manual: true); };
            updates.Items.Add(check);
            var automatic = new NativeMenuItem("Check automatically") { ToggleType = NativeMenuItemToggleType.CheckBox, IsChecked = checker.Automatic };
            automatic.Click += (_, _) => checker.Automatic = !checker.Automatic;
            updates.Items.Add(automatic);
            menu.Items.Add(new NativeMenuItem("Updates") { Menu = updates });
        }
        menu.Items.Add(new NativeMenuItemSeparator());
        var stop = new NativeMenuItem("Stop all forwarding") { IsEnabled = model.HasAnyForwards };
        stop.Click += (_, _) => model.StopAll();
        menu.Items.Add(stop);
        var quit = new NativeMenuItem("Quit Tailport");
        quit.Click += (_, _) => Quit();
        menu.Items.Add(quit);
        tray.ToolTipText = $"Tailport · {viewModel.TrayTitle}";
    }
}
