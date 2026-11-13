import AppKit
import SwiftUI

/// A borderless panel in place of `NSPopover`, so the panel draws its own glass card without the popover arrow.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupPanelController {
    private static let menuBarGap: CGFloat = 6
    private static let screenEdgeInset: CGFloat = 8
    /// The glow and the embers draw outside the card, so the hosting view is larger than the card by this margin.
    static let bleed: CGFloat = 24
    /// The status item click that closes the panel must not open it again.
    private static let reopenSuppression: TimeInterval = 0.25

    private let panel: PopupPanel
    private let hostingController: NSHostingController<AnyView>
    private let onDismiss: () -> Void
    private var globalMonitor: Any?
    private var dismissedAt = Date.distantPast
    private var anchorFrame = NSRect.zero

    var isVisible: Bool { panel.isVisible }
    var wasJustDismissed: Bool { Date().timeIntervalSince(dismissedAt) < Self.reopenSuppression }

    init<Content: View>(content: Content, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        hostingController = NSHostingController(rootView: AnyView(content.padding(Self.bleed)))
        hostingController.sizingOptions = [.preferredContentSize]

        panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 548, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinTopEdge() }
        }
    }

    func show(below anchor: NSRect) {
        anchorFrame = anchor
        panel.setContentSize(hostingController.view.fittingSize)
        pinTopEdge()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installGlobalMonitor()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        dismissedAt = Date()
        removeGlobalMonitor()
        panel.orderOut(nil)
        onDismiss()
    }

    /// AppKit keeps the bottom-left corner fixed on a resize. The panel must grow down from the menu bar.
    private func pinTopEdge() {
        guard anchorFrame != .zero else { return }
        let size = panel.frame.size
        var origin = NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.minY - size.height - Self.menuBarGap + Self.bleed
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let inset = Self.screenEdgeInset - Self.bleed
            origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - size.width - inset)
            origin.y = max(origin.y, visible.minY + inset)
        }
        panel.setFrameOrigin(origin)
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeGlobalMonitor() {
        guard let globalMonitor else { return }
        NSEvent.removeMonitor(globalMonitor)
        self.globalMonitor = nil
    }
}
