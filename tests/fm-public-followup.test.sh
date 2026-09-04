#!/usr/bin/env bash
# End-to-end and regression tests for the deterministic public-followup consumer.
#
# The failure this suite pins: firstmate promises a public final reply in an X or
# Discord thread, routes the work out, and then the session compacts or restarts.
# Nothing in memory survives. The promise is only kept if a terminal work result
# reconciles the typed obligation from DISK and the final reply lands in the
# ORIGINAL thread exactly once.
#
# Everything here is hermetic: the relay is a fakebin `curl`, so no port, no
# server, and no public post. tasks-axi and jq are the real tools, because
# tasks-axi owns the obligation state machine and stubbing it would test nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PF="$ROOT/bin/fm-public-followup.sh"
EMIT="$ROOT/bin/fm-public-followup-emit.sh"
POLL="$ROOT/bin/fm-x-poll.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-public-followup)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A fakebin `curl` standing in for the relay. It logs every call so a test can
# prove exactly how many public posts happened, and honours FAKE_FOLLOWUP_CODE so
# a transport failure can be simulated.
make_fake_curl() {  # <home>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H|-m|-w|-X) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "url=$url"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */connector/followup) printf '%s' "${FAKE_FOLLOWUP_CODE:-200}" ;;
  */connector/answer) printf '200' ;;
  */connector/request-context)
    [ -n "$ofile" ] && printf '%s' "${FAKE_REQCTX_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_REQCTX_CODE:-404}"
    ;;
  */connector/poll) printf '204' ;;
  *) printf '204' ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# make_home <name> [relay-on|relay-off]: a firstmate home with its own backlog.
# relay-off omits .env entirely, which is exactly what a home that never opted
# into the myfirstmate relay looks like.
make_home() {  # <name> [relay-on|relay-off]
  local home="$TMP_ROOT/$1" relay=${2:-relay-on}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  [ "$relay" = relay-off ] || printf 'FMX_PAIRING_TOKEN=test-token\n' > "$home/.env"
  make_fake_curl "$home" >/dev/null
  fm_fake_exit0 "$home/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$home/fakebin"
  printf '%s\n' "$home"
}

run_pf() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FAKE_CURL_LOG="${FAKE_CURL_LOG:-}" \
    FAKE_FOLLOWUP_CODE="${FAKE_FOLLOWUP_CODE:-200}" "$PF" "$@"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# seed_commitment <home> <obligation> <request> <platform> <work-home> <work-id>
# Simulates the intake half that already works today: the relay mention arrives,
# the typed obligation is created with its opaque thread binding, the work is
# bound, and the private request context is retained.
seed_commitment() {
  local home=$1 obligation=$2 request=$3 platform=$4 work_home=$5 work_id=$6
  jq -n --arg r "$request" --arg p "$platform" \
    '{request_id:$r, platform:$p,
      context_binding:{version:"ctx1", value:("ctx1_" + $r)},
      public_safe_summary:"fix worker placement when two spaces share a name",
      received_at:"2026-07-30T10:00:00Z",
      followup_expires_at:"2026-08-06T10:00:00Z",
      reservation_expires_at:"2026-08-06T10:00:00Z"}' > "$home/request.json"
  jq -n '{type:"pr-merged", project:"firstmate",
          required_deliverables:["pr_url"], completion_policy:"all-required"}' \
    > "$home/expected.json"
  jq -n --arg h "$work_home" --arg w "$work_id" \
    '{relation_id:"rel-code", work_ref:{home_id:$h, task_id:$w},
      role:"fulfills", required:true, generation:1}' > "$home/relation.json"

  tasks_in "$home" public-followup add "$obligation" \
    --request-context-file "$home/request.json" --purpose promised-final \
    --expected-final-file "$home/expected.json" --expires-at 2026-10-01T00:00:00Z >/dev/null \
    || fail "could not create the public commitment"
  tasks_in "$home" public-followup bind-work "$obligation" \
    --relation-file "$home/relation.json" >/dev/null \
    || fail "could not bind work to the public commitment"

  # The mention payload and the durable per-request context, exactly as the relay
  # poll records them at intake.
  mkdir -p "$home/state/x-inbox"
  jq -n --arg r "$request" --arg p "$platform" \
    '{request_id:$r, platform:$p, text:"please fix worker placement"}' \
    > "$home/state/x-inbox/$request.json"
  chmod 700 "$home/state/x-inbox"
  chmod 600 "$home/state/x-inbox/$request.json"
  FM_HOME="$home" bash -c \
    ". '$ROOT/bin/fm-x-lib.sh'; fmx_context_registry_set '$home/state' '$request' '$platform' 1900" \
    || fail "could not retain the private request context"

  run_pf "$home" register "$obligation" --relation rel-code \
    --work-home "$work_home" --work-id "$work_id" --generation 1 >/dev/null \
    || fail "could not register the public commitment"
}

