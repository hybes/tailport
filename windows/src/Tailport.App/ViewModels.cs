using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace Tailport.App;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    protected void RaiseChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>An entry in a machine list: a machine, the "Off" choice, or a non-selectable owner heading.</summary>
public sealed record PeerOption(string? Target, string Label, bool IsHeader = false)
{
    public bool IsSelectable => !IsHeader;
    public override string ToString() => Label;
}

/// <summary>A status line under a row title: a plain detail, a success or a failure.</summary>
public sealed class StatusLine(string? detail, string? message, bool ok)
{
    public string? Detail { get; } = detail;
    public string? Message { get; } = message;
    public bool HasDetail => Detail is not null;
    public bool IsOk => Message is not null && ok;
    public bool IsFailed => Message is not null && !ok;
}

public sealed class DeviceRow(MainViewModel owner, NetworkDevice device) : ObservableObject
{
    public NetworkDevice Device { get; private set; } = device;
    public string Id => Device.Id;

    string name = "";
    public string Name { get => name; private set => Set(ref name, value); }
    StatusLine status = new(null, null, true);
    public StatusLine Status { get => status; private set => Set(ref status, value); }
    string? link;
    public string? Link { get => link; private set => Set(ref link, value); }
    bool hasLink;
    public bool HasLink { get => hasLink; private set => Set(ref hasLink, value); }
    bool isOn;
    public bool IsOn
    {
        get => isOn;
        set { if (Set(ref isOn, value) && !owner.Syncing) owner.Model.SetEnabled(value, Device); }
    }

    public void Update(AppModel model, NetworkDevice device)
    {
        Device = device;
        Name = device.Name;
        var state = model.DeviceStates.GetValueOrDefault(device.Id);
        Status = state?.Kind switch
        {
            ForwardKind.Connecting => new StatusLine("Connecting…", null, true),
            ForwardKind.Forwarding => new StatusLine(null, $"{device.Address} via {model.MachineName}", true),
            ForwardKind.Failed => new StatusLine(device.Address, state.Message, false),
            _ => new StatusLine($"{device.Address} → localhost:{device.LocalPort}", null, true),
        };
        Link = state?.Kind == ForwardKind.Forwarding ? $"localhost:{device.LocalPort}" : null;
        HasLink = Link is not null;
        var on = model.IsEnabled(device);
        if (isOn != on) { isOn = on; RaiseChanged(nameof(IsOn)); }
    }

    public void Open() { if (Device.Url is { } url) Shell.Open(url.ToString()); }
    public bool CanOpen => Device.Url is not null;
}

public sealed class PortRow(MainViewModel owner, ListeningPort port) : ObservableObject
{
    public ListeningPort Port { get; private set; } = port;
    public int Number => Port.Number;
    public string NumberText => Port.Number.ToString();

    string service = "";
    public string Service { get => service; private set => Set(ref service, value); }
    StatusLine status = new(null, null, true);
    public StatusLine Status { get => status; private set => Set(ref status, value); }
    string? link;
    public string? Link { get => link; private set => Set(ref link, value); }
    bool hasLink;
    public bool HasLink { get => hasLink; private set => Set(ref hasLink, value); }
    bool canToggle;
    public bool CanToggle { get => canToggle; private set => Set(ref canToggle, value); }
    bool isExcluded;
    public bool IsExcluded { get => isExcluded; private set => Set(ref isExcluded, value); }
    bool isOn;
    public bool IsOn
    {
        get => isOn;
        set { if (Set(ref isOn, value) && !owner.Syncing) owner.Model.SetEnabled(value, Port); }
    }

