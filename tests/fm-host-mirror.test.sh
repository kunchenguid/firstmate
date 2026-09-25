#!/usr/bin/env bash
# Behavior tests for the supervision host's dialog mirror (bin/fm-host-mirror.sh,
# docs/supervision-host.md "The dialog mirror"): its writers, driven through the
# tracked hook registrations each primary harness runs, and its feed.
#
# Every writer runs as a child of a fake harness (a bash symlink named
# "claude") whose pid is the home's session lock, from a git checkout that
# passes the primary-scope check, exactly as a primary's own hook runs. Hook
# payloads are the shapes measured from the real harnesses
# (docs/supervision-host.md "The dialog mirror").
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIRROR="$ROOT/bin/fm-host-mirror.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-host-mirror)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR

# A primary checkout: git, AGENTS.md, and this repo's bin.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"

make_home() {  # <name> [opted-in: 1|0]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ "${2:-1}" != 1 ] || : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

# Run a shell script as the lock-owning primary session of <home>: the script
# runs under the fake harness whose pid it records as the session lock.
as_session() {  # <home> <script>
  FM_HOME="$1" PRIMARY_ROOT="$PRIMARY_ROOT" MIRROR="$MIRROR" "$FAKE_CLAUDE" -c \
    'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; '"$2"
}

# The command string one tracked registration runs.
claude_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.claude/settings.json"; }
cursor_cmd() { jq -r --arg e "$1" '.hooks[$e][] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.cursor/hooks.json"; }

# Inside an as_session script: one Claude prompt-submit (captain) or Stop
# (main) hook payload carrying <text>, through the mirror's hook writer.
SAY='say() {  # <captain|main> <text> [<id>]
  if [ "$1" = captain ]; then
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"UserPromptSubmit\", prompt_id: \$id, prompt: \$t}"
  else
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"Stop\", prompt_id: \$id, last_assistant_message: \$t}"
  fi | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
}
'

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

entries() {  # <home> -> "<tag>|<text>" per entry
  jq -r '"\(.tag)|\(.text)"' "$1/state/.host-mirror.jsonl" 2>/dev/null
}

test_every_harness_registration_writes_the_mirror() {
  local home out
  home=$(make_home harnesses)
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"c1\",\"prompt\":\"claude captain\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"c1\",\"last_assistant_message\":\"claude main\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"generation_id\":\"u1\",\"prompt\":\"cursor captain\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"u1\",\"text\":\"cursor main\",\"cursor_version\":\"x\"}"
  ' || fail "a tracked mirror hook failed"
  out=$(entries "$home")
  assert_equals "captain|claude captain
main|claude main
captain|cursor captain
main|cursor main" "$out" "every tracked registration must write its captain prompt and main reply, in order"
  pass "mirror: the Claude and Cursor registrations each write the captain's prompt and main's reply"
}

# Non-host invariance: on a home without config/supervision-host, every tracked
# mirror registration prints nothing and leaves the home's state byte-for-byte
# as it was, even for the lock-owning primary session in a primary checkout.
test_home_without_the_flag_is_untouched() {
  local home before after
  home=$(make_home without-flag 0)
  printf 'working: demo\n' > "$home/state/demo.status"
  # The fixture's own session lock is written by as_session, not by a writer.
  snapshot() { (cd "$1/state" && find . -type f ! -name .lock | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
  before=$(snapshot "$home")
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"hello\",\"cursor_version\":\"x\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"hi\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"text\":\"hi\",\"cursor_version\":\"x\"}"
  ' > "$home/writers.out" 2>&1 || fail "a mirror registration failed on a home without the flag: $(cat "$home/writers.out")"
  [ ! -s "$home/writers.out" ] || fail "a mirror registration printed on a home without the flag: $(cat "$home/writers.out")"
  after=$(snapshot "$home")
  assert_equals "$before" "$after" "a mirror writer changed the state of a home without the flag"
  pass "mirror: a home without the flag is untouched by every tracked mirror registration"
}

test_writers_are_inert_without_the_opt_in() {
  local home crew out
  home=$(make_home no-opt-in 0)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}" | "$MIRROR" hook claude
  ' || fail "an inert writer failed"
  assert_absent "$home/state/.host-mirror.jsonl" "a home without config/supervision-host must mirror nothing"
  crew="$TMP_ROOT/crew-worktree"
  mkdir -p "$crew"
  out=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}' | FM_HOME="$crew" "$MIRROR" hook claude 2>&1)
  [ -z "$out" ] || fail "an inert writer printed: $out"
  assert_absent "$crew/state" "an inert writer must create nothing in a home without config/"
  pass "mirror: writers stay silent and write nothing on a home that did not opt in"
}

test_operational_foreign_and_unowned_input_is_dropped() {
  local home other
  home=$(make_home dropped)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"from cursor\",\"cursor_version\":\"x\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"PreToolUse\",\"prompt\":\"not dialog\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"\\n\\n<task-notification>\\n<summary>Stop hook feedback</summary>\\n</task-notification>\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"kept\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
  ' || fail "a writer failed"
  assert_equals "captain|kept" "$(entries "$home")" \
    "operational input, a harness-started turn, a Cursor payload on the Claude registration, and a non-dialog event must not be mirrored"

  other=$(make_home unowned)
  sleep 30 &
  printf '%s\n' "$!" > "$other/state/.lock"
  printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"not the owner"}' \
    | FM_HOME="$other" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$FAKE_CLAUDE" -c '"$0" hook claude' "$MIRROR"
  kill "$(cat "$other/state/.lock")" 2>/dev/null || true
  assert_absent "$other/state/.host-mirror.jsonl" "a session that does not hold the fleet lock must mirror nothing"
  pass "mirror: operational input, a harness-started turn, a foreign host's payload, other events, and a session without the lock are never mirrored"
}

