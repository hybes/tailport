namespace Tailport;

public enum ForwardKind { Connecting, Forwarding, Failed }

public sealed record ForwardState(ForwardKind Kind, string? Message = null)
{
    public static readonly ForwardState Connecting = new(ForwardKind.Connecting);
    public static readonly ForwardState Forwarding = new(ForwardKind.Forwarding);
    public static ForwardState Failed(string message) => new(ForwardKind.Failed, message);
}

/// <summary>
/// Everything Tailport shows and does, independent of the UI. Call it from one thread (the UI thread);
/// SSH callbacks are posted back to the synchronisation context the model was created on.
/// </summary>
public sealed class AppModel
{
    readonly SettingsStore store;
    readonly Settings settings;
    readonly Func<string> ssh;
    readonly Func<string> tailscale;
    readonly Dictionary<int, SshForward> sessions = [];
    readonly Dictionary<string, SshForward> deviceSessions = [];
    IgnoreRules rules;
    Guid generation = Guid.NewGuid();
    CancellationTokenSource? polling;

    public AppModel(SettingsStore store, Func<string>? ssh = null, Func<string>? tailscale = null)
    {
        this.store = store;
        this.ssh = ssh ?? Tools.Ssh;
        this.tailscale = tailscale ?? Tools.Tailscale;
        settings = store.Load();
        Machine = settings.Machine ?? "";
        Devices = settings.Devices.GetValueOrDefault(Machine) ?? [];
        try
        {
            rules = new IgnoreRules(settings.IgnoredPorts ?? IgnoreRules.DefaultPorts, settings.IgnoredProcesses ?? IgnoreRules.DefaultProcesses);
            IgnoredPorts = settings.IgnoredPorts ?? IgnoreRules.DefaultPorts;
            IgnoredProcesses = settings.IgnoredProcesses ?? IgnoreRules.DefaultProcesses;
        }
        catch (TailportException)
        {
            rules = new IgnoreRules(IgnoreRules.DefaultPorts, IgnoreRules.DefaultProcesses);
            IgnoredPorts = IgnoreRules.DefaultPorts;
            IgnoredProcesses = IgnoreRules.DefaultProcesses;
        }
    }

    /// <summary>Raised on the UI thread whenever anything visible changes.</summary>
    public event Action? Changed;

    public List<Peer> Peers { get; private set; } = [];
    public string Machine { get; private set; }
    public List<ListeningPort> Ports { get; private set; } = [];
    public Dictionary<int, ForwardState> States { get; } = [];
    public List<NetworkDevice> Devices { get; private set; }
    public Dictionary<string, ForwardState> DeviceStates { get; } = [];
    public List<ScannedHost> ScannedHosts { get; private set; } = [];
    public string? ScannedSubnet { get; private set; }
    public bool Scanning { get; private set; }
    public string? ScanError { get; private set; }
    public bool Refreshing { get; private set; }
    public string? Error { get; private set; }
    public DateTime? LastRefresh { get; private set; }
    public bool DiscoveryAvailable { get; private set; }
    public string IgnoredPorts { get; private set; }
    public string IgnoredProcesses { get; private set; }
    public bool RoutingBusy { get; private set; }
    public string? RoutingError { get; private set; }

    bool showIgnored;
    public bool ShowIgnored { get => showIgnored; set { showIgnored = value; Notify(); } }

    public List<ListeningPort> EligiblePorts => Ports.Where(rules.Allows).ToList();
    public List<ListeningPort> VisiblePorts => ShowIgnored ? Ports : EligiblePorts;
    public int IgnoredCount => Ports.Count - EligiblePorts.Count;
    public int ForwardingCount => States.Values.Concat(DeviceStates.Values).Count(s => s.Kind == ForwardKind.Forwarding);
    public int FailedCount => States.Values.Concat(DeviceStates.Values).Count(s => s.Kind == ForwardKind.Failed);
    public bool HasForwards => sessions.Count > 0;
    public bool HasAnyForwards => sessions.Count > 0 || deviceSessions.Count > 0;
    public string MachineName => Peers.FirstOrDefault(p => p.Target == Machine)?.Name ?? Machine;
    /// <summary>Online peers this computer can send its traffic through, plus the current one if it has gone offline.</summary>
    public List<Peer> Routers => Peers.Where(p => p.IsExitNode || (p.Online && p.ExitNodeOption)).ToList();
    public Peer? Router => Peers.FirstOrDefault(p => p.IsExitNode);
    public bool IsEnabled(ListeningPort port) => sessions.ContainsKey(port.Number);
    public bool IsEnabled(NetworkDevice device) => deviceSessions.ContainsKey(device.Id);
    public string? IgnoreReason(ListeningPort port) => rules.Reason(port);

    void Notify() => Changed?.Invoke();

    public void Start()
    {
        if (polling is not null) return;
        polling = new CancellationTokenSource();
        var token = polling.Token;
        Loop();
        async void Loop()
        {
            while (!token.IsCancellationRequested)
            {
                await RefreshAsync();
                try { await Task.Delay(TimeSpan.FromSeconds(10), token); } catch (OperationCanceledException) { return; }
            }
        }
    }

