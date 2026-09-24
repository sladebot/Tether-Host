import Foundation
import XCTest
@testable import TetherHostCore

final class UbuntuInstallationVerifierTests: XCTestCase {
    func testCompleteBootableDefaultInstallation() throws {
        let image = try Fixture()
        defer { image.remove() }
        XCTAssertTrue(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
    }

    func testInterruptedInstallationDoesNotQualify() throws {
        let image = try Fixture()
        defer { image.remove() }
        image.writeExt4File(block: 106, text: "# unfinished install\n") // no root fstab
        XCTAssertFalse(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
    }

    func testUncleanOrOutOfBoundsImageDoesNotQualify() throws {
        let image = try Fixture()
        defer { image.remove() }
        image.writeExt4(offset: 1024 + 58, bytes: [0, 0])
        XCTAssertFalse(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
        image.writeExt4(offset: 1024 + 58, bytes: [1, 0])
        image.writeAbsolute(offset: 512 + 72, bytes: Array(repeating: 0xff, count: 8))
        XCTAssertFalse(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
    }

    func testCorruptDirectoryAndMissingBootloaderDoNotQualify() throws {
        let image = try Fixture()
        defer { image.remove() }
        image.writeExt4(offset: 10 * 4096 + 256 + 4, bytes: [6, 0, 0, 0]) // root directory too short
        XCTAssertFalse(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
        image.writeExt4(offset: 10 * 4096 + 256 + 4, bytes: [0, 16, 0, 0])
        image.writeFAT(offset: image.fatDataSector * 512 + 2 * 512 + 26, bytes: [0xff, 0xff])
        XCTAssertFalse(try UbuntuInstallationVerifier.isComplete(diskURL: image.url))
    }
}

private final class Fixture {
    let url: URL
    private let file: FileHandle
    private let espStart: UInt64 = 2_048 * 512
    private let ext4Start: UInt64 = 75_776 * 512
    let fatDataSector: UInt64 = 32 + 600
    private let uuid = "00112233-4455-6677-8899-aabbccddeeff"

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-verifier-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forUpdating: url)
        try file.truncate(atOffset: 83_968 * 512)
        makeGPT()
        makeFAT()
        makeExt4()
    }

    deinit { try? file.close() }
    func remove() { try? file.close(); try? FileManager.default.removeItem(at: url) }

    func writeAbsolute(offset: UInt64, bytes: [UInt8]) {
        try! file.seek(toOffset: offset)
        try! file.write(contentsOf: Data(bytes))
    }
    func writeExt4(offset: UInt64, bytes: [UInt8]) { writeAbsolute(offset: ext4Start + offset, bytes: bytes) }
    func writeFAT(offset: UInt64, bytes: [UInt8]) { writeAbsolute(offset: espStart + offset, bytes: bytes) }
    func writeExt4File(block: UInt64, text: String) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes.replaceSubrange(0..<text.utf8.count, with: text.utf8)
        writeExt4(offset: block * 4096, bytes: bytes)
    }
    private func put16(_ data: inout [UInt8], _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    private func put32(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }
    private func put64(_ data: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for n in 0..<8 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }

    private func makeGPT() {
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: "EFI PART".utf8)
        put32(&header, 12, 92); put64(&header, 24, 1)
        put64(&header, 72, 2); put32(&header, 80, 128); put32(&header, 84, 128)
        writeAbsolute(offset: 512, bytes: header)
        var entries = [UInt8](repeating: 0, count: 256)
        entries.replaceSubrange(0..<16, with: [0x28,0x73,0x2a,0xc1,0x1f,0xf8,0xd2,0x11,0xba,0x4b,0x00,0xa0,0xc9,0x3e,0xc9,0x3b])
        put64(&entries, 32, 2_048); put64(&entries, 40, 75_775)
        entries.replaceSubrange(128..<144, with: [0xaf,0x3d,0xc6,0x0f,0x83,0x84,0x72,0x47,0x8e,0x79,0x3d,0x69,0xd8,0x47,0x7d,0xe4])
        put64(&entries, 160, 75_776); put64(&entries, 168, 83_967)
        writeAbsolute(offset: 1024, bytes: entries)
    }

    private func makeFAT() {
        var boot = [UInt8](repeating: 0, count: 512)
        put16(&boot, 11, 512); boot[13] = 1; put16(&boot, 14, 32)
        boot[16] = 1; put32(&boot, 32, 73_728); put32(&boot, 36, 600)
        put32(&boot, 44, 2); boot.replaceSubrange(82..<90, with: "FAT32   ".utf8)
        boot[510] = 0x55; boot[511] = 0xaa
        writeAbsolute(offset: espStart, bytes: boot)
        var fat = [UInt8](repeating: 0, count: 512)
        for cluster in 2...5 { put32(&fat, cluster * 4, 0x0fff_ffff) }
        writeAbsolute(offset: espStart + 32 * 512, bytes: fat)
        writeFATDirectory(cluster: 2, entry: "EFI", child: 3, directory: true)
        writeFATDirectory(cluster: 3, entry: "UBUNTU", child: 4, directory: true)
        writeFATDirectory(cluster: 4, entry: "SHIMAA64.EFI", child: 5, directory: false)
        var shim = [UInt8](repeating: 0, count: 512)
        shim[0] = 0x4d; shim[1] = 0x5a; put32(&shim, 0x3c, 0x80)
        shim.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])
        writeFAT(offset: (fatDataSector + 3) * 512, bytes: shim)
    }

