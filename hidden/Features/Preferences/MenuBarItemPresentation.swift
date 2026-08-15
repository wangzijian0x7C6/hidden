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

    struct ExtraSource: Equatable {
        let title: String?
        let sourceAppName: String
        let sourcePID: pid_t
    }

    static func displayName(
        axTitle: String?,
        windowName: String?,
        appName: String,
        sourceAppName: String? = nil
    ) -> String {
        if let sourceAppName, !isSystemExtraOwner(sourceAppName) {
            return sourceAppName
        }
        if isSystemExtraOwner(sourceAppName ?? appName) {
            if let axTitle = specificName(axTitle) {
                return axTitle
            }
            if let windowName = cleaned(windowName) {
                return titleCaseIdentifier(windowName)
            }
        }
        return sourceAppName ?? appName
    }

    static func specificName(_ raw: String?) -> String? {
        cleaned(raw).flatMap { isGenericSystemName($0) ? nil : $0 }
    }

    static func isSystemExtraOwner(_ appName: String) -> Bool {
        isGenericSystemName(appName) || appName == "SystemUIServer" || appName == "Control Centre"
    }

    static func owningAppName(scannedAppName: String, bundleAppName: String?) -> String {
        if let bundleAppName, !isSystemExtraOwner(bundleAppName) {
            return bundleAppName
        }
        return scannedAppName
    }

    static func resolvedSourceName(
        ownerName: String,
        extraSourceName: String?,
        hint: String?,
        knownApps: [String: String]
    ) -> String {
        if let extraSourceName, !isSystemExtraOwner(extraSourceName) {
            return extraSourceName
        }
        if let name = localizedName(forHint: hint, knownApps: knownApps), !isSystemExtraOwner(name) {
            return name
        }
        return extraSourceName ?? ownerName
    }

    static func localizedName(forHint hint: String?, knownApps: [String: String]) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else {
            return nil
        }
        if let exact = knownApps[hint] {
            return exact
        }
        if hint.contains(".") {
            return knownApps
                .filter { hint.hasPrefix($0.key + ".") || $0.key.hasPrefix(hint + ".") }
                .max { $0.key.count < $1.key.count }?
                .value
        }
        return knownApps.first { $0.value == hint }?.value
    }

    static func axName(title: String?, description: String?, identifier: String? = nil) -> String? {
        let titleName = cleaned(title).map(shortName)
        let descriptionName = cleaned(description).map(shortName)
        if let descriptionName, titleName == nil || isGenericSystemName(titleName!) {
            return descriptionName
        }
        if let titleName, !isGenericSystemName(titleName) {
            return titleName
        }
        return cleaned(identifier)
    }

    static func shortName(_ value: String) -> String {
        let head = value.split(whereSeparator: { "，,、".contains($0) }).first.map(String.init)
        return (head ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func titleCaseIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z]{2})([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    static func isGenericSystemName(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered == "control center"
            || lowered == "unknown"
            || value == "控制中心"
            || value == "未知"
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "-",
              !value.hasPrefix("Item-"),
              !value.hasPrefix("hiddenbar_"),
              !value.hasPrefix("BentoBox"),
              !value.allSatisfy(\.isNumber),
              !value.contains("_")
        else {
            return nil
        }
        let lowered = value.lowercased()
        if lowered.contains("logo") || lowered.contains("icon") {
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

    static func accessibilityPidsToScan(extraPids: [pid_t], runningPids: [pid_t] = [], trusted: Bool) -> [pid_t] {
        guard trusted else { return [] }
        return Array(Set(extraPids + runningPids)).sorted()
    }

    static func shouldProbeExtras(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return true }
        if id.contains(".helper") || id.hasSuffix(".WebContent") || id.hasSuffix(".GPU") {
            return false
        }
        let skipPrefixes = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "com.apple.Safari",
            "com.microsoft.VSCode",
            "com.apple.dt.Xcode",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord"
        ]
        return !skipPrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    static func rowIcon(windowSnapshot: NSImage?, appIcon: NSImage?, isSystemExtra: Bool = true) -> NSImage? {
        let snapshot = isUsableSnapshot(windowSnapshot) ? windowSnapshot : nil
        return snapshot ?? (isSystemExtra ? nil : appIcon)
    }

    static func isUsableSnapshot(_ image: NSImage?) -> Bool {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width >= 4,
              cgImage.height >= 4
        else {
            return false
        }
        return hasVisiblePixels(cgImage)
    }

    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let width = min(Int(image.width), 32)
        let height = min(Int(image.height), 32)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 16 }
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

        var result = [String?](repeating: nil, count: itemMidXs.count)
        var used = Set<Int>()
        for extra in sortedExtras {
            let extraMid = extra.x + extra.width / 2
            guard let name = cleaned(extra.title) else { continue }
            let nearest = itemMidXs.enumerated()
                .filter { !used.contains($0.offset) }
                .min { abs($0.element - extraMid) < abs($1.element - extraMid) }
            guard let nearest, abs(nearest.element - extraMid) < max(36, extra.width) else { continue }
            used.insert(nearest.offset)
            result[nearest.offset] = name
        }
        return result
    }

    static func matchedTitle(
        itemMidX: CGFloat,
        extras: [(title: String, x: CGFloat, width: CGFloat)]
    ) -> String? {
        extras.min { lhs, rhs in
            abs((lhs.x + lhs.width / 2) - itemMidX) < abs((rhs.x + rhs.width / 2) - itemMidX)
        }.flatMap { extra in
            let extraMid = extra.x + extra.width / 2
            return abs(extraMid - itemMidX) < max(36, extra.width) ? cleaned(extra.title) : nil
        }
    }

    static func matchedExtras(
        itemMidXs: [CGFloat],
        extras: [(title: String?, x: CGFloat, width: CGFloat, sourceAppName: String, sourcePID: pid_t)],
        threshold: CGFloat = 36
    ) -> [ExtraSource?] {
        var result = [ExtraSource?](repeating: nil, count: itemMidXs.count)
        var usedItems = Set<Int>()
        var usedExtras = Set<Int>()

        func assign(thirdPartyOnly: Bool) {
            for (extraIndex, extra) in extras.enumerated() {
                guard !usedExtras.contains(extraIndex) else { continue }
                let isThirdParty = !isSystemExtraOwner(extra.sourceAppName)
                guard isThirdParty == thirdPartyOnly else { continue }
                let extraMid = extra.x + extra.width / 2
                let limit = max(threshold, extra.width)
                let nearest = itemMidXs.enumerated()
                    .filter { !usedItems.contains($0.offset) }
                    .min { abs($0.element - extraMid) < abs($1.element - extraMid) }
                guard let nearest, abs(nearest.element - extraMid) <= limit else { continue }
                usedItems.insert(nearest.offset)
                usedExtras.insert(extraIndex)
                result[nearest.offset] = ExtraSource(
                    title: specificName(extra.title),
                    sourceAppName: extra.sourceAppName,
                    sourcePID: extra.sourcePID
                )
            }
        }

        assign(thirdPartyOnly: true)
        assign(thirdPartyOnly: false)

        for (extraIndex, extra) in extras.enumerated() {
            guard !usedExtras.contains(extraIndex), !isSystemExtraOwner(extra.sourceAppName) else { continue }
            let extraMid = extra.x + extra.width / 2
            let nearest = itemMidXs.enumerated()
                .filter { !usedItems.contains($0.offset) }
                .min { abs($0.element - extraMid) < abs($1.element - extraMid) }
            guard let nearest else { continue }
            usedItems.insert(nearest.offset)
            usedExtras.insert(extraIndex)
            result[nearest.offset] = ExtraSource(
                title: specificName(extra.title),
                sourceAppName: extra.sourceAppName,
                sourcePID: extra.sourcePID
            )
        }
        return result
    }
}
