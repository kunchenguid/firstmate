#!/usr/bin/env bash
# Behavior tests for bin/fm-drive-board.sh: the payload snapshot from live goals,
# the self-contained dark page and its fail-closed publication, and the keyed
# drive.go answer that starts or edits a goal and enters /afk through the
# existing guarded scripts. The Lavish serve sequence has its own regression in
# tests/fm-bearings-board.test.sh (same library); the live page is checked by hand.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BOARD="$ROOT/bin/fm-drive-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-drive-board)

# The entry path judges the primary harness; pin one so a real harness ancestor
# cannot change what `enter` prints (tests/fm-afk-launch.test.sh does the same).
unset PI_CODING_AGENT FM_PI_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI
export CLAUDECODE=1 FM_TEST_HARNESS=claude FM_TEST_SEAM=1

H=''
fixture() {
  H=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$H/state" "$H/data" "$H/config/stage-ladders"
  : > "$H/config/supervision-host-off"
  printf '%s\n' 'stage merged: true' 'stage deployed: true' 'stage live: true' > "$H/config/stage-ladders/miko"
  printf '%s\n' \
    'item [id=a] [owner=terp] [project=miko] [target=deployed]: first step' \
    'item [id=b] [owner=main] [after=a]: verify' \
    'item [id=c] [owner=captain] [class=captain]: captain step' > "$H/items"
  printf '%s\n' \
    '[{"id":"c1","title":"Wire the </script> card","owner":"terp","project":"miko"},' \
    ' {"id":"c2","title":"Fix the login","owner":"main"},' \
    ' {"id":"a","title":"already a goal item","owner":"x"}]' > "$H/cands.json"
}
lab() {
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    FM_CONFIG_OVERRIDE="$H/config" "$@"
}
goal() { lab bash "$ROOT/bin/fm-goal.sh" "$@"; }
board() { lab bash "$BOARD" "$@"; }
start_goal() {
  goal start I1 --title 'Production goal' --done-when 'live' --named-by 'finish I1' \
    --plan plan.md --items-file "$H/items" >/dev/null
}
rc_of() {  # <out-file> <command...>: print the exit code, keep the output
  local out=$1 rc=0
  shift
  "$@" > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}
payload() { printf '%s/data/drive-board/drive-board.payload.json' "$H"; }
page() { printf '%s/data/drive-board/drive-board.html' "$H"; }

test_snapshot() {
  fixture; start_goal
  local snap
  snap=$(board snapshot --candidates "$H/cands.json" --new-goal-id fresh)
  assert_equals fm-drive-board.v1 "$(jq -r .schema <<< "$snap")" 'snapshot names its schema'
  assert_equals I1 "$(jq -r '.goals[0].id' <<< "$snap")" 'snapshot carries the active goal'
  assert_equals 'c1,c2' "$(jq -r '[.candidates[].id] | join(",")' <<< "$snap")" 'a candidate already in a goal is dropped'
  assert_equals 'merged,deployed,live' "$(jq -r '.ladders.miko | join(",")' <<< "$snap")" 'the ladder rungs ride along'
  assert_equals attended "$(jq -r '.away.state' <<< "$snap")" 'no away record reads as attended'
  assert_equals fresh "$(jq -r '.new_goal.id' <<< "$snap")" 'the new-goal default is offered'
  snap=$(board snapshot --new-goal-id I1)
  assert_equals null "$(jq -c '.new_goal' <<< "$snap")" 'no new-goal default while its id is an active goal'
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board snapshot --candidates "$H/nope.json")" 'a missing candidates file refuses'
  assert_equals 2 "$(rc_of "$TMP_ROOT/out" board snapshot --new-goal-id ../x)" 'an unsafe new-goal id is a usage error'
  pass 'snapshot composes goals, candidates, ladders, away state and the new-goal default'
}

