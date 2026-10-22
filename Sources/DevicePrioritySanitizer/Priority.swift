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

    /// A tier pattern compiled once at construction. `NSRegularExpression` is
    /// immutable and documented as safe for concurrent matching, hence the
    /// unchecked conformance.
    private struct CompiledEntry: @unchecked Sendable {
        let regex: NSRegularExpression
        let symbol: String
        let title: String?
    }

    private let outputEntries: [CompiledEntry]
    private let inputEntries: [CompiledEntry]

    /// Fails fast on invalid regexes — a tier that silently never matches
    /// would be a config trap (e.g. a forgotten escape).
    init(config: AppConfig) throws {
        outputEntries = try config.outputs.map { try Self.compile($0) }
        inputEntries = try config.inputs.map { try Self.compile($0) }
        self.config = config
    }

    private static func compile(_ entry: PriorityEntry) throws -> CompiledEntry {
        do {
            return CompiledEntry(
                regex: try NSRegularExpression(pattern: entry.match, options: []),
                symbol: entry.symbol,
                title: entry.title
            )
        } catch {
            throw InvalidRegexError(
                pattern: entry.match,
                reason: (error as NSError)
                    .userInfo[NSLocalizedDescriptionKey] as? String ?? "unparseable"
            )
        }
    }

    // MARK: - Matching

    private func entries(for direction: Direction) -> [CompiledEntry] {
        direction == .output ? outputEntries : inputEntries
    }

    private func matches(_ entry: CompiledEntry, _ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return entry.regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Devices of `direction` the app manages (synthetic transports excluded),
    /// ordered: tier order first (list order), remaining devices alphabetically.
    func orderedManagedDevices(_ direction: Direction, devices: [AudioDevice]) -> [AudioDevice] {
        let entries = entries(for: direction)
        let visible =
            devices
            .filter { $0.isDirection(direction) && $0.isManaged }

        func tier(_ device: AudioDevice) -> Int {
            entries.firstIndex(where: { matches($0, device.name) }) ?? entries.count
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
        for entry in entries(for: direction) {
            let candidates = ordered.filter { self.matches(entry, $0.name) }
            if candidates.isEmpty { continue }
            if let current = current, candidates.contains(where: { $0.uid == current.uid }) {
                return current
            }
            return candidates.first
        }
        return nil
    }

    // MARK: - Tier selection

    enum TierSelection: Equatable, Sendable {
        case unknownTier
        case noDevice
        case device(AudioDevice)
    }

    /// Tier names available for `set --tier`, in priority order.
    func tierTitles(_ direction: Direction) -> [String] {
        entries(for: direction).compactMap(\.title)
    }

    /// Best connected device in the tier named `title`, using the same rules
    /// as auto-selection: the current device is kept when it already belongs
    /// to the tier, otherwise the alphabetically first match wins.
    func tierTarget(
        _ direction: Direction,
        title: String,
        current: AudioDevice?,
        devices: [AudioDevice]
    ) -> TierSelection {
        guard let entry = entries(for: direction).first(where: { $0.title == title }) else {
            return .unknownTier
        }
        let candidates = orderedManagedDevices(direction, devices: devices)
            .filter { matches(entry, $0.name) }
        guard let first = candidates.first else { return .noDevice }
        if let current = current, candidates.contains(where: { $0.uid == current.uid }) {
            return .device(current)
        }
        return .device(first)
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
        entries(for: direction)
            .first(where: { matches($0, device.name) })?
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