# Dialog is recorded as said: a line ending in spaces, blank lines, and
# indentation inside a message survive, and only the whitespace at the very
# end of the message is trimmed.
test_internal_whitespace_is_recorded_verbatim() {
  local home
  home=$(make_home whitespace)
  as_session "$home" "$SAY"'
    say captain "$(printf "first line  \n\n  second line\t\nthird  \n \n")" p1
    say main "$(printf "reply line \n    indented\n\nlast")"$(printf " \n\t ") p1
  ' || fail "a writer failed"
  assert_equals "$(printf 'first line  \n\n  second line\t\nthird')" \
    "$(jq -r 'select(.tag == "captain") | .text' "$home/state/.host-mirror.jsonl")" \
    "a captain prompt must keep its internal whitespace and lose only its trailing whitespace"
  assert_equals "$(printf 'reply line \n    indented\n\nlast')" \
    "$(jq -r 'select(.tag == "main") | .text' "$home/state/.host-mirror.jsonl")" \
    "a main reply must keep its internal whitespace and lose only its trailing whitespace"
  [ "$(jq -j 'select(.tag == "captain") | .text' "$home/state/.host-mirror.jsonl" | tail -c 1)" = d ] \
    || fail "the trailing whitespace at the end of a message must be trimmed"
  pass "mirror: a captain prompt and a main reply keep their internal whitespace and newlines verbatim"
}

test_entries_are_deduplicated_and_capped() {
  local home long text kept
  home=$(make_home capped)
  long=$(awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }')
  LONG=$long as_session "$home" "$SAY"'
    for n in 1 2; do printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\",\"prompt\":\"once\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude; done
    say main "$LONG" long
  ' || fail "a writer failed"
  [ "$(grep -c '"text":"once"' "$home/state/.host-mirror.jsonl")" -eq 1 ] || fail "an entry whose id is already recorded must not be appended again"
  text=$(jq -r 'select(.id == "long") | .text' "$home/state/.host-mirror.jsonl")
  kept=$(printf '%s' "$text" | tr -cd x | wc -c | tr -d ' ')
  assert_contains "$text" "[mirror truncated: $((5000 - kept)) characters omitted]" "a long entry must be capped with a truncation note naming what it left out"
  [ "${#text}" -eq 4000 ] || fail "a capped entry must hold 4000 characters with its note, got ${#text}"
  pass "mirror: a repeated entry is recorded once, and a long entry keeps its head and tail within the cap"
}

