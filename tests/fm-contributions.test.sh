#!/usr/bin/env bash
# Published-contribution behavior through Bearings and the authenticated checks.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$home"
}

bearings() {
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_BEARINGS_NOW="$NOW" "$ROOT/bin/fm-bearings-snapshot.sh" --json
}

record() { # home id number forge-state mergeability [hold]
  local home=$1 id=$2 number=$3 state=$4 mergeable=$5 hold=${6:-}
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship) %s\n' \
    "$id" "$id" "$number" "$hold" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" \
    --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" --arg mergeable "$mergeable" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:$mergeable,
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/$id/contributions.json"
}

mutate_record() {
  jq "$3" "$1/data/$2/contributions.json" > "$1/update.json" || fail 'fixture mutation failed'
  mv "$1/update.json" "$1/data/$2/contributions.json"
}

test_actor_coverage() {
  local home out
  home=$(new_home actors)
  record "$home" own 1 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" repair 2 open conflicting
  record "$home" external 3 open mergeable
  record "$home" landed 4 merged mergeable
  out=$(bearings "$home") || fail 'Bearings could not read contribution fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 4 and .contributions.checked == 4
    and .contributions.counts == {captain:1,fleet:1,maintainer:1,nobody:1}
    and (.contributions.captain | length) == 1
    and .contributions.captain[0].url == "https://github.com/o/r/pull/1"
    and .contributions.complete == true and .contributions.proven_clear == false' >/dev/null \
    || fail "published deliveries must report actors and measured coverage: $out"
  pass 'only required-captain contributions are rows; other actors are counted'
}

test_stale_verdict() {
  local home out
  home=$(new_home stale)
  record "$home" changed 5 open mergeable
  mutate_record "$home" changed ".records[0].verdict = {head:\"$HEAD_B\",actor:\"captain\",source:\"https://github.com/o/r/pull/5#issuecomment-8\",summary:\"choose contract\"}"
  out=$(bearings "$home") || fail 'Bearings could not read stale verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.stale_verdicts == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail "a verdict on a replaced head must be STALE, not current captain work: $out"
  pass 'replaced-head verdict is stale and cannot create a captain requirement'
}

test_unchecked_is_not_silence() {
  local home out
  home=$(new_home unchecked)
  printf -- '- [ ] unseen - Unchecked https://github.com/o/r/pull/6 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(bearings "$home") || fail 'Bearings could not read unchecked fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail "no observation must not become a proven empty actionable set: $out"
  pass 'unchecked ownership is disclosed and cannot prove silence'
}

test_newest_check_has_no_verdict() {
  local home out
  home=$(new_home no-verdict)
  record "$home" missing 7 open mergeable
  mutate_record "$home" missing '.records[0].observation.checks += [{name:"test",id:2,status:"completed",conclusion:null,started_at:"2026-09-16T08:00:01Z"}]'
  out=$(bearings "$home") || fail 'Bearings could not read missing verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1
    and .contributions.counts.maintainer == 0' >/dev/null \
    || fail "newest distinct check must not inherit an earlier success: $out"
  pass 'newest check with no verdict is distinct from passing and pending'
}


# Budget seconds left depend on the wall clock unless a test freezes it.
mask_budget() { sed -E 's/ with -?[0-9]+s of budget left: / with Ns of budget left: /'; }

forge_home() {
  local home=$1
  mkdir -p "$home/forge" "$home/root/bin" "$home/wt"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  record "$home" delivery 8 open mergeable
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '[]\n' > "$home/forge/threads.json"
  printf '[]\n' > "$home/forge/labels.json"
  printf '[]\n' > "$home/forge/events.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8'|'api repos/o/r/pulls/9'|'api repos/o/r/pulls/10')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api graphql '*)
    jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

registered_checks() {
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    with_home "$home" bash "$check" || fail 'registered check failed'
  done
}

test_incoming_signal() { # comment|review|inline
  local type=$1 home out count fixture wake_count
  case "$type" in comment) fixture=comments ;; review) fixture=reviews ;; *) fixture=inline ;; esac
  home=$(new_home "incoming-$type")
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" --arg type "$type" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}
    + (if $type == "comment" then {} else {commit_id:$head,state:"CHANGES_REQUESTED"} end)]' \
    > "$home/forge/$fixture.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail "new maintainer $type must survive as a pending outward signal"
  [ -s "$home/state/.wake-queue" ] || fail "new maintainer $type must enqueue an ordinary durable wake"
  count=$(wc -l < "$home/state/.wake-queue")
  wake_count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$wake_count" = 1 ] || fail "new maintainer $type must enqueue exactly one ordinary durable wake"
  registered_checks "$home" >/dev/null
  [ "$(wc -l < "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued event'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$wake_count" ] || fail 're-poll duplicated an already enqueued event'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "maintainer"' >/dev/null \
    || fail 'supervisor cannot retrieve captured signal'
  pass "new maintainer $type wakes once and stays pending until acknowledged"
}

test_ready_issue_wake() {
  local home count
  home=$(new_home ready)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery'
  registered_checks "$home" >/dev/null
  printf '[{"name":"ready-for-pr"}]\n' > "$home/forge/labels.json"
  registered_checks "$home" >/dev/null
  if [ ! -f "$home/data/filed/contributions.json" ] \
    || ! jq -e 'any(.records[].pending[]; .type == "ready-for-pr")' "$home/data/filed/contributions.json" >/dev/null; then
    fail 'ready-for-pr on an explicitly filed issue must become a planning wake'
  fi
  [ -s "$home/state/.wake-queue" ] || fail 'ready-for-pr signal never reached the durable wake path'
  count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$count" = 1 ] || fail 'ready-for-pr signal must enqueue exactly one durable wake'
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued ready-for-pr wake'
  pass 'ready-for-pr on a filed issue becomes a planning wake'
}

test_fresh_issue_requires_maintainer() {
  local home
  home=$(new_home fresh-issue)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not observe filed issue'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 2
    and .contributions.counts.maintainer == 2 and .contributions.counts.fleet == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a fresh open issue did not remain measured maintainer triage'
  pass 'a fresh open issue remains measured maintainer triage'
}

test_comment_wake() { test_incoming_signal comment; }
test_review_wake() { test_incoming_signal review; }
test_inline_wake() { test_incoming_signal inline; }

test_review_bot_inline_wake() {
  local home out token
  home=$(new_home review-bot)
  forge_home "$home"
  mkdir -p "$home/config"
  printf 'greptile-apps[bot]\n' > "$home/config/contribution-review-bots"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[
    {id:21,user:{login:"greptile-apps[bot]"},author_association:"COLLABORATOR",commit_id:$head,
      body:"P1: unchecked error",html_url:"https://github.com/o/r/pull/8#discussion_r21",
      created_at:"2026-09-16T08:01:00Z",updated_at:"2026-09-16T08:01:00Z"},
    {id:22,user:{login:"passerby"},author_association:"NONE",commit_id:$head,
      body:"drive-by",html_url:"https://github.com/o/r/pull/8#discussion_r22",updated_at:"2026-09-16T08:02:00Z"}]' \
    > "$home/forge/inline.json"
  registered_checks "$home" >/dev/null
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "greptile-apps[bot]" and .[0].review_bot == true' >/dev/null \
    || fail "a Greptile inline comment must be the only pending signal: $out"
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'a review-bot finding must enqueue exactly one wake'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect review-bot contribution input'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all \
    | jq -e '.rows[0].actor == "fleet" and .rows[0].reason == "incoming review-bot finding needs triage"' >/dev/null \
    || fail 'a review-bot finding must route to the fleet'
  token=$(printf '%s' "$out" | jq -er '.[0].token') || fail 'the review-bot signal had no token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'the review-bot signal could not be acknowledged'
  poll_at "$home" 2026-09-17T09:01:00Z >/dev/null || fail 'the unanswered review-bot thread was not polled again'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].type == "unanswered" and .[0].review_bot == true' >/dev/null \
    || fail "the re-raised review-bot finding lost its classification: $out"
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-17T09:01:00Z \
    "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all \
    | jq -e '.rows[0].reason == "incoming review-bot finding needs triage"' >/dev/null \
    || fail 'a re-raised review-bot finding must still route as review-bot triage'
  pass 'a listed collaborator bot and its re-raise remain review-bot fleet signals'
}

test_review_bot_watching_is_opt_in() {
  local home out
  home=$(new_home review-bot-off)
  forge_home "$home"
  rm -f "$home/config/contribution-review-bots"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n '[{id:41,user:{login:"greptile-apps[bot]"},author_association:"NONE",body:"P1: finding",
    html_url:"https://github.com/o/r/pull/8#issuecomment-41",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 0' >/dev/null \
    || fail "a home with no review-bot file must admit no bot: $out"
  pass 'review-bot watching is off until a home lists a bot'
}

test_review_bot_allowlist_is_configurable() {
  local home config out token
  home=$(new_home review-bot-config)
  config=review-config
  forge_home "$home"
  mkdir -p "$home/$config"
  printf 'custom-review[bot]\n' > "$home/$config/contribution-review-bots"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  (cd "$home" && with_home "$home" env FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-contributions.sh" arm >/dev/null) \
    || fail 'could not arm the contribution check with its relative review-bot config'
  registered_checks "$home" >/dev/null
  jq -n '[
    {id:31,user:{login:"custom-review[bot]"},author_association:"NONE",body:"configured",
      html_url:"https://github.com/o/r/pull/8#issuecomment-31",updated_at:"2026-09-16T08:01:00Z"},
    {id:32,user:{login:"greptile-apps[bot]"},author_association:"NONE",body:"not configured",
      html_url:"https://github.com/o/r/pull/8#issuecomment-32",updated_at:"2026-09-16T08:02:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "custom-review[bot]"' >/dev/null \
    || fail "the armed check did not retain its configured review-bot allowlist: $out"
  token=$(printf '%s' "$out" | jq -er '.[0].token') || fail 'the configured review-bot signal had no token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'the configured review-bot signal could not be acknowledged'
  : > "$home/$config/contribution-review-bots"
  registered_checks "$home" >/dev/null
  printf 'custom-review[bot]\n' > "$home/$config/contribution-review-bots"
  registered_checks "$home" >/dev/null
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 0' >/dev/null \
    || fail "an acknowledged review-bot signal returned after an allowlist toggle: $out"
  pass 'the armed allowlist is stable across working directories and policy toggles'
}

test_missing_lane_remains_missing() {
  local home
  home=$(new_home absent-lane)
  forge_home "$home"
  mutate_record "$home" delivery '.records[0].observation.checks += [{name:"required-extra",id:2,status:"completed",conclusion:"success",started_at:"2026-09-16T07:59:00Z"}]'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'first poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'second poll failed'
  bearings "$home" | jq -e '.contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'repeated polling erased the absent lane from measured readiness'
  pass 'an absent check lane remains missing across repeated observations'
}

test_partial_freshness_keeps_measured_rows() {
  local home
  home=$(new_home mixed-age)
  record "$home" current 10 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" expired 11 open mergeable
  mutate_record "$home" expired '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.counts.captain == 1 and (.contributions.captain | length) == 1
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'one expired observation erased the independently measured captain row'
  pass 'mixed freshness retains measured captain work and discloses the gap'
}

test_malformed_record_cannot_prove_silence() {
  local home
  home=$(new_home malformed)
  record "$home" invalid 12 open mergeable
  mutate_record "$home" invalid '.records[0].observation.state="not-a-forge-state"'
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'malformed durable evidence was counted as checked'
  pass 'malformed durable evidence cannot prove silence'
}

test_issue_timeline_and_exact_ack() {
  local home token
  home=$(new_home issue-timeline)
  forge_home "$home"
  printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial poll failed'
  printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$home/forge/events.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'timeline poll failed'
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.type=="ready-for-pr") | .token') \
    || fail 'add/remove between polls lost ready-for-pr transition'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack filed https://github.com/o/r/issues/9 "$token" || fail 'exact ack failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'post-ack poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null || fail 'acknowledged timeline event replayed'
  pass 'a transient ready-for-pr label wakes and its exact acknowledgement survives replay'
}

test_verdict_retains_judged_head() {
  local home
  home=$(new_home verdict-roundtrip)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 maintainer 'awaiting maintainer' || fail 'could not record judged head'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\n' "$HEAD_B" >> "$home/state/delivery.meta"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.stale_verdicts == 1 and .contributions.checked == 0' >/dev/null \
    || fail 'changed published head reused a current verdict'
  jq -e --arg head "$HEAD_A" '.records[0].verdict.head==$head' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'projection rewrote the judged head'
  pass 'recorded judgment keeps its exact head and is stale immediately on a published replacement'
}

test_verdict_actor_values_are_discoverable() {
  local home help out actor
  home=$(new_home verdict-actors)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  help=$("$ROOT/bin/fm-contributions.sh" --help) || fail 'verdict help did not print'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 bogus 'no such actor' 2>&1) \
    && fail 'an unknown actor was accepted'
  [ "$(printf '%s\n' "$help" | sed -n '/^  fm-contributions.sh verdict /p')" = \
    '  fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <captain|fleet|maintainer|nobody> <summary>' ] \
    || fail "help usage does not name exactly the accepted actors: $help"
  [ "$(printf '%s\n' "$help" | sed -n '/^actor is exactly one of /p')" = \
    'actor is exactly one of captain, fleet, maintainer or nobody; any other value' ] \
    || fail "help explanation does not name exactly the accepted actors: $help"
  [ "$out" = "fm-contributions: invalid required actor 'bogus'; expected one of: captain, fleet, maintainer, nobody" ] \
    || fail "refusal does not name exactly the accepted actors: $out"
  for actor in captain fleet maintainer nobody; do
    with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
      https://github.com/o/r/pull/8#issuecomment-99 "$actor" 'documented actor' >/dev/null \
      || fail "documented actor $actor was refused"
  done
  pass 'verdict help and refusal name exactly the actors the command accepts'
}

