#!/usr/bin/env bash
# fm-send from-firstmate marker for secondmate targets.
#
# A secondmate is itself a firstmate, so a request relayed to it lands in its own
# chat - which the main firstmate never reads (the only channel back is the terse
# status file). fm-send therefore prepends a from-firstmate marker
# (bin/fm-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=secondmate, so the secondmate can recognize
# the request and route its reply via the status path. The marker now travels
# inside the durable inbox record's body (the payload is never typed; only the
# doorbell is). These tests pin that behavior hermetically (stubbed tmux, no
# real agent):
#   1. Exact-id and stable-label kind=secondmate selectors prepend the marker
#      to the recorded steer, never to the typed doorbell.
#   2. Exact-id and stable-label ordinary crewmate selectors stay unmarked.
#   3. Explicit endpoints stay unmarked and typed, with or without local meta.
#   4. The --key path never carries the marker and never enqueues a record.
#   5. Direct captain text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# FM_SEND_LOG and (b) lets fm-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so fm_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-domain fm-build win window; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). FM_ROOT_OVERRIDE points at the same non-repo home so
# fm-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# FM_SEND_SETTLE=0 keeps the run fast. HOME and CLAUDE_CONFIG_DIR point inside
# TMP_ROOT so the Claude skill and command lookup never sees the real user. Truncates the log first; returns fm-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" HOME="$TMP_ROOT/user" CLAUDE_CONFIG_DIR="$TMP_ROOT/user/claude-config" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The exact enqueued text of one inbox record, read through the production
# owner (bin/fm-task-inbox-lib.sh). Command substitution strips trailing
# newlines, so byte-exact trailing assertions read the raw record instead.
record_body() {  # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_secondmate_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a secondmate target should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "secondmate send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "secondmate send lost the request body"$'\n'"$got" ;;
  esac
  case "$(cat "$log")" in
    *"$FM_FROMFIRST_MARK"*) fail "the marker must ride the record, never the typed doorbell" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -f "$(fm_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked secondmate send should create a parent pending-reply record"
  pass "fm-send: a kind=secondmate target gets the from-firstmate marker and corr prepended"
}

test_exact_secondmate_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact secondmate task id should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact secondmate send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${FM_FROMFIRST_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(record_body "$home/state/domain.inbox/002.msg")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr=${corr} already routed") : ;;
    *) fail "exact secondmate send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "fm-send: an exact kind=secondmate task id is marked with corr exactly once"
}

test_crewmate_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "fm-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label crewmate target should succeed"
  got=$(record_body "$home/state/build.inbox/001.msg")
  [ "$got" = "fix the test" ] \
    || fail "stable-label crewmate send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id crewmate target should succeed"
  got=$(record_body "$home/state/build.inbox/002.msg")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id crewmate send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: exact-id and stable-label kind=ship selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching secondmate
  # metadata must not make fm-send guess the caller's intent and mark it.
  fm_write_secondmate_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a secondmate should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  [ ! -d "$home/state/domain.inbox" ] \
    || fail "--key path must never enqueue an inbox record"
  pass "fm-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$FM_FROMFIRST_MARK" = "[fm-from-firstmate]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  fm_message_from_firstmate "${FM_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  fm_message_from_firstmate "do the work" \
    && fail "direct captain input must remain unmarked"
  fm_message_from_firstmate "[fm-from-firstmate]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "fm-send: the marker is '[fm-from-firstmate]' + terminal-safe U+2063, while direct captain text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  fm_message_mark_from_firstmate "do the work" once
  fm_message_mark_from_firstmate "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${FM_FROMFIRST_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "fm-marker: from-firstmate transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload corr expected actual expected_message
  dir="$TMP_ROOT/sm-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-trailing-newlines)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$(record_body "$home/state/domain.inbox/001.msg")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  fm_pending_reply_embed_corr "$payload" "$corr" expected_message
  expected="$dir/expected.body"
  actual="$dir/actual.body"
  printf '%s' "$expected_message" > "$expected"
  record_body "$home/state/domain.inbox/001.msg" > "$actual"
  cmp -s "$expected" "$actual" \
    || fail "the marked record did not preserve trailing newline bytes exactly"
  pass "fm-send: marked secondmate payload preserves trailing newline bytes in its record"
}

# expect_command_first <log> <command> <rest> <msg>: the typed bytes are the
# command, then marker+corr opening its arguments, then the caller's rest.
expect_command_first() {
  local got corr
  got=$(cat "$1")
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -n "$corr" ] || fail "$4: no corr in typed bytes"$'\n'"$got"
  [ "$got" = "$2 ${FM_FROMFIRST_MARK}corr=$corr${3:+ $3}" ] \
    || fail "$4"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
}

