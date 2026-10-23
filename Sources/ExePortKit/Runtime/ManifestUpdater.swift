import Foundation

/// Keeps the component list current. The copy inside the app always works offline; a newer list is fetched
/// from the repository (the same file, on `main`) about once a day and cached in `ExePort/Manifest.json`.
///
/// A fetched list may only point at downloads on GitHub. The SHA-256 pins protect against a damaged or
/// swapped file, and the host rule keeps a tampered list from sending ExePort to some other server.
public struct ManifestUpdater: Sendable {
    static let manifestPath = "Zig1375/ExePort/main/Sources/ExePortKit/Resources/runtime-manifest.json"
    // A constant, well-formed URL; failing here would be a typo caught by the first test run.
    // swiftlint:disable:next force_unwrapping
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/\(manifestPath)")!
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    static let allowedDownloadHosts: Set<String> = ["github.com"]

    /// What was last fetched, and when.
    public struct Cache: Codable, Sendable, Equatable {
        public var checkedAt: Date
        public var manifest: RuntimeManifest
    }

    let paths: AppPaths
    let url: URL
    let configuration: URLSessionConfiguration
    let bundled: @Sendable () throws -> RuntimeManifest

    public init(
        paths: AppPaths,
        url: URL = ManifestUpdater.defaultURL,
        configuration: URLSessionConfiguration = .ephemeral,
        bundled: @escaping @Sendable () throws -> RuntimeManifest = { try RuntimeManifest.bundled() }
    ) {
        self.paths = paths
        self.url = url
        self.configuration = configuration
        self.bundled = bundled
    }

    public var cacheFile: URL { paths.root.appending(path: "Manifest.json") }

    public func cached() -> Cache? {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder.iso.decode(Cache.self, from: data),
              (try? Self.validateRemote(cache.manifest)) != nil
        else { return nil }
        return cache
    }

    /// The list to use right now, without touching the network.
    public func current() throws -> RuntimeManifest {
        Self.choose(bundled: try bundled(), cached: cached()?.manifest)
    }

    /// The cached list wins unless it is older than the app: a new app version may ship runtimes the cache
    /// from last week doesn't know about yet.
    static func choose(bundled: RuntimeManifest, cached: RuntimeManifest?) -> RuntimeManifest {
        guard let cached else { return bundled }
        let known = Set(cached.runtimes.map(\.id))
        return bundled.runtimes.allSatisfy { known.contains($0.id) } ? cached : bundled
    }

    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        // A clock moved backwards also counts as due, rather than never checking again.
        return now.timeIntervalSince(lastChecked) >= checkInterval || now < lastChecked
    }

    /// Fetches the list, checks it and caches it. Returns the list to use from now on.
    @discardableResult
    public func check(now: Date = Date()) async throws -> RuntimeManifest {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw DownloadError.httpStatus(status)
        }
        let manifest = try RuntimeManifest.decode(data)
        try Self.validateRemote(manifest)

        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(Cache(checkedAt: now, manifest: manifest)).write(to: cacheFile, options: .atomic)
        return Self.choose(bundled: try bundled(), cached: manifest)
    }

    static func validateRemote(_ manifest: RuntimeManifest) throws {
        for runtime in manifest.runtimes {
            for component in runtime.components {
                guard component.url.scheme == "https",
                      let host = component.url.host(), allowedDownloadHosts.contains(host)
                else {
                    throw ManifestError.invalidEntry("\(runtime.id)/\(component.kind.rawValue): download host")
                }
            }
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
