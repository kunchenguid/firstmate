#!/usr/bin/env bash
# Behavior tests for firstmate's durable Linear synchronization.
#
# The rule this suite pins: work is not complete until the corresponding Linear
# issue is current. Every case here is about one of the three ways that rule
# breaks in practice - a target that was never established, an acknowledgement
# lost between Linear committing a comment and firstmate recording it, and a
# disconnected Linear quietly turning an owed handback into a claimed completion.
#
# Everything is hermetic. The Linear transport is a fake that keeps its whole
# workspace in a temp directory, so no credential is needed, no network call is
# made, and no Linear mutation ever happens. The one case that exercises the real
# bin/fm-linear-transport.sh substitutes a fake `curl` and asserts only local
# secret handling.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-linear-sync.sh"
TRANSPORT="$ROOT/bin/fm-linear-transport.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear-sync)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- the hermetic fake Linear workspace -------------------------------------
#
# One executable satisfying bin/fm-linear-transport.sh's contract, backed by
# plain files. It records every operation, so a test can prove exactly how many
# comments were created and how many status changes were applied.
#
# FAKE_LINEAR_MODE injects the failures that matter:
#   transport-fail  the exchange never completes (network down)
#   http-500        Linear answers, unhappily
#   issue-missing   the issue does not exist on this workspace
#   drop-ack        the comment IS committed and the acknowledgement is lost -
#                   the exact interval a local receipt cannot cover
#   status-fail     the comment lands and the status change does not
make_fake_linear() {  # <dir>
  local path="$1/fake-linear.sh"
  mkdir -p "$1"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
req=$1
resp=$2
d=${FAKE_LINEAR_DIR:?}
mode=${FAKE_LINEAR_MODE:-}
op=$(jq -r '.query' < "$req" | grep -o 'FmLinear[A-Za-z]*' | head -n1)
printf 'op=%s\n' "$op" >> "$d/log"
cp "$req" "$d/last-request.json"
cat "$req" >> "$d/requests.log"

case "$mode" in
  transport-fail) echo "fake-linear: no network" >&2; exit 4 ;;
  http-500) printf '{}' > "$resp"; printf '500\n'; exit 0 ;;
esac

fail_json() {  # <message>
  jq -n --arg m "$1" '{errors:[{message:$m}]}' > "$resp"
  printf '200\n'
  exit 0
}

case "$op" in
  FmLinearIssue)
    ref=$(jq -r '.variables.id' < "$req")
    first=$(jq -r '.variables.first' < "$req")
    after=$(jq -r '.variables.after // ""' < "$req")
    meta="$d/issue.$ref"
    if [ "$mode" = issue-missing ] || [ ! -f "$meta" ]; then
      printf '{"data":{"issue":null}}' > "$resp"
      printf '200\n'
      exit 0
    fi
    # shellcheck disable=SC1090
    . "$meta"
    cfile="$d/comments.$ref"
    [ -f "$cfile" ] || : > "$cfile"
    total=$(grep -c . "$cfile" || true)
    start=${after:-0}
    [ -n "$start" ] || start=0
    end=$((start + first))
    [ "$end" -le "$total" ] || end=$total
    nodes=$(sed -n "$((start + 1)),${end}p" "$cfile" | jq -s '.')
    hasnext=false
    [ "$end" -ge "$total" ] || hasnext=true
    jq -n --arg id "$ISSUE_ID" --arg ident "$ref" --arg sid "$STATE_ID" \
      --arg sname "$STATE_NAME" --arg team "$TEAM_ID" --argjson nodes "$nodes" \
      --argjson hasnext "$hasnext" --arg cursor "$end" \
      '{data:{issue:{id:$id, identifier:$ident, state:{id:$sid, name:$sname},
        team:{id:$team},
        comments:{pageInfo:{hasNextPage:$hasnext, endCursor:$cursor}, nodes:$nodes}}}}' \
      > "$resp"
    printf '200\n'
    ;;
  FmLinearStates)
    team=$(jq -r '.variables.teamId' < "$req")
    sfile="$d/states.$team"
    [ -f "$sfile" ] || fail_json "no such team"
    jq -s '{data:{team:{states:{nodes:.}}}}' < "$sfile" > "$resp"
    printf '200\n'
    ;;
  FmLinearComment)
    issue_id=$(jq -r '.variables.issueId' < "$req")
    ref=$(cat "$d/byid.$issue_id" 2>/dev/null) || ref=
    [ -n "$ref" ] || fail_json "unknown issue id"
    cfile="$d/comments.$ref"
    [ -f "$cfile" ] || : > "$cfile"
    n=$(( $(grep -c . "$cfile" || true) + 1 ))
    jq -cn --arg id "c$n" --rawfile body <(jq -j '.variables.body' < "$req") \
      '{id:$id, body:$body}' >> "$cfile"
    printf 'comment-created=%s\n' "$ref" >> "$d/log"
    if [ "$mode" = drop-ack ]; then
      echo "fake-linear: acknowledgement lost after commit" >&2
      exit 4
    fi
    jq -n --arg id "c$n" '{data:{commentCreate:{success:true, comment:{id:$id}}}}' > "$resp"
    printf '200\n'
    ;;
  FmLinearStatus)
    issue_id=$(jq -r '.variables.id' < "$req")
    state_id=$(jq -r '.variables.stateId' < "$req")
    ref=$(cat "$d/byid.$issue_id" 2>/dev/null) || ref=
    [ -n "$ref" ] || fail_json "unknown issue id"
    if [ "$mode" = status-fail ]; then
      printf 'status-refused=%s\n' "$ref" >> "$d/log"
      fail_json "state change rejected"
    fi
    name=$(jq -r --arg i "$state_id" 'select(.id == $i) | .name' < "$d/states.$(grep '^TEAM_ID=' "$d/issue.$ref" | cut -d= -f2)" | head -n1)
    sed -i.bak "s/^STATE_ID=.*/STATE_ID=$state_id/; s/^STATE_NAME=.*/STATE_NAME=$name/" "$d/issue.$ref"
    rm -f "$d/issue.$ref.bak"
    printf 'status-applied=%s=%s\n' "$ref" "$name" >> "$d/log"
    jq -n --arg id "$issue_id" --arg n "$name" \
      '{data:{issueUpdate:{success:true, issue:{id:$id, state:{id:"s", name:$n}}}}}' > "$resp"
    printf '200\n'
    ;;
  *)
    fail_json "unsupported operation"
    ;;
