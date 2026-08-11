#!/usr/bin/env bash
# Behavior tests for the mission control board renderer.
#
# The board is rendered end to end from a real fixture home for the main path,
# and from captured snapshot payloads (the public --snapshot flag) for the
# cross-home and hostile-input cases that a local fixture cannot produce.
#
# Every case that renders a time pins TZ and FM_MISSION_CONTROL_NOW_EPOCH, and
# commits its fixture clones at explicit epochs, so the relative wording the
# board prints is a property of the board rather than of the day it runs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-mission-control.sh"
ACTION="$ROOT/bin/fm-autonomous-action.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-control)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

find_chrome() { fm_find_chrome; }

assert_narrow_board_geometry() {  # <html> <window-label> <provider-label>
  local html=$1 window_label=$2 provider_label=$3 chrome
  command -v node >/dev/null 2>&1 || {
    printf 'skip: node not found for rendered narrow-board geometry assertion\n'
    return 0
  }
  chrome=$(find_chrome) || {
    printf 'skip: Chrome or Chromium not found for rendered narrow-board geometry assertion\n'
    return 0
  }

  node - "$chrome" "$html" "$window_label" "$provider_label" <<'JS'
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const [chromePath, htmlPath, windowLabel, providerLabel] = process.argv.slice(2);
const chrome = spawn(chromePath, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  "--remote-debugging-pipe",
  `--user-data-dir=${htmlPath}.chrome-profile`,
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
let buffer = "";
let nextId = 0;
let finished = false;
const pending = new Map();

function finish(code, message) {
  if (finished) return;
  finished = true;
  if (message) process.stderr.write(`${message}\n`);
  chrome.kill();
  process.exitCode = code;
}

chrome.on("error", (error) => finish(1, error.message));
chrome.stdio[3].on("error", (error) => finish(1, error.message));
chrome.stdio[4].on("error", (error) => finish(1, error.message));
chrome.stdio[4].on("data", (chunk) => {
  buffer += chunk;
  let boundary;
  while ((boundary = buffer.indexOf("\0")) >= 0) {
    const raw = buffer.slice(0, boundary);
    buffer = buffer.slice(boundary + 1);
    if (!raw) continue;
    const message = JSON.parse(raw);
    const resolve = pending.get(message.id);
    if (resolve) {
      pending.delete(message.id);
      resolve(message);
    }
  }
});

function send(method, params = {}, sessionId) {
  return new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    chrome.stdio[3].write(`${JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })}\0`);
  });
}

async function run() {
  const created = await send("Target.createTarget", { url: "about:blank" });
  const attached = await send("Target.attachToTarget", {
    targetId: created.result.targetId,
    flatten: true,
  });
  const sessionId = attached.result.sessionId;
  await send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  }, sessionId);
  const boardUrl = pathToFileURL(htmlPath);
  boardUrl.hash = "tab=system";
  await send("Page.navigate", { url: boardUrl.href }, sessionId);

  for (let attempt = 0; attempt < 100; attempt += 1) {
    const ready = await send("Runtime.evaluate", {
      expression: "document.readyState",
      returnByValue: true,
    }, sessionId);
    if (ready.result.result.value === "complete") break;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }

  const expression = `(() => {
    const expected = ${JSON.stringify([windowLabel, providerLabel])};
    const viewportWidth = document.documentElement.clientWidth;
    const leaves = [...document.body.querySelectorAll("*")].filter((element) => element.children.length === 0);
    const targets = expected.map((text) => leaves.find((element) => element.textContent.trim() === text));
    return {
      viewportWidth,
      documentWidth: document.documentElement.scrollWidth,
      targets: targets.map((element) => {
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return {
          left: rect.left,
          right: rect.right,
          width: rect.width,
          height: rect.height,
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        };
      }),
    };
  })()`;
  const evaluated = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
  }, sessionId);
  const geometry = evaluated.result.result.value;
  const documentFits = geometry.documentWidth <= geometry.viewportWidth;
  const labelsFit = geometry.targets.every((target) => target &&
    target.width > 0 && target.height > 0 &&
    target.left >= 0 && target.right <= geometry.viewportWidth + 0.5 &&
    target.scrollWidth <= target.clientWidth + 1);
  if (!documentFits || !labelsFit) {
    throw new Error(`390px board overflowed: ${JSON.stringify(geometry)}`);
  }
}

// Chrome startup on shared CI runners has exceeded 30 seconds, so keep this below the job-level hang tripwire but above observed startup variance.
const timeout = setTimeout(() => finish(1, "timed out measuring the rendered 390px board"), 90000);
run().then(() => {
  clearTimeout(timeout);
  finish(0);
}).catch((error) => {
  clearTimeout(timeout);
  finish(1, error.message);
});
JS
}

# The labelled decision context is deliberately a SIBLING of the row rather than
# part of it, because the row title is wrapped in a link whenever the decision has
# one and reading the recommendation must never navigate away. Markup alone cannot
# prove that, so this measures the real DOM: the context must not be inside any
# anchor, and it must not push the board sideways at phone width.
assert_decision_context_placement() {  # <html> [require-blocking-line]
  local html=$1 expect_blocking=${2:-false} chrome
  command -v node >/dev/null 2>&1 || {
    printf 'skip: node not found for rendered decision-context placement assertion\n'
    return 0
  }
  chrome=$(find_chrome) || {
    printf 'skip: Chrome or Chromium not found for rendered decision-context placement assertion\n'
    return 0
  }

  node - "$chrome" "$html" "$expect_blocking" <<'JS'
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const [chromePath, htmlPath, expectBlocking] = process.argv.slice(2);
const chrome = spawn(chromePath, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  "--remote-debugging-pipe",
  `--user-data-dir=${htmlPath}.ctx-profile`,
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
let buffer = "";
let nextId = 0;
let finished = false;
const pending = new Map();

function finish(code, message) {
  if (finished) return;
  finished = true;
  if (message) process.stderr.write(`${message}\n`);
  chrome.kill();
  process.exitCode = code;
}

chrome.on("error", (error) => finish(1, error.message));
chrome.stdio[3].on("error", (error) => finish(1, error.message));
chrome.stdio[4].on("error", (error) => finish(1, error.message));
chrome.stdio[4].on("data", (chunk) => {
  buffer += chunk;
  let boundary;
  while ((boundary = buffer.indexOf("\0")) >= 0) {
    const raw = buffer.slice(0, boundary);
    buffer = buffer.slice(boundary + 1);
    if (!raw) continue;
    const message = JSON.parse(raw);
    const resolve = pending.get(message.id);
    if (resolve) {
      pending.delete(message.id);
      resolve(message);
    }
  }
});

function send(method, params = {}, sessionId) {
  return new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    chrome.stdio[3].write(`${JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })}\0`);
  });
}

async function measure(sessionId, width, height, mobile) {
  await send("Emulation.setDeviceMetricsOverride", {
    width, height, deviceScaleFactor: 1, mobile,
  }, sessionId);
  await send("Page.navigate", { url: pathToFileURL(htmlPath).href }, sessionId);
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const ready = await send("Runtime.evaluate", {
      expression: "document.readyState", returnByValue: true,
    }, sessionId);
    if (ready.result.result.value === "complete") break;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const evaluated = await send("Runtime.evaluate", {
    returnByValue: true,
    expression: `(() => {
      const blocks = [...document.querySelectorAll(".need-ctx")];
      const values = [...document.querySelectorAll(".ctx-v")];
      const root = document.documentElement;
      return {
        blocks: blocks.length,
        blockingLines: [...document.querySelectorAll(".ctx-l")]
          .filter((label) => label.textContent.trim() === "Blocking:").length,
        insideAnchor: blocks.some((block) => block.closest("a") !== null),
        overflowing: values.some((value) => {
          const rect = value.getBoundingClientRect();
          return rect.left < 0 || rect.right > root.clientWidth + 0.5;
        }),
        documentWidth: root.scrollWidth,
        viewportWidth: root.clientWidth,
      };
    })()`,
  }, sessionId);
  return evaluated.result.result.value;
}

async function run() {
  const created = await send("Target.createTarget", { url: "about:blank" });
  const attached = await send("Target.attachToTarget", {
    targetId: created.result.targetId, flatten: true,
  });
  const sessionId = attached.result.sessionId;
  for (const [width, height, mobile] of [[1280, 1000, false], [390, 844, true]]) {
    const seen = await measure(sessionId, width, height, mobile);
    if (seen.blocks === 0) {
      throw new Error(`no decision context rendered at ${width}px: ${JSON.stringify(seen)}`);
    }
    if (expectBlocking === "true" && seen.blockingLines === 0) {
      throw new Error(`no blocking line rendered at ${width}px: ${JSON.stringify(seen)}`);
    }
    if (seen.insideAnchor) {
      throw new Error(`decision context rendered inside the row link at ${width}px, so reading it navigates away`);
    }
    if (seen.overflowing || seen.documentWidth > seen.viewportWidth) {
      throw new Error(`decision context overflowed at ${width}px: ${JSON.stringify(seen)}`);
    }
  }
}

const timeout = setTimeout(() => finish(1, "timed out measuring the rendered decision context"), 90000);
run().then(() => {
  clearTimeout(timeout);
  finish(0);
}).catch((error) => {
  clearTimeout(timeout);
  finish(1, error.message);
});
JS
}

# 2026-01-02T15:00:00Z, with TZ=UTC pinned by every case that renders a time.
NOW_EPOCH=1767366000
TODAY_0905=1767344700    # 2026-01-02T09:05:00Z
YESTERDAY_2335=1767310500  # 2026-01-01T23:35:00Z
LAST_JULY=1753178400     # 2025-07-22T10:00:00Z

export TZ=UTC

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  fm_fake_exit0 "$fb" no-mistakes
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A clone whose single commit lands on an exact epoch, so the board's relative
# wording is checked against a time this test chose rather than the clock.
make_clone() {  # <home> <name> <commit-epoch>
  local dir=$1/projects/$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  : > "$dir/README.md"
  git -C "$dir" add README.md
  GIT_AUTHOR_DATE="@$3 +0000" GIT_COMMITTER_DATE="@$3 +0000" \
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'fixture commit'
}

# A complete home: registry, backlog with a captain hold and an item landed on
# the board's own "today", one live ship task, a recorded PR, and a real clone
# for one of the two registered projects.
write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree"
  make_clone "$home" alpha "$TODAY_0905"
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- alpha [direct-PR +yolo] - Alpha service (added 2026-01-01)
- beta [no-mistakes] - Beta site (added 2026-01-02)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Rebuild the alpha intake form (repo: alpha) (kind: ship) (since 2026-01-03)

## Queued
- [ ] alpha-decision - Choose the alpha rollout window (repo: alpha) (kind: captain) (hold: Two rollout windows, both cost money) (hold-kind: captain) (since 2026-01-03)

## Done
- [x] alpha-landed - Ship the alpha health check https://github.com/example/alpha/pull/7 (repo: alpha) (kind: ship) (merged 2026-01-02)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "model=claude-opus-5" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=on" \
    "pr=https://github.com/example/alpha/pull/9"
  printf 'working: intake form wired up\n' > "$home/state/ship-task.status"
  # A task that is actually working proves it through its own semantic busy-state
  # record (bin/fm-busy-lib.sh), which is what the current-state read consults;
  # rendered pane text is not a state source. Without this the task reads
  # unknown, and the live fixture would never exercise a real ladder rung.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
}

# A minimal but schema-shaped snapshot, so a case can drive fields no local
# fixture produces (another home's decisions, hostile prose, path-form repos).
snapshot_json() {  # <records-json> <secondmate-records-json> [<tasks-json>]
  jq -n --argjson records "$1" --argjson sm "$2" --argjson tasks "${3:-[]}" '{
    schema: "fm-fleet-snapshot.v1",
    generated: "2026-01-04T00:00:00Z",
    fm_home: "/fixture/home",
    roots: {state: "/fixture/home/state", data: "/fixture/home/data",
            projects: "/fixture/home/projects"},
    backlog: {path: "/fixture/home/data/backlog.md", present: true, records: $records},
    tasks: $tasks,
    secondmate_current: {registry: {
      present: false, available: true, complete: true,
      input_truncated: false, records_truncated: false, records: []
    }, records: $sm}
  }'
}

# One live task exactly as the snapshot reports it. The stage is given as the
# derived object the snapshot attaches, because that is what the board consumes;
# bin/fm-fleet-snapshot.sh owns deriving it from live state and tests/fm-fleet-
# snapshot-view.test.sh pins that half.
live_task() {  # <id> <title> <repo> <model> <ordinal> <label> <motion>
  jq -n --arg id "$1" --arg title "$2" --arg repo "$3" --arg model "$4" \
        --argjson ordinal "$5" --arg label "$6" --arg motion "$7" '{
    id: $id, kind: "ship", harness: "claude", model: $model,
    project: $repo, backend: "tmux",
    current_state: {state: "working", source: "pane", detail: "", raw: "",
      stage: {ordinal: $ordinal, of: 5, label: $label, motion: $motion}},
    endpoint: {target: ("firstmate:fm-" + $id), exists: true},
    pr: {url: null, source: "absent"},
    hints: {pending_decision: false, blocked_event: false, open_decisions: []},
    backlog: {id: $id, title: $title, repo: $repo, state: "in_flight",
              kind: "ship", structured: true}
  }'
}

in_flight_record() {  # <id> <title> <repo>
  jq -n --arg id "$1" --arg title "$2" --arg repo "$3" '{
    id: $id, title: $title, raw: $title, repo: $repo, state: "in_flight",
    kind: "ship", structured: true, captain_actionable: false,
    captain_deferred: false, unresolved_blocker_ids: [], completion: {date: null}}'
}

# A count tells the captain something is happening without telling them what, so
# each in-progress item names itself and carries the two facts the count hides:
# how far it has travelled and which model is on it.
test_in_progress_items_are_listed_with_stage_and_model() {
  local snap board
  snap=$TMP_ROOT/items.json
  board=$TMP_ROOT/items.html
  snapshot_json "[$(in_flight_record early 'Rebuild the intake form' alpha),
                  $(in_flight_record mid 'Fix search ranking' alpha),
                  $(in_flight_record late 'Migrate the billing webhooks' alpha)]" '[]' \
    "[$(live_task early 'Rebuild the intake form' alpha claude-opus-5 2 Building live),
      $(live_task mid 'Fix search ranking' alpha claude-sonnet-5 3 Validating live),
      $(live_task late 'Migrate the billing webhooks' alpha claude-opus-5 4 'Checks running' live)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with in-progress items must render"

  assert_grep 'Rebuild the intake form' "$board" "an in-progress item must be named, not just counted"
  assert_grep 'Fix search ranking' "$board" "every in-progress item must be named"
  assert_grep 'Migrate the billing webhooks' "$board" "every in-progress item must be named"
  assert_grep '3 tasks under way' "$board" "the count above the list must survive"

  # The rung a bar fills and the rung its label claims are two renderings of one
  # fact. They are asserted together because a bar that drifted from its label is
  # exactly the silent overstatement the ladder exists to avoid.
  assert_grep 'aria-label="Stage 2 of 5: Building"' "$board" \
    "a bar must state its position in words for anyone who cannot see it"
  assert_grep '<i class="on"></i><i class="on"></i><i></i><i></i><i></i>' "$board" \
    "rung 2 of 5 must fill exactly two rungs"
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i></i><i></i>' "$board" \
    "rung 3 of 5 must fill exactly three rungs"
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i><i></i>' "$board" \
    "rung 4 of 5 must fill exactly four rungs"
  assert_grep '>Building</span>' "$board" "the stage must be named beside its bar"
  assert_grep '>Checks running</span>' "$board" "the stage must be named beside its bar"

  assert_grep '>Opus 5</span>' "$board" "the model on an item must be shown readably"
  assert_grep '>Sonnet 5</span>' "$board" "the model on an item must be shown readably"

  # The whole point of a stage ladder is that it is not a completion estimate.
  assert_no_grep '% complete' "$board" "a stage must never be dressed up as a percentage"
  assert_no_grep 'ETA' "$board" "a stage must never be dressed up as an ETA"
  pass "each in-progress item is listed with its stage and its model"
}

# Colour says whether an item is MOVING, which is a different question from how
# far it has come. An item stopped at rung four is still stopped, and a board
# that painted it as live progress would be actively misleading.
test_stalled_items_do_not_read_as_progress() {
  local snap board
  snap=$TMP_ROOT/motion.json
  board=$TMP_ROOT/motion.html
  snapshot_json "[$(in_flight_record held 'Replace the session cookie' alpha),
                  $(in_flight_record stuck 'Speed up the import job' alpha)]" '[]' \
    "[$(live_task held 'Replace the session cookie' alpha claude-opus-5 3 'Waiting on a decision' waiting),
      $(live_task stuck 'Speed up the import job' alpha claude-opus-5 2 Blocked stopped)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with stalled items must render"
  assert_grep 'class="wi-bar m-waiting"' "$board" \
    "an item waiting on the captain must be toned apart from one that is moving"
  assert_grep 'class="wi-bar m-stopped"' "$board" \
    "a blocked item must be toned apart from one that is moving"
  assert_grep 'class="wi-stage m-stopped">Blocked</span>' "$board" \
    "a blocked item must say so in words, not only in colour"
  assert_grep 'aria-label="Stage 3 of 5: Waiting on a decision"' "$board" \
    "a stalled item must keep the rung it reached rather than falling back to zero"
  pass "a stalled item keeps its rung but never reads as progress"
}

test_setup_uses_neutral_tone() {
  local snap board
  snap=$TMP_ROOT/setup-tone.json
  board=$TMP_ROOT/setup-tone.html
  snapshot_json "[$(in_flight_record setup 'Start the worker endpoint' alpha)]" '[]' \
    "[$(live_task setup 'Start the worker endpoint' alpha claude-opus-5 1 'Setup: endpoint present' quiet)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a Setup item must render"
  assert_grep 'class="wi-bar m-quiet" role="img" aria-label="Stage 1 of 5: Setup: endpoint present"' "$board" \
    "Setup must use its bounded neutral motion"
  assert_grep 'class="wi-stage m-quiet">Setup: endpoint present</span>' "$board" \
    "the Setup label must use the same neutral tone as its ladder"
  assert_grep '.wi-bar.m-quiet i.on{background:var(--slate);}' "$board" \
    "the Setup ladder must use the board's slate tone"
  assert_no_grep 'class="wi-bar m-live"' "$board" \
    "Setup must not claim observed live movement"
  pass "Setup uses one neutral slate tone"
}

# Ready has reached the top rung but still awaits the captain, while Done is
# terminal. Position alone cannot distinguish them, so their tones must.
test_ready_and_done_use_distinct_tones() {
  local snap board
  snap=$TMP_ROOT/ready-done.json
  board=$TMP_ROOT/ready-done.html
  snapshot_json "[$(in_flight_record ready 'Review the green PR' alpha),
                  $(in_flight_record 'done' 'Merged delivery' alpha)]" '[]' \
    "[$(live_task ready 'Review the green PR' alpha claude-opus-5 5 'Checks green' ready),
      $(live_task 'done' 'Merged delivery' alpha claude-opus-5 5 Done 'done')]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "ready and done stages must render"
  assert_grep 'class="wi-bar m-ready" role="img" aria-label="Stage 5 of 5: Checks green"' "$board" \
    "green checks awaiting the captain must use the ready tone"
  assert_grep 'class="wi-stage m-ready">Checks green</span>' "$board" \
    "the ready label must use the same bounded tone as its ladder"
  assert_grep 'class="wi-bar m-done" role="img" aria-label="Stage 5 of 5: Done"' "$board" \
    "terminal work must retain the done tone"
  pass "ready work is toned apart from completed work"
}

# A model id is a dispatch identifier. The captain reads a name.
test_model_ids_are_shown_as_readable_names() {
  local snap board
  snap=$TMP_ROOT/models.json
  board=$TMP_ROOT/models.html
  snapshot_json "[$(in_flight_record m1 'Vendor prefixed' alpha),
                  $(in_flight_record m2 'Namespaced provider' alpha),
                  $(in_flight_record m3 'Tagged local model' alpha),
                  $(in_flight_record m4 'Dated release' alpha),
                  $(in_flight_record m5 'Single word' alpha)]" '[]' \
    "[$(live_task m1 'Vendor prefixed' alpha claude-opus-5 2 Building live),
      $(live_task m2 'Namespaced provider' alpha openai-codex/gpt-5.6-terra 2 Building live),
      $(live_task m3 'Tagged local model' alpha ollama/qwen3.6:35b-fm 2 Building live),
      $(live_task m4 'Dated release' alpha claude-haiku-4-5-20251001 2 Building live),
      $(live_task m5 'Single word' alpha sonnet 2 Building live)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with varied model ids must render"
  assert_grep '>Opus 5</span>' "$board" "a vendor prefix must be dropped from the name"
  assert_grep '>GPT-5.6 Terra</span>' "$board" \
    "a namespaced provider must be dropped and the model read as a name"
  assert_grep '>qwen3.6:35b-fm</span>' "$board" \
    "a tagged local model must keep the exact tag it is addressed by"
  assert_grep '>Haiku 4.5</span>' "$board" \
    "a release stamp must be dropped and a split version rejoined"
  assert_grep '>Sonnet</span>' "$board" "a single-word model must still read as a name"
  assert_no_grep 'claude-opus-5' "$board" "a raw dispatch id must not reach the card"
  assert_no_grep '20251001' "$board" "a release stamp must not reach the card"
  pass "recorded model ids are shown as names the captain reads"
}

# An older secondmate home reports a routed task without the title, model, or
# stage this board wants. Absent is not the same as empty, and a blank where a
# fact belongs reads as a fact.
test_unrecorded_item_facts_are_disclosed_rather_than_blanked() {
  local snap board
  snap=$TMP_ROOT/unrecorded.json
  board=$TMP_ROOT/unrecorded.html
  snapshot_json '[]' '[{
    "id": "docsmate", "registered": true, "provenance": {"selected": "structured-home"},
    "current": {"state": "active_child_work", "reason": ""},
    "active_children": [
      {"id": "docs-legacy", "kind": "ship", "state": "working", "source": "pane"},
      {"id": "docs-new", "kind": "ship", "state": "working", "source": "run-step",
       "title": "Refresh the operator guide", "model": "claude-opus-5",
       "stage": {"ordinal": 3, "of": 5, "label": "Validating", "motion": "live"}}
    ],
    "decisions_open": [], "holds": [], "queued": [],
    "counts": {"active_children": 2, "decisions_open": 0, "holds": 0, "queued": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a secondmate reporting partial item facts must render"
  assert_grep 'Refresh the operator guide' "$board" "a routed task must be named on the card"
  assert_grep '>Opus 5</span>' "$board" "a routed task must show the model running it"
  assert_grep 'aria-label="Stage 3 of 5: Validating"' "$board" \
    "a routed task must carry its stage onto the card"
  assert_grep 'docs-legacy' "$board" \
    "a task reported without a title must fall back to its id rather than vanish"
  assert_grep 'model not recorded' "$board" \
    "an unrecorded model must be stated, never shown as a blank"
  assert_grep 'Stage unavailable' "$board" \
    "an unreported stage must be stated, never drawn as an honest-looking empty bar"
  assert_grep 'class="wi-bar m-unknown"' "$board" \
    "an unreported stage must not fill a rung it cannot prove"
  pass "an item fact the fleet did not record is disclosed rather than blanked"
}

# A stage on a routed task crosses a home boundary, and for a remote second mate
# a host boundary, so its numbers are another producer's. An out-of-range rung, a
# huge scale, or a motion this board has no rule for must not be drawn as given:
# the failure mode is a bar and its own label disagreeing, which is precisely
# what the ladder exists to prevent.
test_out_of_range_stage_values_are_bounded_before_they_are_drawn() {
  local snap board
  snap=$TMP_ROOT/hostile-stage.json
  board=$TMP_ROOT/hostile-stage.html
  snapshot_json '[]' '[{
    "id": "oddmate", "registered": true, "provenance": {"selected": "structured-home"},
    "current": {"state": "active_child_work", "reason": ""},
    "active_children": [
      {"id": "huge", "kind": "ship", "state": "working", "source": "pane",
       "title": "Scale far beyond the ladder", "model": "claude-opus-5",
       "stage": {"ordinal": 99, "of": 5000, "label": "Validating", "motion": "live"}},
      {"id": "unknown-motion", "kind": "ship", "state": "working", "source": "pane",
       "title": "Motion this board has no rule for", "model": "claude-opus-5",
       "stage": {"ordinal": 3, "of": 5, "label": "Validating", "motion": "sideways"}}
    ],
    "decisions_open": [], "holds": [], "queued": [],
    "counts": {"active_children": 2, "decisions_open": 0, "holds": 0, "queued": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an out-of-range stage must render rather than break the board"
  assert_no_grep 'Stage 99 of 5000' "$board" \
    "a rung and a scale from another home must be bounded before they are claimed"
  assert_grep 'aria-label="Stage 5 of 5: Validating"' "$board" \
    "an over-range rung must be clamped to the top of the ladder it is drawn on"
  # Five rungs drawn and five filled: the bar and its label still agree.
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i>' "$board" \
    "a clamped rung must fill exactly the rungs its label claims"
  assert_no_grep 'm-sideways' "$board" \
    "a motion with no rule behind it must never reach the page as a class"
  assert_grep 'class="wi-bar m-unknown"' "$board" \
    "an unrecognised motion must fall back to the tone that claims nothing"
  pass "stage values from another home are bounded before the ladder is drawn"
}

# A card keeps its common case open at a glance but must retain every received
# row. Overflow therefore belongs in the board's expandable shelf idiom.
test_long_item_list_keeps_every_item_in_an_expandable_shelf() {
  local snap board records tasks i bar_count model_count
  snap=$TMP_ROOT/many.json
  board=$TMP_ROOT/many.html
  records=""
  tasks=""
  for i in 1 2 3 4 5 6 7 8; do
    [ -z "$records" ] || { records="$records,"; tasks="$tasks,"; }
    records="$records$(in_flight_record "t$i" "Task number $i" alpha)"
    tasks="$tasks$(live_task "t$i" "Task number $i" alpha claude-opus-5 2 Building live)"
  done
  snapshot_json "[$records]" '[]' "[$tasks]" > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a card with many in-progress items must render"
  assert_grep '8 tasks under way' "$board" "the full count must never be capped"
  assert_grep 'Task number 6' "$board" "the open item list must reach the shelf boundary"
  assert_grep '<details class="shelf"><summary>' "$board" \
    "overflow must reuse the board's expandable shelf"
  assert_no_grep '<details class="shelf" id="deferred-shelf">' "$board" \
    "a project overflow shelf must not identify itself as Deferred"
  assert_grep '<span class="stitle">More in progress</span><span class="scount">2 more</span>' "$board" \
    "the shelf summary must state how many received rows it contains"
  assert_grep 'Task number 7' "$board" "the first shelved item must remain in the page"
  assert_grep 'Task number 8' "$board" "every received item must remain in the page"
  bar_count=$(grep -o 'aria-label="Stage 2 of 5: Building"' "$board" | wc -l | tr -d ' ')
  [ "$bar_count" = 8 ] || fail "every received item must retain its stage ladder, got $bar_count"
  model_count=$(grep -o '<span class="wi-model">Opus 5</span>' "$board" | wc -l | tr -d ' ')
  [ "$model_count" = 8 ] || fail "every received item must retain its model label, got $model_count"
  assert_no_grep 'not listed here' "$board" "received rows must never be described as unlisted"
  pass "a long item list keeps every received row in an expandable shelf"
}

# A second mate home can bound its children before the board sees them. Those
# unavailable rows are distinct from received rows placed in the local shelf.
test_upstream_omissions_stay_distinct_from_shelved_items() {
  local snap board children i
  snap=$TMP_ROOT/stacked.json
  board=$TMP_ROOT/stacked.html
  children=""
  for i in 1 2 3 4 5 6 7 8; do
    [ -z "$children" ] || children="$children,"
    children="$children{\"id\": \"c$i\", \"kind\": \"ship\", \"state\": \"working\",
      \"source\": \"pane\", \"title\": \"Routed task $i\", \"model\": \"claude-opus-5\",
      \"stage\": {\"ordinal\": 2, \"of\": 5, \"label\": \"Building\", \"motion\": \"live\"}}"
  done
  # The home reports 20 active children and hands over only 8 of them.
  snapshot_json '[]' "[{
    \"id\": \"busymate\", \"registered\": true, \"provenance\": {\"selected\": \"structured-home\"},
    \"current\": {\"state\": \"active_child_work\", \"reason\": \"\"},
    \"active_children\": [$children],
    \"decisions_open\": [], \"holds\": [], \"queued\": [],
    \"counts\": {\"active_children\": 20, \"decisions_open\": 0, \"holds\": 0, \"queued\": 0},
    \"omitted\": [{\"surface\": \"active_children\", \"count\": 12}]
  }]" > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a card whose home already bounded its children must render"
  assert_grep '<span class="stitle">More in progress</span><span class="scount">2 more</span>' "$board" \
    "the shelf must count only the received rows it contains"
  assert_grep 'Routed task 8' "$board" \
    "every child row received from the second mate must remain available"
  assert_grep '12 more active tasks were not included in this snapshot.' "$board" \
    "the upstream omission must be disclosed without mixing it into the shelf count"
  assert_grep '20 active tasks (8 shown)' "$board" \
    "the home bound must stay separately disclosed on the card"
  pass "upstream omissions stay distinct from received rows in the shelf"
}

