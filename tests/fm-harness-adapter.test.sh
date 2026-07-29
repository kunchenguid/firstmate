#!/usr/bin/env bash
# tests/fm-harness-adapter.test.sh - harness-interface extraction conformance
# (data/harness-interface-build/design.md; phase-1 inventory in
# data/harness-interface-phase1/report.md).
#
# bin/fm-harness-adapter.sh and bin/harnesses/<name>.sh move the per-harness busy
# signature that bin/fm-tmux-lib.sh used to own onto the harness axis. That table
# is the most-consumed harness fact in the system - 8 call sites across 5 files -
# and it lived in a BACKEND-named library that three non-tmux consumers had to
# source purely to read it. This suite:
#
#   1. Unit-tests the registry: the two deliberately different name sets, the
#      pi-signed alias, and adapter sourcing.
#   2. Runs the PRE-REFACTOR fm_busy_lines_match (extracted from the merge-base
#      with `main`, the commit this branch started from) and the REFACTORED
#      fm_harness_busy_match against the SAME capture corpus, and diffs the two
#      verdict logs byte-for-byte - the design's byte-identical gate. Old and new
#      run in separate processes because they define colliding function names.
#   3. Asserts the resolved regex STRING is byte-identical old vs new for every
#      harness name, the empty name, and an unregistered name.
#   4. Asserts the safety properties the move must not lose: an unregistered
#      harness never borrows another harness's signature, and FM_BUSY_REGEX still
#      overrides everything.
#
# Scope note: this suite proves the PLUMBING is byte-identical - that the moved
# signatures resolve and match exactly as before. It deliberately does not
# re-verify each signature against a live TUI, because this change does not touch
# any signature's content; that empirical basis is owned by
# .agents/skills/harness-adapters/SKILL.md and its per-harness verification dates.
# A real-tmux end-to-end check of the capture -> adapter -> verdict path is
# recorded as manual evidence on the pull request.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-harness-adapter.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-tests)

BASE_REF=$(fm_test_base_ref) \
  || fail "harness-adapter baseline requires local main or origin/main; fetch the default branch before running this test"

# Every harness name the dispatcher accepts, plus the two boundary inputs the
# old case statement handled explicitly: '' (no recorded harness -> the shared
# fallback) and an unregistered name (-> no signature at all).
HARNESS_INPUTS=(claude codex opencode pi pi-signed grok kimi '' nosuch-harness)

# --- shared: a pre-refactor busy matcher ------------------------------------
#
# build_old_lib echoes a directory holding BASE_REF's bin/fm-tmux-lib.sh plus the
# siblings it sources, so the PRE-refactor fm_busy_lines_match can be sourced and
# run exactly as it was. Copies (not symlinks) keep BASH_SOURCE-based sibling
# resolution inside the synthetic tree on both macOS and Linux.
OLD_LIB_SIBLINGS="fm-composer-lib.sh"

build_old_lib() {  # -> echoes dir containing the pre-refactor fm-tmux-lib.sh
  local dir="$TMP_ROOT/old-lib" f
  mkdir -p "$dir"
  for f in $OLD_LIB_SIBLINGS; do
    cp "$ROOT/bin/$f" "$dir/$f"
  done
  git -C "$ROOT" show "$BASE_REF:bin/fm-tmux-lib.sh" > "$dir/fm-tmux-lib.sh"
  printf '%s\n' "$dir"
}