test_render_page() {
  fixture; start_goal
  local out html
  out=$(board render --candidates "$H/cands.json")
  assert_equals "board: $(page)" "$out" 'render prints the page path under data/drive-board'
  assert_equals "$(page)" "$(board path)" 'path agrees with render'
  html=$(cat "$(page)")
  assert_contains "$html" '<meta name="color-scheme" content="dark">' 'meta color-scheme dark'
  assert_contains "$html" ':root { color-scheme: dark;' 'root color-scheme dark'
  assert_contains "$html" 'html { background:#0f1115;' 'explicit html background'
  assert_contains "$html" 'body { background:#0f1115;' 'explicit body background'
  assert_not_contains "$html" 'src=' 'no external src'
  assert_not_contains "$html" 'href=' 'no links'
  assert_not_contains "$html" '@import' 'no css import'
  assert_not_contains "$html" 'url(' 'no css url()'
  assert_not_contains "$html" 'fetch(' 'no network calls'
  assert_equals '0' "$(grep -c -E '<link|<img|<iframe|cdn\.|googleapis' "$(page)" || true)" 'no external resource tags'
  # the embedded payload survives a </script> in a candidate title and equals the stored copy
  local embedded
  embedded=$(sed -n '/<script id="drive-data" type="application\/json">/,/<\/script>/p' "$(page)" | sed '1d;$d')
  assert_equals "$(jq -c . "$(payload)")" "$(jq -c . <<< "$embedded")" 'the embedded payload round-trips'
  assert_equals 1 "$(grep -c '</script>' <<< "$(sed -n '/<script id="drive-data"/,/^<script>$/p' "$(page)")")" 'only the real closing tag ends the data block'
  assert_equals 600 "$(stat -c %a "$(page)")" 'the page is private to the owner (mode 600)'
  pass 'render publishes a self-contained dark page and a payload copy under data/drive-board'
}

test_render_fail_closed() {
  fixture; start_goal
  board render --candidates "$H/cands.json" >/dev/null
  local before
  before=$(cat "$(page)")
  printf '{"schema":"fm-drive-board.v1","home":"h"}\n' > "$H/bad.json"
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board render "$H/bad.json")" 'an invalid payload refuses'
  assert_contains "$(cat "$TMP_ROOT/out")" 'does not satisfy fm-drive-board.v1' 'the refusal names the schema'
  assert_equals "$before" "$(cat "$(page)")" 'a refused render leaves the page untouched'
  jq '.candidates[0].id = "../x"' "$(payload)" > "$H/bad2.json"
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board render "$H/bad2.json")" 'an unsafe candidate id refuses'
  jq '.goals[0].items[0].class = "other"' "$(payload)" > "$H/bad3.json"
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board render "$H/bad3.json")" 'an unknown item class refuses'
  assert_equals 2 "$(rc_of "$TMP_ROOT/out" board render --name ../x)" 'an unsafe board name is a usage error'
  jq . "$(payload)" > "$H/good.json"
  assert_equals 0 "$(rc_of "$TMP_ROOT/out" board render "$H/good.json")" 'a valid given payload renders'
  assert_equals 2 "$(rc_of "$TMP_ROOT/out" board render "$H/good.json" --candidates "$H/cands.json")" 'a given payload takes no snapshot flags'
  pass 'render refuses an invalid payload before touching the published page'
}

