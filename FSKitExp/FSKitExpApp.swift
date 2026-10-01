import AppKit
import SwiftUI

@main
struct FSKitExpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ZipFS", systemImage: "doc.zipper") {
            ContentView()
                .environment(appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await viewModel.remountExistingOnLaunch()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel.refreshModules()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel.unmountAllOnTerminate()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.unmountAllOnTerminate()
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
