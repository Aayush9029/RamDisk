# RamDisk

A macOS menu bar app that creates a RAM disk and lets coding agents work on it. The panel shows the disk use for each agent as a dot-matrix bar. Status: active.

## Commands

| Task | Command |
|------|---------|
| Generate the Xcode project | `xcodegen generate` |
| Package tests | `swift test --package-path RamDiskKit` |
| Debug build | `xcodebuild -project RamDisk.xcodeproj -scheme RamDisk -configuration Debug -derivedDataPath .derived build` |
| Release build | `xcodebuild -project RamDisk.xcodeproj -scheme RamDisk -configuration Release -derivedDataPath /tmp/ramdisk-derived CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: Optimal Life Technologies, Inc (6Q29HJZ4AG)" OTHER_CODE_SIGN_FLAGS="--timestamp" build` |
| Install | `ditto /tmp/ramdisk-derived/Build/Products/Release/RamDisk.app /Applications/RamDisk.app` |

`project.yml` is the source of the Xcode project. After a change to targets or build settings, run `xcodegen generate` and commit `RamDisk.xcodeproj`.

## Architecture

- `App/`: the menu bar app (`com.optimalapps.RamDisk`, macOS 26). `AppModel` polls the helper and holds the UI state. `Panel/` is the glass panel, `Bar/DotBar.metal` is the SwiftUI shader for the dot-matrix bar, `Settings/` is the Settings window.
- `Helper/`: the entry point of `ramdisk-helper` and the launch agent template. One binary is the launch agent, the `ramdisk` CLI, and the MCP server (`ramdisk mcp`).
- `RamDiskKit/RamDiskCore`: models, the XPC protocol, `HelperConnection`, and the suggestion logic. The app and the helper share it.
- `RamDiskKit/RamDiskEngine`: `HelperCore` (the actor that owns the disk state), `DiskManager` (`hdiutil` and `diskutil`), `UsageScanner`, `MemoryMonitor`, `AgentIntegrations`, `Workspaces`, and `MCPServer`.
- The app registers the helper with `SMAppService.agent` and talks to it through the Mach service `com.optimalapps.RamDisk.agent`. No administrator password is necessary, because `hdiutil attach ram://` runs as the user.
- The helper stores `config.json`, the `bin/ramdisk` link, and the optional `Snapshot/` copy in `~/Library/Application Support/RamDisk`. Agent configurations point at the `bin/ramdisk` link.
- Volume layout: `agents/<claude|codex|t3code|opencode>/<workspace>`, `builds/`, `caches/`, `tmp/`. `UsageCategory.relativePath` is the source of this layout.

## Rules

- Keep the App Sandbox off. macOS rejects a launch agent without a sandbox from a sandboxed app, and a sandboxed helper cannot run `hdiutil`.
- macOS binds an agent label to the first app path that registers it, and a later registration from a different path does not change it. Thus a Debug build has its own bundle ID (`com.optimalapps.RamDisk.debug`), label, and support folder (`RamDisk-Debug`). Run a Release build only from `/Applications`. If a label points at a deleted path, `sfltool resetbtm` clears all background item records.
- The app binary is `RamDisk` and the helper is `ramdisk-helper`. Do not name the helper `ramdisk`: the two names collide on a case-insensitive disk.
- macOS frees the memory of a RAM disk only at eject. Deleted files keep their memory. `HelperCommand.reclaimMemory` copies the files to the SSD, makes a new disk, and copies them back.
- The bar width is `DotBar.defaultColumns` cells of `DotBar.pitch` points. The panel width comes from these two values, so the shader cells stay square.
- `AgentIntegrations` edits the user's agent configuration files. Test it only with a temporary home folder.
