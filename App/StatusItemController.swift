import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panelController: PopupPanelController?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("RamDisk")
        panelController = PopupPanelController(
            content: PanelView(model: model, dismiss: { [weak self] in self?.panelController?.dismiss() }),
            onDismiss: { [weak self] in
                self?.statusItem.button?.highlight(false)
                self?.model.panelDidClose()
            }
        )
        observeIcon()
    }

    func showPanel() {
        guard let button = statusItem.button, let window = button.window, let panelController, !panelController.isVisible else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        button.highlight(true)
        model.panelDidOpen()
        panelController.show(below: anchor)
    }

    @objc private func togglePanel() {
        guard let panelController else { return }
        if panelController.isVisible {
            panelController.dismiss()
        } else if !panelController.wasJustDismissed {
            showPanel()
        }
    }

    private func observeIcon() {
        withObservationTracking {
            let image = NSImage(named: model.disk.isMounted ? "MenuBarIconMounted" : "MenuBarIcon")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            statusItem.button?.image = image
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }
}
