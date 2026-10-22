# device-priority-sanitizer

Native macOS menubar app + CLI that keeps the default speaker and microphone
on the highest-priority device available. Pure Swift (AppKit + CoreAudio),
built with the nixpkgs Swift toolchain via plain `swiftc`.

## Architecture

```
┌──────────────────────────────┐
│ Sources/DevicePrioritySanitizer │
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
- **Sound effects follow the output**: every write path funnels through
  `DeviceSource.setDefault`, and both implementations also set
  `kAudioHardwarePropertyDefaultSystemOutputDevice` on an output write — so
  alerts/beeps play on the active speaker like System Settings does. Disable
  with `manageSoundEffects = false` in the config JSON (CLI default: true);
  an input write never touches the effects slot.

## Test seams

- `--devices <file>` injects a `FixtureData` JSON table (see
  `test/fixtures/`); combined with `--dry-run` every CLI behavior is
  observable without hardware. Real writes against a fixture are refused
  (EX_USAGE). The optional `defaultSystemOutput` field seeds the
  sound-effects pointer (fixtures without it still decode).
- `--menu-text` renders the dropdown as deterministic text (submenus, ✓
  markers, symbol per device, excluded-current info row).
- `auto` (hidden) models the GUI's automatic path — list change → per-direction
  apply, honoring the excluded-current guard.

## Tests

- **Unit tests** (`Tests/DevicePrioritySanitizerTests/`): pure-logic suite
  (tier matching incl. the documented Jabra headset-vs-speaker example, regex
  semantics, cycle order/wrap, symbol mapping, plan/perform semantics,
  sound-effects mirroring, deterministic menu text, fixture source units).
  Compiled with plain `swiftc` into `device-priority-sanitizer-unit-tests`;
  entry file is `main.swift` (swiftc requires that name for top-level code).
  **Why not Swift Testing/XCTest**: SwiftPM cannot run under the nix sandbox
  (its manifest compiler links against `/usr/lib/swift`, which the sandboxed
  toolchain cannot resolve — cc-wrapper target mismatch). The harness is a
  ~60-line assertion runner (`Harness.swift`) with `ok -`/`not ok -` TAP-ish
  output; test cases live in `UnitTests.swift`, wired in
  `Tests/.../main.swift`. Flake check: `checks.device-priority-sanitizer-unit`.
- **CLI integration tests** (`test/cli.bats`): drive the built binary
  headlessly against the device fixtures (`--devices` + `--dry-run`), one
  bats test per behavior; exit codes asserted against sysexits
  (64 EX_USAGE, 65 EX_DATAERR, 66 EX_NOINPUT, 3 ambiguous, 70 EX_SOFTWARE).
  Flake check: `checks.device-priority-sanitizer-cli`.
- **Format**: `checks.device-priority-sanitizer-format` verifies the Swift
  sources are a fixed point of `swift-format` (4-space indent / 120 cols via
  `.swift-format`; same gate as nixfmt/ruff-format in this repo).

## CLI

```
device-priority-sanitizer list [output|input] [--json]
device-priority-sanitizer current [output|input]
device-priority-sanitizer set <output|input> <name>
device-priority-sanitizer set <output|input> --tier <title>
device-priority-sanitizer reapply
device-priority-sanitizer cycle <output|input>
device-priority-sanitizer menu-text        # test seam
device-priority-sanitizer auto             # hidden test seam
```

- `set`: exact name first, then case-insensitive substring; multiple exact
  matches (two identical devices) and multiple substring matches are ambiguous
  → exit 3 with candidate list; no match → EX_NOINPUT.
- `set --tier`: resolves the configured tier `title` to the best currently
  connected device in it — current device kept when it belongs to the tier,
  otherwise the alphabetically first match (same rules as auto-selection).
  Unknown title → EX_USAGE (lists the titles); tier with no connected device
  → EX_NOINPUT; a device name alongside `--tier` → EX_USAGE. This is a
  one-shot manual pick: it persists until that direction's device set changes,
  then auto-selection resumes at the highest tier.
- `cycle`: the manual override for when the wanted device is *not* the
  highest priority. Advances to the next managed device in visible menu order
  (wrapping, synthetic devices skipped), so it can be bound to a hotkey
  (Raycast `cycle-output`/`cycle-input`) for headset↔speaker switching
  without naming devices or opening System Settings. The pick persists until
  that direction's device set changes, so auto-selection does not immediately
  undo it.
- `list` includes excluded (synthetic) devices, tagged `[virtual]` etc.;
  `--json` adds `excluded`/`transport`/`current` fields.
- Trailing positional arguments a command does not consume are rejected with
  EX_USAGE (except `set`, where they are part of the name).
- The menubar app is the same binary without a command (accessory app,
  `LSUIElement`).

## Packaging

- `default.nix` — plain `swiftc -O` build (NOT SwiftPM, see above), minimal
  `.app` bundle (`Info.plist`, `LSUIElement`), Raycast wrappers with
  `@bash@`/`@cli@` placeholders (`reapply`, `cycle-output`, `cycle-input`).
  Signing relies on the nixpkgs darwin toolchain's ad-hoc signature — no
  `/usr/bin/codesign` call (repo purity rule); the bundle itself needs no
  signature because the launchd wrapper execs the binary directly.
- Consumed by `device-priority-sanitizer.nix` (root HM module): options
  `outputs`/`inputs` (`{ title, match, symbol }` tiers), `fallbackSymbol`,
  `debounceMs`; writes `~/Library/Application Support/device-priority-sanitizer/config.json`
  (store path passed as argv so a rebuild restarts the agent with new
  config), installs the CLI + Raycast commands, and runs the launchd agent
  (`RunAtLoad` + `KeepAlive`, previous log rotated to `agent.log.1` on launch,
  `~/Library/Logs/device-priority-sanitizer/agent.log`).
- The Raycast `set-output`/`set-input` commands are **generated in the root HM
  module**, not shipped by the package: their static tier dropdown must embed
  `cfg.outputs`/`cfg.inputs` titles (`title` is required and must be unique per
  direction; the module asserts this). They call `set <direction> --tier "$1"`.
