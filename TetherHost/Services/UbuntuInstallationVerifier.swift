import Foundation

/// Reads a stopped raw VM disk without mounting it. This recognizes only the
/// ordinary unencrypted GPT + ext4 Ubuntu Desktop layout; uncertainty is false.
public enum UbuntuInstallationVerifier {
    public static func isComplete(diskURL: URL) throws -> Bool {
        let disk = try ReadOnlyDisk(url: diskURL)
        guard let partitions = try? GPT.partitions(on: disk),
              let esp = partitions.first(where: { $0.type == .efiSystem }),
              (try? FAT32(disk: disk, partition: esp).hasUbuntuBootloader()) == true,
              let root = partitions.first(where: { $0.type == .linuxFilesystem }),
              let fs = try? Ext4(disk: disk, partition: root),
              let release = try? fs.file(at: "/usr/lib/os-release", limit: 8_192),
              let releaseText = String(data: release, encoding: .utf8),
              releaseText.split(separator: "\n").contains("ID=ubuntu"),
              let fstab = try? fs.file(at: "/etc/fstab", limit: 65_536),
              let fstabText = String(data: fstab, encoding: .utf8),
              fstabText.split(separator: "\n").contains(where: { line in
                  let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                  return fields.count >= 3 && fields[0].lowercased() == "uuid=\(fs.uuid)" && fields[1] == "/" && fields[2] == "ext4"
              }),
              (try? fs.hasBootFiles()) == true,
              let users = try? fs.file(at: "/etc/passwd", limit: 1_048_576),
              let userText = String(data: users, encoding: .utf8),
              userText.split(separator: "\n").contains(where: { line in
                  let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                  guard fields.count >= 7, let uid = Int(fields[2]), uid >= 1000 && uid < 60_000 else { return false }
                  return fields[5].hasPrefix("/home/") && (fields[6].hasSuffix("/bash") || fields[6].hasSuffix("/zsh"))
              }) else { return false }
        return true
    }
}

private struct Partition {
    enum Kind: Equatable { case efiSystem, linuxFilesystem }
    let type: Kind
    let start: UInt64
    let length: UInt64
}

private final class ReadOnlyDisk {
    private let handle: FileHandle
    let length: UInt64
    private var readCount = 0
    private var bytesRead: UInt64 = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int, within bounds: Range<UInt64>? = nil) throws -> Data {
        guard count >= 0 && count <= 16 * 1024 * 1024,
              let end = checkedAdd(offset, UInt64(count)),
              end <= length,
              bounds.map({ offset >= $0.lowerBound && end <= $0.upperBound }) ?? true,
              readCount < 4_096,
              let newBytesRead = checkedAdd(bytesRead, UInt64(count)),
              newBytesRead <= 128 * 1024 * 1024 else {
            throw VerificationError.invalidImage
        }
        readCount += 1
        bytesRead = newBytesRead
        try handle.seek(toOffset: offset)
        guard let result = try handle.read(upToCount: count), result.count == count else {
            throw VerificationError.invalidImage
        }
        return result
    }
}

private enum VerificationError: Error { case invalidImage }

private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : value
}

private extension Data {
    func u16(_ at: Int) throws -> UInt16 {
        guard at >= 0 && at + 2 <= count else { throw VerificationError.invalidImage }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }
    func u32(_ at: Int) throws -> UInt32 {
        UInt32(try u16(at)) | UInt32(try u16(at + 2)) << 16
    }
    func u64(_ at: Int) throws -> UInt64 {
        UInt64(try u32(at)) | UInt64(try u32(at + 4)) << 32
    }
}

private enum GPT {
    static func partitions(on disk: ReadOnlyDisk) throws -> [Partition] {
        let header = try disk.read(512, 92)
        guard header.prefix(8) == Data("EFI PART".utf8),
              try header.u32(12) >= 92,
              try header.u64(24) == 1,
              try header.u32(84) >= 128 else { throw VerificationError.invalidImage }
        let entryLBA = try header.u64(72)
        let count = Int(try header.u32(80))
        let stride = Int(try header.u32(84))
        guard count > 0 && count <= 128 && stride <= 512,
              entryLBA <= UInt64.max / 512 else { throw VerificationError.invalidImage }
        let table = try disk.read(entryLBA * 512, count * stride)
        var result: [Partition] = []
        for index in 0..<count {
            let entry = Data(table[index * stride..<(index + 1) * stride])
            let guid = entry.prefix(16).map { String(format: "%02x", $0) }.joined()
            let kind: Partition.Kind
            switch guid {
            case "28732ac11ff8d211ba4b00a0c93ec93b": kind = .efiSystem
            case "af3dc60f838472478e793d69d8477de4": kind = .linuxFilesystem
            default: continue
            }
            let first = try entry.u64(32), last = try entry.u64(40)
            guard first <= last, last < disk.length / 512 else { throw VerificationError.invalidImage }
            result.append(Partition(type: kind, start: first * 512, length: (last - first + 1) * 512))
        }
        return result
    }
}

