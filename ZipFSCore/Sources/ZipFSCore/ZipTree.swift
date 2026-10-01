import Foundation

/// Flat member used to build an `ArchiveTree` for ZIP or 7z.
public struct ArchiveTreeMember: Sendable {
    public let path: String
    public let isDirectory: Bool
    public let uncompressedSize: UInt64
    public let modified: Date
    public let posixMode: UInt16?
    public let entryIndex: Int?

    public init(
        path: String,
        isDirectory: Bool,
        uncompressedSize: UInt64,
        modified: Date,
        posixMode: UInt16?,
        entryIndex: Int?
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.uncompressedSize = uncompressedSize
        self.modified = modified
        self.posixMode = posixMode
        self.entryIndex = entryIndex
    }
}

public final class ZipNode: @unchecked Sendable {
    public let name: String
    public let fileID: UInt64
    public let parentID: UInt64
    public let isDirectory: Bool
    public private(set) var children: [String: ZipNode]
    /// Index into the owning archive's entry list for file reads; nil for synthetic directories.
    public let entryIndex: Int?
    public let modified: Date
    public let posixMode: UInt16
    public let size: UInt64

    public var sortedChildren: [ZipNode] {
        children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(
        name: String,
        fileID: UInt64,
        parentID: UInt64,
        isDirectory: Bool,
        entryIndex: Int?,
        size: UInt64,
        modified: Date,
        posixMode: UInt16
    ) {
        self.name = name
        self.fileID = fileID
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.children = [:]
        self.entryIndex = entryIndex
        self.size = size
        self.modified = modified
        self.posixMode = posixMode
    }

    func addChild(_ node: ZipNode) {
        children[node.name] = node
    }
}

public final class ArchiveTree: @unchecked Sendable {
    public let root: ZipNode
    private var nextID: UInt64 = 3

    public init(members: [ArchiveTreeMember]) {
        root = ZipNode(
            name: "/",
            fileID: 2,
            parentID: 1,
            isDirectory: true,
            entryIndex: nil,
            size: 0,
            modified: Date(timeIntervalSince1970: 0),
            posixMode: 0o755
        )

        for member in members {
            insert(member)
        }
    }

    private func insert(_ member: ArchiveTreeMember) {
        let normalized = ArchivePath.normalize(member.path)
        if normalized.isEmpty {
            return
        }

        let parts = normalized.split(separator: "/").map(String.init)
        var parent = root
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let directory = !isLast || member.isDirectory

            if isLast {
                if let existing = parent.children[part] {
                    if directory {
                        // Keep the first directory node identity.
                        _ = existing
                    } else if !existing.isDirectory {
                        // Duplicate file: keep the first entry.
                    }
                    return
                }

                let node = ZipNode(
                    name: part,
                    fileID: nextID,
                    parentID: parent.fileID,
                    isDirectory: directory,
                    entryIndex: directory && !member.isDirectory ? nil : member.entryIndex,
                    size: directory ? 0 : member.uncompressedSize,
                    modified: member.modified,
                    posixMode: mode(for: member, isDirectory: directory)
                )
                nextID += 1
                parent.addChild(node)
                return
            }

            if let existing = parent.children[part] {
                parent = existing
                continue
            }

            let directoryNode = ZipNode(
                name: part,
                fileID: nextID,
                parentID: parent.fileID,
                isDirectory: true,
                entryIndex: nil,
                size: 0,
                modified: member.modified,
                posixMode: 0o755
            )
            nextID += 1
            parent.addChild(directoryNode)
            parent = directoryNode
        }
    }

    private func mode(for member: ArchiveTreeMember, isDirectory: Bool) -> UInt16 {
        if let posix = member.posixMode, posix != 0 {
            return posix & 0o7777
        }
        return isDirectory ? 0o755 : 0o644
    }
}

public enum ArchivePath {
    public static func normalize(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") {
            result = String(result.dropFirst(2))
        }
        while result.hasPrefix("/") {
            result = String(result.dropFirst())
        }
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result
    }

    /// Normalized relative path safe for writing under an extract root.
    /// Rejects empty, `.`, `..`, and any segment that is `..`.
    public static func safeRelativePath(_ path: String) throws -> String {
        let normalized = normalize(path)
        if normalized.isEmpty {
            return ""
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else {
            return ""
        }
        for part in parts {
            if part == "." || part == ".." {
                throw ZipError.ioFailure("Unsafe archive path: \(path)")
            }
            if part.contains("\0") {
                throw ZipError.ioFailure("Unsafe archive path: \(path)")
            }
        }
        return parts.joined(separator: "/")
    }
}

/// Backwards-compatible name used by ZIP code paths.
public typealias ZipTree = ArchiveTree
