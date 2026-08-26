#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v2",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "provenance": {
    "fleet_read_at": "2026-08-19T00:00:00Z",
    "usage_read_at": "2026-08-19T00:00:03Z"
  },
  "usage": {
    "available": true,
    "read_at": "2026-08-19T00:00:03Z",
    "source": "quota-axi",
    "providers": [
      {
        "provider": "claude",
        "plan": "pro",
        "percent_remaining": 42,
        "reset_at": "2026-08-23T02:00:00Z",
        "pace": "burning 1.6x pace",
        "runway": "tight",
        "model_note": "Fable window 67% left",
        "attention": []
      }
    ],
    "attention": []
  },
  "supervisor": {
    "identity": "firstmate",
    "crew_count": 1,
    "model": "gpt-5.6-sol",
    "effort": "high",
    "startup_memory": {
      "used_tokens": 3344,
      "budget_tokens": 7500,
      "status": "within budget"
    }
  },
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [
    {
      "id": "sample-task",
      "repo": "sample",
      "kind": "ship",
      "owner": "crewmate",
      "state": "working",
      "state_detail": "working",
      "doing": "Build sample change",
      "next": "Complete validation and report result",
      "harness": "claude",
      "model": "claude-fable-5-thinking-high",
      "effort": "default",
      "worktree_tail": "sample-worktree",
      "latest": "Validation started",
      "blockers": ["Waiting on fixture"],
      "pr_url": "https://github.com/example/sample/pull/2",
      "report_path": "/tmp/sample/report.md"
    }
  ],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v1"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v2" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_v2_refuses_invalid_usage_and_underway_rows() {
  local home data rc out
  home=$(make_home v2-refusal)
  data="$home/payload.json"

  write_valid_payload "$data"
  jq 'del(.usage)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "payload without usage was accepted"

  write_valid_payload "$data"
  jq '.usage.available = true | del(.usage.providers)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "available usage without providers was accepted"

  write_valid_payload "$data"
  jq '.usage.providers[0].percent_remaining = "42"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "non-numeric provider headroom was accepted"

  write_valid_payload "$data"
  jq 'del(.underway[0].owner)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "Underway row without owner was accepted"

  write_valid_payload "$data"
  jq 'del(.underway[0].next)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "Underway row without next action was accepted"

  write_valid_payload "$data"
  jq '.underway[0].pr_url = "http://example.com/pull/2"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "non-HTTPS Underway PR URL was accepted"

  write_valid_payload "$data"
  jq '.underway[0].report_path = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a javascript Underway report path was accepted"

  write_valid_payload "$data"
  jq '.underway[0].report_path = "//external-host/report.md"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a protocol-relative Underway report path was accepted"

  write_valid_payload "$data"
  latest=$(printf '%241s' '' | tr ' ' x)
  jq --arg latest "$latest" '.underway[0].latest = $latest' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlong Underway latest status was accepted"
  pass "v2 refuses invalid usage and Underway rows"
}

test_v2_accepts_unavailable_unknown_and_optional_absence() {
  local home data out
  home=$(make_home v2-accept)
  data="$home/payload.json"

  write_valid_payload "$data"
  jq '.usage = {available:false,reason:"quota-axi unavailable: command failed",read_at:"2026-08-19T00:00:03Z",source:"quota-axi",attention:[{text:"Sign in to quota-axi."}]} | .underway[0] |= del(.harness,.model,.effort,.worktree_tail,.latest,.blockers,.pr_url,.report_path)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "unavailable usage and absent optional task fields were rejected: $out"
  assert_present "$home/.lavish/bearings-board.html" "accepted v2 payload did not build a board"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    (.usage.available == false)
      and (.underway[0] | (has("harness") | not) and (has("model") | not) and (has("effort") | not))
  ' >/dev/null || fail "accepted optional absence did not round-trip through the board"

  write_valid_payload "$data"
  jq '.usage.providers[0].percent_remaining = null | .usage.providers[0].runway = "unknown"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "unknown provider headroom was rejected: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '.usage.providers[0].percent_remaining == null and .usage.providers[0].runway == "unknown"' >/dev/null \
    || fail "unknown provider headroom did not round-trip through the board"
  pass "v2 accepts unavailable usage, unknown headroom, and absent optional task fields"
}

test_invalid_v2_payload_does_not_replace_existing_board() {
  local home data board before after rc
  home=$(make_home v2-preserve)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not create baseline board"
  before=$(cksum "$board")
  jq '.underway[0].next = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; run_board "$home" build "$data" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "invalid v2 payload replaced existing board"
  after=$(cksum "$board")
  [ "$before" = "$after" ] || fail "invalid v2 payload changed existing board"
  pass "invalid v2 payload is refused before replacing an existing board"
}

