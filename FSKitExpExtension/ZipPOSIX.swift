import Foundation
import FSKit
import ZipFSCore

enum ZipPOSIX {
    static func error(_ code: POSIXError.Code) -> Error {
        fs_errorForPOSIXError(code.rawValue)
    }

    static func map(_ error: Error) -> Error {
        guard let zipError = error as? ZipError else {
            return Self.error(.EIO)
        }
        switch zipError {
        case .readOnly:
            return Self.error(.EROFS)
        case .notFound:
            return Self.error(.ENOENT)
        case .notDirectory:
            return Self.error(.ENOTDIR)
        case .isDirectory:
            return Self.error(.EISDIR)
        case .invalidOffset, .notZip, .notSevenZip, .notArchive:
            return Self.error(.EINVAL)
        default:
            return Self.error(.EIO)
        }
    }
}

enum ZipAttributes {
    static func apply(to attributes: FSItem.Attributes, node: ZipNode) {
        if node.fileID == 2 {
            attributes.fileID = .rootDirectory
            attributes.parentID = .parentOfRoot
        } else {
            attributes.fileID = FSItem.Identifier(rawValue: node.fileID) ?? .invalid
            if node.parentID == 2 {
                attributes.parentID = .rootDirectory
            } else {
                attributes.parentID = FSItem.Identifier(rawValue: node.parentID) ?? .invalid
            }
        }
        attributes.uid = 0
        attributes.gid = 0
        attributes.linkCount = 1
        attributes.type = node.isDirectory ? .directory : .file
        let fileType: UInt32 = node.isDirectory ? UInt32(S_IFDIR) : UInt32(S_IFREG)
        attributes.mode = fileType | presentedMode(for: node)
        attributes.size = node.size
        attributes.allocSize = node.size
        let timespec = Self.posixTimespec(from: node.modified)
        attributes.addedTime = timespec
        attributes.birthTime = timespec
        attributes.changeTime = timespec
        attributes.modifyTime = timespec
        attributes.accessTime = timespec
    }

    static func posixTimespec(from date: Date) -> timespec {
        var value = timespec()
        let seconds = date.timeIntervalSince1970
        value.tv_sec = time_t(seconds)
        value.tv_nsec = Int((seconds - floor(seconds)) * 1_000_000_000)
        return value
    }

    /// Drop write bits so Finder/Launch Services treat items as read-only and
    /// do not try to set quarantine xattrs (which fail on an MNT_RDONLY mount).
    private static func presentedMode(for node: ZipNode) -> UInt32 {
        if node.isDirectory {
            return 0o555
        }
        return 0o444 | (UInt32(node.posixMode) & 0o111)
    }
}
