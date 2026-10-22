import Foundation

/// Runtime (non-declarative) state: the global prioritization master switch.
///
/// Deliberately NOT part of `config.json`: Home Manager owns the config as a
/// read-only store symlink, while this file must stay writable for the
/// menubar toggle and the CLI `enable`/`disable` commands. It is not
/// HM-managed and survives rebuilds. A missing file means enabled (the
/// documented default); a corrupt file is a warning, never a failure — the
/// tool must stay usable so it can be toggled or reconfigured.
struct PrioritizationState: Codable, Equatable, Sendable {
    var prioritizationEnabled: Bool
}

let defaultPrioritizationState = PrioritizationState(prioritizationEnabled: true)

/// Distributed notification posted after a state write so a running agent
/// reloads without being restarted. CLI commands pass `--state` for tests;
/// an overridden path never pokes the live agent.
let stateChangedNotificationName = Notification.Name("alex.device-priority-sanitizer.stateChanged")

func defaultStatePath() -> String {
    if let envPath = ProcessInfo.processInfo.environment["DEVICE_PRIORITY_SANITIZER_STATE"] {
        return envPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/device-priority-sanitizer/state.json"
}

// MARK: - Load (boundary; the outcome is data)

enum StateLoadOutcome: Equatable, Sendable {
    case loaded(PrioritizationState)
    case missing
    case corrupt(String)
}

/// Pure decode of the state JSON.
func decodeState(_ data: Data) -> StateLoadOutcome {
    do {
        return .loaded(try JSONDecoder().decode(PrioritizationState.self, from: data))
    } catch {
        return .corrupt("\(error)")
    }
}

func loadState(_ path: String) -> StateLoadOutcome {
    guard FileManager.default.fileExists(atPath: path) else { return .missing }
    do {
        return decodeState(try Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        return .corrupt("\(error)")
    }
}

/// Boundary convenience: load with the enabled default and a stderr warning
/// on corruption — the state must never render the tool unusable.
func resolveState(_ path: String) -> PrioritizationState {
    switch loadState(path) {
    case .loaded(let state):
        return state
    case .missing:
        return defaultPrioritizationState
    case .corrupt(let reason):
        logStderr("warning: invalid state at \(path) — treating prioritization as enabled (\(reason))")
        return defaultPrioritizationState
    }
}

// MARK: - Save (boundary; atomic, creates the directory)

func encodeState(_ state: PrioritizationState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(state)
}

func saveState(_ state: PrioritizationState, to path: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try encodeState(state).write(to: URL(fileURLWithPath: path), options: .atomic)
}