test_renders_live_fixture_home() {
  local home fakebin out board
  home=$(make_home live)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "rendering a populated home must succeed"
  board="$home/state/mission-control.html"
  [ "$out" = "$board" ] || fail "default output path must be <state>/mission-control.html, got $out"
  assert_present "$board" "the board file must be written"

  assert_grep 'Awaiting your decision' "$board" "the board must carry a decisions-awaiting section"
  assert_grep 'Choose the alpha rollout window' "$board" "a captain-held item must be surfaced"
  assert_grep 'Two rollout windows, both cost money' "$board" "a hold reason with a comma must reach the card intact"
  assert_grep 'https://github.com/example/alpha/pull/9' "$board" "a recorded PR must be surfaced as a call"

  # End to end from the task metadata through the snapshot to the card. Every
  # other item case injects a stage object, so this is the only place that proves
  # the board reads the stage at the path the snapshot writes it: a field-name
  # drift between the two would quietly degrade every card to "Stage unavailable"
  # while leaving the injected cases green.
  assert_grep '1 task under way' "$board" "the live count must survive on the card"
  assert_grep 'Rebuild the alpha intake form' "$board" \
    "the live task must name itself on its project card"
  assert_grep '>Opus 5</span>' "$board" \
    "the model recorded for the live task must reach its card as a name"
  assert_grep 'aria-label="Stage 2 of 5: Building"' "$board" \
    "a task working before validation must reach its card at the rung it earned"
  assert_no_grep 'Stage unavailable' "$board" \
    "a stage the snapshot derived must never read as unavailable on the card"
  assert_grep '1 decision and 1 PR await you' "$board" \
    "a project card must total the calls waiting on the captain"
  assert_grep 'class="proj-name">alpha' "$board" "each registered project must get a card"
  assert_grep 'direct-PR +yolo' "$board" "a project card must show its delivery posture"

  assert_grep 'Ship the alpha health check' "$board" "an item landed today must appear as shipped"
  assert_grep 'https://github.com/example/alpha/pull/7' "$board" "a landed item must keep its link"

  # No completion percentage or ETA is ever invented for active work.
  assert_no_grep 'ETA' "$board" "the board must not invent an ETA"
  assert_no_grep '% complete' "$board" "the board must not invent a completion percentage"

  # The board is renamed into place, so a browser never reads a partial file.
  [ -z "$(find "$home/state" -name '.mission-control.html.*' -print -quit)" ] \
    || fail "no temporary board file may survive a successful render"
  pass "a populated home renders every section from live state"
}

test_project_last_change_comes_from_the_clone() {
  local home fakebin board
  home=$(make_home updated)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- today-proj [direct-PR] - Changed this morning
- yesterday-proj [direct-PR] - Changed last night
- older-proj [direct-PR] - Changed last July
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" today-proj "$TODAY_0905"
  make_clone "$home" yesterday-proj "$YESTERDAY_2335"
  make_clone "$home" older-proj "$LAST_JULY"
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with clones must render"

  # Wording is relative to the board's own NOW, never to a second clock read,
  # so the same snapshot renders identically every time.
  assert_grep 'Updated 9:05am today' "$board" \
    "a clone committed today must read as a time today"
  assert_grep 'Updated 11:35pm yesterday' "$board" \
    "a clone committed yesterday must read as a time yesterday"
  assert_grep 'Updated 22 Jul' "$board" \
    "an older clone must fall back to its calendar date"
  pass "each project card is dated from its own clone, relative to the board's NOW"
}

test_yesterday_uses_local_calendar_arithmetic() {
  local home fakebin board
  home=$(make_home dst-yesterday)
  printf -- '- fallback-proj [direct-PR] - Changed before fallback\n' > "$home/data/projects.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" fallback-proj 1792881000
  fakebin=$(make_fakebin "$home")
  board=$(TZ=Europe/London PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_MISSION_CONTROL_NOW_EPOCH=1792971000 "$BOARD" --no-quota) \
    || fail "a render across the autumn clock change must succeed"
  assert_grep 'Updated 11:30pm yesterday' "$board" \
    "the previous local calendar day must remain yesterday across DST fallback"
  pass "yesterday follows the local calendar across DST fallback"
}

test_missing_change_time_degrades_to_a_dash() {
  local home fakebin board dashes
  home=$(make_home nodate)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- no-clone [direct-PR] - Never cloned here
- not-a-repo [direct-PR] - A directory that is not a git repo
- empty-repo [direct-PR] - A git repo with no commits
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  mkdir -p "$home/projects/not-a-repo"
  : > "$home/projects/not-a-repo/README.md"
  mkdir -p "$home/projects/empty-repo"
  git -C "$home/projects/empty-repo" init -q
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "projects with no readable history must still render"

  # An absent clone, a directory that is not a repo, and a repo with no commits
  # are three different gaps, and all three must read as "no time recorded"
  # rather than as a plausible-looking time.
  dashes=$(grep -c 'Updated &mdash;' "$board")
  [ "$dashes" = 3 ] || fail "every project with no readable history must show a dash, got $dashes"
  assert_no_grep 'Updated today' "$board" "a missing history must not be rendered as today"
  assert_no_grep 'Updated just now' "$board" "a missing history must not be rendered as recent"
  pass "an absent, non-git, or empty clone degrades to a dash instead of a guessed time"
}

test_render_writes_nothing_into_the_project_clones() {
  local home fakebin marker touched
  home=$(make_home readonly)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- probe [direct-PR] - Read-only probe
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" probe "$TODAY_0905"
  fakebin=$(make_fakebin "$home")
  marker=$TMP_ROOT/readonly.marker
  : > "$marker"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota --out "$TMP_ROOT/readonly.html" >/dev/null \
    || fail "the read-only probe render must succeed"

  # Reading a clone's history is the only thing the board does to a project.
  touched=$(find "$home/projects" -newer "$marker" -print | head -5)
  [ -z "$touched" ] || fail "the board must not write inside a project clone, touched: $touched"
  pass "rendering reads project history without writing into any clone"
}

test_absent_sources_render_empty_sections() {
  local home fakebin out board
  home=$(make_home empty)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "an empty home must still render"
  board=$out
  assert_grep 'Nothing needs your decision right now.' "$board" \
    "an empty home must say nothing is waiting"
  assert_grep '<div class="n">0</div><div class="l">In progress</div>' "$board" \
    "an empty home must report no work under way"
  assert_grep 'Nothing landed yet today.' "$board" "an empty home must report nothing landed today"
  assert_grep 'Nothing blocked or failed.' "$board" "an empty home must report clear fleet health"
  assert_grep 'No project registry found' "$board" "an absent registry must be reported, not crash"
  assert_grep 'No second mates registered.' "$board" "an absent secondmate registry must be reported"
  assert_grep 'Allowance unavailable' "$board" "a skipped allowance read must be disclosed"
  pass "absent sources render as explicit empty sections instead of failing"
}

test_header_freshness_discloses_an_unknown_render_time() {
  local known_snap unknown_snap known_board unknown_board
  known_snap=$TMP_ROOT/freshness-known.json
  unknown_snap=$TMP_ROOT/freshness-unknown.json
  known_board=$TMP_ROOT/freshness-known.html
  unknown_board=$TMP_ROOT/freshness-unknown.html
  snapshot_json '[]' '[]' > "$known_snap"
  jq 'del(.generated)' "$known_snap" > "$unknown_snap"

  "$BOARD" --snapshot "$known_snap" --no-quota --out "$known_board" >/dev/null \
    || fail "a board with a generated timestamp must render"
  "$BOARD" --snapshot "$unknown_snap" --no-quota --out "$unknown_board" >/dev/null \
    || fail "a partial snapshot with no generated timestamp must render"

  assert_grep '<span id="age">live &middot; rendered 2026-01-04T00:00:00Z</span>' "$known_board" \
    "a known generated timestamp must keep the existing header label"
  assert_grep '<footer>firstmate &middot; mission control &middot; home /fixture/home &middot; snapshot fm-fleet-snapshot.v1 &middot; rendered 2026-01-04T00:00:00Z &middot; self-reload 60s</footer>' "$known_board" \
    "a known generated timestamp must keep the existing footer label"
  assert_grep '<span id="age">live &middot; rendered unavailable</span>' "$unknown_board" \
    "a missing generated timestamp must be disclosed as unavailable in the header"
  assert_grep '<footer>firstmate &middot; mission control &middot; home /fixture/home &middot; snapshot fm-fleet-snapshot.v1 &middot; rendered unavailable &middot; self-reload 60s</footer>' "$unknown_board" \
    "a missing generated timestamp must be disclosed as unavailable in the footer"
  assert_no_grep '<span id="age">live &middot; rendered null</span>' "$unknown_board" \
    "the header must never expose a raw null generated timestamp"
  assert_no_grep '<footer>firstmate &middot; mission control &middot; home /fixture/home &middot; snapshot fm-fleet-snapshot.v1 &middot; rendered null &middot; self-reload 60s</footer>' "$unknown_board" \
    "the footer must never expose a raw null generated timestamp"
  pass "the header and footer keep known render times and disclose an unavailable one"
}

test_recent_autonomous_actions_are_bounded_and_appendable() {
  local home fakebin board content
  home=$(make_home recent-actions)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "an empty recent-actions feed must render"
  assert_grep 'No autonomous actions were recorded in the last 12 hours.' "$board" \
    "an empty feed must be a genuine empty state"
  assert_no_grep '<div class="recent-action">' "$board" \
    "an empty feed must not invent an action row"

  # The append command is the public writer: two current entries display newest
  # first, while a third entry just outside the fixed 12-hour window ages out.
  FM_HOME="$home" FM_AUTONOMOUS_ACTION_NOW_EPOCH=$((NOW_EPOCH - 120)) \
    "$ACTION" decision alpha 'Validate the accepted threshold range' \
    'Applied the required range validation' >/dev/null \
    || fail "a decision event must append directly"
  FM_HOME="$home" FM_AUTONOMOUS_ACTION_NOW_EPOCH=$((NOW_EPOCH - 60)) \
    "$ACTION" merge beta https://github.com/example/beta/pull/42 >/dev/null \
    || fail "a merge event must append directly"
  FM_HOME="$home" FM_AUTONOMOUS_ACTION_NOW_EPOCH=$((NOW_EPOCH - 43201)) \
    "$ACTION" decision old-project 'Old finding' 'Old decision' >/dev/null \
    || fail "an expired fixture event must append directly"

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a populated recent-actions feed must render"
  assert_grep 'Validate the accepted threshold range' "$board" \
    "a recent autonomous decision must render"
  assert_grep 'Applied the required range validation' "$board" \
    "a recent decision must include its resolution"
  assert_grep 'https://github.com/example/beta/pull/42' "$board" \
    "a recent autonomous merge must render its PR URL"
  assert_no_grep 'Old finding' "$board" \
    "an event outside the 12-hour window must not render"
  content=$(cat "$board")
  case "$content" in
    *'Merged <a href="https://github.com/example/beta/pull/42"'*'Decided: Validate the accepted threshold range'*) ;;
    *) fail "recent actions must render newest first" ;;
  esac
  pass "recent autonomous actions are appendable, bounded, and newest first"
}

test_hostile_text_is_escaped() {
  local snap board out script_tags
  snap=$TMP_ROOT/hostile.json
  board=$TMP_ROOT/hostile.html
  cat > "$snap" <<'EOF'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "</script><script>alert(3)</script>",
  "fm_home": "/fixture/home",
  "roots": {"state": "/fixture/home/state", "data": "/fixture/home/data",
            "projects": "/fixture/home/projects"},
  "backlog": {"present": true, "records": [{
    "state": "queued", "id": "x1", "captain_actionable": true,
    "title": "<script>alert(1)</script> & \"quoted\"",
    "hold_reason": "<img src=x onerror=alert(2)>",
    "repo": "alpha"
  }]},
  "tasks": [],
  "secondmate_current": {"registry": {
    "present": false, "available": true, "complete": true,
    "input_truncated": false, "records_truncated": false, "records": []
  }, "records": []}
}
EOF
  out=$("$BOARD" --snapshot "$snap" --no-quota --out "$board") \
    || fail "hostile prose must still render"
  assert_no_grep '<script>alert(1)</script>' "$board" "markup in fleet prose must not reach the page as markup"
  assert_no_grep '<img src=x' "$board" "an injected tag must not reach the page as markup"
  assert_grep '&lt;script&gt;alert(1)&lt;/script&gt;' "$board" "markup must be escaped and still readable"
  assert_grep '&quot;quoted&quot;' "$board" "quotes in fleet prose must be escaped"
  assert_no_grep '<script>alert(3)</script>' "$board" \
    "a generated timestamp with a literal JSON unicode closing tag must not break out of the inline script"
  # Checked directly, not only by counting scripts: the payload has to be on the
  # page in escaped form, which is what proves it was neutralized rather than
  # dropped or silently rewritten.
  assert_grep '&lt;/script&gt;&lt;script&gt;alert(3)&lt;/script&gt;' "$board" \
    "the closing-tag payload must reach the page escaped and readable"
  # The board renders exactly two of its own scripts: the tab chosen in <head>
  # before first paint, and the age ticker plus tab wiring at the end of the
  # body. A third means hostile prose opened one of its own.
  script_tags=$(grep -o '<script>' "$board" | wc -l | tr -d ' ')
  [ "$script_tags" = 2 ] || fail "the rendered page must contain only its own two scripts, got $script_tags"
  pass "prose from fleet state is escaped before it reaches the page"
}

test_missing_backlog_is_disclosed_as_unavailable() {
  local snap board
  snap=$TMP_ROOT/no-backlog.json
  board=$TMP_ROOT/no-backlog.html
  snapshot_json '[]' '[]' | jq '.backlog.present = false' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot with an absent backlog must render"
  assert_grep 'waiting status incomplete' "$board" \
    "waiting status must be incomplete when main-home decisions cannot be read"
  assert_grep 'Main backlog is unavailable' "$board" "the missing decision source must be named"
  assert_grep '<div class="n">?</div><div class="l">Shipped today</div>' "$board" \
    "landed work must read as unknown, not as zero"
  assert_grep 'backlog unavailable' "$board" "the unreadable source must be named on the summary tile"
  assert_grep 'Shipped today is unavailable' "$board" "shipped work must not render as empty"
  assert_grep 'Backlog health is unavailable' "$board" "backlog health must not render as clear"
  assert_grep 'Fleet health cannot be confirmed' "$board" \
    "unconfirmable health must be raised above the board, not buried in a panel"
  assert_no_grep 'Nothing needs your decision right now.' "$board" \
    "an absent backlog must not produce an authoritative all-clear"
  assert_no_grep 'Nothing landed yet today.' "$board" \
    "an absent backlog must not produce an authoritative shipped zero"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "an absent backlog must not produce an authoritative health all-clear"
  # An unreadable backlog cannot prove that nothing was set aside either, so the
  # shelf stays away rather than asserting a count it did not read.
  assert_no_grep 'set aside' "$board" \
    "an absent backlog must not produce an authoritative deferred count"
  pass "an absent backlog marks every backlog-derived conclusion unavailable"
}

# A decision the captain sets aside must leave the primary view completely -
# the list, the section count, and the "Awaiting you" tile - and reappear only
# in the quiet shelf. Dropping it from the list while still counting it, or
# counting it while still listing it, are separate failures, so both are pinned
# to literal numbers rather than to the absence of the title alone.
# A decision filed with separate context fields must reach the captain as labelled
# sections, and a decision filed before that schema existed must reach them exactly
# as it always did. Both halves render from one real fixture home so the split is
# proven end to end rather than assumed from the renderer alone.
test_structured_decision_context_renders_as_labelled_sections() {
  local home fakebin board snap linked route_block legacy_block
  home=$(make_home decision-context-render)
  make_clone "$home" alpha "$TODAY_0905"
  printf -- '- alpha [direct-PR] - Alpha service\n' > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] alpha-route - Choose the alpha rollout route (repo: alpha) (kind: captain) (hold: Two routes, one call) (hold-kind: captain)
  Origin: alpha-review
  Decision key: route
  State: awaiting captain decision.
  Decision options: ["Use tailnet route","Use public route"]
  Why now: The alpha launch window closes on Friday and both routes need DNS lead time.
  What it affects: The alpha checkout redirect and every saved bookmark.
  Recommendation: Take the tailnet route; it is reversible within a day.
  No decision surface: Both routes are configuration only, so there is nothing built to compare.
- [ ] alpha-legacy - Approve the alpha vendor swap (repo: alpha) (kind: captain) (hold: The old vendor stops publishing next month) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota --controls) || fail "a home with a structured decision must render"

  # Each dimension is its own labelled row, which is the whole reason for storing
  # them apart: the captain finds the recommendation without reading for it.
  assert_grep '<span class="ctx-l">Why now</span><span class="ctx-v">The alpha launch window closes on Friday and both routes need DNS lead time.</span>' \
    "$board" "the reason a decision is needed now must be its own labelled section"
  assert_grep '<span class="ctx-l">What it affects</span><span class="ctx-v">The alpha checkout redirect and every saved bookmark.</span>' \
    "$board" "what a decision affects must be its own labelled section"
  assert_grep '<span class="ctx-l">Recommendation</span><span class="ctx-v">Take the tailnet route; it is reversible within a day.</span>' \
    "$board" "the recommendation must be its own labelled section"

  route_block=$(control_block "$board" "main" "alpha-route")
  assert_contains "$route_block" 'data-answer-choice="Use tailnet route"' \
    "a structured option must render as a labelled answer button"
  assert_contains "$route_block" 'data-answer-choice="Use public route"' \
    "every structured option must render as its own answer button"
  assert_contains "$route_block" 'data-open="answer" data-answer-custom>Answer</button>' \
    "quick answers must retain the legacy label until the direct reply service is proved"
  assert_not_contains "$route_block" 'class="rc-fact"' \
    "answer options without a decision kind must not gain fact-intake framing"

  # The conscious "nothing built applies" answer is shown too, because a decision
  # nobody prepared a surface for and one where none applies are not the same.
  assert_grep '<span class="ctx-l">No built surface</span><span class="ctx-v">Both routes are configuration only, so there is nothing built to compare.</span>' \
    "$board" "an explicit no-built-surface acknowledgment must reach the captain"

  # The legacy half. One structured block on a board with two decisions is what
  # proves the old-style decision was left alone rather than coincidentally bare.
  assert_grep 'Approve the alpha vendor swap' "$board" \
    "a decision filed before the structured schema must still reach the captain"
  assert_grep '<span class="hint">The old vendor stops publishing next month</span>' \
    "$board" "an old-style decision must still render its plain reason exactly as before"
  legacy_block=$(control_block "$board" "main" "alpha-legacy")
  assert_not_contains "$legacy_block" 'data-answer-choice=' \
    "an old-style decision must not gain inferred answer buttons"
  assert_contains "$legacy_block" 'data-open="answer">Answer</button>' \
    "an old-style decision must keep the original free-text Answer control"
  assert_not_contains "$legacy_block" 'class="rc-fact"' \
    "an old-style decision must not gain inferred fact-intake framing"
  [ "$(grep -o 'class="need-ctx"' "$board" | wc -l | tr -d ' ')" = 1 ] \
    || fail "an old-style plain-reason decision must render no labelled context block"
  assert_grep '<div class="n">2</div><div class="l">Awaiting you</div>' \
    "$board" "both decisions must still be counted"

  # The placement hazard only exists for a decision that HAS a link, because that
  # is the only row whose title is wrapped in an anchor. A decision with nothing to
  # link renders no anchor at all, so asserting placement against one would pass no
  # matter where the context sat. This second board carries a recorded PR so the
  # anchor is really on the page when the context is measured against it.
  snap=$TMP_ROOT/decision-context-linked.json
  linked=$TMP_ROOT/decision-context-linked.html
  snapshot_json '[{
    "state":"queued","id":"alpha-linked","structured":true,"kind":"captain",
    "captain_actionable":true,"captain_deferred":false,"unresolved_blocker_ids":[],
    "title":"Choose the linked alpha route","hold_reason":"Two routes, one call",
    "decision_why":"The alpha launch window closes on Friday.",
    "decision_affects":"The alpha checkout redirect and every saved bookmark.",
    "decision_recommendation":"Take the tailnet route; it is reversible within a day.",
    "pr_url":"https://github.com/example/alpha/pull/12","repo":"alpha",
    "completion":{"date":null}
  }]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$linked" >/dev/null \
    || fail "a linked structured decision must render"
  assert_grep '<a class="need-main" href="https://github.com/example/alpha/pull/12">' "$linked" \
    "the linked fixture must really wrap its row title in an anchor"
  assert_grep '</a></div><div class="need-ctx">' "$linked" \
    "the context block must start only after the row link and the row itself have closed"

  assert_decision_context_placement "$linked" \
    || fail "the rendered context must sit outside the row link and fit both widths"
  pass "structured decision context renders as labelled sections and leaves old-style decisions unchanged"
}

# A decision is a dependency fact as well as a call for an answer, so its card
# names the affected backlog work without requiring the captain to infer it from
# prose. A secondmate can omit dependent rows from its bounded summary, in which
# case the durable id is the only honest label.
test_decision_blocking_line_names_dependents_and_falls_back_to_ids() {
  local snap board
  snap=$TMP_ROOT/decision-blocking.json
  board=$TMP_ROOT/decision-blocking.html
  snapshot_json '[
    {"state":"queued","id":"alpha-route","structured":true,"kind":"captain",
     "captain_actionable":true,"captain_deferred":false,"unresolved_blocker_ids":[],
     "blocks_ids":["alpha-dashboard"],"title":"Choose the alpha release route",
     "hold_reason":"The release window is closing.","repo":"alpha","completion":{"date":null}},
    {"state":"queued","id":"alpha-dashboard","structured":true,"kind":"ship",
     "captain_actionable":false,"captain_deferred":false,"unresolved_blocker_ids":["alpha-route"],
     "blocks_ids":[],"title":"Launch the alpha operations dashboard","repo":"alpha",
     "completion":{"date":null}},
    {"state":"queued","id":"quiet-decision","structured":true,"kind":"captain",
     "captain_actionable":true,"captain_deferred":false,"unresolved_blocker_ids":[],
     "blocks_ids":[],"title":"Approve the quiet rollout","hold_reason":"The rollout is ready.",
     "repo":"alpha","completion":{"date":null}}
  ]' '[{
    "id":"brain","current":{"state":"captain_decision"},"active_children":[],
    "decisions_open":[{"id":"brain-route","key":"brain-route","verb":"captain-hold",
      "summary":"Choose the Brain routing budget","reason":"The capacity decision is due.",
      "source":"backlog","blocks_ids":["brain-dashboard"]}],
    "holds":[],"queued":[],"counts":{"active_children":0,"decisions_open":1,"holds":0}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with decision dependents must render"

  assert_grep '<span class="ctx-l">Blocking:</span><span class="ctx-v">Launch the alpha operations dashboard</span>' \
    "$board" "a decision must name the titled work it blocks"
  assert_grep '<span class="ctx-l">Blocking:</span><span class="ctx-v">brain-dashboard</span>' \
    "$board" "a secondmate decision must fall back to an unavailable dependent title's id"
  [ "$(grep -o '<span class="ctx-l">Blocking:</span>' "$board" | wc -l | tr -d ' ')" = 2 ] \
    || fail "only decisions with dependents must render a blocking line"

  assert_decision_context_placement "$board" true \
    || fail "blocking lines must fit the linked decision card at desktop and phone widths"
  pass "decision cards name dependents, omit empty impact lines, and fit at both widths"
}

test_deferred_decision_leaves_the_primary_view() {
  local home fakebin board
  home=$(make_home deferred)
  make_clone "$home" alpha "$TODAY_0905"
  printf -- '- alpha [direct-PR] - Alpha service\n' > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] alpha-window - Choose the alpha rollout window (repo: alpha) (kind: captain) (hold: Two rollout windows both cost money) (hold-kind: captain)
- [ ] pushcut-sub - Approve the Pushcut Pro subscription (repo: alpha) (kind: captain) (hold: The subscription renews yearly) (hold-kind: parked)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with a deferred decision must render"

  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "a deferred decision must not be counted in the awaiting tile"
  assert_grep '<span class="count">1 item' "$board" \
    "a deferred decision must not be counted in the awaiting section header"
  assert_grep 'Choose the alpha rollout window' "$board" \
    "the decision still awaiting the captain must stay in view"

  # Present once, in the shelf, with the reason that identifies it.
  [ "$(grep -c 'Approve the Pushcut Pro subscription' "$board")" = 1 ] \
    || fail "a deferred decision must appear exactly once, in the shelf"
  assert_grep 'class="shelf" id="deferred-shelf"' "$board" \
    "a deferred decision must render the uniquely identified deferred shelf"
  assert_grep '1 set aside' "$board" "the shelf must say how many decisions are set aside"
  assert_grep 'class="defer"' "$board" "the deferred decision must render as a deferred row"
  assert_grep 'The subscription renews yearly' "$board" \
    "a deferred decision must keep the reason that identifies it"

  # Setting a decision aside is a choice, not a gap in the data, and it is not a
  # blocker either.
  assert_no_grep 'waiting status incomplete' "$board" \
    "deferring a decision must not mark the waiting status incomplete"
  assert_no_grep 'some sources unavailable' "$board" \
    "deferring a decision must not read as an unavailable source"
  assert_grep 'Nothing blocked or failed.' "$board" \
    "a deferred decision must not surface as blocked or failed work"
  assert_grep '1 decision awaits you' "$board" \
    "a project card must count only the decisions still awaiting the captain"
  pass "a deferred decision leaves the awaiting list, the awaiting count, and health"
}

