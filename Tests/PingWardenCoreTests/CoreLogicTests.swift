//
//  CoreLogicTests.swift
//  PingWardenCoreTests
//
//  XCTest suite for the Foundation-only helpers under
//  PingWarden/PingWarden/Core/. Run with `swift test`.
//

import Darwin
import Foundation
import XCTest
@testable import PingWardenCore

final class PingStatisticsTests: XCTestCase {
    func testEmptySamplesReportZeroAndPoorQuality() {
        let result = PingStatistics.calculate(from: [])
        XCTAssertEqual(result.currentPing, 0)
        XCTAssertEqual(result.quality, .poor)
    }

    func testHealthySamplesProduceExcellentQuality() {
        let now = Date()
        let samples = [
            PingSample(latencyMs: 12, success: true, timestamp: now),
            PingSample(latencyMs: 14, success: true, timestamp: now.addingTimeInterval(1)),
            PingSample(latencyMs: 10, success: true, timestamp: now.addingTimeInterval(2))
        ]
        let result = PingStatistics.calculate(from: samples)
        XCTAssertEqual(result.currentPing, 10, accuracy: 0.0001)
        XCTAssertEqual(result.averagePing, 12, accuracy: 0.0001)
        XCTAssertEqual(result.jitter, 3, accuracy: 0.0001)
        XCTAssertEqual(result.packetLoss, 0, accuracy: 0.0001)
        XCTAssertEqual(result.quality, .excellent)
    }

    func testLossySamplesReportPacketLossAndPoorQuality() {
        let now = Date()
        let samples = [
            PingSample(latencyMs: 120, success: true, timestamp: now),
            PingSample(latencyMs: 1000, success: false, timestamp: now.addingTimeInterval(1)),
            PingSample(latencyMs: 130, success: true, timestamp: now.addingTimeInterval(2))
        ]
        let result = PingStatistics.calculate(from: samples)
        XCTAssertEqual(result.packetLoss, 33.3333333333, accuracy: 0.0001)
        XCTAssertEqual(result.quality, .poor)
    }

    /// Even-count windows must use the true median (mean of the two middle
    /// elements), not the upper-middle pick. (10, 80) → median 45 → `good`.
    func testEvenCountWindowUsesTrueMedian() {
        let now = Date()
        let samples = [
            PingSample(latencyMs: 10, success: true, timestamp: now),
            PingSample(latencyMs: 80, success: true, timestamp: now.addingTimeInterval(1))
        ]
        let result = PingStatistics.calculate(from: samples)
        XCTAssertEqual(result.quality, .good)
    }
}

final class XPCReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesEachAttempt() {
        XCTAssertEqual(XPCReconnectPolicy.delayForAttempt(1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(XPCReconnectPolicy.delayForAttempt(2), 2.0, accuracy: 0.0001)
        XCTAssertEqual(XPCReconnectPolicy.delayForAttempt(3), 4.0, accuracy: 0.0001)
    }

    func testNonPositiveAttemptReturnsZero() {
        XCTAssertEqual(XPCReconnectPolicy.delayForAttempt(0), 0.0, accuracy: 0.0001)
    }
}

final class TCPProbeTests: XCTestCase {
    /// A 300-char label violates RFC 1035 so `getaddrinfo` rejects it
    /// without a DNS round-trip — deterministic offline test of the
    /// resolver-failure cleanup path.
    func testInvalidHostnameReturnsNil() {
        let invalidHostname = String(repeating: "x", count: 300)
        XCTAssertNil(TCPProbe.measureLatency(host: invalidHostname, port: 53, timeoutSeconds: 1))
        XCTAssertFalse(TCPProbe.connect(host: invalidHostname, port: 53, timeoutSeconds: 1))
    }

    /// Loopback port 1 is privileged and unbound on a normal user account; the
    /// kernel returns ECONNREFUSED immediately, exercising the connect-failure
    /// path without any network dependency.
    func testClosedLoopbackPortReturnsNil() {
        XCTAssertNil(TCPProbe.measureLatency(host: "127.0.0.1", port: 1, timeoutSeconds: 1))
        XCTAssertFalse(TCPProbe.connect(host: "127.0.0.1", port: 1, timeoutSeconds: 1))
    }

    /// Bind a real listener on a kernel-assigned port and verify the probe
    /// returns a non-negative latency. `listen()` queues the incoming SYN
    /// even before any accept() so the handshake completes without a race.
    func testOpenLoopbackPortReturnsLatency() throws {
        let port = try XCTUnwrap(Self.startLoopbackListener(), "failed to bind loopback listener")
        let latency = TCPProbe.measureLatency(host: "127.0.0.1", port: port, timeoutSeconds: 2)
        let unwrappedLatency = try XCTUnwrap(latency, "probe should return non-nil latency")
        XCTAssertGreaterThanOrEqual(unwrappedLatency, 0)
        XCTAssertTrue(TCPProbe.connect(host: "127.0.0.1", port: port, timeoutSeconds: 2))
    }

