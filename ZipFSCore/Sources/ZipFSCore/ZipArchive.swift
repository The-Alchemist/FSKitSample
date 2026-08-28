import Foundation

public struct ZipEntry: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    public let compressionMethod: UInt16
    public let compressedSize: UInt32
    public let uncompressedSize: UInt32
    public let localHeaderOffset: UInt32
    public let crc32: UInt32
    public let dosTime: UInt16
    public let dosDate: UInt16
    public let posixMode: UInt16?
    public let isEncrypted: Bool

    public var modified: Date {
        Self.date(dosDate: dosDate, dosTime: dosTime)
    }

    static func date(dosDate: UInt16, dosTime: UInt16) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 1980 + Int(dosDate >> 9)
        components.month = Int((dosDate >> 5) & 0x0F)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int(dosTime >> 11)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}

public final class ZipArchive: @unchecked Sendable {
    public let source: ZipSource
    public let entries: [ZipEntry]
    public let totalUncompressedSize: UInt64

    public convenience init(data: Data) throws {
        try self.init(source: DataZipSource(data))
    }

    public convenience init(url: URL) throws {
        try self.init(source: FileZipSource(url: url))
    }

    public init(source: ZipSource) throws {
        self.source = source
        let parsed = try Self.parseCentralDirectory(source: source)
        self.entries = parsed
        self.totalUncompressedSize = parsed.reduce(0) { $0 + UInt64($1.uncompressedSize) }
    }

    public subscript(path: String) -> ZipEntry? {
        let normalized = Self.normalizePath(path)
        return entries.first { Self.normalizePath($0.path) == normalized }
    }

    public func extract(_ entry: ZipEntry) throws -> Data {
        if entry.isDirectory {
            throw ZipError.isDirectory
        }
        if entry.isEncrypted {
            throw ZipError.encryptedUnsupported
        }
        switch entry.compressionMethod {
        case 0, 8:
            break
        default:
            throw ZipError.compressionUnsupported(entry.compressionMethod)
        }

        let payload = try readCompressedPayload(entry)
        let uncompressed: Data
        if entry.compressionMethod == 0 {
            uncompressed = payload
        } else {
            uncompressed = try ZipZlib.inflateRaw(payload, uncompressedSize: Int(entry.uncompressedSize))
        }

        if uncompressed.count != Int(entry.uncompressedSize) {
            throw ZipError.truncated
        }
        if ZipZlib.crc32(uncompressed) != entry.crc32 {
            throw ZipError.crcMismatch
        }
        return uncompressed
    }

    public func extract(_ entry: ZipEntry, offset: UInt64, length: Int) throws -> Data {
        if offset > UInt64(entry.uncompressedSize) {
            throw ZipError.invalidOffset
        }
        if length < 0 {
            throw ZipError.invalidOffset
        }
        let remaining = Int(UInt64(entry.uncompressedSize) - offset)
        let count = min(length, remaining)
        if count == 0 {
            return Data()
        }

        if entry.compressionMethod == 0, !entry.isEncrypted {
            return try readStoredRange(entry, offset: Int(offset), length: count)
        }

        let full = try extract(entry)
        let start = Int(offset)
        return full.subdata(in: start..<(start + count))
    }

    private func readCompressedPayload(_ entry: ZipEntry) throws -> Data {
        let dataOffset = try localDataOffset(for: entry)
        return try source.read(offset: dataOffset, length: Int(entry.compressedSize))
    }

    private func readStoredRange(_ entry: ZipEntry, offset: Int, length: Int) throws -> Data {
        let dataOffset = try localDataOffset(for: entry)
        return try source.read(offset: dataOffset + UInt64(offset), length: length)
    }

