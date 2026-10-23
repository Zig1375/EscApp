import CryptoKit
@testable import ExePortKit
import Foundation

/// A temporary folder removed when the value goes away.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ExePortTests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func component(url: URL, data: Data, kind: RuntimeManifest.Component.Kind = .wine,
               from: String = "", into: String = "wine") -> RuntimeManifest.Component {
    RuntimeManifest.Component(kind: kind, version: "1", url: url, sha256: sha256Hex(data), size: Int64(data.count),
                              license: "MIT", from: from, into: into)
}

/// Serves canned responses for `stub://<host>/...`, one handler per host so parallel tests don't collide.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ handler: @escaping Handler) -> (host: String, configuration: URLSessionConfiguration) {
        let host = UUID().uuidString.lowercased()
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (host, configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "stub" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let handler = Self.lock.withLock({ Self.handlers[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, like a real network, so the hashing-as-you-go path is exercised.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 7, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A `.tar.gz` holding `files` (relative path → contents), made with the same bsdtar the installer uses.
func makeArchive(_ files: [String: String], in folder: URL) throws -> Data {
    let source = folder.appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
    for (path, contents) in files {
        let file = source.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
    let archive = folder.appending(path: "archive-\(UUID().uuidString).tar.gz")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/tar")
    // Top-level entries by name, like real release archives (no leading "./").
    let entries = try FileManager.default.contentsOfDirectory(atPath: source.path)
    process.arguments = ["-czf", archive.path, "-C", source.path] + entries
    try process.run()
    process.waitUntilExit()
    return try Data(contentsOf: archive)
}

/// Test-only shorthand; a typo in a literal should crash the test, not be handled.
func version(_ string: String) -> Version {
    guard let version = Version(string) else { fatalError("Bad version literal \(string)") }
    return version
}
