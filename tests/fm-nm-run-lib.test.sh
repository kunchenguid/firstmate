#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-run-lib.sh - the ONE owner of no-mistakes run
# attribution, shared by bin/fm-crew-state.sh (current-state reporting) and
# bin/fm-teardown.sh (pre-teardown run abort).
#
# Two contracts are pinned here, both of which decide whether a run may bind to
# a worktree WITHOUT head equality:
#
#   (a) branch_sync.state is the DIRECT CHILD of the top-level branch_sync
#       block. A sub-block's own `state:` must never be read as the custody
#       label: reading a nested `pipeline_owned` grants the exemption to a run
#       the pipeline does not own (branch-name-only attribution, the exact
#       reused-branch misattribution the head rule exists to prevent), and
#       reading a nested `dirty` denies a legitimate exemption.
#
#   (b) the exemption is BOUNDED. `axi status` reports a run `running` with
#       `pipeline_owned` indefinitely when the daemon dies without writing an
#       outcome, so an unbounded exemption reports that crew as working
#       forever and every signal and turn-end wake from it is absorbed - a
#       wedged worker permanently invisible to supervision. Binding requires
#       positive current custody evidence: a gate the daemon wrote, or a
#       creation time inside the custody window, decoded from the ULID run id
#       the same `axi status` output carries so no other run's freshness can
#       ever stand in for it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

# --- fixtures ---------------------------------------------------------------

# A ULID whose 48-bit timestamp prefix is <seconds> in the past, i.e. the id
# `axi status` would report for a run created then. The trailing 16 characters
# are a ULID's random component and carry no meaning here.
ulid_ago() {  # <seconds-before-now>
  local a='0123456789ABCDEFGHJKMNPQRSTVWXYZ' ms out='' i=0
  ms=$(( ( $(date +%s) - $1 ) * 1000 ))
  while [ "$i" -lt 10 ]; do
    out="${a:$((ms % 32)):1}$out"
    ms=$((ms / 32))
    i=$((i + 1))
  done
  printf '%s0123456789ABCDEF' "$out"
}

# The `run:` header, with the id line omitted entirely when <run-id> is empty
# (a run object that publishes no id at all).
toon_run_header() {  # <run-id>
  printf 'run:\n'
  [ -z "$1" ] || printf '  id: "%s"\n' "$1"
  printf '  branch: fm/feat-x\n  status: running\n  head: "f0f0f0f0"\n'
}

# The well-formed shape the live incident run emitted: branch_sync's own state
# first, nested sub-blocks after it. The run id dates the run, and defaults to
# one created inside the custody window.
toon_direct_child_first() {  # <sync-state> [<run-id>]
  toon_run_header "${2-$(ulid_ago 600)}"
  cat <<EOF
branch_sync:
  state: $1
  changed: false
  local:
    branch: fm/feat-x
    head: "e5e5e5e5"
    clean: true
EOF
}

# A sub-block carrying its own `state:` AHEAD of the direct child. Nothing in
# the CLI contract forbids this, and a first-match-at-any-indent parse reads
# the nested value instead of the block's own.
toon_nested_state_first() {  # <nested-state> <direct-child-state>
  toon_run_header "$(ulid_ago 600)"
  cat <<EOF
branch_sync:
  pipeline:
    state: $1
  state: $2
EOF
}

# A whole nested `branch_sync:` BLOCK ahead of the real top-level one. Its own
# direct child is perfectly well-formed, so direct-child anchoring alone still
# reads it; only anchoring the block header at top level rejects it.
toon_nested_branch_sync_block() {  # <nested-state> <top-level-state>
  toon_run_header "$(ulid_ago 600)"
  cat <<EOF
  branch_sync:
    state: $1
branch_sync:
  state: $2
EOF
}

# The recorded incident shape: parked at a gate for hours, so its own id dates
# it far outside the custody window.
toon_parked_pipeline_owned() {
  cat <<EOF
run:
  id: "$(ulid_ago 27540)"
  branch: fm/feat-x
  status: awaiting_approval
  awaiting_agent: parked 7h39m
  head: "f0f0f0f0"
gate: review
branch_sync:
  state: pipeline_owned
EOF
}

# The same parked run with no decodable id: gate evidence alone must still bind
# it, or bin/fm-teardown.sh orphans the parked run it exists to conclude.
toon_parked_no_id() {
  toon_parked_pipeline_owned | grep -v '^  id:'
}

