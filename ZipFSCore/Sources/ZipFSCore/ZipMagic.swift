import Foundation

public enum ZipMagic: Sendable {
    public static let localFileHeader = Data([0x50, 0x4B, 0x03, 0x04])
    public static let endOfCentralDirectory = Data([0x50, 0x4B, 0x05, 0x06])
    public static let centralDirectoryHeader = Data([0x50, 0x4B, 0x01, 0x02])
    public static let zip64EndOfCentralDirectoryLocator = Data([0x50, 0x4B, 0x06, 0x07])

    /// True if `prefix` starts with a local-file header or an empty-archive EOCD.
    public static func isZip(prefix: Data) -> Bool {
        if prefix.starts(with: localFileHeader) {
            return true
        }
        if prefix.starts(with: endOfCentralDirectory) {
            return true
        }
        return false
    }

    public static func isZip(_ data: Data) -> Bool {
        isZip(prefix: data)
    }
}