emit_terminal() {  # <child-run-dir> <owning-home> <obligation> <work-home> <work-id> [pr-url] [outcome]
  local owning=$2 obligation=$3 work_home=$4 work_id=$5
  local pr=${6:-https://github.com/example/repo/pull/7} outcome=${7:-pr-merged}
  "$EMIT" --home "$owning" --obligation "$obligation" --relation rel-code \
    --source-home "$work_home" --work-id "$work_id" --generation 1 \
    --outcome "$outcome" --deliverable "pr_url=$pr" \
    --outcome-text 'Fixed: workers now land in the launching workspace even when two spaces share a name.'
}

delivery_state() {  # <home> <obligation>
  tasks_in "$1" public-followup list --json 2>/dev/null \
    | jq -r --arg id "$2" '(.public_followups // [])
        | map(select(.id == $id)) | .[0].public_followup.delivery.state // "absent"'
}

task_state() {  # <home> <obligation>
  tasks_in "$1" public-followup list --json 2>/dev/null \
    | jq -r --arg id "$2" '(.public_followups // [])
        | map(select(.id == $id)) | .[0].state // "absent"'
}

followup_posts() {  # <log>
  local n
  n=$(grep -c 'connector/followup' "$1" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# expect_failure <label> <command...>: run <command>, require a non-zero exit, and
# leave its combined output in EXPECT_OUT for the assertions that follow. Keeps
# refusal tests readable without toggling errexit around every case.
EXPECT_OUT=
expect_failure() {
  local label=$1
  shift
  if EXPECT_OUT=$("$@" 2>&1); then
    fail "$label (unexpectedly succeeded)"$'\n'"--- output ---"$'\n'"$EXPECT_OUT"
  fi
}

# --- 0. bounded, single-line, character-safe outcome text -----------------------

# The outcome sentence becomes a public reply, so bounding it must not mangle
# non-ASCII characters, and control characters must never survive into the typed
# event or the thread.
test_outcome_text_is_bounded_without_corrupting_characters() {
  local home event text long
  home=$(make_home outcome-text)
  seed_commitment "$home" pf-text req-text discord main work-text

  "$EMIT" --home "$home" --obligation pf-text --relation rel-code \
    --source-home main --work-id work-text --generation 1 --outcome pr-merged \
    --deliverable pr_url=https://github.com/example/repo/pull/3 \
    --outcome-text "$(printf 'Shipped\tthe caf\xc3\xa9 fix \xe2\x80\x94 \xf0\x9f\x9a\xa2\nsecond line')" >/dev/null \
    || fail "emit failed for non-ASCII outcome text"
  event=$(find "$home/state/public-followup/events" -name '*.json' | head -1)
  text=$(jq -r '.public_safe_outcome' "$event") \
    || fail "the typed event must remain valid JSON with non-ASCII text"
  [ "$text" = 'Shipped the café fix — 🚢 second line' ] \
    || fail "non-ASCII outcome text was corrupted or not collapsed: '$text'"

  # A very long sentence is capped by codepoint, so the JSON stays valid.
  rm -f "$event"
  long=$(python3 -c 'print("é" * 5000, end="")')
  "$EMIT" --home "$home" --obligation pf-text --relation rel-code \
    --source-home main --work-id work-text --generation 1 --outcome pr-merged \
    --deliverable pr_url=https://github.com/example/repo/pull/4 \
    --outcome-text "$long" >/dev/null \
    || fail "emit failed for an over-long outcome text"
  event=$(find "$home/state/public-followup/events" -name '*.json' | head -1)
  text=$(jq -r '.public_safe_outcome' "$event") \
    || fail "an over-long outcome must still produce valid JSON"
  [ "${#text}" -le 600 ] || fail "the outcome text was not bounded, got ${#text} characters"
  case "$text" in
    *[!é]*) fail "codepoint bounding split a multi-byte character" ;;
  esac
  pass "outcome text is collapsed to one line, bounded by codepoint, and never corrupts characters"
}

# --- 1. the restart end-to-end -------------------------------------------------

# The whole reported failure, start to finish, with no conversation memory
# anywhere: a Discord request becomes a typed commitment, a secondmate child
# lands the work and reports a TYPED terminal result, the session ends, and a
# cold reconciliation from disk delivers exactly one final reply into the
# original thread and closes the obligation.
test_restart_e2e_delivers_exactly_once() {
  local home child log out posts receipt
  home=$(make_home restart-e2e)
  child=$(make_home restart-child relay-off)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-restart req-restart discord secondmate:fmdev work-code-q1
  printf '%s\n' fmdev > "$child/.fm-secondmate-home"
  fm_write_meta "$home/state/fmdev.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-code-q1.meta" \
    "x_request=req-restart" "x_request_ts=1700000000" "x_followups=1"

  # The reported failure, reproduced: with the work bound but no reconciled
  # terminal result, the commitment is stranded at pending-work and nothing can
  # be delivered - which is exactly how a promised final reply went unsent.
  [ "$(delivery_state "$home" pf-restart)" = pending-work ] \
    || fail "a freshly bound commitment must sit at pending-work"
  FAKE_CURL_LOG="$log" expect_failure "a commitment still waiting on its work must not be deliverable" \
    run_pf "$home" deliver pf-restart
  assert_contains "$EXPECT_OUT" "still waiting on its bound work" \
    "the stranded state must be reported, not silently skipped"
  [ "$(followup_posts "$log")" -eq 0 ] || fail "the stranded state must post nothing"

  # The child home reports its terminal result as typed data. This is the step
  # whose absence left the obligation stranded at pending-work.
  emit_terminal "$home" "$home" pf-restart secondmate:fmdev work-code-q1 >/dev/null \
    || fail "the child could not report its typed terminal result"

  # Simulate compaction/restart: nothing but disk survives, and the drained inbox
  # is gone. The durable private request context is what keeps the thread binding
  # resolvable.
  rm -f "$home/state/x-inbox/req-restart.json"

  out=$(FAKE_CURL_LOG="$log" run_pf "$home" consume) \
    || fail "cold reconciliation failed"
  assert_contains "$out" "ready pf-restart req-restart discord" \
    "reconciliation must report the commitment as delivery-ready"
  [ "$(delivery_state "$home" pf-restart)" = ready ] \
    || fail "the typed terminal result must move the commitment to ready"
  [ "$(followup_posts "$log")" -eq 0 ] \
    || fail "reconciliation must not post anything by itself"

  out=$(FAKE_CURL_LOG="$log" run_pf "$home" deliver pf-restart) \
    || fail "delivery failed"
  assert_contains "$out" "delivered pf-restart request=req-restart platform=discord" \
    "delivery must report the original request binding"

  posts=$(followup_posts "$log")
  [ "$posts" -eq 1 ] || fail "expected exactly one public reply, got $posts"
  assert_grep 'connector/followup' "$log" "the reply must use the follow-up endpoint"
  assert_grep '"request_id":"req-restart"' "$log" \
    "the reply must target the ORIGINAL request binding"
  assert_grep 'workers now land in the launching workspace' "$log" \
    "the reply must reuse the accepted terminal outcome verbatim"

  receipt=$(tasks_in "$home" public-followup list --json \
    | jq -r '(.public_followups // [])
        | map(select(.id == "pf-restart")) | .[0].public_followup.delivery.receipt.state // "none"')
  [ "$receipt" = posted ] || fail "a validated posted receipt must be recorded, got '$receipt'"
  [ "$(task_state "$home" pf-restart)" = 'done' ] \
    || fail "the commitment must be Done only after the receipt"
  assert_no_grep '^x_request=' "$child/state/work-code-q1.meta" \
    "typed delivery must clear the secondmate's legacy X link"
  pass "restart end-to-end: typed result reconciles from disk and delivers one reply to the original thread"
}

# --- 2. idempotency ------------------------------------------------------------

test_duplicate_event_and_replay_are_noops() {
  local home log first second out posts
  home=$(make_home idempotent)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-dup req-dup discord main work-dup

  first=$(emit_terminal "$home" "$home" pf-dup main work-dup) || fail "first emit failed"
  second=$(emit_terminal "$home" "$home" pf-dup main work-dup) || fail "second emit failed"
  [ "$first" = "$second" ] \
    || fail "the same terminal result must derive the same event identity"
  [ "$(find "$home/state/public-followup/events" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "a duplicate emit must not create a second event file"

  FAKE_CURL_LOG="$log" run_pf "$home" consume >/dev/null || fail "first consume failed"
  # Replay the identical event after the fact, exactly as a restarted child would.
  emit_terminal "$home" "$home" pf-dup main work-dup >/dev/null || fail "replay emit failed"
  out=$(FAKE_CURL_LOG="$log" run_pf "$home" consume) || fail "replay consume failed"
  [ -z "$out" ] || fail "replaying an accepted event must be silent, got: $out"
  [ "$(delivery_state "$home" pf-dup)" = ready ] \
    || fail "replay must not disturb the delivery state"

  FAKE_CURL_LOG="$log" run_pf "$home" deliver pf-dup >/dev/null || fail "delivery failed"
  out=$(FAKE_CURL_LOG="$log" run_pf "$home" deliver pf-dup) || fail "second deliver must succeed silently"
  assert_contains "$out" "already delivered" "a second delivery must report the existing receipt"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 1 ] || fail "a repeated delivery must never double-post, got $posts posts"
  pass "duplicate terminal results, restart replay, and repeated delivery are all no-ops"
}

# --- 3. refusals ---------------------------------------------------------------

# Everything tasks-axi is the authority on - source home, work id, generation,
# schema, and permitted deliverables - must be refused rather than half-applied,
# and quarantined rather than retried forever.
test_invalid_events_are_refused_and_quarantined() {
  local home out events rejected
  home=$(make_home refusals)
  seed_commitment "$home" pf-refuse req-refuse discord secondmate:fmdev work-real

  # Wrong source home and wrong work id are caught at the edge by the emitter,
  # because the owning home's own registration disagrees.
  expect_failure "a wrong source home must be refused" \
    "$EMIT" --home "$home" --obligation pf-refuse --relation rel-code \
    --source-home secondmate:other --work-id work-real --generation 1 \
    --outcome pr-merged --deliverable pr_url=https://example.invalid/1 \
    --outcome-text 'x'
  assert_contains "$EXPECT_OUT" "does not match this home's registration" \
    "the refusal must name the mismatch"

  expect_failure "a wrong work id must be refused" \
    "$EMIT" --home "$home" --obligation pf-refuse --relation rel-code \
    --source-home secondmate:fmdev --work-id work-other --generation 1 \
    --outcome pr-merged --deliverable pr_url=https://example.invalid/1 \
    --outcome-text 'x'
  expect_failure "a stale generation must be refused" \
    "$EMIT" --home "$home" --obligation pf-refuse --relation rel-code \
    --source-home secondmate:fmdev --work-id work-real --generation 0 \
    --outcome pr-merged --deliverable pr_url=https://example.invalid/1 \
    --outcome-text 'x'

  events="$home/state/public-followup/events"
  rejected="$home/state/public-followup/rejected"

  # A malformed event that bypassed the emitter entirely.
  printf 'not json at all\n' > "$events/deadbeef.json"
  out=$(run_pf "$home" consume) || fail "consume must survive a malformed event"
  assert_contains "$out" "rejected deadbeef" "a malformed event must be refused"
  assert_absent "$events/deadbeef.json" "a refused event must leave the pending inbox"
  assert_present "$rejected/deadbeef.reason" "a refusal must keep an inspectable reason"

  # A deliverable the expected-final type does not permit. The emitter accepts the
  # shape; tasks-axi is the authority that refuses the semantics.
  "$EMIT" --home "$home" --obligation pf-refuse --relation rel-code \
    --source-home secondmate:fmdev --work-id work-real --generation 1 \
    --outcome pr-merged --deliverable report_path=data/x/report.md \
    --outcome-text 'wrong deliverable for a merged PR' >/dev/null \
    || fail "the emitter should publish a shape-valid event"
  out=$(run_pf "$home" consume) || fail "consume must survive an unsupported deliverable"
  assert_contains "$out" "rejected " "an unsupported deliverable must be refused by tasks-axi"
  [ "$(delivery_state "$home" pf-refuse)" = pending-work ] \
    || fail "a refused event must leave the commitment untouched"

  # A hand-edited event whose id no longer matches its own identity fields.
  jq -n '{schema_version:1, event_id:"forged", obligation_id:"pf-refuse",
          relation_id:"rel-code", work_id:"work-real", generation:1,
          source_home_id:"secondmate:fmdev", outcome_type:"pr-merged",
          deliverables:{pr_url:"https://example.invalid/9"},
          public_safe_outcome:"forged", occurred_at:"2026-07-30T12:00:00Z",
          successor:null}' > "$events/forged.json"
  out=$(run_pf "$home" consume) || fail "consume must survive a forged event"
  assert_contains "$out" "rejected forged" "a forged event identity must be refused"
  pass "wrong source, wrong work id, stale generation, malformed, unsupported deliverable, and forged identity are all refused"
}

# --- 4. transport failure and late receipt -------------------------------------

test_relay_failure_holds_without_false_completion() {
  local home log out posts
  home=$(make_home retryable)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-retry req-retry discord main work-retry
  emit_terminal "$home" "$home" pf-retry main work-retry >/dev/null || fail "emit failed"
  FAKE_CURL_LOG="$log" run_pf "$home" consume >/dev/null || fail "consume failed"

  FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=500 \
    expect_failure "a failed relay post must not report success" \
    run_pf "$home" deliver pf-retry
  assert_contains "$EXPECT_OUT" "recorded as retryable" "the failure must be typed as retryable"
  [ "$(delivery_state "$home" pf-retry)" = retry-due ] \
    || fail "a failed post must leave a retryable state, got $(delivery_state "$home" pf-retry)"
  [ "$(task_state "$home" pf-retry)" != 'done' ] \
    || fail "a failed post must never close the commitment"

  # The retry succeeds and closes it, with exactly one successful post.
  : > "$log"
  FAKE_CURL_LOG="$log" run_pf "$home" deliver pf-retry >/dev/null || fail "the retry should deliver"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 1 ] || fail "the retry must post exactly once, got $posts"
  [ "$(task_state "$home" pf-retry)" = 'done' ] || fail "a successful retry must close the commitment"
  pass "a relay transport failure is held as retryable with no false completion, and the retry posts once"
}

test_dry_run_does_not_close_commitment() {
  local home log out posts
  home=$(make_home dry-run)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-dry req-dry discord main work-dry
  emit_terminal "$home" "$home" pf-dry main work-dry >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"

  FMX_DRY_RUN=1 FAKE_CURL_LOG="$log" expect_failure \
    "a dry-run must not close a public commitment" run_pf "$home" deliver pf-dry
  assert_contains "$EXPECT_OUT" "recorded as retryable" \
    "a dry-run must leave a retryable typed state"
  [ "$(delivery_state "$home" pf-dry)" = retry-due ] \
    || fail "a dry-run must leave the obligation retryable, got $(delivery_state "$home" pf-dry)"
  [ "$(task_state "$home" pf-dry)" != 'done' ] \
    || fail "a dry-run must never close the commitment"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 0 ] || fail "a dry-run must not post to the relay, got $posts posts"
  pass "a dry-run records no public delivery and leaves the commitment retryable"
}

