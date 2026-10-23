# device-priority-sanitizer

Native macOS menubar app + CLI that keeps the default speaker, microphone,
and camera on the highest-priority device available. Pure Swift
(AppKit + CoreAudio + AVFoundation), built with the nixpkgs Swift toolchain
via plain `swiftc`.

## Architecture

```
┌───────────────────────────────────┐
│ Sources/DevicePrioritySanitizer   │
│                                   │
│ Config.swift       config types   │
│ ConfigModel.swift  raw-JSON       │
│                    document for   │
│                    the config UI  │
│ ConfigWindow.swift AppKit         │
│                    config window  │
│ MediaDevice.swift  Target +       │
│                    devices,       │
│                    CoreAudio +    │
│                    fixtures +     │
│                    composite      │
│ Camera.swift       AVFoundation   │
│ State.swift        runtime        │
│                    state          │
│ Levels.swift       saved volume   │
│                    levels         │
│ Agent.swift        start/stop,    │
│                    quit, log      │
│ Priority.swift     pure engine    │
│ Command.swift      CLI commands   │
│ StatusMenu.swift   NSStatusItem   │
│ main.swift         bootstrap      │
└───────────────────────────────────┘
```

- **Priority.swift is pure** — no I/O; everything takes values and returns
  values. This is what makes the unit tests possible without hardware.
- **Effects are explicit**: `DeviceSource` abstracts device enumeration,
  default-device writes, per-device volume reads/writes, and volume-change
  observation. Implementations: `CoreAudioDeviceSource` (audio output/input),
  `CameraDeviceSource` (AVFoundation cameras), `SystemDeviceSource`
  (composite routing per target), and `FixtureDeviceSource` (in-memory,
  loaded from a JSON device table).
- **MediaDevice is keyed by uid** (CoreAudio device UID /
  `AVCaptureDevice.uniqueID`) — numeric ids are a CoreAudio write-mechanics
  detail owned by the audio source.
- **Failures are typed**: `CliFailure` enumerates the expected CLI failures
  and carries the sysexits exit code + stderr lines as *data*. Only the
  boundary (`main()`) renders and exits — no `exit()` inside logic.
- **Functional style — the Swift elaboration of the repo-wide FP baseline**:
  `throws` with a typed error enum *is* this codebase's result type — failure
  travels as data (`CliFailure`) and is rendered at exactly one boundary.
  Struct `mutating` on *local* values (copy + `upsert`/`remove`) and local
  `var` accumulators are accepted Swift value semantics; the enforced rule is
  *no shared-state mutation*, not "no local var". Mutation is confined to
  three zones: the UI layer (views are dumb renderers fed `LevelRowState` and
  callbacks — never policy), the device-source seams (CoreAudio/AVFoundation
  FFI, recording fixtures), and the `main()` boundary. Everything else stays
  pure: values in, values out — that is what lets the unit suite run without
  hardware. Logging is an observable effect: warning logs belong to the
  boundary or the effects layer; the two loader degradations (`resolveState`,
  `loadLevelsDocument`) are documented, deliberate exceptions.
- **Auto-selection semantics** (see the full rules below):
  - Applied only on a per-target device-*set* change (output, input, and
    camera are fully independent).
  - Applied once at agent start (login/reboot); this is the deliberate
    exception to "a manual pick persists until its target's set changes".
  - The current device wins within its tier: equivalent tier members
    (several headsets) never churn into each other.
  - A synthetic-transport current device (virtual/aggregate/AirPlay/Desk
    View) is left untouched by auto-selection, and surfaced in the UI as
    `questionmark.circle` + a "not managed" menu row.
  - `reapply` (menu/CLI/Raycast) is an explicit user action and bypasses the
    excluded-current guard.
  - **Global switch**: the runtime state file (`State.swift`,
    `state.json` — NOT the config, which Home Manager owns read-only)
    gates every automatic write. Disabled → no startup/set-change/`reapply`
    writes, `pause.circle` in the menubar, Reapply greyed; manual
    `set`/`cycle` stay available; disabling never restores devices.
    Menubar toggle and CLI `enable`/`disable` write the file; the CLI posts
    a distributed notification so a running agent reloads (and applies, when
    the switch turned on). Missing → enabled; corrupt → warning + enabled.
  - **Per-target switch**: an empty tier list *is* the "not managed" state —
    auto-selection and `reapply` skip the target, the UI shows a
    "Not auto-managed" row, and the generated Raycast `set-<target>`
    command is omitted. No separate boolean.
