import AppKit
import Foundation

final class ActionPayload: NSObject {
    enum Kind {
        case select(Direction, AudioDevice)
        case cycle(Direction)
        case reapply
        case settings
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// Owns the `NSStatusItem`: the two-symbol menubar image and the dropdown.
///
/// Menubar: [speaker slot][microphone slot], each an SF Symbol for the
/// category of the current device of that direction. A synthetic (excluded)
/// current device renders the dedicated "not managed" glyph — the app leaves
/// it alone, but says so.
final class MenuController: NSObject {
    private let engine: PriorityEngine
    private let source: DeviceSource
    private let statusItem: NSStatusItem

    var onSelect: ((Direction, AudioDevice) -> Void)?
    var onCycle: ((Direction) -> Void)?
    var onReapply: (() -> Void)?

    init(engine: PriorityEngine, source: DeviceSource) {
        self.engine = engine
        self.source = source
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func update(devices: [AudioDevice]) {
        let outDevice = source.defaultDevice(for: .output)
        let inDevice = source.defaultDevice(for: .input)
        let outSymbol = engine.slotSymbol(for: outDevice, direction: .output)
        let inSymbol = engine.slotSymbol(for: inDevice, direction: .input)

        if let image = Self.statusImage(outSymbol: outSymbol, inSymbol: inSymbol) {
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip =
            "Speaker: \(outDevice?.name ?? "none") · Microphone: \(inDevice?.name ?? "none")"
        statusItem.menu = buildMenu(devices: devices)
    }

    // MARK: - Status image

    static func statusImage(outSymbol: String, inSymbol: String) -> NSImage? {
        guard
            let speaker = NSImage(systemSymbolName: outSymbol, accessibilityDescription: "Speaker"),
            let microphone = NSImage(systemSymbolName: inSymbol, accessibilityDescription: "Microphone")
        else { return nil }
        let gap: CGFloat = 3
        let width = speaker.size.width + gap + microphone.size.width
        let height = max(speaker.size.height, microphone.size.height)
        let image = NSImage(size: NSSize(width: width, height: height))
        let microphoneRect = NSRect(
            x: speaker.size.width + gap,
            y: (height - microphone.size.height) / 2,
            width: microphone.size.width,
            height: microphone.size.height
        )
        image.lockFocus()
        speaker.draw(
            in: NSRect(
                x: 0,
                y: (height - speaker.size.height) / 2,
                width: speaker.size.width,
                height: speaker.size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        microphone.draw(
            in: microphoneRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func buildMenu(devices: [AudioDevice]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        [Direction.output, Direction.input]
            .map { addDirectionSubmenu($0, to: menu, devices: devices) }
            .forEach { menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(makeSubmenu("Cycle Speaker", payload: .cycle(.output)))
        menu.addItem(makeSubmenu("Cycle Microphone", payload: .cycle(.input)))
        menu.addItem(.separator())
        menu.addItem(makeSubmenu("Reapply Priority", payload: .reapply))
        menu.addItem(makeSubmenu("Open Sound Settings", payload: .settings))
        return menu
    }

    private func submenuTitle(_ direction: Direction) -> String {
        direction == .output ? "Speaker" : "Microphone"
    }

    private func addDirectionSubmenu(
        _ direction: Direction,
        to menu: NSMenu,
        devices: [AudioDevice]
    ) -> NSMenuItem {
        let title = submenuTitle(direction)
        let submenu = NSMenu(title: title)
        let current = source.defaultDevice(for: direction)

        // Out-of-domain current device: the app deliberately does not touch
        // it — say so instead of silently hiding it.
        let managedDevices = engine.orderedManagedDevices(direction, devices: devices)
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
            .map { device in makeDeviceItem(device, direction: direction, current: current) }
            .forEach { submenu.addItem($0) }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func makeDeviceItem(
        _ device: AudioDevice,
        direction: Direction,
        current currentDevice: AudioDevice?
    ) -> NSMenuItem {
        let line = NSMenuItem(
            title: device.name,
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        line.target = self
        let symbol = engine.entrySymbol(for: device, direction: direction)
        line.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        line.state = currentDevice?.uid == device.uid ? .on : .off
        line.representedObject = ActionPayload(.select(direction, device))
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
        case .select(let direction, let device):
            onSelect?(direction, device)
        case .cycle(let direction):
            onCycle?(direction)
        case .reapply:
            onReapply?()
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
