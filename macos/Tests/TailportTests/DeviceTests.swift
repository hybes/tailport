import XCTest
@testable import Tailport

final class DeviceTests: XCTestCase {
    func testAddressParsingMovesLowPortsAndAvoidsTakenLocalPorts() throws {
        let router = try NetworkDevice.parse(name: " EE router ", address: " 192.168.1.254:80 ", taken: [])
        XCTAssertEqual(router, NetworkDevice(name: "EE router", host: "192.168.1.254", port: 80, localPort: 10080))
        XCTAssertEqual(router.url?.absoluteString, "http://localhost:10080")
        XCTAssertEqual(try NetworkDevice.parse(name: "", address: "192.168.1.254", taken: [10080]).localPort, 10081)
        XCTAssertEqual(try NetworkDevice.parse(name: "", address: "nas.lan:8443", taken: []).url?.absoluteString, "https://localhost:8443")
        let ipv6 = try NetworkDevice.parse(name: "", address: "[fd00::1]:443", taken: [])
        XCTAssertEqual(ipv6.host, "fd00::1")
        XCTAssertEqual(ipv6.address, "[fd00::1]:443")
        XCTAssertEqual(ipv6.name, "fd00::1")
        XCTAssertEqual(try NetworkDevice.parse(name: "", address: "fd00::1", taken: []).address, "[fd00::1]:80")
        for bad in ["", "192.168.1.254:0", "192.168.1.254:70000", "host:abc", "-oProxyCommand=x:80", "bad host:80", "a;b:80"] {
            XCTAssertThrowsError(try NetworkDevice.parse(name: "", address: bad, taken: []), bad)
        }
    }

    func testDeviceForwardTargetsTheRemoteAddressAndPort() {
        let device = NetworkDevice(name: "Router", host: "192.168.1.254", port: 80, localPort: 10080)
        let arguments = SSH.forwardingArguments(target: "th-pi-400", port: device.forward)
        XCTAssertTrue(arguments.contains("127.0.0.1:10080:192.168.1.254:80"))
        XCTAssertTrue(arguments.contains("[::1]:10080:192.168.1.254:80"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["--", "th-pi-400", SSH.forwardingCommand])
    }

    func testDiscoveryFindsLsofOnLinuxAndExplainsWhenItIsMissing() async throws {
        XCTAssertTrue(SSH.discoveryCommand.contains("command -v lsof"))
        let missing = try await Commands.run("/bin/sh", ["-c", SSH.discoveryCommand.replacingOccurrences(of: "/usr/sbin/lsof", with: "/nonexistent")
            .replacingOccurrences(of: "command -v lsof", with: "command -v tailport-no-such-tool")])
        XCTAssertEqual(missing.status, 127)
        XCTAssertTrue(SSH.explain(missing.error, target: "th-pi-400").hasPrefix("Port discovery needs lsof on th-pi-400."))
    }

    @MainActor func testDevicesAreRememberedPerMachineAndForwardIndependentlyOfPorts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("args")
        let fixture = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(log.path)'\nprintf 'TAILPORT_READY\\n'\nexec /bin/cat >/dev/null\n"
            .write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let suite = "tailport-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("th-pi-400", forKey: "machine")
        let model = AppModel(defaults: defaults, sshExecutable: fixture.path, supervisorExecutable: fixture.path)
        let router = try model.addDevice(name: "EE router", address: "192.168.1.254:80")
        XCTAssertThrowsError(try model.addDevice(name: "Again", address: "192.168.1.254:80"))
        XCTAssertEqual(try model.addDevice(name: "", address: "192.168.1.254:8080").localPort, 8080)

        model.setEnabled(true, for: router)
        for _ in 0..<100 where model.deviceStates[router.id] != .forwarding { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.deviceStates[router.id], .forwarding)
        XCTAssertEqual(model.forwardingCount, 1)
        XCTAssertFalse(model.hasForwards, "The All ports switch only covers listening ports")
        model.setAllEnabled(false)
        XCTAssertTrue(model.isEnabled(router), "Turning off all ports leaves devices running")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("127.0.0.1:10080:192.168.1.254:80\n"))

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.devices.map(\.name), ["EE router", "192.168.1.254"])
        restored.selectMachine("bh-mm")
        XCTAssertTrue(restored.devices.isEmpty, "Devices belong to the machine they were added on")

        model.removeDevice(router)
        XCTAssertFalse(model.isEnabled(router))
        defaults.set("th-pi-400", forKey: "machine")
        XCTAssertEqual(AppModel(defaults: defaults).devices.map(\.port), [8080])
        await model.shutdown()
        await restored.shutdown()
    }
}
