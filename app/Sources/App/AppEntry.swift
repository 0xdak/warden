import SwiftUI
import AppKit
import GuardCore

@main
struct GuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            AppModel.shared.start()
            if !AppModel.shared.onboardingDone || CommandLine.arguments.contains("--show-window") { MainWindow.show() }
        }
    }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

/// The dashboard window (plain AppKit window hosting SwiftUI, so it can be opened from anywhere).
@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(_ screen: Screen? = nil) {
        if let s = screen { AppModel.shared.screen = s }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = Brand.appName
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 880, height: 580)
            w.contentViewController = NSHostingController(rootView: RootView().environment(AppModel.shared))
            w.setContentSize(NSSize(width: 1020, height: 680))
            w.center()
            w.setFrameAutosaveName("\(Brand.identifierPrefix).main")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
