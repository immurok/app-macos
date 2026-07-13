import XCTest
@testable import AuthInjectionKit

final class DeviceActivityCoordinatorTests: XCTestCase {

    func testAuthBlocksMaintenanceAndOtherAuth() {
        let c = DeviceActivityCoordinator()
        let auth = c.tryBegin(.auth)
        XCTAssertNotNil(auth)
        XCTAssertNil(c.tryBegin(.keystoreMaintenance))
        XCTAssertNil(c.tryBegin(.auth))
        XCTAssertEqual(c.currentActivity, .auth)
    }

    func testMaintenanceBlocksAuth() {
        let c = DeviceActivityCoordinator()
        let m = c.tryBegin(.keystoreMaintenance)
        XCTAssertNotNil(m)
        XCTAssertNil(c.tryBegin(.auth))
        XCTAssertEqual(c.currentActivity, .keystoreMaintenance)
    }

    func testEndReleasesOwnership() {
        let c = DeviceActivityCoordinator()
        let m = c.tryBegin(.keystoreMaintenance)!
        c.end(m)
        XCTAssertNil(c.currentActivity)
        XCTAssertNotNil(c.tryBegin(.auth))
    }

    func testStaleTokenDoesNotReleaseNewOwner() {
        let c = DeviceActivityCoordinator()
        let first = c.tryBegin(.auth)!
        c.end(first)
        let second = c.tryBegin(.auth)!
        // A racing completion path of the finished first flow fires again.
        c.end(first)
        XCTAssertEqual(c.currentActivity, .auth)
        c.end(second)
        XCTAssertNil(c.currentActivity)
    }

    func testDoubleEndIsSafe() {
        let c = DeviceActivityCoordinator()
        let m = c.tryBegin(.keystoreMaintenance)!
        c.end(m)
        c.end(m)
        XCTAssertNil(c.currentActivity)
    }

    func testConcurrentTryBeginHasSingleWinner() {
        let c = DeviceActivityCoordinator()
        let winners = NSMutableArray()
        let winnersLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if let t = c.tryBegin(i % 2 == 0 ? .auth : .keystoreMaintenance) {
                winnersLock.lock()
                winners.add(t.activity.rawValue)
                winnersLock.unlock()
            }
        }
        XCTAssertEqual(winners.count, 1)
        XCTAssertNotNil(c.currentActivity)
    }
}
