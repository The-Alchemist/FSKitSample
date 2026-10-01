import Foundation
import ZipFSCore

enum Check {
    private nonisolated(unsafe) static var failures = 0
    private nonisolated(unsafe) static var runs = 0

    static func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        runs += 1
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message)\n".utf8))
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
        expect(actual == expected, "\(message) (got \(actual), expected \(expected))", file: file, line: line)
    }

    static func throwsError<E: Error & Equatable>(_ expected: E, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
        do {
            try body()
            expect(false, "expected \(expected) but no error was thrown", file: file, line: line)
        } catch let error as E {
            equal(error, expected, "error mismatch", file: file, line: line)
        } catch {
            expect(false, "expected \(expected) but got \(error)", file: file, line: line)
        }
    }

    static func finish() {
        if failures == 0 {
            print("All \(runs) checks passed.")
            Foundation.exit(0)
        } else {
            print("\(failures) of \(runs) checks failed.")
            Foundation.exit(1)
        }
    }
}

@main
struct ZipFSCoreCheck {
    static func main() {
        magicTests()
        archiveTests()
        treeAndVolumeTests()
        systemZipTests()
        sevenZipTests()
        Check.finish()
    }

    static func magicTests() {
        Check.expect(ZipMagic.isZip(prefix: Data([0x50, 0x4B, 0x03, 0x04, 0x00])), "local header")
        Check.expect(ZipMagic.isZip(ZipBuilder.emptyArchive()), "empty EOCD")
        Check.expect(!ZipMagic.isZip(prefix: Data([0x00, 0x01, 0x02, 0x03])), "random bytes")
        Check.expect(!ZipMagic.isZip(prefix: Data("hello".utf8)), "text prefix")
        Check.expect(SevenZipMagic.isSevenZip(prefix: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), "7z signature")
        Check.expect(!SevenZipMagic.isSevenZip(prefix: Data([0x50, 0x4B, 0x03, 0x04])), "zip is not 7z")
    }

