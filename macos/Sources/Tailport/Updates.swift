import Foundation
import AppKit
import CryptoKit
import Security

/// Where updates come from and who must have signed them.
enum UpdateSource {
    static let repository = "hybes/tailport"
    /// The Apple Developer team whose Developer ID signs release builds.
    static let team = "BBU4YNR4U3"
    static let bundleIdentifier = "dev.hybes.tailport"
    /// TAILPORT_UPDATE_FEED points at another release description, for testing.
    static var feed: URL {
        if let custom = ProcessInfo.processInfo.environment["TAILPORT_UPDATE_FEED"], let url = URL(string: custom) { return url }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }
    static func archiveName(_ version: String) -> String { "tailport-\(version)-macos.zip" }
}

/// A dotted version such as 0.2.1; a leading "v" and any pre-release suffix are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") { core.removeFirst() }
        core = String(core.prefix { $0 != "-" && $0 != "+" })
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
        description = core
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The parts of a GitHub release an update needs.
struct AppRelease: Equatable {
    let version: String
    let page: URL
    let archive: URL
    let checksums: URL

    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    /// Reads GitHub's release JSON, finding the archive named by `archiveName` and SHA256SUMS.
    static func decode(_ data: Data, archiveName: (String) -> String = UpdateSource.archiveName) throws -> AppRelease {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), let version = AppVersion(payload.tag_name) else {
            throw TailportError("GitHub returned a release Tailport could not read.")
        }
        let name = archiveName(version.description)
        guard let archive = payload.assets.first(where: { $0.name == name }),
              let sums = payload.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            throw TailportError("Tailport \(version) has no download for this computer yet.")
        }
        return AppRelease(version: version.description, page: payload.html_url,
                          archive: archive.browser_download_url, checksums: sums.browser_download_url)
    }

    /// The SHA-256 listed for `name` in a SHA256SUMS file.
    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let file = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            if file == name { return fields[0].lowercased() }
        }
        return nil
    }
}

enum UpdateState: Equatable {
    case idle
    case checking(manual: Bool)
    case upToDate
    case available(AppRelease)
    case installing(AppRelease)
    case failed(String, AppRelease?)
}

/// Checks GitHub for a newer Tailport and replaces this copy with it.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: Self.automaticKey) } }
    let current: String
    private let defaults: UserDefaults
    private let fetch: (URL) async throws -> Data
    private var schedule: Task<Void, Never>?
    private static let automaticKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    init(current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         defaults: UserDefaults = .standard, fetch: @escaping (URL) async throws -> Data = Updater.download) {
        self.current = current
        self.defaults = defaults
        self.fetch = fetch
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// Checks once a day while automatic checks are on. The first check waits a minute after launch.
    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if let self, self.automatic, self.checkDue { await self.check() }
                do { try await Task.sleep(for: .seconds(60 * 60)) } catch { return }
            }
        }
    }

    var checkDue: Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.interval
    }

    var available: AppRelease? {
        switch state {
        case .available(let release), .installing(let release), .failed(_, let release?): release
        default: nil
        }
    }

    /// Looks for a newer release. Automatic checks stay quiet unless one is found.
    func check(manual: Bool = false) async {
        if case .installing = state { return }
        if case .checking = state { return }
        let previous = state
        state = .checking(manual: manual)
        do {
            let release = try AppRelease.decode(try await fetch(UpdateSource.feed))
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let latest = AppVersion(release.version), let running = AppVersion(current), latest > running {
                state = .available(release)
            } else {
                state = manual ? .upToDate : .idle
            }
        } catch {
            if manual { state = .failed(Self.describe(error, checking: true), nil) }
            else if case .available = previous { state = previous }
            else { state = .idle }
        }
    }

    /// Hides the update banner. A failed install goes back to offering the update.
    func dismiss() {
        switch state {
        case .checking, .installing: return
        case .failed(_, let release?): state = .available(release)
        default: state = .idle
        }
    }

    /// Downloads and checks `release`, puts it in place of this copy, then quits and opens the new one.
    func install(_ release: AppRelease, into bundle: URL = Bundle.main.bundleURL) async {
        if case .installing = state { return }
        state = .installing(release)
        do {
            let installed = try await Self.replace(bundle, with: release, fetch: fetch)
            Self.relaunch(installed)
            // Quit from the run loop, not this task: quitting waits for the tunnels to close on the main actor,
            // which cannot happen while this task is still running there.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } catch {
            state = .failed(Self.describe(error, checking: false), release)
        }
    }

    nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Tailport", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404, url.host == "api.github.com" { throw TailportError("No Tailport release is published yet.") }
            if http.statusCode == 403 || http.statusCode == 429 { throw TailportError("GitHub is limiting requests. Try again in an hour.") }
            throw TailportError("GitHub returned an error (\(http.statusCode)). Try again later.")
        }
        return data
    }

    private static func describe(_ error: Error, checking: Bool) -> String {
        if let error = error as? TailportError { return error.message }
        if (error as? URLError) != nil {
            return checking ? "Couldn’t reach GitHub to check for updates. Check your connection and try again."
                : "The download didn’t finish. Check your connection and try again."
        }
        return error.localizedDescription
    }

    /// Checks that this copy can be replaced in place, then downloads, verifies and swaps in the new app.
    nonisolated static func replace(_ bundle: URL, with release: AppRelease,
                                    fetch: (URL) async throws -> Data) async throws -> URL {
        let folder = bundle.deletingLastPathComponent()
        if bundle.path.contains("/AppTranslocation/") {
            throw TailportError("Move Tailport to your Applications folder, open it from there, then install the update.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path), FileManager.default.isWritableFile(atPath: bundle.path) else {
            throw TailportError("Tailport can’t replace itself in \(folder.path). Download the update from GitHub instead.")
        }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let name = UpdateSource.archiveName(release.version)
        let sums = String(decoding: try await fetch(release.checksums), as: UTF8.self)
        guard let expected = AppRelease.checksum(for: name, in: sums) else {
            throw TailportError("The release’s SHA256SUMS doesn’t list \(name).")
        }
        let archive = try await fetch(release.archive)
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw TailportError("The download didn’t match its checksum, so it wasn’t installed.") }
        let zip = work.appendingPathComponent(name)
        try archive.write(to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        let unzip = try await Commands.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 60)
        guard unzip.status == 0 else { throw TailportError("The download couldn’t be opened: \(unzip.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let app = unpacked.appendingPathComponent("Tailport.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw TailportError("The download doesn’t contain Tailport.app.") }
        try verify(app, version: release.version)

        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
        return bundle
    }

    /// Accepts only a Tailport of the expected version signed with the Developer ID of `UpdateSource.team`.
    nonisolated static func verify(_ app: URL, version: String, team: String = UpdateSource.team) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw TailportError("The download isn’t Tailport \(version), so it wasn’t installed.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(UpdateSource.bundleIdentifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw TailportError("The download isn’t signed by Tailport’s developer, so it wasn’t installed.")
        }
    }

    /// Opens `app` once this process has quit.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(getpid()), app.path]
        try? process.run()
    }
}
