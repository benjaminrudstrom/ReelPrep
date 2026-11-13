import AppKit
import SwiftUI
import ReelUI

/// ReelPrep: drop clips, a song and the logo; cut on the beat; export an FCPXML to Final Cut Pro.
/// Build the bundle with scripts/make_app.sh. Files given as arguments (or opened from Finder,
/// or dropped on the Dock icon) land on the start screen.
@main
struct ReelPrepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var project = AppDelegate.project

    init() {
        // File paths after the program name are ReelPrep's to add. Left to AppKit they become "open file"
        // events, and SwiftUI then opens no window at all (seen 2026-11-10).
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    /// The user's preferred layout (2026-11-10): nearly the screen's width, about 2.2 : 1.
    static var defaultWindowSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1728, height: 1080)
        let width = min(screen.width * 0.96, 1900)
        let height = min(max(width / 2.2, 680), screen.height * 0.92)
        return CGSize(width: width, height: height)
    }

    var body: some Scene {
        WindowGroup("ReelPrep") {
            RootView(project: project)
                .frame(minWidth: 1100, minHeight: 640)
                .task {
                    let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
                    if !files.isEmpty {
                        await project.drop(files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
                    }
                }
        }
        .defaultSize(ReelPrepApp.defaultWindowSize)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let project = ReelProject()

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await AppDelegate.project.drop(urls) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
