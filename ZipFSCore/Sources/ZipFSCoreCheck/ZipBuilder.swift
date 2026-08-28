import Foundation
import zlib
import ZipFSCore

enum CheckZlib {
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

struct ZipBuilderFile {
    var path: String
    var data: Data
    var compression: UInt16 = 0
    var encrypted: Bool = false
    var utf8: Bool = true
}

enum ZipBuilder {
    static func build(_ files: [ZipBuilderFile]) throws -> Data {
        var locals = Data()
        var centrals = Data()
        var offset: UInt32 = 0

        for file in files {
            let compressed: Data
            if file.compression == 8 {
                compressed = try CheckZlib.deflateRaw(file.data)
            } else {
                compressed = file.data
            }

            let crc = CheckZlib.crc32(file.data)
            let nameData = Data(file.path.utf8)
            var flags: UInt16 = 0
            if file.utf8 {
                flags |= 0x0800
            }
            if file.encrypted {
                flags |= 0x0001
            }

            let localOffset = offset
            var local = Data()
            local.append(ZipMagic.localFileHeader)
            local.append(u16: 20)
            local.append(u16: flags)
            local.append(u16: file.compression)
            local.append(u16: 0)
            local.append(u16: 0)
            local.append(u32: crc)
            local.append(u32: UInt32(compressed.count))
            local.append(u32: UInt32(file.data.count))
            local.append(u16: UInt16(nameData.count))
            local.append(u16: 0)
            local.append(nameData)
            local.append(compressed)

            locals.append(local)
            offset += UInt32(local.count)

            var central = Data()
            central.append(ZipMagic.centralDirectoryHeader)
            central.append(u16: 0x0314)
            central.append(u16: 20)
            central.append(u16: flags)
            central.append(u16: file.compression)
            central.append(u16: 0)
            central.append(u16: 0)
            central.append(u32: crc)
            central.append(u32: UInt32(compressed.count))
            central.append(u32: UInt32(file.data.count))
            central.append(u16: UInt16(nameData.count))
            central.append(u16: 0)
            central.append(u16: 0)
            central.append(u16: 0)
            central.append(u16: 0)
            let isDir = file.path.hasSuffix("/")
            let mode: UInt32 = isDir ? 0o040755 : 0o100644
            central.append(u32: mode << 16)
            central.append(u32: localOffset)
            central.append(nameData)
            centrals.append(central)
        }

        var eocd = Data()
        eocd.append(ZipMagic.endOfCentralDirectory)
        eocd.append(u16: 0)
        eocd.append(u16: 0)
        eocd.append(u16: UInt16(files.count))
        eocd.append(u16: UInt16(files.count))
        eocd.append(u32: UInt32(centrals.count))
        eocd.append(u32: offset)
        eocd.append(u16: 0)

        var result = Data()
        result.append(locals)
        result.append(centrals)
        result.append(eocd)
        return result
    }

    static func emptyArchive() -> Data {
        var eocd = Data()
        eocd.append(ZipMagic.endOfCentralDirectory)
        eocd.append(contentsOf: Data(count: 16))
        eocd.append(u16: 0)
        return eocd
    }

    static func zip64EOCD() -> Data {
        var eocd = Data()
        eocd.append(ZipMagic.endOfCentralDirectory)
        eocd.append(u16: 0)
        eocd.append(u16: 0)
        eocd.append(u16: 1)
        eocd.append(u16: 1)
        eocd.append(u32: 0)
        eocd.append(u32: 0xFFFF_FFFF)
        eocd.append(u16: 0)
        return eocd
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(u32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
