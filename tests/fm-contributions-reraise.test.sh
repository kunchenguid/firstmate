#!/usr/bin/env bash
# Behavioral tests for contribution-level unanswered re-raising.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions-reraise)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/root/bin" "$home/wt" "$home/forge"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/"*
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  mkdir -p "$home/data/delivery"
  printf -- '- [ ] delivery - Contribution delivery https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  jq -n --arg task delivery --arg url "https://github.com/o/r/pull/8" \
    --arg head "$HEAD_A" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/delivery/contributions.json"
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
    jq -n --arg head "$(cat "$FORGE/head")" \
          --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" \
          --arg pushed "$(cat "$FORGE/pushed_at" 2>/dev/null || printf '')" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       pushed_at:(if $pushed != "" then $pushed else null end),
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
  printf '%s\n' "$home"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

ack_pending() {
  local home=$1 token
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er 'first | .token') || fail 'no pending signal to acknowledge'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" || fail 'ack failed'
}

test_reraise_after_ack() {
  local home out token
  home=$(new_home reraise-after-ack)
  # Maintainer leaves a comment on the PR at 08:00:00Z.
  jq -n --arg head "$HEAD_A" '[{id:101,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please update the tests",html_url:"https://github.com/o/r/pull/8#issuecomment-101",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"}]' > "$home/forge/comments.json"
  # Initial poll at 08:01:00Z wakes once for incoming maintainer signal.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'first poll failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64}$' \
    || fail "initial comment wake missing: $out"
  ack_pending "$home"
  # 1 hour later (09:00:00Z): before default 4h interval, no wake.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll at 1h failed'
  [ -z "$out" ] || fail "woke before re-raise interval: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'pending signals present before interval'
  # 4h 5m later (12:05:00Z): past 4h interval, wakes with PR URL, author, and age!
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll at 4h failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64} unanswered https://github.com/o/r/pull/8 maintainer 4h$' \
    || fail "unanswered re-raise wake missing or malformed: $out"
  grep -Fq 'unanswered https://github.com/o/r/pull/8 maintainer 4h' "$home/state/.wake-queue" \
    || fail 'wake queue missing unanswered reason'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 1 and .[0].type == "unanswered" and .[0].source == "https://github.com/o/r/pull/8"
      and .[0].author == "maintainer" and .[0].age == "4h"' >/dev/null \
    || fail 'pending signal missing or wrong fields'
  # Acknowledge the re-raise: snoozes until next interval.
  ack_pending "$home"
  # 2 hours later (14:00:00Z): snoozed.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T14:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll during snooze failed'
  [ -z "$out" ] || fail "woke during snooze: $out"
  # 4h 5m after last raise (16:10:00Z, 8h total): wakes again with 8h age!
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T16:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll at next interval failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions delivery [0-9a-f]{64} unanswered https://github.com/o/r/pull/8 maintainer 8h$' \
    || fail "second re-raise wake missing or malformed: $out"
  pass 'unanswered contribution re-raises after acknowledgement at each interval'
}

test_clear_on_our_reply() {
  local home out
  home=$(new_home clear-reply)
  jq -n '[{id:101,user:{login:"maintainer"},author_association:"OWNER",
    body:"Needs changes",html_url:"https://github.com/o/r/pull/8#issuecomment-101",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"}]' > "$home/forge/comments.json"
  # Initial poll at 08:01:00Z wakes once for incoming maintainer comment.
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'initial poll failed'
  ack_pending "$home"
  # 4h 5m later (12:05:00Z), unanswered wake fires.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll before reply failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8 maintainer 4h$' \
    || fail "unanswered wake missing: $out"
  # Contribution author replies at 12:30:00Z.
  jq -n '[
    {id:101,user:{login:"maintainer"},author_association:"OWNER",body:"Needs changes",
      html_url:"https://github.com/o/r/pull/8#issuecomment-101",created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"},
    {id:102,user:{login:"author"},author_association:"NONE",body:"Updated the tests as requested",
      html_url:"https://github.com/o/r/pull/8#issuecomment-102",created_at:"2026-09-16T12:30:00Z",updated_at:"2026-09-16T12:30:00Z"}]' \
    > "$home/forge/comments.json"
  # Poll at 12:35:00Z clears unanswered condition and pending signal.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:35:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll after reply failed'
  [ -z "$out" ] || fail "woke after author replied: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'any(.type == "unanswered") | not' >/dev/null \
    || fail 'pending unanswered signal was not cleared on author reply'
  jq -e '.records[0].unanswered == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'record kept unanswered state after reply'
  # Poll 5 hours later (17:35:00Z): still no wake.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T17:35:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll hours after reply failed'
  [ -z "$out" ] || fail "woke later when author spoke last: $out"
  pass 'our reply clears the unanswered condition and withdraws its wake'
}