    public void Update(AppModel model, ListeningPort port)
    {
        Port = port;
        Service = port.Service;
        var reason = model.IgnoreReason(port);
        var state = model.States.GetValueOrDefault(port.Number);
        Status = reason is not null ? new StatusLine($"Excluded · {reason}", null, true) : state?.Kind switch
        {
            ForwardKind.Connecting => new StatusLine("Connecting…", null, true),
            ForwardKind.Forwarding => new StatusLine(null, "Forwarding", true),
            ForwardKind.Failed => new StatusLine(null, state.Message, false),
            _ => new StatusLine($"Opens at localhost:{port.Number} when on", null, true),
        };
        Link = state?.Kind == ForwardKind.Forwarding ? $"localhost:{port.Number}" : null;
        HasLink = Link is not null;
        IsExcluded = reason is not null;
        CanToggle = reason is null && (model.DiscoveryAvailable || model.IsEnabled(port));
        var on = model.IsEnabled(port);
        if (isOn != on) { isOn = on; RaiseChanged(nameof(IsOn)); }
    }

    public void Open() => Shell.Open($"http://localhost:{Port.Number}");
    public void Exclude() => owner.Model.Ignore(Port);
}

public sealed class PortChip(MainViewModel owner, ScannedHost host, int port) : ObservableObject
{
    public string? ServiceName { get; } = NetworkScan.Service(port);
    public bool HasService => ServiceName is not null;
    public string PortText { get; } = port.ToString();
    bool isOn;
    public bool IsOn { get => isOn; set => Set(ref isOn, value); }
    string tip = "";
    public string Tip { get => tip; set => Set(ref tip, value); }

    public void Update(AppModel model)
    {
        var device = model.Devices.FirstOrDefault(d => d.Host == host.Ip && d.Port == port);
        IsOn = device is not null && model.IsEnabled(device);
        Tip = IsOn ? $"Forwarding to localhost:{device!.LocalPort}" : $"Opens at localhost:{device?.LocalPort ?? model.LocalPort(host, port)}";
    }

    public string? Connect()
    {
        try { owner.Model.Connect(host, port); return null; }
        catch (TailportException error) { return error.Message; }
    }
}

public sealed class ScanHostRow(ScannedHost host, IReadOnlyList<PortChip> chips)
{
    public ScannedHost Host { get; } = host;
    public string Label => Host.Label;
    public string Ip => Host.Ip;
    public bool ShowIp => Host.Label != Host.Ip;
    public IReadOnlyList<PortChip> Chips { get; } = chips;
    public bool HasPorts => Chips.Count > 0;
    public bool HasNoPorts => Chips.Count == 0;
}

static class Shell
{
    public static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException) { }
    }
}

public sealed class MainViewModel : ObservableObject
{
    public AppModel Model { get; }
    public bool Syncing { get; private set; }

    public MainViewModel(AppModel model, Updater? updater = null)
    {
        Model = model;
        Updater = updater;
        model.Changed += Sync;
        if (updater is not null) updater.Changed += SyncUpdate;
        Sync();
    }

    public Updater? Updater { get; }

    // Update banner
    public bool HasUpdate { get; private set; }
    public string UpdateText { get; private set; } = "";
    public string? UpdateDetail { get; private set; }
    public bool HasUpdateDetail => UpdateDetail is not null;
    public bool UpdateBusy { get; private set; }
    public bool UpdateFailed { get; private set; }
    public string? UpdateInstallLabel { get; private set; }
    public bool UpdateCanInstall => UpdateInstallLabel is not null;
    public string? UpdateDismissLabel { get; private set; }
    public bool UpdateCanDismiss => UpdateDismissLabel is not null;
    public string? UpdatePageLabel { get; private set; }
    public bool UpdateHasPage => UpdatePageLabel is not null;

    public void InstallUpdate() { if (Updater?.State.Release is { } release) _ = Updater.InstallAsync(release); }
    public void DismissUpdate() => Updater?.Dismiss();
    public void OpenUpdatePage() => Shell.Open(Updater?.State.Release?.Page ?? $"https://github.com/{UpdateSource.Repository}/releases/latest");

