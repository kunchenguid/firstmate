#!/usr/bin/env bash
# The net that keeps the suites off the captain's live multiplexers.
#
# WHY THIS EXISTS. Both guards were added after the accident they prevent had
# already happened: test runs reached the real herdr server and left stray
# `design-home`, `spawn-proj` and `alpha` workspaces behind, and an early cut of
# gate h3 drove the real tmux server and left `firstmate:fm-fallback-t8` in the
# captain's live session. Those were creates - clutter someone notices and
# tidies. The tmux half guards something that does not come back: the cutover
# deliberately keeps the drain paths open, so `tmux kill-window` is a live call
# site, and the panes it can close are exactly the pre-cutover crewmates that may
# still be holding unlanded commits.
#
# A guard nothing exercises is a guard that rots. What is gated here:
#   * sourcing tests/lib.sh puts a refusing `herdr` AND a refusing `tmux` first
#     on PATH, so a suite that forgot to fake one fails loudly instead of
#     silently touching the fleet
#   * each opt-out is INDEPENDENT - a gate that needs the real herdr does not
#     thereby get the real tmux, and vice versa
#   * the opt-in is not a blank cheque: the real tmux is reached through a guard
#     that refuses a destructive verb aimed outside the throwaway session the
#     suite declared, and refuses it outright when none is declared
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/denybin/live-tmux/tmux"

# Run a snippet in a fresh bash that sources tests/lib.sh, with the named
# opt-ins pre-set. A subshell would inherit this file's own already-shimmed
# PATH, which would prove nothing about what sourcing does.
in_fresh() {  # <env-assignments...> -- <snippet>
  local envs=() snippet
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  snippet=$1
  # $1/$@ are bash -c's own positionals, expanded by the inner shell - intentional.
  # shellcheck disable=SC2016
  env -u FM_TEST_ALLOW_LIVE_HERDR -u FM_TEST_ALLOW_LIVE_TMUX \
      -u FM_TEST_LIVE_TMUX_SESSION "${envs[@]}" \
      bash -c '. "$1/tests/lib.sh" >/dev/null 2>&1; shift; eval "$@"' \
      _ "$ROOT" "$snippet" 2>&1
}

# --- the net is opt-in by SOURCING, so who is outside it must be visible -----
#
# THE DEFECT THIS EXISTS FOR. Every guarantee below arrives by sourcing
# tests/lib.sh, so a suite that rolls its own ROOT/fail/pass is simply outside
# the net - silently, with nothing to notice it. That is not hypothetical: the
# captain digest suite sat outside while the same branch taught the digest to
# shell out to `herdr agent list`, `herdr tab list` and `tmux list-windows`, so
# every run of it queried the captain's live servers and its output depended on
# whichever crew happened to be up.
#
# The rule, enforced rather than hoped for: a suite is either UNDER the net (it
# sources tests/lib.sh, directly or through a helper that does) or it DECLARES
# that it is not, with a `# HERMETICITY-WAIVER:` line saying why. A waiver is
# for a suite whose subject IS a real server it creates and destroys itself; it
# is greppable, so the exemptions are a list someone can read and shrink rather
# than an absence nobody can see.
#
# "through a helper that does" is FOLLOWED, not assumed. Accepting any sourced
# helper as proof would make this check vacuous one helper from now: a
# `tests/foo-helpers.sh` that never reaches lib.sh would mark every suite
# sourcing it as guarded while those suites queried the captain's live servers
# - the fails-open direction, in the gate whose whole job is to close it. So
# the chain is walked to lib.sh, which is where it terminates because lib.sh IS
# the net.
reaches_the_net() {  # <file> [<depth>]
  local file=$1 depth=${2:-0} dir helper
  [ "$depth" -lt 8 ] || return 1          # a source cycle is not proof
  [ -f "$file" ] || return 1
  [ "$(basename "$file")" = lib.sh ] && return 0
  dir=$(dirname "$file")
  while read -r helper; do
    [ -n "$helper" ] || continue
    reaches_the_net "$dir/$helper" "$((depth + 1))" && return 0
  done < <(sed -nE 's/^\. "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)\/([A-Za-z0-9._-]+\.sh)".*/\1/p' "$file")
  return 1
}

