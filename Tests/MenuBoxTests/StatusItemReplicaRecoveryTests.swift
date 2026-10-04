// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import XCTest
@testable import MenuBox

final class StatusItemReplicaRecoveryTests: XCTestCase {
    func testInterruptedObservationRequiresTwoNewSamplesAndKeepsCooldown() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [38])]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 0))
        recovery.resetObservation()
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 5))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 10), .reregisterItems)
        recovery.resetObservation()
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 15))
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 20))
    }

    func testChangingMarkerStateDoesNotCombineUnrelatedMissingSamples() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [16])]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 0))
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: true, now: 5))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: true, now: 10), .reregisterItems)
    }

    private func bar(widths: [CGFloat], x: CGFloat = 0) -> NativeMenuBarSnapshot.Bar {
        .init(frame: CGRect(x: x, y: 0, width: 200, height: 30), items: widths.enumerated().map { i, width in
            .init(id: "own:\(i)", bundle: NativeMenuBarPreferences.ownBundle,
                  frame: CGRect(x: x + CGFloat(i) * 40, y: 0, width: width, height: 30), identifier: widths.count == 2 ? (i == 0 ? "MenuBox.marker" : "MenuBox.main") : "")
        })
    }

    func testPersistentMissingReplicaRepairsWithCooldown() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [38, 38]), bar(widths: [38], x: 200)]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 0))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 5), .reregisterItems)
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 10))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 35), .reregisterItems)
    }

    func testTransientFailureAndNormalCollapsedMarkerNeverRepair() {
        var recovery = StatusItemReplicaRecovery()
        XCTAssertNil(recovery.repair(bars: [bar(widths: [38])], markerHidden: false, now: 0))
        XCTAssertNil(recovery.repair(bars: [bar(widths: [38, 38])], markerHidden: false, now: 5))
        XCTAssertNil(recovery.repair(bars: [bar(widths: [38])], markerHidden: false, now: 10))
        for time in [15.0, 20.0] {
            XCTAssertNil(recovery.repair(bars: [bar(widths: [16, 38])], markerHidden: true, now: time))
        }
    }

    func testMissingIdentifiersRefreshBeforeRecreatingAndRespectCooldown() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [unidentifiedBar(0), unidentifiedBar(200)]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 0))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 5), .refreshIdentifiers)
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 10))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 35), .reregisterItems)
    }

    func testPartialIdentificationAvoidsRecreatingIntactReplicas() {
        var recovery = StatusItemReplicaRecovery()
        var identified = unidentifiedBar(0)
        identified.items[0] = .init(id: "box", bundle: NativeMenuBarPreferences.ownBundle,
            frame: identified.items[0].frame, identifier: "MenuBox.main")
        for time in [0.0, 5, 35] {
            XCTAssertNil(recovery.repair(bars: [identified, unidentifiedBar(200)], markerHidden: false, now: time))
        }
    }

    func testMissingBoxIdentityIsRefreshedEvenWhenMarkerCanResolveExpandedPair() {
        var recovery = StatusItemReplicaRecovery()
        var partial = unidentifiedBar(0)
        partial.items[0] = .init(id: "marker", bundle: NativeMenuBarPreferences.ownBundle,
            frame: partial.items[0].frame, identifier: "MenuBox.marker")
        let bars = [partial, unidentifiedBar(200)]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: 0))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 5), .refreshIdentifiers)
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: false, now: 35), .reregisterItems)
    }

    func testHealthyObservationResetsIdentityRepairEscalation() {
        var recovery = StatusItemReplicaRecovery()
        let broken = [unidentifiedBar(0)]
        XCTAssertNil(recovery.repair(bars: broken, markerHidden: false, now: 0))
        XCTAssertEqual(recovery.repair(bars: broken, markerHidden: false, now: 5), .refreshIdentifiers)
        XCTAssertNil(recovery.repair(bars: [bar(widths: [38, 38])], markerHidden: false, now: 10))
        XCTAssertNil(recovery.repair(bars: broken, markerHidden: false, now: 35))
        XCTAssertEqual(recovery.repair(bars: broken, markerHidden: false, now: 40), .refreshIdentifiers)
    }

    func testMissingHostsAndMissingIdentifiersDoNotShareDebounce() {
        var recovery = StatusItemReplicaRecovery()
        XCTAssertNil(recovery.repair(bars: [unidentifiedBar(0)], markerHidden: false, now: 0))
        XCTAssertNil(recovery.repair(bars: [bar(widths: [38])], markerHidden: false, now: 5))
        XCTAssertEqual(recovery.repair(bars: [bar(widths: [38])], markerHidden: false, now: 10), .reregisterItems)
    }

    func testHiddenBoxWithMissingIdentifierAlsoGetsRefreshed() {
        var recovery = StatusItemReplicaRecovery()
        let bars = [bar(widths: [38])]
        XCTAssertNil(recovery.repair(bars: bars, markerHidden: true, now: 0))
        XCTAssertEqual(recovery.repair(bars: bars, markerHidden: true, now: 5), .refreshIdentifiers)
    }

    func testContradictoryAndExtraHostsDoNotTriggerIdentityRepair() {
        let good = bar(widths: [38, 38])
        var conflict = bar(widths: [38, 38], x: 200)
        conflict.items = conflict.items.map { item in
            .init(id: item.id, bundle: item.bundle, frame: item.frame,
                identifier: item.identifier == "MenuBox.main" ? "MenuBox.marker" : "MenuBox.main")
        }
        for bars in [[good, conflict], [bar(widths: [38, 38, 38])]] {
            var recovery = StatusItemReplicaRecovery()
            for time in [0.0, 5, 35] {
                XCTAssertNil(recovery.repair(bars: bars, markerHidden: false, now: time))
            }
        }
    }

    private func unidentifiedBar(_ x: CGFloat) -> NativeMenuBarSnapshot.Bar {
        var result = bar(widths: [38, 38], x: x)
        result.items = result.items.map { .init(id: $0.id, bundle: $0.bundle, frame: $0.frame, identifier: "") }
        return result
    }

    func testHiddenThreeDisplayLayoutRepairsOnlyPersistentlyMissingHosts() {
        // Live failure: collapsed marker + Box on the laptop and far display,
        // neither host on the middle display, blank replica AX identifiers.
        let laptop = unidentifiedHiddenBar(0)
        let middle = bar(widths: [], x: -200)
        let far = unidentifiedHiddenBar(-400)
        var recovery = StatusItemReplicaRecovery()
        XCTAssertNil(recovery.repair(bars: [laptop, middle, far], markerHidden: true, now: 0))
        XCTAssertEqual(recovery.repair(bars: [laptop, middle, far], markerHidden: true, now: 5), .reregisterItems)
        // Once replicas return, missing identifiers take the less disruptive
        // refresh path first; never repeatedly recreate a healthy item pair.
        let repaired = [laptop, unidentifiedHiddenBar(-200), far]
        XCTAssertNil(recovery.repair(bars: repaired, markerHidden: true, now: 10))
        XCTAssertEqual(recovery.repair(bars: repaired, markerHidden: true, now: 35), .refreshIdentifiers)
    }

    private func unidentifiedHiddenBar(_ x: CGFloat) -> NativeMenuBarSnapshot.Bar {
        var result = bar(widths: [16, 38], x: x)
        result.items = result.items.map { .init(id: $0.id, bundle: $0.bundle, frame: $0.frame, identifier: "") }
        return result
    }

    func testCollapsedMarkerAloneDoesNotCountAsBox() {
        var recovery = StatusItemReplicaRecovery()
        XCTAssertNil(recovery.repair(bars: [bar(widths: [16])], markerHidden: true, now: 0))
        XCTAssertEqual(recovery.repair(bars: [bar(widths: [16])], markerHidden: true, now: 5), .reregisterItems)
    }
}
