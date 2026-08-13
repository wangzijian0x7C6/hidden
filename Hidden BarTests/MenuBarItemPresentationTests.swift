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
    }

    func testSectionSplitsOnSeparator() {
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 700, separatorMidX: 798), .hidden)
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 900, separatorMidX: 798), .visible)
    }

    func testDoesNotFallBackToSharedAppIcon() {
        let appIcon = NSImage(size: NSSize(width: 16, height: 16))
        XCTAssertNil(MenuBarItemPresentation.rowIcon(windowSnapshot: nil, appIcon: appIcon))
    }
}