    static func archiveTests() {
        do {
            let archive = try ZipArchive(data: ZipBuilder.emptyArchive())
            Check.equal(archive.entries.count, 0, "empty archive")
        } catch {
            Check.expect(false, "empty archive threw \(error)")
        }

        do {
            let payload = Data("hello zip".utf8)
            let data = try ZipBuilder.build([ZipBuilderFile(path: "dir/file.txt", data: payload)])
            let archive = try ZipArchive(data: data)
            Check.equal(archive.entries.count, 1, "nested entry count")
            guard let entry = archive["dir/file.txt"] else {
                Check.expect(false, "missing dir/file.txt")
                return
            }
            Check.equal(entry.compressionMethod, 0, "stored method")
            Check.equal(try archive.extract(entry), payload, "stored extract")
        } catch {
            Check.expect(false, "stored extract threw \(error)")
        }

        do {
            let payload = Data(String(repeating: "abc", count: 200).utf8)
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "compressed.txt", data: payload, compression: 8),
            ])
            let archive = try ZipArchive(data: data)
            guard let entry = archive["compressed.txt"] else {
                Check.expect(false, "missing compressed.txt")
                return
            }
            Check.equal(entry.compressionMethod, 8, "deflate method")
            Check.equal(try archive.extract(entry), payload, "deflate extract")
        } catch {
            Check.expect(false, "deflate extract threw \(error)")
        }

        do {
            let payload = Data("abcdefghij".utf8)
            let data = try ZipBuilder.build([ZipBuilderFile(path: "range.txt", data: payload)])
            let archive = try ZipArchive(data: data)
            let entry = try unwrap(archive["range.txt"], "range.txt")
            Check.equal(try archive.extract(entry, offset: 3, length: 4), Data("defg".utf8), "ranged stored extract")
        } catch {
            Check.expect(false, "ranged extract threw \(error)")
        }

        do {
            let payload = Data("ok".utf8)
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "café/naïve.txt", data: payload, utf8: true),
            ])
            let archive = try ZipArchive(data: data)
            Check.expect(archive["café/naïve.txt"] != nil, "utf8 path lookup")
            if let entry = archive["café/naïve.txt"] {
                Check.equal(try archive.extract(entry), payload, "utf8 extract")
            }
        } catch {
            Check.expect(false, "utf8 names threw \(error)")
        }

        Check.throwsError(ZipError.zip64Unsupported) {
            _ = try ZipArchive(data: ZipBuilder.zip64EOCD())
        }

        do {
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "secret.txt", data: Data("x".utf8), encrypted: true),
            ])
            let archive = try ZipArchive(data: data)
            let entry = try unwrap(archive["secret.txt"], "secret.txt")
            Check.expect(entry.isEncrypted, "encrypted flag")
            Check.throwsError(ZipError.encryptedUnsupported) {
                _ = try archive.extract(entry)
            }
        } catch {
            Check.expect(false, "encryption test threw \(error)")
        }

        do {
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "weird.bin", data: Data("x".utf8), compression: 12),
            ])
            let archive = try ZipArchive(data: data)
            let entry = try unwrap(archive["weird.bin"], "weird.bin")
            Check.throwsError(ZipError.compressionUnsupported(12)) {
                _ = try archive.extract(entry)
            }
        } catch {
            Check.expect(false, "unknown method test threw \(error)")
        }

        do {
            let payload = Data("from file".utf8)
            let zipData = try ZipBuilder.build([ZipBuilderFile(path: "a.txt", data: payload)])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try zipData.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try ZipArchive(url: url)
            let entry = try unwrap(archive["a.txt"], "a.txt")
            Check.equal(try archive.extract(entry), payload, "file source extract")
        } catch {
            Check.expect(false, "file zip source threw \(error)")
        }

        do {
            let payload = Data("padded".utf8)
            var data = try ZipBuilder.build([ZipBuilderFile(path: "p.txt", data: payload)])
            data.append(contentsOf: Data(count: 512))
            let archive = try ZipArchive(data: data)
            let entry = try unwrap(archive["p.txt"], "p.txt")
            Check.equal(try archive.extract(entry), payload, "padded trailing zeros extract")
        } catch {
            Check.expect(false, "padded zip threw \(error)")
        }
    }

    static func treeAndVolumeTests() {
        do {
            let data = try ZipBuilder.build([ZipBuilderFile(path: "a/b/c.txt", data: Data("c".utf8))])
            let volume = try ZipVolume(archive: ZipArchive(data: data), name: "test")
            let a = try volume.lookup(name: "a", in: volume.root)
            Check.expect(a.isDirectory, "implicit dir a")
            let b = try volume.lookup(name: "b", in: a)
            Check.expect(b.isDirectory, "implicit dir b")
            let c = try volume.lookup(name: "c.txt", in: b)
            Check.expect(!c.isDirectory, "file c.txt")
            Check.throwsError(ZipError.notFound) {
                _ = try volume.lookup(name: "missing", in: volume.root)
            }
        } catch {
            Check.expect(false, "implicit parents threw \(error)")
        }

        do {
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "a.txt", data: Data("a".utf8)),
                ZipBuilderFile(path: "b.txt", data: Data("b".utf8)),
                ZipBuilderFile(path: "c.txt", data: Data("c".utf8)),
            ])
            let volume = try ZipVolume(archive: ZipArchive(data: data), name: "test")
            let all = try volume.enumerate(volume.root, startingAt: 0)
            Check.equal(all.count, 3, "enumerate all")
            Check.equal(all.map(\.nextCookie), [1, 2, 3], "next cookies")
            let rest = try volume.enumerate(volume.root, startingAt: 1)
            Check.equal(rest.count, 2, "enumerate from 1")
            Check.equal(rest.first?.nextCookie, 2, "second cookie")
            let empty = try volume.enumerate(volume.root, startingAt: 3)
            Check.expect(empty.isEmpty, "enumerate past end")
        } catch {
            Check.expect(false, "enumerate threw \(error)")
        }

        do {
            let payload = Data("abcdefghij".utf8)
            let data = try ZipBuilder.build([ZipBuilderFile(path: "range.txt", data: payload)])
            let volume = try ZipVolume(archive: ZipArchive(data: data), name: "test")
            let node = try volume.node(at: "range.txt")
            Check.equal(try volume.read(node, offset: 2, length: 3), Data("cde".utf8), "volume ranged read")
            Check.equal(try volume.read(node, offset: 8, length: 10), Data("ij".utf8), "volume read clamp")
            Check.expect(try volume.read(node, offset: 10, length: 4).isEmpty, "read at EOF")
        } catch {
            Check.expect(false, "volume read threw \(error)")
        }

        do {
            let data = try ZipBuilder.build([ZipBuilderFile(path: "a.txt", data: Data("a".utf8))])
            let volume = try ZipVolume(archive: ZipArchive(data: data), name: "test")
            Check.throwsError(ZipError.readOnly) { try volume.createItem() }
            Check.throwsError(ZipError.readOnly) { try volume.removeItem() }
            Check.throwsError(ZipError.readOnly) { try volume.renameItem() }
            Check.throwsError(ZipError.readOnly) { try volume.write() }
            Check.throwsError(ZipError.readOnly) { try volume.setAttributes() }
            Check.throwsError(ZipError.readOnly) { try volume.setXattr() }
        } catch {
            Check.expect(false, "readonly tests threw \(error)")
        }

        do {
            let payload = Data(String(repeating: "xyz", count: 80).utf8)
            let data = try ZipBuilder.build([
                ZipBuilderFile(path: "big.txt", data: payload, compression: 8),
            ])
            let volume = try ZipVolume(archive: ZipArchive(data: data), name: "test")
            let node = try volume.node(at: "big.txt")
            Check.equal(
                try volume.read(node, offset: 3, length: 6),
                payload.subdata(in: 3..<9),
                "deflate ranged volume read"
            )
        } catch {
            Check.expect(false, "deflate volume read threw \(error)")
        }
    }

    static func systemZipTests() {
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let hello = Data("hello from zip(1)\n".utf8)
            try hello.write(to: tmp.appendingPathComponent("hello.txt"))
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent("nested"),
                withIntermediateDirectories: true
            )
            try Data("nested".utf8).write(to: tmp.appendingPathComponent("nested/file.txt"))

            let zipURL = tmp.appendingPathComponent("tool.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = tmp
            process.arguments = ["-q", "-r", zipURL.path, "hello.txt", "nested"]
            try process.run()
            process.waitUntilExit()
            Check.equal(process.terminationStatus, 0, "zip(1) exit")

            let volume = try ZipVolume(url: zipURL)
            let helloNode = try volume.node(at: "hello.txt")
            Check.equal(try volume.read(helloNode, offset: 0, length: hello.count), hello, "zip(1) hello.txt")

            let nested = try volume.node(at: "nested")
            Check.expect(nested.isDirectory, "zip(1) nested dir")
            let nestedFile = try volume.lookup(name: "file.txt", in: nested)
            Check.equal(try volume.read(nestedFile, offset: 0, length: 6), Data("nested".utf8), "zip(1) nested file")
        } catch {
            Check.expect(false, "system zip threw \(error)")
        }
    }

    static func sevenZipTests() {
        guard let basicURL = Bundle.module.url(forResource: "basic", withExtension: "7z", subdirectory: "Fixtures/7z")
        else {
            Check.expect(false, "missing basic.7z fixture")
            return
        }
        guard let solidURL = Bundle.module.url(forResource: "solid", withExtension: "7z", subdirectory: "Fixtures/7z")
        else {
            Check.expect(false, "missing solid.7z fixture")
            return
        }

        do {
            let prefix = try Data(contentsOf: basicURL).prefix(6)
            Check.expect(SevenZipMagic.isSevenZip(prefix: Data(prefix)), "fixture magic")

            let volume = try SevenZipVolume(url: basicURL)
            let names = try volume.enumerate(volume.root, startingAt: 0).map(\.node.name).sorted()
            Check.equal(names, ["dir", "empty", "hello.txt"], "basic root listing")

            let hello = try volume.node(at: "hello.txt")
            Check.equal(try volume.read(hello, offset: 0, length: Int(hello.size)), Data("hello 7z\n".utf8), "basic hello.txt")

            let nested = try volume.node(at: "dir/nested.txt")
            Check.equal(
                try volume.read(nested, offset: 0, length: Int(nested.size)),
                Data("nested payload\n".utf8),
                "basic nested.txt"
            )

            let unicode = try volume.node(at: "dir/naïve.txt")
            Check.equal(
                try volume.read(unicode, offset: 0, length: Int(unicode.size)),
                Data("café\n".utf8),
                "basic unicode name"
            )

            let empty = try volume.node(at: "empty")
            Check.expect(empty.isDirectory, "basic empty dir")

            let opened = try ArchiveOpener.open(url: basicURL)
            Check.equal(opened.entryCount, volume.entryCount, "ArchiveOpener picks 7z")
        } catch {
            Check.expect(false, "basic 7z threw \(error)")
        }

        do {
            let archive = try SevenZipArchive(url: basicURL)
            Check.expect(!archive.isSolid, "basic.7z is not solid")
            let hello = try unwrap(archive["hello.txt"], "hello.txt")
            _ = try archive.extract(hello)
            Check.expect(archive.extractRootURL == nil, "non-solid never spills to temp")
            let nested = try unwrap(archive["dir/nested.txt"], "nested")
            _ = try archive.extract(nested)
            Check.expect(archive.extractRootURL == nil, "non-solid still no spill after second read")
        } catch {
            Check.expect(false, "non-solid no-spill threw \(error)")
        }

        do {
            let volume = try SevenZipVolume(url: solidURL)
            let a = try volume.node(at: "a.txt")
            let b = try volume.node(at: "b.txt")
            let c = try volume.node(at: "c.txt")
            Check.equal(try volume.read(a, offset: 0, length: 2), Data("a\n".utf8), "solid a.txt")
            Check.equal(try volume.read(b, offset: 0, length: 2), Data("b\n".utf8), "solid b.txt")
            Check.equal(try volume.read(c, offset: 0, length: 1), Data("c".utf8), "solid c.txt ranged")
        } catch {
            Check.expect(false, "solid 7z threw \(error)")
        }

        do {
            let archive = try SevenZipArchive(url: solidURL)
            Check.expect(archive.isSolid, "solid.7z is solid")
            Check.expect(archive.extractRootURL == nil, "no extract root before read")
            let entry = try unwrap(archive["a.txt"], "a.txt")
            _ = try archive.extract(entry)
            guard let root = archive.extractRootURL else {
                Check.expect(false, "extract root missing after solid read")
                return
            }
            let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
            Check.expect(
                root.standardizedFileURL.path.hasPrefix(tempRoot),
                "extract root under temporaryDirectory"
            )
            Check.expect(
                FileManager.default.fileExists(atPath: root.path),
                "extract root exists on disk"
            )
            let spilled = root.appendingPathComponent("a.txt")
            Check.expect(FileManager.default.fileExists(atPath: spilled.path), "spilled a.txt")
            archive.close()
            Check.expect(archive.extractRootURL == nil, "extract root cleared after close")
            Check.expect(
                !FileManager.default.fileExists(atPath: root.path),
                "extract root removed after close"
            )
        } catch {
            Check.expect(false, "solid extract cache lifecycle threw \(error)")
        }

        do {
            let rootPath: String?
            do {
                let archive = try SevenZipArchive(url: solidURL)
                let entry = try unwrap(archive["b.txt"], "b.txt")
                _ = try archive.extract(entry)
                rootPath = archive.extractRootURL?.path
                Check.expect(rootPath != nil, "extract root for deinit test")
            }
            if let path = rootPath {
                Check.expect(
                    !FileManager.default.fileExists(atPath: path),
                    "extract root removed on deinit"
                )
            } else {
                Check.expect(false, "extract root path unavailable for deinit test")
            }
        } catch {
            Check.expect(false, "solid extract deinit threw \(error)")
        }

        Check.throwsError(ZipError.ioFailure("Unsafe archive path: ../escape.txt")) {
            _ = try ArchivePath.safeRelativePath("../escape.txt")
        }
        Check.throwsError(ZipError.ioFailure("Unsafe archive path: dir/../x")) {
            _ = try ArchivePath.safeRelativePath("dir/../x")
        }
        do {
            Check.equal(try ArchivePath.safeRelativePath("dir/file.txt"), "dir/file.txt", "safe nested path")
        } catch {
            Check.expect(false, "safeRelativePath threw \(error)")
        }

        Check.throwsError(ZipError.notSevenZip) {
            _ = try SevenZipArchive(data: Data("not a 7z archive".utf8))
        }
        Check.throwsError(ZipError.notArchive) {
            _ = try ArchiveOpener.open(source: DataZipSource(Data("nope".utf8)), name: "x")
        }
    }

    static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else {
            throw ZipError.notFound
        }
        _ = name
        return value
    }
}