# The shelf is fed by whatever the snapshot could read. A secondmate home reports
# its queued rows bounded, so the shelf says when a decision set aside there may
# be outside the window rather than implying the list is complete.
test_deferred_shelf_reaches_a_secondmate_and_discloses_its_bound() {
  local snap board
  snap=$TMP_ROOT/deferred-sm.json
  board=$TMP_ROOT/deferred-sm.html
  snapshot_json '[]' '[{
    "id": "homemux", "registered": true,
    "provenance": {"selected": "structured-home"},
    "current": {"state": "no_active_work"},
    "decisions_open": [], "holds": [], "active_children": [],
    "queued": [
      {"id": "hm-tariff", "title": "Approve the HomeMux tariff switch",
       "hold_reason": "The switch locks in for a year", "hold_kind": "parked",
       "captain_actionable": false, "captain_deferred": true, "repo": "homemux"}
    ],
    "counts": {"decisions_open": 0, "holds": 0, "active_children": 0, "queued": 4},
    "omitted": [{"surface": "queued", "count": 3}]
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot carrying a deferred secondmate decision must render"
  assert_grep 'Approve the HomeMux tariff switch' "$board" \
    "a decision set aside in a secondmate home must reach the shelf"
  assert_grep 'homemux' "$board" "a deferred row must name where the decision lives"
  assert_grep '3 queued second mate rows were not read' "$board" \
    "a bounded queued read must be disclosed instead of implying a complete shelf"
  assert_no_grep 'class="hstate' "$board" \
    "a deferred decision must not be reported as held or blocked fleet health"
  pass "a deferred secondmate decision reaches the shelf with its bound disclosed"
}

# The header, the stat strip and the attention bar answer "is anything on fire,
# and how much awaits me", so they must never be tabbed away; everything else is
# grouped behind one of four tabs.
test_navigation_tabs_group_the_board() {
  local snap board section
  snap=$TMP_ROOT/tabs.json
  board=$TMP_ROOT/tabs.html
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
    "title": "Choose something", "hold_reason": "because", "repo": "alpha"}]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the board must render with its navigation tabs"

  assert_grep 'role="tablist"' "$board" "the board must expose a tablist"
  for section in decisions projects activity system; do
    assert_grep "id=\"tab-$section\" role=\"tab\"" "$board" "the $section tab must render"
    assert_grep "id=\"panel-$section\" role=\"tabpanel\"" "$board" "the $section panel must render"
    assert_grep "aria-controls=\"panel-$section\"" "$board" \
      "the $section tab must name the panel it controls"
  done
  assert_grep 'aria-labelledby="tab-decisions"' "$board" \
    "each panel must name the tab that labels it"
  # The tab has to be chosen before the body paints, or the default panel
  # flashes on every one of the board's own reloads.
  sed -n '1,/<body>/p' "$board" | grep -q '<script>' \
    || fail "the board must choose its tab before the body paints"

  # Always in view, outside every panel.
  section=$(sed -n '/<div class="wrap">/,/<div class="panel"/p' "$board")
  printf '%s' "$section" | grep -q '<h1>Mission Control</h1>' \
    || fail "the header must sit above the tabs"
  printf '%s' "$section" | grep -q 'class="l">Awaiting you</div>' \
    || fail "the stat strip must sit above the tabs"
  printf '%s' "$section" | grep -q 'class="tabs"' \
    || fail "the tab strip must sit above every panel"

  # The tab is remembered rather than carried in the URL, because the board's
  # own reload navigates without the fragment.
  assert_grep 'fm-mission-control-tab-v2:' "$board" \
    "the selected tab must be remembered across the board's own reload"
  assert_grep 'http-equiv="refresh"' "$board" \
    "the board must keep reloading itself with tabs in place"
  # An opened shelf snapping shut mid-read is the same reset the tabs avoid.
  assert_grep 'fm-mission-control-deferred-v2:' "$board" \
    "an opened deferred shelf must survive the board's own reload"
  assert_grep 'document.getElementById("deferred-shelf")' "$board" \
    "deferred persistence must target only the deferred shelf"
  assert_no_grep 'document.querySelector("details.shelf")' "$board" \
    "project overflow shelves must not share deferred persistence"
  assert_no_grep 'src="http' "$board" "the tabs must not depend on a network asset"
  pass "the board groups its sections behind keyboard-reachable navigation tabs"
}

# A fragment is only present on the entry load because the board's managed reload
# drops it. Execute the rendered head script twice against one browser-shaped
# storage area to prove that the fragment-selected tab becomes the remembered
# tab before the fragment disappears.
test_fragment_selected_tab_survives_reload() {
  local snap board
  snap=$TMP_ROOT/fragment-tab.json
  board=$TMP_ROOT/fragment-tab.html
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the fragment tab behavior fixture must render"
  command -v node >/dev/null 2>&1 \
    || fail "node is required to execute the rendered board's head script"
  node - "$board" <<'JS' \
    || fail "a fragment-selected tab must survive the next fragmentless load"
const fs = require("node:fs");
const vm = require("node:vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const head = html.slice(0, html.indexOf("<body>"));
const script = head.match(/<script>([\s\S]*?)<\/script>/)?.[1];
if (!script) process.exit(1);

const values = new Map();
const storage = {
  getItem(key) { return values.has(key) ? values.get(key) : null; },
  setItem(key, value) { values.set(key, value); }
};

function load(hash, localStorage) {
  const document = {documentElement: {className: ""}};
  const window = {location: {hash}, localStorage};
  vm.runInNewContext(script, {document, window});
  return document.documentElement.className;
}

if (load("#tab=system", storage) !== "js t-system") process.exit(1);
if (load("", storage) !== "js t-system") process.exit(1);

const refused = {
  getItem() { throw new Error("storage refused"); },
  setItem() { throw new Error("storage refused"); }
};
if (load("#tab=system", refused) !== "js t-decisions") process.exit(1);
JS
  pass "a fragment-selected tab is remembered before the fragment disappears"
}

# Project tags should lead to the complete current-state card rather than leave
# the captain to scan the Projects tab. The fixture covers registered,
# unregistered, and secondmate cards, while the browser check proves that the
# decision and PR tags use the existing tab and reading-anchor mechanics.
test_project_tags_jump_to_current_state_cards() {
  local home snap board chrome
  home=$(make_home project-tag-jumps)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- alpha [no-mistakes] - Registered project
EOF
  snap=$TMP_ROOT/project-tag-jumps.json
  board=$TMP_ROOT/project-tag-jumps.html
  snapshot_json '[
    {"id":"alpha-decision","title":"Choose alpha rollout","raw":"Choose alpha rollout","repo":"alpha","state":"queued","kind":"captain","structured":true,"captain_actionable":true,"captain_deferred":false,"unresolved_blocker_ids":[],"completion":{"date":null}},
    {"id":"gamma-decision","title":"Choose gamma rollout","raw":"Choose gamma rollout","repo":"gamma","state":"queued","kind":"captain","structured":true,"captain_actionable":true,"captain_deferred":false,"unresolved_blocker_ids":[],"completion":{"date":null}}
  ]' '[{
    "id":"brain","current":{"state":"captain_decision"},"active_children":[],
    "decisions_open":[{"id":"brain-decision","key":"brain-decision","summary":"Choose brain route","reason":"Needs a route","source":"backlog"}],
    "holds":[],"counts":{"active_children":0,"decisions_open":1,"holds":0}
  }]' "[$(live_task alpha-pr 'Review alpha PR' alpha claude-opus-5 4 Checks ready | jq '.pr.url = "https://example.invalid/alpha/pull/1"'),
             $(live_task gamma-task 'Build gamma route' gamma claude-opus-5 2 Building live)]" > "$snap"
  FM_HOME=$home "$BOARD" --snapshot "$snap" --no-quota --refresh 300 --out "$board" >/dev/null \
    || fail "the project-tag fixture must render"

  assert_grep 'href="#project:alpha" data-project-anchor="project:alpha" class="tag">alpha</a>' "$board" \
    "registered project tags must point at their card"
  assert_grep 'href="#project:gamma" data-project-anchor="project:gamma" class="tag">gamma</a>' "$board" \
    "unregistered project tags must point at their card"
  assert_grep 'href="#secondmate:brain" data-project-anchor="secondmate:brain" class="tag">brain</a>' "$board" \
    "secondmate tags must point at their card"
  assert_grep 'id="project:alpha" class="proj' "$board" \
    "a registered project card must expose its card anchor"
  assert_grep 'id="project:gamma" class="proj' "$board" \
    "an unregistered project card must expose its card anchor"
  assert_grep 'id="secondmate:brain" class="proj' "$board" \
    "a secondmate card must expose its card anchor"

  command -v node >/dev/null 2>&1 || { printf 'skip: node not found for project-tag browser regression\n'; return 0; }
  chrome=$(find_chrome) || { printf 'skip: Chrome or Chromium not found for project-tag browser regression\n'; return 0; }
  node - "$chrome" "$board" <<'JS' \
    || fail "project tags did not navigate to their card in a real browser"
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const [chromePath, boardPath] = process.argv.slice(2);
const chrome = spawn(chromePath, ["--headless=new", "--disable-gpu", "--no-sandbox",
  "--remote-debugging-pipe", `--user-data-dir=${boardPath}.project-jump-profile`],
  {stdio:["ignore","ignore","ignore","pipe","pipe"]});
let buffer = ""; let nextId = 0; const pending = new Map();
function send(method, params = {}, sessionId) { return new Promise((resolve) => {
  const id = ++nextId; pending.set(id, resolve);
  chrome.stdio[3].write(`${JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})}\0`);
}); }
chrome.stdio[4].on("data", (chunk) => { buffer += chunk; let at;
  while ((at = buffer.indexOf("\0")) >= 0) { const raw = buffer.slice(0, at); buffer = buffer.slice(at + 1);
    if (!raw) continue; const message = JSON.parse(raw); const resolve = pending.get(message.id);
    if (resolve) { pending.delete(message.id); resolve(message); } }
});
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function evaluate(sessionId, expression) {
  const result = await send("Runtime.evaluate", {expression,awaitPromise:true,returnByValue:true}, sessionId);
  if (result.result.exceptionDetails) throw new Error(result.result.exceptionDetails.text);
  return result.result.result.value;
}
async function navigate(sessionId) {
  await send("Page.navigate", {url:pathToFileURL(boardPath).href}, sessionId);
  for (let i=0;i<100;i++) { if (await evaluate(sessionId,"document.readyState") === "complete") break; await delay(20); }
  await delay(100);
}
function assert(ok, message) { if (!ok) throw new Error(message); }
(async () => {
  const created = await send("Target.createTarget", {url:"about:blank"});
  const attached = await send("Target.attachToTarget", {targetId:created.result.targetId,flatten:true});
  const sid = attached.result.sessionId;
  await send("Page.enable", {}, sid); await send("Runtime.enable", {}, sid);
  await navigate(sid);
  async function jump() {
    return evaluate(sid, `(() => {
      document.documentElement.className="js t-decisions";
      var tag=[...document.querySelectorAll('.need-wrap .tag[data-project-anchor="project:alpha"]')][0];
      tag.click(); var target=document.getElementById('project:alpha');
      var view=JSON.parse(sessionStorage.getItem(window.__fmViewKey)||'null'); var rect=target.getBoundingClientRect();
      return {projects:document.documentElement.classList.contains('t-projects'),highlight:target.classList.contains('project-arrived'),
        visible:rect.bottom>0&&rect.top<innerHeight,anchor:view&&view.anchor,
        alphaTags:document.querySelectorAll('.need-wrap .tag[data-project-anchor="project:alpha"]').length};
    })()`);
  }
  let result = await jump();
  assert(result.projects && result.highlight && result.visible && result.anchor === 'project:alpha' && result.alphaTags >= 2,
    'desktop project tag did not select, highlight, and save the alpha card: '+JSON.stringify(result));
  await delay(1850);
  assert(!(await evaluate(sid,"document.getElementById('project:alpha').classList.contains('project-arrived')")),
    'the project arrival highlight did not fade away');
  await send("Emulation.setDeviceMetricsOverride", {width:390,height:844,deviceScaleFactor:1,mobile:true}, sid);
  await send("Emulation.setTouchEmulationEnabled", {enabled:true,maxTouchPoints:1}, sid);
  await navigate(sid);
  result = await jump();
  assert(result.projects && result.highlight && result.visible && result.anchor === 'project:alpha' && result.alphaTags >= 2,
    'mobile project tag did not select, highlight, and save the alpha card: '+JSON.stringify(result));
  await send("Emulation.setEmulatedMedia", {features:[{name:"prefers-reduced-motion",value:"reduce"}]}, sid);
  result = await evaluate(sid, `(() => {
    document.documentElement.className="js t-decisions";
    var alpha=document.querySelector('.need-wrap .tag[data-project-anchor="project:alpha"]');
    var gamma=document.querySelector('.need-wrap .tag[data-project-anchor="project:gamma"]');
    alpha.click(); gamma.click();
    return {alpha:document.getElementById('project:alpha').classList.contains('project-arrived'),
      gamma:document.getElementById('project:gamma').classList.contains('project-arrived')};
  })()`);
  assert(!result.alpha && result.gamma,
    'a replaced reduced-motion highlight remained visible: '+JSON.stringify(result));
  await delay(2200);
  assert(!(await evaluate(sid,"document.getElementById('project:gamma').classList.contains('project-arrived')")),
    'the reduced-motion project arrival highlight did not clear');
  await send("Emulation.setTouchEmulationEnabled", {enabled:false}, sid);
  await send("Emulation.clearDeviceMetricsOverride", {}, sid);
  await send("Emulation.setScriptExecutionDisabled", {value:true}, sid);
  await navigate(sid);
  const fallback = await evaluate(sid, `(() => {
    var tag=[...document.querySelectorAll('.need-wrap .tag[href="#project:alpha"]')][0]; tag.click();
    var target=document.getElementById('project:alpha'); var rect=target.getBoundingClientRect();
    return {scripted:document.documentElement.classList.contains('js'),hash:location.hash,
      visible:rect.bottom>0&&rect.top<innerHeight};
  })()`);
  assert(!fallback.scripted && fallback.hash === '#project:alpha' && fallback.visible,
    'the no-script project link no longer reaches its visible card: '+JSON.stringify(fallback));
})().finally(() => chrome.kill()).catch((error) => { console.error(error.stack||error); process.exitCode=1; });
JS
  pass "project tags open and briefly highlight current-state cards on desktop, mobile, and without script"
}

# An attention bar the captain cannot follow is worse than none: clicking it has
# to reach fleet health wherever health now lives.
test_attention_bar_reaches_health_across_tabs() {
  local snap board
  snap=$TMP_ROOT/attn-tabs.json
  board=$TMP_ROOT/attn-tabs.html
  snapshot_json '[{"state": "queued", "id": "b1", "structured": true,
    "title": "Blocked item", "unresolved_blocker_ids": ["dep-1"], "repo": "alpha"}]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with blocked work must render"
  assert_grep 'class="attnbar" href="#health" data-tab="system"' "$board" \
    "the attention bar must open the tab that carries fleet health"
  assert_grep 'id="health"' "$board" \
    "fleet health must keep an anchor so the bar still lands with no script"
  pass "the attention bar reaches fleet health once health sits behind a tab"
}

test_unreadable_backlog_does_not_leave_projects_looking_calm() {
  local snap board data
  snap=$TMP_ROOT/no-backlog-registry.json
  board=$TMP_ROOT/no-backlog-registry.html
  data=$TMP_ROOT/no-backlog-registry-data
  mkdir -p "$data"
  printf -- '- alpha [direct-PR] - Alpha service\n- beta [no-mistakes] - Beta site\n' \
    > "$data/projects.md"
  snapshot_json '[]' '[]' \
    | jq --arg d "$data" '.backlog.present = false | .roots.data = $d' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a readable registry with an unreadable backlog must render"

  # Every quiet signal on a project card - no decisions, nothing queued,
  # nothing in flight - is read from the backlog, so with the backlog gone a
  # calm-looking card would be asserting a fact the board cannot know.
  assert_grep 'class="proj-name">alpha' "$board" "registered projects must still get cards"
  assert_grep 'Unconfirmed' "$board" "a project whose state cannot be read must say so on the card"
  assert_grep 'Your decisions here cannot be counted.' "$board" \
    "the card must name the missing source"
  assert_no_grep '>Idle</span>' "$board" \
    "a project must never read as idle while its backlog cannot be read"
  assert_no_grep 'Nothing in flight.' "$board" \
    "a project must never claim an empty queue it cannot see"
  pass "an unreadable backlog never leaves a project card looking calm"
}

test_blocked_work_is_raised_above_the_board() {
  local snap board
  snap=$TMP_ROOT/blocked.json
  board=$TMP_ROOT/blocked.html
  snapshot_json '[
    {"state": "queued", "id": "b1", "title": "Waits on the licence call",
     "repo": "alpha", "unresolved_blocker_ids": ["licence-call"]}
  ]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "blocked work must render"
  # Health sits below the three primary sections, so anything blocked or failed
  # is announced at the top rather than left for the captain to scroll to.
  assert_grep '1 item is blocked or failed' "$board" \
    "blocked work must be announced above the primary sections"
  assert_grep 'blocked by licence-call' "$board" "the blocker must be named in fleet health"
  assert_grep 'Waits on the licence call' "$board" "the blocked item must be named"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "a board with blocked work must not also claim to be clear"
  pass "blocked work is raised above the board instead of hidden in a panel"
}

test_duplicate_main_health_sources_are_normalized() {
  local snap board matches
  snap=$TMP_ROOT/duplicate-health.json
  board=$TMP_ROOT/duplicate-health.html
  snapshot_json '[{
    "state": "in_flight", "id": "dup-task", "title": "Blocked duplicate",
    "repo": "alpha", "unresolved_blocker_ids": ["access"]
  }]' '[]' | jq '.tasks = [{
    id: "dup-task", kind: "ship", project: "alpha",
    current_state: {state: "blocked"}, hints: {blocked_event: true},
    backlog: {title: "Blocked duplicate", repo: "alpha"},
    paths: {status_log: {last_event: {raw: "blocked: access"}}},
    pr: {url: null}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "duplicate task and backlog health evidence must render"
  assert_grep '1 item is blocked or failed' "$board" \
    "one blocked task must be counted once across health sources"
  assert_no_grep '2 items are blocked or failed' "$board" \
    "duplicate health evidence must not inflate the attention count"
  assert_grep 'blocked by access' "$board" \
    "normalized task health must retain the backlog blocker"
  matches=$(grep -o '>dup-task<' "$board" | wc -l | tr -d ' ')
  [ "$matches" = 1 ] || fail "normalized health must render dup-task once, got $matches"
  pass "main task health is normalized by task identity"
}

test_secondmate_captain_decision_is_surfaced() {
  local snap board
  snap=$TMP_ROOT/secondmate.json
  board=$TMP_ROOT/secondmate.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-cost", "key": "brain-cost", "verb": "captain-hold",
      "summary": "Approve the paid notification tier",
      "reason": "The two-way leg needs the paid tier",
      "why": "The free tier stops accepting two-way replies next month.",
      "affects": "Every reply that comes back from a notification.",
      "recommendation": "Take the paid tier; the one-way fallback loses replies.",
      "no_surface": "There is nothing to look at; the difference is in the reply path."
    }],
    "holds": [{
      "id": "brain-cost", "source": "backlog", "unresolved_blocker_ids": [],
      "reason": "The two-way leg needs the paid tier"
    }],
    "counts": {"active_children": 0, "decisions_open": 1, "holds": 1}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a secondmate-only decision must render"
  # This decision lives in the secondmate's own backlog, never in this home's,
  # so building the section from the main backlog alone would silently drop it.
  assert_grep 'Approve the paid notification tier' "$board" \
    "a captain decision held inside a secondmate home must reach the board"
  assert_grep 'href="#secondmate:brain" data-project-anchor="secondmate:brain" class="tag">brain</a>' "$board" \
    "the owning home must link to its secondmate card"
  # The bar applies to decisions filed in any home, and the secondmate projection
  # reaches the board through different key names than the main-home one, so the
  # cross-home half needs its own assertion rather than inheriting the main one.
  assert_grep '<span class="ctx-l">Recommendation</span><span class="ctx-v">Take the paid tier; the one-way fallback loses replies.</span>' \
    "$board" "a secondmate decision must carry its structured context to the board"
  assert_grep '<span class="ctx-l">No built surface</span><span class="ctx-v">There is nothing to look at; the difference is in the reply path.</span>' \
    "$board" "a secondmate no-built-surface acknowledgment must reach the captain"
  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "a secondmate decision must be counted as waiting"
  assert_grep 'Routed work is waiting for your decision.' "$board" \
    "the card must reflect the authoritative captain-decision state"
  assert_grep 'Nothing blocked or failed.' "$board" \
    "a captain decision must stay out of fleet health"
  assert_no_grep '>Blocked</span>' "$board" \
    "a captain decision must keep the needs-you pill"
  assert_grep 'second mate' "$board" "a secondmate card must say what it is"
  pass "a captain decision inside a secondmate home is surfaced and counted"
}

test_secondmate_mixed_decision_and_child_hold_stay_distinct() {
  local snap board
  snap=$TMP_ROOT/secondmate-mixed-holds.json
  board=$TMP_ROOT/secondmate-mixed-holds.html
  snapshot_json '[]' '[{
    "id": "brain", "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-cost", "key": "brain-cost", "verb": "captain-hold",
      "summary": "Approve the paid notification tier"
    }],
    "holds": [{
      "id": "brain-cost", "source": "backlog", "unresolved_blocker_ids": [],
      "reason": "Captain pricing choice"
    }, {
      "id": "vendor-window", "source": "child-state", "unresolved_blocker_ids": [],
      "reason": "Paused for the vendor maintenance window"
    }],
    "counts": {"active_children": 0, "decisions_open": 1, "holds": 2}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "mixed secondmate decisions and child holds must render"
  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "the captain decision must remain in the waiting count"
  assert_grep '1 fleet health item needs attention' "$board" \
    "only the child-state hold must reach the health count"
  assert_grep '>vendor-window<' "$board" \
    "the child-state hold must appear in fleet health"
  assert_grep 'Paused for the vendor maintenance window' "$board" \
    "child-state health must render its own wait reason"
  assert_no_grep 'blocked or failed' "$board" \
    "the captain decision must not be counted as unhealthy"
  assert_no_grep 'blocked by vendor-window' "$board" \
    "a paused child-state hold must not be relabelled as a blocker"
  pass "mixed secondmate decisions and child holds remain distinct"
}

test_secondmate_change_time_comes_from_its_own_reporting() {
  local home fakebin board
  home=$(make_home smtime)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf -- '- brain - Knowledge OS (home: %s; scope: brain; projects: brain; added 2026-01-01)\n' \
    "$home/secondmate" > "$home/data/secondmates.md"
  mkdir -p "$home/secondmate/state" "$home/secondmate/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/secondmate/data/backlog.md"
  fm_write_meta "$home/state/brain.meta" \
    "window=firstmate:fm-brain" \
    "kind=secondmate" \
    "home=$home/secondmate"
  printf 'working: routed work picked up\n' > "$home/state/brain.status"
  # A second mate is dated by when it last reported, not by a clone it may not
  # have fast-forwarded: a plausible but stale time is worse than no time.
  touch -t 202601020905.00 "$home/state/brain.status"
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with a secondmate must render"
  assert_grep 'Updated 9:05am today' "$board" \
    "a secondmate card must be dated from when it last reported"
  pass "a second mate is dated by its own last report"
}

test_bounded_secondmate_decisions_are_disclosed() {
  local snap board
  snap=$TMP_ROOT/bounded-secondmates.json
  board=$TMP_ROOT/bounded-secondmates.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-visible", "key": "brain-visible", "verb": "captain-hold",
      "summary": "Visible captain decision", "reason": "Visible bounded record"
    }],
    "counts": {"decisions_open": 3},
    "omitted": [{"surface": "decisions_open", "count": 2}]
  }]' | jq '.secondmate_current += {total: 2, shown: 1, truncated: 1}' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "bounded secondmate state must render"
  assert_grep '<div class="n">3+</div><div class="l">Awaiting you</div>' "$board" \
    "the count must include per-home omitted decisions and mark omitted homes unknown"
  assert_grep 'Additional captain decisions are not shown' "$board" \
    "per-home bounded decisions must produce an actionable disclosure"
  assert_grep 'Snapshot shows 1 of 3 decisions.' "$board" \
    "the per-home disclosure must state the bounded count"
  assert_grep 'Snapshot omitted 1 secondmate record(s).' "$board" \
    "top-level secondmate truncation must produce an incomplete-state disclosure"
  assert_grep '3 decisions await you (1 shown)' "$board" \
    "the secondmate card must use the authoritative decision count"
  pass "bounded secondmate decisions remain visible as incomplete captain work"
}

