import AppKit
import Foundation

// MARK: - Editability
//
// The window opens writable or read-only. Read-only reasons (shown in the
// banner): the config is a Home Manager store symlink, or another editable
// window holds the advisory lock. Read-only mode disables every mutation —
// drag/drop, Save — but keeps Revert/Reveal/Reload usable for inspection.

struct ConfigEditability: Sendable {
    let isEditable: Bool
    let banner: String?

    static func writable(_ extraBanner: String?) -> ConfigEditability {
        ConfigEditability(isEditable: true, banner: extraBanner)
    }

    static func readOnly(_ reason: String) -> ConfigEditability {
        ConfigEditability(isEditable: false, banner: reason)
    }
}

// MARK: - Advisory lock (config.json.lock; PID + stale reclaim)
//
// One writable editor at a time: the lock carries the holder's PID; a dead
// holder's lock is reclaimed. Held for the window's lifetime, released on
// close.

enum ConfigLock {
    static func path(for configPath: String) -> String {
        "\(configPath).lock"
    }

    /// Returns nil when acquired, or the holder's reason line when refused.
    static func acquire(configPath: String) -> String? {
        let lockPath = path(for: configPath)
        if let contents = try? String(contentsOfFile: lockPath, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            if alive {
                return "another configuration window (PID \(pid)) is editing this file"
            }
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        do {
            try "\(ProcessInfo.processInfo.processIdentifier)"
                .write(toFile: lockPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "cannot create the edit lock at \(lockPath)"
        }
    }

    static func release(configPath: String) {
        try? FileManager.default.removeItem(atPath: path(for: configPath))
    }
}

// MARK: - Row payload (drag-and-drop data)

/// The private pasteboard payload for a dragged row: either an available
/// device (identified by uid) or a priority tier (identified by its index).
enum RowPayload: Sendable {
    case device(uid: String)
    case tier(index: Int)

    static let pasteboardType = NSPasteboard.PasteboardType("alex.device-priority-sanitizer.row")

    static func write(_ payload: RowPayload, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(payload.encoded, forType: RowPayload.pasteboardType)
    }

    static func read(from pasteboard: NSPasteboard) -> RowPayload? {
        guard let string = pasteboard.string(forType: RowPayload.pasteboardType) else { return nil }
        return RowPayload(encoded: string)
    }

    var encoded: String {
        switch self {
        case .device(let uid): return "device:\(uid)"
        case .tier(let index): return "tier:\(index)"
        }
    }

    init?(encoded: String) {
        if encoded.hasPrefix("device:") {
            self = .device(uid: String(encoded.dropFirst("device:".count)))
        } else if encoded.hasPrefix("tier:") {
            guard let index = Int(encoded.dropFirst("tier:".count)) else { return nil }
            self = .tier(index: index)
        } else {
            return nil
        }
    }
}

/// Minimal NSPasteboardWriting bridge for `RowPayload`.
final class RowPasteboard: NSObject, NSPasteboardWriting {
    private let payload: RowPayload

    init(payload: RowPayload) {
        self.payload = payload
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [RowPayload.pasteboardType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        payload.encoded
    }
}

// MARK: - Cell view

/// A symbol + title (+ optional subtitle) row. Frame-based layout — the cell
/// is rebuilt per refresh, so the width tracks the table.
final class RowCell: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleView = NSTextField(labelWithString: "")
    private let subtitleView = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.frame = NSRect(x: 4, y: (frameRect.height - 18) / 2, width: 18, height: 18)
        titleView.font = .systemFont(ofSize: 12)
        subtitleView.font = .systemFont(ofSize: 10)
        subtitleView.textColor = .secondaryLabelColor
        [symbolView, titleView, subtitleView].forEach(addSubview)
        layout(width: frameRect.width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    private func layout(width: CGFloat) {
        let hasSubtitle = !subtitleView.stringValue.isEmpty
        let textHeight: CGFloat = hasSubtitle ? 32 : 16
        let textY = (bounds.height - textHeight) / 2
        titleView.frame = NSRect(
            x: 28, y: hasSubtitle ? textY + 15 : textY, width: width - 32, height: 16
        )
        subtitleView.frame = NSRect(x: 28, y: hasSubtitle ? textY - 1 : textY, width: width - 32, height: 12)
        subtitleView.isHidden = !hasSubtitle
    }

    func configure(symbol: String, title: String, subtitle: String) {
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleView.stringValue = title
        subtitleView.stringValue = subtitle
        layout(width: bounds.width)
    }
}

// MARK: - One target's pane (available + priority lists)

final class TargetPane: NSView {
    let target: Target
    let availableTable = NSTableView()
    let priorityTable = NSTableView()
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let unmanagedNote = NSTextField(labelWithString: "")

    init(target: Target) {
        self.target = target
        super.init(frame: .zero)
        for table in [availableTable, priorityTable] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
            table.addTableColumn(column)
            table.headerView = nil
            table.usesAlternatingRowBackgroundColors = true
            table.backgroundColor = .controlBackgroundColor
            table.rowHeight = 30
            table.registerForDraggedTypes([RowPayload.pasteboardType])
            table.draggingDestinationFeedbackStyle = .regular
        }

        let availableHeader = NSTextField(labelWithString: "Available")
        availableHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        let priorityHeader = NSTextField(labelWithString: "Priority")
        priorityHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        removeButton.bezelStyle = .smallSquare
        removeButton.controlSize = .small
        unmanagedNote.font = .systemFont(ofSize: 10)
        unmanagedNote.textColor = .secondaryLabelColor
        unmanagedNote.stringValue = "Not auto-managed (empty priority list)"

        let availableScroll = NSScrollView()
        let priorityScroll = NSScrollView()
        for (scroll, table) in [(availableScroll, availableTable), (priorityScroll, priorityTable)] {
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroll)
        }
        [availableHeader, priorityHeader, removeButton, unmanagedNote].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            availableHeader.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            availableHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            priorityHeader.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            priorityHeader.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 12),

            removeButton.centerYAnchor.constraint(equalTo: priorityHeader.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            availableScroll.topAnchor.constraint(equalTo: availableHeader.bottomAnchor, constant: 4),
            availableScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            availableScroll.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -8),
            availableScroll.bottomAnchor.constraint(equalTo: unmanagedNote.topAnchor, constant: -6),

            priorityScroll.topAnchor.constraint(equalTo: priorityHeader.bottomAnchor, constant: 4),
            priorityScroll.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 8),
            priorityScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            priorityScroll.bottomAnchor.constraint(equalTo: unmanagedNote.topAnchor, constant: -6),

