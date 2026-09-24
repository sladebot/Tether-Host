import CryptoKit
import Foundation

private final class UbuntuImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
            .appendingPathComponent("tether-ubuntu-\(UUID().uuidString).download")
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

public enum UbuntuVMImageError: Error, LocalizedError, Sendable {
    case invalidDownload
    case missingChecksum
    case checksumMismatch
    case converterUnavailable
    case conversionFailed(String)
    case invalidDiskSize

    public var errorDescription: String? {
        switch self {
        case .invalidDownload: "The Ubuntu image download was not from Ubuntu's official image server."
        case .missingChecksum: "Ubuntu's checksum list did not contain the expected ARM64 image."
        case .checksumMismatch: "The Ubuntu image failed its SHA-256 check. Download it again."
        case .converterUnavailable:
            "Ubuntu's cloud image needs qemu-img to create an Apple-compatible disk. Install qemu-img or use a Tether Host build that includes it."
        case .conversionFailed(let detail): "Could not prepare the Ubuntu disk: \(detail)"
        case .invalidDiskSize: "The requested Ubuntu disk size is invalid or smaller than the downloaded image."
        }
    }
}

/// Downloads verified ARM64 Ubuntu images and prepares disks for Apple Virtualization.
/// All work is offline after the checksum-verified download; never operate on a running VM disk.
public enum UbuntuVMImageService {
    public static let version = "24.04"
    private static let baseURL = URL(string: "https://cloud-images.ubuntu.com/releases/server/24.04/release/")!
    private static let imageFilename = "ubuntu-24.04-server-cloudimg-arm64.img"
    private static let manualBaseURL = URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/")!
    private static let manualImageFilename = "ubuntu-24.04.3-desktop-arm64.iso"
    private static let manualImageSHA256 = "cdbf0f83ab4f7d46be767e73c59b5cbca9743dd5fb887142c96f4b2df38fa5ad"

    public static func manualCachedImageURL(in directory: URL) -> URL {
        directory.appendingPathComponent(manualImageFilename)
    }

