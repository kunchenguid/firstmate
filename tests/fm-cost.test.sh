#!/usr/bin/env bash
# Behavior tests for landed-work cost accounting (bin/fm-cost-lib.sh,
# bin/fm-cost.sh).
#
# Everything here drives the public interface - the library's functions and the
# operator entrypoint - against fabricated worker-runtime records in a private
# fixture home. The three cases that matter for spend visibility are what the
# suite pins: an honest "unavailable" with a reason instead of an invented
# number, an "estimated" amount only from operator-supplied prices, and a
# landing that cannot be counted twice however often accounting is retried.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cost)

PRICES='{"version":1,"currency":"USD","per":"million_tokens","models":{
  "claude-opus-5":{"input":5,"output":25,"cache_read":0.5,"cache_write":6.25},
  "gpt-5.6-sol":{"input":1.25,"output":10,"cache_read":0.125}}}'

# make_home <name>: a private home with state, config, and a task worktree.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/wt" "$home/proj-alpha"
  printf '%s\n' "$home"
}

# write_meta <home> <task-id> <harness> [spawn-epoch]
# The default incarnation start is an hour ago, so a fixture transcript stamped
# moments ago falls inside the attribution window.
write_meta() {
  local home=$1 id=$2 harness=$3 epoch=${4:-$(( $(date +%s) - 3600 ))}
  cat > "$home/state/$id.meta" <<META
harness=$harness
worktree=$home/wt
project=$home/proj-alpha
spawn_gen=s$epoch.1.2
META
}

# claude_slug <path>: the project directory Claude Code names after a worker cwd.
claude_slug() {
  python3 -c "import re,sys; print(re.sub(r'[^A-Za-z0-9]','-',sys.argv[1]))" "$1"
}

# write_claude_transcript <home> <age-seconds> <recorded-usd-or-empty> <model>
# One assistant entry with fixed token buckets, stamped <age-seconds> ago.
write_claude_transcript() {
  local home=$1 age=$2 usd=$3 model=$4 dir
  dir="$home/claude/projects/$(claude_slug "$home/wt")"
  mkdir -p "$dir"
  python3 - "$dir/session.jsonl" "$home/wt" "$age" "$usd" "$model" <<'PY'
import datetime
import json
import sys

out, worktree, age, usd, model = sys.argv[1:6]
stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
    seconds=int(age)
)
entry = {
    "type": "assistant",
    "uuid": "entry-%s" % age,
    "cwd": worktree,
    "timestamp": stamp.isoformat().replace("+00:00", "Z"),
    "message": {
        "model": model,
        "usage": {
            "input_tokens": 1000,
            "output_tokens": 2000,
            "cache_read_input_tokens": 4000,
            "cache_creation_input_tokens": 8000,
        },
    },
}
if usd:
    entry["costUSD"] = float(usd)
with open(out, "a") as handle:
    handle.write(json.dumps(entry) + "\n")
PY
}

# write_codex_rollout <home> <model>
write_codex_rollout() {
  local home=$1 model=$2 dir
  dir="$home/codex/sessions/2026/09/21"
  mkdir -p "$dir"
  python3 - "$dir/rollout-fixture.jsonl" "$home/wt" "$model" <<'PY'
import json
import sys

out, worktree, model = sys.argv[1:4]
lines = [
    {"type": "session_meta", "payload": {"cwd": worktree, "model_provider": "openai"}},
    {"type": "response_item", "payload": {"type": "turn_context", "model": model}},
    {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 500,
                    "cached_input_tokens": 200,
                    "cache_write_input_tokens": 0,
                    "output_tokens": 100,
                }
            },
        },
    },
    {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 3000,
                    "cached_input_tokens": 1000,
                    "cache_write_input_tokens": 0,
                    "output_tokens": 400,
                }
            },
        },
    },
]
with open(out, "w") as handle:
    for line in lines:
        handle.write(json.dumps(line) + "\n")
PY
}

# cost_lib <home> <script>: run a library snippet with the fixture's runtime
# record roots in place of the operator's real ones.
cost_lib() {
  local home=$1 script=$2
  CLAUDE_CONFIG_DIR="$home/claude" CODEX_HOME="$home/codex" \
    bash -c '. "$1"; '"$script" _ "$ROOT/bin/fm-cost-lib.sh" "$home"
}

