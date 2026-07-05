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

    /// Measure TCP connect latency in milliseconds. Returns nil on failure
    /// (resolution failure/timeout, or no address accepted the connection).
    static func measureLatency(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Double? {
        guard let addresses = resolveAddresses(host: host, port: port, timeoutSeconds: timeoutSeconds),
              !addresses.isEmpty else {
            return nil
        }

        for address in addresses {
            if let latencyMs = connectSingle(address, timeoutSeconds: timeoutSeconds) {
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
    private static func resolveAddresses(host: String, port: UInt16, timeoutSeconds: Int) -> [ResolvedAddress]? {
        if isIPLiteral(host) {
            return resolveAddressesBlocking(host: host, port: port, numericOnly: true)
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

        // Allow at least 2 s for DNS even when the connect timeout is 1 s.
        let resolverDeadline = DispatchTime.now() + max(2.0, Double(timeoutSeconds) * 2.0)
        guard box.semaphore.wait(timeout: resolverDeadline) == .success else {
            return nil
        }
        return box.addresses
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
    private static func connectSingle(_ resolved: ResolvedAddress, timeoutSeconds: Int) -> Double? {
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

        let startTime = Date()
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
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
            guard remainingMs > 0 else {
                return nil
            }
            let pollResult = poll(&pollFD, 1, remainingMs)
            if pollResult > 0 {
                break
            }
            if pollResult == 0 {
                return nil  // Timed out
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

    private static func elapsedMs(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000.0
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
