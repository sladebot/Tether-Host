import Foundation

public struct DownloadProgressEstimate: Equatable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let fraction: Double?
    public let bytesPerSecond: Double?
    public let secondsRemaining: TimeInterval?

    public init(receivedBytes: Int64, expectedBytes: Int64, elapsedSeconds: TimeInterval) {
        self.receivedBytes = max(0, receivedBytes)
        totalBytes = expectedBytes > 0 ? expectedBytes : nil
        if let totalBytes {
            fraction = min(1, Double(self.receivedBytes) / Double(totalBytes))
        } else {
            fraction = nil
        }
        if elapsedSeconds >= 2, self.receivedBytes > 0 {
            bytesPerSecond = Double(self.receivedBytes) / elapsedSeconds
        } else {
            bytesPerSecond = nil
        }
        if let totalBytes, let bytesPerSecond, self.receivedBytes < totalBytes {
            secondsRemaining = Double(totalBytes - self.receivedBytes) / bytesPerSecond
        } else {
            secondsRemaining = nil
        }
    }
}
