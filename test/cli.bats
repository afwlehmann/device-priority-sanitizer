#!/usr/bin/env bats
# bats require_minimum_version 1.7.0
# shellcheck disable=SC2034 # BIN is supplied by the flake check and used across tests

# Tests for the device-priority-sanitizer CLI, run headlessly against
# injected device-table fixtures (--devices) and --dry-run, so no real
# audio hardware or GUI is touched.
# Environment: BIN (built CLI), FIXTURES (fixture dir), TEST_HELPER.

load "${TEST_HELPER}"

FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

FLAGS=(--config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices.json")

@test "list marks the current device and tags excluded transports" {
  run $BIN "${FLAGS[@]}" list output
  assert_success
  assert_has_line "output:"
  assert_has_line "* Jabra Evolve 75 SE"
  assert_has_line "  Jabra SPEAK 510 USB"
  assert_has_line "  DELL U3824DW"
  assert_has_line "  Microsoft Teams Audio [virtual]"
}

@test "list --json emits valid JSON with excluded flag" {
  run $BIN "${FLAGS[@]}" --json list output
  assert_success
  assert_output_is_not_empty_by_jq
}

assert_output_is_not_empty_by_jq() {
  local teams current
  teams="$(jq -r '.output[] | select(.name == "Microsoft Teams Audio") | .excluded' <<<"$output")"
  current="$(jq -r '.output[] | select(.name == "Jabra Evolve 75 SE") | .current' <<<"$output")"
  assert_equal "$teams" "true"
  assert_equal "$current" "true"
}

@test "current prints the bare device name per direction" {
  run $BIN "${FLAGS[@]}" current output
  assert_success
  assert_output_is "Jabra Evolve 75 SE"
  run $BIN "${FLAGS[@]}" current input
  assert_success
  assert_output_is "Jabra Evolve 75 SE"
}

@test "menu-text: ordered first-match — headset tier beats speaker tier" {
  run $BIN "${FLAGS[@]}" menu-text
  assert_success
  assert_has_line "speaker-menu:"
  assert_has_line "  ✓ Jabra Evolve 75 SE [headphones]"
  assert_has_line "  · Jabra SPEAK 510 USB [hifispeaker.fill]"
  assert_has_line "  · MacBook Pro Speakers [laptopcomputer]"
  assert_has_line "  · DELL U3824DW [speaker.wave.3]"
}

@test "menu-text: Jabra headset vs Jabra speaker are distinct tiers (documented example)" {
  # The documented example: 'Jabra Evolve 75 SE' must land in the headset
  # tier and appear BEFORE 'Jabra SPEAK 510 USB' — a bare 'Jabra' pattern
  # would conflate the two.
  run $BIN "${FLAGS[@]}" menu-text
  assert_success
  local evolve speak
  evolve="$(grep -n 'Jabra Evolve 75 SE' <<<"$output" | cut -d: -f1 | head -1)"
  speak="$(grep -n 'Jabra SPEAK 510 USB' <<<"$output" | cut -d: -f1 | head -1)"
  [ "$evolve" -lt "$speak" ]
}

@test "auto: without a headset the speaker tier falls through to SPEAK 510" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-no-headset.json" --dry-run auto
  assert_success
  assert_has_line "output: would set to Jabra SPEAK 510 USB"
  assert_has_line "input: would set to Jabra SPEAK 510 USB"
}

@test "auto: excluded (virtual) current device is left untouched" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-excluded-current.json" --dry-run auto
  assert_success
  assert_has_line "output: skipped — current 'Microsoft Teams Audio' is not managed"
  assert_has_line "input: skipped — current 'Microsoft Teams Audio' is not managed"
}

@test "menu-text: excluded current shows the not-managed glyph and info row" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-excluded-current.json" menu-text
  assert_success
  assert_has_line "status: questionmark.circle questionmark.circle video"
  assert_has_line "  - Current: Microsoft Teams Audio (not managed)"
}

@test "reapply is explicit and bypasses the excluded-current guard" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-excluded-current.json" --dry-run reapply
  assert_success
  assert_has_line "output: would set to Jabra SPEAK 510 USB"
}

@test "auto keeps a managed current that is already the target" {
  run $BIN "${FLAGS[@]}" --dry-run auto
  assert_success
  assert_has_line "output: unchanged (Jabra Evolve 75 SE)"
  assert_has_line "input: unchanged (Jabra Evolve 75 SE)"
}

