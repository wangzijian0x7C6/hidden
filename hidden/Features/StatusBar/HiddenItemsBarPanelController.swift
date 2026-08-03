//
//  HiddenItemsBarPanelController.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

private let notchDebugLogURL = URL(fileURLWithPath: "/tmp/hidden-notch-6F2C.log")

func notchDebug(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) [DEBUG-NOTCH-6F2C] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: notchDebugLogURL.path) {
        FileManager.default.createFile(atPath: notchDebugLogURL.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: notchDebugLogURL) else { return }
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
}

struct HiddenItemsBarCapture {
    let items: [HiddenItemsBarItem]
    let screen: NSScreen
    let separatorFrame: CGRect
    let menuBarOverlayFrame: CGRect
    let prefersDarkBackground: Bool
}

struct HiddenItemsBarItem {
    let image: NSImage
    let sourceRect: CGRect
    let windowNumber: Int
    let accessibilityElement: AXUIElement?
}

final class HiddenItemsBarPanelController: NSObject {
    private let panel: NSPanel
    private let backgroundView: NSView
    private let scrollView: NSScrollView
    private let contentView: HiddenItemsBarView

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        contentView = HiddenItemsBarView(frame: .zero)
        backgroundView = NSView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        scrollView.documentView = contentView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        backgroundView.addSubview(scrollView)

