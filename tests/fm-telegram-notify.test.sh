#!/usr/bin/env bash
# Outward Telegram notifications: the properties that make the feature safe to
# add to a home that is already landing work.
#
#   (a) An unconfigured home is byte-identical to one without the feature.
#   (b) Publishers make NO network call, so a Telegram outage cannot block a
#       PR registration, a merge record, or the cleanup gate that refuses to
#       remove a child while its outcome is undelivered.
#   (c) A card is built from typed fields and can never be built by forwarding
#       a parent-channel or status line.
#   (d) A card carrying a credential value is refused, loudly.
#   (e) Internal identifiers AGENTS.md section 9 forbids do not reach a card.
#   (f) The bot sends and never listens: a full drain asks Telegram for nothing.
#   (g) An outage retries silently; a rejected token reports once, not per poll.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SEND="$ROOT/bin/fm-telegram-send.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
RECONCILE="$ROOT/bin/fm-inactive-reconcile.sh"
MERGE_OUTCOME="$ROOT/bin/fm-merge-outcome-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)
BASE_PATH=$PATH
# A distinctive value so a card that leaked it is unmistakable in an assertion.
BOT_TOKEN='123456:AA-fixture-bot-token-never-real'

API_PID=
cleanup() {
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- fixtures ---------------------------------------------------------------

make_home() {  # <name> [configured]
  local name=$1 configured=${2:-configured} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/wt" "$dir/project" "$dir/fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  if [ "$configured" = configured ]; then
    printf '%s\n' "$BOT_TOKEN" > "$dir/token"
    chmod 0600 "$dir/token"
    printf '4242\n' > "$dir/home/config/telegram-chat-id"
    printf '%s\n' "$dir/token" > "$dir/home/config/telegram-token-path"
  fi
  printf '%s\n' "$dir"
}

# The fake Telegram API. Every request is logged with its method and path, so a
# case can assert not only what was sent but that nothing else was ever asked
# for - which is how "the bot never listens" is proven rather than asserted.
start_api() {  # <dir>
  local dir=$1 port
  : > "$dir/api.log"
  printf 'ok\n' > "$dir/api.mode"
  cat > "$dir/api.py" <<'PY'
import http.server
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
log = root / "api.log"
mode_file = root / "api.mode"
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _handle(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        with lock:
            with log.open("a", encoding="utf-8") as fh:
                fh.write(f"{method} {self.path} {body}\n")
        mode = mode_file.read_text(encoding="utf-8").strip() or "ok"
        if mode == "401":
            payload, code = b'{"ok":false,"error_code":401}', 401
        elif mode == "500":
            payload, code = b'{"ok":false}', 500
        elif mode == "notok":
            payload, code = b'{"ok":false,"description":"chat not found"}', 200
        elif mode == "spaced":
            payload, code = b'{"ok": true}', 200
        else:
            payload, code = b'{"ok":true,"result":{"message_id":1}}', 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        self._handle("POST")

    def do_GET(self):
        self._handle("GET")

    def log_message(self, *_args):
        return


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
  # The server must not inherit this script's stdout: a runner that pipes the
  # suite would then wait on the server for end-of-input long after the last
  # case passed. It publishes its port to a file instead.
  local waited=0
  : > "$dir/api.port"
  python3 "$dir/api.py" "$dir" > "$dir/api.port" 2> "$dir/api.err" < /dev/null &
  API_PID=$!
  while [ "$waited" -lt 100 ]; do
    port=$(head -1 "$dir/api.port" 2>/dev/null || true)
    [ -z "$port" ] || break
    kill -0 "$API_PID" 2>/dev/null || fail "the fake Telegram API exited: $(cat "$dir/api.err")"
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$port" ] || fail "the fake Telegram API did not report a port"
  printf 'http://127.0.0.1:%s\n' "$port"
}

stop_api() {
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
  [ -z "$API_PID" ] || wait "$API_PID" 2>/dev/null || true
  API_PID=
}

# Publish through the seam exactly as a publisher does, and print nothing but
# what the library wrote to stderr.
report() {  # <dir> <line> [card args...]
  local dir=$1
  shift
  FM_CONFIG_OVERRIDE="$dir/home/config" \
    bash -c '. "$1"; shift; fm_parent_channel_report "$@"' _ \
    "$ROOT/bin/fm-parent-channel-lib.sh" "$dir/home" "$dir/home/state" "$@"
}

render() {  # <class> <name=value>...
  bash -c '. "$1"; shift; fm_telegram_card_render "$@"' _ \
    "$ROOT/bin/fm-telegram-lib.sh" "$@"
}

run_send() {  # <dir> <api-base-or-empty> [args...]
  local dir=$1 base=$2
  shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$SEND" "$@"
}

cards_in() {  # <dir>
  local card
  for card in "$1"/home/state/telegram-outbox/*.card; do
    [ -f "$card" ] || continue
    printf '%s\n' "$card"
  done
}

card_count() {  # <dir>
  cards_in "$1" | grep -c . || true
}

only_card() {  # <dir>
  local n
  n=$(card_count "$1")
  [ "$n" = 1 ] || fail "expected exactly one queued card, found $n"
  cards_in "$1" | head -1
}

# --- cases ------------------------------------------------------------------

test_unconfigured_home_is_inert() {
  local dir out rc=0
  dir=$(make_home inert unconfigured)
  out=$(report "$dir" "needs-decision [key=captain-hold-x-1]: captain hold x: pick one" \
    decision captain-hold-x-1 "title=Pick a database" "reason=postgres or sqlite" 2>&1) || rc=$?
  # A main home has no parent channel: rc 1 is exactly today's answer.
  [ "$rc" -eq 1 ] || fail "an unconfigured main home changed its publish result (rc=$rc)"
  [ -z "$out" ] || fail "an unconfigured home produced output: $out"
  [ ! -e "$dir/home/state/telegram-outbox" ] \
    || fail "an unconfigured home created an outbox"

  out=$(run_send "$dir" '' check 2>&1) || fail "the drain failed in an unconfigured home"
  [ -z "$out" ] || fail "the drain spoke in an unconfigured home: $out"

  rc=0
  out=$(run_send "$dir" '' arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arming succeeded in a home with no Telegram configuration"
  case "$out" in
    *"not configured"*) ;;
    *) fail "arming an unconfigured home did not say why: $out" ;;
  esac
  [ ! -e "$dir/home/state/telegram-outbox.check.sh" ] \
    || fail "a refused arm still left a check shim behind"
  pass "a home with no Telegram configuration behaves exactly as one without the feature"
}

test_an_unusable_token_file_is_inert() {
  local dir out rc=0
  dir=$(make_home bad-token)
  printf 'not a token\n' > "$dir/token"
  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a token file that cannot be used changed the publish result (rc=$rc)"
  [ -z "$out" ] || fail "a token file that cannot be used produced output: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "a token file that cannot be used queued a card"
  # Surrounding blanks in a hand-written config item must not read as absence.
  printf '123456:AA-fixture-bot-token-never-real\n' > "$dir/token"
  printf '  4242  \n' > "$dir/home/config/telegram-chat-id"
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "a chat id written with surrounding blanks read as absent"
  pass "a token file that is not one line of credential is the absent feature, and a padded config value is not"
}

test_absent_token_is_inert() {
  local dir out rc=0
  dir=$(make_home no-token)
  rm -f "$dir/token"
  out=$(report "$dir" "done [key=pr-t1]: child t1 PR ready: https://example.test/o/r/pull/1" \
    pr-ready pr-t1 "project=alpha" "url=https://example.test/o/r/pull/1" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a home whose token file is gone changed its publish result (rc=$rc)"
  [ -z "$out" ] || fail "a home whose token file is gone produced output: $out"
  [ ! -e "$dir/home/state/telegram-outbox" ] \
    || fail "a home whose token file is gone queued a card"
  pass "an absent token file is the absent feature, silently"
}

test_card_is_built_from_typed_fields() {
  local dir card
  dir=$(make_home typed)
  report "$dir" "needs-decision [key=captain-hold-tg-1]: captain hold tg: aged account or age one" \
    decision captain-hold-tg-1 \
    "title=telegram: stand up the session on the office machine" \
    "reason=aged account or age one" >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  [ "$(head -1 "$card")" = "Decision waiting" ] \
    || fail "the decision card lost its heading: $(head -1 "$card")"
  grep -Fq 'telegram: stand up the session on the office machine' "$card" \
    || fail "the decision card lost the captain's own title"
  grep -Fq 'aged account or age one' "$card" || fail "the decision card lost the reason"
  grep -Fq 'key=' "$card" && fail "the decision card carried a decision key"
  grep -Fq 'captain-hold-tg-1' "$card" && fail "the decision card carried a task id"
  [ "$(stat -c %a "$card" 2>/dev/null || stat -f %Lp "$card")" = 600 ] \
    || fail "a queued card is not private"
  pass "a decision card carries the captain's own words and none of the machine line"
}

test_all_four_classes_render() {
  local out
  out=$(render decision "title=Pick one" "reason=a or b") || fail "the decision card would not render"
  [ "$out" = "Decision waiting
Pick one
a or b" ] || fail "unexpected decision card: $out"
  out=$(render pr-ready "project=alpha" "url=https://example.test/o/r/pull/7") \
    || fail "the PR card would not render"
  [ "$out" = "Ready for your review
alpha
https://example.test/o/r/pull/7" ] || fail "unexpected PR card: $out"
  out=$(render failed "project=alpha" "note=the migration step never finished") \
    || fail "the failure card would not render"
  [ "$out" = "Work stopped
alpha
the migration step never finished" ] || fail "unexpected failure card: $out"
  out=$(render landed "project=alpha" "url=https://example.test/o/r/pull/7") \
    || fail "the landed card would not render"
  [ "$out" = "Work landed
alpha
https://example.test/o/r/pull/7" ] || fail "unexpected landed card: $out"

  render decision "reason=a or b" >/dev/null 2>&1 \
    && fail "a decision card rendered with no title"
  render pr-ready "project=alpha" >/dev/null 2>&1 \
    && fail "a PR card rendered with no URL"
  render invented "title=x" >/dev/null 2>&1 \
    && fail "an unknown card class rendered"
  render decision "title=x" "worktree=/tmp/wt" >/dev/null 2>&1 \
    && fail "a card accepted a field outside its own set"
  pass "the four card classes render from their own required fields and refuse anything else"
}

test_a_raw_status_line_cannot_become_a_card() {
  local dir out line rc=0
  dir=$(make_home rawline)
  line="failed [key=child-outcome-t1-failed-abcd1234]: child t1 failed: the build broke"
  out=$(report "$dir" "$line" failed child-outcome-t1-failed-abcd1234 \
    "project=alpha" "note=$line" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "refusing a forwarded line changed the publish result (rc=$rc)"
  [ "$(card_count "$dir")" = 0 ] || fail "a card was built by forwarding a status line"
  case "$out" in
    *"raw status line"*) ;;
    *) fail "forwarding a status line was refused silently: $out" ;;
  esac
  # The same refusal at the rendering interface, for every shape a channel or
  # crewmate line takes.
  render failed "project=alpha" "note=done: shipped it" >/dev/null 2>&1 \
    && fail "a crewmate status line rendered as a card"
  render decision "title=needs-decision: which database" >/dev/null 2>&1 \
    && fail "a needs-decision status line rendered as a card"
  pass "a card can never be built by forwarding a parent-channel or status line"
}

test_a_credential_value_is_refused_loudly() {
  local dir out rc=0
  dir=$(make_home secret)
  printf '%s\n' "$dir/extra-credential" > "$dir/home/config/telegram-secret-files"
  printf 'super-secret-api-key-value\n' > "$dir/extra-credential"
  chmod 0600 "$dir/extra-credential"

  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the run died holding $BOT_TOKEN" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] || fail "a card carrying the bot token was queued"
  case "$out" in
    *"credential value"*) ;;
    *) fail "a card carrying the bot token was dropped silently: $out" ;;
  esac
  case "$out" in
    *"$BOT_TOKEN"*) fail "the refusal diagnostic printed the credential it refused" ;;
  esac

  out=$(report "$dir" "failed [key=k2]: child t1 failed: x" failed k2 \
    "project=alpha" "note=config said super-secret-api-key-value" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] \
    || fail "a card carrying a value from config/telegram-secret-files was queued"

  # A refusal is about real values, not about anything that merely looks secret.
  report "$dir" "failed [key=k3]: child t1 failed: x" failed k3 \
    "project=alpha" "note=the token check failed" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "an ordinary card was refused as a secret"
  pass "a card carrying a real credential value is refused, and the refusal is loud"
}

test_internal_identifiers_do_not_reach_a_card() {
  local dir card out
  dir=$(make_home scrub)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" \
    "note=build failed on branch fm/task-x under claude in /home/captain/wt/alpha with harness=claude mode=no-mistakes key=child-outcome-t1 branch=fm/task-x" \
    >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  grep -Fq '/home/captain' "$card" && fail "a card carried an absolute worktree path"
  grep -Fq 'harness=' "$card" && fail "a card carried a harness name"
  grep -Fq 'mode=' "$card" && fail "a card carried a delivery mode"
  grep -Fq 'key=' "$card" && fail "a card carried a decision key"
  grep -Fq 'branch=' "$card" && fail "a card carried a branch name"
  grep -Fq 'fm/task-x' "$card" && fail "a card carried a bare branch ref"
  grep -Fq 'claude' "$card" && fail "a card carried a bare harness name"
  grep -Fq 'build failed on branch' "$card" || fail "scrubbing removed the readable part of the note"
  out=$(render pr-ready "project=alpha" "url=https://example.test/fm/repo/pull/7") \
    || fail "a PR URL containing an fm path would not render"
  grep -Fq 'https://example.test/fm/repo/pull/7' <<< "$out" \
    || fail "scrubbing ate a PR URL"
  pass "the internal identifiers section 9 forbids do not reach a card"
}

test_pr_card_identity_tracks_the_canonical_pr() {
  local dir first_url second_url meta
  dir=$(make_home pr-identity)
  first_url=https://github.com/owner/repo/pull/12
  second_url=https://github.com/owner/repo/pull/13
  meta="$dir/home/state/t1.meta"
  fm_write_meta "$meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$meta"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$first_url" >/dev/null 2>&1 \
    || fail "registering the first PR failed"
  [ "$(card_count "$dir")" = 1 ] || fail "the first PR queued no card"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$first_url" >/dev/null 2>&1 \
    || fail "retrying the same PR failed"
  [ "$(card_count "$dir")" = 1 ] || fail "an exact PR retry queued another card"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$second_url" >/dev/null 2>&1 \
    || fail "registering the replacement PR failed"
  [ "$(card_count "$dir")" = 2 ] || fail "the replacement PR did not queue a distinct card"
  grep -R -Fq "$first_url" "$dir/home/state/telegram-outbox" \
    || fail "the first PR card was lost"
  grep -R -Fq "$second_url" "$dir/home/state/telegram-outbox" \
    || fail "the replacement PR card was lost"
  pass "exact PR retries deduplicate while replacement PRs remain distinct"
}

test_publishers_make_no_network_call() {
  local dir base url meta
  dir=$(make_home nonetwork)
  base=$(start_api "$dir")
  url=https://github.com/owner/repo/pull/12
  meta="$dir/home/state/t1.meta"
  fm_write_meta "$meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$meta"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" t1 "$url" >/dev/null 2>&1 \
    || fail "registering a PR failed in a Telegram-configured home"

  grep -q "^pr=$url$" "$meta" || fail "the PR was not recorded"
  [ -s "$dir/home/state/t1.check.sh" ] || fail "the merge poll was not armed"
  [ "$(card_count "$dir")" = 1 ] || fail "registering a PR queued no card"
  [ ! -s "$dir/api.log" ] \
    || fail "a publisher called Telegram on the critical path: $(cat "$dir/api.log")"
  stop_api
  pass "registering a PR records the PR, queues a card, and calls Telegram not at all"
}

test_cleanup_gate_is_unaffected_by_an_unreachable_telegram() {
  local dir parent
  dir=$(make_home cleanup-gate)
  parent="$dir/parent"
  mkdir -p "$parent/state"
  printf 'mate\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/home/.fm-secondmate-parent"
  fm_write_meta "$dir/home/state/c1.meta" "window=firstmate:fm-c1" \
    "endpoint_task_id=c1" "worktree=$dir/wt" "project=$dir/project" "kind=ship"
  printf 'failed: the migration step never finished\n' > "$dir/home/state/c1.status"

  # This is the exact call bin/fm-teardown.sh makes before it will remove a
  # child, and it refuses when the outcome has not reached the parent channel.
  # Telegram is not running at all here.
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="http://127.0.0.1:1" PATH="$dir/fakebin:$BASE_PATH" \
    "$RECONCILE" report c1 >/dev/null 2>&1 \
    || fail "the cleanup gate refused while Telegram was unreachable"
  grep -Fq 'child c1 failed' "$parent/state/mate.status" \
    || fail "the child's outcome did not reach the parent channel"
  [ "$(card_count "$dir")" = 1 ] || fail "the failure queued no card"
  pass "the gate that refuses to remove a child is unaffected by an unreachable Telegram"
}

test_secondmate_failure_cards_track_incarnations() {
  local dir parent meta status
  dir=$(make_home secondmate-incarnations)
  parent="$dir/parent"
  meta="$dir/home/state/c1.meta"
  status="$dir/home/state/c1.status"
  mkdir -p "$parent/state"
  printf 'mate\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/home/.fm-secondmate-parent"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: failed - source: fixture\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"

  fm_write_meta "$meta" "window=firstmate:fm-c1" "endpoint_task_id=c1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "spawn_gen=spawn-one"
  printf 'working: quiet since\n' > "$status"
  touch -t 200001010000 "$meta" "$status"
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "the first failed incarnation was not reconciled"
  [ "$(card_count "$dir")" = 1 ] || fail "the first failed incarnation queued no card"

  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "retrying the first failed incarnation failed"
  [ "$(card_count "$dir")" = 1 ] || fail "an exact failed-incarnation retry queued another card"

  rm -f "$meta" "$status" "$dir/home/state/c1.turn-ended"
  fm_write_meta "$meta" "window=firstmate:fm-c1" "endpoint_task_id=c1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "spawn_gen=spawn-two"
  printf 'working: quiet since\n' > "$status"
  touch -t 200001010000 "$meta" "$status"
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "the replacement failed incarnation was not reconciled"
  [ "$(card_count "$dir")" = 2 ] || fail "the replacement failed incarnation queued no distinct card"
  [ "$(grep -Fc '[key=inactive-outcome-mate-c1-failed]' "$parent/state/mate.status")" = 2 ] \
    || fail "card identity changes altered the parent-channel key"
  pass "secondmate failure cards distinguish incarnations without changing channel keys"
}

test_merge_recording_survives_card_digest_failure() {
  local dir state out
  dir=$(make_home merge-digest)
  state="$dir/home/state"
  fm_write_meta "$state/t1.meta" "project=$dir/project"
  out=$(FM_CONFIG_OVERRIDE="$dir/home/config" bash -c '
    . "$1"
    fm_telegram_event_digest() { return 1; }
    fm_merge_outcome_report "$2" "$3" t1 https://github.com/owner/repo/pull/12 self
    fm_merge_outcome_report "$2" "$3" t1 https://github.com/owner/repo/pull/13 self
  ' _ "$MERGE_OUTCOME" "$dir/home" "$state" 2>&1) \
    || fail "merge recording inherited a card digest failure: $out"
  [ ! -e "$state/t1.pr-poll-merge-notified.lock" ] \
    || fail "a card digest failure left the merge lock held"
  [ "$(grep -c 'check: merge landed: t1' "$state/.wake-queue")" = 2 ] \
    || fail "a card digest failure skipped a merge outcome"
  [ "$(card_count "$dir")" = 0 ] || fail "a failed card identity queued an unsafe card"
  pass "card digest failures cannot block or lock merge outcome recording"
}

test_drain_sends_and_never_listens() {
  local dir base card key
  dir=$(make_home drain)
  base=$(start_api "$dir")
  report "$dir" "done [key=merged-t1]: merged t1 https://example.test/o/r/pull/3" \
    landed merged-t1 "project=alpha" "url=https://example.test/o/r/pull/3" >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  key=$(basename "$card" .card)

  run_send "$dir" "$base" check >"$dir/out" 2>&1 || fail "the drain failed"
  [ ! -s "$dir/out" ] || fail "a successful drain spoke: $(cat "$dir/out")"
  [ "$(card_count "$dir")" = 0 ] || fail "a delivered card stayed queued"
  grep -Fq "POST /bot$BOT_TOKEN/sendMessage" "$dir/api.log" \
    || fail "the drain did not send the card: $(cat "$dir/api.log")"
  grep -Fq 'Work+landed' "$dir/api.log" || grep -Fq 'Work%20landed' "$dir/api.log" \
    || fail "the sent body did not carry the card text: $(cat "$dir/api.log")"
  grep -Fq 'getUpdates' "$dir/api.log" \
    && fail "the bot asked Telegram for messages: $(cat "$dir/api.log")"
  [ "$(grep -c . "$dir/api.log")" = 1 ] \
    || fail "the drain made more than the one send: $(cat "$dir/api.log")"
  grep -Fq "${key##*-}" "$dir/home/state/telegram-outbox/.delivered" \
    || fail "the delivered key was not recorded"

  # The same outcome published again must not produce a second card.
  report "$dir" "done [key=merged-t1]: merged t1 https://example.test/o/r/pull/3" \
    landed merged-t1 "project=alpha" "url=https://example.test/o/r/pull/3" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 0 ] || fail "a re-published outcome queued a second card"
  stop_api
  pass "a drain sends each card once, asks Telegram for nothing, and never repeats an outcome"
}

test_whitespace_in_success_response_is_accepted() {
  local dir base out
  dir=$(make_home spaced-response)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  base=$(start_api "$dir")
  printf 'spaced\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the spaced success drain failed"
  [ -z "$out" ] || fail "a spaced success response emitted a configuration wake: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "a spaced success response left the card queued"
  [ ! -e "$dir/home/state/telegram-send.error" ] \
    || fail "a spaced success response recorded a false configuration error"
  stop_api
  pass "Telegram success responses are accepted independent of whitespace"
}

test_outage_retries_silently_and_a_rejection_reports_once() {
  local dir base out
  dir=$(make_home degrade)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "no card to drain"

  # Nothing is listening: the card waits, and the drain says nothing.
  out=$(run_send "$dir" 'http://127.0.0.1:1' check 2>&1) \
    || fail "the drain failed while Telegram was unreachable"
  [ -z "$out" ] || fail "an outage produced a wake: $out"
  [ "$(card_count "$dir")" = 1 ] || fail "an outage lost the card"

  # A rejected token is reported once, not once per poll.
  base=$(start_api "$dir")
  printf '401\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the drain failed on a rejected token"
  case "$out" in
    *"HTTP 401"*) ;;
    *) fail "a rejected token was not reported: $out" ;;
  esac
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the second drain failed"
  [ -z "$out" ] || fail "a rejected token woke firstmate twice: $out"
  [ "$(card_count "$dir")" = 1 ] || fail "a rejected token discarded the card"

  # Once the token works again the queued card is delivered.
  printf 'ok\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the recovery drain failed"
  [ -z "$out" ] || fail "the recovery drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the queued card was not delivered after recovery"
  stop_api
  pass "an outage retries in silence, a rejected token wakes firstmate once, and the card survives both"
}

test_arm_and_disarm() {
  local dir base out
  dir=$(make_home arm)
  base=$(start_api "$dir")
  out=$(run_send "$dir" "$base" arm 2>&1) || fail "arming failed: $out"
  case "$out" in
    'armed: state/telegram-outbox.check.sh') ;;
    *) fail "unexpected arm result: $out" ;;
  esac
  [ -f "$dir/home/state/telegram-outbox.check.sh" ] || fail "arming wrote no check"
  [ -f "$dir/home/state/telegram-outbox.check-trust" ] || fail "arming bound no trust record"
  [ "$(stat -c %a "$dir/home/state/telegram-outbox.check.sh" 2>/dev/null \
    || stat -f %Lp "$dir/home/state/telegram-outbox.check.sh")" = 700 ] \
    || fail "the check shim is not a private executable"

  # The shim the watcher will run is the drain.
  report "$dir" "failed [key=k9]: child t1 failed: x" failed k9 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$dir/home/state/telegram-outbox.check.sh" >/dev/null 2>&1 \
    || fail "the armed check shim failed"
  [ "$(card_count "$dir")" = 0 ] || fail "the armed check shim did not drain the outbox"

  out=$(run_send "$dir" "$base" status 2>&1) || fail "status failed: $out"
  case "$out" in
    *'armed: yes'*) ;;
    *) fail "status did not report the home as armed: $out" ;;
  esac
  case "$out" in
    *"$BOT_TOKEN"*) fail "status printed the bot token" ;;
  esac

  out=$(run_send "$dir" "$base" disarm 2>&1) || fail "disarming failed: $out"
  [ ! -e "$dir/home/state/telegram-outbox.check.sh" ] || fail "disarming left the check"
  [ ! -e "$dir/home/state/telegram-outbox.check-trust" ] || fail "disarming left the trust record"
  stop_api
  pass "arming registers a drain the watcher can run, and disarming removes it"
}

test_unconfigured_home_is_inert
test_absent_token_is_inert
test_an_unusable_token_file_is_inert
test_card_is_built_from_typed_fields
test_all_four_classes_render
test_a_raw_status_line_cannot_become_a_card
test_a_credential_value_is_refused_loudly
test_internal_identifiers_do_not_reach_a_card
test_pr_card_identity_tracks_the_canonical_pr
test_publishers_make_no_network_call
test_cleanup_gate_is_unaffected_by_an_unreachable_telegram
test_secondmate_failure_cards_track_incarnations
test_merge_recording_survives_card_digest_failure
test_drain_sends_and_never_listens
test_whitespace_in_success_response_is_accepted
test_outage_retries_silently_and_a_rejection_reports_once
test_arm_and_disarm

echo "all telegram notification tests passed"
