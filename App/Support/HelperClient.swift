import AppKit
import Foundation
import RamDiskCore
import ServiceManagement

enum HelperRegistration: Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// The app side of the helper. Tests and previews replace the closures.
struct HelperClient: Sendable {
    var status: @Sendable () async throws -> HelperStatus
    var run: @Sendable (HelperCommand) async throws -> Void
    var registration: @Sendable () -> HelperRegistration
    var register: @Sendable () throws -> Void
    var unregister: @Sendable () async -> Void
    var openLoginItems: @Sendable () -> Void
    var bundledBuild: @Sendable () -> String
    var bundledPath: @Sendable () -> String
}

extension HelperClient {
    private static var bundledHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ramdisk-helper").resolvingSymlinksInPath().path
    }

    static var live: HelperClient {
        let connection = HelperConnection()
        nonisolated(unsafe) let service = SMAppService.agent(plistName: RamDiskConstants.agentPlistName)
        return HelperClient(
            status: { try await connection.status() },
            run: { try await connection.run($0) },
            registration: {
                switch service.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notFound: .notFound
                default: .notRegistered
                }
            },
            register: { try service.register() },
            unregister: {
                connection.invalidate()
                try? await service.unregister()
            },
            openLoginItems: { SMAppService.openSystemSettingsLoginItems() },
            bundledBuild: { RamDiskConstants.buildStamp(ofExecutableAt: bundledHelperPath) },
            bundledPath: { bundledHelperPath }
        )
    }
}
