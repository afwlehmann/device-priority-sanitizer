#!/usr/bin/env bash
# shellcheck disable=SC2154 # $status/$output are set by bats' `run` helper
# Test helper for device-priority-sanitizer/test/cli.bats — sourced by bats,
# exposes assertion functions only. No `set -euo pipefail` here: bats owns the
# shell options for each test, and forcing errexit in a sourced helper changes
# `run`-based failure handling. Library guard per the shell-scripting skill.
[ -n "${DEVICE_PRIORITY_TEST_HELPER:-}" ] && return 0
DEVICE_PRIORITY_TEST_HELPER=1

assert_success() {
  if [ "$status" -ne 0 ]; then
    printf 'expected exit 0, got %s\noutput:\n%s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_failure() {
  if [ "$status" -eq 0 ]; then
    printf 'expected non-zero exit, got 0\noutput:\n%s\n' "$output" >&2
    return 1
  fi
}

assert_status() {
  if [ "$status" -ne "$1" ]; then
    printf 'expected exit %s, got %s\noutput:\n%s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}

assert_output_is() {
  if [ "$output" != "$1" ]; then
    printf 'expected output:\n%s\ngot:\n%s\n' "$1" "$output" >&2
    return 1
  fi
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected:\n%s\ngot:\n%s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_has_line() {
  local needle="$1"
  local line
  while IFS= read -r line; do
    if [ "$line" = "$needle" ]; then
      return 0
    fi
  done <<<"$output"
  printf 'expected line: %s\nactual output:\n%s\n' "$needle" "$output" >&2
  return 1
}

assert_line_matches() {
  local pattern="$1"
  if ! grep -Eq "$pattern" <<<"$output"; then
    printf 'expected a line matching: %s\nactual output:\n%s\n' "$pattern" "$output" >&2
    return 1
  fi
}

refute_line_matches() {
  local pattern="$1"
  if grep -Eq "$pattern" <<<"$output"; then
    printf 'did not expect a line matching: %s\nactual output:\n%s\n' "$pattern" "$output" >&2
    return 1
  fi
}
