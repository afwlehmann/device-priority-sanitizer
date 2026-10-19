import Foundation

/// Priority selection and symbol resolution. Pure: all functions are total
/// computations over their inputs — I/O lives in the device sources and the
/// boundary.
final class PriorityEngine: Sendable {
    let config: AppConfig

    /// Symbol for a device whose current state is out of the app's domain
    /// (synthetic transports: Microsoft Teams Audio, loopback, aggregates…).
    static let excludedSymbol = "questionmark.circle"

    struct InvalidRegexError: Error, CustomStringConvertible, Sendable {
        let pattern: String
        let reason: String

        var description: String { "invalid regex '\(pattern)': \(reason)" }
    }

    /// Fails fast on invalid regexes — a tier that silently never matches
    /// would be a config trap (e.g. a forgotten escape).
    init(config: AppConfig) throws {
        for entry in config.outputs + config.inputs {
            do {
                _ = try NSRegularExpression(pattern: entry.match, options: [])
            } catch {
                throw InvalidRegexError(
                    pattern: entry.match,
                    reason: (error as NSError)
                        .userInfo[NSLocalizedDescriptionKey] as? String ?? "unparseable"
                )
            }
        }
        self.config = config
    }

    // MARK: - Matching

    private func matches(_ pattern: String, _ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Devices of `direction` the app manages (synthetic transports excluded),
    /// ordered: tier order first (list order), remaining devices alphabetically.
    func orderedManagedDevices(_ direction: Direction, devices: [AudioDevice]) -> [AudioDevice] {
        let entries = config.entries(for: direction)
        let visible =
            devices
            .filter { $0.isDirection(direction) && $0.isManaged }

        func tier(_ device: AudioDevice) -> Int {
            entries.firstIndex(where: { matches($0.match, device.name) }) ?? entries.count
        }

        return visible.sorted { a, b in
            let (tierA, tierB) = (tier(a), tier(b))
            if tierA != tierB { return tierA < tierB }
            return a.name.compare(b.name, options: .caseInsensitive) == .orderedAscending
        }
    }

    /// The device auto-selection would pick for `direction`, if any.
    ///
    /// Within the winning tier, the current device is kept when it already
    /// belongs to that tier — equivalent members of a tier (several headsets)
    /// must not churn into each other on every device-list change.
    func targetDevice(
        _ direction: Direction,
        current: AudioDevice?,
        devices: [AudioDevice]
    ) -> AudioDevice? {
        let ordered = orderedManagedDevices(direction, devices: devices)
        for entry in config.entries(for: direction) {
            let candidates = ordered.filter { self.matches(entry.match, $0.name) }
            if candidates.isEmpty { continue }
            if let current = current, candidates.contains(where: { $0.uid == current.uid }) {
                return current
            }
            return candidates.first
        }
        return nil
    }

    /// Next device after `current` in the visible menu order, wrapping.
    func cycleTarget(
        _ direction: Direction,
        current: AudioDevice?,
        devices: [AudioDevice]
    ) -> AudioDevice? {
        let ordered = orderedManagedDevices(direction, devices: devices)
        guard !ordered.isEmpty else { return nil }
        guard
            let current = current,
            let index = ordered.firstIndex(where: { $0.uid == current.uid })
        else {
            return ordered.first
        }
        let next = ordered.index(after: index)
        return next < ordered.count ? ordered[next] : ordered.first
    }

    // MARK: - Symbols

    /// SF Symbol for a menu item representing `device`.
    func entrySymbol(for device: AudioDevice, direction: Direction) -> String {
        config.entries(for: direction)
            .first(where: { matches($0.match, device.name) })?
            .symbol
            ?? config.fallback(for: direction)
    }

    /// SF Symbol for the menubar slot of `direction` given its current device.
    func slotSymbol(for current: AudioDevice?, direction: Direction) -> String {
        guard let current = current else { return config.fallback(for: direction) }
        guard current.isManaged else { return Self.excludedSymbol }
        return entrySymbol(for: current, direction: direction)
    }
}