esac
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

# seed_issue <fake-dir> <REF> <team-id> <current-state-name>
# The API uuid comes from a per-workspace counter, not $RANDOM: two issues in one
# fake workspace must never collide on the id the comment path resolves through.
seed_issue() {
  local d=$1 ref=$2 team=$3 state=$4 uuid seq
  seq=$(( $(cat "$d/.issue-seq" 2>/dev/null || printf 0) + 1 ))
  printf '%s\n' "$seq" > "$d/.issue-seq"
  uuid="00000000-0000-4000-8000-$(printf '%012d' "$seq")"
  cat > "$d/issue.$ref" <<EOF
ISSUE_ID=$uuid
TEAM_ID=$team
STATE_ID=state-todo
STATE_NAME=$state
EOF
  printf '%s\n' "$ref" > "$d/byid.$uuid"
  : > "$d/comments.$ref"
  cat > "$d/states.$team" <<'EOF'
{"id":"state-todo","name":"Todo"}
{"id":"state-progress","name":"In Progress"}
{"id":"state-done","name":"Done"}
EOF
}

# --- primary-shaped firstmate homes -----------------------------------------
#
# The scoping predicate (bin/fm-primary-scope-lib.sh) needs a plain, non-worktree
# git checkout carrying AGENTS.md, bin/, and state/. Building the real shape here
# is what lets the scoping cases below use genuine linked worktrees instead of a
# stand-in.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/bin" "$home/projects"
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  make_fake_linear "$home" >/dev/null
  mkdir -p "$home/linear-fake"
  printf '%s\n' "$home"
}

fake_dir() { printf '%s\n' "$1/linear-fake"; }

run_sync() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_LINEAR_TRANSPORT="$home/fake-linear.sh" \
    FAKE_LINEAR_DIR="$(fake_dir "$home")" \
    FAKE_LINEAR_MODE="${FAKE_LINEAR_MODE:-}" \
    FM_LINEAR_COMMENT_PAGE_SIZE="${FM_LINEAR_COMMENT_PAGE_SIZE:-100}" \
    FM_LINEAR_COMMENT_PAGE_MAX="${FM_LINEAR_COMMENT_PAGE_MAX:-10}" \
    "$SYNC" "$@"
}

# A credential file exactly as docs/linear-sync.md tells an operator to create it.
write_credential() {  # <home> [key]
  local home=$1 key=${2:-lin_api_TESTKEYqqq0000}
  ( umask 077; printf 'LINEAR_API_KEY=%s\n' "$key" > "$home/config/linear.env" )
  chmod 600 "$home/config/linear.env"
}

queue_comment() {  # <home> <task> <text> [extra sync args...]
  local home=$1 task=$2 text=$3
  shift 3
  printf '%s\n' "$text" > "$home/comment.md"
  run_sync "$home" queue "$task" --comment-file "$home/comment.md" "$@"
}

# grep -c prints 0 and exits 1 on no match, so `|| true` (not `|| printf 0`) is
# what keeps these to a single number.
comment_count() {  # <home> <REF>
  local f
  f="$(fake_dir "$1")/comments.$2"
  if [ -f "$f" ]; then grep -c . "$f" || true; else printf '0\n'; fi
}

log_count() {  # <home> <pattern>
  local f
  f="$(fake_dir "$1")/log"
  if [ -f "$f" ]; then grep -c "$2" "$f" || true; else printf '0\n'; fi
}

# One entry name from a private record directory, with an optional suffix
# trimmed. A glob rather than `ls` so an odd filename cannot be mis-split.
one_id() {  # <dir> [suffix]
  local dir=$1 suffix=${2-} entry name
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    name=$(basename "$entry")
    printf '%s\n' "${name%"$suffix"}"
    return 0
  done
  return 1
}

file_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

expect_failure() {  # <label> <cmd...>
  local label=$1 rc=0
  shift
  "$@" > "$TMP_ROOT/expect.out" 2> "$TMP_ROOT/expect.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected a refusal, got exit 0"
  printf '%s\n' "$rc"
}

# --- 1. targets are established, never inferred ------------------------------