# --- (a) direct-child indentation anchor ------------------------------------

test_direct_child_state_is_read() {
  local out
  out=$(fm_nm_branch_sync_state "$(toon_direct_child_first pipeline_owned)")
  [ "$out" = pipeline_owned ] || fail "well-formed branch_sync.state read as '$out'"
  out=$(fm_nm_branch_sync_state "$(toon_direct_child_first synced)")
  [ "$out" = synced ] || fail "well-formed non-custody state read as '$out'"
  pass "branch_sync.state reads the block's own scalar"
}

test_nested_state_never_grants_the_exemption() {
  local toon out
  toon=$(toon_nested_state_first pipeline_owned synced)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = synced ] || fail "a nested state: was read as the custody label ('$out')"
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a nested pipeline_owned granted the head-rule exemption"
  fi
  pass "a sub-block's pipeline_owned never grants the exemption"
}

test_nested_state_never_denies_a_real_exemption() {
  local toon out
  toon=$(toon_nested_state_first dirty pipeline_owned)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = pipeline_owned ] || fail "a nested state: masked the real custody label ('$out')"
  fm_nm_run_is_pipeline_owned_active "$toon" \
    || fail "a nested dirty denied a legitimate live pipeline-owned exemption"
  pass "a sub-block's state never masks the block's own custody label"
}

test_child_indent_unit_is_not_assumed() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' \
    'branch_sync:' \
    '    pipeline:' \
    '        state: pipeline_owned' \
    '    state: synced')")
  [ "$out" = synced ] || fail "a four-space indent unit was misparsed as '$out'"
  pass "the direct-child indent is taken from the block, never assumed"
}

test_scan_stops_at_the_end_of_the_block() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' \
    'branch_sync:' \
    '  changed: false' \
    'other_block:' \
    '  state: pipeline_owned')")
  [ -z "$out" ] || fail "a later block's state: leaked into branch_sync ('$out')"
  pass "the scan stops at the end of the branch_sync block"
}

test_nested_branch_sync_block_never_wins_over_the_real_one() {
  local toon out
  toon=$(toon_nested_branch_sync_block pipeline_owned synced)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = synced ] || fail "a nested branch_sync block was read as the custody label ('$out')"
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a nested branch_sync block granted the head-rule exemption"
  fi
  pass "only the top-level branch_sync block is read as the custody label"
}

test_only_nested_branch_sync_reads_empty() {
  local toon
  toon=$(printf '%s\n' 'run:' "  id: \"$(ulid_ago 600)\"" '  status: running' \
    '  branch_sync:' '    state: pipeline_owned')
  [ -z "$(fm_nm_branch_sync_state "$toon")" ] \
    || fail "a document whose only branch_sync is nested reported a custody label"
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a nested-only branch_sync granted the head-rule exemption"
  fi
  pass "a nested-only branch_sync reads empty and denies the exemption"
}

test_absent_block_reads_empty() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' 'run:' '  status: running')")
  [ -z "$out" ] || fail "an absent branch_sync block read as '$out'"
  pass "an absent branch_sync block reads empty"
}

test_quoted_child_value_is_unquoted() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' 'branch_sync:' '  state: "pipeline_owned"')")
  [ "$out" = pipeline_owned ] || fail "a quoted state read as '$out'"
  pass "a quoted branch_sync.state is unquoted"
}

# --- (b) the exemption is bounded -------------------------------------------

test_fresh_pipeline_owned_run_binds() {
  fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned)" \
    || fail "a live pipeline-owned run inside the custody window did not bind"
  pass "a fresh pipeline-owned run binds without head equality"
}

test_stranded_custody_stops_binding() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned "$(ulid_ago 108000)")
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a pipeline-owned run 30h old still bound: a stranded run reads working forever"
  fi
  pass "a pipeline-owned run past the custody window stops binding"
}

test_no_age_evidence_denies_the_exemption() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned "")
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "the exemption bound with no custody evidence at all"
  fi
  toon=$(toon_direct_child_first pipeline_owned "01RUN")
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "the exemption bound on a run id that carries no decodable age"
  fi
  pass "an absent or undecodable run id never grants the exemption"
}

test_future_dated_run_denies_the_exemption() {
  if fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned "$(ulid_ago -86400)")"; then
    fail "a run dated a day in the future bound"
  fi
  pass "an implausibly future-dated run age never grants the exemption"
}