test_unreadable_secondmate_sources_are_disclosed() {
  local snap board
  snap=$TMP_ROOT/unavailable-registry.json
  board=$TMP_ROOT/unavailable-registry.html
  snapshot_json '[]' '[]' | jq '.secondmate_current.registry = {
    present: true, available: false, complete: false,
    reason: "registered secondmate table is unreadable",
    input_truncated: false, records_truncated: false, records: []
  }' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an unavailable secondmate registry must render"
  assert_grep 'waiting status incomplete' "$board" \
    "an unavailable registry must make the captain waiting status incomplete"
  assert_grep 'Secondmate registry scan is incomplete' "$board" \
    "an unavailable registry must produce an actionable disclosure"
  assert_grep 'registered secondmate table is unreadable' "$board" \
    "the registry disclosure must preserve the unavailable reason"
  assert_grep 'second mate list incomplete' "$board" \
    "an unavailable registry must mark the project count incomplete too"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "an unavailable registry must not produce an authoritative zero"

  snap=$TMP_ROOT/bounded-registry.json
  board=$TMP_ROOT/bounded-registry.html
  snapshot_json '[]' '[]' | jq '.secondmate_current.registry = {
    present: true, available: true, complete: false,
    reason: null, reasons: ["record_limit"],
    input_truncated: false, records_truncated: true, records: []
  }' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a bounded secondmate registry must render"
  assert_grep 'waiting status incomplete' "$board" \
    "a bounded registry must make the captain waiting status incomplete"
  assert_grep 'record_limit' "$board" "the registry disclosure must preserve its truncation reason"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "a bounded registry must not produce an authoritative zero"

  snap=$TMP_ROOT/unavailable-secondmate-home.json
  board=$TMP_ROOT/unavailable-secondmate-home.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "registered": true,
    "current": {"state": "unknown", "reason": "structured home snapshot failed"},
    "provenance": {"selected": "unknown"},
    "active_children": [], "decisions_open": [],
    "counts": {"decisions_open": 0}, "omitted": []
  }]' | jq '.secondmate_current.registry.records = [{
    id: "brain", home: "/fixture/brain", registered: true
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a registered secondmate with unreadable decisions must render"
  assert_grep 'waiting status incomplete' "$board" \
    "an unreadable registered home must make the captain waiting status incomplete"
  assert_grep 'Registered secondmate decisions are unavailable' "$board" \
    "an unreadable registered home must produce an actionable disclosure"
  assert_grep 'structured home snapshot failed' "$board" \
    "the registered-home disclosure must preserve the read failure reason"
  assert_grep 'Your decisions here cannot be read.' "$board" \
    "the secondmate card must not relabel an unreadable decision source as empty"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "an unreadable registered home must not produce an authoritative zero"
  pass "unreadable and bounded secondmate sources prevent a false all-clear"
}

test_path_form_repo_folds_into_the_project_rollup() {
  local snap board
  snap=$TMP_ROOT/rollup.json
  board=$TMP_ROOT/rollup.html
  # tasks-axi records a repo as a bare name or as a full clone path; both name
  # the same project and must land on the same card.
  snapshot_json '[
    {"state": "queued", "id": "p1", "captain_actionable": true, "title": "Classify the cash movements",
     "repo": "/fixture/home/projects/alpha"},
    {"state": "queued", "id": "p2", "captain_actionable": false, "title": "Queued alpha work", "repo": "alpha"}
  ]' '[]' > "$snap"
  mkdir -p "$TMP_ROOT/rollup-data"
  printf -- '- alpha [direct-PR] - Alpha service\n' > "$TMP_ROOT/rollup-data/projects.md"
  jq --arg d "$TMP_ROOT/rollup-data" '.roots.data = $d' "$snap" > "$snap.tmp" && mv "$snap.tmp" "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a path-form repo must render"
  assert_no_grep '/fixture/home/projects/alpha' "$board" \
    "a clone path must be shown as its project name, not a full path"
  assert_grep 'class="proj-name">alpha' "$board" "the project must appear once under its registry name"
  assert_grep '1 decision awaits you' "$board" \
    "a path-form captain hold must be counted on its project card"
  assert_grep '2 queued, nothing under way' "$board" \
    "both rows must fold onto the same project card"
  pass "path-form and bare-name repos fold onto the same project"
}

test_live_work_outside_the_registry_stays_visible() {
  local snap board
  snap=$TMP_ROOT/unregistered.json
  board=$TMP_ROOT/unregistered.html
  snapshot_json '[]' '[]' | jq '.tasks = [{
    id: "orphan-task", kind: "ship", project: "/somewhere/gamma",
    current_state: {state: "working"},
    backlog: {title: "Rework the gamma importer", repo: "gamma"},
    pr: {url: null}, paths: {status_log: {last_event: {raw: "working: started"}}}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "work on an unregistered project must render"
  # A task the captain can see running must never be invisible just because its
  # project was never registered.
  assert_grep '<div class="n">1</div><div class="l">In progress</div>' "$board" \
    "work under way must be counted"
  assert_grep 'Rework the gamma importer' "$board" \
    "work on an unregistered project must still name itself"
  # This row also arrives with no model and no stage, which is what a task row
  # from an older producer looks like: it stays listed, and says what it lacks.
  assert_grep 'Stage unavailable' "$board" \
    "a task row carrying no stage must be listed with the gap stated"
  assert_grep 'unregistered' "$board" "an unregistered project card must say so"
  pass "live work outside the registry is shown rather than silently dropped"
}

test_unregistered_live_project_uses_clone_change_time() {
  local home snap board
  home=$(make_home unregistered-updated)
  snap=$TMP_ROOT/unregistered-updated.json
  board=$TMP_ROOT/unregistered-updated.html
  make_clone "$home" gamma "$TODAY_0905"
  snapshot_json '[]' '[]' | jq --arg home "$home" '
    .roots.projects = ($home + "/projects") |
    .roots.data = ($home + "/data") |
    .tasks = [{
      id: "gamma-task", kind: "ship", project: "gamma",
      current_state: {state: "working"},
      backlog: {title: "Rework gamma", repo: "gamma"},
      pr: {url: null}
    }]' > "$snap"
  FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an unregistered live project with a clone must render"
  assert_grep 'class="proj-name">gamma' "$board" \
    "the live unregistered project must get a card"
  assert_grep 'Updated 9:05am today' "$board" \
    "an unregistered project card must read its clone history"
  pass "unregistered live project cards read their clone change time"
}

test_secondmate_health_and_activity_use_authoritative_counts() {
  local snap board
  snap=$TMP_ROOT/secondmate-health.json
  board=$TMP_ROOT/secondmate-health.html
  snapshot_json '[]' '[{
    "id": "brain", "current": {"state": "externally_held"},
    "active_children": [], "decisions_open": [],
    "holds": [{
      "id": "vendor-sync", "source": "child-state",
      "unresolved_blocker_ids": [], "reason": "Waiting for vendor access"
    }],
    "counts": {"active_children": 0, "decisions_open": 0, "holds": 3}
  }, {
    "id": "ops", "current": {"state": "active_child_work"},
    "active_children": [{"id": "visible-child"}], "decisions_open": [], "holds": [],
    "counts": {"active_children": 4, "decisions_open": 0, "holds": 0},
    "omitted": [{"surface": "active_children", "count": 3}]
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "bounded secondmate health and activity must render"
  assert_grep '<div class="n">4</div><div class="l">In progress</div>' "$board" \
    "the in-progress stat must include authoritative secondmate child counts"
  assert_grep '3 active task details omitted' "$board" \
    "the stat must disclose bounded secondmate activity details"
  assert_grep '4 tasks routed and under way' "$board" \
    "the secondmate card must use its authoritative active count"
  assert_grep '4 active tasks (1 shown)' "$board" \
    "the secondmate card must disclose omitted active children"
  assert_grep '>Blocked</span>' "$board" \
    "an externally held secondmate must not render as ready"
  assert_grep 'Waiting for vendor access' "$board" \
    "the secondmate card and health surface must preserve the hold reason"
  assert_grep '1 fleet health item needs attention; health details are incomplete' "$board" \
    "the attention bar must count classified secondmate holds without guessing omitted types"
  assert_grep '2 additional holds could not be classified' "$board" \
    "fleet health must disclose bounded hold details it cannot classify"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "held secondmate work must prevent a fleet-health all-clear"
  pass "secondmate health and activity remain authoritative when bounded"
}

# The active-child count crosses a home boundary and can therefore be absent or
# malformed independently of the child rows it describes. The board must keep
# both count consumers numeric without turning arbitrary prose into a count.
test_secondmate_child_count_shapes_render_safely() {
  local snap board
  snap=$TMP_ROOT/secondmate-child-count-shapes.json
  board=$TMP_ROOT/secondmate-child-count-shapes.html
  snapshot_json '[]' '[{
    "id": "numeric", "current": {"state": "active_child_work"},
    "active_children": [{"id": "numeric-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"active_children": 4, "decisions_open": 0, "holds": 0},
    "omitted": [{"surface": "active_children", "count": 3}]
  }, {
    "id": "zero", "current": {"state": "no_active_work"},
    "active_children": [], "decisions_open": [], "holds": [],
    "counts": {"active_children": 0, "decisions_open": 0, "holds": 0},
    "omitted": []
  }, {
    "id": "legacy", "current": {"state": "active_child_work"},
    "active_children": [{"id": "legacy-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"decisions_open": 0, "holds": 0}, "omitted": []
  }, {
    "id": "text-count", "current": {"state": "active_child_work"},
    "active_children": [{"id": "text-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"active_children": "many", "decisions_open": 0, "holds": 0},
    "omitted": []
  }, {
    "id": "text-count-no-rows", "current": {"state": "active_child_work"},
    "active_children": [], "decisions_open": [], "holds": [],
    "counts": {"active_children": "several", "decisions_open": 0, "holds": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "numeric, zero, missing, and non-numeric child counts must all render"
  assert_grep '<div class="n">6+</div><div class="l">In progress</div>' "$board" \
    "the in-progress tile must show the proven lower bound and disclose malformed counts"
  assert_grep '4 tasks routed and under way' "$board" \
    "a valid numeric count must retain its authoritative card total"
  assert_grep '4 active tasks (1 shown)' "$board" \
    "a valid numeric count must retain its omission semantics"
  assert_grep 'Idle and healthy, awaiting routed work.' "$board" \
    "a valid zero must retain the ready secondmate state"
  assert_grep '<div class="proj-state">1 task routed and under way</div>' "$board" \
    "a missing count must fall back to the complete rows an older producer supplied"
  assert_grep '<div class="proj-state">At least 1 task routed and under way</div>' "$board" \
    "a malformed count with one row must make the card state a lower bound"
  assert_grep 'Active task count unavailable (1 shown)' "$board" \
    "a malformed count must disclose that its visible row is not an authoritative total"
  assert_grep 'Routed work is under way; active task count unavailable.' "$board" \
    "a malformed count with no rows must not relabel active work as zero"
  assert_no_grep 'many' "$board" \
    "arbitrary count text must never be displayed as if it were a number"
  assert_no_grep 'several' "$board" \
    "another arbitrary count string must never leak into a count consumer"
  pass "secondmate child counts stay honest across numeric, zero, missing, and malformed inputs"
}

# A captured Token Dashboard API response drives the board through the same
# public payload the standalone service serves. The board keeps the pace-first
# hierarchy but narrows the payload before rendering, so session rows and action
# reasons cannot leak into Mission Control.
write_token_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "latest": {
    "capturedAt": "2026-01-02T14:50:00Z",
    "windows": [
      {"key":"claude:five_hour","provider":"claude","providerLabel":"Claude Max","id":"five_hour","label":"Claude · 5-hour","shortLabel":"Claude 5-hour","percentUsed":30,"percentRemaining":70,"resetsAt":"2026-01-02T17:00:00Z","windowSeconds":18000,"pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":30,"burnMultiple":0.5,"projectedExhaustedAt":"2026-01-02T18:00:00Z"}},
      {"key":"claude:seven_day","provider":"claude","providerLabel":"Claude Max","id":"seven_day","label":"Claude · 7-day","shortLabel":"Claude 7-day","percentUsed":80,"percentRemaining":20,"resetsAt":"2026-01-03T08:10:00Z","windowSeconds":604800,"pace":{"status":"ahead","elapsedPercent":90,"reservePercentPoints":10,"burnMultiple":0.89,"projectedExhaustedAt":"2026-01-03T07:00:00Z"}},
      {"key":"codex:weekly","provider":"codex","providerLabel":"ChatGPT Pro (OpenAI)","id":"weekly","label":"ChatGPT · weekly","shortLabel":"ChatGPT weekly","percentUsed":80,"percentRemaining":20,"resetsAt":"2026-01-04T05:30:00Z","windowSeconds":604800,"pace":{"status":"ahead","elapsedPercent":77,"reservePercentPoints":-3,"burnMultiple":1.04,"projectedExhaustedAt":"2026-01-03T20:30:00Z"}}
    ]
  },
  "history": [
    {"capturedAt":"2026-01-02T13:00:00Z","windows":[{"key":"claude:five_hour","percentUsed":10,"resetsAt":"2026-01-02T17:00:00Z"},{"key":"claude:seven_day","percentUsed":70,"resetsAt":"2026-01-03T08:10:00Z"},{"key":"codex:weekly","percentUsed":70,"resetsAt":"2026-01-04T05:30:00Z"}]},
    {"capturedAt":"2026-01-02T14:00:00Z","windows":[{"key":"claude:five_hour","percentUsed":20,"resetsAt":"2026-01-02T17:00:00Z"},{"key":"claude:seven_day","percentUsed":75,"resetsAt":"2026-01-03T08:10:00Z"},{"key":"codex:weekly","percentUsed":75,"resetsAt":"2026-01-04T05:30:00Z"}]},
    {"capturedAt":"2026-01-02T14:50:00Z","windows":[{"key":"claude:five_hour","percentUsed":30,"resetsAt":"2026-01-02T17:00:00Z"},{"key":"claude:seven_day","percentUsed":80,"resetsAt":"2026-01-03T08:10:00Z"},{"key":"codex:weekly","percentUsed":80,"resetsAt":"2026-01-04T05:30:00Z"}]}
  ],
  "settings":{"paceThresholds":{"fiveHour":{"comfortable":20,"edge":8},"weekly":{"comfortable":15,"edge":5}}},
  "lastError":null,
  "balancing":{"error":null,"actions":[
    {"ts":"2026-01-02T14:40:00Z","action":"route_visual_to_chatgpt","providerEased":"claude","auto":true,"tokens":1234,"reason":"TOP_SECRET_REASON","detail":"TOP_SECRET_DETAIL"},
    {"ts":"2026-01-02T12:00:00Z","action":"manual_override","providerEased":"codex","auto":false}
  ]},
  "metering":{"ranges":[{"providers":{"claude":{"sessions":[{"sessionId":"TOP_SECRET_SESSION"}]}}}]},
  "credentials":{"token":"TOP_SECRET_CREDENTIAL"},
  "refreshIntervalMs":900000
}
EOF
}

write_grok_quota_payload() {  # <path> [remaining]
  local remaining=${2:-97}
  cat > "$1" <<EOF
{
  "providers": [{
    "provider": "grok",
    "label": "Grok / SuperGrok",
    "windows": [
      {"id":"credits","label":"credits","percentUsed":$((100 - remaining)),"percentRemaining":$remaining,"resetsAt":"2026-01-09T15:00:00Z","pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":$((remaining - 40)),"cycleSeconds":604800,"burnMultiple":0.5,"projectedExhaustedAt":"2026-01-10T15:00:00Z"}},
      {"id":"product:grok_build","label":"Grok Build","percentUsed":2,"percentRemaining":98,"resetsAt":"2026-01-09T15:00:00Z","pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":38,"cycleSeconds":604800,"burnMultiple":0.05,"projectedExhaustedAt":"2026-01-10T15:00:00Z"}},
      {"id":"product:chat","label":"Chat","percentUsed":1,"percentRemaining":99,"resetsAt":"2026-01-09T15:00:00Z","pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":39,"cycleSeconds":604800,"burnMultiple":0.025,"projectedExhaustedAt":"2026-01-10T15:00:00Z"}}
    ],
    "credits": {"remaining": 1234, "unit": "credits"},
    "state": {"status":"fresh","authStatus":"usable"}
  }]
}
EOF
}

test_rich_token_dashboard_is_one_pace_first_allowance_view() {
  local snap token board cards
  snap=$TMP_ROOT/rich-token-snapshot.json
  token=$TMP_ROOT/rich-token.json
  board=$TMP_ROOT/rich-token.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a rich local token payload must render"

  assert_grep 'Allowance &amp; pace' "$board" \
    "the richer view must replace the old allowance heading rather than compete with it"
  cards=$(grep -o 'class="qwindow tone-' "$board" | wc -l | tr -d ' ')
  [ "$cards" = 3 ] || fail "the three primary allowance windows must render once each, got $cards"
  assert_grep '<strong>70%</strong><span>remaining</span>' "$board" \
    "current allowance must lead a window card"
  assert_grep 'Comfortably under pace' "$board" "a roomy window must carry the configured pace verdict"
  assert_grep 'Near your pace edge' "$board" "a narrowing window must carry the configured pace verdict"
  assert_grep 'Past your pace edge' "$board" "an over-pace window must carry the configured pace verdict"
  assert_grep '30% used · 60% through cycle · 30 pt pace buffer' "$board" \
    "used allowance, cycle position, and reserve must remain one supporting pace line"
  assert_grep 'Projected runway reaches reset' "$board" \
    "a projection beyond reset must be stated as runway through reset"
  assert_grep 'Projected exhaustion' "$board" \
    "a projection before reset must state exhaustion rather than implying enough runway"
  assert_grep '3 saved rounds · +20 pts observed' "$board" \
    "the compact trend must state its observed history rather than inventing a forecast"
  assert_grep 'Automatic balancing</strong> · 1 recent shift' "$board" \
    "automatic balancing must remain visible without expanding into a monitoring wall"
  assert_grep 'Route visual to chatgpt' "$board" "the newest automatic balancing action must be inspectable"
  assert_no_grep 'Manual override' "$board" "manual activity must not be relabelled as automatic balancing"
  assert_no_grep 'TOP_SECRET' "$board" \
    "session rows, credentials, action reasons, and unknown fields must not enter Mission Control"
  assert_no_grep '<h3>Allowance</h3>' "$board" \
    "the legacy gauge pane must not duplicate the richer allowance view"
  pass "rich local token data renders as one pace-first Mission Control allowance view"
}

test_unavailable_token_sources_are_explicit() {
  local snap token quota board
  snap=$TMP_ROOT/unavailable-token-snapshot.json
  token=$TMP_ROOT/unavailable-token.json
  quota=$TMP_ROOT/unavailable-quota.json
  board=$TMP_ROOT/unavailable-token.html
  snapshot_json '[]' '[]' > "$snap"
  printf '%s\n' '{"latest":null,"history":[],"balancing":{"actions":[]},"refreshIntervalMs":900000}' > "$token"
  printf '%s\n' '[]' > "$quota"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "unavailable token sources must still render the board"
  assert_grep 'Allowance unavailable' "$board" "an absent rich and raw reading must never look like zero"
  assert_grep 'local token history has no successful reading' "$board" \
    "the missing richer source must be named"
  assert_no_grep '<strong>0%</strong><span>remaining</span>' "$board" \
    "an unavailable allowance must not render as exhausted"
  pass "unavailable rich and raw allowance sources render an explicit unavailable state"
}

test_token_dashboard_url_cannot_leave_the_local_machine() {
  local snap board fakebin calls
  snap=$TMP_ROOT/local-token-url-snapshot.json
  board=$TMP_ROOT/local-token-url.html
  calls=$TMP_ROOT/local-token-url.calls
  snapshot_json '[]' '[]' > "$snap"
  fakebin=$(fm_fakebin "$TMP_ROOT/local-token-url-bin")
  cat > "$fakebin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\\n' called >> '$calls'
printf '%s\\n' '{"latest":{"capturedAt":"2026-01-02T14:50:00Z","windows":[]}}'
EOF
  cat > "$fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"providers":[]}'
EOF
  chmod +x "$fakebin/curl" "$fakebin/quota-axi"

  PATH="$fakebin:$PATH" FM_MISSION_CONTROL_TOKEN_URL='http://localhost:4173@outside.invalid/api/dashboard' \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a non-local token URL must fall back without leaving the machine"
  assert_absent "$calls" "a userinfo-shaped URL must not trick the local-only reader into calling outside"
  assert_grep 'token dashboard URL must be local' "$board" \
    "the live-only fallback must say why richer local history was refused"
  pass "the Token Dashboard reader cannot be redirected outside the local machine"
}

test_stale_token_history_is_labelled_without_hiding_it() {
  local snap token quota board
  snap=$TMP_ROOT/stale-token-snapshot.json
  token=$TMP_ROOT/stale-token.json
  quota=$TMP_ROOT/stale-token-quota.json
  board=$TMP_ROOT/stale-token.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"
  write_grok_quota_payload "$quota"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    FM_MISSION_CONTROL_NOW_EPOCH="$((NOW_EPOCH + 7200))" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a stale saved token reading must still render"
  assert_grep 'Token Dashboard allowance data is stale' "$board" \
    "the stale warning must identify the historical source rather than the live Grok cards"
  assert_grep '2h ago' "$board" "staleness must be judged against the board clock"
  assert_grep '<strong>70%</strong><span>remaining</span>' "$board" \
    "stale data must remain inspectable rather than disappearing"
  assert_grep '3 saved snapshots' "$board" "saved history must remain visible in the stale state"
  pass "stale token history stays visible with an explicit freshness warning"
}

test_narrow_token_shapes_keep_every_value_wrappable() {
  local snap token board long
  snap=$TMP_ROOT/narrow-token-snapshot.json
  token=$TMP_ROOT/narrow-token.json
  board=$TMP_ROOT/narrow-token.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"
  long='ClaudeAllowanceWindowWithAnIntentionallyLongUnbrokenOperatorFacingName1234567890'
  jq --arg long "$long" \
    '.latest.windows[0].shortLabel = $long | .latest.windows[0].providerLabel = ($long + $long)' \
    "$token" > "$token.tmp" && mv "$token.tmp" "$token"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a narrow-screen-shaped token payload must render"
  assert_grep "$long" "$board" "a long honest label must stay present rather than being clipped from the payload"
  assert_narrow_board_geometry "$board" "$long" "$long$long" \
    || fail "long allowance labels must fit the rendered board without horizontal overflow"
  pass "narrow-screen token shapes keep every operator value present and wrappable"
}

test_unmeasurable_allowance_is_not_a_zero_gauge() {
  local snap quota board
  snap=$TMP_ROOT/quota-snap.json
  quota=$TMP_ROOT/quota.json
  board=$TMP_ROOT/quota.html
  snapshot_json '[]' '[]' > "$snap"
  cat > "$quota" <<'EOF'
{"providers": [
  {"provider": "claude", "label": "Claude", "windows": [],
   "state": {"status": "auth_required", "error": "Claude sign-in required"}},
  {"provider": "codex", "label": "Codex", "windows": [
    {"id": "weekly", "label": "week", "percentRemaining": 68, "resetsAt": "2026-01-09T21:10:04.000Z"}]}
]}
EOF
  FM_MISSION_CONTROL_QUOTA_JSON="$quota" "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "an allowance reading must render"
  assert_grep '68%' "$board" "a measured allowance window must render as a gauge"
  assert_grep 'Claude sign-in required' "$board" "an unavailable provider must state why"
  # A sign-in gap is not an exhausted allowance, so it must never draw as 0%.
  assert_no_grep '>0%<' "$board" "an unmeasurable provider must not render as a zero gauge"
  pass "an unmeasurable allowance reports its reason instead of an empty gauge"
}

test_grok_live_windows_fill_a_dashboard_gap() {
  local snap token quota board cards
  snap=$TMP_ROOT/grok-dashboard-gap-snapshot.json
  token=$TMP_ROOT/grok-dashboard-gap-token.json
  quota=$TMP_ROOT/grok-dashboard-gap-quota.json
  board=$TMP_ROOT/grok-dashboard-gap.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"
  write_grok_quota_payload "$quota"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a live Grok reading must fill a Token Dashboard provider gap"

  cards=$(grep -o 'class="qwindow tone-' "$board" | wc -l | tr -d ' ')
  [ "$cards" = 6 ] || fail "the three existing and three Grok windows must render, got $cards"
  assert_grep '>Credits</span>' "$board" "the Grok credits window title must be human-readable"
  assert_no_grep '>credits</span>' "$board" "the raw Grok credits identifier must not leak into the card title"
  assert_grep '>Grok Build</span>' "$board" "the Grok Build product window must render"
  assert_grep '>Chat</span>' "$board" "the Chat product window must render"
  assert_grep '>Grok / SuperGrok</span>' "$board" "Grok cards must retain their provider label"
  assert_grep '<strong>97%</strong><span>remaining</span>' "$board" \
    "the Grok credits window percentage must render as remaining allowance"
  assert_grep '60% through cycle' "$board" "Grok pace data must remain visible on the compact card"
  assert_grep 'Projected runway reaches reset' "$board" "Grok runway must render when the live probe supplies it"
  assert_no_grep '1234' "$board" "a prepaid credits balance must not be represented as a percentage or allowance window"
  assert_narrow_board_geometry "$board" "Grok Build" "Grok / SuperGrok" \
    || fail "Grok cards must fit a 390px allowance view"
  pass "live Grok windows fill a missing Token Dashboard provider without using prepaid credits"
}

test_grok_quota_fallback_keeps_live_windows() {
  local snap token quota board cards
  snap=$TMP_ROOT/grok-quota-fallback-snapshot.json
  token=$TMP_ROOT/grok-quota-fallback-token.json
  quota=$TMP_ROOT/grok-quota-fallback-quota.json
  board=$TMP_ROOT/grok-quota-fallback.html
  snapshot_json '[]' '[]' > "$snap"
  printf '%s\n' '{"latest":null,"history":[],"balancing":{"actions":[]}}' > "$token"
  write_grok_quota_payload "$quota"
  jq '.providers += [{"provider":"claude","label":"Claude Max","windows":[{"id":"five_hour","label":"5-hour","percentRemaining":68,"resetsAt":"2026-01-09T15:00:00Z"}],"state":{"status":"fresh"}}]' \
    "$quota" > "$quota.tmp" && mv "$quota.tmp" "$quota"

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a Grok-only quota fallback must render"

  cards=$(grep -o 'class="qwindow tone-' "$board" | wc -l | tr -d ' ')
  [ "$cards" = 3 ] || fail "the three Grok fallback windows must use compact cards, got $cards"
  assert_grep '>Grok Build</span>' "$board" "the compact fallback must retain Grok product windows"
  assert_grep '<strong>98%</strong><span>remaining</span>' "$board" \
    "the compact fallback must retain Grok window percentages"
  assert_grep '60% through cycle' "$board" "the compact fallback must retain supplied Grok pace"
  assert_grep 'Projected runway reaches reset' "$board" \
    "the compact fallback must retain supplied Grok runway"
  assert_grep 'Claude Max / 5-hour' "$board" \
    "an existing provider must retain its legacy fallback gauge"
  assert_no_grep '1234' "$board" "the quota fallback must not render prepaid credits as allowance"
  pass "the raw quota fallback carries Grok windows through unchanged"
}

test_token_dashboard_grok_data_stays_preferred() {
  local snap token quota board
  snap=$TMP_ROOT/grok-dashboard-preferred-snapshot.json
  token=$TMP_ROOT/grok-dashboard-preferred-token.json
  quota=$TMP_ROOT/grok-dashboard-preferred-quota.json
  board=$TMP_ROOT/grok-dashboard-preferred.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"
  jq '.latest.windows += [{"key":"grok:product:grok_build","provider":"grok","providerLabel":"Grok / SuperGrok","id":"product:grok_build","label":"Dashboard Grok Build","shortLabel":"Dashboard Grok Build","percentUsed":23,"percentRemaining":77,"resetsAt":"2026-01-09T15:00:00Z","windowSeconds":604800,"pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":17,"burnMultiple":0.6,"projectedExhaustedAt":"2026-01-10T15:00:00Z"}},{"key":"grok:credits","provider":"grok","providerLabel":"Grok / SuperGrok","id":"credits","label":"credits","shortLabel":"credits","percentUsed":9,"percentRemaining":91,"resetsAt":"2026-01-09T15:00:00Z","windowSeconds":604800,"pace":{"status":"behind","elapsedPercent":60,"reservePercentPoints":31,"burnMultiple":0.2,"projectedExhaustedAt":"2026-01-10T15:00:00Z"}}]' \
    "$token" > "$token.tmp" && mv "$token.tmp" "$token"
  write_grok_quota_payload "$quota" 12

  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a Token Dashboard Grok reading must render"

  assert_grep '>Dashboard Grok Build</span>' "$board" \
    "the normalized Token Dashboard Grok window must render"
  assert_grep '>Credits</span>' "$board" \
    "the normalized Token Dashboard credits title must be human-readable"
  assert_no_grep '>credits</span>' "$board" \
    "the normalized Token Dashboard credits title must not remain lowercase"
  assert_grep '<strong>77%</strong><span>remaining</span>' "$board" \
    "the normalized Token Dashboard reading must remain authoritative"
  assert_no_grep '<strong>12%</strong><span>remaining</span>' "$board" \
    "a live Grok fallback must not replace normalized Token Dashboard data"
  pass "Token Dashboard Grok data remains preferred over the live fallback"
}

test_grok_unmeasurable_and_sign_in_states_use_existing_allowance_copy() {
  local snap token quota board
  snap=$TMP_ROOT/grok-unmeasurable-snapshot.json
  token=$TMP_ROOT/grok-unmeasurable-token.json
  quota=$TMP_ROOT/grok-unmeasurable-quota.json
  board=$TMP_ROOT/grok-unmeasurable.html
  snapshot_json '[]' '[]' > "$snap"
  write_token_payload "$token"

  cat > "$quota" <<'EOF'
{"providers":[{"provider":"grok","label":"Grok / SuperGrok","windows":[],"credits":{"remaining":456,"unit":"credits"},"state":{"status":"fresh"}}]}
EOF
  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a prepaid-credits-only Grok source must render"
  assert_grep '<span>Grok / SuperGrok</span><span class="gval">fresh</span>' "$board" \
    "a prepaid-credits-only source must use the existing no-window state"
  assert_no_grep '456' "$board" "a prepaid credits balance must remain out of the allowance UI"

  cat > "$quota" <<'EOF'
{"providers":[{"provider":"grok","label":"Grok / SuperGrok","windows":[{"id":"product:chat","label":"Chat"}],"state":{"status":"unavailable","error":"Grok usage unavailable"}}]}
EOF
  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "an unmeasurable Grok source must render"
  assert_grep 'Grok usage unavailable' "$board" \
    "an unmeasurable Grok window must use the existing provider reason"

  cat > "$quota" <<'EOF'
{"providers":[{"provider":"grok","label":"Grok / SuperGrok","windows":[],"state":{"status":"auth_required","error":"Grok sign-in required"}}]}
EOF
  FM_MISSION_CONTROL_TOKEN_JSON="$token" FM_MISSION_CONTROL_QUOTA_JSON="$quota" \
    "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "a Grok sign-in-required source must render"
  assert_grep 'Grok sign-in required' "$board" \
    "a Grok sign-in gap must use the existing provider reason"
  assert_no_grep '>0%<' "$board" "unavailable Grok data must not render as exhausted allowance"
  pass "Grok prepaid, unmeasurable, and sign-in states use existing allowance equivalents"
}

test_usage_errors_refuse() {
  local code snap
  snap=$TMP_ROOT/usage.json
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --nonsense >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "an unknown flag"
  "$BOARD" --refresh 0 >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "a zero refresh interval"
  "$BOARD" --snapshot "$TMP_ROOT/does-not-exist.json" >/dev/null 2>&1; code=$?
  expect_code 1 "$code" "an unreadable snapshot file"
  pass "invalid invocations refuse instead of writing a board"
}

test_self_reload_is_wired() {
  local snap board default_board help
  snap=$TMP_ROOT/reload.json
  board=$TMP_ROOT/reload.html
  default_board=$TMP_ROOT/reload-default.html
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$default_board" >/dev/null \
    || fail "the board must render with its default refresh interval"
  assert_grep 'http-equiv="refresh" content="60"' "$default_board" \
    "the default board refresh interval must be 60 seconds"
  assert_grep 'var every = 60000;' "$default_board" \
    "the script-managed default refresh interval must be 60 seconds"
  help=$("$BOARD" --help)
  assert_contains "$help" 'self-reload interval (default 60)' \
    "the usage text must state the default refresh interval"
  "$BOARD" --snapshot "$snap" --no-quota --refresh 30 --out "$board" >/dev/null \
    || fail "the board must render with an explicit refresh interval"
  assert_grep 'http-equiv="refresh" content="30"' "$board" \
    "the board must reload itself so a regenerated file is picked up"
  assert_grep 'var every = 30000;' "$board" \
    "an explicit refresh interval must override the default"
  assert_no_grep 'src="http' "$board" "the board must not depend on a network asset"
  assert_no_grep 'href="http://' "$board" "the board must not load a remote stylesheet"
  pass "the board self-reloads and stays self-contained"
}

# Exercise both public render modes, then parse their emitted document contract
# rather than looking for implementation text in the renderer. The browser gets
# one percent-encoded, standalone SVG with an explicit MIME type in either mode.
test_favicon_is_self_contained_in_every_board() {
  local snap board controls_board
  snap=$TMP_ROOT/favicon.json
  board=$TMP_ROOT/favicon.html
  controls_board=$TMP_ROOT/favicon-controls.html
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the ordinary board must render with its favicon"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$controls_board" >/dev/null \
    || fail "the control-enabled board must render with its favicon"

  python3 - "$board" "$controls_board" <<'PY' \
    || fail "every rendered board must expose the same valid, self-contained SVG favicon"
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

class IconParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.icons = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "link" and "icon" in attributes.get("rel", "").split():
            self.icons.append(attributes)

def icon_contract(path):
    parser = IconParser()
    with open(path, encoding="utf-8") as rendered:
        parser.feed(rendered.read())
    if len(parser.icons) != 1:
        raise AssertionError(f"{path}: expected one favicon, got {len(parser.icons)}")
    icon = parser.icons[0]
    if icon.get("type") != "image/svg+xml" or icon.get("sizes") != "any":
        raise AssertionError(f"{path}: favicon MIME or scalable-size contract is missing")
    prefix = "data:image/svg+xml,"
    href = icon.get("href", "")
    if not href.startswith(prefix):
        raise AssertionError(f"{path}: favicon is not an inline SVG data URL")
    encoded = href[len(prefix):]
    if "<" in encoded or ">" in encoded:
        raise AssertionError(f"{path}: SVG markup is not URL encoded")
    payload = urllib.parse.unquote_to_bytes(encoded).decode("utf-8", "strict")
    root = ET.fromstring(payload)
    if root.tag != "{http://www.w3.org/2000/svg}svg" or root.get("viewBox") != "0 0 32 32":
        raise AssertionError(f"{path}: favicon is not the expected scalable SVG document")
    children = list(root)
    if len(children) < 3 or not any(child.tag.endswith("circle") for child in children):
        raise AssertionError(f"{path}: favicon has no complete compact mark")
    for element in root.iter():
        if element.tag.endswith(("script", "foreignObject")):
            raise AssertionError(f"{path}: favicon contains executable or foreign content")
        for name, value in element.attrib.items():
            if name.endswith("href") or "url(" in value.lower():
                raise AssertionError(f"{path}: favicon references another resource")
    return href

ordinary = icon_contract(sys.argv[1])
controlled = icon_contract(sys.argv[2])
if ordinary != controlled:
    raise AssertionError("ordinary and control-enabled boards emitted different favicons")
PY
  pass "ordinary and control-enabled boards share one valid self-contained favicon"
}

# A snapshot carrying one of every row the reply layer has to decide about: a
# main captain decision, a secondmate decision that IS a backlog hold, a
# secondmate decision that is only a task-level open decision, and a PR row.
controls_snapshot() {
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
      "title": "Choose the rollout window", "hold_reason": "Both windows cost money",
      "repo": "alpha"}]' \
    '[{"id": "ios", "registered": true, "provenance": {"selected": "structured-home"},
       "current": {"state": "captain_decision"},
       "decisions_open": [
         {"id": "b7", "key": "b7", "verb": "captain-hold", "summary": "Pick the signing route",
          "reason": "two routes", "source": "backlog"},
         {"id": "t9", "key": "api-shape", "verb": "needs-decision", "summary": "Which API shape",
          "reason": null, "source": "status"}],
       "holds": [], "queued": [], "counts": {}, "omitted": []}]' \
  | jq '.tasks = [{id: "t1", kind: "ship", project: "alpha", model: "claude-opus-5",
        backlog: {title: "Wire the intake form", repo: "alpha"},
        pr: {url: "https://github.com/example/alpha/pull/9"},
        current_state: {state: "working",
          stage: {ordinal: 4, of: 5, label: "Checks running", motion: "live"}}}]'
}

