import Foundation

/// Saved per-device volume levels — runtime state, deliberately NOT the HM
/// config (same reasoning as `State.swift`: the store must stay writable for
/// the menubar Save/Clear and the `volume` CLI). `levels.json` maps a device
/// UID to the level the device is restored to whenever it *becomes* the
/// default output/input through an app/CLI activation.
///
/// Replacement devices: a defective unit swapped for the same model gets a
/// new UID. Each entry therefore also records `name` + `modelUID`; when the
/// exact UID is not connected, a *unique* name+model match restores instead.
/// Two same-name devices with both UIDs connected never cross-apply (the
/// saved entry is only eligible as a replacement while its own UID is
/// absent), and ambiguity restores nothing.

struct SavedLevel: Codable, Equatable, Sendable {
    let uid: String
    let name: String
    let modelUID: String?
    let transport: TransportClass
    var level: Float
    let savedAt: String
}

struct LevelsDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var output: [String: SavedLevel] = [:]
    var input: [String: SavedLevel] = [:]

    static let empty = LevelsDocument()

    init(schemaVersion: Int = 1, output: [String: SavedLevel] = [:], input: [String: SavedLevel] = [:]) {
        self.schemaVersion = schemaVersion
        self.output = output
        self.input = input
    }

    /// Every key is optional on decode — hand-edited and future files must
    /// not fail because a section is absent (synthesized decoding does not
    /// honor default values for missing keys).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        output = try container.decodeIfPresent([String: SavedLevel].self, forKey: .output) ?? [:]
        input = try container.decodeIfPresent([String: SavedLevel].self, forKey: .input) ?? [:]
    }

    func entries(for target: Target) -> [String: SavedLevel] {
        switch target {
        case .output: return output
        case .input: return input
        case .camera: return [:]
        }
    }

    mutating func upsert(_ entry: SavedLevel, for target: Target) {
        switch target {
        case .output: output[entry.uid] = entry
        case .input: input[entry.uid] = entry
        case .camera: break
        }
    }

    mutating func remove(uid: String, for target: Target) {
        switch target {
        case .output: output.removeValue(forKey: uid)
        case .input: input.removeValue(forKey: uid)
        case .camera: break
        }
    }
}

func defaultLevelsPath() -> String {
    if let envPath = ProcessInfo.processInfo.environment["DEVICE_PRIORITY_SANITIZER_LEVELS"] {
        return envPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/device-priority-sanitizer/levels.json"
}

/// Distributed notification posted after a CLI levels write on the default
/// path (never for an overridden `--levels`), so a running agent refreshes
/// its menu — same contract as `stateChanged`.
let levelsChangedNotificationName = Notification.Name("alex.device-priority-sanitizer.levelsChanged")

func currentTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

// MARK: - Load/save (atomic; corrupt or missing degrades to empty)

func loadLevelsDocument(_ path: String) -> LevelsDocument {
    guard FileManager.default.fileExists(atPath: path) else { return .empty }
    do {
        return try JSONDecoder().decode(LevelsDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        logStderr("warning: invalid saved levels at \(path) — treating as empty (\(error))")
        return .empty
    }
}

func saveLevelsDocument(_ document: LevelsDocument, to path: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(document).write(to: URL(fileURLWithPath: path), options: .atomic)
}

// MARK: - Lookup (pure)

enum LevelMatch: Equatable, Sendable {
    case none
    case exact(SavedLevel)
    /// Same name + model UID; the saved unit is no longer connected.
    case replacement(SavedLevel)

    var entry: SavedLevel? {
        switch self {
        case .none: return nil
        case .exact(let entry), .replacement(let entry): return entry
        }
    }
}

/// Exact UID first; otherwise — only for entries whose own UID is not
/// currently connected — a *unique* entry with the same name and (when both
/// sides know one) the same model UID. Ambiguity restores nothing.
func savedLevel(
    for device: MediaDevice,
    target: Target,
    document: LevelsDocument,
    connectedUIDs: Set<String>
) -> LevelMatch {
    guard target != .camera else { return .none }
    if let entry = document.entries(for: target)[device.uid] {
        return .exact(entry)
    }
    let candidates = document.entries(for: target).values.filter { entry in
        guard !connectedUIDs.contains(entry.uid) else { return false }
        guard entry.name == device.name else { return false }
        switch (entry.modelUID, device.modelUID) {
        case (.some(let saved), .some(let current)): return saved == current
        case (.none, .none): return true
        default: return false
        }
    }
    guard candidates.count == 1, let only = candidates.first else { return .none }
    return .replacement(only)
}

// MARK: - Restore (effect helper; failures are data)

enum LevelRestoreOutcome: Equatable, Sendable {
    case restored(level: Float, replacement: Bool)
    case noEntry
    case unsupported
    case failed(OSStatus)
}

/// Restores a device's saved level. `perform: false` reports what *would*
/// happen (dry-run) without writing. Volume writes have a real error channel
/// (unlike the camera preference setter), so the OSStatus decides — no
/// read-back verification is layered on top.
func restoreSavedLevel(
    device: MediaDevice,
    target: Target,
    source: DeviceSource,
    document: LevelsDocument,
    connectedUIDs: Set<String>,
    perform: Bool
) -> LevelRestoreOutcome {
    let match = savedLevel(
        for: device, target: target, document: document, connectedUIDs: connectedUIDs
    )
    guard let entry = match.entry else { return .noEntry }
    guard source.volume(for: device, target: target) != nil else { return .unsupported }
    let replacement: Bool
    if case .replacement = match {
        replacement = true
    } else {
        replacement = false
    }
    guard perform else { return .restored(level: entry.level, replacement: replacement) }
    let status = source.setVolume(entry.level, for: device, target: target)
    guard status == noErr else { return .failed(status) }
    return .restored(level: entry.level, replacement: replacement)
}

func levelPercent(_ level: Float) -> Int {
    Int((min(max(level, 0), 1) * 100).rounded())
}