test_clear_on_no_action_verdict() {
  local home out
  home=$(new_home clear-verdict)
  jq -n '[{id:105,user:{login:"maintainer"},author_association:"OWNER",
    body:"Thanks for the patch!",html_url:"https://github.com/o/r/pull/8#issuecomment-105",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"}]' > "$home/forge/comments.json"
  # Initial poll at 08:01:00Z and ack.
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'initial poll failed'
  ack_pending "$home"
  # 4h 5m later (12:05:00Z), unanswered wake fires.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll before verdict failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8 maintainer 4h$' \
    || fail "unanswered wake missing before verdict: $out"
  # Record deliberate no-reply verdict (actor nobody, e.g. thanks-only).
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-105 nobody "thanks-only" || fail 'could not record verdict'
  # Poll immediately clears the condition.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll after verdict failed'
  [ -z "$out" ] || fail "woke after deliberate no-reply verdict: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'any(.type == "unanswered") | not' >/dev/null \
    || fail 'pending unanswered signal not cleared by deliberate no-reply verdict'
  jq -e '.records[0].unanswered == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'record kept unanswered state after no-reply verdict'
  # Later poll: still clear.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T18:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll hours after verdict failed'
  [ -z "$out" ] || fail "woke later after deliberate no-reply verdict: $out"
  pass 'a deliberate no-reply verdict clears the unanswered condition for that comment'
}

test_no_reraise_when_we_spoke_last() {
  local home out
  home=$(new_home spoke-last)
  # Maintainer spoke at 06:00:00Z, author spoke at 07:00:00Z.
  jq -n '[
    {id:101,user:{login:"maintainer"},author_association:"OWNER",body:"Question?",
      html_url:"https://github.com/o/r/pull/8#issuecomment-101",created_at:"2026-09-16T06:00:00Z",updated_at:"2026-09-16T06:00:00Z"},
    {id:102,user:{login:"author"},author_association:"NONE",body:"Answered!",
      html_url:"https://github.com/o/r/pull/8#issuecomment-102",created_at:"2026-09-16T07:00:00Z",updated_at:"2026-09-16T07:00:00Z"}]' \
    > "$home/forge/comments.json"
  # Initial poll at 07:05:00Z and ack.
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T07:05:00Z "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'initial poll failed'
  ack_pending "$home"
  # Poll 5 hours later (12:00:00Z): we spoke last, so condition never holds.
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed'
  [ -z "$out" ] || fail "woke when our account spoke last: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'any(.type == "unanswered") | not' >/dev/null \
    || fail 'pending unanswered signal present when we spoke last'
  jq -e '.records[0].unanswered == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'record stored unanswered state when we spoke last'
  pass 'no re-raise occurs when our account spoke last'
}

test_clear_on_our_push() {
  local home out
  home=$(new_home clear-push)
  jq -n '[{id:101,user:{login:"maintainer"},author_association:"OWNER",
    body:"Fix the typo",html_url:"https://github.com/o/r/pull/8#issuecomment-101",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"}]' > "$home/forge/comments.json"
  # Initial poll at 08:01:00Z and ack.
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'initial poll failed'
  ack_pending "$home"
  # Push a new commit at 09:00:00Z (after the 08:00:00Z comment).
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  printf '2026-09-16T09:00:00Z\n' > "$home/forge/pushed_at"
  # Poll at 13:00:00Z (5 hours after comment, 4 hours after push): push is newer, so clear!
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll after push failed'
  [ -z "$out" ] || fail "woke after author pushed: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'any(.type == "unanswered") | not' >/dev/null \
    || fail 'pending unanswered signal present after push'
  pass 'a push after the comment clears the unanswered condition'
}

test_reraise_interval_configurable() {
  local home out
  home=$(new_home interval-config)
  jq -n '[{id:101,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please check this",html_url:"https://github.com/o/r/pull/8#issuecomment-101",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z"}]' > "$home/forge/comments.json"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'first poll failed'
  ack_pending "$home"
  # With FM_CONTRIBUTIONS_RERAISE_INTERVAL=3600 (1 hour):
  # Poll at 09:05:00Z (1h 5m later): wakes with 1h!
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:05:00Z FM_CONTRIBUTIONS_RERAISE_INTERVAL=3600 \
    "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll with 1h interval failed'
  printf '%s\n' "$out" | grep -Eq 'unanswered https://github.com/o/r/pull/8 maintainer 1h$' \
    || fail "1h interval wake missing: $out"
  # Arm plumbs FM_CONTRIBUTIONS_RERAISE_INTERVAL into check shim
  with_home "$home" env FM_CONTRIBUTIONS_RERAISE_INTERVAL=7200 "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
    || fail 'arm failed'
  grep -Fq 'export FM_CONTRIBUTIONS_RERAISE_INTERVAL=7200' "$home/state/contributions.check.sh" \
    || fail 'arm did not plumb FM_CONTRIBUTIONS_RERAISE_INTERVAL into check shim'
  pass 'the re-raise interval is configurable via env and plumbs into the check shim'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  failures=0
  for test_name in test_reraise_after_ack test_clear_on_our_reply test_clear_on_no_action_verdict test_no_reraise_when_we_spoke_last test_clear_on_our_push test_reraise_interval_configurable; do
    ( "$test_name" ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || exit 1
fi
