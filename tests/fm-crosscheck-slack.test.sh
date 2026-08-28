#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for bin/fm-crosscheck-slack.py + bin/fm-crosscheck-slack.sh
# (R10: crosscheck exposed to team engineers through Slack).
#
# Hermetic: no Slack connection is ever opened. The event-handling core
# (handle_mention) is driven directly with parsed events through the REAL
# module code; the crosscheck CLI is a fixture binary that writes a real
# ledger shape; Slack posts/reactions land in local capture files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The listener parses hostile JSON through fm_bounded_io, whose defense needs
# the 3.11 interpreter floor; resolve through the same owner the gate uses.
# shellcheck source=bin/fm-crosscheck-python-lib.sh
. "$ROOT/bin/fm-crosscheck-python-lib.sh"
PYTHON="$(fm_crosscheck_resolve_python)" || fail "no supported python interpreter"

BOT_PY="$ROOT/bin/fm-crosscheck-slack.py"
BOT_SH="$ROOT/bin/fm-crosscheck-slack.sh"
SERVICE_SH="$ROOT/bin/fm-crosscheck-slack-service.sh"

fm_test_tmproot_into TMP_ROOT fm-crosscheck-slack-tests

# Model the macOS plist editing interface for service fixtures on every host.
# Parse and serialize actual plists so the service's consumer validates output.
PLIST_BIN=$(fm_fakebin "$TMP_ROOT/plist-tools")
printf '#!%s\n' "$("$PYTHON" -c 'import sys; print(sys.executable)')" > "$PLIST_BIN/plutil"
cat >> "$PLIST_BIN/plutil" <<'PY'
import plistlib
import sys
from pathlib import Path

args = sys.argv[1:]
path = Path(args[-1])
if args[:-1] == ["-create", "xml1"]:
    value = {}
else:
    if args[0] != "-insert":
        raise SystemExit("unsupported fixture plutil operation")
    value = plistlib.loads(path.read_bytes())
    kind = args[2]
    if kind == "-array" and len(args) == 4:
        item = []
    elif kind == "-dictionary" and len(args) == 4:
        item = {}
    elif kind == "-string" and len(args) == 5:
        item = args[3]
    elif kind == "-integer" and len(args) == 5:
        item = int(args[3])
    elif kind == "-bool" and len(args) == 5 and args[3] in ("true", "false"):
        item = args[3] == "true"
    else:
        raise SystemExit("unsupported fixture plutil value")
    keys = args[1].split(".")
    parent = value
    for key in keys[:-1]:
        parent = parent[int(key)] if isinstance(parent, list) else parent[key]
    if isinstance(parent, list):
        parent.insert(int(keys[-1]), item)
    else:
        if keys[-1] in parent:
            raise SystemExit("duplicate fixture plist key")
        parent[keys[-1]] = item
path.write_bytes(plistlib.dumps(value))
PY
chmod +x "$PLIST_BIN/plutil"
export PATH="$PLIST_BIN:$PATH"

HOMEDIR="$TMP_ROOT/home"
OUTDIR="$TMP_ROOT/out"
POSTS="$TMP_ROOT/posts.jsonl"
REACTS="$TMP_ROOT/reacts.jsonl"
FIXTURE_LOG="$TMP_ROOT/fixture-invocations.log"
DRIVER="$TMP_ROOT/driver.py"
FIXTURE="$TMP_ROOT/fake-crosscheck.sh"
REVIEWER_CONFIG="$HOMEDIR/config/crosscheck-reviewer.json"
REVIEWER_HOME="$TMP_ROOT/reviewer-home"
mkdir -p "$HOMEDIR/config" "$HOMEDIR/state" "$HOMEDIR/data" "$OUTDIR" "$REVIEWER_HOME"
cat > "$REVIEWER_CONFIG" <<JSON
{
  "reviewers": [
    {
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "$REVIEWER_HOME"
    }
  ]
}
JSON
: > "$POSTS"
: > "$REACTS"
: > "$FIXTURE_LOG"

# Distinctive token values: test_tokens_never_reach_logs_or_ledgers greps every
# artifact for these exact strings at the end of the suite.
APP_TOKEN='xapp-1-SECRETAPP-cafef00dcafef00d'
BOT_TOKEN='xoxb-SECRETBOT-deadbeefdeadbeef'
GH_TOKEN_VALUE='ghp_SECRETGITHUB0123456789abcdef'

CONFIG_MAIN="$TMP_ROOT/config-main.json"
CONFIG_BUDGET="$TMP_ROOT/config-budget.json"
CONFIG_CAP="$TMP_ROOT/config-cap.json"
CONFIG_TINYBUDGET="$TMP_ROOT/config-tinybudget.json"

write_config() { # <path> <daily_budget_usd-json> <daily_request_cap-json>
  cat > "$1" <<JSON
{
  "app_token_env": "FM_TEST_SLACK_APP_TOKEN",
  "bot_token_env": "FM_TEST_SLACK_BOT_TOKEN",
  "channel_allowlist": ["C0TESTCHAN"],
  "repo_allowlist": ["ruby-labs/goodrepo"],
  "github_token_env": "FM_TEST_GITHUB_READ_TOKEN",
  "daily_budget_usd": $2,
  "daily_request_cap": $3,
  "state_dir": "\$FM_HOME/state/crosscheck-slack"
}
JSON
}
write_config "$CONFIG_MAIN" null null
write_config "$CONFIG_BUDGET" 5.0 null
write_config "$CONFIG_CAP" null 2
write_config "$CONFIG_TINYBUDGET" 0.01 null

# The fixture crosscheck binary: records every invocation, refuses if a Slack
# token leaked into its environment, verifies the bot staged real task
# author-free exact-head admission, and writes a real ledger + report shape.
cat > "$FIXTURE" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FIXTURE_LOG"
if [ -n "${FM_TEST_SLACK_APP_TOKEN:-}" ] || [ -n "${FM_TEST_SLACK_BOT_TOKEN:-}" ]; then
  echo "SLACK TOKEN LEAKED INTO CROSSCHECK ENV" >&2
  exit 66
fi
[ "${1:-}" = run ] || { echo "fixture: expected run, got ${1:-}" >&2; exit 65; }
task=$2
url=$3
meta="$FM_HOME/state/$task.meta"
[ ! -e "$meta" ] || {
  echo "fixture: Slack admission produced forbidden author metadata at $meta" >&2
  exit 67
}
if find "$FM_HOME/data/$task" -maxdepth 1 -type f -iname '*attestation*' | grep -q .; then
  echo "fixture: Slack admission produced a forbidden authorship artifact" >&2
  exit 68
fi
mode=${FM_FIXTURE_MODE:-clear}
if [ "$mode" = fail ]; then
  echo "fixture: induced tool failure" >&2
  exit 1
fi
reviewer_json=${FM_FIXTURE_REVIEWER_JSON:-}
[ -n "$reviewer_json" ] || reviewer_json='{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}'
usage_json=${FM_FIXTURE_USAGE_JSON:-}
[ -n "$usage_json" ] || usage_json=null
findings_json=${FM_FIXTURE_FINDINGS_JSON:-}
[ -n "$findings_json" ] || findings_json='[]'
dest="$FM_HOME/data/$task"
mkdir -p "$dest"
cat > "$dest/crosscheck-ledger.json" <<JSON
{
  "schema": "firstmate.crosscheck-ledger.v2",
  "task_id": "$task",
  "pr_url": "$url",
  "findings": $findings_json,
  "runs": [
    {
      "at": "2026-08-20T00:00:00Z",
      "head_sha": "${FM_FIXTURE_HEAD_SHA:-1111111111111111111111111111111111111111}",
      "state": "$mode",
      "summary": "fixture review summary",
      "reviewer": $reviewer_json,
      "usage": $usage_json,
      "telemetry": {
        "tokens": {"input": 100000, "output": 10000, "cache_read": 50000, "cache_write": 0},
        "costs_usd": {"provider_reported": null, "pi_calculated": 3.5, "declared": 3.5}
      }
    }
  ]
}
JSON
printf '# Crosscheck\n' > "$dest/crosscheck.md"
[ "$mode" = clear ]
SH
chmod +x "$FIXTURE"

