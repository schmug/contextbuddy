import SwiftUI
import AppKit

@main
struct ContextBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No main window — menubar-only. The Settings scene exists only so
        // SwiftUI's App protocol is satisfied; we never present it.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Equivalent of LSUIElement = true at runtime. The bundled .app's
        // Info.plist also sets this for distribution; setting it here keeps
        // `swift run` from showing a Dock icon during development.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                self.menubar = try await MenubarController.create()
            } catch {
                FileHandle.standardError.write(
                    Data("ContextBuddy: failed to start: \(error)\n".utf8)
                )
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