# --- an absent price table reports unavailable, with tokens and a reason -----

home=$(make_home no-prices)
write_meta "$home" t1 claude
write_claude_transcript "$home" 5 '' claude-opus-5
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t1
  printf "%s|%s|%s|%s\n" "$FM_COST_STATUS" "$FM_COST_USD" \
    "$FM_COST_TOKENS_TOTAL" "$FM_COST_REASON"')
assert_contains "$out" 'unavailable||15000|' \
  'an absent price table must report unavailable with the recorded tokens'
assert_contains "$out" 'model-prices.json is absent' \
  'an unavailable amount must say why it is unavailable'
pass 'no price table reports unavailable USD and still reports recorded tokens'

# --- operator prices produce an estimated amount -----------------------------

printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t1
  printf "%s|%s\n" "$FM_COST_STATUS" "$FM_COST_USD"')
# 1000 input, 2000 output, 4000 cache read, 8000 cache write at the prices above.
assert_equals 'estimated|0.1070' "$out" \
  'operator prices must yield an estimated amount over the recorded buckets'
pass 'operator-supplied prices yield an estimated USD amount'

# --- a priced table with no entry for the used model stays unavailable -------

write_meta "$home" t2 claude
dir="$home/claude/projects/$(claude_slug "$home/wt")"
: > "$dir/session.jsonl"
write_claude_transcript "$home" 5 '' claude-unpriced-9
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t2
  printf "%s|%s|%s\n" "$FM_COST_STATUS" "$FM_COST_USD" "$FM_COST_REASON"')
assert_contains "$out" 'unavailable||no operator price for model claude-unpriced-9' \
  'an unpriced model must not be priced from another model or a default'
pass 'a model with no operator price reports unavailable, naming the model'

# --- a runtime that records USD itself is measured, not estimated ------------

home=$(make_home measured)
printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
write_meta "$home" t1 claude
write_claude_transcript "$home" 5 0.5 claude-opus-5
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t1
  printf "%s|%s\n" "$FM_COST_STATUS" "$FM_COST_USD"')
assert_equals 'measured|0.5000' "$out" \
  "a runtime's own recorded USD amount must be reported as measured"
pass "a runtime that records USD is reported as measured, not estimated"

# --- usage from before this incarnation is not attributed to this task -------

home=$(make_home pooled)
printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
write_meta "$home" t1 claude "$(( $(date +%s) - 600 ))"
write_claude_transcript "$home" 5000 '' claude-opus-5
write_claude_transcript "$home" 30 '' claude-opus-5
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t1
  printf "%s\n" "$FM_COST_TOKENS_TOTAL"')
assert_equals '15000' "$out" \
  'a pooled local copy must not carry an earlier task usage into this one'
pass 'usage recorded before this worker started is not counted'

# --- an unsupported runtime says so instead of guessing ----------------------

write_meta "$home" t3 grok
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t3
  printf "%s|%s\n" "$FM_COST_STATUS" "$FM_COST_REASON"')
assert_contains "$out" 'unavailable|grok keeps no durable usage record' \
  'a runtime with no readable usage record must report unavailable, naming itself'
pass 'a runtime with no readable usage record reports unavailable'

# --- the codex rollout record is read from its cumulative token usage --------

home=$(make_home codex)
printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
write_meta "$home" t1 codex
write_codex_rollout "$home" gpt-5.6-sol
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" '
  fm_cost_usage "$2" "$2/state" t1
  printf "%s|%s|%s\n" "$FM_COST_STATUS" "$FM_COST_TOKENS_TOTAL" "$FM_COST_USD"')
# The last cumulative record only: 2000 uncached input, 1000 cache read, 400 output.
assert_equals 'estimated|3400|0.0066' "$out" \
  'a codex session must be counted once from its latest cumulative usage'
pass 'a codex rollout record is counted once from its latest cumulative usage'

# --- a landing is recorded exactly once, however often accounting retries ----

