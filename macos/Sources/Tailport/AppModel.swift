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
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var discoveryAvailable = false
    @Published private(set) var ignoredPorts: String
    @Published private(set) var ignoredProcesses: String
    @Published var showIgnored = false
    @Published var showExclusions = false
    private var rules: IgnoreRules
    private var sessions: [Int: SSHForward] = [:]
    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let sshExecutable: String
    private let supervisorExecutable: String?

    init(defaults: UserDefaults = .standard, sshExecutable: String = "/usr/bin/ssh",
         supervisorExecutable: String? = Bundle.main.path(forAuxiliaryExecutable: "TailportTunnel")) {
        self.defaults = defaults
        self.sshExecutable = sshExecutable
        self.supervisorExecutable = supervisorExecutable
        machine = defaults.string(forKey: "machine") ?? "bh-mm"
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
    var forwardingCount: Int { states.values.filter { $0 == .forwarding }.count }
    var hasForwards: Bool { !sessions.isEmpty }
    var machineName: String { peers.first { $0.target == machine }?.name ?? machine }
    func isEnabled(_ port: ListeningPort) -> Bool { sessions[port.number] != nil }
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
            let result = try await Commands.run(Commands.tailscalePath(), ["status", "--json"])
            guard request == generation, !Task.isCancelled else { return }
            guard result.status == 0 else { throw TailportError(result.error.isEmpty ? "Tailscale could not list machines. Open Tailscale and refresh." : result.error) }
            peers = try Peer.decode(result.output)
            if defaults.string(forKey: "machine") == nil, !peers.contains(where: { $0.target == machine }),
               let first = peers.first(where: { $0.online && $0.os == "macOS" }) ?? peers.first(where: \.online) {
                machine = first.target
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
        guard let supervisorExecutable else {
            states[port.number] = .failed("Tailport’s tunnel helper is missing. Rebuild or reinstall the app.")
            return
        }
        let number = port.number
        let session = SSHForward(target: machine, port: port, executable: sshExecutable, supervisorExecutable: supervisorExecutable, onReady: { [weak self] id in
            guard let self, self.sessions[number]?.id == id else { return }
            self.states[number] = .forwarding
        }, onExit: { [weak self] id, message in
            guard let self, self.sessions[number]?.id == id else { return }
            self.sessions.removeValue(forKey: number)
            self.states[number] = message.map(ForwardState.failed)
        })
        sessions[number] = session
        states[number] = .connecting
        do { try session.start() }
        catch {
            sessions.removeValue(forKey: number)
            states[number] = .failed(error.localizedDescription)
        }
    }

    func setAllEnabled(_ enabled: Bool) {
        for port in eligiblePorts { setEnabled(enabled, for: port) }
    }

    private func stop(_ number: Int) {
        let session = sessions.removeValue(forKey: number)
        states.removeValue(forKey: number)
        session?.stop()
    }

    func stopAll() {
        for number in Array(sessions.keys) { stop(number) }
        states = [:]
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
        let closing = Array(sessions.values)
        stopAll()
        for _ in 0..<20 {
            if closing.allSatisfy({ !$0.isRunning }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        closing.forEach { $0.forceStop() }
    }
}
