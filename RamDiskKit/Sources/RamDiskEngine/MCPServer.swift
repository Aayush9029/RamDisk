import Foundation
import RamDiskCore

public protocol HelperBackend: Sendable {
    func status() async throws -> HelperStatus
    func run(_ command: HelperCommand) async throws
}

extension HelperConnection: HelperBackend {}

public enum MountError: LocalizedError {
    case timedOut

    public var errorDescription: String? {
        "The RAM disk did not mount. Open the RamDisk app and create the disk."
    }
}

extension HelperBackend {
    /// Mounts the disk when it is not mounted, and returns the mount path.
    public func mountedRoot() async throws -> String {
        if let path = try await status().disk.mountPath { return path }
        try await run(.createDisk)
        for _ in 0..<40 {
            if let path = try await status().disk.mountPath { return path }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MountError.timedOut
    }
}

/// A Model Context Protocol server on stdio: one JSON-RPC message for each line.
public struct MCPServer: Sendable {
    static let instructions = """
    RamDisk gives this Mac a disk that lives in memory. Use it for files that are cheap to make again: build output, \
    dependency caches, temporary clones, and scratch files of subagents. Reads and writes there do not touch the SSD.

    Call ramdisk_create_workspace to get a directory, and work in that directory. The disk loses its contents at eject \
    or restart, so keep source code and results that matter on the normal disk. Call ramdisk_remove_workspace when the \
    work is done. Call ramdisk_status before a large write to see the free space.
    """

    let backend: any HelperBackend
    let environment: [String: String]
    private let owner = OwnerBox()

    public init(backend: any HelperBackend, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.backend = backend
        self.environment = environment
    }

    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let response = await handle(message),
                  let output = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
            else { continue }
            FileHandle.standardOutput.write(output + Data("\n".utf8))
        }
    }

    func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let parameters = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let client = (parameters["clientInfo"] as? [String: Any])?["name"] as? String
            owner.set(Self.ownerFolder(clientName: client, environment: environment))
            return result(id, [
                "protocolVersion": parameters["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": RamDiskConstants.mcpServerName, "title": "RamDisk", "version": "1.0.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            let name = parameters["name"] as? String ?? ""
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments)
                return result(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch let error as UnknownTool {
                return failure(id, code: -32602, message: "Unknown tool: \(error.name)")
            } catch {
                return result(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return failure(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    private struct UnknownTool: Error {
        var name: String
    }

    private static var tools: [[String: Any]] { [
        tool("ramdisk_status", "Reports the RAM disk mount path, capacity, free space, and the memory pressure of the Mac."),
        tool(
            "ramdisk_create_workspace",
            "Creates an empty directory on the RAM disk and returns its absolute path. Mounts the disk first when it is not mounted.",
            properties: ["name": ["type": "string", "description": "A short label for the directory, for example the task or repository name."]]
        ),
        tool("ramdisk_list_workspaces", "Lists the workspace directories on the RAM disk, newest first."),
        tool(
            "ramdisk_remove_workspace",
            "Deletes one workspace directory and its contents from the RAM disk.",
            properties: ["path": ["type": "string", "description": "The absolute path that ramdisk_create_workspace returned."]],
            required: ["path"]
        ),
    ] }

    private static func tool(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }

    private func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "ramdisk_status":
            let status = try await backend.status()
            return Self.json([
                "mounted": status.disk.isMounted,
                "path": status.disk.mountPath ?? NSNull(),
                "capacityBytes": status.disk.capacity,
                "freeBytes": status.disk.free,
                "free": ByteFormat.string(status.disk.free),
                "memoryPressure": status.memory.pressure.rawValue,
            ])
        case "ramdisk_create_workspace":
            let root = try await backend.mountedRoot()
            return try Workspaces.create(root: root, owner: owner.get(), name: arguments["name"] as? String)
        case "ramdisk_list_workspaces":
            guard let root = try await backend.status().disk.mountPath else { return "[]" }
            let formatter = ISO8601DateFormatter()
            return Self.json(Workspaces.list(root: root).map {
                ["path": $0.path, "owner": $0.owner, "modified": formatter.string(from: $0.modified)]
            })
        case "ramdisk_remove_workspace":
            guard let root = try await backend.status().disk.mountPath else { throw DiskError.notMounted }
            let path = arguments["path"] as? String ?? ""
            try Workspaces.remove(root: root, path: path)
            return "Removed \(path)"
        default:
            throw UnknownTool(name: name)
        }
    }

    /// T3 Code runs other agents, so its thread variable wins over the client name.
    static func ownerFolder(clientName: String?, environment: [String: String]) -> String {
        if environment["T3CODE_THREAD_ID"] != nil { return AgentKind.t3Code.folderName }
        let name = (clientName ?? "").lowercased()
        if name.contains("claude") { return AgentKind.claudeCode.folderName }
        if name.contains("codex") { return AgentKind.codex.folderName }
        if name.contains("opencode") { return AgentKind.openCode.folderName }
        if name.contains("t3") { return AgentKind.t3Code.folderName }
        return "other"
    }

    // MARK: - JSON-RPC

    private func result(_ id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func failure(_ id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private final class OwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var owner = "other"

    func set(_ new: String) { lock.withLock { owner = new } }
    func get() -> String { lock.withLock { owner } }
}
