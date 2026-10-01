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
    var fileSystemType: String
}

enum ZipMounter {
    static let fileSystemType = "MyFS"

    static func suggestsExtensionDisabled(details: String) -> Bool {
        if isResourceBusy(details) || isOperationNotPermitted(details) {
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

    static func isOperationNotPermitted(_ details: String) -> Bool {
        details.localizedCaseInsensitiveContains("operation not permitted")
    }

    /// FSKit can cache a mount path after a failed unmount and reject the same
    /// directory with NSFileWriteFileExistsError until reboot.
    static func isStaleMountPoint(_ details: String) -> Bool {
        details.localizedCaseInsensitiveContains("couldn’t be saved because a file with the same name already exists")
            || details.localizedCaseInsensitiveContains("couldn't be saved because a file with the same name already exists")
    }

    static func shouldFallBackFromPreferredMount(_ details: String) -> Bool {
        isOperationNotPermitted(details)
            || isStaleMountPoint(details)
            || details.localizedCaseInsensitiveContains("permission")
    }

    static func isBesideArchive(_ mountPoint: URL, zipURL: URL) -> Bool {
        canonicalPath(mountPoint.deletingLastPathComponent())
            == canonicalPath(zipURL.deletingLastPathComponent())
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
        ourMounts().first { isSameFile($0.source, zipURL) }
    }

    static func ourMounts() -> [SystemMount] {
        allMounts().filter { $0.fileSystemType == fileSystemType }
    }

    static func mount(zipURL: URL) throws -> URL {
        let zipURL = zipURL.resolvingSymlinksInPath().standardizedFileURL
        if let existing = existingMount(for: zipURL) {
            return present(existing.mountPoint, beside: zipURL)
        }

        let preferred = try siblingMountPointURL(for: zipURL)
        if !blocksFileSystemMounts(in: zipURL.deletingLastPathComponent()),
           !blocksFileSystemMounts(in: preferred) {
            do {
                return present(try mount(zipURL: zipURL, onto: preferred), beside: zipURL)
            } catch let error as MountError where shouldFallBackFromPreferredMount(error.details) {
                removeEmptyMountPoint(preferred)
            }
        }

        do {
            var fallback = try fallbackMountPointURL(for: zipURL)
            do {
                let real = try mount(zipURL: zipURL, onto: fallback)
                return present(real, beside: zipURL)
            } catch let error as MountError where isStaleMountPoint(error.details) {
                removeEmptyMountPoint(fallback)
                fallback = try fallbackMountPointURL(for: zipURL, forceUnique: true)
                let real = try mount(zipURL: zipURL, onto: fallback)
                return present(real, beside: zipURL)
            }
        } catch let error as MountError where isOperationNotPermitted(error.details) {
            throw MountError(
                message: "Unable to mount archive",
                details: "macOS does not allow file systems to be mounted in this folder."
            )
        }
    }

    private static func mount(zipURL: URL, onto mountPoint: URL) throws -> URL {
        if blocksFileSystemMounts(in: mountPoint)
            || blocksFileSystemMounts(in: mountPoint.deletingLastPathComponent()) {
            throw MountError(
                message: "Unable to mount archive",
                details: "The operation couldn’t be completed. Operation not permitted"
            )
        }
        try prepareMountPoint(mountPoint)

        let result = try run(
            "/sbin/mount",
            arguments: ["-F", "-t", fileSystemType, zipURL.path, mountPoint.path]
        )
        if result.status != 0 {
            removeEmptyMountPoint(mountPoint)
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

    static func unmount(mountPoint: URL, zipURL: URL? = nil, force: Bool = false) throws {
        let real = URL(fileURLWithPath: canonicalPath(mountPoint), isDirectory: true)
        // Drop the sibling symlink first so Finder is not holding the volume busy.
        removeSiblingLink(presented: mountPoint, zipURL: zipURL, realMount: real)
        var result = try run("/sbin/umount", arguments: [real.path])
        if result.status != 0, force {
            result = try run("/sbin/umount", arguments: ["-f", real.path])
        }
        if result.status != 0 {
            throw MountError(
                message: "Unable to unmount",
                details: result.error.isEmpty ? result.output : result.error
            )
        }
        removeEmptyMountPoint(real)
        removeLegacyTempMountParent(real)
    }

    /// Best-effort teardown of every MyFS volume, including sibling symlinks.
    static func unmountAll() {
        for volume in ourMounts() {
            try? unmount(mountPoint: volume.mountPoint, zipURL: volume.source, force: true)
        }
    }

    private static func archiveMountName(for zipURL: URL) throws -> String {
        let name = zipURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else {
            throw MountError(
                message: "Failed to create mount point",
                details: "The archive name is empty."
            )
        }
        return name
    }

    /// Sibling of the zip, named after the archive without its extension.
    /// `Photos.zip` → `Photos/` next to the zip.
    private static func siblingMountPointURL(for zipURL: URL) throws -> URL {
        let name = try archiveMountName(for: zipURL)
        let mountPoint = zipURL
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: mountPoint.path),
           isSameFile(mountPoint, zipURL) {
            throw MountError(
                message: "Failed to create mount point",
                details: "The archive has no extension, so a folder cannot share its name."
            )
        }
        return mountPoint
    }

    /// When the real mount is not next to the zip (Downloads, stale path, …),
    /// put a symlink beside the archive so Finder still shows a sibling folder.
    private static func present(_ realMount: URL, beside zipURL: URL) -> URL {
        guard let sibling = try? siblingMountPointURL(for: zipURL) else {
            return realMount
        }
        if canonicalPath(realMount) == canonicalPath(sibling) {
            return realMount
        }
        if installSiblingLink(at: sibling, destination: realMount) {
            return sibling
        }
        return realMount
    }

    private static func installSiblingLink(at link: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: link.path) {
            if resolves(link, to: destination) {
                return true
            }
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try? fileManager.removeItem(at: link)
            } else if isEffectivelyEmptyDirectory(link), !isMounted(link) {
                try? fileManager.removeItem(at: link)
            } else {
                return false
            }
        }
        do {
            try fileManager.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: canonicalPath(destination)
            )
            return true
        } catch {
            return false
        }
    }