- **Saved volume levels** (see "Saved levels" below): every activation —
  auto-selection, menu pick, cycle, `reapply`, or the CLI `set`/`cycle` —
  restores the activated device's saved output/input level. Not restored on
  startup onto an already-active device, and not on external default changes:
  a saved level never overwrites a change made outside this app.
- **Transport classification** (`TransportClass.isSynthetic`) is the single
  place deciding menu visibility and auto-selection eligibility — extending
  to AirPlay-as-managed is a one-place change. Camera transports:
  `.continuity` (a Continuity camera, managed) and `.deskView` (synthetic);
  `AVCaptureDevice.isVirtualDevice` maps to `.virtual`.
- **Cameras follow the system-preferred camera**: `CameraDeviceSource`
  reads `AVCaptureDevice.systemPreferredCamera` and writes
  `AVCaptureDevice.userPreferredCamera`. Never opens a capture session,
  never requests camera TCC. The setter has **no error channel** (it is a
  plain settable property), so every write is verified by re-reading the
  preference with a bounded runloop spin; a silent no-op surfaces as a
  non-`noErr` status → CLI exit 70, agent log warning. The write path is
  isolated in `CameraDeviceSource.setDefault` so a fallback backend (e.g.
  the CoreMediaIO default input device) would be a one-place change.
- **App coverage caveat**: apps that follow the system default (FaceTime,
  Safari `getUserMedia`, native AVCapture clients, and Zoom/Slack/Teams set
  once to "System Default") pick the preference up; apps with their own
  pinned camera picker ignore it. There is no public CoreAudio-style global
  camera setter — a virtual camera would be a separate, much larger project
  (signing/notarization) and is deliberately out of scope.
- **Sound effects follow the output**: every output write funnels through
  `DeviceSource.setDefault`, and the audio source also sets
  `kAudioHardwarePropertyDefaultSystemOutputDevice` — so alerts/beeps play
  on the active speaker like System Settings does. Disable with
  `manageSoundEffects = false` in the config JSON (CLI default: true);
  input and camera writes never touch the effects slot.
- **Camera events**: `AVCaptureDevice.wasConnected/wasDisconnectedNotification`
  feed the same debounced device-list pass as CoreAudio's device-list
  listener; KVO on `systemPreferredCamera` (a class property, documented as
  key-value observable) refreshes the menu when another app changes the
  preferred camera.

## Configuration window

AppKit window (`ConfigWindow.swift`) over a pure model
(`ConfigModel.swift`), opened from the menubar *Configure Devices…*, the
`config` CLI command, or the Raycast `configure` script. Three tabs
(Speaker / Microphone / Camera), each with:

- **Available** (left): managed devices not covered by any tier,
  lexicographic; identical names collapse into one row (a name tier matches
  both anyway). Double-click appends.
- **Priority** (right): tier rows in priority order; multi-device regex
  tiers render grouped ("Headset — 2 devices" style subtitle), a tier
  matching nothing shows "not connected". Drag to reorder, drag out or
  Remove to drop the tier, drag a device in to manage it. An empty priority
  list is the per-target "not auto-managed" switch — no other boolean.

