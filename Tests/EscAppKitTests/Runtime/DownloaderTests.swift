@testable import EscAppKit
import Foundation
import Testing

@Suite struct DownloaderTests {
    let body = Data((0..<1000).map { UInt8($0 % 251) })

    /// Answers `Range: bytes=N-` with 206 and the rest of the body, like GitHub's CDN.
    func rangeServer(_ body: Data, log: Log? = nil) -> (host: String, configuration: URLSessionConfiguration) {
        StubProtocol.register { request in
            log?.add(request.value(forHTTPHeaderField: "Range"))
            if let range = request.value(forHTTPHeaderField: "Range"),
               let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                let headers = ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"]
                return (206, headers, body.subdata(in: start..<body.count))
            }
            return (200, [:], body)
        }
    }

    @Test func downloadsAndVerifies() async throws {
        let temp = try TempFolder()
        let server = rangeServer(body)
        let item = component(url: URL(string: "stub://\(server.host)/w.tar.xz")!, data: body)
        let seen = Log()
        let file = try await Downloader(configuration: server.configuration)
            .fetch(item, into: temp.url) { seen.add(String($0)) }
        #expect(try Data(contentsOf: file) == body)
        #expect(file.lastPathComponent == item.sha256)
        #expect(seen.values.last == "1000")
    }

    @Test func resumesFromThePartialFile() async throws {
        let temp = try TempFolder()
        let log = Log()
        let server = rangeServer(body, log: log)
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)
        try body.prefix(400).write(to: temp.url.appending(path: item.sha256 + ".part"))

        let file = try await Downloader(configuration: server.configuration).fetch(item, into: temp.url)
        #expect(log.values == ["bytes=400-"])
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func startsOverWhenTheServerIgnoresRange() async throws {
        let temp = try TempFolder()
        let server = StubProtocol.register { [body] _ in (200, [:], body) }
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)
        // A stale partial file with wrong bytes: it must not end up in front of the fresh download.
        try Data(repeating: 0xFF, count: 400).write(to: temp.url.appending(path: item.sha256 + ".part"))

        let file = try await Downloader(configuration: server.configuration).fetch(item, into: temp.url)
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func wrongBytesAreDeleted() async throws {
        let temp = try TempFolder()
        var tampered = body
        tampered[10] ^= 0x01
        let server = rangeServer(tampered)
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)

        await #expect(throws: DownloadError.checksumMismatch) {
            try await Downloader(configuration: server.configuration).fetch(item, into: temp.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test func tooManyBytesStopTheDownload() async throws {
        let temp = try TempFolder()
        let server = rangeServer(body + body)
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)
        await #expect(throws: DownloadError.self) {
            try await Downloader(configuration: server.configuration).fetch(item, into: temp.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test func httpErrorsAreReported() async throws {
        let temp = try TempFolder()
        let server = StubProtocol.register { _ in (404, [:], Data("Not Found".utf8)) }
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)
        await #expect(throws: DownloadError.httpStatus(404)) {
            try await Downloader(configuration: server.configuration).fetch(item, into: temp.url)
        }
    }

    @Test func aVerifiedFileIsNotDownloadedAgain() async throws {
        let temp = try TempFolder()
        let log = Log()
        let server = rangeServer(body, log: log)
        let item = component(url: URL(string: "stub://\(server.host)/w")!, data: body)
        let downloader = Downloader(configuration: server.configuration)
        _ = try await downloader.fetch(item, into: temp.url)
        _ = try await downloader.fetch(item, into: temp.url)
        #expect(log.values.count == 1)
    }

    @Test func fileURLsWork() async throws {
        let temp = try TempFolder()
        let source = temp.url.appending(path: "local.bin")
        try body.write(to: source)
        let item = component(url: source, data: body)
        let file = try await Downloader().fetch(item, into: temp.url.appending(path: "dl"))
        #expect(try Data(contentsOf: file) == body)
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func add(_ value: String?) { lock.withLock { items.append(value) } }
    var values: [String?] { lock.withLock { items } }
}
