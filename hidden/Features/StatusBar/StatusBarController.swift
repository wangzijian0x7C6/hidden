//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

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

class StatusBarController {
    private typealias AccessibilityMenuBarItem = (element: AXUIElement, icon: NSImage, frame: CGRect)

    //MARK: - Variables
    private var timer:Timer? = nil
    private let accessibilityScanQueue = DispatchQueue(label: "com.dwarvesv.hiddenbar.accessibility-scan", qos: .utility)
    private let accessibilityCacheLock = NSLock()
    private var accessibilityMenuBarItemCache: [AccessibilityMenuBarItem]?
    private var menuBarIconCache: [CFHashCode: NSImage] = [:]

    //MARK: - BarItems

    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil

    private var btnHiddenLength: CGFloat = 20
    private var btnHiddenCollapseLength: CGFloat = 2000

    private var btnAlwaysHiddenLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 20 : 0
    private var btnAlwaysHiddenEnableExpandCollapseLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 2000 : 0

    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    private let hiddenItemsBarController = HiddenItemsBarPanelController()
    private let hiddenItemsCaptureShieldController = HiddenItemsBarCaptureShieldController()
    private let hiddenItemsSeparatorOverlayController = HiddenItemsBarSeparatorOverlayController()
    private var activeExpandCollapseFrame: CGRect?
    private var activeStatusItemScreen: NSScreen?
    private var configurationDragMonitor: Any?
    private var isTemporarilyExpandedForConfigurationDrag = false
    private var configurationDragCollapseWorkItem: DispatchWorkItem?

    private var isCollapsed: Bool {
        // Compare with > rather than == so the state survives updateCollapsedLengths
        // changing btnHiddenCollapseLength while the bar is collapsed (PR #354).
        return self.btnSeparate.length > self.btnHiddenLength
    }

    private var isSeparateHiddenItemsBarVisible: Bool {
        return self.hiddenItemsBarController.isVisible
    }

    private var isBtnSeparateValidPosition: Bool {
        guard
            let btnExpandCollapseX = self.btnExpandCollapse.button?.getOrigin?.x,
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x
            else {return false}

        if Constant.isUsingLTRLanguage {
            return btnExpandCollapseX >= btnSeparateX
        } else {
            return btnExpandCollapseX <= btnSeparateX
        }
    }

    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }

        guard
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x,
            let btnAlwaysHiddenX = self.btnAlwaysHidden?.button?.getOrigin?.x
            else {return false}

        if Constant.isUsingLTRLanguage {
            return btnSeparateX >= btnAlwaysHiddenX
        } else {
            return btnSeparateX <= btnAlwaysHiddenX
        }
    }

    private var isToggle = false

    // SPEC-003 (macOS 27 hide-mechanism). macOS 27 re-architected the menu bar so
    // inflating the separator length may no longer push items off-screen (#360).
    // This is DIAGNOSTIC ONLY: on the first collapse with the menu-bar window
    // ready, log the separator geometry so a macOS 27 run reveals which signal
    // (if any) distinguishes "length honored" from "ignored". No behavior change.
    // The degrade ACTION is deliberately NOT shipped: review found the trigger
    // unverifiable without 27 hardware, and a false positive would disable hiding
    // for a working user. The action lands once this log calibrates the signal.
    private var hideMechanismChecked = false

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    private var isNativeMenuBarMutationInFlight = false
    private var pendingNativeRestoreWorkItem: DispatchWorkItem?
    private let menuBarItemWindowIDField = CGEventField(rawValue: 0x33)!

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        let wc = PreferencesWindowController.shared
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
    }
    //MARK: - Methods
    init() {
        updateCollapsedLengths()
        setupUI()
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupConfigurationDragMonitor()
        setupHoverToExpandIfEnabled()
        warmAccessibilityMenuBarItemCache()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePreferencesChanged), name: .prefsChanged, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let configurationDragMonitor = configurationDragMonitor {
            NSEvent.removeMonitor(configurationDragMonitor)
        }
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
        }
        }
    }

    @objc private func handleScreenParametersChanged() {
        activeExpandCollapseFrame = nil
        activeStatusItemScreen = nil
        // Re-apply the recomputed length to the LIVE item when collapsed, or a
        // display hot-plug leaves the separator at a stale length (PR #354).
        let wasCollapsed = isCollapsed
        updateCollapsedLengths()
        if wasCollapsed {
            btnSeparate.length = btnHiddenCollapseLength
            if Preferences.areSeparatorsHidden {
                btnAlwaysHidden?.length = btnAlwaysHiddenEnableExpandCollapseLength
            }
        }
    }

    private func updateCollapsedLengths() {
        // The menubar replicates across every attached display, so the collapse
        // length must cover the WIDEST screen, not NSScreen.main (the focused one);
        // sizing from a narrower screen leaks hidden icons on wider displays.
        // frame.width, not visibleFrame: the menubar spans the full frame width.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        // Keep collapse length bounded to avoid pathological layout/memory behavior;
        // macOS enforces a hard 10,000pt maximum on NSStatusItem.length (PR #354).
        let boundedCollapseLength = max(500, min(screenWidth * 2, 10_000))
        btnHiddenCollapseLength = boundedCollapseLength
        btnAlwaysHiddenEnableExpandCollapseLength = Preferences.alwaysHiddenSectionEnabled ? boundedCollapseLength : 0
    }
    @objc private func handlePreferencesChanged() {
        if !Preferences.showHiddenItemsInSeparateBar {
            hiddenItemsBarController.hide()
            hiddenItemsSeparatorOverlayController.hide()
            if let button = btnExpandCollapse.button {
                button.image = isCollapsed ? Assets.expandImage : Assets.collapseImage
            }
        }
        updateAutoCollapseMenuTitle()
        autoCollapseIfNeeded()
    }

    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
        }
        let menu = self.getContextMenu()
        btnSeparate.menu = menu

        updateAutoCollapseMenuTitle()

        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self

            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }

    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        activeExpandCollapseFrame = sender.window?.frame
        activeStatusItemScreen = sender.window?.screen

        if let event = NSApp.currentEvent {

            let isOptionKeyPressed = event.modifierFlags.contains(NSEvent.ModifierFlags.option)

            if event.type == NSEvent.EventType.leftMouseUp && !isOptionKeyPressed{
                self.expandCollapseIfNeeded()
            } else if event.type == NSEvent.EventType.rightMouseUp && !isOptionKeyPressed {
                // Right-click opens the same context menu the separator has (#356),
                // making settings reachable from the control everyone clicks.
                // The separators/always-hidden toggle stays on option-click.
                showContextMenu(from: sender)
            } else {
                // Both option+left and option+right land here: separators toggle.
                self.showHideSeparatorsAndAlwayHideArea()
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = btnSeparate.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    func showHideSeparatorsAndAlwayHideArea() {
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()

        if self.isCollapsed {self.expandMenubar()}
    }

    private func showSeparators() {
        Preferences.areSeparatorsHidden = false

        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenLength
    }

    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}

        Preferences.areSeparatorsHidden = true
        hiddenItemsSeparatorOverlayController.hide()

        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenEnableExpandCollapseLength
    }

    func expandCollapseIfNeeded() {
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        if self.isSeparateHiddenItemsBarVisible {
            self.collapseMenuBar()
        } else if self.isCollapsed && Preferences.showHiddenItemsInSeparateBar {
            self.expandHiddenItemsBar()
        } else {
            self.isCollapsed ? self.expandMenubar() : self.collapseMenuBar()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }

    private func collapseMenuBar() {
        hiddenItemsCaptureShieldController.hide()
        hiddenItemsBarController.hide()
        hiddenItemsSeparatorOverlayController.hide()

        guard self.isBtnSeparateValidPosition && !self.isCollapsed else {
            if !self.isBtnSeparateValidPosition {
                restoreInlineMenuBarAfterInvalidSeparatePosition()
                return
            }
            timer?.invalidate()
            autoCollapseIfNeeded()
            if let button = btnExpandCollapse.button {
                button.image = Assets.expandImage
            }
            return
        }

        btnSeparate.length = self.btnHiddenCollapseLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
        verifyHideMechanismIfNeeded()
    }
    private func expandMenubar(force: Bool = false) {
        guard self.isCollapsed || force else {return}
        hiddenItemsCaptureShieldController.hide()
        hiddenItemsBarController.hide()
        hiddenItemsSeparatorOverlayController.hide()
        btnSeparate.length = btnHiddenLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
        autoCollapseIfNeeded()

        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

        }
    }

    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed || isSeparateHiddenItemsBarVisible else { return }

        startTimerToAutoHide()
    }

    // After a collapse, confirm on the next runloop tick (so layout settles) that
    // the separator actually claimed its inflated width. macOS <= 26 honors it;
    // a macOS that ignores NSStatusItem.length leaves the slot narrow, meaning
    // hiding did nothing. Checked once: cheap, and the OS behavior won't change
    // mid-session.
    private func verifyHideMechanismIfNeeded() {
        guard !hideMechanismChecked else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCollapsed else { return }
            // Need the separator's backing window to measure. If it is not up yet
            // (early launch), do NOT burn the one-shot check: return and let a
            // later collapse retry once the window exists.
            guard let separatorButton = self.btnSeparate.button,
                  let window = separatorButton.window else { return }
            self.hideMechanismChecked = true
            // Log several geometry signals. On macOS <= 26 the inflation is
            // honored; on macOS 27 it may be ignored. Which of these tracks the
            // requested length is exactly what a 27 capture must reveal before any
            // degrade action can trigger on a sound signal.
            let requested = self.btnHiddenCollapseLength
            let windowWidth = window.frame.width
            let buttonWidth = separatorButton.frame.width
            NSLog("HideMechanism: requested=\(requested) windowWidth=\(windowWidth) buttonWidth=\(buttonWidth) length=\(self.btnSeparate.length)")
        }
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers.
            if self.isMouseInMenuBar || self.isPreferencesWindowVisible {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }

    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()

        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)

        let toggleAutoHideItem = NSMenuItem(title: "Toggle Auto Collapse".localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        toggleAutoHideItem.tag = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    private func updateAutoCollapseMenuTitle() {
        guard let toggleAutoHideItem = btnSeparate.menu?.item(withTag: 1) else { return }
        if Preferences.isAutoHide {
            toggleAutoHideItem.title = "Disable Auto Collapse".localized
        } else {
            toggleAutoHideItem.title = "Enable Auto Collapse".localized
        }
    }

    @objc func updateAutoHide() {
        handlePreferencesChanged()
    }

    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }

    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}