test_v2_renders_in_browser() {
  local home data board session opened state
  command -v chrome-devtools-axi >/dev/null 2>&1 || { echo "skip - chrome-devtools-axi not installed"; return 0; }
  home=$(make_home browser)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.usage.providers[0].runway = "exhausted"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not build browser fixture"
  session="fleet-board-v2-$$"
  opened=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi open "file://$board" 2>&1) \
    || fail "browser could not open built board: $opened"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval 'JSON.stringify({providers:document.querySelectorAll("#bb-provisions .bb-provision").length, exhausted:document.querySelector("#bb-provisions").textContent.includes("exhausted"), custody:document.querySelector("#bb-underway").textContent.includes("firstmate supervises"), context:document.querySelector("#bb-underway").textContent.includes("model window: not measured"), expanded:document.querySelector("#bb-underway .bb-underway-detail").hidden})' 2>&1 \
    | sed -n 's/^result: //p' | jq -r . | jq -r .) \
    || fail "browser could not inspect built board: $state"
  assert_contains "$state" '"providers":1' "browser did not render provider row: $state"
  assert_contains "$state" '"exhausted":true' "browser did not render exhausted badge: $state"
  assert_contains "$state" '"custody":true' "browser did not render custody detail: $state"
  assert_contains "$state" '"context":true' "browser did not render honest context status: $state"
  assert_contains "$state" '"expanded":true' "browser detail was not collapsed initially: $state"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval '(()=>{document.querySelector("#bb-underway button").click(); return JSON.stringify({expanded:document.querySelector("#bb-underway .bb-underway-detail").hidden,aria:document.querySelector("#bb-underway button").getAttribute("aria-expanded")})})()' 2>&1 \
    | sed -n 's/^result: //p' | jq -r . | jq -r .) \
    || fail "browser could not expand Underway detail"
  assert_contains "$state" '"expanded":false' "browser detail did not expand: $state"
  assert_contains "$state" '"aria":"true"' "expanded detail did not expose aria-expanded: $state"

  jq '.usage = {available:false,reason:"quota-axi unavailable: command failed",read_at:"2026-08-19T00:00:03Z",source:"quota-axi",attention:[{text:"Sign in to quota-axi."}]}' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not build unavailable usage fixture"
  CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi open "file://$board" >/dev/null 2>&1 || fail "browser could not reload unavailable usage fixture"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval 'JSON.stringify({reason:document.querySelector("#bb-provisions").textContent.includes("usage unavailable: quota-axi unavailable"),attention:document.querySelector("#bb-provisions").textContent.includes("Sign in to quota-axi.")})' 2>&1 | sed -n 's/^result: //p' | jq -r . | jq -r .)
  assert_contains "$state" '"reason":true' "browser did not render explicit unavailable usage: $state"
  assert_contains "$state" '"attention":true' "browser dropped usage attention while unavailable: $state"

  write_valid_payload "$data"
  jq '.usage.providers = [] | .usage.attention = [{text:"Reconnect quota source."}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not build zero-provider fixture"
  CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi open "file://$board" >/dev/null 2>&1 || fail "browser could not reload zero-provider fixture"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval 'JSON.stringify({empty:document.querySelector("#bb-provisions").textContent.includes("No providers reported."),attention:document.querySelector("#bb-provisions").textContent.includes("Reconnect quota source.")})' 2>&1 | sed -n 's/^result: //p' | jq -r . | jq -r .)
  assert_contains "$state" '"empty":true' "browser did not render zero-provider empty state: $state"
  assert_contains "$state" '"attention":true' "browser dropped usage attention with zero providers: $state"

  write_valid_payload "$data"
  jq 'del(.underway[0].model,.underway[0].effort)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not build empty model-effort fixture"
  CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi open "file://$board" >/dev/null 2>&1 || fail "browser could not reload empty model-effort fixture"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval 'JSON.stringify({defaults:document.querySelector("#bb-underway").textContent.includes("default"),report_links:document.querySelectorAll("#bb-underway .bb-underway-detail__links a").length})' 2>&1 | sed -n 's/^result: //p' | jq -r . | jq -r .)
  assert_contains "$state" '"defaults":false' "browser invented model or effort defaults: $state"
  assert_contains "$state" '"report_links":2' "browser did not render report_path as a link: $state"

  write_valid_payload "$data"
  jq '.underway += [
    {"id":"a/b","repo":"sample","kind":"ship","owner":"crewmate","state":"working","state_detail":"working","doing":"Slash task","next":"Review slash task"},
    {"id":"a:b","repo":"sample","kind":"ship","owner":"scout","state":"working","state_detail":"working","doing":"Colon task","next":"Review colon task"}
  ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not build colliding task-id fixture"
  CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi open "file://$board" >/dev/null 2>&1 || fail "browser could not reload colliding task-id fixture"
  state=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi eval '(()=>{const b=[...document.querySelectorAll("#bb-underway .bb-underway-row__button")],d=[...document.querySelectorAll("#bb-underway .bb-underway-detail")],ids=d.map(x=>x.id),controls=b.map(x=>x.getAttribute("aria-controls")); return JSON.stringify({unique:new Set(ids).size===ids.length,paired:controls.every((id,i)=>id===ids[i])})})()' 2>&1 | sed -n 's/^result: //p' | jq -r . | jq -r .)
  assert_contains "$state" '"unique":true' "browser emitted duplicate Underway detail IDs: $state"
  assert_contains "$state" '"paired":true' "browser emitted ambiguous Underway aria-controls: $state"
  pass "v2 renders usage and accessible Underway detail in browser"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: the payload extracted from the built page is byte-for-byte the
  # same JSON document, and the escaped </script> string can no longer
  # terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != poll ]; then
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_v2_refuses_invalid_usage_and_underway_rows
test_v2_accepts_unavailable_unknown_and_optional_absence
test_invalid_v2_payload_does_not_replace_existing_board
if [ "${FM_BROWSER_TEST:-0}" = 1 ]; then test_v2_renders_in_browser; fi
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