@test "set matches exact first, then case-insensitive substring" {
  run $BIN "${FLAGS[@]}" --dry-run set output "MacBook Pro Speakers"
  assert_success
  assert_output_is "output: would set to MacBook Pro Speakers"
  run $BIN "${FLAGS[@]}" --dry-run set output "macbook pro speak"
  assert_success
  assert_output_is "output: would set to MacBook Pro Speakers"
}

@test "set to the current device is a no-op" {
  run $BIN "${FLAGS[@]}" --dry-run set output "Evolve"
  assert_success
  assert_output_is "output: already Jabra Evolve 75 SE"
}

@test "set with no match fails with EX_NOINPUT" {
  run $BIN "${FLAGS[@]}" --dry-run set output "Nonexistent"
  assert_failure
  assert_status 66
}

@test "set with ambiguous match fails with exit 3 and lists candidates" {
  run $BIN "${FLAGS[@]}" --dry-run set output "Jabra"
  assert_failure
  assert_status 3
  assert_has_line "  Jabra Evolve 75 SE"
  assert_has_line "  Jabra SPEAK 510 USB"
}

@test "set can target an excluded device by explicit name" {
  # Q5: `set` honors an explicit excluded target; the menu hides it, the CLI
  # does not get in the way of deliberate choices.
  run $BIN "${FLAGS[@]}" --dry-run set output "Microsoft Teams Audio"
  assert_success
  assert_output_is "output: would set to Microsoft Teams Audio"
}

@test "set --tier picks the best connected device in that tier" {
  # Auto-selection would pick the headset (tier 0); an explicit Speaker pick
  # must resolve within that tier, not fall back to the headset.
  run $BIN "${FLAGS[@]}" --dry-run set output --tier "Speaker"
  assert_success
  assert_output_is "output: would set to Jabra SPEAK 510 USB"
}

@test "set --tier to the current device is a no-op" {
  run $BIN "${FLAGS[@]}" --dry-run set output --tier "Headset"
  assert_success
  assert_output_is "output: already Jabra Evolve 75 SE"
}

@test "set --tier is per direction" {
  run $BIN "${FLAGS[@]}" --dry-run set input --tier "Built-in"
  assert_success
  assert_output_is "input: would set to MacBook Pro Microphone"
}

@test "set --tier with an unknown title fails with EX_USAGE" {
  run $BIN "${FLAGS[@]}" --dry-run set output --tier "Nope"
  assert_failure
  assert_status 64
  assert_line_matches "unknown output tier 'Nope'; available: Headset, Speaker, Built-in"
}

@test "set --tier with no connected device fails with EX_NOINPUT" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-no-headset.json" --dry-run set output --tier "Headset"
  assert_failure
  assert_status 66
}

@test "set --tier rejects a device name" {
  run $BIN "${FLAGS[@]}" --dry-run set output --tier "Headset" "Evolve"
  assert_failure
  assert_status 64
}

@test "cycle advances in visible menu order" {
  # Tier 0 (headsets) is alphabetical: EarPods, Jabra Evolve 75 SE, WH-1000XM2
  # — cycling from Evolve advances to the next tier-0 member, not to the next
  # tier.
  run $BIN "${FLAGS[@]}" --dry-run cycle output
  assert_success
  assert_output_is "output: would cycle to WH-1000XM2"
}

@test "cycle advances within the alphabetical fallback tier" {
  # Visible output order: Evolve (headset) → SPEAK 510 (speaker) → MacBook
  # Pro Speakers (internal) → DELL U3824DW, Generic USB Audio (fallback,
  # alphabetical). The mid-fixture has DELL current → advances to Generic.
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-wrap-mid.json" --dry-run cycle output
  assert_success
  assert_output_is "output: would cycle to Generic USB Audio"
}

@test "cycle wraps from the last visible device to the first" {
  # devices-wrap output visible order: Jabra SPEAK 510 USB → MacBook Pro
  # Speakers → DELL U3824DW → Generic USB Audio (current, last) → wraps to
  # Jabra SPEAK 510 USB (first, highest tier present).
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-wrap.json" --dry-run cycle output
  assert_success
  assert_output_is "output: would cycle to Jabra SPEAK 510 USB"
}

