using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Tailport.Tests;

public class DiscoveryTests
{
    [Fact]
    public void ListenersMergeIPv4IPv6AndProcessesAndKeepBoundAddresses()
    {
        var output = string.Join('\n', "p123", "cnode", "f12", "n127.0.0.1:3000", "f13", "n[::1]:3000", "p456", "cControlCenter",
            "n*:7000", "p789", "cOther process", "n*:3000", "n100.64.0.2:8080", "n[fd7a:115c::2]:8081", "n127.0.0.2:8082",
            "nnot-an-address:1234", "n*:70000");
        var ports = ListeningPort.Parse(output);
        Assert.Equal([3000, 7000, 8080, 8081, 8082], ports.Select(p => p.Number));
        Assert.Equal(["Other process", "node"], ports[0].Processes);
        Assert.Equal("localhost", ports[0].Destination);
        Assert.Equal("100.64.0.2", ports[2].Destination);
        Assert.Equal("fd7a:115c::2", ports[3].Destination);
        Assert.Equal("127.0.0.2", ports[4].Destination);
        Assert.Empty(ListeningPort.Parse("warning: cannot inspect process\r\nn*:0\nn*:abc\nnmissing"));
    }

    [Fact]
    public void DefaultRulesIgnoreSystemServicesWithoutBlockingDevelopmentPorts()
    {
        var rules = new IgnoreRules(IgnoreRules.DefaultPorts, IgnoreRules.DefaultProcesses);
        ListeningPort[] listeners =
        [
            new(22, ["sshd"]), new(5000, ["ControlCenter"]), new(7000, ["ControlCenter"]), new(49193, ["rapportd"]),
            new(3000, ["node"]), new(5000, ["Python"]), new(7000, ["node"]),
        ];
        Assert.Equal([3000, 5000, 7000], listeners.Where(rules.Allows).Select(p => p.Number));
        var custom = new IgnoreRules("3000, 8000-8002\n9000", "Node, My App");
        Assert.False(custom.Allows(new(8001, ["Python"])));
        Assert.False(custom.Allows(new(5173, ["node"])));
        Assert.True(custom.Allows(new(5173, ["ControlCenter", "Python"])));
        foreach (var bad in new[] { "0", "65536", "8-7", "-1", "1-", "1-2-3", "hello", "0-2" })
            Assert.Throws<TailportException>(() => new IgnoreRules(bad, ""));
    }

    [Fact]
    public void PeerNamesMatchTailscaleAndSharedMachinesGroupByOwner()
    {
        const string json = """
            {"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"Self":{"UserID":1},
             "User":{"1":{"DisplayName":"Ben"},"2":{"DisplayName":"Jack Grassby"}},"Peer":{
              "a":{"HostName":"apple-tv","DNSName":"bh-atv.example.ts.net.","TailscaleIPs":["100.64.0.3"],"UserID":1,"Online":true},
              "b":{"HostName":"th-pi-400","DNSName":"th-pi-400.example.ts.net.","UserID":1,"Online":false,
                   "ExitNodeOption":true,"PrimaryRoutes":["192.168.1.0/24","0.0.0.0/0"],"TailscaleIPs":["100.64.0.5"]},
              "c":{"HostName":"GF-NICKHOME","DNSName":"gf-nickhome.example.ts.net.","UserID":2,"Online":true},
              "d":{"DNSName":"-invalid.example.ts.net.","Online":true}
            }}
            """;
        var peers = Peer.Decode(json);
        Assert.Equal(["bh-atv (apple-tv)", "gf-nickhome", "th-pi-400"], peers.Select(p => p.DisplayName));
        Assert.Equal(["bh-atv", "gf-nickhome", "th-pi-400"], peers.Select(p => p.Target));
        var pi = peers.Single(p => p.Name == "th-pi-400");
        Assert.False(pi.Online);
        Assert.True(pi.ExitNodeOption);
        Assert.Equal(["192.168.1.0/24"], pi.Routes);
        var groups = Peer.Grouped(peers);
        Assert.Equal([null, "Jack Grassby"], groups.Select(g => g.Owner));
        Assert.Throws<TailportException>(() => Peer.Decode("""{"BackendState":"Stopped"}"""));
        Assert.Throws<TailportException>(() => Peer.Decode("The Tailscale CLI failed to start"));
        Assert.Equal("100.64.0.2", Peer.Decode("""
            {"BackendState":"Running","Peer":{"one":{"HostName":"Mac mini","DNSName":"bh-mm.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true}}}
            """).Single().Target);
    }

    [Fact]
    public void ForwardArgumentsBindBothLoopbacksAndTargetRemoteAddresses()
    {
        var arguments = Ssh.ForwardingArguments("bh-mm", new ListeningPort(3000, ["node"], "fd7a:115c::2"));
        Assert.Contains("127.0.0.1:3000:[fd7a:115c::2]:3000", arguments);
        Assert.Contains("[::1]:3000:[fd7a:115c::2]:3000", arguments);
        Assert.Contains("ExitOnForwardFailure=yes", arguments);
        Assert.Contains("StrictHostKeyChecking=yes", arguments);
        Assert.Equal(["--", "bh-mm", Ssh.ForwardingCommand], arguments.TakeLast(3));
        var router = new NetworkDevice("Router", "192.168.1.254", 80, 10080);
        Assert.Contains("127.0.0.1:10080:192.168.1.254:80", Ssh.ForwardingArguments("th-pi-400", router.Forward));
    }