# expect_marker_first <log> <text> <msg>: today's marker-first typed bytes.
expect_marker_first() {
  case "$(cat "$1")" in
    "${FM_FROMFIRST_MARK}corr="[a-f0-9]*" $2") : ;;
    *) fail "$3"$'\n'"$(cat "$1")" ;;
  esac
}

test_claude_secondmate_slash_command_leads_typed_bytes() {
  local dir fb log home rc got corr long user_root acct plugin
  dir="$TMP_ROOT/sm-slash"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-slash)
  user_root="$TMP_ROOT/user/claude-config"
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain" alpha claude
  mkdir -p "$home/.claude/skills/sharpen" "$user_root/commands"
  printf -- '---\nname: sharpen\n---\n' > "$home/.claude/skills/sharpen/SKILL.md"
  printf 'Tidy up.\n' > "$user_root/commands/tidy.md"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"

  run_send "$fb" "$home" "$log" "domain" "/sharpen tighten the plan"; rc=$?
  expect_code 0 "$rc" "a slash command to a local claude secondmate should succeed"
  [ ! -d "$home/state/domain.inbox" ] || fail "a slash command must stay on the typed plane"
  expect_command_first "$log" /sharpen "tighten the plan" \
    "an installed project skill must be typed command-first with marker and corr opening its arguments"
  got=$(cat "$log")
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -f "$(fm_pending_reply_path "$home/state" "$corr")" ] \
    || fail "the typed slash command must carry the corr of its parent pending-reply record"$'\n'"$got"

  FM_PENDING_REPLY_EXISTING_CORR=$corr run_send "$fb" "$home" "$log" "domain" "/sharpen tighten the plan"; rc=$?
  expect_code 0 "$rc" "a recovery resend of the slash command should succeed"
  [ "$(cat "$log")" = "/sharpen ${FM_FROMFIRST_MARK}corr=$corr tighten the plan" ] \
    || fail "a resend must keep the same corr in the command-first bytes"$'\n'"$(cat "$log")"

  run_send "$fb" "$home" "$log" "domain" "/tidy"; rc=$?
  expect_code 0 "$rc" "a bare installed command to a local claude secondmate should succeed"
  got=$(cat "$log")
  corr=$(fm_pending_reply_extract_corr "$got")
  [ "${got% }" = "/tidy ${FM_FROMFIRST_MARK}corr=$corr" ] \
    || fail "a bare installed command must be typed as the command followed by marker and corr"$'\n'"$got"

  run_send "$fb" "$home" "$log" "domain" "/model sonnet"; rc=$?
  expect_code 0 "$rc" "a built-in to a local claude secondmate should succeed"
  expect_marker_first "$log" "/model sonnet" "a built-in must keep the marker in front"
  run_send "$fb" "$home" "$log" "domain" "/nosuchcmd x"; rc=$?
  expect_code 0 "$rc" "an unknown command to a local claude secondmate should succeed"
  expect_marker_first "$log" "/nosuchcmd x" "an unknown command must keep the marker in front"

  long=$(printf 'word %.0s' $(seq 1 160))
  run_send "$fb" "$home" "$log" "domain" "/sharpen $long"; rc=$?
  expect_code 0 "$rc" "a long slash command to a local claude secondmate should succeed"
  expect_marker_first "$log" "/sharpen $long" \
    "typed bytes over Claude's 800-character paste threshold must keep the marker in front"

  if command -v jq >/dev/null 2>&1; then
    plugin="$TMP_ROOT/plugin-cache/pstack/1.0"
    mkdir -p "$plugin/skills/sharpen" "$user_root/plugins"
    printf -- '---\nname: sharpen\n---\n' > "$plugin/skills/sharpen/SKILL.md"
    printf '{"version":2,"plugins":{"pstack@market":[{"scope":"user","installPath":"%s"}]}}\n' "$plugin" \
      > "$user_root/plugins/installed_plugins.json"
    run_send "$fb" "$home" "$log" "domain" "/pstack:sharpen tighten the plan"; rc=$?
    expect_code 0 "$rc" "a plugin skill send without enabledPlugins should succeed"
    expect_marker_first "$log" "/pstack:sharpen tighten the plan" \
      "a plugin skill with no enabledPlugins entry must keep the marker in front"
    printf '{"enabledPlugins":{"pstack@market":false}}\n' > "$user_root/settings.json"
    run_send "$fb" "$home" "$log" "domain" "/pstack:sharpen tighten the plan"; rc=$?
    expect_code 0 "$rc" "a disabled plugin skill send should succeed"
    expect_marker_first "$log" "/pstack:sharpen tighten the plan" \
      "a disabled plugin skill must keep the marker in front"
    printf '{"enabledPlugins":{"pstack@market":true}}\n' > "$user_root/settings.json"
    run_send "$fb" "$home" "$log" "domain" "/pstack:sharpen tighten the plan"; rc=$?
    expect_code 0 "$rc" "an enabled plugin skill send should succeed"
    expect_command_first "$log" /pstack:sharpen "tighten the plan" \
      "an enabled plugin skill must be typed command-first"
  else
    echo "skip: jq missing, plugin skill cases not run" >&2
  fi

  acct="$TMP_ROOT/acct-root"
  mkdir -p "$acct/commands"
  printf 'Account only.\n' > "$acct/commands/acctonly.md"
  run_send "$fb" "$home" "$log" "domain" "/acctonly now"; rc=$?
  expect_code 0 "$rc" "a command absent from the default roots should succeed"
  expect_marker_first "$log" "/acctonly now" "a command outside the searched roots must keep the marker in front"
  fm_write_secondmate_meta "$home/state/acct.meta" "$home" "sess:fm-acct" alpha claude
  printf 'account=%s\n' "$acct" >> "$home/state/acct.meta"
  run_send "$fb" "$home" "$log" "acct" "/acctonly now"; rc=$?
  expect_code 0 "$rc" "a command in the meta account root should succeed"
  expect_command_first "$log" /acctonly "now" "the meta account= root must be searched"
  pass "fm-send: a local claude secondmate installed skill or command is typed command-first, while built-ins, unknown commands, and long text keep the marker in front"
}