@test "invalid regex in config is fatal (EX_DATAERR)" {
  run $BIN --config "${FIXTURES}/config-invalid.json" --devices "${FIXTURES}/devices.json" menu-text
  assert_failure
  assert_status 65
}

@test "regex matching is case-sensitive: lowercase 'jabra speak' does not hit the speaker tier" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-case.json" menu-text
  assert_success
  # 'jabra speak 510 usb' (lowercase) matches no tier → fallback symbol (it is
  # the current device in this fixture, so the row carries the checkmark; the
  # assertion matches the symbol suffix, mark-agnostic).
  assert_line_matches "jabra speak 510 usb \[speaker\.wave\.3\]$"
  # The uppercase name still matches the SPEAK tier.
  assert_line_matches "Jabra SPEAK 510 USB \(Stereo\) \[hifispeaker\.fill\]$"
}

@test "regex matching is case-sensitive: auto-select falls through a case-mismatched device" {
  # Only the lowercase Jabra name is present — the case-sensitive 'SPEAK 510'
  # tier does not match it, so selection falls through to the internal tier.
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-case-only.json" --dry-run auto
  assert_success
  assert_has_line "output: would set to MacBook Pro Speakers"
  refute_line_matches "would set to jabra speak 510 usb"
}

@test "name matching is unanchored: substring matches anywhere in the name" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-case.json" --dry-run set output "(Stereo)"
  assert_success
  assert_output_is "output: would set to Jabra SPEAK 510 USB (Stereo)"
}

@test "fixture mode refuses real writes without --dry-run (EX_USAGE)" {
  run $BIN "${FLAGS[@]}" set output "MacBook Pro Speakers"
  assert_failure
  assert_status 64
}

@test "fixture with a sound-effects pointer decodes (effects mirror field)" {
  # devices.json carries `defaultSystemOutput`; the remaining fixtures omit it,
  # so the suite covers both decode paths. The mirror itself is write-side and
  # asserted by the unit tests.
  run $BIN "${FLAGS[@]}" current output
  assert_success
  assert_output_is "Jabra Evolve 75 SE"
}

@test "unknown direction exits EX_USAGE" {
  run $BIN "${FLAGS[@]}" current sideways
  assert_failure
  assert_status 64
}

@test "trailing positional arguments exit EX_USAGE" {
  run $BIN "${FLAGS[@]}" list output extra
  assert_failure
  assert_status 64
  run $BIN "${FLAGS[@]}" reapply extra
  assert_failure
  assert_status 64
  run $BIN "${FLAGS[@]}" menu-text extra
  assert_failure
  assert_status 64
}

@test "unknown command exits EX_USAGE" {
  run $BIN "${FLAGS[@]}" frobnicate
  assert_failure
  assert_status 64
}

# ── Camera target ────────────────────────────────────────────────────────────
# The camera fixtures pair the audio table from devices.json with four
# cameras: an external capture card (managed, External tier), a Continuity
# camera (managed, Continuity tier), the built-in FaceTime camera (managed,
# Built-in tier), and an OBS virtual camera (synthetic, never auto-managed).

CAMFLAGS=(--config "${FIXTURES}/config-cameras.json" --devices "${FIXTURES}/devices-cameras.json")

@test "list camera orders tiers and tags the virtual camera" {
  run $BIN "${CAMFLAGS[@]}" list camera
  assert_success
  assert_has_line "camera:"
  assert_has_line "  Elgato Cam Link 4K"
  assert_has_line "  iPhone Continuity Camera"
  assert_has_line "* FaceTime HD Camera"
  assert_has_line "  OBS Virtual Camera [virtual]"
}

@test "list --json camera emits uid, deviceType, and excluded flags" {
  run $BIN "${CAMFLAGS[@]}" --json list camera
  assert_success
  local excluded current devicetype
  excluded="$(jq -r '.camera[] | select(.name == "OBS Virtual Camera") | .excluded' <<<"$output")"
  current="$(jq -r '.camera[] | select(.name == "FaceTime HD Camera") | .current' <<<"$output")"
  devicetype="$(jq -r '.camera[] | select(.name == "FaceTime HD Camera") | .deviceType' <<<"$output")"
  assert_equal "$excluded" "true"
  assert_equal "$current" "true"
  assert_equal "$devicetype" "AVCaptureDeviceTypeBuiltInWideAngleCamera"
}