test_late_receipt_closes_the_exact_attempt_without_reposting() {
  local home log out posts attempt
  home=$(make_home late-receipt)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-late req-late x main work-late
  fm_write_meta "$home/state/work-late.meta" \
    "x_request=req-late" "x_request_ts=1700000000" "x_followups=1"
  emit_terminal "$home" "$home" pf-late main work-late >/dev/null || fail "emit failed"
  FAKE_CURL_LOG="$log" run_pf "$home" consume >/dev/null || fail "consume failed"

  FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=503 run_pf "$home" deliver pf-late >/dev/null 2>&1 || true
  attempt=$(tasks_in "$home" public-followup list --json \
    | jq -r '(.public_followups // []) | map(select(.id == "pf-late"))
             | .[0].public_followup.delivery.attempt_count')
  [ "$attempt" = 1 ] || fail "the failed attempt must be recorded as attempt 1, got '$attempt'"

  expect_failure "a late receipt must include its exact message count" \
    run_pf "$home" record-posted pf-late --attempt 1
  assert_contains "$EXPECT_OUT" "--chunks <n> is required" \
    "a late receipt without a message count must be refused"

  # The post actually landed; its receipt was simply lost. Close the exact attempt
  # without sending anything else.
  : > "$log"
  out=$(FAKE_CURL_LOG="$log" run_pf "$home" record-posted pf-late --attempt 1 --chunks 1) \
    || fail "recording a late receipt for the exact attempt must succeed"
  assert_contains "$out" "recorded pf-late attempt=1" "the late receipt must name its attempt"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 0 ] || fail "recording a late receipt must post nothing, got $posts posts"
  [ "$(task_state "$home" pf-late)" = 'done' ] || fail "a validated late receipt must close the commitment"
  assert_no_grep '^x_request=' "$home/state/work-late.meta" \
    "a late receipt must clear the legacy X link"

  FAKE_CURL_LOG="$log" expect_failure "a receipt for a different attempt must be refused" \
    run_pf "$home" record-posted pf-late --attempt 9 --chunks 1
  pass "a late success receipt closes the exact attempt with no second post, and a mismatched attempt is refused"
}

test_typed_terminal_clear_only_removes_legacy_link() {
  local home meta out
  home=$(make_home typed-clear)
  meta="$home/state/work-clear.meta"
  printf '%s\n' 'status=working' 'x_request=req-clear' 'x_request_ts=1700000000' \
    'x_followups=2' 'x_platform=discord' 'x_reply_max_chars=1900' > "$meta"

  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-x-followup.sh" --clear work-clear) \
    || fail "the typed terminal clear transition must succeed"
  [ "$out" = work-clear ] || fail "the clear-only transition must identify the task"
  assert_grep 'status=working' "$meta" "clear-only transition must preserve unrelated task metadata"
  assert_no_grep '^x_request=' "$meta" "clear-only transition must remove the request link"
  assert_no_grep '^x_followups=' "$meta" "clear-only transition must remove the follow-up counter"
  assert_no_grep '^x_platform=' "$meta" "clear-only transition must remove platform metadata"
  pass "typed terminal cleanup clears the legacy link without posting"
}