test_absent_status_is_not_a_live_run() {
  local toon
  toon=$(printf '%s\n' 'run:' "  id: \"$(ulid_ago 600)\"" '  branch: fm/feat-x' \
    'branch_sync:' '  state: pipeline_owned')
  if fm_nm_run_is_active "$toon"; then
    fail "a run object with no status: read as active"
  fi
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "the exemption bound on a run with no positive status evidence"
  fi
  pass "an absent status is not evidence of a live run"
}

test_terminal_run_is_never_exempt() {
  local toon
  toon="$(toon_direct_child_first pipeline_owned)
outcome: failed"
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a terminal run bound through the exemption"
  fi
  toon=$(printf '%s\n' 'run:' "  id: \"$(ulid_ago 600)\"" '  status: cancelled' \
    'branch_sync:' '  state: pipeline_owned')
  if fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a cancelled run bound through the exemption"
  fi
  pass "the exemption never applies to a terminal run"
}

# The terminal word set has one owner, because two copies that drift let a
# finished run be read as in-flight and hand its timestamp back as live custody
# evidence. bin/fm-crew-state.sh's runs-row age lookup asks through this same
# predicate.
test_terminal_word_set_is_exactly_the_three_finished_words() {
  local w
  for w in completed failed cancelled; do
    fm_nm_run_word_is_terminal "$w" || fail "'$w' was not recognized as terminal"
  done
  for w in running fixing ci review awaiting_approval '' 'not-a-status'; do
    if fm_nm_run_word_is_terminal "$w"; then
      fail "'$w' was treated as terminal, so a live run would lose its age evidence"
    fi
  done
  pass "the terminal word set covers the finished words and nothing else"
}

test_non_custody_state_is_never_exempt() {
  if fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first synced)"; then
    fail "a synced branch bound through the exemption"
  fi
  pass "the exemption requires branch_sync.state=pipeline_owned"
}

# A run parked at a gate is the case bin/fm-teardown.sh must still conclude:
# its lane head is routinely not a git object in the worktree, and the parked
# duration is exactly what makes it an orphan worth aborting. The daemon wrote
# that gate, and a parked run never maps to `working`, so gate evidence binds
# regardless of run age.
test_gate_parked_run_binds_regardless_of_age() {
  local toon
  toon=$(toon_parked_pipeline_owned)
  fm_nm_run_is_gate_parked "$toon" || fail "a parked run was not recognized as gate-parked"
  fm_nm_run_is_pipeline_owned_active "$toon" \
    || fail "a long-parked pipeline-owned run did not bind, so teardown would orphan it"
  fm_nm_run_is_pipeline_owned_active "$(toon_parked_no_id)" \
    || fail "a parked pipeline-owned run needed a decodable run age to bind"
  pass "a gate-parked pipeline-owned run binds on the daemon's own gate evidence"
}

test_running_run_is_not_gate_parked() {
  if fm_nm_run_is_gate_parked "$(toon_direct_child_first pipeline_owned)"; then
    fail "an autonomous running run was read as gate-parked"
  fi
  pass "an autonomous running step is not gate evidence"
}

# --- custody window configuration -------------------------------------------

test_custody_window_is_configurable() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned "$(ulid_ago 108000)")
  FM_NM_CUSTODY_MAX_AGE_SECS=172800 fm_nm_run_is_pipeline_owned_active "$toon" \
    || fail "a widened custody window was ignored"
  toon=$(toon_direct_child_first pipeline_owned)
  if FM_NM_CUSTODY_MAX_AGE_SECS=60 fm_nm_run_is_pipeline_owned_active "$toon"; then
    fail "a narrowed custody window was ignored"
  fi
  pass "the custody window honours FM_NM_CUSTODY_MAX_AGE_SECS"
}

test_malformed_custody_window_falls_back_to_the_default() {
  local v
  v=$(FM_NM_CUSTODY_MAX_AGE_SECS=forever fm_nm_custody_max_age_secs)
  [ "$v" = "$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT" ] || fail "a malformed window resolved to '$v'"
  v=$(FM_NM_CUSTODY_MAX_AGE_SECS=0 fm_nm_custody_max_age_secs)
  [ "$v" = "$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT" ] || fail "a zero window resolved to '$v'"
  if FM_NM_CUSTODY_MAX_AGE_SECS=forever \
     fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned "$(ulid_ago 108000)")"; then
    fail "a malformed window removed the custody bound"
  fi
  pass "a malformed custody window falls back to the default instead of removing the bound"
}