@test "current camera prints the camera block only" {
  run $BIN "${CAMFLAGS[@]}" current camera
  assert_success
  assert_output_is "FaceTime HD Camera"
}

@test "auto applies the external camera tier" {
  run $BIN "${CAMFLAGS[@]}" --dry-run auto
  assert_success
  assert_has_line "camera: would set to Elgato Cam Link 4K"
}

@test "camera auto skips an excluded current camera" {
  run $BIN --config "${FIXTURES}/config-cameras.json" --devices "${FIXTURES}/devices-cameras-virtual-current.json" --dry-run auto
  assert_success
  assert_has_line "camera: skipped — current 'OBS Virtual Camera' is not managed"
}

@test "set camera by name works with --dry-run" {
  run $BIN "${CAMFLAGS[@]}" --dry-run set camera "iPhone Continuity Camera"
  assert_success
  assert_output_is "camera: would set to iPhone Continuity Camera"
  # Setting the already-current camera is a no-op.
  run $BIN "${CAMFLAGS[@]}" --dry-run set camera "FaceTime HD Camera"
  assert_success
  assert_output_is "camera: already FaceTime HD Camera"
}

@test "set camera --tier resolves within the chosen tier" {
  run $BIN "${CAMFLAGS[@]}" --dry-run set camera --tier "Continuity"
  assert_success
  assert_output_is "camera: would set to iPhone Continuity Camera"
  run $BIN "${CAMFLAGS[@]}" --dry-run set camera --tier "Nope"
  assert_failure
  assert_status 64
  assert_line_matches "unknown camera tier 'Nope'; available: External, Continuity, Built-in"
}

@test "cycle camera wraps through the tier order" {
  # Camera order: Elgato Cam Link 4K → iPhone Continuity Camera → FaceTime HD
  # Camera (current, Built-in tier, last) → wraps to Elgato Cam Link 4K.
  run $BIN "${CAMFLAGS[@]}" --dry-run cycle camera
  assert_success
  assert_output_is "camera: would cycle to Elgato Cam Link 4K"
}

@test "reapply covers the camera target" {
  run $BIN --config "${FIXTURES}/config-cameras.json" --devices "${FIXTURES}/devices-cameras-virtual-current.json" --dry-run reapply
  assert_success
  assert_has_line "camera: would set to Elgato Cam Link 4K"
}

@test "menu-text renders the camera block with its own submenu" {
  run $BIN "${CAMFLAGS[@]}" menu-text
  assert_success
  assert_has_line "status: headphones headphones laptopcomputer"
  assert_has_line "camera-menu:"
  assert_has_line "  · Elgato Cam Link 4K [video]"
  assert_has_line "  · iPhone Continuity Camera [iphone]"
  assert_has_line "  ✓ FaceTime HD Camera [laptopcomputer]"
}

@test "menu-text marks an excluded current camera" {
  run $BIN --config "${FIXTURES}/config-cameras.json" --devices "${FIXTURES}/devices-cameras-virtual-current.json" menu-text
  assert_success
  assert_has_line "status: headphones headphones questionmark.circle"
  assert_has_line "  - Current: OBS Virtual Camera (not managed)"
}

@test "fixture mode refuses real camera writes without --dry-run (EX_USAGE)" {
  run $BIN "${CAMFLAGS[@]}" set camera "FaceTime HD Camera"
  assert_failure
  assert_status 64
}

# ── Prioritization switch ────────────────────────────────────────────────────
# The master switch lives in a runtime state file (not the HM config) so the
# menubar/CLI can toggle it without a rebuild. Missing → enabled; corrupt →
# warning + enabled. An empty tier list is the per-target "not managed" state.

@test "status defaults to enabled and reports per-target managed state" {
  run $BIN --config "${FIXTURES}/config.json" status
  assert_success
  assert_has_line "prioritization: enabled"
  assert_has_line "output: managed (3 tiers)"
  assert_has_line "input: managed (3 tiers)"
  assert_has_line "camera: not managed (0 tiers)"
}

@test "status --json reports the switch and per-target tiers" {
  run $BIN --config "${FIXTURES}/config.json" --json status
  assert_success
  local enabled cameraManaged outputTiers
  enabled="$(jq -r '.enabled' <<<"$output")"
  cameraManaged="$(jq -r '.targets.camera.managed' <<<"$output")"
  outputTiers="$(jq -r '.targets.output.tiers' <<<"$output")"
  assert_equal "$enabled" "true"
  assert_equal "$cameraManaged" "false"
  assert_equal "$outputTiers" "3"
}

