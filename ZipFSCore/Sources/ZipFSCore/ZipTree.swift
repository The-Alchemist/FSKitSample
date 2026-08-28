import Foundation

public final class ZipNode: @unchecked Sendable {
    public let name: String
    public let fileID: UInt64
    public let parentID: UInt64
    public let isDirectory: Bool
    public private(set) var children: [String: ZipNode]
    public let entry: ZipEntry?
    public let modified: Date
    public let posixMode: UInt16

    public var size: UInt64 {
        if isDirectory {
            return 0
        }
        return UInt64(entry?.uncompressedSize ?? 0)
    }

    public var sortedChildren: [ZipNode] {
        children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(
        name: String,
        fileID: UInt64,
        parentID: UInt64,
        isDirectory: Bool,
        entry: ZipEntry?,
        modified: Date,
        posixMode: UInt16
    ) {
        self.name = name
        self.fileID = fileID
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.children = [:]
        self.entry = entry
        self.modified = modified
        self.posixMode = posixMode
    }

    func addChild(_ node: ZipNode) {
        children[node.name] = node
    }
}

public final class ZipTree: @unchecked Sendable {
    public let root: ZipNode
    private var nextID: UInt64 = 3

    public init(archive: ZipArchive) {
        root = ZipNode(
            name: "/",
            fileID: 2,
            parentID: 1,
            isDirectory: true,
            entry: nil,
            modified: Date(timeIntervalSince1970: 0),
            posixMode: 0o755
        )

        for entry in archive.entries {
            insert(entry)
        }
    }

    private func insert(_ entry: ZipEntry) {
        let normalized = ZipArchive.normalizePath(entry.path)
        if normalized.isEmpty {
            if entry.isDirectory {
                apply(entry, to: root)
            }
            return
        }

        let parts = normalized.split(separator: "/").map(String.init)
        var parent = root
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let directory = !isLast || entry.isDirectory

            if isLast {
                if let existing = parent.children[part] {
                    if directory {
                        apply(entry, to: existing)
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
                    entry: directory && !entry.isDirectory ? nil : entry,
                    modified: entry.modified,
                    posixMode: mode(for: entry, isDirectory: directory)
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
                entry: nil,
                modified: entry.modified,
                posixMode: 0o755
            )
            nextID += 1
            parent.addChild(directoryNode)
            parent = directoryNode
        }
    }

    private func apply(_ entry: ZipEntry, to node: ZipNode) {
        // Root / existing directories keep identity; timestamps can come from the entry.
        _ = entry
        _ = node
    }

    private func mode(for entry: ZipEntry, isDirectory: Bool) -> UInt16 {
        if let posix = entry.posixMode, posix != 0 {
            return posix & 0o7777
        }
        return isDirectory ? 0o755 : 0o644
    }
}