# The reply layer must never appear unless it was asked for, because the same
# file is what gets served read-only.
test_controls_are_absent_unless_asked_for() {
  local snap board
  snap=$TMP_ROOT/nocontrols.json
  board=$TMP_ROOT/nocontrols.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the board must still render without the controls flag"
  assert_no_grep 'class="rc"' "$board" "a board rendered without --controls carries no reply layer"
  assert_no_grep 'FM-BOARD-REQUEST' "$board" "a board rendered without --controls queues nothing"
  assert_no_grep 'data-open=' "$board" "a board rendered without --controls has no control markup"
  assert_grep '<noscript><meta http-equiv="refresh" content="60"' "$board" \
    "a board rendered without --controls keeps its no-script refresh fallback"
  pass "the default board is unchanged by the existence of the reply layer"
}

# The reply layer one row carries: everything from that row's control block up
# to the next one, so an assertion cannot accidentally read a neighbour.
control_block() {  # <board> <home> <id>
  FM_CB_HOME=$2 FM_CB_ID=$3 perl -0777 -ne '
    my $open = "<div class=\"rc\" data-home=\"$ENV{FM_CB_HOME}\" data-id=\"$ENV{FM_CB_ID}\"";
    my $at = index($_, $open);
    exit 1 if $at < 0;
    my $rest = substr($_, $at + length($open));
    my $next = index($rest, "<div class=\"rc\"");
    print $next < 0 ? $rest : substr($rest, 0, $next);
  ' "$1"
}

# Which controls a row gets is the safety-relevant decision: a task-level
# decision has no backlog row behind it, so it has no hold kind to change and
# must not offer to be set aside.
test_controls_match_what_each_row_can_actually_resolve() {
  local snap board block
  snap=$TMP_ROOT/controls.json
  board=$TMP_ROOT/controls.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "the board must render with the controls flag"

  # A main captain decision is a backlog hold: answerable and deferrable.
  block=$(control_block "$board" "main" "d1")
  assert_contains "$block" 'data-open="answer"' "a main captain decision must offer an answer"
  assert_contains "$block" 'data-open="defer"' "a main captain decision must offer to be set aside"

  # A secondmate decision that is a backlog hold behaves the same, in its home.
  block=$(control_block "$board" "ios" "b7")
  assert_contains "$block" 'data-open="answer"' "a secondmate backlog decision must offer an answer"
  assert_contains "$block" 'data-open="defer"' "a secondmate backlog decision must offer to be set aside"

  # A task-level open decision has no backlog row, so setting it aside would
  # name nothing. It carries its decision key so two on one task stay distinct.
  block=$(control_block "$board" "ios" "t9")
  assert_contains "$block" 'data-key="api-shape"' \
    "a task-level decision must carry its decision key, not just its task"
  assert_contains "$block" 'data-open="answer"' "a task-level decision must offer an answer"
  case "$block" in
    *'data-open="defer"'*)
      fail "a task-level decision has no backlog hold to change and must not offer to be set aside" ;;
  esac

  block=$(control_block "$board" "main" "t1")
  assert_contains "$block" 'data-open="merge"' "a PR awaiting the captain must offer a merge request"
  assert_contains "$block" 'data-open="reply"' "a PR awaiting the captain must offer a reply"

  assert_grep 'data-intent="file"' "$board" \
    "the board must offer one composer for a one-shot new-work request"
  assert_grep '>Start something new</h2>' "$board" \
    "the one-shot new-work composer must name its purpose"
  assert_grep 'data-intent="ask"' "$board" \
    "the board must retain the continuing Ask-firstmate composer"
  assert_grep '>Ask firstmate</h2><p>Use the continuing board conversation' "$board" \
    "the conversation composer must stay distinct from new-work intake"

  # The item rows are read-only display and carry no control of their own, so the
  # reply layer must be unchanged by their presence: this snapshot renders a full
  # item row on the alpha card, and every control assertion above still holds.
  assert_grep 'aria-label="Stage 4 of 5: Checks running"' "$board" \
    "an item row must still render with the reply layer on"
  assert_grep '>Opus 5</span>' "$board" \
    "an item row must still name its model with the reply layer on"

  # Every control that can hold the refresh has to say so. The composer is
  # always open, so text left in it holds the board with no form to close.
  holds=$(grep -o 'class="rc-hold"' "$board" | wc -l | tr -d ' ')
  opens=$(grep -o 'class="rc-f" data-toggle' "$board" | wc -l | tr -d ' ')
  [ "$holds" = "$((opens + 2))" ] \
    || fail "each toggled control and both always-open composers must say the refresh is held, got $holds notes for $opens forms"
  pass "each row offers only the controls it can actually resolve"
}

# The whole safety model rests on a control being unable to do anything itself.
test_controls_can_only_queue_a_request() {
  local snap board
  snap=$TMP_ROOT/inert.json
  board=$TMP_ROOT/inert.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "the controls board must render"

  # The only way out of the page is the document its own URL, or the legacy
  # Lavish bridge. A named host, port, or absolute endpoint would mean a control
  # could reach somewhere the captain did not choose to serve this board from.
  assert_grep 'window.location.pathname' "$board" \
    "a request target must be derived from the URL this document was loaded from"
  assert_no_grep '127.0.0.1' "$board" "a control must not carry a hard-coded host"
  assert_no_grep 'localhost' "$board" "a control must not carry a hard-coded host"
  assert_no_grep '4321' "$board" "a control must not carry a hard-coded port"
  assert_no_grep 'XMLHttpRequest' "$board" "a control must not open a legacy transport"
  assert_no_grep 'WebSocket' "$board" "a control must not open a socket"
  assert_no_grep 'method="post"' "$board" "a control must not post from markup"
  ! grep -Eq '<form[^>]*action=' "$board" || fail "a control must not post from markup"
  assert_grep 'queuePrompt' "$board" "the legacy Lavish bridge path is retained"
  assert_grep 'FM-BOARD-REQUEST' "$board" "a recorded request carries the request marker"

  # Hidden by CSS, revealed only once a transport that can actually reach
  # firstmate is proved, so a statically served copy of this same file shows no
  # control at all whichever transport is missing.
  assert_grep '.rc{display:none' "$board" "the reply layer must be hidden by default"
  assert_grep 'body.board-reply .rc,body.lavish .rc{display:block' "$board" \
    "the reply layer must be revealed only for a page with a proved transport"
  assert_grep 'classList.add("board-reply")' "$board" \
    "the reveal must be gated on the reply service answering its probe"
  assert_grep 'classList.add("lavish")' "$board" \
    "the reveal must still be gated on the legacy bridge being present"
  # An explicit display beats [hidden], so without this a closed control stands
  # open and every form on the board shows at once.
  assert_grep '.rc-f[hidden]{display:none' "$board" \
    "a closed control must stay closed against the layer own display rule"

  # The confirmed state ships hidden and EMPTY. Only the script that saw a
  # transport accept the request fills it in, so a statically served copy can
  # never show the captain a confirmation that never happened.
  assert_grep 'class="rc-ok rc-quiet" data-ok="answer" hidden' "$board" \
    "an acknowledged control must have a quiet confirmation banner that ships hidden"
  assert_grep '<strong class="rc-ok-h"></strong>' "$board" \
    "the confirmation banner must ship with no claim in it"
  assert_grep '.rc-ok{flex-basis:100%' "$board" \
    "the confirmation banner must be a full-width replacement, not a small label"

  # The script-managed reload can hold while a control is open.
  # The meta refresh survives only for a page that runs no script, so every
  # occurrence of it has to be the one inside noscript.
  local all inert
  all=$(grep -o '<meta http-equiv="refresh"' "$board" | wc -l | tr -d ' ')
  inert=$(grep -o '<noscript><meta http-equiv="refresh"' "$board" | wc -l | tr -d ' ')
  [ "$inert" = 1 ] \
    || fail "the meta refresh must move into noscript once the reload is managed, got $inert"
  [ "$all" = "$inert" ] \
    || fail "a managed reload must not race a live meta refresh ($all refresh tags, $inert in noscript)"
  pass "a control can only queue a request; it reaches nothing else"
}

test_decision_context_links_and_submission_state_in_a_browser() {
  local snap board read_only reduced shifted missing node_free node_free_bin chrome
  snap=$TMP_ROOT/decision-controls-runtime.json
  board=$TMP_ROOT/decision-controls-runtime.html
  read_only=$TMP_ROOT/decision-controls-readonly.html
  reduced=$TMP_ROOT/decision-controls-reduced.html
  shifted=$TMP_ROOT/decision-controls-shifted.html
  missing=$TMP_ROOT/decision-controls-missing.html
  node_free=$TMP_ROOT/decision-controls-node-free.html
  node_free_bin=$TMP_ROOT/decision-controls-node-free-bin
  snapshot_json '[
    {"state":"queued","id":"d-exact","captain_actionable":true,
     "title":"Choose the prototype emphasis","hold_reason":"Guidance and detail compete for the first screen",
     "decision_question":"Should the prototype lead with guidance before showing raw detail?",
     "decision_options":["Lead with guidance","Lead with raw detail"],
     "decision_url":"https://sample.tailnet.invalid/decision-aid","repo":"sample"},
    {"state":"queued","id":"d-fallback","captain_actionable":true,
     "title":"Choose the comparison layout","hold_reason":"Scanning speed trades off against explanation","repo":"sample"},
    {"state":"queued","id":"d-fact","captain_actionable":true,
     "title":"Supply the prototype cost basis","hold_reason":"The valuation needs its source figure",
     "decision_kind":"fact","decision_expects":"one figure in GBP","repo":"sample"},
    {"state":"queued","id":"local-lane-bakeoff-v2-powered-decision-widen-bounded-judgment-rung",
     "captain_actionable":true,
     "title":"Widen bounded-judgment dispatch rung to include ollama/qwen3.6:35b-fm? data/local-lane-bakeoff-v2-powered/report.md",
     "hold_reason":"The powered benchmark missed the pre-agreed reliability bar.",
     "report_path":"data/local-lane-bakeoff-v2-powered/report.md","repo":"firstmate"},
    {"state":"queued","id":"d-empty","captain_actionable":true,"title":"","hold_reason":"","repo":"sample"},
    {"state":"queued","id":"d-bad-link","captain_actionable":true,
     "title":"Choose without an aid","hold_reason":"The recorded link is unsupported",
     "decision_url":"http://public.invalid/not-supported","repo":"sample"},
    {"state":"queued","id":"d-malformed-link","captain_actionable":true,
     "title":"Choose despite a malformed aid","hold_reason":"The URL has no authority",
     "decision_url":"https://","repo":"sample"},
    {"state":"queued","id":"d-invalid-ipv6","captain_actionable":true,
     "title":"Choose despite an invalid IPv6 aid","hold_reason":"The authority is malformed",
     "decision_url":"https://[::::]/aid","repo":"sample"},
    {"state":"queued","id":"d-valid-ipv6","captain_actionable":true,
     "title":"Choose with an IPv6 aid","hold_reason":"The authority is private IPv6",
     "decision_url":"https://[fd00::1]/aid","repo":"sample"},
    {"state":"queued","id":"d-valid-fqdn","captain_actionable":true,
     "title":"Choose with an absolute FQDN aid","hold_reason":"The terminal root dot is valid",
     "decision_url":"https://decision.example.com./aid","repo":"sample"},
    {"state":"queued","id":"d-invalid-port","captain_actionable":true,
     "title":"Choose despite an invalid port","hold_reason":"The port is out of range",
     "decision_url":"https://example.invalid:99999/aid","repo":"sample"},
    {"state":"queued","id":"d-hostile","captain_actionable":true,
     "title":"Hostile <b>title</b>","hold_reason":"Reason & quote \" stays text",
     "decision_question":"Question \" ><img src=x onerror=alert(1)> stays text?",
     "decision_url":"https://safe.invalid/?q=%22%3E%3Cscript%3E","repo":"sample"}
  ]' '[{
    "id":"ios","registered":true,"provenance":{"selected":"structured-home"},
    "current":{"state":"captain_decision"},"active_children":[],"holds":[],"queued":[],
    "decisions_open":[
      {"id":"d-exact","key":"route","verb":"captain-hold","source":"backlog",
       "summary":"Choose the routed emphasis","reason":"The routed choice has two valid shapes",
       "question":"Which routed shape should lead?","options":["Lead with routed shape","Lead with alternate shape"],
       "decision_url":"https://ios.tailnet.invalid/decision-aid"},
      {"id":"d-exact","key":"route-b","verb":"needs-decision","source":"status",
       "summary":"Which secondary routed shape should follow?","reason":null}
    ],
    "counts":{"active_children":0,"decisions_open":2,"holds":0,"queued":0},"omitted":[]
  }]' | jq '.tasks = [{id:"pr-ready",kind:"ship",project:"sample",model:"claude-opus-5",
    backlog:{title:"Review the ready change",repo:"sample"},
    pr:{url:"https://github.com/example/sample/pull/7"},
    current_state:{state:"done",stage:{ordinal:5,of:5,label:"Checks green",motion:"ready"}}}]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the decision control runtime fixture must render"
  mkdir -p "$node_free_bin"
  ln -sf "$(command -v jq)" "$node_free_bin/jq"
  PATH="$node_free_bin:/usr/bin:/bin" "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$node_free" >/dev/null \
    || fail "valid decision links must render without optional Node"
  assert_grep 'href="https://sample.tailnet.invalid/decision-aid"' "$node_free" \
    "a missing optional Node runtime must not erase a valid private decision aid"
  assert_no_grep 'href="https://\[::::\]/aid"' "$node_free" \
    "jq-owned URL validation must reject malformed IPv6 authorities without Node"
  assert_no_grep 'href="https://example.invalid:99999/aid"' "$node_free" \
    "jq-owned URL validation must reject out-of-range ports without Node"
  "$BOARD" --snapshot "$snap" --no-quota --refresh 300 --out "$read_only" >/dev/null \
    || fail "the read-only decision fixture must render"
  jq '.backlog.records = ([range(0;8) | {state:"queued",id:("inserted-" + tostring),captain_actionable:true,
        title:("New decision " + tostring),hold_reason:"Inserted above the reading anchor",repo:"sample"}]
        + .backlog.records)' "$snap" > "$snap.shifted"
  "$BOARD" --snapshot "$snap.shifted" --no-quota --controls --refresh 300 --out "$shifted" >/dev/null \
    || fail "the shifted reading-position fixture must render"
  jq '.backlog.records |= map(select(.id != "d-fallback"))' "$snap.shifted" > "$snap.missing"
  "$BOARD" --snapshot "$snap.missing" --no-quota --controls --refresh 300 --out "$missing" >/dev/null \
    || fail "the disappeared-anchor fixture must render"
  snapshot_json '[]' '[]' > "$snap.reduced"
  "$BOARD" --snapshot "$snap.reduced" --no-quota --controls --refresh 300 --out "$reduced" >/dev/null \
    || fail "the acknowledgement-retirement fixture must render"

  command -v node >/dev/null 2>&1 || { printf 'skip: node not found for decision-control browser regression\n'; return 0; }
  chrome=$(find_chrome) || { printf 'skip: Chrome or Chromium not found for decision-control browser regression\n'; return 0; }
  node - "$chrome" "$board" "$read_only" "$reduced" "$shifted" "$missing" <<'JS' \
    || fail "decision prompts, links, and submission state failed in a real browser"
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");
const [chromePath, boardPath, readonlyPath, reducedPath, shiftedPath, missingPath] = process.argv.slice(2);
const original = fs.readFileSync(boardPath);
const chrome = spawn(chromePath, ["--headless=new", "--disable-gpu", "--no-sandbox",
  "--remote-debugging-pipe", `--user-data-dir=${boardPath}.runtime-profile`],
  {stdio:["ignore","ignore","ignore","pipe","pipe"]});