# The capture corpus: one real busy shape per harness, the cross-harness leak
# cases the signatures must NOT match, and idle shapes. Tab-separated
# "label<TAB>line" so a line's own spacing is preserved verbatim.
corpus_lines() {
  printf '%s\n' \
    $'claude-esc\t✻ Thinking… (12s · esc to interrupt)' \
    $'claude-elapsed\t✻ Herding… (3m ↑ 1.2k tokens)' \
    $'codex-esc\tesc to interrupt' \
    $'opencode-esc\tesc interrupt' \
    $'pi-working\tWorking...' \
    $'grok-cancel\tCtrl+c:cancel' \
    $'kimi-spinner\t  🌑 · Tip: ask Kimi to schedule tasks' \
    $'kimi-no-middot\t  🌑 Tip: ask Kimi to schedule tasks' \
    $'kimi-idle-label\tauto  K2.7 Coding thinking  /some/path' \
    $'idle-composer\t│ > │' \
    $'blank\t' \
    $'plain-moon\tthe 🌑 emoji in ordinary prose'
}

# Run one side's matcher over the whole corpus and print "harness/label=verdict"
# lines. OLD_LIB set -> source BASE_REF's fm-tmux-lib.sh and call
# fm_busy_lines_match; unset -> source the refactored adapter and call
# fm_harness_busy_match.
run_matcher_side() {  # <side: old|new> <out-file>
  local side=$1 out=$2 old_lib=""
  [ "$side" = old ] && old_lib=$(build_old_lib)
  # shellcheck disable=SC2016  # single quotes are deliberate: this body must expand
  # inside the child shell, which is what keeps the old and new matchers in separate
  # processes so their colliding function names cannot overwrite each other.
  env -u FM_BUSY_REGEX FM_SIDE="$side" FM_OLD_LIB="$old_lib" FM_ROOT_DIR="$ROOT" \
    bash -c '
      set -u
      if [ "$FM_SIDE" = old ]; then
        . "$FM_OLD_LIB/fm-tmux-lib.sh"
        match() { fm_busy_lines_match "$1"; }
      else
        . "$FM_ROOT_DIR/bin/fm-harness-adapter.sh"
        match() { fm_harness_busy_match "$1"; }
      fi
      while IFS="	" read -r label line; do
        for h in claude codex opencode pi pi-signed grok kimi "" nosuch-harness; do
          if printf "%s" "$line" | match "$h" >/dev/null 2>&1; then
            printf "%s/%s=busy\n" "${h:-EMPTY}" "$label"
          else
            printf "%s/%s=idle\n" "${h:-EMPTY}" "$label"
          fi
        done
      done
    ' > "$out"
}

# --- registry unit tests ----------------------------------------------------

test_registry_two_name_sets() {
  local h
  for h in claude codex opencode pi pi-signed grok kimi; do
    fm_harness_is_known "$h" || fail "fm_harness_is_known rejected verified harness '$h'"
  done
  for h in nosuch '' 'claude codex' pi-unsigned; do
    fm_harness_is_known "$h" && fail "fm_harness_is_known accepted non-harness '$h'"
  done

  # The primary set is strictly narrower, and kimi is the difference. Collapsing
  # the two sets would silently promote kimi to a supported primary harness and
  # contradict README.md's Requirements.
  for h in claude codex opencode pi pi-signed grok; do
    fm_harness_is_primary "$h" || fail "fm_harness_is_primary rejected primary harness '$h'"
  done
  fm_harness_is_primary kimi \
    && fail "kimi must NOT be a primary harness: README.md lists six, and docs/supervision-protocols/ has no kimi.md"
  fm_harness_is_known kimi \
    || fail "kimi must stay a verified CREWMATE harness even though it is not a primary one"

  pass "harness registry: the crewmate set and the narrower primary set stay distinct"
}

test_pi_signed_alias_resolves_once() {
  local name
  name=$(fm_harness_adapter_name pi-signed) || fail "fm_harness_adapter_name rejected pi-signed"
  [ "$name" = pi ] || fail "pi-signed must resolve to the pi adapter, got '$name'"
  name=$(fm_harness_adapter_name pi) || fail "fm_harness_adapter_name rejected pi"
  [ "$name" = pi ] || fail "pi must resolve to the pi adapter, got '$name'"
  fm_harness_adapter_name nosuch >/dev/null 2>&1 \
    && fail "fm_harness_adapter_name must reject an unregistered harness"

  [ "$(fm_harness_busy_regex pi)" = "$(fm_harness_busy_regex pi-signed)" ] \
    || fail "pi and pi-signed must resolve to one signature through the shared adapter"

  pass "harness registry: pi-signed resolves to pi once, so call sites drop their own alias arms"
}