# A crash between the post and its receipt is the one case where we cannot know
# whether the thread already got a reply. Delivery must refuse rather than guess.
test_interrupted_delivery_refuses_to_repost() {
  local home log out posts
  home=$(make_home interrupted)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-crash req-crash discord main work-crash
  emit_terminal "$home" "$home" pf-crash main work-crash >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"

  # Reproduce the crash window directly through the state machine.
  tasks_in "$home" public-followup begin-delivery pf-crash \
    --payload-hash 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null \
    || fail "could not stage the interrupted attempt"

  FAKE_CURL_LOG="$log" expect_failure "an interrupted delivery must not silently post again" \
    run_pf "$home" deliver pf-crash
  assert_contains "$EXPECT_OUT" "mid-delivery" "the refusal must name the interrupted attempt"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 0 ] || fail "an interrupted delivery must post nothing, got $posts posts"
  pass "a delivery interrupted between post and receipt refuses to repost"
}

# --- 5. ownership --------------------------------------------------------------

# The outward post belongs to the home holding the relay consent and the thread
# binding. A child home has neither, and must not be able to acquire them.
test_outward_delivery_stays_with_the_owning_home() {
  local owner child log out
  owner=$(make_home owner)
  child=$(make_home child relay-off)
  log="$owner/curl.log"; : > "$log"
  seed_commitment "$owner" pf-own req-own discord secondmate:child work-child
  printf '%s\n' child > "$child/.fm-secondmate-home"
  fm_write_meta "$owner/state/child.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-child.meta" \
    "x_request=req-own" "x_request_ts=1700000000" "x_followups=1"

  FAKE_CURL_LOG="$log" emit_terminal "$owner" "$owner" pf-own secondmate:child work-child >/dev/null \
    || fail "the child could not report its typed result"
  [ "$(followup_posts "$log")" -eq 0 ] \
    || fail "reporting a terminal result must never post publicly"
  run_pf "$owner" consume >/dev/null || fail "the owning home could not consume the child's typed result"

  # The child home has no commitment of its own and no relay consent, so it can
  # neither deliver nor even see one.
  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FAKE_CURL_LOG="$log" \
    expect_failure "a home without relay consent must not deliver a public reply" \
    "$PF" deliver pf-own
  assert_contains "$EXPECT_OUT" "has not opted into the myfirstmate relay" \
    "the refusal must name the missing relay consent"
  [ "$(followup_posts "$log")" -eq 0 ] || fail "the refused delivery must post nothing"
  FAKE_CURL_LOG="$log" run_pf "$owner" deliver pf-own >/dev/null \
    || fail "the owning home must deliver the typed public reply"
  assert_no_grep '^x_request=' "$child/state/work-child.meta" \
    "typed delivery must clear the child task's legacy X link"
  pass "a child home reports typed results but can never become the outward-post owner"
}

test_delivery_requires_registration_before_posting() {
  local home log out
  home=$(make_home missing-registration)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-missing req-missing x main work-missing
  fm_write_meta "$home/state/work-missing.meta" \
    "x_request=req-missing" "x_request_ts=1700000000" "x_followups=1"
  emit_terminal "$home" "$home" pf-missing main work-missing >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"
  rm -f "$home/state/public-followup/registry/pf-missing"

  FAKE_CURL_LOG="$log" expect_failure "delivery without a registration must refuse" \
    run_pf "$home" deliver pf-missing
  assert_contains "$EXPECT_OUT" "registration for 'pf-missing' is missing or invalid" \
    "missing registration must be an actionable delivery refusal"
  [ "$(followup_posts "$log")" -eq 0 ] || fail "missing registration must prevent any public post"
  [ "$(task_state "$home" pf-missing)" != 'done' ] \
    || fail "missing registration must not close the obligation"
  assert_grep 'x_request=req-missing' "$home/state/work-missing.meta" \
    "missing registration must leave the legacy link for reconciliation"
  pass "typed delivery refuses to post when its cleanup registration is missing"
}

test_secondmate_teardown_requires_parent_binding() {
  local parent child registry_before marker_before
  parent=$(make_home teardown-parent)
  child=$(make_home teardown-child)
  printf '%s\n' mate > "$child/.fm-secondmate-home"
  seed_commitment "$parent" pf-teardown req-teardown x secondmate:mate work-child
  fm_write_meta "$parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only"

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    expect_failure "marked child teardown without a parent must refuse cleanup" \
    "$TEARDOWN" work-child
  assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate" \
    "missing parent binding must be an actionable teardown refusal"
  assert_present "$child/state/work-child.meta" \
    "missing parent binding must preserve the child work metadata"

  parent=$(make_home teardown-valid-parent)
  child=$(make_home teardown-valid-child)
  printf '%s\n' mate > "$child/.fm-secondmate-home"
  printf -- '- mate - synthetic (id is legacy); preserve this (home: %s; scope: synthetic (child); semicolon remains meaningful; projects: ; added 2026-07-30)\n' \
    "$child" > "$parent/data/secondmates.md"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "home-seed validation rejected a punctuation-bearing operational registry record"
  registry_before=$(cat "$parent/data/secondmates.md")
  marker_before=$(cat "$child/.fm-secondmate-home")
  seed_commitment "$parent" pf-teardown-valid req-teardown-valid x secondmate:mate work-child
  fm_write_meta "$parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only"
  assert_absent "$child/.fm-secondmate-parent" \
    "the legacy env-only binding case must not gain a durable parent record"

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" \
    expect_failure "marked child teardown with a valid parent must enforce the parent commitment" \
    "$TEARDOWN" work-child
  assert_contains "$EXPECT_OUT" "still owes a public reply" \
    "valid parent binding must route cleanup through the parent commitment"
  case "$EXPECT_OUT" in
    *"cannot resolve the primary home"*) fail "valid parent binding was reported as unresolved" ;;
  esac
  assert_present "$child/state/work-child.meta" \
    "an owed parent commitment must preserve the child work metadata"
  [ "$registry_before" = "$(cat "$parent/data/secondmates.md")" ] \
    || fail "guarded cleanup refusal changed the parent registry"
  [ "$marker_before" = "$(cat "$child/.fm-secondmate-home")" ] \
    || fail "guarded cleanup refusal changed the child identity marker"
  pass "marked secondmate teardown resolves its parent and fails closed when unavailable"
}

# The three tests below exercise the durable .fm-secondmate-parent record a real
# bin/fm-home-seed.sh seed now writes next to .fm-secondmate-home (fm-remote-sm-
# cleanup-parent-binding-s1 report, section 7). Before this record existed, the
# marked-child gate above could only ever see the parent through the launch-time
# FM_PUBLIC_FOLLOWUP_PRIMARY_HOME env var: a restart that dropped that prefix made
# the guard silently treat an actually-active parent relay as off, which could
# drop a real public-reply obligation without anyone noticing. Each test drives
# the real bin/fm-teardown.sh cleanup path against a home real fm-home-seed.sh
# produced, never a hand-crafted marker.

assert_local_secondmate_parent_record() {
  local child=$1 parent=$2
  cmp -s "$child/.fm-secondmate-parent" <(
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent"
  ) || fail "real secondmate seeding must write the exact durable local parent record"
}

test_local_secondmate_seed_publishes_parent_before_identity() {
  local parent child parent_resolved fakebin entered release manifest_out real_mv seed_pid wait_count
  parent=$(make_home seed-publication-parent relay-off)
  child="$TMP_ROOT/seed-publication-child"
  parent_resolved=$(cd "$parent" && pwd -P)
  fakebin=$(fm_fakebin "$TMP_ROOT/seed-publication-fake")
  entered="$TMP_ROOT/seed-publication-entered"
  release="$TMP_ROOT/seed-publication-release"
  manifest_out="$TMP_ROOT/seed-publication.out"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "$destination" in
  */.fm-secondmate-home)
    touch "$FM_TEST_PUBLISH_ENTERED"
    wait_count=0
    while [ ! -f "$FM_TEST_PUBLISH_RELEASE" ]; do
      wait_count=$((wait_count + 1))
      [ "$wait_count" -le 250 ] || exit 97
      sleep 0.02
    done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  PATH="$fakebin:$PATH" FM_HOME="$parent" \
    FM_SECONDMATE_CHARTER='Local publication-order regression charter.' \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_PUBLISH_ENTERED="$entered" \
    FM_TEST_PUBLISH_RELEASE="$release" \
    "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects > "$manifest_out" 2>&1 &
  seed_pid=$!
  wait_count=0
  while [ ! -f "$entered" ]; do
    kill -0 "$seed_pid" 2>/dev/null \
      || fail "local seeding exited before its identity completion marker: $(cat "$manifest_out")"
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 250 ] || fail "local seeding never reached its identity completion marker"
    sleep 0.02
  done
  assert_local_secondmate_parent_record "$child" "$parent_resolved"
  assert_absent "$child/.fm-secondmate-home" \
    "the local identity marker must remain absent until durable parent publication completes"
  touch "$release"
  wait "$seed_pid" || fail "local seeding failed after publishing durable parent state: $(cat "$manifest_out")"
  assert_present "$child/.fm-secondmate-home" \
    "local seeding must publish its identity marker as the completion point"
  pass "local seeding publishes durable parent state before its identity marker"
}

