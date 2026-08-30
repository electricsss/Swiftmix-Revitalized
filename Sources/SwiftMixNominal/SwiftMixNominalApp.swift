import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: (() -> Bool)?

    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate?() == false ? .terminateCancel : .terminateNow
    }

    @MainActor
    func showSettings(model: AppModel) {
        model.start()

        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 820),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "SwiftMix Nominal Lock Settings"
            newWindow.contentViewController = NSHostingController(
                rootView: SettingsView(model: model)
            )
            newWindow.contentMinSize = NSSize(width: 640, height: 700)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct SwiftMixNominalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, openSettings: showSettings)
                .onAppear {
                    configureLifecycleSafety()
                    model.start()
                }
        } label: {
            Image(systemName: "slider.vertical.3")
                .symbolRenderingMode(.monochrome)
                .opacity(model.menuBarIconIsActive ? 1.0 : 0.35)
                .accessibilityLabel(model.statusLine)
        }
        .menuBarExtraStyle(.menu)
    }

    private func showSettings() {
        configureLifecycleSafety()
        appDelegate.showSettings(model: model)
    }

    private func configureLifecycleSafety() {
        appDelegate.shouldTerminate = { [weak model] in
            guard let model else { return true }
            if model.hasUnsafeActiveMode {
                model.noteQuitBlockedDuringActiveControl()
                return false
            }
            return true
        }
    }
}
