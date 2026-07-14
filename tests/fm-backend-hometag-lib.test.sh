#!/usr/bin/env bash
# tests/fm-backend-hometag-lib.test.sh - the shared per-home tag derivation
# (bin/fm-backend-hometag-lib.sh), the ONE owner of the home label that cmux's
# and zellij's tab titles and herdr's workspace label all delegate to.
#
# The load-bearing contract:
#   1. BOTH halves of the tag - the readable prefix (from the home's
#      .fm-secondmate-home marker) and the path hash - are derived from the
#      SAME home, $FM_HOME. A cross-home invocation (FM_HOME naming one home
#      while another home's bin/ runs the operation, which the FM_HOME contract
#      permits) must therefore still yield a tag whose prefix and hash agree on
#      one home; hashing $FM_ROOT there used to mint a third label that neither
#      home's find/list_live could ever match.
#   2. In a well-formed home FM_HOME and FM_ROOT are the same path, so the tag
#      is byte-identical to the FM_ROOT-hashed derivation for every existing
#      installation - the fix is a no-op in normal use.
#   3. Two independent primary homes never collide; a secondmate home carries
#      its own id in the prefix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hometag-lib-tests)

# hometag <home> [root]: the tag the lib derives for <home>, with $FM_ROOT set
# to [root] (default: the firstmate repo root, i.e. the cross-home shape where
# the scripts are sourced from a DIFFERENT root than the home being operated
# on). Sourced in a subshell so each case gets a clean environment.
hometag() {  # <home> [root]
  local home=$1 root=${2:-$ROOT}
  ( FM_HOME="$home"; FM_ROOT="$root"; . "$ROOT/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag )
}

# path_hash <path>: the same short hash the lib computes, reimplemented in
# bash so expectations are not path-dependent hardcodes.
path_hash() {  # <path>
  local real
  real=$(cd "$1" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

# --- the cross-home regression: prefix and hash must name the SAME home -------

test_cross_home_prefix_and_hash_agree_for_a_secondmate() {
  local home other out
  home="$TMP_ROOT/cross-home-secondmate"; mkdir -p "$home"
  printf 'sshhip-h7\n' > "$home/.fm-secondmate-home"
  other="$TMP_ROOT/cross-home-other-root"; mkdir -p "$other"
  # FM_HOME names the secondmate home; FM_ROOT names a DIFFERENT installation,
  # as it does whenever one home's operation runs through another repo's bin/.
  out=$(hometag "$home" "$other")
  [ "$out" = "2ndmate-sshhip-h7-$(path_hash "$home")" ] \
    || fail "a cross-home invocation must hash the home FM_HOME names, got '$out'"
  [ "$out" != "2ndmate-sshhip-h7-$(path_hash "$other")" ] \
    || fail "the tag must not carry the FM_ROOT installation's hash under a secondmate prefix"
  pass "fm_backend_hometag: a cross-home invocation's prefix and hash both name FM_HOME's home"
}

test_cross_home_tag_matches_the_home_running_its_own_bin() {
  local home other from_other from_own
  home="$TMP_ROOT/cross-home-match"; mkdir -p "$home"
  other="$TMP_ROOT/cross-home-match-other"; mkdir -p "$other"
  # The same home, operated on through ANOTHER home's bin/ (FM_ROOT=$other) and
  # through its own (FM_ROOT=$home), must resolve to ONE tag - otherwise the
  # tab the first mints is one neither home's find/list_live can ever match.
  from_other=$(hometag "$home" "$other")
  from_own=$(hometag "$home" "$home")
  [ "$from_other" = "$from_own" ] \
    || fail "one home must resolve to one tag whichever bin/ runs the operation ('$from_other' vs '$from_own')"
  pass "fm_backend_hometag: a home resolves to the same tag whichever installation's bin/ derives it"
}

# --- the no-op-in-normal-use property ----------------------------------------

test_wellformed_home_hashes_its_own_path() {
  local home out
  home="$TMP_ROOT/wellformed-primary"; mkdir -p "$home"
  # A well-formed home: FM_HOME and FM_ROOT are the same path (the home IS the
  # repo root). This is every real installation, and its tag is unchanged from
  # the earlier FM_ROOT-hashed derivation.
  out=$(hometag "$home" "$home")
  [ "$out" = "firstmate-$(path_hash "$home")" ] \
    || fail "a well-formed primary home should resolve to 'firstmate-<own-path-hash>', got '$out'"
  pass "fm_backend_hometag: a well-formed home (FM_HOME = FM_ROOT) hashes its own path, unchanged"
}

test_absent_fm_home_falls_back_to_fm_root() {
  local root out
  root="$TMP_ROOT/fallback-root"; mkdir -p "$root"
  out=$( FM_HOME='' FM_ROOT="$root" bash -c '. "$0/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag' "$ROOT" )
  [ "$out" = "firstmate-$(path_hash "$root")" ] \
    || fail "an unset FM_HOME should fall back to FM_ROOT, got '$out'"
  pass "fm_backend_hometag: an empty FM_HOME falls back to FM_ROOT for both prefix and hash"
}

# --- prefix/collision basics --------------------------------------------------

test_two_primary_homes_get_distinct_tags() {
  local one two out_one out_two
  one="$TMP_ROOT/primary-one"; mkdir -p "$one"
  two="$TMP_ROOT/primary-two"; mkdir -p "$two"
  out_one=$(hometag "$one" "$one")
  out_two=$(hometag "$two" "$two")
  case "$out_one" in firstmate-*) : ;; *) fail "primary home one should resolve to 'firstmate-<hash>', got '$out_one'" ;; esac
  case "$out_two" in firstmate-*) : ;; *) fail "primary home two should resolve to 'firstmate-<hash>', got '$out_two'" ;; esac
  [ "$out_one" != "$out_two" ] \
    || fail "two independent primary homes must not collapse into one tag (got identical '$out_one')"
  pass "fm_backend_hometag: two independent primary homes get two distinct firstmate-<hash> tags"
}

test_secondmate_marker_drives_the_prefix() {
  local home out
  home="$TMP_ROOT/marker-prefix"; mkdir -p "$home"
  printf '  alpha-a1  \n\n' > "$home/.fm-secondmate-home"
  out=$(hometag "$home" "$home")
  [ "$out" = "2ndmate-alpha-a1-$(path_hash "$home")" ] \
    || fail "a secondmate home should resolve to '2ndmate-<id>-<hash>' with the id trimmed, got '$out'"
  : > "$home/.fm-secondmate-home"
  out=$(hometag "$home" "$home")
  [ "$out" = "firstmate-$(path_hash "$home")" ] \
    || fail "an empty marker should fall back to the primary prefix, got '$out'"
  pass "fm_backend_hometag: the .fm-secondmate-home marker drives the prefix and empty falls back to primary"
}

test_cross_home_prefix_and_hash_agree_for_a_secondmate
test_cross_home_tag_matches_the_home_running_its_own_bin
test_wellformed_home_hashes_its_own_path
test_absent_fm_home_falls_back_to_fm_root
test_two_primary_homes_get_distinct_tags
test_secondmate_marker_drives_the_prefix

echo "all fm-backend-hometag-lib tests passed"
