import CryptoKit
import Foundation

private final class DebianImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let startedAt = Date()
    private let allowedHost: String
    private let onProgress: @Sendable (Int64, Int64, TimeInterval) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var result: Result<URL, Error>?

    init(allowedHost: String, onProgress: @escaping @Sendable (Int64, Int64, TimeInterval) -> Void) {
        self.allowedHost = allowedHost
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite, Date().timeIntervalSince(startedAt))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" &&
                          request.url?.host == allowedHost ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-debian-\(UUID().uuidString).download")
        result = Result { try FileManager.default.moveItem(at: location, to: stable); return stable }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else if let result, let response = task.response {
            continuation.resume(with: result.map { ($0, response) })
        } else { continuation.resume(throwing: URLError(.cannotCreateFile)) }
    }
}

public enum DebianVMImageError: Error, LocalizedError, Sendable {
    case invalidDownload
    case missingChecksum
    case checksumMismatch
    case converterUnavailable
    case conversionFailed(String)
    case invalidDiskSize

    public var errorDescription: String? {
        switch self {
        case .invalidDownload: "The Debian image download was not from Debian's official image server."
        case .missingChecksum: "Debian's checksum list did not contain the expected ARM64 image."
        case .checksumMismatch: "The Debian image failed its SHA-512 check. Download it again."
        case .converterUnavailable:
            "Debian's cloud image needs qemu-img to create an Apple-compatible disk. Install qemu-img or use a Tether Host build that includes it."
        case .conversionFailed(let detail): "Could not prepare the Debian disk: \(detail)"
        case .invalidDiskSize: "The requested Debian disk size is invalid or smaller than the downloaded image."
        }
    }
}

/// Downloads verified ARM64 Debian images and prepares disks for Apple Virtualization.
/// All work is offline after the checksum-verified download; never operate on a running VM disk.
public enum DebianVMImageService {
    public static let version = "13"
    private static let downloadHost = "chuangtzu.ftp.acc.umu.se"
    private static let baseURL = URL(string: "https://chuangtzu.ftp.acc.umu.se/images/cloud/trixie/latest/")!
    public static let imageFilename = "debian-13-generic-arm64.qcow2"
    public static let imageSHA512 = "bef60fa5c4f5511cf83fe1ade0279edd5318dccbbb44f14eb0aa7f3b467e038d7a7c0b6f837be0ad1c3b2e06c5ed8e27adfdf0fd111a201b8f4c9347cd414863"

    public static func cachedImageURL(in directory: URL) -> URL {
        directory.appendingPathComponent(imageFilename)
    }

    public static func cachedDigestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(imageFilename).sha512")
    }

    public static func verifiedCachedImage(in directory: URL) async throws -> URL? {
        let image = cachedImageURL(in: directory)
        let digestFile = cachedDigestURL(in: directory)
        guard FileManager.default.fileExists(atPath: image.path),
              FileManager.default.fileExists(atPath: digestFile.path) else { return nil }
        let expected = try String(contentsOf: digestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected == imageSHA512 else { return nil }
        return try await sha512(of: image) == expected ? image : nil
    }

    public static func downloadVerifiedImage(
        into directory: URL,
        onProgress: @escaping @Sendable (Int64, Int64, TimeInterval) -> Void = { _, _, _ in }
    ) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let cached = try await verifiedCachedImage(in: directory) { return cached }

        let (temporary, imageResponse) = try await DebianImageDownload(
            allowedHost: downloadHost, onProgress: onProgress)
            .run(from: baseURL.appendingPathComponent(imageFilename))
        defer { try? manager.removeItem(at: temporary) }
        guard officialResponse(imageResponse, from: downloadHost) else { throw DebianVMImageError.invalidDownload }
        guard try await sha512(of: temporary) == imageSHA512 else { throw DebianVMImageError.checksumMismatch }
        let destination = directory.appendingPathComponent(imageFilename)
        let staged = directory.appendingPathComponent(".\(imageFilename).\(UUID().uuidString).download")
        try manager.moveItem(at: temporary, to: staged)
        do {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staged, to: destination)
            try Data(imageSHA512.utf8).write(to: cachedDigestURL(in: directory), options: .atomic)
            return destination
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    public static func createRawDisk(from image: URL, at destination: URL, diskGiB: Int,
                                     bundledConverter: URL?) async throws {
        guard diskGiB >= 24, diskGiB <= 1024 else { throw DebianVMImageError.invalidDiskSize }
        guard let converter = converterURL(bundledConverter) else { throw DebianVMImageError.converterUnavailable }
        try await Task.detached(priority: .utility) {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".disk-\(UUID().uuidString).img")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try run(converter, ["convert", "-f", "qcow2", "-O", "raw", "-S", "4k", image.path, temporary.path])
            let imageBytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let requestedBytes = Int64(diskGiB) * 1_073_741_824
            guard Int64(imageBytes) <= requestedBytes else { throw DebianVMImageError.invalidDiskSize }
            // `truncate` grows the raw disk sparsely. Debian cloud-init's growpart
            // and filesystem-resize modules use the extra capacity on first boot.
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(requestedBytes))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }.value
    }

    public static func converterURL(_ bundled: URL?) -> URL? {
        let candidates = [bundled,
                          URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img"),
                          URL(fileURLWithPath: "/usr/local/bin/qemu-img")].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile().prefix(1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DebianVMImageError.conversionFailed(detail.isEmpty ? "qemu-img exited with status \(process.terminationStatus)." : detail)
        }
    }

    private static func officialResponse(_ response: URLResponse, from host: String = "cloud-images.debian.com") -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https" else { return false }
        return response.url?.host == host
    }

    private static func sha512(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA512()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
