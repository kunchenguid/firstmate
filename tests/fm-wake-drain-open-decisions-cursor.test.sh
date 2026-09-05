#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions-cursor.test.sh - end-to-end behavior tests
# for the incremental, cursor-backed OPEN DECISIONS scan
# (fm-classify-lib.sh's status_open_decisions_incremental /
# scan_open_decisions_incremental, wired into bin/fm-wake-drain.sh). These drive
# the REAL drain script across MANY successive invocations over a status log
# that keeps growing, and assert both the printed output and a bounded-cost
# property, not the fold's own source text. tests/fm-wake-drain-open-decisions.test.sh
# already covers the fold's single-drain correctness; this file covers the
# cursor's cross-drain persistence and cost bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-cursor-tests)

# Append <count> harmless filler lines (routine working: notes, never a
# needs-decision/blocked/resolved verb) to <file> and print the exact number of
# bytes appended, so a test can assert the read-probe's byte count against a
# known ground truth rather than an approximation.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT
# incremental fold call (last matching line in the probe log).
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

test_buried_decision_survives_many_growing_drains_and_resolution_clears_it() {
  local dir state out probe status bootstrap_bytes total_size round increment_bytes probe_bytes
  dir=$(make_case cursor-lifecycle)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"

  # Open a keyed decision, buried under an initial filler round big enough to
  # make a full-file rescan cost visibly more than a small incremental one.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 400 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over a large buried decision failed"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the buried decision did not surface on the bootstrap drain"
  bootstrap_bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bootstrap_bytes" ] && [ "$bootstrap_bytes" -gt 0 ] \
    || fail "the bootstrap drain recorded no incremental read at all"

  # Many further drains, each appending only a SMALL increment while the total
  # log keeps growing large. The buried decision must resurface on EVERY one of
  # them (never dropped just because it is old or buried under more appends),
  # and each drain's read-probe byte count must match ONLY that round's small
  # increment - never the ever-growing total file size - proving the read cost
  # is bounded by new appends, not by total log size.
  for round in 1 2 3 4 5; do
    increment_bytes=$(append_filler "$status" 20)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "drain $round over a growing log failed"
    grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
      || fail "the buried decision was dropped on growth round $round"
    probe_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$probe_bytes" = "$increment_bytes" ] \
      || fail "round $round read $probe_bytes bytes, expected exactly this round's $increment_bytes-byte increment (cost is not bounded)"
  done
  total_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$total_size" -gt "$bootstrap_bytes" ] \
    || fail "test setup error: the log never grew past its bootstrap size"

  # Now resolve it. The very next drain's own read (a small increment) must
  # clear it - not by rescanning the whole now-large file, but by folding the
  # small resolved line into the still-persisted open set.
  increment_bytes=$(printf 'resolved [key=api-shape]: went with REST\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the resolved decision still printed as open right after resolution: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte resolved line (cost is not bounded)"

  # Grow the log again after resolution: the decision must stay cleared (a
  # closed decision is not resurrected by unrelated later growth), and the read
  # cost for this final round must still be bounded to that round's increment.
  increment_bytes=$(append_filler "$status" 20)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-resolution growth drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a resolved decision reappeared after later unrelated growth: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the post-resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte increment (cost is not bounded)"

  pass "a buried decision survives many growing drains with bounded read cost, and resolution durably clears it at bounded cost too"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision() {
  local dir state out probe status rewritten_bytes probe_bytes
  dir=$(make_case cursor-truncation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task2.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before truncation failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before truncation"

  # Simulate a rewritten/truncated log (shrunk below the persisted cursor
  # offset): the decision is re-opened by a fresh needs-decision line in the
  # rewritten content, and the incremental scan must fall back to a full
  # re-fold of the new, smaller file rather than trusting a now-invalid cursor.
  printf 'needs-decision [key=migration]: rewritten after truncation\n' > "$status"
  rewritten_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-truncation drain failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' | grep -F 'rewritten after truncation' >/dev/null \
    || fail "the rewritten decision after truncation did not surface"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$rewritten_bytes" ] \
    || fail "post-truncation drain read $probe_bytes bytes, expected a full re-fold of the $rewritten_bytes-byte rewritten file"

  pass "a truncated/rewritten log falls back to a full re-fold instead of dropping or misreading the decision"
}

test_same_size_rewrite_is_detected_via_inode_identity() {
  local dir state out probe status new_bytes probe_bytes
  dir=$(make_case cursor-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task3.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before rotation failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before rotation"

  # Replace the file at the same path with a DIFFERENT file of the SAME byte
  # size (mv gives the destination path a new inode) - a same-size rewrite,
  # which a plain offset>size shrink check alone would NOT catch. The buried
  # decision must still surface: the device+inode identity check must detect
  # this as a rotation/recreation and fall back to a full re-fold.
  new_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=migration]: rewritten via rotation\n' > "$dir/replacement"
  padded=$(LC_ALL=C wc -c < "$dir/replacement" | tr -d '[:space:]')
  pad=$((new_bytes - padded))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$dir/replacement"
  mv "$dir/replacement" "$status"
  [ "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')" = "$new_bytes" ] \
    || fail "test setup error: the rotated replacement is not the same size as the original"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-rotation drain failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' | grep -F 'rewritten via rotation' >/dev/null \
    || fail "the same-size rotated file's decision did not surface (inode-identity check did not fire)"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$new_bytes" ] \
    || fail "post-rotation drain read $probe_bytes bytes, expected a full re-fold of the $new_bytes-byte replacement"

  pass "a same-size file rotation (new inode) is detected and falls back to a full re-fold"
}

test_read_failure_preserves_state_for_retry() {
  local dir state reader statusfile cursor out before_cursor after_cursor
  dir=$(make_case cursor-read-failure)
  state="$dir/state"
  reader="$dir/fail-reader"
  statusfile="$state/task4.status"
  cursor="$state/.task4.open-decisions-cursor"
  out="$dir/drain.out"

  printf 'needs-decision [key=x]: something important\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failure failed"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the decision did not surface on the bootstrap drain"
  [ -s "$cursor" ] || fail "no cursor was persisted after the bootstrap drain"
  before_cursor=$(LC_ALL=C cksum "$cursor")

  printf 'working: more routine content\n' >> "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of preserving state after the injected read failure"
  [ ! -s "$out" ] \
    || fail "the failed presentation read emitted a partial status presentation: $(command cat "$out")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "the failed read advanced or rewrote the persisted cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failure"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the open decision disappeared when presentation reads recovered: $(command cat "$out")"

  pass "a failed presentation read preserves status state for retry"
}

test_cursor_cache_read_failure_refolds_without_replaying_unread_status() {
  local dir state fakebin statusfile cursor out probe real_cat status_bytes probe_bytes
  dir=$(make_case cursor-cache-read-failure)
  state="$dir/state"
  fakebin="$dir/failbin"
  mkdir -p "$fakebin"
  statusfile="$state/task5.status"
  cursor="$state/.task5.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  real_cat=$(command -v cat)

  {
    printf 'needs-decision [key=cache]: recover from authoritative status\n'
    printf 'note: already handled informational status\n'
  } > "$statusfile"
  append_filler "$statusfile" 40 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the cursor-cache read failure failed"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the decision did not surface before the cursor-cache read failure"
  grep -F 'task5 note: already handled informational status' "$out" >/dev/null \
    || fail "the bootstrap drain did not surface the informational status"
  [ -s "$cursor" ] || fail "no cursor was persisted before the cursor-cache read failure"

  printf 'working: appended before cache failure\n' >> "$statusfile"
  status_bytes=$(LC_ALL=C wc -c < "$statusfile" | tr -d '[:space:]')
  : > "$probe"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$cursor" ]; then
  exit 1
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" PATH="$fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of refolding after the cursor-cache read failure"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the cursor-cache read failure hid the recurring open decision: $(command cat "$out")"
  if grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || grep -F 'already handled informational status' "$out" >/dev/null; then
    fail "the cursor-cache read failure replayed handled informational status as new: $(command cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$statusfile")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the cursor-cache read failure read $probe_bytes bytes, expected a full $status_bytes-byte authoritative refold"

  pass "a cursor-cache read failure refolds decisions without replaying handled unread status"
}

test_pre_fix_cursor_refolds_corr_tagged_decision() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-corr-tag-migration)
  state="$dir/state"
  status="$state/task7.status"
  cursor="$state/.task7.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the corr-tag cursor migration failed"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  [ -n "$ident" ] || fail "bootstrap drain did not persist a file identity"
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'version=3\n'
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while migrating the pre-fix corr-tag cursor"
  grep -F 'task7 [key=loan-installment-cadence-amount] needs-decision: pick the cadence' "$out" >/dev/null \
    || fail "the pre-fix cursor hid the corr-tagged decision after migration: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the pre-fix cursor read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  pass "a pre-fix cursor is rebuilt so a previously skipped corr-tagged decision surfaces"
}

