import Foundation
import RamDiskCore
import Security

public final class HelperListener: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
    private let core: HelperCore
    private let listener: NSXPCListener

    public init(core: HelperCore) {
        self.core = core
        listener = NSXPCListener(machServiceName: RamDiskConstants.machService)
        super.init()
        // An ad hoc build has no team, and the requirement would then reject each client.
        if Self.ownTeamID() == RamDiskConstants.teamID {
            listener.setConnectionCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(RamDiskConstants.teamID)\""
            )
        }
        listener.delegate = self
    }

    public func resume() {
        listener.resume()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    public func status(reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(core.box.read())) ?? Data())
    }

    public func run(_ command: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let command = try? JSONDecoder().decode(HelperCommand.self, from: command) else {
            reply("The helper does not know this command. Update RamDisk.")
            return
        }
        if command != .rescan {
            core.box.isCancelRequested = true
        }
        Task {
            reply(await core.handle(command))
        }
    }

    private static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