test_other_marked_messages_keep_marker_first() {
  local dir fb log home rc got
  dir="$TMP_ROOT/sm-slash-others"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-slash-others)
  fm_write_secondmate_meta "$home/state/echo.meta" "$home" "sess:fm-echo" alpha echo
  fm_write_secondmate_meta "$home/state/cdx.meta" "$home" "sess:fm-cdx" alpha codex
  fm_write_secondmate_meta "$home/state/cl.meta" "$home" "sess:fm-cl" alpha claude
  fm_write_meta "$home/state/crew.meta" \
    "window=sess:fm-crew" "worktree=$home/wt" "project=$home/p" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"

  run_send "$fb" "$home" "$log" "echo" "/audit the ledger"; rc=$?
  expect_code 0 "$rc" "a slash command to a non-claude secondmate should succeed"
  got=$(cat "$log")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr="[a-f0-9]*" /audit the ledger") : ;;
    *) fail "a non-claude secondmate slash command must keep the marker in front"$'\n'"$got" ;;
  esac

  run_send "$fb" "$home" "$log" "cdx" "\$audit the ledger"; rc=$?
  expect_code 0 "$rc" "a skill invocation to a codex secondmate should succeed"
  got=$(cat "$log")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr="[a-f0-9]*" \$audit the ledger") : ;;
    *) fail "a codex secondmate skill invocation must keep the marker in front"$'\n'"$got" ;;
  esac

  run_send "$fb" "$home" "$log" "crew" "/audit the ledger"; rc=$?
  expect_code 0 "$rc" "a slash command to a claude crewmate should succeed"
  [ "$(cat "$log")" = "/audit the ledger" ] \
    || fail "a claude crewmate slash command must stay unmarked"$'\n'"$(cat "$log")"

  run_send "$fb" "$home" "$log" "cl" --fire-and-forget 0123456789abcdef "/audit the ledger"; rc=$?
  expect_code 0 "$rc" "a fire-and-forget slash command to a claude secondmate should succeed"
  got=$(record_body "$home/state/cl.inbox/001.msg")
  [ "$got" = "${FM_FROMFIRST_MARK}delivery=0123456789abcdef /audit the ledger" ] \
    || fail "a fire-and-forget slash command must ride the inbox with the marker in front"$'\n'"$got"

  run_send "$fb" "$home" "$log" "cl" "audit the ledger"; rc=$?
  expect_code 0 "$rc" "plain text to a claude secondmate should succeed"
  got=$(record_body "$home/state/cl.inbox/002.msg")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr="[a-f0-9]*" audit the ledger") : ;;
    *) fail "plain text to a claude secondmate must ride the inbox with the marker in front"$'\n'"$got" ;;
  esac
  pass "fm-send: every other marked message, and every unmarked one, keeps today's bytes"
}

test_secondmate_target_is_marked
test_exact_secondmate_task_id_is_marked
test_claude_secondmate_slash_command_leads_typed_bytes
test_other_marked_messages_keep_marker_first
test_crewmate_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