test_secondmate_teardown_resolves_parent_from_durable_record_when_env_lost() {
  local parent child parent_resolved
  parent=$(make_home teardown-durable-parent)
  child="$TMP_ROOT/teardown-durable-child"
  FM_SECONDMATE_CHARTER='Durable-record regression charter.' \
    FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "real secondmate seeding failed"
  child=$(cd "$child" && pwd -P)
  parent_resolved=$(cd "$parent" && pwd -P)
  make_fake_curl "$child" >/dev/null
  fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$child/fakebin"

  assert_local_secondmate_parent_record "$child" "$parent_resolved"

  seed_commitment "$parent" pf-durable req-durable x secondmate:mate work-child
  fm_write_meta "$parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only"

  # No FM_PUBLIC_FOLLOWUP_PRIMARY_HOME at all here: a restart of the secondmate
  # agent that drops the launch-time prefix must still find the real parent
  # through the durable record instead of silently treating the relay as off.
  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    expect_failure "teardown with a lost launch binding must still find the real parent" \
    "$TEARDOWN" work-child
  assert_contains "$EXPECT_OUT" "still owes a public reply" \
    "the durable record must resolve to the real parent's owed commitment"
  case "$EXPECT_OUT" in
    *"cannot resolve the primary home"*) fail "the durable local record was not used to resolve the parent" ;;
  esac
  assert_present "$child/state/work-child.meta" \
    "a durably-resolved owed commitment must preserve the child work metadata"
  pass "a lost launch-time parent binding is recovered from the durable local record"
}

test_secondmate_teardown_durable_record_missing_parent_registration_still_refuses() {
  local parent child parent_resolved
  parent=$(make_home teardown-durable-missing-parent relay-off)
  child="$TMP_ROOT/teardown-durable-missing-child"
  FM_SECONDMATE_CHARTER='Durable-record missing-registration regression charter.' \
    FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "real secondmate seeding failed"
  child=$(cd "$child" && pwd -P)
  parent_resolved=$(cd "$parent" && pwd -P)
  make_fake_curl "$child" >/dev/null
  fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$child/fakebin"
  assert_local_secondmate_parent_record "$child" "$parent_resolved"
  fm_write_meta "$child/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only"
  # No parent/state/mate.meta at all: the parent never recorded this secondmate's
  # own agent, so its side of the binding is genuinely missing. A durable LOCAL
  # record naming the real parent path must not be enough on its own to bypass
  # the check; the real protection this guard exists for must survive the fix.

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    expect_failure "a durable local record with no parent-side registration must still refuse" \
    "$TEARDOWN" work-child
  assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate" \
    "a genuinely missing parent-side registration must remain an actionable teardown refusal"
  assert_present "$child/state/work-child.meta" \
    "a genuinely missing parent binding must preserve the child work metadata"
  pass "a durable local parent record does not bypass a genuinely missing parent-side registration"
}

test_secondmate_teardown_durable_record_with_unknown_field_succeeds() {
  local parent parent_alias child parent_resolved rc out
  parent=$(make_home teardown-durable-clean-parent relay-off)
  child="$TMP_ROOT/teardown-durable-clean-child"
  FM_SECONDMATE_CHARTER='Durable-record clean-cleanup regression charter.' \
    FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "real secondmate seeding failed"
  child=$(cd "$child" && pwd -P)
  parent_resolved=$(cd "$parent" && pwd -P)
  make_fake_curl "$child" >/dev/null
  fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$child/fakebin"
  assert_local_secondmate_parent_record "$child" "$parent_resolved"
  printf 'some_future_field=value\n' >> "$child/.fm-secondmate-parent"
  parent_alias="$TMP_ROOT/teardown-durable-clean-parent-alias"
  ln -s "$parent" "$parent_alias"
  fm_write_meta "$parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_git_init_commit "$child/projects/worktree"
  printf 'manual\n' > "$child/config/backlog-backend"
  fm_write_meta "$child/state/work-clean.meta" \
    "window=firstmate:fm-work-clean" "endpoint_task_id=work-clean" \
    "worktree=$child/projects/worktree" "project=$child/projects/worktree" \
    "kind=ship" "mode=local-only"

  rc=0
  out=$(PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent_alias" \
    "$TEARDOWN" work-clean 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a resolved parent with no owed commitment must allow cleanup (rc=$rc): $out"
  assert_not_contains "$out" "cannot resolve the primary home" \
    "a real durable-record-backed parent must resolve cleanly"
  pass "unknown durable parent fields remain forward-compatible"
}

test_secondmate_teardown_rejects_conflicting_live_and_durable_parent_bindings() {
  local durable_parent live_parent child parent_resolved
  durable_parent=$(make_home teardown-durable-conflict-recorded relay-off)
  live_parent=$(make_home teardown-durable-conflict-live relay-off)
  child="$TMP_ROOT/teardown-durable-conflict-child"
  FM_SECONDMATE_CHARTER='Durable-record conflict regression charter.' \
    FM_HOME="$durable_parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "real secondmate seeding failed"
  child=$(cd "$child" && pwd -P)
  parent_resolved=$(cd "$durable_parent" && pwd -P)
  make_fake_curl "$child" >/dev/null
  fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$child/fakebin"
  assert_local_secondmate_parent_record "$child" "$parent_resolved"
  fm_write_meta "$durable_parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_git_init_commit "$child/projects/worktree"
  printf 'manual\n' > "$child/config/backlog-backend"
  fm_write_meta "$child/state/work-conflict.meta" \
    "window=firstmate:fm-work-conflict" "endpoint_task_id=work-conflict" \
    "worktree=$child/projects/worktree" "project=$child/projects/worktree" \
    "kind=ship" "mode=local-only"

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$live_parent" \
    expect_failure "conflicting live and durable parent bindings must refuse cleanup" \
    "$TEARDOWN" work-conflict
  assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate" \
    "a conflicting live parent must produce the explicit durable-binding refusal"
  assert_present "$child/state/work-conflict.meta" \
    "a conflicting live parent must preserve child work metadata"
  pass "conflicting live and durable parent bindings fail closed"
}

test_secondmate_teardown_rejects_unsafe_durable_parent_records() {
  local case_name parent child parent_record
  for case_name in symlink invalid-route duplicate-route remote-parent-home local-parent-host; do
    parent=$(make_home "teardown-durable-$case_name-parent" relay-off)
    child="$TMP_ROOT/teardown-durable-$case_name-child"
    FM_SECONDMATE_CHARTER='Unsafe durable-record regression charter.' \
      FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
      || fail "real secondmate seeding failed for $case_name"
    child=$(cd "$child" && pwd -P)
    make_fake_curl "$child" >/dev/null
    fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
    fm_fake_treehouse_legacy "$child/fakebin"
    fm_write_meta "$child/state/work-child.meta" \
      "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
      "worktree=$child" "project=$child" "kind=ship" "mode=local-only"
    parent_record="$child/.fm-secondmate-parent"
    case "$case_name" in
      symlink)
        mv "$parent_record" "$parent_record.valid"
        ln -s .fm-secondmate-parent.valid "$parent_record"
        ;;
      invalid-route)
        printf 'schema=fm-secondmate-parent.v1\nroute=garbage\n' > "$parent_record"
        ;;
      duplicate-route)
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nroute=remote\n' \
          "$parent" > "$parent_record"
        ;;
      remote-parent-home)
        printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_home=%s\n' \
          "$parent" > "$parent_record"
        ;;
      local-parent-host)
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nparent_host=remote-host\n' \
          "$parent" > "$parent_record"
        ;;
    esac

    PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
      FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
      expect_failure "an unsafe $case_name durable parent record must refuse cleanup" \
      "$TEARDOWN" work-child
    assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate" \
      "an unsafe $case_name durable parent record must produce the explicit binding refusal"
    assert_present "$child/state/work-child.meta" \
      "an unsafe $case_name durable parent record must preserve child work metadata"
  done
  pass "unsafe durable parent records fail closed before cleanup"
}

