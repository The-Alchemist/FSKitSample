import AppKit
import Foundation

enum ExtensionSettings {
    /// Direct link to File System Extensions in System Settings (macOS 26).
    private static let fileSystemExtensionsURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule"
    )!

    /// Fallback when the deep link above stops working.
    private static let loginItemsExtensionsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems"
    )!

    @MainActor
    static func openFileSystemExtensions() {
        if NSWorkspace.shared.open(fileSystemExtensionsURL) {
            return
        }
        _ = NSWorkspace.shared.open(loginItemsExtensionsURL)
    }
}
