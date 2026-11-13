import Foundation
import RamDiskCore

public enum RamDiskCommandLine {
    static let usage = """
    ramdisk: control the RamDisk app from a terminal.

      ramdisk status [--json]     Show the disk and memory state
      ramdisk mount               Create and mount the RAM disk
      ramdisk eject [--force]     Eject the RAM disk
      ramdisk reclaim             Make a new disk with the same files, to return memory to macOS
      ramdisk path                Print the mount path
      ramdisk workspace [name]    Create a workspace directory and print its path
      ramdisk connect <agent>     Add the RamDisk MCP server to an agent: claude, codex, or opencode
      ramdisk disconnect <agent>  Remove the RamDisk MCP server from an agent
      ramdisk mcp                 Run the MCP server on stdio
    """

    public static func main() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"

        // launchd starts the helper without arguments and sets this variable to the job label.
        let isLaunchdJob = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == RamDiskConstants.machService
        if command == "agent" || (arguments.isEmpty && isLaunchdJob) {
            runAgent()
        }

        Task {
            let code = await run(command, Array(arguments.dropFirst()))
            exit(code)
        }
        dispatchMain()
    }

    private static func runAgent() -> Never {
        let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        let core = HelperCore(binaryPath: binary)
        let listener = HelperListener(core: core)

        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            Task {
                await core.shutdown()
                exit(0)
            }
        }
        terminate.resume()

        Task {
            await core.start()
            listener.resume()
        }
        withExtendedLifetime(terminate) {
            dispatchMain()
        }
    }

    private static func run(_ command: String, _ arguments: [String]) async -> Int32 {
        let helper = HelperConnection()
        do {
            switch command {
            case "mcp":
                await MCPServer(backend: helper).run()
            case "status":
                let status = try await helper.status()
                if arguments.contains("--json") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    print(String(decoding: try encoder.encode(status), as: UTF8.self))
                } else {
                    print(summary(status))
                }
            case "mount":
                print(try await helper.mountedRoot())
            case "eject":
                try await helper.run(.eject(force: arguments.contains("--force")))
            case "reclaim":
                try await helper.run(.reclaimMemory)
            case "path":
                guard let path = try await helper.status().disk.mountPath else {
                    throw DiskError.notMounted
                }
                print(path)
            case "workspace":
                let root = try await helper.mountedRoot()
                let owner = MCPServer.ownerFolder(clientName: nil, environment: ProcessInfo.processInfo.environment)
                print(try Workspaces.create(root: root, owner: owner, name: arguments.first))
            case "connect", "disconnect":
                guard let kind = AgentKind.allCases.first(where: { $0.folderName == arguments.first }), kind != .t3Code else {
                    print(usage)
                    return 64
                }
                try await helper.run(.setAgentConnected(kind, command == "connect"))
            default:
                print(usage)
                return command == "help" || command == "--help" ? 0 : 64
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("ramdisk: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func summary(_ status: HelperStatus) -> String {
        var lines: [String] = []
        if let path = status.disk.mountPath {
            lines.append("\(path)  \(ByteFormat.string(status.disk.used)) of \(ByteFormat.string(status.disk.capacity)) used, holds \(ByteFormat.string(status.disk.memoryHeld)) of memory")
            for usage in status.disk.categories where usage.bytes > 0 {
                lines.append("  \(usage.category.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(ByteFormat.string(usage.bytes))")
            }
        } else {
            lines.append("The RAM disk is not mounted.")
        }
        lines.append("Memory  \(ByteFormat.string(status.memory.used)) of \(ByteFormat.string(status.memory.total)) used, pressure \(status.memory.pressure.rawValue)")
        return lines.joined(separator: "\n")
    }
}