test_previous_fold_cache_is_refolded_under_current_semantics() {
  local dir state status cursor out probe status_bytes ident appended_bytes probe_bytes
  dir=$(make_case cursor-fold-version)
  state="$dir/state"
  status="$state/task6.status"
  cursor="$state/.task6.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'blocked [key=pending-reply-abcdef0123456789]: forged decision\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the fold-version migration failed"
  [ ! -s "$out" ] || fail "the current whole-file semantics accepted the foreign reserved-key decision: $(cat "$out")"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
    printf 'pending-reply-abcdef0123456789\tblocked\tforged decision'
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while upgrading the previous fold cache"
  [ ! -s "$out" ] || fail "the previous fold cache kept surfacing a foreign reserved-key decision: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the previous fold cache read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  appended_bytes=$(printf 'needs-decision [key=current]: choose the current path\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "same-version incremental drain failed after cache migration"
  grep -F 'task6 [key=current] needs-decision: choose the current path' "$out" >/dev/null \
    || fail "the same-version append did not fold into the migrated open set"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$appended_bytes" ] \
    || fail "the same-version fold read $probe_bytes bytes instead of only the $appended_bytes-byte append"

  pass "an old fold cache is rebuilt once before same-version incremental reads resume"
}

test_terminal_supersession_reaches_cached_drains() {
  local dir state status cursor out kind terminal expected closing ident size span pass_number
  for kind in scout ship secondmate; do
    for terminal in done failed; do
      dir=$(make_case "terminal-$kind-$terminal")
      state="$dir/state"; status="$state/task.status"; cursor="$state/.task.open-decisions-cursor"; out="$dir/drain.out"
      printf 'kind=%s\n' "$kind" > "$state/task.meta"
      printf 'blocked [key=access]: waiting\n' > "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "initial blocked drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "initial blocker must surface"
      printf '%s: report saved\nnote: cleanup complete\n' "$terminal" >> "$status"
      expected=''; closing=$terminal
      if [ "$kind" = secondmate ]; then expected=$'access\tblocked\twaiting'; closing=blocked; fi
      for pass_number in 1 2; do
        if [ "$pass_number" = 2 ]; then
          ident=$(sed -n 's/^ident=//p' "$cursor")
          size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
          printf 'version=5\noffset=%s\nident=%s\naccess\tblocked\twaiting' "$size" "$ident" > "$cursor"
        fi
        FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "$kind terminal drain failed"
        if [ "$kind" = secondmate ]; then
          assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "secondmate blocker must survive $terminal and cache migration"
        else
          assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "$kind pre-terminal blocker resurfaced after $terminal or cache migration"
        fi
        bash -c '. "$1"; [ "$(status_open_decisions "$2")" = "$3" ] && [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_key_closing_verb "$2" access)" = "$4" ]' \
          _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" "$closing" \
          || fail "$kind whole-file, incremental, and key-history reads disagree with terminal supersession"
      done
      span=$(bash -c '. "$1"; status_span_first_actionable "$2" 0' _ "$ROOT/bin/fm-classify-lib.sh" "$status")
      if [ "$kind" = secondmate ]; then
        assert_contains "$span" 'blocked [key=access]: waiting' "secondmate opening must remain actionable"
      else
        assert_not_contains "$span" 'waiting' "$kind superseded opening remained actionable in a captured span"
      fi
      printf 'blocked [key=access]: reopened\nneeds-decision [key=new]: a new decision\nnote: more cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "reopened drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: reopened' "post-terminal reopening must surface"
      assert_contains "$(cat "$out")" 'task [key=new] needs-decision: a new decision' "post-terminal new key must surface"
      printf 'resolved [key=access]: answered\nresolved [key=new]: answered\nnote: final cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "resolved drain failed"
      assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "matching resolutions must close reopened decisions"
    done
  done
  pass "terminal supersession reaches whole-file reads, incremental drains, old caches, and captured spans"
}

test_kind_changes_invalidate_folded_decisions() {
  local dir state status kind expected
  dir=$(make_case cursor-kind-change); state="$dir/state"; status="$state/task.status"
  printf 'blocked [key=access]: waiting\ndone: report saved\nnote: cleanup complete\n' > "$status"
  for kind in unknown ship secondmate scout; do
    [ "$kind" = unknown ] || printf 'kind=%s\n' "$kind" >> "$state/task.meta"
    case "$kind" in unknown|secondmate) expected=$'access\tblocked\twaiting' ;; *) expected='' ;; esac
    bash -c '. "$1"; [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_open_decisions "$2")" = "$3" ]' \
      _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" \
      || fail "cached decisions did not follow the current $kind metadata without a status append"
  done
  pass "folded decisions are rebuilt when task-kind evidence changes"
}

test_terminal_supersession_reaches_cached_drains
test_kind_changes_invalidate_folded_decisions
test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
test_same_size_rewrite_is_detected_via_inode_identity
test_read_failure_preserves_state_for_retry
test_cursor_cache_read_failure_refolds_without_replaying_unread_status
test_pre_fix_cursor_refolds_corr_tagged_decision
test_previous_fold_cache_is_refolded_under_current_semantics
test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
