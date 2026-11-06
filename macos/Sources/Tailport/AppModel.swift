import Foundation
import SwiftUI

enum ForwardState: Equatable {
    case connecting, forwarding, failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var machine: String
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var states: [Int: ForwardState] = [:]
    @Published private(set) var devices: [NetworkDevice] = []
    @Published private(set) var deviceStates: [String: ForwardState] = [:]
    @Published private(set) var scannedHosts: [ScannedHost] = []
    @Published private(set) var scannedSubnet: String?
    @Published private(set) var scanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var discoveryAvailable = false
    @Published private(set) var ignoredPorts: String
    @Published private(set) var ignoredProcesses: String
    @Published private(set) var routingBusy = false
    @Published private(set) var routingError: String?
    @Published var showIgnored = false
    @Published var showExclusions = false
    @Published var showAddDevice = false
    private var rules: IgnoreRules
    private var sessions: [Int: SSHForward] = [:]
    private var deviceSessions: [String: SSHForward] = [:]
    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let sshExecutable: String
    private let supervisorExecutable: String?
    private let tailscaleExecutable: () throws -> String

    init(defaults: UserDefaults = .standard, sshExecutable: String = "/usr/bin/ssh",
         supervisorExecutable: String? = Bundle.main.path(forAuxiliaryExecutable: "TailportTunnel"),
         tailscaleExecutable: @escaping () throws -> String = Commands.tailscalePath) {
        self.defaults = defaults
        self.tailscaleExecutable = tailscaleExecutable
        self.sshExecutable = sshExecutable
        self.supervisorExecutable = supervisorExecutable
        let saved = defaults.string(forKey: "machine") ?? "bh-mm"
        machine = saved
        devices = Self.savedDevices(defaults)[saved] ?? []
        let savedPorts = defaults.string(forKey: "ignoredPorts") ?? IgnoreRules.defaultPorts
        let savedProcesses = defaults.string(forKey: "ignoredProcesses") ?? IgnoreRules.defaultProcesses
        if let saved = try? IgnoreRules(ports: savedPorts, processes: savedProcesses) {
            ignoredPorts = savedPorts
            ignoredProcesses = savedProcesses
            rules = saved
        } else {
            ignoredPorts = IgnoreRules.defaultPorts
            ignoredProcesses = IgnoreRules.defaultProcesses
            rules = try! IgnoreRules(ports: IgnoreRules.defaultPorts, processes: IgnoreRules.defaultProcesses)
        }
    }

    var eligiblePorts: [ListeningPort] { ports.filter { rules.allows($0) } }
    var visiblePorts: [ListeningPort] { showIgnored ? ports : eligiblePorts }
    var ignoredCount: Int { ports.count - eligiblePorts.count }
    var forwardingCount: Int { (Array(states.values) + Array(deviceStates.values)).filter { $0 == .forwarding }.count }
    var failedCount: Int {
        (Array(states.values) + Array(deviceStates.values)).filter { if case .failed = $0 { return true } else { return false } }.count
    }
    var hasForwards: Bool { !sessions.isEmpty }
    var hasAnyForwards: Bool { !sessions.isEmpty || !deviceSessions.isEmpty }
    var machineName: String { peers.first { $0.target == machine }?.name ?? machine }
    /// Online peers this Mac can send its traffic through, plus the current one if it has gone offline.
    var routers: [Peer] { peers.filter { $0.isExitNode || ($0.online && $0.exitNodeOption) } }
    var router: Peer? { peers.first(where: \.isExitNode) }
    func isEnabled(_ port: ListeningPort) -> Bool { sessions[port.number] != nil }
    func isEnabled(_ device: NetworkDevice) -> Bool { deviceSessions[device.id] != nil }
    func ignoreReason(_ port: ListeningPort) -> String? { rules.reason(for: port) }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func selectMachine(_ target: String) {
        guard machine != target else { return }
        generation = UUID()
        stopAll()
        machine = target
        defaults.set(target, forKey: "machine")
        devices = Self.savedDevices(defaults)[target] ?? []
        scannedHosts = []
        scannedSubnet = nil
        scanError = nil
        scanning = false
        ports = []
        lastRefresh = nil
        discoveryAvailable = false
        refreshing = false
        error = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing, !Task.isCancelled else { return }
        refreshing = true
        let request = generation
        defer { if request == generation { refreshing = false } }
        do {
            let loaded = try await loadPeers()
            guard request == generation, !Task.isCancelled else { return }
            peers = loaded
            if defaults.string(forKey: "machine") == nil, !peers.contains(where: { $0.target == machine }),
               let first = peers.first(where: { $0.online && $0.os == "macOS" }) ?? peers.first(where: \.online) {
                machine = first.target
                devices = Self.savedDevices(defaults)[first.target] ?? []
            }
            guard peers.contains(where: { $0.target == machine && $0.online }) else {
                throw TailportError("\(machineName) is offline or unavailable. Wake the Mac and check Tailscale, then refresh.")
            }
            let target = machine
            let scan = try await Commands.run("/usr/bin/ssh", SSH.options + ["--", target, SSH.discoveryCommand])
            guard request == generation, !Task.isCancelled else { return }
            guard scan.status == 0 else { throw TailportError(SSH.explain(scan.error, target: target)) }
            let discovered = ListeningPort.parse(String(decoding: scan.output, as: UTF8.self))
            acceptDiscovery(discovered)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            discoveryAvailable = false
        }
    }

