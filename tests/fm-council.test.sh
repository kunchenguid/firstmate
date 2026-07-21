#!/usr/bin/env bash
# Deterministic behavior coverage for the thin persistent council MVP.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-council)
TRANSPORT="$TMP_ROOT/transport"
STUB="$TMP_ROOT/stub"
mkdir -p "$STUB"

cat > "$TRANSPORT" <<'SH'
#!/usr/bin/env bash
set -eu
op=$1
shift
state=$FM_COUNCIL_STUB_DIR
mkdir -p "$state/endpoints" "$state/payloads"
case "$op" in
  launch)
    council=$1 member=$2 owner=$3 runtime=$4
    marker="$state/endpoints/$council--$member.json"
    [ ! -e "$marker" ] || { echo "duplicate launch" >&2; exit 31; }
    jq -nc --arg c "$council" --arg m "$member" --arg o "$owner" \
      '{session:"stub",workspace_id:("ws-"+$c),tab_id:("tab-"+$m),pane_id:("pane-"+$m),endpoint:("stub:pane-"+$m),owner_token:$o,alive:true}' > "$marker"
    printf 'launch\t%s\t%s\t%s\n' "$council" "$member" "$owner" >> "$state/events"
    jq -c '{session,workspace_id,tab_id,pane_id,endpoint}' "$marker"
    ;;
  probe)
    council=$1 member=$2 owner=$3 runtime=$4
    marker="$state/endpoints/$council--$member.json"
    if [ -f "$state/unavailable-$council--$member" ]; then
      jq -nc --arg c "$council" --arg m "$member" --arg o "$owner" \
        '{session:"stub",workspace_id:("ws-"+$c),tab_id:("tab-"+$m),pane_id:("pane-"+$m),owner_token:$o,alive:false}'
      exit 0
    fi
    [ -f "$marker" ] || exit 32
    cat "$marker"
    ;;
  send)
    council=$1 member=$2 kind=$3 payload=$4 common=$5 runtime=$6
    fail="$state/fail-once-$council--$member--$kind"
    if [ -f "$fail" ]; then
      rm -f "$fail"
      exit 33
    fi
    if [ "$kind" = round ] && [ -f "$state/parallel-mode" ]; then
      : > "$state/active-$council"
      sleep 0.25
      active_count=$(find "$state" -maxdepth 1 -name 'active-*' -type f | wc -l | tr -d ' ')
      [ "$active_count" -lt 2 ] || : > "$state/parallel-proved"
      rm -f "$state/active-$council"
    fi
    sequence=$(($(wc -l < "$state/events" 2>/dev/null || printf 0) + 1))
    copy="$state/payloads/$sequence-$council-$member-$kind.md"
    cp "$payload" "$copy"
    payload_hash=$(sha256sum "$payload" | awk '{print $1}')
    if [ "$common" = - ]; then
      common_hash=-
    else
      common_hash=$(sha256sum "$common" | awk '{print $1}')
    fi
    printf 'send\t%s\t%s\t%s\t%s\t%s\t%s\n' "$council" "$member" "$kind" "$payload_hash" "$common_hash" "$copy" >> "$state/events"
    ;;
  close)
    council=$1 member=$2 owner=$3 runtime=$4
    failclose="$state/fail-close-once-$council--$member"
    if [ -f "$failclose" ]; then
      rm -f "$failclose"
      exit 37
    fi
    marker="$state/endpoints/$council--$member.json"
    [ -f "$marker" ] || exit 34
    [ "$(jq -r .owner_token "$marker")" = "$owner" ] || exit 35
    rm -f "$marker"
    printf 'close\t%s\t%s\t%s\n' "$council" "$member" "$owner" >> "$state/events"
    ;;
  *)
    exit 36
    ;;
esac
SH
chmod +x "$TRANSPORT"

new_home() {
  local label=$1 home project
  home="$TMP_ROOT/$label/home"
  project="$TMP_ROOT/$label/project"
  mkdir -p "$home/data" "$home/state" "$home/config" "$project"
  printf 'visible\n' > "$project/README.md"
  printf 'TOP_SECRET\n' > "$project/.env"
  printf 'PRIVATE\n' > "$project/id_rsa"
  printf 'example=yes\n' > "$project/.env.example"
  printf '%s\t%s\n' "$home" "$project"
}

council() {
  local home=$1
  shift
  FM_HOME="$home" FM_COUNCIL_TEST_TRANSPORT="$TRANSPORT" FM_COUNCIL_STUB_DIR="$STUB" \
    "$ROOT/bin/fm-council.sh" "$@"
}

