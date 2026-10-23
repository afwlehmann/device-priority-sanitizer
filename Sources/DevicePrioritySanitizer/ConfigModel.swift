import Foundation

// MARK: - Config document (raw JSON, preserving unknown data)
//
// The UI edits the config as a raw JSON document, not a typed AppConfig: the
// pure-core contract is "preserve unknown top-level keys and unknown fields
// on existing entries" — a decode/re-encode cycle through a typed struct
// would silently drop anything the schema does not model. Tier rows are only
// ever reordered, removed, or appended, so retained tiers keep their raw
// dictionaries untouched.

/// One tier as the raw document sees it: the JSON dictionary plus the typed
/// view of the fields the UI needs.
struct RawTier: @unchecked Sendable {
    let raw: [String: Any]
    let match: String
    let symbol: String
    let title: String?

    init(raw: [String: Any], match: String, symbol: String, title: String?) {
        self.raw = raw
        self.match = match
        self.symbol = symbol
        self.title = title
    }

    init?(dict: [String: Any]) {
        guard
            let match = dict["match"] as? String,
            let symbol = dict["symbol"] as? String
        else { return nil }
        self.init(raw: dict, match: match, symbol: symbol, title: dict["title"] as? String)
    }

    static func new(title: String, match: String, symbol: String) -> RawTier {
        RawTier(
            raw: ["match": match, "symbol": symbol, "title": title],
            match: match,
            symbol: symbol,
            title: title
        )
    }

    /// Display title: the tier title when present, otherwise the raw pattern
    /// (so an unnamed regex tier is still identifiable in the list).
    var displayTitle: String { title ?? match }
}

enum ConfigDocumentError: Error, CustomStringConvertible, Sendable {
    case unreadable(String)
    case invalidJSON(String)
    case invalidRegex(pattern: String, reason: String)

    var description: String {
        switch self {
        case .unreadable(let path): return "cannot read config at \(path)"
        case .invalidJSON(let reason): return "invalid JSON: \(reason)"
        case .invalidRegex(let pattern, let reason): return "invalid regex '\(pattern)': \(reason)"
        }
    }
}

struct ConfigDocument: @unchecked Sendable {
    let path: String
    private var raw: [String: Any]

    init(path: String, raw: [String: Any]) {
        self.path = path
        self.raw = raw
    }

