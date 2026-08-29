import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: (() -> Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate?() == false ? .terminateCancel : .terminateNow
    }
}

@main
struct SwiftMixNominalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
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

        Settings {
            SettingsView(model: model)
                .onAppear {
                    configureLifecycleSafety()
                    model.start()
                }
        }
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