# The driver loads the REAL module and drives its real entry points; posts and
# reactions are captured raw (deliberately without the web client's redaction)
# so a token that reached reply text would be caught by the leak grep.
cat > "$DRIVER" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location(
    "fm_crosscheck_slack", os.environ["FMT_BOT_PY"]
)
mod = importlib.util.module_from_spec(spec)
sys.modules["fm_crosscheck_slack"] = mod
spec.loader.exec_module(mod)

command = sys.argv[1]

if command == "extract":
    cases = [
        (
            "plain link https://github.com/Ruby-Labs/goodrepo/pull/42 ok",
            ["https://github.com/Ruby-Labs/goodrepo/pull/42"],
        ),
        (
            "slack-wrapped <https://github.com/ruby-labs/goodrepo/pull/7|PR 7>",
            ["https://github.com/ruby-labs/goodrepo/pull/7"],
        ),
        (
            "dup <https://github.com/A/b/pull/1> and https://github.com/a/B/pull/1",
            ["https://github.com/A/b/pull/1"],
        ),
        (
            "two <https://github.com/a/b/pull/1> <https://github.com/a/b/pull/2>",
            ["https://github.com/a/b/pull/1", "https://github.com/a/b/pull/2"],
        ),
        ("no links here, just github.com/a/b/pull/3 without scheme", []),
        # An over-long PR number must be refused whole, never truncated into
        # a different, shorter PR id inside an allowlisted repository.
        ("https://github.com/a/b/pull/12345678901 is too long", []),
        ("http://github.com/a/b/pull/4 is not https", []),
        ("https://github.com/a/b/issues/5 is not a pull", []),
        ("https://evilgithub.com/a/b/pull/6 is not github.com", []),
        ("", []),
    ]
    for text, expected in cases:
        got = mod.extract_pr_links(text)
        if got != expected:
            print(f"extract mismatch for {text!r}: {got} != {expected}")
            sys.exit(1)
    if mod.repo_of("https://github.com/Ruby-Labs/GoodRepo/pull/9") != "ruby-labs/goodrepo":
        print("repo_of did not normalize case")
        sys.exit(1)
    print("extract-ok")
    sys.exit(0)

if command == "redact-unit":
    mod.register_secret("tok-sekrit-123")
    out = mod.redact("before tok-sekrit-123 after")
    if "tok-sekrit-123" in out or "[redacted]" not in out:
        print(f"redact failed: {out!r}")
        sys.exit(1)
    print("redact-ok")
    sys.exit(0)

if command == "mention":
    config = mod.load_config(Path(os.environ["FM_CROSSCHECK_SLACK_CONFIG"]))
    app_token = mod.required_token(config.app_token_env, "Slack app-level (Socket Mode) token")
    bot_token = mod.required_token(config.bot_token_env, "Slack bot token")
    github_token = mod.required_token(config.github_token_env, "GitHub read credential")
    posts = Path(os.environ["FMT_POSTS"])
    reacts = Path(os.environ["FMT_REACTS"])
    fail_verdict_post = os.environ.get("FMT_FAIL_VERDICT_POST") == "1"
    event = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    head_sha = os.environ.get("FMT_HEAD_SHA") or "1" * 40
    head_after = os.environ.get("FMT_HEAD_AFTER") or head_sha

    def post(channel, thread_ts, text):
        if fail_verdict_post and text.startswith("Crosscheck "):
            raise RuntimeError("induced post failure")
        with posts.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps({"channel": channel, "thread_ts": thread_ts, "text": text}) + "\n"
            )

    def react(channel, ts, name):
        with reacts.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"channel": channel, "ts": ts, "name": name}) + "\n")

    def pr_snapshot(pr_url):
        if head_sha == "ERROR":
            raise RuntimeError("induced PR head lookup failure")
        return mod.PrSnapshot(
            pr_url=pr_url,
            repository=mod.repo_of(pr_url),
            number=int(mod.PR_LINK_RE.fullmatch(pr_url).group(3)),
            head_sha=head_sha,
        )

    def current_snapshot(pr_url):
        return mod.PrSnapshot(
            pr_url=pr_url,
            repository=mod.repo_of(pr_url),
            number=int(mod.PR_LINK_RE.fullmatch(pr_url).group(3)),
            head_sha=head_after,
        )

    config.state_dir.mkdir(parents=True, exist_ok=True)
    ctx = mod.MentionContext(
        config=config,
        meter=mod.DailyMeter(config.state_dir / "meter"),
        deduper=mod.EventDeduper(config.state_dir / "events"),
        post=post,
        react=react,
        reviewer_preflight=mod.make_reviewer_preflight(),
        run_review=mod.make_run_review(
            config, github_token, current_snapshot=current_snapshot
        ),
        pr_snapshot=pr_snapshot,
    )
    action = mod.handle_mention(os.environ["FMT_EVENT_ID"], event, ctx)
    print(f"action: {action}")
    sys.exit(0)

if command == "rollover-unit":
    state_dir = Path(os.environ["FMT_METER_DIR"])
    day_one = "2026-01-01"
    day_two = "2026-01-02"
    meter_d1 = mod.DailyMeter(state_dir, day_fn=lambda: day_one)
    request_id, refusal, _ = meter_d1.begin(
        "U0NIGHTOWL", "https://github.com/a/b/pull/1", "ev-night-1"
    )
    if refusal is not None or request_id is None:
        print(f"unexpected meter refusal: {refusal}")
        sys.exit(1)
    if not request_id.startswith(f"req-{day_one}-"):
        print(f"request id does not encode its origin day: {request_id}")
        sys.exit(1)
    # The clock rolls over before the review completes.
    meter_d2 = mod.DailyMeter(state_dir, day_fn=lambda: day_two)
    meter_d2.finish(request_id, "clear", "GLM-5.2 primary", None, 1.25)
    day_one_value = json.loads((state_dir / f"{day_one}.json").read_text(encoding="utf-8"))
    rows = [r for r in day_one_value["requests"] if r["id"] == request_id]
    if len(rows) != 1:
        print(f"origin-day record count wrong: {len(rows)}")
        sys.exit(1)
    row = rows[0]
    if row["status"] != "clear" or row["finished_at"] is None or row["estimated_usd"] != 1.25:
        print(f"origin-day record was not finalized: {row}")
        sys.exit(1)
    if row["submitter"] != "U0NIGHTOWL":
        print(f"origin-day record lost its submitter: {row}")
        sys.exit(1)
    day_two_path = state_dir / f"{day_two}.json"
    if day_two_path.exists():
        day_two_value = json.loads(day_two_path.read_text(encoding="utf-8"))
        if any(r["id"] == request_id or r["submitter"] == "unknown"
               for r in day_two_value["requests"]):
            print("completion leaked into the next day's ledger")
            sys.exit(1)
    for path in state_dir.glob("*.json"):
        if '"submitter": "unknown"' in path.read_text(encoding="utf-8"):
            print(f"an unknown-submitter record appeared in {path}")
            sys.exit(1)
    if meter_d1.submitter_day_count("U0NIGHTOWL") != 1:
        print("origin-day count wrong after rollover finalize")
        sys.exit(1)
    print("rollover-ok")
    sys.exit(0)

