import Foundation

public enum SevenZipMagic: Sendable {
    /// `7z\xBC\xAF\x27\x1C`
    public static let signature = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])

    public static func isSevenZip(prefix: Data) -> Bool {
        guard prefix.count >= signature.count else {
            return false
        }
        return prefix.prefix(signature.count) == signature
    }

    public static func isSevenZip(_ data: Data) -> Bool {
        isSevenZip(prefix: data)
    }
}
