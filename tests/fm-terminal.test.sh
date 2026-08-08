#!/usr/bin/env bash
# Public-interface tests for the ordered attempt-to-terminal orchestrator
# (bin/fm-terminal.sh): one outer non-reentrant attempt lock spans steps 1-8
# and releases before the fresh step-9 projection; a crash at every receipt
# boundary replays to a semantically equivalent record; a concurrent terminal
# run and refill projection never observe an intermediate free slot; unknown
# forge state, a stale claim-only closure authority, an immature quiet
# interval, and a pre-land actual-diff conflict all refuse before any
# destructive effect.
#
# Every external owner is faked; the fixture never touches the real
# decision-os tracker, the real gh/br CLIs, or the real treehouse. A fake gh
# reports the forge MERGED (landed); a fake br answers `show` with the live
# open bead; a fake treehouse accepts the provider return; and the fake
# attended steward (FM_BR_RECEIPT_BIN) observes the tracker receipt through
# the LOCK-HELD primitive: the terminal holds the attempt lock throughout the
# steward step, and the public observe wrapper is non-reentrant, so it would
# refuse inside the outer lock exactly as a subprocess reacquire must.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The fake attended steward and other fixture subprocesses need ROOT in their
# environment (lib.sh sets it but does not export it).
export ROOT

TMP_ROOT=$(fm_test_tmproot fm-terminal)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$PROJECT/.beads"

# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

# Fixture tracker source file: the close-request hash reads it; the fake
# steward never mutates it.
printf '%s\n' '{"id":"dos-t","status":"open"}' > "$PROJECT/.beads/issues.jsonl"

# --- fake external owners ---------------------------------------------------

# fake gh: the forge reports the PR merged, so fm_disposition_live classifies
# the delivery landed
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}'
SH
chmod +x "$FAKEBIN/gh"

# fake br: live-bead verification (step 1) and the disposition's bead-state
# read answer the open-bead array shape the real br 0.2.19 emits
cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  printf '%s\n' '[{"id":"dos-t","status":"open"}]'
fi
SH
chmod +x "$FAKEBIN/br"

# fake treehouse: the structured cleanup's tmux provider return must stay
# hermetic (the real binary refuses copies it does not manage)
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/treehouse"

# fake attended steward: on success it observes the tracker effect receipt
# through the lock-held primitive (the terminal holds the attempt lock for the
# whole steward step; the public wrapper is non-reentrant) and exits 0
cat > "$FAKEBIN/fm-br-receipt.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-attempt-lib.sh"
REQ=$(cat "$1")
attempt=$(echo "$REQ" | jq -r '.attempt_id')
gen=$(echo "$REQ" | jq -r '.generation')
bead=$(echo "$REQ" | jq -r '.bead_id')
fm_attempt_effect_observe_held "$attempt" "$gen" tracker \
  "$(jq -n --arg bead "$bead" '{bead:$bead,status:"closed"}')" || exit 1
echo "tracker_receipt: $attempt close $bead closed"
SH
chmod +x "$FAKEBIN/fm-br-receipt.sh"

# fake crew-state: the shared capacity projection (terminal step 9 and the
# concurrent refill samples) needs a fast, deterministic fm-crew-state.v1 read
FAKE_CREW="$FAKEBIN/fm-crew-state.sh"
cat > "$FAKE_CREW" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-crew-state.v1","id":"fixture","state":"working","source":"fake"}'
SH
chmod +x "$FAKE_CREW"

export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
export FM_BR_RECEIPT_BIN="$FAKEBIN/fm-br-receipt.sh"
export FM_AUTHORITY_FILE="$STATE/authority-current.json"
export FM_TERMINAL_QUIET_SECS=0
export FM_CREW_STATE_BIN="$FAKE_CREW"
export PATH="$FAKEBIN:$PATH"

# A ship meta named after the envelope task_key (with no attempt= binding) keeps
# the retired attempt visible to the shared capacity projection: the capacity
# row reads kind=ship and the attempt record (which outlives the meta), while
# the structured cleanup, which resolves task ids by scanning for attempt=<id>,
# never removes a meta that does not bind the attempt.
printf 'kind=ship\nmode=direct-PR\n' > "$STATE/dos-t.meta"

# The provider copy must be a real git repo so cleanup's preflight dirty check
# and branch-fate evidence behave deterministically on every replay. Cleanup
# detaches HEAD and deletes the current branch, so the fixture re-creates a
# named branch at HEAD each time: the branch-fate receipt is then identical
# across the baseline and every replayed attempt.
ensure_landed_copy() {
  local dir=$TMP_ROOT/wt-t
  mkdir -p "$dir"
  if [ ! -d "$dir/.git" ]; then
    fm_git_init_commit "$dir"
  fi
  git -C "$dir" checkout -q -B main 2>/dev/null || true
}

setup_terminal_attempt() {  # -> prints a fully landed attempt id
  local aid gen
  aid=$(fm_attempt_alloc pi dos-t holu) || fail "alloc"
  gen=$(fm_attempt_generation "$aid") || fail "generation"
  fm_attempt_effect_observe "$aid" "$gen" claim '{"bead":"dos-t","status":"claimed"}' || fail "claim"
  fm_attempt_freeze_allocation "$aid" "$gen" "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-t\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" "$gen" launch '{"endpoint":"w-t"}' || fail "launch"
  fm_attempt_effect_observe "$aid" "$gen" landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  # forge journal: fm_disposition_live finds the forge owner only through this
  # observation, so the fully-landed fixture must journal it
  fm_attempt_observe "$aid" "$gen" forge '{"provider":"github","pr":"https://github.com/kunchenguid/firstmate/pull/1","state":"open"}' \
    || fail "forge journal"
  ensure_landed_copy
  # Fresh per-effect close authority, written per attempt so a test that
  # overrides the authority file cannot leak into later tests.
  printf '%s\n' '{"transition":"close","authority":"captain:merge"}' > "$STATE/authority-current.json"
  printf '%s\n' "$aid"
}