    private static func removeSiblingLink(presented: URL, zipURL: URL?, realMount: URL) {
        var candidates = [presented]
        if let zipURL, let sibling = try? siblingMountPointURL(for: zipURL) {
            candidates.append(sibling)
        }
        let fileManager = FileManager.default
        var seen = Set<String>()
        for url in candidates where seen.insert(url.path).inserted {
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
                continue
            }
            if resolves(url, to: realMount) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func resolves(_ link: URL, to destination: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let resolved: URL
        if dest.hasPrefix("/") {
            resolved = URL(fileURLWithPath: dest)
        } else {
            resolved = link.deletingLastPathComponent().appendingPathComponent(dest)
        }
        return canonicalPath(resolved) == canonicalPath(destination)
    }
    private static func fallbackMountPointURL(for zipURL: URL, forceUnique: Bool = false) throws -> URL {
        let name = try archiveMountName(for: zipURL)
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ZipFSKitExp", isDirectory: true)
        .appendingPathComponent("Mounts", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw MountError(
                message: "Failed to create mount point",
                details: error.localizedDescription
            )
        }

        let preferred = root.appendingPathComponent(name, isDirectory: true)
        if forceUnique || FileManager.default.fileExists(atPath: preferred.path) {
            return root.appendingPathComponent(
                "\(name)-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        }
        return preferred
    }

    /// TCC blocks mounting a file system *into* these folders (reading a zip from them is fine).
    private static func blocksFileSystemMounts(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        let folders: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .desktopDirectory,
            .documentDirectory,
            .moviesDirectory,
            .musicDirectory,
            .picturesDirectory,
        ]
        var blocked: [URL] = folders.compactMap {
            fileManager.urls(for: $0, in: .userDomainMask).first
        }
        let home = fileManager.homeDirectoryForCurrentUser
        blocked.append(home.appendingPathComponent("Library/Mobile Documents", isDirectory: true))
        blocked.append(home.appendingPathComponent("Library/CloudStorage", isDirectory: true))
        let blockedIDs = blocked.compactMap { fileIdentifier($0) }
        let blockedPaths = Set(blocked.map { canonicalPath($0) })

        var current = directory.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<String>()
        while seen.insert(canonicalPath(current)).inserted {
            if let id = fileIdentifier(current), blockedIDs.contains(where: { $0.isEqual(id) }) {
                return true
            }
            if blockedPaths.contains(canonicalPath(current)) {
                return true
            }
            if blockedHomeFolderNames.contains(current.lastPathComponent) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if canonicalPath(parent) == canonicalPath(current) {
                break
            }
            current = parent
        }
        return false
    }

    private static let blockedHomeFolderNames: Set<String> = [
        "Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures",
    ]

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static let ignorableDirectoryEntries: Set<String> = [".DS_Store", ".localized"]

    private static func prepareMountPoint(_ mountPoint: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MountError(
                    message: "Failed to create mount point",
                    details: "A file already exists at \(mountPoint.path)."
                )
            }
            if isMounted(mountPoint) {
                throw MountError(
                    message: "Failed to create mount point",
                    details: "Something else is already mounted at \(mountPoint.path)."
                )
            }
            guard isEffectivelyEmptyDirectory(mountPoint) else {
                throw MountError(
                    message: "Mount folder already exists",
                    details: "A folder named “\(mountPoint.lastPathComponent)” already exists at \(mountPoint.path). Move or rename it, then try again."
                )
            }
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: mountPoint,
                withIntermediateDirectories: false
            )
        } catch {
            throw MountError(
                message: "Failed to create mount point",
                details: error.localizedDescription
            )
        }
    }

    private static func isEffectivelyEmptyDirectory(_ url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return contents.allSatisfy { ignorableDirectoryEntries.contains($0) }
    }

    private static func removeEmptyMountPoint(_ mountPoint: URL) {
        guard isEffectivelyEmptyDirectory(mountPoint) else { return }
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Old builds mounted at `tmpdir/UUID/_ZipFSKitExp`. Unmount removes the
    /// inner folder; drop the UUID parent too if it is empty.
    private static func removeLegacyTempMountParent(_ mountPoint: URL) {
        guard mountPoint.lastPathComponent == "_ZipFSKitExp" else { return }
        let parent = mountPoint.deletingLastPathComponent()
        guard isEffectivelyEmptyDirectory(parent) else { return }
        try? FileManager.default.removeItem(at: parent)
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
            let type = fsString(fs.f_fstypename)
            guard !source.isEmpty, !mountOn.isEmpty else {
                return nil
            }
            return SystemMount(
                source: urlFromMountSource(source),
                mountPoint: URL(fileURLWithPath: mountOn),
                fileSystemType: type
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
