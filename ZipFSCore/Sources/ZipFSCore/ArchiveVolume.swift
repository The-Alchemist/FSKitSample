import Foundation

public struct ArchiveDirectoryEntry: Sendable {
    public let node: ZipNode
    public let nextCookie: UInt64
}

/// Shared read-only volume surface used by ZIP and 7z backends.
public protocol ArchiveVolumeProviding: AnyObject {
    var name: String { get }
    var root: ZipNode { get }
    var totalUncompressedSize: UInt64 { get }
    var entryCount: Int { get }

    func lookup(name: String, in directory: ZipNode) throws -> ZipNode
    func node(at path: String) throws -> ZipNode
    func enumerate(_ directory: ZipNode, startingAt cookie: UInt64) throws -> [ArchiveDirectoryEntry]
    func read(_ node: ZipNode, offset: UInt64, length: Int) throws -> Data
}

public enum ArchiveOpener {
    public static func open(url: URL) throws -> any ArchiveVolumeProviding {
        let source = try FileZipSource(url: url)
        return try open(source: source, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func open(source: ZipSource, name: String) throws -> any ArchiveVolumeProviding {
        let prefix = try source.read(offset: 0, length: 6)
        if SevenZipMagic.isSevenZip(prefix: prefix) {
            return try SevenZipVolume(source: source, name: name)
        }
        if ZipMagic.isZip(prefix: prefix) {
            return try ZipVolume(source: source, name: name)
        }
        throw ZipError.notArchive
    }
}
