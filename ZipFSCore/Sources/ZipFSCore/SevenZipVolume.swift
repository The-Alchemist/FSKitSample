import Foundation

public final class SevenZipVolume: ArchiveVolumeProviding, @unchecked Sendable {
    public let archive: SevenZipArchive
    public let tree: ArchiveTree
    public let name: String
    public var root: ZipNode { tree.root }
    public var totalUncompressedSize: UInt64 { archive.totalUncompressedSize }
    public var entryCount: Int { archive.entries.count }

    private let cacheLock = NSLock()
    private var cache: [UInt64: Data] = [:]

    public init(archive: SevenZipArchive, name: String) {
        self.archive = archive
        self.tree = ArchiveTree(members: Self.members(from: archive))
        self.name = name
    }

    public convenience init(source: ZipSource, name: String) throws {
        try self.init(archive: SevenZipArchive(source: source), name: name)
    }

    public convenience init(url: URL) throws {
        try self.init(archive: SevenZipArchive(url: url), name: url.deletingPathExtension().lastPathComponent)
    }

    public func lookup(name: String, in directory: ZipNode) throws -> ZipNode {
        guard directory.isDirectory else {
            throw ZipError.notDirectory
        }
        if let child = directory.children[name] {
            return child
        }
        throw ZipError.notFound
    }

    public func node(at path: String) throws -> ZipNode {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var current = root
        for part in parts {
            current = try lookup(name: part, in: current)
        }
        return current
    }

    public func enumerate(_ directory: ZipNode, startingAt cookie: UInt64) throws -> [ArchiveDirectoryEntry] {
        guard directory.isDirectory else {
            throw ZipError.notDirectory
        }
        let children = directory.sortedChildren
        let start = Int(cookie)
        guard start >= 0 else {
            throw ZipError.invalidOffset
        }
        guard start < children.count else {
            return []
        }
        return (start..<children.count).map { index in
            ArchiveDirectoryEntry(node: children[index], nextCookie: UInt64(index + 1))
        }
    }

    public func read(_ node: ZipNode, offset: UInt64, length: Int) throws -> Data {
        guard !node.isDirectory else {
            throw ZipError.isDirectory
        }
        guard let entryIndex = node.entryIndex, archive.entries.indices.contains(entryIndex) else {
            throw ZipError.notFound
        }
        let entry = archive.entries[entryIndex]
        if offset > entry.uncompressedSize {
            throw ZipError.invalidOffset
        }
        if length < 0 {
            throw ZipError.invalidOffset
        }

        let remaining = Int(entry.uncompressedSize - offset)
        let count = min(length, remaining)
        if count == 0 {
            return Data()
        }

        let data = try cachedContents(of: node, entry: entry)
        let start = Int(offset)
        return data.subdata(in: start..<(start + count))
    }

    public func createItem() throws -> Never {
        throw ZipError.readOnly
    }

    public func removeItem() throws -> Never {
        throw ZipError.readOnly
    }

    public func renameItem() throws -> Never {
        throw ZipError.readOnly
    }

    public func write() throws -> Never {
        throw ZipError.readOnly
    }

    public func setAttributes() throws -> Never {
        throw ZipError.readOnly
    }

    public func setXattr() throws -> Never {
        throw ZipError.readOnly
    }

    private func cachedContents(of node: ZipNode, entry: SevenZipArchiveEntry) throws -> Data {
        cacheLock.lock()
        if let cached = cache[node.fileID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let data = try archive.extract(entry)

        cacheLock.lock()
        cache[node.fileID] = data
        cacheLock.unlock()
        return data
    }

    private static func members(from archive: SevenZipArchive) -> [ArchiveTreeMember] {
        archive.entries.enumerated().map { index, entry in
            ArchiveTreeMember(
                path: entry.path,
                isDirectory: entry.isDirectory,
                uncompressedSize: entry.uncompressedSize,
                modified: entry.modified,
                posixMode: entry.posixMode,
                entryIndex: entry.isDirectory ? nil : index
            )
        }
    }
}