create_pair() {
  local home=$1 project=$2 name=$3
  shift 3
  council "$home" create "$name" --project "$project" \
    --participant claude/claude-fable-5/xhigh \
    --participant codex/gpt-5.6-sol/xhigh "$@"
}

consent_pair() {
  local home=$1 project=$2
  council "$home" provider-consent anthropic --project "$project" --acknowledge-project-disclosure >/dev/null
  council "$home" provider-consent openai --project "$project" --acknowledge-project-disclosure >/dev/null
}

json_id() {
  jq -r .id <<<"$1"
}

submit_all() {
  local home=$1 name=$2 ask_json=$3 prefix=$4 round member nonce answer
  round=$(jq -r .round <<<"$ask_json")
  while IFS=$'\t' read -r member nonce; do
    [ -n "$member" ] || continue
    answer="$TMP_ROOT/$prefix-$member.md"
    printf '%s answer from %s\n' "$prefix" "$member" > "$answer"
    council "$home" submit "$name" "$member" --round "$round" --nonce "$nonce" --file "$answer" >/dev/null
  done < <(jq -r '.roster | to_entries[] | select(.value.dispatch == "sent") | [.key,.value.nonce] | @tsv' <<<"$ask_json")
}

# Create, exact profile validation, and duplicate-name refusal.
IFS=$'\t' read -r HOME1 PROJECT1 < <(new_home core)
CREATE1=$(create_pair "$HOME1" "$PROJECT1" Atlas)
ID1=$(json_id "$CREATE1")
[ "$(jq '.members | length' <<<"$CREATE1")" = 2 ] || fail "create did not retain two exact profiles"
status=0
create_pair "$HOME1" "$PROJECT1" atlas >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "duplicate names must be refused case-insensitively"
status=0
council "$HOME1" create Other --project "$PROJECT1" \
  --participant claude/claude-opus-4/xhigh \
  --participant codex/gpt-5.6-sol/xhigh >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "unsupported exact model must be refused instead of substituted"
pass "council create: named identity, two exact profiles, duplicate refusal, and no model substitution"

# Provider consent must exist before any project view is built or sent.
status=0
council "$HOME1" ask Atlas "Choose a cache." >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "round without provider consent must be refused"
[ ! -d "$HOME1/data/councils/$ID1/snapshots/R0001" ] || fail "consent refusal created a project view"
status=0
council "$HOME1" provider-consent anthropic --project "$PROJECT1" >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "provider consent without explicit disclosure acknowledgement must be refused"
consent_pair "$HOME1" "$PROJECT1"
pass "council consent: project-specific durable provider approval is required before fan-out"