    void SyncUpdate()
    {
        var state = Updater?.State ?? UpdateState.Idle;
        var current = Updater?.Current;
        (HasUpdate, UpdateText, UpdateDetail, UpdateBusy, UpdateFailed, UpdateInstallLabel, UpdateDismissLabel, UpdatePageLabel) = state switch
        {
            { Kind: UpdateKind.Checking, Manual: true } => (true, "Checking for updates…", null, true, false, null, null, null),
            { Kind: UpdateKind.UpToDate } => (true, $"Tailport {current} is the latest version.", null, false, false, null, "OK", null),
            { Kind: UpdateKind.Available, Release: { } release } => (true, $"Tailport {release.Version} is available. You have {current}.",
                Model.HasAnyForwards ? "Forwarding stops while Tailport restarts." : null, false, false, "Install and restart", "Later", "What’s new"),
            { Kind: UpdateKind.Installing, Release: { } release } => (true, $"Installing Tailport {release.Version}…", null, true, false, null, null, null),
            { Kind: UpdateKind.Failed, Release: { } } => (true, state.Message ?? "", null, false, true, "Try again", null, "Download from GitHub"),
            { Kind: UpdateKind.Failed } => (true, state.Message ?? "", null, false, true, null, "OK", null),
            _ => (false, "", (string?)null, false, false, (string?)null, (string?)null, (string?)null),
        };
        foreach (var name in new[]
        {
            nameof(HasUpdate), nameof(UpdateText), nameof(UpdateDetail), nameof(HasUpdateDetail), nameof(UpdateBusy), nameof(UpdateFailed),
            nameof(UpdateInstallLabel), nameof(UpdateCanInstall), nameof(UpdateDismissLabel), nameof(UpdateCanDismiss),
            nameof(UpdatePageLabel), nameof(UpdateHasPage),
        }) RaiseChanged(name);
    }

    public ObservableCollection<PeerOption> Machines { get; } = [];
    public ObservableCollection<PeerOption> Routers { get; } = [];
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public ObservableCollection<PortRow> Ports { get; } = [];
    public ObservableCollection<ScanHostRow> ScanHosts { get; } = [];

    PeerOption? selectedMachine;
    public PeerOption? SelectedMachine
    {
        get => selectedMachine;
        set
        {
            if (value is { IsHeader: true }) return;
            if (Set(ref selectedMachine, value) && !Syncing && value?.Target is { } target) Model.SelectMachine(target);
        }
    }

    PeerOption? selectedRouter;
    public PeerOption? SelectedRouter
    {
        get => selectedRouter;
        set
        {
            if (value is { IsHeader: true }) return;
            if (Set(ref selectedRouter, value) && !Syncing && value is not null) _ = Model.RouteThroughAsync(value.Target);
        }
    }

    public bool Refreshing => Model.Refreshing;
    public bool RoutingBusy => Model.RoutingBusy;
    public bool RoutersAvailable => !Model.RoutingBusy && (Model.Routers.Count > 0 || Model.Router is not null);
    public StatusLine? RoutingStatus { get; private set; }
    public bool HasRoutingStatus => RoutingStatus is not null;
    public string? Error => Model.Error;
    public bool HasError => Model.Error is not null;
    public bool HasDevices => Devices.Count > 0;
    public string DevicesTitle => $"Devices on {Model.MachineName}’s network";
    public string PortsTitle => $"Listening ports on {Model.MachineName}";
    public bool HasPorts => Ports.Count > 0;
    public string? PortsPlaceholder { get; private set; }
    public bool HasPortsPlaceholder => PortsPlaceholder is not null;
    public bool ShowList => Devices.Count > 0 || Ports.Count > 0;
    public bool ShowEmptyState => !ShowList;
    public string EmptyTitle { get; private set; } = "";
    public string EmptyMessage { get; private set; } = "";
    public bool EmptyBusy { get; private set; }
    public bool ShowAllPorts => Model.EligiblePorts.Count > 0 || Model.HasForwards;
    public bool AllPortsEnabled => Model.EligiblePorts.Count > 0 && (Model.DiscoveryAvailable || Model.HasForwards);
    public string MachineName => Model.MachineName;
    public string ShowIgnoredLabel => $"Show excluded ({Model.IgnoredCount})";
    public string FooterStatus { get; private set; } = "";

