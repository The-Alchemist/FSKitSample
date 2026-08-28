import Foundation
import zlib

enum ZipZlib {
    static func inflateRaw(_ input: Data, uncompressedSize: Int) throws -> Data {
        if uncompressedSize == 0 {
            return Data()
        }
        if input.isEmpty {
            throw ZipError.truncated
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ZipError.ioFailure("inflateInit2 failed (\(initStatus))")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(uncompressedSize)

        try input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else {
                throw ZipError.truncated
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            let chunk = 16 * 1024
            var status: Int32
            repeat {
                var outBuf = [UInt8](repeating: 0, count: chunk)
                let produced = outBuf.withUnsafeMutableBytes { outRaw -> Int in
                    stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    return chunk
                }
                status = inflate(&stream, Z_FINISH)
                let written = produced - Int(stream.avail_out)
                if written > 0 {
                    output.append(contentsOf: outBuf.prefix(written))
                }
                if output.count > uncompressedSize {
                    throw ZipError.truncated
                }
            } while status == Z_OK || status == Z_BUF_ERROR

            guard status == Z_STREAM_END else {
                throw ZipError.ioFailure("inflate failed (\(status))")
            }
        }

        if output.count > uncompressedSize {
            output = output.prefix(uncompressedSize)
        }
        if output.count < uncompressedSize {
            throw ZipError.truncated
        }
        return output
    }

    static func deflateRaw(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ZipError.ioFailure("deflateInit2 failed (\(initStatus))")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        try input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            let chunk = 16 * 1024
            var status: Int32
            repeat {
                var outBuf = [UInt8](repeating: 0, count: chunk)
                let capacity = outBuf.withUnsafeMutableBytes { outRaw -> Int in
                    stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    return chunk
                }
                status = deflate(&stream, Z_FINISH)
                let written = capacity - Int(stream.avail_out)
                if written > 0 {
                    output.append(contentsOf: outBuf.prefix(written))
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw ZipError.ioFailure("deflate failed (\(status))")
            }
        }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress
            let result = zlib.crc32(0, ptr, uInt(data.count))
            return UInt32(result)
        }
    }
}
