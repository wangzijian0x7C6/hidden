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

struct ManagedMenuBarItem {
    let id: String
    let windowNumber: Int
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let quartzRect: CGRect
    let section: Section

    enum Section {
        case hidden
        case visible
    }

    var primaryName: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, cleaned != "-", !cleaned.hasPrefix("Item-") {
            return cleaned
        }
        return appName
    }
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

    static func extras(layout: MenuBarManagementLayout) -> [ManagedMenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, NSRunningApplication)? in
                app.processIdentifier == 0 ? nil : (app.processIdentifier, app)
            }
        )
        let axTitles = extraTitlesByPID()
        let separatorMidX = layout.separatorFrame.midX

        return menuBarWindows().compactMap { info in
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                (info[kCGWindowLayer as String] as? Int).map { $0 == 25 } ?? true,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = rect(from: bounds),
                rect.height > 4, rect.width > 4, rect.width < 240
            else {
                return nil
            }

            let app = apps[pid]
            let appName = app?.localizedName
                ?? (info[kCGWindowOwnerName as String] as? String)
                ?? "Unknown".localized
            let title = matchedTitle(in: axTitles[pid] ?? [], rect: rect) ?? ""
            return ManagedMenuBarItem(
                id: "\(pid)-\(windowNumber)",
                windowNumber: windowNumber,
                pid: pid,
                appName: appName,
                title: title,
                icon: app?.icon,
                quartzRect: rect,
                section: rect.midX < separatorMidX ? .hidden : .visible
            )
        }
        .sorted { $0.quartzRect.minX < $1.quartzRect.minX }
    }

    static func windowNumber(ownedBy pid: pid_t, nearestAppKitFrame frame: CGRect) -> Int? {
        menuBarWindows().compactMap { info -> (Int, CGFloat)? in
            guard
                (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
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
        for _ in 1...3 {
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
        menuBarWindows().first { ($0[kCGWindowNumber as String] as? Int) == windowNumber }
            .flatMap { info in
                guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                return rect(from: bounds)
            }
    }

    private static func rect(from bounds: [String: Any]) -> CGRect? {
        guard
            let x = bounds["X"] as? CGFloat,
            let y = bounds["Y"] as? CGFloat,
            let w = bounds["Width"] as? CGFloat,
            let h = bounds["Height"] as? CGFloat
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func extraTitlesByPID() -> [pid_t: [(title: String, x: CGFloat, width: CGFloat)]] {
        var result: [pid_t: [(title: String, x: CGFloat, width: CGFloat)]] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var extrasValue: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasValue) == .success else {
                continue
            }
            var childrenValue: AnyObject?
            guard AXUIElementCopyAttributeValue(extrasValue as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement]
            else {
                continue
            }
            for element in children {
                guard let position = axPoint(kAXPositionAttribute as CFString, of: element),
                      let size = axSize(kAXSizeAttribute as CFString, of: element),
                      size.width > 2
                else { continue }
                let title = axString(kAXTitleAttribute as CFString, of: element)
                    ?? axString(kAXDescriptionAttribute as CFString, of: element)
                    ?? ""
                result[app.processIdentifier, default: []].append((title, position.x, size.width))
            }
        }
        return result
    }

    private static func matchedTitle(in extras: [(title: String, x: CGFloat, width: CGFloat)], rect: CGRect) -> String? {
        extras.min { lhs, rhs in
            abs((lhs.x + lhs.width / 2) - rect.midX) < abs((rhs.x + rhs.width / 2) - rect.midX)
        }.flatMap { extra in
            abs((extra.x + extra.width / 2) - rect.midX) < max(12, extra.width) ? extra.title : nil
        }
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
        let deadline = Date().addingTimeInterval(0.55)
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
