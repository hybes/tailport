import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let output: Data
    let error: String
}

enum Commands {
    static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return values
    }

    static func tailscalePath() throws -> String {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TailportError("Install and open Tailscale on this Mac, then refresh.")
        }
        return path
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outURL)
            let errors = try FileHandle(forWritingTo: errURL)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            let started = Date()
            try process.run()
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            if process.terminationStatus != 0 && Date().timeIntervalSince(started) >= timeout {
                throw TailportError("The connection timed out. Check Tailscale and that the other Mac is awake, then refresh.")
            }
            return CommandResult(status: process.terminationStatus, output: try Data(contentsOf: outURL),
                                 error: String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
        }.value
    }
}

@MainActor
final class SSHForward {
    let id = UUID()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let target: String
    private let port: ListeningPort
    private let executable: String
    private let supervisorExecutable: String?
    private let onReady: (UUID) -> Void
    private let onExit: (UUID, String?) -> Void
    private var directory: URL?
    private var errorFile: FileHandle?
    private var received = ""
    private var ready = false
    private var stopped = false
    private var timeout: DispatchWorkItem?
    private var timeoutMessage: String?
    var isRunning: Bool { process.isRunning }

    init(target: String, port: ListeningPort, executable: String = "/usr/bin/ssh", supervisorExecutable: String? = nil,
         onReady: @escaping (UUID) -> Void, onExit: @escaping (UUID, String?) -> Void) {
        self.target = target
        self.port = port
        self.executable = executable
        self.supervisorExecutable = supervisorExecutable
        self.onReady = onReady
        self.onExit = onExit
    }

    func start() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-forward-\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = folder
        let errorURL = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        errorFile = try FileHandle(forWritingTo: errorURL)
        let arguments = SSH.forwardingArguments(target: target, port: port)
        process.executableURL = URL(fileURLWithPath: supervisorExecutable ?? executable)
        process.arguments = supervisorExecutable == nil ? arguments : [String(getpid()), executable] + arguments
        process.environment = Commands.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorFile
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [self] _ in Task { @MainActor in finish(errorURL) } }
        do { try process.run() }
        catch { process.terminationHandler = nil; cleanUp(); throw error }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.ready, !self.stopped else { return }
            self.timeoutMessage = "Forwarding did not become ready. Check SSH access and try again."
            self.endProcess()
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
    }

    private func receive(_ data: Data) {
        guard !stopped, !ready else { return }
        received += String(decoding: data, as: UTF8.self)
        received = String(received.suffix(4096))
        if received.contains("TAILPORT_READY\n") {
            ready = true
            timeout?.cancel()
            onReady(id)
        }
    }

    func stop() {
        stopped = true
        timeout?.cancel()
        endProcess()
    }

    private func endProcess() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in forceStop() }
    }

    func forceStop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func finish(_ errorURL: URL) {
        let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        let failure = stopped ? nil : (timeoutMessage ?? SSH.explain(message, target: target, port: port.number))
        process.terminationHandler = nil
        cleanUp()
        onExit(id, failure)
    }

    private func cleanUp() {
        timeout?.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? errorFile?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