test_missing_and_ambiguous_targets_refuse() {
  local home rc out
  home=$(make_home targets)
  write_credential "$home"

  rc=0
  queue_comment "$home" unbound-task 'shipped it' > "$home/q.out" 2> "$home/q.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unbound task must refuse to queue (rc=$rc)"
  assert_grep "has no Linear issue binding" "$home/q.err" \
    "the refusal must name the missing binding, not guess a target"
  assert_absent "$home/state/linear/outbox" "a refused queue must leave no delivery"

  run_sync "$home" bind two-issue-task ENG-11 ENG-12 >/dev/null || fail "bind failed"
  rc=0
  queue_comment "$home" two-issue-task 'shipped it' > "$home/q2.out" 2> "$home/q2.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an ambiguous binding must refuse (rc=$rc)"
  assert_grep "bound to 2 Linear issues" "$home/q2.err" "the refusal must say why it is ambiguous"

  rc=0
  queue_comment "$home" two-issue-task 'shipped it' --issue ENG-99 \
    > "$home/q3.out" 2> "$home/q3.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unbound issue must refuse even when named explicitly"
  assert_grep "is not bound to task" "$home/q3.err" "naming an unbound issue must refuse"

  queue_comment "$home" two-issue-task 'shipped it' --issue ENG-12 >/dev/null \
    || fail "naming one bound issue must resolve the ambiguity"
  out=$(run_sync "$home" pending two-issue-task)
  assert_contains "$out" "issue=ENG-12" "the queued handback must target the named issue"

  rc=0
  run_sync "$home" bind bad-task 'not an issue' > /dev/null 2> "$home/q4.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a prose target must refuse to bind"
  assert_grep "not a Linear issue reference" "$home/q4.err" "binding must validate the reference shape"

  pass "an unbound task, an ambiguous binding, and a prose target all refuse instead of guessing"
}

test_comment_content_is_validated() {
  local home rc big
  home=$(make_home content)
  run_sync "$home" bind task-a ENG-1 >/dev/null || fail "bind failed"

  rc=0
  printf '' > "$home/empty.md"
  run_sync "$home" queue task-a --comment-file "$home/empty.md" >/dev/null 2> "$home/e1" || rc=$?
  [ "$rc" -eq 1 ] || fail "an empty comment must refuse"
  assert_grep "refusing to post nothing" "$home/e1" "an empty comment must say so"

  rc=0
  queue_comment "$home" task-a 'sneaky fm-linear-sync:deadbeef' >/dev/null 2> "$home/e2" || rc=$?
  [ "$rc" -eq 1 ] || fail "a comment carrying the reserved marker prefix must refuse"
  assert_grep "reserved marker prefix" "$home/e2" "a forged marker must be named as such"

  big=$(head -c 7000 /dev/zero | tr '\0' 'x')
  rc=0
  queue_comment "$home" task-a "$big" >/dev/null 2> "$home/e3" || rc=$?
  [ "$rc" -eq 1 ] || fail "an oversized comment must refuse"
  assert_grep "over the" "$home/e3" "the size refusal must name the limit"

  rc=0
  queue_comment "$home" task-a 'bad status' --status "$(printf 'Done\001')" >/dev/null 2> "$home/e4" || rc=$?
  [ "$rc" -eq 1 ] || fail "a control character in the status must refuse"

  assert_absent "$home/state/linear/outbox" "no refused input may leave a delivery record"
  pass "an empty comment, a forged marker, an oversized body, and a malformed status all refuse"
}

# --- 2. delivery, and its idempotence ---------------------------------------

test_delivery_posts_once_and_sets_status() {
  local home out
  home=$(make_home deliver)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-42 team-1 Todo
  run_sync "$home" bind ship-1 ENG-42 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-1 'Landed: https://example.invalid/pr/7' --status Done >/dev/null \
    || fail "queue failed"

  run_sync "$home" deliver --all > "$home/d1.out" 2> "$home/d1.err" \
    || fail "delivery failed: $(cat "$home/d1.err")"
  assert_grep "delivered ship-1 -> ENG-42" "$home/d1.out" "delivery must report the issue it updated"
  [ "$(comment_count "$home" ENG-42)" -eq 1 ] || fail "expected exactly one comment"
  [ "$(log_count "$home" '^status-applied=ENG-42=Done$')" -eq 1 ] || fail "expected one status change"
  assert_present "$home/state/linear/sent" "delivery must leave a receipt"
  [ -z "$(run_sync "$home" pending)" ] || fail "a delivered handback must leave the pending set"

  # The posted body carries the captain's text and the read-back marker, nothing else.
  out=$(jq -r '.body' < <(head -n1 "$(fake_dir "$home")/comments.ENG-42"))
  assert_contains "$out" "Landed: https://example.invalid/pr/7" "the comment must carry the exact text"
  assert_contains "$out" "fm-linear-sync:" "the comment must carry its read-back marker"

  # Delivering again is a no-op in every direction.
  run_sync "$home" deliver --all >/dev/null 2>&1 || true
  [ "$(comment_count "$home" ENG-42)" -eq 1 ] || fail "a repeated delivery must not post again"
  [ "$(log_count "$home" '^status-applied=')" -eq 1 ] || fail "a repeated delivery must not restatus"
  pass "a delivery posts one comment, applies the status once, and repeats as a no-op"
}

test_requeueing_the_same_handback_is_one_delivery() {
  local home first second
  home=$(make_home requeue)
  run_sync "$home" bind ship-2 ENG-7 >/dev/null || fail "bind failed"
  first=$(queue_comment "$home" ship-2 'same text' --status Done)
  second=$(queue_comment "$home" ship-2 'same text' --status Done)
  assert_contains "$first" "queued ship-2" "the first queue must create the delivery"
  assert_contains "$second" "already queued ship-2" "the second must resolve to the same delivery"
  [ "$(run_sync "$home" pending | grep -c .)" -eq 1 ] \
    || fail "the same handback must never queue twice"

  # A different status is a different handback, so it gets its own delivery.
  queue_comment "$home" ship-2 'same text' --status "In Progress" >/dev/null || fail "queue failed"
  [ "$(run_sync "$home" pending | grep -c .)" -eq 2 ] \
    || fail "a different status must be a distinct handback"
  pass "re-queueing an identical handback resolves to one delivery, and a changed one is distinct"
}