# A turn that continues after a blocked Stop fires Stop again under the same
# prompt id with its real final reply: only an identical repeat is dropped.
test_a_different_reply_under_the_same_id_is_recorded() {
  local home
  home=$(make_home same-id-reply)
  as_session "$home" "$SAY"'
    say captain "ship it" p1
    say main "interim reply before the guard blocked" p1
    say main "the real final answer" p1
    say main "the real final answer" p1
  ' || fail "a writer failed"
  assert_equals "captain|ship it
main|interim reply before the guard blocked
main|the real final answer" "$(entries "$home")" \
    "a different reply under the same id must be recorded, and an identical repeat only once"
  pass "mirror: a later different reply under the same id is recorded, while an identical repeat is recorded once"
}

# A hook id names an entry only within one main session: a later session
# reusing it is new dialog.
test_a_later_session_may_reuse_an_entry_id() {
  local home
  home=$(make_home reused-id)
  as_session "$home" "$SAY"'say captain "asked in the first session" p1' || fail "the first session failed"
  as_session "$home" "$SAY"'
    say captain "asked in the second session" p1
    "$MIRROR" feed s1 new > "$FM_HOME/feed.second"
  ' || fail "the second session failed"
  assert_equals "[captain] asked in the second session" "$(cat "$home/feed.second")" \
    "a later session's entry must be recorded even when an earlier session used its id"
  pass "mirror: an entry id already recorded by an earlier main session does not drop a later session's dialog"
}

# A write that fails partway (here a file-size limit, as a full disk would)
# must leave the mirror as it was, print nothing, and let later dialog land.
test_a_failed_append_leaves_the_mirror_valid() {
  local home
  home=$(make_home failed-append)
  as_session "$home" "$SAY"'
    say captain "asked before the disk filled" p1
    big=$(awk "BEGIN { for (i = 0; i < 3000; i++) printf \"z\" }")
    (ulimit -f 1; trap "" XFSZ; say main "$big" p1) > "$FM_HOME/full.out" 2>&1
    printf "%s\n" "$?" > "$FM_HOME/full.rc"
    say captain "asked once space returned" p2
    "$MIRROR" feed s1 new > "$FM_HOME/feed.after"
  ' || fail "the mirror did not stay valid across a failed append"
  assert_equals "0" "$(cat "$home/full.rc")" "a failed append must still exit 0"
  assert_equals "" "$(cat "$home/full.out")" "a failed append must print nothing"
  assert_equals "[captain] asked before the disk filled
[captain] asked once space returned" "$(cat "$home/feed.after")" \
    "a failed append must record nothing and leave later dialog feedable"
  [ -z "$(find "$home/state" -name '.host-mirror.jsonl.tmp.*')" ] || fail "a failed append left its temporary file"
  pass "mirror: a failed append leaves the mirror valid, prints nothing, and later dialog still lands"
}

test_mirror_is_owner_only_under_an_open_umask() {
  local home mirror
  home=$(make_home private)
  mirror="$home/state/.host-mirror.jsonl"
  (umask 022; as_session "$home" "$SAY"'say captain "keep this between us" p1') || fail "a writer failed"
  [ "$(mode_of "$mirror")" = 600 ] || fail "a new mirror must be owner-only, got $(mode_of "$mirror")"
  chmod 644 "$mirror"
  (umask 022; as_session "$home" "$SAY"'say main "understood" p1') || fail "a writer failed"
  [ "$(mode_of "$mirror")" = 600 ] || fail "an existing readable mirror must be owner-only after an append, got $(mode_of "$mirror")"
  [ "$(entries "$home" | wc -l | tr -d ' ')" -eq 2 ] || fail "both entries must be recorded: $(entries "$home")"
  pass "mirror: the captain's dialog lands only in an owner-only mirror, even when the file already existed readable by others"
}

# A jq on PATH that appends its own argv to $FM_HOME/jq-argv.log, then runs
# the real jq.
JQ_SHIM="$TMP_ROOT/jq-shim"
mkdir -p "$JQ_SHIM"
{
  printf '#!/usr/bin/env bash\nREAL_JQ=%q\n' "$(command -v jq)"
  cat <<'SH'
printf '%s\n' "$@" >> "$FM_HOME/jq-argv.log"
exec "$REAL_JQ" "$@"
SH
} > "$JQ_SHIM/jq"
chmod +x "$JQ_SHIM/jq"

