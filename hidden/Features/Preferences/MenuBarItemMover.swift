import AppKit
import ApplicationServices

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ capacity: Int32,
    _ windows: UnsafeMutablePointer<CGWindowID>,
    _ count: inout Int32
) -> CGError

struct MenuBarManagementLayout {
    let separatorFrame: CGRect
    let expandCollapseFrame: CGRect
}

enum NativeMenuBarRelation {
    case leftOf(windowNumber: Int)
    case rightOf(windowNumber: Int)

    var targetWindowNumber: Int {
        switch self {
        case .leftOf(let windowNumber), .rightOf(let windowNumber):
            return windowNumber
        }
    }
}

enum MenuBarItemMover {
    private static let menuBarItemWindowIDField = CGEventField(rawValue: 0x33)!
    private static let iconLock = NSLock()
    private static var iconCache: [Int: (NSImage, Date)] = [:]

    static func extras(layout: MenuBarManagementLayout) -> [ManagedMenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, NSRunningApplication)? in
                app.processIdentifier == 0 ? nil : (app.processIdentifier, app)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let windows = menuBarWindows().compactMap { info -> (pid: pid_t, windowNumber: Int, rect: CGRect, ownerName: String?, windowName: String?)? in
            let windowName = info[kCGWindowName as String] as? String
            let ownerName = info[kCGWindowOwnerName as String] as? String
            guard
                let pid = intValue(info[kCGWindowOwnerPID as String]).map(pid_t.init),
                let windowNumber = intValue(info[kCGWindowNumber as String]),
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = rect(from: bounds),
                MenuBarItemPresentation.isManageableExtra(
                    ownerPID: pid,
                    ownPID: ownPID,
                    layer: intValue(info[kCGWindowLayer as String]),
                    width: rect.width,
                    height: rect.height,
                    windowName: windowName,
                    ownerName: ownerName
                )
            else {
                return nil
            }
            return (pid, windowNumber, rect, ownerName, windowName)
        }

