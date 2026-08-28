import Foundation

public protocol ZipSource: AnyObject {
    var size: UInt64 { get }
    func read(offset: UInt64, length: Int) throws -> Data
}

public final class DataZipSource: ZipSource, @unchecked Sendable {
    private let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var size: UInt64 {
        UInt64(data.count)
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw ZipError.invalidOffset
        }
        guard offset <= size else {
            throw ZipError.truncated
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }
}

public final class FileZipSource: ZipSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public let size: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let end = try handle.seekToEnd()
        size = end
        try handle.seek(toOffset: 0)
    }

    deinit {
        try? handle.close()
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw ZipError.invalidOffset
        }
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        guard let chunk = try handle.read(upToCount: length) else {
            return Data()
        }
        return chunk
    }
}