if command == "sweep-unit":
    import time as time_module
    state_dir = Path(os.environ["FMT_SWEEP_DIR"])
    events = state_dir / "events"
    meter = state_dir / "meter"
    events.mkdir(parents=True, exist_ok=True)
    meter.mkdir(parents=True, exist_ok=True)
    old_claim = events / "Ev-old.claimed"
    old_reply = events / "Ev-old.reply"
    fresh_claim = events / "Ev-fresh.claimed"
    for path in (old_claim, old_reply, fresh_claim):
        path.write_text("{}\n", encoding="utf-8")
    aged = time_module.time() - 20 * 86400
    os.utime(old_claim, (aged, aged))
    os.utime(old_reply, (aged, aged))
    old_meter = meter / "2020-01-01.json"
    fresh_meter = meter / f"{mod.utc_day()}.json"
    old_meter.write_text("{}\n", encoding="utf-8")
    fresh_meter.write_text("{}\n", encoding="utf-8")
    removed = mod.sweep_state(state_dir)
    removed_names = {Path(p).name for p in removed}
    if removed_names != {"Ev-old.claimed", "Ev-old.reply", "2020-01-01.json"}:
        print(f"sweep removed the wrong set: {sorted(removed_names)}")
        sys.exit(1)
    if not fresh_claim.exists() or not fresh_meter.exists():
        print("sweep removed fresh files")
        sys.exit(1)
    if old_claim.exists() or old_reply.exists() or old_meter.exists():
        print("sweep left aged files behind")
        sys.exit(1)
    print("sweep-ok")
    sys.exit(0)

if command == "postshape-unit":
    captured = []
    client = mod.SlackWebClient(bot_token="xoxb-shape-test", app_token="xapp-shape-test")
    client._call = lambda method, payload, token: captured.append((method, payload)) or {"ok": True}
    mod.register_secret("xoxb-shape-test")
    client.post_message("C0TESTCHAN", "1755640000.000100", "hello xoxb-shape-test world")
    method, payload = captured[0]
    if method != "chat.postMessage":
        print(f"unexpected method: {method}")
        sys.exit(1)
    if payload.get("mrkdwn") is not False:
        print(f"mrkdwn was not disabled: {payload}")
        sys.exit(1)
    if "xoxb-shape-test" in payload.get("text", ""):
        print("post payload leaked a registered secret")
        sys.exit(1)
    print("postshape-ok")
    sys.exit(0)

if command == "concurrency-unit":
    import threading

    config = mod.load_config(Path(os.environ["FM_CROSSCHECK_SLACK_CONFIG"]))
    meter_dir = Path(os.environ["FMT_METER_DIR"])
    meter = mod.DailyMeter(meter_dir)
    results = []
    result_lock = threading.Lock()

    def admit(index):
        result = meter.begin(
            "U0CONCURRENT",
            f"https://github.com/a/b/pull/{index + 1}",
            f"ev-concurrent-{index}",
            request_cap=3,
        )
        with result_lock:
            results.append(result)

    threads = [threading.Thread(target=admit, args=(index,)) for index in range(12)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    admitted = [result for result in results if result[0] is not None]
    refused = [result for result in results if result[1] == "cap"]
    if len(admitted) != 3 or len(refused) != 9:
        print(f"atomic cap failed: admitted={len(admitted)} refused={len(refused)}")
        sys.exit(1)
    service = mod.SocketModeService(config)
    if len(service.workers) != 4:
        print(f"listener worker count is {len(service.workers)}, not 4")
        sys.exit(1)
    saturation = []
    service.web.post_message = (
        lambda channel, thread_ts, text: saturation.append(
            (channel, thread_ts, text)
        )
    )
    for index in range(mod.REVIEW_QUEUE_LIMIT):
        service.queue.put_nowait((f"ev-fill-{index}", {}))
    service._enqueue(
        "ev-overflow",
        {
            "channel": "C0TESTCHAN",
            "ts": "1755640099.000100",
            "user": "U0CONCURRENT",
            "text": "review",
        },
    )
    if len(saturation) != 1 or "review queue is full" not in saturation[0][2]:
        print(f"queue saturation was not visible: {saturation}")
        sys.exit(1)
    print("concurrency-ok")
    sys.exit(0)

print(f"unknown driver command: {command}")
sys.exit(2)
PY

write_event() { # <path> <channel> <user> <ts> <text>
  "$PYTHON" -c 'import json, sys
print(json.dumps({"type": "app_mention", "channel": sys.argv[1],
                  "user": sys.argv[2], "ts": sys.argv[3], "text": sys.argv[4]}))' \
    "$2" "$3" "$4" "$5" > "$1"
}

run_mention() { # <event-id> <config> <event-file> <out-name>
  local out="$OUTDIR/$4.log"
  perl -e 'alarm 120; exec @ARGV' -- \
    env \
      FM_HOME="$HOMEDIR" \
      FM_TEST_SLACK_APP_TOKEN="$APP_TOKEN" \
      FM_TEST_SLACK_BOT_TOKEN="$BOT_TOKEN" \
      FM_TEST_GITHUB_READ_TOKEN="$GH_TOKEN_VALUE" \
      FM_CROSSCHECK_SLACK_CONFIG="$2" \
      FM_CROSSCHECK_SLACK_CROSSCHECK_BIN="$FIXTURE" \
      FM_CROSSCHECK_REVIEWER_CONFIG="${FMT_REVIEWER_CONFIG:-$REVIEWER_CONFIG}" \
      FM_FIXTURE_LOG="$FIXTURE_LOG" \
      FM_FIXTURE_MODE="${FM_FIXTURE_MODE:-clear}" \
      FM_FIXTURE_REVIEWER_JSON="${FM_FIXTURE_REVIEWER_JSON:-}" \
      FM_FIXTURE_USAGE_JSON="${FM_FIXTURE_USAGE_JSON:-}" \
      FM_FIXTURE_FINDINGS_JSON="${FM_FIXTURE_FINDINGS_JSON:-}" \
      FM_FIXTURE_HEAD_SHA="${FMT_HEAD_SHA:-1111111111111111111111111111111111111111}" \
      FMT_BOT_PY="$BOT_PY" \
      FMT_POSTS="$POSTS" \
      FMT_REACTS="$REACTS" \
      FMT_EVENT_ID="$1" \
      FMT_HEAD_SHA="${FMT_HEAD_SHA:-}" \
      FMT_HEAD_AFTER="${FMT_HEAD_AFTER:-}" \
      FMT_FAIL_VERDICT_POST="${FMT_FAIL_VERDICT_POST:-}" \
      "$PYTHON" "$DRIVER" mention "$3" > "$out" 2>&1
  local code=$?
  RUN_MENTION_OUTPUT=$(cat "$out")
  return "$code"
}

fixture_run_count() {
  grep -c . "$FIXTURE_LOG" || true
}

meter_request_count() {
  "$PYTHON" -c 'import json, pathlib, sys
count = 0
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    value = json.loads(path.read_text(encoding="utf-8"))
    count += len(value.get("requests", []))
print(count)' "$HOMEDIR/state/crosscheck-slack/meter"
}

last_post_text() {
  "$PYTHON" -c 'import json, sys
lines = [line for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
print(json.loads(lines[-1])["text"] if lines else "")' "$POSTS"
}

GOOD_PR_TEXT='<@U0BOT> please review https://github.com/Ruby-Labs/goodrepo/pull/12'

# --- units --------------------------------------------------------------------

test_pr_link_extraction() {
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FMT_BOT_PY="$BOT_PY" "$PYTHON" "$DRIVER" extract 2>&1) \
    || fail "extraction unit failed: $output"
  assert_contains "$output" "extract-ok" "extraction did not complete"
  pass "PR links extract from plain, slack-wrapped, duplicate, and garbage text"
}

test_selftest_validates_config_shape() {
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FM_HOME="$HOMEDIR" "$BOT_SH" --selftest "$CONFIG_MAIN" 2>&1) \
    || fail "selftest refused a valid config: $output"
  assert_contains "$output" "schema: valid" "selftest did not report a valid schema"
  assert_contains "$output" "repo_allowlist: ruby-labs/goodrepo" \
    "selftest did not report the repo allowlist"
  assert_contains "$output" "unmetered pass-through" \
    "selftest did not explain the null budget"
  assert_contains "$output" "daily_request_cap: null (uncapped" \
    "selftest did not report the null request cap"
  assert_contains "$output" "authorship ignored" \
    "selftest did not report exact-head-only admission"
  assert_contains "$output" "review_workers: 4" \
    "selftest did not report four shared-capacity workers"

  legacy="$TMP_ROOT/config-legacy-provenance.json"
  "$PYTHON" -c 'import json, sys
value = json.load(open(sys.argv[1]))
value["provenance_key_file"] = "/historical/nonexistent/key"
json.dump(value, open(sys.argv[2], "w"))' "$CONFIG_MAIN" "$legacy"
  output=$(env FM_HOME="$HOMEDIR" "$BOT_SH" --selftest "$legacy" 2>&1) \
    || fail "selftest stopped reading a historical config: $output"
  assert_contains "$output" "schema: valid" \
    "historical provenance config was not accepted and ignored"

  bad="$TMP_ROOT/config-bad.json"
  "$PYTHON" -c 'import json, sys
value = json.load(open(sys.argv[1]))
value["surprise"] = 1
json.dump(value, open(sys.argv[2], "w"))' "$CONFIG_MAIN" "$bad"
  if output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FM_HOME="$HOMEDIR" "$BOT_SH" --selftest "$bad" 2>&1); then
    fail "selftest accepted a config with unexpected keys"
  fi
  assert_contains "$output" "unexpected keys: surprise" \
    "selftest refusal did not name the unexpected key"

  "$PYTHON" -c 'import json, sys