test_dialog_text_never_enters_process_arguments() {
  local home
  home=$(make_home argv)
  PATH="$JQ_SHIM:$PATH" as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\",\"prompt\":\"captain-secret-7f3a\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"main-secret-9c1e\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
  ' || fail "a writer failed"
  assert_equals "captain|captain-secret-7f3a
main|main-secret-9c1e" "$(entries "$home")" "both entries must be recorded"
  [ -s "$home/jq-argv.log" ] || fail "the writers must have run through the recording jq"
  ! grep -q 'secret' "$home/jq-argv.log" || fail "dialog text must never appear in a jq argument list"
  pass "mirror: captain prompts and main replies reach the mirror without ever entering a process argument list"
}

test_feed_resumes_reanchors_and_is_bounded() {
  local home out
  home=$(make_home feed)
  as_session "$home" "$SAY"'
    say captain "first ask"; say main "first answer"
    "$MIRROR" feed s1 new > "$FM_HOME/feed.1" && "$MIRROR" commit
    say captain "second ask"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.uncommitted"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.2" && "$MIRROR" commit
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.3" && "$MIRROR" commit
    "$MIRROR" feed s2 resume > "$FM_HOME/feed.4"
  ' || fail "the first session failed"
  assert_equals "[captain] first ask
[main] first answer" "$(cat "$home/feed.1")" "a new conversation must be fed this session's dialog"
  assert_equals "[captain] second ask" "$(cat "$home/feed.uncommitted")" "a resumed conversation must be fed only what is new"
  assert_equals "[captain] second ask" "$(cat "$home/feed.2")" "a feed never committed to the engine must leave its entries for the next feed"
  assert_equals "" "$(cat "$home/feed.3")" "a resumed conversation with nothing new must be fed nothing"
  assert_equals "[captain] first ask
[main] first answer
[captain] second ask" "$(cat "$home/feed.4")" "a conversation the cursor does not belong to must re-anchor"

  as_session "$home" "$SAY"'
    say captain "a later session"
    "$MIRROR" feed s3 new > "$FM_HOME/feed.5"
    big=$(awk "BEGIN { for (i = 0; i < 3000; i++) printf \"y\" }")
    for n in 1 2 3 4 5 6 7; do say main "$n $big"; done
    "$MIRROR" feed s4 new > "$FM_HOME/feed.6"
  ' || fail "the second session failed"
  assert_equals "[captain] a later session" "$(cat "$home/feed.5")" "a new main session must never be fed an earlier session's dialog"
  out=$(cat "$home/feed.6")
  assert_contains "$(head -n 1 "$home/feed.6")" "earlier mirrored entries are not shown)" "a bounded feed must say what it left out"
  assert_contains "$out" "[main] 7 yyy" "a bounded feed must keep the newest entries"
  assert_not_contains "$out" "[captain] a later session" "a bounded feed must drop the oldest entries"
  [ "$(wc -c < "$home/feed.6")" -le 16000 ] || fail "the feed was not bounded: $(wc -c < "$home/feed.6") characters"
  pass "mirror: the feed resumes from its committed cursor, re-anchors on a new conversation or session, and is bounded"
}

# Newest entries that alone fill the bound leave no room for the note naming
# what was left out: the note counts within the bound, so one more entry goes.
test_feed_bound_includes_its_omitted_note() {
  local home out
  home=$(make_home feed-note)
  as_session "$home" "$SAY"'
    say captain "the oldest ask"
    big=$(awk "BEGIN { for (i = 0; i < 3988; i++) printf \"y\" }")
    for n in 1 2 3 4; do say main "$n $big"; done
    "$MIRROR" feed s1 new > "$FM_HOME/feed"
  ' || fail "the session failed"
  out=$(cat "$home/feed")
  [ "$(wc -c < "$home/feed")" -le 16000 ] || fail "the feed and its note must fit 16000 characters, got $(wc -c < "$home/feed")"
  assert_equals "(2 earlier mirrored entries are not shown)" "$(head -n 1 "$home/feed")" "the note must count every entry it left out"
  assert_contains "$out" "[main] 4 yyy" "a bounded feed must keep the newest entry"
  assert_not_contains "$out" "[main] 1 yyy" "a bounded feed must drop the oldest entries to fit its note"
  pass "mirror: the feed's bound includes the note naming how many earlier entries it left out"
}