    private static func startLoopbackListener() -> UInt16? {
        // POSIX socket calls are qualified with `Darwin.` because inside an
        // XCTestCase subclass `bind`, `listen`, and `close` shadow the global
        // C functions with NSObject's KVO `bind(_:to:withKeyPath:options:)`
        // and friends.
        let listenerFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.bind(listenerFD, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 4) == 0 else {
            Darwin.close(listenerFD)
            return nil
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.getsockname(listenerFD, sockAddrPtr, &len)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listenerFD)
            return nil
        }

        // The socket is intentionally leaked for the lifetime of the test
        // process — `listen()` keeps the kernel queue alive so the probe's
        // connect() succeeds without an accept loop racing it.
        return UInt16(bigEndian: boundAddr.sin_port)
    }
}

final class StateObserverRegistryTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func add(_ delta: Int) {
            lock.lock()
            value += delta
            lock.unlock()
        }

        func reset() {
            lock.lock()
            value = 0
            lock.unlock()
        }

        var currentValue: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testFreshRegistryIsEmpty() {
        XCTAssertEqual(StateObserverRegistry().count, 0)
    }

    func testAddRemoveLifecycle() {
        let registry = StateObserverRegistry()
        let fireCount = LockedCounter()

        let tokenA = registry.add { fireCount.add(1) }
        let tokenB = registry.add { fireCount.add(10) }
        XCTAssertEqual(registry.count, 2)

        registry.snapshot().forEach { $0() }
        XCTAssertEqual(fireCount.currentValue, 11)

        registry.remove(tokenA)
        XCTAssertEqual(registry.count, 1)
        fireCount.reset()
        registry.snapshot().forEach { $0() }
        XCTAssertEqual(fireCount.currentValue, 10)

        // Removing a stale token must be a no-op, never a crash.
        registry.remove(UUID())
        XCTAssertEqual(registry.count, 1)

        registry.remove(tokenB)
        XCTAssertEqual(registry.count, 0)
    }
}

final class HelperBundleValidatorTests: XCTestCase {
    private var fakeBundle: URL!
    private let plistName = "com.amesvt.pingwarden.helper.plist"

    override func setUpWithError() throws {
        fakeBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("pingwarden-validator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fakeBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeBundle.appendingPathComponent("Contents/Library/LaunchDaemons"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeBundle)
        fakeBundle = nil
    }

    func testReportsMissingBinaryFirst() {
        let binaryPath = fakeBundle.appendingPathComponent("Contents/MacOS/PingWardenHelper").path
        let result = HelperBundleValidator.validate(
            appBundlePath: fakeBundle.path,
            helperPlistName: plistName
        )
        XCTAssertEqual(result, .binaryMissing(path: binaryPath))
    }

    func testReportsMissingPlistOnceBinaryExists() throws {
        let binaryPath = fakeBundle.appendingPathComponent("Contents/MacOS/PingWardenHelper").path
        let plistPath = fakeBundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)").path
        FileManager.default.createFile(atPath: binaryPath, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binaryPath)

        let result = HelperBundleValidator.validate(
            appBundlePath: fakeBundle.path,
            helperPlistName: plistName
        )
        XCTAssertEqual(result, .plistMissing(path: plistPath))
    }

    func testReportsNonExecutableBinaryOnceBothFilesExist() throws {
        let binaryPath = fakeBundle.appendingPathComponent("Contents/MacOS/PingWardenHelper").path
        let plistPath = fakeBundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)").path
        FileManager.default.createFile(atPath: binaryPath, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binaryPath)
        FileManager.default.createFile(atPath: plistPath, contents: Data("<?xml version=\"1.0\"?>\n".utf8))

        let result = HelperBundleValidator.validate(
            appBundlePath: fakeBundle.path,
            helperPlistName: plistName
        )
        XCTAssertEqual(result, .binaryNotExecutable(path: binaryPath))
    }

    func testAcceptsCompleteExecutableBundle() throws {
        let binaryPath = fakeBundle.appendingPathComponent("Contents/MacOS/PingWardenHelper").path
        let plistPath = fakeBundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)").path
        FileManager.default.createFile(atPath: binaryPath, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        FileManager.default.createFile(atPath: plistPath, contents: Data("<?xml version=\"1.0\"?>\n".utf8))

        XCTAssertNil(HelperBundleValidator.validate(
            appBundlePath: fakeBundle.path,
            helperPlistName: plistName
        ))
    }
}

