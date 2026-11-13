import Foundation
import RamDiskCore
import Testing

@testable import RamDiskEngine

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ramdisk-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Suite struct CodexConfigTests {
    let command = "/Users/me/Library/Application Support/RamDisk/bin/ramdisk"

    @Test func addKeepsOtherServersAndRemoveRestoresTheFile() {
        let original = """
        model = "gpt"

        [mcp_servers.xcode]
        command = "xcrun"
        """
        let added = CodexConfig.adding(to: original, command: command)
        #expect(added.hasPrefix(original))
        #expect(CodexConfig.contains(added, command: command))
        #expect(CodexConfig.adding(to: added, command: command) == added)
        #expect(CodexConfig.removing(from: added).trimmingCharacters(in: .newlines) == original)
    }

    @Test func removeDropsSubtablesAndKeepsLaterTables() {
        let text = """
        [mcp_servers.ramdisk]
        command = "/old/path"
        args = ["mcp"]

        [mcp_servers.ramdisk.env]
        A = "1"

        [mcp_servers.ramdisk_other]
        command = "keep"
        """
        let removed = CodexConfig.removing(from: text)
        #expect(!removed.contains("/old/path"))
        #expect(!removed.contains("A = \"1\""))
        #expect(removed.contains("[mcp_servers.ramdisk_other]\ncommand = \"keep\""))
    }

    @Test func addReplacesAStaleCommand() {
        let stale = CodexConfig.block(command: "/old/path")
        let updated = CodexConfig.adding(to: stale, command: command)
        #expect(!updated.contains("/old/path"))
        #expect(CodexConfig.contains(updated, command: command))
    }
}

@Suite struct AgentIntegrationTests {
    @Test func claudeConnectsEachProfileAndKeepsOtherServers() throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let main = home.appendingPathComponent(".claude.json")
        let profile = home.appendingPathComponent(".claude-profiles/work/.claude.json")
        try Data(#"{"numStartups": 4, "mcpServers": {"figma": {"command": "figma"}}}"#.utf8).write(to: main)
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile)

        let integrations = AgentIntegrations(home: home, command: "/bin/ramdisk")
        #expect(integrations.statuses().first { $0.kind == .claudeCode }?.isConnected == false)

        try integrations.setConnected(.claudeCode, true)
        let claude = try #require(integrations.statuses().first { $0.kind == .claudeCode })
        #expect(claude.isConnected)
        #expect(claude.detail == "2 of 2 profiles")

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: main)) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(root["numStartups"] as? Int == 4)
        #expect(servers["figma"] != nil)
        #expect((servers["ramdisk"] as? [String: Any])?["args"] as? [String] == ["mcp"])

        try integrations.setConnected(.claudeCode, false)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: main)) as? [String: Any])
        #expect((after["mcpServers"] as? [String: Any])?.keys.sorted() == ["figma"])
    }

    @Test func t3CodeFollowsClaudeAndCodex() throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in [".t3", ".codex"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let integrations = AgentIntegrations(home: home, command: "/bin/ramdisk")
        #expect(integrations.statuses().first { $0.kind == .t3Code }?.isConnected == false)
        try integrations.setConnected(.codex, true)
        let t3 = try #require(integrations.statuses().first { $0.kind == .t3Code })
        #expect(t3.isConnected)
        #expect(t3.detail == "Through Codex")
    }

    @Test func openCodeWritesALocalServerAndRejectsCommentedJSON() throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcp": {"proxyman": {"type": "local"}}}"#.utf8).write(to: file)
        let integrations = AgentIntegrations(home: home, command: "/bin/ramdisk")

        try integrations.setConnected(.openCode, true)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let servers = try #require(root["mcp"] as? [String: Any])
        #expect(servers["proxyman"] != nil)
        #expect((servers["ramdisk"] as? [String: Any])?["command"] as? [String] == ["/bin/ramdisk", "mcp"])
        #expect(integrations.statuses().first { $0.kind == .openCode }?.isConnected == true)

        try Data("{ // comment\n}".utf8).write(to: file)
        #expect(throws: IntegrationError.unreadable(file.resolvingSymlinksInPath().path)) {
            try integrations.setConnected(.openCode, true)
        }
    }

    @Test func aMissingAgentReportsNotInstalled() throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let integrations = AgentIntegrations(home: home, command: "/bin/ramdisk")
        #expect(integrations.statuses().allSatisfy { !$0.isInstalled && !$0.isConnected })
        #expect(throws: IntegrationError.notInstalled("Codex")) {
            try integrations.setConnected(.codex, true)
        }
    }
}

