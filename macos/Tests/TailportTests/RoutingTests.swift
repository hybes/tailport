import XCTest
@testable import Tailport

final class RoutingTests: XCTestCase {
    private let status = """
    {"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"Peer":{
      "pi":{"HostName":"bh-pi-5","DNSName":"bh-pi-5.example.ts.net.","TailscaleIPs":["100.64.0.5","fd7a::5"],"Online":true,"OS":"linux",
            "ExitNodeOption":true,"ExitNode":false,"PrimaryRoutes":["192.168.1.0/24","0.0.0.0/0"]},
      "cloud":{"HostName":"uk1","DNSName":"uk1.example.ts.net.","TailscaleIPs":["100.64.0.6"],"Online":true,"OS":"linux","ExitNodeOption":true},
      "away":{"HostName":"spare","DNSName":"spare.example.ts.net.","TailscaleIPs":["100.64.0.7"],"Online":false,"ExitNodeOption":true},
      "mac":{"HostName":"bh-mm","DNSName":"bh-mm.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true,"OS":"macOS"}
    }}
    """

    func testPeerDecodingReadsExitNodeAndSharedSubnets() throws {
        let peers = try Peer.decode(Data(status.utf8))
        let pi = try XCTUnwrap(peers.first { $0.target == "bh-pi-5" })
        XCTAssertEqual(pi.address, "100.64.0.5")
        XCTAssertTrue(pi.exitNodeOption)
        XCTAssertFalse(pi.isExitNode)
        XCTAssertEqual(pi.routes, ["192.168.1.0/24"], "Default routes are not a shared network")
        XCTAssertFalse(try XCTUnwrap(peers.first { $0.target == "bh-mm" }).exitNodeOption)
    }

    func testArgumentsSetOrClearTheExitNodeAndAcceptSharedSubnets() {
        let pi = Peer(name: "bh-pi-5", target: "bh-pi-5", online: true, os: "linux", address: "100.64.0.5",
                      exitNodeOption: true, routes: ["192.168.1.0/24"])
        let cloud = Peer(name: "uk1", target: "uk1", online: true, os: "linux", address: "100.64.0.6", exitNodeOption: true)
        XCTAssertEqual(Routing.arguments(for: pi), ["set", "--exit-node=100.64.0.5", "--accept-routes"])
        XCTAssertEqual(Routing.arguments(for: cloud), ["set", "--exit-node=100.64.0.6"])
        XCTAssertEqual(Routing.arguments(for: nil), ["set", "--exit-node="])
    }

    func testErrorsDropTailscaleTimestampsAndExplainUnapprovedExitNodes() {
        let pi = Peer(name: "bh-pi-5", target: "bh-pi-5", online: true, os: "linux", address: "100.64.0.5")
        XCTAssertTrue(Routing.explain("2026/11/06 16:48:12 node \"100.64.0.5\" is not advertising an exit node\n", peer: pi)
            .hasPrefix("bh-pi-5 no longer offers routing."))
        XCTAssertEqual(Routing.explain("2026/11/06 16:48:12 something else failed\n", peer: pi), "something else failed")
        XCTAssertTrue(Routing.explain("2026/11/06 16:51:04 Cannot advertise an exit node and use an exit node at the same time.", peer: pi)
            .hasPrefix("This Mac is set to run as an exit node."))
        XCTAssertEqual(Routing.explain("", peer: nil), "Tailscale could not stop routing. Open Tailscale and try again.")
    }

    @MainActor func testRoutingSetsTheExitNodeAndReflectsTailscaleState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A fake Tailscale CLI that remembers the chosen exit node and reports it in its status.
        let state = directory.appendingPathComponent("exit-node")
        let json = directory.appendingPathComponent("status.json")
        let log = directory.appendingPathComponent("calls")
        try status.write(to: json, atomically: true, encoding: .utf8)
        let fixture = directory.appendingPathComponent("tailscale")
        try """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$1" in
          set)
            node="${2#--exit-node=}"
            case "$node" in 100.64.0.6) echo '2026/11/06 16:48:12 node "100.64.0.6" is not advertising an exit node' >&2; exit 1;; esac
            printf '%s' "$node" > '\(state.path)'; exit 0;;
          status)
            node=$(cat '\(state.path)' 2>/dev/null)
            if [ -n "$node" ]; then
              /usr/bin/sed "s/\\"TailscaleIPs\\":\\[\\"$node\\"/\\"ExitNode\\":true,&/" '\(json.path)'
            else
              cat '\(json.path)'
            fi;;
        esac
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let suite = "tailport-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bh-mm", forKey: "machine")
        let model = AppModel(defaults: defaults, sshExecutable: "/usr/bin/false", tailscaleExecutable: { fixture.path })
        await model.route(through: nil)
        XCTAssertEqual(model.routers.map(\.target), ["bh-pi-5", "uk1"], "Offline and non-exit peers are not offered")
        XCTAssertNil(model.router)

        await model.route(through: "bh-pi-5")
        XCTAssertEqual(model.router?.target, "bh-pi-5")
        XCTAssertNil(model.routingError)
        XCTAssertFalse(model.routingBusy)

        await model.route(through: "uk1")
        XCTAssertEqual(model.router?.target, "bh-pi-5", "A refused change keeps the existing route")
        XCTAssertTrue(model.routingError?.hasPrefix("uk1 no longer offers routing.") == true)

        await model.route(through: nil)
        XCTAssertNil(model.router)
        XCTAssertNil(model.routingError)
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("set --exit-node=100.64.0.5 --accept-routes"))
    }
}
