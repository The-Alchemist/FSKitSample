import Darwin
import Foundation

struct MountError: Error, LocalizedError {
    var message: String
    var details: String

    var errorDescription: String? { message }
    var failureReason: String? { details }
}

struct CommandResult {
    var status: Int32
    var output: String
    var error: String
}

struct SystemMount: Equatable {
    var source: URL
    var mountPoint: URL
}

enum ZipMounter {
    static let fileSystemType = "MyFS"

    static func suggestsExtensionDisabled(details: String) -> Bool {
        if isResourceBusy(details) {
            return false
        }
        let normalized = details.lowercased()
        return normalized.contains("unable to invoke task")
            || normalized.contains("module") && normalized.contains("disabled")
            || normalized.contains("no extension with fsshortname")
            || normalized.contains("file system named")
    }

    static func isResourceBusy(_ details: String) -> Bool {
        details.localizedCaseInsensitiveContains("resource busy")
            || details.localizedCaseInsensitiveContains("device busy")
    }

    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if let leftID = fileIdentifier(lhs), let rightID = fileIdentifier(rhs) {
            return leftID.isEqual(rightID)
        }
        return canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func isMounted(_ mountPoint: URL) -> Bool {
        var fs = statfs()
        guard statfs(canonicalPath(mountPoint), &fs) == 0 else {
            return false
        }
        return canonicalPath(URL(fileURLWithPath: fsString(fs.f_mntonname))) == canonicalPath(mountPoint)
    }

    static func existingMount(for zipURL: URL) -> SystemMount? {
        allMounts().first { isSameFile($0.source, zipURL) }
    }

    static func mount(zipURL: URL) throws -> URL {
        if let existing = existingMount(for: zipURL) {
            return existing.mountPoint
        }

        var mountPoint = FileManager.default.temporaryDirectory
        mountPoint.appendPathComponent(UUID().uuidString, isDirectory: true)
        mountPoint.appendPathComponent("_ZipFSKitExp", isDirectory: true)
        let mountRoot = mountPoint.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: mountPoint,
                withIntermediateDirectories: true
            )
        } catch {
            throw MountError(
                message: "Failed to create mount point",
                details: error.localizedDescription
            )
        }

        let result = try run(
            "/sbin/mount",
            arguments: ["-F", "-t", fileSystemType, zipURL.path, mountPoint.path]
        )
        if result.status != 0 {
            try? FileManager.default.removeItem(at: mountRoot)
            let details = result.error.isEmpty ? result.output : result.error
            if isResourceBusy(details), let existing = existingMount(for: zipURL) {
                return existing.mountPoint
            }
            throw MountError(
                message: suggestsExtensionDisabled(details: details)
                    ? "File System Extension is disabled"
                    : "Unable to mount archive",
                details: details
            )
        }
        return mountPoint
    }

    static func unmount(mountPoint: URL) throws {
        let result = try run("/sbin/umount", arguments: [mountPoint.path])
        if result.status != 0 {
            throw MountError(
                message: "Unable to unmount",
                details: result.error.isEmpty ? result.output : result.error
            )
        }
        try? FileManager.default.removeItem(at: mountPoint.deletingLastPathComponent())
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func allMounts() -> [SystemMount] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else {
            return []
        }
        return (0..<Int(count)).compactMap { index in
            let fs = pointer[index]
            let source = fsString(fs.f_mntfromname)
            let mountOn = fsString(fs.f_mntonname)
            guard !source.isEmpty, !mountOn.isEmpty else {
                return nil
            }
            return SystemMount(
                source: urlFromMountSource(source),
                mountPoint: URL(fileURLWithPath: mountOn)
            )
        }
    }

    private static func urlFromMountSource(_ source: String) -> URL {
        if source.hasPrefix("file:"), let url = URL(string: source), url.isFileURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: source)
    }

    private static func fsString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func fileIdentifier(_ url: URL) -> (any NSObjectProtocol & NSCopying)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    static func run(_ path: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output, error: error)
    }
}