test_apply_edit_and_away() {
  fixture; start_goal
  goal mark I1 a running --stage merged -- 'merged' >/dev/null
  board render --candidates "$H/cands.json" >/dev/null
  local out rc
  out=$(board apply --answer 'goal=I1 pick=a@live,c1@deployed,c2@- away=yes' --dry-run)
  assert_contains "$out" 'would edit goal I1' 'dry-run names the edit'
  assert_contains "$out" '[target=live]: first step' 'dry-run shows the retargeted item'
  assert_contains "$out" 'item [id=c1] [owner=terp] [project=miko] [target=deployed]: Wire the </script> card' 'dry-run shows the added item with its target'
  assert_equals 3 "$(jq '.goals[0].items | length' <<< "$(goal export I1)")" 'dry-run changed nothing in the goal'
  rc=0; lab bash "$ROOT/bin/fm-afk-contract.sh" mode >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'dry-run entered no away record'
  out=$(board apply --answer 'goal=I1 pick=a@live,c1@deployed,c2@- away=yes' 2>&1)
  assert_contains "$out" 'goal: edited I1' 'apply edits the existing goal'
  assert_contains "$out" 'picked: c1@deployed' 'apply reports each pick'
  assert_contains "$out" 'away: entered, drive goal I1' 'apply enters /afk'
  assert_contains "$out" 'next: finish the /afk entry' 'apply says what the afk skill still owns'
  local exp
  exp=$(goal export I1)
  assert_equals 'live' "$(jq -r '.goals[0].items[] | select(.id == "a") | .target' <<< "$exp")" 'the picked target is set'
  assert_equals 'deployed' "$(jq -r '.goals[0].items[] | select(.id == "c1") | .target' <<< "$exp")" 'a candidate is added with its target'
  assert_equals 'null' "$(jq -c '.goals[0].items[] | select(.id == "c2") | .target' <<< "$exp")" 'a no-target pick adds the item without one'
  assert_equals 'running merged' "$(jq -r '.goals[0].items[] | select(.id == "a") | "\(.state) \(.stage)"' <<< "$exp")" 'edit preserves every mark'
  assert_equals 'captain' "$(jq -r '.goals[0].items[] | select(.id == "c") | .class' <<< "$exp")" 'edit keeps the captain item as it was'
  assert_equals away "$(lab bash "$ROOT/bin/fm-afk-contract.sh" mode)" 'the away record is written'
  assert_equals I1 "$(lab bash "$ROOT/bin/fm-afk-contract.sh" field drive_goals)" 'the away record names the goal'
  assert_contains "$(lab bash "$ROOT/bin/fm-afk-contract.sh" words)" 'Drive board order: drive goal I1' 'the away words say where the order came from'
  # a second order while away refreshes the record and keeps the standing words
  out=$(board apply --answer 'goal=I1 pick=c2@- away=yes' 2>&1)
  assert_contains "$out" 'away: refreshed, now naming I1' 'a second order while away refreshes'
  assert_contains "$(lab bash "$ROOT/bin/fm-afk-contract.sh" words)" 'Drive board order: drive goal I1 to its target stages (a@live,c1@deployed,c2@-)' 'a refresh keeps the standing words'
  pass 'apply edits a goal (targets set, candidates added, marks kept) and enters or refreshes /afk'
}

test_apply_start() {
  fixture
  board render --candidates "$H/cands.json" --new-goal-id fresh >/dev/null
  local out exp
  out=$(board apply --answer 'goal=fresh pick=c1@live,c2@- away=no' 2>&1)
  assert_contains "$out" 'goal: started fresh' 'apply starts the new goal'
  assert_contains "$out" 'away: not requested' 'no away entry without the box'
  exp=$(goal export fresh)
  assert_equals 'c1,c2' "$(jq -r '[.goals[0].items[].id] | join(",")' <<< "$exp")" 'the new goal holds the picked items'
  assert_equals 'live' "$(jq -r '.goals[0].items[0].target' <<< "$exp")" 'the pick carries its target'
  assert_equals 'Drive board goal' "$(jq -r '.goals[0].title' <<< "$exp")" 'the title is the payload default'
  assert_contains "$(cat "$H/state/goals/fresh.goal")" 'named_by: Drive board press: goal=fresh pick=c1@live,c2@- away=no' 'the answer is the recorded mandate words'
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" lab bash "$ROOT/bin/fm-afk-contract.sh" mode)" 'no away record yet'
  # a rebuilt page now shows the goal and no new-goal default for its id
  board render --candidates "$H/cands.json" --new-goal-id fresh >/dev/null
  assert_equals 'fresh' "$(jq -r '.goals[0].id' "$(payload)")" 'the rebuilt payload shows the goal'
  assert_equals null "$(jq -c '.new_goal' "$(payload)")" 'the rebuilt payload drops the new-goal default'
  pass 'apply starts the payload new goal from the picks and names the answer as the captain words'
}

