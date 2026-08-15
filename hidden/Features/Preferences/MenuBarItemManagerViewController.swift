import AppKit
import ApplicationServices

final class MenuBarItemManagerViewController: NSViewController {
    private enum Drag {
        static let type = NSPasteboard.PasteboardType("com.dwarvesv.minimalbar.menu-item")
    }

    private let hiddenTable = NSTableView()
    private let visibleTable = NSTableView()
    private let hiddenCountLabel = NSTextField(labelWithString: "")
    private let visibleCountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "Grant Access".localized, target: nil, action: nil)
    private let managerRoot = NSStackView()
    private let permissionRoot = NSStackView()
    private let permissionTitle = NSTextField(labelWithString: "")
    private let permissionStep = NSTextField(labelWithString: "")
    private let permissionDetail = NSTextField(wrappingLabelWithString: "")
    private var hiddenItems: [ManagedMenuBarItem] = []
    private var visibleItems: [ManagedMenuBarItem] = []
    private var layout: MenuBarManagementLayout?
    private var separatorWindowNumber: Int?
    private var expandCollapseWindowNumber: Int?
    private var isBusy = false
    private var autoRefreshTimer: Timer?
    private var presentWork: DispatchWorkItem?
    private var didRequestScreenCapture = false
    private var pinnedStatus: String?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 540))
        preferredContentSize = NSSize(width: 640, height: 540)
        buildUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeWindowToFit()
        if autoRefreshTimer == nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(self, selector: #selector(autoRefresh), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            workspace.addObserver(self, selector: #selector(autoRefresh), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.present(reuseLayout: true)
            }
        }
        present()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func resizeWindowToFit() {
        guard let window = view.window else { return }
        let size = preferredContentSize
        var content = window.contentRect(forFrameRect: window.frame)
        guard content.width < size.width || content.height < size.height else { return }
        content.size = size
        var frame = window.frameRect(forContentRect: content)
        frame.origin.y += window.frame.height - frame.height
        window.setFrame(frame, display: true)
    }

    private func buildUI() {
        configure(table: hiddenTable, identifier: "hidden")
        configure(table: visibleTable, identifier: "visible")

        let help = NSTextField(wrappingLabelWithString: "Drag items within a list to reorder them, or between lists to hide and show them.".localized)
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.maximumNumberOfLines = 2
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let columns = NSStackView(views: [
            makeColumn(title: "Hidden".localized, countLabel: hiddenCountLabel, table: hiddenTable),
            makeColumn(title: "Visible".localized, countLabel: visibleCountLabel, table: visibleTable)
        ])
        columns.orientation = .horizontal
        columns.spacing = 16
        columns.distribution = .fillEqually
        columns.setContentHuggingPriority(.defaultLow, for: .vertical)

        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(permissionPressed)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        managerRoot.orientation = .vertical
        managerRoot.alignment = .leading
        managerRoot.spacing = 12
        managerRoot.translatesAutoresizingMaskIntoConstraints = false
        [help, columns, footer].forEach(managerRoot.addArrangedSubview)

        permissionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        permissionTitle.alignment = .center
        permissionStep.textColor = .secondaryLabelColor
        permissionStep.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionStep.alignment = .center
        permissionDetail.textColor = .secondaryLabelColor
        permissionDetail.font = .systemFont(ofSize: NSFont.systemFontSize)
        permissionDetail.alignment = .center
        permissionDetail.maximumNumberOfLines = 3
        permissionButton.bezelStyle = .rounded

        permissionRoot.orientation = .vertical
        permissionRoot.alignment = .centerX
        permissionRoot.spacing = 12
        permissionRoot.translatesAutoresizingMaskIntoConstraints = false
        permissionRoot.isHidden = true
        [permissionTitle, permissionStep, permissionDetail, permissionButton].forEach(permissionRoot.addArrangedSubview)

        view.addSubview(managerRoot)
        view.addSubview(permissionRoot)
        NSLayoutConstraint.activate([
            managerRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            managerRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            managerRoot.topAnchor.constraint(equalTo: view.topAnchor, constant: 38),
            managerRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            columns.widthAnchor.constraint(equalTo: managerRoot.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            footer.widthAnchor.constraint(equalTo: managerRoot.widthAnchor),
            permissionRoot.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            permissionRoot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            permissionRoot.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 48),
            permissionRoot.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -48),
            permissionDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    private func configure(table: NSTableView, identifier: String) {
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        table.headerView = nil
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Drag.type])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
    }

    private func makeColumn(title: String, countLabel: NSTextField, table: NSTableView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let header = NSStackView(views: [label, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .lastBaseline

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
        return stack
    }

    @objc private func autoRefresh() {
        schedulePresent(reuseLayout: true)
    }

    @objc private func appDidBecomeActive() {
        guard view.window?.isVisible == true else { return }
        schedulePresent()
    }

    @objc private func permissionPressed() {
        if !AXIsProcessTrusted() {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(prompt)
            openPrivacySettings(anchors: [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ])
            return
        }
        if !CGPreflightScreenCaptureAccess(), !didRequestScreenCapture {
            didRequestScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func schedulePresent(reuseLayout: Bool = false) {
        presentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.present(reuseLayout: reuseLayout)
        }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func present(reuseLayout: Bool = false) {
        if !AXIsProcessTrusted() {
            showPermissionGate(step: 1)
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            didRequestScreenCapture = false
            showPermissionGate(step: 2)
            return
        }
        showManager()
        refresh(reuseLayout: reuseLayout)
    }

    private func showPermissionGate(step: Int) {
        isBusy = false
        managerRoot.isHidden = true
        permissionRoot.isHidden = false
        permissionTitle.stringValue = "Permission required".localized
        if step == 1 {
            permissionStep.stringValue = "Step 1 of 2".localized
            permissionDetail.stringValue = "Accessibility is required to name and move menu bar items.".localized
            permissionButton.title = "Grant Accessibility".localized
        } else {
            permissionStep.stringValue = "Step 2 of 2".localized
            permissionDetail.stringValue = "Screen Recording is required to show menu bar icons.".localized
            permissionButton.title = "Grant Screen Recording".localized
        }
    }

    private func showManager() {
        permissionRoot.isHidden = true
        managerRoot.isHidden = false
    }

    private func openPrivacySettings(anchors: [String]) {
        for string in anchors {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func refresh(reuseLayout: Bool = false) {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            present()
            return
        }
        guard !isBusy, let appDelegate = NSApp.delegate as? AppDelegate else { return }
        isBusy = true
        let scan: (MenuBarManagementLayout) -> Void = { [weak self] layout in
            guard let self else { return }
            self.layout = layout
            let ownPID = ProcessInfo.processInfo.processIdentifier
            self.separatorWindowNumber = MenuBarItemMover.windowNumber(ownedBy: ownPID, nearestAppKitFrame: layout.separatorFrame)
            self.expandCollapseWindowNumber = MenuBarItemMover.windowNumber(ownedBy: ownPID, nearestAppKitFrame: layout.expandCollapseFrame)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let items = MenuBarItemMover.extras(layout: layout)
                let trusted = AXIsProcessTrusted()
                DispatchQueue.main.async {
                    self?.apply(items, accessibilityTrusted: trusted)
                }
            }
        }
        if reuseLayout, let layout {
            scan(layout)
        } else {
            appDelegate.statusBarController.prepareForItemManagement(completion: scan)
        }
    }

    private func apply(_ items: [ManagedMenuBarItem], accessibilityTrusted: Bool) {
        isBusy = false
        if !accessibilityTrusted || !CGPreflightScreenCaptureAccess() {
            present()
            return
        }
        showManager()
        hiddenItems = items.filter { $0.section == .hidden }
        visibleItems = items.filter { $0.section == .visible }
        hiddenTable.reloadData()
        visibleTable.reloadData()
        hiddenCountLabel.stringValue = "\(hiddenItems.count)"
        visibleCountLabel.stringValue = "\(visibleItems.count)"
        if let pinnedStatus {
            statusLabel.stringValue = pinnedStatus
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = items.isEmpty
                ? "No identifiable menu bar items were found.".localized
                : "Drop an item to apply the real menu bar position.".localized
        }
        isBusy = false
    }

    private func items(for table: NSTableView) -> [ManagedMenuBarItem] {
        table === hiddenTable ? hiddenItems : visibleItems
    }

    private func move(_ item: ManagedMenuBarItem, to table: NSTableView, row: Int) {
        hiddenItems.removeAll { $0.id == item.id }
        visibleItems.removeAll { $0.id == item.id }
        let destination = items(for: table)
        let clampedRow = max(0, min(row, destination.count))
        let relation: NativeMenuBarRelation?
        if destination.isEmpty {
            if table === hiddenTable, let separatorWindowNumber {
                relation = .leftOf(windowNumber: separatorWindowNumber)
            } else if let expandCollapseWindowNumber {
                relation = .rightOf(windowNumber: expandCollapseWindowNumber)
            } else {
                relation = nil
            }
        } else if clampedRow == destination.count {
            relation = .rightOf(windowNumber: destination[destination.count - 1].windowNumber)
        } else {
            relation = .leftOf(windowNumber: destination[clampedRow].windowNumber)
        }
        if table === hiddenTable {
            hiddenItems.insert(item, at: clampedRow)
        } else {
            visibleItems.insert(item, at: clampedRow)
        }
        hiddenTable.reloadData()
        visibleTable.reloadData()
        hiddenCountLabel.stringValue = "\(hiddenItems.count)"
        visibleCountLabel.stringValue = "\(visibleItems.count)"

        guard let relation else {
            reportMoveFailure("Couldn't find a drop target in the menu bar.".localized)
            return
        }

        isBusy = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let result = MenuBarItemMover.move(item, relation: relation)
            self.isBusy = false
            switch result {
            case .moved, .alreadyThere:
                self.clearPinnedStatus()
                self.statusLabel.stringValue = "Drop an item to apply the real menu bar position.".localized
            case .crossedNotch:
                self.reportMoveFailure("Couldn't move that item across the notch.".localized)
                self.refresh(reuseLayout: true)
            case .full:
                self.reportMoveFailure("The right side of the menu bar is full.".localized)
                self.refresh(reuseLayout: true)
            case .missingWindows, .timedOut:
                self.reportMoveFailure("Couldn't place that item. It was moved back.".localized)
                self.refresh(reuseLayout: true)
            }
        }
    }

    private func reportMoveFailure(_ message: String) {
        pinnedStatus = message
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    private func clearPinnedStatus() {
        pinnedStatus = nil
        statusLabel.textColor = .secondaryLabelColor
    }
}

extension MenuBarItemManagerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items(for: tableView).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items(for: tableView)[row]
        let cell = NSTableCellView()
        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = MenuBarItemPresentation.wellBackground(for: item.icon).cgColor
        well.layer?.cornerRadius = 5
        well.layer?.masksToBounds = true
        let imageView = NSImageView()
        imageView.image = item.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(imageView)
        let label = NSTextField(labelWithString: item.primaryName)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [well, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 26),
            well.heightAnchor.constraint(equalToConstant: 26),
            imageView.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 3),
            imageView.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -3),
            imageView.topAnchor.constraint(equalTo: well.topAnchor, constant: 3),
            imageView.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(items(for: tableView)[row].id, forType: Drag.type)
        return pasteboardItem
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard
            let id = info.draggingPasteboard.string(forType: Drag.type),
            let item = (hiddenItems + visibleItems).first(where: { $0.id == id })
        else { return false }
        move(item, to: tableView, row: row)
        return true
    }
}
