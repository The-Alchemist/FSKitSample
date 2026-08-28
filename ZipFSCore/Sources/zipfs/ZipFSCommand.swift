import Foundation
import ZipFSCore

@main
struct ZipFSCommand {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try run(args)
        } catch let error as ZipError {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ args: [String]) throws {
        guard let command = args.first else {
            printUsage()
            Foundation.exit(2)
        }

        switch command {
        case "ls":
            guard args.count >= 2 else {
                printUsage()
                Foundation.exit(2)
            }
            try ls(archivePath: args[1], path: args.count > 2 ? args[2] : "/")
        case "stat":
            guard args.count >= 3 else {
                printUsage()
                Foundation.exit(2)
            }
            try stat(archivePath: args[1], path: args[2])
        case "cat":
            guard args.count >= 3 else {
                printUsage()
                Foundation.exit(2)
            }
            try cat(archivePath: args[1], path: args[2])
        case "read":
            try read(Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            printUsage()
            Foundation.exit(2)
        }
    }

    private static func volume(at archivePath: String) throws -> ZipVolume {
        let url = URL(fileURLWithPath: archivePath)
        return try ZipVolume(url: url)
    }

    private static func ls(archivePath: String, path: String) throws {
        let volume = try volume(at: archivePath)
        let node = try volume.node(at: path)
        if node.isDirectory {
            for child in node.sortedChildren {
                let suffix = child.isDirectory ? "/" : ""
                print("\(child.name)\(suffix)")
            }
        } else {
            print(node.name)
        }
    }

    private static func stat(archivePath: String, path: String) throws {
        let volume = try volume(at: archivePath)
        let node = try volume.node(at: path)
        let type = node.isDirectory ? "directory" : "file"
        print("path: \(path)")
        print("name: \(node.name)")
        print("type: \(type)")
        print("id: \(node.fileID)")
        print("size: \(node.size)")
        print("mode: \(String(node.posixMode, radix: 8))")
        print("modified: \(node.modified)")
        if let entry = node.entry {
            print("compression: \(entry.compressionMethod)")
            print("crc32: \(String(entry.crc32, radix: 16))")
        }
    }

    private static func cat(archivePath: String, path: String) throws {
        let volume = try volume(at: archivePath)
        let node = try volume.node(at: path)
        let data = try volume.read(node, offset: 0, length: Int(node.size))
        FileHandle.standardOutput.write(data)
    }

    private static func read(_ args: [String]) throws {
        var offset: UInt64 = 0
        var length: Int?
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--offset" {
                index += 1
                guard index < args.count, let value = UInt64(args[index]) else {
                    printUsage()
                    Foundation.exit(2)
                }
                offset = value
            } else if arg == "--length" {
                index += 1
                guard index < args.count, let value = Int(args[index]) else {
                    printUsage()
                    Foundation.exit(2)
                }
                length = value
            } else if arg.hasPrefix("-") {
                printUsage()
                Foundation.exit(2)
            } else {
                positional.append(arg)
            }
            index += 1
        }

        guard positional.count >= 2 else {
            printUsage()
            Foundation.exit(2)
        }

        let volume = try volume(at: positional[0])
        let node = try volume.node(at: positional[1])
        let count = length ?? Int(node.size)
        let data = try volume.read(node, offset: offset, length: count)
        FileHandle.standardOutput.write(data)
    }

    private static func printUsage() {
        let text = """
        usage:
          zipfs ls <archive.zip> [path]
          zipfs stat <archive.zip> <path>
          zipfs cat <archive.zip> <path>
          zipfs read <archive.zip> <path> [--offset N] [--length N]
        """
        FileHandle.standardError.write(Data(text.utf8 + Data("\n".utf8)))
    }
}
