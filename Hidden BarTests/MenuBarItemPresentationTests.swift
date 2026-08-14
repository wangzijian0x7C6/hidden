import XCTest

final class MenuBarItemPresentationTests: XCTestCase {
    func testControlCenterExtrasUseWindowOrAXNameNotTheAppName() {
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: "Wi-Fi", windowName: nil, appName: "Control Center"),
            "Wi-Fi"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "Battery", appName: "Control Center"),
            "Battery"
        )
    }

    func testIgnoresPlaceholderWindowNames() {
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "Item-3", appName: "Control Center"),
            "Control Center"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: " ", windowName: "-", appName: "Things"),
            "Things"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "BentoBox-0", appName: "Control Center"),
            "Control Center"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "com.tencent.token-dashboard.main", appName: "QQ"),
            "QQ"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "AudioVideoModule", appName: "Control Center"),
            NSLocalizedString("Sound", comment: "")
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "NowPlaying", appName: "Control Center"),
            NSLocalizedString("Now Playing", comment: "")
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "iOA_white_icon", appName: "iOA"),
            "iOA"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "130", appName: "WeChat"),
            "WeChat"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(axTitle: nil, windowName: "LOGO 16 black", appName: "TT"),
            "TT"
        )
    }

    func testSkipsAccessibilityWhenUntrusted() {
        XCTAssertEqual(
            MenuBarItemPresentation.accessibilityPidsToScan(extraPids: [11, 22, 11], trusted: false),
            []
        )
    }

    func testOnlyScansPidsThatOwnExtras() {
        XCTAssertEqual(
            MenuBarItemPresentation.accessibilityPidsToScan(extraPids: [22, 11, 22], trusted: true),
            [11, 22]
        )
        XCTAssertEqual(
            MenuBarItemPresentation.accessibilityPidsToScan(extraPids: [11], runningPids: [22, 11], trusted: true),
            [11, 22]
        )
    }

    func testDropsOwnProcessAndOversizedWindows() {
        XCTAssertFalse(
            MenuBarItemPresentation.isManageableExtra(
                ownerPID: 99,
                ownPID: 99,
                layer: 25,
                width: 31,
                height: 29
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.isManageableExtra(
                ownerPID: 12,
                ownPID: 99,
                layer: 25,
                width: 800,
                height: 29
            )
        )
        XCTAssertTrue(
            MenuBarItemPresentation.isManageableExtra(
                ownerPID: 12,
                ownPID: 99,
                layer: 25,
                width: 31,
                height: 29
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.isManageableExtra(
                ownerPID: 12,
                ownPID: 99,
                layer: 25,
                width: 31,
                height: 29,
                windowName: "hiddenbar_separate"
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.isManageableExtra(
                ownerPID: 12,
                ownPID: 99,
                layer: 25,
                width: 31,
                height: 29,
                ownerName: "Hidden Bar"
            )
        )
    }

    func testMatchesTitlesBySortedOrderWhenCountsAlign() {
        let titles = MenuBarItemPresentation.matchedTitles(
            itemMidXs: [120, 80],
            extras: [
                (title: "Battery", x: 70, width: 20),
                (title: "Wi-Fi", x: 110, width: 20)
            ]
        )
        XCTAssertEqual(titles, ["Wi-Fi", "Battery"])
    }

    func testPrefersDescriptionWhenTitleIsControlCenter() {
        XCTAssertEqual(
            MenuBarItemPresentation.axName(title: "控制中心", description: "Wi-Fi，已接入，3格"),
            "Wi-Fi"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.axName(title: "Control Center", description: "Battery, 80%"),
            "Battery"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.shortName("播放中，音乐"),
            "播放中"
        )
    }

    func testDoesNotAssignTheSameExtraToTwoItems() {
        let titles = MenuBarItemPresentation.matchedTitles(
            itemMidXs: [100, 108],
            extras: [(title: "Wi-Fi", x: 90, width: 20)]
        )
        XCTAssertEqual(titles.compactMap { $0 }.count, 1)
        XCTAssertEqual(titles.compactMap { $0 }.first, "Wi-Fi")
    }

    func testSectionSplitsOnSeparator() {
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 700, separatorMidX: 798), .hidden)
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 900, separatorMidX: 798), .visible)
    }

    func testDoesNotFallBackToSharedAppIcon() {
        let appIcon = NSImage(size: NSSize(width: 16, height: 16))
        XCTAssertNil(MenuBarItemPresentation.rowIcon(windowSnapshot: nil, appIcon: appIcon, isSystemExtra: true))
        XCTAssertNotNil(MenuBarItemPresentation.rowIcon(windowSnapshot: nil, appIcon: appIcon, isSystemExtra: false))
    }
}