    [Fact]
    public void SshErrorsAreExplainedIncludingWindowsBindFailures()
    {
        Assert.StartsWith("Local port 3000 is already in use", Ssh.Explain("bind [127.0.0.1]:3000: Permission denied", "bh-mm", 3000));
        Assert.StartsWith("Local port 3000 is already in use", Ssh.Explain("bind: Address already in use", "bh-mm", 3000));
        Assert.StartsWith("SSH access needs attention", Ssh.Explain("ben@bh-mm: Permission denied (publickey).", "bh-mm", 3000));
        Assert.StartsWith("Port discovery needs lsof on th-pi-400", Ssh.Explain("tailport: lsof not found", "th-pi-400"));
        Assert.StartsWith("Cannot reach bh-mm", Ssh.Explain("ssh: connect to host bh-mm port 22: Connection timed out", "bh-mm"));
    }
}

public class RoutingTests
{
    [Fact]
    public void ArgumentsSetOrClearTheExitNodeAndAcceptSharedSubnets()
    {
        var pi = new Peer("bh-pi-5", "bh-pi-5", true, "linux", "100.64.0.5", true, Routes: ["192.168.1.0/24"]);
        var cloud = new Peer("uk1", "uk1", true, "linux", "100.64.0.6", true);
        Assert.Equal(["set", "--exit-node=100.64.0.5", "--accept-routes"], Routing.Arguments(pi));
        Assert.Equal(["set", "--exit-node=100.64.0.6"], Routing.Arguments(cloud));
        Assert.Equal(["set", "--exit-node="], Routing.Arguments(null));
    }

    [Fact]
    public void ErrorsDropTimestampsAndExplainCommonRefusals()
    {
        var pi = new Peer("bh-pi-5", "bh-pi-5", true, "linux", "100.64.0.5");
        Assert.StartsWith("bh-pi-5 no longer offers routing.", Routing.Explain("2026/11/06 16:48:12 node \"100.64.0.5\" is not advertising an exit node\n", pi));
        Assert.StartsWith("This computer is set to run as an exit node.", Routing.Explain("2026/11/06 16:51:04 Cannot advertise an exit node and use an exit node at the same time.", pi));
        Assert.Equal("something else failed", Routing.Explain("2026/11/06 16:48:12 something else failed\n", pi));
        Assert.Equal("Tailscale could not stop routing. Open Tailscale and try again.", Routing.Explain("", null));
    }
}

public class DeviceTests
{
    [Fact]
    public void AddressParsingMovesLowPortsAndAvoidsTakenLocalPorts()
    {
        var router = NetworkDevice.Parse(" EE router ", " 192.168.1.254:80 ", new HashSet<int>());
        Assert.Equal(new NetworkDevice("EE router", "192.168.1.254", 80, 10080), router);
        Assert.Equal("http://localhost:10080/", router.Url?.ToString());
        Assert.Equal(10081, NetworkDevice.Parse("", "192.168.1.254", new HashSet<int> { 10080 }).LocalPort);
        Assert.Equal("https://localhost:8443/", NetworkDevice.Parse("", "nas.lan:8443", new HashSet<int>()).Url?.ToString());
        var ipv6 = NetworkDevice.Parse("", "[fd00::1]:443", new HashSet<int>());
        Assert.Equal("fd00::1", ipv6.Host);
        Assert.Equal("[fd00::1]:443", ipv6.Address);
        Assert.Equal("[fd00::1]:80", NetworkDevice.Parse("", "fd00::1", new HashSet<int>()).Address);
        foreach (var bad in new[] { "", "192.168.1.254:0", "192.168.1.254:70000", "host:abc", "-oProxyCommand=x:80", "bad host:80", "a;b:80" })
            Assert.Throws<TailportException>(() => NetworkDevice.Parse("", bad, new HashSet<int>()));
    }

    [Fact]
    public void KnownPortsGetNamesAndLinks()
    {
        var hd = new ScannedHost("192.168.1.229", "90:09:d0:16:91:c9", "HD.lan", []);
        Assert.Equal("HD · Plex", NetworkScan.DeviceName(hd, 32400));
        Assert.Equal("HD · Minecraft", NetworkScan.DeviceName(hd, 25565));
        Assert.Equal("HD", NetworkScan.DeviceName(hd, 443));
        Assert.Null(NetworkScan.Service(5000));
        string? Url(int port) => new NetworkDevice("", "h", port, 10000 + port % 10000).Url?.ToString();
        Assert.Equal("smb://localhost:10445/", Url(445));
        Assert.Equal("vnc://localhost:15900/", Url(5900));
        Assert.Null(Url(25565));
    }

