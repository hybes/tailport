using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text.RegularExpressions;

namespace Tailport;

/// <summary>A device on the selected machine's network, such as its router, reached through an SSH forward.</summary>
public sealed record NetworkDevice(string Name, string Host, int Port, int LocalPort)
{
    public string Id => $"{Host}:{Port}";
    public string Address => Host.Contains(':') ? $"[{Host}]:{Port}" : $"{Host}:{Port}";
    public Uri? Url => NetworkScan.Scheme(Port) is { } scheme ? new Uri($"{scheme}://localhost:{LocalPort}") : null;
    public ListeningPort Forward => new(LocalPort, [Name], Host, Port);

    /// <summary>
    /// Parses an address such as <c>192.168.1.254:80</c>, <c>router.lan:8080</c> or <c>[fd00::1]:80</c>.
    /// Low ports are moved above 10000 locally (80 becomes 10080), avoiding common local servers.
    /// </summary>
    public static NetworkDevice Parse(string name, string address, IReadOnlySet<int> taken)
    {
        address = address.Trim();
        string host, portText;
        if (address.StartsWith('[') && address.IndexOf(']') is > 0 and var close)
        {
            host = address[1..close];
            var rest = address[(close + 1)..];
            portText = rest.StartsWith(':') ? rest[1..] : "";
        }
        else if (address.IndexOf(':') is >= 0 and var colon && address.LastIndexOf(':') == colon)
        {
            host = address[..colon];
            portText = address[(colon + 1)..];
        }
        else
        {
            host = address;
            portText = "80";
        }
        if (host.Length == 0 || host.StartsWith('-') || !host.All(c => char.IsAsciiLetterOrDigit(c) || ".-_:%".Contains(c)))
            throw new TailportException("Enter an address such as 192.168.1.254:80.");
        if (!int.TryParse(portText, out var port) || port is < 1 or > 65535)
            throw new TailportException("Use a port between 1 and 65535, such as 192.168.1.254:80.");
        var local = port < 1024 ? 10000 + port : port;
        while (taken.Contains(local) && local < 65535) local++;
        var label = name.Trim();
        return new NetworkDevice(label.Length == 0 ? host : label, host, port, local);
    }
}

public sealed partial record ScannedHost(string Ip, string Mac, string Name, IReadOnlyList<int> Ports)
{
    public string Label => Name.Length == 0 ? Ip : LocalSuffix().Replace(Name, "");

    [GeneratedRegex(@"\.(lan|local|home|home\.arpa)$")]
    private static partial Regex LocalSuffix();
}

/// <summary>
/// Finds devices on the remote machine's local network. It runs there as a POSIX shell script over SSH,
/// using only ping, nc and the neighbour table, so nothing needs installing.
/// </summary>
public static class NetworkScan
{
    /// <summary>
    /// TCP ports probed on each device: web and admin pages, file sharing, media servers, home automation,
    /// development servers and games. UDP services, such as Minecraft Bedrock, cannot be forwarded over SSH.
    /// </summary>
    public static readonly IReadOnlyList<int> Ports =
    [
        21, 22, 23, 53, 80, 81, 139, 443, 445, 548, 554, 631, 1880, 1883, 3000, 3001, 3306, 3389,
        4000, 4200, 4321, 5000, 5001, 5173, 5174, 5432, 5900, 6379, 7878, 8000, 8008, 8080, 8081,
        8096, 8123, 8384, 8443, 8888, 8989, 9000, 9090, 9091, 9100, 9443, 10000, 25565, 27017, 32400,
    ];

    /// <summary>Only well-established uses are named; ports such as 5000 or 8888 vary too much to guess.</summary>
    static readonly Dictionary<int, string> Services = new()
    {
        [21] = "FTP", [22] = "SSH", [23] = "Telnet", [53] = "DNS", [80] = "Web", [81] = "Web", [139] = "File sharing",
        [443] = "Web", [445] = "File sharing", [548] = "AFP", [554] = "Camera", [631] = "Printer", [1880] = "Node-RED",
        [1883] = "MQTT", [3000] = "Dev server", [3001] = "Dev server", [3306] = "MySQL", [3389] = "Remote Desktop",
        [4000] = "Dev server", [4200] = "Angular", [4321] = "Astro", [5173] = "Vite", [5174] = "Vite",
        [5432] = "PostgreSQL", [5900] = "Screen sharing", [6379] = "Redis", [7878] = "Radarr", [8080] = "Web",
        [8096] = "Jellyfin", [8123] = "Home Assistant", [8384] = "Syncthing", [8443] = "Web", [8989] = "Sonarr",
        [9091] = "Transmission", [9100] = "Printer", [10000] = "Webmin", [25565] = "Minecraft", [27017] = "MongoDB",
        [32400] = "Plex",
    };

    public static readonly string Script = LoadTemplate().Replace("@PORTS@", string.Join(' ', Ports));

    internal static string LoadTemplate()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Tailport.scan.sh")!;
        // The script runs under /bin/sh on the remote machine, so it must keep Unix line endings.
        return new StreamReader(stream).ReadToEnd().Replace("\r\n", "\n");
    }

    public static string? Service(int port) => Services.GetValueOrDefault(port);

    /// <summary>How a forwarded port is opened, or null for services that need their own app, such as Minecraft.</summary>
    public static string? Scheme(int port) => port switch
    {
        443 or 5001 or 8443 or 9443 or 10000 => "https",
        22 => "ssh",
        139 or 445 => "smb",
        548 => "afp",
        5900 => "vnc",
        21 or 23 or 53 or 554 or 631 or 1883 or 3306 or 3389 or 5432 or 6379 or 9100 or 25565 or 27017 => null,
        _ => "http",
    };

    /// <summary>The default name for a device found by a scan, such as "HD · Plex". Web pages keep the device's own name.</summary>
    public static string DeviceName(ScannedHost host, int port) =>
        Service(port) is { } service && service != "Web" ? $"{host.Label} · {service}" : host.Label;

    /// <summary>Devices with open ports come first, each group in address order.</summary>
    public static (string? Subnet, List<ScannedHost> Hosts) Parse(string output)
    {
        string? subnet = null;
        var hosts = new Dictionary<string, (string Mac, string Name)>();
        var ports = new Dictionary<string, SortedSet<int>>();
        foreach (var line in output.Split('\n'))
        {
            var fields = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length == 0) continue;
            if (fields[0] == "S" && fields.Length >= 2) { subnet = fields[1]; continue; }
            if (fields.Length < 3 || !IPAddress.TryParse(fields[1], out var ip) || ip.AddressFamily != AddressFamily.InterNetwork) continue;
            if (fields[0] == "H") hosts[fields[1]] = (fields[2], fields.Length > 3 ? fields[3] : "");
            else if (fields[0] == "P" && int.TryParse(fields[2], out var port) && port is >= 1 and <= 65535)
                (ports.TryGetValue(fields[1], out var set) ? set : ports[fields[1]] = []).Add(port);
        }
        var found = hosts.Select(h => new ScannedHost(h.Key, h.Value.Mac, h.Value.Name,
                ports.TryGetValue(h.Key, out var set) ? set.ToList() : []))
            .OrderBy(h => h.Ports.Count == 0 ? 1 : 0).ThenBy(h => Order(h.Ip)).ToList();
        return (subnet, found);
    }

    static long Order(string ip) => ip.Split('.').Aggregate(0L, (sum, part) => sum * 256 + (long.TryParse(part, out var n) ? n : 0));
}
