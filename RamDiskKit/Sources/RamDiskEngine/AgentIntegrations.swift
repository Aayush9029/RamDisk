import Foundation
import RamDiskCore

public enum IntegrationError: LocalizedError, Equatable {
    case unreadable(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "RamDisk cannot read \(path) as JSON. Add the MCP server by hand."
        case .notInstalled(let name): "\(name) is not installed on this Mac."
        }
    }
}

/// Adds and removes the RamDisk MCP server in the configuration of each coding agent.
public struct AgentIntegrations: Sendable {
    let home: URL
    let command: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, command: String) {
        self.home = home
        self.command = command
    }

    public func statuses() -> [AgentStatus] {
        let claude = claudeStatus()
        let codex = codexStatus()
        let t3Installed = exists(".t3")
        let viaNames = [claude, codex].filter(\.isConnected).map(\.kind.displayName)
        let t3 = AgentStatus(
            kind: .t3Code,
            isInstalled: t3Installed,
            isConnected: t3Installed && !viaNames.isEmpty,
            detail: viaNames.isEmpty
                ? "Connect Claude Code or Codex. T3 Code runs both."
                : "Through \(viaNames.joined(separator: " and "))"
        )
        return [claude, codex, t3, openCodeStatus()]
    }

    public func setConnected(_ kind: AgentKind, _ connected: Bool) throws {
        switch kind {
        case .claudeCode:
            let files = claudeFiles()
            guard !files.isEmpty else { throw IntegrationError.notInstalled(kind.displayName) }
            for file in files {
                try updateJSON(file) { root in
                    var servers = root["mcpServers"] as? [String: Any] ?? [:]
                    servers[RamDiskConstants.mcpServerName] = connected
                        ? ["type": "stdio", "command": command, "args": ["mcp"]] as [String: Any]
                        : nil
                    root["mcpServers"] = servers
                }
            }
        case .codex:
            guard exists(".codex") else { throw IntegrationError.notInstalled(kind.displayName) }
            let file = codexFile
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let updated = connected ? CodexConfig.adding(to: text, command: command) : CodexConfig.removing(from: text)
            if updated != text {
                try write(Data(updated.utf8), to: file)
            }
        case .openCode:
            guard let file = openCodeFile() else { throw IntegrationError.notInstalled(kind.displayName) }
            try updateJSON(file) { root in
                var servers = root["mcp"] as? [String: Any] ?? [:]
                servers[RamDiskConstants.mcpServerName] = connected
                    ? ["type": "local", "command": [command, "mcp"], "enabled": true] as [String: Any]
                    : nil
                root["mcp"] = servers
            }
        case .t3Code:
            break
        }
    }

    // MARK: - Claude Code

    private func claudeFiles() -> [URL] {
        var files = [home.appendingPathComponent(".claude.json")]
        let profiles = home.appendingPathComponent(".claude-profiles")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
        files += names.sorted().map { profiles.appendingPathComponent($0).appendingPathComponent(".claude.json") }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func claudeStatus() -> AgentStatus {
        let files = claudeFiles()
        let connected = files.filter { file in
            let servers = readJSON(file)?["mcpServers"] as? [String: Any]
            return (servers?[RamDiskConstants.mcpServerName] as? [String: Any])?["command"] as? String == command
        }
        let detail: String = if files.isEmpty {
            "Not installed"
        } else if files.count == 1 {
            "~/.claude.json"
        } else {
            "\(connected.count) of \(files.count) profiles"
        }
        return AgentStatus(
            kind: .claudeCode,
            isInstalled: !files.isEmpty,
            isConnected: !files.isEmpty && connected.count == files.count,
            detail: detail
        )
    }

    // MARK: - Codex

    private var codexFile: URL { home.appendingPathComponent(".codex/config.toml") }

    private func codexStatus() -> AgentStatus {
        let installed = exists(".codex")
        let text = (try? String(contentsOf: codexFile, encoding: .utf8)) ?? ""
        return AgentStatus(
            kind: .codex,
            isInstalled: installed,
            isConnected: installed && CodexConfig.contains(text, command: command),
            detail: installed ? "~/.codex/config.toml" : "Not installed"
        )
    }

    // MARK: - OpenCode

    private func openCodeFile() -> URL? {
        let folder = home.appendingPathComponent(".config/opencode")
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let json = folder.appendingPathComponent("opencode.json")
        let jsonc = folder.appendingPathComponent("opencode.jsonc")
        if !FileManager.default.fileExists(atPath: json.path), FileManager.default.fileExists(atPath: jsonc.path) {
            return jsonc
        }
        return json
    }

    private func openCodeStatus() -> AgentStatus {
        guard let file = openCodeFile() else {
            return AgentStatus(kind: .openCode, isInstalled: false, isConnected: false, detail: "Not installed")
        }
        let servers = readJSON(file)?["mcp"] as? [String: Any]
        let entry = servers?[RamDiskConstants.mcpServerName] as? [String: Any]
        return AgentStatus(
            kind: .openCode,
            isInstalled: true,
            isConnected: (entry?["command"] as? [String])?.first == command,
            detail: "~/.config/opencode/\(file.lastPathComponent)"
        )
    }

    // MARK: - Files

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func updateJSON(_ url: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw IntegrationError.unreadable(url.path)
            }
            root = parsed
        }
        mutate(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try write(data, to: url)
    }

    /// Writes through a symlink and keeps the file mode. The first change saves a copy of the original file.
    private func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let attributes = try? manager.attributesOfItem(atPath: target.path)
        let backup = target.appendingPathExtension("before-ramdisk")
        if manager.fileExists(atPath: target.path), !manager.fileExists(atPath: backup.path) {
            try? manager.copyItem(at: target, to: backup)
        }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if let mode = attributes?[.posixPermissions] {
            try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }
}

enum CodexConfig {
    static let header = "[mcp_servers.\(RamDiskConstants.mcpServerName)]"

    static func block(command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(header)\ncommand = \"\(escaped)\"\nargs = [\"mcp\"]\n"
    }

    static func contains(_ text: String, command: String) -> Bool {
        text.contains(block(command: command))
    }

    static func adding(to text: String, command: String) -> String {
        if contains(text, command: command) { return text }
        var base = removing(from: text)
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        if !base.isEmpty { base += "\n" }
        return base + block(command: command)
    }

    static func removing(from text: String) -> String {
        let subtablePrefix = String(header.dropLast()) + "."
        var kept: [Substring] = []
        var isInsideBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isInsideBlock = trimmed == header || trimmed.hasPrefix(subtablePrefix)
            }
            if !isInsideBlock { kept.append(line) }
        }
        while kept.count > 1, kept[kept.count - 1].isEmpty, kept[kept.count - 2].isEmpty {
            kept.removeLast()
        }
        return kept.joined(separator: "\n")
    }
}