    private func writeFATDirectory(cluster: UInt64, entry: String, child: UInt16, directory: Bool) {
        var bytes = [UInt8](repeating: 0, count: 512)
        let pieces = entry.split(separator: ".")
        let base = String(pieces[0]).padding(toLength: 8, withPad: " ", startingAt: 0)
        let ext = (pieces.count > 1 ? String(pieces[1]) : "").padding(toLength: 3, withPad: " ", startingAt: 0)
        bytes.replaceSubrange(0..<11, with: (base + ext).utf8)
        bytes[11] = directory ? 0x10 : 0x20
        put16(&bytes, 26, child); put32(&bytes, 28, directory ? 0 : 512)
        writeAbsolute(offset: espStart + (fatDataSector + cluster - 2) * 512, bytes: bytes)
    }

    private func makeExt4() {
        var superblock = [UInt8](repeating: 0, count: 1024)
        put32(&superblock, 0, 1000); put32(&superblock, 4, 1024)
        put32(&superblock, 24, 2); put32(&superblock, 32, 1024); put32(&superblock, 40, 1000)
        put16(&superblock, 56, 0xef53); put16(&superblock, 58, 1)
        put16(&superblock, 88, 256); put32(&superblock, 96, 0x40); put16(&superblock, 254, 64)
        superblock.replaceSubrange(104..<120, with: [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                                                      0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff])
        writeExt4(offset: 1024, bytes: superblock)
        var descriptor = [UInt8](repeating: 0, count: 64)
        put32(&descriptor, 8, 10)
        writeExt4(offset: 4096, bytes: descriptor)

        directory(inode: 2, block: 100, entries: [("usr",12),("etc",15),("boot",18)])
        directory(inode: 12, block: 101, entries: [("lib",13)])
        directory(inode: 13, block: 102, entries: [("os-release",14)])
        directory(inode: 15, block: 103, entries: [("fstab",16),("passwd",17)])
        directory(inode: 18, block: 104, entries: [("grub",19),("vmlinuz-6.8",21),("initrd.img-6.8",22)])
        directory(inode: 19, block: 109, entries: [("grub.cfg",20)])
        regular(inode: 14, block: 105, text: "ID=ubuntu\n")
        regular(inode: 16, block: 106, text: "UUID=\(uuid) / ext4 defaults 0 1\n")
        regular(inode: 17, block: 107, text: "alice:x:1000:1000::/home/alice:/bin/bash\n")
        regular(inode: 20, block: 108, text: "menuentry ubuntu {}\n")
        regular(inode: 21, block: 110, text: "kernel\n")
        regular(inode: 22, block: 111, text: "initrd\n")
    }

    private func directory(inode: Int, block: UInt32, entries: [(String, UInt32)]) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        var offset = 0
        for (index, (name, number)) in entries.enumerated() {
            let size = index == entries.count - 1 ? 4096 - offset : (8 + name.utf8.count + 3) & ~3
            put32(&bytes, offset, number); put16(&bytes, offset + 4, UInt16(size))
            bytes[offset + 6] = UInt8(name.utf8.count)
            bytes.replaceSubrange((offset + 8)..<(offset + 8 + name.utf8.count), with: name.utf8)
            offset += size
        }
        writeExt4(offset: UInt64(block) * 4096, bytes: bytes)
        writeInode(inode, mode: 0x41ed, block: block, size: 4096)
    }

    private func regular(inode: Int, block: UInt32, text: String) {
        writeExt4File(block: UInt64(block), text: text)
        writeInode(inode, mode: 0x81a4, block: block, size: UInt32(text.utf8.count))
    }

    private func writeInode(_ number: Int, mode: UInt16, block: UInt32, size: UInt32) {
        var bytes = [UInt8](repeating: 0, count: 256)
        put16(&bytes, 0, mode); put32(&bytes, 4, size); put32(&bytes, 32, 0x80000)
        put16(&bytes, 40, 0xf30a); put16(&bytes, 42, 1); put16(&bytes, 44, 4)
        put32(&bytes, 52, 0); put16(&bytes, 56, 1); put32(&bytes, 60, block)
        writeExt4(offset: 10 * 4096 + UInt64(number - 1) * 256, bytes: bytes)
    }
}