    [Fact]
    public void ScanParseGroupsPortsByHostWithOpenPortsFirst()
    {
        var output = "S 192.168.1.0/24\r\nP 192.168.1.254 443\nH 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa\n" +
                     "H 192.168.1.71 f0:09:0d:63:de:10 deco-X10.lan\nP 192.168.1.254 80\nH 192.168.1.9 b4:1f:4d:46:49:e4\n" +
                     "P not-an-ip 80\nP 192.168.1.9 99999\ngarbage\n";
        var (subnet, hosts) = NetworkScan.Parse(output);
        Assert.Equal("192.168.1.0/24", subnet);
        Assert.Equal(["192.168.1.254", "192.168.1.9", "192.168.1.71"], hosts.Select(h => h.Ip));
        Assert.Equal([80, 443], hosts[0].Ports);
        Assert.Equal("hub", hosts[0].Label);
        Assert.Equal("deco-X10", hosts[2].Label);
    }
}

/// <summary>The Windows app and the macOS app must run the same remote commands.</summary>
public class SharedWithMacTests
{
    static string Swift() => File.ReadAllText(Path.Combine(Repo(), "macos", "Sources", "Tailport", "Discovery.swift"));

    static string Repo()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "VERSION")) && Directory.Exists(Path.Combine(dir.FullName, "macos"))) return dir.FullName;
        throw new InvalidOperationException("Repository root not found");
    }

    [Fact]
    public void ScanScriptMatchesTheMacApp()
    {
        var swift = Swift().Replace("\r\n", "\n");
        var match = Regex.Match(swift, "private static let template = #\"\"\"\n(.*?)\"\"\"#", RegexOptions.Singleline);
        Assert.True(match.Success);
        Assert.Equal(match.Groups[1].Value, NetworkScan.LoadTemplate());
        Assert.DoesNotContain("@PORTS@", NetworkScan.Script);
        Assert.DoesNotContain("\r", NetworkScan.Script);
    }

    [Fact]
    public void PortListAndCommandsMatchTheMacApp()
    {
        var swift = Swift();
        var list = Regex.Match(swift, @"static let ports = \[([^\]]*)\]").Groups[1].Value;
        Assert.Equal(list.Split(',').Select(p => int.Parse(p.Trim())), NetworkScan.Ports);
        Assert.Contains(Ssh.ForwardingCommand.Replace("\\", "\\\\"), swift);
        Assert.Contains("TAILPORT_READY", Ssh.ForwardingCommand);
    }
}

/// <summary>Runs the real scan script against stub tools, so no network is touched. Needs a POSIX shell.</summary>
public class ScanScriptTests
{
    [Fact]
    public void ScriptOnLinuxFindsNeighboursNamesAndOpenPorts()
    {
        if (OperatingSystem.IsWindows() || !File.Exists("/bin/sh")) return;
        var directory = Directory.CreateTempSubdirectory("tailport-scan-");
        try
        {
            void Stub(string name, string body)
            {
                var path = Path.Combine(directory.FullName, name);
                File.WriteAllText(path, $"#!/bin/sh\n{body}\n");
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            Stub("uname", "echo Linux");
            Stub("ip", """
                case "$*" in
                  *"route show default"*) echo 'default via 10.9.8.254 dev eth0 proto dhcp src 10.9.8.20 metric 100';;
                  *"addr show dev eth0"*) echo '2: eth0    inet 10.9.8.20/24 brd 10.9.8.255 scope global eth0';;
                  *"neigh show dev eth0"*) printf '%s\n' '10.9.8.254 lladdr 60:8d:26:cc:fa:63 REACHABLE' '10.9.8.30 lladdr aa:bb:cc:dd:ee:ff STALE' '10.9.8.31  FAILED';;
                esac
                """);
            Stub("ping", "exit 0");
            Stub("nc", "case \"$*\" in *'10.9.8.254 443'*|*'10.9.8.30 22'*) exit 0;; esac; exit 1");
            Stub("getent", "[ \"$2\" = 10.9.8.254 ] && echo '10.9.8.254 hub.home.arpa'");
            Stub("timeout", "shift; exec \"$@\"");
            var info = new ProcessStartInfo("/bin/sh", ["-s"]) { RedirectStandardInput = true, RedirectStandardOutput = true };
            info.Environment["PATH"] = $"{directory.FullName}:/usr/bin:/bin";
            using var process = Process.Start(info)!;
            process.StandardInput.Write(NetworkScan.Script);
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            var (subnet, hosts) = NetworkScan.Parse(output);
            Assert.Equal("10.9.8.0/24", subnet);
            Assert.Equal(new HashSet<string> { "10.9.8.30", "10.9.8.254" }, hosts.Select(h => h.Ip).ToHashSet());
            Assert.Equal("hub.home.arpa", hosts.Single(h => h.Ip == "10.9.8.254").Name);
            Assert.Equal([443], hosts.Single(h => h.Ip == "10.9.8.254").Ports);
        }
        finally { directory.Delete(true); }
    }
}