test_observed_replacement_refreshes_verdict() {
  local home
  home=$(new_home observed-replacement)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before replacement'
  registered_checks "$home" >/dev/null
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_B" \
    https://github.com/o/r/pull/8#issuecomment-100 maintainer 'awaiting maintainer' \
    || fail 'could not record verdict on the observed replacement'
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.stale_verdicts == 0
    and .contributions.counts.maintainer == 1 and .contributions.counts.fleet == 0' >/dev/null \
    || fail 'a current forge observation did not refresh a verdict on its observed head'
  pass 'a current forge observation refreshes a verdict after a replacement'
}

test_unobserved_head_leaves_verdict_unknown() {
  local home out
  home=$(new_home unobserved-head)
  record "$home" delivery 17 open mergeable
  mutate_record "$home" delivery ".records[0].error=\"forge unavailable\" | .records[0].verdict={head:\"$HEAD_B\",actor:\"maintainer\",source:\"https://github.com/o/r/pull/17#issuecomment-101\",summary:\"awaiting maintainer\"}"
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input without a forge read'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project unavailable forge observation'
  printf '%s' "$out" | jq -e '.stale_verdicts == 0 and .checked == 0
    and .rows[0].verdict.freshness == "unverified"' >/dev/null \
    || fail 'an unavailable current head became a fresh or stale verdict'
  pass 'an unavailable current head leaves verdict freshness unknown'
}

test_away_yolo_is_fleet_work() {
  local home out
  home=$(new_home away-yolo)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register away delivery'
  printf 'yolo=on\n' >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter away posture'
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input for away posture'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project away delivery'
  printf '%s' "$out" | jq -e '.checked == 1 and .counts.captain == 0 and .counts.fleet == 1' >/dev/null \
    || fail 'away yolo delivery requiring a merge remained captain work'
  pass 'away yolo delivery is fleet work without granting merge authority'
}

test_away_yolo_cross_home_is_fleet_work() {
  local home child
  home=$(new_home away-yolo-parent)
  child=$(new_home away-yolo-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  forge_home "$child"
  with_home "$child" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register child away delivery'
  printf 'yolo=on\n' >> "$child/state/delivery.meta"
  with_home "$child" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter child away posture'
  mutate_record "$child" delivery '.records[0].observation.can_merge=true'
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child contribution summary'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'cross-home away yolo delivery requiring a merge remained captain work'
  pass 'cross-home away yolo delivery is fleet work'
}

test_retired_and_unsupported_coverage() {
  local home
  home=$(new_home retained)
  record "$home" retained 14 open mergeable
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true and .contributions.counts.maintainer == 1' >/dev/null \
    || fail 'endpoint retirement lost published ownership or proved nothing'
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'unsupported forge silently disappeared from coverage'
  pass 'retired ownership persists and unsupported forge remains visibly unmeasured'
}

test_unsupported_forge_is_not_fleet_work() {
  local home
  home=$(new_home unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.fleet == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unsupported forge was classified as fleet work instead of unmeasured coverage'
  pass 'unsupported forge coverage is disclosed without inventing fleet work'
}

test_unsupported_poll_is_silent_and_clears_legacy_errors() {
  local home mode out url task
  for mode in fresh legacy; do
    home=$(new_home "unsupported-poll-$mode")
    forge_home "$home"
    wrap_forge "$home"
    rm -f "$home/state/delivery.meta" "$home/data/delivery/contributions.json"
    printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
    for task in gitlab selfhosted hyphenated wildcard; do
      case "$task" in
        gitlab) url=https://gitlab.com/o/r/-/merge_requests/2 ;;
        selfhosted) url=https://git.example.org/group/subgroup/r/-/merge_requests/3 ;;
        hyphenated) url=https://github-com/o/r/pull/8 ;;
        wildcard) url=https://githubXcom/o/r/issues/9 ;;
      esac
      printf -- '- [ ] %s - Filed %s (repo: sample) (kind: ship)\n' "$task" "$url" >> "$home/data/backlog.md"
      if [ "$mode" = legacy ]; then
        mkdir -p "$home/data/$task"
        jq -n --arg task "$task" --arg url "$url" --arg now "$NOW" '
          {schema:"fm-contributions.v1",task:$task,records:[{url:$url,
            kind:(if ($url | contains("/issues/")) then "issue" else "pr" end),checked_at:$now,error:"forge observation unavailable or changed during read",
            observation:null,verdict:null,seen:[],pending:[],notified:[],provenance:"retained ownership"}]}' \
          > "$home/data/$task/contributions.json"
        jq '.records[].error=null' "$home/data/$task/contributions.json" > "$home/$task.expected.json"
      fi
    done
    # Forgejo pulls are not accepted by the existing contribution ownership schema.
    printf -- '- [ ] forgejo - Filed https://codeberg.org/o/r/pulls/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    # Saved URLs retain ownership after their backlog links disappear.
    [ "$mode" != legacy ] || printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
    out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" poll 2>&1) \
      || fail "unsupported poll failed ($mode): $out"
    [ -z "$out" ] || fail "unsupported poll printed an unavailable signal ($mode): $out"
    [ ! -s "$home/forge/calls" ] || fail "unsupported poll contacted the forge ($mode)"
    [ ! -s "$home/state/.wake-queue" ] || fail "unsupported poll enqueued a wake ($mode)"
    for task in gitlab selfhosted hyphenated wildcard; do
      if [ "$mode" = legacy ]; then
        jq -e --slurpfile expected "$home/$task.expected.json" '. == $expected[0]' \
          "$home/data/$task/contributions.json" >/dev/null \
          || fail 'legacy cleanup changed evidence beyond its unsupported error'
      else
        [ ! -e "$home/data/$task/contributions.json" ] || fail 'unsupported poll fabricated a record'
      fi
    done
    bearings "$home" | jq -e '.contributions | .known == 4 and .checked == 0
      and .unmeasured == 4 and .unreadable_records == 0
      and .counts == {captain:0,fleet:0,maintainer:0,nobody:0}
      and .complete == false and .proven_clear == false' >/dev/null \
      || fail "unsupported poll corrupted unmeasured coverage ($mode)"
  done
  pass 'unsupported ownership stays silent and unmeasured; legacy errors clear without fabricated evidence'
}

test_legacy_cleanup_preserves_supported_failure() {
  local home out
  home=$(new_home legacy-mixed-errors)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation=null
    | .records[0].error="forge observation unavailable or changed during read"
    | .records += [(.records[0] | .url="https://gitlab.com/o/r/-/merge_requests/2"),
      (.records[0] | .url="https://github-com/o/r/pull/8"),
      (.records[0] | .url="https://githubXcom/o/r/issues/9" | .kind="issue")]'
  jq '[.records[] | select(.url != "https://github.com/o/r/pull/8") | .error=null]' \
    "$home/data/delivery/contributions.json" > "$home/unsupported.expected.json"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" poll 2>&1) \
    || fail "mixed legacy-error poll failed: $out"
  [ -z "$out" ] || fail "an existing GitHub failure episode re-alerted: $out"
  grep -Fxq 'api repos/o/r/pulls/8' "$home/forge/calls" || fail 'supported ownership was not retried'
  # The transient 502 core read is retried once; unsupported records add no reads.
  [ "$(wc -l < "$home/forge/calls")" -eq 2 ] || fail 'unsupported mixed records triggered forge reads'
  [ ! -s "$home/state/.wake-queue" ] || fail 'mixed legacy cleanup enqueued a wake'
  jq -e --slurpfile expected "$home/unsupported.expected.json" '.records | length == 4
    and all(.[]; .observation == null)
    and any(.[]; .url == "https://github.com/o/r/pull/8" and .error != null)
    and ([.[] | select(.url != "https://github.com/o/r/pull/8")] | sort_by(.url))
      == ($expected[0] | sort_by(.url))' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'unsupported cleanup erased supported failure or fabricated an observation'
  bearings "$home" | jq -e '.contributions | .known == 4 and .checked == 0
    and .unmeasured == 3 and .unreadable_records == 0
    and .counts == {captain:0,fleet:1,maintainer:0,nobody:0} and .complete == false' >/dev/null \
    || fail 'mixed legacy cleanup confused supported failures with unmeasured coverage'
  rm "$home/forge/fault"
  out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" poll 2>&1) \
    || fail "mixed saved-file recovery failed: $out"
  [ -z "$out" ] || fail "mixed saved-file recovery printed an alert: $out"
  [ ! -s "$home/state/.wake-queue" ] || fail 'mixed saved-file recovery enqueued a wake'
  jq -e --slurpfile expected "$home/unsupported.expected.json" '
    [.records[] | select(.url != "https://github.com/o/r/pull/8")] | sort_by(.url)
    == ($expected[0] | sort_by(.url))' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'supported recovery changed retained unsupported evidence'
  bearings "$home" | jq -e '.contributions | .known == 4 and .checked == 1
    and .unmeasured == 3 and .unreadable_records == 0
    and .counts == {captain:0,fleet:0,maintainer:1,nobody:0} and .complete == false' >/dev/null \
    || fail 'real GitHub recovery lost mixed saved ownership'
  pass 'legacy cleanup preserves unsupported ownership and supported missing-evidence failure in the same file'
}

