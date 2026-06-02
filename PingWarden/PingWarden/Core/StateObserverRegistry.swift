//
//  StateObserverRegistry.swift
//  PingWarden
//
//  Thread-safe registry for state-change observer callbacks.
//

import Foundation

/// Token-based observer registry. Observers register a closure and receive a
/// UUID token that can later be used to deregister. Snapshotting the current
/// observer set is decoupled from invocation so callers can deliver
/// notifications outside any internal lock.
final class StateObserverRegistry {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable () -> Void] = [:]

    @discardableResult
    func add(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func remove(_ token: UUID) {
        lock.lock()
        observers.removeValue(forKey: token)
        lock.unlock()
    }

    /// Returns a point-in-time snapshot of the registered observers. Callers
    /// should invoke the returned closures outside the registry so observers
    /// cannot deadlock by calling back into add/remove during delivery.
    func snapshot() -> [@Sendable () -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return Array(observers.values)
    }

    /// Test/diagnostic helper: number of currently registered observers.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }
}
