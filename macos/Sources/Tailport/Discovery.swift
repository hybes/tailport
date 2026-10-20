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
    var id: String { target }

    static func decode(_ data: Data) throws -> [Peer] {
        struct Status: Decodable {
            struct Tailnet: Decodable { var MagicDNSEnabled: Bool? }
            struct Node: Decodable {
                var HostName: String?
                var DNSName: String?
                var TailscaleIPs: [String]?
                var Online: Bool?
                var OS: String?
            }
            var BackendState: String?
            var CurrentTailnet: Tailnet?
            var Peer: [String: Node]?
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
            return Peer(name: node.HostName ?? target, target: target, online: node.Online == true, os: node.OS ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ListeningPort: Identifiable, Equatable {
    let number: Int
    var processes: [String]
    var destination: String = "localhost"
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
    static let discoveryCommand = "LC_ALL=C /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcn; result=$?; [ \"$result\" -eq 0 ] || [ \"$result\" -eq 1 ]"
    // The remote marker confirms SSH is authenticated and local listeners are ready.
    static let forwardingCommand = "/usr/bin/printf 'TAILPORT_READY\\n'; exec /bin/cat > /dev/null"

    static func forwardingArguments(target: String, port: ListeningPort) -> [String] {
        let host = port.destination.contains(":") ? "[\(port.destination)]" : port.destination
        return options + ["-o", "ExitOnForwardFailure=yes",
                          "-L", "127.0.0.1:\(port.number):\(host):\(port.number)",
                          "-L", "[::1]:\(port.number):\(host):\(port.number)",
                          "--", target, forwardingCommand]
    }

    static func explain(_ text: String, target: String, port: Int? = nil) -> String {
        if text.localizedCaseInsensitiveContains("address already in use"), let port {
            return "Local port \(port) is already in use. Stop its other server or tunnel, then try again."
        }
        if text.localizedCaseInsensitiveContains("permission denied") || text.localizedCaseInsensitiveContains("host key verification failed") || text.contains("host key is known") {
            return "SSH access needs attention. Connect once in Terminal with ‘ssh \(target)’, then try again."
        }
        if text.localizedCaseInsensitiveContains("could not resolve") || text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("no route to host") {
            return "Cannot reach \(target). Check Tailscale and that the Mac is awake, then refresh."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The connection closed. Toggle the port to reconnect." : String(trimmed.prefix(400))
    }
}
