import XCTest
@testable import Tailport

final class DiscoveryTests: XCTestCase {
    func testListenersMergeIPv4IPv6AndProcessesAndKeepBoundAddresses() {
        let output = """
        p123
        cnode
        f12
        n127.0.0.1:3000
        f13
        n[::1]:3000
        p456
        cControlCenter
        n*:7000
        p789
        cOther process
        n*:3000
        n100.64.0.2:8080
        n[fd7a:115c::2]:8081
        n127.0.0.2:8082
        nnot-an-address:1234
        n*:70000
        """
        let ports = ListeningPort.parse(output)
        XCTAssertEqual(ports.map(\.number), [3000, 7000, 8080, 8081, 8082])
        XCTAssertEqual(ports[0].processes, ["Other process", "node"])
        XCTAssertEqual(ports[0].destination, "localhost")
        XCTAssertEqual(ports[2].destination, "100.64.0.2")
        XCTAssertEqual(ports[3].destination, "fd7a:115c::2")
        XCTAssertEqual(ports[4].destination, "127.0.0.2")
    }

    func testEmptyAndMalformedDiscovery() {
        XCTAssertTrue(ListeningPort.parse("").isEmpty)
        XCTAssertTrue(ListeningPort.parse("warning: cannot inspect process\nn*:0\nn*:abc\nnmissing").isEmpty)
    }

    func testDefaultRulesIgnoreSystemServicesWithoutBlockingDevelopmentPorts() throws {
        let rules = try IgnoreRules(ports: IgnoreRules.defaultPorts, processes: IgnoreRules.defaultProcesses)
        let listeners = [
            ListeningPort(number: 22, processes: ["sshd"]),
            ListeningPort(number: 5000, processes: ["ControlCenter"]),
            ListeningPort(number: 7000, processes: ["ControlCenter"]),
            ListeningPort(number: 49193, processes: ["rapportd"]),
            ListeningPort(number: 49556, processes: ["cloudflared"]),
            ListeningPort(number: 2432, processes: ["SetappAgent"]),
            ListeningPort(number: 3000, processes: ["node"]),
            ListeningPort(number: 5000, processes: ["Python"]),
            ListeningPort(number: 7000, processes: ["node"])
        ]
        XCTAssertEqual(listeners.filter(rules.allows).map(\.number), [3000, 5000, 7000])
    }

    func testCustomRulesSupportRangesAndCaseInsensitiveProcesses() throws {
        let rules = try IgnoreRules(ports: "3000, 8000-8002\n9000", processes: "Node, My App")
        XCTAssertFalse(rules.allows(ListeningPort(number: 8001, processes: ["Python"])))
        XCTAssertFalse(rules.allows(ListeningPort(number: 5173, processes: ["node"])))
        XCTAssertTrue(rules.allows(ListeningPort(number: 5173, processes: ["Python"])))
        XCTAssertTrue(rules.allows(ListeningPort(number: 5173, processes: ["ControlCenter", "Python"])))
        for bad in ["0", "65536", "8-7", "-1", "1-", "1-2-3", "hello", "0-2"] {
            XCTAssertThrowsError(try IgnoreRules(ports: bad, processes: ""), bad)
        }
    }

    func testPeerDecodingPreservesSSHShortAliasAndOfflineState() throws {
        let json = """
        {"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"Peer":{
          "one":{"HostName":"Mac mini","DNSName":"bh-mm.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true,"OS":"macOS"},
          "two":{"HostName":"Other Mac","DNSName":"other.example.ts.net.","Online":false},
          "three":{"DNSName":"-invalid.example.ts.net.","Online":true}
        }}
        """
        let peers = try Peer.decode(Data(json.utf8))
        XCTAssertEqual(peers.map(\.target), ["bh-mm", "other"])
        XCTAssertEqual(peers.map(\.online), [true, false])
        XCTAssertThrowsError(try Peer.decode(Data("{\"BackendState\":\"Stopped\"}".utf8)))
        XCTAssertThrowsError(try Peer.decode(Data("The Tailscale CLI failed to start".utf8)))
    }

    func testPeerDecodingFallsBackToAddressWithoutMagicDNS() throws {
        let json = """
        {"BackendState":"Running","Peer":{"one":{"HostName":"Mac mini","DNSName":"bh-mm.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true}}}
        """
        XCTAssertEqual(try Peer.decode(Data(json.utf8)).first?.target, "100.64.0.2")
    }

    func testForwardArgumentsBindBothLocalLoopbacksAndKeepRemoteIPv6Brackets() {
        let port = ListeningPort(number: 3000, processes: ["node"], destination: "fd7a:115c::2")
        let arguments = SSH.forwardingArguments(target: "bh-mm", port: port)
        XCTAssertTrue(arguments.contains("127.0.0.1:3000:[fd7a:115c::2]:3000"))
        XCTAssertTrue(arguments.contains("[::1]:3000:[fd7a:115c::2]:3000"))
        XCTAssertTrue(arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["--", "bh-mm", SSH.forwardingCommand])
        XCTAssertFalse(arguments.contains("-N"))
    }

    @MainActor func testExclusionsPersistAndInvalidChangesPreserveSavedRules() throws {
        let suite = "tailport-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        try model.applyExclusions(ports: "3000, 8000-8002", processes: "node")
        XCTAssertThrowsError(try model.applyExclusions(ports: "70000", processes: ""))
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.ignoredPorts, "3000, 8000-8002")
        XCTAssertEqual(restored.ignoredProcesses, "node")
    }
}
