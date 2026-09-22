import AppKit
import Darwin
import Foundation

// Host-initiated, text-only clipboard transfer. This service never polls either clipboard.
// Wire format: opcode/status (1 byte), UTF-8 payload size (4-byte big-endian), payload.
private enum ClipboardWire {
    static let port: UInt32 = 45_251
    static let maxTextBytes = 65_536
    static let headerBytes = 5
    static let get: UInt8 = 1
    static let set: UInt8 = 2
    static let ok: UInt8 = 0
    static let invalidRequest: UInt8 = 1
    static let unavailable: UInt8 = 2

    static func length(from header: [UInt8]) -> Int? {
        guard header.count == headerBytes else { return nil }
        let length = header[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return length <= maxTextBytes ? Int(length) : nil
    }

    static func response(status: UInt8, text: String) -> [UInt8]? {
        let payload = Array(text.utf8)
        guard payload.count <= maxTextBytes else { return nil }
        let length = UInt32(payload.count)
        return [status, UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff)] + payload
    }
}

private func readExactly(_ descriptor: Int32, count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let result = bytes.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
        }
        if result == 0 { return nil }
        if result < 0 {
            if errno == EINTR { continue }
            return nil
        }
        offset += result
    }
    return bytes
}

private func writeExactly(_ descriptor: Int32, bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let result = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return }
            offset += result
        }
    }
}

private func reply(_ descriptor: Int32, status: UInt8, text: String) {
    if let bytes = ClipboardWire.response(status: status, text: text) {
        writeExactly(descriptor, bytes: bytes)
    }
}

private func handle(_ descriptor: Int32) {
    guard let header = readExactly(descriptor, count: ClipboardWire.headerBytes),
          let payloadSize = ClipboardWire.length(from: header) else {
        reply(descriptor, status: ClipboardWire.invalidRequest, text: "Invalid clipboard request size.")
        return
    }
    let opcode = header[0]
    guard opcode == ClipboardWire.get || opcode == ClipboardWire.set,
          opcode == ClipboardWire.set || payloadSize == 0 else {
        reply(descriptor, status: ClipboardWire.invalidRequest, text: "Unknown clipboard request.")
        return
    }
    guard let payload = readExactly(descriptor, count: payloadSize),
          let text = String(bytes: payload, encoding: .utf8) else {
        reply(descriptor, status: ClipboardWire.invalidRequest, text: "Clipboard text must be UTF-8.")
        return
    }
    if opcode == ClipboardWire.get {
        guard let guestText = NSPasteboard.general.string(forType: .string) else {
            reply(descriptor, status: ClipboardWire.unavailable, text: "Guest clipboard has no text.")
            return
        }
        guard guestText.utf8.count <= ClipboardWire.maxTextBytes else {
            reply(descriptor, status: ClipboardWire.unavailable, text: "Guest clipboard text exceeds 64 KiB.")
            return
        }
        reply(descriptor, status: ClipboardWire.ok, text: guestText)
    } else {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            reply(descriptor, status: ClipboardWire.unavailable, text: "Could not set guest clipboard text.")
            return
        }
        reply(descriptor, status: ClipboardWire.ok, text: "")
    }
}

private func isVirtualMac() -> Bool {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return false }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return false }
    return String(cString: bytes).hasPrefix("VirtualMac")
}

private func serve() throws {
    guard isVirtualMac(), geteuid() != 0 else {
        throw NSError(domain: "TetherGuestClipboard", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Run in a macOS VM desktop user session."])
    }
    let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(listener) }

    var address = sockaddr_vm(svm_len: UInt8(MemoryLayout<sockaddr_vm>.size),
                              svm_family: sa_family_t(AF_VSOCK), svm_reserved1: 0,
                              svm_port: ClipboardWire.port, svm_cid: VMADDR_CID_ANY)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
        }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    while true {
        var peer = sockaddr_vm()
        var peerLength = socklen_t(MemoryLayout<sockaddr_vm>.size)
        let connection = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener, $0, &peerLength)
            }
        }
        if connection < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(connection) }
        // The hypervisor is CID 2. Refuse connections initiated by guest processes.
        guard peerLength == MemoryLayout<sockaddr_vm>.size,
              peer.svm_family == sa_family_t(AF_VSOCK), peer.svm_cid == VMADDR_CID_HOST else {
            continue
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        handle(connection)
    }
}

@main
private struct TetherGuestClipboardHelper {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--self-test") {
            precondition(ClipboardWire.length(from: [ClipboardWire.set, 0, 1, 0, 0]) == 65_536)
            precondition(ClipboardWire.length(from: [ClipboardWire.set, 0, 1, 0, 1]) == nil)
            precondition(ClipboardWire.response(status: 0, text: "héllo") == [0, 0, 0, 0, 6] + Array("héllo".utf8))
            precondition(ClipboardWire.response(status: 0, text: String(repeating: "a", count: 65_537)) == nil)
            print("Clipboard framing tests passed.")
            return
        }
        do {
            try serve()
        } catch {
            fputs("Tether Guest Clipboard Helper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
