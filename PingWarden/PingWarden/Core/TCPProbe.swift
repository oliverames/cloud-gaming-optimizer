//
//  TCPProbe.swift
//  PingWarden
//
//  Lightweight TCP connect latency probe used by dashboard and monitoring.
//

import Foundation

enum TCPProbe {
    static func measureLatency(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Double? {
        let startTime = Date()
        guard connect(host: host, port: port, timeoutSeconds: timeoutSeconds) else {
            return nil
        }
        return Date().timeIntervalSince(startTime) * 1000.0
    }

    static func connect(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)

        // Per POSIX, the contents of `result` are unspecified when
        // getaddrinfo() fails, so freeaddrinfo() must not be called on it.
        // On success the manpage guarantees a non-nil linked list.
        guard status == 0, let resolved = result else {
            return false
        }

        defer { freeaddrinfo(resolved) }

        var current: UnsafeMutablePointer<addrinfo>? = resolved
        while let addrInfo = current {
            if connectSingle(addrInfo: addrInfo.pointee, timeoutSeconds: timeoutSeconds) {
                return true
            }
            current = addrInfo.pointee.ai_next
        }
        return false
    }

    private static func connectSingle(addrInfo: addrinfo, timeoutSeconds: Int) -> Bool {
        let socketFD = socket(addrInfo.ai_family, addrInfo.ai_socktype, addrInfo.ai_protocol)
        guard socketFD >= 0 else {
            return false
        }
        defer { close(socketFD) }

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags >= 0,
              fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            return false
        }

        let connectResult = Darwin.connect(socketFD, addrInfo.ai_addr, addrInfo.ai_addrlen)
        if connectResult == 0 {
            return true
        }

        if errno != EINPROGRESS {
            return false
        }

        var writeSet = fd_set()
        fdZero(&writeSet)
        guard fdSet(socketFD, set: &writeSet) else {
            return false
        }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let selectResult = select(socketFD + 1, nil, &writeSet, nil, &timeout)
        guard selectResult > 0 else {
            return false
        }

        var socketError: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)
        return socketError == 0
    }

    private static func fdZero(_ set: inout fd_set) {
        set = fd_set()
    }

    private static func fdSet(_ fd: Int32, set: inout fd_set) -> Bool {
        guard fd >= 0 else {
            return false
        }

        let bitsPerWord = Int32(MemoryLayout<Int32>.size * 8)
        let tupleByteCount = MemoryLayout.size(ofValue: set.fds_bits)
        let wordCount = tupleByteCount / MemoryLayout<Int32>.size

        let intOffset = Int(fd / bitsPerWord)
        let bitOffset = Int(fd % bitsPerWord)

        guard intOffset >= 0, intOffset < wordCount else {
            return false
        }

        withUnsafeMutableBytes(of: &set.fds_bits) { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            let ptr = baseAddress.assumingMemoryBound(to: Int32.self)
            let bitMask = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
            ptr[intOffset] |= bitMask
        }
        return true
    }
}