    public bool AllPorts
    {
        get => Model.HasForwards;
        set { if (!Syncing) Model.SetAllEnabled(value); }
    }

    public bool ShowIgnored
    {
        get => Model.ShowIgnored;
        set { if (!Syncing) Model.ShowIgnored = value; }
    }

    // Add device sheet
    public bool Scanning => Model.Scanning;
    public bool CanScan => !Model.Scanning;
    public string? ScanError => Model.ScanError;
    public bool HasScanError => Model.ScanError is not null;
    public bool HasScanResults => ScanHosts.Count > 0;
    public string ScanButtonLabel => Model.ScannedSubnet is null ? "Scan network" : "Scan again";
    public string ScanSummary => Model.Scanning ? $"Scanning {Model.MachineName}’s network…"
        : Model.ScannedSubnet is null ? "Find devices and their open ports."
        : $"{Model.ScannedHosts.Count} {(Model.ScannedHosts.Count == 1 ? "device" : "devices")} on {Model.ScannedSubnet}. Click a port to forward it.";
    public string AddDeviceIntro => $"Forward a device on {Model.MachineName}’s network, such as its router, to this computer over SSH.";

    public string TrayTitle => Model.ForwardingCount == 0 ? "Nothing forwarding" : $"{Model.ForwardingCount} forwarding";

    void Sync()
    {
        Syncing = true;
        try
        {
            SyncOptions(Machines, MachineOptions());
            SyncOptions(Routers, RouterOptions());
            selectedMachine = Machines.FirstOrDefault(o => o.Target == Model.Machine);
            selectedRouter = Routers.FirstOrDefault(o => o.Target == Model.Router?.Target) ?? Routers.FirstOrDefault();
            RoutingStatus = Model.RoutingError is { } routingError ? new StatusLine(null, routingError, false)
                : Model.Router is { } router
                    ? router.Online ? new StatusLine(Routing.Summary(router), null, true)
                        : new StatusLine(null, $"{router.Name} is offline, so this computer may have no internet access. Choose Off or another device.", false)
                : Model.Peers.Count > 0 && Model.Routers.Count == 0
                    ? new StatusLine("No online device offers routing. Turn on “Run as exit node” on one, then approve it in the Tailscale admin console.", null, true)
                    : null;

            SyncRows(Devices, Model.Devices, d => d.Id, row => row.Id, d => new DeviceRow(this, d), (row, d) => row.Update(Model, d));
            SyncRows(Ports, Model.VisiblePorts, p => p.Number, row => row.Number, p => new PortRow(this, p), (row, p) => row.Update(Model, p));

            PortsPlaceholder = Ports.Count > 0 ? null
                : Model.Refreshing && Model.LastRefresh is null ? "Finding listening ports…"
                : Model.Error is not null ? "Ports unavailable. See the message above."
                : Model.IgnoredCount > 0 ? "All listening ports are excluded."
                : "No listening ports found.";
            EmptyBusy = Model.Refreshing && Model.LastRefresh is null;
            (EmptyTitle, EmptyMessage) = EmptyBusy ? ("Finding listening ports…", "")
                : Model.Error is not null ? ("Ports unavailable", $"Fix the connection above, then refresh. You can still add a device on {Model.MachineName}’s network.")
                : Model.IgnoredCount > 0 ? ("All ports are excluded", "Show excluded ports or edit your exclusions.")
                : ("No listening ports", $"Start a development server on {Model.MachineName}, or add a device on its network, such as its router.");

            var parts = new List<string>();
            if (Model.ForwardingCount > 0) parts.Add($"{Model.ForwardingCount} forwarding");
            if (Model.FailedCount > 0) parts.Add($"{Model.FailedCount} failed");
            FooterStatus = parts.Count > 0 ? string.Join(" · ", parts) : Model.LastRefresh is { } checkedAt ? $"Checked {checkedAt:HH:mm}" : "";

            ScanHosts.Clear();
            foreach (var host in Model.ScannedHosts)
            {
                var chips = host.Ports.Select(port => new PortChip(this, host, port)).ToList();
                chips.ForEach(chip => chip.Update(Model));
                ScanHosts.Add(new ScanHostRow(host, chips));
            }
        }
        finally { Syncing = false; }
        RaiseAll();
        SyncUpdate();
    }

