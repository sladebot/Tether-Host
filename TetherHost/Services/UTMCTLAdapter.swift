import Foundation
import Darwin

public enum UTMCommand: Equatable, Sendable {
    case list
    case status(VirtualMachineID)

    fileprivate var arguments: [String] {
        switch self {
        case .list: ["list"]
        case .status(let id): ["status", id.rawValue.uuidString]
        }
    }
}

public struct UTMCommandOutput: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String

    public init(standardOutput: String, standardError: String = "") {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol UTMCommandExecuting: Sendable {
    func execute(_ command: UTMCommand) async throws -> UTMCommandOutput
}

public enum UTMAdapterError: Error, Equatable, LocalizedError, Sendable {
    case executableUnavailable
    case timedOut
    case commandFailed(exitCode: Int32, sanitizedMessage: String)
    case malformedOutput(String)
    case vmNotFound(VirtualMachineID)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "utmctl is unavailable at an approved path."
        case .timedOut: "The read-only UTM query timed out."
        case .commandFailed(let code, let message): "utmctl failed (\(code)): \(message)"
        case .malformedOutput(let message): "Could not parse sanitized utmctl output: \(message)"
        case .vmNotFound(let id): "UTM did not return the exact VM ID \(id)."
        }
    }
}

public actor UTMCTLProcessExecutor: UTMCommandExecuting {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let redactor: SecretRedactor

    public init(
        timeout: TimeInterval = 8,
        redactor: SecretRedactor = SecretRedactor()
    ) throws {
        guard UTMInstallation.detect() == .installed else {
            throw UTMAdapterError.executableUnavailable
        }
        self.executableURL = UTMInstallation.applicationURL.appendingPathComponent("Contents/MacOS/utmctl")
        self.timeout = min(max(timeout, 0.25), 30)
        self.redactor = redactor
    }

    public func execute(_ command: UTMCommand) async throws -> UTMCommandOutput {
        let executableURL = self.executableURL
        let timeout = self.timeout
        let redactor = self.redactor
        return try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executableURL
            process.arguments = command.arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

            do {
                try process.run()
            } catch {
                throw UTMAdapterError.commandFailed(
                    exitCode: -1,
                    sanitizedMessage: redactor.redact(error.localizedDescription)
                )
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                process.terminate()
                let graceDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < graceDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                throw UTMAdapterError.timedOut
            }

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile().prefix(65_536)
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile().prefix(65_536)
            let output = redactor.redact(String(decoding: outputData, as: UTF8.self))
            let errorOutput = redactor.redact(String(decoding: errorData, as: UTF8.self))
            guard process.terminationStatus == 0 else {
                throw UTMAdapterError.commandFailed(
                    exitCode: process.terminationStatus,
                    sanitizedMessage: errorOutput.isEmpty ? "No diagnostic output." : errorOutput
                )
            }
            return UTMCommandOutput(standardOutput: output, standardError: errorOutput)
        }.value
    }
}

public struct UTMCTLAdapter: VirtualMachineReading, Sendable {
    private let executor: any UTMCommandExecuting

    public init(executor: any UTMCommandExecuting) {
        self.executor = executor
    }

    public func list() async throws -> [VirtualMachineRecord] {
        let output = try await executor.execute(.list).standardOutput
        return try Self.parseList(output)
    }

    public func status(of id: VirtualMachineID) async throws -> VirtualMachineState {
        let inventory = try await list()
        let exact = inventory.filter { $0.id == id }
        guard exact.count == 1 else {
            if exact.isEmpty { throw UTMAdapterError.vmNotFound(id) }
            throw UTMAdapterError.malformedOutput("Duplicate exact UUID records.")
        }
        let output = try await executor.execute(.status(id)).standardOutput
        return try Self.parseStatus(output)
    }

    public static func parseList(_ input: String) throws -> [VirtualMachineRecord] {
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let records = json.compactMap { item -> VirtualMachineRecord? in
                let uuidText = (item["uuid"] ?? item["UUID"] ?? item["id"]) as? String
                let name = (item["name"] ?? item["Name"]) as? String
                let status = (item["status"] ?? item["Status"]) as? String
                guard let uuidText, let id = VirtualMachineID(uuidText), let name else { return nil }
                return VirtualMachineRecord(id: id, name: name, state: parseState(status ?? "unknown"))
            }
            if records.count == json.count {
                guard Set(records.map(\.id)).count == records.count else {
                    throw UTMAdapterError.malformedOutput("Duplicate exact UUID records.")
                }
                return records
            }
        }

        let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        let regex = try NSRegularExpression(pattern: uuidPattern)
        var records: [VirtualMachineRecord] = []
        for line in input.split(whereSeparator: \.isNewline).map(String.init) {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange),
                  let uuidRange = Range(match.range, in: line),
                  let id = VirtualMachineID(String(line[uuidRange])) else { continue }

            var remainder = line.replacingCharacters(in: uuidRange, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var state: VirtualMachineState = .unknown
            for candidate in VirtualMachineState.allCases where candidate != .unknown {
                let token = candidate.rawValue
                if let range = remainder.range(of: token, options: [.caseInsensitive]) {
                    state = candidate
                    remainder.removeSubrange(range)
                    break
                }
            }
            let name = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " |\t"))
            guard !name.isEmpty else { continue }
            records.append(VirtualMachineRecord(id: id, name: name, state: state))
        }
        if records.isEmpty && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw UTMAdapterError.malformedOutput("No UUID records were found.")
        }
        guard Set(records.map(\.id)).count == records.count else {
            throw UTMAdapterError.malformedOutput("Duplicate exact UUID records.")
        }
        return records
    }

    public static func parseStatus(_ input: String) throws -> VirtualMachineState {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for state in VirtualMachineState.allCases where state != .unknown {
            if normalized == state.rawValue || normalized.contains("\"status\":\"\(state.rawValue)\"") {
                return state
            }
        }
        if normalized == "unknown" { return .unknown }
        throw UTMAdapterError.malformedOutput("Unknown VM state.")
    }

    private static func parseState(_ input: String) -> VirtualMachineState {
        VirtualMachineState(rawValue: input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }
}
