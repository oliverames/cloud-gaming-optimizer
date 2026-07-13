//
//  TCPProbe.swift
//  PingWarden
//
//  Lightweight TCP connect latency probe used by dashboard and monitoring.
//
//  Pure POSIX sockets (no Network.framework) so the same source compiles on
//  macOS and Linux — the SwiftPM test target exercises it on both. The
//  connect wait uses poll(2) rather than select(2): poll is portable, has no
//  FD_SETSIZE ceiling, and needs no fd_set bit manipulation.
//
//  Measurement semantics: the reported latency is the TCP handshake time of
//  the successful attempt ONLY. DNS resolution time and failed connect
//  attempts (e.g. an unroutable IPv6 address tried before the working IPv4
//  one) are excluded — including them used to report a ~1010 ms "successful
//  ping" on dual-stack hostnames, poisoning averages, jitter, spike events,
//  and auto-select rankings.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum TCPProbe {
    /// A resolved socket address, copied out of the addrinfo list so it can
    /// outlive freeaddrinfo() and cross the resolver-thread boundary.
    private struct ResolvedAddress {
        let family: Int32
        let socktype: Int32
        let proto: Int32
        let addressBytes: [UInt8]
    }

    final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private struct AddressCacheKey: Hashable {
        let host: String
        let port: UInt16
    }

    private struct AddressCacheEntry {
        let addresses: [ResolvedAddress]
        let expiresAt: Date
    }

    private static let addressCacheLock = NSLock()
    private nonisolated(unsafe) static var addressCache: [AddressCacheKey: AddressCacheEntry] = [:]
    private static let addressCacheTTL: TimeInterval = 5 * 60
    private static let addressCacheLimit = 128

    /// Measure TCP connect latency in milliseconds. Returns nil on failure
    /// (resolution failure/timeout, or no address accepted the connection).
    static func measureLatency(
        host: String,
        port: UInt16,
        timeoutSeconds: Int = 1,
        cancellationToken: CancellationToken? = nil
    ) -> Double? {
        let sanitizedTimeout = max(1, timeoutSeconds)
        let deadline = DispatchTime.now() + .seconds(sanitizedTimeout)
        guard cancellationToken?.isCancelled != true,
              let addresses = resolveAddresses(
                  host: host,
                  port: port,
                  deadline: deadline,
                  cancellationToken: cancellationToken
              ),
              !addresses.isEmpty else {
            return nil
        }

        for address in addresses {
            guard cancellationToken?.isCancelled != true,
                  DispatchTime.now() < deadline else {
                return nil
            }
            if let latencyMs = connectSingle(
                address,
                deadline: deadline,
                cancellationToken: cancellationToken
            ) {
                return latencyMs
            }
        }
        return nil
    }

    static func connect(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Bool {
        measureLatency(host: host, port: port, timeoutSeconds: timeoutSeconds) != nil
    }

    // MARK: - Resolution

    /// getaddrinfo has no timeout of its own — an unresponsive resolver can
    /// block for ~30 s, which used to freeze the entire probe pipeline (the
    /// serial probe queue skipped every subsequent tick behind the hung
    /// call). IP-literal hosts (all the default targets: public DNS servers,
    /// the local gateway, discovered GFN endpoints) can never hit the
    /// resolver, so they resolve inline; only real hostnames pay for the
    /// deadline-bounded detached thread — off the 2-second probe hot path.
    /// On timeout the probe reports failure and the orphaned thread finishes
    /// on its own.
    private static func resolveAddresses(
        host: String,
        port: UInt16,
        deadline: DispatchTime,
        cancellationToken: CancellationToken?
    ) -> [ResolvedAddress]? {
        if isIPLiteral(host) {
            return resolveAddressesBlocking(host: host, port: port, numericOnly: true)
        }

        let cacheKey = AddressCacheKey(host: host.lowercased(), port: port)
        if let cached = cachedAddresses(for: cacheKey) {
            return cached
        }

        final class ResultBox: @unchecked Sendable {
            var addresses: [ResolvedAddress]?
            let semaphore = DispatchSemaphore(value: 0)
        }

        let box = ResultBox()
        let thread = Thread {
            box.addresses = resolveAddressesBlocking(host: host, port: port, numericOnly: false)
            box.semaphore.signal()
        }
        thread.name = "TCPProbe.resolve"
        thread.stackSize = 512 * 1024
        thread.start()

        while true {
            guard cancellationToken?.isCancelled != true else { return nil }
            let remainingMilliseconds = millisecondsRemaining(until: deadline)
            guard remainingMilliseconds > 0 else { return nil }
            let sliceDeadline = DispatchTime.now() + .milliseconds(Int(min(remainingMilliseconds, 100)))
            if box.semaphore.wait(timeout: sliceDeadline) == .success {
                break
            }
        }
        guard let addresses = box.addresses, !addresses.isEmpty else { return nil }
        cacheAddresses(addresses, for: cacheKey)
        return addresses
    }

    private static func cachedAddresses(for key: AddressCacheKey) -> [ResolvedAddress]? {
        addressCacheLock.lock()
        defer { addressCacheLock.unlock() }
        guard let entry = addressCache[key] else { return nil }
        guard entry.expiresAt > Date() else {
            addressCache.removeValue(forKey: key)
            return nil
        }
        return entry.addresses
    }

    private static func cacheAddresses(_ addresses: [ResolvedAddress], for key: AddressCacheKey) {
        addressCacheLock.lock()
        let now = Date()
        addressCache = addressCache.filter { $0.value.expiresAt > now }
        if addressCache[key] == nil,
           addressCache.count >= addressCacheLimit,
           let oldestKey = addressCache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            addressCache.removeValue(forKey: oldestKey)
        }
        addressCache[key] = AddressCacheEntry(
            addresses: addresses,
            expiresAt: now.addingTimeInterval(addressCacheTTL)
        )
        addressCacheLock.unlock()
    }

    static func resetAddressCacheForTesting() {
        addressCacheLock.lock()
        addressCache.removeAll()
        addressCacheLock.unlock()
    }

    static var addressCacheEntryCountForTesting: Int {
        addressCacheLock.lock()
        defer { addressCacheLock.unlock() }
        return addressCache.count
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return true
        }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    private static func resolveAddressesBlocking(host: String, port: UInt16, numericOnly: Bool) -> [ResolvedAddress]? {
        // Build hints via memberwise-zero init and explicit field assignment:
        // the addrinfo struct declares its members in a different order on
        // Darwin and Glibc, so a positional initializer is not portable.
        var hints = addrinfo()
        hints.ai_flags = numericOnly ? (AI_NUMERICSERV | AI_NUMERICHOST) : AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)

        // Per POSIX, the contents of `result` are unspecified when
        // getaddrinfo() fails, so freeaddrinfo() must not be called on it.
        // On success the manpage guarantees a non-nil linked list.
        guard status == 0, let resolved = result else {
            return nil
        }
        defer { freeaddrinfo(resolved) }

        var addresses: [ResolvedAddress] = []
        var current: UnsafeMutablePointer<addrinfo>? = resolved
        while let info = current {
            if let addrPtr = info.pointee.ai_addr, info.pointee.ai_addrlen > 0 {
                let byteCount = Int(info.pointee.ai_addrlen)
                let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(addrPtr), count: byteCount)
                addresses.append(ResolvedAddress(
                    family: info.pointee.ai_family,
                    socktype: info.pointee.ai_socktype,
                    proto: info.pointee.ai_protocol,
                    addressBytes: Array(bytes)
                ))
            }
            current = info.pointee.ai_next
        }
        return addresses
    }

    // MARK: - Connect

    /// Attempt one address; returns the handshake latency in milliseconds on
    /// success, nil on failure/timeout.
    private static func connectSingle(
        _ resolved: ResolvedAddress,
        deadline: DispatchTime,
        cancellationToken: CancellationToken?
    ) -> Double? {
        let socketFD = socket(resolved.family, resolved.socktype, resolved.proto)
        guard socketFD >= 0 else {
            return nil
        }
        defer { close(socketFD) }

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags >= 0,
              fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            return nil
        }

        let startTime = DispatchTime.now()
        let connectResult = resolved.addressBytes.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
            return systemConnect(socketFD, sockaddrPtr, socklen_t(raw.count))
        }
        if connectResult == 0 {
            return elapsedMs(since: startTime)
        }

        if errno != EINPROGRESS {
            return nil
        }

        // Wait for the socket to become writable (connect finished or failed),
        // retrying on EINTR without extending the overall deadline.
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        while true {
            guard cancellationToken?.isCancelled != true else { return nil }
            let remainingMs = millisecondsRemaining(until: deadline)
            guard remainingMs > 0 else {
                return nil
            }
            // Short slices make cancellation observable without extending the
            // single end-to-end deadline shared by DNS and every address.
            let pollResult = poll(&pollFD, 1, min(remainingMs, 100))
            if pollResult > 0 {
                break
            }
            if pollResult == 0 {
                continue
            }
            if errno != EINTR {
                return nil
            }
        }

        var socketError: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0,
              socketError == 0 else {
            return nil
        }
        return elapsedMs(since: startTime)
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNanoseconds) / 1_000_000.0
    }

    private static func millisecondsRemaining(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0 }
        let remainingNanoseconds = deadline.uptimeNanoseconds - now
        let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
    }

    /// Platform-qualified connect(2). The enum's own `connect(host:port:)`
    /// shadows the libc symbol, so the call must be disambiguated per platform.
    private static func systemConnect(
        _ fd: Int32,
        _ addr: UnsafePointer<sockaddr>?,
        _ len: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, addr, len)
        #elseif canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #endif
    }
}