@Suite struct UsageScannerTests {
    @Test func scanSortsItemsIntoCategories() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        DiskManager.createFolders(root: root.path)
        try write(40_000, to: root.appendingPathComponent("agents/claude/big/a.bin"))
        try write(10_000, to: root.appendingPathComponent("agents/claude/small/a.bin"))
        try write(20_000, to: root.appendingPathComponent("agents/unknown/x/a.bin"))
        try write(20_000, to: root.appendingPathComponent("tmp/file.bin"))
        try write(20_000, to: root.appendingPathComponent("loose.bin"))
        try write(20_000, to: root.appendingPathComponent(".ramdisk"))

        let usage = try #require(UsageScanner.scan(root: root.path))
        let byCategory = Dictionary(uniqueKeysWithValues: usage.map { ($0.category, $0) })

        #expect(byCategory[.claudeCode]?.itemCount == 2)
        #expect(byCategory[.claudeCode]?.largestName == "big")
        #expect((byCategory[.claudeCode]?.bytes ?? 0) >= 50_000)
        #expect(byCategory[.temp]?.itemCount == 1)
        #expect(byCategory[.other]?.itemCount == 2)
        #expect(byCategory[.codex]?.bytes == 0)
    }

    @Test func aCancelledScanReturnsNoResult() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(100, to: root.appendingPathComponent("tmp/file.bin"))
        #expect(UsageScanner.scan(root: root.path, isCancelled: { true }) == nil)
    }
}

@Suite struct WorkspaceTests {
    @Test func slugKeepsOnlySafeCharacters() {
        #expect(Workspaces.slug("My Repo / feature#12") == "my-repo-feature-12")
        #expect(Workspaces.slug("../..") == "workspace")
        #expect(Workspaces.slug(nil) == "workspace")
    }

    @Test func removeRefusesPathsOutsideAWorkspace() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try Workspaces.create(root: root.path, owner: "codex", name: "Build Cache")
        #expect(path.hasPrefix(root.path + "/agents/codex/build-cache-"))
        #expect(Workspaces.list(root: root.path).map(\.path) == [path])

        for bad in [root.path, root.path + "/agents/codex", path + "/../../../tmp", "/etc"] {
            #expect(throws: WorkspaceError.self) {
                try Workspaces.remove(root: root.path, path: bad)
            }
        }
        try Workspaces.remove(root: root.path, path: path)
        #expect(Workspaces.list(root: root.path).isEmpty)
    }

    @Test func removeIdleKeepsRecentWorkspaces() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try Workspaces.create(root: root.path, owner: "claude", name: "old")
        let recent = try Workspaces.create(root: root.path, owner: "claude", name: "recent")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old)

        #expect(Workspaces.removeIdle(root: root.path, olderThan: 3600) == 1)
        #expect(Workspaces.list(root: root.path).map(\.path) == [recent])
    }
}

private actor FakeBackend: HelperBackend {
    var root: String?
    let mountRoot: String
    var commands: [HelperCommand] = []

    init(mountRoot: String, mounted: Bool) {
        self.mountRoot = mountRoot
        root = mounted ? mountRoot : nil
    }

    func status() -> HelperStatus {
        var status = HelperStatus()
        status.disk.isMounted = root != nil
        status.disk.mountPath = root
        status.disk.capacity = 1 << 30
        return status
    }

    func run(_ command: HelperCommand) {
        commands.append(command)
        if command == .createDisk { root = mountRoot }
    }
}

@Suite struct MCPServerTests {
    private func call(_ server: MCPServer, _ method: String, _ parameters: [String: Any] = [:]) async -> [String: Any]? {
        await server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": parameters])
    }

    private func text(_ response: [String: Any]?) -> String? {
        let result = response?["result"] as? [String: Any]
        return (result?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    @Test func createWorkspaceMountsTheDiskAndUsesTheClientFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend(mountRoot: root.path, mounted: false)
        let server = MCPServer(backend: backend, environment: [:])

        let hello = await call(server, "initialize", ["protocolVersion": "2025-03-26", "clientInfo": ["name": "codex-mcp-client"]])
        #expect((hello?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")

        let created = await call(server, "tools/call", ["name": "ramdisk_create_workspace", "arguments": ["name": "api tests"]])
        let path = try #require(text(created))
        #expect(path.hasPrefix(root.path + "/agents/codex/api-tests-"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await backend.commands == [.createDisk])

        let removed = await call(server, "tools/call", ["name": "ramdisk_remove_workspace", "arguments": ["path": path]])
        #expect((removed?["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aT3ThreadOwnsTheWorkspaceForAnyClient() {
        #expect(MCPServer.ownerFolder(clientName: "claude-code", environment: ["T3CODE_THREAD_ID": "x"]) == "t3code")
        #expect(MCPServer.ownerFolder(clientName: "claude-code", environment: [:]) == "claude")
        #expect(MCPServer.ownerFolder(clientName: "opencode", environment: [:]) == "opencode")
        #expect(MCPServer.ownerFolder(clientName: "cursor", environment: [:]) == "other")
    }

    @Test func protocolErrorsAndNotifications() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(backend: FakeBackend(mountRoot: root.path, mounted: true), environment: [:])

        #expect(await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let unknownMethod = await call(server, "resources/list")
        #expect((unknownMethod?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let unknownTool = await call(server, "tools/call", ["name": "nope"])
        #expect((unknownTool?["error"] as? [String: Any])?["code"] as? Int == -32602)
        let outside = await call(server, "tools/call", ["name": "ramdisk_remove_workspace", "arguments": ["path": "/etc"]])
        #expect((outside?["result"] as? [String: Any])?["isError"] as? Bool == true)
        let tools = await call(server, "tools/list")
        #expect(((tools?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 4)
    }
}

