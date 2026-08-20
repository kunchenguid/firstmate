#!/usr/bin/env bash
# Characterization tests for per-installation backend home-tag derivation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_primary_tag_is_stable_and_readable() {
  local root home first second
  root=$(fm_test_tmproot fm-backend-hometag)
  home="$root/home"
  mkdir -p "$home"
  FM_ROOT="$root" FM_HOME="$home"
  export FM_ROOT FM_HOME
  # shellcheck source=bin/fm-backend-hometag-lib.sh
  . "$ROOT/bin/fm-backend-hometag-lib.sh"

  first=$(fm_backend_hometag)
  second=$(fm_backend_hometag)
  [ "$first" = "$second" ] || fail "primary tag must be stable: $first != $second"
  case "$first" in
    firstmate-????????) ;;
    *) fail "primary tag must use the firstmate-<8-char-hash> format: $first" ;;
  esac
  pass "hometag-lib: primary tags are stable and readable"
}

test_secondmate_marker_changes_tag_prefix() {
  local root home tag
  root=$(fm_test_tmproot fm-backend-hometag)
  home="$root/home"
  mkdir -p "$home"
  printf '%s\n' crew-17 > "$home/.fm-secondmate-home"
  FM_ROOT="$root" FM_HOME="$home"
  export FM_ROOT FM_HOME
  # shellcheck source=bin/fm-backend-hometag-lib.sh
  . "$ROOT/bin/fm-backend-hometag-lib.sh"

  tag=$(fm_backend_hometag)
  case "$tag" in
    2ndmate-crew-17-????????) ;;
    *) fail "secondmate tag must include its marker id and an 8-char hash: $tag" ;;
  esac
  pass "hometag-lib: secondmate marker selects a scoped tag prefix"
}

test_primary_tag_is_stable_and_readable
test_secondmate_marker_changes_tag_prefix
