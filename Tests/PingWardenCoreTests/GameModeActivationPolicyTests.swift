//
//  GameModeActivationPolicyTests.swift
//  PingWardenCoreTests
//
//  XCTest suite for GameModeActivationPolicy: frontmost and fullscreen
//  observation paths, and the wired-path gate.
//

import Foundation
import XCTest
@testable import PingWardenCore

final class GameModeActivationPolicyTests: XCTestCase {

    // MARK: - gamePresent

    func testFrontmostGameAloneIsPresent() {
        XCTAssertTrue(GameModeActivationPolicy.gamePresent(frontmostIsGame: true, fullscreenGamePresent: false))
    }

    func testFullscreenGameAloneIsPresent() {
        XCTAssertTrue(GameModeActivationPolicy.gamePresent(frontmostIsGame: false, fullscreenGamePresent: true))
    }

    func testNoObservationIsNotPresent() {
        XCTAssertFalse(GameModeActivationPolicy.gamePresent(frontmostIsGame: false, fullscreenGamePresent: false))
    }

    // MARK: - shouldEngage

    func testEngagesOnWiFi() {
        XCTAssertTrue(GameModeActivationPolicy.shouldEngage(gamePresent: true, pathInterface: .wifi))
    }

    func testSkipsWiredPath() {
        XCTAssertFalse(GameModeActivationPolicy.shouldEngage(gamePresent: true, pathInterface: .wired))
    }

    func testUnknownPathFailsTowardProtection() {
        XCTAssertTrue(GameModeActivationPolicy.shouldEngage(gamePresent: true, pathInterface: .unknown))
    }

    func testOtherPathFailsTowardProtection() {
        XCTAssertTrue(GameModeActivationPolicy.shouldEngage(gamePresent: true, pathInterface: .other))
    }

    func testNoGameNeverEngages() {
        for path in [GameModeActivationPolicy.PathInterface.wifi, .wired, .other, .unknown] {
            XCTAssertFalse(GameModeActivationPolicy.shouldEngage(gamePresent: false, pathInterface: path), "\(path)")
        }
    }

    func testFrontmostGameEngagesWithoutFullscreenOnWiFi() {
        XCTAssertTrue(GameModeActivationPolicy.shouldEngage(
            frontmostIsGame: true,
            fullscreenGamePresent: false,
            pathInterface: .wifi
        ))
    }

    func testFullscreenGameOnWiredDoesNotEngage() {
        XCTAssertFalse(GameModeActivationPolicy.shouldEngage(
            frontmostIsGame: false,
            fullscreenGamePresent: true,
            pathInterface: .wired
        ))
    }
}
