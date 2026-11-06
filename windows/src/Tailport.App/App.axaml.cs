using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;

namespace Tailport.App;

public partial class App : Application
{
    MainViewModel? viewModel;
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
            viewModel = new MainViewModel(model);
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
            BuildTrayMenu();
            model.Start();
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

    async void Quit()
    {
        if (viewModel is null || ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop) return;
        quitting = true;
        await viewModel.Model.ShutdownAsync();
        tray?.Dispose();
        desktop.Shutdown();
    }

    /// <summary>The tray menu mirrors the macOS menu bar item.</summary>
    void BuildTrayMenu()
    {
        if (tray?.Menu is not { } menu || viewModel is null) return;
        var model = viewModel.Model;
        // Rebuild only when something in the menu changes; refreshes otherwise churn the system tray.
        var key = string.Join("|", viewModel.TrayTitle, model.Router?.Target, model.RoutingBusy, model.HasAnyForwards,
            string.Join(",", model.Routers.Select(p => $"{p.Target}:{p.Online}:{p.Routes.Count}")));
        if (key == trayKey) return;
        trayKey = key;
        menu.Items.Clear();
        menu.Items.Add(new NativeMenuItem(viewModel.TrayTitle) { IsEnabled = false });

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