# --- 3. the lost-acknowledgement interval -----------------------------------

test_lost_acknowledgement_converges_without_a_duplicate() {
  local home rc
  home=$(make_home lost-ack)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-50 team-1 Todo
  run_sync "$home" bind ship-3 ENG-50 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-3 'the fix is on main' >/dev/null || fail "queue failed"

  # Linear commits the comment and the acknowledgement never arrives. This is the
  # exact interval a local receipt cannot cover.
  rc=0
  FAKE_LINEAR_MODE=drop-ack run_sync "$home" deliver --all >/dev/null 2> "$home/d.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a lost acknowledgement must hold, not complete (rc=$rc)"
  [ "$(comment_count "$home" ENG-50)" -eq 1 ] || fail "the fake must have committed the comment"
  assert_absent "$home/state/linear/sent/$(one_id "$home/state/linear/outbox" .json)" \
    "no receipt may exist for an unacknowledged post"
  [ -n "$(run_sync "$home" pending ship-3)" ] || fail "the handback must still be owed"

  # The retry must find Linear's own copy of the marker and converge.
  run_sync "$home" deliver --all > "$home/d2.out" 2> "$home/d2.err" \
    || fail "the retry must converge: $(cat "$home/d2.err")"
  [ "$(comment_count "$home" ENG-50)" -eq 1 ] || fail "the retry must not post a second comment"
  assert_grep "read-back" "$home/d2.out" "the retry must report that it converged from the read-back"
  [ -z "$(run_sync "$home" pending)" ] || fail "the converged handback must leave the pending set"
  pass "a comment committed by Linear with a lost acknowledgement converges with no duplicate"
}

test_a_destroyed_receipt_does_not_repost() {
  local home id
  home=$(make_home receipt-loss)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-51 team-1 Todo
  run_sync "$home" bind ship-4 ENG-51 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-4 'done and dusted' --status Done >/dev/null || fail "queue failed"
  run_sync "$home" deliver --all >/dev/null || fail "delivery failed"
  id=$(one_id "$home/state/linear/sent")

  # Simulate a home restored from an older copy: the receipt is gone and the
  # handback is queued again by the same deterministic identity.
  rm -f "$home/state/linear/sent/$id"
  queue_comment "$home" ship-4 'done and dusted' --status Done >/dev/null || fail "re-queue failed"
  run_sync "$home" deliver --all >/dev/null || fail "re-delivery failed"
  [ "$(comment_count "$home" ENG-51)" -eq 1 ] || fail "a lost receipt must not produce a second comment"
  [ "$(log_count "$home" '^status-applied=')" -eq 1 ] || fail "a lost receipt must not restatus"
  pass "a lost local receipt is recovered from Linear's own copy, never by reposting"
}

test_truncated_read_back_refuses_to_post() {
  local home rc i
  home=$(make_home truncated)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-60 team-1 Todo
  for i in $(seq 1 12); do
    jq -cn --arg id "old$i" '{id:$id, body:"unrelated chatter"}' \
      >> "$(fake_dir "$home")/comments.ENG-60"
  done
  run_sync "$home" bind ship-5 ENG-60 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-5 'a handback on a very long issue' >/dev/null || fail "queue failed"

  rc=0
  FM_LINEAR_COMMENT_PAGE_SIZE=2 FM_LINEAR_COMMENT_PAGE_MAX=2 \
    run_sync "$home" deliver --all >/dev/null 2> "$home/t.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a truncated read-back must hold, not post (rc=$rc)"
  [ "$(comment_count "$home" ENG-60)" -eq 12 ] || fail "a truncated read-back must post nothing"
  assert_grep "could not confirm the current state" "$home/t.err" \
    "the hold must say the issue state was unconfirmed"
  [ -n "$(run_sync "$home" pending ship-5)" ] || fail "the handback must still be owed"

  # With a read-back that can complete, the same delivery proceeds exactly once.
  run_sync "$home" deliver --all >/dev/null || fail "delivery failed once the read-back completes"
  [ "$(comment_count "$home" ENG-60)" -eq 13 ] || fail "exactly one comment must be added"
  pass "a read-back that cannot be completed holds rather than risking a duplicate"
}

# --- 4. disconnected Linear never becomes a completion ----------------------

