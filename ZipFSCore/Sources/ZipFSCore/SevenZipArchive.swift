import Foundation
import PLzmaSDK

public struct SevenZipArchiveEntry: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    public let uncompressedSize: UInt64
    public let modified: Date
    public let posixMode: UInt16?
    public let isAnti: Bool
    /// Index inside the PLzmaSDK decoder item list.
    public let itemIndex: UInt64
    public let packSize: UInt64
    public let isEncrypted: Bool
}

public final class SevenZipArchive: @unchecked Sendable {
    public let source: ZipSource
    public let entries: [SevenZipArchiveEntry]
    public let totalUncompressedSize: UInt64
    /// True when at least one non-empty file has packSize 0 (solid block members).
    public let isSolid: Bool

    /// On-disk extract root for solid archives only; set after the first solid extract.
    public private(set) var extractRootURL: URL?

    private let archiveData: Data
    private let decoder: Decoder
    private let openLock = NSLock()
    private var closed = false
    /// Non-solid per-file payload cache (path → data).
    private var fileCache: [String: Data] = [:]

    public convenience init(data: Data) throws {
        try self.init(source: DataZipSource(data))
    }

    public convenience init(url: URL) throws {
        try self.init(source: FileZipSource(url: url))
    }

    public init(source: ZipSource) throws {
        self.source = source
        let size = source.size
        guard size <= UInt64(Int.max) else {
            throw ZipError.ioFailure("7z archive is too large to map into memory")
        }
        let data = try source.read(offset: 0, length: Int(size))
        guard SevenZipMagic.isSevenZip(prefix: data) else {
            throw ZipError.notSevenZip
        }
        if data.isEmpty {
            throw ZipError.notSevenZip
        }
        self.archiveData = data

        let decoder: Decoder
        do {
            let stream = try InStream(dataCopy: data)
            decoder = try Decoder(stream: stream, fileType: .sevenZ)
            guard try decoder.open() else {
                throw ZipError.ioFailure("Unable to open 7z archive")
            }
        } catch let error as Exception {
            throw Self.map(error)
        } catch let error as ZipError {
            throw error
        } catch {
            throw ZipError.ioFailure(error.localizedDescription)
        }
        self.decoder = decoder

        var entries: [SevenZipArchiveEntry] = []
        do {
            let count = try decoder.count()
            entries.reserveCapacity(Int(count))
            for index in 0..<count {
                let item = try decoder.item(at: index)
                if item.encrypted {
                    throw ZipError.encryptedUnsupported
                }
                let pathString = try item.path().description
                let isDirectory = item.isDir
                entries.append(
                    SevenZipArchiveEntry(
                        path: pathString,
                        isDirectory: isDirectory,
                        uncompressedSize: isDirectory ? 0 : item.size,
                        modified: item.modificationDate,
                        posixMode: nil,
                        isAnti: false,
                        itemIndex: UInt64(index),
                        packSize: item.packSize,
                        isEncrypted: item.encrypted
                    )
                )
            }
        } catch let error as ZipError {
            throw error
        } catch let error as Exception {
            throw Self.map(error)
        } catch {
            throw ZipError.ioFailure(error.localizedDescription)
        }

        self.entries = entries
        self.totalUncompressedSize = entries.reduce(0) { $0 + $1.uncompressedSize }
        self.isSolid = Self.detectSolid(entries: entries)
    }

    deinit {
        removeExtractRoot()
    }

    /// Removes the on-disk extract cache (solid archives). Safe to call more than once.
    public func close() {
        openLock.lock()
        defer { openLock.unlock() }
        closed = true
        fileCache.removeAll(keepingCapacity: false)
        removeExtractRootLocked()
    }

    public subscript(path: String) -> SevenZipArchiveEntry? {
        let normalized = ArchivePath.normalize(path)
        return entries.first { ArchivePath.normalize($0.path) == normalized }
    }

    public func extract(_ entry: SevenZipArchiveEntry) throws -> Data {
        try extract(entry, offset: 0, length: Int(entry.uncompressedSize))
    }

    public func extract(_ entry: SevenZipArchiveEntry, offset: UInt64, length: Int) throws -> Data {
        if entry.isDirectory {
            throw ZipError.isDirectory
        }
        if entry.isEncrypted {
            throw ZipError.encryptedUnsupported
        }
        if length < 0 {
            throw ZipError.invalidOffset
        }
        if offset > entry.uncompressedSize {
            throw ZipError.invalidOffset
        }

        let remaining = Int(entry.uncompressedSize - offset)
        let count = min(length, remaining)
        if count == 0 {
            return Data()
        }

        if isSolid {
            let fileURL = try ensureSolidExtractedFile(for: entry)
            return try readFile(fileURL, offset: offset, length: count)
        }

        let data = try extractSingleFile(entry)
        let start = Int(offset)
        return data.subdata(in: start..<(start + count))
    }

