import Foundation
import XCTest
@testable import PingWardenCore

final class WelcomePresentationStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PingWardenWelcomeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallPresentsWelcomeUntilItHasBeenShown() {
        let state = WelcomePresentationState(defaults: defaults)
        XCTAssertTrue(state.shouldPresentAutomatically(helperIsRegistered: false))
        state.markPresented()
        XCTAssertFalse(state.shouldPresentAutomatically(helperIsRegistered: false))
    }

    func testRelaunchWithoutHelperDoesNotRepeatWelcome() {
        WelcomePresentationState(defaults: defaults).markPresented()
        let relaunched = WelcomePresentationState(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertFalse(relaunched.shouldPresentAutomatically(helperIsRegistered: false))
    }

    func testRegisteredHelperDoesNotNeedIntroduction() {
        XCTAssertFalse(WelcomePresentationState(defaults: defaults)
            .shouldPresentAutomatically(helperIsRegistered: true))
    }

    func testRemovingAppDataRestoresFirstLaunchBehavior() {
        let state = WelcomePresentationState(defaults: defaults)
        state.markPresented()
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(state.shouldPresentAutomatically(helperIsRegistered: false))
    }

    func testPresentationDoesNotChangeProtectionIntent() {
        defaults.set(true, forKey: "AWDLMonitoringEnabled")
        WelcomePresentationState(defaults: defaults).markPresented()
        XCTAssertTrue(defaults.bool(forKey: "AWDLMonitoringEnabled"))
    }
}