home=$(make_home idempotent)
printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
write_meta "$home" t1 claude
write_claude_transcript "$home" 5 '' claude-opus-5
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
first=$(cost_lib "$home" '
  fm_cost_landing_report "$2" "$2/state" t1 local deadbee')
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
second=$(cost_lib "$home" '
  fm_cost_landing_report "$2" "$2/state" t1 local deadbee
  printf "already=%s\n" "$FM_COST_ALREADY_RECORDED"')
ledger="$home/data/cost/ledger.jsonl"
assert_equals '1' "$(wc -l < "$ledger" | tr -d '[:space:]')" \
  'a retried landing report must not append a second ledger entry'
assert_contains "$second" 'already=true' \
  'a retried landing report must say the landing was already recorded'
assert_contains "$first" 'cost: task t1 estimated USD 0.1070' \
  'the landing report must state the task cost and its state'
assert_contains "$first" 'cost: project proj-alpha USD 0.1070' \
  'the landing report must state the project total so far'
pass 'one landed task is accounted exactly once across retries'

# --- a second landing of the same task is its own entry ----------------------

# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
cost_lib "$home" 'fm_cost_landing_report "$2" "$2/state" t1 local cafe123' >/dev/null
assert_equals '2' "$(wc -l < "$ledger" | tr -d '[:space:]')" \
  'a distinct landing reference must be recorded as its own entry'
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" 'fm_cost_projects "$2"')
assert_contains "$out" 'proj-alpha' 'the project view must list the project'
assert_contains "$out" '0.2140' 'the project view must total every recorded landing'
pass 'a distinct landing is its own entry and totals into the project view'

# --- an unreadable ledger must never read as "not yet recorded" --------------

printf '%s\n' 'not json' >> "$ledger"
status=0
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
cost_lib "$home" 'fm_cost_record "$2" "$2/state" t1 local newref' >/dev/null 2>&1 \
  || status=$?
expect_code 1 "$status" 'a corrupt ledger must refuse to record rather than double count'
pass 'a ledger that cannot be read refuses to record instead of double counting'

# --- the operator entrypoint exposes the same records ------------------------

home=$(make_home operator)
printf '%s\n' "$PRICES" > "$home/config/model-prices.json"
write_meta "$home" t1 claude
write_claude_transcript "$home" 5 '' claude-opus-5
out=$(CLAUDE_CONFIG_DIR="$home/claude" CODEX_HOME="$home/codex" FM_HOME="$home" \
  "$ROOT/bin/fm-cost.sh" show t1)
assert_contains "$out" 'cost: task t1 estimated USD 0.1070' \
  'show must report the task cost'
assert_absent "$home/data/cost/ledger.jsonl" 'show must record nothing'
out=$(CLAUDE_CONFIG_DIR="$home/claude" CODEX_HOME="$home/codex" FM_HOME="$home" \
  "$ROOT/bin/fm-cost.sh" record t1 pr https://example.test/pr/1)
assert_contains "$out" 'cost: task t1 estimated USD 0.1070' \
  'record must report what it recorded'
out=$(CLAUDE_CONFIG_DIR="$home/claude" CODEX_HOME="$home/codex" FM_HOME="$home" \
  "$ROOT/bin/fm-cost.sh" record t1 pr https://example.test/pr/1)
assert_contains "$out" 'already recorded' \
  'a repeated record must report the landing as already recorded'
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$TMP_ROOT/gone" "$ROOT/bin/fm-cost.sh" show t1)
assert_contains "$out" 'recorded for pr landing https://example.test/pr/1' \
  'show must answer from the recorded ledger once the task records are gone'
out=$(FM_HOME="$home" "$ROOT/bin/fm-cost.sh" projects)
assert_contains "$out" 'proj-alpha' 'projects must list the recorded project'
status=0
FM_HOME="$home" "$ROOT/bin/fm-cost.sh" record t1 sideways ref >/dev/null 2>&1 \
  || status=$?
expect_code 2 "$status" 'an unknown landing kind must be refused'
pass 'the operator entrypoint shows, records idempotently, and totals projects'

# --- an unaccounted landing says so instead of printing a number ------------

home=$(make_home unaccounted)
write_meta "$home" t1 claude
# shellcheck disable=SC2016 # The literal snippet expands in its child Bash process.
out=$(cost_lib "$home" 'fm_cost_landing_lines "$2" t1 pr https://example.test/pr/9')
assert_contains "$out" 'cost: task t1 unrecorded' \
  'a landing with no ledger entry must report itself unrecorded'
pass 'a landing with no recorded cost reports unrecorded rather than a number'