//MARK: - Configuration drag support
extension StatusBarController {
    private func setupConfigurationDragMonitor() {
        configurationDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleConfigurationDragEvent(event)
            }
        }
    }

    private func handleConfigurationDragEvent(_ event: NSEvent?) {
        guard let event = event else { return }

        switch event.type {
        case .leftMouseDragged:
            guard event.modifierFlags.contains(.command) else { return }
            temporarilyExpandForConfigurationDragIfNeeded()
        case .leftMouseUp:
            collapseAfterConfigurationDragIfNeeded()
        default:
            break
        }
    }

    private func temporarilyExpandForConfigurationDragIfNeeded() {
        guard
            Preferences.showHiddenItemsInSeparateBar,
            !Preferences.areSeparatorsHidden,
            isCollapsed
        else {
            return
        }

        configurationDragCollapseWorkItem?.cancel()
        hiddenItemsCaptureShieldController.hide()
        hiddenItemsBarController.hide()
        hiddenItemsSeparatorOverlayController.hide()
        btnSeparate.length = btnHiddenLength
        isTemporarilyExpandedForConfigurationDrag = true

        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
    }

    private func collapseAfterConfigurationDragIfNeeded() {
        guard isTemporarilyExpandedForConfigurationDrag else { return }

        configurationDragCollapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isTemporarilyExpandedForConfigurationDrag = false
            self.forceCollapseAfterConfigurationDrag()
        }
        configurationDragCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func forceCollapseAfterConfigurationDrag() {
        hiddenItemsCaptureShieldController.hide()
        hiddenItemsBarController.hide()
        hiddenItemsSeparatorOverlayController.hide()
        btnSeparate.length = btnHiddenCollapseLength

        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
    }
}

