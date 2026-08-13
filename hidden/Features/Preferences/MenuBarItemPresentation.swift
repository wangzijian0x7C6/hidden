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

    var primaryName: String {
        MenuBarItemPresentation.displayName(axTitle: title, windowName: nil, appName: appName)
    }
}

enum MenuBarItemPresentation {
    static func displayName(axTitle: String?, windowName: String?, appName: String) -> String {
        cleaned(axTitle) ?? cleaned(windowName) ?? appName
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "-",
              !value.hasPrefix("Item-")
        else {
            return nil
        }
        return value
    }

    static func isManageableExtra(
        ownerPID: pid_t,
        ownPID: pid_t,
        layer: Int?,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        ownerPID != ownPID
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
}