    public void SelectMachine(string target)
    {
        if (Machine == target) return;
        generation = Guid.NewGuid();
        StopAll();
        Machine = target;
        settings.Machine = target;
        Save();
        Devices = settings.Devices.GetValueOrDefault(target) ?? [];
        ScannedHosts = [];
        ScannedSubnet = null;
        ScanError = null;
        Scanning = false;
        Ports = [];
        LastRefresh = null;
        DiscoveryAvailable = false;
        Refreshing = false;
        Error = null;
        Notify();
        _ = RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        if (Refreshing) return;
        Refreshing = true;
        Notify();
        var request = generation;
        try
        {
            var loaded = await LoadPeersAsync();
            if (request != generation) return;
            Peers = loaded;
            if (Machine.Length == 0 && (Peers.FirstOrDefault(p => p.Online && p.Os == "macOS") ?? Peers.FirstOrDefault(p => p.Online)) is { } first)
            {
                Machine = first.Target;
                Devices = settings.Devices.GetValueOrDefault(Machine) ?? [];
            }
            if (!Peers.Any(p => p.Target == Machine && p.Online))
                throw new TailportException(Machine.Length == 0
                    ? "No machines are online. Check Tailscale, then refresh."
                    : $"{MachineName} is offline or unavailable. Wake it and check Tailscale, then refresh.");
            var target = Machine;
            var scan = await Commands.RunAsync(ssh(), [.. Ssh.Options, "--", target, Ssh.DiscoveryCommand]);
            if (request != generation) return;
            if (scan.Status != 0) throw new TailportException(Ssh.Explain(scan.Error, target));
            AcceptDiscovery(ListeningPort.Parse(scan.Output));
        }
        catch (TailportException error)
        {
            if (request != generation) return;
            Error = error.Message;
            DiscoveryAvailable = false;
        }
        finally
        {
            if (request == generation) Refreshing = false;
            Notify();
        }
    }

    async Task<List<Peer>> LoadPeersAsync()
    {
        var result = await Commands.RunAsync(tailscale(), ["status", "--json"]);
        if (result.Status != 0)
            throw new TailportException(result.Error.Trim().Length == 0 ? "Tailscale could not list machines. Open Tailscale and refresh." : result.Error.Trim());
        return Peer.Decode(result.Output);
    }

    public void AcceptDiscovery(List<ListeningPort> discovered)
    {
        foreach (var number in sessions.Keys.ToList())
        {
            var updated = discovered.FirstOrDefault(p => p.Number == number);
            var previous = Ports.FirstOrDefault(p => p.Number == number);
            if (updated is null || !rules.Allows(updated) || previous?.Destination != updated.Destination) Stop(number);
        }
        Ports = discovered;
        DiscoveryAvailable = true;
        LastRefresh = DateTime.Now;
        Error = null;
        Notify();
    }

    public void SetEnabled(bool enabled, ListeningPort port)
    {
        if (!enabled) { Stop(port.Number); Notify(); return; }
        if (!DiscoveryAvailable || !rules.Allows(port) || sessions.ContainsKey(port.Number)) return;
        var number = port.Number;
        Begin(port, sessions, States, number);
    }

    public void SetEnabled(bool enabled, NetworkDevice device)
    {
        if (!enabled) { StopDevice(device.Id); Notify(); return; }
        if (deviceSessions.ContainsKey(device.Id)) return;
        Begin(device.Forward, deviceSessions, DeviceStates, device.Id);
    }

    void Begin<TKey>(ListeningPort port, Dictionary<TKey, SshForward> table, Dictionary<TKey, ForwardState> states, TKey key) where TKey : notnull
    {
        string executable;
        try { executable = ssh(); }
        catch (TailportException error) { states[key] = ForwardState.Failed(error.Message); Notify(); return; }
        var session = new SshForward(Machine, port, executable,
            ready => { if (table.TryGetValue(key, out var s) && s.Id == ready.Id) { states[key] = ForwardState.Forwarding; Notify(); } },
            (ended, message) =>
            {
                if (!table.TryGetValue(key, out var s) || s.Id != ended.Id) return;
                table.Remove(key);
                if (message is null) states.Remove(key); else states[key] = ForwardState.Failed(message);
                Notify();
            });
        table[key] = session;
        states[key] = ForwardState.Connecting;
        try { session.Start(); }
        catch (TailportException error)
        {
            table.Remove(key);
            states[key] = ForwardState.Failed(error.Message);
        }
        Notify();
    }

    public void SetAllEnabled(bool enabled)
    {
        if (!enabled) { StopPorts(); Notify(); return; }
        foreach (var port in EligiblePorts) SetEnabled(true, port);
    }

    void Stop(int number)
    {
        if (sessions.Remove(number, out var session)) session.Stop();
        States.Remove(number);
    }

    void StopDevice(string key)
    {
        if (deviceSessions.Remove(key, out var session)) session.Stop();
        DeviceStates.Remove(key);
    }