@test "status does not compile tier regexes (invalid regex still reports)" {
  # config-invalid.json is valid JSON with an unparseable regex — status must
  # still report the tiers because it never builds the engine.
  run $BIN --config "${FIXTURES}/config-invalid.json" status
  assert_success
  assert_has_line "output: managed (1 tiers)"
}

@test "disable writes the state file and status reflects it" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --state "$state" disable
  assert_success
  assert_output_is "prioritization: disabled"
  jq -e '.prioritizationEnabled == false' "$state" >/dev/null
  run $BIN --state "$state" status
  assert_success
  assert_has_line "prioritization: disabled"
}

@test "enable round-trips back to enabled" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --state "$state" disable
  assert_success
  run $BIN --state "$state" enable
  assert_success
  assert_output_is "prioritization: enabled"
  jq -e '.prioritizationEnabled == true' "$state" >/dev/null
}

@test "corrupt state falls back to enabled" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  printf 'garbage' >"$state"
  run $BIN --state "$state" status
  assert_success
  assert_has_line "prioritization: enabled"
}

@test "reapply and auto respect the disabled switch" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --state "$state" disable
  assert_success
  run $BIN "${CAMFLAGS[@]}" --state "$state" --dry-run reapply
  assert_success
  assert_has_line "output: skipped — prioritization disabled"
  assert_has_line "input: skipped — prioritization disabled"
  assert_has_line "camera: skipped — prioritization disabled"
  run $BIN "${CAMFLAGS[@]}" --state "$state" --dry-run auto
  assert_success
  assert_has_line "camera: skipped — prioritization disabled"
}

@test "manual set and cycle still work while disabled" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --state "$state" disable
  assert_success
  run $BIN "${CAMFLAGS[@]}" --state "$state" --dry-run set camera "iPhone Continuity Camera"
  assert_success
  assert_output_is "camera: would set to iPhone Continuity Camera"
  run $BIN "${CAMFLAGS[@]}" --state "$state" --dry-run cycle camera
  assert_success
  assert_has_line "camera: would cycle to Elgato Cam Link 4K"
}

@test "empty camera tiers are not auto-managed" {
  # config.json has no camera tiers; the cameras fixture is present — the
  # camera target must be reported as not managed, not as "no device found".
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-cameras.json" --dry-run auto
  assert_success
  assert_has_line "camera: not auto-managed (no priority tiers)"
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-cameras.json" --dry-run reapply
  assert_success
  assert_has_line "camera: not auto-managed (no priority tiers)"
}

@test "menu-text renders the prioritization line and pause marker" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN "${CAMFLAGS[@]}" menu-text
  assert_success
  assert_has_line "prioritization: enabled"
  refute_line_matches "pause.circle"
  run $BIN --state "$state" disable
  assert_success
  run $BIN "${CAMFLAGS[@]}" --state "$state" menu-text
  assert_success
  assert_has_line "prioritization: disabled"
  assert_line_matches "^status: .* pause\.circle$"
}

@test "menu-text shows the not-auto-managed row for unmanaged targets" {
  run $BIN --config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-cameras.json" menu-text
  assert_success
  assert_has_line "  - Not auto-managed (no priority tiers)"
}

@test "status with invalid JSON shows the switch and exits 65" {
  run $BIN --config "${FIXTURES}/config-broken.json" status
  assert_failure
  assert_status 65
  assert_has_line "prioritization: enabled"
  assert_has_line "targets: unavailable (invalid config)"
}

@test "enable and disable never load the tier config" {
  # Even a broken config must not prevent toggling the switch.
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --config "${FIXTURES}/config-broken.json" --state "$state" disable
  assert_success
  assert_output_is "prioritization: disabled"
  run $BIN --config "${FIXTURES}/config-broken.json" --state "$state" enable
  assert_success
  assert_output_is "prioritization: enabled"
}

@test "switch commands reject trailing arguments and missing values" {
  local state="${BATS_TEST_TMPDIR}/state.json"
  run $BIN --state "$state" disable extra
  assert_failure
  assert_status 64
  run $BIN --state "$state" status extra
  assert_failure
  assert_status 64
  run $BIN --state
  assert_failure
  assert_status 64
}