test_disconnected_linear_preserves_the_handback() {
  local home rc out
  home=$(make_home disconnected)
  seed_issue "$(fake_dir "$home")" ENG-70 team-1 Todo
  run_sync "$home" bind ship-6 ENG-70 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-6 'this must not be lost' --status Done >/dev/null || fail "queue failed"

  # No credential at all: the disconnected case an operator hits before OAuth.
  rc=0
  run_sync "$home" deliver --all >/dev/null 2> "$home/c1.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a disconnected Linear must hold, not fail-and-forget (rc=$rc)"
  [ "$(grep -c . "$home/c1.err")" -le 2 ] || fail "the blocker must stay concise"
  assert_grep "Linear is not connected" "$home/c1.err" "the blocker must name the actual problem"
  assert_grep "still owed" "$home/c1.err" "the blocker must say the handback survives"
  [ "$(comment_count "$home" ENG-70)" -eq 0 ] || fail "nothing may be posted while disconnected"

  # Repeated runs converge: still exactly one owed handback, no duplicate record.
  run_sync "$home" deliver --all >/dev/null 2>&1 || true
  run_sync "$home" deliver --all >/dev/null 2>&1 || true
  [ "$(run_sync "$home" pending | grep -c .)" -eq 1 ] \
    || fail "repeated disconnected runs must not multiply the owed handback"
  out=$(run_sync "$home" pending ship-6)
  assert_contains "$out" "no Linear credential" "the pending line must carry the current reason"

  # A malformed credential is refused rather than used.
  printf 'LINEAR_API_KEY=has space\n' > "$home/config/linear.env"
  chmod 600 "$home/config/linear.env"
  rc=0
  run_sync "$home" deliver --all >/dev/null 2> "$home/c2.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a malformed credential must hold"
  assert_grep "not a single-line credential" "$home/c2.err" "a malformed credential must be named"

  # A world-readable credential is refused rather than used.
  write_credential "$home"
  chmod 644 "$home/config/linear.env"
  rc=0
  run_sync "$home" deliver --all >/dev/null 2> "$home/c3.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a world-readable credential must hold"
  assert_grep "must be mode 0600" "$home/c3.err" "the credential mode requirement must be explicit"

  # Once connected, the preserved handback lands exactly once.
  write_credential "$home"
  run_sync "$home" deliver --all >/dev/null || fail "delivery must succeed once connected"
  [ "$(comment_count "$home" ENG-70)" -eq 1 ] || fail "the preserved handback must land exactly once"
  pass "a disconnected or misconfigured Linear preserves the handback and never claims completion"
}

test_transport_failure_holds_then_lands_once() {
  local home rc
  home=$(make_home transport-fail)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-80 team-1 Todo
  run_sync "$home" bind ship-7 ENG-80 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-7 'retry me' >/dev/null || fail "queue failed"

  rc=0
  FAKE_LINEAR_MODE=transport-fail run_sync "$home" deliver --all >/dev/null 2> "$home/f1" || rc=$?
  [ "$rc" -eq 3 ] || fail "an unreachable Linear must hold (rc=$rc)"
  rc=0
  FAKE_LINEAR_MODE=http-500 run_sync "$home" deliver --all >/dev/null 2> "$home/f2" || rc=$?
  [ "$rc" -eq 3 ] || fail "an HTTP 500 must hold (rc=$rc)"
  [ "$(comment_count "$home" ENG-80)" -eq 0 ] || fail "a failed exchange must post nothing"

  run_sync "$home" deliver --all >/dev/null || fail "the retry must succeed"
  [ "$(comment_count "$home" ENG-80)" -eq 1 ] || fail "the retry must post exactly once"
  pass "an unreachable Linear holds the handback and the later retry posts exactly once"
}

test_a_partial_delivery_completes_its_status_without_reposting() {
  local home rc
  home=$(make_home partial)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-90 team-1 Todo
  run_sync "$home" bind ship-8 ENG-90 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-8 'comment lands, status does not' --status Done >/dev/null \
    || fail "queue failed"

  rc=0
  FAKE_LINEAR_MODE=status-fail run_sync "$home" deliver --all >/dev/null 2> "$home/p.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "an unapplied status must hold the delivery (rc=$rc)"
  [ "$(comment_count "$home" ENG-90)" -eq 1 ] || fail "the comment must have landed"
  assert_grep "status change" "$home/p.err" "the hold must name the status as the missing half"
  [ -n "$(run_sync "$home" pending ship-8)" ] || fail "a half-applied handback is still owed"

  run_sync "$home" deliver --all >/dev/null || fail "the retry must complete the status change"
  [ "$(comment_count "$home" ENG-90)" -eq 1 ] || fail "the retry must not repost the comment"
  [ "$(log_count "$home" '^status-applied=ENG-90=Done$')" -eq 1 ] || fail "the status must be applied once"
  [ -z "$(run_sync "$home" pending)" ] || fail "the completed handback must leave the pending set"
  pass "a comment that landed without its status is completed on retry with no second comment"
}