# --- run age from the run's own id ------------------------------------------
#
# The captured `axi status` output carries no timestamp, but it does carry the
# run id, and no-mistakes run ids are ULIDs whose first 10 characters are the
# creation time in milliseconds. Taking the age from there is what makes it
# impossible for another run's freshness to stand in for the captured run's:
# the one other surface that publishes a run date, `no-mistakes runs`,
# publishes no run id, so a row from it can only be matched back by branch and
# head sha - and a replacement run on the same branch from the same commit
# carries both.

# Pinned against a real run: 01M1J2XASY2PXBBB142ZF8A8J8 was created at epoch
# 1788387175 (its runs.created_at in ~/.no-mistakes/state.sqlite, the birth
# time of ~/.no-mistakes/logs/<id>/, and the 2026-09-02 16:12 local date
# `no-mistakes runs` printed for it), under no-mistakes v1.57.0.
test_ulid_epoch_decodes_a_real_run_id() {
  local got
  got=$(fm_nm_ulid_epoch 01M1J2XASY2PXBBB142ZF8A8J8)
  [ "$got" = 1788387175 ] || fail "a real run id decoded to '$got', not its creation time"
  got=$(fm_nm_ulid_epoch 01m1j2xasy2pxbbb142zf8a8j8)
  [ "$got" = 1788387175 ] || fail "Crockford base32 is case-insensitive; lower case decoded to '$got'"
  pass "a run id decodes to the run's own creation time"
}

test_ulid_epoch_rejects_anything_that_is_not_a_run_id() {
  local id
  # Wrong length, and characters Crockford base32 excludes (I, L, O, U) - an id
  # that is not a ULID must yield no age rather than a wrong one.
  for id in '' '01RUN' '01M1J2XASY2PXBBB142ZF8A8J' '01M1J2XASY2PXBBB142ZF8A8J89' \
            '0IM1J2XASY2PXBBB142ZF8A8J8' '01M1J2XASY2PXBBB142ZF8A8-8'; do
    if fm_nm_ulid_epoch "$id" >/dev/null; then
      fail "'$id' was decoded as a run id"
    fi
  done
  pass "an id that is not a ULID yields no age evidence"
}

test_run_started_epoch_reads_the_captured_runs_own_id() {
  local got want
  want=$(( $(date +%s) - 600 ))
  got=$(fm_nm_run_started_epoch "$(toon_direct_child_first pipeline_owned "$(ulid_ago 600)")")
  # ULID milliseconds truncate to the second, so allow the one-second floor.
  [ "$got" -ge $((want - 1)) ] && [ "$got" -le "$want" ] \
    || fail "the captured run's age resolved to '$got', expected about '$want'"
  if fm_nm_run_started_epoch "$(toon_direct_child_first pipeline_owned "")" >/dev/null; then
    fail "a run object with no id reported an age"
  fi
  pass "run age comes from the id in the captured output"
}

test_direct_child_state_is_read
test_nested_state_never_grants_the_exemption
test_nested_state_never_denies_a_real_exemption
test_child_indent_unit_is_not_assumed
test_nested_branch_sync_block_never_wins_over_the_real_one
test_only_nested_branch_sync_reads_empty
test_scan_stops_at_the_end_of_the_block
test_absent_block_reads_empty
test_quoted_child_value_is_unquoted
test_fresh_pipeline_owned_run_binds
test_stranded_custody_stops_binding
test_no_age_evidence_denies_the_exemption
test_future_dated_run_denies_the_exemption
test_absent_status_is_not_a_live_run
test_terminal_run_is_never_exempt
test_terminal_word_set_is_exactly_the_three_finished_words
test_non_custody_state_is_never_exempt
test_gate_parked_run_binds_regardless_of_age
test_running_run_is_not_gate_parked
test_custody_window_is_configurable
test_malformed_custody_window_falls_back_to_the_default
test_ulid_epoch_decodes_a_real_run_id
test_ulid_epoch_rejects_anything_that_is_not_a_run_id
test_run_started_epoch_reads_the_captured_runs_own_id

echo "all fm-nm-run-lib tests passed"
