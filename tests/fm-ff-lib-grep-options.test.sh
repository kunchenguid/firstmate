#!/usr/bin/env bash
# tests/fm-ff-lib-grep-options.test.sh - the captain's machine exports
# GREP_OPTIONS=--color=always, which wraps every grep stdout line in ANSI
# escapes. bin/fm-ff-lib.sh's live_secondmate_meta_records() extracts the
# home= field with `grep '^home=' | cut -d= -f2-`, so without a guard that
# trap hands validate_secondmate_home an escape-wrapped path it then refuses
# as "not a directory". This pins that the emitted record is clean even when
# the trap is live in the environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_live_secondmate_meta_records_strips_grep_options_color() {
  local dir state registry out home_field
  dir=$(fm_test_tmproot fm-ff-lib-grep-options)
  state="$dir/state"
  registry="$dir/secondmates.md"
  mkdir -p "$state"
  home_field="$dir/homes/adminsite"
  mkdir -p "$home_field"

  printf 'kind=secondmate\nhome=%s\nwindow=42\n' "$home_field" > "$state/adminsite.meta"
  : > "$registry"

  out=$(GREP_OPTIONS='--color=always' bash -c '
    . "$1"
    live_secondmate_meta_records "$2" "$3"
  ' _ "$ROOT/bin/fm-ff-lib.sh" "$state" "$registry") || fail "live_secondmate_meta_records failed"

  case "$out" in
    *$'\e'*) fail "emitted record contains an ESC byte under GREP_OPTIONS=--color=always: $(printf '%q' "$out")" ;;
  esac

  local got_home
  got_home=$(printf '%s\n' "$out" | awk -F'|' '{print $2}')
  [ "$got_home" = "$home_field" ] \
    || fail "home field does not match the fixture exactly: got [$got_home] want [$home_field]"

  pass "live_secondmate_meta_records emits a clean home path under the GREP_OPTIONS color trap"
}

test_live_secondmate_meta_records_strips_grep_options_color