let buffer = ""; let nextId = 0; const pending = new Map();
function send(method, params = {}, sessionId) { return new Promise((resolve) => {
  const id = ++nextId; pending.set(id, resolve);
  chrome.stdio[3].write(`${JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})}\0`);
}); }
chrome.stdio[4].on("data", (chunk) => { buffer += chunk; let at;
  while ((at = buffer.indexOf("\0")) >= 0) { const raw = buffer.slice(0, at); buffer = buffer.slice(at + 1);
    if (!raw) continue; const message = JSON.parse(raw); const resolve = pending.get(message.id);
    if (resolve) { pending.delete(message.id); resolve(message); } }
});
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function evaluate(sessionId, expression) {
  const result = await send("Runtime.evaluate", {expression,awaitPromise:true,returnByValue:true}, sessionId);
  if (result.result.exceptionDetails) throw new Error(result.result.exceptionDetails.text);
  return result.result.result.value;
}
async function navigate(sessionId, file, hash = "") {
  const url = pathToFileURL(file); url.hash = hash;
  await send("Page.navigate", {url:url.href}, sessionId);
  for (let i=0;i<100;i++) { if (await evaluate(sessionId,"document.readyState") === "complete") break; await delay(20); }
  await delay(250);
}
async function reload(sessionId) {
  await send("Page.reload", {ignoreCache:true}, sessionId);
  await delay(100);
  for (let i=0;i<100;i++) { if (await evaluate(sessionId,"document.readyState") === "complete") break; await delay(20); }
  await delay(250);
}
function assert(ok, message) { if (!ok) throw new Error(message); }
(async () => {
  const created = await send("Target.createTarget", {url:"about:blank"});
  const attached = await send("Target.attachToTarget", {targetId:created.result.targetId,flatten:true});
  const sid = attached.result.sessionId;
  await send("Page.enable", {}, sid);
  await send("Runtime.enable", {}, sid);
  await send("Page.addScriptToEvaluateOnNewDocument", {source:`
    window.__fmFrameTops=[];
    window.addEventListener('DOMContentLoaded',function(){var left=8; function sample(){
      var target=document.querySelector('[data-scroll-anchor="call:main:d-fallback::decision"]');
      window.__fmFrameTops.push(target?target.getBoundingClientRect().top:null);
      if(--left>0)requestAnimationFrame(sample);
    } requestAnimationFrame(sample);});
    window.lavish={
      queuePrompt:function(prompt,options){
        if(localStorage.getItem("test-bridge-fail")==="1") throw new Error("queue failed");
        function accept(){
          var p=JSON.parse(localStorage.getItem("test-prompts")||"[]");
          var item={prompt:prompt,key:options&&options.queueKey||""};
          var at=item.key?p.findIndex(x=>x.key===item.key):-1;
          if(at===-1)p.push(item);else p[at]=item;
          localStorage.setItem("test-prompts",JSON.stringify(p)); return true;
        }
        // Keep acceptance pending until the reload destroys this document.
        if(localStorage.getItem("test-queue-delay")==="1") return new Promise(()=>{});
        return accept();
      },
      sendQueuedPrompts:function(){
        if(localStorage.getItem("test-send-fail")==="1") throw new Error("send failed");
        if(localStorage.getItem("test-delivery-unconfirmed")==="1") return undefined;
        return true;
      }
    };`}, sid);
  await navigate(sid, boardPath);
  async function themeRoles(scheme) {
    await send("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:scheme}]}, sid);
    return evaluate(sid, `(() => {
      const root=getComputedStyle(document.documentElement);
      const color=(name)=>root.getPropertyValue(name).trim();
      const liveProbe=Object.assign(document.body.appendChild(document.createElement('span')),{className:'dot'});
      const blockedProbe=Object.assign(document.body.appendChild(document.createElement('p')),{className:'rc-form-error'});
      const answerProbe=document.querySelector('.rc-answer');
      const roles={
        bg:color('--bg'),panel:color('--panel'),ink:color('--ink'),line:color('--line'),
        needs:color('--needs-you'),live:color('--live'),blocked:color('--blocked'),accent:color('--accent'),
        body:getComputedStyle(document.body).backgroundColor,
        decisionBand:getComputedStyle(document.querySelector('.band')).backgroundColor,
        liveDot:getComputedStyle(liveProbe).backgroundColor,
        blockedBar:getComputedStyle(blockedProbe).color,
        primary:getComputedStyle(document.querySelector('.rc-go')).backgroundColor,
        answerInk:getComputedStyle(answerProbe).color,
        answerSoft:getComputedStyle(answerProbe).backgroundColor
      };
      liveProbe.remove();blockedProbe.remove();return roles;
    })()`);
  }
  async function composerLayout(scheme, width, height, mobile) {
    await send("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:scheme}]}, sid);
    await send("Emulation.setDeviceMetricsOverride", {width,height,deviceScaleFactor:1,mobile}, sid);
    return evaluate(sid, `(() => {
      function block(selector) {
        const card=document.querySelector(selector);const rect=card.getBoundingClientRect();
        const field=card.querySelector('textarea');const input=field.getBoundingClientRect();
        return {left:Math.round(rect.left),right:Math.round(rect.right),top:Math.round(rect.top),
          bottom:Math.round(rect.bottom),width:Math.round(rect.width),label:card.querySelector('h2').textContent,
          background:getComputedStyle(card).backgroundImage,inputLabel:field.getAttribute('aria-label'),
          inputDisplay:getComputedStyle(field).display,
          inputInside:input.top>=rect.top&&input.bottom<=rect.bottom};
      }
      const file=block('.rc-file');const ask=block('.rc-ask');
      return {file,ask,gap:ask.top-file.bottom,
        overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth};
    })()`);
  }
  function assertComposerLayout(layout, scheme, width) {
    assert(layout.file.label === "Start something new" && layout.ask.label === "Ask firstmate"
      && layout.file.background !== layout.ask.background && layout.gap >= 20
      && !layout.overflow && layout.file.left >= 0 && layout.file.right <= width
      && layout.ask.left >= 0 && layout.ask.right <= width
      && layout.file.inputLabel === "Describe the new work" && layout.file.inputDisplay !== "none"
      && layout.file.inputInside && layout.ask.inputLabel === "Ask firstmate"
      && layout.ask.inputDisplay !== "none" && layout.ask.inputInside,
      `the visible board-level composer inputs did not fit inside their labelled cards at ${width}px in ${scheme} mode: `
        + JSON.stringify(layout));
  }
  function channels(value) {
    if (/^#[0-9a-f]{6}$/i.test(value)) {
      return [value.slice(1,3),value.slice(3,5),value.slice(5,7)].map(x=>parseInt(x,16));
    }
    const match=value.match(/[\d.]+/g);
    if (!match || match.length < 3) throw new Error('unreadable computed colour: '+value);
    return match.slice(0,3).map(Number);
  }
  function sameColor(left,right) {
    return JSON.stringify(channels(left)) === JSON.stringify(channels(right));
  }
  function contrast(left,right) {
    const luminance=(value)=>{
      const linear=channels(value).map(x=>x/255).map(x=>x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4));
      return .2126*linear[0]+.7152*linear[1]+.0722*linear[2];
    };
    const a=luminance(left),b=luminance(right);
    return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
  }
  const darkTheme=await themeRoles('dark');
  const lightTheme=await themeRoles('light');
  for (const [name,roles] of Object.entries({darkTheme,lightTheme})) {
    assert(roles.needs === roles.accent, name+' does not map needs-you to the single accent role');
    assert(sameColor(roles.decisionBand,roles.needs) && sameColor(roles.primary,roles.accent),
      name+' does not reserve the accent for decisions and primary actions: '+JSON.stringify(roles));
    assert(sameColor(roles.liveDot,roles.live) && sameColor(roles.blockedBar,roles.blocked),
      name+' does not distinguish live and blocked states through their semantic roles: '+JSON.stringify(roles));
    assert(contrast(roles.ink,roles.panel) >= 7 && contrast(roles.accent,roles.panel) >= 4.5,
      name+' misses executive-text or accent contrast: '+JSON.stringify(roles));
    assert(contrast(roles.answerInk,roles.answerSoft) >= 4.5,
      name+' misses Answer control contrast: '+JSON.stringify(roles));
  }
  assert(darkTheme.bg !== lightTheme.bg && darkTheme.panel !== lightTheme.panel,
    'dark and light preferences did not produce distinct rendered themes');
  for (const scheme of ['light','dark']) {
    const desktopComposers=await composerLayout(scheme,1280,900,false);
    assertComposerLayout(desktopComposers,scheme,1280);
    assert(desktopComposers.file.width > 500 && desktopComposers.ask.width > 500,
      `the board-level composers were not desktop width in ${scheme} mode: ${JSON.stringify(desktopComposers)}`);
  }
  await send("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:"light"}]}, sid);
  const dom = await evaluate(sid, `(() => {
    function block(home,id){return [...document.querySelectorAll('.rc')].find(x=>x.dataset.home===home&&x.dataset.id===id);}
    function answer(home,id){return block(home,id).querySelector('form[data-intent=answer] textarea');}
    return {
      exact:[answer('main','d-exact').placeholder,answer('main','d-exact').getAttribute('aria-label')],
      options:[...block('main','d-exact').querySelectorAll('[data-answer-choice]')].map(x=>({text:x.textContent,display:getComputedStyle(x).display})),
      custom:block('main','d-exact').querySelector('[data-open=answer]').innerText,
      legacyOptions:block('main','d-fallback').querySelectorAll('[data-answer-choice]').length,
      fact:{labels:[...block('main','d-fact').querySelectorAll('.rc-fact-l,.rc-fact-v')].map(x=>x.textContent),
        choices:block('main','d-fact').querySelectorAll('[data-answer-choice]').length,
        prompt:answer('main','d-fact').placeholder},
      legacyFact:block('main','d-fallback').querySelectorAll('.rc-fact').length,
      fallback:answer('main','d-fallback').placeholder,
      empty:answer('main','d-empty').placeholder,
      hostile:answer('main','d-hostile').placeholder,
      injectedImages:document.querySelectorAll('img[src="x"]').length,
      aids:[...document.querySelectorAll('.decision-aid')].map(a=>a.href),
      badAid:!!block('main','d-bad-link').closest('.need-wrap').querySelector('.decision-aid'),
      malformedAid:!!block('main','d-malformed-link').closest('.need-wrap').querySelector('.decision-aid'),
      invalidIpv6Aid:!!block('main','d-invalid-ipv6').closest('.need-wrap').querySelector('.decision-aid'),
      validIpv6Aid:!!block('main','d-valid-ipv6').closest('.need-wrap').querySelector('.decision-aid'),
      validFqdnAid:!!block('main','d-valid-fqdn').closest('.need-wrap').querySelector('.decision-aid'),
      invalidPortAid:!!block('main','d-invalid-port').closest('.need-wrap').querySelector('.decision-aid'),
      localReport:(()=>{var row=block('main','local-lane-bakeoff-v2-powered-decision-widen-bounded-judgment-rung').closest('.need-wrap');
        var ref=row.querySelector('.local-ref'); return {text:ref&&ref.textContent,anchor:!!row.querySelector('a[href="data/local-lane-bakeoff-v2-powered/report.md"]')};})(),
      cards:document.querySelectorAll('.need-wrap').length
    };
  })()`);
  assert(dom.exact[0] === "Should the prototype lead with guidance before showing raw detail?", "exact question was not the answer prompt");
  assert(dom.exact[1] === "Your answer", "the answer textarea lost its accessible label");
  assert(JSON.stringify(dom.options) === JSON.stringify([
      {text:"Lead with guidance",display:"none"},{text:"Lead with raw detail",display:"none"}])
    && dom.custom === "Answer" && dom.legacyOptions === 0,
    "Lavish did not preserve its legacy Answer-only view: " + JSON.stringify(dom));
  assert(JSON.stringify(dom.fact.labels) === JSON.stringify(["Fact needed","Expected answer: one figure in GBP"])
    && dom.fact.choices === 0 && dom.fact.prompt === "Supply the prototype cost basis - The valuation needs its source figure",
    "fact intake was not explicitly labelled without inventing answer choices: " + JSON.stringify(dom.fact));
  assert(dom.legacyFact === 0,
    "a decision without kind gained inferred fact-intake framing: " + JSON.stringify(dom));
  assert(dom.fallback === "Choose the comparison layout - Scanning speed trades off against explanation", "decision context fallback was not specific");
  assert(dom.empty === "Your answer", "an empty decision invented context");
  assert(dom.hostile === 'Question " ><img src=x onerror=alert(1)> stays text?' && dom.injectedImages === 0, "hostile question escaped its text context");
  assert(dom.aids.includes("https://sample.tailnet.invalid/decision-aid") && dom.aids.includes("https://ios.tailnet.invalid/decision-aid"), "main or secondmate decision aid was missing");
  assert(dom.aids.includes("https://safe.invalid/?q=%22%3E%3Cscript%3E") && dom.validIpv6Aid && dom.validFqdnAid && !dom.badAid && !dom.malformedAid
    && !dom.invalidIpv6Aid && !dom.invalidPortAid, "valid hostile text or malformed link handling was wrong");
  assert(dom.localReport.text === "Local report: data/local-lane-bakeoff-v2-powered/report.md" && !dom.localReport.anchor,
    "the Qwen bounded-judgment report path was not preserved as non-clickable context");
  assert(dom.cards >= 8, "ordinary multi-card decision list did not render");

  await send("Emulation.setDeviceMetricsOverride", {width:1280,height:900,deviceScaleFactor:1,mobile:false}, sid);
  const wideOptions = await evaluate(sid, `(() => ({buttons:[...document.querySelectorAll('[data-answer-choice]')]
    .map(x=>getComputedStyle(x).display),answer:[...document.querySelectorAll('[data-answer-custom]')]
    .map(x=>x.innerText)}))()`);
  assert(wideOptions.buttons.every(x=>x==="none") && wideOptions.answer.every(x=>x==="Answer"),
    "Lavish exposed direct-board answer controls at 1280px: "+JSON.stringify(wideOptions));
  const wideFact = await evaluate(sid, `(() => {var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fact');
    b.querySelector('[data-open=answer]').click();var hint=b.querySelector('.rc-fact');hint.scrollIntoView({block:'center'});
    var r=hint.getBoundingClientRect();return {left:r.left,right:r.right,display:getComputedStyle(hint).display,
      overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth};})()`);
  assert(wideFact.display === "flex" && wideFact.left >= 0 && wideFact.right <= 1280 && !wideFact.overflow,
    "fact-intake hint was not legible at 1280px: "+JSON.stringify(wideFact));

  await send("Emulation.setDeviceMetricsOverride", {width:390,height:844,deviceScaleFactor:1,mobile:true}, sid);
  const narrowOptions = await evaluate(sid, `(() => ({buttons:[...document.querySelectorAll('[data-answer-choice]')]
    .map(x=>getComputedStyle(x).display),answer:[...document.querySelectorAll('[data-answer-custom]')]
    .map(x=>x.innerText)}))()`);
  assert(narrowOptions.buttons.every(x=>x==="none") && narrowOptions.answer.every(x=>x==="Answer"),
    "Lavish exposed direct-board answer controls at 390px: "+JSON.stringify(narrowOptions));
  const narrowFact = await evaluate(sid, `(() => {var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fact');
    var hint=b.querySelector('.rc-fact');hint.scrollIntoView({block:'center'});var r=hint.getBoundingClientRect();
    return {left:r.left,right:r.right,label:hint.querySelector('.rc-fact-l').textContent,
      expects:hint.querySelector('.rc-fact-v').textContent,
      overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth};})()`);
  assert(narrowFact.left >= 0 && narrowFact.right <= 390 && !narrowFact.overflow
    && narrowFact.label === "Fact needed" && narrowFact.expects === "Expected answer: one figure in GBP",
    "fact-intake hint overflowed or became illegible at 390px: "+JSON.stringify(narrowFact));
  await evaluate(sid, `var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fact');b.querySelector('.rc-x').click();`);
  await send("Emulation.setTouchEmulationEnabled", {enabled:true,maxTouchPoints:1}, sid);
  for (const scheme of ['light','dark']) {
    assertComposerLayout(await composerLayout(scheme,390,844,true),scheme,390);
  }
  await send("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:"light"}]}, sid);
  const mobileTap = await evaluate(sid, `(() => {var ref=document.querySelector('.local-ref'); ref.scrollIntoView({block:'center'});
    var r=ref.getBoundingClientRect(); return {x:r.left+r.width/2,y:r.top+r.height/2,before:location.href,anchor:!!ref.closest('a')};})()`);
  assert(!mobileTap.anchor && mobileTap.x >= 0 && mobileTap.x <= 390 && mobileTap.y >= 0 && mobileTap.y <= 844,
    "the Qwen local report context was not a visible non-link mobile target");
  await send("Input.dispatchTouchEvent", {type:"touchStart",touchPoints:[{x:mobileTap.x,y:mobileTap.y}]}, sid);
  await send("Input.dispatchTouchEvent", {type:"touchEnd",touchPoints:[]}, sid);
  await delay(100);
  assert(await evaluate(sid,"location.href") === mobileTap.before, "a real mobile tap on the local Qwen report path navigated away from /mission");
  await send("Emulation.setTouchEmulationEnabled", {enabled:false}, sid);
  await send("Emulation.clearDeviceMetricsOverride", {}, sid);

  await navigate(sid, readonlyPath);
  assert(await evaluate(sid,"document.querySelectorAll('.rc').length") === 0, "controls appeared when disabled");
  await navigate(sid, boardPath);
  await evaluate(sid, `localStorage.removeItem('test-prompts'); localStorage.removeItem('test-bridge-fail');`);

  const draftBefore = await evaluate(sid, `(async()=>{
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback');
    b.querySelector('[data-open=answer]').click(); var t=b.querySelector('textarea');
    t.value='Draft survives an external artifact replacement'; t.dispatchEvent(new Event('input',{bubbles:true}));
    var anchor=b.closest('.need-wrap'); anchor.scrollIntoView({block:'center'}); window.scrollBy(0,47);
    await new Promise(r=>setTimeout(r,140)); return {top:anchor.getBoundingClientRect().top,tab:document.documentElement.className};
  })()`);
  fs.copyFileSync(shiftedPath, boardPath);
  await reload(sid);
  const draftOne = await evaluate(sid, `(() => {var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback');
    return {value:b.querySelector('textarea').value,open:!b.querySelector('form[data-intent=answer]').hidden,
      top:b.closest('.need-wrap').getBoundingClientRect().top,tab:document.documentElement.className,
      view:sessionStorage.getItem(window.__fmViewKey),explicit:window.__fmExplicitNavigation,hash:location.hash};})()`);
  assert(draftOne.value === 'Draft survives an external artifact replacement' && draftOne.open,
    'an external file rewrite discarded the open draft or composer identity');
  assert(draftOne.tab.includes('t-decisions') && Math.abs(draftOne.top-draftBefore.top)<=3,
    'an external file rewrite lost the active tab or stable reading position: '+JSON.stringify({draftBefore,draftOne}));
  fs.copyFileSync(missingPath, boardPath);
  await reload(sid);
  const absentDraft = await evaluate(sid, `JSON.parse(sessionStorage.getItem('fm-mission-control-drafts-v1:'+window.__fmBoardScope)||'[]')
    .find(x=>decodeURIComponent(x.identity.split(':')[1])==='d-fallback')`);
  assert(absentDraft && absentDraft.note === 'Draft survives an external artifact replacement' && absentDraft.open,
    'a temporarily omitted item erased its unmatched stored draft identity');
  fs.writeFileSync(boardPath, original);
  await reload(sid);
  const draftTwo = await evaluate(sid, `(() => {var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback');
    return {value:b.querySelector('textarea').value,open:!b.querySelector('form[data-intent=answer]').hidden};})()`);
  assert(draftTwo.value === 'Draft survives an external artifact replacement' && draftTwo.open,
    'a second file rewrite discarded the restored draft');
  await evaluate(sid, `var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback'); b.querySelector('.rc-x').click();`);

  const success = await evaluate(sid, `(async()=>{
    function block(home,id,key=''){return [...document.querySelectorAll('.rc')].find(x=>x.dataset.home===home&&x.dataset.id===id&&x.dataset.key===key);}
    var a=block('main','d-exact'); a.querySelector('[data-open=answer]').click();
    a.querySelector('textarea').value='Lead with guidance'; a.querySelector('form[data-intent=answer]').requestSubmit();
    await new Promise(r=>setTimeout(r,20));
    var p=block('main','pr-ready'); p.querySelector('[data-open=merge]').click(); p.querySelector('form[data-intent=merge]').requestSubmit();
    await new Promise(r=>setTimeout(r,20));
    var routed=block('ios','d-exact','route'); routed.querySelector('[data-open=answer]').click();
    routed.querySelector('textarea').value='Lead with the routed shape'; routed.querySelector('form[data-intent=answer]').requestSubmit();
    await new Promise(r=>setTimeout(r,20));
    var routedB=block('ios','d-exact','route-b'); routedB.querySelector('[data-open=answer]').click();
    routedB.querySelector('textarea').value='Use the secondary routed shape'; routedB.querySelector('form[data-intent=answer]').requestSubmit();
    await new Promise(r=>setTimeout(r,20));
    p.querySelector('[data-open=reply]').click(); p.querySelector('textarea').value='Keep the PR open for review';
    p.querySelector('form[data-intent=reply]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    a.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    return {answer:a.querySelector('[data-open=answer]').textContent,answerDisabled:a.querySelector('[data-open=answer]').disabled,
      answerClosed:a.querySelector('form[data-intent=answer]').hidden,
      answerMessage:a.querySelector('.rc-sent').textContent,
      merge:p.querySelector('[data-open=merge]').textContent,mergeDisabled:p.querySelector('[data-open=merge]').disabled,
      reply:p.querySelector('[data-open=reply]').textContent,
      routed:routed.querySelector('[data-open=answer]').textContent,
      routedB:routedB.querySelector('[data-open=answer]').textContent,
      choices:[...a.querySelectorAll('[data-answer-choice]')].map(x=>({hidden:x.hidden,disabled:x.disabled})),
      lavish:!!window.lavish,body:document.body.className,
      wires:JSON.parse(localStorage.getItem('test-prompts')||'[]').map(x=>JSON.parse(x.prompt.slice('FM-BOARD-REQUEST '.length)))};
  })()`);
  assert(success.answer === "Answer sent" && success.answerDisabled && success.answerClosed, "accepted answer was not acknowledged and closed: " + JSON.stringify(success));
  assert(success.merge === "Merge request sent" && success.mergeDisabled && success.reply === "Reply sent", "PR intents did not keep distinct acknowledgement identities");
  assert(success.routed === "Answer sent" && success.routedB === "Answer sent", "home or decision-key acknowledgement identities collided");
  assert(success.choices.every(x=>x.hidden&&x.disabled), "acknowledging a quick answer left its sibling buttons actionable");
  var quickWire=success.wires.find(x=>x.home==='main'&&x.id==='d-exact');
  var textWire=success.wires.find(x=>x.home==='ios'&&x.id==='d-exact'&&x.key==='route');
  assert(success.wires.length === 5 && quickWire.intent==='answer' && quickWire.note==='Lead with guidance'
    && textWire.intent==='answer' && textWire.note==='Lead with the routed shape',
    "quick and free-text answers did not share the Answer wire path: "+JSON.stringify(success.wires));

  await send("Emulation.setDeviceMetricsOverride", {width:1280,height:844,deviceScaleFactor:1,mobile:false}, sid);
  const unconfirmed = await evaluate(sid, `(async()=>{
    localStorage.setItem('test-delivery-unconfirmed','1');
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-hostile');
    b.querySelector('[data-open=answer]').click(); b.querySelector('textarea').value='Queue this exact answer';
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    var beforeDuplicate=JSON.parse(localStorage.getItem('test-prompts')||'[]').length;
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    var stored=[...Array(localStorage.length)].map((_,i)=>localStorage.key(i))
      .filter(k=>k&&k.startsWith('fm-mission-control-ack-v1:')&&localStorage.getItem(k)==='queued');
    localStorage.removeItem('test-delivery-unconfirmed');
    var panel=b.querySelector('[data-ok=answer]');
    return {label:b.querySelector('[data-open=answer]').textContent,message:b.querySelector('.rc-sent').textContent,
      banner:panel.querySelector('.rc-ok-h').textContent,note:panel.querySelector('.rc-ok-s').textContent,
      tone:panel.className,disabled:b.querySelector('[data-open=answer]').disabled,stored:stored.length,
      beforeDuplicate,afterDuplicate:JSON.parse(localStorage.getItem('test-prompts')||'[]').length};
  })()`);
  assert(unconfirmed.label === 'Answer queued' && unconfirmed.message === 'Answer queued for firstmate.'
    && unconfirmed.banner === 'Answer queued'
    && unconfirmed.note.startsWith('No action is needed from you right now.')
    && unconfirmed.note.includes('queued for firstmate')
    && unconfirmed.tone.includes('rc-quiet') && !unconfirmed.tone.includes('rc-needs-you')
    && unconfirmed.disabled && unconfirmed.stored === 1
    && unconfirmed.beforeDuplicate === unconfirmed.afterDuplicate,
    'a queued answer lost its quiet no-action-needed treatment, was reported as sent, or duplicated: '+JSON.stringify(unconfirmed));
  await send("Emulation.setDeviceMetricsOverride", {width:390,height:844,deviceScaleFactor:1,mobile:true}, sid);
  const queuedNarrow = await evaluate(sid, `(() => {var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-hostile');
    var panel=b.querySelector('[data-ok=answer]');panel.scrollIntoView({block:'center'});var rect=panel.getBoundingClientRect();
    return {left:rect.left,right:rect.right,tone:panel.className,note:panel.querySelector('.rc-ok-s').textContent,
      overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth};})()`);
  assert(queuedNarrow.left >= 0 && queuedNarrow.right <= 390 && !queuedNarrow.overflow
    && queuedNarrow.tone.includes('rc-quiet') && queuedNarrow.note.includes('queued for firstmate'),
    'the queued quiet banner overflowed or changed tone at 390px: '+JSON.stringify(queuedNarrow));
  await send("Emulation.clearDeviceMetricsOverride", {}, sid);

  const asynchronous = await evaluate(sid, `(async()=>{
    localStorage.setItem('test-queue-delay','1');
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-empty');
    b.querySelector('[data-open=answer]').click(); var t=b.querySelector('textarea'); t.value='Frozen asynchronous answer';
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    var saved=JSON.parse(sessionStorage.getItem('fm-mission-control-drafts-v1:'+window.__fmBoardScope)||'[]')
      .find(x=>decodeURIComponent(x.identity.split(':')[1])==='d-empty');
    return {value:t.value,textLocked:t.disabled,closeLocked:b.querySelector('.rc-x').disabled,
      submitLocked:b.querySelector('.rc-go').disabled,saved,prompts:JSON.parse(localStorage.getItem('test-prompts')||'[]').length};
  })()`);
  assert(asynchronous.value === 'Frozen asynchronous answer' && asynchronous.textLocked
    && asynchronous.closeLocked && asynchronous.submitLocked && asynchronous.saved
    && asynchronous.saved.queued && asynchronous.saved.queued.status === 'queuing'
    && typeof asynchronous.saved.queued.attempt === 'string' && asynchronous.saved.queued.attempt,
    'an asynchronous enqueue attempt was not frozen and durably bound before acceptance: '+JSON.stringify(asynchronous));
  await reload(sid);
  const asynchronousRetry = await evaluate(sid, `(async()=>{
    localStorage.removeItem('test-queue-delay');
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-empty'); var t=b.querySelector('textarea');
    var restored={value:t.value,textLocked:t.disabled,closeLocked:b.querySelector('.rc-x').disabled,
      retry:!b.querySelector('.rc-go').disabled};
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    var prompts=JSON.parse(localStorage.getItem('test-prompts')||'[]');
    return {restored,label:b.querySelector('[data-open=answer]').textContent,
      prompts:prompts.length,key:prompts.length&&prompts[prompts.length-1].key};
  })()`);
  assert(asynchronousRetry.restored.value === 'Frozen asynchronous answer' && asynchronousRetry.restored.textLocked
    && asynchronousRetry.restored.closeLocked && asynchronousRetry.restored.retry
    && asynchronousRetry.label === 'Answer sent' && asynchronousRetry.prompts === asynchronous.prompts + 1
    && asynchronousRetry.key === asynchronous.saved.queued.attempt,
    'reload during asynchronous queue acceptance re-queued or changed the frozen answer: '+JSON.stringify({asynchronous,asynchronousRetry}));

  const failed = await evaluate(sid, `(async()=>{
    localStorage.setItem('test-send-fail','1');
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback');
    b.querySelector('[data-open=answer]').click(); var t=b.querySelector('textarea'); t.value='Keep comparison compact';
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    var failed={open:!b.querySelector('form[data-intent=answer]').hidden,value:t.value,
      retry:!b.querySelector('.rc-go').disabled,message:b.querySelector('.rc-sent').textContent,
      textLocked:t.disabled,closeLocked:b.querySelector('.rc-x').disabled};
    failed.queued=JSON.parse(localStorage.getItem('test-prompts')||'[]').length;
    failed.saved=JSON.parse(sessionStorage.getItem('fm-mission-control-drafts-v1:'+window.__fmBoardScope)||'[]')
      .find(x=>decodeURIComponent(x.identity.split(':')[1])==='d-fallback');
    return failed;
  })()`);
  assert(failed.open && failed.value === "Keep comparison compact" && failed.retry
    && failed.message.startsWith("Queued but not sent") && failed.textLocked && failed.closeLocked,
    "a queued-but-unsent answer was not visibly preserved and retryable");
  assert(failed.saved && failed.saved.queued && failed.saved.queued.note === 'Keep comparison compact',
    'the queued payload was not persisted under its exact draft identity: '+JSON.stringify(failed));

  await reload(sid);
  const retried = await evaluate(sid, `(async()=>{
    var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='d-fallback'); var t=b.querySelector('textarea');
    var restored={open:!b.querySelector('form[data-intent=answer]').hidden,value:t.value,
      textLocked:t.disabled,closeLocked:b.querySelector('.rc-x').disabled,retry:!b.querySelector('.rc-go').disabled};
    localStorage.removeItem('test-send-fail');
    t.value='Edited answer that was never queued'; b.querySelector('form[data-intent=answer]').requestSubmit();
    await new Promise(r=>setTimeout(r,20));
    var afterEdit={value:t.value,label:b.querySelector('[data-open=answer]').textContent,
      queued:JSON.parse(localStorage.getItem('test-prompts')||'[]').length};
    b.querySelector('form[data-intent=answer]').requestSubmit(); await new Promise(r=>setTimeout(r,20));
    return {restored,afterEdit,after:b.querySelector('[data-open=answer]').textContent,
      afterQueued:JSON.parse(localStorage.getItem('test-prompts')||'[]').length};
  })()`);
  assert(retried.restored.open && retried.restored.value === 'Keep comparison compact' && retried.restored.textLocked
    && retried.restored.closeLocked && retried.restored.retry, 'reload did not restore the locked queued answer: '+JSON.stringify(retried));
  assert(retried.afterEdit.value === "Keep comparison compact" && retried.afterEdit.label === "Answer",
    "edited text replaced or acknowledged the older queued answer: " + JSON.stringify(retried));
  assert(retried.after === "Answer sent", "retry of the exact queued answer was not acknowledged");
  assert(failed.queued === retried.afterEdit.queued && failed.queued === retried.afterQueued,
    "retry after a partial bridge failure queued a duplicate request: " + JSON.stringify({failed,retried}));

  await navigate(sid, boardPath);
  const restored = await evaluate(sid, `(() => {var all=[...document.querySelectorAll('.rc')]; var pr=all.find(x=>x.dataset.id==='pr-ready'); return {
    answer:all.find(x=>x.dataset.home==='main'&&x.dataset.id==='d-exact').querySelector('[data-open=answer]').textContent,
    routed:all.find(x=>x.dataset.home==='ios'&&x.dataset.key==='route').querySelector('[data-open=answer]').textContent,
    routedB:all.find(x=>x.dataset.home==='ios'&&x.dataset.key==='route-b').querySelector('[data-open=answer]').textContent,
    merge:pr.querySelector('[data-open=merge]').textContent,reply:pr.querySelector('[data-open=reply]').textContent};})()`);
  assert(restored.answer === "Answer sent" && restored.routed === "Answer sent" && restored.routedB === "Answer sent"
    && restored.merge === "Merge request sent" && restored.reply === "Reply sent",
    "acknowledgements did not survive managed page reload under each exact identity");

  fs.copyFileSync(reducedPath, boardPath);
  await navigate(sid, boardPath);
  const stale = await evaluate(sid, `[...Array(localStorage.length)].map((_,i)=>localStorage.key(i)).filter(k=>k.startsWith('fm-mission-control-ack-v1:'))`);
  assert(stale.length === 0, "acknowledgements survived after their actionable items disappeared: "+JSON.stringify(stale));

  fs.writeFileSync(boardPath, original);
  await navigate(sid, boardPath);
  await evaluate(sid, `document.getElementById('tab-projects').click();
    history.replaceState(null,'',location.pathname+location.search); window.__fmSaveView();
    sessionStorage.setItem(window.__fmReloadKey,'reload');`);
  await navigate(sid, boardPath);
  assert(await evaluate(sid,"document.documentElement.classList.contains('t-projects')"), "active tab did not survive managed reload");

  const beforeAnchor = await evaluate(sid, `(async()=>{
    document.getElementById('tab-decisions').click();
    var target=document.querySelector('[data-scroll-anchor="call:main:d-fallback::decision"]');
    target.scrollIntoView({block:'center'}); window.scrollBy(0,73); await new Promise(r=>requestAnimationFrame(r));
    window.__fmSaveView(); sessionStorage.setItem(window.__fmReloadKey,'reload');
    return target.getBoundingClientRect().top;
  })()`);
  fs.copyFileSync(shiftedPath, boardPath);
  await reload(sid);
  const afterAnchorState = await evaluate(sid,"({top:document.querySelector('[data-scroll-anchor=\\\"call:main:d-fallback::decision\\\"]').getBoundingClientRect().top,hash:location.hash,frames:window.__fmFrameTops})");
  const afterAnchor = afterAnchorState.top;
  assert(Math.abs(afterAnchor - beforeAnchor) <= 3, `stable reading anchor shifted from ${beforeAnchor} to ${afterAnchor}`);
  assert(afterAnchorState.hash === '#tab=decisions', 'an internally generated tab fragment did not survive the external reload regression');
  assert(afterAnchorState.frames.filter(x=>typeof x==='number').every(x=>Math.abs(x-beforeAnchor)<=3),
    'the reading anchor visibly jumped during early refresh frames: '+JSON.stringify({beforeAnchor,afterAnchorState}));

  await evaluate(sid, `window.scrollTo(0,700); window.__fmSaveView(); sessionStorage.setItem(window.__fmReloadKey,'reload');`);
  await navigate(sid, readonlyPath);
  await navigate(sid, boardPath, "tab=projects");
  const explicit = await evaluate(sid,"({projects:document.documentElement.classList.contains('t-projects'),y:scrollY})");
  assert(explicit.projects && explicit.y < 5, "explicit tab navigation was dragged to an old scroll offset: " + JSON.stringify(explicit));

  const fallbackY = await evaluate(sid, `(async()=>{
    document.getElementById('tab-decisions').click(); history.replaceState(null,'',location.pathname+location.search);
    var target=document.querySelector('[data-scroll-anchor="call:main:d-fallback::decision"]');
    target.scrollIntoView({block:'center'}); window.scrollBy(0,61); await new Promise(r=>requestAnimationFrame(r));
    window.__fmSaveView(); sessionStorage.setItem(window.__fmReloadKey,'reload'); return scrollY;
  })()`);
  fs.copyFileSync(missingPath, boardPath);
  await reload(sid);
  const fallback = await evaluate(sid,"({y:scrollY,max:Math.max(0,document.documentElement.scrollHeight-innerHeight)})");
  assert(Math.abs(fallback.y - Math.min(fallbackY,fallback.max)) <= 3, "disappeared anchor did not use the clamped scroll fallback: " + JSON.stringify({fallbackY,...fallback}));

  const opened = await evaluate(sid, `(async()=>{
    document.getElementById('tab-decisions').click(); var b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='inserted-0');
    b.querySelector('[data-open=answer]').click(); await new Promise(r=>setTimeout(r,30));
    return {focused:document.activeElement===b.querySelector('textarea'),open:!b.querySelector('form[data-intent=answer]').hidden};
  })()`);
  assert(opened.focused && opened.open, "a newly opened control was displaced by stale scroll restoration");
})().finally(() => { fs.writeFileSync(boardPath, original); chrome.kill(); }).catch((error) => { console.error(error.stack||error); process.exitCode=1; });
JS
  pass "decision prompts, private links, and reply acknowledgements behave coherently in a browser"
}

test_live_fleet_mobile_refresh_keeps_reading_position() {
  local live_home=${FM_MISSION_CONTROL_LIVE_HOME:-} board chrome
  if [ -z "$live_home" ]; then
    [ "${FM_MISSION_CONTROL_REQUIRE_LIVE:-0}" = 1 ] \
      && fail "FM_MISSION_CONTROL_LIVE_HOME is required for the live-fleet browser regression"
    printf 'skip: FM_MISSION_CONTROL_LIVE_HOME not set for live-fleet browser regression\n'
    return 0
  fi
  [ -f "$live_home/data/backlog.md" ] \
    || fail "FM_MISSION_CONTROL_LIVE_HOME has no live backlog"
  command -v node >/dev/null 2>&1 \
    || fail "node is required for the live-fleet browser regression"
  chrome=$(find_chrome) \
    || fail "Chrome or Chromium is required for the live-fleet browser regression"
  board=$TMP_ROOT/live-fleet-mobile-refresh.html
  FM_HOME="$live_home" "$BOARD" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the live fleet board did not render"

  node - "$chrome" "$board" "$BOARD" "$live_home" <<'JS' \
    || fail "the privacy-safe live-fleet mobile refresh regression failed"
const { spawn, spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const [chromePath, boardPath, boardBin, liveHome] = process.argv.slice(2);
const chrome = spawn(chromePath, ["--headless=new", "--disable-gpu", "--no-sandbox",
  "--remote-debugging-pipe", `--user-data-dir=${boardPath}.live-profile`],
  {stdio:["ignore","ignore","ignore","pipe","pipe"]});
let buffer = ""; let nextId = 0; const pending = new Map();
function send(method, params = {}, sessionId) { return new Promise((resolve) => {
  const id = ++nextId; pending.set(id, resolve);
  chrome.stdio[3].write(`${JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})}\0`);
}); }
chrome.stdio[4].on("data", (chunk) => { buffer += chunk; let at;
  while ((at = buffer.indexOf("\0")) >= 0) { const raw = buffer.slice(0, at); buffer = buffer.slice(at + 1);
    if (!raw) continue; const message = JSON.parse(raw); const resolve = pending.get(message.id);
    if (resolve) { pending.delete(message.id); resolve(message); } }
});
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function evaluate(sessionId, expression) {
  const result = await send("Runtime.evaluate", {expression,awaitPromise:true,returnByValue:true}, sessionId);
  if (result.result.exceptionDetails) throw new Error("browser evaluation failed");
  return result.result.result.value;
}
async function loaded(sessionId) {
  for (let i=0;i<100;i++) { if (await evaluate(sessionId,"document.readyState") === "complete") return; await delay(20); }
  throw new Error("live board load timed out");
}
function assert(ok, message) { if (!ok) throw new Error(message); }
(async () => {
  const created = await send("Target.createTarget", {url:"about:blank"});
  const attached = await send("Target.attachToTarget", {targetId:created.result.targetId,flatten:true});
  const sid = attached.result.sessionId;
  await send("Page.enable", {}, sid);
  await send("Runtime.enable", {}, sid);
  await send("Emulation.setDeviceMetricsOverride", {width:390,height:844,deviceScaleFactor:1,mobile:true}, sid);
  await send("Page.addScriptToEvaluateOnNewDocument", {source:`
    window.__fmLiveFrameTops=[];
    window.lavish={queuePrompt:function(){return true},sendQueuedPrompts:function(){return true}};
    window.addEventListener('DOMContentLoaded',function(){var left=8;function sample(){
      var state=null;try{state=JSON.parse(sessionStorage.getItem(window.__fmViewKey)||'null')}catch(e){}
      var target=state&&typeof state.anchor==='string'?[...document.querySelectorAll('[data-scroll-anchor]')]
        .find(x=>x.getAttribute('data-scroll-anchor')===state.anchor):null;
      window.__fmLiveFrameTops.push(target?target.getBoundingClientRect().top:null);
      if(--left>0)requestAnimationFrame(sample);
    }requestAnimationFrame(sample)});`}, sid);
  await send("Page.navigate", {url:pathToFileURL(boardPath).href}, sid);
  await loaded(sid); await delay(200);
  const before = await evaluate(sid, `(async()=>{
    var tabs=[...document.querySelectorAll('[role=tab]')]; var best=null;
    for(var tab of tabs){tab.click();await new Promise(r=>requestAnimationFrame(r));
      var height=document.documentElement.scrollHeight;if(!best||height>best.height)best={id:tab.id,height:height};}
    document.getElementById(best.id).click();await new Promise(r=>requestAnimationFrame(r));
    var max=Math.max(0,document.documentElement.scrollHeight-innerHeight);
    if(max<160)return {meaningful:false,max:max};
    scrollTo(0,Math.max(120,Math.round(max*.55)));await new Promise(r=>requestAnimationFrame(r));
    window.__fmSaveView();var state=JSON.parse(sessionStorage.getItem(window.__fmViewKey)||'null');
    var target=state&&[...document.querySelectorAll('[data-scroll-anchor]')]
      .find(x=>x.getAttribute('data-scroll-anchor')===state.anchor);
    return {meaningful:!!target,y:scrollY,top:target&&target.getBoundingClientRect().top,tab:best.id};
  })()`);
  assert(before.meaningful && before.y >= 120, "live board lacks a meaningful mobile reading position");
  const regenerated = spawnSync(boardBin, ["--no-quota","--controls","--refresh","300","--out",boardPath],
    {env:{...process.env,FM_HOME:liveHome},stdio:"ignore"});
  assert(regenerated.status === 0, "live board regeneration failed");
  await send("Page.reload", {ignoreCache:true}, sid);
  await loaded(sid); await delay(200);
  const after = await evaluate(sid, `(()=>{
    var state=JSON.parse(sessionStorage.getItem(window.__fmViewKey)||'null');
    var target=state&&[...document.querySelectorAll('[data-scroll-anchor]')]
      .find(x=>x.getAttribute('data-scroll-anchor')===state.anchor);
    return {found:!!target,y:scrollY,top:target&&target.getBoundingClientRect().top,
      classes:document.documentElement.className,
      frames:window.__fmLiveFrameTops};
  })()`);
  assert(after.found && after.y >= 120, "live board lost its meaningful mobile reading position");
  assert(documentTab(before.tab, after.classes), "live board lost its active tab");
  assert(Math.abs(after.top-before.top)<=3, `live board anchor shifted by ${Math.abs(after.top-before.top)}px`);
  const frames=after.frames.filter(x=>typeof x==="number");
  assert(frames.length>0 && frames.every(x=>Math.abs(x-before.top)<=3), "live board jumped during early refresh frames");
  function documentTab(tabId, classes){return classes.split(/\s+/).includes("t-"+tabId.replace(/^tab-/,""));}
})().finally(() => chrome.kill()).catch((error) => { console.error(error.message); process.exitCode=1; });
JS
  pass "a privacy-safe live fleet stays anchored across regeneration and full reload"
}

test_recorded_answers_persist_across_devices_and_sink() {
  local snap state board log device_one device_two chrome
  snap=$TMP_ROOT/recorded-answers.json
  state=$TMP_ROOT/recorded-answers-state
  board=$TMP_ROOT/recorded-answers.html
  device_one=$TMP_ROOT/recorded-answers-device-one.html
  device_two=$TMP_ROOT/recorded-answers-device-two.html
  mkdir -p "$state"
  snapshot_json '[
    {"state":"queued","id":"alpha","captain_actionable":true,"captain_deferred":false,
     "title":"Choose alpha path","hold_reason":"Alpha was answered","repo":"sample",
     "decision_group":"portfolio-data-trust-scope","decision_options":["Keep alpha","Replace alpha"],
     "decision_why":"The alpha source is incomplete.","decision_affects":"The alpha dashboard.",
     "decision_recommendation":"Replace alpha.","blocks_ids":["alpha-build"]},
    {"state":"queued","id":"delta","captain_actionable":true,"captain_deferred":false,
     "title":"Choose delta path","hold_reason":"Delta is still open","repo":"sample"},
    {"state":"queued","id":"beta","captain_actionable":true,"captain_deferred":false,
     "title":"Choose beta path","hold_reason":"Beta is still open","repo":"sample",
     "decision_group":"portfolio-data-trust-scope","decision_kind":"fact",
     "decision_expects":"one beta source name","blocks_ids":["beta-build"]},
    {"state":"queued","id":"gamma","captain_actionable":true,"captain_deferred":false,
     "title":"Choose gamma path","hold_reason":"Gamma was answered","repo":"sample",
     "decision_group":"release-readiness"},
    {"state":"queued","id":"epsilon","captain_actionable":true,"captain_deferred":false,
     "title":"Choose epsilon path","hold_reason":"Epsilon was answered","repo":"sample",
     "decision_group":"release-readiness"},
    {"state":"queued","id":"zeta","captain_actionable":true,"captain_deferred":false,
     "title":"Choose zeta path","hold_reason":"Zeta is still open","repo":"sample",
     "decision_group":"only-one"},
    {"state":"queued","id":"alpha-build","captain_actionable":false,"captain_deferred":false,
     "title":"Build alpha dashboard","repo":"sample"},
    {"state":"queued","id":"beta-build","captain_actionable":false,"captain_deferred":false,
     "title":"Build beta dashboard","repo":"sample"},
    {"state":"queued","id":"defer-one","captain_actionable":false,"captain_deferred":true,
     "title":"Defer first","hold_reason":"First shelf row","repo":"sample","decision_group":"deferred-pair"},
    {"state":"queued","id":"defer-two","captain_actionable":false,"captain_deferred":true,
     "title":"Defer second","hold_reason":"Second shelf row","repo":"sample","decision_group":"deferred-pair"}
  ]' '[
    {"id":"ios","registered":true,"provenance":{"selected":"structured-home"},
     "current":{"state":"captain_decision"},"active_children":[],"holds":[],"queued":[],
     "decisions_open":[{"id":"shared","key":"route","source":"status",
       "summary":"Choose iOS shared route","reason":"The iOS answer was recorded"}],
     "counts":{"active_children":0,"decisions_open":1,"holds":0,"queued":0},"omitted":[]},
    {"id":"android","registered":true,"provenance":{"selected":"structured-home"},
     "current":{"state":"captain_decision"},"active_children":[],"holds":[],"queued":[],
     "decisions_open":[{"id":"shared","key":"route","source":"status",
       "summary":"Choose Android shared route","reason":"The Android answer is still open"}],
     "counts":{"active_children":0,"decisions_open":1,"holds":0,"queued":0},"omitted":[]}
  ]' | jq --arg state "$state" '.roots.state = $state' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the initial recorded-answer board must render"
  log=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-procevent-board-reply.sh" log-path "$board") \
    || fail "the board request log path must resolve"
  mkdir -p "$(dirname "$log")"
  cat > "$log" <<'EOF'
  "2026-01-04T00:00:01Z","fm-board:alpha","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"alpha\",\"note\":\"Use alpha.\"}"
  "2026-01-04T00:00:02Z","fm-board:gamma","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"gamma\",\"note\":\"Use gamma.\"}"
  "2026-01-04T00:00:03Z","fm-board:epsilon","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"epsilon\",\"note\":\"Use epsilon.\"}"
  "2026-01-04T00:00:04Z","fm-board:ios","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"ios\",\"id\":\"shared\",\"key\":\"route\",\"note\":\"Use the iOS route.\"}"
  "2026-01-04T00:00:05Z","fm-board:deferred","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"defer-two\",\"note\":\"Keep this deferred.\"}"
EOF

  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the first durable-answer regeneration must render"
  cp "$board" "$device_one"
  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the second durable-answer regeneration must render"
  cp "$board" "$device_two"

  [ "$(grep -o 'data-recorded-answer="true"' "$device_one" | wc -l | tr -d ' ')" = 4 ] \
    || fail "only the four still-actionable exact answer identities should be marked recorded"
  [ "$(grep -o 'class="decision-group"' "$device_one" | wc -l | tr -d ' ')" = 2 ] \
    || fail "only shared non-null group keys should create consolidated cards"
  assert_grep 'data-decision-group="portfolio-data-trust-scope"' "$device_one" \
    "two decisions sharing an origin did not render in one group"
  assert_grep '<h3>Portfolio data trust scope</h3>' "$device_one" \
    "a grouped card did not turn its slug into a readable heading"
  assert_no_grep 'data-decision-group="only-one"' "$device_one" \
    "a lone group key created a single-item wrapper"
  assert_no_grep 'data-decision-group="deferred-pair"' "$device_one" \
    "the Deferred shelf was changed into grouped decision cards"
  assert_grep '<div class="n">8</div><div class="l">Awaiting you</div>' "$device_one" \
    "visual grouping changed the number of underlying decisions awaiting the captain"
  cmp -s "$device_one" "$device_two" \
    || fail "two regenerations over the same durable request log disagreed"

  command -v node >/dev/null 2>&1 || {
    printf 'skip: node not found for durable decision-card browser regression\n'; return 0; }
  chrome=$(find_chrome) || {
    printf 'skip: Chrome or Chromium not found for durable decision-card browser regression\n'; return 0; }
  node - "$chrome" "$device_one" "$device_two" <<'JS' \
    || fail "durable answer ordering and shared Ask-firstmate wiring failed in a real browser"
const {spawn} = require("node:child_process");
const {pathToFileURL} = require("node:url");
const [chromePath, ...boards] = process.argv.slice(2);
const chrome = spawn(chromePath, ["--headless=new","--disable-gpu","--no-sandbox",
  "--remote-debugging-pipe",`--user-data-dir=${boards[0]}.profile`],
  {stdio:["ignore","ignore","ignore","pipe","pipe"]});
let buffer="", nextId=0; const pending=new Map();
function send(method,params={},sessionId){return new Promise(resolve=>{const id=++nextId;pending.set(id,resolve);
  chrome.stdio[3].write(`${JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})}\0`);});}
chrome.stdio[4].on("data",chunk=>{buffer+=chunk;let at;while((at=buffer.indexOf("\0"))>=0){
  const raw=buffer.slice(0,at);buffer=buffer.slice(at+1);if(!raw)continue;const message=JSON.parse(raw);
  const resolve=pending.get(message.id);if(resolve){pending.delete(message.id);resolve(message);}}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function evaluate(sid,expression){const result=await send("Runtime.evaluate",{expression,returnByValue:true,awaitPromise:true},sid);
  if(result.result.exceptionDetails)throw new Error(result.result.exceptionDetails.text);return result.result.result.value;}
function assert(ok,message){if(!ok)throw new Error(message);}
async function inspect(path,width,mobile){
  const context=await send("Target.createBrowserContext");
  const created=await send("Target.createTarget",{url:"about:blank",browserContextId:context.result.browserContextId});
  const attached=await send("Target.attachToTarget",{targetId:created.result.targetId,flatten:true});
  const sid=attached.result.sessionId;
  await send("Page.enable",{},sid); await send("Runtime.enable",{},sid);
  await send("Page.addScriptToEvaluateOnNewDocument",{source:`window.lavish={queuePrompt:()=>true,sendQueuedPrompts:()=>true};`},sid);
  await send("Emulation.setDeviceMetricsOverride",{width,height:844,deviceScaleFactor:1,mobile},sid);
  await send("Page.navigate",{url:pathToFileURL(path).href},sid);
  for(let i=0;i<100;i++){if(await evaluate(sid,"document.readyState") === "complete")break;await delay(20);}
  for(let i=0;i<40;i++){if(await evaluate(sid,"document.body.classList.contains('lavish')"))break;await delay(25);}
  const seen=await evaluate(sid,`(() => {
    const blocks=[...document.querySelectorAll('.needs .rc[data-what]')];
    const answered=blocks.filter(block=>block.dataset.recordedAnswer==='true');
    const android=blocks.find(block=>block.dataset.home==='android');
    const alpha=blocks.find(block=>block.dataset.id==='alpha');
    const beta=blocks.find(block=>block.dataset.id==='beta');
    const groups=[...document.querySelectorAll('.needs > .decision-group')];
    const partial=groups.find(group=>group.dataset.decisionGroup==='portfolio-data-trust-scope');
    const complete=groups.find(group=>group.dataset.decisionGroup==='release-readiness');
    const askButton=alpha.querySelector('[data-ask-about]');
    askButton.scrollIntoView({block:'center'}); askButton.click();
    const composer=document.querySelector('#ask-firstmate-composer textarea');
    const composerValue=composer.value;
    composer.value='x'.repeat(1998); composer.dispatchEvent(new Event('input',{bubbles:true}));
    blocks.find(block=>block.dataset.id==='delta').querySelector('[data-ask-about]').click();
    const boundedComposerValue=composer.value;
    const boxes=[askButton,...groups,...answered.map(block=>block.querySelector('[data-ok=answer]'))]
      .map(element=>{const rect=element.getBoundingClientRect();return {left:rect.left,right:rect.right,width:rect.width};});
    const topOrder=[...document.querySelector('.needs').children].map(unit=>unit.classList.contains('decision-group')
      ? 'group:'+unit.dataset.decisionGroup : unit.querySelector('.rc[data-what]')?.dataset.what || 'notice');
    return {
      order:blocks.map(block=>block.dataset.what), topOrder, total:blocks.length,
      groups:groups.map(group=>({key:group.dataset.decisionGroup,
        count:group.querySelector('.decision-group-count').textContent,
        questions:[...group.querySelectorAll('.decision-subquestion')].map(label=>label.textContent),
        ids:[...group.querySelectorAll('.rc[data-id]')].map(control=>control.dataset.id)})),
      partialContent:{choices:alpha.querySelectorAll('[data-answer-choice]').length,
        answer:alpha.querySelectorAll('[data-open=answer]').length,
        ask:partial.querySelectorAll('[data-ask-about]').length,
        contexts:partial.querySelectorAll('.need-ctx').length,
        blocking:[...partial.querySelectorAll('.ctx-l')].filter(label=>label.textContent==='Blocking:').length,
        fact:beta.querySelector('.rc-fact-v')?.textContent || '',
        banners:partial.querySelectorAll('[data-ok=answer]').length},
      standalone:{delta:!blocks.find(block=>block.dataset.id==='delta').closest('.decision-group'),
        zeta:!blocks.find(block=>block.dataset.id==='zeta').closest('.decision-group')},
      answered:answered.map(block=>({home:block.dataset.home,id:block.dataset.id,
        head:block.querySelector('[data-ok=answer] .rc-ok-h').textContent,
        note:block.querySelector('[data-ok=answer] .rc-ok-s').textContent,
        tone:block.querySelector('[data-ok=answer]').className,
        visible:!block.querySelector('[data-ok=answer]').hidden})),
      androidPending:android.dataset.recordedAnswer,
      deferred:[...document.querySelectorAll('#deferred-shelf .defer .ask')].map(row=>row.firstChild.textContent),
      deferredControls:document.querySelectorAll('#deferred-shelf .rc').length,
      groupsOutsideWaiting:document.querySelectorAll('#panel-projects .decision-group, #panel-activity .decision-group, #panel-system .decision-group, #deferred-shelf .decision-group').length,
      composers:document.querySelectorAll('#ask-firstmate-composer').length,
      composerValue, boundedComposerValue, focused:document.activeElement===composer,
      boxes, documentWidth:document.documentElement.scrollWidth,
      viewportWidth:document.documentElement.clientWidth
    };
  })()`);
  await send("Target.disposeBrowserContext",{browserContextId:context.result.browserContextId});
  return seen;
}
(async()=>{
  const expected=["Choose delta path","Choose alpha path","Choose beta path","Choose zeta path",
    "Choose Android shared route","Choose gamma path","Choose epsilon path","Choose iOS shared route"];
  const topExpected=["Choose delta path","group:portfolio-data-trust-scope","Choose zeta path",
    "Choose Android shared route","group:release-readiness","Choose iOS shared route"];
  for(const path of boards){for(const [width,mobile] of [[1280,false],[390,true]]){
    const seen=await inspect(path,width,mobile);
    assert(JSON.stringify(seen.order)===JSON.stringify(expected)
      && JSON.stringify(seen.topOrder)===JSON.stringify(topExpected),
      `partial or complete decision groups sorted incorrectly at ${width}px: ${JSON.stringify(seen)}`);
    assert(seen.total===8 && seen.answered.length===4 && seen.answered.every(row=>row.visible
      && row.head==="Answer received" && row.note.startsWith("No action is needed from you right now.")
      && row.tone.includes("rc-quiet") && !row.tone.includes("rc-needs-you")),
      `durable collected banners were not quiet and reassuring at ${width}px: ${JSON.stringify(seen)}`);
    assert(seen.groups.length===2
      && seen.groups[0].key==='portfolio-data-trust-scope' && seen.groups[0].count==='1 of 2 answered'
      && JSON.stringify(seen.groups[0].questions)===JSON.stringify(['Question 1 of 2','Question 2 of 2'])
      && JSON.stringify(seen.groups[0].ids)===JSON.stringify(['alpha','beta'])
      && seen.groups[1].key==='release-readiness' && seen.groups[1].count==='2 of 2 answered'
      && JSON.stringify(seen.groups[1].ids)===JSON.stringify(['gamma','epsilon']),
      `group wrappers lost their labels, progress, or independent identities at ${width}px: ${JSON.stringify(seen)}`);
    assert(seen.partialContent.choices===2 && seen.partialContent.answer===1
      && seen.partialContent.ask===2 && seen.partialContent.contexts===2
      && seen.partialContent.blocking===2 && seen.partialContent.fact==='Expected answer: one beta source name'
      && seen.partialContent.banners===2,
      `a consolidated card simplified or merged existing sub-question content at ${width}px: ${JSON.stringify(seen)}`);
    assert(seen.standalone.delta && seen.standalone.zeta,
      `an absent or unique group key changed standalone rendering at ${width}px: ${JSON.stringify(seen)}`);
    assert(seen.androidPending==="false",`another home's matching id/key inherited the iOS answer: ${JSON.stringify(seen)}`);
    assert(JSON.stringify(seen.deferred)===JSON.stringify(["Defer first","Defer second"])
      && seen.deferredControls===0 && seen.groupsOutsideWaiting===0,
      `grouping changed Deferred or another board section: ${JSON.stringify(seen)}`);
    assert(seen.composers===1 && seen.focused && seen.composerValue==="About “Choose alpha path”:\n",
      `the per-decision question entry did not focus and prefill the one shared composer: ${JSON.stringify(seen)}`);
    assert(seen.boundedComposerValue.length<=2000
      && seen.boundedComposerValue.endsWith("About “Choose delta path”:\n"),
      `a near-limit shared composer lost the quoted decision reference: ${JSON.stringify(seen)}`);
    assert(seen.documentWidth<=seen.viewportWidth && seen.boxes.every(box=>box.left>=0&&box.right<=seen.viewportWidth+0.5&&box.width>0),
      `a new decision-card visual state overflowed at ${width}px: ${JSON.stringify(seen)}`);
  }}
})().finally(()=>chrome.kill()).catch(error=>{console.error(error.stack||error);process.exitCode=1;});
JS
  pass "grouped decisions retain independent cards, sink only when complete, and fit both breakpoints"
}

test_control_targets_are_escaped() {
  local snap board
  snap=$TMP_ROOT/hostile-controls.json
  board=$TMP_ROOT/hostile-controls.html
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
      "title": "Ship \"><script>alert(1)</script> now", "hold_reason": "x", "repo": "alpha"}]' \
    '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "hostile prose must still render with controls"
  assert_no_grep '<script>alert(1)</script>' "$board" \
    "hostile prose must not reach the page as markup through a control attribute"
  assert_grep 'data-what="Ship &quot;&gt;' "$board" \
    "hostile prose must be escaped inside the control attribute that carries it"
  pass "fleet prose stays escaped where a control carries it"
}


# A fielded fact pack stays structured from its filed schema through the board
# wire, while every older or unusable shape keeps the proven textarea path.
test_schema_driven_fact_forms() {
  local snap state board log chrome
  snap=$TMP_ROOT/schema-facts.json
  state=$TMP_ROOT/schema-facts-state
  board=$TMP_ROOT/schema-facts.html
  mkdir -p "$state"
  snapshot_json '[
    {"state":"queued","id":"field-one","captain_actionable":true,"title":"Supply portfolio identity facts",
     "hold_reason":"The reconciliation needs identity facts","repo":"sample","decision_kind":"fact",
     "decision_expects":"account identity, statement date, and valuation facts",
     "decision_group":"portfolio-reconciliation","decision_fact_fields":[
       {"label":"Account name","key":"account_name","type":"text","required":true,"hint":"Use the statement heading."},
       {"label":"Statement date","key":"statement_date","type":"date","required":true},
       {"label":"Units held","key":"units_held","type":"number","required":false,"unit":"shares"},
       {"label":"Market value","key":"market_value","type":"money","required":true,"unit":"GBP","example":"125000.50"},
       {"label":"Custodian","key":"custodian","type":"enum","required":false,"enum_options":["North Bank","South Bank","Other"]},
       {"label":"Reconciliation detail","key":"detail","type":"longtext","required":false}]},
    {"state":"queued","id":"field-two","captain_actionable":true,"title":"Supply portfolio source facts",
     "hold_reason":"The reconciliation needs source facts","repo":"sample","decision_kind":"fact",
     "decision_expects":"source account, date, and valuation facts","decision_group":"portfolio-reconciliation",
     "decision_fact_fields":[
       {"label":"Account name","key":"account_name","type":"text","required":true,"hint":"Use the statement heading."},
       {"label":"Statement date","key":"statement_date","type":"date","required":true},
       {"label":"Units held","key":"units_held","type":"number","required":false,"unit":"shares"},
       {"label":"Market value","key":"market_value","type":"money","required":true,"unit":"GBP","example":"125000.50"},
       {"label":"Custodian","key":"custodian","type":"enum","required":false,"enum_options":["North Bank","South Bank","Other"]},
       {"label":"Reconciliation detail","key":"detail","type":"longtext","required":false}]},
    {"state":"queued","id":"legacy-fact","captain_actionable":true,"title":"Supply the legacy fact",
     "hold_reason":"This predates field schemas","repo":"sample","decision_kind":"fact","decision_expects":"one source name"},
    {"state":"queued","id":"longtext-fact","captain_actionable":true,"title":"Explain the exceptional fact",
     "hold_reason":"This answer is inherently prose","repo":"sample","decision_kind":"fact","decision_expects":"a short explanation",
     "decision_fact_fields":[{"label":"Explanation","key":"explanation","type":"longtext","required":true}]},
    {"state":"queued","id":"malformed-fact","captain_actionable":true,"title":"Supply the malformed-schema fact",
     "hold_reason":"A hand-built snapshot is malformed","repo":"sample","decision_kind":"fact","decision_expects":"one safe fallback answer",
     "decision_fact_fields":[{"label":"Grid","key":"grid","type":"spreadsheet","required":true}]},
    {"state":"queued","id":"prose-only","captain_actionable":true,"title":"FACTS appear only in prose",
     "hold_reason":"Do not infer intake from words","repo":"sample"},
    {"state":"queued","id":"already-answered","captain_actionable":true,"title":"Supply an already recorded fact",
     "hold_reason":"This answer should sink","repo":"sample","decision_kind":"fact","decision_expects":"one code"}
  ]' '[]' | jq --arg state "$state" '.roots.state = $state' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the schema fact fixture must render"
  log=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-procevent-board-reply.sh" log-path "$board") \
    || fail "the schema fact request log path must resolve"
  mkdir -p "$(dirname "$log")"
  cat > "$log" <<'EOF'
  "2026-08-10T00:00:01Z","fm-board:field-one","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"field-one\",\"facts\":{\"account_name\":\"Harbour Fund\",\"statement_date\":\"2026-08-09\",\"market_value\":\"125000.50\"},\"required_keys\":[\"account_name\",\"statement_date\",\"market_value\"]}"
  "2026-08-10T00:00:02Z","fm-board:already","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"already-answered\",\"note\":\"ABC\"}"
EOF
  "$BOARD" --snapshot "$snap" --no-quota --controls --refresh 300 --out "$board" >/dev/null \
    || fail "the partially answered fact group must render"

  [ "$(grep -o 'class=\"rc-f rc-fact-form\"' "$board" | wc -l | tr -d ' ')" = 2 ] \
    || fail "only the two valid non-longtext schemas should render fielded forms"
  assert_grep '1 of 2 facts provided' "$board" \
    "a partially answered fact group did not show fact progress"
  assert_grep 'data-fact-key="market_value"' "$board" \
    "a valid money field did not reach the form"
  assert_grep 'data-fact-key="custodian"' "$board" \
    "a valid enum field did not reach the form"
  assert_grep 'Expected answer: one source name' "$board" \
    "a legacy fact lost its expected-answer textarea fallback"
  assert_grep 'Expected answer: a short explanation' "$board" \
    "a longtext-only schema did not keep the textarea fallback"
  assert_grep 'Expected answer: one safe fallback answer' "$board" \
    "a malformed schema did not fail safely to the textarea"

  command -v node >/dev/null 2>&1 || {
    printf 'skip: node not found for schema fact-form browser regression\n'; return 0; }
  chrome=$(find_chrome) || {
    printf 'skip: Chrome or Chromium not found for schema fact-form browser regression\n'; return 0; }
  node - "$chrome" "$board" <<'JS' \
    || fail "schema fact form rendering and structured submission failed in a real browser"
const {spawn}=require("node:child_process"); const {pathToFileURL}=require("node:url");
const [chromePath,boardPath]=process.argv.slice(2);
const chrome=spawn(chromePath,["--headless=new","--disable-gpu","--no-sandbox","--remote-debugging-pipe",
  `--user-data-dir=${boardPath}.facts-profile`],{stdio:["ignore","ignore","ignore","pipe","pipe"]});
let buffer="",nextId=0;const pending=new Map();
function send(method,params={},sessionId){return new Promise(resolve=>{const id=++nextId;pending.set(id,resolve);
  chrome.stdio[3].write(`${JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})}\0`);});}
chrome.stdio[4].on("data",chunk=>{buffer+=chunk;let at;while((at=buffer.indexOf("\0"))>=0){const raw=buffer.slice(0,at);
  buffer=buffer.slice(at+1);if(!raw)continue;const message=JSON.parse(raw);const resolve=pending.get(message.id);
  if(resolve){pending.delete(message.id);resolve(message);}}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function evaluate(sid,expression){const result=await send("Runtime.evaluate",{expression,returnByValue:true,awaitPromise:true},sid);
  if(result.result.exceptionDetails)throw new Error(result.result.exceptionDetails.text);return result.result.result.value;}
function assert(ok,message){if(!ok)throw new Error(message);}
(async()=>{const created=await send("Target.createTarget",{url:"about:blank"});const attached=await send("Target.attachToTarget",
  {targetId:created.result.targetId,flatten:true});const sid=attached.result.sessionId;await send("Page.enable",{},sid);await send("Runtime.enable",{},sid);
  await send("Page.addScriptToEvaluateOnNewDocument",{source:`window.lavish={queuePrompt:function(prompt){
    localStorage.setItem('fact-wire',prompt);return true;},sendQueuedPrompts:function(){return true;}};`},sid);
  await send("Page.navigate",{url:pathToFileURL(boardPath).href},sid);for(let i=0;i<100;i++){
    if(await evaluate(sid,"document.readyState") === "complete")break;await delay(20);}await delay(150);
  const shape=await evaluate(sid,`(()=>{function block(id){return [...document.querySelectorAll('.rc')].find(x=>x.dataset.id===id);}
    const schema=block('field-two'),legacy=block('legacy-fact'),longtext=block('longtext-fact'),malformed=block('malformed-fact'),prose=block('prose-only');
    const group=schema.closest('.decision-group'),answered=block('already-answered').closest('.need-wrap');
    return {types:[...schema.querySelectorAll('[data-fact-key]')].map(x=>x.tagName+':'+x.type),
      legacy:!!legacy.querySelector('form[data-intent=answer]>.rc-t'),longtext:!!longtext.querySelector('form[data-intent=answer]>.rc-t'),
      malformed:!!malformed.querySelector('form[data-intent=answer]>.rc-t'),prose:prose.querySelectorAll('.rc-fact,.rc-fact-form').length,
      progress:group.querySelector('.decision-group-count').textContent,
      partialBeforeAnswered:[...document.querySelector('.needs').children].indexOf(group)<[...document.querySelector('.needs').children].indexOf(answered)};})()`);
  assert(shape.types.includes('INPUT:text')&&shape.types.includes('INPUT:date')&&shape.types.includes('INPUT:number')
    &&shape.types.includes('SELECT:select-one')&&shape.types.includes('TEXTAREA:textarea'),"field types did not map to real controls: "+JSON.stringify(shape));
  assert(shape.legacy&&shape.longtext&&shape.malformed&&shape.prose===0,"legacy fallback or no-inference behavior failed: "+JSON.stringify(shape));
  assert(shape.progress==="1 of 2 facts provided"&&shape.partialBeforeAnswered,"partial fact group read as complete: "+JSON.stringify(shape));
  const wide=await evaluate(sid,`(()=>{const b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='field-two');
    b.querySelector('[data-open=answer]').click();const f=b.querySelector('.rc-fact-form');f.scrollIntoView({block:'center'});
    const r=f.getBoundingClientRect();return {left:r.left,right:r.right,overflow:document.documentElement.scrollWidth>innerWidth};})()`);
  assert(wide.left>=0&&wide.right<=1280&&!wide.overflow,"fact form overflowed at desktop width: "+JSON.stringify(wide));
  await send("Emulation.setDeviceMetricsOverride",{width:390,height:844,deviceScaleFactor:1,mobile:true},sid);await delay(100);
  const mobile=await evaluate(sid,`(()=>{const f=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='field-two').querySelector('.rc-fact-form');
    const fields=[...f.querySelectorAll('.rc-field-input')].map(x=>x.getBoundingClientRect());const submit=f.querySelector('.rc-go');
    submit.scrollIntoView({block:'center'});const s=submit.getBoundingClientRect();return {lefts:fields.map(r=>Math.round(r.left)),
      within:fields.every(r=>r.left>=0&&r.right<=390),submit:{left:s.left,right:s.right,top:s.top,bottom:s.bottom},
      progress:f.closest('.decision-group').querySelector('.decision-group-count').textContent,
      overflow:document.documentElement.scrollWidth>390};})()`);
  assert(mobile.within&&!mobile.overflow&&new Set(mobile.lefts).size===1&&mobile.submit.left>=0&&mobile.submit.right<=390
    &&mobile.submit.top>=0&&mobile.submit.bottom<=844&&mobile.progress==="1 of 2 facts provided",
    "mobile field stack or submit/progress failed: "+JSON.stringify(mobile));
  const sent=await evaluate(sid,`(async()=>{const b=[...document.querySelectorAll('.rc')].find(x=>x.dataset.id==='field-two');const f=b.querySelector('.rc-fact-form');
    f.querySelector('[data-fact-key=account_name]').value='Harbour Fund';f.querySelector('[data-fact-key=statement_date]').value='2026-08-09';
    f.querySelector('[data-fact-key=units_held]').value='250';f.querySelector('[data-fact-key=market_value]').value='125000.50';
    f.querySelector('[data-fact-key=custodian]').value='North Bank';f.querySelector('[data-fact-key=detail]').value='Matched by account code.';
    f.querySelector('.rc-overflow').open=true;f.querySelector('.rc-overflow-note').value='Renamed last quarter.';f.requestSubmit();
    await new Promise(r=>setTimeout(r,30));return JSON.parse(localStorage.getItem('fact-wire').slice('FM-BOARD-REQUEST '.length));})()`);
  assert(sent.intent==='answer'&&sent.facts.account_name==='Harbour Fund'&&sent.facts.market_value==='125000.50'
    &&sent.facts.detail==='Matched by account code.'&&sent.note==='Renamed last quarter.'
    &&JSON.stringify(sent.required_keys)===JSON.stringify(['account_name','statement_date','market_value']),
    "field submission lost structured facts or overflow note: "+JSON.stringify(sent));
})().finally(()=>chrome.kill()).catch(error=>{console.error(error.message);process.exitCode=1;});
JS
  pass "schema fact forms render, fall back safely, submit structured values, and fit mobile"
}

# A decision the captain cannot act on is worse than no decision: it sits in
# Captain's Call looking answerable. Fleet health is where the board already
# reports what needs attention, so an incomplete decision surfaces there with the
# specific gap, without anyone remembering to run a separate check.
test_incomplete_decision_reaches_fleet_health() {
  local snap board
  snap=$TMP_ROOT/decision-readiness.json
  board=$TMP_ROOT/decision-readiness.html
  snapshot_json '[
    {"id": "ready-decision", "structured": true, "state": "queued", "kind": "captain",
     "title": "Choose the route", "repo": "sample",
     "hold_reason": "captain route choice pending", "hold_kind": "captain",
     "decision_readiness": {"structured": true, "ready": true, "gaps": []}},
    {"id": "unready-decision", "structured": true, "state": "queued", "kind": "captain",
     "title": "Choose the palette", "repo": "sample",
     "hold_reason": "captain palette choice pending", "hold_kind": "captain",
     "unresolved_blocker_ids": ["palette-source"],
     "decision_readiness": {"structured": true, "ready": false, "gaps": [
       {"check": "question", "flag": "--question", "detail": "the decision question is missing"},
       {"check": "recommendation", "flag": "--recommendation", "detail": "the recommendation is missing"}]}},
    {"id": "free-text-decision", "structured": true, "state": "queued", "kind": "captain",
     "title": "Choose the schedule", "repo": "sample",
     "hold_reason": "captain schedule choice pending", "hold_kind": "captain",
     "decision_readiness": {"structured": false, "ready": true, "gaps": []}},
    {"id": "parked-decision", "structured": true, "state": "queued", "kind": "captain",
     "title": "Choose the font", "repo": "sample",
     "hold_reason": "set aside for now", "hold_kind": "parked",
     "captain_actionable": false, "captain_deferred": true,
     "decision_readiness": {"structured": true, "ready": false, "gaps": [
       {"check": "question", "flag": "--question", "detail": "the decision question is missing"}]}}
  ]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot carrying an incomplete decision must render"

  assert_grep '<li><span class="hstate">incomplete</span><span class="hwhat">Choose the palette<span class="hint">the decision question is missing; the recommendation is missing</span></span></li>' \
    "$board" "an incomplete decision must reach fleet health naming every gap"
  assert_grep '<h3>Fleet health<span class="count">1 item</span></h3>' "$board" \
    "an incomplete blocked decision must be counted once in fleet health"
  assert_no_grep 'blocked by palette-source' "$board" \
    "an incomplete decision must retain its readiness details instead of a duplicate blocker row"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "fleet health must not read as all clear while a decision is unanswerable"

  # The bar above the board summarises fleet health, and an unanswerable decision
  # is neither blocked nor failed, so the wording has to widen with it.
  assert_grep '1 fleet health item needs attention' "$board" \
    "the attention bar must describe an incomplete decision honestly"
  assert_no_grep '1 item is blocked or failed' "$board" \
    "an incomplete decision must not be reported as blocked or failed"

  # Scope: only a decision the checklist actually covers and actually failed.
  assert_no_grep '<span class="hwhat">Choose the route' "$board" \
    "a complete decision must not appear in fleet health"
  assert_no_grep '<span class="hwhat">Choose the schedule' "$board" \
    "an older free-text captain hold must not appear in fleet health"
  assert_no_grep '<span class="hwhat">Choose the font' "$board" \
    "a decision the captain set aside must not be re-surfaced by fleet health"
  pass "an unanswerable captain decision surfaces in fleet health with its gap"
}

test_in_progress_items_are_listed_with_stage_and_model
test_stalled_items_do_not_read_as_progress
test_setup_uses_neutral_tone
test_ready_and_done_use_distinct_tones
test_model_ids_are_shown_as_readable_names
test_unrecorded_item_facts_are_disclosed_rather_than_blanked
test_out_of_range_stage_values_are_bounded_before_they_are_drawn
test_long_item_list_keeps_every_item_in_an_expandable_shelf
test_upstream_omissions_stay_distinct_from_shelved_items
test_renders_live_fixture_home
test_project_last_change_comes_from_the_clone
test_yesterday_uses_local_calendar_arithmetic
test_missing_change_time_degrades_to_a_dash
test_render_writes_nothing_into_the_project_clones
test_absent_sources_render_empty_sections
test_header_freshness_discloses_an_unknown_render_time
test_recent_autonomous_actions_are_bounded_and_appendable
test_hostile_text_is_escaped
test_missing_backlog_is_disclosed_as_unavailable
test_structured_decision_context_renders_as_labelled_sections
test_decision_blocking_line_names_dependents_and_falls_back_to_ids
test_deferred_decision_leaves_the_primary_view
test_deferred_shelf_reaches_a_secondmate_and_discloses_its_bound
test_navigation_tabs_group_the_board
test_fragment_selected_tab_survives_reload
test_project_tags_jump_to_current_state_cards
test_attention_bar_reaches_health_across_tabs
test_unreadable_backlog_does_not_leave_projects_looking_calm
test_blocked_work_is_raised_above_the_board
test_duplicate_main_health_sources_are_normalized
test_secondmate_captain_decision_is_surfaced
test_secondmate_mixed_decision_and_child_hold_stay_distinct
test_secondmate_change_time_comes_from_its_own_reporting
test_bounded_secondmate_decisions_are_disclosed
test_unreadable_secondmate_sources_are_disclosed
test_path_form_repo_folds_into_the_project_rollup
test_live_work_outside_the_registry_stays_visible
test_unregistered_live_project_uses_clone_change_time
test_secondmate_health_and_activity_use_authoritative_counts
test_secondmate_child_count_shapes_render_safely
test_rich_token_dashboard_is_one_pace_first_allowance_view
test_unavailable_token_sources_are_explicit
test_token_dashboard_url_cannot_leave_the_local_machine
test_stale_token_history_is_labelled_without_hiding_it
test_narrow_token_shapes_keep_every_value_wrappable
test_unmeasurable_allowance_is_not_a_zero_gauge
test_grok_live_windows_fill_a_dashboard_gap
test_grok_quota_fallback_keeps_live_windows
test_token_dashboard_grok_data_stays_preferred
test_grok_unmeasurable_and_sign_in_states_use_existing_allowance_copy
test_usage_errors_refuse
test_self_reload_is_wired
test_favicon_is_self_contained_in_every_board
test_controls_are_absent_unless_asked_for
test_controls_match_what_each_row_can_actually_resolve
test_controls_can_only_queue_a_request
test_recorded_answers_persist_across_devices_and_sink
test_control_targets_are_escaped
test_decision_context_links_and_submission_state_in_a_browser
test_live_fleet_mobile_refresh_keeps_reading_position
test_schema_driven_fact_forms
test_incomplete_decision_reaches_fleet_health