private struct Ext4 {
    let disk: ReadOnlyDisk
    let partition: Partition
    let blockSize: UInt64
    let inodesPerGroup: UInt32
    let inodeSize: Int
    let descriptorSize: Int
    let inodeCount: UInt32
    let blockCount: UInt64
    let uuid: String

    init(disk: ReadOnlyDisk, partition: Partition) throws {
        self.disk = disk
        self.partition = partition
        let superblock = try disk.read(partition.start + 1024, 1024, within: partition.range)
        guard try superblock.u16(56) == 0xef53,
              try superblock.u16(58) & 1 == 1, // cleanly unmounted
              try superblock.u32(24) <= 4,
              try superblock.u32(40) > 0,
              try superblock.u16(88) >= 128,
              try superblock.u32(96) & 0x40 != 0, // extents
              try superblock.u32(96) & 0x10000 == 0, // encryption
              try superblock.u32(96) & 0x8000 == 0 else { // inline data
            throw VerificationError.invalidImage
        }
        blockSize = 1024 << (try superblock.u32(24))
        inodesPerGroup = try superblock.u32(40)
        inodeSize = Int(try superblock.u16(88))
        descriptorSize = max(32, Int(try superblock.u16(254)))
        inodeCount = try superblock.u32(0)
        blockCount = UInt64(try superblock.u32(4)) | UInt64(try superblock.u32(336)) << 32
        let uuidBytes = Array(superblock[104..<120])
        let hex = uuidBytes.map { String(format: "%02x", $0) }.joined()
        uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard inodeSize <= 1024 && descriptorSize <= 512,
              blockCount > 0 && blockCount <= partition.length / blockSize else {
            throw VerificationError.invalidImage
        }
    }

    func file(at path: String, limit: Int) throws -> Data {
        let inode = try resolve(path)
        guard inode.mode & 0xf000 == 0x8000 else { throw VerificationError.invalidImage }
        return try contents(of: inode, limit: limit)
    }

    func names(at path: String) throws -> [String] {
        try directory(resolve(path)).map(\.name)
    }

    func hasBootFiles() throws -> Bool {
        guard try isRegularNonempty("/boot/grub/grub.cfg") else { return false }
        let bootNames = try names(at: "/boot")
        for name in bootNames where name.hasPrefix("vmlinuz-") {
            let version = name.dropFirst("vmlinuz-".count)
            guard !version.isEmpty else { continue }
            if try isRegularNonempty("/boot/\(name)") &&
                isRegularNonempty("/boot/initrd.img-\(version)") {
                return true
            }
        }
        return false
    }

    private func isRegularNonempty(_ path: String) throws -> Bool {
        guard let inode = try? resolve(path) else { return false }
        let flags = try inode.bytes.u32(32)
        guard inode.mode & 0xf000 == 0x8000 && inode.size > 0 && inode.size <= 512 * 1024 * 1024 &&
                flags & 0x80000 != 0 else { return false }
        let mapped = try extents(Data(inode.bytes[40..<100]), depthLimit: 5)
        guard let first = mapped.first, first.logical == 0 else { return false }
        return first.physical > 0 && first.physical + UInt64(first.length) <= blockCount
    }

    private func resolve(_ path: String) throws -> Inode {
        guard path.hasPrefix("/"), path.split(separator: "/").count <= 12 else { throw VerificationError.invalidImage }
        var inode = try readInode(2)
        for component in path.split(separator: "/") {
            guard let found = try directory(inode).first(where: { $0.name == component }) else {
                throw VerificationError.invalidImage
            }
            inode = try readInode(found.number)
        }
        return inode
    }