    public static func verifiedManualCachedImage(in directory: URL) async throws -> URL? {
        let image = manualCachedImageURL(in: directory)
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }
        return try await sha256(of: image) == manualImageSHA256 ? image : nil
    }

    public static func downloadVerifiedManualImage(
        into directory: URL,
        onProgress: @escaping @Sendable (Int64, Int64, TimeInterval) -> Void = { _, _, _ in }
    ) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let cached = try await verifiedManualCachedImage(in: directory) { return cached }

        let (checksumBytes, checksumResponse) = try await URLSession.shared.data(
            from: manualBaseURL.appendingPathComponent("SHA256SUMS"))
        guard officialResponse(checksumResponse, from: "cdimage.ubuntu.com"),
              let checksums = String(data: checksumBytes, encoding: .utf8) else {
            throw UbuntuVMImageError.invalidDownload
        }
        guard checksum(for: manualImageFilename, in: checksums) == manualImageSHA256 else {
            throw UbuntuVMImageError.missingChecksum
        }

        let (temporary, imageResponse) = try await UbuntuImageDownload(
            allowedHost: "cdimage.ubuntu.com", onProgress: onProgress
        ).run(from: manualBaseURL.appendingPathComponent(manualImageFilename))
        defer { try? manager.removeItem(at: temporary) }
        guard officialResponse(imageResponse, from: "cdimage.ubuntu.com") else {
            throw UbuntuVMImageError.invalidDownload
        }
        guard try await sha256(of: temporary) == manualImageSHA256 else {
            throw UbuntuVMImageError.checksumMismatch
        }
        let destination = manualCachedImageURL(in: directory)
        let staged = directory.appendingPathComponent(".\(manualImageFilename).\(UUID().uuidString).download")
        try manager.moveItem(at: temporary, to: staged)
        do {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staged, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    public static func cachedImageURL(in directory: URL) -> URL {
        directory.appendingPathComponent(imageFilename)
    }

    public static func cachedDigestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(imageFilename).sha256")
    }

    public static func verifiedCachedImage(in directory: URL) async throws -> URL? {
        let image = cachedImageURL(in: directory)
        let digestFile = cachedDigestURL(in: directory)
        guard FileManager.default.fileExists(atPath: image.path),
              FileManager.default.fileExists(atPath: digestFile.path) else { return nil }
        let expected = try String(contentsOf: digestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { return nil }
        return try await sha256(of: image) == expected ? image : nil
    }

    public static func downloadVerifiedImage(
        into directory: URL,
        onProgress: @escaping @Sendable (Int64, Int64, TimeInterval) -> Void = { _, _, _ in }
    ) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let cached = try await verifiedCachedImage(in: directory) { return cached }

        let checksumURL = baseURL.appendingPathComponent("SHA256SUMS")
        let (checksumBytes, checksumResponse) = try await URLSession.shared.data(from: checksumURL)
        guard officialResponse(checksumResponse),
              let checksums = String(data: checksumBytes, encoding: .utf8) else {
            throw UbuntuVMImageError.invalidDownload
        }
        guard let expected = checksum(for: imageFilename, in: checksums) else {
            throw UbuntuVMImageError.missingChecksum
        }

        let (temporary, imageResponse) = try await UbuntuImageDownload(
            allowedHost: "cloud-images.ubuntu.com", onProgress: onProgress)
            .run(from: baseURL.appendingPathComponent(imageFilename))
        defer { try? manager.removeItem(at: temporary) }
        guard officialResponse(imageResponse) else { throw UbuntuVMImageError.invalidDownload }
        guard try await sha256(of: temporary) == expected else { throw UbuntuVMImageError.checksumMismatch }
        let destination = directory.appendingPathComponent(imageFilename)
        let staged = directory.appendingPathComponent(".\(imageFilename).\(UUID().uuidString).download")
        try manager.moveItem(at: temporary, to: staged)
        do {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staged, to: destination)
            try Data(expected.utf8).write(to: directory.appendingPathComponent("\(imageFilename).sha256"), options: .atomic)
            return destination
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    public static func createRawDisk(from image: URL, at destination: URL, diskGiB: Int,
                                     bundledConverter: URL?) async throws {
        guard diskGiB >= 24, diskGiB <= 1024 else { throw UbuntuVMImageError.invalidDiskSize }
        guard let converter = converterURL(bundledConverter) else { throw UbuntuVMImageError.converterUnavailable }
        try await Task.detached(priority: .utility) {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".disk-\(UUID().uuidString).img")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try run(converter, ["convert", "-f", "qcow2", "-O", "raw", "-S", "4k", image.path, temporary.path])
            let imageBytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let requestedBytes = Int64(diskGiB) * 1_073_741_824
            guard Int64(imageBytes) <= requestedBytes else { throw UbuntuVMImageError.invalidDiskSize }
            // `truncate` grows the raw disk sparsely. Ubuntu cloud-init's growpart
            // and filesystem-resize modules use the extra capacity on first boot.
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(requestedBytes))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }.value
    }

    /// Creates a sparse disk for an interactive desktop installation.
    public static func createBlankDisk(at destination: URL, diskGiB: Int) async throws {
        guard diskGiB >= 24, diskGiB <= 1024 else { throw UbuntuVMImageError.invalidDiskSize }
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".disk-\(UUID().uuidString).img")
            defer { try? manager.removeItem(at: temporary) }
            try Data().write(to: temporary, options: .atomic)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(diskGiB) * 1_073_741_824)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try manager.moveItem(at: temporary, to: destination)
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
            throw UbuntuVMImageError.conversionFailed(detail.isEmpty ? "qemu-img exited with status \(process.terminationStatus)." : detail)
        }
    }

    private static func officialResponse(_ response: URLResponse, from host: String = "cloud-images.ubuntu.com") -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https" else { return false }
        return response.url?.host == host
    }

    private static func checksum(for filename: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename else { continue }
            let digest = String(fields[0]).lowercased()
            if digest.count == 64 && digest.allSatisfy({ $0.isHexDigit }) { return digest }
        }
        return nil
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
