import XCTest
@testable import FocusGuard

final class SetupNeedTests: XCTestCase {
    private func flags(installed: Bool = true, legacy: Bool = false, update: Bool = false, running: Bool = true) -> SetupNeed.Flags {
        SetupNeed.Flags(daemonInstalled: installed, legacyDaemonRunning: legacy, needsUpdate: update, daemonRunning: running)
    }

    func testHealthyNeedsNoSetup() {
        XCTAssertNil(SetupNeed.evaluate(flags()))
    }

    func testNotInstalled() {
        XCTAssertEqual(SetupNeed.evaluate(flags(installed: false, running: false)), .notInstalled)
    }

    func testLegacyDaemonOutranksTheRest() {
        XCTAssertEqual(SetupNeed.evaluate(flags(installed: false, legacy: true, running: false)), .legacyDaemon)
        XCTAssertEqual(SetupNeed.evaluate(flags(legacy: true, update: true, running: false)), .legacyDaemon)
    }

    func testNeedsUpdate() {
        XCTAssertEqual(SetupNeed.evaluate(flags(update: true)), .needsUpdate)
        XCTAssertEqual(SetupNeed.evaluate(flags(update: true, running: false)), .needsUpdate, "update outranks not running")
    }

    func testInstalledButNotRunning() {
        XCTAssertEqual(SetupNeed.evaluate(flags(running: false)), .notRunning)
    }

    func testEveryReasonHasADistinctTitle() {
        let all: [SetupNeed.Reason] = [.legacyDaemon, .notInstalled, .needsUpdate, .notRunning]
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
    }
}
