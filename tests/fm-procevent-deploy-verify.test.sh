#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-deploy-verify.sh.
#
# GitHub is a fake `gh` that serves recorded API answers from files, so every
# case is deterministic and no network is used. A new Tester is a fake spawn that
# leaves a state/<id>.meta record, a live Tester receives the ask through a fake
# fm-send that writes its steering inbox, and the Tester role template and pin live
# in the lab home. Issues are read by the real bin/fm-acceptance.mjs. Each scenario
# runs against an adapter copy, so the mutation proofs at the end remove one guard
# at a time (in the adapter or the parser) and show the scenario that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-verify)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
REPO=huynhtandat223/cfw-modules
RURL="https://github.com/$REPO"

# A herdr that always fails, so no scenario can reach a real terminal session.
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 99\n' > "$TMP_ROOT/fakebin/herdr"
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Serves the recorded answer for `gh api <path>`; a missing file is a failed read.
[ "${1:-}" = api ] || exit 2
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
f="$FAKE_GH_DIR/$(printf '%s' "$2" | tr '/?&=:' '_____')"
printf '%s\n' "$2" >> "$FAKE_GH_DIR/calls.log"
[ -f "$f" ] || exit 1
cat "$f"
SH
chmod +x "$TMP_ROOT/fakebin/herdr" "$TMP_ROOT/fakebin/gh"
export PATH="$TMP_ROOT/fakebin:$PATH"

# ---- lab ------------------------------------------------------------------

new_lab() {  # <bin-dir>: a firstmate home with a Tester role and fake spawn, tasks and send
  LAB=$(mktemp -d "$TMP_ROOT/lab.XXXXXX")
  H="$LAB/home"
  TH="$LAB/tester"
  GHD="$LAB/gh"
  BIN=$1
  SEQ=0
  mkdir -p "$H"/{state,data,config/roles} "$TH/data/pending-mentions" "$GHD"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"  # backlog_task appends under Done
  register_tester
  cat > "$LAB/spawn" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/spawn.calls"
id=\$1
[ ! -f "$H/state/\$id.meta" ] || exit 1
[ ! -e "$LAB/spawn-fail" ] || exit 1
printf 'kind=scout\n' > "$H/state/\$id.meta"
if [ -f "$LAB/claim-race" ]; then
  printf 'kind=ship\n' > "$H/state/racer.meta"
  printf 'racer\\t%s\\n' "\$(date +%s)" > "$H/state/.envlease-company"
  rm "$LAB/claim-race"
fi
SH
  cat > "$LAB/tasks" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/tasks.calls"
case "\$1" in show) exit 1 ;; esac
exit 0
SH
  cat > "$LAB/send" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/send.calls"
[ ! -e "$LAB/send-fail" ] || exit 1
id=\$1; shift
mkdir -p "$H/state/\$id.inbox"
n=\$(find "$H/state/\$id.inbox" -maxdepth 1 -name '*.msg' | wc -l)
printf '%s\n' "\$*" > "$H/state/\$id.inbox/\$(printf '%03d' \$((n + 1))).msg"
SH
  chmod +x "$LAB/spawn" "$LAB/tasks" "$LAB/send"
  export FM_HOME="$H" FAKE_GH_DIR="$GHD" FM_DEPLOY_VERIFY_POLL_SECONDS=0 FM_DEPLOY_VERIFY_ONCE=1
  export FM_DEPLOY_VERIFY_SPAWN="$LAB/spawn" FM_DEPLOY_VERIFY_TASKS="$LAB/tasks" FM_DEPLOY_VERIFY_SEND="$LAB/send"
  unset FAKE_GH_FAIL FM_DEPLOY_VERIFY_MAX_TESTERS
}
register_tester() {
  printf '# Tester template\n\nCheck each row and record its evidence.\n' > "$H/config/roles/tester.md"
  printf '{"harness":"claude","model":"claude-sonnet","effort":"high"}\n' > "$H/config/roles/tester.json"
}
unregister_tester() { rm -f "$H/config/roles/tester.md" "$H/config/roles/tester.json"; }

# ---- recorded GitHub answers -----------------------------------------------

gh_put() { printf '%s\n' "$2" > "$GHD/$(printf '%s' "$1" | tr '/?&=:' '_____')"; }
sha() { printf '%s%s' "$1" "0000000000000000000000000000000000000000" | cut -c1-40; }
fx_runs() {  # <id:status:conclusion:sha-seed>...
  local spec json='[]' id status conclusion seed
  for spec in "$@"; do
    IFS=: read -r id status conclusion seed <<<"$spec"
    json=$(jq -c --argjson id "$id" --arg s "$status" --arg c "$conclusion" --arg h "$(sha "$seed")" \
      '. + [{id: $id, name: "CI", status: $s, conclusion: (if $c == "" then null else $c end), head_sha: $h, html_url: ("https://example.test/runs/" + ($id | tostring))}]' <<<"$json")
  done
  gh_put "repos/$REPO/actions/runs?branch=main&event=push&per_page=30" "$(jq -c '{workflow_runs: .}' <<<"$json")"
}
fx_jobs() {  # <run-id> <conclusion>
  gh_put "repos/$REPO/actions/runs/$1/jobs?per_page=100" \
    "{\"jobs\":[{\"name\":\"Build\",\"conclusion\":\"success\"},{\"name\":\"Deploy Development host (5001)\",\"conclusion\":\"$2\",\"completed_at\":\"2026-10-20T14:30:20Z\"}]}"
}
fx_compare() {  # <base-seed> <head-seed> <commit-seed>...
  local base=$1 head=$2 c json='[]'
  shift 2
  for c in "$@"; do json=$(jq -c --arg s "$(sha "$c")" '. + [{sha: $s}]' <<<"$json"); done
  gh_put "repos/$REPO/compare/$(sha "$base")...$(sha "$head")" "{\"commits\":$json}"
}
fx_commit_prs() {  # <commit-seed> <pr-number:issue-number>...
  local c=$1 spec json='[]'
  shift
  for spec in "$@"; do
    json=$(jq -c --arg u "$RURL/pull/${spec%%:*}" --arg b "Closes #${spec##*:}" \
      '. + [{html_url: $u, merged_at: "2026-10-20T14:00:00Z", base: {ref: "main"}, body: $b}]' <<<"$json")
  done
  gh_put "repos/$REPO/commits/$(sha "$c")/pulls" "$json"
}
issue_body() {  # <id:surface[:draft]>...
  local spec id surface draft
  printf '## Context\n\nSomething.\n\n## Acceptance\n\n'
  for spec in "$@"; do
    IFS=: read -r id surface draft <<<"$spec"
    printf -- '- [ ] %s WHEN a user acts, THE page SHALL answer.\n' "$id"
    if [ -n "$draft" ]; then printf '  - env/page: `firstmate.board.inbox` (draft)\n'; else printf '  - env/page: `firstmate.board`\n'; fi
    printf '  - surface: %s\n' "$surface"
  done
  printf '\n## Notes\n\n- [ ] A99 not an acceptance line\n  - surface: user-visible\n'
}
fx_issue() {  # <number> <id:surface[:draft]>...
  local n=$1
  shift
  gh_put "repos/$REPO/issues/$n" "$(jq -cn --arg b "$(issue_body "$@")" '{body: $b}')"
}
fx_issue_raw() {  # <number> <body>
  gh_put "repos/$REPO/issues/$1" "$(jq -cn --arg b "$2" '{body: $b}')"
}
# A template-form body (the parser's v1 sections, eight fields per scenario).
tpl_scenario() {  # <id> <surface> <page> <widths>
  printf -- '- [ ] %s WHEN a user acts, THE page SHALL answer.\n' "$1"
  printf '  - page: %s\n  - widths: %s\n  - controls: button "Go"\n  - env: Dev 5001\n  - proof: click Go\n  - data: the probe\n  - mock: none\n  - surface: %s\n' "$3" "$4" "$2"
}
tpl_issue_body() {  # <scenarios-text>
  printf '## Context\n\nWhy.\n\n## Requirements\n\nBuild.\n\n## Definition of done\n\nDone.\n\n## Scenarios\n\n%s\n## Mockup\n\nnone\n\n## Links\n\nnone\n\n## Decisions\n\nnone\n' "$1"
}
fx_pr() {  # <number> <state> <head-seed> <issue-number>
  gh_put "repos/$REPO/pulls/$1" "$(jq -cn --arg s "$2" --arg h "$(sha "$3")" --arg b "Part of #$4" '{state: $s, head: {sha: $h}, body: $b}')"
  gh_put "repos/$REPO/commits/$(sha "$3")" '{"commit":{"committer":{"date":"2026-10-20T15:00:00Z"}}}'
}
backlog_task() {  # <task> <pr-number> [issue-number]
  printf -- '- [x] %s - Title%s %s/pull/%s (repo: cfw-modules) (kind: ship) (merged 2026-10-20)\n' \
    "$1" "${3:+ (cfw-modules #$3)}" "$RURL" "$2" >> "$H/data/backlog.md"
}
live_task() {  # <task> <pr-number> [surface]
  printf 'kind=ship\npr=%s/pull/%s\nsurface=%s\n' "$RURL" "$2" "${3:-user-visible}" > "$H/state/$1.meta"
}
set_cursor() { mkdir -p "$H/data/deploy-verify"; printf '{"cursor_run":%s,"last_green_sha":"%s"}\n' "$1" "$(sha "$2")" > "$H/data/deploy-verify/state.json"; }

# ---- drive the adapter as the runner would -----------------------------------