value = json.load(open(sys.argv[1]))
value["daily_budget_usd"] = "twenty"
json.dump(value, open(sys.argv[2], "w"))' "$CONFIG_MAIN" "$bad"
  if output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FM_HOME="$HOMEDIR" "$BOT_SH" --selftest "$bad" 2>&1); then
    fail "selftest accepted a non-numeric daily_budget_usd"
  fi
  assert_contains "$output" "daily_budget_usd" \
    "selftest refusal did not name the budget key"
  pass "selftest validates config shape and refuses malformed configs by name"
}

test_slack_app_manifest_is_minimal_and_socket_only() {
  app_dir="$ROOT/ops/slack-crosscheck"
  output=$("$app_dir/get-manifest.sh" --source="$app_dir" 2>&1) \
    || fail "Slack manifest hook failed: $output"
  APP_MANIFEST_JSON="$output" "$PYTHON" - <<'PYTEST' \
    || fail "Slack app manifest contract failed"
import json
import os

manifest = json.loads(os.environ["APP_MANIFEST_JSON"])
assert manifest["settings"] == {
    "event_subscriptions": {"bot_events": ["app_mention"]},
    "org_deploy_enabled": False,
    "socket_mode_enabled": True,
    "is_hosted": False,
    "token_rotation_enabled": False,
}
assert manifest["oauth_config"]["scopes"]["bot"] == [
    "app_mentions:read",
    "chat:write",
    "reactions:write",
]
assert "request_url" not in json.dumps(manifest).lower()
PYTEST
  pass "Slack app manifest is outbound-only and least-privileged"
}

test_missing_token_env_refuses_start() {
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env -u FM_TEST_SLACK_APP_TOKEN -u FM_TEST_SLACK_BOT_TOKEN -u FM_TEST_GITHUB_READ_TOKEN \
      FM_HOME="$HOMEDIR" "$BOT_SH" run --config "$CONFIG_MAIN" 2>&1)
  code=$?
  [ "$code" -ne 0 ] || fail "listener started without its Slack app token"
  expect_code 3 "$code" "missing app token refusal exit code"
  assert_contains "$output" "FM_TEST_SLACK_APP_TOKEN is not set" \
    "refusal did not name the missing app token variable"

  if output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env -u FM_TEST_SLACK_BOT_TOKEN -u FM_TEST_GITHUB_READ_TOKEN \
      FM_TEST_SLACK_APP_TOKEN="$APP_TOKEN" \
      FM_HOME="$HOMEDIR" "$BOT_SH" run --config "$CONFIG_MAIN" 2>&1); then
    fail "listener started without its Slack bot token"
  fi
  assert_contains "$output" "FM_TEST_SLACK_BOT_TOKEN is not set" \
    "refusal did not name the missing bot token variable"

  if output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env -u FM_TEST_GITHUB_READ_TOKEN \
      FM_TEST_SLACK_APP_TOKEN="$APP_TOKEN" FM_TEST_SLACK_BOT_TOKEN="$BOT_TOKEN" \
      FM_HOME="$HOMEDIR" "$BOT_SH" run --config "$CONFIG_MAIN" 2>&1); then
    fail "listener started without its GitHub read credential"
  fi
  assert_contains "$output" "FM_TEST_GITHUB_READ_TOKEN is not set" \
    "refusal did not name the missing GitHub token variable"
  assert_not_contains "$output" "$APP_TOKEN" "refusal output leaked the app token"
  pass "a missing token environment variable refuses startup naming the exact variable"
}

test_mention_without_link_gets_usage_reply() {
  event="$TMP_ROOT/event-nolink.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640000.000100 '<@U0BOT> hello there'
  run_mention ev-nolink-1 "$CONFIG_MAIN" "$event" nolink \
    || fail "no-link mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: no-link" "expected no-link action"
  assert_contains "$(last_post_text)" "Tag me with one GitHub pull-request link" \
    "usage reply missing"
  pass "a mention without a PR link gets a threaded usage reply"
}

test_multiple_links_are_refused() {
  event="$TMP_ROOT/event-multi.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640001.000100 \
    'both <https://github.com/ruby-labs/goodrepo/pull/1> and <https://github.com/ruby-labs/goodrepo/pull/2>'
  run_mention ev-multi-1 "$CONFIG_MAIN" "$event" multi \
    || fail "multi-link mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: multiple-links" "expected multiple-links action"
  assert_contains "$(last_post_text)" "One pull-request link per request" \
    "multiple-link refusal missing"
  pass "multiple PR links in one mention are refused without starting a review"
}

test_out_of_allowlist_repo_is_refused() {
  before=$(fixture_run_count)
  event="$TMP_ROOT/event-badrepo.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640002.000100 \
    '<@U0BOT> review <https://github.com/evil-org/surprise/pull/13>'
  run_mention ev-badrepo-1 "$CONFIG_MAIN" "$event" badrepo \
    || fail "out-of-allowlist mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: repo-refused" "expected repo-refused action"
  reply=$(last_post_text)
  assert_contains "$reply" "not in the crosscheck repository allowlist" \
    "allowlist refusal text missing"
  assert_contains "$reply" "evil-org/surprise" "refusal did not name the repository"
  assert_contains "$reply" "ruby-labs/goodrepo" "refusal did not name the allowlist"
  after=$(fixture_run_count)
  [ "$after" = "$before" ] || fail "out-of-allowlist PR reached the crosscheck CLI"
  pass "an out-of-allowlist repository is refused in thread and never reaches the credentialed CLI"
}