test_held_unsupported_forge_is_not_captain_work() {
  local home
  home=$(new_home held-unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship) (hold: choose scope) (hold-kind: captain)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and (.contributions.captain | length) == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'a held unsupported forge was classified as captain or fleet work'
  pass 'held unsupported forge coverage remains unmeasured'
}

test_shared_contribution_signal_wakes_once() {
  local home token pending wakes
  home=$(new_home shared-contribution-signal)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register shared contribution owner'
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "one shared contribution signal created $wakes durable wakes"
  pending=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending) || fail 'shared contribution pending view failed'
  printf '%s' "$pending" | jq -e 'length == 2 and ([.[].task] | sort) == ["delivery","duplicate"]' >/dev/null \
    || fail 'shared contribution owners did not retain their separate acknowledgements'
  token=$(printf '%s' "$pending" | jq -er '.[0].token') || fail 'shared contribution signal had no acknowledgement token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the first shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack duplicate https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the second shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'shared contribution acknowledgements did not remain independent'
  pass 'shared contribution signal wakes once while retaining both acknowledgements'
}

test_watcher_keeps_diagnostics_separate_from_contribution_wakes() {
  local home out rc wakes diagnostic
  home=$(new_home watcher-diagnostics)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for diagnostic watcher wake'
  registered_checks "$home" >/dev/null
  mkdir -p "$home/data/unreadable"
  printf 'incomplete JSON\n' > "$home/data/unreadable/contributions.json"
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher-diagnostics.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$out" 2> "$home/watcher-diagnostics.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface contribution diagnostics: $(cat "$home/watcher-diagnostics.err")"
  diagnostic=$(awk -F '\t' -v key="$home/state/contributions.check.sh" '$3 == "check" && $4 == key { print $5 }' "$home/state/.wake-queue")
  [ "$diagnostic" = "check: $home/state/contributions.check.sh: contributions: 1 unreadable durable record(s)" ] \
    || fail "watcher wrapped a durable contribution wake into diagnostics: $diagnostic"
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 2 ] || fail "signal plus observer failure created $wakes durable wakes"
  pass 'watcher keeps observer diagnostics separate from contribution wakes'
}

test_expired_child_unsupported_forge_stays_unmeasured() {
  local home child
  home=$(new_home expired-unsupported-parent)
  child=$(new_home expired-unsupported-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$child/data/backlog.md"
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child unsupported-forge coverage'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and .contributions.complete == false
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'expired child unsupported-forge coverage became fleet work'
  pass 'expired child unsupported-forge coverage remains unmeasured'
}

test_watcher_surfaces_new_contribution_once() {
  local home out rc rows
  home=$(new_home watcher-contribution)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for watcher wake'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface the new contribution signal: $(cat "$home/watcher.err")"
  grep -E '^check: contributions delivery [0-9a-f]{64}$' "$out" >/dev/null \
    || fail "watcher did not surface the durable contribution wake: $(cat "$out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one contribution signal created $rows durable check wakes"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "an already durable contribution signal re-rang the watcher: $(cat "$home/watcher-repeat.out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "repeat contribution observation created $rows durable check wakes"
  pass 'watcher surfaces one newly durable contribution signal without re-ringing it'
}

test_home_summary_coverage() {
  local home child
  home=$(new_home parent)
  child=$(new_home child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  record "$child" child-work 15 open mergeable
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'child summary failed'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true' >/dev/null || fail 'measured child coverage did not reach parent'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.proven_clear == false' >/dev/null || fail 'expired child evidence proved parent silence'
  pass 'parent consumes measured child coverage and refuses expired child silence'
}

test_unreadable_pending_is_not_empty() {
  local home
  home=$(new_home unreadable-pending)
  record "$home" invalid 16 open mergeable
  printf 'incomplete JSON\n' > "$home/data/invalid/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > "$home/pending.json" 2> "$home/pending.err"; then
    fail 'an unreadable signal record was presented as an empty inbox'
  fi
  pass 'unreadable pending signals refuse an empty-inbox claim'
}

# Each record's durable task identity is the directory the snapshot loop finds
# it in, exactly as `basename "$(dirname "$file")"` named it, however the data
# root is spelled and whatever bytes the directory name carries.
test_record_task_identity_matches_dirname_basename() {
  local home data name file want n=0 names=() tasks=() expected actual
  home=$(new_home task-identity)
  names=(plain dot.ted 'two words' -dash $'caf\xc3\xa9' $'nl\n' '*')
  for data in "$home/data" "$home/data/" "$home/data//"; do
    for name in "${names[@]}"; do
      n=$((n + 1))
      mkdir -p "$home/data/$name"
      file="$data/$name/contributions.json"
      want=$(basename "$(dirname "$file")")
      jq -n --arg task "$want" --arg url "https://github.com/o/r/pull/$n" --arg token "t$n" \
        '{schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:null,error:null,
          pending:[{token:$token}],seen:[],verdict:null,observation:null}]}' > "$file"
      tasks+=("$want")
    done
    expected=$(printf '%s\0' "${tasks[@]}" | jq -Rs 'split("\u0000")[:-1] | sort')
    actual=$(with_home "$home" env FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-contributions.sh" pending | jq '[.[].task] | sort') \
      || fail "records under data root '$data' were refused"
    [ "$actual" = "$expected" ] || fail "data root '$data' named tasks $actual, expected $expected"
    rm -rf "${home:?}/data/"*/
    tasks=()
  done
  mkdir -p "$home/data/named"
  jq -n '{schema:"fm-contributions.v1",task:"other",records:[]}' > "$home/data/named/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > /dev/null 2>&1; then
    fail 'a record naming another task was accepted'
  fi
  pass 'record task identity is the directory dirname/basename named'
}

# snapshot and pending are read-only: reading saved records never creates the
# state directory or anything else, even in a home that has none.
test_read_only_views_create_no_state() {
  local home before after
  home=$(new_home read-only-views)
  record "$home" delivery 8 open mergeable
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$TMP_ROOT/read-only-input.json" \
    || fail 'could not collect contribution input'
  rm -rf "${home:?}/state"
  before=$(find "$home" | sort)
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$TMP_ROOT/read-only-input.json" --all \
    | jq -e '.checked == 1' >/dev/null || fail 'snapshot did not read the saved record without a state directory'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'pending did not read the saved record without a state directory'
  after=$(find "$home" | sort)
  [ ! -e "$home/state" ] || fail 'a read-only contribution view created the state directory'
  [ "$after" = "$before" ] || fail "a read-only contribution view created files: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  pass 'snapshot and pending create nothing in a home without state'
}

wrap_forge() { # home: log gh calls and apply per-call faults from $FORGE/fault
  local home=$1
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/calls"
fault=$(cat "$FORGE/fault" 2>/dev/null || true)
case "$fault" in latency) sleep "${FORGE_LATENCY:-2}" ;; esac
# Concurrent forge callers each advance one shared clock. Truncating it in
# place races with the other callers and the fake date: an interleaved write
# can publish a half-written value (or the 6 an emptied read computes), and a
# caller then evaluates DEADLINE against torn arithmetic. Publish every new
# value by rename so each reader always sees one complete old-or-new clock.
clock_bump() {
  local tmp
  tmp=$(mktemp "$FORGE/clock.XXXXXX")
  printf '%s\n' "$(( $(cat "$FORGE/clock") + $1 ))" > "$tmp"
  mv -f "$tmp" "$FORGE/clock"
}
case "$fault:$*" in
  # Advance once before the parallel read wave; its readers share this clock.
  reserve:'api repos/o/r/issues/9') clock_bump 6 ;;
  slow-wave:'api repos/o/r/pulls/8') sleep 3 ;;
  slow-wave:'api repos/o/r/pulls/8/reviews?'*) sleep 6 ;;
  exhaust:'api repos/o/r/issues/8/comments?'*) clock_bump 100 ;;
  fail-late:'api repos/o/r/pulls/8/reviews?'*) clock_bump 100; printf 'gh: Bad Gateway (HTTP 502)\n' >&2; exit 1 ;;
  fail:'api repos/o/r/pulls/8/reviews?'*) printf 'gh: Internal Server Error (HTTP 500)\n' >&2; exit 1 ;;
  fail-once:'api repos/o/r/pulls/8/reviews?'*)
    if [ ! -e "$FORGE/fail-once-spent" ]; then
      : > "$FORGE/fail-once-spent"
      printf 'gh: Internal Server Error (HTTP 500)\n' >&2
      exit 1
    fi
    ;;
  real-reviews:'api repos/o/r/pulls/8/reviews?'*)
    printf '%s\n' "$FORGE_ERROR_TEXT" >&2
    exit "${FORGE_ERROR_RC:-1}"
    ;;
  real-core:'api repos/o/r/pulls/8')
    printf '%s\n' "$FORGE_ERROR_TEXT" >&2
    exit "${FORGE_ERROR_RC:-1}"
    ;;
  real-closing:'pr view '*)
    printf '%s\n' "$FORGE_ERROR_TEXT" >&2
    exit "${FORGE_ERROR_RC:-1}"
    ;;
  down:*) printf 'gh: Bad Gateway (HTTP 502)\n' >&2; exit 1 ;;
  not-found:'api repos/o/r/'*) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
  hang:'api repos/o/r/pulls/8') sleep 4 ;;
  head:'pr view '*) printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' "$(printf 'b%.0s' $(seq 40))"; exit 0 ;;
  headless:'pr view '*) printf '{"headRefOid":null,"reviewDecision":"APPROVED"}\n'; exit 0 ;;
esac
exec "$(dirname "$0")/gh-fixture" "$@"
SH
  # A controllable clock lets the budget expire between two forge calls.
  cat > "$home/fakebin/date" <<'SH'
#!/bin/sh
if [ "$*" = +%s ] && [ -f "$FORGE/clock" ]; then cat "$FORGE/clock"; else exec /bin/date "$@"; fi
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/date"
}

test_budget_exhaustion_keeps_prior_record() { # exhaust|hang
  local mode=$1 home out
  home=$(new_home "budget-$mode")
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  # Both modes freeze the clock: an unfrozen one can tick past a one-second
  # budget before the first forge call, so nothing is ever observed.
  /bin/date +%s > "$home/forge/clock"
  printf '%s\n' "$mode" > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=1 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail "poll failed when its budget ran out ($mode)"
  [ -z "$out" ] || fail "budget exhaustion ($mode) printed a wake line: $out"
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    || fail "budget exhaustion ($mode) never started the observation"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail "budget exhaustion ($mode) rewrote the prior record: $(cat "$home/data/delivery/contributions.json")"
  [ ! -s "$home/state/.wake-queue" ] || fail "budget exhaustion ($mode) enqueued a wake"
  pass "budget exhausted mid-observation ($mode) keeps the prior record and stays silent"
}

test_budget_refusal_between_calls() { test_budget_exhaustion_keeps_prior_record exhaust; }
test_budget_bounded_call_timeout() { test_budget_exhaustion_keeps_prior_record hang; }

test_genuine_failure_near_deadline_is_unavailable() {
  local home out
  home=$(new_home genuine-failure)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'fail-late\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on a genuine forge failure'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8 - reviews read exited 1 with -80s of budget left: gh: Bad Gateway (HTTP 502)' ] \
    || fail "a genuine forge failure past the deadline was swallowed or lost its cause: $out"
  jq -e --arg now "$NOW" '.records[0].checked_at == $now
    and .records[0].error == "forge observation unavailable: reviews read exited 1 with -80s of budget left: gh: Bad Gateway (HTTP 502)"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a genuine forge failure left no error evidence'
  pass 'a genuine forge failure inside the budget still records the error, its cause and wakes'
}