    private func directory(_ inode: Inode) throws -> [(name: String, number: UInt32)] {
        guard inode.mode & 0xf000 == 0x4000 else { throw VerificationError.invalidImage }
        let bytes = try contents(of: inode, limit: 16 * 1024 * 1024)
        var offset = 0
        var result: [(name: String, number: UInt32)] = []
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw VerificationError.invalidImage }
            let number = try bytes.u32(offset)
            let recordLength = Int(try bytes.u16(offset + 4))
            let nameLength = Int(bytes[offset + 6])
            guard recordLength >= 8 && recordLength % 4 == 0,
                  offset + recordLength <= bytes.count,
                  nameLength <= recordLength - 8 else { throw VerificationError.invalidImage }
            if number != 0 {
                guard let name = String(data: bytes[(offset + 8)..<(offset + 8 + nameLength)], encoding: .utf8) else {
                    throw VerificationError.invalidImage
                }
                result.append((name, number))
            }
            offset += recordLength
        }
        return result
    }

    private struct Inode {
        let bytes: Data
        var mode: UInt16 { (try? bytes.u16(0)) ?? 0 }
        var size: UInt64 { UInt64((try? bytes.u32(4)) ?? 0) | UInt64((try? bytes.u32(108)) ?? 0) << 32 }
    }

    private func readInode(_ number: UInt32) throws -> Inode {
        guard number > 0 && number <= inodeCount else { throw VerificationError.invalidImage }
        let group = UInt64((number - 1) / inodesPerGroup)
        let index = UInt64((number - 1) % inodesPerGroup)
        let descriptorBlock: UInt64 = blockSize == 1024 ? 2 : 1
        let descriptor = try read(partitionOffset: descriptorBlock * blockSize + group * UInt64(descriptorSize), count: descriptorSize)
        let table = UInt64(try descriptor.u32(8)) | (descriptorSize >= 64 ? UInt64(try descriptor.u32(40)) << 32 : 0)
        guard table > 0 && table < blockCount else { throw VerificationError.invalidImage }
        let bytes = try read(partitionOffset: table * blockSize + index * UInt64(inodeSize), count: inodeSize)
        return Inode(bytes: bytes)
    }

    private func contents(of inode: Inode, limit: Int) throws -> Data {
        guard inode.size <= UInt64(limit), inode.size <= UInt64(Int.max),
              try inode.bytes.u32(32) & 0x80000 != 0 else { throw VerificationError.invalidImage }
        var output = Data(repeating: 0, count: Int(inode.size))
        for extent in try extents(Data(inode.bytes[40..<100]), depthLimit: 5) {
            let logical = UInt64(extent.logical) * blockSize
            let count = UInt64(extent.length) * blockSize
            guard logical < inode.size,
                  logical + count <= inode.size + blockSize - 1,
                  extent.physical > 0,
                  extent.physical + UInt64(extent.length) <= blockCount else { throw VerificationError.invalidImage }
            let actual = Int(min(count, inode.size - logical))
            let chunk = try read(partitionOffset: extent.physical * blockSize, count: actual)
            output.replaceSubrange(Int(logical)..<(Int(logical) + actual), with: chunk)
        }
        return output
    }

    private struct Extent { let logical: UInt32; let length: UInt16; let physical: UInt64 }

    private func extents(_ bytes: Data, depthLimit: Int) throws -> [Extent] {
        guard depthLimit > 0, try bytes.u16(0) == 0xf30a else { throw VerificationError.invalidImage }
        let entries = Int(try bytes.u16(2)), maximum = Int(try bytes.u16(4)), depth = Int(try bytes.u16(6))
        guard entries <= maximum, 12 + entries * 12 <= bytes.count, depth <= depthLimit else {
            throw VerificationError.invalidImage
        }
        var result: [Extent] = []
        for index in 0..<entries {
            let at = 12 + index * 12
            if depth == 0 {
                let length = try bytes.u16(at + 4)
                guard length > 0 && length <= 32_768 else { throw VerificationError.invalidImage }
                result.append(Extent(logical: try bytes.u32(at), length: length,
                                     physical: UInt64(try bytes.u32(at + 8)) | UInt64(try bytes.u16(at + 6)) << 32))
            } else {
                let block = UInt64(try bytes.u32(at + 4)) | UInt64(try bytes.u16(at + 8)) << 32
                guard block > 0 && block < blockCount else { throw VerificationError.invalidImage }
                let child = try extents(read(partitionOffset: block * blockSize, count: Int(blockSize)), depthLimit: depthLimit - 1)
                guard result.count + child.count <= 8_192 else { throw VerificationError.invalidImage }
                result += child
            }
        }
        return result
    }

    private func read(partitionOffset: UInt64, count: Int) throws -> Data {
        guard let absolute = checkedAdd(partition.start, partitionOffset) else {
            throw VerificationError.invalidImage
        }
        return try disk.read(absolute, count, within: partition.range)
    }
}

private extension Partition {
    var range: Range<UInt64> { start..<(start + length) }
}

private struct FAT32 {
    let disk: ReadOnlyDisk
    let partition: Partition
    let bytesPerSector: UInt64
    let sectorsPerCluster: UInt64
    let fatOffset: UInt64
    let dataOffset: UInt64
    let rootCluster: UInt32
    let maxCluster: UInt32

