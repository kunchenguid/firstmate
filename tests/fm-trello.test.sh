#!/usr/bin/env bash
# Behavior tests for the Trello control plane: the REST wrapper (fm-trello.sh),
# the board poll client (fm-trello-poll.sh), and bootstrap's config-presence
# activation.
#
# The control plane must be INERT by default (no config/trello.env -> every
# subcommand and the poll are hard no-ops and bootstrap writes/prints nothing)
# and additive when on (a check shim + a 60s cadence config, both idempotent).
# The network is stubbed with a fakebin `curl` that emulates api.trello.com, so
# these stay hermetic: no ports, no server, deterministic in CI. jq stays the
# real tool. End-to-end verification against a real board is done out of band.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-trello-tests)

# Standard board fixture: seven lanes with emoji prefixes, exactly like a real
# board, to prove lane name->id resolution is dynamic and emoji-tolerant.
LISTS_JSON='[
  {"id":"L-inbox","name":"📥 Inbox"},
  {"id":"L-queued","name":"📋 Queued"},
  {"id":"L-ip","name":"🔨 In Progress"},
  {"id":"L-needs","name":"✋ Needs Input"},
  {"id":"L-ready","name":"🟢 Ready / Go"},
  {"id":"L-review","name":"👀 In Review"},
  {"id":"L-done","name":"✅ Done"}
]'
LABELS_JSON='[{"id":"lbl-go","name":"go"},{"id":"lbl-hold","name":"hold"}]'

# A fakebin `curl` that emulates the Trello REST API. The auth (key/token) is
# passed by fm-trello-lib via a -K config file (never argv), so the fake reads
# the real URL from that config file and logs both argv and the config contents,
# letting tests assert that credentials never leak into argv.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET url="" data="" cfg=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -K) cfg=$2; shift 2 ;;
    --data-urlencode) data="$data
$2"; shift 2 ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  line=$(grep '^url = ' "$cfg")
  url=${line#url = \"}; url=${url%\"}
fi
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "data=$data";
    [ -n "$cfg" ] && [ -f "$cfg" ] && cat "$cfg"; } >> "$FAKE_CURL_LOG"