    private static func detectSolid(entries: [SevenZipArchiveEntry]) -> Bool {
        for entry in entries where !entry.isDirectory && entry.uncompressedSize > 0 {
            if entry.packSize == 0 {
                return true
            }
        }
        return false
    }

    private func extractSingleFile(_ entry: SevenZipArchiveEntry) throws -> Data {
        let key = ArchivePath.normalize(entry.path)
        openLock.lock()
        if closed {
            openLock.unlock()
            throw ZipError.ioFailure("7z archive was closed")
        }
        if let cached = fileCache[key] {
            openLock.unlock()
            return cached
        }
        openLock.unlock()

        let data: Data
        do {
            let item = try decoder.item(at: Size(entry.itemIndex))
            let out = try OutStream()
            let pairs = try ItemOutStreamArray(capacity: 1)
            try pairs.add(item: item, stream: out)
            guard try decoder.extract(itemsToStreams: pairs) else {
                throw ZipError.ioFailure("Failed to extract \(entry.path)")
            }
            data = try out.copyContent()
        } catch let error as ZipError {
            throw error
        } catch let error as Exception {
            throw Self.map(error)
        } catch {
            throw ZipError.ioFailure(error.localizedDescription)
        }

        openLock.lock()
        if !closed {
            fileCache[key] = data
        }
        openLock.unlock()
        return data
    }

    private func ensureSolidExtractedFile(for entry: SevenZipArchiveEntry) throws -> URL {
        let relative = try ArchivePath.safeRelativePath(entry.path)
        openLock.lock()
        if closed {
            openLock.unlock()
            throw ZipError.ioFailure("7z archive extract cache was closed")
        }
        if let root = extractRootURL {
            openLock.unlock()
            return try fileURL(relative: relative, under: root)
        }
        openLock.unlock()

        try spillSolidArchiveToTemporaryDirectory()

        openLock.lock()
        defer { openLock.unlock() }
        guard let root = extractRootURL else {
            throw ZipError.ioFailure("Failed to create 7z extract cache")
        }
        return try fileURL(relative: relative, under: root)
    }

    private func spillSolidArchiveToTemporaryDirectory() throws {
        openLock.lock()
        if extractRootURL != nil || closed {
            openLock.unlock()
            return
        }
        openLock.unlock()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipFS-7z-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            let path = try Path(root.path)
            guard try decoder.extract(to: path, itemsFullPath: true) else {
                throw ZipError.ioFailure("Failed to extract solid 7z archive")
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            if let error = error as? ZipError {
                throw error
            }
            if let error = error as? Exception {
                throw Self.map(error)
            }
            throw ZipError.ioFailure(error.localizedDescription)
        }

        openLock.lock()
        if closed {
            openLock.unlock()
            try? FileManager.default.removeItem(at: root)
            throw ZipError.ioFailure("7z archive extract cache was closed")
        }
        extractRootURL = root
        openLock.unlock()
    }

    private func fileURL(relative: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try assertUnderRoot(url, root: root)
        return url
    }

    private func readFile(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let chunk = try handle.read(upToCount: length) else {
            return Data()
        }
        return chunk
    }

    private func assertUnderRoot(_ url: URL, root: URL) throws {
        let standardized = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if standardized == rootPath {
            return
        }
        guard standardized.hasPrefix(rootPath + "/") else {
            throw ZipError.ioFailure("Refusing path outside extract root")
        }
    }

    private func removeExtractRoot() {
        openLock.lock()
        defer { openLock.unlock() }
        removeExtractRootLocked()
    }

    private func removeExtractRootLocked() {
        guard let root = extractRootURL else {
            return
        }
        extractRootURL = nil
        try? FileManager.default.removeItem(at: root)
    }

    static func map(_ error: Exception) -> ZipError {
        let what = error.what.lowercased()
        let reason = error.reason.lowercased()
        let combined = what + " " + reason
        if combined.contains("password") || combined.contains("encrypt") {
            return .encryptedUnsupported
        }
        if combined.contains("signature") || combined.contains("type") {
            return .notSevenZip
        }
        if combined.contains("crc") {
            return .crcMismatch
        }
        return .ioFailure(error.description)
    }
}
