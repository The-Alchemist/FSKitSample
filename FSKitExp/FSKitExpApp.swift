import AppKit
import SwiftUI

@main
struct FSKitExpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.viewModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ViewModel()

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel.refreshModules()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task {
                await viewModel.mountAndReveal(url)
            }
        }
    }

    func application(_ sender: NSApplication, open files: [String]) {
        application(sender, open: files.map { URL(fileURLWithPath: $0) })
    }
}