@Suite struct ConfigurationTests {
    @Test func sizeStaysInsidePhysicalMemory() {
        let memory: UInt64 = 16 << 30
        #expect(DiskConfiguration.clampedSize(64 << 30, physicalMemory: memory) == memory)
        #expect(DiskConfiguration.clampedSize(1, physicalMemory: memory) == DiskConfiguration.minimumSize)
        #expect(DiskConfiguration.defaultSize(physicalMemory: memory) == 4 << 30)
    }

    @Test func nameCannotEscapeTheVolumesFolder() {
        #expect(DiskConfiguration.sanitizedName("../../etc") == "etc")
        #expect(DiskConfiguration.sanitizedName("  ") == "RamDisk")
        #expect(DiskConfiguration.sanitizedName("Scratch Disk") == "Scratch Disk")
    }
}

@Suite struct BackingProcessTests {
    @Test func findsTheProcessOfTheRamDiskAndSkipsOtherImages() {
        let info = """
        framework       : 671.140.2
        ================================================
        image-path      : /Library/Developer/CoreSimulator/Images/A.dmg
        process ID      : 411
        /dev/disk5s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Volumes/RamDisk Other
        ================================================
        image-path      : ram://25165824
        mounting user   : me
        process ID      : 18511
        framework name  : DiskImages
        /dev/disk17\t\t
        /dev/disk18s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Volumes/RamDisk
        ================================================
        image-path      : ram://2048
        process ID      : 999
        /dev/disk21s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Volumes/Scratch
        """
        #expect(DiskManager.backingProcess(mountPath: "/Volumes/RamDisk", hdiutilInfo: info) == 18511)
        #expect(DiskManager.backingProcess(mountPath: "/Volumes/Scratch", hdiutilInfo: info) == 999)
        #expect(DiskManager.backingProcess(mountPath: "/Volumes/Missing", hdiutilInfo: info) == nil)
    }
}

@Suite struct SuggestionTests {
    private func status(_ change: (inout HelperStatus) -> Void) -> HelperStatus {
        var status = HelperStatus()
        status.disk.isMounted = true
        status.disk.capacity = 12 << 30
        change(&status)
        return status
    }

    @Test func theLargestRebuildableCategoryWins() {
        let suggestion = Suggestion.make(status: status {
            $0.disk[.temp].bytes = 200 << 20
            $0.disk[.caches].bytes = 900 << 20
            $0.disk[.claudeCode].bytes = 4 << 30
        }, clearing: nil)
        #expect(suggestion.action == .clear(.caches))
        #expect(suggestion.actionTitle == "Clear")
        #expect(suggestion.text.hasPrefix("Caches use 900 MB."))
    }

    @Test func smallCategoriesAndAgentWorkspacesAreNotSuggested() {
        let suggestion = Suggestion.make(status: status {
            $0.disk[.temp].bytes = 4 << 20
            $0.disk[.codex].bytes = 6 << 30
            $0.disk.used = 6 << 30
            $0.disk.memoryHeld = 6 << 30
        }, clearing: nil)
        #expect(suggestion.action == nil)
        #expect(suggestion.tone == .done)
    }

    @Test func heldMemoryOfDeletedFilesOffersAReclaim() {
        let idle = status {
            $0.disk.used = 1 << 30
            $0.disk.memoryHeld = 5 << 30
        }
        #expect(Suggestion.make(status: idle, clearing: nil).action == .reclaim)

        var pressured = idle
        pressured.memory.pressure = .warning
        pressured.disk[.caches].bytes = 900 << 20
        let suggestion = Suggestion.make(status: pressured, clearing: nil)
        #expect(suggestion.tone == .warning)
        #expect(suggestion.action == .reclaim)
    }

    @Test func aClearInProgressKeepsItsCategory() {
        let suggestion = Suggestion.make(status: status { $0.disk[.builds].bytes = 3 << 30 }, clearing: .temp)
        #expect(suggestion.action == .clear(.temp))
        #expect(suggestion.text == "Clearing temporary.")
    }
}
