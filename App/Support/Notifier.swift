import RamDiskCore
import UserNotifications

/// Posts one notification when the disk goes above its limit and one when the memory pressure rises.
@MainActor
final class Notifier {
    private var isDiskAlertActive = false
    private var lastPressure = MemoryPressure.normal
    private var didRequestAuthorization = false

    func evaluate(_ status: HelperStatus) {
        let configuration = status.configuration
        let disk = status.disk

        if configuration.diskAlertPercent > 0, disk.isMounted, disk.capacity > 0 {
            let percent = Int(Double(disk.used) / Double(disk.capacity) * 100)
            if percent >= configuration.diskAlertPercent, !isDiskAlertActive {
                isDiskAlertActive = true
                post(
                    id: "disk-full",
                    title: "The RAM disk is \(percent)% full",
                    body: "\(ByteFormat.string(disk.free)) is free. Clear temporary files or caches from the menu bar."
                )
            } else if percent < configuration.diskAlertPercent - 5 {
                isDiskAlertActive = false
            }
        } else {
            isDiskAlertActive = false
        }

        let pressure = status.memory.pressure
        if configuration.memoryAlerts, pressure != lastPressure, pressure != .normal, disk.isMounted {
            post(
                id: "memory-pressure",
                title: pressure == .critical ? "Memory pressure is critical" : "Memory pressure is high",
                body: "The RAM disk holds \(ByteFormat.string(disk.used)). Clear it or eject it to free memory."
            )
        }
        lastPressure = pressure
    }

    private func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if didRequestAuthorization {
            center.add(request)
            return
        }
        didRequestAuthorization = true
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }
}
