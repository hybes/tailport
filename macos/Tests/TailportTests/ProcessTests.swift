import XCTest
@testable import Tailport

final class ProcessTests: XCTestCase {
    func testCommandCapturesOutputAndFailure() async throws {
        let result = try await Commands.run("/bin/sh", ["-c", "printf 'output'; printf 'failure' >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "output")
        XCTAssertEqual(result.error, "failure")
    }

    func testCommandTimeoutIsBounded() async {
        let started = Date()
        do {
            _ = try await Commands.run("/bin/sleep", ["10"], timeout: 0.1)
            XCTFail("The sleeping process should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    @MainActor func testForwardReportsReadyAndStopsItsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf 'TAILPORT_READY\\n'\nexec /bin/cat >/dev/null\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let ready = expectation(description: "SSH is ready")
        let ended = expectation(description: "SSH exited")
        let session = SSHForward(target: "test", port: ListeningPort(number: 3000, processes: ["node"]),
                                 executable: fixture.path, onReady: { _ in ready.fulfill() },
                                 onExit: { _, error in XCTAssertNil(error); ended.fulfill() })
        try session.start()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(session.isRunning)
        session.stop()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertFalse(session.isRunning)
    }

    @MainActor func testForwardFailureNeverReportsReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf 'bind: Address already in use\\n' >&2\nexit 255\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let ended = expectation(description: "SSH failed")
        let session = SSHForward(target: "test", port: ListeningPort(number: 3000, processes: ["node"]),
                                 executable: fixture.path, onReady: { _ in XCTFail("A failed bind must not report ready") },
                                 onExit: { _, error in XCTAssertTrue(error?.contains("Local port 3000 is already in use") == true); ended.fulfill() })
        try session.start()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertFalse(session.isRunning)
    }

    @MainActor func testBulkForwardingKeepsExclusionsAndCanStopAfterPartialFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\ncase \"$*\" in *127.0.0.1:3001:*) printf 'Address already in use' >&2; exit 255;; esac\nprintf 'TAILPORT_READY\\n'\nexec /bin/cat >/dev/null\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let suite = "tailport-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, sshExecutable: fixture.path, supervisorExecutable: fixture.path)
        let good = ListeningPort(number: 3000, processes: ["node"])
        let conflict = ListeningPort(number: 3001, processes: ["node"])
        let ignored = ListeningPort(number: 7000, processes: ["ControlCenter"])
        model.acceptDiscovery([good, conflict, ignored])
        model.setAllEnabled(true)
        for _ in 0..<100 {
            if model.states[3000] == .forwarding, case .failed = model.states[3001] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.states[3000], .forwarding)
        guard case .failed = model.states[3001] else { XCTFail("The conflicting port should fail"); await model.shutdown(); return }
        XCTAssertFalse(model.isEnabled(ignored))
        XCTAssertTrue(model.hasForwards, "The master switch must still be able to turn off working forwards")
        model.setAllEnabled(false)
        XCTAssertFalse(model.hasForwards)
        model.setEnabled(true, for: good)
        model.acceptDiscovery([ListeningPort(number: 3000, processes: ["ControlCenter"]), conflict, ignored])
        XCTAssertFalse(model.hasForwards, "A port becoming an ignored service must stop forwarding")
        await model.shutdown()
    }

    func testTunnelHelperStopsChildWhenParentDies() async throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TailportTunnel")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() }; parent.waitUntilExit() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-helper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let watcher = Process()
        watcher.executableURL = helper
        watcher.arguments = [String(parent.processIdentifier), "/bin/sh", "-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "test", pidFile.path]
        try watcher.run()
        defer { if watcher.isRunning { watcher.terminate() }; watcher.waitUntilExit() }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        parent.terminate()
        for _ in 0..<300 {
            if !watcher.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(watcher.isRunning)
        XCTAssertEqual(kill(child, 0), -1, "The SSH child must be gone even if it ignores stdin")
    }
}
