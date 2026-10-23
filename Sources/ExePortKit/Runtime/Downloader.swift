import CryptoKit
import Foundation

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int)
    /// The file doesn't match the manifest. It is deleted, never installed.
    case checksumMismatch
    case sizeMismatch(expected: Int64, received: Int64)

    public var description: String {
        switch self {
        case let .httpStatus(code): "The download server answered with error \(code)."
        case .checksumMismatch: "The downloaded file is damaged or not the expected one, so ExePort didn't use it."
        case let .sizeMismatch(expected, received):
            "The download stopped early or was too big (\(received) of \(expected) bytes)."
        }
    }
}

/// Downloads one manifest component into `folder`, checking its SHA-256 as the bytes arrive.
///
/// The partial file is named by its hash and kept when the connection drops, so the next attempt asks the
/// server only for the missing part (HTTP `Range`). A file that fails the check is deleted.
public struct Downloader: Sendable {
    let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    /// - Parameter progress: bytes received so far, including what an earlier attempt already had.
    /// - Returns: the verified file, `<folder>/<sha256>`.
    public func fetch(
        _ component: RuntimeManifest.Component,
        into folder: URL,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let done = folder.appending(path: component.sha256)
        let part = folder.appending(path: component.sha256 + ".part")

        if fileManager.fileExists(atPath: done.path) {
            if try Self.sha256(of: done) == component.sha256 {
                progress(component.size)
                return done
            }
            try fileManager.removeItem(at: done)
        }

        var hasher = SHA256()
        var existing: Int64 = 0
        if let size = try? fileManager.attributesOfItem(atPath: part.path)[.size] as? Int64 {
            if size <= component.size {
                existing = size
                try Self.feed(part, into: &hasher)
            } else {
                try fileManager.removeItem(at: part)
            }
        }
        if !fileManager.fileExists(atPath: part.path) {
            fileManager.createFile(atPath: part.path, contents: nil)
        }

        var request = URLRequest(url: component.url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let writer = try ChunkWriter(file: part, offset: existing, hasher: hasher, limit: component.size,
                                     progress: progress)
        let result: ChunkWriter.Result
        do {
            result = try await writer.run(request, configuration: configuration)
        } catch let error as DownloadError {
            // A wrong answer from the server can't be resumed; a dropped connection (any other error) can.
            try? fileManager.removeItem(at: part)
            throw error
        }

        guard result.received == component.size else {
            try? fileManager.removeItem(at: part)
            throw DownloadError.sizeMismatch(expected: component.size, received: result.received)
        }
        guard result.digest == component.sha256 else {
            try? fileManager.removeItem(at: part)
            throw DownloadError.checksumMismatch
        }
        try fileManager.moveItem(at: part, to: done)
        return done
    }

    static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        try feed(file, into: &hasher)
        return hex(hasher.finalize())
    }

    static func feed(_ file: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Receives the response in chunks, appends them to the partial file and hashes them on the way.
/// All state is touched only on the session's serial delegate queue.
private final class ChunkWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var received: Int64
        var digest: String
    }

    private let handle: FileHandle
    private var hasher: SHA256
    private var received: Int64
    private let resumedFrom: Int64
    private let limit: Int64
    private let progress: @Sendable (Int64) -> Void
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Result, any Error>?

    init(file: URL, offset: Int64, hasher: SHA256, limit: Int64,
         progress: @escaping @Sendable (Int64) -> Void) throws {
        handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(offset))
        self.hasher = hasher
        received = offset
        resumedFrom = offset
        self.limit = limit
        self.progress = progress
    }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Result {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // file:// URLs (tests, local manifests) have no status code and always send the whole file.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 206 where resumedFrom > 0:
            completionHandler(.allow)
        case 200:
            // The server ignored Range: start over so the hash covers exactly the bytes in the file.
            do {
                if resumedFrom > 0 {
                    try handle.truncate(atOffset: 0)
                    hasher = SHA256()
                    received = 0
                }
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        default:
            failure = DownloadError.httpStatus(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= limit else {
            failure = DownloadError.sizeMismatch(expected: limit, received: received)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            progress(received)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        guard let continuation else { return }
        self.continuation = nil
        if let failure = failure ?? error {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(returning: Result(received: received, digest: Downloader.hex(hasher.finalize())))
        }
    }
}
