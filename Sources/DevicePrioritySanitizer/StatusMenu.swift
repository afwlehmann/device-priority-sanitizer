import AppKit
import Foundation

final class ActionPayload: NSObject {
    enum Kind {
        case select(Target, MediaDevice)
        case cycle(Target)
        case reapply
        case togglePrioritization
        case configure
        case settings
        case quit
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// Owns the `NSStatusItem`: the three-symbol menubar image and the dropdown.
///
/// Menubar: [speaker slot][microphone slot][camera slot], each an SF Symbol
/// for the category of the current device of that target; a synthetic
/// (excluded) current device renders the dedicated "not managed" glyph. A
/// globally disabled switch appends `pause.circle` — the app leaves
/// everything alone, but says so. The dropdown leads with a checkable
/// Enabled item (the master toggle), a Configure Devices… entry, and
/// greys out Reapply while disabled; between the device submenus and the
/// Cycle items sit the per-device volume rows (slider + Save/Clear, see
/// `LevelRowView`); it ends with a Quit item. Manual device picks and Cycle
/// remain available. `update(engine:source:)` swaps the engine/source after
/// a configuration save without recreating the status item. The dropdown is
/// rebuilt on every refresh *and* on open (`menuNeedsUpdate`), so sliders
/// and saved-state markers always render fresh values.
final class MenuController: NSObject {
    private var engine: PriorityEngine
    private var source: DeviceSource
    private let statusItem: NSStatusItem
    private let dropdown = NSMenu()
    private var devicesSnapshot: [MediaDevice] = []
    private var prioritizationEnabledSnapshot = true

    /// Targets that carry a volume row, in dropdown order ("same order as
    /// the items above": output first, then input).
    private static let levelTargets: [Target] = [.output, .input]

    var onSelect: ((Target, MediaDevice) -> Void)?
    var onCycle: ((Target) -> Void)?
    var onReapply: (() -> Void)?
    var onTogglePrioritization: (() -> Void)?
    var onConfigure: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSetVolume: ((Target, Float) -> Void)?
    /// Saves the current device's level; returns the saved value, `nil` on failure.
    var onSaveLevel: ((Target) -> Float?)?
    /// Removes the entry applying to the current device; returns whether one existed.
    var onClearLevel: ((Target) -> Bool)?
    /// Fresh row snapshot for one audio target (policy lives in the delegate owner).
    var onLevelState: ((Target) -> LevelRowState)?

    init(engine: PriorityEngine, source: DeviceSource) {
        self.engine = engine
        self.source = source
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        dropdown.autoenablesItems = false
        dropdown.delegate = self
        statusItem.menu = dropdown
    }

    /// Hot-swaps the engine and source after a configuration save/reload —
    /// the status item (and its menu) stay alive.
    func update(engine: PriorityEngine, source: DeviceSource) {
        self.engine = engine
        self.source = source
    }

