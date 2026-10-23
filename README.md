# Device Priority Sanitizer

![CI](https://github.com/afwlehmann/device-priority-sanitizer/actions/workflows/ci.yml/badge.svg)

Keeps your speaker, microphone, and camera on the device you actually want —
automatically, and independently for each target. A native macOS menubar app
with a full CLI.

## Why not just use macOS device selection?

macOS has no notion of an ordered priority list. Device selection is a manual,
per-device choice, and when devices connect or disconnect the defaults can
drift to the built-in hardware, a virtual device, or whatever was selected
last.

Device Priority Sanitizer adds:

- **Ordered priority tiers** — first matching device wins (e.g. headset before
  speaker before built-in)
- **Fully independent targets** — output, input, and camera each have their
  own priority list and device set
- **Automatic re-evaluation** whenever the connected device set changes
- **Stability within a tier** — equivalent devices (several headsets) never
  churn into each other
- **Manual overrides that persist** — a manual pick stays until that target's
  device set changes, then auto-selection resumes
- **Synthetic devices are left alone** — virtual, aggregate, AirPlay, and Desk
  View devices are recognised and never auto-selected
- **Per-device saved volume levels**, restored whenever a device is activated
- **Camera prioritization** via the macOS system-preferred camera (apps that
  follow the system default pick it up)
- **Sound effects follow the output** — alerts and beeps play on the active
  speaker, like changing the device in System Settings does
- **Menubar UI plus a scriptable CLI** for hotkeys and automation

## How it works

Define ordered tiers as name-matching rules per target. On startup and
whenever the connected device set changes, the app selects the
highest-priority connected device for each target and applies it — including
the sound-effects device for output. Manual picks (`set`, `cycle`) are
respected until that target's device set changes again; `reapply` forces the
configured priority at any time.

## CLI

```
device-priority-sanitizer list [output|input|camera] [--json]
device-priority-sanitizer current [output|input|camera]
device-priority-sanitizer set <output|input|camera> <name>
device-priority-sanitizer set <output|input|camera> --tier <title>
device-priority-sanitizer cycle <output|input|camera>
device-priority-sanitizer reapply
device-priority-sanitizer enable | disable
device-priority-sanitizer status [--json]
device-priority-sanitizer start | stop
device-priority-sanitizer volume get <output|input>
device-priority-sanitizer volume set <output|input> <0…1>
device-priority-sanitizer volume save <output|input>
device-priority-sanitizer volume clear <output|input>
device-priority-sanitizer volume show [--json]
device-priority-sanitizer config
```

- `set` resolves a device by exact name first, then case-insensitive
  substring; ambiguity exits with a candidate list.
- `set --tier` picks the best currently connected device in a configured
  tier — the same rules auto-selection uses.
- `cycle` advances to the next managed device in menu order (wrapping,
  synthetic devices skipped) — ideal for a headset↔speaker hotkey.
- `enable`/`disable` toggle prioritization globally without touching manual
  picks; `status` reports the current switch and configured tiers.
- `start`/`stop` control the menubar app itself, honoring whichever
  supervisor owns it (launchd agent or manual launch).
- `volume save`/`clear` manage the per-device levels that are restored on
  every activation; `volume show` inspects the store.

## Configuration

- Configure tiers, fallback symbols, and sound-effects mirroring in the
  configuration window (menubar *Configure Devices…* or `config`). Priority
  is drag-and-drop; an empty priority list leaves that target unmanaged.
- Configuration lives at
  `~/Library/Application Support/device-priority-sanitizer/config.json`;
  runtime state (`state.json`) and saved levels (`levels.json`) sit next to
  it and are owned by the app.
- The global prioritization switch is menubar/CLI-only and independent of the
  configuration.
- Agent log: `~/Library/Logs/device-priority-sanitizer/agent.log`.

## License

MIT — see [LICENSE](LICENSE).
