import Foundation

/// Priority selection and symbol resolution. Pure: all functions are total
/// computations over their inputs — I/O lives in the device sources and the
/// boundary.
final class PriorityEngine: Sendable {
    let config: AppConfig

    /// Symbol for a device whose current state is out of the app's domain
    /// (synthetic transports: Microsoft Teams Audio, loopback, OBS Virtual
    /// Camera, Desk View, aggregates…).
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
    private let cameraEntries: [CompiledEntry]

    /// Fails fast on invalid regexes — a tier that silently never matches
    /// would be a config trap (e.g. a forgotten escape).
    init(config: AppConfig) throws {
        outputEntries = try config.outputs.map { try Self.compile($0) }
        inputEntries = try config.inputs.map { try Self.compile($0) }
        cameraEntries = try (config.cameras ?? []).map { try Self.compile($0) }
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

    private func entries(for target: Target) -> [CompiledEntry] {
        switch target {
        case .output: return outputEntries
        case .input: return inputEntries
        case .camera: return cameraEntries
        }
    }

    private func matches(_ entry: CompiledEntry, _ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return entry.regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Devices of `target` the app manages (synthetic transports excluded),
    /// ordered: tier order first (list order), remaining devices alphabetically.
    func orderedManagedDevices(_ target: Target, devices: [MediaDevice]) -> [MediaDevice] {
        let entries = entries(for: target)
        let visible =
            devices
            .filter { $0.supports(target) && $0.isManaged }

        func tier(_ device: MediaDevice) -> Int {
            entries.firstIndex(where: { matches($0, device.name) }) ?? entries.count
        }

        return visible.sorted { a, b in
            let (tierA, tierB) = (tier(a), tier(b))
            if tierA != tierB { return tierA < tierB }
            return a.name.compare(b.name, options: .caseInsensitive) == .orderedAscending
        }
    }

    /// The device auto-selection would pick for `target`, if any.
    ///
    /// Within the winning tier, the current device is kept when it already
    /// belongs to that tier — equivalent members of a tier (several headsets)
    /// must not churn into each other on every device-list change.
    func targetDevice(
        _ target: Target,
        current: MediaDevice?,
        devices: [MediaDevice]
    ) -> MediaDevice? {
        let ordered = orderedManagedDevices(target, devices: devices)
        for entry in entries(for: target) {
            let candidates = ordered.filter { self.matches(entry, $0.name) }
            if candidates.isEmpty { continue }
            if let current = current, candidates.contains(where: { $0.uid == current.uid }) {
                return current
            }
            return candidates.first
        }
        return nil
    }

    // MARK: - Managed targets

    /// A target with no configured tiers is not auto-managed: auto-selection
    /// and `reapply` skip it entirely. The empty tier list *is* the switch —
    /// there is no separate boolean.
    func isManaged(_ target: Target) -> Bool {
        !entries(for: target).isEmpty
    }

    // MARK: - Tier selection

    enum TierSelection: Equatable, Sendable {
        case unknownTier
        case noDevice
        case device(MediaDevice)
    }

    /// Tier names available for `set --tier`, in priority order.
    func tierTitles(_ target: Target) -> [String] {
        entries(for: target).compactMap(\.title)
    }

    /// Best connected device in the tier named `title`, using the same rules
    /// as auto-selection: the current device is kept when it already belongs
    /// to the tier, otherwise the alphabetically first match wins.
    func tierTarget(
        _ target: Target,
        title: String,
        current: MediaDevice?,
        devices: [MediaDevice]
    ) -> TierSelection {
        guard let entry = entries(for: target).first(where: { $0.title == title }) else {
            return .unknownTier
        }
        let candidates = orderedManagedDevices(target, devices: devices)
            .filter { matches(entry, $0.name) }
        guard let first = candidates.first else { return .noDevice }
        if let current = current, candidates.contains(where: { $0.uid == current.uid }) {
            return .device(current)
        }
        return .device(first)
    }

    /// Next device after `current` in the visible menu order, wrapping.
    func cycleTarget(
        _ target: Target,
        current: MediaDevice?,
        devices: [MediaDevice]
    ) -> MediaDevice? {
        let ordered = orderedManagedDevices(target, devices: devices)
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
    func entrySymbol(for device: MediaDevice, target: Target) -> String {
        entries(for: target)
            .first(where: { matches($0, device.name) })?
            .symbol
            ?? config.fallback(for: target)
    }

    /// SF Symbol for the menubar slot of `target` given its current device.
    func slotSymbol(for current: MediaDevice?, target: Target) -> String {
        guard let current = current else { return config.fallback(for: target) }
        guard current.isManaged else { return Self.excludedSymbol }
        return entrySymbol(for: current, target: target)
    }
}