test_every_known_harness_has_a_sourceable_adapter() {
  local h regex
  for h in claude codex opencode pi pi-signed grok kimi; do
    fm_harness_source "$h" || fail "fm_harness_source failed for verified harness '$h'"
    regex=$(fm_harness_busy_regex "$h")
    [ -n "$regex" ] || fail "harness '$h' resolved an EMPTY busy signature; every verified harness must carry one"
  done
  fm_harness_source nosuch 2>/dev/null \
    && fail "fm_harness_source must refuse an unregistered harness rather than sourcing an arbitrary path"

  pass "harness registry: every verified harness has a sourceable adapter with a non-empty signature"
}

# --- old vs new: the byte-identical gate ------------------------------------

test_busy_regex_strings_are_byte_identical() {
  local old_lib h old_val new_val old_out new_out
  old_lib=$(build_old_lib)
  old_out="$TMP_ROOT/regex-old.txt"; new_out="$TMP_ROOT/regex-new.txt"
  : > "$old_out"; : > "$new_out"

  for h in "${HARNESS_INPUTS[@]}"; do
    # shellcheck disable=SC2016  # single quotes are deliberate: the pre-refactor
    # constants must be read inside the child shell that sourced BASE_REF's library.
    old_val=$(env -u FM_BUSY_REGEX FM_OLD_LIB="$old_lib" FM_H="$h" bash -c '
      set -u
      . "$FM_OLD_LIB/fm-tmux-lib.sh"
      case "$FM_H" in
        claude) printf "%s" "$FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT" ;;
        codex) printf "%s" "$FM_TMUX_CODEX_BUSY_REGEX_DEFAULT" ;;
        opencode) printf "%s" "$FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT" ;;
        pi|pi-signed) printf "%s" "$FM_TMUX_PI_BUSY_REGEX_DEFAULT" ;;
        grok) printf "%s" "$FM_TMUX_GROK_BUSY_REGEX_DEFAULT" ;;
        kimi) printf "%s" "$FM_TMUX_KIMI_BUSY_REGEX_DEFAULT" ;;
        "") printf "%s" "$FM_TMUX_BUSY_REGEX_DEFAULT" ;;
        *) printf "" ;;
      esac')
    new_val=$(fm_harness_busy_regex "$h")
    printf '%s=%s\n' "${h:-EMPTY}" "$old_val" >> "$old_out"
    printf '%s=%s\n' "${h:-EMPTY}" "$new_val" >> "$new_out"
  done

  diff -u "$old_out" "$new_out" > "$TMP_ROOT/regex-diff.txt" 2>&1 \
    || fail "busy signature strings differ old vs new"$'\n'"$(cat "$TMP_ROOT/regex-diff.txt")"

  pass "busy signatures: every harness's regex string is byte-identical to the pre-refactor constant"
}

test_busy_verdicts_are_byte_identical_old_vs_new() {
  local old_out new_out
  old_out="$TMP_ROOT/verdicts-old.txt"; new_out="$TMP_ROOT/verdicts-new.txt"
  corpus_lines | run_matcher_side old "$old_out"
  corpus_lines | run_matcher_side new "$new_out"

  [ -s "$old_out" ] || fail "the pre-refactor matcher produced no verdicts; the baseline fixture is broken"
  [ "$(wc -l < "$old_out")" -eq "$(wc -l < "$new_out")" ] \
    || fail "old and new verdict logs have different lengths"

  diff -u "$old_out" "$new_out" > "$TMP_ROOT/verdicts-diff.txt" 2>&1 \
    || fail "busy verdicts differ old vs new"$'\n'"$(cat "$TMP_ROOT/verdicts-diff.txt")"

  # Guard against a tautological pass: the corpus must actually exercise both
  # verdicts, or an all-idle log would diff clean and prove nothing.
  assert_contains "$(cat "$new_out")" '=busy' "the corpus never produced a busy verdict"
  assert_contains "$(cat "$new_out")" '=idle' "the corpus never produced an idle verdict"

  pass "busy verdicts: $(wc -l < "$new_out" | tr -d ' ') harness/capture pairs classify identically old vs new"
}