    init(disk: ReadOnlyDisk, partition: Partition) throws {
        self.disk = disk
        self.partition = partition
        let boot = try disk.read(partition.start, 512, within: partition.range)
        let sectorSize = UInt64(try boot.u16(11))
        let clusterSectors = UInt64(boot[13])
        let reserved = UInt64(try boot.u16(14))
        let fatCount = UInt64(boot[16])
        let fatSectors = UInt64(try boot.u32(36))
        let totalSectors = UInt64(try boot.u32(32))
        let firstDataSector = reserved + fatCount * fatSectors
        guard boot[510] == 0x55 && boot[511] == 0xaa,
              sectorSize == 512 || sectorSize == 4096,
              clusterSectors > 0 && clusterSectors <= 128 && clusterSectors.nonzeroBitCount == 1,
              fatCount > 0 && fatCount <= 2,
              fatSectors > 0 && firstDataSector < totalSectors,
              totalSectors <= partition.length / sectorSize,
              boot[82..<90] == Data("FAT32   ".utf8) else { throw VerificationError.invalidImage }
        bytesPerSector = sectorSize
        sectorsPerCluster = clusterSectors
        fatOffset = reserved * sectorSize
        dataOffset = firstDataSector * sectorSize
        rootCluster = try boot.u32(44)
        let count = (totalSectors - firstDataSector) / clusterSectors
        guard count >= 65525 && count <= UInt64(UInt32.max - 2),
              rootCluster >= 2 && UInt64(rootCluster) < count + 2 else { throw VerificationError.invalidImage }
        maxCluster = UInt32(count + 1)
    }

    func hasUbuntuBootloader() throws -> Bool {
        guard let efi = try find("EFI", in: rootCluster), efi.isDirectory,
              let ubuntu = try find("UBUNTU", in: efi.cluster), ubuntu.isDirectory else { return false }
        return try ["SHIMAA64.EFI", "GRUBAA64.EFI"].contains { name in
            guard let entry = try find(name, in: ubuntu.cluster), !entry.isDirectory,
                  entry.size >= 128, entry.cluster >= 2, entry.cluster <= maxCluster else { return false }
            let offset = dataOffset + UInt64(entry.cluster - 2) * sectorsPerCluster * bytesPerSector
            let header = try disk.read(partition.start + offset, Int(min(UInt64(entry.size), sectorsPerCluster * bytesPerSector)),
                                       within: partition.range)
            guard header.count >= 128 && header[0] == 0x4d && header[1] == 0x5a else { return false }
            let peOffset = Int(try header.u32(0x3c))
            return peOffset >= 64 && peOffset + 4 <= header.count &&
                header[peOffset..<(peOffset + 4)] == Data([0x50, 0x45, 0, 0])
        }
    }

    private struct Entry {
        let cluster: UInt32
        let size: UInt32
        let isDirectory: Bool
    }

    private func find(_ wanted: String, in firstCluster: UInt32) throws -> Entry? {
        var cluster = firstCluster
        var seen = Set<UInt32>()
        for _ in 0..<64 {
            guard cluster >= 2 && cluster <= maxCluster && seen.insert(cluster).inserted else {
                throw VerificationError.invalidImage
            }
            let offset = dataOffset + UInt64(cluster - 2) * sectorsPerCluster * bytesPerSector
            let bytes = try disk.read(partition.start + offset, Int(sectorsPerCluster * bytesPerSector), within: partition.range)
            for index in stride(from: 0, to: bytes.count, by: 32) {
                let first = bytes[index]
                if first == 0 { return nil }
                if first == 0xe5 || bytes[index + 11] == 0x0f { continue }
                let base = String(data: bytes[index..<(index + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
                let ext = String(data: bytes[(index + 8)..<(index + 11)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
                guard let base, let ext else { throw VerificationError.invalidImage }
                let name = ext.isEmpty ? base : base + "." + ext
                if name.uppercased() == wanted {
                    let high = UInt32(try bytes.u16(index + 20))
                    let low = UInt32(try bytes.u16(index + 26))
                    return Entry(cluster: high << 16 | low, size: try bytes.u32(index + 28),
                                 isDirectory: bytes[index + 11] & 0x10 != 0)
                }
            }
            let fatEntry = try disk.read(partition.start + fatOffset + UInt64(cluster) * 4, 4, within: partition.range)
            cluster = try fatEntry.u32(0) & 0x0fff_ffff
            if cluster >= 0x0fff_fff8 { return nil }
        }
        throw VerificationError.invalidImage
    }
}
