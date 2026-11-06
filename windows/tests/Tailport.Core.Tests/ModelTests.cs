namespace Tailport.Tests;

/// <summary>
/// Drives the model with fake ssh and tailscale executables. The fakes are shell scripts on macOS and Linux
/// and batch files on Windows.
/// </summary>
public sealed class ModelTests : IDisposable
{
    readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("tailport-model-");
    public void Dispose() => directory.Delete(true);

    string Fake(string name, string unix, string windows)
    {
        var path = Path.Combine(directory.FullName, OperatingSystem.IsWindows() ? name + ".cmd" : name);
        File.WriteAllText(path, OperatingSystem.IsWindows() ? "@echo off\r\n" + windows.Replace("\n", "\r\n") + "\r\n" : "#!/bin/sh\n" + unix + "\n");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }

    static async Task Until(Func<bool> condition)
    {
        for (var i = 0; i < 300 && !condition(); i++) await Task.Delay(10);
    }

    [Fact]
    public async Task DevicesAreRememberedPerMachineAndForwardIndependentlyOfPorts()
    {
        // Batch files cannot keep a stdin-driven SSH session alive, so the forwarding half runs on Unix only.
        if (OperatingSystem.IsWindows()) return;
        var log = Path.Combine(directory.FullName, "args");
        var ssh = Fake("ssh", $"printf '%s\\n' \"$@\" >> '{log}'\nprintf 'TAILPORT_READY\\n'\nexec /bin/cat >/dev/null", "");
        var store = new SettingsStore(Path.Combine(directory.FullName, "settings.json"));
        store.Save(new Settings { Machine = "th-pi-400" });
        var model = new AppModel(store, () => ssh);
        var router = model.AddDevice("EE router", "192.168.1.254:443");
        Assert.Throws<TailportException>(() => model.AddDevice("Again", "192.168.1.254:443"));
        Assert.Equal(8080, model.AddDevice("", "192.168.1.254:8080").LocalPort);

        model.SetEnabled(true, router);
        await Until(() => model.DeviceStates.GetValueOrDefault(router.Id)?.Kind == ForwardKind.Forwarding);
        Assert.Equal(ForwardKind.Forwarding, model.DeviceStates[router.Id].Kind);
        Assert.Equal(1, model.ForwardingCount);
        Assert.False(model.HasForwards, "All ports only covers listening ports");
        model.SetAllEnabled(false);
        Assert.True(model.IsEnabled(router), "Turning off all ports leaves devices running");
        Assert.Contains("127.0.0.1:10443:192.168.1.254:443", File.ReadAllLines(log));

        var restored = new AppModel(store);
        Assert.Equal(["EE router", "192.168.1.254"], restored.Devices.Select(d => d.Name));

        model.RemoveDevice(router);
        Assert.False(model.IsEnabled(router));
        Assert.Equal([8080], new AppModel(store).Devices.Select(d => d.Port));
        await model.ShutdownAsync();
    }

    [Fact]
    public async Task ForwardFailureIsExplainedAndNeverReportsReady()
    {
        var ssh = Fake("ssh", "printf 'bind [127.0.0.1]:3000: Address already in use\\n' >&2\nexit 255",
                       "echo bind [127.0.0.1]:3000: Permission denied 1>&2\nexit /b 255");
        var model = new AppModel(new SettingsStore(Path.Combine(directory.FullName, "s.json")), () => ssh);
        model.AcceptDiscovery([new ListeningPort(3000, ["node"])]);
        model.SetEnabled(true, model.Ports[0]);
        await Until(() => model.States.GetValueOrDefault(3000)?.Kind == ForwardKind.Failed);
        Assert.Equal(ForwardKind.Failed, model.States[3000].Kind);
        Assert.StartsWith("Local port 3000 is already in use", model.States[3000].Message);
        Assert.False(model.HasForwards);
        Assert.Equal(1, model.FailedCount);
    }

    [Fact]
    public async Task ScanSendsTheScriptAndRoutingReflectsTailscale()
    {
        var received = Path.Combine(directory.FullName, "stdin");
        var ssh = Fake("ssh",
            $"cat > '{received}'; printf 'S 192.168.1.0/24\\nH 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa\\nP 192.168.1.254 443\\n'",
            $"more > \"{received}\"\necho S 192.168.1.0/24\necho H 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa\necho P 192.168.1.254 443");
        var status = Path.Combine(directory.FullName, "status.json");
        File.WriteAllText(status, """
            {"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"Peer":{
              "pi":{"HostName":"bh-pi-5","DNSName":"bh-pi-5.example.ts.net.","TailscaleIPs":["100.64.0.5"],"Online":true,"ExitNodeOption":true},
              "uk":{"HostName":"uk1","DNSName":"uk1.example.ts.net.","TailscaleIPs":["100.64.0.6"],"Online":true,"ExitNodeOption":true}}}
            """);
        var tailscale = Fake("tailscale",
            $"case \"$1\" in status) cat '{status}';; set) case \"$2\" in *100.64.0.6) echo '2026/11/06 16:48:12 node \"100.64.0.6\" is not advertising an exit node' >&2; exit 1;; esac;; esac",
            // cmd.exe splits arguments at "=", so match the exit node anywhere in the arguments instead of by position.
            $"if \"%1\"==\"status\" type \"{status}\"\nif \"%1\"==\"set\" echo %*| findstr /c:\"100.64.0.6\" >nul && (echo 2026/11/06 16:48:12 node \"100.64.0.6\" is not advertising an exit node 1>&2\nexit /b 1)");
        var model = new AppModel(new SettingsStore(Path.Combine(directory.FullName, "s.json")), () => ssh, () => tailscale);
        await model.ScanNetworkAsync();
        Assert.Null(model.ScanError);
        Assert.Contains("ports=\"21 22", File.ReadAllText(received));
        Assert.Equal([443], model.ScannedHosts.Single().Ports);

        await model.RouteThroughAsync(null);
        Assert.Equal(["bh-pi-5", "uk1"], model.Routers.Select(p => p.Target));
        await model.RouteThroughAsync("uk1");
        Assert.StartsWith("uk1 no longer offers routing.", model.RoutingError);
        Assert.False(model.RoutingBusy);
    }
}