fi
path=${url%%\?*}
body="" code=200
case "$path" in
  */boards/*/lists)  body=${FAKE_LISTS_BODY:-} ; code=${FAKE_LISTS_CODE:-200} ;;
  */boards/*/cards)  body=${FAKE_CARDS_BODY:-} ; code=${FAKE_CARDS_CODE:-200} ;;
  */boards/*/labels) body=${FAKE_LABELS_BODY:-}; code=200 ;;
  */lists/*/cards)   body=${FAKE_LISTCARDS_BODY:-'[]'}; code=200 ;;
  */cards/*/actions/comments) code=${FAKE_MUT_CODE:-200} ;;
  */cards/*/idLabels*)        code=${FAKE_MUT_CODE:-200} ;;
  */cards)  body=${FAKE_CREATE_BODY:-'{"id":"newcard1"}'}; code=${FAKE_MUT_CODE:-200} ;;
  */cards/*)
    if [ "$method" = "PUT" ]; then code=${FAKE_MUT_CODE:-200}
    else body=${FAKE_CARD_BODY:-'{"id":"c1","dateLastActivity":"2026-07-15T00:00:00.000Z","idList":"L-ip"}'}; code=200
    fi
    ;;
esac
[ -n "$ofile" ] && printf '%s' "$body" > "$ofile"
printf '%s' "$code"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

write_config() {
  local home=$1
  mkdir -p "$home/config"
  cat > "$home/config/trello.env" <<EOF
TRELLO_API_KEY=key-abc
TRELLO_TOKEN=tok-xyz
TRELLO_BOARD_SHORTLINK=BoArD01
EOF
}

# ---------------------------------------------------------------------------
# Inert-without-config gating
# ---------------------------------------------------------------------------

test_cli_help_always_works() {
  local home out rc
  home="$TMP_ROOT/cli-help"; mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-trello.sh" --help); rc=$?
  expect_code 0 "$rc" "help exit"
  assert_contains "$out" "Trello control-plane REST wrapper" "help must print the header"
  assert_contains "$out" "api.trello.com is an EXTERNAL host" "help must document the network dependency"
  pass "fm-trello.sh --help works with no config"
}

test_cli_noop_without_config() {
  local home fakebin log out rc sub
  home="$TMP_ROOT/cli-noop"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  for sub in "comment c1 hi" "move c1 Done" "describe c1 x" "create-card Queued t" "list-cards Inbox" "get-card c1" "pause" "start"; do
    # shellcheck disable=SC2086
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TRELLO_NO_ARM=1 FAKE_CURL_LOG="$log" \
      "$ROOT/bin/fm-trello.sh" $sub 2>&1); rc=$?
    expect_code 0 "$rc" "no-config '$sub' exit"
    [ -z "$out" ] || fail "no-config '$sub' must be silent (got: $out)"
  done
  [ ! -f "$log" ] || fail "no-config subcommands must never call the network"
  assert_absent "$home/state/.trello-paused" "no-config pause must not create a flag"
  pass "fm-trello.sh is a silent no-op for every subcommand without config (inert default)"
}

test_poll_noop_without_config() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-trello-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-config exit"
  [ -z "$out" ] || fail "poll must be silent without config (got: $out)"
  [ ! -f "$log" ] || fail "poll without config must never call the network"
  pass "fm-trello-poll.sh is a hard no-op without config (inert default)"
}

test_poll_noop_when_paused() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-paused"; mkdir -p "$home/state"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  : > "$home/state/.trello-paused"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_CARDS_BODY='[]' \
    "$ROOT/bin/fm-trello-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll paused exit"
  [ -z "$out" ] || fail "paused poll must be silent (got: $out)"
  [ ! -f "$log" ] || fail "paused poll must not call the network (global hibernate)"
  pass "fm-trello-poll.sh stands down while state/.trello-paused exists"
}

# ---------------------------------------------------------------------------
# fm-trello.sh REST + arg parsing
# ---------------------------------------------------------------------------

test_cli_arg_errors() {
  local home fakebin rc err
  home="$TMP_ROOT/cli-args"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LISTS_BODY="$LISTS_JSON" \
    "$ROOT/bin/fm-trello.sh" comment c1 >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "comment with a missing arg must fail"
  assert_grep "usage: fm-trello.sh comment" "$err" "comment usage error must be clear"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-trello.sh" bogus 2>"$err" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "unknown subcommand must fail"
  assert_grep "unknown subcommand" "$err" "unknown subcommand must be reported"
  pass "fm-trello.sh reports arg and subcommand errors clearly"
}

test_cli_comment_posts_and_hides_creds() {
  local home fakebin log out rc
  home="$TMP_ROOT/cli-comment"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    FAKE_LISTS_BODY="$LISTS_JSON" \
    "$ROOT/bin/fm-trello.sh" comment card42 'picked up — working'); rc=$?
  expect_code 0 "$rc" "comment exit"
  [ "$out" = "card42" ] || fail "comment must echo the card id (got: $out)"
  assert_grep "url=https://api.trello.com/1/cards/card42/actions/comments" "$log" "comment must POST to the comment endpoint"
  assert_grep "method=POST" "$log" "comment must use POST"
  assert_grep "text=picked up — working" "$log" "comment must send the text field"
  # Credentials must live in the -K config file, never in argv.
  grep '^argv=' "$log" | grep -F 'tok-xyz' >/dev/null 2>&1 && fail "token must not appear in curl argv"
  grep '^argv=' "$log" | grep -F 'key-abc' >/dev/null 2>&1 && fail "key must not appear in curl argv"
  assert_grep "key=key-abc&token=tok-xyz" "$log" "auth must be in the -K config file"
  pass "fm-trello.sh comment posts to the right endpoint with credentials off argv"
}

test_cli_move_resolves_lane_dynamically() {
  local home fakebin log out rc
  home="$TMP_ROOT/cli-move"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    FAKE_LISTS_BODY="$LISTS_JSON" \
    "$ROOT/bin/fm-trello.sh" move card42 "In Progress"); rc=$?
  expect_code 0 "$rc" "move exit"
  [ "$out" = "card42" ] || fail "move must echo the card id"
  assert_grep "idList=L-ip" "$log" "move must resolve 'In Progress' to its list id from the board"
  assert_grep "method=PUT" "$log" "move must use PUT"
  pass "fm-trello.sh move resolves the lane name to a list id dynamically"
}

test_cli_move_unknown_lane_fails() {
  local home fakebin rc err
  home="$TMP_ROOT/cli-move-bad"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LISTS_BODY="$LISTS_JSON" \
    "$ROOT/bin/fm-trello.sh" move card42 "Nonexistent Lane" 2>"$err" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "move to an unknown lane must fail"
  assert_grep "cannot resolve lane" "$err" "unknown lane must be reported clearly"
  pass "fm-trello.sh move fails cleanly on an unresolvable lane"
}

test_cli_create_card_returns_id() {
  local home fakebin log out rc
  home="$TMP_ROOT/cli-create"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_CREATE_BODY='{"id":"fresh99","shortLink":"sl99"}' \
    "$ROOT/bin/fm-trello.sh" create-card "Queued" "Investigate flaky test"); rc=$?
  expect_code 0 "$rc" "create-card exit"
  [ "$out" = "fresh99" ] || fail "create-card must echo the new card id (got: $out)"
  assert_grep "idList=L-queued" "$log" "create-card must place the card in the resolved lane"
  assert_grep "name=Investigate flaky test" "$log" "create-card must send the card name"
  pass "fm-trello.sh create-card creates a card and returns its id"
}

test_cli_label_add_resolves_label() {
  local home fakebin log out rc
  home="$TMP_ROOT/cli-label"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_LABELS_BODY="$LABELS_JSON" \
    "$ROOT/bin/fm-trello.sh" label card42 add go); rc=$?
  expect_code 0 "$rc" "label add exit"
  [ "$out" = "card42" ] || fail "label add must echo the card id"
  assert_grep "value=lbl-go" "$log" "label add must resolve the label name to its id and POST idLabels"
  pass "fm-trello.sh label add resolves a label name to a board label id"
}

test_cli_get_and_list_cards() {
  local home fakebin out rc
  home="$TMP_ROOT/cli-read"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_LISTS_BODY="$LISTS_JSON" \
    FAKE_LISTCARDS_BODY='[{"id":"c1","name":"Fix login"},{"id":"c2","name":"Docs"}]' \
    "$ROOT/bin/fm-trello.sh" list-cards Inbox); rc=$?
  expect_code 0 "$rc" "list-cards exit"
  assert_contains "$out" "c1	Fix login" "list-cards must print id<TAB>name"
  assert_contains "$out" "c2	Docs" "list-cards must print every card"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_CARD_BODY='{"id":"c1","name":"Fix login","idList":"L-ip"}' \
    "$ROOT/bin/fm-trello.sh" get-card c1); rc=$?
  expect_code 0 "$rc" "get-card exit"
  [ "$(printf '%s' "$out" | jq -r .id)" = "c1" ] || fail "get-card must print the card JSON"
  pass "fm-trello.sh list-cards and get-card read the board"
}

test_cli_rejects_unsafe_card_id() {
  local home fakebin rc err
  home="$TMP_ROOT/cli-evil"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LISTS_BODY="$LISTS_JSON" \
    "$ROOT/bin/fm-trello.sh" comment "../../etc/x" hi 2>"$err" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an unsafe card id must be rejected"
  assert_grep "unsafe card id" "$err" "unsafe card id must be reported"
  pass "fm-trello.sh rejects a path-traversal card id"
}

test_cli_http_error_fails_loudly() {
  local home fakebin rc err
  home="$TMP_ROOT/cli-500"; mkdir -p "$home"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LISTS_BODY="$LISTS_JSON" FAKE_MUT_CODE=500 \
    "$ROOT/bin/fm-trello.sh" comment card42 hi 2>"$err" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a mutating call must fail loudly on a non-2xx response"
  assert_grep "HTTP 500" "$err" "the failing status must be reported"
  pass "fm-trello.sh fails loudly on a non-2xx REST response"
}

# ---------------------------------------------------------------------------
# meta binding + pause/start
# ---------------------------------------------------------------------------

test_cli_bind_unbind_card_for() {
  local home fakebin out rc
  home="$TMP_ROOT/cli-bind"; mkdir -p "$home/state"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  fm_write_meta "$home/state/fix-login-k3.meta" "window=fm-fix-login-k3" "project=alpha"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_CARD_BODY='{"dateLastActivity":"2026-07-15T01:00:00.000Z","idList":"L-ip"}' \
    "$ROOT/bin/fm-trello.sh" bind fix-login-k3 card42); rc=$?
  expect_code 0 "$rc" "bind exit"
  [ "$out" = "card42" ] || fail "bind must echo the card id"
  assert_grep "trello_card=card42" "$home/state/fix-login-k3.meta" "bind must record the binding in the task meta"
  assert_present "$home/state/.trello-seen-card42" "bind must seed the seen marker so the binding never self-wakes"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-trello.sh" card-for fix-login-k3); rc=$?
  [ "$out" = "card42" ] || fail "card-for must print the bound card id (got: $out)"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-trello.sh" unbind fix-login-k3 >/dev/null
  assert_no_grep "trello_card=" "$home/state/fix-login-k3.meta" "unbind must remove the binding"
  pass "fm-trello.sh bind/unbind/card-for manage the task meta binding"
}

test_cli_pause_and_start() {
  local home fakebin out rc
  home="$TMP_ROOT/cli-pause"; mkdir -p "$home/state"
  write_config "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-trello.sh" pause); rc=$?
  expect_code 0 "$rc" "pause exit"
  assert_present "$home/state/.trello-paused" "pause must create the hibernate flag"
  assert_contains "$out" "paused" "pause must confirm"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TRELLO_NO_ARM=1 "$ROOT/bin/fm-trello.sh" start); rc=$?
  expect_code 0 "$rc" "start exit"
  assert_absent "$home/state/.trello-paused" "start must remove the hibernate flag"
  assert_contains "$out" "resumed" "start must confirm"
  pass "fm-trello.sh pause/start toggle the global hibernate flag"
}

# ---------------------------------------------------------------------------
# poll trigger states + idempotency
# ---------------------------------------------------------------------------

# Run the poll once against a given board-cards fixture; echo its stdout.
run_poll() {
  local home=$1 cards=$2 fakebin
  fakebin=$(make_fake_curl "$home")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_CARDS_BODY="$cards" \
    "$ROOT/bin/fm-trello-poll.sh"
}

test_poll_inbox_trigger_and_idempotency() {
  local home out
  home="$TMP_ROOT/poll-inbox"; mkdir -p "$home/state"
  write_config "$home"
  local cards='[{"id":"cx","name":"new request","idList":"L-inbox","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}}]'
  out=$(run_poll "$home" "$cards")
  [ "$out" = "trello-inbox cx" ] || fail "a new Inbox card must fire trello-inbox (got: $out)"
  assert_present "$home/state/.trello-seen-cx" "inbox trigger must write a seen marker"
  # Idempotent: same activity, no re-fire.
  out=$(run_poll "$home" "$cards")
  [ -z "$out" ] || fail "an unchanged Inbox card must not re-fire (got: $out)"
  # New activity (captain edits the request) fires again.
  local cards2='[{"id":"cx","name":"new request","idList":"L-inbox","dateLastActivity":"2026-07-15T11:00:00.000Z","labels":[],"badges":{"comments":0}}]'
  out=$(run_poll "$home" "$cards2")
  [ "$out" = "trello-inbox cx" ] || fail "an updated Inbox card must fire again (got: $out)"
  pass "poll fires trello-inbox once per new/updated Inbox card (seen-marker idempotency)"
}

test_poll_ready_trigger_lane_and_go_label() {
  local home out
  home="$TMP_ROOT/poll-ready"; mkdir -p "$home/state"
  write_config "$home"
  # Card in the Ready lane.
  local cards='[{"id":"cr","name":"go ahead","idList":"L-ready","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":1}}]'
  out=$(run_poll "$home" "$cards")
  [ "$out" = "trello-ready cr" ] || fail "a card in Ready must fire trello-ready (got: $out)"
  # A go-labeled + commented card anywhere fires ready.
  home="$TMP_ROOT/poll-ready-go"; mkdir -p "$home/state"
  write_config "$home"
  local cards2='[{"id":"cg","name":"approved","idList":"L-queued","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[{"name":"go"}],"badges":{"comments":2}}]'
  out=$(run_poll "$home" "$cards2")
  [ "$out" = "trello-ready cg" ] || fail "a go-labeled + commented card must fire trello-ready (got: $out)"
  # A go label WITHOUT a comment is not a decision yet.
  home="$TMP_ROOT/poll-ready-go-nocomment"; mkdir -p "$home/state"
  write_config "$home"
  local cards3='[{"id":"cn","name":"maybe","idList":"L-queued","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[{"name":"go"}],"badges":{"comments":0}}]'
  out=$(run_poll "$home" "$cards3")
  [ -z "$out" ] || fail "a go label with no comment must not fire (got: $out)"
  pass "poll fires trello-ready for a Ready-lane card and a go-labeled+commented card"
}

test_poll_nudge_on_bound_live_task_comment() {
  local home out
  home="$TMP_ROOT/poll-nudge"; mkdir -p "$home/state"
  write_config "$home"
  fm_write_meta "$home/state/task-a.meta" "window=fm-task-a" "trello_card=cb"
  # Firstmate already saw the card in In Progress (seed the marker at T0/L-ip).
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-cb"
  # Captain comments -> activity advances, still In Progress -> nudge.
  local cards='[{"id":"cb","name":"working","idList":"L-ip","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":1}}]'
  out=$(run_poll "$home" "$cards")
  [ "$out" = "trello-nudge cb task-a" ] || fail "a new comment on a bound In-Progress card must fire trello-nudge (got: $out)"
  # A card with no binding does not nudge.
  home="$TMP_ROOT/poll-nudge-unbound"; mkdir -p "$home/state"
  write_config "$home"
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-cb"
  out=$(run_poll "$home" "$cards")
  [ -z "$out" ] || fail "an unbound In-Progress card must not nudge (got: $out)"
  pass "poll fires trello-nudge only for a new comment on a bound live-task card"
}

test_poll_hold_on_label_and_move_back() {
  local home out
  # hold label on a bound In-Progress card.
  home="$TMP_ROOT/poll-hold-label"; mkdir -p "$home/state"
  write_config "$home"
  fm_write_meta "$home/state/task-b.meta" "window=fm-task-b" "trello_card=ch"
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-ch"
  local cards='[{"id":"ch","name":"pause me","idList":"L-ip","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[{"name":"hold"}],"badges":{"comments":0}}]'
  out=$(run_poll "$home" "$cards")
  [ "$out" = "trello-hold ch task-b" ] || fail "a hold label on a bound card must fire trello-hold (got: $out)"
  # move back to Needs Input (prev lane was In Progress) -> hold.
  home="$TMP_ROOT/poll-hold-moveback"; mkdir -p "$home/state"
  write_config "$home"
  fm_write_meta "$home/state/task-c.meta" "window=fm-task-c" "trello_card=cm"
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-cm"
  local cards2='[{"id":"cm","name":"needs input","idList":"L-needs","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}}]'
  out=$(run_poll "$home" "$cards2")
  [ "$out" = "trello-hold cm task-c" ] || fail "a captain move back to Needs Input must fire trello-hold (got: $out)"
  pass "poll fires trello-hold for a hold label and for a move back to Needs Input"
}

test_poll_ignores_firstmate_owned_lanes() {
  local home out
  home="$TMP_ROOT/poll-ignore"; mkdir -p "$home/state"
  write_config "$home"
  # Cards in Queued / In Review / Done with no binding are firstmate-owned and
  # must never fire.
  local cards='[
    {"id":"q1","name":"queued","idList":"L-queued","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}},
    {"id":"v1","name":"review","idList":"L-review","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":3}},
    {"id":"d1","name":"done","idList":"L-done","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}}
  ]'
  out=$(run_poll "$home" "$cards")
  [ -z "$out" ] || fail "firstmate-owned lanes must not fire (got: $out)"
  assert_absent "$home/state/.trello-seen-q1" "an unwatched card must not leave a marker"
  pass "poll ignores firstmate-owned lanes and leaves no markers for them"
}

test_poll_bound_card_never_refires_ready() {
  local home out
  # A card bound to a live task can NEVER re-fire trello-ready in any lane.
  # (1) Bound card the captain moves INTO the Ready lane -> fires nothing.
  home="$TMP_ROOT/poll-bound-ready"; mkdir -p "$home/state"
  write_config "$home"
  fm_write_meta "$home/state/task-r.meta" "window=fm-task-r" "trello_card=crb"
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-crb"
  local cards='[{"id":"crb","name":"bound","idList":"L-ready","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":1}}]'
  out=$(run_poll "$home" "$cards")
  [ -z "$out" ] || fail "a bound card moved into Ready must NOT fire trello-ready (got: $out)"
  # (2) Bound In-Progress card carrying a stray go label + comment -> nudge, not ready.
  home="$TMP_ROOT/poll-bound-golabel"; mkdir -p "$home/state"
  write_config "$home"
  fm_write_meta "$home/state/task-g.meta" "window=fm-task-g" "trello_card=cgb"
  printf '2026-07-15T09:00:00.000Z\tL-ip\n' > "$home/state/.trello-seen-cgb"
  local cards2='[{"id":"cgb","name":"bound go","idList":"L-ip","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[{"name":"go"}],"badges":{"comments":2}}]'
  out=$(run_poll "$home" "$cards2")
  [ "$out" = "trello-nudge cgb task-g" ] || fail "a bound In-Progress card with a stray go label must nudge, not re-fire ready (got: $out)"
  pass "poll never re-fires trello-ready for a card bound to a live task"
}

test_poll_one_trigger_per_sweep() {
  local home out
  home="$TMP_ROOT/poll-one-per-sweep"; mkdir -p "$home/state"
  write_config "$home"
  # Two Inbox cards would fire in one sweep; only ONE line may be emitted and the
  # other card's marker must stay unwritten so it fires on the next sweep.
  local cards='[
    {"id":"cA","name":"first","idList":"L-inbox","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}},
    {"id":"cB","name":"second","idList":"L-inbox","dateLastActivity":"2026-07-15T10:00:00.000Z","labels":[],"badges":{"comments":0}}
  ]'
  out=$(run_poll "$home" "$cards")
  [ "$(printf '%s' "$out" | grep -c .)" = "1" ] || fail "at most one trigger line per sweep (got: $out)"
  [ "$out" = "trello-inbox cA" ] || fail "the first firing card must be emitted (got: $out)"
  assert_present "$home/state/.trello-seen-cA" "the emitted card must advance its seen marker"
  assert_absent "$home/state/.trello-seen-cB" "a deferred firing card must NOT advance its marker"
  # Next sweep: cA is seen (unchanged), cB fires.
  out=$(run_poll "$home" "$cards")
  [ "$out" = "trello-inbox cB" ] || fail "the deferred card must fire on the next sweep (got: $out)"
  pass "poll emits at most one trigger per sweep and defers the rest without dropping them"
}

test_poll_reports_error_once() {
  local home out
  home="$TMP_ROOT/poll-err"; mkdir -p "$home/state"
  write_config "$home"
  local fakebin; fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_CARDS_CODE=401 FAKE_CARDS_BODY='{}' \
    "$ROOT/bin/fm-trello-poll.sh")
  [ "$out" = "trello-mode-error board cards returned HTTP 401" ] \
    || fail "an auth error must surface one diagnostic (got: $out)"
  assert_present "$home/state/trello-poll.error" "an error must write a dedupe marker"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_LISTS_BODY="$LISTS_JSON" FAKE_CARDS_CODE=401 FAKE_CARDS_BODY='{}' \
    "$ROOT/bin/fm-trello-poll.sh")
  [ -z "$out" ] || fail "a repeated error must be quiet after the first diagnostic (got: $out)"
  pass "fm-trello-poll.sh surfaces relay errors once and dedupes"
}

# ---------------------------------------------------------------------------
# bootstrap activation
# ---------------------------------------------------------------------------

test_bootstrap_activates_on_config() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home"
  write_config "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "TRELLO: control plane on" "bootstrap must announce the control plane"
  assert_present "$home/state/trello-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/trello-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-trello-poll.sh" "$home/state/trello-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/trello-mode.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=60" "$home/config/trello-mode.env" "cadence must be 60s (once per minute)"
  sum1=$(cat "$home/state/trello-watch.check.sh" "$home/config/trello-mode.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/trello-watch.check.sh" "$home/config/trello-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap Trello setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'trello-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates the Trello control plane from config/trello.env, idempotently"
}

test_bootstrap_inert_without_config() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "TRELLO:" "bootstrap must say nothing about Trello without config"
  assert_absent "$home/state/trello-watch.check.sh" "no config -> no check shim"
  assert_absent "$home/config/trello-mode.env" "no config -> no cadence config"
  # Config present but incomplete (missing board) -> still off.
  home="$TMP_ROOT/boot-partial"; mkdir -p "$home/config"
  printf 'TRELLO_API_KEY=k\nTRELLO_TOKEN=t\n' > "$home/config/trello.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "TRELLO: control plane on" "incomplete config must be treated as off"
  assert_absent "$home/state/trello-watch.check.sh" "incomplete config -> no check shim"
  pass "bootstrap is inert without complete Trello config (non-Trello users unaffected)"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home"
  write_config "$home"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/trello-watch.check.sh" "opt-in must create the shim"
  # Opt out: remove the config, re-run -> artifacts removed + one off line.
  rm -f "$home/config/trello.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "TRELLO: control plane off" "opt-out must announce control plane off when it removed artifacts"
  assert_absent "$home/state/trello-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/config/trello-mode.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "TRELLO:" "steady-state off must be silent"
  pass "bootstrap cleans up Trello artifacts on opt-out and is silent once off"
}

# ---------------------------------------------------------------------------

test_cli_help_always_works
test_cli_noop_without_config
test_poll_noop_without_config
test_poll_noop_when_paused
test_cli_arg_errors
test_cli_comment_posts_and_hides_creds
test_cli_move_resolves_lane_dynamically
test_cli_move_unknown_lane_fails
test_cli_create_card_returns_id
test_cli_label_add_resolves_label
test_cli_get_and_list_cards
test_cli_rejects_unsafe_card_id
test_cli_http_error_fails_loudly
test_cli_bind_unbind_card_for
test_cli_pause_and_start
test_poll_inbox_trigger_and_idempotency
test_poll_ready_trigger_lane_and_go_label
test_poll_nudge_on_bound_live_task_comment
test_poll_hold_on_label_and_move_back
test_poll_ignores_firstmate_owned_lanes
test_poll_bound_card_never_refires_ready
test_poll_one_trigger_per_sweep
test_poll_reports_error_once
test_bootstrap_activates_on_config
test_bootstrap_inert_without_config
test_bootstrap_opt_out_cleanup