Adding a device writes `{title: unique name, match: "^escaped-name$",
symbol: auto}` — anchored exact patterns (a name containing another
device's name cannot capture it), deduplicated titles (`Name (2)`), symbols
derived from transport (headphones / hifispeaker.fill / laptopcomputer /
mic / iphone / video). v1 has no symbol picker, tier renaming, or regex
editor; symbols stay editable in the JSON.

- **Editing model**: explicit **Save** (atomic write + apply), **Revert**
  (reload from disk), **Reload** (discarding-unsaved prompt), unsaved-close
  prompt; no autosave. Saving applies in-process when owned by the agent;
  a standalone window (`config` CLI) posts the `configChanged`
  distributed notification so the running agent reloads and applies.
- **Offline tiers**: removing a priority row whose device is not currently
  connected (drag-out or Remove) asks for confirmation — the removal would
  otherwise be invisible, because the device cannot enter the Available
  list until it is reconnected, and nothing could bring the tier back.
  Connected devices remove instantly; they are reversible via the
  Available list. The lists re-enumerate when the window becomes key, so
  hotplugs appear without the Reload button.
- **Data safety**: the document is a raw JSON object (`ConfigDocument`) —
  unknown top-level keys and unknown fields on existing tiers pass through
  untouched; only the three tier arrays are rewritten. Invalid config at
  open: alert + timestamped `config.json.invalid-<ts>` backup + "start
  with empty" recovery; regexes are validated at load so a save always
  yields an engine-compilable config.
- **Read-only mode**: Home Manager's store symlink (resolved path under
  `/nix/store` or non-writable) opens with a banner and disabled
  edit/Save. A live advisory lock (`config.json.lock`, PID + stale
  reclaim) makes a second writable editor read-only ("another
  configuration window (PID …)"); the lock is released on window close.
- **Banners**: a disabled global switch shows "Prioritization is disabled
  globally" (the toggle stays menubar/CLI-only); the camera tab documents
  "Apps must be set to System Default".
- Standalone `config` quits after the last window closes; the agent-owned
  window only releases the lock. The AppKit UI is verified manually — no
  GUI automation under the nix sandbox; the pure model is unit-tested.

## Saved levels (per-device volume restore)

Between the device submenus and the Cycle items the dropdown carries two
custom-view rows (output first, then input — same order as the submenus):

```
Jabra SPEAK 510 USB      (out)    restore                ← name + suffix + state
[───────────●────────────────]       Save         Clear  ← slider + actions
```

- **Line 1** names the *device* the controls act on (the current default of
  that target — this is what makes the per-device scope visible), truncated
  with the full name as tooltip, plus a fixed `(out)` / `(in)` target suffix
  in secondary color (a headset used as both output and input would otherwise
  make the rows indistinguishable). The suffix is a *separate* label
  right-aligned on the slider's right edge, so a long name ellipsizes before
  it and the marker never disappears. The state label `restore` /
  `do not restore` spans exactly the two buttons, left-aligned, and the
  labels and buttons use the small system font.
- **Line 2** holds the live slider (drag = set the current device's volume;
  never persisted by dragging) and the `Save`/`Clear` pair — the slider ends
  12 pt before the right column, giving the actions their own visual space
  without widening the row. `Save` upserts the current device's entry;
  `Clear` removes the entry that applies to the shown device and is dimmed
  when none does — label and Clear state derive from the same lookup that
  drives restore, so they can never disagree. Button clicks update their own
  state in place; no menu rebuild while open.
- **Row content aligns with the menu items' text**: AppKit does not inset
  `NSMenuItem.view` content by the state/title gutter, so the row pads by
  AppKit's own title origin, derived at runtime from
  `NSMenuItemCell.titleRect(forBounds:)` (26 pt on current macOS: state
  column + padding, counted from the item rect origin) minus the row view's
  own x within the menu window — the metric and the view placement have
  different origins. No hand-tuned constant; a macOS gutter change follows
  along. `DPS_DEBUG_LAYOUT=1` logs the metric, the view frame, and the
  effective inset at menu open.
- **The stored value is visible on the slider**: the custom-drawn
  `LevelSliderControl` marks the saved position with a small accent tick on
  its track, so the bare `restore`/`do not restore` label stays unambiguous.
  The control draws everything itself (track, filled portion, tick, knob)
  from its own bounds — `NSSliderCell` insets its bar by the knob thickness,
  which visibly misaligned the two rows' tracks in 0.4.0; the geometry
  mapping (`sliderKnobX`/`sliderValue`) is pure and unit-tested. The numeric
  value is also inspectable via `volume show`.
- Volume rows work regardless of the prioritization switch (manual control,
  like `set`/`cycle`). No volume row for the camera target.

**Store** (`Levels.swift`): `~/Library/Application Support/device-priority-sanitizer/levels.json`
(env `DEVICE_PRIORITY_SANITIZER_LEVELS`, CLI `--levels <path>`; atomic write;
missing/corrupt → warning + empty, never blocks the app). Schema:
`{schemaVersion: 1, output|input: {<uid>: {uid, name, modelUID?, transport, level, savedAt}}}`.
Runtime state, deliberately not the HM config (same reasoning as `state.json`).

**Lookup** (`savedLevel`): exact UID first; otherwise — only for entries whose
own UID is *not currently connected* — a unique entry with the same name and
(when both sides know one) the same `modelUID` (`kAudioDevicePropertyModelUID`,
surfaced on `MediaDevice` and in `list --json`). This is the replacement-device
fallback: a defective unit swapped for the same model keeps restoring its
level. Two same-name devices with both UIDs connected never cross-apply (the
gate), ambiguity restores nothing. `Clear` removes the matched entry (exact or
replacement). Stale entries linger harmlessly — `volume show` inspects them.

**Restore** (`restoreSavedLevel`): applied right after every activation the
app or CLI performs — auto-selection, menu pick, cycle, `reapply`, CLI
`set`/`cycle` — best-effort (a failed volume write logs a warning, never
fails the activation). Explicitly *not* restored: startup onto an
already-active device, and external default changes (`defaultsChanged` only
refreshes the menu). Volume I/O goes through the `DeviceSource` seam
(`kAudioDevicePropertyVolumeScalar`: main element when present, otherwise
per-channel — read: average, write: every channel; unsupported devices report
`nil` and render a disabled slider). Unlike the camera preference, volume
writes have a real error channel, so the OSStatus decides — no read-back
verification.

**Live sliders** (0.5.0): the displayed level follows external changes
(System Settings, media keys, other apps) immediately. `DeviceSource
.observeVolume(of:target:handler:)` registers CoreAudio property listeners
on the current output and input devices — the rows show exactly those —
using the same element selection as reads/writes (`volumeElements` is the
one place deciding all three). The listener block runs on the main queue, so
the handler re-reads the level and pushes it to the displayed row in place
(`MenuController.setLiveLevel` — never a menu rebuild, which would disrupt an
open menu). Listeners are re-registered on every default-device, device-set,
or config change and after coreaudiod restarts (the service drops
registrations); removal closures tolerate registrations that died with their
device. The app's own slider-drag writes echo back as notifications and are
ignored while the knob is dragging (`LevelSliderControl.isDragging`); the
trailing push after mouse-up lands harmlessly. Devices that post no volume
notifications (rare) still refresh on the next menu open.

**CLI** (`volume …`): `get`/`set` are live (set follows the fixture write
guard), `save`/`clear`/`show` operate on the store. `save`/`clear` post the
`levelsChanged` distributed notification on the default path so a running
agent refreshes; overridden `--levels` paths never poke the live agent. Exit
codes: 64 invalid target/level/args, 66 no current device or no volume
control, 70 write failure; `clear` without an entry is idempotent (exit 0).
Volume commands never load the tier config.

Known limitations: devices that post no volume notifications (rare) refresh
on the next menu open instead of live; the row UI is verified manually (no
GUI automation under the nix sandbox) — the lookup, restore, and store
logic are unit-tested and the CLI paths run in bats against
`devices-volumes.json` (volume seeds + model UIDs;
`levels-exact.json`/`levels-replacement.json`).

## App lifecycle (start/stop, autostart, Quit, logging)

The app **is** the agent — one binary, no separate service. Lifecycle control
(`Agent.swift`) targets that one process and honors whichever supervisor
owns it:

- **launchd mode** (HM LaunchAgent installed, `autostart = true`): `KeepAlive`
  resurrects any plain exit, so `stop` boots the job out
  (`launchctl bootout gui/<uid>/<label>`) and `start` bootstraps the plist
  back in. The agent plist is discovered by scanning
  `~/Library/LaunchAgents/*.device-priority-sanitizer.plist`; the label is
  read from the plist (HM derives it from the Nix `username` — never guessed).
- **manual mode** (no plist — `autostart = false`, or a bare install):
  `start` launches the `.app` via LaunchServices (`NSWorkspace`, resolved
  from the CLI's own executable path) and `stop` terminates running
  instances via `NSRunningApplication` (bundle id match, graceful terminate
  with a 2 s poll).
- `start`/`stop` are idempotent (`app: already running` / `app: not running`,
  exit 0) and never load the tier config — a broken config must not block
  stopping. `stop` is transient: the next login or `darwin-rebuild switch`
  reloads the LaunchAgent; the persistent "off" is `disable` (prioritization
  switch) or `autostart = false` (declarative).
- **Quit** uses the same stop path (`stopAgentFromWithinApp`): bootout when
  supervised, `NSApp.terminate` otherwise.
- **Logging is app-owned** (`AgentLog`): GUI mode creates
  `~/Library/Logs/device-priority-sanitizer/`, rotates `agent.log` →
  `agent.log.1`, and redirects stdout+stderr before any config load — so
  launchd, `start`, and manual launches all keep the same `agent.log`, and a
  crash loop still rotates evidence per start. Two concurrent instances can
  rotate each other's log (the survivor keeps writing through the renamed
  inode); this is documented, not fixed.
- `/bin/launchctl` is the only external binary (no nixpkgs package exists;
  same precedent as the module's migration script).
- Test seams: `--launchd-plist <path>` overrides plist discovery,
  `--app-bundle <path>` overrides bundle resolution (fixtures:
  `agent.plist` with the never-loaded label `bats.device-priority-sanitizer`,
  `TestApp.app` with its own bundle id). With `--dry-run` the commands only
  print the plan; inside the nix sandbox `/bin/launchctl` is unavailable and
  `isJobLoaded` degrades to "not loaded". The pure planner
  (`planAgent`) is unit-tested; the GUI Quit is manually verified.

## Symbols

`symbol` values (tier entries, `fallbackSymbol`) are SF Symbol names —
Apple's system icon catalog:

- Catalog + the SF Symbols browsing app:
  https://developer.apple.com/sf-symbols
- Human Interface Guidelines overview:
  https://developer.apple.com/design/human-interface-guidelines/sf-symbols

The SF Symbols app is the reference for names and availability — symbols
appear in newer macOS releases, and a name resolves against the *running*
system, so a symbol that only exists on a newer OS behaves like a typo.

An invalid name (e.g. `laptop-foo`) fails silently —
`NSImage(systemSymbolName:)` returns nil and the damage is partial:

- **Menubar status image**: `statusImage` requires every slot symbol to
  resolve; one invalid name makes the whole composite nil — no menubar
  icon at all on launch (or the previous image sticks after a refresh).
- **Menu and config-window rows**: the row renders without its icon; the
  text is unaffected.
- **CLI** (`menu-text`, `list --json`): symbols are opaque strings — the
  raw name is printed, nothing fails.

Unlike tier regexes there is no fail-fast validation at startup; symbols
resolve only where they render. Module defaults: `headphones`,
`hifispeaker.fill`, `laptopcomputer`, `mic`, `speaker.wave.3`, `video`,
`iphone`, `display`, plus the built-in `questionmark.circle` (excluded
current) and `pause.circle` (disabled switch).

## Test seams

- `--devices <file>` injects a `FixtureData` JSON table (see
  `test/fixtures/`); combined with `--dry-run` every CLI behavior is
  observable without hardware. Real writes against a fixture are refused
  (EX_USAGE). The optional `defaultSystemOutput` field seeds the
  sound-effects pointer; `isCamera` on a device and `defaultCamera` seed
  camera capability/current (fixtures without them still decode — audio-only
  tables predate cameras).
- `--menu-text` renders the dropdown as deterministic text (submenus, ✓
  markers, symbol per device, excluded-current info row).
- `auto` (hidden) models the GUI's automatic path — list change → per-target
  apply, honoring the excluded-current guard.

## Tests

- **Unit tests** (`Tests/DevicePrioritySanitizerTests/`): pure-logic suite
  (tier matching incl. the documented Jabra headset-vs-speaker example, regex
  semantics, cycle order/wrap, symbol mapping, plan/perform semantics,
  sound-effects mirroring, camera tier matching/fall-through/exclusion,
  deterministic menu text, fixture source units).
  Compiled with plain `swiftc` into `device-priority-sanitizer-unit-tests`;
  entry file is `main.swift` (swiftc requires that name for top-level code).
  **Why not Swift Testing/XCTest**: SwiftPM cannot run under the nix sandbox
  (its manifest compiler links against `/usr/lib/swift`, which the sandboxed
  toolchain cannot resolve — cc-wrapper target mismatch). The harness is a
  ~60-line assertion runner (`Harness.swift`) with `ok -`/`not ok -` TAP-ish
  output; test cases live in `UnitTests.swift`, wired in
  `Tests/.../main.swift`. Flake check: `checks.unit`.
- **CLI integration tests** (`test/cli.bats`): drive the built binary
  headlessly against the device fixtures (`--devices` + `--dry-run`), one
  bats test per behavior; exit codes asserted against sysexits
  (64 EX_USAGE, 65 EX_DATAERR, 66 EX_NOINPUT, 3 ambiguous, 70 EX_SOFTWARE).
  The camera fixtures (`config-cameras.json`, `devices-cameras*.json`) pair
  the full audio table with four cameras (external, Continuity, built-in,
  virtual) and three camera tiers. Flake check: `checks.cli`.
- **Format**: `checks.format` verifies the Swift
  sources are a fixed point of `swift-format` (4-space indent / 120 cols via
  `.swift-format`; same gate as nixfmt for the Nix files).

## CLI

```
device-priority-sanitizer list [output|input|camera] [--json]
device-priority-sanitizer current [output|input|camera]
device-priority-sanitizer set <output|input|camera> <name>
device-priority-sanitizer set <output|input|camera> --tier <title>
device-priority-sanitizer reapply
device-priority-sanitizer cycle <output|input|camera>
device-priority-sanitizer enable
device-priority-sanitizer disable
device-priority-sanitizer status [--json]
device-priority-sanitizer start
device-priority-sanitizer stop
device-priority-sanitizer volume get <output|input>
device-priority-sanitizer volume set <output|input> <0…1>
device-priority-sanitizer volume save <output|input>
device-priority-sanitizer volume clear <output|input>
device-priority-sanitizer volume show [--json]
device-priority-sanitizer config [--config <path>] [--devices <fixture>] [--state <path>]
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
  one-shot manual pick: it persists until that target's device set changes,
  then auto-selection resumes at the highest tier.
- `cycle`: the manual override for when the wanted device is *not* the
  highest priority. Advances to the next managed device in visible menu order
  (wrapping, synthetic devices skipped), so it can be bound to a hotkey
  (Raycast `cycle-output`/`cycle-input`/`cycle-camera`) for
  headset↔speaker (or camera) switching without naming devices or opening
  System Settings. The pick persists until that target's device set changes,
  so auto-selection does not immediately undo it.
- `list` includes excluded (synthetic) devices, tagged `[virtual]` etc.;
  `--json` adds `uid` (all targets), `excluded`/`transport`/`current`, and
  `deviceType` (the AVFoundation device type string, camera entries only).
- `enable`/`disable` are state-only: they never load the tier config (a
  broken config must not prevent disabling), write the state file atomically,
  and post the state-changed notification when writing the *default* path —
  an overridden `--state` (tests) never pokes the live agent. Write failure
  → exit 70. `status` reads the config JSON without compiling regexes:
  an invalid regex still reports tiers; invalid JSON still shows the switch
  (`targets: unavailable (invalid config)`, exit 65); a missing config is
  not an error (all targets `not managed`).
- Trailing positional arguments a command does not consume are rejected with
  EX_USAGE (except `set`, where they are part of the name).
- The menubar app is the same binary without a command (accessory app,
  `LSUIElement`).

## Packaging

- `default.nix` — plain `swiftc -O` build (NOT SwiftPM, see above), minimal
  `.app` bundle (`Info.plist`, `LSUIElement`), Raycast wrappers with
  `@bash@`/`@cli@` placeholders (`reapply`, `cycle-output`, `cycle-input`,
  `cycle-camera`, `configure`). The package source is a focused fileset
  (`Sources/`, `raycast/`, `Info.plist`) — tests and docs must not change
  the package hash. Signing relies on the nixpkgs darwin toolchain's ad-hoc
  signature — no `/usr/bin/codesign` call; the bundle itself needs no
  signature because the launchd wrapper execs the binary directly.
- Consumed by `nix/home-manager.nix` (exported as
  `homeManagerModules.default`; the flake sets
  `services.device-priority-sanitizer.package` via `lib.mkDefault`): options
  `outputs`/`inputs`/`cameras` (`{ title, match, symbol }` tiers),
  `fallbackSymbol` (incl. `camera`), `debounceMs`, `manageSoundEffects`, and
  `autostart` (default `true`). It writes
  `~/Library/Application Support/device-priority-sanitizer/config.json`
  (store path passed as argv so a rebuild restarts the agent with new
  config), installs the CLI + Raycast commands, and — when `autostart` —
  runs the launchd agent (`RunAtLoad` + `KeepAlive`). launchd runs the app
  binary directly with `--config <store path>`; the old shell wrapper is
  gone because the app owns `agent.log` itself (see App lifecycle). With
  `autostart = false` an activation boots out a still-loaded job and removes
  the plist — `device-priority-sanitizer start` launches the app on demand.
  The launchd label is `<home.username>.device-priority-sanitizer` (read
  from `config.home.username`, no extraSpecialArg needed).
- The Raycast `set-output`/`set-input`/`set-camera` commands are **generated
  in the HM module**, not shipped by the package: their static tier
  dropdown must embed `cfg.outputs`/`cfg.inputs`/`cfg.cameras` titles
  (`title` is required and must be unique per target; the module asserts
  this). They call `set <target> --tier "$1"`. The `configure` command is
  package-shipped (static; opens the config window via `config`).

## Development

- `nix develop` — dev shell with the pre-commit hooks auto-installed
  (shellHook from `checks.pre-commit-check`) plus: `swift`, `swift-format`,
  `bats`, `jq`, `nixfmt`, `shellcheck`, `shfmt`, `convco`, `nixd`, `git`,
  `gh`.
- Hooks (git-hooks.nix, mirrored from the origin config repo): `nixfmt`,
  `convco` (commit-msg), `shellcheck` + `shfmt` (scoped to `raycast/` and
  `test/` with `types = []` + `--shell=bash` + `SC2239` exclusion so the
  `@bash@` placeholder shebangs are handled). `swift-format` is deliberately
  a flake check, not a hook (Swift toolchain too heavy for every invocation).
- Verification: `nix flake check` (builds package, runs `unit`, `cli`,
  `format`, and the pre-commit check) and `nix build .#default`. Quick
  evaluation-only pass: `nix flake check --no-build`.
- CI (`.github/workflows/ci.yml`): macOS Tahoe runner (`macos-26`), Nix via
  DeterminateSystems installer + magic-nix-cache, runs `nix flake check` on
  push/PR/tags.
- Release process: bump the version in exactly three places (`default.nix`
  `version`, `Sources/DevicePrioritySanitizer/Command.swift`
  `programVersion`, `Info.plist` `CFBundleShortVersionString`), commit with a
  conventional message, and tag an annotated `vX.Y.Z`.
- History note: this repo was extracted from a private config repository;
  `git-filter-repo` preserved the full app history, including the
  pre-rename `audio-priority-sanitizer` era and the Home Manager module
  (mapped to `nix/home-manager.nix`). Commit hashes differ from the origin
  repository.