test_an_unknown_issue_is_quarantined_and_still_blocks() {
  local home rc out
  home=$(make_home unknown-issue)
  write_credential "$home"
  run_sync "$home" bind ship-9 ENG-404 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-9 'nowhere to put this' >/dev/null || fail "queue failed"

  rc=0
  run_sync "$home" deliver --all >/dev/null 2> "$home/u.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an issue Linear does not have must refuse (rc=$rc)"
  assert_grep "does not have issue ENG-404" "$home/u.err" "the refusal must name the issue"
  out=$(run_sync "$home" pending ship-9)
  assert_contains "$out" "refused" "a refused handback must stay visible as pending work"
  rc=$(expect_failure "a refused handback still blocks completion" \
    env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work ship-9)
  [ "$rc" -eq 1 ] || fail "guard-work must refuse on a quarantined handback"

  # Only an explicit, reasoned discard clears it.
  set -- "$home/state/linear/refused"/*.json
  rc=0
  run_sync "$home" discard "$(basename "$1" .json)" --reason 'issue was deleted upstream' \
    >/dev/null 2> "$home/u2.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a discard without --yes must refuse"
  run_sync "$home" discard "$(basename "$1" .json)" --reason 'issue was deleted upstream' --yes \
    >/dev/null || fail "an explicit discard must succeed"
  assert_present "$home/state/linear/discarded" "a discard must stay inspectable"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work ship-9 >/dev/null || fail "guard-work must pass after an explicit discard"
  pass "an issue Linear does not have is quarantined, keeps blocking, and clears only on an explicit discard"
}

test_a_refusal_that_cannot_be_quarantined_holds_instead() {
  local home rc out refused_dir id
  home=$(make_home refusal-cannot-quarantine)
  write_credential "$home"
  run_sync "$home" bind ship-11 ENG-406 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-11 'nowhere to put this' >/dev/null || fail "queue failed"
  id=$(one_id "$home/state/linear/outbox" .json) || fail "queue left no outbox record"

  refused_dir="$home/state/linear/refused"
  ( umask 077; mkdir -p "$refused_dir" ) || fail "cannot pre-create the refused dir"
  chmod 500 "$refused_dir"

  rc=0
  run_sync "$home" deliver --all >/dev/null 2> "$home/r.err" || rc=$?
  chmod 700 "$refused_dir"
  [ "$rc" -eq 3 ] || fail "a refusal that cannot be quarantined must hold instead (rc=$rc)"
  assert_grep "preserved and still owed" "$home/r.err" \
    "the fallback must say the handback is still owed, not discarded"

  assert_present "$home/state/linear/outbox/$id.json" \
    "the outbox record must survive when the quarantine write fails"
  assert_absent "$refused_dir/$id.json" \
    "no partial quarantine record should be left behind when the copy could not be confirmed"

  out=$(run_sync "$home" pending ship-11)
  assert_contains "$out" "queued  task=ship-11" \
    "pending must still show the handback as owed, not refused"

  rc=$(expect_failure "an unquarantinable refusal still blocks completion" \
    env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work ship-11)
  [ "$rc" -eq 1 ] || fail "guard-work must still refuse while the handback is preserved"

  pass "a refusal that cannot be quarantined preserves the outbox record and holds instead of discarding it"
}

# --- 5. the completion gate --------------------------------------------------

test_cleanup_refuses_while_a_linear_handback_is_owed() {
  local home rc
  home=$(make_home cleanup-gate)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-100 team-1 Todo
  run_sync "$home" bind ship-task ENG-100 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-task 'PR merged' --status Done >/dev/null || fail "queue failed"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/gone" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_fake_exit0 "$(fm_fakebin "$home")" tmux treehouse no-mistakes gh gh-axi

  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" ship-task \
    > "$home/td.out" 2> "$home/td.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup must refuse while a Linear handback is owed"
  assert_grep "still owes its bound Linear issue" "$home/td.err" "the refusal must be explicit"
  assert_present "$home/state/ship-task.meta" "a refused cleanup must preserve the task record"

  run_sync "$home" deliver --all >/dev/null || fail "delivery failed"
  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" ship-task >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "cleanup must proceed once the Linear issue is current (rc=$rc)"
  pass "cleanup refuses while a Linear handback is owed and proceeds once the issue is current"
}

test_cleanup_of_an_unbound_task_is_unaffected() {
  local home rc
  home=$(make_home cleanup-unbound)
  run_sync "$home" bind other-task ENG-111 >/dev/null || fail "bind failed"
  queue_comment "$home" other-task 'unrelated' >/dev/null || fail "queue failed"
  fm_write_meta "$home/state/free-task.meta" \
    "window=firstmate:fm-free-task" \
    "worktree=$home/projects/gone" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_fake_exit0 "$(fm_fakebin "$home")" tmux treehouse no-mistakes gh gh-axi
  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" free-task >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "another task's owed handback must not block this cleanup (rc=$rc)"
  pass "the completion gate blocks only the task that owes the handback"
}

# --- 6. surfacing across restart --------------------------------------------

test_startup_surfaces_owed_handbacks_only_when_owed() {
  local home out
  home=$(make_home startup)
  fm_fake_exit0 "$(fm_fakebin "$home")" tmux treehouse no-mistakes gh gh-axi tasks-axi
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SESSION_START_NO_LOCK=1 \
    "$SESSION_START" 2>/dev/null || true)
  assert_not_contains "$out" "Linear issues awaiting synchronization" \
    "a home with no Linear work must print no Linear subsection"

  run_sync "$home" bind ship-x ENG-200 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-x 'survives a restart' >/dev/null || fail "queue failed"
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SESSION_START_NO_LOCK=1 \
    "$SESSION_START" 2>/dev/null || true)
  assert_contains "$out" "Linear issues awaiting synchronization" \
    "an owed handback must be surfaced from disk at session start"
  assert_contains "$out" "issue=ENG-200" "the surfaced line must name the issue"
  pass "session start surfaces an owed Linear handback from disk, and stays silent otherwise"
}

# --- 7. zero overhead and scope ----------------------------------------------

test_a_home_with_no_linear_work_gains_nothing() {
  local home out
  home=$(make_home untouched)
  out=$(run_sync "$home" hook 2>&1)
  [ -z "$out" ] || fail "the hook must be silent in a home with no Linear work: $out"
  out=$(run_sync "$home" pending 2>&1)
  [ -z "$out" ] || fail "pending must be silent in a home with no Linear work"
  out=$(run_sync "$home" bindings 2>&1)
  [ -z "$out" ] || fail "bindings must be silent in a home with no Linear work"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work anything >/dev/null 2>&1 \
    || fail "the completion gate must pass in a home with no Linear work"
  assert_absent "$home/state/linear" "a home with no Linear work must gain no Linear state"
  assert_absent "$home/config/linear.env" "a home with no Linear work must gain no credential file"
  pass "a home that never bound a Linear issue gains no artifact and prints nothing"
}

test_scope_is_a_genuine_primary_home() {
  local main worktree secondmate project out rc
  main=$(make_home scope-main)
  run_sync "$main" bind ship-s ENG-300 >/dev/null || fail "bind failed"
  queue_comment "$main" ship-s 'owed' >/dev/null || fail "queue failed"
  out=$(run_sync "$main" hook 2>&1)
  assert_contains "$out" "handback(s) still owed" "a genuine primary home must surface owed work"

  # A crewmate/scout task worktree: a genuine linked git worktree of the home.
  worktree="$TMP_ROOT/scope-child"
  git -C "$main" worktree add --quiet -b fm/linear-scope-test "$worktree"
  mkdir -p "$worktree/state"
  cp -R "$main/state/linear" "$worktree/state/linear"
  : > "$worktree/AGENTS.md"
  mkdir -p "$worktree/bin"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$worktree" FM_STATE_OVERRIDE="$worktree/state" \
    "$SYNC" hook 2>&1)
  [ -z "$out" ] || fail "the hook must be inert in a task worktree, printed: $out"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$worktree" FM_STATE_OVERRIDE="$worktree/state" \
    "$SYNC" bind other ENG-1 >/dev/null 2> "$worktree/err" || rc=$?
  [ "$rc" -eq 1 ] || fail "binding inside a task worktree must refuse"
  assert_grep "is not a firstmate primary home" "$worktree/err" "the refusal must name the scope"

  # An ordinary project repo is not a firstmate home at all.
  project="$TMP_ROOT/scope-project"
  fm_git_init_commit "$project"
  mkdir -p "$project/state"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$project" FM_STATE_OVERRIDE="$project/state" \
    "$SYNC" hook 2>&1)
  [ -z "$out" ] || fail "the hook must be inert in an ordinary project repo"

  # A marked secondmate home runs its own primary session and stays in scope.
  secondmate="$TMP_ROOT/scope-secondmate"
  git -C "$main" worktree add --quiet -b fm/linear-secondmate-home "$secondmate"
  mkdir -p "$secondmate/state" "$secondmate/bin"
  : > "$secondmate/AGENTS.md"
  printf 'sm-linear-1\n' > "$secondmate/.fm-secondmate-home"
  cp -R "$main/state/linear" "$secondmate/state/linear"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$secondmate" FM_STATE_OVERRIDE="$secondmate/state" \
    "$SYNC" hook 2>&1)
  assert_contains "$out" "handback(s) still owed" "a marked secondmate home must stay in scope"
  pass "the hook is active in a primary and secondmate home and inert in a task worktree or project repo"
}

# --- 8. secret handling ------------------------------------------------------

test_the_credential_never_leaves_its_file() {
  local home key hit
  home=$(make_home secrets)
  key='lin_api_SUPERSECRETVALUE0001'
  write_credential "$home" "$key"
  seed_issue "$(fake_dir "$home")" ENG-400 team-1 Todo
  run_sync "$home" bind ship-sec ENG-400 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-sec 'no secrets here' --status Done >/dev/null || fail "queue failed"
  run_sync "$home" deliver --all > "$home/s.out" 2> "$home/s.err" || fail "delivery failed"

  # Nothing the transport saw, nothing durable, and nothing printed may carry it.
  hit=$(grep -rl "$key" "$(fake_dir "$home")" "$home/state" "$home/s.out" "$home/s.err" 2>/dev/null || true)
  [ -z "$hit" ] || fail "the credential leaked into: $hit"
  hit=$(grep -rl "$key" "$home/state/linear" 2>/dev/null || true)
  [ -z "$hit" ] || fail "the credential leaked into a durable record: $hit"
  # It is still exactly where it belongs.
  assert_grep "$key" "$home/config/linear.env" "the credential must remain in its own file"
  pass "the credential never reaches a request body, a durable record, or any output"
}

test_the_real_transport_keeps_the_credential_out_of_argv() {
  local home fakebin argv key headerfile
  home=$(make_home real-transport)
  key='lin_api_ARGVCHECK00000002'
  write_credential "$home" "$key"
  fakebin=$(fm_fakebin "$home")
  argv="$home/curl-argv.log"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$argv"
env > "$home/curl-env.log"
for a in "\$@"; do
  case "\$a" in
    @*)
      f=\${a#@}
      case "\$f" in
        *fm-linear-auth*)
          printf '%s\n' "\$f" > "$home/curl-headerfile"
          cat "\$f" > "$home/curl-headerfile-content"
          ;;
      esac
      ;;
  esac
done
printf '200'
exit 0
SH
  chmod +x "$fakebin/curl"
  jq -n '{query:"query FmLinearIssue { __typename }", variables:{}}' > "$home/req.json"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$TRANSPORT" "$home/req.json" "$home/resp.json" >/dev/null \
    || fail "the real transport must complete with a fake curl"

  assert_no_grep "$key" "$argv" "the credential must never appear in curl's argv"
  assert_no_grep "$key" "$home/req.json" "the credential must never appear in the request body"
  assert_no_grep "$key" "$home/curl-env.log" "the credential must never be exported to curl's environment"
  # The credential did travel - as a complete header line in a private file that
  # curl was pointed at, and that file is gone as soon as the transport exits.
  assert_grep "Authorization: $key" "$home/curl-headerfile-content" \
    "the credential must reach curl as a header file"
  headerfile=$(cat "$home/curl-headerfile")
  assert_absent "$headerfile" "the private credential file must not outlive the transport"
  pass "the real transport passes its credential by private file, never in argv or the environment"
}

# --- 9. records stay inspectable and typed ----------------------------------

test_records_are_typed_and_bounded() {
  local home id record mode
  home=$(make_home records)
  run_sync "$home" bind ship-r ENG-500 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-r 'a typed handback' --status Done >/dev/null || fail "queue failed"
  id=$(one_id "$home/state/linear/outbox" .json)
  record="$home/state/linear/outbox/$id.json"

  [ "$(jq -r '.schema' < "$record")" = fm-linear-delivery-v1 ] || fail "the record must carry its schema"
  [ "$(jq -r '.delivery_id' < "$record")" = "$id" ] || fail "the record must carry its own identity"
  [ "$(jq -r '.task_id' < "$record")" = ship-r ] || fail "the record must name its task"
  [ "$(jq -r '.issue' < "$record")" = ENG-500 ] || fail "the record must name its issue"
  [ "$(jq -r '.status' < "$record")" = Done ] || fail "the record must carry its status"
  [ "$(jq -r '.marker' < "$record")" = "fm-linear-sync:$id" ] || fail "the record must carry its marker"

  mode=$(file_mode "$record")
  [ "$mode" = 600 ] || fail "a delivery record must be private (found $mode)"
  mode=$(file_mode "$home/state/linear")
  [ "$mode" = 700 ] || fail "the Linear state root must be private (found $mode)"

  # A record that no longer matches its own identity never reaches Linear.
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-500 team-1 Todo
  jq '.comment = "tampered"' < "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  chmod 600 "$record"
  run_sync "$home" deliver "$id" >/dev/null 2> "$home/r.err" && fail "a tampered record must refuse"
  assert_grep "identity check" "$home/r.err" "the refusal must name the identity check"
  [ "$(comment_count "$home" ENG-500)" -eq 0 ] || fail "a tampered record must post nothing"
  pass "delivery records are typed, private, and refused when they no longer match their identity"
}

test_a_concurrent_delivery_is_serialized() {
  local home id rc
  home=$(make_home concurrency)
  write_credential "$home"
  seed_issue "$(fake_dir "$home")" ENG-600 team-1 Todo
  run_sync "$home" bind ship-c ENG-600 >/dev/null || fail "bind failed"
  queue_comment "$home" ship-c 'only one of these may post' >/dev/null || fail "queue failed"
  id=$(one_id "$home/state/linear/outbox" .json)

  # Two runs that both complete a read-back before either posts would both see a
  # proven absence. The per-delivery lock is what makes that impossible, so hold
  # it directly rather than racing two processes.
  mkdir "$home/state/linear/.lock.$id" || fail "cannot hold the delivery lock"
  rc=0
  run_sync "$home" deliver "$id" >/dev/null 2> "$home/lock.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a delivery already in progress must hold (rc=$rc)"
  assert_grep "already in progress" "$home/lock.err" "the hold must say why"
  assert_grep "still owed" "$home/lock.err" "the hold must say the handback survives"
  [ "$(comment_count "$home" ENG-600)" -eq 0 ] || fail "a locked delivery must post nothing"

  # An abandoned lock must not strand the handback forever.
  touch -t 202001010000 "$home/state/linear/.lock.$id"
  run_sync "$home" deliver "$id" >/dev/null || fail "an abandoned lock must be taken over"
  [ "$(comment_count "$home" ENG-600)" -eq 1 ] || fail "the takeover must post exactly once"
  assert_absent "$home/state/linear/.lock.$id" "the lock must be released"
  pass "a delivery already under way holds, and an abandoned lock is taken over rather than stranding it"
}

test_comment_text_cannot_forge_record_fields() {
  local home out rc
  home=$(make_home field-forgery)
  run_sync "$home" bind ship-f ENG-700 >/dev/null || fail "bind failed"
  # The cleanup gate reads delivery records without jq, so a comment that looks
  # like a record must not be able to rewrite what that gate sees.
  printf 'here is a record:\n  "status": "Nothing"\n  "issue": "ENG-999"\n  "task_id": "someone-else"\n' \
    > "$home/comment.md"
  run_sync "$home" queue ship-f --comment-file "$home/comment.md" --status Done >/dev/null \
    || fail "queue failed"

  out=$(run_sync "$home" pending)
  assert_contains "$out" "issue=ENG-700" "the real issue must win over comment text"
  assert_contains "$out" "status=Done" "the real status must win over comment text"
  assert_contains "$out" "task=ship-f" "the real task must win over comment text"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work someone-else >/dev/null 2>&1 \
    || fail "the gate must not block a task named only inside comment text"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SYNC" guard-work ship-f >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "the gate must block the task that actually owes the handback"
  pass "comment text cannot forge the record fields the jq-free cleanup gate reads"
}

test_missing_and_ambiguous_targets_refuse
test_comment_content_is_validated
test_delivery_posts_once_and_sets_status
test_requeueing_the_same_handback_is_one_delivery
test_a_concurrent_delivery_is_serialized
test_lost_acknowledgement_converges_without_a_duplicate
test_a_destroyed_receipt_does_not_repost
test_truncated_read_back_refuses_to_post
test_disconnected_linear_preserves_the_handback
test_transport_failure_holds_then_lands_once
test_a_partial_delivery_completes_its_status_without_reposting
test_an_unknown_issue_is_quarantined_and_still_blocks
test_a_refusal_that_cannot_be_quarantined_holds_instead
test_cleanup_refuses_while_a_linear_handback_is_owed
test_cleanup_of_an_unbound_task_is_unaffected
test_startup_surfaces_owed_handbacks_only_when_owed
test_a_home_with_no_linear_work_gains_nothing
test_scope_is_a_genuine_primary_home
test_the_credential_never_leaves_its_file
test_the_real_transport_keeps_the_credential_out_of_argv
test_records_are_typed_and_bounded
test_comment_text_cannot_forge_record_fields