# --- safety properties the move must not lose -------------------------------

test_unregistered_harness_never_borrows_a_signature() {
  local line
  [ -z "$(fm_harness_busy_regex nosuch-harness)" ] \
    || fail "an unregistered harness must resolve an EMPTY signature, never another harness's"

  while IFS= read -r line; do
    printf '%s' "${line#*	}" | fm_harness_busy_match nosuch-harness \
      && fail "an unregistered harness was classified busy by output: ${line%%	*}"
  done < <(corpus_lines)

  pass "safety: an unregistered harness is never classified busy by borrowing a verified signature"
}

test_scoped_signatures_do_not_leak_across_harnesses() {
  # Claude's ellipsis-plus-elapsed shape and Kimi's moon spinner are the two
  # signatures deliberately kept OUT of the shared fallback, because neither is
  # safe to run against an unidentified agent's output.
  printf '%s' '✻ Herding… (3m ↑ 1.2k tokens)' | fm_harness_busy_match claude \
    || fail "claude's ellipsis-plus-elapsed spinner must read busy for a claude task"
  printf '%s' '✻ Herding… (3m ↑ 1.2k tokens)' | fm_harness_busy_match '' \
    && fail "claude's scoped spinner must NOT match the shared no-harness fallback"

  printf '%s' '  🌑 · Tip: ask Kimi to schedule tasks' | fm_harness_busy_match kimi \
    || fail "kimi's moon-plus-middot spinner must read busy for a kimi task"
  printf '%s' '  🌑 · Tip: ask Kimi to schedule tasks' | fm_harness_busy_match codex \
    && fail "kimi's spinner leaked into another harness's matcher"
  printf '%s' '  🌑 · Tip: ask Kimi to schedule tasks' | fm_harness_busy_match '' \
    && fail "kimi's scoped spinner must NOT match the shared no-harness fallback"

  pass "safety: claude's and kimi's scoped signatures stay out of the shared fallback"
}

test_global_busy_regex_override_still_wins() {
  printf '%s' 'TOTALLY CUSTOM MARKER' | FM_BUSY_REGEX='custom marker' fm_harness_busy_match claude \
    || fail "FM_BUSY_REGEX must override a harness's own signature"
  printf '%s' 'esc to interrupt' | FM_BUSY_REGEX='custom marker' fm_harness_busy_match claude \
    && fail "FM_BUSY_REGEX must REPLACE the harness signature, not union with it"
  # The override must reach even an unregistered harness, which otherwise has no
  # signature at all - this is how FM_BUSY_REGEX rescues an unverified adapter.
  printf '%s' 'TOTALLY CUSTOM MARKER' | FM_BUSY_REGEX='custom marker' fm_harness_busy_match nosuch-harness \
    || fail "FM_BUSY_REGEX must apply even when no adapter signature exists"

  pass "safety: FM_BUSY_REGEX still overrides every per-harness signature"
}

test_registry_two_name_sets
test_pi_signed_alias_resolves_once
test_every_known_harness_has_a_sourceable_adapter
test_busy_regex_strings_are_byte_identical
test_busy_verdicts_are_byte_identical_old_vs_new
test_unregistered_harness_never_borrows_a_signature
test_scoped_signatures_do_not_leak_across_harnesses
test_global_busy_regex_override_still_wins

printf 'all fm-harness-adapter tests passed\n'
