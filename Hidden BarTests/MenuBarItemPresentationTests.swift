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

    func testThirdPartyUsesSourceAppNameEvenWhenOwnerIsControlCenter() {
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(
                axTitle: "控制中心",
                windowName: "Item-0",
                appName: "Control Center",
                sourceAppName: "ChatGPT"
            ),
            "ChatGPT"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(
                axTitle: "控制中心",
                windowName: "130",
                appName: "控制中心",
                sourceAppName: "微信"
            ),
            "微信"
        )
    }

    func testGenericAXTitleDoesNotHideSystemWindowName() {
        XCTAssertEqual(
            MenuBarItemPresentation.displayName(
                axTitle: "控制中心",
                windowName: "Battery",
                appName: "Control Center",
                sourceAppName: "Control Center"
            ),
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

    func testHidesUnidentifiedControlCenterRows() {
        XCTAssertFalse(MenuBarItemPresentation.isIdentifiableRow(title: "控制中心", icon: nil))
        XCTAssertFalse(MenuBarItemPresentation.isIdentifiableRow(title: "Control Center", icon: nil))
        XCTAssertTrue(MenuBarItemPresentation.isIdentifiableRow(title: "微信", icon: nil))
        XCTAssertTrue(MenuBarItemPresentation.isIdentifiableRow(title: "Wi-Fi", icon: nil))
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        XCTAssertTrue(MenuBarItemPresentation.isIdentifiableRow(title: "控制中心", icon: icon))
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

    func testTrailingRoomRejectsWhenFlushToTheNotch() {
        XCTAssertFalse(MenuBarItemPresentation.trailingHasRoom(usableMinX: 800, leftmostItemMinX: 802, itemWidth: 37))
        XCTAssertTrue(MenuBarItemPresentation.trailingHasRoom(usableMinX: 800, leftmostItemMinX: 860, itemWidth: 37))
    }

    func testCollapsedRoomUsesShownItemsNotExpandedHiddenOnes() {
        XCTAssertTrue(
            MenuBarItemPresentation.collapsedTrailingHasRoom(
                notchMaxX: 798,
                separatorWidth: 20,
                expandWidth: 18,
                leftmostShownMinX: 1000,
                itemWidth: 31
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.collapsedTrailingHasRoom(
                notchMaxX: 798,
                separatorWidth: 20,
                expandWidth: 18,
                leftmostShownMinX: 840,
                itemWidth: 31
            )
        )
    }

    func testPathThroughTheNotchCountsAsCrossing() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertTrue(MenuBarItemPresentation.pathCrossesNotch(from: 1000, to: 661, notch: notch))
        XCTAssertTrue(MenuBarItemPresentation.pathCrossesNotch(from: 664, to: 987, notch: notch))
        XCTAssertFalse(MenuBarItemPresentation.pathCrossesNotch(from: 973, to: 1102, notch: notch))
        XCTAssertFalse(MenuBarItemPresentation.pathCrossesNotch(from: 580, to: 600, notch: notch))
    }

    func testHidingAcrossTheNotchIsNeverTrailingFull() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertFalse(
            MenuBarItemPresentation.shouldBlockAsTrailingFull(
                sourceMidX: 1040,
                targetMidX: 600,
                notch: notch,
                trailingIsFull: true
            )
        )
    }

    func testShowingAcrossTheNotchBlocksOnlyWhenTrailingIsFull() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertTrue(
            MenuBarItemPresentation.shouldBlockAsTrailingFull(
                sourceMidX: 600,
                targetMidX: 1040,
                notch: notch,
                trailingIsFull: true
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.shouldBlockAsTrailingFull(
                sourceMidX: 600,
                targetMidX: 1040,
                notch: notch,
                trailingIsFull: false
            )
        )
    }

    func testLeftmostTrailingItemIgnoresNotchOverlap() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertEqual(
            MenuBarItemPresentation.leftmostTrailingMinX(
                frames: [
                    CGRect(x: 790, y: 0, width: 30, height: 29),
                    CGRect(x: 820, y: 0, width: 24, height: 29),
                    CGRect(x: 580, y: 0, width: 28, height: 29)
                ],
                notch: notch
            ),
            820
        )
    }

    func testUnclipPushesHalfIconFullyOffTheNotch() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertEqual(
            MenuBarItemPresentation.unclipMinX(CGRect(x: 620, y: 0, width: 37, height: 29), notch: notch),
            605
        )
        XCTAssertEqual(
            MenuBarItemPresentation.unclipMinX(CGRect(x: 790, y: 0, width: 30, height: 29), notch: notch),
            798
        )
        XCTAssertNil(
            MenuBarItemPresentation.unclipMinX(CGRect(x: 580, y: 0, width: 37, height: 29), notch: notch)
        )
    }

    func testWedgeDetectsIconStuckBetweenSeparatorAndChevron() {
        let separator = CGRect(x: 900, y: 0, width: 8, height: 29)
        let expand = CGRect(x: 910, y: 0, width: 18, height: 29)
        XCTAssertTrue(
            MenuBarItemPresentation.isWedgedBetween(
                CGRect(x: 904, y: 0, width: 37, height: 29),
                first: separator,
                second: expand
            )
        )
        XCTAssertFalse(
            MenuBarItemPresentation.isWedgedBetween(
                CGRect(x: 940, y: 0, width: 37, height: 29),
                first: separator,
                second: expand
            )
        )
    }

    func testNotchIntersectionDetectsHalfClippedIcons() {
        let notch = CGRect(x: 642, y: 0, width: 156, height: 32)
        XCTAssertTrue(MenuBarItemPresentation.intersectsNotch(CGRect(x: 620, y: 0, width: 37, height: 29), notch: notch))
        XCTAssertFalse(MenuBarItemPresentation.intersectsNotch(CGRect(x: 580, y: 0, width: 37, height: 29), notch: notch))
        XCTAssertFalse(MenuBarItemPresentation.intersectsNotch(CGRect(x: 820, y: 0, width: 37, height: 29), notch: notch))
    }

    func testSectionSplitsOnSeparator() {
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 700, separatorMidX: 798), .hidden)
        XCTAssertEqual(MenuBarItemPresentation.section(itemMidX: 900, separatorMidX: 798), .visible)
    }

    func testVisibleBoundsIgnoresTransparentPadding() {
        let image = CGImage(
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(
                repeating: 0, count: 8 * 8 * 4
            ) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        XCTAssertNil(MenuBarItemPresentation.visibleBounds(of: image))
    }

    func testColorfulDetectionRequiresSaturation() {
        let gray = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([
                200, 200, 200, 255, 200, 200, 200, 255,
                200, 200, 200, 255, 200, 200, 200, 255
            ]) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let color = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([
                30, 180, 80, 255, 30, 180, 80, 255,
                30, 180, 80, 255, 30, 180, 80, 255
            ]) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        XCTAssertFalse(MenuBarItemPresentation.isColorful(gray))
        XCTAssertTrue(MenuBarItemPresentation.isColorful(color))
    }

    func testDoesNotFallBackToSharedAppIcon() {
        let appIcon = NSImage(size: NSSize(width: 16, height: 16))
        XCTAssertNil(MenuBarItemPresentation.rowIcon(windowSnapshot: nil, appIcon: appIcon, isSystemExtra: true))
        XCTAssertNotNil(MenuBarItemPresentation.rowIcon(windowSnapshot: nil, appIcon: appIcon, isSystemExtra: false))
        XCTAssertFalse(MenuBarItemPresentation.isUsableSnapshot(appIcon))
    }

    func testSkipsHeavyAppsWhenProbingExtras() {
        XCTAssertFalse(MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: "com.google.Chrome.helper"))
        XCTAssertTrue(MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: "com.openai.chat"))
        XCTAssertTrue(MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: "com.tencent.xinWeChat"))
        XCTAssertTrue(MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: "com.apple.controlcenter"))
    }

    func testMatchesThirdPartySourceByXBeforeControlCenter() {
        let matches = MenuBarItemPresentation.matchedExtras(
            itemMidXs: [100, 140],
            extras: [
                (title: "控制中心", x: 90, width: 20, sourceAppName: "Control Center", sourcePID: 1),
                (title: nil, x: 92, width: 20, sourceAppName: "ChatGPT", sourcePID: 2),
                (title: "Wi-Fi", x: 130, width: 20, sourceAppName: "Control Center", sourcePID: 1)
            ]
        )
        XCTAssertEqual(matches[0]?.sourceAppName, "ChatGPT")
        XCTAssertEqual(matches[1]?.sourceAppName, "Control Center")
        XCTAssertEqual(matches[1]?.title, "Wi-Fi")
    }

    func testBundleIdentifierOnControlCenterExtraUsesTheRealApp() {
        XCTAssertEqual(
            MenuBarItemPresentation.owningAppName(scannedAppName: "控制中心", bundleAppName: "ChatGPT"),
            "ChatGPT"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.owningAppName(scannedAppName: "控制中心", bundleAppName: nil),
            "控制中心"
        )
    }

    func testMatchesThirdPartyWhenCentersAreAFewPixelsOff() {
        let matches = MenuBarItemPresentation.matchedExtras(
            itemMidXs: [100],
            extras: [
                (title: nil, x: 70, width: 20, sourceAppName: "微信", sourcePID: 3)
            ]
        )
        XCTAssertEqual(matches[0]?.sourceAppName, "微信")
    }

    func testAssignsThirdPartyEvenWhenFarFromWindow() {
        let matches = MenuBarItemPresentation.matchedExtras(
            itemMidXs: [100],
            extras: [
                (title: nil, x: 10, width: 20, sourceAppName: "微信", sourcePID: 3)
            ]
        )
        XCTAssertEqual(matches[0]?.sourceAppName, "微信")
    }

    func testDuplicateBundleIDsKeepTheFirstName() {
        let names = MenuBarItemPresentation.namesByBundleID([
            ("com.tencent.xinWeChat", "微信"),
            ("com.tencent.xinWeChat", "WeChat"),
            ("com.openai.chat", "ChatGPT")
        ])
        XCTAssertEqual(names["com.tencent.xinWeChat"], "微信")
        XCTAssertEqual(names["com.openai.chat"], "ChatGPT")
        XCTAssertEqual(names.count, 2)
    }

    func testResolvesBundleIDHintToRealApp() {
        let known = [
            "com.openai.chat": "ChatGPT",
            "com.tencent.xinWeChat": "微信",
            "com.apple.controlcenter": "控制中心"
        ]
        XCTAssertEqual(
            MenuBarItemPresentation.resolvedSourceName(
                ownerName: "控制中心",
                extraSourceName: "控制中心",
                hint: "com.openai.chat",
                knownApps: known
            ),
            "ChatGPT"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.resolvedSourceName(
                ownerName: "控制中心",
                extraSourceName: "控制中心",
                hint: "com.tencent.xinWeChat.status",
                knownApps: known
            ),
            "微信"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.resolvedSourceName(
                ownerName: "控制中心",
                extraSourceName: "控制中心",
                hint: "com.apple.controlcenter.WiFi",
                knownApps: known
            ),
            "控制中心"
        )
        XCTAssertEqual(
            MenuBarItemPresentation.resolvedSourceName(
                ownerName: "控制中心",
                extraSourceName: "微信",
                hint: "com.openai.chat",
                knownApps: known
            ),
            "微信"
        )
    }
}