            unmanagedNote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            unmanagedNote.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }
}

// MARK: - Window controller

/// The configuration window: three tabs (Speaker/Microphone/Camera), each
/// with an Available list (drag a device into the Priority list to manage
/// it) and a Priority list (drag to reorder; drag out or press Remove to
/// drop the tier). Save writes the document atomically and applies it — via
/// the owning agent in-process, or via a distributed notification when the
/// window runs standalone (CLI `config`).
final class ConfigWindowController: NSWindowController, NSWindowDelegate {
    private let source: DeviceSource
    private let statePath: String
    /// Agent mode: reload+apply in-process. Standalone: nil → post the
    /// config-changed notification so a running agent reloads.
    private let onSaveApply: ((AppConfig) -> Void)?
    private let standalone: Bool

    private var configDocument: ConfigDocument
    private var devices: [MediaDevice] = []
    private var editability: ConfigEditability
    private var isDirty = false
    private var panes: [TargetPane] = []
    /// Load failed and the user declined the start-empty recovery (agent
    /// mode): `show()` is a no-op and the controller is discarded.
    private(set) var failedToOpen = false

    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let bannerLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)

    init(
        configPath: String,
        statePath: String,
        source: DeviceSource,
        standalone: Bool,
        onSaveApply: ((AppConfig) -> Void)?
    ) {
        self.source = source
        self.statePath = statePath
        self.standalone = standalone
        self.onSaveApply = onSaveApply
        configDocument = ConfigDocument(path: configPath, raw: [:])
        var extraBanner: String?
        var readOnlyReason: String?

        // Load — a broken config offers the backup + start-empty recovery
        // instead of refusing to open.
        do {
            configDocument = try ConfigDocument.load(configPath)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Configuration could not be opened"
            alert.informativeText =
                "\(error)\n\nThe file is backed up and can be replaced with an empty configuration."
            alert.addButton(withTitle: "Start with empty configuration")
            alert.addButton(withTitle: standalone ? "Quit" : "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                do {
                    try ConfigDocument(path: configPath, raw: [:]).backup()
                    configDocument = ConfigDocument.empty(path: configPath)
                } catch {
                    logStderr("warning: could not back up the broken config: \(error)")
                    configDocument = ConfigDocument.empty(path: configPath)
                }
            } else if standalone {
                exit(0)
            } else {
                failedToOpen = true
            }
        }

        // Editability: read-only config (HM store symlink) or a live lock.
        // A failed open never holds the lock.
        if failedToOpen {
            editability = ConfigEditability.readOnly("configuration could not be opened")
        } else if configDocument.isReadOnly {
            readOnlyReason = "Managed by Home Manager — edit \(programName)'s Nix configuration and rebuild"
        } else if let lockReason = ConfigLock.acquire(configPath: configPath) {
            readOnlyReason = "Read-only — \(lockReason)"
        }
        if !failedToOpen, !resolveState(statePath).prioritizationEnabled {
            extraBanner =
                "Prioritization is disabled globally — enable it from the menubar or `\(programName) enable`."
        }
        editability =
            readOnlyReason.map(ConfigEditability.readOnly)
            ?? ConfigEditability.writable(extraBanner)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Device Priority Configuration"
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self
        if !failedToOpen {
            buildContent()
            refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    // MARK: Content layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)
        panes = Target.allCases.map { target in
            let pane = TargetPane(target: target)
            let item = NSTabViewItem(identifier: nil)
            item.label = target.menuTitle
            item.view = pane
            tabView.addTabViewItem(item)
            return pane
        }
        for pane in panes {
            [pane.availableTable, pane.priorityTable].forEach { table in
                table.dataSource = self
                table.delegate = self
            }
            pane.availableTable.target = self
            pane.availableTable.doubleAction = #selector(doubleClickAvailable(_:))
            pane.removeButton.target = self
            pane.removeButton.action = #selector(removeSelectedTier(_:))
        }
        // The camera tab documents the app-coverage caveat.
        if let cameraPane = panes.first(where: { $0.target == .camera }) {
            cameraPane.unmanagedNote.stringValue = "Apps must be set to System Default to follow this priority"
            cameraPane.unmanagedNote.textColor = .secondaryLabelColor
        }

        let bottom = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        bannerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        bannerLabel.textColor = .systemOrange

        saveButton.keyEquivalent = "s"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        revertButton.target = self
        revertButton.action = #selector(revert(_:))
        reloadButton.target = self
        reloadButton.action = #selector(reload(_:))
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        [pathLabel, statusLabel, bannerLabel, saveButton, revertButton, reloadButton, revealButton]
            .forEach { view in
                view.translatesAutoresizingMaskIntoConstraints = false
                bottom.addSubview(view)
            }

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),

            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            bottom.heightAnchor.constraint(equalToConstant: 56),

            bannerLabel.topAnchor.constraint(equalTo: bottom.topAnchor),
            bannerLabel.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            bannerLabel.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            pathLabel.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            pathLabel.widthAnchor.constraint(equalToConstant: 340),
            statusLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),

            saveButton.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            saveButton.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            revertButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            revertButton.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: revertButton.leadingAnchor, constant: -8),
            reloadButton.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            revealButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -8),
            revealButton.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
        ])
    }

    // MARK: Data plumbing

    private func pane(for tableView: NSTableView) -> TargetPane? {
        panes.first { $0.availableTable == tableView || $0.priorityTable == tableView }
    }

    private func pane(of button: NSButton) -> TargetPane? {
        panes.first { $0.removeButton == button }
    }

    private func rows(for target: Target) -> ConfigDocument.TargetRows {
        configDocument.rows(for: target, devices: devices)
    }

    private func refresh() {
        devices = source.allDevices()
        panes.forEach { pane in
            pane.availableTable.reloadData()
            pane.priorityTable.reloadData()
            pane.unmanagedNote.isHidden =
                pane.target == .camera
                ? !rows(for: pane.target).isManaged && pane.unmanagedNote.stringValue.isEmpty
                : rows(for: pane.target).isManaged
        }
        pathLabel.stringValue = configDocument.path
        bannerLabel.stringValue = editability.banner ?? ""
        bannerLabel.isHidden = editability.banner == nil
        statusLabel.stringValue =
            editability.isEditable
            ? (isDirty ? "Unsaved changes" : "Saved")
            : "Read-only"
        saveButton.isEnabled = editability.isEditable && isDirty
        revertButton.isEnabled = editability.isEditable && isDirty
    }

    private func markDirty() {
        guard editability.isEditable, !isDirty else { return }
        isDirty = true
        refresh()
    }

    private func refreshFromDisk() {
        do {
            configDocument = try ConfigDocument.load(configDocument.path)
            isDirty = false
        } catch {
            let alert = NSAlert()
            alert.messageText = "Configuration could not be reloaded"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        refresh()
    }

    // MARK: Actions

    @objc private func save(_ sender: Any?) {
        do {
            try configDocument.save()
            isDirty = false
            if let onSaveApply = onSaveApply {
                onSaveApply(try configDocument.appConfig())
            } else {
                DistributedNotificationCenter.default()
                    .post(name: configChangedNotificationName, object: nil)
            }
            refresh()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save the configuration"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func revert(_ sender: Any?) {
        refreshFromDisk()
    }

    @objc private func reload(_ sender: Any?) {
        if isDirty, editability.isEditable {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Reloading replaces the window's edits with the file on disk."
            alert.addButton(withTitle: "Discard and Reload")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        refreshFromDisk()
    }

    @objc private func reveal(_ sender: Any?) {
        NSWorkspace.shared.selectFile(
            configDocument.path,
            inFileViewerRootedAtPath: (configDocument.path as NSString).deletingLastPathComponent
        )
    }

    @objc private func doubleClickAvailable(_ sender: Any?) {
        guard
            let table = sender as? NSTableView,
            let pane = pane(for: table),
            editability.isEditable
        else { return }
        let rows = self.rows(for: pane.target)
        guard table.clickedRow >= 0, table.clickedRow < rows.available.count else { return }
        configDocument = configDocument.insert(
            device: rows.available[table.clickedRow], target: pane.target, at: rows.priority.count
        )
        markDirty()
        refresh()
    }

    /// Removes a tier, guarding offline tiers with a confirmation. Removing
    /// an offline tier is invisible afterwards — the device cannot enter
    /// the Available list until it is reconnected — so the guard explains
    /// the consequence before deleting. Connected devices stay instant:
    /// their removal is reversible via the Available list.
    private func removeTierInteractive(at index: Int, pane: TargetPane) -> Bool {
        let rows = self.rows(for: pane.target)
        guard index >= 0, index < rows.priority.count else { return false }
        if rows.priority[index].connected.isEmpty {
            let tier = rows.priority[index].tier
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove '\(tier.displayTitle)'?"
            alert.informativeText =
                "The device for this tier is not connected right now — removing the tier deletes it from the configuration. Reconnect the device to add it again."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        configDocument = configDocument.removeTier(target: pane.target, at: index)
        markDirty()
        refresh()
        return true
    }

    @objc private func removeSelectedTier(_ sender: Any?) {
        guard
            let button = sender as? NSButton,
            let pane = pane(of: button),
            editability.isEditable
        else { return }
        let row = pane.priorityTable.selectedRow
        guard row >= 0 else { return }
        _ = removeTierInteractive(at: row, pane: pane)
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isDirty, editability.isEditable {
            let alert = NSAlert()
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "Unsaved priority changes will be lost."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                save(nil)
                return !isDirty
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if editability.isEditable {
            ConfigLock.release(configPath: configDocument.path)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh the device lists when the window is focused — the
        // approved design's "refresh on activation". Unsaved edits are
        // kept: only the devices are re-enumerated.
        refresh()
    }

    func show() {
        guard !failedToOpen else { return }
        window?.center()
        showWindow(self)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Table data source / delegate (both tables, all tabs)

extension ConfigWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let pane = pane(for: tableView) else { return 0 }
        let rows = self.rows(for: pane.target)
        return tableView == pane.availableTable ? rows.available.count : rows.priority.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let pane = pane(for: tableView) else { return nil }
        let rows = self.rows(for: pane.target)
        let cell = RowCell(
            frame: NSRect(x: 0, y: 0, width: max(tableView.bounds.width - 8, 120), height: tableView.rowHeight)
        )
        if tableView == pane.availableTable {
            guard row < rows.available.count else { return cell }
            let device = rows.available[row]
            cell.configure(
                symbol: autoSymbol(device, pane.target),
                title: device.name,
                subtitle: device.transportClass.rawValue
            )
        } else {
            guard row < rows.priority.count else { return cell }
            let tierRow = rows.priority[row]
            let subtitle =
                tierRow.connected.isEmpty
                ? "not connected"
                : tierRow.connected.map(\.name).joined(separator: ", ")
            cell.configure(
                symbol: tierRow.tier.symbol, title: tierRow.tier.displayTitle, subtitle: subtitle
            )
        }
        return cell
    }

    // MARK: Drag out (rows become pasteboard payloads)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let pane = pane(for: tableView) else { return nil }
        let rows = self.rows(for: pane.target)
        if tableView == pane.availableTable {
            guard row < rows.available.count else { return nil }
            return RowPasteboard(payload: .device(uid: rows.available[row].uid))
        }
        // Only an editable window lets priority rows leave the list.
        guard row < rows.priority.count, editability.isEditable else { return nil }
        return RowPasteboard(payload: .tier(index: row))
    }

    // MARK: Drag in (insert / reorder / remove)

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard editability.isEditable, let pane = pane(for: tableView) else { return [] }
        guard let payload = RowPayload.read(from: info.draggingPasteboard) else { return [] }
        // The available list only accepts tier rows (removal); the priority
        // list accepts devices (insert) and tiers (reorder).
        if tableView == pane.availableTable {
            guard case .tier = payload else { return [] }
        }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return [.generic]
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            editability.isEditable,
            let pane = pane(for: tableView),
            let payload = RowPayload.read(from: info.draggingPasteboard)
        else { return false }
        let rows = self.rows(for: pane.target)

        // Dragging a priority row to the available list removes the tier
        // (offline tiers confirm first — see removeTierInteractive).
        if tableView == pane.availableTable {
            guard case .tier(let index) = payload else { return false }
            return removeTierInteractive(at: index, pane: pane)
        }

        switch payload {
        case .device(let uid):
            guard let device = devices.first(where: { $0.uid == uid }) else { return false }
            configDocument = configDocument.insert(device: device, target: pane.target, at: row)
        case .tier(let source):
            guard source < rows.priority.count else { return false }
            configDocument = configDocument.moveTier(target: pane.target, from: source, to: row)
        }
        markDirty()
        refresh()
        return true
    }
}
