using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Styling;
using Avalonia.Threading;
using Tailport;
using Tailport.App;

// Renders Tailport's windows off-screen with fake ssh and tailscale commands, then saves PNGs.
// Usage: dotnet run --project tools/Tailport.Screenshots -- <output-directory>
if (OperatingSystem.IsWindows()) { Console.Error.WriteLine("The screenshot tool uses shell-script fakes; run it on macOS or Linux."); return 1; }
var output = Path.GetFullPath(args.Length > 0 ? args[0] : "screenshots");
Directory.CreateDirectory(output);
var work = Directory.CreateTempSubdirectory("tailport-shots-");

string Fake(string name, string body)
{
    var path = Path.Combine(work.FullName, name);
    File.WriteAllText(path, "#!/bin/sh\n" + body + "\n");
    File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    return path;
}

var status = Path.Combine(work.FullName, "status.json");
File.WriteAllText(status, """
    {"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"Self":{"UserID":1},
     "User":{"1":{"DisplayName":"Ben"},"2":{"DisplayName":"Jack Grassby"}},"Peer":{
      "a":{"HostName":"th-pi-400","DNSName":"th-pi-400.example.ts.net.","TailscaleIPs":["100.64.0.4"],"UserID":1,"Online":true,"OS":"linux"},
      "b":{"HostName":"bh-pi-5","DNSName":"bh-pi-5.example.ts.net.","TailscaleIPs":["100.64.0.5"],"UserID":1,"Online":true,"OS":"linux",
           "ExitNodeOption":true,"PrimaryRoutes":["192.168.1.0/24"]},
      "c":{"HostName":"bh-mbp","DNSName":"bh-mbp.example.ts.net.","TailscaleIPs":["100.64.0.6"],"UserID":1,"Online":true,"OS":"macOS"},
      "d":{"HostName":"apple-tv","DNSName":"bh-atv.example.ts.net.","TailscaleIPs":["100.64.0.7"],"UserID":1,"Online":true,"OS":"tvOS","ExitNodeOption":true},
      "e":{"HostName":"GF-NICKHOME","DNSName":"gf-nickhome.example.ts.net.","TailscaleIPs":["100.64.0.8"],"UserID":2,"Online":true,"OS":"windows"}
    }}
    """);
var tailscale = Fake("tailscale", $"""
    case "$1" in
      status) cat '{status}';;
      set) echo '2026/11/06 16:51:04 Cannot advertise an exit node and use an exit node at the same time.' >&2; exit 1;;
    esac
    """);
var ssh = Fake("ssh", """
    case "$*" in
      *"127.0.0.1:3773:"*) echo 'bind [127.0.0.1]:3773: Address already in use' >&2; exit 255;;
      *TAILPORT_READY*) printf 'TAILPORT_READY\n'; exec cat >/dev/null;;
      *"/bin/sh -s"*) cat >/dev/null; printf '%s\n' 'S 192.168.1.0/24' \
          'H 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa' 'P 192.168.1.254 80' 'P 192.168.1.254 443' 'P 192.168.1.254 53' \
          'H 192.168.1.229 90:09:d0:16:91:c9 HD.lan' 'P 192.168.1.229 80' 'P 192.168.1.229 443' 'P 192.168.1.229 445' 'P 192.168.1.229 5000' 'P 192.168.1.229 5001' 'P 192.168.1.229 32400' \
          'H 192.168.1.72 b8:be:f4:a8:a6:e5 Lounge.lan' 'P 192.168.1.72 80' \
          'H 192.168.1.105 a8:e6:21:e3:20:4b' 'P 192.168.1.105 8888' \
          'H 192.168.1.201 d0:d2:b0:9c:0d:c9 Nest-Doorbell-Battery.lan' \
          'H 192.168.1.235 d4:a6:51:d6:88:ae';;
      *lsof*) case "$*" in *th-pi-400*) exit 0;; esac
          printf '%s\n' p1 cOrbStack n*:1029 p2 'cT3 Code' n127.0.0.1:3773 p3 cnode n*:5173 p4 cnode n*:3000 p5 cPython n*:8000 p6 crapportd n*:49193 p7 cControlCenter n*:7000;;
    esac
    """);

