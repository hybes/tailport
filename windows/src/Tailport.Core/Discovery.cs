using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Tailport;

public sealed class TailportException(string message) : Exception(message);

/// <summary>A machine on the Tailscale network.</summary>
public sealed record Peer(
    string Name,
    string Target,
    bool Online,
    string Os,
    string Address = "",
    bool ExitNodeOption = false,
    bool IsExitNode = false,
    IReadOnlyList<string>? Routes = null,
    string HostName = "",
    string? Owner = null)
{
    public IReadOnlyList<string> Routes { get; init; } = Routes ?? [];

    /// <summary>Matches Tailscale's menu: "bh-atv (apple-tv)".</summary>
    public string DisplayName =>
        HostName.Length == 0 || string.Equals(HostName, Name, StringComparison.OrdinalIgnoreCase) ? Name : $"{Name} ({HostName})";

    /// <summary>Your machines first, then machines shared by each other person, as in Tailscale's menu.</summary>
    public static List<(string? Owner, List<Peer> Peers)> Grouped(IEnumerable<Peer> peers)
    {
        var list = peers.ToList();
        var owners = list.Select(p => p.Owner).OfType<string>().Distinct().Order(StringComparer.CurrentCultureIgnoreCase);
        return new string?[] { null }.Concat(owners)
            .Select(owner => (owner, list.Where(p => p.Owner == owner).ToList()))
            .Where(group => group.Item2.Count > 0)
            .ToList();
    }

    public static List<Peer> Decode(string json)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(json); }
        catch (JsonException) { throw new TailportException("Tailscale could not list your machines. Open Tailscale, check it is connected, then refresh."); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Text(root, "BackendState") != "Running")
                throw new TailportException("Tailscale is not connected. Open Tailscale, connect, then refresh.");
            var magicDns = root.TryGetProperty("CurrentTailnet", out var tailnet) && tailnet.ValueKind == JsonValueKind.Object &&
                           tailnet.TryGetProperty("MagicDNSEnabled", out var magic) && magic.ValueKind == JsonValueKind.True;
            long? self = root.TryGetProperty("Self", out var selfNode) && selfNode.ValueKind == JsonValueKind.Object ? Number(selfNode, "UserID") : null;
            var peers = new List<Peer>();
            if (!root.TryGetProperty("Peer", out var peerMap) || peerMap.ValueKind != JsonValueKind.Object) return peers;
            foreach (var entry in peerMap.EnumerateObject())
            {
                var node = entry.Value;
                var dns = (Text(node, "DNSName") ?? "").Trim('.');
                var addresses = Strings(node, "TailscaleIPs");
                var target = magicDns && dns.Length > 0 ? dns.Split('.')[0] : addresses.FirstOrDefault() ?? "";
                if (target.Length == 0 || target.StartsWith('-') || target.Any(char.IsWhiteSpace)) continue;
                var hostName = Text(node, "HostName") ?? "";
                var machine = dns.Length == 0 ? (hostName.Length > 0 ? hostName : target) : dns.Split('.')[0];
                string? owner = null;
                if (Number(node, "UserID") is { } user && user != self)
                {
                    var profile = root.TryGetProperty("User", out var users) && users.ValueKind == JsonValueKind.Object &&
                                  users.TryGetProperty(user.ToString(), out var p) ? p : default;
                    owner = profile.ValueKind == JsonValueKind.Object
                        ? Text(profile, "DisplayName") ?? Text(profile, "LoginName") ?? "Shared with you"
                        : "Shared with you";
                }
                peers.Add(new Peer(machine, target, Bool(node, "Online"), Text(node, "OS") ?? "",
                    addresses.FirstOrDefault() ?? "", Bool(node, "ExitNodeOption"), Bool(node, "ExitNode"),
                    Strings(node, "PrimaryRoutes").Where(r => r != "0.0.0.0/0" && r != "::/0").ToList(), hostName, owner));
            }
            return peers.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }
    }

    static string? Text(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    static bool Bool(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
    static long? Number(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;
    static List<string> Strings(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToList()
            : [];
}

/// <summary>A TCP listener on the selected machine, or the forward for a network device.</summary>
public sealed record ListeningPort(int Number, IReadOnlyList<string> Processes, string Destination = "localhost", int? RemotePort = null)
{
    public string Service => string.Join(", ", Processes);

    /// <summary>Parses <c>lsof -Fpcn</c> output, merging IPv4 and IPv6 listeners on the same port.</summary>
    public static List<ListeningPort> Parse(string output)
    {
        var process = "Unknown process";
        var ports = new Dictionary<int, (List<string> Processes, string Destination)>();
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;
            var field = line[0];
            var value = line[1..];
            if (field == 'p') process = "Unknown process";
            if (field == 'c') process = value;
            if (field != 'n') continue;
            var colon = value.LastIndexOf(':');
            if (colon < 0 || !int.TryParse(value[(colon + 1)..], out var number) || number is < 1 or > 65535) continue;
            var host = value[..colon].Trim('[', ']');
            var address = host.Split('%', 2)[0];
            if (host != "*" && !IPAddress.TryParse(address, out _)) continue;
            var loopback = host == "*" || address is "0.0.0.0" or "::" or "::1" or "127.0.0.1";
            var destination = loopback ? "localhost" : host;
            if (ports.TryGetValue(number, out var existing))
            {
                if (!existing.Processes.Contains(process)) { existing.Processes.Add(process); existing.Processes.Sort(StringComparer.Ordinal); }
                ports[number] = (existing.Processes, destination == "localhost" ? destination : existing.Destination);
            }
            else ports[number] = ([process], destination);
        }
        return ports.OrderBy(p => p.Key).Select(p => new ListeningPort(p.Key, p.Value.Processes, p.Value.Destination)).ToList();
    }
}

/// <summary>Ports and process names that stay off, such as system services.</summary>
public sealed class IgnoreRules
{
    public const string DefaultPorts = "22, 53, 88, 111, 139, 445, 548, 631, 2049, 3283, 5900";
    public const string DefaultProcesses = "ControlCenter, rapportd, sharingd, mDNSResponder, sshd, launchd, cupsd, remoted, AirPlayXPCHelper, cloudflared, SetappAgent";

    public IReadOnlySet<int> Ports { get; }
    public IReadOnlySet<string> Processes { get; }

    public IgnoreRules(string ports, string processes)
    {
        var numbers = new HashSet<int>();
        foreach (var token in ports.Split([',', ' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries))
        {
            var bounds = token.Split('-');
            if (bounds.Length is < 1 or > 2 || !int.TryParse(bounds[0], out var first) || first is < 1 or > 65535 ||
                !int.TryParse(bounds.Length == 2 ? bounds[1] : bounds[0], out var last) || last < first || last > 65535)
                throw new TailportException("Use ports between 1 and 65535, separated by commas. Ranges such as 8000-8010 are also supported.");
            for (var n = first; n <= last; n++) numbers.Add(n);
        }
        Ports = numbers;
        Processes = processes.Split(',').Select(p => p.Trim().ToLowerInvariant()).Where(p => p.Length > 0).ToHashSet();
    }

    public string? Reason(ListeningPort port)
    {
        if (Ports.Contains(port.Number)) return $"Port {port.Number} is excluded";
        if (port.Processes.Count > 0 && port.Processes.All(p => Processes.Contains(p.ToLowerInvariant()))) return "System or excluded service";
        return null;
    }

    public bool Allows(ListeningPort port) => Reason(port) is null;
}

public static class Ssh
{
    public static readonly IReadOnlyList<string> Options =
    [
        "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
        "-o", "ControlMaster=no", "-o", "ControlPath=none",
    ];

    // macOS keeps lsof in /usr/sbin; Linux usually has it on the PATH. Kept identical to the macOS app.
    public const string DiscoveryCommand = "l=/usr/sbin/lsof; [ -x \"$l\" ] || l=$(command -v lsof) || { echo 'tailport: lsof not found' >&2; exit 127; }; LC_ALL=C \"$l\" -nP -iTCP -sTCP:LISTEN -Fpcn; result=$?; [ \"$result\" -eq 0 ] || [ \"$result\" -eq 1 ]";

    /// <summary>The remote marker confirms SSH is authenticated and local listeners are ready.</summary>
    public const string ForwardingCommand = "/usr/bin/printf 'TAILPORT_READY\\n'; exec /bin/cat > /dev/null";

    public static List<string> ForwardingArguments(string target, ListeningPort port)
    {
        var host = port.Destination.Contains(':') ? $"[{port.Destination}]" : port.Destination;
        var remote = port.RemotePort ?? port.Number;
        return [.. Options, "-o", "ExitOnForwardFailure=yes",
            "-L", $"127.0.0.1:{port.Number}:{host}:{remote}",
            "-L", $"[::1]:{port.Number}:{host}:{remote}",
            "--", target, ForwardingCommand];
    }

    public static string Explain(string text, string target, int? port = null)
    {
        bool Has(string s) => text.Contains(s, StringComparison.OrdinalIgnoreCase);
        // Windows reports a busy or reserved local port as "bind ... Permission denied", so check binds first.
        if (port is { } p && (Has("address already in use") || (Has("bind") && Has("permission denied")) || Has("cannot listen to port")))
            return $"Local port {p} is already in use. Stop its other server or tunnel, then try again.";
        if (Has("permission denied") || Has("host key verification failed") || text.Contains("host key is known"))
            return $"SSH access needs attention. Connect once in a terminal with ‘ssh {target}’, then try again.";
        if (text.Contains("tailport: lsof not found"))
            return $"Port discovery needs lsof on {target}. Install it there, or add network devices instead.";
        if (Has("could not resolve") || Has("timed out") || Has("no route to host"))
            return $"Cannot reach {target}. Check Tailscale and that the machine is awake, then refresh.";
        var trimmed = text.Trim();
        return trimmed.Length == 0 ? "The connection closed. Toggle the port to reconnect." : trimmed[..Math.Min(400, trimmed.Length)];
    }
}

public static partial class Routing
{
    public static List<string> Arguments(Peer? peer)
    {
        // Subnets shared by the peer, such as its home network, are only reachable with routes accepted.
        var arguments = new List<string> { "set", $"--exit-node={peer?.Address ?? ""}" };
        if (peer is { Routes.Count: > 0 }) arguments.Add("--accept-routes");
        return arguments;
    }

    public static string Summary(Peer peer)
    {
        var routes = peer.Routes.Count == 0 ? "" : $" Its network {string.Join(", ", peer.Routes)} is reachable.";
        return $"This computer’s internet traffic goes through {peer.Name}.{routes}";
    }

    public static string Explain(string text, Peer? peer)
    {
        // The Tailscale CLI prefixes errors with a timestamp such as "2026/11/06 16:48:12 ".
        var message = Timestamp().Replace(text, "").Trim();
        if (message.Contains("is not advertising an exit node") && peer is not null)
            return $"{peer.Name} no longer offers routing. Turn on “Run as exit node” on it, then approve it in the Tailscale admin console.";
        if (message.Contains("Cannot advertise an exit node and use an exit node"))
            return "This computer is set to run as an exit node. Turn off “Run as exit node” in Tailscale’s menu, then try again.";
        if (message.Length == 0)
            return peer is null ? "Tailscale could not stop routing. Open Tailscale and try again."
                : $"Tailscale could not route through {peer.Name}. Open Tailscale and try again.";
        return message[..Math.Min(400, message.Length)];
    }

    [GeneratedRegex(@"(?m)^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ")]
    private static partial Regex Timestamp();
}