        panel.contentView = backgroundView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
    }

    func show(
        capture: HiddenItemsBarCapture,
        clickHandler: @escaping (HiddenItemsBarItem) -> Void,
        dragHandler: @escaping (HiddenItemsBarItem, HiddenItemsBarItem, Bool) -> Void
    ) {
        contentView.prefersDarkBackground = capture.prefersDarkBackground
        contentView.configure(items: capture.items, clickHandler: clickHandler, dragHandler: dragHandler)

        let contentSize = contentView.preferredContentSize
        let menuBarArea = leftMenuBarArea(on: capture.screen)
        let panelWidth = max(1, min(contentSize.width, menuBarArea.width))
        let panelHeight = min(max(22, contentSize.height), menuBarArea.height)
        let panelX = menuBarArea.maxX - panelWidth
        let panelY = menuBarArea.midY - panelHeight / 2
        let panelFrame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

        contentView.frame = NSRect(
            origin: .zero,
            size: CGSize(width: max(contentSize.width, panelWidth), height: panelHeight)
        )
        scrollView.hasHorizontalScroller = false
        scrollView.frame = NSRect(origin: .zero, size: CGSize(width: panelWidth, height: panelHeight))
        backgroundView.frame = scrollView.frame
        panel.setFrame(panelFrame, display: true)
        scrollView.contentView.scroll(to: NSPoint(x: max(0, contentSize.width - panelWidth), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        panel.orderFrontRegardless()
        notchDebug(
            "show itemCount=\(capture.items.count) leftArea=\(NSStringFromRect(menuBarArea)) contentSize=\(NSStringFromSize(contentSize)) panel=\(NSStringFromRect(panelFrame)) visible=\(panel.isVisible)"
        )
    }

    private func leftMenuBarArea(on screen: NSScreen) -> CGRect {
        let reservedForAppleAndAppMenu: CGFloat = 150
        let trailingPadding: CGFloat = 8
        let leadingEdge = max(
            screen.frame.minX + reservedForAppleAndAppMenu,
            (applicationMenuMaxX(on: screen) ?? screen.frame.minX) + trailingPadding
        )
        let fallbackHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        let fallbackArea = CGRect(
            x: leadingEdge,
            y: screen.frame.maxY - fallbackHeight,
            width: max(1, screen.frame.midX - leadingEdge - trailingPadding),
            height: fallbackHeight
        )

        guard #available(macOS 12.0, *), let leftArea = screen.auxiliaryTopLeftArea else {
            return fallbackArea
        }

        return CGRect(
            x: leadingEdge,
            y: leftArea.minY,
            width: max(1, leftArea.maxX - leadingEdge - trailingPadding),
            height: leftArea.height
        )
    }

    private func applicationMenuMaxX(on screen: NSScreen) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }

        let referenceMaxY = NSScreen.main?.frame.maxY ?? screen.frame.maxY
        let point = CGPoint(
            x: screen.frame.minX,
            y: referenceMaxY - screen.frame.maxY
        )
        var menuBar: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(),
                Float(point.x),
                Float(point.y),
                &menuBar
            ) == .success,
            let menuBar
        else {
            return nil
        }

        var childrenValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        return children.compactMap { child -> CGFloat? in
            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            guard
                AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionValue) == .success,
                AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success,
                let positionValue,
                let sizeValue,
                CFGetTypeID(positionValue) == AXValueGetTypeID(),
                CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else {
                return nil
            }

            var position = CGPoint.zero
            var size = CGSize.zero
            guard
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            else {
                return nil
            }
            return position.x + size.width
        }.max()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class HiddenItemsBarCaptureShieldController: NSObject {
    private let panel: NSPanel

    override init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
    }

    func show(on screen: NSScreen, near expandCollapseFrame: CGRect, covering hiddenSectionFrame: CGRect?) {
        // A visible shield hides the short capture transition, but it also causes
        // a distracting dark flash on modern translucent menu bars. Prefer the
        // brief native item transition over covering the menu bar with a panel.
        panel.orderOut(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class HiddenItemsBarSeparatorOverlayController: NSObject {
    private let panel: NSPanel
    private let contentView: HiddenItemsBarSeparatorOverlayView

    override init() {
        contentView = HiddenItemsBarSeparatorOverlayView(frame: .zero)
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.contentView = contentView
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
    }

    func show(frame: CGRect, separatorFrame: CGRect, prefersDarkBackground: Bool) {
        guard frame.width > 1 && frame.height > 1 else {
            hide()
            return
        }

        contentView.frame = NSRect(origin: .zero, size: frame.size)
        contentView.separatorFrame = separatorFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        contentView.prefersDarkBackground = prefersDarkBackground
        contentView.needsDisplay = true
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class HiddenItemsBarSeparatorOverlayView: NSView {
    var separatorFrame: CGRect = .zero
    var prefersDarkBackground = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        overlayBackgroundColor.setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: separatorColor,
            .font: NSFont.systemFont(ofSize: 18)
        ]
        let text = "|"
        let size = text.size(withAttributes: attributes)
        let targetFrame = separatorFrame.isEmpty ? bounds : separatorFrame
        text.draw(
            at: NSPoint(x: targetFrame.midX - size.width / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private var overlayBackgroundColor: NSColor {
        prefersDarkBackground || isDarkAppearance ? NSColor.black : NSColor.windowBackgroundColor
    }

    private var separatorColor: NSColor {
        prefersDarkBackground || isDarkAppearance ? NSColor.white : NSColor.labelColor
    }

    private var isDarkAppearance: Bool {
        if #available(OSX 10.14, *) {
            return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return false
    }
}

final class HiddenItemsBarView: NSView {
    private enum Metrics {
        static let paddingX: CGFloat = 12
        static let paddingY: CGFloat = 5
        static let spacing: CGFloat = 2
        static let minItemHeight: CGFloat = 18
    }

    private var items: [HiddenItemsBarItem] = []
    private var itemRects: [CGRect] = []
    private var clickHandler: ((HiddenItemsBarItem) -> Void)?
    private var dragHandler: ((HiddenItemsBarItem, HiddenItemsBarItem, Bool) -> Void)?
    private var mouseDownIndex: Int?
    private var mouseDownLocation = CGPoint.zero
    private var isCommandDrag = false
    var prefersDarkBackground = false

    var preferredContentSize: CGSize {
        let itemWidth = items.reduce(CGFloat(0)) { $0 + max($1.image.size.width, 1) }
        let spacingWidth = CGFloat(max(items.count - 1, 0)) * Metrics.spacing
        let itemHeight = items.map { max($0.image.size.height, Metrics.minItemHeight) }.max() ?? Metrics.minItemHeight
        return CGSize(
            width: itemWidth + spacingWidth + Metrics.paddingX * 2,
            height: itemHeight + Metrics.paddingY * 2
        )
    }

    func configure(
        items: [HiddenItemsBarItem],
        clickHandler: @escaping (HiddenItemsBarItem) -> Void,
        dragHandler: @escaping (HiddenItemsBarItem, HiddenItemsBarItem, Bool) -> Void
    ) {
        self.items = items
        itemRects = []
        self.clickHandler = clickHandler
        self.dragHandler = dragHandler
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !items.isEmpty else {
            drawEmptyState()
            return
        }

        itemRects = layoutItemRects()
        for (index, item) in items.enumerated() {
            guard itemRects.indices.contains(index) else { continue }
            item.image.draw(in: itemRects[index], from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let rects = itemRects.isEmpty ? layoutItemRects() : itemRects
        mouseDownIndex = rects.firstIndex { $0.contains(location) }
        mouseDownLocation = location
        isCommandDrag = event.modifierFlags.contains(.command)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownIndex = nil
            isCommandDrag = false
        }
        guard !items.isEmpty, let sourceIndex = mouseDownIndex else { return }

        let location = convert(event.locationInWindow, from: nil)
        let rects = itemRects.isEmpty ? layoutItemRects() : itemRects
        guard let targetIndex = rects.firstIndex(where: { $0.contains(location) }) else { return }

        if isCommandDrag, hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y) > 5 {
            guard targetIndex != sourceIndex else { return }
            dragHandler?(items[sourceIndex], items[targetIndex], location.x > rects[targetIndex].midX)
        } else if targetIndex == sourceIndex {
            clickHandler?(items[sourceIndex])
        }
    }

    private func layoutItemRects() -> [CGRect] {
        let contentSize = preferredContentSize
        var currentX = (bounds.width - (contentSize.width - Metrics.paddingX * 2)) / 2
        let itemHeight = contentSize.height - Metrics.paddingY * 2
        let originY = (bounds.height - itemHeight) / 2

        return items.map { item in
            let size = item.image.size
            let rect = CGRect(
                x: currentX,
                y: originY + (itemHeight - size.height) / 2,
                width: size.width,
                height: size.height
            )
            currentX += size.width + Metrics.spacing
            return rect
        }
    }

    private func drawEmptyState() {
        let text = "Hidden items unavailable".localized
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: prefersDarkBackground ? NSColor.white.withAlphaComponent(0.72) : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
