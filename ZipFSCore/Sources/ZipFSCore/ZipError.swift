import Foundation

public enum ZipError: Error, Equatable, Sendable {
    case notZip
    case notSevenZip
    case notArchive
    case truncated
    case zip64Unsupported
    case encryptedUnsupported
    case compressionUnsupported(UInt16)
    case crcMismatch
    case readOnly
    case notFound
    case notDirectory
    case isDirectory
    case invalidOffset
    case ioFailure(String)
}

extension ZipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notZip:
            return "Not a ZIP archive"
        case .notSevenZip:
            return "Not a 7z archive"
        case .notArchive:
            return "Not a supported archive"
        case .truncated:
            return "Truncated archive"
        case .zip64Unsupported:
            return "Zip64 archives are not supported"
        case .encryptedUnsupported:
            return "Encrypted archive entries are not supported"
        case .compressionUnsupported(let method):
            return "Unsupported ZIP compression method \(method)"
        case .crcMismatch:
            return "Archive CRC mismatch"
        case .readOnly:
            return "Volume is read-only"
        case .notFound:
            return "No such file or directory"
        case .notDirectory:
            return "Not a directory"
        case .isDirectory:
            return "Is a directory"
        case .invalidOffset:
            return "Invalid read offset"
        case .ioFailure(let message):
            return message
        }
    }
}