test_apply_refusals() {
  fixture; start_goal
  board render --candidates "$H/cands.json" >/dev/null
  local before
  before=$(goal export I1)
  try() {  # <answer> <fragment>
    assert_equals 1 "$(rc_of "$TMP_ROOT/out" board apply --answer "$1")" "refused: $1"
    assert_contains "$(cat "$TMP_ROOT/out")" "$2" "refusal text for: $1"
    assert_equals "$before" "$(goal export I1)" "the goal is unchanged after: $1"
    assert_equals 1 "$(rc_of "$TMP_ROOT/out2" lab bash "$ROOT/bin/fm-afk-contract.sh" mode)" "no away record after: $1"
  }
  try 'goal=I1 pick=nope@live away=no' 'unknown item: nope'
  try 'goal=I1 pick=c@live away=yes' 'captain item'
  try 'goal=I1 pick=a@nowhere away=yes' 'is not on the miko ladder'
  try 'goal=I1 pick=c2@live away=yes' 'has no project'
  try 'goal=other pick=c1@live away=yes' "is not the board's new goal"
  try 'goal=I1 pick=a@live,a@deployed away=no' 'picks an item twice'
  try 'goal=I1 pick= away=no' 'malformed'
  try 'goal=I1 pick=a@live away=maybe' 'malformed'
  try 'goal=I1 pick=a@live' 'malformed'
  goal mark I1 b "done" -- ok >/dev/null
  goal mark I1 a "done" -- ok >/dev/null
  board render --candidates "$H/cands.json" >/dev/null
  before=$(goal export I1)
  try 'goal=I1 pick=b@- away=no' 'already done'
  rm -f "$(payload)"
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board apply --answer 'goal=I1 pick=c1@live away=no')" 'apply without a payload copy refuses'
  assert_contains "$(cat "$TMP_ROOT/out")" 'render the board first' 'the refusal says to render first'
  pass 'apply refuses a malformed answer, an unknown, captain or finished item, an off-ladder stage, and a target without a project'
}

test_apply_result() {
  fixture
  board render --candidates "$H/cands.json" --new-goal-id fresh >/dev/null
  local res="$H/result" out
  printf 'session:\n  file: /drive-board.html\n  status: feedback\nprompts[1]{tag,text,prompt}:\n  "choice","Drive: x","Context data: {\\"question\\":\\"drive.go\\",\\"answer\\":\\"goal=fresh pick=c1@deployed away=no\\"}"\n' > "$res"
  out=$(board apply --result "$res" 2>&1)
  assert_contains "$out" 'goal: started fresh' 'a captured Lavish result is applied'
  assert_equals deployed "$(jq -r '.goals[0].items[0].target' <<< "$(goal export fresh)")" 'the result answer set the target'
  printf 'session:\n  file: /drive-board.html\n  status: feedback\nprompts[1]{tag,text,prompt}:\n  "choice","Other","Context data: {\\"question\\":\\"dispatch.charted\\",\\"answer\\":\\"x\\"}"\n' > "$res"
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" board apply --result "$res")" 'a result without a drive.go answer refuses'
  assert_contains "$(cat "$TMP_ROOT/out")" 'no drive.go answer' 'the refusal names the missing key'
  assert_equals 2 "$(rc_of "$TMP_ROOT/out" board apply)" 'apply needs an answer or a result'
  assert_equals 2 "$(rc_of "$TMP_ROOT/out" board apply --answer x --result y)" 'apply takes only one source'
  pass 'apply reads the drive.go answer from a captured Lavish result and ignores other keys'
}

test_apply_authority() {
  fixture; start_goal
  board render --candidates "$H/cands.json" >/dev/null
  local before
  before=$(goal export I1)
  assert_equals 1 "$(rc_of "$TMP_ROOT/out" env FM_SUPERVISION_ACTOR=branch FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" bash "$BOARD" apply --answer 'goal=I1 pick=c1@live away=yes')" 'the supervision branch cannot apply a drive order'
  assert_equals "$before" "$(goal export I1)" 'a refused branch apply leaves the goal alone'
  assert_equals 1 "$(rc_of "$TMP_ROOT/out2" lab bash "$ROOT/bin/fm-afk-contract.sh" mode)" 'a refused branch apply enters no away record'
  pass 'apply inherits fm-goal.sh authority: only the main actor starts or edits a goal'
}

fm_test_run test_snapshot test_render_page test_render_fail_closed test_apply_edit_and_away \
  test_apply_start test_apply_refusals test_apply_result test_apply_authority