    List<PeerOption> MachineOptions()
    {
        var options = new List<PeerOption>();
        if (Model.Machine.Length > 0 && !Model.Peers.Any(p => p.Target == Model.Machine)) options.Add(new PeerOption(Model.Machine, Model.Machine));
        foreach (var (owner, peers) in Peer.Grouped(Model.Peers))
        {
            if (owner is not null) options.Add(new PeerOption(null, owner, IsHeader: true));
            options.AddRange(peers.Select(p => new PeerOption(p.Target, p.Online ? p.DisplayName : $"{p.DisplayName} · Offline")));
        }
        return options;
    }

    List<PeerOption> RouterOptions()
    {
        var options = new List<PeerOption> { new(null, "Off") };
        foreach (var (owner, peers) in Peer.Grouped(Model.Routers))
        {
            if (owner is not null) options.Add(new PeerOption(null, owner, IsHeader: true));
            options.AddRange(peers.Select(p =>
                new PeerOption(p.Target, (p.Online ? p.DisplayName : $"{p.DisplayName} · Offline") + (p.Routes.Count > 0 ? $" · {string.Join(", ", p.Routes)}" : ""))));
        }
        return options;
    }

    static void SyncOptions(ObservableCollection<PeerOption> target, List<PeerOption> source)
    {
        if (target.SequenceEqual(source)) return;
        target.Clear();
        foreach (var option in source) target.Add(option);
    }

    /// <summary>Updates rows in place so switches and scroll position survive refreshes.</summary>
    static void SyncRows<TItem, TRow, TKey>(ObservableCollection<TRow> rows, List<TItem> items, Func<TItem, TKey> itemKey,
                                            Func<TRow, TKey> rowKey, Func<TItem, TRow> create, Action<TRow, TItem> update)
        where TKey : notnull
    {
        var keys = items.Select(itemKey).ToHashSet();
        for (var i = rows.Count - 1; i >= 0; i--) if (!keys.Contains(rowKey(rows[i]))) rows.RemoveAt(i);
        for (var index = 0; index < items.Count; index++)
        {
            var key = itemKey(items[index]);
            var existing = rows.Select((row, i) => (row, i)).FirstOrDefault(x => EqualityComparer<TKey>.Default.Equals(rowKey(x.row), key));
            TRow row;
            if (existing.row is null) { row = create(items[index]); rows.Insert(index, row); }
            else
            {
                row = existing.row;
                if (existing.i != index) rows.Move(existing.i, index);
            }
            update(row, items[index]);
        }
    }

    void RaiseAll()
    {
        foreach (var name in new[]
        {
            nameof(SelectedMachine), nameof(SelectedRouter), nameof(Refreshing), nameof(RoutingBusy), nameof(RoutersAvailable),
            nameof(RoutingStatus), nameof(HasRoutingStatus), nameof(Error), nameof(HasError), nameof(HasDevices), nameof(DevicesTitle),
            nameof(PortsTitle), nameof(HasPorts), nameof(PortsPlaceholder), nameof(HasPortsPlaceholder), nameof(ShowList),
            nameof(ShowEmptyState), nameof(EmptyTitle), nameof(EmptyMessage), nameof(EmptyBusy), nameof(ShowAllPorts),
            nameof(AllPortsEnabled), nameof(AllPorts), nameof(MachineName), nameof(ShowIgnored), nameof(ShowIgnoredLabel),
            nameof(FooterStatus), nameof(Scanning), nameof(CanScan), nameof(ScanError), nameof(HasScanError), nameof(HasScanResults),
            nameof(ScanButtonLabel), nameof(ScanSummary), nameof(AddDeviceIntro), nameof(TrayTitle),
        }) RaiseChanged(name);
    }
}
