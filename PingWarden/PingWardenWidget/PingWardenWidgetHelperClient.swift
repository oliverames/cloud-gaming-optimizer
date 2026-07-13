import Foundation
import os.log

private let helperClientLog = Logger(
    subsystem: "com.amesvt.pingwarden",
    category: "WidgetHelperClient"
)

@objc private protocol PingWardenWidgetHelperProtocol {
    func setAWDLEnabled(_ enable: Bool, withReply reply: @escaping (Bool) -> Void)
}

private final class WidgetXPCRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let protectionEnabled: Bool
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var connection: NSXPCConnection?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(protectionEnabled: Bool, timeout: TimeInterval) {
        self.protectionEnabled = protectionEnabled
        self.timeout = timeout
    }

    func perform() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func start(continuation: CheckedContinuation<Void, Error>) {
        let newConnection = NSXPCConnection(
            machServiceName: "com.amesvt.pingwarden.xpc",
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: PingWardenWidgetHelperProtocol.self
        )

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        connection = newConnection
        lock.unlock()

        newConnection.interruptionHandler = {
            helperClientLog.warning("Privileged helper connection interrupted")
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.finish(.failure(AWDLError.monitoringFailed))
        }
        newConnection.resume()

        guard let proxy = newConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            helperClientLog.error("Privileged helper proxy failed: \(error.localizedDescription)")
            self?.finish(.failure(error))
        }) as? PingWardenWidgetHelperProtocol else {
            finish(.failure(AWDLError.monitoringFailed))
            return
        }

        let newTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0, self.timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.finish(.failure(AWDLError.monitoringFailed))
        }
        lock.lock()
        if isFinished {
            lock.unlock()
            newTimeoutTask.cancel()
        } else {
            timeoutTask = newTimeoutTask
            lock.unlock()
        }

        // The helper API controls whether AWDL itself is enabled. Ping
        // Protection has the inverse meaning: protection on means AWDL off.
        proxy.setAWDLEnabled(!protectionEnabled) { [weak self] success in
            self?.finish(success ? .success(()) : .failure(AWDLError.monitoringFailed))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        connection?.invalidate()
        continuation?.resume(with: result)
    }
}

enum PingWardenWidgetHelperClient {
    static func setProtectionEnabled(
        _ protectionEnabled: Bool,
        timeout: TimeInterval = 3
    ) async throws {
        let request = WidgetXPCRequest(
            protectionEnabled: protectionEnabled,
            timeout: timeout
        )
        try await request.perform()
    }
}