test_channel_outside_allowlist_is_refused() {
  before=$(fixture_run_count)
  event="$TMP_ROOT/event-badchan.json"
  write_event "$event" C0SOMEWHERE U0ALICE 1755640003.000100 "$GOOD_PR_TEXT"
  run_mention ev-badchan-1 "$CONFIG_MAIN" "$event" badchan \
    || fail "out-of-channel mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: channel-refused" "expected channel-refused action"
  assert_contains "$(last_post_text)" "not enabled for crosscheck reviews" \
    "channel refusal text missing"
  after=$(fixture_run_count)
  [ "$after" = "$before" ] || fail "a non-allowlisted channel reached the crosscheck CLI"
  pass "a mention outside the channel allowlist is refused without a review"
}

test_missing_configured_reviewer_is_refused_before_admission() {
  before_runs=$(fixture_run_count)
  before_requests=$(meter_request_count)
  before_starts=$(grep -c "Review started" "$POSTS" || true)
  before_reacts=$(wc -l < "$REACTS" | tr -d ' ')
  event="$TMP_ROOT/event-no-reviewer.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640003.500100 "$GOOD_PR_TEXT"
  FMT_REVIEWER_CONFIG="$TMP_ROOT/missing-reviewer.json" \
    run_mention ev-no-reviewer-1 "$CONFIG_MAIN" "$event" no-reviewer \
    || fail "missing-reviewer mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: reviewer-refused" \
    "missing reviewer was not refused at Slack admission"
  reply=$(last_post_text)
  assert_contains "$reply" "no configured Crosscheck reviewer is available" \
    "reviewer refusal did not name the unavailable configuration"
  assert_contains "$reply" "No review started" \
    "reviewer refusal did not state that no review started"
  after_runs=$(fixture_run_count)
  after_requests=$(meter_request_count)
  after_starts=$(grep -c "Review started" "$POSTS" || true)
  after_reacts=$(wc -l < "$REACTS" | tr -d ' ')
  [ "$after_runs" = "$before_runs" ] \
    || fail "missing reviewer reached the Crosscheck CLI"
  [ "$after_requests" = "$before_requests" ] \
    || fail "missing reviewer consumed the submitter request meter"
  [ "$after_starts" = "$before_starts" ] \
    || fail "missing reviewer posted a review-start acknowledgement"
  [ "$after_reacts" = "$before_reacts" ] \
    || fail "missing reviewer posted a review-start reaction"
  pass "a missing configured reviewer is refused before metering or review startup"
}

test_completed_review_names_lane_head_task_and_artifact() {
  before=$(fixture_run_count)
  event="$TMP_ROOT/event-clear.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640004.000100 "$GOOD_PR_TEXT"
  FM_FIXTURE_REVIEWER_JSON='{"harness":"pi","model":"accounts/fireworks/models/glm-5p2","effort":"xhigh","account_home":"/tmp/x","review_family_mode":"cross-family-primary"}' \
    run_mention ev-clear-1 "$CONFIG_MAIN" "$event" clear \
    || fail "clear review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "expected completed:clear"
  reply=$(last_post_text)
  assert_contains "$reply" "Crosscheck CLEAR" "verdict reply missing state"
  assert_contains "$reply" "Lane: glm-5p2 primary" \
    "verdict reply did not name the cross-family lane"
  assert_contains "$reply" "Reviewed head: 1111111111111111111111111111111111111111" \
    "verdict reply did not name the exact reviewed head"
  assert_contains "$reply" "Task ID: slack-" \
    "verdict reply did not name the durable task"
  assert_contains "$reply" "crosscheck.md" "verdict reply did not point at the full report"
  assert_contains "$reply" "Durable artifact:" \
    "report path was not labeled as the durable artifact"
  after=$(fixture_run_count)
  [ "$after" = $((before + 1)) ] || fail "expected exactly one crosscheck invocation"
  assert_grep "Review started" "$POSTS" "review start ack missing"
  assert_grep "hourglass" "$REACTS" "ack reaction missing"
  pass "an allowlisted exact head starts review without author metadata or attestation artifacts"
}

test_lane_naming_covers_fallback_and_explicit_marker() {
  event="$TMP_ROOT/event-lane-pi.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640005.000100 "$GOOD_PR_TEXT"
  FM_FIXTURE_REVIEWER_JSON='{"harness":"pi","model":"openai-codex-2/gpt-5.6-sol","effort":"xhigh","account_home":"/tmp/x"}' \
    run_mention ev-lane-pi-1 "$CONFIG_MAIN" "$event" lane-pi \
    || fail "pi-lane review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$(last_post_text)" "Lane: pi-codex fallback (degraded)" \
    "pi reviewer was not named as the degraded fallback"

  event="$TMP_ROOT/event-lane-marker.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640006.000100 "$GOOD_PR_TEXT"
  FM_FIXTURE_REVIEWER_JSON='{"harness":"pi","model":"gpt-5.6-sol","effort":"xhigh","lane":"pi-codex roster","degraded":true}' \
    run_mention ev-lane-marker-1 "$CONFIG_MAIN" "$event" lane-marker \
    || fail "marker-lane review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$(last_post_text)" "Lane: pi-codex roster (degraded)" \
    "explicit ledger lane marker was not passed through"
  pass "lane naming covers the pi-codex fallback and passes an explicit ledger marker through"
}

test_duplicate_event_id_starts_one_review() {
  before=$(fixture_run_count)
  starts_before=$(grep -c "Review started" "$POSTS" || true)
  event="$TMP_ROOT/event-dup.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640007.000100 "$GOOD_PR_TEXT"
  run_mention ev-dup-once "$CONFIG_MAIN" "$event" dup-first \
    || fail "first delivery errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "first delivery did not review"
  run_mention ev-dup-once "$CONFIG_MAIN" "$event" dup-second \
    || fail "second delivery errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: duplicate" "second delivery was not deduped"
  after=$(fixture_run_count)
  [ "$after" = $((before + 1)) ] || fail "duplicate event started a second crosscheck run"
  starts_after=$(grep -c "Review started" "$POSTS" || true)
  [ "$starts_after" = $((starts_before + 1)) ] || fail "duplicate event posted a second start ack"
  pass "the same event id delivered twice starts exactly one review"
}

