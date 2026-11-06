import XCTest
@testable import Tailport

final class ScanTests: XCTestCase {
    func testParseGroupsPortsByHostAndSortsAddressesNumerically() {
        let output = """
        S 192.168.1.0/24
        P 192.168.1.254 443
        H 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa
        H 192.168.1.71 f0:09:0d:63:de:10 deco-X10.lan
        P 192.168.1.254 80
        H 192.168.1.9 b4:1f:4d:46:49:e4
        P not-an-ip 80
        P 192.168.1.9 99999
        garbage
        """
        let result = NetworkScan.parse(output)
        XCTAssertEqual(result.subnet, "192.168.1.0/24")
        XCTAssertEqual(result.hosts.map(\.ip), ["192.168.1.254", "192.168.1.9", "192.168.1.71"],
                       "Devices with open ports first, then the rest, each in address order")
        XCTAssertEqual(result.hosts[0].ports, [80, 443])
        XCTAssertEqual(result.hosts[0].label, "hub")
        XCTAssertEqual(result.hosts[2].label, "deco-X10")
        XCTAssertEqual(result.hosts[1].label, "192.168.1.9")
        XCTAssertEqual(result.hosts[1].ports, [])
    }

    func testKnownPortsGetNamesLinksAndAreAllScanned() {
        let hd = ScannedHost(ip: "192.168.1.229", mac: "90:09:d0:16:91:c9", name: "HD.lan")
        XCTAssertEqual(NetworkScan.deviceName(hd, port: 32400), "HD · Plex")
        XCTAssertEqual(NetworkScan.deviceName(hd, port: 25565), "HD · Minecraft")
        XCTAssertEqual(NetworkScan.deviceName(hd, port: 443), "HD", "Web pages keep the device's own name")
        XCTAssertEqual(NetworkScan.deviceName(hd, port: 12345), "HD")
        XCTAssertEqual(NetworkScan.service(5173), "Vite")
        for port in [3000, 5173, 8080, 8123, 25565, 32400] { XCTAssertTrue(NetworkScan.ports.contains(port), "\(port)") }
        XCTAssertTrue(NetworkScan.script.contains("ports=\"\(NetworkScan.ports.map(String.init).joined(separator: " "))\""))
        XCTAssertFalse(NetworkScan.script.contains("@PORTS@"))
        func url(_ port: Int) -> String? { NetworkDevice(name: "", host: "h", port: port, localPort: 10000 + port % 10000).url?.absoluteString }
        XCTAssertEqual(url(80), "http://localhost:10080")
        XCTAssertEqual(url(5001), "https://localhost:15001")
        XCTAssertEqual(url(445), "smb://localhost:10445")
        XCTAssertEqual(url(5900), "vnc://localhost:15900")
        XCTAssertNil(url(25565), "Minecraft is opened from the game, not a browser")
    }

    /// Runs the real scan script against stub tools, so no network is touched.
    private func runScript(darwin: Bool, netcat: Bool = true) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stubs: [String: String] = [
            "uname": "echo \(darwin ? "Darwin" : "Linux")",
            "ip": """
            case "$*" in
              *"route show default"*) echo 'default via 10.9.8.254 dev eth0 proto dhcp src 10.9.8.20 metric 100';;
              *"addr show dev eth0"*) echo '2: eth0    inet 10.9.8.20/24 brd 10.9.8.255 scope global eth0';;
              *"neigh show dev eth0"*) printf '%s\\n' '10.9.8.254 lladdr 60:8d:26:cc:fa:63 REACHABLE' '10.9.8.30 lladdr aa:bb:cc:dd:ee:ff STALE' '10.9.8.31  FAILED' '10.0.1.4 lladdr aa:cf:b1:94:b6:50 STALE';;
            esac
            """,
            "route": "echo '  interface: en0'",
            "ifconfig": "echo '\tinet 10.9.8.20 netmask 0xffffff00 broadcast 10.9.8.255'",
            "arp": "echo '? (10.9.8.254) at 60:8d:26:cc:fa:63 on en0 ifscope [ethernet]'; echo '? (10.9.8.31) at (incomplete) on en0 ifscope [ethernet]'",
            "ping": "echo \"$@\" >> \"\(directory.path)/pinged\"",
            "nc": "for last; do :; done; case \"$*\" in *'10.9.8.254 443'*|*'10.9.8.30 22'*) exit 0;; esac; exit 1",
            "getent": "[ \"$2\" = 10.9.8.254 ] && echo '10.9.8.254 hub.home.arpa'",
            "timeout": "shift; exec \"$@\""
        ]
        for (name, body) in stubs {
            let url = directory.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        if darwin { try FileManager.default.removeItem(at: directory.appendingPathComponent("getent")) }
        if !netcat {
            // Without the system directories on the PATH, the only tools are the stubs plus awk and grep.
            try FileManager.default.removeItem(at: directory.appendingPathComponent("nc"))
            for tool in ["awk", "grep"] {
                try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(tool).path, withDestinationPath: "/usr/bin/\(tool)")
            }
        }
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ["PATH": netcat ? "\(directory.path):/usr/bin:/bin" : directory.path]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(NetworkScan.script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let pinged = try String(contentsOf: directory.appendingPathComponent("pinged"), encoding: .utf8)
        XCTAssertEqual(pinged.split(separator: "\n").count, 253, "Every other address on the /24 is probed once")
        XCTAssertFalse(pinged.contains("10.9.8.20\n"), "The machine itself is skipped")
        return String(decoding: data, as: UTF8.self)
    }