//MARK: - Separate hidden items bar
extension StatusBarController {
    private func expandHiddenItemsBar() {
        notchDebug(
            "expand entry collapsed=\(isCollapsed) validPosition=\(isBtnSeparateValidPosition) preference=\(Preferences.showHiddenItemsInSeparateBar)"
        )
        guard self.isCollapsed else {
            notchDebug("expand stop notCollapsed")
            return
        }
        guard self.isBtnSeparateValidPosition else {
            notchDebug("expand stop invalidPosition")
            restoreInlineMenuBarAfterInvalidSeparatePosition()
            return
        }
        guard self.canCaptureScreenForSeparatePanel() else {
            notchDebug("expand stop noScreenCapture")
            self.expandMenubar()
            return
        }
        guard currentExpandCollapseGeometry() != nil else {
            notchDebug("expand stop noGeometry")
            return
        }

        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        timer?.invalidate()
        warmAccessibilityMenuBarItemCache()
        btnSeparate.length = btnHiddenLength
        btnExpandCollapse.button?.image = Assets.collapseImage

        // AppKit needs a short layout window after changing NSStatusItem.length.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            guard Preferences.showHiddenItemsInSeparateBar else {
                self.collapseMenuBar()
                return
            }

            guard let capture = self.captureExpandedHiddenItems() else {
                notchDebug("expand stop noCapture")
                self.expandMenubar(force: true)
                return
            }

            notchDebug("expand captured items=\(capture.items.count)")
            guard self.prepareExpandedMenuBarForNotchBridge() else {
                notchDebug("expand stop prepareFailed")
                return
            }
            guard let overflowCapture = self.captureByFilteringItemsOutsideRightMenuBar(capture) else {
                notchDebug("expand stop noOverflow")
                self.hiddenItemsBarController.hide()
                self.hiddenItemsSeparatorOverlayController.hide()
                self.autoCollapseIfNeeded()
                return
            }

