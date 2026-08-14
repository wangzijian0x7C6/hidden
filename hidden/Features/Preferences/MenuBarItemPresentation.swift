import AppKit

enum MenuBarItemSection: Equatable {
    case hidden
    case visible
}

struct ManagedMenuBarItem {
    let id: String
    let windowNumber: Int
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let quartzRect: CGRect
    let section: MenuBarItemSection

    var primaryName: String { title }
}

enum MenuBarItemPresentation {
    private static let windowNameAliases = [
        "AudioVideoModule": "Sound",
        "NowPlaying": "Now Playing",
        "WiFi": "Wi-Fi",
        "Battery": "Battery",
        "Focus": "Focus",
        "Display": "Display",
        "UserNotifications": "Notifications",
        "ScreenMirroring": "Screen Mirroring",
        "MusicRecognition": "Music Recognition",
        "KeyboardBrightness": "Keyboard Brightness"
    ]

    static func displayName(axTitle: String?, windowName: String?, appName: String) -> String {
        cleaned(axTitle) ?? cleaned(windowName) ?? appName
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "-",
              !value.hasPrefix("Item-"),
              !value.hasPrefix("hiddenbar_"),
              !value.hasPrefix("BentoBox")
        else {
            return nil
        }
        if let alias = windowNameAliases[value] {
            return NSLocalizedString(alias, comment: "")
        }
        if value.hasSuffix("Module") { return nil }
        if value.contains("."), !value.contains(" ") { return nil }
        return value
    }

    static func isManageableExtra(
        ownerPID: pid_t,
        ownPID: pid_t,
        layer: Int?,
        width: CGFloat,
        height: CGFloat,
        windowName: String? = nil,
        ownerName: String? = nil
    ) -> Bool {
        ownerPID != ownPID
            && ownerName != "Hidden Bar"
            && !(windowName?.hasPrefix("hiddenbar_") ?? false)
            && (layer == nil || layer == 25)
            && height > 4
            && width > 4
            && width < 240
    }

    static func section(itemMidX: CGFloat, separatorMidX: CGFloat) -> MenuBarItemSection {
        itemMidX < separatorMidX ? .hidden : .visible
    }

    static func accessibilityPidsToScan(extraPids: [pid_t], trusted: Bool) -> [pid_t] {
        guard trusted else { return [] }
        return Array(Set(extraPids)).sorted()
    }

    static func rowIcon(windowSnapshot: NSImage?, appIcon _: NSImage?) -> NSImage? {
        windowSnapshot
    }

    static func matchedTitles(
        itemMidXs: [CGFloat],
        extras: [(title: String, x: CGFloat, width: CGFloat)]
    ) -> [String?] {
        let sortedExtras = extras.sorted { $0.x < $1.x }
        let sortedItems = itemMidXs.enumerated().sorted { $0.element < $1.element }
        if sortedExtras.count == sortedItems.count, !sortedItems.isEmpty {
            var result = [String?](repeating: nil, count: itemMidXs.count)
            for (index, item) in sortedItems.enumerated() {
                result[item.offset] = cleaned(sortedExtras[index].title)
            }
            return result
        }
        return itemMidXs.map { matchedTitle(itemMidX: $0, extras: extras) }
    }

    static func matchedTitle(
        itemMidX: CGFloat,
        extras: [(title: String, x: CGFloat, width: CGFloat)]
    ) -> String? {
        extras.min { lhs, rhs in
            abs((lhs.x + lhs.width / 2) - itemMidX) < abs((rhs.x + rhs.width / 2) - itemMidX)
        }.flatMap { extra in
            let extraMid = extra.x + extra.width / 2
            abs(extraMid - itemMidX) < max(36, extra.width) ? cleaned(extra.title) : nil
        }
    }
}