test_recycled_lock_pid_is_a_new_main_session() {
  local home
  home=$(make_home recycled)
  as_session "$home" "$SAY"'
    fake_proc() {  # <root> <starttime>: this pid with that process start
      mkdir -p "$1/$$"
      printf "%s (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n" "$$" "$2" > "$1/$$/stat"
      printf "claude\0" > "$1/$$/cmdline"
    }
    fake_proc "$FM_HOME/proc.first" 1000
    fake_proc "$FM_HOME/proc.recycled" 2000
    export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc.first"
    say captain "asked in the first session"
    "$MIRROR" feed s1 new > "$FM_HOME/feed.first" && "$MIRROR" commit
    export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc.recycled"
    "$MIRROR" feed s2 new > "$FM_HOME/feed.recycled"
    say captain "asked in the recycled session"
    "$MIRROR" feed s3 new > "$FM_HOME/feed.second"
  ' || fail "the session failed"
  assert_equals "[captain] asked in the first session" "$(cat "$home/feed.first")" \
    "one lock holder must keep one key across its writes and feeds"
  assert_equals "" "$(cat "$home/feed.recycled")" \
    "a later lock holder given the same pid must not be fed the earlier holder's dialog"
  assert_equals "[captain] asked in the recycled session" "$(cat "$home/feed.second")" \
    "a later lock holder given the same pid must be fed only its own dialog"
  pass "mirror: a later lock holder with a recycled pid is a new main session"
}

# A mirror whose sequence numbers are not positive integers rising in file
# order, or whose final record is unterminated, cannot vouch for the dialog it
# carries: the feed refuses it and stages nothing.
test_feed_refuses_unfeedable_sequences_and_unterminated_records() {
  local home bad good
  home=$(make_home unfeedable)
  as_session "$home" "$SAY"'say captain "a sound ask"; "$MIRROR" feed s1 new >/dev/null' || fail "the feed refused a sound mirror"
  good=$(cat "$home/state/.host-mirror.jsonl")
  for bad in "$(printf '%s' "$good" | jq -c '.seq = 0')"$'\n' \
    "$(printf '%s' "$good" | jq -c '.seq = 1.5')"$'\n' \
    "$good"$'\n'"$good"$'\n' \
    "$good"; do
    printf '%s' "$bad" > "$home/state/.host-mirror.jsonl"
    as_session "$home" '"$MIRROR" feed s1 new' >/dev/null && fail "the feed accepted an unfeedable mirror:"$'\n'"$bad"
    [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "the feed staged a cursor for an unfeedable mirror"
  done
  pass "mirror: the feed refuses a mirror with a zero, fractional, or non-rising sequence, or an unterminated final record"
}

test_recreated_mirror_continues_past_both_cursors() {
  local home
  home=$(make_home recreate)
  as_session "$home" "$SAY"'
    for n in 1 2 3 4 5; do say captain "earlier ask $n"; done
    "$MIRROR" feed s1 new > /dev/null && "$MIRROR" commit
    rm "$FM_HOME/state/.host-mirror.jsonl"
    say captain "asked after the mirror was lost"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.recreated"
    rm "$FM_HOME/state/.host-mirror.jsonl"
    say captain "asked while that turn ran"
    "$MIRROR" commit
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.after-commit"
  ' || fail "the session failed"
  assert_equals "[captain] asked after the mirror was lost" "$(cat "$home/feed.recreated")" \
    "a recreated mirror must not number new dialog at or below the committed cursor"
  assert_equals "[captain] asked while that turn ran" "$(cat "$home/feed.after-commit")" \
    "a mirror recreated during a turn must not let that turn's commit skip new dialog"
  pass "mirror: a recreated mirror continues past the committed and staged cursors, so a resumed conversation still gets new dialog"
}

test_every_harness_registration_writes_the_mirror
test_writers_are_inert_without_the_opt_in
test_home_without_the_flag_is_untouched
test_operational_foreign_and_unowned_input_is_dropped
test_internal_whitespace_is_recorded_verbatim
test_entries_are_deduplicated_and_capped
test_a_different_reply_under_the_same_id_is_recorded
test_a_later_session_may_reuse_an_entry_id
test_a_failed_append_leaves_the_mirror_valid
test_mirror_is_owner_only_under_an_open_umask
test_dialog_text_never_enters_process_arguments
test_feed_resumes_reanchors_and_is_bounded
test_feed_bound_includes_its_omitted_note
test_recycled_lock_pid_is_a_new_main_session
test_feed_refuses_unfeedable_sequences_and_unterminated_records
test_recreated_mirror_continues_past_both_cursors
