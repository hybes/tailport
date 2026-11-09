import XCTest
@testable import Tailport

final class UpdateTests: XCTestCase {
    private func release(_ tag: String, assets: [String]? = nil) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = assets ?? ["tailport-\(version)-macos.zip", "tailport-\(version)-windows-app-x64.zip", "SHA256SUMS"]
        let list = names.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/hybes/tailport/releases/tag/\#(tag)","assets":[\#(list)]}"#.utf8)
    }

    func testVersionsCompareNumericallyAndIgnoreThePrefixAndSuffix() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.0")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("v0.2.1")), try XCTUnwrap(AppVersion("0.3")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2")), try XCTUnwrap(AppVersion("1.2.0")))
        XCTAssertEqual(AppVersion("v1.4.0-beta.1")?.description, "1.4.0")
        for bad in ["", "v", "one", "1..2", "1.-2", "1.x"] { XCTAssertNil(AppVersion(bad), bad) }
    }

    func testReleaseDecodingFindsThisPlatformsArchiveAndChecksums() throws {
        let decoded = try AppRelease.decode(release("v0.3.0"))
        XCTAssertEqual(decoded.version, "0.3.0")
        XCTAssertEqual(decoded.archive.lastPathComponent, "tailport-0.3.0-macos.zip")
        XCTAssertEqual(decoded.checksums.lastPathComponent, "SHA256SUMS")
        XCTAssertEqual(decoded.page.absoluteString, "https://github.com/hybes/tailport/releases/tag/v0.3.0")
        XCTAssertThrowsError(try AppRelease.decode(release("v0.3.0", assets: ["SHA256SUMS"])))
        XCTAssertThrowsError(try AppRelease.decode(release("v0.3.0", assets: ["tailport-0.3.0-macos.zip"])))
        XCTAssertThrowsError(try AppRelease.decode(Data("{\"message\":\"Not Found\"}".utf8)))
    }

    func testChecksumsAreReadFromShasumOutput() {
        let sums = """
        aaa111  tailport-0.3.0-darwin.tar.gz
        BBB222 *tailport-0.3.0-macos.zip
        ccc333  tailport-0.3.0-macos.zip.old
        """
        XCTAssertEqual(AppRelease.checksum(for: "tailport-0.3.0-macos.zip", in: sums), "bbb222")
        XCTAssertNil(AppRelease.checksum(for: "tailport-0.3.0-windows.zip", in: sums))
    }

    @MainActor
    func testChecksOfferOnlyNewerReleasesAndManualChecksReportTheResult() async {
        let defaults = UserDefaults(suiteName: "tailport-update-tests-\(UUID())")!
        var served = release("v0.3.0")
        let updater = Updater(current: "0.2.1", defaults: defaults) { _ in served }
        XCTAssertTrue(updater.automatic)
        XCTAssertTrue(updater.checkDue)
        await updater.check()
        guard case .available(let found) = updater.state else { return XCTFail("Expected an update, got \(updater.state)") }
        XCTAssertEqual(found.version, "0.3.0")
        XCTAssertFalse(updater.checkDue)

        served = release("v0.2.1")
        await updater.check()
        XCTAssertEqual(updater.state, .idle, "An automatic check with nothing new stays quiet")
        await updater.check(manual: true)
        XCTAssertEqual(updater.state, .upToDate)
        updater.dismiss()
        XCTAssertEqual(updater.state, .idle)

        served = Data("not json".utf8)
        await updater.check()
        XCTAssertEqual(updater.state, .idle, "Automatic failures are silent")
        await updater.check(manual: true)
        guard case .failed(_, nil) = updater.state else { return XCTFail("Expected a failure, got \(updater.state)") }

        updater.automatic = false
        XCTAssertFalse(Updater(current: "0.2.1", defaults: defaults) { _ in Data() }.automatic)
    }

    @MainActor
    func testInstallRefusesMismatchedChecksumsAndLeavesTheAppAlone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-update-\(UUID())")
        let bundle = folder.appendingPathComponent("Tailport.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = try AppRelease.decode(release("v0.3.0"))
        let updater = Updater(current: "0.2.1", defaults: UserDefaults(suiteName: "tailport-update-tests-\(UUID())")!) { url in
            url.lastPathComponent == "SHA256SUMS" ? Data("\(String(repeating: "0", count: 64))  tailport-0.3.0-macos.zip\n".utf8) : Data("zip".utf8)
        }
        await updater.install(release, into: bundle)
        guard case .failed(let message, let offered?) = updater.state else { return XCTFail("Expected a failure, got \(updater.state)") }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertEqual(offered, release)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        updater.dismiss()
        XCTAssertEqual(updater.state, .available(release))
    }

    func testOnlyTailportSignedWithTheDeveloperIDIsAccepted() throws {
        // Calculator is signed by Apple, not with Tailport's Developer ID.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let version = try XCTUnwrap(NSDictionary(contentsOf: calculator.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
        XCTAssertThrowsError(try Updater.verify(calculator, version: version)) { error in
            XCTAssertTrue(error.localizedDescription.contains("signed"), error.localizedDescription)
        }
        XCTAssertThrowsError(try Updater.verify(calculator, version: "0.0.1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("isn’t Tailport"), error.localizedDescription)
        }
    }
}