    /// <summary>Stops forwarded listening ports. Network devices are left alone.</summary>
    public void StopPorts()
    {
        foreach (var number in sessions.Keys.ToList()) Stop(number);
        States.Clear();
    }

    public void StopAll()
    {
        StopPorts();
        foreach (var key in deviceSessions.Keys.ToList()) StopDevice(key);
        DeviceStates.Clear();
        Notify();
    }

    /// <summary>Adds a device on the selected machine's network, remembered for that machine.</summary>
    public NetworkDevice AddDevice(string name, string address)
    {
        var device = NetworkDevice.Parse(name, address, Devices.Select(d => d.LocalPort).ToHashSet());
        if (Devices.Any(d => d.Id == device.Id)) throw new TailportException($"{device.Address} is already in the list.");
        Devices = [.. Devices, device];
        SaveDevices();
        Notify();
        return device;
    }

    public void RemoveDevice(NetworkDevice device)
    {
        StopDevice(device.Id);
        Devices = Devices.Where(d => d.Id != device.Id).ToList();
        SaveDevices();
        Notify();
    }

    /// <summary>The local port a scanned port would open on if forwarded now.</summary>
    public int LocalPort(ScannedHost host, int port)
    {
        try { return NetworkDevice.Parse("", $"{host.Ip}:{port}", Devices.Select(d => d.LocalPort).ToHashSet()).LocalPort; }
        catch (TailportException) { return port; }
    }

    /// <summary>Adds a port found by a scan, or reuses the saved device, and starts forwarding it.</summary>
    public void Connect(ScannedHost host, int port)
    {
        var device = Devices.FirstOrDefault(d => d.Host == host.Ip && d.Port == port)
            ?? AddDevice(NetworkScan.DeviceName(host, port), $"{host.Ip}:{port}");
        SetEnabled(true, device);
    }

    /// <summary>Lists devices on the selected machine's local network and their common open ports.</summary>
    public async Task ScanNetworkAsync()
    {
        if (Scanning) return;
        var request = generation;
        var target = Machine;
        Scanning = true;
        ScanError = null;
        Notify();
        try
        {
            var result = await Commands.RunAsync(ssh(), [.. Ssh.Options, "--", target, "/bin/sh", "-s"], TimeSpan.FromSeconds(60), NetworkScan.Script);
            if (request != generation) return;
            if (result.Error.Contains("tailport: no local network found"))
                throw new TailportException($"{MachineName} is not connected to a local network.");
            if (result.Status != 0) throw new TailportException(Ssh.Explain(result.Error, target));
            (ScannedSubnet, ScannedHosts) = NetworkScan.Parse(result.Output);
        }
        catch (TailportException error)
        {
            if (request == generation) ScanError = error.Message;
        }
        finally
        {
            if (request == generation) Scanning = false;
            Notify();
        }
    }

    /// <summary>Sends this computer's traffic through <paramref name="target"/> as a Tailscale exit node, or stops when null.</summary>
    public async Task RouteThroughAsync(string? target)
    {
        if (RoutingBusy) return;
        var peer = target is null ? null : Peers.FirstOrDefault(p => p.Target == target);
        if (target is not null && (peer is null || peer.Address.Length == 0)) return;
        RoutingBusy = true;
        RoutingError = null;
        Notify();
        try
        {
            var result = await Commands.RunAsync(tailscale(), Routing.Arguments(peer));
            if (result.Status != 0) RoutingError = Routing.Explain(result.Error, peer);
            Peers = await LoadPeersAsync();
            if (result.Status == 0 && peer is not null && Router?.Target != peer.Target) RoutingError = Routing.Explain("", peer);
        }
        catch (TailportException error) { RoutingError = error.Message; }
        finally
        {
            RoutingBusy = false;
            Notify();
        }
    }

    public void ApplyExclusions(string ports, string processes)
    {
        var updated = new IgnoreRules(ports, processes);
        rules = updated;
        IgnoredPorts = ports;
        IgnoredProcesses = processes;
        settings.IgnoredPorts = ports;
        settings.IgnoredProcesses = processes;
        Save();
        foreach (var port in Ports.Where(p => !updated.Allows(p))) Stop(port.Number);
        Notify();
    }

    public void Ignore(ListeningPort port)
    {
        try { ApplyExclusions(IgnoredPorts.Length == 0 ? $"{port.Number}" : $"{IgnoredPorts}, {port.Number}", IgnoredProcesses); }
        catch (TailportException) { }
    }

    public async Task ShutdownAsync()
    {
        polling?.Cancel();
        polling = null;
        generation = Guid.NewGuid();
        var closing = sessions.Values.Concat(deviceSessions.Values).ToList();
        StopAll();
        for (var i = 0; i < 20 && closing.Any(s => s.IsRunning); i++) await Task.Delay(50);
        closing.ForEach(s => s.ForceStop());
    }

    void SaveDevices()
    {
        if (Devices.Count == 0) settings.Devices.Remove(Machine); else settings.Devices[Machine] = Devices;
        Save();
    }

    void Save()
    {
        try { store.Save(settings); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