AppBuilder.Configure<App>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
AvaloniaSynchronizationContext.InstallIfNeeded();

void Pump(Func<bool> done, int seconds = 10)
{
    var until = DateTime.Now.AddSeconds(seconds);
    while (!done() && DateTime.Now < until) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(25); }
    Dispatcher.UIThread.RunJobs();
}

void Save(Window window, string name)
{
    Pump(() => false, 1);
    window.CaptureRenderedFrame()?.Save(Path.Combine(output, name + ".png"));
    Console.WriteLine($"captured {name}");
}

foreach (var theme in new[] { ThemeVariant.Dark, ThemeVariant.Light })
{
    Application.Current!.RequestedThemeVariant = theme;
    var label = theme == ThemeVariant.Dark ? "dark" : "light";
    var store = new SettingsStore(Path.Combine(work.FullName, $"settings-{label}.json"));
    store.Save(new Settings
    {
        Machine = "th-pi-400",
        Devices = new()
        {
            ["th-pi-400"] =
            [
                new("EE router", "192.168.1.254", 443, 10443),
                new("HD · Plex", "192.168.1.229", 32400, 32400),
                new("Nest-Cam", "192.168.1.141", 8080, 3773),
            ],
        },
    });
    var model = new AppModel(store, () => ssh, () => tailscale);
    var release = System.Text.Encoding.UTF8.GetBytes("""
        {"tag_name":"v0.3.0","html_url":"https://github.com/hybes/tailport/releases/tag/v0.3.0","assets":[
         {"name":"tailport-0.3.0-windows-app-x64.zip","browser_download_url":"https://example.com/x64.zip"},
         {"name":"SHA256SUMS","browser_download_url":"https://example.com/SHA256SUMS"}]}
        """);
    var updater = new Updater(model, "0.2.1", Path.Combine(work.FullName, "Tailport.exe"), _ => Task.FromResult(release),
        System.Runtime.InteropServices.Architecture.X64);
    var vm = new MainViewModel(model, updater);
    var main = new MainWindow { DataContext = vm, Width = 760, Height = 560 };
    main.Show();
    var refresh = model.RefreshAsync();
    Pump(() => refresh.IsCompleted);
    model.SetEnabled(true, model.Devices[0]);
    model.SetEnabled(true, model.Devices[2]);
    Pump(() => model.DeviceStates.Count == 2 && model.DeviceStates.Values.All(s => s.Kind != ForwardKind.Connecting));
    Save(main, $"{label}-1-devices");

    var check = updater.CheckAsync();
    Pump(() => check.IsCompleted);
    Save(main, $"{label}-8-update");
    var install = updater.InstallAsync(updater.State.Release!);
    Pump(() => install.IsCompleted);
    Save(main, $"{label}-9-update-failed");
    updater.Dismiss();
    updater.Dismiss();

    var route = model.RouteThroughAsync("bh-pi-5");
    Pump(() => route.IsCompleted);
    Save(main, $"{label}-2-route-error");

    main.Width = 620;
    main.Height = 440;
    Save(main, $"{label}-3-min-size");
    main.Width = 760;
    main.Height = 560;

    var add = new AddDeviceWindow { DataContext = vm };
    add.Show();
    Save(add, $"{label}-4-add-empty");
    var scan = model.ScanNetworkAsync();
    Pump(() => scan.IsCompleted);
    model.Connect(model.ScannedHosts.First(h => h.Ip == "192.168.1.229"), 32400);
    Pump(() => model.DeviceStates.Values.Count(s => s.Kind == ForwardKind.Forwarding) >= 2);
    Save(add, $"{label}-5-add-scan");
    add.Close();

    var exclusions = new ExclusionsWindow(model);
    exclusions.Show();
    Save(exclusions, $"{label}-7-exclusions");
    exclusions.Close();

    model.SelectMachine("bh-mbp");
    Pump(() => model.LastRefresh is not null);
    model.SetEnabled(true, model.Ports.First(p => p.Number == 5173));
    Pump(() => model.States.GetValueOrDefault(5173)?.Kind == ForwardKind.Forwarding);
    Save(main, $"{label}-6-ports");

    var shutdown = model.ShutdownAsync();
    Pump(() => shutdown.IsCompleted);
    main.Close();
}

work.Delete(true);
return 0;
