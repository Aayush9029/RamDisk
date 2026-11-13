import Foundation

struct ShellResult {
    var status: Int32
    var output: String
    var error: String

    var succeeded: Bool { status == 0 }

    var message: String {
        let text = error.isEmpty ? output : error
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: "", error: error.localizedDescription)
        }

        // Drain stderr on a second thread, because a full pipe blocks the child process.
        let errorData = LockedData()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            errorData.set(error.fileHandleForReading.readDataToEndOfFile())
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData.get(), as: UTF8.self)
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ new: Data) { lock.withLock { data = new } }
    func get() -> Data { lock.withLock { data } }
}
