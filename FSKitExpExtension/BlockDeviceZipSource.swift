import Foundation
import FSKit
import os
import ZipFSCore

final class BlockDeviceZipSource: ZipSource {
    private let resource: FSBlockDeviceResource
    private let lock = NSLock()

    init(resource: FSBlockDeviceResource) {
        self.resource = resource
    }

    var size: UInt64 {
        resource.blockCount * resource.blockSize
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw ZipError.invalidOffset
        }
        if length == 0 {
            return Data()
        }

        let sector = max(Int(resource.physicalBlockSize), 1)
        let alignedOffset = (offset / UInt64(sector)) * UInt64(sector)
        let leading = Int(offset - alignedOffset)
        let alignedLength = ((leading + length + sector - 1) / sector) * sector

        var buffer = Data(count: alignedLength)
        let actuallyRead = try lock.withLock {
            try buffer.withUnsafeMutableBytes { raw -> Int in
                try resource.read(
                    into: raw,
                    startingAt: off_t(alignedOffset),
                    length: alignedLength
                )
            }
        }

        if actuallyRead < leading {
            throw ZipError.truncated
        }
        let available = min(length, actuallyRead - leading)
        return buffer.subdata(in: leading..<(leading + available))
    }
}