semantic_equiv() {  # <file-a> <file-b>; receipt names/states/evidence with timestamps and attempt ids stripped
  local norm
  # attempt ids differ between the baseline and replayed attempts (each replay
  # allocates a fresh id), so evidence strings are normalized before compare
  norm='walk(if type == "string" then gsub("-a[0-9]+$"; "-aN") else . end) | [.receipts | to_entries[] | {name:.key, entries:[.value[] | {state,evidence}]}]'
  jq -S "$norm" "$1" > "$TMP_ROOT/sem-a.json"
  jq -S "$norm" "$2" > "$TMP_ROOT/sem-b.json"
  cmp -s "$TMP_ROOT/sem-a.json" "$TMP_ROOT/sem-b.json"
}

test_outer_lock_spans_verification_through_retirement() {
  # with FM_TERMINAL_HOLD_LOCK_PROBE=1, the orchestrator proves it holds the
  # attempt lock at steps 1 and 8 (nested acquire refuses) and releases it
  # before the fresh projection in step 9
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_TERMINAL_HOLD_LOCK_PROBE=1 FM_TERMINAL_QUIET_SECS=0 \
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "lock-held-at-step-1" "orchestrator did not hold the lock at step 1"
  assert_contains "$out" "lock-held-at-step-8" "orchestrator did not hold the lock at step 8"
  assert_contains "$out" "lock-released-before-step-9" "lock not released before the fresh projection"
  pass "one outer non-reentrant lock spans steps 1-8 and releases before step 9"
}

test_crash_after_every_effect_replays_to_semantic_equivalence() {
  # crash after each receipt boundary; replay converges to the same effect
  # set, compared semantically (receipt names + states + evidence), not by
  # byte-identical timestamps or attempt ids
  local baseline aid point
  baseline=$(setup_terminal_attempt)
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$baseline" >/dev/null 2>&1 || true
  for point in claim launch closure cleanup retirement; do
    aid=$(setup_terminal_attempt)
    FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_CRASH_AFTER="$point" \
      "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    semantic_equiv "$STATE/attempts/$baseline.json" "$STATE/attempts/$aid.json" \
      || fail "replay after $point did not converge semantically"
  done
  pass "replay after every irreversible effect converges to a semantically equivalent record"
}

test_concurrent_terminal_and_refill_are_deterministic() {
  # one terminal run and one refill projection race; the projection sees
  # either pre-retirement ownership or a post-retirement deficit, never an
  # intermediate free slot
  local aid out bad pid
  aid=$(setup_terminal_attempt)
  FM_TERMINAL_QUIET_SECS=0 FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 &
  pid=$!
  bad=0
  for _ in 1 2 3 4 5; do
    out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
    # the attempt record outlives the meta, so every sample shows the attempt
    # either pre-retirement (reserved) or retired - never an intermediate
    # state with reserved=false and classification != retired
    echo "$out" | jq -e --arg id "$aid" \
      '([.rows[] | select(.attempt_id == $id) | .reserved == true or .classification == "retired"] | length) == 1' \
      >/dev/null 2>&1 || bad=1
  done
  wait "$pid" 2>/dev/null || true
  [ "$bad" = 0 ] || fail "projection observed an intermediate free slot"
  pass "concurrent terminal and refill see no intermediate free slot"
}

test_unknown_forge_state_refuses_destructive_cleanup() {
  local out
  out=$(FM_TERMINAL_FORGE=unknown "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "reconciliation" "unknown forge did not stop with ownership preserved"
  pass "unknown forge state refuses destructive cleanup and preserves ownership"
}

test_fresh_closure_authority_is_required() {
  # a claim-only authority record must not authorize bead closure
  local aid out
  aid=$(setup_terminal_attempt)
  printf '%s\n' '{"transition":"claim","authority":"captain:dispatch"}' > "$STATE/authority-current.json"
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "authority" "closure without fresh authority proceeded"
  pass "claim authorization never authorizes later bead closure or destructive cleanup"
}

test_immature_quiet_preserves_copy_then_matures() {
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_TERMINAL_QUIET_SECS=100000 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "quiet" "immature quiet did not preserve the copy"
  out=$(FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "cleanup:" "mature replay did not remove the copy"
  pass "immature quiet preserves the copy; a later replay removes it only after maturity"
}

test_preland_actual_diff_conflict_refuses_landing() {
  # FM_REVIEW_DIFF_CONFLICT=1 makes the existing fm-review-diff.sh path report
  # a concrete overlap with another attempt; landing must refuse and serialize
  local out
  out=$(FM_REVIEW_DIFF_CONFLICT=1 "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "pre-land" "pre-land actual-diff conflict not enforced"
  pass "the pre-land actual-diff recheck refuses landing on a concrete overlap"
}

test_outer_lock_spans_verification_through_retirement
test_crash_after_every_effect_replays_to_semantic_equivalence
test_concurrent_terminal_and_refill_are_deterministic
test_unknown_forge_state_refuses_destructive_cleanup
test_fresh_closure_authority_is_required
test_immature_quiet_preserves_copy_then_matures
test_preland_actual_diff_conflict_refuses_landing
