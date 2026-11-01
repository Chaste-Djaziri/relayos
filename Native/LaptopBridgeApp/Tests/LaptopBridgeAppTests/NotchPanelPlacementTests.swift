// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NotchPanelPlacementTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class NotchPanelPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    private func notch(
        _ phase: NotchPanelPhase,
        hasLiveActivity: Bool = false
    ) -> NotchPanelPlacement.Layout {
        NotchPanelPlacement.layout(
            displayFrame: screen,
            visibleFrame: visible,
            hardwareNotchWidth: 185,
            phase: phase,
            hasLiveActivity: hasLiveActivity
        )
    }

    func testIdleCollapsedMatchesHardwareNotchFootprintWithNoWings() {
        let layout = notch(.collapsed, hasLiveActivity: false)
        XCTAssertTrue(layout.hasHardwareNotch)
        XCTAssertFalse(layout.hasLiveActivity)
        XCTAssertEqual(layout.frame.height, layout.topBandHeight)
        XCTAssertEqual(layout.frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(layout.topBandHeight, 38)
        XCTAssertEqual(layout.centerGap, 185, accuracy: 0.01)
        XCTAssertEqual(layout.leftWidth, 0, accuracy: 0.01)
        XCTAssertEqual(layout.rightWidth, 0, accuracy: 0.01)
        XCTAssertEqual(
            layout.frame.width,
            layout.centerGap + (layout.topCornerRadius * 2),
            accuracy: 0.01
        )
    }

    @MainActor
    func testHoverExitGracePeriodAvoidsAccidentalCollapse() {
        XCTAssertGreaterThanOrEqual(NotchPanelCoordinator.hoverCollapseDelayMilliseconds, 600)
    }

    func testApprovalIsAFirstClassNotchDestination() {
        XCTAssertEqual(NotchSubpage.approvals.title, "Approve")
        XCTAssertEqual(NotchSubpage.approvals.icon, "checkmark.shield.fill")
        XCTAssertGreaterThanOrEqual(NotchPanelPhase.expanded.trayHeight, 170)
    }

    func testLiveActivityCollapsedRevealsLeftAndRightStatusWings() {
        let idle = notch(.collapsed, hasLiveActivity: false)
        let active = notch(.collapsed, hasLiveActivity: true)
        XCTAssertTrue(active.hasLiveActivity)
        XCTAssertGreaterThan(active.leftWidth, 0)
        XCTAssertGreaterThan(active.rightWidth, 0)
        XCTAssertGreaterThan(active.frame.width, idle.frame.width)
        XCTAssertEqual(active.frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(
            active.leftWidth + active.centerGap + active.rightWidth + (active.topCornerRadius * 2),
            active.frame.width,
            accuracy: 0.01
        )
    }

    func testIdleHoverEnlargesSlightlyWithNoWingsOrFullTray() {
        let collapsed = notch(.collapsed, hasLiveActivity: false)
        let hover = notch(.hovered, hasLiveActivity: false)
        let expanded = notch(.expanded, hasLiveActivity: false)
        XCTAssertGreaterThan(hover.frame.width, collapsed.frame.width)
        XCTAssertLessThan(hover.frame.width, expanded.frame.width)
        XCTAssertEqual(hover.leftWidth, 0, accuracy: 0.01)
        XCTAssertEqual(hover.rightWidth, 0, accuracy: 0.01)
        XCTAssertEqual(hover.frame.height, hover.topBandHeight + NotchPanelPhase.hovered.trayHeight)
        XCTAssertLessThan(hover.frame.height, expanded.frame.height)
        XCTAssertEqual(hover.frame.maxY, collapsed.frame.maxY, accuracy: 0.01)
    }

    func testClickExpandsDownwardAndLeavingReturnsToCompactGeometry() {
        let collapsed = notch(.collapsed)
        let expanded = notch(.expanded)
        XCTAssertEqual(expanded.frame.height, expanded.topBandHeight + NotchPanelPhase.expanded.trayHeight)
        XCTAssertEqual(expanded.frame.maxY, collapsed.frame.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(expanded.frame.width, collapsed.frame.width)
        XCTAssertGreaterThan(expanded.leftWidth, 0)
        XCTAssertGreaterThan(expanded.rightWidth, 0)
        XCTAssertEqual(
            expanded.leftWidth + expanded.centerGap + expanded.rightWidth + (expanded.topCornerRadius * 2),
            expanded.frame.width,
            accuracy: 0.01
        )
        XCTAssertEqual(notch(.collapsed).frame, collapsed.frame)
    }

    func testLargerHousingKeepsAdditionalBlackExclusionWhenActiveOrExpanded() {
        let monitor = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let usable = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor,
                visibleFrame: usable,
                hardwareNotchWidth: 220,
                phase: phase,
                hasLiveActivity: true
            )
            XCTAssertGreaterThanOrEqual(layout.centerGap, 232)
            XCTAssertEqual(layout.frame.midX, usable.midX, accuracy: 0.01)
            XCTAssertEqual(layout.frame.maxY, monitor.maxY, accuracy: 0.01)
            XCTAssertGreaterThan(layout.leftWidth, 0)
            XCTAssertGreaterThan(layout.rightWidth, 0)
        }
    }

    func testAllDisplaysTouchVeryTopEdgeOfScreen() {
        let monitor = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let usable = CGRect(x: -1920, y: -120, width: 1920, height: 1040)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor,
                visibleFrame: usable,
                phase: phase
            )
            XCTAssertFalse(layout.hasHardwareNotch)
            XCTAssertEqual(layout.frame.midX, usable.midX, accuracy: 0.01)
            XCTAssertEqual(layout.frame.maxY, monitor.maxY, accuracy: 0.01)
        }
    }

    func testNarrowDisplayClampsWidthCleanly() {
        let monitor = CGRect(x: 50, y: 100, width: 330, height: 300)
        let usable = CGRect(x: 50, y: 100, width: 330, height: 262)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor,
                visibleFrame: usable,
                hardwareNotchWidth: 90,
                phase: phase,
                hasLiveActivity: true
            )
            XCTAssertLessThanOrEqual(layout.frame.width, usable.width - 24)
            XCTAssertGreaterThan(layout.leftWidth, 0)
            XCTAssertGreaterThan(layout.rightWidth, 0)
            XCTAssertEqual(
                layout.leftWidth + layout.centerGap + layout.rightWidth + (layout.topCornerRadius * 2),
                layout.frame.width,
                accuracy: 0.01
            )
        }
    }

    func testNotchShapeFlaresOutwardsAtTopEdge() {
        let rect = CGRect(x: 0, y: 0, width: 205, height: 38)
        let shape = NotchShape(topCornerRadius: 10, bottomCornerRadius: 13)
        let bounds = shape.path(in: rect).boundingRect
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 205, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 38, accuracy: 0.01)
    }

    @MainActor
    func testSavedNotchSubpageRestoresAndInvalidValueFallsBackToActivity() {
        let suite = "RelayOS.NotchPanelPlacementTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to create isolated user defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NotchPanelCoordinator.restoredSubpage(from: defaults), .activity)
        defaults.set(NotchSubpage.music.rawValue, forKey: "relayos.notch.selected-subpage")
        XCTAssertEqual(NotchPanelCoordinator.restoredSubpage(from: defaults), .music)
        defaults.set("unknown-page", forKey: "relayos.notch.selected-subpage")
        XCTAssertEqual(NotchPanelCoordinator.restoredSubpage(from: defaults), .activity)
    }

    @MainActor
    func testNotchWindowIsExcludedFromScreenshotsAndUnconstrainedAtTopEdge() {
        let topRect = CGRect(x: 650, y: 944, width: 205, height: 38)
        let window = RelayOSNotchWindow(
            contentRect: topRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(window.constrainFrameRect(topRect, to: nil), topRect)
    }

    func testSpotifyTrackMetadataAndMillisecondsDuration() {
        let sep = "\u{001E}"
        let result = ["playing", "A Song || With a Separator", "Artist", "Album",
                      "72.5", "245000", "https://i.scdn.co/image/test"].joined(separator: sep)
        let track = NotchMediaController.parseSnapshot(
            result, player: "Spotify", bundle: "com.spotify.client")
        XCTAssertEqual(track?.trackTitle, "A Song || With a Separator")
        XCTAssertEqual(track?.duration, 245)
        XCTAssertEqual(track?.elapsed, 72.5)
        XCTAssertEqual(track?.artworkURL, "https://i.scdn.co/image/test")
        XCTAssertTrue(track?.isPlaying == true)
    }

    func testAppleMusicSecondsAndPausedTrack() {
        let sep = "\u{001E}"
        let result = ["paused", "Track", "Singer", "Album", "30", "185.25", ""]
            .joined(separator: sep)
        let track = NotchMediaController.parseSnapshot(
            result, player: "Music", bundle: "com.apple.Music")
        XCTAssertEqual(track?.duration, 185.25)
        XCTAssertEqual(track?.elapsed, 30)
        XCTAssertEqual(track?.isPlaying, false)
    }

    func testMalformedMetadataAndMissingDurationShowNoFakeProgress() {
        let sep = "\u{001E}"
        XCTAssertNil(NotchMediaController.parseSnapshot(
            "stopped", player: "Music", bundle: "com.apple.Music"))
        let raw = ["playing", "Track", "Artist", "Album", "bad", "NaN", ""]
            .joined(separator: sep)
        let track = NotchMediaController.parseSnapshot(
            raw, player: "Music", bundle: "com.apple.Music")
        XCTAssertNotNil(track)
        XCTAssertNil(track?.duration)
        XCTAssertNil(track?.elapsed)
        XCTAssertNil(NotchPlaybackTimeline.position(
            elapsed: nil, duration: 200, isPlaying: true,
            observedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 120)))
    }

    func testPlaybackProgressAdvancesOnlyWhilePlayingAndClampsToDuration() {
        let started = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 110)
        XCTAssertEqual(NotchPlaybackTimeline.position(
            elapsed: 43, duration: 180, isPlaying: true,
            observedAt: started, now: now), 53)
        XCTAssertEqual(NotchPlaybackTimeline.position(
            elapsed: 43, duration: 180, isPlaying: false,
            observedAt: started, now: now), 43)
        XCTAssertEqual(NotchPlaybackTimeline.position(
            elapsed: 179, duration: 180, isPlaying: true,
            observedAt: started, now: now), 180)
        XCTAssertEqual(NotchPlaybackTimeline.clock(83), "1:23")
        XCTAssertEqual(NotchPlaybackTimeline.clock(3703), "1:01:43")
        XCTAssertEqual(NotchPlaybackTimeline.clock(nil), "–:––")
    }


    func testGlobalMediaKeyMappingMatchesSystemMediaEvents() {
        XCTAssertEqual(RelayOSMediaKeys.Key.toggle.rawValue, 16)
        XCTAssertEqual(RelayOSMediaKeys.Key.next.rawValue, 17)
        XCTAssertEqual(RelayOSMediaKeys.Key.previous.rawValue, 18)
        // Do not post a global CGEvent from unit tests.
    }

}
