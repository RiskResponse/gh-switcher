import AppKit
import SwiftUI

@main
struct GHSwitchApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            FlyoutView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                if let title = model.menuBarTitle { Text(title) }
            }
        }
        .menuBarExtraStyle(.window)

        Window("GitHub Accounts", id: "manage") {
            ManageView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also set via LSUIElement in the bundle; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}