test_http_500_once_retries_without_waking() {
  local home out calls
  home=$(new_home retry-http-500-once)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  printf 'fail-once\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed after one transient HTTP 500'
  [ -z "$out" ] || fail "a recovered HTTP 500 printed an unavailable line: $out"
  calls=$(grep -cF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls")
  [ "$calls" = 2 ] || fail "one HTTP 500 made $calls review reads, expected 2"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a recovered HTTP 500 left an error in the contribution record'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a recovered HTTP 500 enqueued a wake'
  pass 'one HTTP 500 is retried once and a successful retry stays healthy'
}

test_http_500_twice_records_the_failed_read() {
  local home out calls why='reviews read exited 1 with Ns of budget left: gh: Internal Server Error (HTTP 500)'
  home=$(new_home retry-http-500-twice)
  forge_home "$home"
  wrap_forge "$home"
  printf 'fail\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed after two HTTP 500 responses'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "two HTTP 500 responses did not print one unavailable line: $out"
  calls=$(grep -cF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls")
  [ "$calls" = 2 ] || fail "two HTTP 500 responses made $calls review reads, expected 2"
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'a failed retry did not name the reviews read and its error'
  pass 'two transient failures wake once and name the failed read in the record'
}

test_http_404_is_not_retried() {
  local home out calls why='core read exited 1 with Ns of budget left: gh: Not Found (HTTP 404)'
  home=$(new_home no-retry-http-404)
  forge_home "$home"
  wrap_forge "$home"
  printf 'not-found\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed after an HTTP 404'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "an HTTP 404 did not print one unavailable line: $out"
  calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
  [ "$calls" = 1 ] || fail "an HTTP 404 made $calls core reads, expected 1"
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'an HTTP 404 did not name the core read and its error'
  pass 'an HTTP 404 is reported without retrying'
}

test_real_gh_errors_drive_retry_and_summary() {
  local home out calls status message row repo error summary why
  message=$'error connecting to no-such-host-f67.invalid\ncheck your internet connection or https://githubstatus.com'
  home=$(new_home real-gh-dns)
  forge_home "$home"
  wrap_forge "$home"
  printf 'real-reviews\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_ERROR_TEXT="$message" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on a real gh DNS error shape'
  why='reviews read exited 1 with Ns of budget left: error connecting to no-such-host-f67.invalid'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "a persistent DNS error did not print one unavailable line: $out"
  calls=$(grep -cF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls")
  [ "$calls" = 2 ] || fail "a gh DNS error made $calls review reads, expected 2"
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'a gh DNS error did not retain its error'

  for row in \
    'kunchenguid/firstmate|proxyconnect tcp: dial tcp 127.0.0.1:1: connect: connection refused|connection error' \
    'coredns/coredns|dial tcp 140.82.112.6:443: connect: connection refused|connection error' \
    'openssl/openssl|read tcp 10.0.0.2:50000->140.82.112.6:443: read: connection reset by peer|connection error' \
    'rustls/rustls|unexpected EOF|connection error' \
    'coredns/coredns|net/http: TLS handshake timeout|TLS error' \
    'openssl/openssl|dial tcp: lookup api.github.com: no such host|DNS error'; do
    IFS='|' read -r repo error summary <<< "$row"
    message="Get \"https://api.github.com/repos/$repo/pulls/7262/reviews?per_page=100\": $error"
    home=$(new_home "real-gh-network-$(printf '%s' "$row" | shasum | cut -c1-8)")
    forge_home "$home"
    wrap_forge "$home"
    printf 'real-reviews\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_ERROR_TEXT="$message" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll failed on a real gh $summary shape"
    why="reviews read exited 1 with Ns of budget left: $message"
    [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
      || fail "a persistent $summary did not print one unavailable line: $out"
    calls=$(grep -cF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls")
    [ "$calls" = 2 ] || fail "a gh $summary made $calls review reads, expected 2"
    [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail "a gh $summary from $repo did not retain its error"
  done

  for message in \
    'GraphQL: Could not resolve to a PullRequest with the number of 99999999. (repository.pullRequest)' \
    "GraphQL: Could not resolve to a Repository with the name 'missing'. (repository)" \
    "GraphQL: Could not resolve to a Repository with the name 'openssl/openssl'. (repository)" \
    "GraphQL: Could not resolve to a Repository with the name 'o/dnsmasq'. (repository)"; do
    home=$(new_home "real-gh-graphql-$(printf '%s' "$message" | shasum | cut -c1-8)")
    forge_home "$home"
    wrap_forge "$home"
    printf 'real-closing\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_ERROR_TEXT="$message" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'poll failed on a real gh GraphQL not-found shape'
    why="head read exited 1 with Ns of budget left: $message"
    [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
      || fail "a GraphQL not-found did not print one unavailable line: $out"
    calls=$(grep -cF 'pr view https://github.com/o/r/pull/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "a GraphQL not-found made $calls closing reads, expected 1"
    [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail 'a GraphQL not-found did not retain its error'
  done

  for status in 404 401; do
    case "$status" in 404) message='gh: Not Found (HTTP 404)' ;; 401) message='gh: Bad credentials (HTTP 401)' ;; esac
    home=$(new_home "real-gh-http-$status")
    forge_home "$home"
    wrap_forge "$home"
    printf 'real-core\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_ERROR_TEXT="$message" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll failed on a real gh HTTP $status shape"
    why="core read exited 1 with Ns of budget left: $message"
    [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
      || fail "HTTP $status did not print one unavailable line: $out"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "HTTP $status made $calls core reads, expected 1"
    [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail "HTTP $status lost its error"
  done

  # Only GitHub's secondary rate limit makes a 403 transient.
  for row in \
    'secondary|2|gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)' \
    'forbidden|1|gh: Resource not accessible by integration (HTTP 403)'; do
    IFS='|' read -r status calls message <<< "$row"
    home=$(new_home "real-gh-http-403-$status")
    forge_home "$home"
    wrap_forge "$home"
    printf 'real-core\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_ERROR_TEXT="$message" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll failed on a real gh $status HTTP 403 shape"
    why="core read exited 1 with Ns of budget left: $message"
    [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
      || fail "a persistent $status HTTP 403 did not print one unavailable line: $out"
    [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = "$calls" ] \
      || fail "a $status HTTP 403 did not make exactly $calls core read(s)"
    [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail "a $status HTTP 403 lost its error"
  done

  for status in 500 502 503 429; do
    home=$(new_home "real-gh-bare-http-$status")
    forge_home "$home"
    wrap_forge "$home"
    printf 'real-core\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_ERROR_TEXT="gh: HTTP $status" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll failed on bare gh HTTP $status"
    why="core read exited 1 with Ns of budget left: gh: HTTP $status"
    [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
      || fail "bare gh HTTP $status did not print one unavailable line: $out"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 2 ] || fail "bare gh HTTP $status made $calls core reads, expected 2"
    [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail "bare gh HTTP $status lost its error"
  done

  home=$(new_home real-gh-bare-http-404)
  forge_home "$home"
  wrap_forge "$home"
  printf 'real-core\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_ERROR_TEXT='gh: HTTP 404' "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on bare gh HTTP 404'
  why='core read exited 1 with Ns of budget left: gh: HTTP 404'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "bare gh HTTP 404 did not print one unavailable line: $out"
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 1 ] \
    || fail 'bare gh HTTP 404 was retried'
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'bare gh HTTP 404 lost its error'

  home=$(new_home real-gh-http-line)
  forge_home "$home"
  wrap_forge "$home"
  printf 'real-core\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_ERROR_TEXT='HTTP 503: Service Unavailable' "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on a line-leading HTTP status'
  why='core read exited 1 with Ns of budget left: HTTP 503: Service Unavailable'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "a line-leading HTTP 503 did not print one unavailable line: $out"
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] \
    || fail 'a line-leading HTTP 503 was not retried exactly once'
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'a line-leading HTTP status was not retained'

  home=$(new_home real-gh-graphql-bare-http)
  forge_home "$home"
  wrap_forge "$home"
  printf 'real-closing\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_ERROR_TEXT='HTTP 503 (https://api.github.com/graphql)' "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on a message-less GraphQL HTTP status'
  why='head read exited 1 with Ns of budget left: HTTP 503 (https://api.github.com/graphql)'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "a message-less GraphQL HTTP 503 did not print one unavailable line: $out"
  [ "$(grep -cF 'pr view https://github.com/o/r/pull/8' "$home/forge/calls")" = 2 ] \
    || fail 'a message-less GraphQL HTTP 503 was not retried exactly once'
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'a message-less GraphQL HTTP status was not retained'

  home=$(new_home real-gh-exit-137)
  forge_home "$home"
  wrap_forge "$home"
  printf 'real-core\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_ERROR_TEXT='process killed outside the read bound' FORGE_ERROR_RC=137 \
    "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed after an external exit 137'
  why='core read exited 137 with Ns of budget left: process killed outside the read bound'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
    || fail "an external exit 137 was treated as budget refusal: $out"
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 1 ] \
    || fail 'an external exit 137 was retried'
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'an external exit 137 left no error evidence'
  pass 'real gh error shapes drive the intended retry decision and keep their error'
}

test_next_url_does_not_inherit_a_forge_diagnostic() {
  local home out pull_line issue_line why='reviews read exited 1 with Ns of budget left: gh: Internal Server Error (HTTP 500)'
  home=$(new_home next-url-no-stale-diagnostic)
  forge_home "$home"
  wrap_forge "$home"
  printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  # Malformed comment pages fail the issue after its reads succeed; the PR
  # fails on its reviews read before it checks comments.
  printf '{}\n' > "$home/forge/comments.json"
  printf 'fail\n' > "$home/forge/fault"
  # This rotation bucket reads the failing PR before the issue.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed while a GitHub issue followed a failed PR read'
  pull_line=$(grep -nF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls" | head -n 1 | cut -d: -f1)
  issue_line=$(grep -nFx 'api repos/o/r/issues/9' "$home/forge/calls" | head -n 1 | cut -d: -f1)
  [ -n "$pull_line" ] && [ -n "$issue_line" ] && [ "$pull_line" -lt "$issue_line" ] \
    || fail 'the seeded PR read failure did not run before the issue'
  printf '%s\n' "$out" | mask_budget | grep -Fxq "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" \
    || fail 'the seeded PR failure did not wake'
  printf '%s\n' "$out" | grep -Fxq 'contributions: observation unavailable for https://github.com/o/r/issues/9 - comment pages returned an unexpected shape' \
    || fail 'the malformed issue observation did not wake'
  [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'the PR record lost its failed read diagnostic'
  jq -e '.records[0].error == "forge observation unavailable: comment pages returned an unexpected shape"' \
    "$home/data/filed/contributions.json" >/dev/null \
    || fail 'the issue inherited the preceding PR read diagnostic'
  pass 'a URL never inherits the previous URL read diagnostic'
}

test_shared_url_observed_once() {
  local mode home out calls expected
  for mode in ok fail head headless; do
    home=$(new_home "shared-once-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    printf '%s\n' "$mode" > "$home/forge/fault"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "shared-owner poll failed ($mode)"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "a URL owned by two tasks was observed $calls times in one poll ($mode)"
    case "$mode" in
      ok) why= ;;
      fail) why='reviews read exited 1 with Ns of budget left: gh: Internal Server Error (HTTP 500)' ;;
      head) why='head changed during observation' ;;
      headless) why='head read named no head commit' ;;
    esac
    if [ "$mode" = ok ]; then
      expected=null
      [ -z "$out" ] || fail "a healthy shared observation printed: $out"
    else
      expected="\"forge observation unavailable: $why\""
      [ "$(printf '%s\n' "$out" | mask_budget)" = "contributions: observation unavailable for https://github.com/o/r/pull/8 - $why" ] \
        || fail "a shared unavailable observation did not wake exactly once with its cause ($mode): $out"
    fi
    for task in delivery duplicate; do
      jq -e --arg now "$NOW" '.records[0].checked_at == $now' "$home/data/$task/contributions.json" >/dev/null \
        && [ "$(jq -c .records[0].error "$home/data/$task/contributions.json" | mask_budget)" = "$expected" ] \
        || fail "owner $task did not receive the shared result ($mode)"
    done
  done
  pass 'a URL owned by two tasks is observed once and every owner receives the result'
}

test_terminal_contribution_settles() {
  local mode home out later=2026-09-17T08:00:00Z
  for mode in merged closed; do
    home=$(new_home "terminal-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf '%s\n' "$mode" > "$home/forge/state"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "terminal observation poll failed ($mode)"
    [ -z "$out" ] || fail "a $mode observation printed: $out"
    jq -e --arg now "$NOW" --arg mode "$mode" '.records[0] | .checked_at == $now and .error == null and .observation.state == $mode' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "a $mode observation was not recorded once without error"
    cp "$home/data/delivery/contributions.json" "$home/prior.json"
    : > "$home/forge/calls"
    printf 'down\n' > "$home/forge/fault"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll after a $mode observation failed"
    [ -z "$out" ] || fail "a $mode contribution woke again when a later read would fail: $out"
    [ ! -s "$home/forge/calls" ] || fail "a $mode contribution was re-read: $(cat "$home/forge/calls")"
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail "a $mode contribution record changed after it settled: $(cat "$home/data/delivery/contributions.json")"
    [ ! -s "$home/state/.wake-queue" ] || fail "a $mode contribution enqueued a wake"
    NOW=$later bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.nobody == 1
      and .contributions.complete == true' >/dev/null \
      || fail "a settled $mode contribution expired into fleet work"
  done
  home=$(new_home terminal-legacy-error)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll of an error-stamped merged record failed'
  [ -z "$out" ] || fail "an error-stamped merged record woke again: $out"
  [ ! -s "$home/forge/calls" ] || fail 'an error-stamped merged record was re-read'
  jq -e --arg at "$NOW" '.records[0] | .error == null and .checked_at == $at and .observation.state == "merged"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an error-stamped merged record did not settle'
  pass 'a merged or closed contribution settles once, is not re-read, and never wakes again'
}

test_late_owner_inherits_terminal_observation() {
  local home out later=2026-09-17T08:00:00Z
  home=$(new_home terminal-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  printf 'merged\n' > "$home/forge/state"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial terminal observation poll failed'
  cp "$home/data/delivery/contributions.json" "$home/final.json"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  : > "$home/forge/calls"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner terminal poll failed'
  [ -z "$out" ] || fail "a late owner reactivated a terminal contribution: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a late owner triggered a terminal forge read'
  jq -e --slurpfile final "$home/final.json" '
    .records[0] as $late | $final[0].records[0] as $terminal
    | $late.error == null and $late.pending == [] and $late.notified == []
    and $late.checked_at == $terminal.checked_at and $late.observation == $terminal.observation' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail 'a late owner did not inherit the settled terminal observation'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a late owner terminal record enqueued a wake'
  pass 'a late owner inherits a terminal observation without a forge read or wake'
}

test_interrupted_multi_owner_poll_settles_every_owner() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home multi-owner-open)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].pending=[{token:"evt-1"}] | .records[0].notified=["evt-0"]
    | .records[0].checked_at="2026-09-15T08:00:00Z"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation
    and .error == null and .checked_at == $terminal[0].records[0].checked_at
    and .pending == [{token:"evt-1"}] and .notified == ["evt-0"]' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an owner whose saved row stayed open did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"

  home=$(new_home multi-owner-errored)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll (errored owner) failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read (errored owner)'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation and .error == null' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an errored owner did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"
  pass 'a retry converges every owner whose saved row is not terminal, keeping its own acknowledgement state'
}

test_done_task_open_pr_still_observed() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home done-open)
  forge_home "$home"
  wrap_forge "$home"
  rm "$home/data/delivery/contributions.json"
  printf '# Backlog\n\n## Queued\n\n## Done\n- [x] delivery - Shipped https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    > "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll of a done task failed'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'second poll of a done task failed'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] \
    || fail 'an open PR linked from a done task was not observed on every poll'
  jq -e --arg head "$HEAD_B" --arg at "$later" '.records[0] | .checked_at == $at and .error == null
    and .observation.state == "open" and .observation.head == $head' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an open PR on a done task did not track its current head'
  pass 'an open PR linked from a done task keeps being observed'
}

test_many_settled_records_keep_the_poll_inside_the_check_bound() {
  local home real_jq template i task record rc=0
  home=$(new_home many-settled)
  forge_home "$home"
  record "$home" landed 900 merged mergeable
  template=$(cat "$home/data/landed/contributions.json")
  for i in $(seq 1 150); do
    task="landed-$i"
    mkdir -p "$home/data/$task"
    record=${template//\"landed\"/\"$task\"}
    printf '%s\n' "${record//pull\/900/pull/$((900 + i))}" > "$home/data/$task/contributions.json"
  done
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
    html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || fail 'could not arm the contribution check'
  real_jq=$(command -v jq)
  printf '#!/bin/sh\nsleep 0.05\nexec %s "$@"\n' "$real_jq" > "$home/fakebin/jq"
  chmod +x "$home/fakebin/jq"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  with_home "$home" fm_run_timed 20 bash "$home/state/contributions.check.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a poll over 151 settled records outlived the watcher's 20-second check bound (status $rc)"
  "$real_jq" -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the open PR was not observed before the check bound in a home with many settled records'
  pass 'a home with many settled records still observes its open PR within the check bound'
}

test_many_settled_records_beside_a_malformed_one_keep_the_poll_inside_the_check_bound() {
  local home real_jq template i task record rc=0
  home=$(new_home many-settled-malformed)
  forge_home "$home"
  record "$home" landed 900 merged mergeable
  template=$(cat "$home/data/landed/contributions.json")
  for i in $(seq 1 150); do
    task="landed-$i"
    mkdir -p "$home/data/$task"
    record=${template//\"landed\"/\"$task\"}
    printf '%s\n' "${record//pull\/900/pull/$((900 + i))}" > "$home/data/$task/contributions.json"
  done
  printf '{broken\n' > "$home/data/landed-1/contributions.json"
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
    html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || fail 'could not arm the contribution check'
  real_jq=$(command -v jq)
  printf '#!/bin/sh\nsleep 0.05\nexec %s "$@"\n' "$real_jq" > "$home/fakebin/jq"
  chmod +x "$home/fakebin/jq"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  with_home "$home" fm_run_timed 20 bash "$home/state/contributions.check.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a poll over 150 settled records and a malformed one outlived the watcher's 20-second check bound (status $rc)"
  "$real_jq" -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the open PR was not observed before the check bound in a home with many settled records and a malformed one'
  pass 'a home with many settled records and a malformed one still observes its open PR within the check bound'
}

test_record_without_trailing_newline_does_not_join_its_neighbour() {
  local home name n=0 actual
  home=$(new_home no-trailing-newline)
  for name in alpha beta gamma; do
    n=$((n + 1))
    mkdir -p "$home/data/$name"
    jq -nj --arg task "$name" --arg url "https://github.com/o/r/pull/$n" --arg token "t$n" \
      '{schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:null,error:null,
        pending:[{token:$token}],seen:[],verdict:null,observation:null}]}' > "$home/data/$name/contributions.json"
  done
  actual=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[].task] | sort') \
    || fail 'records without a trailing newline made pending unreadable'
  [ "$actual" = '["alpha","beta","gamma"]' ] || fail "records without a trailing newline named tasks $actual"
  pass 'a record without a trailing newline stays readable beside its neighbours'
}

test_reservation_defers_later_url_when_fifteen_seconds_do_not_remain() {
  local home out
  home=$(new_home reservation)
  forge_home "$home"
  wrap_forge "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'reserve\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'reservation poll failed'
  [ -z "$out" ] || fail "reservation poll printed an unavailable wake: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/filed/contributions.json" >/dev/null \
    || fail 'the first issue was not observed before reserving the remaining budget'
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    && fail 'a later PR began without the fifteen-second observation reservation'
  jq -e '.records[0].checked_at == "2026-09-15T08:00:00Z"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a later PR record changed when the poll deferred it for budget'
  pass 'a later URL waits when fewer than fifteen seconds remain for its observation'
}

test_three_second_pr_reads_complete_fresh_in_one_cycle() { # 3-second reads: 8 sequential > 20s budget, parallel waves fit
  local home out
  home=$(new_home three-second-pr)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=3 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'a 3-second-read PR observation failed'
  [ -z "$out" ] || fail "a fresh 3-second-read PR observation woke: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a 3-second-read PR observation was not fresh within one cycle'
  pass 'eight 3-second PR reads complete fresh within one 20-second poll cycle'
}

test_slow_read_deadline_kill_is_budget_refusal() {
  local home out
  home=$(new_home slow-kill)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  /bin/date +%s > "$home/forge/clock"
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=6 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on a deadline-killed slow read'
  [ -z "$out" ] || fail "a deadline-killed slow read printed an unavailable wake: $out"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail 'a deadline-killed slow read rewrote the prior record'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a deadline-killed slow read enqueued a wake'
  pass 'a read killed at the five-second bound is budget refusal and stays silent'
}

test_unmeasured_url_does_not_starve_the_tail() {
  local home out cycle at started elapsed task
  home=$(new_home unmeasured-tail)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  printf 'slow-wave\n' > "$home/forge/fault"
  for cycle in 0 1 2; do
    at=$(jq -nr --arg now "$NOW" --argjson cycle "$cycle" '(($now | fromdateiso8601) + ($cycle + 1) * 300) | todateiso8601')
    started=$(/bin/date +%s)
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'poll failed after an unmeasured first URL'
    elapsed=$(( $(/bin/date +%s) - started ))
    [ -z "$out" ] || fail "a poll after an unmeasured URL printed a wake: $out"
    [ "$elapsed" -le 23 ] || fail "poll exceeded its elapsed budget: $elapsed seconds"
    if [ "$cycle" -eq 0 ]; then
      [ "$elapsed" -ge 8 ] || fail 'the slow head did not consume its core and parallel-wave budget'
      if grep -Eq '^api repos/o/r/pulls/(9|10)$' "$home/forge/calls"; then
        fail 'a tail PR began without its observation reserve'
      fi
    fi
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail 'a timed-out observation changed its prior freshness or record'
  done
  for task in second third; do
    jq -e --arg prior "$NOW" '.records[0] | .checked_at != $prior and .error == null' \
      "$home/data/$task/contributions.json" >/dev/null \
      || fail "successive polls starved $task behind the slow head"
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'routine slow reads enqueued a wake'
  home=$(new_home sustained-slow-refresh)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  record "$home" merged-one 90 merged mergeable
  record "$home" closed-one 91 closed mergeable
  record "$home" merged-two 92 merged mergeable
  record "$home" closed-two 93 closed mergeable
  mutate_record "$home" closed-two '.records[0].error="forge observation unavailable or changed during read"'
  cp "$home/data/closed-two/contributions.json" "$home/terminal.json"
  printf -- '- [ ] late-owner - Shared https://github.com/o/r/pull/93 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  for task in delivery second third; do
    mutate_record "$home" "$task" '.records[0].checked_at="2026-09-16T07:55:00Z"'
  done
  printf 'latency\n' > "$home/forge/fault"
  for cycle in 0 1 2 3 4 5; do
    at=$(jq -nr --arg now "$NOW" --argjson cycle "$cycle" '(($now | fromdateiso8601) + $cycle * 300) | todateiso8601')
    started=$(/bin/date +%s)
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=3 "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'sustained slow-read poll failed'
    elapsed=$(( $(/bin/date +%s) - started ))
    [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 23 ] \
      || fail "slow successful poll did not respect its elapsed budget: $elapsed seconds"
    [ -z "$out" ] || fail "slow successful reads printed a wake: $out"
    for task in closed-two late-owner; do
      jq -e --slurpfile prior "$home/terminal.json" '.records[0] | .error == null
        and .checked_at == $prior[0].records[0].checked_at
        and .observation == $prior[0].records[0].observation' \
        "$home/data/$task/contributions.json" >/dev/null \
        || fail "terminal settlement or freshness changed for $task"
    done
    if grep -Eq '^api repos/o/r/pulls/9[0-3]($|/)' "$home/forge/calls"; then
      fail 'a retained terminal PR was read from the forge'
    fi
    if [ "$cycle" -ge 2 ]; then
      for task in delivery second third; do
        jq -e --arg at "$at" '.records[0] | .error == null
          and (($at | fromdateiso8601) - (.checked_at | fromdateiso8601) <= 600)' \
          "$home/data/$task/contributions.json" >/dev/null \
          || fail "$task was not refreshed within three consecutive slow polls at $at"
      done
    fi
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'slow successful reads enqueued a wake'
  pass 'rotation preserves timed-out records and refreshes every slow PR on successive cycles'
}

test_budget_is_cut_down_to_the_watcher_check_bound() {
  local home out
  home=$(new_home check-bound-budget)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  /bin/date +%s > "$home/forge/clock"
  printf 'hang\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CHECK_TIMEOUT=6 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed under a small watcher check bound'
  [ -z "$out" ] || fail "a check-bound-capped poll printed a wake: $out"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail 'a poll observed with the full budget despite a six-second check bound'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a check-bound-capped poll enqueued a wake'
  pass 'the effective budget is cut down to the watcher per-check bound with margin'
}

test_arm_plumbs_a_configured_budget_into_the_check_shim() {
  local home out mode
  for mode in configured inherited; do
    home=$(new_home "arm-budget-$mode")
    forge_home "$home"
    wrap_forge "$home"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    cp "$home/data/delivery/contributions.json" "$home/prior.json"
    # Freeze the clock: an unfrozen one can tick past the one-second budget
    # before the first forge call, so nothing is ever observed.
    /bin/date +%s > "$home/forge/clock"
    printf 'hang\n' > "$home/forge/fault"
    # Freeze the clock. An unfrozen one-second budget can tick past before the
    # first forge call, so the generated check never writes forge/calls.
    /bin/date +%s > "$home/forge/clock"
    if [ "$mode" = configured ]; then
      with_home "$home" env FM_CONTRIBUTIONS_BUDGET=1 "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
        || fail 'arm with a configured budget failed'
      out=$(with_home "$home" env -u FM_CONTRIBUTIONS_BUDGET bash "$home/state/contributions.check.sh") \
        || fail 'configured check shim failed'
    else
      with_home "$home" env -u FM_CONTRIBUTIONS_BUDGET "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
        || fail 'arm without a configured budget failed'
      out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=1 bash "$home/state/contributions.check.sh") \
        || fail 'inherited-budget check shim failed'
    fi
    [ -z "$out" ] || fail "generated check printed an unavailable wake: $out"
    grep -Fxq 'api repos/o/r/pulls/8' "$home/forge/calls" || fail 'generated check did not attempt a read'
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail "generated check failed to preserve the $mode one-second budget"
  done
  pass 'generated checks enforce configured and inherited budgets at runtime'
}

test_unavailable_forge_records_error_and_wakes_once_per_episode() { # genuine outage, two consecutive cycles
  local why='core read exited 1 with Ns of budget left: gh: Bad Gateway (HTTP 502)'
  local home out line="contributions: observation unavailable for https://github.com/o/r/pull/8 - $why"
  home=$(new_home failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  poll_at() {
    local polled
    polled=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll) || fail "poll at $1 failed"
    printf '%s\n' "$polled" | mask_budget
  }
  out=$(poll_at 2026-09-16T09:00:00Z)
  [ "$out" = "$line" ] || fail "the first failure of an episode did not wake with its cause: $out"
  out=$(poll_at 2026-09-16T10:00:00Z)
  [ -z "$out" ] || fail "an unchanged read failure woke again on the next cycle: $out"
  jq -e '.records[0].checked_at == "2026-09-16T10:00:00Z"' "$home/data/delivery/contributions.json" >/dev/null \
    && [ "$(jq -r .records[0].error "$home/data/delivery/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
    || fail 'a repeated read failure stopped recording its error and cause'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 4 ] || fail 'a failing open PR stopped being observed'
  bearings "$home" | jq -e '.contributions | .known == 1 and .checked == 0
    and .unmeasured == 0 and .counts.fleet == 1 and .complete == false' >/dev/null \
    || fail 'a supported GitHub failure became unmeasured or successful coverage'
  : > "$home/forge/fault"
  out=$(poll_at 2026-09-16T11:00:00Z)
  [ -z "$out" ] || fail "a successful read printed: $out"
  jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a successful read did not end the failure episode'
  printf 'down\n' > "$home/forge/fault"
  out=$(poll_at 2026-09-16T12:00:00Z)
  [ "$out" = "$line" ] || fail "a new failure after a successful read did not wake: $out"
  pass 'a genuinely unavailable forge records an error and wakes once per failure episode'
}

test_late_owner_keeps_failure_episode_suppressed() {
  local why='core read exited 1 with Ns of budget left: gh: Bad Gateway (HTTP 502)' home out task
  local line="contributions: observation unavailable for https://github.com/o/r/pull/8 - $why"
  home=$(new_home late-owner-failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial failing poll failed'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "$line" ] || fail "the initial failure did not wake with its cause: $out"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner failing poll failed'
  [ -z "$out" ] || fail "a late owner restarted an unchanged failure episode: $out"
  for task in delivery duplicate; do
    [ "$(jq -r .records[0].error "$home/data/$task/contributions.json" | mask_budget)" = "forge observation unavailable: $why" ] \
      || fail "owner $task did not retain the shared failure evidence"
  done
  : > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'successful shared poll failed'
  [ -z "$out" ] || fail "a successful shared poll printed: $out"
  for task in delivery duplicate; do
    jq -e '.records[0].error == null' "$home/data/$task/contributions.json" >/dev/null \
      || fail "owner $task did not end the shared failure episode"
  done
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'new shared failing poll failed'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "$line" ] || fail "a failure after shared recovery did not wake: $out"
  pass 'a late owner does not restart a shared forge failure episode'
}

test_retire_ends_observation_of_a_gone_contribution() {
  local home out url=https://github.com/o/r/pull/8
  local line='contributions: observation unavailable for https://github.com/o/r/pull/8 - core read exited 1 with Ns of budget left: gh: Not Found (HTTP 404)'
  home=$(new_home retire-gone)
  forge_home "$home"
  wrap_forge "$home"
  printf 'not-found\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'failing poll failed'
  [ "$(printf '%s\n' "$out" | mask_budget)" = "$line" ] || fail "a gone repository did not raise the unavailable check with its cause: $out"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unreadable contribution did not hold coverage incomplete before retirement'
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z "$ROOT/bin/fm-contributions.sh" retire delivery "$url" captain 'repository deleted' \
    || fail 'retire of an owned unreadable contribution failed'
  jq -e '.records[0].retired == {actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'retire did not record its provenance'
  : > "$home/forge/calls"
  for at in 2026-09-16T10:00:00Z 2026-09-16T10:05:00Z; do
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" "$ROOT/bin/fm-contributions.sh" poll) || fail "poll after retire failed at $at"
    [ -z "$out" ] || fail "a retired contribution still raised a check: $out"
  done
  [ ! -s "$home/forge/calls" ] || fail "a retired contribution stayed in rotation: $(cat "$home/forge/calls")"
  bearings "$home" | jq -e '.contributions.known == 0 and .contributions.checked == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a retired contribution still counted against coverage despite its backlog link'
  pass 'retire stops the unavailable check, leaves rotation and restores complete coverage'
}

test_late_owner_of_a_retired_final_contribution_is_not_retired() {
  local home out
  home=$(new_home retire-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged"
    | .records[0].retired={actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}'
  record "$home" duplicate 8 merged mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  printf -- '- [ ] late - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-17T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'late-owner poll failed'
  [ -z "$out" ] || fail "a late owner of a retired final contribution printed: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a known final contribution triggered a forge read'
  jq -e '.records[0] | .retired == null and .observation.state == "merged" and .error == null' \
    "$home/data/late/contributions.json" >/dev/null || fail 'a late owner inherited another task'"'"'s retirement'
  jq -e '.records[0].retired.reason == "repository deleted"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'settling a late owner changed the retired record'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'contribution input failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all | jq -e '.rows[0].tasks == ["duplicate","late"]' >/dev/null \
    || fail 'a late owner settled beside a retired final record left known'
  pass 'a late owner settled beside a retired final record stays unretired and known'
}

test_retire_is_idempotent_and_refuses_unknown_pairs() {
  local home url=https://github.com/o/r/pull/8 before err
  home=$(new_home retire-refusals)
  forge_home "$home"
  retire() { with_home "$home" "$ROOT/bin/fm-contributions.sh" retire "$@"; }
  retire delivery "$url" fleet 'repository deleted' >/dev/null 2>&1 && fail 'retire accepted the fleet as its actor'
  jq -e '.records[0].retired == null' "$home/data/delivery/contributions.json" >/dev/null || fail 'a fleet retire changed the record'
  retire delivery "$url" captain 'repository deleted' >/dev/null || fail 'first retire failed'
  before=$(cat "$home/data/delivery/contributions.json")
  retire delivery "$url" captain 'second reason' >/dev/null || fail 'repeating a retire was refused'
  [ "$(cat "$home/data/delivery/contributions.json")" = "$before" ] || fail 'repeating a retire rewrote its first provenance'
  printf -- '- [ ] linked - Linked only https://github.com/o/r/pull/30 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  err=$(retire linked https://github.com/o/r/pull/30 captain gone 2>&1) && fail 'retire created a record for an unobserved pair'
  case "$err" in *'not recorded for this durable task'*) ;; *) fail "unrecorded-pair refusal was unclear: $err" ;; esac
  [ ! -e "$home/data/linked/contributions.json" ] || fail 'a refused retire created a record'
  retire other "$url" captain gone >/dev/null 2>&1 && fail 'retire accepted a task that does not own the URL'
  record "$home" queued 31 open mergeable
  retire queued https://github.com/o/r/pull/31 owner gone >/dev/null 2>&1 && fail 'retire accepted an unknown actor'
  retire queued https://github.com/o/r/pull/31 captain '' >/dev/null 2>&1 && fail 'retire accepted an empty reason'
  retire queued https://github.com/o/r/pull/31 captain ' 	 ' >/dev/null 2>&1 && fail 'retire accepted a whitespace-only reason'
  retire queued https://github.com/o/r/pull/31 captain >/dev/null 2>&1 && fail 'retire accepted a missing reason'
  mutate_record "$home" queued '.records[0].pending=[{token:"comment:1:x",type:"comment"}]'
  retire queued https://github.com/o/r/pull/31 captain gone >/dev/null 2>&1 && fail 'retire dropped an unacknowledged signal'
  jq -e '.records[0].retired == null' "$home/data/queued/contributions.json" >/dev/null || fail 'a refused retire changed the record'
  pass 'retire is idempotent and refuses non-captain, unknown, malformed and signal-bearing pairs'
}

# GitHub returns every review with its full body, user object and links; a
# long-lived PR's history must still leave a record every reader accepts.
test_many_reviews_stay_readable() {
  local home size out wakes token
  home=$(new_home many-reviews)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the many-review delivery'
  # 300 reviews: a non-member bot comments on every head, while the maintainer
  # and a collaborator leave formal states on the observed and a replaced head.
  jq -n --arg a "$HEAD_A" --arg b "$HEAD_B" '
    ("x" * 4000) as $body
    | def person($login; $id): {login:$login,id:$id,node_id:"MDQ6VXNlcjE=",type:"User",site_admin:false,
        avatar_url:"https://avatars.githubusercontent.com/u/1?v=4",gravatar_id:"",
        url:("https://api.github.com/users/" + $login),html_url:("https://github.com/" + $login),
        followers_url:("https://api.github.com/users/" + $login + "/followers"),
        following_url:("https://api.github.com/users/" + $login + "/following{/other_user}"),
        gists_url:("https://api.github.com/users/" + $login + "/gists{/gist_id}"),
        starred_url:("https://api.github.com/users/" + $login + "/starred{/owner}{/repo}"),
        subscriptions_url:("https://api.github.com/users/" + $login + "/subscriptions"),
        organizations_url:("https://api.github.com/users/" + $login + "/orgs"),
        repos_url:("https://api.github.com/users/" + $login + "/repos"),
        events_url:("https://api.github.com/users/" + $login + "/events{/privacy}"),
        received_events_url:("https://api.github.com/users/" + $login + "/received_events")};
    [range(1; 301) as $i
     | (if $i % 10 == 0 then ["maintainer","OWNER",(if $i == 300 then "COMMENTED" elif $i == 290 then "CHANGES_REQUESTED" else "APPROVED" end),$a]
        elif $i % 10 == 5 then ["helper","COLLABORATOR",(if $i == 295 then "APPROVED" else "COMMENTED" end),(if $i == 295 then $b else $a end)]
        else ["review-bot","NONE","COMMENTED",$a] end) as [$login,$association,$state,$commit]
     | {id:(1000 + $i),node_id:"PRR_kwDOAAAA",user:person($login; $i),body:$body,state:$state,
        html_url:("https://github.com/o/r/pull/8#pullrequestreview-" + ((1000 + $i) | tostring)),
        pull_request_url:"https://api.github.com/repos/o/r/pulls/8",author_association:$association,
        _links:{html:{href:"https://github.com/o/r/pull/8"},pull_request:{href:"https://api.github.com/repos/o/r/pulls/8"}},
        submitted_at:(1789538400 + $i * 10 | todate),commit_id:$commit}]' > "$home/forge/reviews.json"
  [ "$(wc -c < "$home/forge/reviews.json")" -gt 1048576 ] || fail 'the many-review fixture no longer exceeds the record cap'
  registered_checks "$home" >/dev/null
  size=$(wc -c < "$home/data/delivery/contributions.json" | tr -d " ")
  [ "$size" -lt 524288 ] || fail "a many-review observation wrote a $size-byte record"
  jq -e '.records[0].observation.reviews | length == 300
    and all(.[]; keys == ["commit_id","id","state","submitted_at","user"] and .user == {login:.user.login})' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'stored reviews carry more than the classified fields'
  wakes=$(awk 'END { print NR }' "$home/state/.wake-queue")
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$wakes" ] || fail 'already notified review signals woke again'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending) || fail 'a many-review record made pending unreadable'
  printf '%s' "$out" | jq -e 'length == 60 and all(.[]; .type == "review")' >/dev/null \
    || fail "pending lost the maintainer review signals: $out"
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect many-review contribution input'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project the many-review record'
  printf '%s' "$out" | jq -e --arg a "$HEAD_A" --arg b "$HEAD_B" '
    .unreadable_records == 0 and .rows[0].stale_verdicts == 1
    and .rows[0].reviews == [
      {id:1295,state:"APPROVED",submitted_at:"2026-09-16T06:49:10Z",commit_id:$b,user:{login:"helper"},freshness:"STALE"},
      {id:1290,state:"CHANGES_REQUESTED",submitted_at:"2026-09-16T06:48:20Z",commit_id:$a,user:{login:"maintainer"},freshness:"current"}]' \
    >/dev/null || fail "the stored review projection changed the classified reviews: $out"
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[0].token') || fail 'no review token to acknowledge'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" \
    || fail 'a many-review record refused an exact acknowledgement'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#pullrequestreview-1290 fleet 'address requested changes' \
    || fail 'a many-review record refused a verdict'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 59' >/dev/null \
    || fail 'the acknowledgement did not persist in the many-review record'
  pass 'a many-review PR stores only classified review fields and stays readable'
}

# The 19-hour incident: a reviewer's inline comment was acknowledged while the
# delivery sat on a captain hold, and nothing raised the thread again.
unanswered_home() { # name: delivery on a captain hold with one unanswered inline comment
  local home
  home=$(new_home "$1")
  forge_home "$home"
  sed -i.bak '/ delivery /s/$/ (hold: wait for the scope decision) (hold-kind: captain)/' "$home/data/backlog.md" \
    && rm -f "$home/data/backlog.md.bak"
  jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",
    body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head}]' > "$home/forge/inline.json"
  printf '%s\n' "$home"
}

