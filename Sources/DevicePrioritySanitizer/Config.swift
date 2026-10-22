import Foundation

/// Config path resolution (I/O-free lookup; `--config` and the env override
/// the macOS-native default).
func defaultConfigPath() -> String {
    if let envPath = ProcessInfo.processInfo.environment["DEVICE_PRIORITY_SANITIZER_CONFIG"] {
        return envPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/device-priority-sanitizer/config.json"
}

/// One priority tier: a regex matched against device names plus the SF Symbol
/// shown for devices of this tier. The list order encodes the priority — the
/// first entry with a matching device wins (case-sensitive).
///
/// Worked example (see AGENTS.md): with tiers
///   1. `Evolve` (headset)   2. `SPEAK 510` (Jabra speaker)
/// the device `Jabra Evolve 75 SE` matches tier 1, while
/// `Jabra SPEAK 510 USB` only matches tier 2 — bare `Jabra` patterns would
/// conflate the two.
struct PriorityEntry: Codable, Equatable, Sendable {
    let match: String
    let symbol: String
    /// Human-readable tier name, used by `set --tier` and by the generated
    /// Raycast dropdown. Optional for backward compatibility with configs
    /// written before tier selection existed.
    var title: String? = nil
}

struct FallbackSymbols: Codable, Equatable, Sendable {
    let output: String
    let input: String
    /// Absent in pre-camera configs; falls back to `video`.
    var camera: String? = nil
}

struct AppConfig: Codable, Equatable, Sendable {
    var outputs: [PriorityEntry]
    var inputs: [PriorityEntry]
    /// Camera priority tiers. Absent in pre-camera configs — decodes as an
    /// empty list, which leaves the camera target unmanaged.
    var cameras: [PriorityEntry]? = nil
    var fallbackSymbol: FallbackSymbols?
    var debounceMs: Int?
    var manageSoundEffects: Bool? = nil

    var debounceInterval: TimeInterval {
        Double(debounceMs ?? 500) / 1000.0
    }

    /// Sound effects/alert device follows the default output unless disabled.
    var managesSoundEffects: Bool { manageSoundEffects ?? true }

    func entries(for target: Target) -> [PriorityEntry] {
        switch target {
        case .output: return outputs
        case .input: return inputs
        case .camera: return cameras ?? []
        }
    }

    func fallback(for target: Target) -> String {
        switch (target, fallbackSymbol) {
        case (.output, .some(let symbols)): return symbols.output
        case (.input, .some(let symbols)): return symbols.input
        case (.camera, .some(let symbols)): return symbols.camera ?? "video"
        case (.output, .none): return "speaker.wave.3"
        case (.input, .none): return "mic"
        case (.camera, .none): return "video"
        }
    }
}
