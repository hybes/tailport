import Foundation
import Darwin

struct TailportError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Peer: Identifiable, Equatable {
    let name: String
    let target: String
    let online: Bool
    let os: String
    var address = ""
    /// The peer is approved to carry this Mac's traffic as a Tailscale exit node.
    var exitNodeOption = false
    /// This Mac currently routes its traffic through the peer.
    var isExitNode = false
    /// Local subnets the peer shares, such as its home network.
    var routes: [String] = []
    /// The device's own hostname, shown when it differs from its Tailscale machine name.
    var hostName = ""
    /// The person who shared the machine, or nil for your own machines.
    var owner: String?
    var id: String { target }
    /// Matches Tailscale's menu: "bh-atv (apple-tv)".
    var displayName: String {
        hostName.isEmpty || hostName.caseInsensitiveCompare(name) == .orderedSame ? name : "\(name) (\(hostName))"
    }

    /// Your machines first, then machines shared by each other person, as in Tailscale's menu.
    static func grouped(_ peers: [Peer]) -> [(owner: String?, peers: [Peer])] {
        let owners = Set(peers.compactMap(\.owner)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ([nil] + owners).map { owner in (owner, peers.filter { $0.owner == owner }) }.filter { !$0.peers.isEmpty }
    }

    static func decode(_ data: Data) throws -> [Peer] {
        struct Status: Decodable {
            struct Tailnet: Decodable { var MagicDNSEnabled: Bool? }
            struct Node: Decodable {
                var HostName: String?
                var DNSName: String?
                var TailscaleIPs: [String]?
                var Online: Bool?
                var OS: String?
                var UserID: Int64?
                var ExitNode: Bool?
                var ExitNodeOption: Bool?
                var PrimaryRoutes: [String]?
            }
            struct Profile: Decodable { var DisplayName: String?; var LoginName: String? }
            struct SelfNode: Decodable { var UserID: Int64? }
            var BackendState: String?
            var CurrentTailnet: Tailnet?
            var Peer: [String: Node]?
            var `Self`: SelfNode?
            var User: [String: Profile]?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw TailportError("Tailscale could not list your machines. Open Tailscale, check it is connected, then refresh.")
        }
        guard status.BackendState == "Running" else {
            throw TailportError("Tailscale is not connected. Open Tailscale, connect, then refresh.")
        }
        return (status.Peer ?? [:]).values.compactMap { node in
            let dns = (node.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let target = status.CurrentTailnet?.MagicDNSEnabled == true && !dns.isEmpty
                ? String(dns.split(separator: ".")[0]) : (node.TailscaleIPs?.first ?? "")
            guard !target.isEmpty, !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace }) else { return nil }
            let machine = dns.isEmpty ? (node.HostName ?? target) : String(dns.split(separator: ".")[0])
            let owner = node.UserID.flatMap { id -> String? in
                guard id != status.`Self`?.UserID else { return nil }
                let profile = status.User?[String(id)]
                return profile?.DisplayName ?? profile?.LoginName ?? "Shared with you"
            }
            return Peer(name: machine, target: target, online: node.Online == true, os: node.OS ?? "",
                        address: node.TailscaleIPs?.first ?? "", exitNodeOption: node.ExitNodeOption == true,
                        isExitNode: node.ExitNode == true,
                        routes: (node.PrimaryRoutes ?? []).filter { $0 != "0.0.0.0/0" && $0 != "::/0" },
                        hostName: node.HostName ?? "", owner: owner)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ListeningPort: Identifiable, Equatable {
    let number: Int
    var processes: [String]
    var destination: String = "localhost"
    /// The port on `destination` when it differs from the local port `number`.
    var remotePort: Int? = nil
    var id: Int { number }
    var service: String { processes.joined(separator: ", ") }

    static func parse(_ output: String) -> [ListeningPort] {
        var process = "Unknown process"
        var ports: [Int: ListeningPort] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            if field == "p" { process = "Unknown process" }
            if field == "c" { process = value }
            guard field == "n", let colon = value.lastIndex(of: ":"),
                  let number = Int(value[value.index(after: colon)...]), (1...65535).contains(number) else { continue }
            let host = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let address = String(host.split(separator: "%", maxSplits: 1).first ?? "")
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            guard host == "*" || inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else { continue }
            let loopback = host == "*" || address == "0.0.0.0" || address == "::" || address == "::1" || address == "127.0.0.1"
            let destination = loopback ? "localhost" : host
            if var existing = ports[number] {
                if !existing.processes.contains(process) { existing.processes.append(process); existing.processes.sort() }
                if destination == "localhost" { existing.destination = destination }
                ports[number] = existing
            } else {
                ports[number] = ListeningPort(number: number, processes: [process], destination: destination)
            }
        }
        return ports.values.sorted { $0.number < $1.number }
    }
}

struct IgnoreRules {
    static let defaultPorts = "22, 53, 88, 111, 139, 445, 548, 631, 2049, 3283, 5900"
    static let defaultProcesses = "ControlCenter, rapportd, sharingd, mDNSResponder, sshd, launchd, cupsd, remoted, AirPlayXPCHelper, cloudflared, SetappAgent"
    let ports: Set<Int>
    let processes: Set<String>

    init(ports text: String, processes: String) throws {
        var numbers: Set<Int> = []
        for token in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), (1...65535).contains(first),
                  let last = bounds.count == 2 ? Int(bounds[1]) : first,
                  (first...65535).contains(last) else {
                throw TailportError("Use ports between 1 and 65535, separated by commas. Ranges such as 8000-8010 are also supported.")
            }
            numbers.formUnion(first...last)
        }
        self.ports = numbers
        self.processes = Set(processes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    func reason(for port: ListeningPort) -> String? {
        if ports.contains(port.number) { return "Port \(port.number) is excluded" }
        if !port.processes.isEmpty && port.processes.allSatisfy({ processes.contains($0.lowercased()) }) {
            return "System or excluded service"
        }
        return nil
    }

    func allows(_ port: ListeningPort) -> Bool { reason(for: port) == nil }
}

enum SSH {
    static let options = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                          "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                          "-o", "ControlMaster=no", "-o", "ControlPath=none"]
    // macOS keeps lsof in /usr/sbin; Linux usually has it on the PATH.
    static let discoveryCommand = "l=/usr/sbin/lsof; [ -x \"$l\" ] || l=$(command -v lsof) || { echo 'tailport: lsof not found' >&2; exit 127; }; LC_ALL=C \"$l\" -nP -iTCP -sTCP:LISTEN -Fpcn; result=$?; [ \"$result\" -eq 0 ] || [ \"$result\" -eq 1 ]"
    // The remote marker confirms SSH is authenticated and local listeners are ready.
    static let forwardingCommand = "/usr/bin/printf 'TAILPORT_READY\\n'; exec /bin/cat > /dev/null"

    static func forwardingArguments(target: String, port: ListeningPort) -> [String] {
        let host = port.destination.contains(":") ? "[\(port.destination)]" : port.destination
        let remote = port.remotePort ?? port.number
        return options + ["-o", "ExitOnForwardFailure=yes",
                          "-L", "127.0.0.1:\(port.number):\(host):\(remote)",
                          "-L", "[::1]:\(port.number):\(host):\(remote)",
                          "--", target, forwardingCommand]
    }

    static func explain(_ text: String, target: String, port: Int? = nil) -> String {
        if text.localizedCaseInsensitiveContains("address already in use"), let port {
            return "Local port \(port) is already in use. Stop its other server or tunnel, then try again."
        }
        if text.localizedCaseInsensitiveContains("permission denied") || text.localizedCaseInsensitiveContains("host key verification failed") || text.contains("host key is known") {
            return "SSH access needs attention. Connect once in Terminal with ‘ssh \(target)’, then try again."
        }
        if text.contains("tailport: lsof not found") {
            return "Port discovery needs lsof on \(target). Install it there, or add network devices instead."
        }
        if text.localizedCaseInsensitiveContains("could not resolve") || text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("no route to host") {
            return "Cannot reach \(target). Check Tailscale and that the Mac is awake, then refresh."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The connection closed. Toggle the port to reconnect." : String(trimmed.prefix(400))
    }
}

enum Routing {
    static func arguments(for peer: Peer?) -> [String] {
        // Subnets shared by the peer, such as its home network, are only reachable with routes accepted.
        ["set", "--exit-node=\(peer?.address ?? "")"] + (peer?.routes.isEmpty == false ? ["--accept-routes"] : [])
    }

    static func summary(for peer: Peer) -> String {
        let routes = peer.routes.isEmpty ? "" : " Its network \(peer.routes.joined(separator: ", ")) is reachable."
        return "This Mac’s internet traffic goes through \(peer.name).\(routes)"
    }

    static func explain(_ text: String, peer: Peer?) -> String {
        // The Tailscale CLI prefixes errors with a timestamp such as "2026/11/06 16:48:12 ".
        let message = text.replacingOccurrences(of: #"(?m)^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("is not advertising an exit node"), let peer {
            return "\(peer.name) no longer offers routing. Turn on “Run as exit node” on it, then approve it in the Tailscale admin console."
        }
        if message.contains("Cannot advertise an exit node and use an exit node") {
            return "This Mac is set to run as an exit node. Turn off “Run as exit node” in Tailscale’s menu, then try again."
        }
        if message.isEmpty {
            return peer == nil ? "Tailscale could not stop routing. Open Tailscale and try again."
                : "Tailscale could not route through \(peer!.name). Open Tailscale and try again."
        }
        return String(message.prefix(400))
    }
}

/// A device on the selected machine's network, such as its router, reached through an SSH forward.
struct NetworkDevice: Identifiable, Equatable, Codable {
    var name: String
    var host: String
    var port: Int
    var localPort: Int
    var id: String { "\(host):\(port)" }
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    var url: URL? { NetworkScan.scheme(port).flatMap { URL(string: "\($0)://localhost:\(localPort)") } }
    var forward: ListeningPort { ListeningPort(number: localPort, processes: [name], destination: host, remotePort: port) }

    /// Parses an address such as `192.168.1.254:80`, `router.lan:8080` or `[fd00::1]:80`.
    /// Low ports are moved above 10000 locally (80 becomes 10080), avoiding common local servers.
    static func parse(name: String, address text: String, taken: Set<Int>) throws -> NetworkDevice {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = "", portText = ""
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) }
        } else if let colon = address.lastIndex(of: ":"), address.firstIndex(of: ":") == colon {
            host = String(address[..<colon])
            portText = String(address[address.index(after: colon)...])
        } else {
            host = address
            portText = "80"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TailportError("Enter an address such as 192.168.1.254:80.")
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw TailportError("Use a port between 1 and 65535, such as 192.168.1.254:80.")
        }
        var local = port < 1024 ? 10000 + port : port
        while taken.contains(local) && local < 65535 { local += 1 }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkDevice(name: label.isEmpty ? host : label, host: host, port: port, localPort: local)
    }
}

