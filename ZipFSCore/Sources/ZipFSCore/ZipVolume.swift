import Foundation

public struct ZipDirectoryEntry: Sendable {
    public let node: ZipNode
    public let nextCookie: UInt64
}

public final class ZipVolume: @unchecked Sendable {
    public let archive: ZipArchive
    public let tree: ZipTree
    public let name: String
    public var root: ZipNode { tree.root }

    private let cacheLock = NSLock()
    private var cache: [UInt64: Data] = [:]

    public init(archive: ZipArchive, name: String) {
        self.archive = archive
        self.tree = ZipTree(archive: archive)
        self.name = name
    }

    public convenience init(source: ZipSource, name: String) throws {
        try self.init(archive: ZipArchive(source: source), name: name)
    }

    public convenience init(url: URL) throws {
        try self.init(archive: ZipArchive(url: url), name: url.deletingPathExtension().lastPathComponent)
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

    public func enumerate(_ directory: ZipNode, startingAt cookie: UInt64) throws -> [ZipDirectoryEntry] {
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
            ZipDirectoryEntry(node: children[index], nextCookie: UInt64(index + 1))
        }
    }

    public func read(_ node: ZipNode, offset: UInt64, length: Int) throws -> Data {
        guard !node.isDirectory else {
            throw ZipError.isDirectory
        }
        guard let entry = node.entry else {
            throw ZipError.notFound
        }
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

        if entry.compressionMethod == 0 {
            return try archive.extract(entry, offset: offset, length: count)
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

    private func cachedContents(of node: ZipNode, entry: ZipEntry) throws -> Data {
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
}