poll_at() { with_home "$1" env FM_CONTRIBUTIONS_REPLY_AGE=86400 FM_CONTRIBUTIONS_NOW="$2" "$ROOT/bin/fm-contributions.sh" poll; }

ack_pending() { # home: acknowledge the one pending signal
  local home=$1 token
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er 'first | .token') || fail 'no pending signal to acknowledge'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" || fail 'ack failed'
}

test_unanswered_thread_is_raised_again_under_hold() {
  local home out
  home=$(unanswered_home unanswered-hold)
  out=$(poll_at "$home" 2026-09-16T08:01:00Z) || fail 'first poll failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64}$' \
    || fail "the arriving comment did not raise its ordinary wake: $out"
  ack_pending "$home"
  out=$(poll_at "$home" 2026-09-17T03:00:00Z) || fail 'poll 19 hours after the comment failed'
  [ -z "$out" ] || fail "a thread 19 hours old was raised again before the bound: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'an acknowledged signal came back before the bound'
  out=$(poll_at "$home" 2026-09-17T09:00:00Z) || fail 'poll 25 hours after the comment failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64} unanswered https://github.com/o/r/pull/8#discussion_r31 25h$' \
    || fail "an unanswered thread under a hold was not raised with its URL and age: $out"
  grep -Fq 'unanswered https://github.com/o/r/pull/8#discussion_r31 25h' "$home/state/.wake-queue" \
    || fail 'the re-raise never reached the durable wake queue'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 1 and .[0].type == "unanswered" and .[0].source == "https://github.com/o/r/pull/8#discussion_r31"
      and .[0].age == "25h" and .[0].author == "maintainer"' >/dev/null \
    || fail 'the re-raise is not one pending signal naming the thread'
  jq -e '.records[0].threads | length == 1 and .[0].raised == "2026-09-17T09:00:00Z"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'the re-raise did not record when the thread was raised'
  # An acknowledged re-raise is raised again one reply age later, not at every poll.
  ack_pending "$home"
  out=$(poll_at "$home" 2026-09-18T08:00:00Z) || fail 'poll 24 hours after the re-raise failed'
  [ -z "$out" ] || fail "the thread was raised again before a day passed: $out"
  out=$(poll_at "$home" 2026-09-18T09:00:00Z) || fail 'poll a day after the re-raise failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8#discussion_r31 49h$' \
    || fail "the thread was not raised again a day later: $out"
  jq -e '[.records[0].notified[] | select(startswith("unanswered:"))] | length == 1' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'acknowledged re-raises stayed in the notified list'
  # A reply from the contribution author in the thread ends the tracking and
  # withdraws the signal nobody had acknowledged yet.
  jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",
      body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",
      created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head},
    {id:32,in_reply_to_id:31,user:{login:"author"},author_association:"NONE",body:"Fixed in the next push",
      html_url:"https://github.com/o/r/pull/8#discussion_r32",created_at:"2026-09-18T10:00:00Z",updated_at:"2026-09-18T10:00:00Z",commit_id:$head}]' \
    > "$home/forge/inline.json"
  for at in 2026-09-18T10:05:00Z 2026-09-20T10:00:00Z; do
    out=$(poll_at "$home" "$at") || fail "poll at $at failed"
    [ -z "$out" ] || fail "an answered thread was raised at $at: $out"
  done
  jq -e '.records[0] | (.threads | length) == 0 and (.pending | length) == 0' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'an author reply did not clear the tracked thread and its signal'
  pass 'an acknowledged unanswered thread under a hold is raised again after a day, daily, until the author replies'
}

