import AppKit
import Foundation
import FSKit
import Observation
import UniformTypeIdentifiers

struct MountedVolume: Identifiable, Hashable {
    let id: UUID
    let zipURL: URL
    let mountPoint: URL

    init(zipURL: URL, mountPoint: URL) {
        self.id = UUID()
        self.zipURL = zipURL
        self.mountPoint = mountPoint
    }
}

@Observable
@MainActor
final class ViewModel {
    static let extensionBundleID = "app.the-alchemist.ZipFSKitExp.FSKitExpExtension"

    private var client: FSClient?
    private var pollingTask: Task<Void, Never>?

    private(set) var modules: [FSModuleIdentity] = []
    private(set) var mounts: [MountedVolume] = []
    private(set) var isPollingModules = false

    var zipPath: String = ""
    var isMounting = false
    var errorMessage: String?
    var errorDetails: String?
    var errorSuggestsEnableExtension = false

    var ownModule: FSModuleIdentity? {
        modules.first { $0.bundleIdentifier == Self.extensionBundleID }
    }

    var isModuleRegistered: Bool {
        ownModule != nil
    }

    var isExtensionEnabled: Bool {
        ownModule?.isEnabled ?? false
    }

    var needsOnboarding: Bool {
        !isExtensionEnabled
    }

    init() {
        client = FSClient.shared
        refreshModules()
    }

    func refreshModules() {
        client?.fetchInstalledExtensions { modules, _ in
            Task { @MainActor in
                if let modules {
                    self.modules = modules
                }
            }
        }
    }

    func startModulePolling() {
        guard pollingTask == nil else { return }
        isPollingModules = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshModules()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopModulePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPollingModules = false
    }

    func openExtensionSettings() {
        ExtensionSettings.openFileSystemExtensions()
        refreshModules()
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            zipPath = url.path
        }
    }

    func mountSelected() async {
        let path = zipPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            present(MountError(message: "Invalid input", details: "Please select a ZIP archive to mount"))
            return
        }
        await mountAndReveal(URL(fileURLWithPath: path), reveal: true)
    }

    func mountAndReveal(_ zipURL: URL, reveal: Bool = true) async {
        zipPath = zipURL.path
        isMounting = true
        clearError()
        defer { isMounting = false }

        pruneStaleMounts()
        if let existing = mounts.first(where: { ZipMounter.isSameFile($0.zipURL, zipURL) }) {
            if reveal {
                self.reveal(existing)
            }
            return
        }

        guard isExtensionEnabled else {
            presentExtensionDisabledError()
            return
        }

        do {
            let mountPoint = try ZipMounter.mount(zipURL: zipURL)
            let volume = adopt(zipURL: zipURL, mountPoint: mountPoint)
            if reveal {
                self.reveal(volume)
            }
        } catch let error as MountError {
            present(error)
        } catch {
            present(MountError(message: "Unable to mount archive", details: error.localizedDescription))
        }
    }

    func unmount(_ volume: MountedVolume) {
        do {
            try ZipMounter.unmount(mountPoint: volume.mountPoint)
            mounts.removeAll { $0.id == volume.id }
        } catch let error as MountError {
            present(error)
        } catch {
            present(MountError(message: "Unable to unmount", details: error.localizedDescription))
        }
    }

    func reveal(_ volume: MountedVolume) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.mountPoint.path)
    }

    private func pruneStaleMounts() {
        mounts.removeAll { !ZipMounter.isMounted($0.mountPoint) }
    }

    private func adopt(zipURL: URL, mountPoint: URL) -> MountedVolume {
        if let existing = mounts.first(where: {
            ZipMounter.isSameFile($0.mountPoint, mountPoint) || ZipMounter.isSameFile($0.zipURL, zipURL)
        }) {
            return existing
        }
        let volume = MountedVolume(zipURL: zipURL, mountPoint: mountPoint)
        mounts.append(volume)
        return volume
    }

    private func clearError() {
        errorMessage = nil
        errorDetails = nil
        errorSuggestsEnableExtension = false
    }

    private func presentExtensionDisabledError() {
        present(
            MountError(
                message: "File System Extension is disabled",
                details: "Enable FSKitExpExtension in System Settings → General → Login Items & Extensions → File System Extensions, then try again."
            ),
            suggestsEnableExtension: true
        )
    }

    private func present(_ error: MountError, suggestsEnableExtension: Bool? = nil) {
        errorMessage = error.message
        errorDetails = error.details
        errorSuggestsEnableExtension = suggestsEnableExtension
            ?? ZipMounter.suggestsExtensionDisabled(details: error.details)
    }
}