# Same-input fan-out, secret exclusions, answer isolation, and one active round.
ASK1=$(council "$HOME1" ask Atlas "Choose a cache.")
ROUND1=$(jq -r .round <<<"$ASK1")
COMMON1="$HOME1/data/councils/$ID1/rounds/$ROUND1/common.md"
[ "$(jq -r '.roster[].dispatch' <<<"$ASK1" | sort -u)" = sent ] || fail "same-input round did not dispatch to both profiles"
common_hash=$(sha256sum "$COMMON1" | awk '{print $1}')
[ "$(jq -r .common_hash <<<"$ASK1")" = "$common_hash" ] || fail "round common hash does not match the frozen common bytes"
round_log=$(grep -F $'send\t' "$STUB/events" | grep -F $'\tround\t' | grep -F "$ID1")
[ "$(printf '%s\n' "$round_log" | awk -F '\t' '{print $6}' | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "participants received different common inputs"
manifest="$HOME1/data/councils/$ID1/snapshots/$ROUND1/manifest.json"
assert_grep '"path": ".env"' "$manifest" "snapshot manifest did not list .env exclusion"
assert_grep '"path": "id_rsa"' "$manifest" "snapshot manifest did not list private-key exclusion"
assert_present "$HOME1/data/councils/$ID1/snapshots/$ROUND1/project/.env.example" ".env.example should remain visible"
assert_absent "$HOME1/data/councils/$ID1/snapshots/$ROUND1/project/.env" ".env leaked into the project view"
for answer_path in $(jq -r '.roster[].answer' <<<"$ASK1"); do
  assert_absent "$answer_path" "fan-out exposed an answer before that participant submitted it"
done
status=0
council "$HOME1" ask Atlas "Second overlapping task" >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "a second active round in one council must be refused"
pass "council round: one frozen secret-filtered input is isolated and serialized per council"

# Linux Landlock enforces the fixed-view and answer-isolation boundaries below
# the participant process rather than relying on council instructions.
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
  sandbox="$TMP_ROOT/sandbox"
  mkdir -p "$sandbox/home" "$sandbox/source" "$sandbox/view" "$sandbox/other"
  printf 'source-private\n' > "$sandbox/source/code"
  printf 'fixed-view\n' > "$sandbox/view/code"
  printf 'competing-answer\n' > "$sandbox/other/answer"
  # shellcheck disable=SC2016  # positional parameters expand inside the sandboxed shell
  "$ROOT/bin/fm-council-sandbox.py" \
    --home "$sandbox/home" \
    --readable "$sandbox/view" \
    --allow-exec /bin/sh \
    --allow-exec /bin/cat \
    --allow-exec /usr/bin/python3 \
    -- /bin/sh -c '
      {
        cat "$1/code" > "$2/read-view"
        if echo mutate > "$1/code"; then echo view-write-bad > "$2/view-write"; else echo view-write-denied > "$2/view-write"; fi
        if cat "$3/code" > "$2/source-read"; then echo source-read-bad > "$2/source-status"; else echo source-read-denied > "$2/source-status"; fi
        if echo mutate > "$3/code"; then echo source-write-bad >> "$2/source-status"; else echo source-write-denied >> "$2/source-status"; fi
        if cat "$4/answer" > "$2/other-answer"; then echo answer-read-bad > "$2/answer-status"; else echo answer-read-denied > "$2/answer-status"; fi
        if /usr/bin/python3 -c "import socket; socket.socket(socket.AF_UNIX)"; then echo unix-socket-bad > "$2/socket-status"; else echo unix-socket-denied > "$2/socket-status"; fi
        if /usr/bin/python3 -c "import socket; socket.socketpair()"; then echo socketpair-bad > "$2/socketpair-status"; else echo socketpair-denied > "$2/socketpair-status"; fi
        if /usr/bin/python3 -c "import ctypes, sys; libc = ctypes.CDLL(None, use_errno=True); rc = libc.syscall(425, 4, 0); sys.exit(0 if rc < 0 and ctypes.get_errno() == 13 else 1)"; then echo io-uring-denied > "$2/iouring-status"; else echo io-uring-bad > "$2/iouring-status"; fi
        if /usr/bin/python3 -c "import socket; socket.socket(socket.AF_INET).close()"; then echo tcp-socket-allowed > "$2/tcp-status"; else echo tcp-socket-bad > "$2/tcp-status"; fi
        if /bin/ls / > /dev/null; then echo exec-bad > "$2/exec-status"; else echo exec-denied > "$2/exec-status"; fi
      } 2> "$2/denials"
    ' sh "$sandbox/view" "$sandbox/home" "$sandbox/source" "$sandbox/other"
  [ "$(cat "$sandbox/home/read-view")" = fixed-view ] || fail "sandbox could not read the fixed project view"
  [ "$(cat "$sandbox/home/exec-status")" = exec-denied ] || fail "sandbox executed a binary outside the exact allowlist"
  [ "$(cat "$sandbox/home/view-write")" = view-write-denied ] || fail "sandbox wrote the fixed project view"
  assert_grep source-read-denied "$sandbox/home/source-status" "sandbox read the source project outside the fixed view"
  assert_grep source-write-denied "$sandbox/home/source-status" "sandbox wrote the source project"
  [ "$(cat "$sandbox/home/answer-status")" = answer-read-denied ] || fail "sandbox exposed a competing participant answer"
  [ "$(cat "$sandbox/home/socket-status")" = unix-socket-denied ] || fail "sandbox allowed a terminal-control socket channel"
  [ "$(cat "$sandbox/home/socketpair-status")" = socketpair-denied ] || fail "sandbox allowed a Unix socketpair channel"
  [ "$(cat "$sandbox/home/iouring-status")" = io-uring-denied ] || fail "sandbox allowed an io_uring socket bypass"
  [ "$(cat "$sandbox/home/tcp-status")" = tcp-socket-allowed ] || fail "sandbox blocked provider-style TCP sockets"
  [ "$(cat "$sandbox/source/code")" = source-private ] || fail "sandbox changed the source bytes"
  pass "council sandbox: Landlock enforces read-only fixed views, the exact exec allowlist, and answer isolation"

  env_probe='import json, os, sys; json.dump({key: os.environ.get(key) for key in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY") if key in os.environ}, open(sys.argv[1], "w"))'
  ANTHROPIC_API_KEY=anthropic-secret CLAUDE_CODE_OAUTH_TOKEN=claude-oauth OPENAI_API_KEY=openai-secret \
    "$ROOT/bin/fm-council-sandbox.py" --home "$sandbox/home" --harness claude \
    -- /usr/bin/python3 -c "$env_probe" "$sandbox/home/env-claude.json"
  ANTHROPIC_API_KEY=anthropic-secret CLAUDE_CODE_OAUTH_TOKEN=claude-oauth OPENAI_API_KEY=openai-secret \
    "$ROOT/bin/fm-council-sandbox.py" --home "$sandbox/home" --harness codex \
    -- /usr/bin/python3 -c "$env_probe" "$sandbox/home/env-codex.json"
  [ "$(jq -r '.ANTHROPIC_API_KEY // "-"' "$sandbox/home/env-claude.json")" = anthropic-secret ] || fail "claude lane lost its own provider key"
  [ "$(jq -r '.CLAUDE_CODE_OAUTH_TOKEN // "-"' "$sandbox/home/env-claude.json")" = claude-oauth ] || fail "claude lane lost its own oauth token"
  [ "$(jq -r '.OPENAI_API_KEY // "-"' "$sandbox/home/env-claude.json")" = - ] || fail "claude lane leaked the OpenAI key"
  [ "$(jq -r '.OPENAI_API_KEY // "-"' "$sandbox/home/env-codex.json")" = openai-secret ] || fail "codex lane lost its own provider key"
  [ "$(jq -r '.ANTHROPIC_API_KEY // "-"' "$sandbox/home/env-codex.json")" = - ] || fail "codex lane leaked the Anthropic key"
  [ "$(jq -r '.CLAUDE_CODE_OAUTH_TOKEN // "-"' "$sandbox/home/env-codex.json")" = - ] || fail "codex lane leaked the Claude oauth token"
  pass "council sandbox: each lane receives only its own harness provider credentials"
fi

# Different councils use independent locks and can dispatch concurrently.
IFS=$'\t' read -r HOME2 PROJECT2 < <(new_home parallel)
create_pair "$HOME2" "$PROJECT2" Alpha >/dev/null
create_pair "$HOME2" "$PROJECT2" Beta >/dev/null
consent_pair "$HOME2" "$PROJECT2"
: > "$STUB/parallel-mode"
council "$HOME2" ask Alpha "Alpha task" > "$TMP_ROOT/alpha.ask" &
pid_a=$!
council "$HOME2" ask Beta "Beta task" > "$TMP_ROOT/beta.ask" &
pid_b=$!
wait "$pid_a" || fail "first independent council ask failed"
wait "$pid_b" || fail "second independent council ask failed"
assert_present "$STUB/parallel-proved" "different councils did not overlap their independent fan-out"
rm -f "$STUB/parallel-mode" "$STUB"/active-*
pass "council concurrency: independent councils dispatch in parallel while each remains serialized"

# Partial failure produces an honest sole-answer collection, never a winner.
IFS=$'\t' read -r HOME3 PROJECT3 < <(new_home partial)
CREATE3=$(create_pair "$HOME3" "$PROJECT3" Partial)
ID3=$(json_id "$CREATE3")
consent_pair "$HOME3" "$PROJECT3"
CODEX3=$(jq -r '.members[] | select(startswith("codex-"))' <<<"$CREATE3")
: > "$STUB/unavailable-$ID3--$CODEX3"
ASK3=$(council "$HOME3" ask Partial "Choose one safe option.")
[ "$(jq -r --arg member "$CODEX3" '.roster[$member].dispatch' <<<"$ASK3")" = unavailable ] || fail "partial failure was not named unavailable"
submit_all "$HOME3" Partial "$ASK3" partial
COLLECT3=$(council "$HOME3" collect Partial)
[ "$(jq -r .comparison <<<"$COLLECT3")" = only-available ] || fail "one answer was treated as a comparative result"
[ "$(jq -r '.unavailable[0]' <<<"$COLLECT3")" = "$CODEX3" ] || fail "collection did not name the unavailable participant"
printf 'Only available answer: use the safe option.\n' > "$TMP_ROOT/only.md"
status=0
council "$HOME3" present Partial --file "$TMP_ROOT/only.md" --kind best >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "one answer must not be presented as a winner"
council "$HOME3" present Partial --file "$TMP_ROOT/only.md" --kind only >/dev/null
PARTIAL_ROUND=$(jq -r .round <<<"$ASK3")
council "$HOME3" reject Partial --reason "captain rejected the sole answer" >/dev/null
[ "$(jq -r .phase "$HOME3/data/councils/$ID3/council.json")" = idle ] || fail "plain reject did not return the council to idle"
assert_absent "$HOME3/data/councils/$ID3/rounds/$PARTIAL_ROUND/presented.md" "plain reject retained the rejected canonical result"
pass "council collection: partial failure is honest, one answer is never a winner, and plain rejection retains no result"

# Acceptance saves exact bytes before broadcast, defers one member, catches it up,
# preserves participant sessions, and emits a separate implementation instruction.
submit_all "$HOME1" Atlas "$ASK1" first
COLLECT1=$(council "$HOME1" collect Atlas)
[ "$(jq -r '.answers | length' <<<"$COLLECT1")" = 2 ] || fail "two answers were not collected"
printf 'Canonical synthesis byte-for-byte.\nSecond line.\n' > "$TMP_ROOT/canonical.md"
council "$HOME1" present Atlas --file "$TMP_ROOT/canonical.md" --kind synthesis >/dev/null
CODEX1=$(jq -r '.members[] | select(startswith("codex-"))' <<<"$CREATE1")
: > "$STUB/fail-once-$ID1--$CODEX1--decision"
ACCEPT1=$(council "$HOME1" accept-and-implement Atlas)
DECISION1=$(jq -r .canonical <<<"$ACCEPT1")
cmp -s "$TMP_ROOT/canonical.md" "$DECISION1" || fail "accepted decision bytes differ from the presented canonical bytes"
[ "$(jq -r .implementation.action <<<"$ACCEPT1")" = create_separate_ordinary_implementation_task ] || fail "accept-and-implement did not return an ordinary-task instruction"
[ "$(jq -r '.deferred_members[0]' <<<"$ACCEPT1")" = "$CODEX1" ] || fail "temporary decision delivery failure was not deferred honestly"
saved_line=$(grep -n '"event": "decision_saved"' "$HOME1/data/councils/$ID1/events.jsonl" | tail -1 | cut -d: -f1)
delivered_line=$(grep -n '"event": "decision_delivered"' "$HOME1/data/councils/$ID1/events.jsonl" | tail -1 | cut -d: -f1)
[ "$saved_line" -lt "$delivered_line" ] || fail "decision broadcast preceded durable canonical save"
decision_payload=$(grep -F $'send\t' "$STUB/events" | grep -F "$ID1" | grep -F $'\tdecision\t' | tail -1 | awk -F '\t' '{print $7}')
cmp -s "$TMP_ROOT/canonical.md" "$decision_payload" || fail "broadcast payload was not exactly the presented canonical decision"
launches_before=$(grep -c "^launch.$ID1" "$STUB/events")
ASK1B=$(council "$HOME1" ask Atlas "Plan the schema migration.")
launches_after=$(grep -c "^launch.$ID1" "$STUB/events")
[ "$launches_before" = "$launches_after" ] || fail "next round duplicated persistent participant sessions"
codex_events=$(grep -F $'send\t' "$STUB/events" | grep -F "$ID1" | grep -F "$CODEX1" | tail -2 | awk -F '\t' '{print $4}' | paste -sd, -)
[ "$codex_events" = decision,round ] || fail "unavailable participant did not catch up before its next round"
pass "council acceptance: exact save precedes exact broadcast, catch-up, and separate implementation routing"

# Reject/rerun removes rejected output and sends clarified constraints.
submit_all "$HOME1" Atlas "$ASK1B" second
ROUND1B=$(jq -r .round <<<"$ASK1B")
RERUN=$(council "$HOME1" rerun Atlas --clarify "Do not use Redis")
ROUND1C=$(jq -r .rerun <<<"$RERUN")
[ "$ROUND1B" != "$ROUND1C" ] || fail "rerun reused the rejected round identity"
old_round_dir="$HOME1/data/councils/$ID1/rounds/$ROUND1B"
assert_absent "$old_round_dir/presented.md" "rerun retained a rejected presentation"
for answer_path in $(jq -r '.roster[].answer // empty' "$old_round_dir/round.json"); do
  assert_absent "$answer_path" "rerun retained a rejected raw answer"
done
assert_grep 'Clarified constraint: Do not use Redis' "$HOME1/data/councils/$ID1/rounds/$ROUND1C/common.md" "rerun did not fan out clarified constraints"
pass "council rerun: rejected results are removed and clarified constraints get a fresh round"

# Restart/recovery is duplicate-safe and interrupted work requires explicit retry.
launches_before=$(grep -c "^launch.$ID1" "$STUB/events")
council "$HOME1" status Atlas >/dev/null
launches_after=$(grep -c "^launch.$ID1" "$STUB/events")
[ "$launches_before" = "$launches_after" ] || fail "clean restart/status inspection duplicated participants"
council "$HOME1" recover Atlas >/dev/null
status=0
council "$HOME1" ask Atlas "Must refuse while interrupted" >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "interrupted round accepted a new ask without retry"
RETRY=$(council "$HOME1" retry Atlas --clarify "Retry after restart")
[ "$(jq -r .retry <<<"$RETRY")" != "$ROUND1C" ] || fail "explicit retry reused interrupted identity"
launches_after=$(grep -c "^launch.$ID1" "$STUB/events")
[ "$launches_before" = "$launches_after" ] || fail "explicit retry duplicated participant endpoints"
pass "council restart: endpoint identity is reused and interrupted rounds require explicit retry"

# New councils inherit active project decisions by default, while clean-slate omits
# them and always starts fresh conversation homes.
DEFAULT_NEW=$(create_pair "$HOME1" "$PROJECT1" Atlas2)
CLEAN_NEW=$(create_pair "$HOME1" "$PROJECT1" AtlasClean --clean-slate)
DEFAULT_ID=$(json_id "$DEFAULT_NEW")
CLEAN_ID=$(json_id "$CLEAN_NEW")
[ "$(jq -r '.decision_ids[0]' "$HOME1/data/councils/$DEFAULT_ID/council.json")" = D0001 ] || fail "new council did not inherit active project decisions"
[ "$(jq '.decision_ids | length' "$HOME1/data/councils/$CLEAN_ID/council.json")" = 0 ] || fail "clean-slate council inherited old decisions"
default_homes=$(jq -r '.members[].runtime' "$HOME1/data/councils/$DEFAULT_ID/council.json" | sort)
clean_homes=$(jq -r '.members[].runtime' "$HOME1/data/councils/$CLEAN_ID/council.json" | sort)
[ "$default_homes" != "$clean_homes" ] || fail "new councils reused old participant conversations"
pass "council restart policy: fresh conversations inherit active decisions unless clean-slate is explicit"

# Explicit close verifies and closes exact owned endpoints only, preserving an
# unrelated endpoint marker and deleting conversation homes.
printf 'unrelated\n' > "$STUB/endpoints/unrelated"
council "$HOME1" close Atlas2 >/dev/null
assert_present "$STUB/endpoints/unrelated" "council close touched an unrelated endpoint"
[ "$(grep -c "^close.$DEFAULT_ID" "$STUB/events")" = 2 ] || fail "close did not terminate exactly its two participants"
assert_absent "$HOME1/state/councils/$DEFAULT_ID/members" "close did not clear participant conversation homes"
[ "$(jq -r .status "$HOME1/data/councils/$DEFAULT_ID/council.json")" = closed ] || fail "close did not preserve durable closed identity"
clean_runtime_rel=$(jq -r '.members[0].runtime' "$HOME1/data/councils/$CLEAN_ID/council.json")
clean_runtime="$HOME1/$clean_runtime_rel"
cp "$clean_runtime" "$clean_runtime.saved"
jq '.pane_id = "forged-pane"' "$clean_runtime.saved" > "$clean_runtime"
status=0
council "$HOME1" close AtlasClean >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "close must refuse a changed endpoint identity"
[ "$(find "$STUB/endpoints" -maxdepth 1 -name "$CLEAN_ID--*" -type f | wc -l | tr -d ' ')" = 2 ] || fail "ambiguous close touched a council participant"
mv "$clean_runtime.saved" "$clean_runtime"
council "$HOME1" close AtlasClean >/dev/null
pass "council close: only exact owned sessions terminate, ambiguity refuses, and conversation context is cleared"

# Failed round setup rolls back its unpublished round directory and keeps the
# durable counter retryable.
if [ "$(id -u)" != 0 ]; then
  IFS=$'\t' read -r HOME4 PROJECT4 < <(new_home rollback)
  CREATE4=$(create_pair "$HOME4" "$PROJECT4" Rollback)
  ID4=$(json_id "$CREATE4")
  consent_pair "$HOME4" "$PROJECT4"
  mkdir -p "$PROJECT4/blocked"
  printf 'x\n' > "$PROJECT4/blocked/file"
  chmod 000 "$PROJECT4/blocked"
  status=0
  council "$HOME4" ask Rollback "Task while the project is unreadable" >/dev/null 2>&1 || status=$?
  chmod 700 "$PROJECT4/blocked"
  expect_code 1 "$status" "unreadable project must fail the round setup"
  [ ! -d "$HOME4/data/councils/$ID4/rounds/R0001" ] || fail "failed round setup left a stale round directory"
  [ ! -d "$HOME4/data/councils/$ID4/snapshots/R0001" ] || fail "failed round setup left a stale snapshot"
  [ "$(jq -r .round_counter "$HOME4/data/councils/$ID4/council.json")" = 0 ] || fail "failed round setup burned the durable round counter"
  ASK4=$(council "$HOME4" ask Rollback "Task after the project stabilizes")
  [ "$(jq -r .round <<<"$ASK4")" = R0001 ] || fail "retry after a failed setup did not reuse the rolled-back round identity"
  pass "council round rollback: failed snapshot setup is retryable without a stale round directory"
fi

# A corrupt participant runtime defers decision delivery instead of aborting an
# acceptance whose canonical decision is already saved, without duplicating it.
IFS=$'\t' read -r HOME5 PROJECT5 < <(new_home deferral)
CREATE5=$(create_pair "$HOME5" "$PROJECT5" Deferral)
ID5=$(json_id "$CREATE5")
consent_pair "$HOME5" "$PROJECT5"
ASK5=$(council "$HOME5" ask Deferral "Pick a queue.")
submit_all "$HOME5" Deferral "$ASK5" deferral
council "$HOME5" collect Deferral >/dev/null
printf 'Queue decision.\n' > "$TMP_ROOT/deferral-canonical.md"
council "$HOME5" present Deferral --file "$TMP_ROOT/deferral-canonical.md" --kind synthesis >/dev/null
CODEX5=$(jq -r '.members[] | select(startswith("codex-"))' <<<"$CREATE5")
codex_runtime="$HOME5/state/councils/$ID5/members/$CODEX5/runtime.json"
cp "$codex_runtime" "$codex_runtime.saved"
printf 'not-json\n' > "$codex_runtime"
ACCEPT5=$(council "$HOME5" accept Deferral)
[ "$(jq -r '.deferred_members[0]' <<<"$ACCEPT5")" = "$CODEX5" ] || fail "a corrupt runtime aborted acceptance instead of deferring delivery"
[ "$(jq -r .phase "$HOME5/data/councils/$ID5/council.json")" = idle ] || fail "acceptance with a corrupt runtime did not complete"
index5=$(find "$HOME5/data/council-projects" -name index.json)
[ "$(jq '.decisions | length' "$index5")" = 1 ] || fail "acceptance duplicated the saved decision entry"
mv "$codex_runtime.saved" "$codex_runtime"
council "$HOME5" ask Deferral "Follow-up task." >/dev/null
codex_events5=$(grep -F $'send\t' "$STUB/events" | grep -F "$ID5" | grep -F "$CODEX5" | tail -2 | awk -F '\t' '{print $4}' | paste -sd, -)
[ "$codex_events5" = decision,round ] || fail "deferred member did not catch up before its next round"
pass "council acceptance deferral: canonical save survives a corrupt runtime and is never duplicated"

# A close that fails partway is retryable; retries skip only journal-confirmed
# closures and close each remaining exact endpoint once.
: > "$STUB/fail-close-once-$ID5--$CODEX5"
status=0
council "$HOME5" close Deferral >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "a partial close failure must be reported"
[ "$(jq -r .status "$HOME5/data/councils/$ID5/council.json")" = open ] || fail "a partially closed council must remain open"
[ "$(jq '.closed | length' "$HOME5/data/councils/$ID5/close-journal.json")" = 1 ] || fail "close journal did not record exactly the confirmed closure"
council "$HOME5" close Deferral >/dev/null
[ "$(grep -c "^close.$ID5" "$STUB/events")" = 2 ] || fail "close retry did not close each participant exactly once"
[ "$(jq -r .status "$HOME5/data/councils/$ID5/council.json")" = closed ] || fail "close retry did not complete the council closure"
pass "council close retry: journal-confirmed closures are skipped and remaining endpoints close exactly once"

# Stale unpublished round/snapshot leftovers from a crashed ask are recovered
# deterministically instead of blocking every later ask.
IFS=$'\t' read -r HOME6 PROJECT6 < <(new_home stale)
CREATE6=$(create_pair "$HOME6" "$PROJECT6" Stale)
ID6=$(json_id "$CREATE6")
consent_pair "$HOME6" "$PROJECT6"
mkdir -p "$HOME6/data/councils/$ID6/rounds/R0001"
printf 'leftover\n' > "$HOME6/data/councils/$ID6/rounds/R0001/common.md"
mkdir -p "$HOME6/data/councils/$ID6/snapshots/R0001/project"
printf 'leftover\n' > "$HOME6/data/councils/$ID6/snapshots/R0001/project/file"
chmod 555 "$HOME6/data/councils/$ID6/snapshots/R0001/project"
ASK6=$(council "$HOME6" ask Stale "Task after a crashed ask") || fail "stale unpublished leftovers blocked the next ask"
[ "$(jq -r .round <<<"$ASK6")" = R0001 ] || fail "stale leftovers changed the deterministic round identity"
if grep -q leftover "$HOME6/data/councils/$ID6/rounds/R0001/common.md"; then
  fail "stale round leftovers were adopted as a valid round"
fi
assert_absent "$HOME6/data/councils/$ID6/snapshots/R0001/project/file" "stale snapshot leftovers were adopted as a valid view"
pass "council stale recovery: unpublished crash leftovers are cleared, never adopted"

# A corrupt participant runtime during dispatch becomes an honest unavailable
# roster entry in a complete frozen roster instead of aborting the fan-out.
IFS=$'\t' read -r HOME7 PROJECT7 < <(new_home dispatch)
CREATE7=$(create_pair "$HOME7" "$PROJECT7" Dispatch)
ID7=$(json_id "$CREATE7")
consent_pair "$HOME7" "$PROJECT7"
CODEX7=$(jq -r '.members[] | select(startswith("codex-"))' <<<"$CREATE7")
codex_runtime7="$HOME7/state/councils/$ID7/members/$CODEX7/runtime.json"
cp "$codex_runtime7" "$codex_runtime7.saved"
printf 'not-json\n' > "$codex_runtime7"
ASK7=$(council "$HOME7" ask Dispatch "Pick a linter.") || fail "a corrupt runtime aborted the round fan-out"
ROUND7=$(jq -r .round <<<"$ASK7")
[ "$(jq -r --arg member "$CODEX7" '.roster[$member].dispatch' <<<"$ASK7")" = unavailable ] || fail "corrupt runtime was not an honest unavailable roster entry"
[ "$(jq '.roster | length' <<<"$ASK7")" = 2 ] || fail "dispatch failure left an incomplete frozen roster"
[ "$(jq -r .status "$HOME7/data/councils/$ID7/rounds/$ROUND7/round.json")" = collecting ] || fail "round did not finish dispatch after a member failure"
grep -q '"event": "round_dispatched"' "$HOME7/data/councils/$ID7/events.jsonl" || fail "dispatch failure suppressed the round_dispatched event"
mv "$codex_runtime7.saved" "$codex_runtime7"
pass "council dispatch: a per-member runtime failure defers honestly and still freezes a complete roster"

# A non-UTF-8 presentation is refused before any state mutates.
submit_all "$HOME7" Dispatch "$ASK7" dispatch
council "$HOME7" collect Dispatch >/dev/null
printf '\xff\xfe broken bytes' > "$TMP_ROOT/bad-utf8.md"
status=0
council "$HOME7" present Dispatch --file "$TMP_ROOT/bad-utf8.md" --kind only >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "non-UTF-8 presentation must be refused"
[ "$(jq -r .phase "$HOME7/data/councils/$ID7/council.json")" = awaiting_presentation ] || fail "invalid presentation mutated the council phase"
assert_absent "$HOME7/data/councils/$ID7/rounds/$ROUND7/presented.md" "invalid presentation bytes were saved"
printf 'Valid decision.\n' > "$TMP_ROOT/good-utf8.md"
council "$HOME7" present Dispatch --file "$TMP_ROOT/good-utf8.md" --kind only >/dev/null
pass "council present: non-UTF-8 canonical bytes are refused before any state mutation"

# One corrupt council record neither bricks other councils nor hides itself
# from a direct request.
mkdir -p "$HOME7/data/councils/corrupt-1234"
printf 'not-json\n' > "$HOME7/data/councils/corrupt-1234/council.json"
council "$HOME7" status Dispatch >/dev/null || fail "a corrupt unrelated record broke healthy council status"
council "$HOME7" reject Dispatch --reason cleanup >/dev/null || fail "a corrupt unrelated record broke healthy council mutation"
status=0
council "$HOME7" status corrupt-1234 >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "a direct request for the corrupt identity must report the corruption"
[ "$(council "$HOME7" status | jq -r '.[] | select(.id == "corrupt-1234") | .status')" = unreadable ] || fail "the status listing did not surface the corrupt record"
rm -rf "$HOME7/data/councils/corrupt-1234"
pass "council isolation: corrupt records are skipped for other councils and reported when requested directly"