    private func localDataOffset(for entry: ZipEntry) throws -> UInt64 {
        let header = try source.read(offset: UInt64(entry.localHeaderOffset), length: 30)
        guard header.count == 30 else {
            throw ZipError.truncated
        }
        guard header.starts(with: ZipMagic.localFileHeader) else {
            throw ZipError.truncated
        }
        let nameLen = header.u16(26)
        let extraLen = header.u16(28)
        return UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLen) + UInt64(extraLen)
    }

    private static func parseCentralDirectory(source: ZipSource) throws -> [ZipEntry] {
        let size = source.size
        guard size >= 22 else {
            throw ZipError.notZip
        }

        let eocdOffset = try findEOCD(source: source)
        if eocdOffset >= 20 {
            let locator = try source.read(offset: eocdOffset - 20, length: 20)
            if locator.starts(with: ZipMagic.zip64EndOfCentralDirectoryLocator) {
                throw ZipError.zip64Unsupported
            }
        }

        let eocd = try source.read(offset: eocdOffset, length: 22)
        guard eocd.count == 22, eocd.starts(with: ZipMagic.endOfCentralDirectory) else {
            throw ZipError.notZip
        }

        let diskNumber = eocd.u16(4)
        let cdDisk = eocd.u16(6)
        let entriesOnDisk = eocd.u16(8)
        let totalEntries = eocd.u16(10)
        let cdSize = eocd.u32(12)
        let cdOffset = eocd.u32(16)
        let commentLength = eocd.u16(20)

        if diskNumber != 0 || cdDisk != 0 {
            throw ZipError.zip64Unsupported
        }
        if cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF || totalEntries == 0xFFFF {
            throw ZipError.zip64Unsupported
        }
        if eocdOffset + 22 + UInt64(commentLength) > size {
            throw ZipError.truncated
        }
        if entriesOnDisk != totalEntries {
            throw ZipError.zip64Unsupported
        }

        if totalEntries == 0 {
            return []
        }

        let cdData = try source.read(offset: UInt64(cdOffset), length: Int(cdSize))
        guard cdData.count == Int(cdSize) else {
            throw ZipError.truncated
        }

        var entries: [ZipEntry] = []
        var cursor = 0
        for _ in 0..<totalEntries {
            let entry = try parseCentralDirectoryEntry(cdData, cursor: &cursor)
            entries.append(entry)
        }
        return entries
    }

    private static func parseCentralDirectoryEntry(_ data: Data, cursor: inout Int) throws -> ZipEntry {
        guard cursor + 46 <= data.count else {
            throw ZipError.truncated
        }
        let slice = data.subdata(in: cursor..<(cursor + 46))
        guard slice.starts(with: ZipMagic.centralDirectoryHeader) else {
            throw ZipError.truncated
        }

        let versionMadeBy = slice.u16(4)
        let flags = slice.u16(8)
        let method = slice.u16(10)
        let dosTime = slice.u16(12)
        let dosDate = slice.u16(14)
        let crc = slice.u32(16)
        let compressedSize = slice.u32(20)
        let uncompressedSize = slice.u32(24)
        let nameLen = Int(slice.u16(28))
        let extraLen = Int(slice.u16(30))
        let commentLen = Int(slice.u16(32))
        let diskStart = slice.u16(34)
        let externalAttrs = slice.u32(38)
        let localHeaderOffset = slice.u32(42)

        cursor += 46
        guard cursor + nameLen + extraLen + commentLen <= data.count else {
            throw ZipError.truncated
        }

        let nameData = data.subdata(in: cursor..<(cursor + nameLen))
        cursor += nameLen
        let extraData = data.subdata(in: cursor..<(cursor + extraLen))
        cursor += extraLen + commentLen

        if diskStart != 0 {
            throw ZipError.zip64Unsupported
        }
        if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
            throw ZipError.zip64Unsupported
        }
        if extraData.containsZip64ExtraField {
            throw ZipError.zip64Unsupported
        }

        let utf8 = (flags & 0x0800) != 0
        let path = decodePath(nameData, utf8: utf8)
        let encrypted = (flags & 0x0001) != 0

        let unix = (versionMadeBy >> 8) == 3
        let posixMode: UInt16? = unix ? UInt16((externalAttrs >> 16) & 0xFFFF) : nil
        let dosDirectory = (externalAttrs & 0x10) != 0
        let unixDirectory = posixMode.map { ($0 & 0xF000) == 0x4000 } ?? false
        let isDirectory = path.hasSuffix("/") || dosDirectory || unixDirectory

        return ZipEntry(
            path: path,
            isDirectory: isDirectory,
            compressionMethod: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            crc32: crc,
            dosTime: dosTime,
            dosDate: dosDate,
            posixMode: posixMode,
            isEncrypted: encrypted
        )
    }

    private static func findEOCD(source: ZipSource) throws -> UInt64 {
        let size = source.size
        let maxComment = 65535
        let eocdMin = 22
        let searchLen = Int(min(size, UInt64(eocdMin + maxComment)))
        let start = size - UInt64(searchLen)
        let window = try source.read(offset: start, length: searchLen)
        guard window.count == searchLen else {
            throw ZipError.truncated
        }

        var index = window.count - eocdMin
        while index >= 0 {
            if window[index] == 0x50,
               index + 3 < window.count,
               window[index + 1] == 0x4B,
               window[index + 2] == 0x05,
               window[index + 3] == 0x06 {
                let commentLength = window.u16(index + 20)
                let cdSize = window.u32(index + 12)
                let cdOffset = window.u32(index + 16)
                let eocdAbsolute = start + UInt64(index)
                if index + 22 + Int(commentLength) > window.count {
                    index -= 1
                    continue
                }
                if cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
                    throw ZipError.zip64Unsupported
                }
                if eocdAbsolute == UInt64(cdOffset) + UInt64(cdSize) {
                    return eocdAbsolute
                }
            }
            index -= 1
        }
        throw ZipError.notZip
    }

    private static func decodePath(_ data: Data, utf8: Bool) -> String {
        if utf8, let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func normalizePath(_ path: String) -> String {
        var result = path
        if result.hasPrefix("/") {
            result.removeFirst()
        }
        if result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    var containsZip64ExtraField: Bool {
        var cursor = 0
        while cursor + 4 <= count {
            let headerID = u16(cursor)
            let size = Int(u16(cursor + 2))
            if headerID == 0x0001 {
                return true
            }
            cursor += 4 + size
            if cursor > count {
                return false
            }
        }
        return false
    }
}