struct ScannedHost: Identifiable, Equatable {
    let ip: String
    var mac: String
    var name: String
    var ports: [Int] = []
    var id: String { ip }
    var label: String { name.isEmpty ? ip : name.replacingOccurrences(of: #"\.(lan|local|home|home\.arpa)$"#, with: "", options: .regularExpression) }
}

/// Finds devices on the remote machine's local network. It runs there as a POSIX shell script over SSH,
/// using only ping, nc and the neighbour table, so nothing needs installing.
enum NetworkScan {
    static let script = template.replacingOccurrences(of: "@PORTS@", with: ports.map(String.init).joined(separator: " "))

    private static let template = #"""
set -u
ports="@PORTS@"
if [ "$(uname -s)" = Darwin ]; then
  dev=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
  addr=$(ifconfig "$dev" 2>/dev/null | awk '/inet / { print $2 "/" $4; exit }')
else
  dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{ print $4; exit }')
fi
[ -n "$addr" ] || { echo 'tailport: no local network found' >&2; exit 3; }
# Accepts 192.168.1.5/24 or macOS's 192.168.1.5/0xffffff00. Scans at most a /22.
hosts=$(echo "$addr" | awk -F/ '{
  split($1, o, "."); self = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
  m = $2; bits = 0
  if (m ~ /^0x/) { m = substr(m, 3); for (i = 1; i <= length(m); i++) { d = index("0123456789abcdef", tolower(substr(m, i, 1))) - 1; for (b = 3; b >= 0; b--) if (int(d / 2 ^ b) % 2) bits++ } }
  else bits = m + 0
  if (bits < 22) bits = 24
  size = 2 ^ (32 - bits); base = self - self % size
  printf "S %d.%d.%d.%d/%d\n", int(base / 16777216), int(base / 65536) % 256, int(base / 256) % 256, base % 256, bits > "/dev/stderr"
  for (h = base + 1; h < base + size - 1; h++) if (h != self) printf "%d.%d.%d.%d\n", int(h / 16777216), int(h / 65536) % 256, int(h / 256) % 256, h % 256
}' 2>&1)
echo "$hosts" | grep '^S '
targets=$(echo "$hosts" | grep -v '^S ')
for ip in $targets; do
  if [ "$(uname -s)" = Darwin ]; then ping -c 1 -t 1 -q "$ip" >/dev/null 2>&1 &
  else ping -c 1 -W 1 -q "$ip" >/dev/null 2>&1 & fi
done
wait
if [ "$(uname -s)" = Darwin ]; then
  found=$(arp -an -i "$dev" 2>/dev/null | awk '$4 ~ /:/ { gsub(/[()]/, "", $2); print $2, $4 }')
else
  found=$(ip -4 neigh show dev "$dev" 2>/dev/null | awk '$2 == "lladdr" && $NF != "FAILED" && $NF != "INCOMPLETE" { print $1, $3 }')
fi
echo "$found" | { while read -r ip mac; do
  [ -n "$ip" ] || continue
  echo "$targets" | grep -qx "$ip" || continue
  (name=""
   if command -v getent >/dev/null 2>&1; then name=$(timeout 2 getent hosts "$ip" 2>/dev/null | awk '{ print $2; exit }')
   elif [ -x /usr/bin/dig ]; then name=$(/usr/bin/dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null | sed -n '1s/\.$//p'); fi
   echo "H $ip $mac $name") &
  # Each device is probed in batches of 12 ports, keeping the number of processes small.
  (n=0
   for port in $ports; do
     if [ "$(uname -s)" = Darwin ]; then (nc -z -G 1 -w 1 "$ip" "$port" >/dev/null 2>&1 && echo "P $ip $port") &
     else (nc -z -w 1 "$ip" "$port" >/dev/null 2>&1 && echo "P $ip $port") & fi
     n=$((n + 1)); [ $((n % 12)) -eq 0 ] && wait
   done
   wait) &
done
wait; }
"""#

    /// Devices with open ports come first, each group in address order.
    static func parse(_ output: String) -> (subnet: String?, hosts: [ScannedHost]) {
        var subnet: String?
        var hosts: [String: ScannedHost] = [:]
        var ports: [String: Set<Int>] = [:]
        var ipv4 = in_addr()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let kind = fields.first else { continue }
            if kind == "S", fields.count >= 2 { subnet = fields[1]; continue }
            guard fields.count >= 3, inet_pton(AF_INET, fields[1], &ipv4) == 1 else { continue }
            if kind == "H" {
                hosts[fields[1]] = ScannedHost(ip: fields[1], mac: fields[2], name: fields.count > 3 ? fields[3] : "")
            } else if kind == "P", let port = Int(fields[2]), (1...65535).contains(port) {
                ports[fields[1], default: []].insert(port)
            }
        }
        let found = hosts.values.map { host -> ScannedHost in
            var host = host
            host.ports = (ports[host.ip] ?? []).sorted()
            return host
        }.sorted { ($0.ports.isEmpty ? 1 : 0, order($0.ip)) < ($1.ports.isEmpty ? 1 : 0, order($1.ip)) }
        return (subnet, found)
    }

    /// TCP ports probed on each device: web and admin pages, file sharing, media servers, home automation,
    /// development servers and games. UDP services, such as Minecraft Bedrock, cannot be forwarded over SSH.
    static let ports = [21, 22, 23, 53, 80, 81, 139, 443, 445, 548, 554, 631, 1880, 1883, 3000, 3001, 3306, 3389,
                        4000, 4200, 4321, 5000, 5001, 5173, 5174, 5432, 5900, 6379, 7878, 8000, 8008, 8080, 8081,
                        8096, 8123, 8384, 8443, 8888, 8989, 9000, 9090, 9091, 9100, 9443, 10000, 25565, 27017, 32400]

    /// Only well-established uses are named; ports such as 5000 or 8888 vary too much to guess.
    private static let services: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 53: "DNS", 80: "Web", 81: "Web", 139: "File sharing", 443: "Web",
        445: "File sharing", 548: "AFP", 554: "Camera", 631: "Printer", 1880: "Node-RED", 1883: "MQTT",
        3000: "Dev server", 3001: "Dev server", 3306: "MySQL", 3389: "Remote Desktop", 4000: "Dev server",
        4200: "Angular", 4321: "Astro", 5173: "Vite", 5174: "Vite", 5432: "PostgreSQL",
        5900: "Screen sharing", 6379: "Redis", 7878: "Radarr", 8080: "Web",
        8096: "Jellyfin", 8123: "Home Assistant", 8384: "Syncthing", 8443: "Web", 8989: "Sonarr",
        9091: "Transmission", 9100: "Printer", 10000: "Webmin",
        25565: "Minecraft", 27017: "MongoDB", 32400: "Plex"
    ]

    static func service(_ port: Int) -> String? { services[port] }

    /// How macOS opens a forwarded port, or nil for services that need their own app, such as Minecraft.
    static func scheme(_ port: Int) -> String? {
        switch port {
        case 443, 5001, 8443, 9443, 10000: return "https"
        case 22: return "ssh"
        case 139, 445: return "smb"
        case 548: return "afp"
        case 5900: return "vnc"
        case 21, 23, 53, 554, 631, 1883, 3306, 3389, 5432, 6379, 9100, 25565, 27017: return nil
        default: return "http"
        }
    }

    /// The default name for a device found by a scan, such as "HD · Plex". Web pages keep the device's own name.
    static func deviceName(_ host: ScannedHost, port: Int) -> String {
        guard let service = service(port), service != "Web" else { return host.label }
        return "\(host.label) · \(service)"
    }

    private static func order(_ ip: String) -> Int { ip.split(separator: ".").reduce(0) { $0 * 256 + (Int($1) ?? 0) } }
}
