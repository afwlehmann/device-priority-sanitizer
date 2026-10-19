#!/usr/bin/env bats
# bats require_minimum_version 1.7.0
# shellcheck disable=SC2034 # BIN is supplied by the flake check and used across tests

# Tests for the audio-priority-sanitizer CLI, run headlessly against
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
  assert_has_line "status: questionmark.circle questionmark.circle"
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

@test "--help exits 0" {
  run $BIN --help
  assert_success
  assert_line_matches "^Usage: audio-priority-sanitizer"
}
