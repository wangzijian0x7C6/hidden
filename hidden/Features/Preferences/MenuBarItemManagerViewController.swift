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
    private var hiddenItems: [ManagedMenuBarItem] = []
    private var visibleItems: [ManagedMenuBarItem] = []
    private var layout: MenuBarManagementLayout?
    private var separatorWindowNumber: Int?
    private var expandCollapseWindowNumber: Int?
    private var isBusy = false
    private var autoRefreshTimer: Timer?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        buildUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
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
                self?.refresh(reuseLayout: true)
            }
        }
        refresh()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        permissionButton.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [statusLabel, permissionButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let root = NSStackView(views: [help, columns, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 38),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            columns.widthAnchor.constraint(equalTo: root.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func configure(table: NSTableView, identifier: String) {
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        table.headerView = nil
        table.rowHeight = 32
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        return stack
    }

    @objc private func autoRefresh() {
        refresh(reuseLayout: true)
    }

    @objc private func appDidBecomeActive() {
        guard view.window?.isVisible == true else { return }
        refresh()
    }

    @objc private func permissionPressed() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        let settings = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for string in settings {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { break }
        }
        statusLabel.stringValue = "Enable Hidden Bar in System Settings, then return and refresh.".localized
    }

    private func refresh(reuseLayout: Bool = false) {
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
        hiddenItems = items.filter { $0.section == .hidden }
        visibleItems = items.filter { $0.section == .visible }
        hiddenTable.reloadData()
        visibleTable.reloadData()
        hiddenCountLabel.stringValue = "\(hiddenItems.count)"
        visibleCountLabel.stringValue = "\(visibleItems.count)"
        let needsAX = !accessibilityTrusted
        let needsScreen = !CGPreflightScreenCaptureAccess()
        permissionButton.isHidden = !needsAX && !needsScreen
        if needsAX || needsScreen {
            statusLabel.stringValue = "Grant Accessibility and Screen Recording to show names and icons.".localized
        } else {
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
            statusLabel.stringValue = "Couldn't find a drop target in the menu bar.".localized
            return
        }

        isBusy = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let result = MenuBarItemMover.move(item, relation: relation)
            self.isBusy = false
            switch result {
            case .moved, .alreadyThere:
                self.statusLabel.stringValue = "Drop an item to apply the real menu bar position.".localized
            case .crossedNotch:
                self.statusLabel.stringValue = "Couldn't move that item across the notch.".localized
                self.refresh(reuseLayout: true)
            case .missingWindows, .timedOut:
                self.statusLabel.stringValue = "Couldn't move that item. Try again after refreshing.".localized
                self.refresh(reuseLayout: true)
            }
        }
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