    private func loadPeers() async throws -> [Peer] {
        let result = try await Commands.run(tailscaleExecutable(), ["status", "--json"])
        guard result.status == 0 else { throw TailportError(result.error.isEmpty ? "Tailscale could not list machines. Open Tailscale and refresh." : result.error) }
        return try Peer.decode(result.output)
    }

    /// Sends this Mac's traffic through `target` as a Tailscale exit node, or stops when `target` is nil.
    func route(through target: String?) async {
        guard !routingBusy else { return }
        let peer = target.flatMap { name in peers.first { $0.target == name } }
        guard target == nil || peer?.address.isEmpty == false else { return }
        routingBusy = true
        routingError = nil
        defer { routingBusy = false }
        do {
            let result = try await Commands.run(tailscaleExecutable(), Routing.arguments(for: peer))
            if result.status != 0 { routingError = Routing.explain(result.error, peer: peer) }
            peers = try await loadPeers()
            if result.status == 0, let peer, router?.target != peer.target {
                routingError = Routing.explain("", peer: peer)
            }
        } catch {
            routingError = error.localizedDescription
        }
    }

    func acceptDiscovery(_ discovered: [ListeningPort]) {
        for number in Array(sessions.keys) {
            let updated = discovered.first { $0.number == number }
            if updated == nil || !rules.allows(updated!) || ports.first(where: { $0.number == number })?.destination != updated?.destination {
                stop(number)
            }
        }
        ports = discovered
        discoveryAvailable = true
        lastRefresh = Date()
        error = nil
    }