    func update(devices: [MediaDevice], prioritizationEnabled: Bool) {
        devicesSnapshot = devices
        prioritizationEnabledSnapshot = prioritizationEnabled
        let currents = Target.allCases.map { ($0, source.defaultDevice(for: $0)) }
        var symbols = currents.map { target, current in
            (symbol: engine.slotSymbol(for: current, target: target), description: target.menuTitle)
        }
        if !prioritizationEnabled {
            symbols.append((symbol: "pause.circle", description: "Prioritization"))
        }

        if let image = Self.statusImage(symbols: symbols) {
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip =
            currents
            .map { "\($0.0.menuTitle): \($0.1?.name ?? "none")" }
            .joined(separator: " · ")
            + (prioritizationEnabled ? "" : " · Prioritization disabled")
        rebuild()
    }

    private func rebuild() {
        populate(dropdown)
    }

    // MARK: - Status image

    static func statusImage(symbols: [(symbol: String, description: String)]) -> NSImage? {
        let images = symbols.compactMap { symbol, description in
            NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        }
        guard images.count == symbols.count, !images.isEmpty else { return nil }
        let gap: CGFloat = 3
        let width = images.reduce(0) { $0 + $1.size.width } + gap * CGFloat(images.count - 1)
        let height = images.map(\.size.height).max() ?? 0
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        var x: CGFloat = 0
        for symbol in images {
            symbol.draw(
                in: NSRect(
                    x: x,
                    y: (height - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            x += symbol.size.width + gap
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func populate(_ menu: NSMenu) {
        let prioritizationEnabled = prioritizationEnabledSnapshot
        menu.removeAllItems()
        let toggle = NSMenuItem(
            title: "Enabled",
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = prioritizationEnabled ? .on : .off
        toggle.representedObject = ActionPayload(.togglePrioritization)
        menu.addItem(toggle)
        menu.addItem(.separator())
        Target.allCases
            .map { addTargetSubmenu($0, to: menu, devices: devicesSnapshot) }
            .forEach { menu.addItem($0) }
        menu.addItem(.separator())
        for target in Self.levelTargets {
            let state =
                onLevelState?(target) ?? LevelRowState(deviceName: nil, liveLevel: nil, savedLevel: nil)
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.view = LevelRowView(target: target, state: state, menuController: self)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        Target.allCases.forEach { target in
            menu.addItem(makeSubmenu("Cycle \(target.menuTitle)", payload: .cycle(target)))
        }
        menu.addItem(.separator())
        let reapply = makeSubmenu("Reapply Priority", payload: .reapply)
        // Reapply is a prioritization action: while the master switch is
        // off it is greyed out instead of silently no-opping.
        reapply.isEnabled = prioritizationEnabled
        menu.addItem(reapply)
        menu.addItem(makeSubmenu("Configure Devices…", payload: .configure))
        menu.addItem(makeSubmenu("Open Sound Settings", payload: .settings))
        menu.addItem(.separator())
        menu.addItem(makeSubmenu("Quit", payload: .quit))
    }

    private func addTargetSubmenu(
        _ target: Target,
        to menu: NSMenu,
        devices: [MediaDevice]
    ) -> NSMenuItem {
        let title = target.menuTitle
        let submenu = NSMenu(title: title)
        let current = source.defaultDevice(for: target)

        // A target with no priority tiers is not auto-managed: the empty
        // tier list is the switch — say so in the submenu.
        if !engine.isManaged(target) {
            let item = NSMenuItem(
                title: "Not auto-managed (no priority tiers)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            submenu.addItem(item)
            submenu.addItem(.separator())
        }

        // Out-of-domain current device: the app deliberately does not touch
        // it — say so instead of silently hiding it.
        let managedDevices = engine.orderedManagedDevices(target, devices: devices)
        let infoItem: NSMenuItem? = current.flatMap { currentDevice in
            guard !currentDevice.isManaged else { return nil }
            let item = NSMenuItem(
                title: "Current: \(currentDevice.name) (not managed)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return item
        }
        if let item = infoItem {
            submenu.addItem(item)
            submenu.addItem(.separator())
        }

        managedDevices
            .map { device in makeDeviceItem(device, target: target, current: current) }
            .forEach { submenu.addItem($0) }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func makeDeviceItem(
        _ device: MediaDevice,
        target: Target,
        current currentDevice: MediaDevice?
    ) -> NSMenuItem {
        let line = NSMenuItem(
            title: device.name,
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        line.target = self
        let symbol = engine.entrySymbol(for: device, target: target)
        line.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        line.state = currentDevice?.uid == device.uid ? .on : .off
        line.representedObject = ActionPayload(.select(target, device))
        return line
    }

    private func makeSubmenu(_ title: String, payload: ActionPayload.Kind) -> NSMenuItem {
        let line = NSMenuItem(
            title: title,
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        line.target = self
        line.representedObject = ActionPayload(payload)
        return line
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ActionPayload else { return }
        switch payload.kind {
        case .select(let target, let device):
            onSelect?(target, device)
        case .cycle(let target):
            onCycle?(target)
        case .reapply:
            onReapply?()
        case .togglePrioritization:
            onTogglePrioritization?()
        case .configure:
            onConfigure?()
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .quit:
            onQuit?()
        }
    }
}

// MARK: - Menu refresh on open

extension MenuController: NSMenuDelegate {
    /// Rebuilds on every open, so the volume sliders read the *current*
    /// levels instead of whatever was true at the last refresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }
}

// MARK: - Per-device volume rows

/// One audio target's row snapshot — all policy (current device, saved-level
/// lookup) lives with the owner of the `on*` callbacks; the row renders.
struct LevelRowState: Equatable, Sendable {
    /// `nil` → "no device".
    var deviceName: String?
    /// The device's live level; `nil` → it has no volume control.
    var liveLevel: Float?
    /// The stored level applying to this device (exact or replacement match);
    /// `nil` → "do not restore" and Clear dimmed.
    var savedLevel: Float?
}

/// Pure x↔value mapping for `LevelSliderControl`, kept as free functions so
/// the geometry is unit-testable. The knob center travels between
/// `knobRadius` and `width - knobRadius`, so the knob never clips the track.
func sliderKnobX(for value: Float, width: CGFloat, knobRadius: CGFloat) -> CGFloat {
    let usable = width - knobRadius * 2
    guard usable > 0 else { return knobRadius }
    let clamped = CGFloat(min(max(value, 0), 1))
    return knobRadius + clamped * usable
}

func sliderValue(forX x: CGFloat, width: CGFloat, knobRadius: CGFloat) -> Float {
    let usable = width - knobRadius * 2
    guard usable > 0 else { return 0 }
    return Float(min(max((x - knobRadius) / usable, 0), 1))
}

/// Custom-drawn volume slider. `NSSliderCell` insets its bar by the knob
/// thickness — metrics that varied between rows and visibly misaligned the
/// two tracks. This control draws everything itself (track, filled portion,
/// saved-level tick, knob) from its own bounds, so every row shares the same
/// geometry and the track starts exactly at the row's leading edge.
final class LevelSliderControl: NSControl {
    /// Live 0…1 level.
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }
    /// Stored level rendered as an accent tick; `nil` → no tick.
    var savedLevel: Float? {
        didSet { needsDisplay = true }
    }

    private let knobRadius: CGFloat = 5
    private let trackHeight: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LevelSliderControl is built programmatically")
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let knobX = sliderKnobX(for: level, width: bounds.width, knobRadius: knobRadius)
        let track = NSRect(x: 0, y: midY - trackHeight / 2, width: bounds.width, height: trackHeight)

        // Track and the filled portion up to the knob.
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        let fill = NSRect(x: 0, y: track.minY, width: knobX, height: trackHeight)
        if fill.width > 0 {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        }

        // Stored-level tick: a small accent bar spanning the track.
        if let savedLevel {
            let x = sliderKnobX(for: savedLevel, width: bounds.width, knobRadius: knobRadius)
            let tick = NSRect(x: x - 1, y: midY - 7, width: 2, height: 14)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1).fill()
        }

        // Knob.
        let knob = NSRect(x: knobX - knobRadius, y: midY - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        (isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        updateLevel(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateLevel(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateLevel(with: event)
    }

    private func updateLevel(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        level = sliderValue(forX: point.x, width: bounds.width, knobRadius: knobRadius)
        setAccessibilityValue(NSNumber(value: Double(level)))
        sendAction(action, to: target)
    }
}

/// The two-line dropdown row for one audio target:
///
/// ```
/// Jabra Evolve 75 SE                    restore     ← device + state label
/// [────────────────●─────────────]   Save   Clear   ← live slider + actions
/// ```
///
/// Line 1 identifies the *device* the controls act on (the current default),
/// line 2 holds the live slider (drag = set the device volume, never
/// persisted) and the Save/Clear pair. The state label spans exactly the two
/// buttons, left-aligned; both label and buttons use the small system font.
/// Button clicks update their own state in place — no menu rebuild while
/// the menu is open.
final class LevelRowView: NSView {
    private let target: Target
    private weak var menuController: MenuController?
    private let deviceLabel: NSTextField
    private let restoreLabel: NSTextField
    private let slider: LevelSliderControl
    private let saveButton: NSButton
    private let clearButton: NSButton

    private static let rowWidth: CGFloat = 320
    private static let rowHeight: CGFloat = 44
    private static let saveWidth: CGFloat = 48
    private static let clearWidth: CGFloat = 56
    private static let buttonGap: CGFloat = 6
    /// Exactly spans Save + gap + Clear; the state label shares this width.
    private static let rightColumnWidth: CGFloat = saveWidth + buttonGap + clearWidth
    /// The standard `NSMenu` item text gutter: regular items draw their
    /// titles at this offset from the leading edge of a custom item view —
    /// AppKit does NOT apply it to `NSMenuItem.view` content, so the row
    /// must pad by it to line up with the other menu items. No public API
    /// exposes the value; it is a measured constant, adjusted in this one
    /// place if a macOS release changes the gutter.
    private static let textInset: CGFloat = 16

    init(target: Target, state: LevelRowState, menuController: MenuController) {
        self.target = target
        self.menuController = menuController

        deviceLabel = NSTextField(labelWithString: "")
        deviceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        deviceLabel.lineBreakMode = .byTruncatingTail

        restoreLabel = NSTextField(labelWithString: "")
        restoreLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        restoreLabel.lineBreakMode = .byTruncatingTail

        slider = LevelSliderControl(frame: .zero)
        slider.setAccessibilityLabel("\(target.menuTitle) volume")

        saveButton = Self.smallButton(title: "Save", action: #selector(saveClicked), frame: .zero)
        saveButton.setAccessibilityLabel("Save \(target.menuTitle) level")
        clearButton = Self.smallButton(title: "Clear", action: #selector(clearClicked), frame: .zero)
        clearButton.setAccessibilityLabel("Clear saved \(target.menuTitle) level")

        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        // Targets reference self — only assignable after super.init.
        slider.target = self
        slider.action = #selector(sliderMoved)
        saveButton.target = self
        clearButton.target = self
        [deviceLabel, restoreLabel, slider, saveButton, clearButton].forEach { addSubview($0) }
        layoutFrames()
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LevelRowView is built programmatically")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutFrames()
    }

    /// One geometry pass shared by both rows: the right column (state label
    /// over Save/Clear) is pinned to the trailing edge, the left column
    /// (device name over the slider) fills the remainder. Recomputed on
    /// resize so a wider menu can never break the alignment.
    private func layoutFrames() {
        let leftX = Self.textInset
        let rightX = bounds.width - Self.rightColumnWidth - 4
        let leftWidth = rightX - leftX - 2
        deviceLabel.frame = NSRect(x: leftX, y: 26, width: leftWidth, height: 14)
        restoreLabel.frame = NSRect(x: rightX, y: 26, width: Self.rightColumnWidth, height: 14)
        slider.frame = NSRect(x: leftX, y: 0, width: leftWidth, height: 20)
        saveButton.frame = NSRect(x: rightX, y: 0, width: Self.saveWidth, height: 20)
        clearButton.frame = NSRect(
            x: rightX + Self.saveWidth + Self.buttonGap, y: 0, width: Self.clearWidth, height: 20)
    }

    private static func smallButton(title: String, action: Selector, frame: NSRect) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.frame = frame
        return button
    }
    func apply(_ state: LevelRowState) {
        deviceLabel.stringValue = state.deviceName ?? "no device"
        deviceLabel.toolTip = state.deviceName
        let hasVolume = state.deviceName != nil && state.liveLevel != nil
        slider.isEnabled = hasVolume
        slider.level = state.liveLevel ?? 0
        slider.savedLevel = state.savedLevel
        saveButton.isEnabled = hasVolume
        applySavedLevel(state.savedLevel)
    }

    private func applySavedLevel(_ level: Float?) {
        restoreLabel.stringValue = level == nil ? "do not restore" : "restore"
        clearButton.isEnabled = level != nil
        slider.savedLevel = level
    }

    @objc private func sliderMoved() {
        menuController?.onSetVolume?(target, slider.level)
    }

    @objc private func saveClicked() {
        guard let level = menuController?.onSaveLevel?(target) else { return }
        applySavedLevel(level)
    }

    @objc private func clearClicked() {
        guard let removed = menuController?.onClearLevel?(target), removed else { return }
        applySavedLevel(nil)
    }
}