    /// Loads and validates a raw JSON document. Validation is limited to
    /// JSON object shape and tier regex compilability — everything else
    /// passes through untouched.
    static func load(_ path: String) throws -> ConfigDocument {
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigDocument(path: path, raw: [:])
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigDocumentError.unreadable(path)
        }
        let raw: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigDocumentError.invalidJSON("root is not a JSON object")
            }
            raw = object
        } catch let error as ConfigDocumentError {
            throw error
        } catch {
            throw ConfigDocumentError.invalidJSON("\(error)")
        }
        let document = ConfigDocument(path: path, raw: raw)
        try document.validateRegexes()
        return document
    }

    /// An empty document — the "start with empty" recovery path for a
    /// config that failed validation. Saving overwrites the broken file
    /// (after the caller made its backup).
    static func empty(path: String) -> ConfigDocument {
        ConfigDocument(path: path, raw: [:])
    }

    private func validateRegexes() throws {
        for key in ["outputs", "inputs", "cameras"] {
            for tier in tiers(key) {
                do {
                    _ = try NSRegularExpression(pattern: tier.match, options: [])
                } catch {
                    let reason =
                        (error as NSError)
                        .userInfo[NSLocalizedDescriptionKey] as? String ?? "unparseable"
                    throw ConfigDocumentError.invalidRegex(pattern: tier.match, reason: reason)
                }
            }
        }
    }

    private var tierKey: [Target: String] {
        [.output: "outputs", .input: "inputs", .camera: "cameras"]
    }

    private func tiers(_ key: String) -> [RawTier] {
        ((raw[key] as? [[String: Any]]) ?? []).compactMap(RawTier.init(dict:))
    }

    private mutating func setTiers(_ key: String, _ tiers: [RawTier]) {
        raw[key] = tiers.map(\.raw)
    }

    func tiers(for target: Target) -> [RawTier] {
        tiers(tierKey[target]!)
    }

    private mutating func setTiers(for target: Target, _ tiers: [RawTier]) {
        setTiers(tierKey[target]!, tiers)
    }

    // MARK: - Row model (pure)

    /// One row of the priority list: a tier plus the connected devices it
    /// matches. Multi-device tiers render grouped; a tier matching nothing
    /// still shows (as "not connected").
    struct TierRow: Sendable {
        let tier: RawTier
        let connected: [MediaDevice]
    }

    struct TargetRows: Sendable {
        let target: Target
        let priority: [TierRow]
        /// Managed, uncovered devices, lexicographic; identical names
        /// collapse into one row (the engine cannot distinguish them and a
        /// name tier matches both anyway).
        let available: [MediaDevice]
        var isManaged: Bool { !priority.isEmpty }
    }

    /// Devices covered by any tier pattern (case-sensitive, like the engine).
    func isCovered(_ device: MediaDevice, tiers: [RawTier]) -> Bool {
        tiers.contains { tier in
            guard let regex = try? NSRegularExpression(pattern: tier.match, options: []) else { return false }
            return regex.firstMatch(
                in: device.name, options: [], range: NSRange(device.name.startIndex..., in: device.name)
            ) != nil
        }
    }

    func rows(for target: Target, devices: [MediaDevice]) -> TargetRows {
        let tiers = tiers(for: target)
        let ordered = orderedManagedDevices(target, devices)
        let priority = tiers.map { tier in
            TierRow(tier: tier, connected: ordered.filter { isCovered($0, tiers: [tier]) })
        }
        let coveredUIDs = Set(ordered.filter { isCovered($0, tiers: tiers) }.map(\.uid))
        var seen = Set<String>()
        let available =
            ordered
            .filter { device in
                !coveredUIDs.contains(device.uid) && seen.insert(device.name).inserted
            }
        return TargetRows(target: target, priority: priority, available: available)
    }

    /// Managed devices of `target`, lexicographic (the same order the
    /// available list shows; the priority list is tier-ordered instead).
    private func orderedManagedDevices(_ target: Target, _ devices: [MediaDevice]) -> [MediaDevice] {
        devices
            .filter { $0.supports(target) && $0.isManaged }
            .sorted { $0.name.compare($1.name, options: .caseInsensitive) == .orderedAscending }
    }

    // MARK: - Mutations (pure; return an updated document)

    /// Inserts a new exact-match tier for the device at `index` (the priority
    /// drop position). The title is deduplicated; the pattern is anchored so
    /// it matches the device name (and its same-named twins) exactly.
    func insert(device: MediaDevice, target: Target, at index: Int) -> ConfigDocument {
        var document = self
        var tiers = document.tiers(for: target)
        let title = uniqueTitle(device.name, existing: tiers.map(\.displayTitle))
        tiers.insert(
            RawTier.new(title: title, match: exactPattern(device.name), symbol: autoSymbol(device, target)),
            at: min(max(index, 0), tiers.count)
        )
        document.setTiers(for: target, tiers)
        return document
    }

    func removeTier(target: Target, at index: Int) -> ConfigDocument {
        var document = self
        var tiers = document.tiers(for: target)
        guard index < tiers.count else { return document }
        tiers.remove(at: index)
        document.setTiers(for: target, tiers)
        return document
    }

    func moveTier(target: Target, from source: Int, to destination: Int) -> ConfigDocument {
        var document = self
        var tiers = document.tiers(for: target)
        guard source < tiers.count else { return document }
        let tier = tiers.remove(at: source)
        let index = source < destination ? destination - 1 : destination
        tiers.insert(tier, at: min(max(index, 0), tiers.count))
        document.setTiers(for: target, tiers)
        return document
    }

    // MARK: - Save (boundary; caller handles backups/locking)

    func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            + Data("\n".utf8)
    }

    /// Atomic write; the caller (window controller) owns backup/lock policy.
    func save() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// A timestamped backup next to the config — the safety net before the
    /// "start with empty" recovery overwrites a broken file.
    @discardableResult
    func backup() throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = "\(path).invalid-\(formatter.string(from: Date()))"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.copyItem(atPath: path, toPath: backupPath)
        }
        return backupPath
    }

    // MARK: - Derived config (for applying after save)

    /// The typed config the engine needs — only used after a successful
    /// save, when the document is known valid.
    func appConfig() throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: try encoded())
    }

    /// True when the file (or its resolved target) is not writable —
    /// Home Manager's store symlink opens read-only.
    var isReadOnly: Bool {
        if (path as NSString).resolvingSymlinksInPath.hasPrefix("/nix/store/") { return true }
        if !FileManager.default.fileExists(atPath: path) {
            // A missing file is writable when its directory is.
            return !FileManager.default.isWritableFile(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        return !FileManager.default.isWritableFile(atPath: path)
    }
}

// MARK: - Pure helpers

/// `^` + regex-escaped name + `$`: the exact-match tier the UI creates when a
/// device is dragged into the priority list. Anchored so a name that happens
/// to contain another device's name does not capture it.
func exactPattern(_ name: String) -> String {
    "^" + NSRegularExpression.escapedPattern(for: name) + "$"
}

/// Tier titles must stay unique (`set --tier`, Raycast dropdown): append
/// ` (2)`, ` (3)`, … until the title is free.
func uniqueTitle(_ name: String, existing: [String]) -> String {
    guard existing.contains(name) else { return name }
    var index = 2
    while existing.contains("\(name) (\(index))") {
        index += 1
    }
    return "\(name) (\(index))"
}

/// The auto-assigned tier symbol for a newly added device, derived from its
/// transport (v1 has no symbol picker; symbols stay editable in the JSON).
func autoSymbol(_ device: MediaDevice, _ target: Target) -> String {
    switch target {
    case .output:
        switch device.transportClass {
        case .bluetooth: return "headphones"
        case .builtIn: return "laptopcomputer"
        case .displayPort, .thunderbolt: return "display"
        case .usb: return "hifispeaker.fill"
        default: return "speaker.wave.3"
        }
    case .input:
        switch device.transportClass {
        case .bluetooth: return "headphones"
        case .builtIn: return "laptopcomputer"
        default: return "mic"
        }
    case .camera:
        switch device.transportClass {
        case .continuity: return "iphone"
        case .builtIn: return "laptopcomputer"
        default: return "video"
        }
    }
}