        let runningPids = apps.values.compactMap { app -> pid_t? in
            guard app.processIdentifier != ownPID,
                  !app.isTerminated,
                  app.activationPolicy != .prohibited,
                  MenuBarItemPresentation.shouldProbeExtras(bundleIdentifier: app.bundleIdentifier)
            else {
                return nil
            }
            return app.processIdentifier
        }
        let knownApps = MenuBarItemPresentation.namesByBundleID(
            apps.values.compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (id, name)
            }
        )
        let extras = collectExtraGeometries(
            for: MenuBarItemPresentation.accessibilityPidsToScan(
                extraPids: windows.map(\.pid),
                runningPids: runningPids,
                trusted: AXIsProcessTrusted()
            ),
            apps: apps,
            knownApps: knownApps
        )
        let matches = MenuBarItemPresentation.matchedExtras(
            itemMidXs: windows.map(\.rect.midX),
            extras: extras
        )
        let separatorMidX = layout.separatorFrame.midX

        return windows.enumerated().map { index, window in
            let ownerName = apps[window.pid]?.localizedName ?? window.ownerName ?? "Unknown".localized
            let match = index < matches.count ? matches[index] : nil
            let sourceName = MenuBarItemPresentation.resolvedSourceName(
                ownerName: ownerName,
                extraSourceName: match?.sourceAppName,
                hint: window.windowName,
                knownApps: knownApps
            )
            let isSystemExtra = MenuBarItemPresentation.isSystemExtraOwner(sourceName)
            let sourceApp = apps.values.first { $0.localizedName == sourceName }
                ?? match.flatMap { apps[$0.sourcePID] }
            let appIcon = sourceApp?.icon
            appIcon?.isTemplate = false
            return ManagedMenuBarItem(
                id: "\(window.pid)-\(window.windowNumber)",
                windowNumber: window.windowNumber,
                pid: window.pid,
                appName: sourceName,
                title: MenuBarItemPresentation.displayName(
                    axTitle: match?.title,
                    windowName: window.windowName,
                    appName: ownerName,
                    sourceAppName: sourceName
                ),
                icon: MenuBarItemPresentation.rowIcon(
                    windowSnapshot: captureIcon(windowNumber: window.windowNumber),
                    appIcon: appIcon,
                    isSystemExtra: isSystemExtra
                ),
                quartzRect: window.rect,
                section: MenuBarItemPresentation.section(itemMidX: window.rect.midX, separatorMidX: separatorMidX)
            )
        }
        .filter { MenuBarItemPresentation.isIdentifiableRow(title: $0.title, icon: $0.icon) }
        .sorted { $0.quartzRect.minX < $1.quartzRect.minX }
    }

    static func windowNumber(ownedBy pid: pid_t, nearestAppKitFrame frame: CGRect) -> Int? {
        menuBarWindows().compactMap { info -> (Int, CGFloat)? in
            guard
                intValue(info[kCGWindowOwnerPID as String]).map(pid_t.init) == pid,
                let windowNumber = intValue(info[kCGWindowNumber as String]),
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = rect(from: bounds)
            else {
                return nil
            }
            return (windowNumber, abs(rect.midX - frame.midX))
        }
        .min { $0.1 < $1.1 }?
        .0
    }

    static func move(_ item: ManagedMenuBarItem, relation: NativeMenuBarRelation) -> Bool {
        CGDisplayHideCursor(CGMainDisplayID())
        defer { CGDisplayShowCursor(CGMainDisplayID()) }
        let cursor = CGEvent(source: nil)?.location
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
        }
        for _ in 1...2 {
            guard
                let sourceRect = currentRect(windowNumber: item.windowNumber),
                let targetRect = currentRect(windowNumber: relation.targetWindowNumber)
            else {
                return false
            }
            if satisfies(sourceRect, relation: relation, targetRect: targetRect) {
                return true
            }
            let points = movePoints(sourceRect: sourceRect, targetRect: targetRect, relation: relation)
            postMove(
                sourceWindowNumber: item.windowNumber,
                targetWindowNumber: relation.targetWindowNumber,
                pid: item.pid,
                start: points.start,
                end: points.end
            )
            let updated = waitForMove(windowNumber: item.windowNumber, from: sourceRect)
            if let updated, satisfies(updated, relation: relation, targetRect: currentRect(windowNumber: relation.targetWindowNumber) ?? targetRect) {
                return true
            }
        }
        return false
    }

    private static func menuBarWindows() -> [[String: Any]] {
        var count: Int32 = 0
        let connection = CGSMainConnectionID()
        guard CGSGetWindowCount(connection, 0, &count) == .success, count > 0 else {
            return []
        }
        var windowIDs = [CGWindowID](repeating: 0, count: Int(count))
        guard CGSGetProcessMenuBarWindowList(connection, 0, count, &windowIDs, &count) == .success else {
            return []
        }
        var pointers: [UnsafeRawPointer?] = windowIDs[..<Int(count)].map {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
        guard
            !pointers.isEmpty,
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
        else {
            return []
        }
        return (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]) ?? []
    }

    private static func currentRect(windowNumber: Int) -> CGRect? {
        menuBarWindows().first { intValue($0[kCGWindowNumber as String]) == windowNumber }
            .flatMap { info in
                guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                return rect(from: bounds)
            }
    }

    private static func rect(from bounds: [String: Any]) -> CGRect? {
        guard
            let x = cgFloat(bounds["X"]),
            let y = cgFloat(bounds["Y"]),
            let w = cgFloat(bounds["Width"]),
            let h = cgFloat(bounds["Height"])
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int32 { return Int(value) }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func cgFloat(_ raw: Any?) -> CGFloat? {
        if let value = raw as? CGFloat { return value }
        if let value = raw as? Double { return CGFloat(value) }
        if let value = raw as? NSNumber { return CGFloat(truncating: value) }
        return nil
    }

    private static func collectExtraGeometries(
        for pids: [pid_t],
        apps: [pid_t: NSRunningApplication],
        knownApps: [String: String]
    ) -> [(title: String?, x: CGFloat, width: CGFloat, sourceAppName: String, sourcePID: pid_t)] {
        let collect = {
            extraGeometries(for: pids, apps: apps, knownApps: knownApps)
        }
        if Thread.isMainThread || !AXIsProcessTrusted() {
            return collect()
        }
        return DispatchQueue.main.sync(execute: collect)
    }

    private static func extraGeometries(
        for pids: [pid_t],
        apps: [pid_t: NSRunningApplication],
        knownApps: [String: String]
    ) -> [(title: String?, x: CGFloat, width: CGFloat, sourceAppName: String, sourcePID: pid_t)] {
        var result: [(title: String?, x: CGFloat, width: CGFloat, sourceAppName: String, sourcePID: pid_t)] = []
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.8)
            var extrasValue: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
                  extrasValue != nil
            else {
                continue
            }
            let extrasBar = extrasValue as! AXUIElement
            let sourceName = apps[pid]?.localizedName ?? "Unknown".localized
            var collected: [(title: String?, x: CGFloat, width: CGFloat, identifier: String?)] = []
            collectExtras(from: extrasBar, into: &collected, depth: 0)
            for extra in collected {
                let source = sourceApp(forHint: extra.identifier, apps: apps, knownApps: knownApps)
                result.append((
                    extra.title,
                    extra.x,
                    extra.width,
                    MenuBarItemPresentation.resolvedSourceName(
                        ownerName: sourceName,
                        extraSourceName: source?.localizedName,
                        hint: extra.identifier,
                        knownApps: knownApps
                    ),
                    source?.processIdentifier ?? pid
                ))
            }
        }
        return result
    }

    private static func collectExtras(
        from element: AXUIElement,
        into result: inout [(title: String?, x: CGFloat, width: CGFloat, identifier: String?)],
        depth: Int
    ) {
        var childrenValue: AnyObject?
        let children: [AXUIElement]
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success {
            children = childrenValue as? [AXUIElement] ?? []
        } else {
            children = []
        }
        if depth == 0, !children.isEmpty {
            for child in children {
                collectExtras(from: child, into: &result, depth: 1)
            }
            return
        }
        if axBool(kAXEnabledAttribute as CFString, of: element) == false { return }
        guard let position = axPoint(kAXPositionAttribute as CFString, of: element),
              let size = axSize(kAXSizeAttribute as CFString, of: element),
              size.width > 2
        else { return }
        let identifier = axString("AXIdentifier" as CFString, of: element)
        let name = MenuBarItemPresentation.axName(
            title: axString(kAXTitleAttribute as CFString, of: element),
            description: axString(kAXDescriptionAttribute as CFString, of: element)
                ?? axString(kAXHelpAttribute as CFString, of: element),
            identifier: identifier
        )
        result.append((name, position.x, size.width, identifier))
    }

    private static func sourceApp(
        forHint hint: String?,
        apps: [pid_t: NSRunningApplication],
        knownApps: [String: String]
    ) -> NSRunningApplication? {
        guard let name = MenuBarItemPresentation.localizedName(forHint: hint, knownApps: knownApps),
              !MenuBarItemPresentation.isSystemExtraOwner(name)
        else {
            return nil
        }
        return apps.values.first { $0.localizedName == name }
    }

    private static func captureIcon(windowNumber: Int) -> NSImage? {
        iconLock.lock()
        if let cached = iconCache[windowNumber], Date().timeIntervalSince(cached.1) < 4 {
            let image = cached.0
            iconLock.unlock()
            return image
        }
        iconLock.unlock()
        for _ in 1...2 {
            if let image = snapshotImage(windowNumber: windowNumber) {
                iconLock.lock()
                iconCache[windowNumber] = (image, Date())
                iconLock.unlock()
                return image
            }
        }
        return nil
    }

    private static func snapshotImage(windowNumber: Int) -> NSImage? {
        guard let windowID = CGWindowID(exactly: windowNumber) else { return nil }
        var pointer = UnsafeRawPointer(bitPattern: UInt(windowID))
        let fromList: CGImage?
        if let array = CFArrayCreate(nil, &pointer, 1, nil) {
            fromList = CGImage(
                windowListFromArrayScreenBounds: .null,
                windowArray: array,
                imageOption: [.boundsIgnoreFraming, .bestResolution]
            )
        } else {
            fromList = nil
        }
        let image = fromList ?? CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        guard let image else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(
            width: max(CGFloat(image.width) / scale, 1),
            height: max(CGFloat(image.height) / scale, 1)
        )
        let nsImage = NSImage(cgImage: image, size: size)
        nsImage.isTemplate = false
        return MenuBarItemPresentation.isUsableSnapshot(nsImage) ? nsImage : nil
    }

    private static func axBool(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func axPoint(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func axSize(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(rawValue as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func axString(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func satisfies(_ rect: CGRect, relation: NativeMenuBarRelation, targetRect: CGRect) -> Bool {
        switch relation {
        case .leftOf:
            return abs(rect.maxX - targetRect.minX) <= 1.5
        case .rightOf:
            return abs(rect.minX - targetRect.maxX) <= 1.5
        }
    }

    private static func movePoints(sourceRect: CGRect, targetRect: CGRect, relation: NativeMenuBarRelation) -> (start: CGPoint, end: CGPoint) {
        switch relation {
        case .leftOf:
            var start = CGPoint(x: targetRect.minX, y: targetRect.midY)
            var end = start
            if sourceRect.maxX <= targetRect.minX {
                end.x -= sourceRect.width
            } else {
                start.x -= 1
            }
            return (start, end)
        case .rightOf:
            var start = CGPoint(x: targetRect.maxX, y: targetRect.midY)
            var end = start
            if sourceRect.minX <= targetRect.maxX {
                end.x -= sourceRect.width
            } else {
                start.x += 1
            }
            return (start, end)
        }
    }

    private static func postMove(
        sourceWindowNumber: Int,
        targetWindowNumber: Int,
        pid: pid_t,
        start: CGPoint,
        end: CGPoint
    ) {
        permitLocalMouseEvents()
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: start,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: end,
                mouseButton: .left
            )
        else { return }

        configure(mouseDown, windowNumber: sourceWindowNumber, pid: pid, command: true)
        configure(mouseUp, windowNumber: targetWindowNumber, pid: pid, command: false)
        deliver(mouseDown, to: pid)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        deliver(mouseUp, to: pid)
        deliver(mouseUp, to: pid)
    }

    private static func configure(_ event: CGEvent, windowNumber: Int, pid: pid_t, command: Bool) {
        let windowID = Int64(windowNumber)
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(menuBarItemWindowIDField, value: windowID)
    }

    private static func deliver(_ event: CGEvent, to pid: pid_t) {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.postToPid(pid)
        event.post(tap: .cgSessionEventTap)
    }

    private static func permitLocalMouseEvents() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateRemoteMouseDrag
        )
    }

    private static func waitForMove(windowNumber: Int, from initialRect: CGRect) -> CGRect? {
        let deadline = Date().addingTimeInterval(0.18)
        var latest = currentRect(windowNumber: windowNumber)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            latest = currentRect(windowNumber: windowNumber)
            if let latest, hypot(latest.minX - initialRect.minX, latest.minY - initialRect.minY) > 1 {
                return latest
            }
        }
        return latest
    }
}