# FORWARD CONTRACT: observational telemetry does not activate the USD cap.
# This unit injects the legacy `usage` object explicitly to exercise the dormant
# contract, while the next unit proves ordinary telemetry stays informational.
test_usd_meter_forward_contract_with_fixture_injected_usage() {
  before=$(fixture_run_count)
  export FM_FIXTURE_USAGE_JSON='{"total_tokens": 120000, "estimated_usd": 3.5}'
  event="$TMP_ROOT/event-budget.json"

  write_event "$event" C0TESTCHAN U0BUDGET 1755640008.000100 "$GOOD_PR_TEXT"
  run_mention ev-budget-1 "$CONFIG_BUDGET" "$event" budget-1 \
    || fail "first metered review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "first metered review refused"

  write_event "$event" C0TESTCHAN U0BUDGET 1755640009.000100 "$GOOD_PR_TEXT"
  run_mention ev-budget-2 "$CONFIG_BUDGET" "$event" budget-2 \
    || fail "second metered review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "second metered review refused"

  write_event "$event" C0TESTCHAN U0BUDGET 1755640010.000100 "$GOOD_PR_TEXT"
  run_mention ev-budget-3 "$CONFIG_BUDGET" "$event" budget-3 \
    || fail "third metered mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: budget-refused" "budget bound was not enforced"
  reply=$(last_post_text)
  assert_contains "$reply" "Daily crosscheck budget reached" "bound-reached reply missing"
  # The dollars below are literal money, not expansions.
  # shellcheck disable=SC2016
  assert_contains "$reply" '$7.00 of $5.00' "bound-reached reply did not state the totals"

  after=$(fixture_run_count)
  [ "$after" = $((before + 2)) ] || fail "budget-refused request still reached the crosscheck CLI"

  meter_day="$HOMEDIR/state/crosscheck-slack/meter/$(date -u +%Y-%m-%d).json"
  assert_present "$meter_day" "daily meter ledger missing"
  usd_count=$("$PYTHON" -c 'import json, sys
value = json.load(open(sys.argv[1]))
rows = [r for r in value["requests"] if r["submitter"] == "U0BUDGET" and r["estimated_usd"] == 3.5]
tokens = [r for r in rows if isinstance(r.get("tokens"), dict) and r["tokens"].get("total_tokens") == 120000]
lanes = [r for r in rows if r.get("lane")]
print(len(rows), len(tokens), len(lanes))' "$meter_day")
  [ "$usd_count" = "2 2 2" ] || fail "meter ledger rows wrong: $usd_count"

  # A different submitter is not bound by U0BUDGET's spend.
  write_event "$event" C0TESTCHAN U0OTHER 1755640011.000100 "$GOOD_PR_TEXT"
  run_mention ev-budget-other "$CONFIG_BUDGET" "$event" budget-other \
    || fail "other-submitter review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" \
    "budget bound leaked across submitters"
  unset FM_FIXTURE_USAGE_JSON
  pass "per-submitter USD meter accumulates fixture-injected forward-contract cost and the bound is announced in thread"
}

test_production_shaped_ledger_never_trips_usd_bound() {
  # The default fixture carries current economics telemetry but no legacy
  # `usage` field. Under a tiny USD budget, reviews must still run because
  # this upgrade deliberately adds observability without activating a cap.
  trip_before=$(grep -c "Daily crosscheck budget reached" "$POSTS" || true)
  event="$TMP_ROOT/event-prod-shape.json"
  write_event "$event" C0TESTCHAN U0PRODSHAPE 1755640020.000100 "$GOOD_PR_TEXT"
  run_mention ev-prodshape-1 "$CONFIG_TINYBUDGET" "$event" prodshape-1 \
    || fail "first production-shaped review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" \
    "first production-shaped review did not run"
  write_event "$event" C0TESTCHAN U0PRODSHAPE 1755640021.000100 "$GOOD_PR_TEXT"
  run_mention ev-prodshape-2 "$CONFIG_TINYBUDGET" "$event" prodshape-2 \
    || fail "second production-shaped review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" \
    "the USD bound tripped falsely on a production-shaped ledger"
  trip_after=$(grep -c "Daily crosscheck budget reached" "$POSTS" || true)
  [ "$trip_after" = "$trip_before" ] \
    || fail "a budget-reached reply appeared without any recorded cost"
  meter_day="$HOMEDIR/state/crosscheck-slack/meter/$(date -u +%Y-%m-%d).json"
  shape=$("$PYTHON" -c 'import json, sys
value = json.load(open(sys.argv[1]))
rows = [r for r in value["requests"] if r["submitter"] == "U0PRODSHAPE"]
nulls = [r for r in rows if r["estimated_usd"] is None and r["tokens"] is None]
print(len(rows), len(nulls))' "$meter_day")
  [ "$shape" = "2 2" ] || fail "production-shaped meter rows wrong: $shape"
  pass "economics telemetry stays observational and does not activate the Slack USD cap"
}

test_request_cap_binds_today() {
  before=$(fixture_run_count)
  event="$TMP_ROOT/event-cap.json"

  write_event "$event" C0TESTCHAN U0CAPPED 1755640030.000100 "$GOOD_PR_TEXT"
  run_mention ev-cap-1 "$CONFIG_CAP" "$event" cap-1 \
    || fail "first capped review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "first capped review refused"

  write_event "$event" C0TESTCHAN U0CAPPED 1755640031.000100 "$GOOD_PR_TEXT"
  run_mention ev-cap-2 "$CONFIG_CAP" "$event" cap-2 \
    || fail "second capped review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" "second capped review refused"

  write_event "$event" C0TESTCHAN U0CAPPED 1755640032.000100 "$GOOD_PR_TEXT"
  run_mention ev-cap-3 "$CONFIG_CAP" "$event" cap-3 \
    || fail "third capped mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: cap-refused" \
    "the request-count cap was not enforced"
  reply=$(last_post_text)
  assert_contains "$reply" "Daily crosscheck request cap reached" "cap-reached reply missing"
  assert_contains "$reply" "2 of 2" "cap-reached reply did not state the totals"

  after=$(fixture_run_count)
  [ "$after" = $((before + 2)) ] || fail "cap-refused request still reached the crosscheck CLI"

  # A different submitter is not bound by U0CAPPED's count.
  write_event "$event" C0TESTCHAN U0UNCAPPED 1755640033.000100 "$GOOD_PR_TEXT"
  run_mention ev-cap-other "$CONFIG_CAP" "$event" cap-other \
    || fail "other-submitter capped review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:clear" \
    "request cap leaked across submitters"
  pass "the per-submitter daily request cap binds today with no cost data and is announced in thread"
}

test_head_change_invalidates_the_verdict() {
  event="$TMP_ROOT/event-stale.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640042.000100 "$GOOD_PR_TEXT"
  FMT_HEAD_SHA="4444444444444444444444444444444444444444" \
  FMT_HEAD_AFTER="5555555555555555555555555555555555555555" \
    run_mention ev-stale-1 "$CONFIG_MAIN" "$event" stale \
    || fail "head-change mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: failed" \
    "head change did not invalidate the review"
  reply=$(last_post_text)
  assert_contains "$reply" "Crosscheck STALE" "head change was not reported as stale"
  assert_contains "$reply" "Reviewed head: 4444444444444444444444444444444444444444" \
    "stale reply lost the reviewed head"
  assert_contains "$reply" "Current head: 5555555555555555555555555555555555555555" \
    "stale reply lost the new head"
  assert_not_contains "$reply" "Crosscheck CLEAR" \
    "a stale review was translated into CLEAR"
  pass "a PR head change invalidates the earlier verdict visibly"
}

test_day_rollover_finalizes_the_origin_day() {
  rollover_dir="$TMP_ROOT/rollover-meter"
  mkdir -p "$rollover_dir"
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FMT_BOT_PY="$BOT_PY" FMT_METER_DIR="$rollover_dir" \
      "$PYTHON" "$DRIVER" rollover-unit 2>&1) \
    || fail "rollover unit failed: $output"
  assert_contains "$output" "rollover-ok" "rollover unit did not complete"
  pass "a review crossing midnight UTC finalizes the origin day's record with no orphan"
}

test_undelivered_verdict_is_reposted_on_redelivery() {
  before=$(fixture_run_count)
  event="$TMP_ROOT/event-undelivered.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640050.000100 "$GOOD_PR_TEXT"
  FMT_FAIL_VERDICT_POST=1 \
    run_mention ev-undelivered-1 "$CONFIG_MAIN" "$event" undelivered-first \
    || fail "undelivered-first mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: undelivered:completed:clear" \
    "a failed verdict post was not reported as undelivered"
  after=$(fixture_run_count)
  [ "$after" = $((before + 1)) ] || fail "expected exactly one review before redelivery"

  run_mention ev-undelivered-1 "$CONFIG_MAIN" "$event" undelivered-second \
    || fail "redelivery errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: redelivered" \
    "redelivery did not re-post the stored verdict"
  assert_contains "$(last_post_text)" "Crosscheck CLEAR" \
    "the re-posted reply is not the stored verdict"
  final=$(fixture_run_count)
  [ "$final" = $((before + 1)) ] || fail "redelivery ran a second review"

  # A delivered event stays a plain duplicate on further redelivery.
  run_mention ev-undelivered-1 "$CONFIG_MAIN" "$event" undelivered-third \
    || fail "third delivery errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: duplicate" \
    "a delivered event was re-posted again"
  pass "a produced-but-undelivered verdict is re-posted on redelivery without a second review"
}

test_redelivery_revalidates_head() {
  local next_head event before reply
  for next_head in 2222222222222222222222222222222222222222 ERROR; do
    event="$TMP_ROOT/redelivery-$next_head.json"
    write_event "$event" C0TESTCHAN U0ALICE 1755640014.000100 "$GOOD_PR_TEXT"
    before=$(fixture_run_count)
    FMT_FAIL_VERDICT_POST=1 run_mention "ev-retry-$next_head" "$CONFIG_MAIN" "$event" "retry-first-$next_head" \
      || fail "initial review failed: $RUN_MENTION_OUTPUT"
    assert_contains "$RUN_MENTION_OUTPUT" "undelivered:completed:clear" "verdict was not stored"
    FMT_HEAD_SHA="$next_head" run_mention "ev-retry-$next_head" "$CONFIG_MAIN" "$event" "retry-second-$next_head" \
      || fail "redelivery failed: $RUN_MENTION_OUTPUT"
    reply=$(last_post_text)
    assert_not_contains "$reply" "Crosscheck CLEAR" "redelivery emitted an unverified CLEAR"
    if [ "$next_head" = ERROR ]; then
      assert_contains "$reply" "TOOL FAILURE" "lookup failure did not invalidate verdict"
    else
      assert_contains "$reply" "Crosscheck STALE" "changed head did not invalidate verdict"
      assert_contains "$reply" "$next_head" "stale verdict omitted current head"
    fi
    [ "$(fixture_run_count)" = $((before + 1)) ] || fail "redelivery started another review"
  done
  pass "redelivery checks current head and never translates lookup failure to CLEAR"
}

test_retention_sweep_removes_only_aged_state() {
  sweep_dir="$TMP_ROOT/sweep-state"
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FMT_BOT_PY="$BOT_PY" FMT_SWEEP_DIR="$sweep_dir" \
      "$PYTHON" "$DRIVER" sweep-unit 2>&1) \
    || fail "sweep unit failed: $output"
  assert_contains "$output" "sweep-ok" "sweep unit did not complete"
  pass "the retention sweep removes aged claim and meter files and keeps fresh ones"
}