test_resolved_thread_is_answered() {
  local home out
  home=$(unanswered_home resolved-thread)
  printf '[{"isResolved":false,"comments":{"nodes":[{"databaseId":40}]}},{"isResolved":true,"comments":{"nodes":[{"databaseId":31}]}}]\n' \
    > "$home/forge/threads.json"
  poll_at "$home" 2026-09-16T08:01:00Z >/dev/null || fail 'first poll failed'
  ack_pending "$home"
  out=$(poll_at "$home" 2026-09-18T08:00:00Z) || fail 'poll two days later failed'
  [ -z "$out" ] || fail "a resolved thread was raised as unanswered: $out"
  jq -e '.records[0].threads | length == 0' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a resolved thread stayed tracked'
  pass 'a resolved thread with no reply counts as answered'
}

test_reply_rules() {
  local home out
  home=$(new_home reply-rules)
  forge_home "$home"
  jq -n --arg head "$HEAD_A" '[
    {id:50,user:{login:"maintainer"},author_association:"OWNER",body:"Please explain",html_url:"https://github.com/o/r/pull/8#issuecomment-50",created_at:"2026-09-16T06:00:00Z",updated_at:"2026-09-16T06:00:00Z"},
    {id:51,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks, merging soon",html_url:"https://github.com/o/r/pull/8#issuecomment-51",created_at:"2026-09-16T07:00:00Z",updated_at:"2026-09-16T07:00:00Z"},
    {id:52,user:{login:"author"},author_association:"NONE",body:"Explained above",html_url:"https://github.com/o/r/pull/8#issuecomment-52",created_at:"2026-09-16T06:30:00Z",updated_at:"2026-09-16T06:30:00Z"}]' \
    > "$home/forge/comments.json"
  jq -n --arg head "$HEAD_A" '[
    {id:60,user:{login:"maintainer"},author_association:"MEMBER",state:"APPROVED",body:"LGTM",html_url:"https://github.com/o/r/pull/8#pullrequestreview-60",submitted_at:"2026-09-16T05:00:00Z",commit_id:$head},
    {id:61,user:{login:"maintainer"},author_association:"MEMBER",state:"CHANGES_REQUESTED",body:"",html_url:"https://github.com/o/r/pull/8#pullrequestreview-61",submitted_at:"2026-09-16T05:00:00Z",commit_id:$head},
    {id:62,user:{login:"maintainer"},author_association:"MEMBER",state:"CHANGES_REQUESTED",body:"Needs a test",html_url:"https://github.com/o/r/pull/8#pullrequestreview-62",submitted_at:"2026-09-16T06:45:00Z",commit_id:$head},
    {id:63,user:{login:"maintainer"},author_association:"MEMBER",state:"CHANGES_REQUESTED",body:"",html_url:"https://github.com/o/r/pull/8#pullrequestreview-63",submitted_at:"2026-09-16T07:30:00Z",commit_id:$head},
    {id:64,user:{login:"reviewer"},author_association:"MEMBER",state:"CHANGES_REQUESTED",body:"Rename this",html_url:"https://github.com/o/r/pull/8#pullrequestreview-64",submitted_at:"2026-09-16T07:00:00Z",commit_id:$head},
    {id:65,user:{login:"reviewer"},author_association:"MEMBER",state:"APPROVED",body:"",html_url:"https://github.com/o/r/pull/8#pullrequestreview-65",submitted_at:"2026-09-16T07:40:00Z",commit_id:$head}]' \
    > "$home/forge/reviews.json"
  jq -n --arg head "$HEAD_A" '[
    {id:70,user:{login:"maintainer"},author_association:"OWNER",body:"Root",html_url:"https://github.com/o/r/pull/8#discussion_r70",created_at:"2026-09-16T04:00:00Z",updated_at:"2026-09-16T04:00:00Z",commit_id:$head},
    {id:71,in_reply_to_id:70,user:{login:"stranger"},author_association:"NONE",body:"Same here",html_url:"https://github.com/o/r/pull/8#discussion_r71",created_at:"2026-09-16T04:30:00Z",updated_at:"2026-09-16T04:30:00Z",commit_id:$head},
    {id:72,user:{login:"maintainer"},author_association:"OWNER",body:"Other thread",html_url:"https://github.com/o/r/pull/8#discussion_r72",created_at:"2026-09-16T04:00:00Z",updated_at:"2026-09-16T04:00:00Z",commit_id:$head},
    {id:73,in_reply_to_id:72,user:{login:"author"},author_association:"NONE",body:"Done",html_url:"https://github.com/o/r/pull/8#discussion_r73",created_at:"2026-09-16T04:30:00Z",updated_at:"2026-09-16T04:30:00Z",commit_id:$head},
    {id:74,in_reply_to_id:72,user:{login:"maintainer"},author_association:"OWNER",body:"Still wrong",html_url:"https://github.com/o/r/pull/8#discussion_r74",created_at:"2026-09-16T05:00:00Z",updated_at:"2026-09-16T05:00:00Z",commit_id:$head}]' \
    > "$home/forge/inline.json"
  poll_at "$home" 2026-09-16T08:00:00Z >/dev/null || fail 'poll failed'
  jq -e '[.records[0].threads[].key] | sort == ["review-comment:70","review-comment:74","review:62"]' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail "wrong threads tracked: $(jq -c '[.records[0].threads[].key]' "$home/data/delivery/contributions.json")"
  out=$(poll_at "$home" 2026-09-18T08:00:00Z) || fail 'poll two days later failed'
  [ "$(printf '%s\n' "$out" | grep -o 'unanswered https://[^ ]*' | sort)" = "$(printf '%s\n' \
    'unanswered https://github.com/o/r/pull/8#discussion_r70' 'unanswered https://github.com/o/r/pull/8#discussion_r74' \
    'unanswered https://github.com/o/r/pull/8#pullrequestreview-62')" ] \
    || fail "a plain comment was raised again, or a tracked thread was not: $out"
  pass 'only inline threads and reviews requesting changes with text, no author reply, resolution or later verdict are tracked as unanswered'
}

