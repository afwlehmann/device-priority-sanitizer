# audio-priority-sanitizer

Native macOS menubar app + CLI that keeps the default speaker and microphone
on the highest-priority device available. Pure Swift (AppKit + CoreAudio),
built with the nixpkgs Swift toolchain via plain `swiftc`.

## Architecture

```
┌──────────────────────────────┐
│ Sources/AudioPrioritySanitizer │
│                              │
│ Config.swift    config types │
│ AudioDevice.swift CoreAudio  │
│                 I/O + fixtures│
│ Priority.swift  pure engine  │
│ Command.swift   CLI commands │
│ StatusMenu.swift NSStatusItem│
│ main.swift       bootstrap   │
└──────────────────────────────┘
```

- **Priority.swift is pure** — no I/O; everything takes values and returns
  values. This is what makes the unit tests possible without hardware.
- **Effects are explicit**: `DeviceSource` abstracts device enumeration and
  default-device writes. Two implementations: `CoreAudioDeviceSource` (real)
  and `FixtureDeviceSource` (in-memory, loaded from a JSON device table).
- **Failures are typed**: `CliFailure` enumerates the expected CLI failures
  and carries the sysexits exit code + stderr lines as *data*. Only the
  boundary (`main()`) renders and exits — no `exit()` inside logic.
- **Auto-selection semantics** (see root [AGENTS.md](../../AGENTS.md)):
  - Applied only on a per-direction device-*set* change (output and input are
    fully independent).
  - Applied once at agent start (login/reboot); this is the deliberate
    exception to "a manual pick persists until its direction's set changes".
  - The current device wins within its tier: equivalent tier members
    (several headsets) never churn into each other.
  - A synthetic-transport current device (virtual/aggregate/AirPlay) is left
    untouched by auto-selection, and surfaced in the UI as
    `questionmark.circle` + a "not managed" menu row.
  - `reapply` (menu/CLI/Raycast) is an explicit user action and bypasses the
    excluded-current guard.
- **Transport classification** (`TransportClass.isSynthetic`) is the single
  place deciding menu visibility and auto-selection eligibility — extending
  to AirPlay-as-managed is a one-place change.

## Test seams

- `--devices <file>` injects a `FixtureData` JSON table (see
  `test/fixtures/`); combined with `--dry-run` every CLI behavior is
  observable without hardware. Real writes against a fixture are refused
  (EX_USAGE).
- `--menu-text` renders the dropdown as deterministic text (submenus, ✓
  markers, symbol per device, excluded-current info row).
- `auto` (hidden) models the GUI's automatic path — list change → per-direction
  apply, honoring the excluded-current guard.

## Tests

- **Unit tests** (`Tests/AudioPrioritySanitizerTests/`): pure-logic suite
  (tier matching incl. the documented Jabra headset-vs-speaker example, regex
  semantics, cycle order/wrap, symbol mapping, plan/perform semantics,
  deterministic menu text, fixture source units). Compiled with plain
  `swiftc` into `audio-priority-sanitizer-unit-tests`; entry file is
  `main.swift` (swiftc requires that name for top-level code).
  **Why not Swift Testing/XCTest**: SwiftPM cannot run under the nix sandbox
  (its manifest compiler links against `/usr/lib/swift`, which the sandboxed
  toolchain cannot resolve — cc-wrapper target mismatch). The harness is a
  ~60-line assertion runner (`Harness.swift`) with `ok -`/`not ok -` TAP-ish
  output; test cases live in `UnitTests.swift`, wired in
  `Tests/.../main.swift`. Flake check: `checks.audio-priority-sanitizer-unit`.
- **CLI integration tests** (`test/cli.bats`): drive the built binary
  headlessly against the device fixtures (`--devices` + `--dry-run`), one
  bats test per behavior; exit codes asserted against sysexits
  (64 EX_USAGE, 65 EX_DATAERR, 66 EX_NOINPUT, 3 ambiguous, 70 EX_SOFTWARE).
  Flake check: `checks.audio-priority-sanitizer-cli`.
- **Format**: `checks.audio-priority-sanitizer-format` verifies the Swift
  sources are a fixed point of `swift-format` (4-space indent / 120 cols via
  `.swift-format`; same gate as nixfmt/ruff-format in this repo).

## CLI

```
audio-priority-sanitizer list [output|input] [--json]
audio-priority-sanitizer current [output|input]
audio-priority-sanitizer set <output|input> <name>
audio-priority-sanitizer reapply
audio-priority-sanitizer cycle <output|input>
audio-priority-sanitizer menu-text        # test seam
audio-priority-sanitizer auto             # hidden test seam
```

- `set`: exact name first, then case-insensitive substring; ambiguous → exit
  3 with candidate list; no match → EX_NOINPUT.
- `list` includes excluded (synthetic) devices, tagged `[virtual]` etc.;
  `--json` adds `excluded`/`transport`/`current` fields.
- The menubar app is the same binary without a command (accessory app,
  `LSUIElement`).

## Packaging

- `default.nix` — plain `swiftc -O` build (NOT SwiftPM, see above), minimal
  `.app` bundle (`Info.plist`, `LSUIElement`), ad-hoc `codesign`, Raycast
  wrappers with `@bash@`/`@cli@` placeholders.
- Consumed by `audio-priority-sanitizer.nix` (root HM module): options
  `outputs`/`inputs` (`{ match, symbol }` tiers), `fallbackSymbol`,
  `debounceMs`; writes `~/Library/Application Support/audio-priority-sanitizer/config.json`
  (store path passed as argv so a rebuild restarts the agent with new
  config), installs the CLI + Raycast commands, and runs the launchd agent
  (`RunAtLoad` + `KeepAlive`, log truncated on launch,
  `~/Library/Logs/audio-priority-sanitizer/agent.log`).