CYCLE_AUTO=none
cycle() {  # one wait; when it returns a result, capture it and autohandle it
  local out inbox="$H/state/procevent-inbox"
  mkdir -p "$H/data/deploy-verify"
  if ! out=$("$BIN/fm-procevent-deploy-verify.sh" wait 2>/dev/null); then
    CYCLE_AUTO=none
    return 0
  fi
  SEQ=$((SEQ + 1))
  mkdir -p "$inbox"
  printf '%s\n' "$out" > "$inbox/deploy-verify.$SEQ.result"
  printf 'deploy-verify\n' > "$inbox/deploy-verify.$SEQ.adapter"
  "$BIN/fm-procevent-deploy-verify.sh" autohandle deploy-verify "$SEQ" "$inbox/deploy-verify.$SEQ.result" >/dev/null 2>&1
  CYCLE_AUTO=$?
  LAST_RESULT=$out
}
ledger() { cat "$H/data/deploy-verify/ledger.jsonl" 2>/dev/null; }
ledger_count() {  # <jq-filter>
  [ -s "$H/data/deploy-verify/ledger.jsonl" ] || { echo 0; return; }
  jq -sc "[.[] | select($1)] | length" "$H/data/deploy-verify/ledger.jsonl"
}
inbox_count() { find "$H/state" -mindepth 2 -maxdepth 2 -path '*.inbox/*.msg' -type f 2>/dev/null | wc -l | tr -d ' '; }
spawn_count() { wc -l < "$LAB/spawn.calls" 2>/dev/null | tr -d ' '; }
asked() {  # Read the delivered payload, not the ledger's copy of the planned ask.
  local f
  for f in "$H"/data/verify-*/brief.md; do
    [ -f "$f" ] || continue
    awk '/^### The ask$/{f=1;next} f && /^```json$/{j=1;next} j && /^```$/{exit} j{print}' "$f"
  done
  for f in "$H"/state/verify-*.inbox/*.msg; do
    [ -f "$f" ] || continue
    grep '^{' "$f"
  done
}

# ---- scenarios: each returns 0 when the behavior holds ------------------------

# Mapping and ledger: two PRs of one task in one deploy give one ask; the next
# deploy that still contains a PR already asked about asks nothing.
scenario_ledger() {
  new_lab "$1"
  backlog_task alpha 11 500; backlog_task alpha 12 500; backlog_task beta 13 600
  fx_issue 500 V1:user-visible A2:internal; fx_issue 600 E10:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1 c2 c3
  fx_commit_prs c1 11:500; fx_commit_prs c2 12:500; fx_commit_prs c3 13:600
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '(.asks | length) == 2' <<<"$LAST_RESULT" >/dev/null || { echo 'the deploy result is not one ask per task'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "asks: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(spawn_count)" = 2 ] || { echo "spawns: $(spawn_count)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "alpha" and (.prs | length) == 2 and .lines == ["V1"] and .issue == "cfw-modules#500"')" = 1 ] \
    || { echo 'task alpha ask is not one ask with both PRs and its one user-visible line'; return 1; }
  # A later green deploy whose range returns PR 11 again.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c4
  fx_commit_prs c4 11:500
  cycle
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "repeat ask recorded: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(spawn_count)" = 2 ] || { echo "repeat reached the Tester: $(spawn_count)"; return 1; }
}

# Skips: internal task, no user-visible line, and no task each send nothing and
# leave a reason in the ledger.
scenario_skips() {
  new_lab "$1"
  live_task inner 21 internal
  fx_pr 21 closed h0 800
  backlog_task plain 22 700; backlog_task noissue 24
  fx_issue 700 A1:internal
  fx_runs "1:completed:success:s0" "2:completed:success:s1"
  fx_jobs 2 success
  fx_compare s0 s1 c1 c2 c3 c4
  fx_commit_prs c1 21:800; fx_commit_prs c2 22:700; fx_commit_prs c3 23:900
  gh_put "repos/$REPO/commits/$(sha c4)/pulls" "[{\"html_url\":\"$RURL/pull/24\",\"merged_at\":\"2026-10-20T14:00:00Z\",\"base\":{\"ref\":\"main\"},\"body\":\"No reference.\"}]"
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "skip did not request attention: $CYCLE_AUTO"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || return 1
  "$BIN/fm-procevent-deploy-verify.sh" silent "$H/state/procevent-inbox/deploy-verify.$SEQ.result" && return 1
  [ "$(inbox_count)" = 0 ] || { echo "an ask was sent: $(inbox_count)"; ledger; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || return 1
  local reason
  for reason in internal no-user-visible-line no-task no-issue; do
    [ "$(ledger_count ".type == \"skip\" and .reason == \"$reason\"")" = 1 ] || { echo "missing skip reason $reason"; return 1; }
  done
}

# A skipped, cancelled or failed deploy asks nothing; the next green deploy
# carries the commits of every run since the last green one.
scenario_not_deployed() {
  new_lab "$1"
  backlog_task alpha 31 500; backlog_task beta 32 600
  fx_issue 500 A1:user-visible; fx_issue 600 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:cancelled:s1" "3:completed:success:s2"
  fx_jobs 2 skipped; fx_jobs 3 success
  fx_compare s0 s2 c1 c2
  fx_commit_prs c1 31:500; fx_commit_prs c2 32:600
  # The cancelled run's own commit must never be asked on its own.
  fx_compare s0 s1 c1
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "asks: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .sha == \"$(sha s2)\"")" = 2 ] || { echo 'asks do not name the green deploy'; return 1; }
  # A run still in progress holds the cursor.
  fx_runs "1:completed:success:s0" "2:completed:cancelled:s1" "3:completed:success:s2" "4:in_progress::s3"
  fx_jobs 4 in_progress
  cycle
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 3 ] || { echo 'cursor moved past a run in progress'; return 1; }
}

# Draft round: each new head of a task PR whose issue has (draft) lines gets one
# ask for those lines; the same head asks nothing; a later head asks again.
scenario_draft() {
  new_lab "$1"
  live_task gamma 41
  fx_issue 900 E10:user-visible:draft A2:user-visible C14:internal:draft
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  fx_pr 41 open h1 900
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask" and .round == "draft"')" = 1 ] || { echo "draft asks: $(ledger_count '.type == "ask" and .round == "draft"')"; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .head == \"$(sha h1)\" and .lines == [\"E10\",\"C14\"] and .task == \"gamma\" and .issue == \"cfw-modules#900\"")" = 1 ] \
    || { echo 'draft ask does not name the task, issue, head and draft lines'; ledger; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the same head produced a second ask'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo 'the same head asked twice'; return 1; }
  fx_pr 41 open h2 900
  cycle
  [ "$(ledger_count '.type == "ask" and .round == "draft"')" = 2 ] || { echo 'the new head was not asked'; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .head == \"$(sha h2)\"")" = 1 ] || return 1
  [ "$(inbox_count)" = 1 ] || { echo "the live Tester got no steer: $(inbox_count)"; return 1; }
  [ "$(spawn_count)" = 1 ] || { echo "a second Tester was spawned for one task: $(spawn_count)"; return 1; }
  # An issue with no draft line asks nothing, and is remembered for that head.
  live_task delta 42
  fx_issue 901 A1:user-visible
  fx_pr 42 open h3 901
  cycle
  [ "$(spawn_count)" = 1 ] || { echo "a PR without draft lines was asked: $(spawn_count)"; return 1; }
  [ "$(ledger_count '.type == "draft-skip" and .reason == "no-draft-lines"')" = 1 ] || return 1
  # A closed PR is not asked.
  live_task eps 43
  fx_pr 43 closed h4 900
  cycle
  [ "$(spawn_count)" = 1 ] || { echo 'a closed PR was asked'; return 1; }
}

# A new Tester is spawned as a scout `verify-<task>-<sha7>`: the backlog item is
# filed, the role pin names the harness, the ask is written into the brief, and the
# brief may write the evidence directory and, before T5, the task's Tester record.
scenario_spawn_brief() {
  new_lab "$1"
  backlog_task alpha 51 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 51:500
  set_cursor 1 s0
  cycle
  local id brief content
  id=$(ledger | jq -r 'select(.type == "ask" and .task == "alpha") | .tester')
  [ "$id" = "verify-alpha-$(sha s2 | cut -c1-7)" ] || { echo "tester id: $id"; return 1; }
  [ -f "$H/state/$id.meta" ] || { echo 'the spawn left no task record'; return 1; }
  [ -d "$H/data/verify/alpha/$id" ] || { echo 'no evidence directory'; return 1; }
  grep -qx -- "verify-alpha-$(sha s2 | cut -c1-7) $ROOT --scout --plan-exempt verify --harness claude --model claude-sonnet --effort high" "$LAB/spawn.calls" \
    || { echo "spawn args: $(cat "$LAB/spawn.calls")"; return 1; }
  grep -q -- "add $id Verify alpha on $(sha s2) for https://github.com/$REPO/issues/500 --kind scout" "$LAB/tasks.calls" \
    || { echo "no backlog item: $(cat "$LAB/tasks.calls")"; return 1; }
  brief="$H/data/$id/brief.md"
  [ -f "$brief" ] || { echo 'no brief'; return 1; }
  grep -q "these exact paths: $H/data/verify/alpha/$id" "$brief" || { echo 'the brief names no evidence path'; return 1; }
  content=$(awk '/^### The ask$/{f=1;next} f && /^```json$/{j=1;next} j && /^```$/{exit} j{print}' "$brief")
  jq -e --arg sha "$(sha s2)" '.schema == "fm-tester-verify.v1" and .round == "deploy" and .task == "alpha" and .issue == "cfw-modules#500" and .sha == $sha and (.prs == ["'"$RURL"'/pull/51"]) and .run == "https://example.test/runs/2"' <<<"$content" >/dev/null \
    || { echo "ask content: $content"; return 1; }
  grep -q 'Check each row and record its evidence.' "$brief" || { echo 'the Tester template did not reach the brief'; return 1; }
  ! grep -q '{FIRSTMATE_SPEC}' "$brief" || { echo 'the filled brief keeps the spec placeholder'; return 1; }
  # A pre-T5 task's Tester record also joins the write paths when the old home names it.
  new_lab "$1"
  backlog_task alpha 52 501
  mkdir -p "$TH/data/verify"
  printf 'surface: user-visible\n' > "$TH/data/verify/alpha.md"
  printf 'kind=assistance\nhome=%s\n' "$TH" > "$H/state/tester.meta"
  fx_issue 501 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c2
  fx_commit_prs c2 52:501
  set_cursor 1 s0
  cycle
  id=$(ledger | jq -r 'select(.type == "ask" and .task == "alpha") | .tester')
  grep -q -- "$TH/data/verify/alpha.md" "$H/data/$id/brief.md" \
    || { echo "the pre-T5 record is not writable: $(cat "$H/data/$id/brief.md")"; return 1; }
}

# An undeliverable ask and an unreadable GitHub each leave one result for the
# wake, retry without sending twice, and stay quiet while the same reason holds.
scenario_failures() {
  new_lab "$1"
  backlog_task alpha 61 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 61:500
  set_cursor 1 s0
  unregister_tester
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "first failure autohandle=$CYCLE_AUTO (want 1: left for the wake)"; return 1; }
  [ ! -e "$H/state/procevent-inbox/deploy-verify.1.handled" ] || { echo 'the failed result was acknowledged'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || return 1
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 1 ] || { echo 'cursor advanced past an undelivered ask'; return 1; }
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "same reason again autohandle=$CYCLE_AUTO (want 0: already announced)"; return 1; }
  register_tester
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "recovery autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo "asks after recovery: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(spawn_count)" = 1 ] || { echo "spawns after recovery: $(spawn_count)"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || { echo 'cursor did not advance after delivery'; return 1; }
  [ -e "$H/state/procevent-inbox/deploy-verify.1.handled" ] || { echo 'the old failed result stayed open after recovery'; return 1; }
  cycle
  [ "$(spawn_count)" = 1 ] || { echo 'a further poll sent the ask again'; return 1; }
  # GitHub unreadable: one result for the wake, then quiet, then a recovery record.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c9
  fx_commit_prs c9 62:501
  export FAKE_GH_FAIL=1
  local before=$SEQ
  cycle
  [ "$CYCLE_AUTO" = 1 ] && [ "$SEQ" = $((before + 1)) ] || { echo "GitHub failure: autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '.error != null and (.asks | length) == 0' "$H/state/procevent-inbox/deploy-verify.$SEQ.result" >/dev/null || { echo 'failure result carries no reason'; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the same GitHub failure produced a second result'; return 1; }
  unset FAKE_GH_FAIL
  cycle
  [ -e "$H/state/procevent-inbox/deploy-verify.$SEQ.handled" ] || { echo 'the GitHub failure result stayed open after recovery'; return 1; }
  [ ! -e "$H/data/deploy-verify/last-error" ] || { echo 'the failure reason was not cleared'; return 1; }
}

# A refused spawn leaves its filled brief; the next poll reuses that brief for the
# same ask, spawns the Tester, records the ask and clears the failure.
scenario_retry_brief() {
  new_lab "$1"
  backlog_task alpha 65 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 65:500
  set_cursor 1 s0
  touch "$LAB/spawn-fail"
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "refused spawn autohandle=$CYCLE_AUTO"; return 1; }
  grep -q 'the Tester spawn was refused' "$H/data/deploy-verify/last-error" || { echo "last-error: $(cat "$H/data/deploy-verify/last-error" 2>/dev/null)"; return 1; }
  rm "$LAB/spawn-fail"
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "retry autohandle=$CYCLE_AUTO: $(cat "$H/data/deploy-verify/last-error" 2>/dev/null)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "alpha"')" = 1 ] || { echo "asks after retry: $(ledger)"; return 1; }
  [ "$(spawn_count)" = 2 ] || { echo "spawn calls: $(spawn_count)"; return 1; }
  [ ! -s "$H/data/deploy-verify/last-error" ] || { echo "the failure stayed: $(cat "$H/data/deploy-verify/last-error")"; return 1; }
  [ "$(asked | jq -s length)" = 1 ] || { echo "the brief holds $(asked | jq -s length) asks"; return 1; }
}

# The real runner: a delivered ask wakes nobody, an undeliverable one wakes once.
scenario_runner() {
  new_lab "$1"
  backlog_task alpha 71 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 71:500
  set_cursor 1 s0
  fm_test_track_procevent_home "$H"
  "$BIN/fm-procevent-deploy-verify.sh" arm >/dev/null 2>&1 || { echo 'arm failed'; return 1; }
  local out
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'autohandled: deploy-verify'*) ;; *) echo "runner: $out"; return 1 ;; esac
  [ "$(spawn_count)" = 1 ] || { echo "spawns: $(spawn_count)"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo "asks: $(ledger_count '.type == "ask"')"; return 1; }
  if [ -s "$H/state/.wake-queue" ]; then echo 'a delivered ask woke firstmate'; return 1; fi
  # A visible skip advances the cursor but publishes one real runner wake.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 cskip
  fx_commit_prs cskip 73:501 74:502 75:503
  backlog_task visible 73 501
  live_task internal 74 internal
  fx_pr 74 closed h0 502
  fx_issue 501 A1:internal
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "skip runner: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue")" = 1 ] || return 1
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 3 ] || return 1
  "$BIN/fm-procevent.sh" handled deploy-verify 2 >/dev/null 2>&1 || return 1
  : > "$H/state/.wake-queue"
  "$BIN/fm-procevent.sh" start deploy-verify >/dev/null 2>&1
  [ ! -s "$H/state/.wake-queue" ] || { echo 'skip woke twice'; return 1; }
  # An undeliverable ask: one wake row naming the source.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3" "4:completed:success:s4"
  fx_jobs 4 success
  fx_compare s3 s4 c2
  fx_commit_prs c2 72:500
  backlog_task beta 72 500
  unregister_tester
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "runner failure: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue" 2>/dev/null || echo 0)" = 1 ] \
    || { echo 'want exactly one wake row'; cat "$H/state/.wake-queue" 2>&1; return 1; }
}

# Every ask carries the parser's rows: one pending row per user-visible scenario
# and width, for a template issue, a legacy issue, the draft round and a replay.
scenario_rows() {
  new_lab "$1"
  # This parser scenario needs three concurrent tasks; the default cap has its own case.
  export FM_DEPLOY_VERIFY_MAX_TESTERS=3
  backlog_task alpha 101 500; backlog_task beta 102 501
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario V1 user-visible home.video '1440, 390'; tpl_scenario V2 user-visible 'home.video (draft)' 1440; tpl_scenario K3 internal - -)")"
  fx_issue 501 E10:user-visible A2:internal
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1 c2
  fx_commit_prs c1 101:500; fx_commit_prs c2 102:501
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  local line='WHEN a user acts, THE page SHALL answer.' content
  content=$(asked | jq -c 'select(.task == "alpha")')
  jq -e --arg l "$line" '.lines == ["V1","V2"] and .rows == [
      "- V1@1440 | \($l) | pending | evidence: -",
      "- V1@390 | \($l) | pending | evidence: -",
      "- V2@1440 | \($l) | pending | evidence: -"]' <<<"$content" >/dev/null || { echo "template ask: $content"; return 1; }
  content=$(asked | jq -c 'select(.task == "beta")')
  jq -e --arg l "$line" '.lines == ["E10"] and .rows == ["- E10@1440 | \($l) | pending | evidence: -", "- E10@390 | \($l) | pending | evidence: -"]' <<<"$content" >/dev/null \
    || { echo "legacy ask: $content"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "alpha" and (.rows | length) == 3')" = 1 ] || { echo 'the ledger ask does not keep its rows'; return 1; }
  # Draft round: only the draft scenarios, whatever their surface.
  live_task gamma 103
  fx_issue 900 E10:user-visible:draft A2:user-visible C14:internal:draft
  fx_pr 103 open h1 900
  cycle
  content=$(asked | jq -c 'select(.round == "draft")')
  jq -e --arg l "$line" '.lines == ["E10","C14"] and .rows == [
      "- E10@1440 | \($l) | pending | evidence: -",
      "- E10@390 | \($l) | pending | evidence: -",
      "- C14@- | \($l) | pending | evidence: -"]' <<<"$content" >/dev/null || { echo "draft ask: $content ledger=$(ledger) spawns=$(cat "$LAB/spawn.calls" 2>/dev/null)"; return 1; }
}

# An issue the parser refuses is a template-refused skip naming the problems. It
# wakes firstmate once, asks nobody, and a repeat of the PR stays quiet. A refused
# draft round is remembered per head. A parser that cannot run is an error result.
scenario_refused() {
  new_lab "$1"
  backlog_task alpha 111 500
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario V1 user-visible home.video '1440, 390'; tpl_scenario V1 internal - -)")"
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 111:500
  set_cursor 1 s0
  fm_test_track_procevent_home "$H"
  "$BIN/fm-procevent-deploy-verify.sh" arm >/dev/null 2>&1 || { echo 'arm failed'; return 1; }
  local out
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "runner: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue")" = 1 ] || { echo 'the refusal did not wake firstmate once'; return 1; }
  [ "$(inbox_count)" = 0 ] || { echo "an ask was sent: $(inbox_count)"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || return 1
  [ "$(ledger_count '.type == "skip" and .reason == "template-refused" and .task == "alpha" and (.detail | contains("duplicate id"))')" = 1 ] \
    || { echo 'no template-refused skip naming the duplicate id'; ledger; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || { echo 'the cursor did not pass the refused deploy'; return 1; }
  # The same PR in a later deploy neither asks nor wakes again.
  "$BIN/fm-procevent.sh" handled deploy-verify 1 >/dev/null 2>&1 || return 1
  : > "$H/state/.wake-queue"
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c4
  fx_commit_prs c4 111:500
  "$BIN/fm-procevent.sh" start deploy-verify >/dev/null 2>&1
  [ ! -s "$H/state/.wake-queue" ] || { echo 'the repeated PR woke firstmate again'; return 1; }
  [ "$(ledger_count '.type == "skip" and .reason == "template-refused"')" = 1 ] || { echo 'the refusal was recorded twice'; return 1; }
  # Draft round: one draft-skip per head, no ask.
  live_task gamma 112
  fx_pr 112 open h1 500
  cycle
  [ "$(ledger_count '.type == "draft-skip" and .reason == "template-refused" and (.detail | contains("duplicate id"))')" = 1 ] || { echo 'the refused draft was not remembered'; ledger; return 1; }
  [ "$(inbox_count)" = 0 ] || { echo 'a refused draft was asked'; return 1; }
  # A parser that cannot run is an error result, not a refusal of the issue.
  new_lab "$1"
  local pbin="$LAB/pbin"
  mkdir -p "$pbin"
  cp "$1"/*.sh "$pbin/"
  BIN=$pbin
  backlog_task alpha 113 500
  fx_issue 500 V1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 113:500
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "a missing parser autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '.error | test("acceptance parser could not run")' "$H/state/procevent-inbox/deploy-verify.$SEQ.result" >/dev/null || { echo "no parser error: $(cat "$H/state/procevent-inbox/deploy-verify.$SEQ.result")"; return 1; }
  [ "$(ledger_count '.type == "skip"')" = 0 ] || { echo 'a missing parser was recorded as a skip'; return 1; }
}

# A template-refused skip is final for its PR, so replay-skips re-reads it too: once
# the issue is corrected the task gets its ask; while it is still refused it asks nothing.
scenario_replay_refused() {
  new_lab "$1"
  set_cursor 2 s2
  backlog_task alpha 121 500
  gh_put "repos/$REPO/pulls/121" "$(jq -cn --arg m "$(sha m121)" '{body:"Closes #500", merge_commit_sha:$m}')"
  gh_put "repos/$REPO/compare/$(sha m121)...$(sha s2)" '{"status":"ahead"}'
  jq -cn --arg p "$RURL/pull/121" '{type:"skip", reason:"template-refused", pr:$p, task:"alpha", detail:"V1 (line 9): duplicate id"}' >> "$H/data/deploy-verify/ledger.jsonl"
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario V1 user-visible home.video '1440, 390'; tpl_scenario V1 internal - -)")"
  local dry
  dry=$("$BIN/fm-procevent-deploy-verify.sh" replay-skips --dry-run 2>"$LAB/err") || { echo 'replay failed on a refused issue'; return 1; }
  [ -z "$dry" ] || { echo "a still-refused issue was replayed: $dry"; return 1; }
  grep -q 'refused: alpha cfw-modules#500: .*duplicate id' "$LAB/err" || { echo "no refusal named on stderr: $(cat "$LAB/err")"; return 1; }
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario V1 user-visible home.video '1440, 390'; tpl_scenario K2 internal - -)")"
  dry=$("$BIN/fm-procevent-deploy-verify.sh" replay-skips --dry-run) || return 1
  jq -se 'length == 1 and .[0].task == "alpha" and .[0].lines == ["V1"] and (.[0].rows | length) == 2' <<<"$dry" >/dev/null || { echo "corrected issue was not replayed: $dry"; return 1; }
  "$BIN/fm-procevent-deploy-verify.sh" replay-skips >/dev/null || return 1
  [ "$(spawn_count)" = 1 ] || { echo "spawns: $(spawn_count)"; return 1; }
}

scenario_replay() {
  new_lab "$1"
  set_cursor 2 s2
  local n before dry
  for n in 81 82 83 84 86; do
    backlog_task "replay$((n / 2))" "$n" 500
    gh_put "repos/$REPO/pulls/$n" "$(jq -cn --arg m "$(sha "m$n")" '{body:"Closes #500", merge_commit_sha:$m}')"
    gh_put "repos/$REPO/compare/$(sha "m$n")...$(sha s2)" '{"status":"ahead"}'
    jq -cn --arg p "$RURL/pull/$n" --arg t "replay$((n / 2))" '{type:"skip", reason:"no-user-visible-line", pr:$p, task:$t}' >> "$H/data/deploy-verify/ledger.jsonl"
  done
  gh_put "repos/$REPO/compare/$(sha m81)...$(sha s2)" '{"status":"behind"}'
  gh_put "repos/$REPO/pulls/84" "$(jq -cn --arg m "$(sha m84)" '{body:"Closes #501", merge_commit_sha:$m}')"
  fx_issue 500 V1:user-visible; fx_issue 501 A1:internal
  jq -cn --arg k "replay:replay43:$(sha s2)" '{type:"ask", round:"deploy", key:$k, prs:[]}' >> "$H/data/deploy-verify/ledger.jsonl"
  # An ask for another task must not hide this task's skip of the same PR.
  jq -cn --arg p "$RURL/pull/82" '{type:"ask", round:"deploy", key:"other-task", task:"other", prs:[$p]}' >> "$H/data/deploy-verify/ledger.jsonl"
  before=$(ledger)
  dry=$("$BIN/fm-procevent-deploy-verify.sh" replay-skips --dry-run) || return 1
  [ "$before" = "$(ledger)" ] && [ "$(inbox_count)" = 0 ] || return 1
  jq -se 'length == 1 and .[0].lines == ["V1"] and (.[0].prs | length) == 2 and (.[0].rows | length) == 2' <<<"$dry" >/dev/null || { echo "bad replay plan: $dry"; return 1; }
  "$BIN/fm-procevent-deploy-verify.sh" replay-skips >/dev/null || return 1
  [ "$(spawn_count)" = 1 ] || return 1
  before=$(ledger)
  [ -z "$("$BIN/fm-procevent-deploy-verify.sh" replay-skips)" ] || return 1
  [ "$before" = "$(ledger)" ] && [ "$(spawn_count)" = 1 ] || return 1
}

# A visible skip is left unhandled so one wake reaches firstmate. A later
# successful result runs the shared catch-up acknowledgement, which must not
# close that skip: the row stays queued and the drain still prints it.
scenario_skip_catchup() {
  new_lab "$1"
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 cskip
  fx_commit_prs cskip 73:501 74:502
  backlog_task visible 73 501
  live_task internal 74 internal
  fx_pr 74 closed h0 502
  fx_issue 501 A1:internal
  set_cursor 2 s2
  fm_test_track_procevent_home "$H"
  "$BIN/fm-procevent-deploy-verify.sh" arm >/dev/null 2>&1 || { echo 'arm failed'; return 1; }
  local out
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "skip runner: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue")" = 1 ] || { echo 'the skip queued no wake'; return 1; }
  # A later result that delivers its ask, before any drain.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3" "4:completed:success:s4"
  fx_jobs 4 success
  fx_compare s3 s4 cdel
  fx_commit_prs cdel 76:504
  backlog_task delivered 76 504
  fx_issue 504 A1:user-visible
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'autohandled: deploy-verify'*) ;; *) echo "later runner: $out"; return 1 ;; esac
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo "the later ask was not delivered: $(ledger_count '.type == "ask"')"; return 1; }
  [ ! -e "$H/state/procevent-inbox/deploy-verify.1.handled" ] || { echo 'the catch-up closed the visible skip'; return 1; }
  # The second runner start announces the still-pending skip again, so one row or more.
  [ "$(grep -c 'procevent:deploy-verify:1' "$H/state/.wake-queue" 2>/dev/null || echo 0)" -ge 1 ] \
    || { echo "the visible skip lost its queued wake row: $(cat "$H/state/.wake-queue" 2>&1)"; return 1; }
  out=$("$BIN/fm-wake-drain.sh" 2>&1)
  case "$out" in *'procevent:deploy-verify:1'*) ;; *) echo "the drain hid the visible skip: $out"; return 1 ;; esac
}

# With the task record shadow on, a delivered ask also reaches the record as a deploy event of its task; a home without the flag writes nothing.
scenario_shadow() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\n' "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  backlog_task alpha 11 500
  fx_issue 500 V1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 11:500
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ ! -s "$LAB/writer.calls" ] || { echo "a home without the flag wrote to the record: $(cat "$LAB/writer.calls")"; return 1; }
  : > "$H/config/task-shadow"
  backlog_task beta 13 600
  fx_issue 600 V1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c3
  fx_commit_prs c3 13:600
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "autohandle=$CYCLE_AUTO"; return 1; }
  unset FM_TASK_SHADOW_WRITER
  grep -q "^event beta deploy --note deploy deploy at $(sha s3): verify ask sent (cfw-modules#600) --key shadow:beta:deploy-[0-9a-f]* --actor shadow --role system$" "$LAB/writer.calls" \
    || { echo "the delivered ask did not reach the record: $(cat "$LAB/writer.calls" 2>&1)"; return 1; }
  [ "$(wc -l < "$LAB/writer.calls" | tr -d ' ')" = 1 ] || { echo "more than the one delivered ask reached the record: $(cat "$LAB/writer.calls")"; return 1; }
}

# A task begun after T5 ('record: rows' in firstmate's record): before its ask goes out, the task record gets the issue's
# user-visible check rows and a deploy event that names the deployed head; a failed record write fails the delivery, so
# the next poll retries it, and the ask tells the Tester the check call that records each result.
scenario_rows_record() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$*" in *"${FAKE_WRITER_FAIL:-@no-fail@}"*) exit 3 ;; esac\ncase "$1" in checks) echo "{\\"rows\\":[]}" ;; esac\n' "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  backlog_task alpha 11 500
  backlog_task beta 12 600
  mkdir -p "$H/data/alpha" "$H/data/beta"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/500\nrecord: rows\n' "$REPO" > "$H/data/alpha/verify.md"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/600\n' "$REPO" > "$H/data/beta/verify.md"
  fx_issue 500 V1:user-visible
  fx_issue 600 V1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 11:500 12:600
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  FAKE_WRITER_FAIL='rows alpha' cycle
  [ "$CYCLE_AUTO" != 0 ] || { unset FM_TASK_SHADOW_WRITER; echo 'a failed record write was handled as delivered'; return 1; }
  if asked | jq -e 'select(.task == "alpha")' >/dev/null || ledger | grep -q '"task":"alpha"'; then
    unset FM_TASK_SHADOW_WRITER; echo "the ask went out before its rows were written: $(ledger)"; return 1
  fi
  asked | jq -e 'select(.task == "beta")' >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo 'the other task lost its ask'; return 1; }
  : > "$LAB/writer.calls"
  cycle
  unset FM_TASK_SHADOW_WRITER
  [ "$CYCLE_AUTO" = 0 ] || { echo "the retry: autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(sed -n 1p "$LAB/writer.calls")" = "rows alpha https://github.com/$REPO/issues/500 --surface user-visible --key deploy-verify:$(ledger | jq -r 'select(.task == "alpha") | .key'):rows --actor deploy-verify --role system" ] \
    || { echo "the rows were not written first: $(cat "$LAB/writer.calls" 2>&1)"; return 1; }
  grep -q "^event alpha deploy --note deploy deploy at $(sha s2): verify ask sent (cfw-modules#500) --head $(sha s2) --touched all --key deploy-verify:[^ ]*:deploy --actor deploy-verify --role system$" "$LAB/writer.calls" \
    || { echo "the rows task deploy event names no head, or a PR with no Scenarios touched line did not touch all: $(cat "$LAB/writer.calls")"; return 1; }
  [ "$(grep -c '^event alpha deploy' "$LAB/writer.calls")" = 1 ] || { echo "the deploy event was written twice: $(cat "$LAB/writer.calls")"; return 1; }
  ! grep -q '^rows beta' "$LAB/writer.calls" || { echo "a task begun before T5 got check rows: $(cat "$LAB/writer.calls")"; return 1; }
  asked | jq -e --arg sha "$(sha s2)" 'select(.task == "alpha") | .check == "bin/fm-task.sh check alpha <id>@<width> pass|fail --evidence <path|url> --head \($sha)"' >/dev/null \
    || { echo "the rows task ask names no check call: $(asked | jq -c 'select(.task == "alpha")')"; return 1; }
  asked | jq -e 'select(.task == "beta") | has("check") | not' >/dev/null || { echo "a task begun before T5 was told to check rows: $(asked | jq -c 'select(.task == "beta")')"; return 1; }
}

# HG2 (firstmate#176 Step 4): a deploy ask lists only the rows the Tester checks on its head. A pass on an earlier
# deployed head carries while no PR of the deploy names its id (`Scenarios touched:`; a PR without the line names
# none): the ask lists it under carried with that head, a task begun after T5 gets the ids on its deploy event, a task
# with nothing due gets no ask (a carry entry in the ledger instead), a later PR that names the id brings the row back,
# and `deploy --dry-run` prints the same ask and writes nothing.
fx_commit_pr_body() {  # <commit-seed> <pr-number> <body>
  gh_put "repos/$REPO/commits/$(sha "$1")/pulls" "$(jq -cn --arg u "$RURL/pull/$2" --arg b "$3" \
    '[{html_url: $u, merged_at: "2026-10-20T14:00:00Z", base: {ref: "main"}, body: $b}]')"
}
scenario_carry() {
  new_lab "$1"
  export FM_DEPLOY_VERIFY_MAX_TESTERS=3
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$1" in checks) cat "%s/checks-$2.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  backlog_task alpha 11 500
  backlog_task beta 12 600
  backlog_task gamma 14 700
  mkdir -p "$H/data/alpha" "$H/data/beta" "$H/data/gamma" "$TH/data/verify"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/500\nrecord: rows\n' "$REPO" > "$H/data/alpha/verify.md"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/600\n' "$REPO" > "$H/data/beta/verify.md"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/700\nrecord: rows\n' "$REPO" > "$H/data/gamma/verify.md"
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario A1 user-visible p 1440; tpl_scenario A2 user-visible p 1440)")"
  fx_issue_raw 600 "$(tpl_issue_body "$(tpl_scenario B1 user-visible p 1440; tpl_scenario B2 user-visible p 1440)")"
  fx_issue_raw 700 "$(tpl_issue_body "$(tpl_scenario C1 user-visible p 1440)")"
  # beta begun before T5: its Tester file has B1 passed on head s1, B2 failed. An old task keeps the old path (the owner,
  # 2026-10-30: no migration), so nothing of it carries and the Tester is asked for every row.
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/600\n## Scenarios\n- B1@1440 | x | pass | evidence: e\n- B2@1440 | x | fail | evidence: e\nverified: tester 1 head=%s acceptance=d\n' "$REPO" "$(sha s1)" > "$TH/data/verify/beta.md"
  # alpha's record: A1 passed on s1 and carries, A2 is pending for the Tester; gamma's record: C1 passed on s1 and carries
  printf '{"task":"alpha","head":"%s","rows":[{"key":"A1@1440","scenarioId":"A1","width":"1440","surface":"user-visible","status":"pass","head":"%s","carried":true,"due":false},{"key":"A2@1440","scenarioId":"A2","width":"1440","surface":"user-visible","status":"pending","head":null,"carried":false,"due":true}]}\n' "$(sha s2)" "$(sha s1)" > "$LAB/checks-alpha.json"
  printf '{"task":"gamma","head":"%s","rows":[{"key":"C1@1440","scenarioId":"C1","width":"1440","surface":"user-visible","status":"pass","head":"%s","carried":true,"due":false}]}\n' "$(sha s2)" "$(sha s1)" > "$LAB/checks-gamma.json"
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1 c2 c4
  fx_commit_pr_body c1 11 "$(printf 'Closes #500\n\nScenarios touched: ???')"
  fx_commit_pr_body c2 12 'Closes #600'
  fx_commit_pr_body c4 14 "$(printf 'Closes #700\nScenarios touched: none')"
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  local dry
  dry=$("$BIN/fm-procevent-deploy-verify.sh" deploy --dry-run --sha "$(sha s2)" --base "$(sha s0)") || { unset FM_TASK_SHADOW_WRITER; echo "deploy --dry-run failed"; return 1; }
  if [ -n "$(ledger)" ] || grep -q '^\(rows\|event\) ' "$LAB/writer.calls" 2>/dev/null; then
    unset FM_TASK_SHADOW_WRITER; echo "the dry run wrote: $(ledger) $(cat "$LAB/writer.calls" 2>&1)"; return 1
  fi
  grep -qx "checks alpha --as-deployed $(sha s2) --touched all" "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "the dry run did not read alpha as deployed: $(cat "$LAB/writer.calls" 2>&1)"; return 1; }
  jq -e '[.asks[] | {task, rows: [.rows[] | split(" | ")[0]], carried: [.carried[].key]}] == [{task: "alpha", rows: ["- A2@1440"], carried: ["A1@1440"]}, {task: "beta", rows: ["- B1@1440", "- B2@1440"], carried: []}, {task: "gamma", rows: [], carried: ["C1@1440"]}]' <<<"$dry" >/dev/null \
    || { unset FM_TASK_SHADOW_WRITER; echo "dry run asks: $(jq -c '[.asks[] | {task, rows, carried}]' <<<"$dry")"; return 1; }
  : > "$LAB/writer.calls"
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "autohandle=$CYCLE_AUTO"; return 1; }
  grep -q "^event alpha deploy .*--head $(sha s2) --touched all --key " "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "alpha's unreadable Scenarios touched line did not touch all: $(cat "$LAB/writer.calls")"; return 1; }
  grep -q "^event gamma deploy .*--head $(sha s2) --touched none --key " "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "gamma's deploy event does not record its PR's none: $(cat "$LAB/writer.calls")"; return 1; }
  asked | jq -e --arg h "$(sha s1)" 'select(.task == "alpha") | (.rows | map(split(" | ")[0])) == ["- A2@1440"] and .lines == ["A2"] and .carried == [{key: "A1@1440", head: $h}]' >/dev/null \
    || { unset FM_TASK_SHADOW_WRITER; echo "alpha ask: $(asked | jq -c 'select(.task == "alpha")')"; return 1; }
  asked | jq -e 'select(.task == "beta") | (.rows | map(split(" | ")[0])) == ["- B1@1440", "- B2@1440"] and .lines == ["B1", "B2"] and .carried == []' >/dev/null \
    || { unset FM_TASK_SHADOW_WRITER; echo "beta ask: $(asked | jq -c 'select(.task == "beta")')"; return 1; }
  ! asked | jq -e 'select(.task == "gamma")' >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo 'gamma had nothing due and still got an ask'; return 1; }
  [ "$(ledger_count '.type == "carry" and .task == "gamma"')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "no carry entry for gamma: $(ledger)"; return 1; }
  # the same result handled again sends and records nothing more
  "$BIN/fm-procevent-deploy-verify.sh" autohandle deploy-verify "$SEQ" "$H/state/procevent-inbox/deploy-verify.$SEQ.result" >/dev/null 2>&1
  [ "$(ledger_count '.type == "carry"')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "a handled carry was recorded again: $(ledger)"; return 1; }
  # the dry run ignores the ledger: the deploy already asked about plans the same asks again
  if ! dry=$("$BIN/fm-procevent-deploy-verify.sh" deploy --dry-run --sha "$(sha s2)" --base "$(sha s0)") \
    || ! jq -e '[.asks[].task] == ["alpha", "beta", "gamma"]' <<<"$dry" >/dev/null; then
    unset FM_TASK_SHADOW_WRITER; echo "a dry run after the deploy: $dry"; return 1
  fi
  # beta is asked for every row again, a PR that names all is recorded on gamma's deploy event and its C1 is due, and
  # gamma's carried PR 14, still in the compare, is not planned again
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c3 c4 c5
  fx_commit_pr_body c3 13 "$(printf 'Closes #600\nScenarios touched: B1')"
  fx_commit_pr_body c5 15 "$(printf 'Closes #700\n- Scenarios touched: `all`')"
  backlog_task beta 13 600
  backlog_task gamma 15 700
  printf '{"task":"gamma","head":"%s","rows":[{"key":"C1@1440","scenarioId":"C1","width":"1440","surface":"user-visible","status":"pass","head":"%s","carried":false,"due":true}]}\n' "$(sha s3)" "$(sha s1)" > "$LAB/checks-gamma.json"
  cycle
  unset FM_TASK_SHADOW_WRITER
  asked | jq -e --arg s "$(sha s3)" 'select(.task == "beta" and .sha == $s) | (.rows | map(split(" | ")[0])) == ["- B1@1440", "- B2@1440"] and .carried == []' >/dev/null \
    || { echo "beta at s3 was not asked for every row: $(asked | jq -c 'select(.task == "beta")')"; return 1; }
  grep -q "^event gamma deploy .*--head $(sha s3) --touched all --key " "$LAB/writer.calls" \
    || { echo "gamma's deploy event does not record all: $(cat "$LAB/writer.calls")"; return 1; }
  asked | jq -e --arg s "$(sha s3)" --arg p "$RURL/pull/15" 'select(.task == "gamma" and .sha == $s) | (.rows | map(split(" | ")[0])) == ["- C1@1440"] and .carried == [] and .prs == [$p]' >/dev/null \
    || { echo "gamma at s3: $(asked | jq -c 'select(.task == "gamma")')"; return 1; }
}

# HG4 (firstmate#176 Step 4): a worker records rows pending with next actor tester on a head, and the Tester gets one
# ask built from the record with exactly those rows and each row's env. For an env with a config/env/<name> file the
# builder reads free RAM, runs the recover command once below the floor and reads again; still below, the ask is held
# with a wait and not sent, and a later poll sends it with the reads, the floor, the recover step and the processes
# never to touch. A row asked on a head is not asked again on that head, and `ask-rows <task> --dry-run` prints the
# ask and writes nothing.
tpl_scenario_env() {  # <id> <env> <widths>
  printf -- '- [ ] %s WHEN a user acts, THE page SHALL answer.\n' "$1"
  printf '  - page: p\n  - widths: %s\n  - controls: button "Go"\n  - env: %s\n  - proof: click Go\n  - data: the probe\n  - mock: none\n  - surface: user-visible\n' "$3" "$2"
}
scenario_rows_ask() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$1" in checks) cat "%s/checks.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  printf 'kind=ship\n' > "$H/state/alpha.meta"
  mkdir -p "$H/data/alpha" "$H/config/env"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/500\nrecord: rows\n' "$REPO" > "$H/data/alpha/verify.md"
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario_env A1 'Dev 5001; DMS env `company`' 1440; tpl_scenario_env A2 'Dev 5001' 1440,390; tpl_scenario_env A3 'Dev 5001' 1440)")"
  # A1@1440 and A2@1440 are pending for the Tester on head h1; A3 is pending with no head (a rows call); A2@390 passed
  printf '{"task":"alpha","state":"running","nextActor":"worker","issueUrl":"https://github.com/%s/issues/500","head":null,"rows":[{"key":"A1@1440","scenarioId":"A1","width":"1440","surface":"user-visible","status":"pending","nextActor":"tester","head":"%s","carried":false,"due":true},{"key":"A2@1440","scenarioId":"A2","width":"1440","surface":"user-visible","status":"pending","nextActor":"tester","head":"%s","carried":false,"due":true},{"key":"A2@390","scenarioId":"A2","width":"390","surface":"user-visible","status":"pass","nextActor":"firstmate","head":"%s","carried":false,"due":false},{"key":"A3@1440","scenarioId":"A3","width":"1440","surface":"user-visible","status":"pending","nextActor":"tester","head":null,"carried":false,"due":true}]}\n' "$REPO" "$(sha h1)" "$(sha h1)" "$(sha h1)" > "$LAB/checks.json"
  # Legacy records stored the bare task id despite issue-backed acceptance.
  jq '.issueUrl = "alpha"' "$LAB/checks.json" > "$LAB/checks.next" && mv "$LAB/checks.next" "$LAB/checks.json"
  printf '3.5\n' > "$LAB/ram"
  printf '# company: the admin PC that runs Titan\nram-read=cat %s/ram\nfloor-gb=6\nrecover=echo ran >> %s/recover.log; echo 4 > %s/ram\nnever-touch=Titan.exe, vsdbg\n' "$LAB" "$LAB" "$LAB" > "$H/config/env/company"
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer" FM_DEPLOY_VERIFY_HOLD_SECONDS=0
  local dry
  dry=$("$BIN/fm-procevent-deploy-verify.sh" ask-rows alpha --dry-run) || { unset FM_TASK_SHADOW_WRITER; echo "ask-rows --dry-run failed: $dry"; return 1; }
  jq -e --arg h "$(sha h1)" '.round == "rows" and .sha == $h and ([.rows[] | split(" | ")[0]] == ["- A1@1440", "- A2@1440"])' <<<"$dry" >/dev/null \
    || { unset FM_TASK_SHADOW_WRITER; echo "dry ask: $dry"; return 1; }
  if [ -n "$(ledger)" ] || [ -e "$LAB/recover.log" ] || grep -q '^event ' "$LAB/writer.calls"; then
    unset FM_TASK_SHADOW_WRITER; echo "the dry run wrote: $(ledger) $(cat "$LAB/writer.calls")"; return 1
  fi
  # below the floor after the recover step: held with a wait, not sent
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "held: autohandle=$CYCLE_AUTO"; return 1; }
  [ -z "$(asked)" ] || { unset FM_TASK_SHADOW_WRITER; echo "a held ask was sent: $(asked)"; return 1; }
  [ "$(cat "$LAB/recover.log" 2>/dev/null)" = ran ] || { unset FM_TASK_SHADOW_WRITER; echo "the recover step did not run once: $(cat "$LAB/recover.log" 2>&1)"; return 1; }
  grep -q "^event alpha wait --next-actor tester --clears-on rows --rows A1@1440,A2@1440 --note .*company.*4 GB.*floor 6 GB.* --key deploy-verify:rows:alpha:[^ ]*:hold --actor deploy-verify --role system$" "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "no wait names the floor: $(cat "$LAB/writer.calls")"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "a held ask is in the ledger: $(ledger)"; return 1; }
  # the next poll finds 4 GB, recovers to 8 GB and sends the ask
  printf 'recover=echo ran >> %s/recover.log; echo 8 > %s/ram\n' "$LAB" "$LAB" > "$LAB/recover.line"
  sed -i "s|^recover=.*|$(sed 's/[|&]/\\&/g' "$LAB/recover.line")|" "$H/config/env/company"
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "sent: autohandle=$CYCLE_AUTO"; return 1; }
  asked | jq -e --arg h "$(sha h1)" 'select(.round == "rows" and .task == "alpha" and .sha == $h)
    | ([.rows[] | split(" | ")[0]] == ["- A1@1440", "- A2@1440"]) and .lines == ["A1", "A2"]
    and .env == {A1: "Dev 5001; DMS env `company`", A2: "Dev 5001"}
    and .envs == [{name: "company", free_gb: 4, floor_gb: 6, recovered: true, free_after_gb: 8, never_touch: ["Titan.exe", "vsdbg"]}]
    and (.check | startswith("bin/fm-task.sh check alpha "))' >/dev/null \
    || { unset FM_TASK_SHADOW_WRITER; echo "rows ask: $(asked)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .round == "rows" and .task == "alpha"')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "ledger: $(ledger)"; return 1; }
  grep -q "^event alpha wait --next-actor tester --clears-on rows --rows A1@1440,A2@1440 --note Tester asked for these rows on $(sha h1) --key deploy-verify:rows:alpha:[^ ]*:wait --actor deploy-verify --role system$" "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "the sent ask wrote no wait: $(cat "$LAB/writer.calls")"; return 1; }
  # a row asked on a head is not asked again on that head: when A3 is pending on h1 too, the next ask holds A3 alone
  cycle
  [ "$(asked | wc -l | tr -d ' ')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "the rows were asked again: $(asked)"; return 1; }
  jq -c --arg h "$(sha h1)" '(.rows[] | select(.key == "A3@1440") | .head) = $h' "$LAB/checks.json" > "$LAB/checks.next" && mv "$LAB/checks.next" "$LAB/checks.json"
  cycle
  unset FM_TASK_SHADOW_WRITER FM_DEPLOY_VERIFY_HOLD_SECONDS
  if [ "$(asked | wc -l | tr -d ' ')" != 2 ] || ! asked | jq -e 'select(.round == "rows" and .lines == ["A3"]) | [.rows[] | split(" | ")[0]] == ["- A3@1440"]' >/dev/null; then
    echo "a new row on the same head: $(asked)"; return 1
  fi
}

# A task whose acceptance is its own task record (`issue: task:<id>`) gets the same rows ask: one ask for the rows
# pending for the Tester on an explicit head, its issue the task id and its issue URL the board link.
scenario_rows_ask_task() {
  new_lab "$1"
  tpl_issue_body "$(tpl_scenario_env V1 'Dev 5001' 1440; tpl_scenario_env V2 'Dev 5001' 1440)" > "$LAB/description"
  printf '#!/usr/bin/env bash\ncase "$1" in document) cat "%s/description" ;; checks) cat "%s/checks.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  printf 'kind=ship\n' > "$H/state/alpha.meta"
  mkdir -p "$H/data/alpha"
  printf 'surface: user-visible\nissue: task:alpha\nrecord: rows\n' > "$H/data/alpha/verify.md"
  printf '{"task":"alpha","state":"running","nextActor":"worker","issueUrl":"alpha","head":null,"rows":[{"key":"V1@1440","scenarioId":"V1","width":"1440","surface":"user-visible","status":"pending","nextActor":"tester","head":"%s","carried":false,"due":true},{"key":"V2@1440","scenarioId":"V2","width":"1440","surface":"user-visible","status":"pending","nextActor":"tester","head":"%s","carried":false,"due":true}]}\n' "$(sha h1)" "$(sha h1)" > "$LAB/checks.json"
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  local dry
  dry=$("$BIN/fm-procevent-deploy-verify.sh" ask-rows alpha --dry-run 2>&1)
  unset FM_TASK_SHADOW_WRITER
  jq -e --arg h "$(sha h1)" '.round == "rows" and .sha == $h and .issue == "alpha" and (.issue_url | contains("task=alpha"))
    and ([.rows[] | split(" | ")[0]] == ["- V1@1440", "- V2@1440"])' <<<"$dry" >/dev/null 2>&1 \
    || { echo "task rows ask: $dry"; return 1; }
}

# HG5 (firstmate#176 G5): the rows ask of an env with a config/env/<name> file claims `env:<name>` for the Tester
# before it is sent. While a worker holds the lease the ask is held with a wait naming the holder (one hold line, no
# RAM read), it goes out at the first poll after the worker releases, and the poll releases the Tester's lease when
# the asked rows land.
scenario_rows_lease() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$1" in checks) cat "%s/checks.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  printf 'kind=ship\n' > "$H/state/alpha.meta"
  printf 'kind=ship\n' > "$H/state/beta.meta"
  mkdir -p "$H/data/alpha" "$H/config/env"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/500\nrecord: rows\n' "$REPO" > "$H/data/alpha/verify.md"
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario_env A1 'DMS env `company`' 1440)")"
  local pending
  pending='{"task":"alpha","state":"running","nextActor":"worker","issueUrl":"https://github.com/%s/issues/500","head":null,"rows":[{"key":"A1@1440","scenarioId":"A1","width":"1440","surface":"user-visible","status":"%s","nextActor":"tester","head":"%s","carried":false,"due":true}]}\n'
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$pending" "$REPO" pending "$(sha h1)" > "$LAB/checks.json"
  printf '9\n' > "$LAB/ram"
  printf 'ram-read=echo read >> %s/ram.log; cat %s/ram\nfloor-gb=6\nnever-touch=Titan.exe\n' "$LAB" "$LAB" > "$H/config/env/company"
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  "$BIN/fm-lease.sh" claim env:company --holder beta || { unset FM_TASK_SHADOW_WRITER; echo 'the worker could not claim env:company'; return 1; }
  cycle
  cycle
  [ -z "$(asked)" ] || { unset FM_TASK_SHADOW_WRITER; echo "an ask went out while beta held env:company: $(asked)"; return 1; }
  [ ! -e "$LAB/ram.log" ] || { unset FM_TASK_SHADOW_WRITER; echo 'the RAM was read while the lease was held elsewhere'; return 1; }
  grep -q "^event alpha wait --next-actor tester --clears-on rows --rows A1@1440 --note .*env:company is leased to beta.* --key deploy-verify:rows:alpha:[^ ]*:hold " "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "no wait names the holder: $(cat "$LAB/writer.calls")"; return 1; }
  [ "$(ledger_count '.type == "hold"')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "hold lines: $(ledger)"; return 1; }
  # the worker releases: the next poll sends the ask under the Tester's lease
  "$BIN/fm-lease.sh" release env:company --holder beta
  : > "$LAB/claim-race"
  cycle
  [ "$(spawn_count)" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo 'race did not spawn its first Tester'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo 'failed claim recorded an ask'; return 1; }
  "$BIN/fm-lease.sh" release env:company --holder racer
  cycle
  [ "$(spawn_count)" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo 'claim retry spawned twice instead of steering'; return 1; }
  asked | jq -e 'select(.round == "rows" and .task == "alpha") | .envs[0].name == "company"' >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo "no ask after the release: $(asked) $(ledger)"; return 1; }
  local tid
  tid="verify-alpha-$(sha h1 | cut -c1-7)"
  [ "$("$BIN/fm-lease.sh" check env:company | cut -d' ' -f1)" = "$tid" ] || { unset FM_TASK_SHADOW_WRITER; echo "the Tester holds no lease: $("$BIN/fm-lease.sh" check env:company 2>&1)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .leases == ["env:company"]')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "the ask records no lease: $(ledger)"; return 1; }
  # a poll before the rows land keeps the lease; the poll after releases it
  cycle
  "$BIN/fm-lease.sh" check env:company >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo 'the lease was released before the rows landed'; return 1; }
  # PR 223 reader round 2: a result on another head than the ask's is not the asked row landing
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$pending" "$REPO" pass "$(sha h0)" > "$LAB/checks.json"
  cycle
  "$BIN/fm-lease.sh" check env:company >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo 'a pass on another head released the lease'; return 1; }
  # Also retain release compatibility for asks sent by the old persistent Tester.
  "$BIN/fm-lease.sh" release env:company --holder "$tid"
  printf 'kind=assistance\n' > "$H/state/tester.meta"
  "$BIN/fm-lease.sh" claim env:company --holder tester
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$pending" "$REPO" pass "$(sha h1)" > "$LAB/checks.json"
  cycle
  unset FM_TASK_SHADOW_WRITER
  ! "$BIN/fm-lease.sh" check env:company >/dev/null 2>&1 || { echo "the lease outlived the rows: $("$BIN/fm-lease.sh" check env:company)"; return 1; }
  [ "$(ledger_count '.type == "release" and .lease == "env:company" and .task == "alpha"')" = 1 ] || { echo "no release line: $(ledger)"; return 1; }
}

# Each Tester holds an env lease under its own id, so two rows asks on one env cannot share it. The first Tester's
# ask takes the lease; the second task's ask is held with a wait naming that Tester's id, reads no RAM, and goes out
# under its own Tester after the first task's rows land and release the lease.
scenario_rows_lease_two() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$1" in checks) cat "%s/checks-$2.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  local t row first second
  row='{"task":"%s","state":"running","nextActor":"worker","issueUrl":"https://github.com/%s/issues/%s","head":null,"rows":[{"key":"A1@1440","scenarioId":"A1","width":"1440","surface":"user-visible","status":"%s","nextActor":"tester","head":"%s","carried":false,"due":true}]}\n'
  mkdir -p "$H/config/env"
  for t in alpha:500:h1 gamma:501:h2; do
    printf 'kind=ship\n' > "$H/state/${t%%:*}.meta"
    mkdir -p "$H/data/${t%%:*}"
    printf 'surface: user-visible\nissue: https://github.com/%s/issues/%s\nrecord: rows\n' "$REPO" "$(cut -d: -f2 <<<"$t")" > "$H/data/${t%%:*}/verify.md"
    fx_issue_raw "$(cut -d: -f2 <<<"$t")" "$(tpl_issue_body "$(tpl_scenario_env A1 'DMS env `company`' 1440)")"
    # shellcheck disable=SC2059 # the row template above is the format
    printf "$row" "${t%%:*}" "$REPO" "$(cut -d: -f2 <<<"$t")" pending "$(sha "${t##*:}")" > "$LAB/checks-${t%%:*}.json"
  done
  printf '9\n' > "$LAB/ram"
  printf 'ram-read=echo read >> %s/ram.log; cat %s/ram\nfloor-gb=6\nnever-touch=Titan.exe\n' "$LAB" "$LAB" > "$H/config/env/company"
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  cycle
  first="verify-alpha-$(sha h1 | cut -c1-7)"
  [ "$(ledger_count '.type == "ask" and .task == "alpha" and .leases == ["env:company"]')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "alpha's ask does not hold the lease: $(ledger)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "gamma"')" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "gamma's ask went out while alpha held the env: $(ledger)"; return 1; }
  [ "$(grep -c '^read' "$LAB/ram.log")" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "gamma read the RAM under another Tester's lease: $(cat "$LAB/ram.log")"; return 1; }
  grep -q "^event gamma wait --next-actor tester --clears-on rows --rows A1@1440 --note .*env:company is leased to $first.* --key deploy-verify:rows:gamma:[^ ]*:hold " "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "gamma's wait does not name alpha's Tester: $(cat "$LAB/writer.calls")"; return 1; }
  [ "$(ledger_count '.type == "release"')" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "a release line while alpha was pending: $(ledger)"; return 1; }
  # alpha's row lands: the lease releases, and gamma's ask spawns its own Tester and claims it.
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$row" alpha "$REPO" 500 pass "$(sha h1)" > "$LAB/checks-alpha.json"
  cycle
  second="verify-gamma-$(sha h2 | cut -c1-7)"
  [ "$(ledger_count '.type == "release" and .lease == "env:company" and (.tasks | sort) == ["alpha"]')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "alpha's landed ask did not release its lease: $(ledger)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "gamma" and .leases == ["env:company"]')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "gamma's ask did not take the released lease: $(ledger)"; return 1; }
  [ "$("$BIN/fm-lease.sh" check env:company | cut -d' ' -f1)" = "$second" ] || { unset FM_TASK_SHADOW_WRITER; echo "gamma's Tester holds no lease: $("$BIN/fm-lease.sh" check env:company 2>&1)"; return 1; }
  unset FM_TASK_SHADOW_WRITER
}

# A rows ask whose send fails gives back only a lease no other ask holds: the first ask of one task holds
# `env:company` for its Tester, the second ask on another head of the same task fails to send, and the lease the
# first ask's pending row needs stays.
scenario_rows_lease_failed_send() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\ncase "$1" in checks) cat "%s/checks.json" ;; esac\n' "$LAB" "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  : > "$H/config/task-shadow"
  local id row
  row='{"task":"alpha","state":"running","nextActor":"worker","issueUrl":"https://github.com/%s/issues/500","head":null,"rows":[{"key":"A1@1440","scenarioId":"A1","width":"1440","surface":"user-visible","status":"%s","nextActor":"tester","head":"%s","carried":false,"due":true},{"key":"A1@390","scenarioId":"A1","width":"390","surface":"user-visible","status":"%s","nextActor":"tester","head":"%s","carried":false,"due":true}]}\n'
  printf 'kind=ship\n' > "$H/state/alpha.meta"
  mkdir -p "$H/data/alpha" "$H/config/env"
  printf 'surface: user-visible\nissue: https://github.com/%s/issues/500\nrecord: rows\n' "$REPO" > "$H/data/alpha/verify.md"
  fx_issue_raw 500 "$(tpl_issue_body "$(tpl_scenario_env A1 'DMS env `company`' 1440,390)")"
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$row" "$REPO" pending "$(sha h1)" pending "$(sha h2)" > "$LAB/checks.json"
  printf '9\n' > "$LAB/ram"
  printf 'ram-read=cat %s/ram\nfloor-gb=6\nnever-touch=Titan.exe\n' "$LAB" > "$H/config/env/company"
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  : > "$LAB/send-fail"
  cycle
  id="verify-alpha-$(sha h1 | cut -c1-7)"
  [ "$(ledger_count '.type == "ask" and .task == "alpha" and .leases == ["env:company"]')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "alpha's first ask does not hold the lease: $(ledger)"; return 1; }
  [ "$("$BIN/fm-lease.sh" check env:company 2>/dev/null | cut -d' ' -f1)" = "$id" ] \
    || { unset FM_TASK_SHADOW_WRITER; echo "the failed second send gave back the lease the first ask holds: $("$BIN/fm-lease.sh" check env:company 2>&1)"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "the failed ask was recorded: $(ledger)"; return 1; }
  rm -f "$LAB/send-fail"
  cycle
  [ "$(ledger_count '.type == "ask" and .task == "alpha"')" = 2 ] || { unset FM_TASK_SHADOW_WRITER; echo "the retried ask was not delivered: $(ledger)"; return 1; }
  [ "$(inbox_count)" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "the live Tester got no steer: $(inbox_count)"; return 1; }
  # Both asks now hold the lease under one Tester: one landing keeps it, both release it once.
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$row" "$REPO" pass "$(sha h1)" pending "$(sha h2)" > "$LAB/checks.json"
  cycle
  "$BIN/fm-lease.sh" check env:company >/dev/null || { unset FM_TASK_SHADOW_WRITER; echo "one landing released the lease another ask holds: $(ledger)"; return 1; }
  # shellcheck disable=SC2059 # the row template above is the format
  printf "$row" "$REPO" pass "$(sha h1)" pass "$(sha h2)" > "$LAB/checks.json"
  cycle
  unset FM_TASK_SHADOW_WRITER
  ! "$BIN/fm-lease.sh" check env:company >/dev/null 2>&1 || { echo "the lease outlived both asks: $("$BIN/fm-lease.sh" check env:company)"; return 1; }
  [ "$(ledger_count '.type == "release" and .lease == "env:company" and (.keys | length) == 2')" = 1 ] || { echo "no one release line naming both asks: $(ledger)"; return 1; }
}

# A later ask for the same task goes to its live Tester through the steering inbox,
# not to a second spawn, and the ledger names the same tester.
scenario_live_tester() {
  new_lab "$1"
  backlog_task alpha 51 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 51:500
  set_cursor 1 s0
  cycle
  local id
  id=$(ledger | jq -r 'select(.type == "ask" and .task == "alpha") | .tester')
  [ -f "$H/state/$id.meta" ] || { echo 'the first ask spawned no Tester'; return 1; }
  [ "$(spawn_count)" = 1 ] || { echo "spawns: $(spawn_count)"; return 1; }
  # A second deploy of the same task on a new head.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c2
  fx_commit_prs c2 52:500
  backlog_task alpha 52 500
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(spawn_count)" = 1 ] || { echo "a second Tester was spawned for one task: $(spawn_count)"; return 1; }
  [ "$(inbox_count)" = 1 ] || { echo "the live Tester got no steer: $(inbox_count)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "alpha"')" = 2 ] || { echo "asks: $(ledger)"; return 1; }
  [ "$(ledger | jq -r 'select(.type == "ask" and .task == "alpha") | .tester' | sort -u)" = "$id" ] \
    || { echo 'the second ask names another tester'; return 1; }
  grep -q -- "\"sha\":\"$(sha s3)\"" "$H/state/$id.inbox/001.msg" || { echo 'the steer does not carry the new ask'; return 1; }
  # A new ask on the same head after cleanup needs a fresh, dispatchable id.
  rm "$H/state/$id.meta"
  jq '.asks |= map(.key += ":again")' "$H/state/procevent-inbox/deploy-verify.$SEQ.result" > "$LAB/again.result"
  "$BIN/fm-procevent-deploy-verify.sh" autohandle deploy-verify 99 "$LAB/again.result" >/dev/null 2>&1
  [ -f "$H/state/verify-alpha-$(sha s3 | cut -c1-7).meta" ] || { echo 'new head did not get its own Tester id'; return 1; }
  rm "$H/state/verify-alpha-$(sha s3 | cut -c1-7).meta"
  jq '.asks |= map(.key += ":third")' "$LAB/again.result" > "$LAB/third.result"
  "$BIN/fm-procevent-deploy-verify.sh" autohandle deploy-verify 100 "$LAB/third.result" >/dev/null 2>&1
  [ -f "$H/state/verify-alpha-$(sha s3 | cut -c1-7)-2.meta" ] || { echo 'same-head re-ask reused the closed Tester id'; return 1; }
}

# The live Tester cap holds a further new Tester's ask: the task gets a wait naming
# the cap, the ledger a cap hold, the poll does not advance its cursor, and the ask
# goes out once a Tester is gone.
scenario_cap() {
  new_lab "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/writer.calls"\n' "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  backlog_task alpha 11 500; backlog_task beta 12 501; backlog_task gamma 13 502
  fx_issue 500 A1:user-visible; fx_issue 501 A1:user-visible; fx_issue 502 A1:user-visible
  mkdir -p "$H/data/gamma"
  printf 'record: rows\n' > "$H/data/gamma/verify.md"
  printf '\ncase "$1" in checks) echo '\''{"rows":[]}'\'' ;; esac\n' >> "$LAB/writer"
  printf 'kind=ship\n' > "$H/state/verify-not-a-tester.meta"
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1 c2 c3
  fx_commit_prs c1 11:500; fx_commit_prs c2 12:501; fx_commit_prs c3 13:502
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(spawn_count)" = 2 ] || { unset FM_TASK_SHADOW_WRITER; echo "spawns: $(spawn_count)"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { unset FM_TASK_SHADOW_WRITER; echo "asks: $(ledger)"; return 1; }
  [ "$(ledger_count '.type == "hold" and .cap == 2')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo "cap holds: $(ledger)"; return 1; }
  grep -q "^event gamma wait --next-actor tester --clears-on rows .*--note .*live Tester cap 2 reached" "$LAB/writer.calls" \
    || { unset FM_TASK_SHADOW_WRITER; echo "no wait names the cap: $(cat "$LAB/writer.calls")"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo 'the cursor advanced past a held ask'; return 1; }
  cycle
  [ "$(ledger_count '.type == "hold" and .cap == 2')" = 1 ] || { unset FM_TASK_SHADOW_WRITER; echo 'the repeated cap hold duplicated its ledger line'; return 1; }
  # A legacy task has no task-record rows: a cap hold must not call its writer.
  rm "$H/data/gamma/verify.md"
  printf '#!/usr/bin/env bash\nexit 5\n' > "$LAB/writer"
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { unset FM_TASK_SHADOW_WRITER; echo 'legacy cap hold called the task writer'; return 1; }
  # A historical hold cannot hide a failed delivery after capacity clears.
  unregister_tester
  rm -f "$H/state/$(ledger | jq -r 'select(.type == "ask") | .tester' | head -1).meta"
  cycle
  if "$BIN/fm-procevent-deploy-verify.sh" silent "$H/state/procevent-inbox/deploy-verify.$SEQ.result"; then
    unset FM_TASK_SHADOW_WRITER; echo 'historical hold hid the missing role failure'; return 1
  fi
  register_tester
  # One Tester's record goes away: the next poll spawns the held task's Tester.
  rm -f "$H/state/$(ledger | jq -r 'select(.type == "ask") | .tester' | head -1).meta"
  cycle
  unset FM_TASK_SHADOW_WRITER
  [ "$(spawn_count)" = 3 ] || { echo "the held ask did not spawn after the cap freed: $(spawn_count)"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 3 ] || { echo "asks: $(ledger)"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || { echo 'the cursor did not advance after delivery'; return 1; }
}

scenario_task_native() {
  new_lab "$1"
  backlog_task alpha 11 ''
  mkdir -p "$H/data/alpha"
  printf 'surface: user-visible\nissue: task:alpha\n' > "$H/data/alpha/verify.md"
  : > "$H/config/task-shadow"
  issue_body V1:user-visible > "$LAB/description"
  printf '#!/usr/bin/env bash\ncase "$1" in document) cat "%s/description" ;; checks) echo "{\\"rows\\":[]}" ;; esac\n' "$LAB" > "$LAB/writer"
  chmod +x "$LAB/writer"
  export FM_TASK_SHADOW_WRITER="$LAB/writer"
  fx_runs '1:completed:success:s0' '2:completed:success:s2'
  fx_jobs 2 success
  fx_compare s0 s2 c1
  gh_put "repos/$REPO/commits/$(sha c1)/pulls" "$(jq -cn --arg u "$RURL/pull/11" '[{html_url:$u, merged_at:"2026-10-20T14:00:00Z",base:{ref:"main"},body:"No issue or task marker"}]')"
  set_cursor 1 s0
  cycle
  unset FM_TASK_SHADOW_WRITER
  asked | jq -e 'select(.task == "alpha" and .issue == "alpha" and (.issue_url | contains("task=alpha")))' >/dev/null || { echo 'task-native ask missing'; return 1; }
}

run_scenarios() {  # <bin-dir>
  local s rc=0
  for s in ledger skips not_deployed draft spawn_brief retry_brief failures runner live_tester cap skip_catchup rows refused replay replay_refused shadow rows_record carry rows_ask rows_lease rows_lease_two rows_lease_failed_send; do
    out=$(scenario_"$s" "$1" 2>&1) || { printf 'scenario %s: %s\n' "$s" "$out"; rc=1; }
  done
  return $rc
}

# ---- real adapter -----------------------------------------------------------

for s in task_native ledger skips not_deployed draft spawn_brief retry_brief failures runner live_tester cap skip_catchup rows refused replay replay_refused shadow rows_record carry rows_ask rows_ask_task rows_lease rows_lease_two rows_lease_failed_send; do
  out=$(scenario_"$s" "$ROOT/bin" 2>&1) || fail "scenario $s failed on the real adapter: $out"
  pass "deploy-verify $s"
done

# ---- mutation proofs: remove one guard, the scenario guarding it goes red ------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT"/bin/*.sh "$ROOT"/bin/fm-acceptance.mjs "$MBIN/"
ADAPTER="$MBIN/fm-procevent-deploy-verify.sh"
PARSER="$MBIN/fm-acceptance.mjs"
cp "$ADAPTER" "$TMP_ROOT/adapter.orig"
cp "$PARSER" "$TMP_ROOT/parser.orig"

mutate() {  # <label> <scenario> <perl-substitution>
  cp "$TMP_ROOT/adapter.orig" "$ADAPTER"
  perl -0pi -e "$3" "$ADAPTER"
  cmp -s "$TMP_ROOT/adapter.orig" "$ADAPTER" && fail "mutation '$1' changed nothing"
  if out=$(scenario_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left scenario $2 green"
  fi
  pass "guard '$1' is needed: scenario $2 goes red without it"
}

# The same proof against the parser copy, for a guard that lives in bin/fm-acceptance.mjs.
mutate_parser() {  # <label> <scenario> <perl-substitution>
  cp "$TMP_ROOT/parser.orig" "$PARSER"
  perl -0pi -e "$3" "$PARSER"
  cmp -s "$TMP_ROOT/parser.orig" "$PARSER" && fail "mutation '$1' changed nothing"
  if out=$(scenario_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left scenario $2 green"
  fi
  cp "$TMP_ROOT/parser.orig" "$PARSER"
  pass "guard '$1' is needed: scenario $2 goes red without it"
}

mutate 'replay reads template-refused skips' replay_refused \
  's/(unique_by[^\n]*) or \.reason == "template-refused"/$1/'
mutate 'replay dedupe is task scoped' replay \
  's/ and \.task == \$t and \(\.prs/ and (.prs/'
mutate 'replay ancestry' replay \
  's/jq -e .\.status == "ahead" or \.status == "identical". <<<"\$comparison" >\/dev\/null \|\| continue/:/'
mutate 'replay dry run' replay \
  's/if \[ "\$dry" -eq 1 \]; then/if false; then/'
mutate 'replay visible lines' replay \
  's/\[ -n "\$lines" \] \|\| continue/:/'
mutate 'replay grouping' replay \
  's/cut -d.\|. -f1 "\$w\/rows" \| sort -u/cut -d"|" -f1 "\$w\/rows"/'
mutate 'replay idempotency' replay \
  's/ledger_has_key "replay:\$task:\$sha" && continue/:/; s/ledger_test .\.type == "ask" and \.round == "deploy" and \.task == \$t and \(\.prs \| index\(\$p\)\). --arg p "\$pr" --arg t "\$task" && continue/:/'
mutate_parser 'non-A acceptance ids' ledger \
  's/\[A-Z\]\+\[0-9\]\+\)\(\?=/A[0-9]+)(?=/'
mutate_parser 'non-A draft ids' draft \
  's/\[A-Z\]\+\[0-9\]\+\)\(\?=/A[0-9]+)(?=/'
mutate 'the ask carries the rows' rows \
  's/head, pushed, lines, rows, touched/head, pushed, lines, touched/'
mutate 'draft rows are the draft scenarios' rows \
  's/\[ "\$mode" != draft \] \|\| flag=--draft/:/'
mutate 'a refused issue wakes firstmate' refused \
  's/ or \.reason == "template-refused"\)/)/'
mutate 'a refusal names its problems' refused \
  's/ \+ \(if \$d == "" then \{\} else \{detail: \$d\} end\)//'
mutate_parser 'the parser refuses a duplicate id' refused \
  's/seen\.has\(scenario\.id\)/false/'
mutate 'a parser refusal is a skip' refused \
  's/if \[ "\$rc" -ne 0 \]; then\n    ISSUE_PROBLEMS/if false; then\n    ISSUE_PROBLEMS/'
mutate 'a parser that cannot run is an error' refused \
  's/if ! jq -e .\.schema == "fm-acceptance\.v1". <<<"\$parsed" >\/dev\/null 2>&1; then/if false; then/'
mutate 'visible skips need attention' skips \
  's/attention_skip "\$result" && return 1/:/g'
mutate 'ledger: a PR already asked is skipped' ledger \
  's/ledger_pr_final "\$url" "\$task" && continue//'
mutate 'one ask per task' ledger \
  's/tasks=\$\(cut -d.\|. -f1 "\$w\/rows.psv" \| sort -u\)/tasks=\$(cut -d"|" -f1 "\$w\/rows.psv")/'
mutate 'internal tasks are skipped' skips \
  's/if \[ "\$surface" = internal \]; then\n      while/if false; then\n      while/'
mutate 'issues with no user-visible line are skipped' skips \
  's/if \[ -z "\$lines" \]; then\n      while/if false; then\n      while/'
mutate 'only a green deploy job asks' not_deployed \
  's/if \[ "\$conclusion" = success \]; then/if true; then/'
mutate 'a run in progress holds the cursor' not_deployed \
  's/\[ "\$status" = completed \] \|\| break/:/'
mutate 'draft asks once per head' draft \
  's/ledger_has_key "\$key" && continue//'
mutate 'draft asks name only the draft lines' draft \
  's/read_acceptance draft/read_acceptance visible/'
mutate 'the catch-up leaves a visible skip pending' skip_catchup \
  's/keep_pending_result\(\) \{ attention_skip "\$1"; \}/keep_pending_result() { return 1; }/'
mutate 'a repeated failure stays quiet' failures \
  's/\[ "\$previous" = "\$reason" \] \|\| return 1//'
mutate 'a failed delivery keeps the cursor' failures \
  's/if \[ "\$failed" -eq 1 \]; then/if false; then/'
mutate 'an unread GitHub is left for the wake' failures \
  's/jq -e .\.error == null. "\$result" >\/dev\/null 2>&1 \|\| return 1/:/'
mutate 'a delivered ask reaches the task record' shadow \
  's/^[^\n]*fm-task-shadow\.sh" deploy-verify[^\n]*\n//m'
mutate 'a rows task ask names the check call' rows_record \
  's/if rows_task "\$task"; then/if false; then/g'
mutate 'a refused record write fails the delivery' rows_record \
  's/record_rows "\$ask" \|\| return 1/record_rows "\$ask" || true/'
mutate 'the deploy round names the deployed head' rows_record \
  's/head=\(--head "\$\(jq -r \.sha <<<"\$ask"\)"\)/head=()/'
mutate 'the deploy event is written once, by the rows path' rows_record \
  's/ \|\| \[ "\$rows_task" = 1 \]//'
mutate 'a PR names the scenarios it touches' carry \
  's/print \(o != "" \? o : \(z \? "none" : "all"\)\); found = 1; exit/print "all"; found = 1; exit/'
mutate 'a PR with no Scenarios touched line touches all' rows_record \
  's/END \{ if \(!found\) print "all" \}/END { if (!found) print "none" }/'
mutate 'an unreadable Scenarios touched line touches all' carry \
  's/\(z \? "none" : "all"\)/(z ? "none" : "none")/'
mutate 'one PR that names all touches every row' carry \
  's/\$0 == "all" \{ a = 1 \}/$0 == "all" { a = 0 }/'
mutate 'a deploy ask drops its carried rows' carry \
  's/carried=\$\(carried_rows "\$ask" "\$2"\) \|\| return 1/carried="[]"/'
mutate 'a record row carries when it is a pass that is not due' carry \
  's/select\(\.status == "pass" and \(\.due \| not\)\)/select(false)/'
mutate 'nothing due sends no ask' carry \
  's/if jq -e .\.round == "deploy" and \(\.rows \| length\) == 0/if false \&\& jq -e ".round" and (.rows | length) == 0/'
mutate 'a handled carry is not recorded again' carry \
  's/\.type == "ask" or \.type == "carry" or \.type == "draft-skip"/.type == "ask" or .type == "draft-skip"/'
mutate 'a carried PR is final' carry \
  's/\(\(\.type == "ask" or \.type == "carry"\) and \.round == "deploy"/((.type == "ask") and .round == "deploy"/'
mutate 'the deploy event records the touched ids' carry \
  's/^[^\n]*head\+=\(--touched[^\n]*\n//m'
mutate 'the dry run reads the record as deployed' carry \
  's/checks "\$task" --as-deployed "\$sha" --touched "\$touched"/checks "\$task"/'
mutate 'the dry run ignores the ledger' carry \
  's/PLAN_IGNORE_LEDGER=1/PLAN_IGNORE_LEDGER=0/'
mutate 'a rows ask holds only rows pending for the Tester' rows_ask \
  's/select\(\.surface == "user-visible" and \.status == "pending" and \.nextActor == "tester" and \.head == \$h\)/select(.head == \$h)/'
mutate 'a row asked on a head is not asked again' rows_ask \
  's/<\(\[ ! -f "\$LEDGER" \] \|\| jq -Rr --arg t/<(true || jq -Rr --arg t/'
mutate 'the poll plans the rows asks' rows_ask \
  's/^[^\n]*plan_rows \|\| \{[^\n]*\n//m'
mutate 'a rows ask names each row env' rows_ask \
  's/env: \(\$envs \| with_entries\(select\(\.key as \$id \| \$lines \| index\(\$id\)\)\)\)/env: \$envs/'
mutate 'an env gate applies to the env the rows name' rows_ask \
  's/jq -e --arg n "\$name" .any\(/jq -e --arg n "\$name" '"'"'false and any(/'
mutate 'below the floor the recover step runs' rows_ask \
  's/if below "\$free" "\$floor" && \[ -n "\$recover" \]; then/if false; then/'
mutate 'still below the floor the ask is held' rows_ask \
  's/! below "\$\{after:-\$free\}" "\$floor" \|\| GATE_HELD=/true || GATE_HELD=/'
mutate 'a held ask is planned again after its hold' rows_ask \
  's/\[ -z "\$held_at" \] \|\| \[ \$\(\(now - held_at\)\) -ge "\$\{FM_DEPLOY_VERIFY_HOLD_SECONDS:-600\}" \] \|\| continue/[ -z "\$held_at" ] || continue/'
mutate 'a sent rows ask writes its wait' rows_ask \
  's/^[^\n]*rows_wait "\$ask" wait [^\n]*\n//m'
mutate 'ask-rows --dry-run sends nothing' rows_ask \
  's/if \[ "\$dry" = 0 \] && ! deliver_ask "\$ask"; then/if ! deliver_ask "\$ask"; then/'
mutate 'another holder of the env lease holds the ask' rows_lease \
  's/\[ "\$\{out##\* \}" = live \] && \[ "\$\{out%% \*\}" != "\$tester" \] \|\| continue/continue/'
mutate 'a lease hold reads no RAM' rows_lease \
  's/if \[ "\$lease_hold" = 0 \]; then/if true; then/'
mutate 'a held lease keeps one hold line' rows_lease \
  's/\[ "\$lease_hold" = 1 \] && ledger_test/false \&\& ledger_test/'
mutate 'a lease hold is planned again at every poll' rows_lease \
  's/ and \(\.lease \| not\)//'
mutate 'a sent ask claims the env lease for the Tester' rows_lease \
  's/if ! out=\$\(env_lease claim/if false \&\& ! out=\$(env_lease claim/'
mutate 'the poll releases the lease of landed rows' rows_lease \
  's/^  release_landed_leases\n//m'
mutate 'pending rows keep the lease' rows_lease \
  's/; \.status != "pending" and/; true and/'
mutate 'every ask holding a lease must land before its release' rows_lease_failed_send \
  's/done < <\(jq -c .\.\[\]. <<<"\$asks"\)/done < <(jq -c "first" <<<"\$asks")/'
mutate 'a failed send keeps a lease another ask holds' rows_lease_failed_send \
  's/^[^\n]*lease_asks "\$lease" \| jq length[^\n]*\n//m'
mutate 'a landed row is a result on the ask'"'"'s head' rows_lease \
  's/\.status != "pending" and \.head == \$h\)/.status != "pending")/'
mutate 'a live Tester receives the ask instead of a second spawn' live_tester \
  's/\[ -n "\$id" \] && \[ -f "\$STATE\/\$id\.meta" \] \|\| return 1/return 1/'
mutate 'a live Tester gets the ask in its inbox' live_tester \
  's/if ! FM_HOME=\$FM_HOME "\$SEND_CMD" "\$id" "\$text" >\/dev\/null 2>&1; then/if false; then/'
mutate 'the live Tester cap holds a further ask' cap \
  's/-ge "\$MAX_TESTERS"/-ge 0/g'
mutate 'a held ask keeps the cursor' cap \
  's/\[ "\$held" -eq 0 \] && jq -e/true \&\& jq -e/'
mutate 'a new Tester id names the task and head' spawn_brief \
  's/base="verify-\$task-\$\{sha:0:7\}"/base="verify"/'
mutate 'a missing role refuses the spawn' failures \
  's/if \[ ! -f "\$role_md" \] \|\| \[ ! -f "\$role_json" \]; then/if false; then/; s/if \[ -z "\$harness" \]; then/if false; then/'
mutate 'the spawn brief carries the ask' spawn_brief \
  's/fill_brief "\$brief" "\$intent" "\$spec"/true/'
mutate 'the Tester spawn passes the plan gate on its verify exemption' spawn_brief \
  's/ --scout --plan-exempt verify --harness/ --scout --harness/'
mutate 'the filled brief drops the spec placeholder' spawn_brief \
  's/^[^\n]*FIRSTMATE_SPEC[^\n]*\{ next \}\n//m'
mutate 'a retry reuses the filled brief of the same ask' retry_brief \
  's/if \[ -f "\$brief" \] && \[ "\$\(brief_ask "\$brief"\)" = "\$content" \]; then/if false; then/'
mutate 'the spawn names the evidence directory' spawn_brief \
  's/args=\( "\$id" firstmate --scout --also-write "\$evidence" \)/args=( "$id" firstmate --scout )/'
mutate 'legacy cap holds do not require a task record' cap \
  's/if rows_task "\$\(jq -r \.task <<<"\$1"\)"; then/if true; then/'
mutate 'historical holds cannot hide a delivery failure' cap \
  's/grep -Fxq -- "\$\(jq -r \.key <<<"\$ask"\)" "\$result.holds" 2>\/dev\/null/ledger_test '\''.type == "hold"'\''/'
mutate 'only Tester scouts consume the cap' cap \
  's/ && grep -qx '\''kind=scout'\'' "\$f"//'
mutate 'legacy Tester leases still release' rows_lease \
  's/tester\|verify-\*/verify-*/'
mutate 'a claimed-race retry finds its live Tester' rows_lease \
  's/id=\$\(tester_id_for_ask "\$2"\)/id=missing/'
mutate 'a used closed Tester id gets a suffix' live_tester \
  's/if ! ledger_test '\''.type == "ask" and .tester == \$id'\'' --arg id "\$id"/if true/'
mutate 'task-native deployment honors the recorded source' task_native \
  's/issue=\$\(recorded_acceptance[^\n]*/issue=""/g'
pass 'every guarded behavior has a red mutation proof'