test_posts_disable_mrkdwn() {
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FMT_BOT_PY="$BOT_PY" "$PYTHON" "$DRIVER" postshape-unit 2>&1) \
    || fail "post-shape unit failed: $output"
  assert_contains "$output" "postshape-ok" "post-shape unit did not complete"
  pass "chat.postMessage payloads disable mrkdwn and redact registered secrets"
}

test_four_workers_and_concurrent_cap_are_binding() {
  concurrency_dir="$TMP_ROOT/concurrency-meter"
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FM_HOME="$HOMEDIR" \
      FM_TEST_SLACK_APP_TOKEN="$APP_TOKEN" \
      FM_TEST_SLACK_BOT_TOKEN="$BOT_TOKEN" \
      FM_TEST_GITHUB_READ_TOKEN="$GH_TOKEN_VALUE" \
      FM_CROSSCHECK_SLACK_CONFIG="$CONFIG_MAIN" \
      FMT_BOT_PY="$BOT_PY" FMT_METER_DIR="$concurrency_dir" \
      "$PYTHON" "$DRIVER" concurrency-unit 2>&1) \
    || fail "concurrency unit failed: $output"
  assert_contains "$output" "concurrency-ok" "concurrency unit did not complete"
  pass "four Slack workers expose shared capacity and concurrent requests cannot overrun the engineer cap"
}