test_reply_age_is_configurable_and_validated() {
  local home out bad
  home=$(unanswered_home reply-age)
  poll_at "$home" 2026-09-16T08:01:00Z >/dev/null || fail 'first poll failed'
  ack_pending "$home"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z FM_CONTRIBUTIONS_REPLY_AGE=3600 \
    "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll with a one-hour reply age failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8#discussion_r31 1h$' \
    || fail "a one-hour reply age did not raise the thread: $out"
  for bad in soon -5 1.5 0 00 000; do
    with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE="$bad" "$ROOT/bin/fm-contributions.sh" poll >/dev/null 2>&1 \
      && fail "the reply age '$bad' was accepted"
  done
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z FM_CONTRIBUTIONS_REPLY_AGE=03600 \
    "$ROOT/bin/fm-contributions.sh" poll >/dev/null 2>&1 || fail 'a zero-padded positive reply age was refused'
  pass 'the reply age is a validated seconds setting'
}

test_closed_pull_request_drops_its_threads() {
  local home
  home=$(unanswered_home closed-threads)
  poll_at "$home" 2026-09-16T08:01:00Z >/dev/null || fail 'first poll failed'
  printf 'merged\n' > "$home/forge/state"
  poll_at "$home" 2026-09-18T08:00:00Z >/dev/null || fail 'poll after the merge failed'
  jq -e '.records[0] | .observation.state == "merged" and (.threads | length) == 0
    and all(.pending[]; .type != "unanswered")' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a merged pull request kept unanswered threads'
  pass 'a closed pull request stops raising its threads'
}