# A NUL byte inside the durable record must fail closed like every other
# malformed record. bash's read drops NUL bytes while parsing, and different
# bash generations disagree on the result (3.2 truncates the value at the NUL,
# 5.x splices the surrounding bytes together), so a NUL-bearing parent_home can
# resolve to a home the record's bytes never name contiguously - and teardown's
# parent reads (registration, registry, relay state) then land in that other
# home, with the promised-public-reply protection engaging or not depending on
# which interpreter ran the cleanup. The fixture is deliberately the proven
# clean-cleanup shape above (registered parent, landed worktree, quiet relay):
# with the NUL spliced mid-path the record reassembles the real registered
# parent under a NUL-dropping read, so before the parser rejected NUL this
# cleanup PROCEEDED - the refusal asserted here is the parser failing closed,
# not the fixture refusing for some unrelated reason.
test_secondmate_teardown_rejects_nul_bearing_durable_parent_record() {
  local parent child parent_resolved pre suf record
  parent=$(make_home teardown-durable-nul-parent relay-off)
  child="$TMP_ROOT/teardown-durable-nul-child"
  FM_SECONDMATE_CHARTER='Durable-record NUL regression charter.' \
    FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "real secondmate seeding failed"
  child=$(cd "$child" && pwd -P)
  parent_resolved=$(cd "$parent" && pwd -P)
  make_fake_curl "$child" >/dev/null
  fm_fake_exit0 "$child/fakebin" tmux no-mistakes gh gh-axi
  fm_fake_treehouse_legacy "$child/fakebin"
  assert_local_secondmate_parent_record "$child" "$parent_resolved"
  fm_write_meta "$parent/state/mate.meta" "kind=secondmate" "home=$child"
  fm_git_init_commit "$child/projects/worktree"
  printf 'manual\n' > "$child/config/backlog-backend"
  fm_write_meta "$child/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$child/projects/worktree" "project=$child/projects/worktree" \
    "kind=ship" "mode=local-only"
  pre=${parent_resolved%??????}
  suf=${parent_resolved#"$pre"}
  record="$child/.fm-secondmate-parent"
  {
    printf 'schema=fm-secondmate-parent.v1\nroute=local\n'
    printf 'parent_home=%s' "$pre"
    printf '\0'
    printf '%s\n' "$suf"
  } > "$record"

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" \
    expect_failure "a NUL-bearing durable parent record must refuse cleanup" \
    "$TEARDOWN" work-child
  assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate" \
    "a NUL-bearing durable parent record must produce the explicit binding refusal"
  assert_present "$child/state/work-child.meta" \
    "a NUL-bearing durable parent record must preserve child work metadata"
  pass "a NUL-bearing durable parent record fails closed before cleanup"
}

test_relay_disabled_unmarked_teardown_skips_public_path() {
  local home tasks_log out rc
  home=$(make_home teardown-disabled-unmarked relay-off)
  fm_git_init_commit "$home/projects/worktree"
  tasks_log="$home/tasks-axi.log"; : > "$tasks_log"
  printf 'manual\n' > "$home/config/backlog-backend"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TASKS_AXI_LOG"
exit 99
SH
  chmod +x "$home/fakebin/tasks-axi"
  fm_write_meta "$home/state/work-disabled.meta" \
    "window=firstmate:fm-work-disabled" "endpoint_task_id=work-disabled" \
    "worktree=$home/projects/worktree" "project=$home/projects/worktree" \
    "kind=ship" "mode=local-only"

  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FAKE_TASKS_AXI_LOG="$tasks_log" \
    "$TEARDOWN" work-disabled 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "relay-disabled unmarked teardown must not refuse public-followup cleanup (rc=$rc): $out"
  [ ! -s "$tasks_log" ] || fail "relay-disabled unmarked teardown must not invoke tasks-axi: $(tr '\n' ';' < "$tasks_log")"
  assert_not_contains "$out" "still owes a public reply" \
    "relay-disabled unmarked teardown must not run the public commitment guard"
  assert_absent "$home/state/public-followup" \
    "relay-disabled unmarked teardown must not create a public-followup artifact"
  pass "relay-disabled unmarked teardown runs no public-followup work"
}

test_relay_disabled_parent_allows_marked_child_teardown() {
  local parent child tasks_log out rc
  parent=$(make_home teardown-disabled-parent relay-off)
  child=$(make_home teardown-disabled-child relay-off)
  fm_git_init_commit "$child/projects/worktree"
  printf '%s\n' disabled-mate > "$child/.fm-secondmate-home"
  printf -- '- disabled-mate - synthetic (home: %s; scope: synthetic; projects: ; added 2026-07-30)\n' \
    "$child" > "$parent/data/secondmates.md"
  fm_write_meta "$parent/state/disabled-mate.meta" "kind=secondmate" "home=$child"
  tasks_log="$child/tasks-axi.log"; : > "$tasks_log"
  printf 'manual\n' > "$child/config/backlog-backend"
  cat > "$child/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TASKS_AXI_LOG"
exit 99
SH
  chmod +x "$child/fakebin/tasks-axi"
  fm_write_meta "$child/state/work-disabled.meta" \
    "window=firstmate:fm-work-disabled" "endpoint_task_id=work-disabled" \
    "worktree=$child/projects/worktree" "project=$child/projects/worktree" \
    "kind=ship" "mode=local-only"

  rc=0
  out=$(PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" \
    FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" FAKE_TASKS_AXI_LOG="$tasks_log" \
    "$TEARDOWN" work-disabled 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "relay-disabled parent must allow marked-child teardown (rc=$rc): $out"
  [ ! -s "$tasks_log" ] || fail "relay-disabled parent must not invoke tasks-axi for a marked child"
  assert_not_contains "$out" "still owes a public reply" \
    "relay-disabled parent must not run the public commitment guard"
  assert_absent "$child/state/public-followup" \
    "relay-disabled parent must not create a public-followup artifact"
  pass "a marked child proceeds without tasks-axi when its parent relay is disabled"
}

test_secondmate_parent_binding_matches_literal_id() {
  local parent child
  parent=$(make_home teardown-literal-parent)
  child=$(make_home teardown-literal-child)
  printf '%s\n' 'mate.id' > "$child/.fm-secondmate-home"
  printf -- '- mateXid - synthetic (home: %s; scope: synthetic; projects: ; added 2026-07-30)\n' \
    "$child" > "$parent/data/secondmates.md"
  seed_commitment "$parent" pf-teardown-literal req-teardown-literal x secondmate:mate.id work-literal
  fm_write_meta "$parent/state/mate.id.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-literal.meta" \
    "window=firstmate:fm-work-literal" "endpoint_task_id=work-literal" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only"

  PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" \
    expect_failure "a near-match registry id must not satisfy a dotted parent binding" \
    "$TEARDOWN" work-literal
  assert_contains "$EXPECT_OUT" "cannot resolve the primary home for marked secondmate mate.id" \
    "a dotted id must be matched as an exact registry field"
  assert_present "$child/state/work-literal.meta" \
    "a near-match parent binding must preserve the child work metadata"
  pass "secondmate parent resolution matches the durable registry id literally"
}

test_traversal_registration_is_refused_before_delivery() {
  local home log out
  home=$(make_home traversal-registration)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-traversal req-traversal x main work-traversal
  emit_terminal "$home" "$home" pf-traversal main work-traversal >/dev/null \
    || fail "emit failed for traversal registration"
  sed -i.bak 's/^work_home=.*/work_home=secondmate:..\/..\/x/' \
    "$home/state/public-followup/registry/pf-traversal"
  rm -f "$home/state/public-followup/registry/pf-traversal.bak"
  run_pf "$home" consume >/dev/null || fail "consume failed for traversal registration"

  out=$(FAKE_CURL_LOG="$log" run_pf "$home" deliver pf-traversal 2>&1) && \
    fail "a traversal-shaped registration must not be deliverable"
  assert_contains "$out" "registration for 'pf-traversal' is missing or invalid" \
    "a traversal-shaped work home must be rejected before delivery"
  [ "$(followup_posts "$log")" -eq 0 ] || fail "an invalid work home must not post publicly"
  assert_present "$home/state/public-followup/registry/pf-traversal" \
    "an invalid work home must retain its registration for reconciliation"
  [ "$(task_state "$home" pf-traversal)" != 'done' ] \
    || fail "an invalid work home must not close the obligation"
  pass "traversal-shaped registrations are rejected before path construction or posting"
}

test_pending_rejects_malformed_listing() {
  local home out
  home=$(make_home pending-malformed)
  seed_commitment "$home" pf-malformed req-malformed discord main work-malformed
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"public_followups":['
SH
  chmod +x "$home/fakebin/tasks-axi"

  out=$(run_pf "$home" pending) || fail "pending must survive malformed tasks-axi output"
  assert_contains "$out" "cannot read this home's public commitments through tasks-axi" \
    "malformed backlog output must use the loud fallback"
  assert_present "$home/state/public-followup/registry/pf-malformed" \
    "malformed backlog output must retain the registration"
  pass "pending keeps registrations when tasks-axi returns malformed JSON"
}

test_private_context_survives_inbox_cleanup() {
  local home log posts
  home=$(make_home context-retention)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-ctx req-ctx discord main work-ctx
  emit_terminal "$home" "$home" pf-ctx main work-ctx >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"

  # Drain the inbox exactly as answering the original mention does, and make any
  # relay fallback fail, so only the retained private context can resolve the
  # thread's platform and size budget.
  rm -f "$home/state/x-inbox/req-ctx.json"
  assert_present "$home/state/x-context/req-ctx.json" \
    "the private request context must outlive the inbox payload"

  FAKE_CURL_LOG="$log" FAKE_REQCTX_CODE=500 run_pf "$home" deliver pf-ctx >/dev/null \
    || fail "delivery must still resolve the thread from retained private context"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 1 ] || fail "expected one reply after inbox cleanup, got $posts"
  assert_grep '"request_id":"req-ctx"' "$log" "the reply must still target the original thread"
  pass "the retained private request context keeps the original thread deliverable after inbox cleanup"
}

# --- 6. completion semantics ---------------------------------------------------

test_cleanup_refuses_while_a_public_reply_is_owed() {
  local home rc
  home=$(make_home cleanup-guard)
  seed_commitment "$home" pf-guard req-guard discord main ship-task
  mkdir -p "$home/projects/sample"
  git -C "$home/projects/sample" init -q
  git -C "$home/projects/sample" config user.email test@example.com
  git -C "$home/projects/sample" config user.name Test
  printf '%s\n' fixture > "$home/projects/sample/fixture"
  git -C "$home/projects/sample" add fixture
  git -C "$home/projects/sample" commit -qm fixture
  git -C "$home/projects/sample" branch fm/ship-task
  git -C "$home/projects/sample" update-ref refs/remotes/origin/fm/ship-task HEAD
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/gone" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"

  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" ship-task \
    > "$home/teardown.out" 2> "$home/teardown.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup must refuse while a public reply is still owed"
  assert_grep "still owes a public reply" "$home/teardown.err" "the refusal must be explicit"
  assert_present "$home/state/ship-task.meta" "a refused cleanup must preserve the task record"

  # Once the reply has landed, the same cleanup is allowed to proceed.
  emit_terminal "$home" "$home" pf-guard main ship-task >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"
  FAKE_CURL_LOG="$home/curl.log" run_pf "$home" deliver pf-guard >/dev/null || fail "delivery failed"
  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" ship-task \
    > "$home/teardown-landed.out" 2> "$home/teardown-landed.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "cleanup must proceed once the public reply has landed (rc=$rc): $(cat "$home/teardown-landed.err")"
  pass "cleanup refuses while a public reply is owed and proceeds once it has landed"
}

# --- 7. zero overhead for homes that do not use the relay ----------------------

# The hard acceptance criterion. A home that never opted into the myfirstmate
# relay must see no process, no tasks-axi call, no scan, no output, and no file.
test_relay_disabled_home_pays_nothing() {
  local home tasks_log out rc before after cmd
  home=$(make_home relay-disabled relay-off)
  tasks_log="$home/tasks-axi.log"; : > "$tasks_log"
  # Any tasks-axi invocation at all is a failure here, so make it loud.
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TASKS_AXI_LOG"
exit 0
SH
  chmod +x "$home/fakebin/tasks-axi"

  before=$(find "$home/state" | LC_ALL=C sort)
  for cmd in "consume" "pending" "guard-work main any-task" "retire anything"; do
    rc=0
    # shellcheck disable=SC2086  # each cmd is a deliberate argument list
    out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FAKE_TASKS_AXI_LOG="$tasks_log" "$PF" $cmd 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "'$cmd' must be a silent success in a relay-disabled home (rc=$rc)"
    [ -z "$out" ] || fail "'$cmd' must print nothing in a relay-disabled home, got: $out"
  done

  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FAKE_TASKS_AXI_LOG="$tasks_log" "$PF" active || rc=$?
  [ "$rc" -eq 1 ] || fail "'active' must report inactive in a relay-disabled home"

  [ ! -s "$tasks_log" ] \
    || fail "a relay-disabled home must never invoke tasks-axi: $(cat "$tasks_log")"
  after=$(find "$home/state" | LC_ALL=C sort)
  [ "$before" = "$after" ] \
    || fail "a relay-disabled home must gain no public-followup artifact"
  assert_absent "$home/state/public-followup" \
    "a relay-disabled home must never get a public-followup directory"

  # A child cannot force artifacts into a home that never opted in either.
  rc=0
  out=$("$EMIT" --home "$home" --obligation pf-x --relation rel-code \
    --source-home main --work-id w --generation 1 --outcome pr-merged \
    --outcome-text 'x' 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "emitting into a relay-disabled home must be a silent no-op (rc=$rc)"
  [ -z "$out" ] || fail "emitting into a relay-disabled home must produce no output: $out"
  assert_absent "$home/state/public-followup" \
    "a refused emit must not create a public-followup directory"
  pass "a relay-disabled home runs no tasks-axi call, prints nothing, and gains no artifact"
}

# An opted-in home that has never made a public commitment must not start paying
# either: the second gate is a directory presence check, not a backlog scan.
test_relay_enabled_empty_state_makes_no_calls() {
  local home tasks_log out rc cmd
  home=$(make_home relay-enabled-empty)
  tasks_log="$home/tasks-axi.log"; : > "$tasks_log"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TASKS_AXI_LOG"
exit 0
SH
  chmod +x "$home/fakebin/tasks-axi"

  for cmd in "consume" "pending" "guard-work main any-task"; do
    rc=0
    # shellcheck disable=SC2086  # each cmd is a deliberate argument list
    out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FAKE_TASKS_AXI_LOG="$tasks_log" "$PF" $cmd 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "'$cmd' must be a silent success with no commitments (rc=$rc)"
    [ -z "$out" ] || fail "'$cmd' must print nothing with no commitments, got: $out"
  done
  [ ! -s "$tasks_log" ] \
    || fail "an empty relay home must not query the backlog: $(cat "$tasks_log")"
  pass "a relay-enabled home with no commitments makes no backlog call and stays silent"
}

# The relay's own refusal of an exhausted follow-up binding is a captain
# decision, not something to retry into a public thread.
test_exhausted_binding_is_not_retried() {
  local home log out posts
  home=$(make_home exhausted)
  log="$home/curl.log"; : > "$log"
  seed_commitment "$home" pf-gone req-gone x main work-gone
  emit_terminal "$home" "$home" pf-gone main work-gone >/dev/null || fail "emit failed"
  run_pf "$home" consume >/dev/null || fail "consume failed"

  FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=409 \
    expect_failure "an exhausted binding must not be reported as delivered" \
    run_pf "$home" deliver pf-gone
  assert_contains "$EXPECT_OUT" "captain decision" "an exhausted binding must be escalated, not retried"
  [ "$(delivery_state "$home" pf-gone)" = expired-action-required ] \
    || fail "an exhausted binding must be recorded as needing action, got $(delivery_state "$home" pf-gone)"
  [ "$(task_state "$home" pf-gone)" != 'done' ] \
    || fail "an exhausted binding must never close the commitment"
  posts=$(followup_posts "$log")
  [ "$posts" -eq 1 ] || fail "the refused attempt is one relay call, got $posts"
  pass "a relay-exhausted follow-up binding is escalated rather than retried into the thread"
}

# The relay poll is the only thing that runs on a cadence in an opted-in home, so
# it must stay a hard no-op without a token, and must not start scanning when a
# relay-enabled home has no public commitments at all.
test_relay_poll_stays_inert_and_surfaces_once() {
  local off on out first second
  off=$(make_home poll-off relay-off)
  out=$(PATH="$off/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$off" \
    FM_STATE_OVERRIDE="$off/state" "$POLL" 2>&1)
  [ -z "$out" ] || fail "the relay poll must stay silent without a token, got: $out"
  assert_absent "$off/state/public-followup" "an inert poll must create nothing"

  on=$(make_home poll-on)
  out=$(PATH="$on/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$on" \
    FM_STATE_OVERRIDE="$on/state" "$POLL" 2>&1)
  assert_not_contains "$out" "public-followup" \
    "a relay home with no public commitments must not mention public follow-ups"

  seed_commitment "$on" pf-poll req-poll discord main work-poll
  out=$(PATH="$on/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$on" \
    FM_STATE_OVERRIDE="$on/state" "$POLL" 2>&1)
  assert_not_contains "$out" "public-followup" \
    "a registered commitment with no terminal result yet must not wake the poll"

  emit_terminal "$on" "$on" pf-poll main work-poll >/dev/null || fail "emit failed"
  first=$(PATH="$on/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$on" \
    FM_STATE_OVERRIDE="$on/state" "$POLL" 2>&1)
  assert_contains "$first" "public-followup terminal results are waiting" \
    "a new terminal result must surface through the existing relay poll"
  second=$(PATH="$on/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$on" \
    FM_STATE_OVERRIDE="$on/state" "$POLL" 2>&1)
  assert_not_contains "$second" "public-followup" \
    "an unchanged pending set must not wake firstmate again every cycle"
  pass "the relay poll stays inert without a token, silent with no commitments, and surfaces a new result once"
}

# --- 8. startup surfacing ------------------------------------------------------

test_session_start_surfaces_only_when_owed() {
  local off on out
  off=$(make_home startup-off relay-off)
  out=$(PATH="$off/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$off" \
    FM_STATE_OVERRIDE="$off/state" FM_DATA_OVERRIDE="$off/data" \
    FM_CONFIG_OVERRIDE="$off/config" "$SESSION_START" 2>&1)
  assert_not_contains "$out" "Public commitments" \
    "a relay-disabled home must not gain a public-commitments section at startup"

  on=$(make_home startup-on)
  seed_commitment "$on" pf-start req-start discord main work-start
  out=$(PATH="$on/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$on" \
    FM_STATE_OVERRIDE="$on/state" FM_DATA_OVERRIDE="$on/data" \
    FM_CONFIG_OVERRIDE="$on/config" "$SESSION_START" 2>&1)
  assert_contains "$out" "Public commitments awaiting delivery" \
    "an unresolved commitment must be surfaced at startup"
  assert_contains "$out" "unresolved pf-start state=pending-work platform=discord" \
    "the startup summary must be typed and actionable"
  assert_contains "$out" "fix worker placement when two spaces share a name" \
    "the startup summary must carry the public-safe summary"
  assert_not_contains "$out" "please fix worker placement" \
    "the startup summary must not carry raw request text"
  pass "startup surfaces unresolved public commitments only in a relay home that owes one"
}

# --- 9. typed records stay public-safe ----------------------------------------

test_typed_records_exclude_raw_public_material() {
  local home backlog event
  home=$(make_home privacy)
  seed_commitment "$home" pf-priv req-priv discord main work-priv
  emit_terminal "$home" "$home" pf-priv main work-priv >/dev/null || fail "emit failed"
  event=$(find "$home/state/public-followup/events" -name '*.json' | head -1)
  assert_no_grep 'please fix worker placement' "$event" \
    "a terminal event must not carry raw request text"
  run_pf "$home" consume >/dev/null || fail "consume failed"

  backlog="$home/data/backlog.md"
  assert_no_grep 'please fix worker placement' "$backlog" \
    "the backlog must never carry raw public message text"
  # The typed record is base64url canonical JSON, so check the decoded payload too.
  tasks_in "$home" public-followup list --json > "$home/typed.json"
  assert_no_grep 'please fix worker placement' "$home/typed.json" \
    "the typed obligation must never carry raw public message text"
  pass "typed public-followup records carry only public-safe summaries and deliverables"
}

test_outcome_text_is_bounded_without_corrupting_characters
test_restart_e2e_delivers_exactly_once
test_duplicate_event_and_replay_are_noops
test_invalid_events_are_refused_and_quarantined
test_relay_failure_holds_without_false_completion
test_dry_run_does_not_close_commitment
test_late_receipt_closes_the_exact_attempt_without_reposting
test_typed_terminal_clear_only_removes_legacy_link
test_interrupted_delivery_refuses_to_repost
test_outward_delivery_stays_with_the_owning_home
test_delivery_requires_registration_before_posting
test_secondmate_teardown_requires_parent_binding
test_local_secondmate_seed_publishes_parent_before_identity
test_secondmate_teardown_resolves_parent_from_durable_record_when_env_lost
test_secondmate_teardown_durable_record_missing_parent_registration_still_refuses
test_secondmate_teardown_durable_record_with_unknown_field_succeeds
test_secondmate_teardown_rejects_conflicting_live_and_durable_parent_bindings
test_secondmate_teardown_rejects_unsafe_durable_parent_records
test_secondmate_teardown_rejects_nul_bearing_durable_parent_record
test_relay_disabled_unmarked_teardown_skips_public_path
test_relay_disabled_parent_allows_marked_child_teardown
test_secondmate_parent_binding_matches_literal_id
test_traversal_registration_is_refused_before_delivery
test_pending_rejects_malformed_listing
test_private_context_survives_inbox_cleanup
test_cleanup_refuses_while_a_public_reply_is_owed
test_relay_disabled_home_pays_nothing
test_relay_enabled_empty_state_makes_no_calls
test_exhausted_binding_is_not_retried
test_relay_poll_stays_inert_and_surfaces_once
test_session_start_surfaces_only_when_owed
test_typed_records_exclude_raw_public_material