            self.hiddenItemsBarController.show(
                capture: overflowCapture,
                clickHandler: { [weak self] item in
                    self?.activateHiddenItem(item, from: overflowCapture)
                },
                dragHandler: { [weak self] item, target, placeAfter in
                    self?.moveHiddenItem(item, relativeTo: target, placeAfter: placeAfter)
                }
            )
            self.hiddenItemsSeparatorOverlayController.hide()
            self.btnExpandCollapse.button?.image = Assets.collapseImage
            self.autoCollapseIfNeeded()
        }
    }

    private func canCaptureScreenForSeparatePanel() -> Bool {
        if #available(OSX 10.15, *) {
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                return false
            }
        }
        return true
    }

    private func prepareExpandedMenuBarForNotchBridge() -> Bool {
        hiddenItemsBarController.hide()
        guard self.isBtnSeparateValidPosition else {
            restoreInlineMenuBarAfterInvalidSeparatePosition()
            return false
        }
        btnSeparate.length = btnHiddenLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func captureByFilteringItemsOutsideRightMenuBar(_ capture: HiddenItemsBarCapture) -> HiddenItemsBarCapture? {
        let rightArea = rightMenuBarArea(on: capture.screen)

        notchDebug(
            "filter screen=\(NSStringFromRect(capture.screen.frame)) rightArea=\(NSStringFromRect(rightArea)) items=\(capture.items.map { NSStringFromRect($0.sourceRect) })"
        )
        let tolerance: CGFloat = 2
        let overflowItems = capture.items.filter { item in
            item.sourceRect.minX < rightArea.minX - tolerance
                || item.sourceRect.maxX > rightArea.maxX + tolerance
        }
        notchDebug("filter overflowCount=\(overflowItems.count)")
        guard !overflowItems.isEmpty else { return nil }

        return HiddenItemsBarCapture(
            items: overflowItems,
            screen: capture.screen,
            separatorFrame: capture.separatorFrame,
            menuBarOverlayFrame: .zero,
            prefersDarkBackground: capture.prefersDarkBackground
        )
    }

    private func restoreInlineMenuBarAfterInvalidSeparatePosition() {
        timer?.invalidate()
        hiddenItemsCaptureShieldController.hide()
        hiddenItemsBarController.hide()
        hiddenItemsSeparatorOverlayController.hide()
        btnSeparate.length = btnHiddenLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }

        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func captureExpandedHiddenItems() -> HiddenItemsBarCapture? {
        guard let windowList = menuBarWindowList() else {
            notchDebug("capture stop noWindowList")
            return nil
        }
        notchDebug("capture windowCount=\(windowList.count)")
        let statusWindowRects = windowList.compactMap { info -> String? in
            guard
                (info[kCGWindowLayer as String] as? Int) == 25,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = rectFromWindowBounds(bounds)
            else {
                return nil
            }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            return "\(NSStringFromRect(rect)) onscreen=\(onscreen)"
        }
        notchDebug("capture statusWindows=\(statusWindowRects)")

        for screen in preferredCaptureScreens() {
            guard let separatorQuartzRect = statusItemQuartzRect(named: "hiddenbar_separate", statusItem: btnSeparate, from: windowList, on: screen) else {
                notchDebug("capture screen=\(NSStringFromRect(screen.frame)) missingSeparator")
                continue
            }
            guard let expandCollapseQuartzRect = statusItemQuartzRect(named: "hiddenbar_expandcollapse", statusItem: btnExpandCollapse, from: windowList, on: screen) else {
                notchDebug("capture screen=\(NSStringFromRect(screen.frame)) missingExpandCollapse")
                continue
            }

            let items = captureVisibleHiddenSectionItems(
                from: windowList,
                separatorQuartzRect: separatorQuartzRect,
                expandCollapseQuartzRect: expandCollapseQuartzRect,
                on: screen
            )
            notchDebug(
                "capture screen=\(NSStringFromRect(screen.frame)) separator=\(NSStringFromRect(separatorQuartzRect)) expandCollapse=\(NSStringFromRect(expandCollapseQuartzRect)) items=\(items.count)"
            )
            if !items.isEmpty {
                let separatorFrame = appKitRectFromQuartzRect(separatorQuartzRect, on: screen)
                return HiddenItemsBarCapture(
                    items: items,
                    screen: screen,
                    separatorFrame: separatorFrame,
                    menuBarOverlayFrame: menuBarOverlayFrame(
                        for: separatorFrame,
                        covering: [],
                        on: screen
                    ),
                    prefersDarkBackground: prefersDarkBackground(for: items)
                )
            }
        }

        return nil
    }

    private func captureVisibleHiddenSectionItems(from windowList: [[String: Any]], separatorQuartzRect: CGRect, expandCollapseQuartzRect: CGRect, on screen: NSScreen) -> [HiddenItemsBarItem] {
        let accessibilityItems = cachedAccessibilityMenuBarItems()
        let capturedItems = windowList.compactMap { info -> (item: HiddenItemsBarItem, quartzRect: CGRect)? in
            guard
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let sourcePID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let quartzRect = visibleMenuBarItemQuartzRect(from: info, on: screen)
            else {
                return nil
            }

            let appKitRect = appKitRectFromQuartzRect(quartzRect, on: screen)
            let windowID = CGWindowID(exactly: windowNumber)
            let windowImage = windowID.flatMap { captureMenuBarWindow($0) }
            let image: NSImage
            let accessibilityElement: AXUIElement?
            if let windowImage = windowImage {
                image = NSImage(cgImage: windowImage, size: appKitRect.size)
                let match = accessibilityItems.first(where: {
                    hypot($0.frame.midX - quartzRect.midX, $0.frame.midY - quartzRect.midY) <= 8
                })
                accessibilityElement = match?.element
                if let match {
                    menuBarIconCache[CFHash(match.element)] = image
                }
            } else {
                guard let match = accessibilityItems.first(where: {
                    hypot($0.frame.midX - quartzRect.midX, $0.frame.midY - quartzRect.midY) <= 8
                }) else {
                    let nearestDistance = accessibilityItems.map {
                        hypot($0.frame.midX - quartzRect.midX, $0.frame.midY - quartzRect.midY)
                    }.min() ?? -1
                    notchDebug("capture accessibilityMiss window=\(NSStringFromRect(quartzRect)) nearestDistance=\(nearestDistance)")
                    return nil
                }
                image = menuBarIconCache[CFHash(match.element)] ?? (match.icon.copy() as? NSImage ?? match.icon)
                image.size = CGSize(width: min(max(quartzRect.width, 18), 24), height: min(max(quartzRect.height, 18), 24))
                accessibilityElement = match.element
            }

            return (
                item: HiddenItemsBarItem(
                    image: image,
                    sourceRect: appKitRect,
                    windowNumber: windowNumber,
                    sourcePID: sourcePID,
                    accessibilityElement: accessibilityElement
                ),
                quartzRect: quartzRect
            )
        }
        .sorted { $0.item.sourceRect.minX < $1.item.sourceRect.minX }

        let hiddenSectionItems = capturedItems.filter {
            hiddenSectionCandidateLocation(
                $0.quartzRect,
                separatorQuartzRect: separatorQuartzRect,
                expandCollapseQuartzRect: expandCollapseQuartzRect
            ) != nil
        }

        if !hiddenSectionItems.isEmpty {
            return hiddenSectionItems.map { $0.item }
        }

        return []
    }

    private func warmAccessibilityMenuBarItemCache() {
        guard AXIsProcessTrusted() else { return }
        accessibilityScanQueue.async { [weak self] in
            guard let self = self, self.cachedAccessibilityMenuBarItems().isEmpty else { return }
            let items = self.scanAccessibilityMenuBarItems()
            self.accessibilityCacheLock.lock()
            self.accessibilityMenuBarItemCache = items
            self.accessibilityCacheLock.unlock()
        }
    }

    private func cachedAccessibilityMenuBarItems() -> [AccessibilityMenuBarItem] {
        accessibilityCacheLock.lock()
        defer { accessibilityCacheLock.unlock() }
        return accessibilityMenuBarItemCache ?? []
    }

    private func accessibilityMenuBarItems() -> [AccessibilityMenuBarItem] {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            notchDebug("capture accessibilityNotTrusted")
            return []
        }

        return accessibilityScanQueue.sync {
            let cached = cachedAccessibilityMenuBarItems()
            if !cached.isEmpty {
                return cached
            }
            let items = scanAccessibilityMenuBarItems()
            accessibilityCacheLock.lock()
            accessibilityMenuBarItemCache = items
            accessibilityCacheLock.unlock()
            return items
        }
    }

    private func scanAccessibilityMenuBarItems() -> [AccessibilityMenuBarItem] {
        NSWorkspace.shared.runningApplications.flatMap { app -> [AccessibilityMenuBarItem] in
            guard
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                let icon = app.icon
            else {
                return []
            }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var extrasValue: AnyObject?
            guard
                AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
                let extras = extrasValue
            else {
                return []
            }

            var childrenValue: AnyObject?
            guard
                AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                let children = childrenValue as? [AXUIElement]
            else {
                return []
            }

            return children.compactMap { element -> (AXUIElement, NSImage, CGRect)? in
                guard
                    let position = accessibilityPoint(kAXPositionAttribute as CFString, of: element),
                    let size = accessibilitySize(kAXSizeAttribute as CFString, of: element)
                else {
                    return nil
                }
                return (element, icon, CGRect(origin: position, size: size))
            }
        }
    }

    private func accessibilityPoint(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let rawValue = value,
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func accessibilitySize(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let rawValue = value,
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(rawValue as! AXValue, .cgSize, &size) ? size : nil
    }

    private func captureByCoveringItemsStillVisibleInMenuBar(_ capture: HiddenItemsBarCapture) -> HiddenItemsBarCapture {
        guard let windowList = menuBarWindowList() else { return capture }

        let visibleRectsByWindowNumber = Dictionary(uniqueKeysWithValues: windowList.compactMap { info -> (Int, CGRect)? in
            guard
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let quartzRect = visibleMenuBarItemQuartzRect(from: info, on: capture.screen)
            else {
                return nil
            }

            return (windowNumber, appKitRectFromQuartzRect(quartzRect, on: capture.screen))
        })
        let visibleCapturedRects = capture.items.compactMap { visibleRectsByWindowNumber[$0.windowNumber] }
        guard !visibleCapturedRects.isEmpty else { return capture }

        return HiddenItemsBarCapture(
            items: capture.items,
            screen: capture.screen,
            separatorFrame: capture.separatorFrame,
            menuBarOverlayFrame: menuBarOverlayFrame(
                for: capture.separatorFrame,
                covering: visibleCapturedRects,
                on: capture.screen
            ),
            prefersDarkBackground: capture.prefersDarkBackground
        )
    }

    private func prefersDarkBackground(for items: [HiddenItemsBarItem]) -> Bool {
        var luminanceTotal: CGFloat = 0
        var sampleCount: CGFloat = 0

        for item in items {
            guard let cgImage = item.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let xStep = max(1, bitmap.pixelsWide / 8)
            let yStep = max(1, bitmap.pixelsHigh / 8)

            stride(from: 0, to: bitmap.pixelsWide, by: xStep).forEach { x in
                stride(from: 0, to: bitmap.pixelsHigh, by: yStep).forEach { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.2
                    else {
                        return
                    }

                    luminanceTotal += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return false }
        return (luminanceTotal / sampleCount) > 0.55
    }

    private func menuBarOverlayFrame(for separatorFrame: CGRect, covering itemFrames: [CGRect], on screen: NSScreen) -> CGRect {
        let menuBarHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        let minX = max(
            screen.frame.minX,
            itemFrames.reduce(separatorFrame.minX) { min($0, $1.minX) }
        )
        let maxX = min(
            screen.frame.maxX,
            itemFrames.reduce(separatorFrame.maxX) { max($0, $1.maxX) }
        )
        let width = max(btnHiddenLength, maxX - minX)

        return CGRect(
            x: minX,
            y: screen.frame.maxY - menuBarHeight,
            width: width,
            height: menuBarHeight
        )
    }

    private func menuBarWindowList() -> [[String: Any]]? {
        var count: Int32 = 0
        let connection = CGSMainConnectionID()
        guard CGSGetWindowCount(connection, 0, &count) == .success, count > 0 else {
            return nil
        }

        var windowIDs = [CGWindowID](repeating: 0, count: Int(count))
        guard CGSGetProcessMenuBarWindowList(connection, 0, count, &windowIDs, &count) == .success else {
            return nil
        }

        var pointers: [UnsafeRawPointer?] = windowIDs[..<Int(count)].map {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
        guard
            !pointers.isEmpty,
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
        else {
            return nil
        }
        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    }

    private func captureMenuBarWindow(_ windowID: CGWindowID) -> CGImage? {
        var pointer = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let array = CFArrayCreate(nil, &pointer, 1, nil) else {
            return nil
        }
        return CGImage(
            windowListFromArrayScreenBounds: .null,
            windowArray: array,
            imageOption: [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private func visibleMenuBarItemQuartzRect(from info: [String: Any], on screen: NSScreen) -> CGRect? {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let screenQuartzRect = quartzRectFromAppKitRect(screen.frame)
        let menuBarHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        let maxMenuBarQuartzY = screenQuartzRect.minY + menuBarHeight + 6
        let appBundleIdentifier = Bundle.main.bundleIdentifier

        guard
            (info[kCGWindowOwnerPID as String] as? Int32) != currentProcessID,
            !isHiddenBarStatusWindow(info, appBundleIdentifier: appBundleIdentifier),
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 25,
            let bounds = info[kCGWindowBounds as String] as? [String: Any],
            let quartzRect = rectFromWindowBounds(bounds),
            quartzRect.intersects(screenQuartzRect),
            quartzRect.minY >= screenQuartzRect.minY - 1,
            quartzRect.minY <= maxMenuBarQuartzY,
            quartzRect.height > 4,
            quartzRect.width > 4
        else {
            return nil
        }

        return quartzRect
    }

    private enum HiddenSectionCandidateLocation {
        case hiddenSection
    }

    private func hiddenSectionCandidateLocation(_ quartzRect: CGRect, separatorQuartzRect: CGRect, expandCollapseQuartzRect: CGRect) -> HiddenSectionCandidateLocation? {
        if expandCollapseQuartzRect.minX >= separatorQuartzRect.minX {
            if quartzRect.maxX <= separatorQuartzRect.minX + 1 {
                return .hiddenSection
            }
        } else {
            if quartzRect.minX >= separatorQuartzRect.maxX - 1 {
                return .hiddenSection
            }
        }

        return nil
    }

    private func preferredCaptureScreens() -> [NSScreen] {
        let preferred = btnExpandCollapse.button?.window?.screen ?? activeStatusItemScreen ?? NSScreen.main
        guard let first = preferred else { return NSScreen.screens }

        return [first] + NSScreen.screens.filter { $0 !== first }
    }

    private func currentExpandCollapseGeometry() -> (frame: CGRect, screen: NSScreen)? {
        if
            let frame = btnExpandCollapse.button?.window?.frame,
            let screen = btnExpandCollapse.button?.window?.screen
        {
            return (frame, screen)
        }

        guard let frame = activeExpandCollapseFrame else { return nil }
        let screen = activeStatusItemScreen
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let resolvedScreen = screen else { return nil }
        return (frame, resolvedScreen)
    }

    private func statusItemQuartzRect(named name: String, statusItem: NSStatusItem, from windowList: [[String: Any]], on screen: NSScreen) -> CGRect? {
        let screenQuartzRect = quartzRectFromAppKitRect(screen.frame)
        let menuBarQuartzRect = quartzMenuBarRect(on: screen)
        let appBundleIdentifier = Bundle.main.bundleIdentifier

        let namedWindows = windowList.compactMap { info -> CGRect? in
            guard
                (info[kCGWindowName as String] as? String) == name,
                let quartzRect = statusItemWindowQuartzRect(from: info, screenQuartzRect: screenQuartzRect, menuBarQuartzRect: menuBarQuartzRect)
            else {
                return nil
            }

            return quartzRect
        }
        if let namedWindow = namedWindows.sorted(by: { $0.minX < $1.minX }).first {
            return namedWindow
        }

        guard let expectedFrame = statusItem.button?.window?.frame else { return nil }
        let expectedQuartzRect = quartzRectFromAppKitRect(expectedFrame)
        let bundleWindows = windowList.compactMap { info -> CGRect? in
            guard
                let title = info[kCGWindowName as String] as? String,
                title == appBundleIdentifier || title.hasPrefix("hiddenbar_"),
                let quartzRect = statusItemWindowQuartzRect(from: info, screenQuartzRect: screenQuartzRect, menuBarQuartzRect: menuBarQuartzRect)
            else {
                return nil
            }

            return quartzRect
        }

        return bundleWindows.sorted {
            statusItemMatchScore($0, expectedQuartzRect: expectedQuartzRect) < statusItemMatchScore($1, expectedQuartzRect: expectedQuartzRect)
        }.first
    }

    private func statusItemWindowQuartzRect(from info: [String: Any], screenQuartzRect: CGRect, menuBarQuartzRect: CGRect) -> CGRect? {
        guard
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 25,
            let bounds = info[kCGWindowBounds as String] as? [String: Any],
            let quartzRect = rectFromWindowBounds(bounds),
            quartzRect.intersects(screenQuartzRect),
            quartzRect.intersects(menuBarQuartzRect)
        else {
            return nil
        }

        return quartzRect
    }

    private func statusItemMatchScore(_ quartzRect: CGRect, expectedQuartzRect: CGRect) -> CGFloat {
        let centerDistance = abs(quartzRect.midX - expectedQuartzRect.midX) + abs(quartzRect.midY - expectedQuartzRect.midY)
        let sizeDistance = abs(quartzRect.width - expectedQuartzRect.width) + abs(quartzRect.height - expectedQuartzRect.height)
        return centerDistance + sizeDistance
    }

    private func quartzMenuBarRect(on screen: NSScreen) -> CGRect {
        let screenQuartzRect = quartzRectFromAppKitRect(screen.frame)
        let menuBarHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(
            x: screenQuartzRect.minX,
            y: screenQuartzRect.minY - 2,
            width: screen.frame.width,
            height: menuBarHeight + 4
        )
    }

    private func isHiddenBarStatusWindow(_ info: [String: Any], appBundleIdentifier: String?) -> Bool {
        let title = info[kCGWindowName as String] as? String
        return title == appBundleIdentifier || title?.hasPrefix("hiddenbar_") == true
    }

    private func rectFromWindowBounds(_ bounds: [String: Any]) -> CGRect? {
        guard
            let x = bounds["X"] as? NSNumber,
            let y = bounds["Y"] as? NSNumber,
            let width = bounds["Width"] as? NSNumber,
            let height = bounds["Height"] as? NSNumber
        else {
            return nil
        }
        return CGRect(
            x: CGFloat(truncating: x),
            y: CGFloat(truncating: y),
            width: CGFloat(truncating: width),
            height: CGFloat(truncating: height)
        )
    }

    private func appKitRectFromQuartzRect(_ quartzRect: CGRect, on screen: NSScreen) -> CGRect {
        let referenceMaxY = NSScreen.main?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: quartzRect.minX,
            y: referenceMaxY - quartzRect.maxY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    private func quartzRectFromAppKitRect(_ appKitRect: CGRect) -> CGRect {
        let referenceMaxY = NSScreen.main?.frame.maxY ?? appKitRect.maxY
        return CGRect(
            x: appKitRect.minX,
            y: referenceMaxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    private enum NativeMenuBarRelation {
        case leftOf(windowNumber: Int)
        case rightOf(windowNumber: Int)

        var targetWindowNumber: Int {
            switch self {
            case .leftOf(let windowNumber), .rightOf(let windowNumber):
                return windowNumber
            }
        }
    }

    private struct NativeMenuBarWindow {
        let windowNumber: Int
        let sourcePID: pid_t
        let quartzRect: CGRect
    }

    private func activateHiddenItem(_ item: HiddenItemsBarItem, from capture: HiddenItemsBarCapture) {
        let cursorBefore = CGEvent(source: nil)?.location
        guard canForwardClicksToMenuBarItems() else {
            notchInteractionDebug(
                "click denied windowID=\(item.windowNumber) sourceRect=\(NSStringFromRect(item.sourceRect)) cursorBefore=\(cursorBefore.map { NSStringFromPoint($0) } ?? "nil")"
            )
            return
        }
        guard !isNativeMenuBarMutationInFlight else {
            notchInteractionDebug("click busy windowID=\(item.windowNumber)")
            return
        }

        isNativeMenuBarMutationInFlight = true
        pendingNativeRestoreWorkItem?.cancel()
        hiddenItemsBarController.hide()

        notchInteractionDebug(
            "click begin windowID=\(item.windowNumber) ownerPID=\(item.sourcePID) sourceRect=\(NSStringFromRect(item.sourceRect)) screen=\(NSStringFromRect(capture.screen.frame)) cursorBefore=\(cursorBefore.map { NSStringFromPoint($0) } ?? "nil")"
        )

        let cursorLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let cursorLocation {
                CGWarpMouseCursorPosition(cursorLocation)
            }
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        let initialRect = currentQuartzRect(forMenuBarWindow: item.windowNumber)
            ?? quartzRectFromAppKitRect(item.sourceRect)
        let alreadyVisible = isQuartzRectVisibleInRightMenuBar(initialRect, on: capture.screen)
        var returnRelation = returnRelation(forWindowNumber: item.windowNumber)
        var didTemporarilyMove = false

        if !alreadyVisible {
            guard let slot = visibleSlotRelation(on: capture.screen, excluding: item.windowNumber) else {
                notchInteractionDebug("click noVisibleSlot windowID=\(item.windowNumber)")
                finishNativeMenuBarMutation(refreshProxy: true)
                return
            }
            if returnRelation == nil {
                returnRelation = slot
            }
            notchInteractionDebug(
                "click tempMove windowID=\(item.windowNumber) to=\(slot.targetWindowNumber) return=\(returnRelation?.targetWindowNumber ?? -1)"
            )
            guard moveNativeMenuBarWindow(
                windowNumber: item.windowNumber,
                ownerPID: item.sourcePID,
                relation: slot,
                timeout: 0.45
            ) else {
                notchInteractionDebug("click tempMoveFailed windowID=\(item.windowNumber)")
                finishNativeMenuBarMutation(refreshProxy: true)
                return
            }
            didTemporarilyMove = true
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.08))
        }

        let posted = postTargetedClick(windowNumber: item.windowNumber, ownerPID: item.sourcePID)
        let cursorImmediate = CGEvent(source: nil)?.location
        notchInteractionDebug(
            "click targetedEventsPosted windowID=\(item.windowNumber) ownerPID=\(item.sourcePID) posted=\(posted) moved=\(didTemporarilyMove) cursorImmediate=\(cursorImmediate.map { NSStringFromPoint($0) } ?? "nil")"
        )

        guard didTemporarilyMove, let returnRelation else {
            finishNativeMenuBarMutation(refreshProxy: true)
            return
        }

        scheduleNativeRestore(
            windowNumber: item.windowNumber,
            ownerPID: item.sourcePID,
            relation: returnRelation,
            screen: capture.screen
        )
    }

    private func moveHiddenItem(_ item: HiddenItemsBarItem, relativeTo target: HiddenItemsBarItem, placeAfter: Bool) {
        notchInteractionDebug(
            "moveHiddenItem entered sourceWindowID=\(item.windowNumber) sourceRect=\(NSStringFromRect(item.sourceRect)) targetWindowID=\(target.windowNumber) targetRect=\(NSStringFromRect(target.sourceRect)) placeAfter=\(placeAfter)"
        )
        guard canForwardClicksToMenuBarItems() else { return }
        guard !isNativeMenuBarMutationInFlight else {
            notchInteractionDebug("moveHiddenItem busy")
            return
        }
        guard item.windowNumber != target.windowNumber else { return }

        isNativeMenuBarMutationInFlight = true
        pendingNativeRestoreWorkItem?.cancel()
        hiddenItemsBarController.hide()

        let cursorLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let cursorLocation {
                CGWarpMouseCursorPosition(cursorLocation)
            }
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        let relation: NativeMenuBarRelation = placeAfter
            ? .rightOf(windowNumber: target.windowNumber)
            : .leftOf(windowNumber: target.windowNumber)
        let moved = moveNativeMenuBarWindow(
            windowNumber: item.windowNumber,
            ownerPID: item.sourcePID,
            relation: relation,
            timeout: 0.55
        )
        notchInteractionDebug(
            "moveHiddenItem finished sourceWindowID=\(item.windowNumber) targetWindowID=\(target.windowNumber) moved=\(moved)"
        )
        finishNativeMenuBarMutation(refreshProxy: true)
    }

    private func scheduleNativeRestore(
        windowNumber: Int,
        ownerPID: pid_t,
        relation: NativeMenuBarRelation,
        screen: NSScreen
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreNativeMenuBarWindow(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                relation: relation,
                screen: screen,
                attempt: 0
            )
        }
        pendingNativeRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: workItem)
    }

    private func restoreNativeMenuBarWindow(
        windowNumber: Int,
        ownerPID: pid_t,
        relation: NativeMenuBarRelation,
        screen: NSScreen,
        attempt: Int
    ) {
        if ownerPIDHasTransientMenuBarUI(ownerPID) && attempt < 12 {
            notchInteractionDebug("restore waitUI windowID=\(windowNumber) attempt=\(attempt)")
            let workItem = DispatchWorkItem { [weak self] in
                self?.restoreNativeMenuBarWindow(
                    windowNumber: windowNumber,
                    ownerPID: ownerPID,
                    relation: relation,
                    screen: screen,
                    attempt: attempt + 1
                )
            }
            pendingNativeRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
            return
        }

        let cursorLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        let restored = moveNativeMenuBarWindow(
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            relation: relation,
            timeout: 0.55
        )
        if let cursorLocation {
            CGWarpMouseCursorPosition(cursorLocation)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        notchInteractionDebug(
            "restore finished windowID=\(windowNumber) restored=\(restored) attempt=\(attempt)"
        )
        finishNativeMenuBarMutation(refreshProxy: true)
    }

    private func finishNativeMenuBarMutation(refreshProxy: Bool) {
        pendingNativeRestoreWorkItem?.cancel()
        pendingNativeRestoreWorkItem = nil
        isNativeMenuBarMutationInFlight = false
        guard refreshProxy, Preferences.showHiddenItemsInSeparateBar else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.expandHiddenItemsBar()
        }
    }

    private func moveNativeMenuBarWindow(
        windowNumber: Int,
        ownerPID: pid_t,
        relation: NativeMenuBarRelation,
        timeout: TimeInterval
    ) -> Bool {
        for attempt in 1...3 {
            guard
                let sourceRect = currentQuartzRect(forMenuBarWindow: windowNumber),
                let targetRect = currentQuartzRect(forMenuBarWindow: relation.targetWindowNumber),
                let targetPID = menuBarWindowOwnerPID(for: relation.targetWindowNumber)
            else {
                notchInteractionDebug(
                    "nativeMove missingGeometry windowID=\(windowNumber) target=\(relation.targetWindowNumber) attempt=\(attempt)"
                )
                return false
            }

            if nativeWindow(sourceRect, satisfies: relation, targetRect: targetRect) {
                notchInteractionDebug(
                    "nativeMove alreadyPlaced windowID=\(windowNumber) target=\(relation.targetWindowNumber)"
                )
                return true
            }

            let points = movePoints(sourceRect: sourceRect, targetRect: targetRect, relation: relation)
            guard postNativeMenuBarMove(
                sourceWindowNumber: windowNumber,
                sourcePID: ownerPID,
                targetWindowNumber: relation.targetWindowNumber,
                targetPID: targetPID,
                start: points.start,
                end: points.end
            ) else {
                continue
            }

            if let updated = waitForWindowMove(windowNumber: windowNumber, from: sourceRect, timeout: timeout),
               nativeWindow(updated, satisfies: relation, targetRect: currentQuartzRect(forMenuBarWindow: relation.targetWindowNumber) ?? targetRect)
                || hypot(updated.minX - sourceRect.minX, updated.minY - sourceRect.minY) > 1
            {
                notchInteractionDebug(
                    "nativeMove ok windowID=\(windowNumber) attempt=\(attempt) rect=\(NSStringFromRect(updated))"
                )
                return true
            }
            notchInteractionDebug("nativeMove retry windowID=\(windowNumber) attempt=\(attempt)")
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func postNativeMenuBarMove(
        sourceWindowNumber: Int,
        sourcePID: pid_t,
        targetWindowNumber: Int,
        targetPID: pid_t,
        start: CGPoint,
        end: CGPoint
    ) -> Bool {
        let source = makeMenuBarEventSource()
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
        else {
            return false
        }

        configureNativeMenuBarMoveEvent(mouseDown, windowNumber: sourceWindowNumber, ownerPID: sourcePID, command: true)
        configureNativeMenuBarMoveEvent(mouseUp, windowNumber: targetWindowNumber, ownerPID: targetPID, command: false)
        mouseDown.post(tap: .cghidEventTap)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        mouseUp.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    private func postTargetedClick(windowNumber: Int, ownerPID: pid_t) -> Bool {
        let source = makeMenuBarEventSource()
        let currentRect = currentQuartzRect(forMenuBarWindow: windowNumber)
        guard let currentRect else {
            notchInteractionDebug("click targetedEventNoRect windowID=\(windowNumber)")
            return false
        }
        let clickPoint = CGPoint(x: currentRect.midX, y: currentRect.midY)
        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: clickPoint,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: clickPoint,
                mouseButton: .left
            )
        else {
            notchInteractionDebug("click targetedEventCreationFailed windowID=\(windowNumber)")
            return false
        }

        configureTargetedClickEvent(mouseDown, windowNumber: windowNumber, ownerPID: ownerPID, clickState: 1)
        configureTargetedClickEvent(mouseUp, windowNumber: windowNumber, ownerPID: ownerPID, clickState: 0)
        notchInteractionDebug(
            "click targetedEventBegin windowID=\(windowNumber) ownerPID=\(ownerPID) currentRect=\(NSStringFromRect(currentRect)) clickPoint=\(NSStringFromPoint(clickPoint))"
        )
        mouseDown.postToPid(ownerPID)
        mouseUp.postToPid(ownerPID)
        mouseUp.postToPid(ownerPID)
        return true
    }

    private func makeMenuBarEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }

    private func configureNativeMenuBarMoveEvent(
        _ event: CGEvent,
        windowNumber: Int,
        ownerPID: pid_t,
        command: Bool
    ) {
        let windowID = Int64(windowNumber)
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(menuBarItemWindowIDField, value: windowID)
    }

    private func configureTargetedClickEvent(
        _ event: CGEvent,
        windowNumber: Int,
        ownerPID: pid_t,
        clickState: Int64
    ) {
        let windowID = Int64(windowNumber)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
    }

    private func movePoints(
        sourceRect: CGRect,
        targetRect: CGRect,
        relation: NativeMenuBarRelation
    ) -> (start: CGPoint, end: CGPoint) {
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

    private func nativeWindow(_ sourceRect: CGRect, satisfies relation: NativeMenuBarRelation, targetRect: CGRect) -> Bool {
        switch relation {
        case .leftOf:
            return abs(sourceRect.maxX - targetRect.minX) <= 1.5
        case .rightOf:
            return abs(sourceRect.minX - targetRect.maxX) <= 1.5
        }
    }

    private func waitForWindowMove(windowNumber: Int, from initialRect: CGRect, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = currentQuartzRect(forMenuBarWindow: windowNumber)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            latest = currentQuartzRect(forMenuBarWindow: windowNumber)
            if let latest, hypot(latest.minX - initialRect.minX, latest.minY - initialRect.minY) > 1 {
                return latest
            }
        }
        return latest
    }

    private func returnRelation(forWindowNumber windowNumber: Int) -> NativeMenuBarRelation? {
        let windows = orderedStatusWindows()
        guard let index = windows.firstIndex(where: { $0.windowNumber == windowNumber }) else {
            return nil
        }
        if windows.indices.contains(index + 1) {
            return .leftOf(windowNumber: windows[index + 1].windowNumber)
        }
        if windows.indices.contains(index - 1) {
            return .rightOf(windowNumber: windows[index - 1].windowNumber)
        }
        return nil
    }

    private func visibleSlotRelation(on screen: NSScreen, excluding windowNumber: Int) -> NativeMenuBarRelation? {
        if let separatorWindowNumber = btnSeparate.button?.window?.windowNumber,
           separatorWindowNumber != windowNumber
        {
            return .leftOf(windowNumber: separatorWindowNumber)
        }

        let rightArea = rightMenuBarArea(on: screen)
        let visible = orderedStatusWindows().filter { window in
            window.windowNumber != windowNumber
                && appKitRectFromQuartzRect(window.quartzRect, on: screen).minX >= rightArea.minX - 2
        }
        guard let anchor = visible.first else { return nil }
        return .leftOf(windowNumber: anchor.windowNumber)
    }

    private func orderedStatusWindows() -> [NativeMenuBarWindow] {
        guard let windowList = menuBarWindowList() else { return [] }
        return windowList.compactMap { info -> NativeMenuBarWindow? in
            guard
                (info[kCGWindowLayer as String] as? Int) == 25,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let sourcePID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let quartzRect = rectFromWindowBounds(bounds),
                quartzRect.width > 4,
                quartzRect.height > 4
            else {
                return nil
            }
            return NativeMenuBarWindow(windowNumber: windowNumber, sourcePID: sourcePID, quartzRect: quartzRect)
        }
        .sorted { $0.quartzRect.minX < $1.quartzRect.minX }
    }

    private func menuBarWindowOwnerPID(for windowNumber: Int) -> pid_t? {
        orderedStatusWindows().first(where: { $0.windowNumber == windowNumber })?.sourcePID
    }

    private func isQuartzRectVisibleInRightMenuBar(_ quartzRect: CGRect, on screen: NSScreen) -> Bool {
        let appKitRect = appKitRectFromQuartzRect(quartzRect, on: screen)
        let rightArea = rightMenuBarArea(on: screen)
        return appKitRect.minX >= rightArea.minX - 2 && appKitRect.maxX <= rightArea.maxX + 2
    }

    private func rightMenuBarArea(on screen: NSScreen) -> CGRect {
        if #available(macOS 12.0, *), let auxiliaryRightArea = screen.auxiliaryTopRightArea {
            return auxiliaryRightArea
        }
        let menuBarHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(
            x: screen.frame.midX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width / 2,
            height: menuBarHeight
        )
    }

    private func ownerPIDHasTransientMenuBarUI(_ ownerPID: pid_t) -> Bool {
        let ownStatusWindows = Set(orderedStatusWindows().map(\.windowNumber))
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return false
        }

        return windows.contains { info in
            guard
                (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                !ownStatusWindows.contains(windowNumber),
                let layer = info[kCGWindowLayer as String] as? Int,
                layer >= 0,
                (info[kCGWindowAlpha as String] as? Double) ?? 1 > 0.05
            else {
                return false
            }
            return true
        }
    }

    private func currentQuartzRect(forMenuBarWindow windowNumber: Int) -> CGRect? {
        menuBarWindowList()?.first(where: { info in
            (info[kCGWindowNumber as String] as? Int) == windowNumber
        }).flatMap { info in
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return rectFromWindowBounds(bounds)
        }
    }

    private func canForwardClicksToMenuBarItems() -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        return false
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        updateCollapsedLengths()

        if Preferences.alwaysHiddenSectionEnabled {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = NSStatusBar.system.statusItem(withLength: btnAlwaysHiddenLength)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
            }
            self.btnAlwaysHidden?.autosaveName = "hiddenbar_terminate"
            self.btnAlwaysHidden?.isVisible = true
        } else {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
        }
    }
}
