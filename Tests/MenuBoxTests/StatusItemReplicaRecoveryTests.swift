import XCTest
@testable import MenuBox

final class StatusItemReplicaRecoveryTests: XCTestCase {
    func testInterruptedObservationRequiresTwoNewSamplesAndKeepsCooldown() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [38])]
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 0))
        recovery.resetObservation()
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 5))
        XCTAssertTrue(recovery.shouldRepair(bars: bars, markerHidden: false, now: 10))
        recovery.resetObservation()
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 15))
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 20))
    }

    func testChangingMarkerStateDoesNotCombineUnrelatedMissingSamples() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [16])]
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 0))
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: true, now: 5))
        XCTAssertTrue(recovery.shouldRepair(bars: bars, markerHidden: true, now: 10))
    }

    private func bar(widths: [CGFloat], x: CGFloat = 0) -> NativeMenuBarSnapshot.Bar {
        .init(frame: CGRect(x: x, y: 0, width: 200, height: 30), items: widths.enumerated().map { i, width in
            .init(id: "own:\(i)", bundle: NativeMenuBarPreferences.ownBundle,
                  frame: CGRect(x: x + CGFloat(i) * 40, y: 0, width: width, height: 30), identifier: "")
        })
    }

    func testPersistentMissingReplicaRepairsWithCooldown() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [38, 38]), bar(widths: [38], x: 200)]
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 0))
        XCTAssertTrue(recovery.shouldRepair(bars: bars, markerHidden: false, now: 5))
        XCTAssertFalse(recovery.shouldRepair(bars: bars, markerHidden: false, now: 10))
        XCTAssertTrue(recovery.shouldRepair(bars: bars, markerHidden: false, now: 35))
    }

    func testTransientFailureAndNormalCollapsedMarkerNeverRepair() {
        var recovery = StatusItemReplicaRecovery()
        XCTAssertFalse(recovery.shouldRepair(bars: [bar(widths: [38])], markerHidden: false, now: 0))
        XCTAssertFalse(recovery.shouldRepair(bars: [bar(widths: [38, 38])], markerHidden: false, now: 5))
        XCTAssertFalse(recovery.shouldRepair(bars: [bar(widths: [38])], markerHidden: false, now: 10))
        for time in [15.0, 20.0] {
            XCTAssertFalse(recovery.shouldRepair(bars: [bar(widths: [16, 38])], markerHidden: true, now: time))
        }
    }

    func testCollapsedMarkerAloneDoesNotCountAsBox() {
        var recovery = StatusItemReplicaRecovery()
        XCTAssertFalse(recovery.shouldRepair(bars: [bar(widths: [16])], markerHidden: true, now: 0))
        XCTAssertTrue(recovery.shouldRepair(bars: [bar(widths: [16])], markerHidden: true, now: 5))
    }
}
