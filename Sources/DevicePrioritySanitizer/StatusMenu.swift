import AppKit
import Foundation

final class ActionPayload: NSObject {
    enum Kind {
        case select(Target, MediaDevice)
        case cycle(Target)
        case reapply
        case togglePrioritization
        case settings
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
/// Prioritization item (the master toggle) and greys out Reapply while
/// disabled; manual device picks and Cycle remain available.
final class MenuController: NSObject {
    private let engine: PriorityEngine
    private let source: DeviceSource
    private let statusItem: NSStatusItem

    var onSelect: ((Target, MediaDevice) -> Void)?
    var onCycle: ((Target) -> Void)?
    var onReapply: (() -> Void)?
    var onTogglePrioritization: (() -> Void)?

    init(engine: PriorityEngine, source: DeviceSource) {
        self.engine = engine
        self.source = source
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func update(devices: [MediaDevice], prioritizationEnabled: Bool) {
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
        statusItem.menu = buildMenu(devices: devices, prioritizationEnabled: prioritizationEnabled)
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

    private func buildMenu(devices: [MediaDevice], prioritizationEnabled: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let toggle = NSMenuItem(
            title: "Prioritization",
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = prioritizationEnabled ? .on : .off
        toggle.representedObject = ActionPayload(.togglePrioritization)
        menu.addItem(toggle)
        menu.addItem(.separator())
        Target.allCases
            .map { addTargetSubmenu($0, to: menu, devices: devices) }
            .forEach { menu.addItem($0) }
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
        menu.addItem(makeSubmenu("Open Sound Settings", payload: .settings))
        return menu
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
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
