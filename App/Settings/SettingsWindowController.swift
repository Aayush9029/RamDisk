import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let size = CGSize(width: SettingsLayout.windowWidth, height: 520)
            let new = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            new.title = "RamDisk Settings"
            new.titleVisibility = .hidden
            new.titlebarAppearsTransparent = true
            new.toolbarStyle = .unified
            new.contentView = NSHostingView(rootView: SettingsView(model: model))
            new.contentMinSize = CGSize(width: size.width, height: 420)
            new.contentMaxSize = CGSize(width: size.width, height: .greatestFiniteMagnitude)
            new.setContentSize(size)
            new.isReleasedWhenClosed = false
            new.delegate = self
            new.center()
            window = new
        }
        model.isSettingsVisible = true
        model.wake()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.isSettingsVisible = false
    }
}