test_service_install_contains_no_credentials() {
  output=$("$PYTHON" - "$TMP_ROOT" "$ROOT" "$HOMEDIR" "$CONFIG_MAIN" "$SERVICE_SH" <<'PYTEST'
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root, repo, fm_home, original_config, service = map(Path, sys.argv[1:])
home = root / "service-home"
fixture = root / "service-fixture"
bin_dir = fixture / "bin"
bin_dir.mkdir(parents=True)
home.mkdir()
azure_dir = home / ".fm-azure"
azure_dir.mkdir()
fleet = azure_dir / "fleet.env"
fleet.write_text("""FM_AZURE_TENANT_ID=11111111-1111-1111-1111-111111111111
FM_AZURE_SUBSCRIPTION_ID=22222222-2222-2222-2222-222222222222
FM_AZURE_NAMING_PREFIX=fixture
FM_AZURE_STORAGE_NAME=fixturestorage
FM_AZURE_OWNER_TAG=fixture-owner
FM_AZURE_DEPLOYMENT_GENERATION=fixture-generation
FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID=33333333-3333-3333-3333-333333333333
""")
fleet.chmod(0o600)
config_path = fixture / "config.json"
config = json.loads(original_config.read_text())
config["keychain_services"] = dict(app_token="fixture-app", bot_token="fixture-bot", github_token="fixture-github")
config_path.write_text(json.dumps(config))
ready = fixture / "keychain-ready"
launch_log = fixture / "launch.log"
wrapper = bin_dir / "fm-crosscheck-slack.sh"
wrapper.write_text(f"#!{sys.executable}\n" + f"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
spec = importlib.util.spec_from_file_location('slack_service_fixture', {str(repo / 'bin/fm-crosscheck-slack.py')!r})
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
real_run = subprocess.run
real_is_file = Path.is_file
def is_file(path):
    return True if str(path) == '/usr/bin/security' else real_is_file(path)
def run(command, **kwargs):
    if command[0] == '/usr/bin/security':
        assert not any(os.environ.get(name) for name in {tuple(config[k] for k in ('app_token_env', 'bot_token_env', 'github_token_env'))!r})
        if not Path({str(ready)!r}).exists():
            return subprocess.CompletedProcess(command, 1, b'')
        return subprocess.CompletedProcess(command, 0, b'fixture-keychain-secret')
    return real_run(command, **kwargs)
subprocess.run = run
Path.is_file = is_file
if sys.argv[1] == '--selftest':
    sys.argv[1] = 'selftest'
sys.exit(mod.main())
""")
wrapper.chmod(0o755)
launchctl = bin_dir / "launchctl"
launchctl.write_text(f"#!{sys.executable}\n" + f"""
from pathlib import Path
import sys
with Path({str(launch_log)!r}).open('a') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\\n')
sys.exit(1 if sys.argv[1] == 'print' else 0)
""")
launchctl.chmod(0o755)
# Model the macOS plist editor on every host; the emitted plist is parsed below
# and its actual service command is executed with the emitted environment.
plutil = bin_dir / "plutil"
plutil.write_text(f"#!{sys.executable}\n" + """
import plistlib
from pathlib import Path
import sys
args = sys.argv[1:]
path = Path(args[-1])
if args[0] == '-create':
    value = {}
else:
    value = plistlib.loads(path.read_bytes())
    parts = args[1].split('.')
    parent = value
    for part in parts[:-1]:
        parent = parent[int(part)] if isinstance(parent, list) else parent[part]
    kind = args[2]
    item = {'-array': [], '-dictionary': {}}.get(kind)
    if kind == '-string':
        item = args[3]
    elif kind == '-bool':
        item = args[3] == 'true'
    elif kind == '-integer':
        item = int(args[3])
    if isinstance(parent, list):
        parent.insert(int(parts[-1]), item)
    else:
        parent[parts[-1]] = item
path.write_bytes(plistlib.dumps(value))
""")
plutil.chmod(0o755)
environment = dict(os.environ, HOME=str(home), FM_HOME=str(fm_home), FM_ROOT_OVERRIDE=str(fixture), FM_CROSSCHECK_SLACK_CONFIG=str(config_path), FM_CROSSCHECK_PYTHON=sys.executable, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
for name in ('app_token_env', 'bot_token_env', 'github_token_env'):
    environment[config[name]] = 'fixture-inherited-secret'
plist = home / 'Library/LaunchAgents/com.firstmate.crosscheck-slack.plist'
def invoke(operation):
    result = subprocess.run([str(service), operation], env=environment, capture_output=True, text=True, timeout=60)
    assert 'fixture-inherited-secret' not in result.stdout + result.stderr
    assert 'fixture-keychain-secret' not in result.stdout + result.stderr
    return result
result = invoke('install')
assert result.returncode != 0, 'install accepted shell credentials with unavailable Keychain'
assert not plist.exists()
assert not launch_log.exists()
ready.touch()
result = invoke('install')
assert result.returncode == 0, result.stdout + result.stderr
assert not launch_log.exists(), 'install started listener'
agent = plistlib.loads(plist.read_bytes())
assert set(agent['EnvironmentVariables']) == {'HOME', 'FM_HOME', 'FM_CROSSCHECK_SLACK_CONFIG', 'FM_CROSSCHECK_PYTHON', 'PATH'}
assert '--keychain-only' in agent['ProgramArguments']
assert 'fixture-inherited-secret' not in plist.read_text()
assert 'fixture-keychain-secret' not in plist.read_text()
command = agent['ProgramArguments']
result = subprocess.run([command[0], 'preflight', *command[2:]], env=agent['EnvironmentVariables'], capture_output=True, text=True, timeout=30)
assert result.returncode == 0, result.stdout + result.stderr
assert 'Azure fleet are ready' in result.stdout
fleet_off = fleet.with_suffix('.env.off')
fleet.rename(fleet_off)
result = invoke('start')
assert result.returncode != 0, 'start accepted a missing central Azure fleet environment'
assert not launch_log.exists(), 'missing Azure fleet validation mutated service state'
fleet_off.rename(fleet)
result = invoke('start')
assert result.returncode == 0, result.stdout + result.stderr
assert 'bootstrap' in launch_log.read_text()
launch_log.unlink()
ready.unlink()
result = invoke('start')
assert result.returncode != 0, 'start accepted unavailable Keychain'
assert not launch_log.exists(), 'failed validation mutated service state'
previous = plist.read_bytes()
result = invoke('install')
assert result.returncode != 0
assert plist.read_bytes() == previous, 'failed reinstall replaced plist'
ready.touch()
del config['keychain_services']
config_path.write_text(json.dumps(config))
result = invoke('install')
assert result.returncode != 0, 'service accepted environment-only configuration'
assert plist.read_bytes() == previous
PYTEST
  ) || fail "launch-agent credential contract failed: $output"
  pass "service validates emitted environment and refuses unavailable Keychain without mutating launch state"
}

test_tool_failure_is_reported_honestly() {
  event="$TMP_ROOT/event-fail.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640012.000100 "$GOOD_PR_TEXT"
  FM_FIXTURE_MODE=fail run_mention ev-fail-1 "$CONFIG_MAIN" "$event" toolfail \
    || fail "tool-failure mention errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: failed" "expected failed action"
  reply=$(last_post_text)
  assert_contains "$reply" "TOOL FAILURE" "failure reply missing"
  assert_contains "$reply" "not a review outcome" "failure reply must not read as a verdict"
  meter_day="$HOMEDIR/state/crosscheck-slack/meter/$(date -u +%Y-%m-%d).json"
  assert_grep '"status": "tool-failure"' "$meter_day" "tool failure was not ledgered"
  pass "a crosscheck tool failure posts an honest threaded failure and is ledgered"
}

test_blocking_verdict_reply_names_state_and_findings() {
  event="$TMP_ROOT/event-blocking.json"
  write_event "$event" C0TESTCHAN U0ALICE 1755640013.000100 "$GOOD_PR_TEXT"
  FM_FIXTURE_MODE=blocking \
  FM_FIXTURE_FINDINGS_JSON='[{"id":"cc-abcdefabcdef","lifecycle":"open","severity":"blocking","title":"fixture finding title"}]' \
    run_mention ev-blocking-1 "$CONFIG_MAIN" "$event" blocking \
    || fail "blocking review errored: $RUN_MENTION_OUTPUT"
  assert_contains "$RUN_MENTION_OUTPUT" "action: completed:blocking" "expected completed:blocking"
  reply=$(last_post_text)
  assert_contains "$reply" "Crosscheck BLOCKING" "blocking reply missing state"
  assert_contains "$reply" "fixture finding title" "blocking reply missing the finding"
  pass "a blocking verdict posts the state and the active findings"
}

test_tokens_never_reach_logs_or_ledgers() {
  output=$(perl -e 'alarm 60; exec @ARGV' -- \
    env FMT_BOT_PY="$BOT_PY" "$PYTHON" "$DRIVER" redact-unit 2>&1) \
    || fail "redact unit failed: $output"
  assert_contains "$output" "redact-ok" "redactor unit did not complete"
  for secret in "$APP_TOKEN" "$BOT_TOKEN" "$GH_TOKEN_VALUE"; do
    if grep -R -F -- "$secret" "$HOMEDIR" "$POSTS" "$REACTS" "$OUTDIR" "$FIXTURE_LOG" >/dev/null 2>&1; then
      fail "a token value leaked into an artifact (grep hit for a secret)"
    fi
  done
  pass "no token value appears in any state, ledger, post, reaction, or log artifact"
}

# --- registration ----------------------------------------------------------------

UNITS=(
  test_pr_link_extraction
  test_selftest_validates_config_shape
  test_slack_app_manifest_is_minimal_and_socket_only
  test_missing_token_env_refuses_start
  test_mention_without_link_gets_usage_reply
  test_multiple_links_are_refused
  test_out_of_allowlist_repo_is_refused
  test_channel_outside_allowlist_is_refused
  test_missing_configured_reviewer_is_refused_before_admission
  test_completed_review_names_lane_head_task_and_artifact
  test_lane_naming_covers_fallback_and_explicit_marker
  test_duplicate_event_id_starts_one_review
  test_usd_meter_forward_contract_with_fixture_injected_usage
  test_production_shaped_ledger_never_trips_usd_bound
  test_request_cap_binds_today
  test_head_change_invalidates_the_verdict
  test_day_rollover_finalizes_the_origin_day
  test_undelivered_verdict_is_reposted_on_redelivery
  test_redelivery_revalidates_head
  test_retention_sweep_removes_only_aged_state
  test_posts_disable_mrkdwn
  test_four_workers_and_concurrent_cap_are_binding
  test_service_install_contains_no_credentials
  test_tool_failure_is_reported_honestly
  test_blocking_verdict_reply_names_state_and_findings
  test_tokens_never_reach_logs_or_ledgers
)

case "${FM_SLACK_TEST_GROUP:-all}" in
  service-repair) UNITS=(test_service_install_contains_no_credentials) ;;
  repair) UNITS=(test_completed_review_names_lane_head_task_and_artifact test_redelivery_revalidates_head test_service_install_contains_no_credentials) ;;
  compatibility) UNITS=(test_missing_configured_reviewer_is_refused_before_admission test_completed_review_names_lane_head_task_and_artifact test_undelivered_verdict_is_reposted_on_redelivery test_head_change_invalidates_the_verdict test_four_workers_and_concurrent_cap_are_binding) ;;
  all) ;;
  *) fail "unknown Slack test group" ;;
esac

for unit in "${UNITS[@]}"; do
  declare -F "$unit" >/dev/null || fail "registered unit is not a defined function: $unit"
  "$unit"
done
printf 'executed %d units\n' "${#UNITS[@]}"