    func setEnabled(_ enabled: Bool, for port: ListeningPort) {
        if !enabled { stop(port.number); return }
        guard discoveryAvailable, rules.allows(port), sessions[port.number] == nil else { return }
        let number = port.number
        let session = makeForward(port, ready: { [weak self] id in
            guard let self, self.sessions[number]?.id == id else { return }
            self.states[number] = .forwarding
        }, exit: { [weak self] id, message in
            guard let self, self.sessions[number]?.id == id else { return }
            self.sessions.removeValue(forKey: number)
            self.states[number] = message.map(ForwardState.failed)
        })
        guard let session else {
            states[number] = .failed("Tailport’s tunnel helper is missing. Rebuild or reinstall the app.")
            return
        }
        sessions[number] = session
        states[number] = .connecting
        do { try session.start() }
        catch {
            sessions.removeValue(forKey: number)
            states[number] = .failed(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool, for device: NetworkDevice) {
        let key = device.id
        if !enabled { stopDevice(key); return }
        guard deviceSessions[key] == nil else { return }
        let session = makeForward(device.forward, ready: { [weak self] id in
            guard let self, self.deviceSessions[key]?.id == id else { return }
            self.deviceStates[key] = .forwarding
        }, exit: { [weak self] id, message in
            guard let self, self.deviceSessions[key]?.id == id else { return }
            self.deviceSessions.removeValue(forKey: key)
            self.deviceStates[key] = message.map(ForwardState.failed)
        })
        guard let session else {
            deviceStates[key] = .failed("Tailport’s tunnel helper is missing. Rebuild or reinstall the app.")
            return
        }
        deviceSessions[key] = session
        deviceStates[key] = .connecting
        do { try session.start() }
        catch {
            deviceSessions.removeValue(forKey: key)
            deviceStates[key] = .failed(error.localizedDescription)
        }
    }

    private func makeForward(_ port: ListeningPort, ready: @escaping (UUID) -> Void,
                             exit: @escaping (UUID, String?) -> Void) -> SSHForward? {
        guard let supervisorExecutable else { return nil }
        return SSHForward(target: machine, port: port, executable: sshExecutable, supervisorExecutable: supervisorExecutable,
                          onReady: ready, onExit: exit)
    }

    /// Adds a device on the selected machine's network, remembered for that machine.
    @discardableResult
    func addDevice(name: String, address: String) throws -> NetworkDevice {
        let taken = Set(devices.map(\.localPort))
        let device = try NetworkDevice.parse(name: name, address: address, taken: taken)
        guard !devices.contains(where: { $0.id == device.id }) else {
            throw TailportError("\(device.address) is already in the list.")
        }
        devices.append(device)
        saveDevices()
        return device
    }

    /// Lists devices on the selected machine's local network and their common open ports.
    func scanNetwork() async {
        guard !scanning else { return }
        let request = generation
        let target = machine
        scanning = true
        scanError = nil
        defer { if request == generation { scanning = false } }
        do {
            let result = try await Commands.run(sshExecutable, SSH.options + ["--", target, "/bin/sh", "-s"],
                                                timeout: 60, input: Data(NetworkScan.script.utf8))
            guard request == generation else { return }
            if result.error.contains("tailport: no local network found") {
                throw TailportError("\(machineName) is not connected to a local network.")
            }
            guard result.status == 0 else { throw TailportError(SSH.explain(result.error, target: target)) }
            let found = NetworkScan.parse(String(decoding: result.output, as: UTF8.self))
            scannedSubnet = found.subnet
            scannedHosts = found.hosts
        } catch {
            guard request == generation else { return }
            scanError = error.localizedDescription
        }
    }

    /// The local port a scanned port would open on if forwarded now.
    func localPort(for host: ScannedHost, port: Int) -> Int {
        (try? NetworkDevice.parse(name: "", address: "\(host.ip):\(port)", taken: Set(devices.map(\.localPort))))?.localPort ?? port
    }

    /// Adds a port found by a scan, or reuses the saved device, and starts forwarding it.
    func connect(_ host: ScannedHost, port: Int) throws {
        let device = try devices.first { $0.host == host.ip && $0.port == port }
            ?? addDevice(name: NetworkScan.deviceName(host, port: port), address: "\(host.ip):\(port)")
        setEnabled(true, for: device)
    }

    func removeDevice(_ device: NetworkDevice) {
        stopDevice(device.id)
        devices.removeAll { $0.id == device.id }
        saveDevices()
    }

    private func stopDevice(_ key: String) {
        let session = deviceSessions.removeValue(forKey: key)
        deviceStates.removeValue(forKey: key)
        session?.stop()
    }

    private static func savedDevices(_ defaults: UserDefaults) -> [String: [NetworkDevice]] {
        guard let data = defaults.data(forKey: "devices"),
              let saved = try? JSONDecoder().decode([String: [NetworkDevice]].self, from: data) else { return [:] }
        return saved
    }

    private func saveDevices() {
        var saved = Self.savedDevices(defaults)
        saved[machine] = devices.isEmpty ? nil : devices
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "devices") }
    }

    func setAllEnabled(_ enabled: Bool) {
        if !enabled { stopPorts(); return }
        for port in eligiblePorts { setEnabled(enabled, for: port) }
    }

    private func stop(_ number: Int) {
        let session = sessions.removeValue(forKey: number)
        states.removeValue(forKey: number)
        session?.stop()
    }

    /// Stops forwarded listening ports. Network devices are left alone.
    func stopPorts() {
        for number in Array(sessions.keys) { stop(number) }
        states = [:]
    }

    func stopAll() {
        stopPorts()
        for key in Array(deviceSessions.keys) { stopDevice(key) }
        deviceStates = [:]
    }

    func applyExclusions(ports text: String, processes: String) throws {
        let updated = try IgnoreRules(ports: text, processes: processes)
        rules = updated
        ignoredPorts = text
        ignoredProcesses = processes
        defaults.set(text, forKey: "ignoredPorts")
        defaults.set(processes, forKey: "ignoredProcesses")
        for port in ports where !updated.allows(port) { stop(port.number) }
    }

    func ignore(_ port: ListeningPort) {
        let text = ignoredPorts.isEmpty ? "\(port.number)" : "\(ignoredPorts), \(port.number)"
        try? applyExclusions(ports: text, processes: ignoredProcesses)
    }

    func shutdown() async {
        pollTask?.cancel()
        pollTask = nil
        generation = UUID()
        let closing = Array(sessions.values) + Array(deviceSessions.values)
        stopAll()
        for _ in 0..<20 {
            if closing.allSatisfy({ !$0.isRunning }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        closing.forEach { $0.forceStop() }
    }
}