    func testScriptOnLinuxFindsNeighboursNamesAndOpenPorts() throws {
        let result = NetworkScan.parse(try runScript(darwin: false))
        XCTAssertEqual(result.subnet, "10.9.8.0/24")
        XCTAssertEqual(Set(result.hosts.map(\.ip)), ["10.9.8.30", "10.9.8.254"], "Failed and other-interface neighbours are left out")
        let hub = try XCTUnwrap(result.hosts.first { $0.ip == "10.9.8.254" })
        XCTAssertEqual(hub.name, "hub.home.arpa")
        XCTAssertEqual(hub.ports, [443])
        XCTAssertEqual(result.hosts.first { $0.ip == "10.9.8.30" }?.ports, [22])
    }

    func testScriptWithoutNetcatListsDevicesAndSaysPortsWereNotChecked() throws {
        let result = NetworkScan.parse(try runScript(darwin: false, netcat: false))
        XCTAssertFalse(result.portsChecked)
        XCTAssertEqual(Set(result.hosts.map(\.ip)), ["10.9.8.30", "10.9.8.254"])
        XCTAssertTrue(result.hosts.allSatisfy(\.ports.isEmpty))
        XCTAssertTrue(NetworkScan.parse(try runScript(darwin: false)).portsChecked)
        XCTAssertTrue(NetworkScan.missingNetcat(on: "th-pi-400").contains("sudo apt install netcat-openbsd"))
    }

    func testScriptOnMacReadsHexNetmaskAndArpTable() throws {
        let result = NetworkScan.parse(try runScript(darwin: true))
        XCTAssertEqual(result.subnet, "10.9.8.0/24")
        XCTAssertEqual(result.hosts.map(\.ip), ["10.9.8.254"])
        XCTAssertEqual(result.hosts[0].mac, "60:8d:26:cc:fa:63")
        XCTAssertEqual(result.hosts[0].ports, [443])
    }

    @MainActor func testScanSendsTheScriptOverSSHAndConnectsAFoundPort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let received = directory.appendingPathComponent("stdin")
        let fixture = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        case "$*" in
          *"/bin/sh -s") cat > '\(received.path)'; printf 'S 192.168.1.0/24\\nH 192.168.1.254 60:8d:26:cc:fa:63 hub.home.arpa\\nP 192.168.1.254 443\\n';;
          *) printf 'TAILPORT_READY\\n'; exec /bin/cat >/dev/null;;
        esac
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let suite = "tailport-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("th-pi-400", forKey: "machine")
        let model = AppModel(defaults: defaults, sshExecutable: fixture.path, supervisorExecutable: fixture.path)
        await model.scanNetwork()
        XCTAssertNil(model.scanError)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), NetworkScan.script)
        let hub = try XCTUnwrap(model.scannedHosts.first)
        try model.connect(hub, port: 443)
        try model.connect(hub, port: 443)
        XCTAssertEqual(model.devices, [NetworkDevice(name: "hub", host: "192.168.1.254", port: 443, localPort: 10443)])
        for _ in 0..<100 where model.deviceStates[hub.ip + ":443"] != .forwarding { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.deviceStates["192.168.1.254:443"], .forwarding)
        model.selectMachine("bh-mm")
        XCTAssertTrue(model.scannedHosts.isEmpty, "Scan results belong to the machine that was scanned")
        await model.shutdown()
    }
}