test_unanswered_reraise_is_off_unless_configured() {
  local home out at
  home=$(unanswered_home reraise-off)
  wrap_forge "$home"
  poll_off() { with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll; }
  out=$(poll_off 2026-09-16T08:01:00Z) || fail 'first poll without a reply age failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64}$' \
    || fail "the arriving comment lost its ordinary wake: $out"
  ack_pending "$home"
  for at in 2026-09-17T09:00:00Z 2026-09-18T09:00:00Z 2026-09-25T09:00:00Z; do
    out=$(poll_off "$at") || fail "poll at $at without a reply age failed"
    [ -z "$out" ] || fail "an unconfigured install raised a thread at $at: $out"
  done
  ! grep -Fq 'api graphql' "$home/forge/calls" || fail 'an unconfigured install read review threads'
  jq -e '.records[0] | has("threads") == false and (.pending | length) == 0
    and all(.observation.events[]; has("unanswered") == false and has("at") == false)' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an unconfigured install recorded thread tracking'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE= FM_CONTRIBUTIONS_NOW=2026-09-26T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll with an empty reply age failed'
  [ -z "$out" ] || fail "an empty reply age raised a thread: $out"
  # Turning the setting on tracks the thread, and turning it off again withdraws it.
  out=$(poll_at "$home" 2026-09-27T09:00:00Z) || fail 'poll with the setting on failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8#discussion_r31 ' \
    || fail "a configured install did not raise the thread: $out"
  grep -Fq 'api graphql' "$home/forge/calls" || fail 'a configured install never read review threads'
  out=$(poll_off 2026-09-27T10:00:00Z) || fail 'poll with the setting off again failed'
  [ -z "$out" ] || fail "switching the setting off printed a wake: $out"
  jq -e '.records[0] | has("threads") == false and all(.pending[]; .type != "unanswered")
    and all(.notified[]; startswith("unanswered:") | not)' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'switching the setting off left thread tracking behind'
  pass 'the unanswered re-raise and the review-thread read stay off unless a reply age is configured'
}

test_arm_plumbs_the_reply_age_into_the_check_shim() {
  local home out
  home=$(unanswered_home arm-reply-age)
  poll_at "$home" 2026-09-16T08:01:00Z >/dev/null || fail 'first poll failed'
  ack_pending "$home"
  with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=3600 "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
    || fail 'arm with a reply age failed'
  out=$(with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z bash "$home/state/contributions.check.sh") \
    || fail 'configured check shim failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8#discussion_r31 1h$' \
    || fail "the generated check ignored the configured reply age: $out"
  with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
    || fail 'arm without a reply age failed'
  out=$(with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-18T09:30:00Z bash "$home/state/contributions.check.sh") \
    || fail 'unconfigured check shim failed'
  [ -z "$out" ] || fail "a check armed without a reply age raised a thread: $out"
  pass 'arm copies a configured reply age into the generated check'
}

failures=0
for test_name in test_actor_coverage test_stale_verdict test_unchecked_is_not_silence test_newest_check_has_no_verdict test_comment_wake test_review_wake test_inline_wake test_review_bot_inline_wake test_review_bot_watching_is_opt_in test_review_bot_allowlist_is_configurable test_ready_issue_wake test_fresh_issue_requires_maintainer test_missing_lane_remains_missing test_partial_freshness_keeps_measured_rows test_malformed_record_cannot_prove_silence test_issue_timeline_and_exact_ack test_verdict_retains_judged_head test_verdict_actor_values_are_discoverable test_observed_replacement_refreshes_verdict test_unobserved_head_leaves_verdict_unknown test_away_yolo_is_fleet_work test_away_yolo_cross_home_is_fleet_work test_retired_and_unsupported_coverage test_unsupported_forge_is_not_fleet_work test_held_unsupported_forge_is_not_captain_work test_unsupported_poll_is_silent_and_clears_legacy_errors test_legacy_cleanup_preserves_supported_failure test_shared_contribution_signal_wakes_once test_watcher_keeps_diagnostics_separate_from_contribution_wakes test_expired_child_unsupported_forge_stays_unmeasured test_watcher_surfaces_new_contribution_once test_home_summary_coverage test_unreadable_pending_is_not_empty test_record_task_identity_matches_dirname_basename test_read_only_views_create_no_state test_budget_refusal_between_calls test_budget_bounded_call_timeout test_genuine_failure_near_deadline_is_unavailable test_http_500_once_retries_without_waking test_http_500_twice_records_the_failed_read test_http_404_is_not_retried test_real_gh_errors_drive_retry_and_summary test_next_url_does_not_inherit_a_forge_diagnostic test_shared_url_observed_once test_terminal_contribution_settles test_late_owner_inherits_terminal_observation test_interrupted_multi_owner_poll_settles_every_owner test_done_task_open_pr_still_observed test_many_settled_records_keep_the_poll_inside_the_check_bound test_many_settled_records_beside_a_malformed_one_keep_the_poll_inside_the_check_bound test_record_without_trailing_newline_does_not_join_its_neighbour test_reservation_defers_later_url_when_fifteen_seconds_do_not_remain test_three_second_pr_reads_complete_fresh_in_one_cycle test_slow_read_deadline_kill_is_budget_refusal test_unmeasured_url_does_not_starve_the_tail test_budget_is_cut_down_to_the_watcher_check_bound test_arm_plumbs_a_configured_budget_into_the_check_shim test_unavailable_forge_records_error_and_wakes_once_per_episode test_late_owner_keeps_failure_episode_suppressed test_retire_ends_observation_of_a_gone_contribution test_late_owner_of_a_retired_final_contribution_is_not_retired test_retire_is_idempotent_and_refuses_unknown_pairs test_unanswered_thread_is_raised_again_under_hold test_resolved_thread_is_answered test_reply_rules test_reply_age_is_configurable_and_validated test_closed_pull_request_drops_its_threads test_unanswered_reraise_is_off_unless_configured test_arm_plumbs_the_reply_age_into_the_check_shim test_many_reviews_stay_readable; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures contribution regressions"