@test "config rejects trailing arguments before opening the window" {
  # The usage guard runs before any AppKit call, so this is testable
  # headlessly; the window itself needs a GUI session and is verified
  # manually (see AGENTS.md).
  run $BIN config extra
  assert_failure
  assert_status 64
}

# ── Volume levels (per-device restore) ────────────────────────────────────────
# devices-volumes.json seeds volumes (a seeded direction is volume-capable;
# jabra510 is deliberately unseeded) and model UIDs; defaultOutput is
# jabra510, defaultInput is mic. Every store-touching test passes --levels
# against BATS_TEST_TMPDIR or a fixture, so the live levels.json is never
# written. Restore lines are observed through set/cycle/reapply --dry-run.

VOLFLAGS=(--config "${FIXTURES}/config.json" --devices "${FIXTURES}/devices-volumes.json")

@test "volume get prints the current device level" {
  run $BIN "${VOLFLAGS[@]}" volume get input
  assert_success
  assert_output_is "input: 0.60"
}

@test "volume get on a device without volume control exits 66" {
  run $BIN "${VOLFLAGS[@]}" volume get output
  assert_failure
  assert_status 66
  assert_has_line "Jabra SPEAK 510 USB has no output volume control"
}

@test "volume set updates the level; fixtures require --dry-run" {
  run $BIN "${VOLFLAGS[@]}" --dry-run volume set input 0.7
  assert_success
  assert_output_is "input: would set volume to 0.70"
  run $BIN "${VOLFLAGS[@]}" volume set input 0.7
  assert_failure
  assert_status 64
}

@test "volume save writes the store and show reads it back" {
  local levels="${BATS_TEST_TMPDIR}/levels.json"
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" volume save input
  assert_success
  assert_output_is "input: saved 60% for MacBook Pro Microphone"
  run $BIN --levels "$levels" volume show
  assert_success
  assert_line_matches '^input: 60% MacBook Pro Microphone \(mic, saved '
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" --dry-run volume save input
  assert_success
  assert_output_is "input: would save 60% for MacBook Pro Microphone"
}

@test "volume clear removes the entry and is idempotent" {
  local levels="${BATS_TEST_TMPDIR}/levels.json"
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" volume save input
  assert_success
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" volume clear input
  assert_success
  assert_output_is "input: cleared saved level for MacBook Pro Microphone"
  run $BIN --levels "$levels" volume show
  assert_has_line "input: no saved levels"
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" volume clear input
  assert_success
  assert_output_is "input: no saved level for MacBook Pro Microphone"
}

@test "activating a device restores its exact saved level" {
  run $BIN "${VOLFLAGS[@]}" --levels "${FIXTURES}/levels-exact.json" --dry-run set output "Jabra Evolve 75 SE"
  assert_success
  assert_has_line "output: would set to Jabra Evolve 75 SE"
  assert_has_line "output: would restore saved level 42%"
  run $BIN "${VOLFLAGS[@]}" --levels "${FIXTURES}/levels-exact.json" --dry-run reapply
  assert_success
  # From jabra510 the force-apply picks the alphabetically-first tier-0
  # device (EarPods), which carries its own exact entry.
  assert_has_line "output: would set to EarPods"
  assert_has_line "output: would restore saved level 15%"
}

@test "cycle restores the newly activated device's saved level" {
  # From jabra510 the cycle advances to MacBook Pro Speakers (visible order:
  # tier 0 headsets → tier 1 SPEAK 510 → tier 2 built-in speakers).
  local levels="${BATS_TEST_TMPDIR}/levels-spk.json"
  cat >"$levels" <<'EOF'
{
  "schemaVersion": 1,
  "output": {
    "spk": {
      "uid": "spk",
      "name": "MacBook Pro Speakers",
      "modelUID": "apple-speakers",
      "transport": "builtIn",
      "level": 0.3,
      "savedAt": "2026-01-01T00:00:00Z"
    }
  },
  "input": {}
}
EOF
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" --dry-run cycle output
  assert_success
  assert_has_line "output: would cycle to MacBook Pro Speakers"
  assert_has_line "output: would restore saved level 30%"
}