test_every_suite_is_under_the_net_or_declares_that_it_is_not() {
  local f base unguarded=()
  for f in "$ROOT"/tests/*.test.sh; do
    base=$(basename "$f")
    reaches_the_net "$f" && continue
    grep -q '^# HERMETICITY-WAIVER:' "$f" && continue
    unguarded+=("$base")
  done
  [ "${#unguarded[@]}" -eq 0 ] || fail \
    "these suites neither source tests/lib.sh nor declare a HERMETICITY-WAIVER, so they can reach the captain's live servers unnoticed: ${unguarded[*]}"
  pass "hermeticity: every suite reaches tests/lib.sh through its own source chain, or declares in-file why it does not"
}

# The check above is only worth having if it actually FOLLOWS the chain, so the
# walker is exercised against a helper that sources nothing. Before this, such a
# helper read as proof of guarding for every suite that sourced it.
# shellcheck disable=SC2016  # the source lines below are written out verbatim, not expanded
test_a_helper_that_never_reaches_lib_is_not_proof() {
  local sandbox
  sandbox=$(fm_test_tmproot fm-herm-chain)
  printf '%s\n' '# a helper that reaches nothing' > "$sandbox/orphan-helpers.sh"
  printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/orphan-helpers.sh"' > "$sandbox/a.test.sh"
  reaches_the_net "$sandbox/a.test.sh" \
    && fail "a suite sourcing a helper that never reaches lib.sh was accepted as guarded"

  # ... and a helper that DOES reach it, two hops out, still counts.
  cp "$ROOT/tests/lib.sh" "$sandbox/lib.sh"
  printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"' > "$sandbox/mid-helpers.sh"
  printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/mid-helpers.sh"' > "$sandbox/b.test.sh"
  reaches_the_net "$sandbox/b.test.sh" \
    || fail "a suite reaching lib.sh through two helpers was reported unguarded"
  pass "hermeticity: the under-the-net check follows the source chain rather than trusting its first hop"
}

# A waiver must not become a way to opt out of thinking. Each one has to say
# what it is exempt FOR, so the list stays reviewable and shrinkable.
test_every_waiver_states_a_reason() {
  local f base line
  while IFS= read -r f; do
    base=$(basename "$f")
    line=$(grep -m1 '^# HERMETICITY-WAIVER:' "$f")
    [ "${#line}" -gt 40 ] || fail "$base carries a bare HERMETICITY-WAIVER with no reason"
  done < <(grep -rl '^# HERMETICITY-WAIVER:' "$ROOT"/tests/*.test.sh)
  pass "hermeticity: every waiver names the real server it is exempt for"
}

# --- the fixtures themselves have to do what they claim ---------------------
#
# THE DEFECT THIS EXISTS FOR. Every suite in tests/ opens with
# `TMP_ROOT=$(fm_test_tmproot ...)`, and a command substitution is a SUBSHELL.
# A version of that helper which installed its own EXIT trap on first use
# installed it inside that subshell, so the trap fired as the substitution
# closed and deleted the directory it had just handed back. The caller silently
# re-created the path with mkdir -p, nothing was ever registered in the parent,
# and every suite leaked its temp root on every run - the precise accumulation
# the helper was written to prevent, passing green the whole time because a
# leak is invisible from inside the suite that causes it. Both halves are
# pinned here: the directory must still exist to the caller, and it must be
# gone once the shell that made it has exited.
test_the_temp_root_survives_a_subshell_and_is_cleaned_on_exit() {
  local path
  # shellcheck disable=SC2016  # the snippet is evaluated in the fresh shell, not here
  path=$(in_fresh -- '
    p=$(fm_test_tmproot fm-herm-probe)
    [ -d "$p" ] || { echo "GONE-TOO-EARLY"; exit 1; }
    printf "%s\n" "$p"')
  case "$path" in
    GONE-TOO-EARLY*) fail "fm_test_tmproot deleted its own directory as the command substitution closed" ;;
    /*) : ;;
    *) fail "fm_test_tmproot returned no usable path: $path" ;;
  esac
  [ -e "$path" ] && fail "the temp root outlived the shell that created it, so every suite leaks one per run: $path"
  pass "fixtures: a temp root taken with \$( ) is usable by the caller and removed when the suite exits"
}

# --- the default: neither binary is reachable -------------------------------

test_a_forgetful_suite_cannot_reach_either_binary() {
  local out rc=0
  out=$(in_fresh -- 'herdr session list') || rc=$?
  expect_code 97 "$rc" "a suite that did not fake herdr reached something other than the refusal"
  assert_contains "$out" "REAL herdr binary" "the herdr refusal does not say what was reached"
  assert_contains "$out" "fm_herdr_fake_server" "the herdr refusal does not say how to fake it"

  rc=0
  out=$(in_fresh -- 'tmux list-sessions') || rc=$?
  expect_code 97 "$rc" "a suite that did not fake tmux reached the REAL tmux server"
  assert_contains "$out" "REAL tmux binary" "the tmux refusal does not say what was reached"
  assert_contains "$out" "fm_herdr_fake_tmux" "the tmux refusal does not say how to fake it"
  assert_contains "$out" "unlanded commits" "the tmux refusal does not say why a kill is the dangerous one"
  pass "hermeticity: sourcing lib.sh denies BOTH live multiplexers, loudly and greppably"
}

# The two opt-outs are separate on purpose: a gate driving the real herdr binary
# has no business reaching real tmux. One flag opening both would quietly hand
# every live herdr gate a live `tmux kill-window`.
test_the_two_opt_outs_are_independent() {
  local out rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_HERDR=1 -- 'tmux list-sessions') || rc=$?
  expect_code 97 "$rc" "the herdr opt-out also handed the suite a live tmux"
  assert_contains "$out" "REAL tmux binary" "the tmux refusal did not fire under the herdr opt-out"

  rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 -- 'herdr session list') || rc=$?
  expect_code 97 "$rc" "the tmux opt-out also handed the suite a live herdr"
  assert_contains "$out" "REAL herdr binary" "the herdr refusal did not fire under the tmux opt-out"
  pass "hermeticity: each opt-out withholds only its own binary"
}

# --- the opt-in is guarded, not blank ---------------------------------------

test_opting_in_still_routes_through_the_guard() {
  local out
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 -- 'command -v tmux')
  [ "$out" = "$GUARD" ] \
    || fail "the tmux opt-in reached '$out', not the guard at '$GUARD'"
  pass "hermeticity: the tmux opt-in reaches the real binary through the guard"
}

test_a_kill_outside_the_declared_session_is_refused() {
  local out rc=0
  out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
        "$GUARD" kill-window -t firstmate:fm-drainer 2>&1) || rc=$?
  expect_code 97 "$rc" "a kill aimed at the fleet's own session was allowed through"
  assert_contains "$out" "firstmate:fm-drainer" "the refusal does not name the target it refused"
  assert_contains "$out" "fmtest-throwaway" "the refusal does not name the session that would be allowed"
  pass "hermeticity: a destructive verb outside the declared session is refused"
}

# Fail closed: no declared session must not mean "aim it at whatever is current".
test_a_kill_with_no_declared_session_is_refused() {
  local out rc=0
  out=$(env -u FM_TEST_LIVE_TMUX_SESSION \
        "$GUARD" kill-session -t whatever 2>&1) || rc=$?
  expect_code 97 "$rc" "a kill was allowed with no throwaway session declared"
  assert_contains "$out" "FM_TEST_LIVE_TMUX_SESSION" "the refusal does not say what to declare"

  rc=0
  out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
        "$GUARD" kill-server 2>&1) || rc=$?
  expect_code 97 "$rc" "kill-server was allowed; it can never be scoped to one session"

  # tmux's -a inverts the kill: `-a -t X` kills everything EXCEPT X. Scoping the
  # -t target is backwards there - a correctly declared throwaway session would
  # spare itself and take the fleet's with it - so it must be refused outright,
  # including in the combined `-at X` form.
  local form
  for form in "-a -t fmtest-throwaway" "-at fmtest-throwaway"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
          "$GUARD" kill-session $form 2>&1) || rc=$?
    expect_code 97 "$rc" "an inverted kill ('$form') was allowed through by scoping its -t target"
    assert_contains "$out" "ALL BUT the target" "the refusal does not say why -t cannot scope an inverted kill"
  done
  pass "hermeticity: an unscopeable, inverted or undeclared kill is refused, not aimed at the current session"
}

# The guard reads the same argv twice - once for the -t target, once for the
# inverting -a - and the two readings have to agree about what an argument IS.
# `-t` carries a VALUE, so `-tbar` is a target, not a flag bundle; a scan that
# only asks "does this contain an a" reads it as -a and refuses a correctly
# scoped kill, which fails closed but for a reason that is a lie. And a kill
# with no flags at all must reach the refusal rather than dying on an
# out-of-range index under `set -u`, which would abort the guard before it ever
# decided anything.
#
# Both verdicts are read WITHOUT a live tmux: pointing PATH at nothing means an
# allowed verb stops at the guard's own "no real tmux binary" report, which is
# proof it got past the scoping check with no live server involved.
test_the_two_argv_readings_agree() {
  local out rc form ses argv
  # "<declared session>|<argv>" - the -t value is the target in every allowed
  # row, including `-ta`, where tmux reads the "a" as -t's value and not as -a.
  local -a allowed=("fmthrow|kill-session -tfmthrow" \
                    "fmthrow|kill-session -t fmthrow" \
                    "fmthrow|kill-window -tfmthrow:fm-drainer" \
                    "a|kill-session -ta")
  local -a refused=("kill-session -at fmthrow" \
                    "kill-session -abc" \
                    "kill-session")
  for form in "${allowed[@]}"; do
    ses=${form%%|*}; argv=${form#*|}; rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION="$ses" PATH=/nonexistent-fm-test \
          "$BASH" "$GUARD" $argv 2>&1) || rc=$?
    assert_contains "$out" "no real tmux binary" \
      "the guard refused '$argv', which is scoped to the declared session '$ses'"
  done
  for argv in "${refused[@]}"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION=fmthrow PATH=/nonexistent-fm-test \
          "$BASH" "$GUARD" $argv 2>&1) || rc=$?
    expect_code 97 "$rc" "'$argv' did not reach a refusal (the guard aborted or allowed it)"
    assert_contains "$out" "refusing a destructive tmux verb" \
      "'$argv' failed without the guard's own refusal"
  done
  pass "hermeticity: the -t target and the inverting -a are read from one argv, consistently"
}

# The guard must not become a second deny shim: a read-only verb, and a kill
# INSIDE the declared session, both have to reach the real binary. Run through
# in_fresh with the opt-in set, because that is the only PATH where the guard
# CAN reach it - this file itself carries the deny shim, by design.
test_the_guard_passes_scoped_and_harmless_verbs_through() {
  local ses="fmherm-$$" out rc=0 realpath_ real=
  # The skip check must ask about the REAL binary, not this file's deny shim, so
  # it searches a PATH with every denybin entry dropped rather than assuming
  # which one sourcing lib.sh happened to put first.
  realpath_=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/tests/denybin/' | paste -sd: -)
  real=$(PATH="$realpath_" command -v tmux 2>/dev/null || true)
  [ -n "$real" ] || {
    pass "hermeticity: pass-through (skipped: no tmux installed)"
    return 0
  }
  # Nothing below may outlive this test; the guard permits a kill in $ses.
  # shellcheck disable=SC2064
  trap "FM_TEST_LIVE_TMUX_SESSION='$ses' '$GUARD' kill-session -t '$ses' 2>/dev/null || true" RETURN

  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 FM_TEST_LIVE_TMUX_SESSION="$ses" \
        -- 'tmux -V') || rc=$?
  expect_code 0 "$rc" "the guard refused a harmless read-only verb"
  assert_contains "$out" "tmux" "the guard did not reach the real binary for a read-only verb"

  rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 FM_TEST_LIVE_TMUX_SESSION="$ses" \
        -- "tmux new-session -d -s '$ses' && tmux kill-session -t '$ses'") || rc=$?
  if [ "$rc" = 97 ]; then
    fail "the guard refused a kill INSIDE the suite's own declared session"$'\n'"$out"
  fi
  [ "$rc" = 0 ] || {
    # A machine with no usable terminal for new-session cannot prove this half.
    pass "hermeticity: in-session kill (skipped: tmux new-session unavailable here)"
    return 0
  }
  pass "hermeticity: the guard passes read-only verbs and in-session kills through"
}

# Sitting first on PATH, the guard makes `command -v tmux` succeed. A suite
# probing for tmux would then be told it is installed and fail on an empty exec
# with nothing to read - the shape of a live half that "ran" and proved nothing.
test_an_absent_real_binary_is_reported_not_execed() {
  local dir out rc=0
  dir=$(fm_test_tmproot fm-herm-nobin)
  # Invoked through an ABSOLUTE interpreter, so an empty PATH hides every tmux
  # without also hiding the shell that has to run the guard in the first place.
  out=$(PATH="$dir" "$BASH" "$GUARD" -V 2>&1) || rc=$?
  expect_code 97 "$rc" "the guard exec'd nothing instead of reporting an absent tmux"
  assert_contains "$out" "no real tmux binary" "the guard does not say the binary is missing"
  assert_contains "$out" "did not silently pass" "the guard does not say what the silence would have meant"
  pass "hermeticity: an absent real tmux is reported, not exec'd as an empty command"
}

test_every_suite_is_under_the_net_or_declares_that_it_is_not
test_a_helper_that_never_reaches_lib_is_not_proof
test_the_temp_root_survives_a_subshell_and_is_cleaned_on_exit
test_every_waiver_states_a_reason
test_a_forgetful_suite_cannot_reach_either_binary
test_the_two_opt_outs_are_independent
test_opting_in_still_routes_through_the_guard
test_an_absent_real_binary_is_reported_not_execed
test_a_kill_outside_the_declared_session_is_refused
test_a_kill_with_no_declared_session_is_refused
test_the_two_argv_readings_agree
test_the_guard_passes_scoped_and_harmless_verbs_through
