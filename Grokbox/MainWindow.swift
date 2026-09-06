import AppKit
import SwiftUI

/// Brings the main window forward, creating one if the user closed it.
/// The main scene deliberately has no id (ADR-0016), so this goes through
/// AppKit: the same reopen path a Dock click uses, with File ▸ New Window as
/// the fallback.
@MainActor
enum MainWindow {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.className != "NSStatusBarWindow" && !($0 is NSPanel) && $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let delegate = NSApp.delegate, delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) == true {
            return
        }
        if let item = NSApp.mainMenu?.items.lazy.compactMap({ $0.submenu }).flatMap({ $0.items }).first(where: { $0.title.hasPrefix("New Window") }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
}