final class VersionPromptPolicyTests: XCTestCase {
    func testFirstLaunchPromptsWhenNothingSeen() {
        XCTAssertTrue(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.3.0",
            lastSeenVersion: nil,
            dismissedPermanently: false
        ))
    }

    func testKillSwitchSuppressesEverything() {
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.3.0",
            lastSeenVersion: nil,
            dismissedPermanently: true
        ))
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "9.9.0",
            lastSeenVersion: "1.0.0",
            dismissedPermanently: true
        ))
    }

    /// Patch bumps (2.2.1 → 2.2.2) must not re-trigger the prompt;
    /// otherwise we'd be asking users for money after a bug fix.
    func testPatchBumpDoesNotPrompt() {
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.2.2",
            lastSeenVersion: "2.2.1",
            dismissedPermanently: false
        ))
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.2.1",
            lastSeenVersion: "2.2.1",
            dismissedPermanently: false
        ))
    }

    func testMinorBumpPrompts() {
        XCTAssertTrue(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.3.0",
            lastSeenVersion: "2.2.5",
            dismissedPermanently: false
        ))
    }

    func testMajorBumpPrompts() {
        XCTAssertTrue(VersionPromptPolicy.shouldPrompt(
            currentVersion: "3.0.0",
            lastSeenVersion: "2.9.9",
            dismissedPermanently: false
        ))
    }

    /// A downgrade (somehow) must NOT prompt — we already showed them this
    /// minor version, and going backwards isn't a fresh trigger.
    func testDowngradeDoesNotPrompt() {
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.2.0",
            lastSeenVersion: "2.3.0",
            dismissedPermanently: false
        ))
    }

    func testGarbageCurrentVersionFailsClosed() {
        // We cannot decide — better to stay quiet than to nag.
        XCTAssertFalse(VersionPromptPolicy.shouldPrompt(
            currentVersion: "not-a-version",
            lastSeenVersion: "2.2.0",
            dismissedPermanently: false
        ))
    }

    func testGarbageStoredVersionTreatedAsFirstLaunch() {
        XCTAssertTrue(VersionPromptPolicy.shouldPrompt(
            currentVersion: "2.3.0",
            lastSeenVersion: "garbage",
            dismissedPermanently: false
        ))
    }
}

final class CustomPingTargetStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CustomPingTargetStore!

    override func setUpWithError() throws {
        suiteName = "pingwarden-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = CustomPingTargetStore(userDefaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
    }

    func testEmptyStoreReturnsEmptyArray() {
        XCTAssertEqual(store.load(), [])
    }

    func testAddPersistsAcrossInstances() {
        let target = CustomPingTarget(displayName: "NextDNS", host: "45.90.28.0", port: 53)
        store.add(target)

        let fresh = CustomPingTargetStore(userDefaults: defaults)
        XCTAssertEqual(fresh.load(), [target])
    }

    func testRemoveById() {
        let a = CustomPingTarget(displayName: "A", host: "1.1.1.1", port: 53)
        let b = CustomPingTarget(displayName: "B", host: "2.2.2.2", port: 53)
        store.save([a, b])

        let remaining = store.remove(id: a.id)
        XCTAssertEqual(remaining, [b])
        XCTAssertEqual(store.load(), [b])
    }

    func testUpdateById() {
        let original = CustomPingTarget(displayName: "Old", host: "1.1.1.1", port: 53)
        store.add(original)

        let edited = CustomPingTarget(id: original.id, displayName: "New", host: "9.9.9.9", port: 853)
        let result = store.update(edited)
        XCTAssertEqual(result, [edited])
        XCTAssertEqual(store.load(), [edited])
    }

    func testCorruptedBlobReturnsEmptyAndDoesNotCrash() {
        defaults.set(Data("not json".utf8), forKey: "DashboardCustomPingTargets")
        XCTAssertEqual(store.load(), [])
    }

    func testValidationRejectsEmptyName() {
        XCTAssertEqual(
            CustomPingTargetStore.validate(displayName: "  ", host: "1.1.1.1", port: 53),
            .nameEmpty
        )
    }

    func testValidationRejectsEmptyHost() {
        XCTAssertEqual(
            CustomPingTargetStore.validate(displayName: "X", host: "", port: 53),
            .hostEmpty
        )
    }

    func testValidationRejectsTooLongHost() {
        let longHost = String(repeating: "x", count: 300)
        XCTAssertEqual(
            CustomPingTargetStore.validate(displayName: "X", host: longHost, port: 53),
            .hostTooLong
        )
    }

    func testValidationRejectsOutOfRangePort() {
        XCTAssertEqual(
            CustomPingTargetStore.validate(displayName: "X", host: "1.1.1.1", port: 0),
            .portOutOfRange
        )
        XCTAssertEqual(
            CustomPingTargetStore.validate(displayName: "X", host: "1.1.1.1", port: 70000),
            .portOutOfRange
        )
    }

    func testValidationAcceptsGoodInput() {
        XCTAssertNil(CustomPingTargetStore.validate(displayName: "NextDNS", host: "45.90.28.0", port: 53))
    }
}
