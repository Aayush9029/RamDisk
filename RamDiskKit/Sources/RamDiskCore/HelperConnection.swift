import Foundation

public enum HelperConnectionError: LocalizedError {
    case unreachable(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason): "The RamDisk helper does not respond. \(reason)"
        case .commandFailed(let message): message
        }
    }
}

/// The XPC client that the app, the CLI, and the MCP server share.
public final class HelperConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    public func status() async throws -> HelperStatus {
        let data: Data = try await send { proxy, finish in
            proxy.status { finish(.success($0)) }
        }
        return try JSONDecoder().decode(HelperStatus.self, from: data)
    }

    public func run(_ command: HelperCommand) async throws {
        let payload = try JSONEncoder().encode(command)
        let failure: String? = try await send { proxy, finish in
            proxy.run(payload) { finish(.success($0)) }
        }
        if let failure {
            throw HelperConnectionError.commandFailed(failure)
        }
    }

    public func invalidate() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    private func send<Value: Sendable>(
        _ body: @escaping (HelperXPCProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.invalidate()
                once.finish(.failure(HelperConnectionError.unreachable(error.localizedDescription)))
            }
            guard let helper = proxy as? HelperXPCProtocol else {
                once.finish(.failure(HelperConnectionError.unreachable("The helper interface is not available.")))
                return
            }
            body(helper) { once.finish($0) }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let new = NSXPCConnection(machServiceName: RamDiskConstants.machService, options: [])
            new.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            new.invalidationHandler = { [weak self, weak new] in
                guard let self, let new else { return }
                self.lock.withLock {
                    if self.connection === new { self.connection = nil }
                }
            }
            new.resume()
            connection = new
            return new
        }
    }
}

private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