@test "activating a replacement device restores via the fallback match" {
  # levels-replacement.json holds an entry for a disconnected old unit with
  # the same name + model UID as the connected evolve — the unique match.
  run $BIN "${VOLFLAGS[@]}" --levels "${FIXTURES}/levels-replacement.json" --dry-run set output "Jabra Evolve 75 SE"
  assert_success
  assert_has_line "output: would restore saved level 25% (replacement match)"
}

@test "activating a device without a saved level adds no restore line" {
  local levels="${BATS_TEST_TMPDIR}/nonexistent-levels.json"
  run $BIN "${VOLFLAGS[@]}" --levels "$levels" --dry-run set output "Jabra Evolve 75 SE"
  assert_success
  assert_output_is "output: would set to Jabra Evolve 75 SE"
}

@test "volume rejects bad targets, levels, and trailing arguments" {
  run $BIN "${VOLFLAGS[@]}" volume
  assert_failure
  assert_status 64
  run $BIN "${VOLFLAGS[@]}" volume frob
  assert_failure
  assert_status 64
  run $BIN "${VOLFLAGS[@]}" volume get camera
  assert_failure
  assert_status 64
  run $BIN "${VOLFLAGS[@]}" volume set input 2
  assert_failure
  assert_status 64
  run $BIN "${VOLFLAGS[@]}" volume get input extra
  assert_failure
  assert_status 64
  run $BIN "${VOLFLAGS[@]}" volume get
  assert_failure
  assert_status 64
}

@test "volume show --json emits the raw document" {
  run $BIN --levels "${FIXTURES}/levels-exact.json" --json volume show
  assert_success
  local level
  level="$(jq -r '.output.evolve.level' <<<"$output")"
  assert_equal "$level" "0.42"
}

@test "volume commands never load the tier config" {
  # A broken config must not prevent volume control (same rule as
  # enable/disable/start/stop).
  run $BIN --config "${FIXTURES}/config-broken.json" --devices "${FIXTURES}/devices-volumes.json" volume get input
  assert_success
  assert_output_is "input: 0.60"
}

# ── Lifecycle (start/stop) ────────────────────────────────────────────────────
# The menubar app IS the agent — start/stop control that one process. With the
# HM LaunchAgent installed, KeepAlive resurrects plain exits, so stopping must
# go through launchctl bootout. Every test drives fixture plists/app bundles
# plus --dry-run, so the live agent on this machine is never touched (the
# fixture label `bats.device-priority-sanitizer` is never loaded anywhere).

@test "start plans a launchd bootstrap from the installed plist" {
  run $BIN --launchd-plist "${FIXTURES}/agent.plist" --dry-run start
  assert_success
  assert_output_is "app: would start launchd agent bats.device-priority-sanitizer"
}

@test "stop reports not running when neither the job nor the app is up" {
  run $BIN --launchd-plist "${FIXTURES}/agent.plist" --app-bundle "${FIXTURES}/TestApp.app" --dry-run stop
  assert_success
  assert_output_is "app: not running"
}

@test "start falls back to a manual launch when no plist exists" {
  run $BIN --launchd-plist "${BATS_TEST_TMPDIR}/nonexistent.plist" --app-bundle "${FIXTURES}/TestApp.app" --dry-run start
  assert_success
  assert_line_matches "^app: would launch .*/TestApp\.app$"
}

@test "stop falls back to terminating a manual instance" {
  # The fixture app's bundle id is never registered with LaunchServices, so
  # the row reports "not running" — the terminate plan itself is covered by
  # the unit tests (planAgent).
  run $BIN --launchd-plist "${BATS_TEST_TMPDIR}/nonexistent.plist" --app-bundle "${FIXTURES}/TestApp.app" --dry-run stop
  assert_success
  assert_output_is "app: not running"
}

@test "start and stop reject trailing arguments" {
  run $BIN --launchd-plist "${FIXTURES}/agent.plist" --dry-run start extra
  assert_failure
  assert_status 64
  run $BIN --launchd-plist "${FIXTURES}/agent.plist" --dry-run stop extra
  assert_failure
  assert_status 64
}

@test "--help exits 0" {
  run $BIN --help
  assert_success
  assert_line_matches "^Usage: device-priority-sanitizer"
  assert_has_line "  start                         Start the app (launchd agent when installed, else launch the bundle)"
  assert_has_line "  stop                          Stop the app (boots out the launchd agent; manual instances terminate)"
}
