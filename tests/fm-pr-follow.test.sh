#!/usr/bin/env bash
# Explicit PR follows through the public CLI and real outcome store, with local forge reads.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-follow)
home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$home/config" "$TMP_ROOT/tools"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
export FM_FOLLOW_FIXTURE="$TMP_ROOT/forge.json" FM_FOLLOW_READS="$TMP_ROOT/reads"
export PATH="$TMP_ROOT/tools:$PATH"
cat > "$TMP_ROOT/tools/gh" <<'SH'
#!/usr/bin/env bash
printf 'read\n' >> "$FM_FOLLOW_READS"
case "$*" in
  *'--json state --jq .state') jq -r .state "$FM_FOLLOW_FIXTURE" ;;
  *) cat "$FM_FOLLOW_FIXTURE" ;;
esac
SH
cp "$TMP_ROOT/tools/gh" "$TMP_ROOT/tools/glab"
chmod +x "$TMP_ROOT/tools/gh" "$TMP_ROOT/tools/glab"
follow() { bash "$ROOT/bin/fm-pr-follow.sh" "$@"; }
surface() {
  printf '%s\n' "$$" > "$home/state/.lock"
  rm -f "$home/state/.lock-session"
  if [ "$1" = claude-calm ]; then
    printf 'follow-test\n' > "$home/state/.lock-session"
    jq -n --arg owner "$$" --argjson now "$(date +%s)" \
      '{surface:"claude-calm",owner:$owner,session:"follow-test",epoch:$now}' > "$home/state/.pr-follow-surface"
  else
    jq -n --arg owner "$$" --argjson now "$(date +%s)" --arg surface "$1" \
      '{surface:$surface,owner:$owner,epoch:$now}' > "$home/state/.pr-follow-surface"
  fi
}
fixture() {
  jq -n --arg state "$1" --arg head "${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    --arg conclusion "${3:-SUCCESS}" --arg review "${4:-APPROVED}" \
    '{state:$state,headRefOid:$head,reviewDecision:$review,statusCheckRollup:[{name:"test",status:"COMPLETED",conclusion:$conclusion,startedAt:"2026-11-19T00:00:00Z"}]}' > "$FM_FOLLOW_FIXTURE"
}
url=https://github.com/example/project/pull/1
fixture OPEN
surface pi
if follow add "$url" --requested 'Tell me when this changes' > "$TMP_ROOT/out" 2>&1; then fail 'default-off enrollment succeeded'; fi
[ ! -e "$FM_FOLLOW_READS" ] || fail 'default-off enrollment read the forge'
touch "$home/config/pr-follow"
follow add "$url" --requested 'Tell me when this changes' > "$TMP_ROOT/out"
[ -f "$home/data/pr-follows.json" ] || fail 'follow is not durable'
[ ! -e "$home/state/named-pr.meta" ] || fail 'following fabricated a task'
[ ! -s "$home/state/branch-outcomes.jsonl" ] || fail 'baseline notified'

fixture MERGED
follow poll
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 1 ] || fail 'merge was not reported once'
jq -e --arg url "$url" '.verdict == "notice" and (.summary | contains("MERGED") and contains($url))' "$home/state/branch-outcomes.jsonl" >/dev/null || fail 'merge outcome missing'
[ ! -s "$home/state/.wake-queue" ] || fail 'taskless merge woke the model'
FM_HOME="$home" bash "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1
[ -z "$(bash "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] || fail 'notice asks for a processing turn'
[ -n "$(bash "$ROOT/bin/fm-branch-outcome.sh" notices)" ] || fail 'model cursor consumed an unseen direct notice'
bash "$ROOT/bin/fm-branch-outcome.sh" mark-notices --through 1
[ -z "$(bash "$ROOT/bin/fm-branch-outcome.sh" notices)" ] || fail 'displayed notice remains pending'
seq=$(bash "$ROOT/bin/fm-branch-outcome.sh" append --task fleet --verdict notice \
  --wake "$(jq -r .wake "$home/state/branch-outcomes.jsonl")" --summary "MERGED: $url")
[ "$seq" = 1 ] || fail 'retry after interrupted baseline save duplicated the notice'
pass 'taskless merge reaches the outcome store once without a processing request'

follow remove "$url"
fixture OPEN
follow add "$url" --requested 'Follow closure' >/dev/null
fixture CLOSED
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 2 ] || fail 'closed outcome missing'
jq -s -e '.[1].summary | contains("CLOSED")' "$home/state/branch-outcomes.jsonl" >/dev/null
pass 'closed without merging is an outcome'

follow remove "$url"
fixture OPEN
follow add "$url" --requested 'Follow checks and review' >/dev/null
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FAILURE
follow poll
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 3 ] || fail 'new-head failure not reported once'
jq -s -e '.[2].summary | contains("FAILURE") and contains("bbbbbbb")' "$home/state/branch-outcomes.jsonl" >/dev/null
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SUCCESS
jq '.statusCheckRollup += [{name:"test",status:"COMPLETED",conclusion:"FAILURE",startedAt:"2026-11-18T00:00:00Z"}]' "$FM_FOLLOW_FIXTURE" > "$TMP_ROOT/next"
mv "$TMP_ROOT/next" "$FM_FOLLOW_FIXTURE"
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 3 ] || fail 'old failed run overrode a passing rerun'
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FAILURE
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 4 ] || fail 'green-to-red recurrence lost'
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FAILURE CHANGES_REQUESTED
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 5 ] || fail 'requested changes not reported'
pass 'checks and review transitions preserve forge words and suppress unchanged reads'

jq '.statusCheckRollup += [{name:"lint",status:"COMPLETED",conclusion:"FAILURE",startedAt:"2026-11-19T00:00:00Z"}]' "$FM_FOLLOW_FIXTURE" > "$TMP_ROOT/next"
mv "$TMP_ROOT/next" "$FM_FOLLOW_FIXTURE"
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 6 ] || fail 'a second check that newly fails on the same commit was not reported'
jq -s -e '.[5].summary | contains("lint: FAILURE")' "$home/state/branch-outcomes.jsonl" >/dev/null || fail 'newly failing check is not named'
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FAILURE CHANGES_REQUESTED
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 6 ] || fail 'a partial check recovery repeated the still-failing check'
jq -e '.follows[0].observation.checks | map(.name) == ["test"]' "$home/data/pr-follows.json" >/dev/null || fail 'partial recovery did not advance the baseline'
fixture OPEN dddddddddddddddddddddddddddddddddddddddd SUCCESS CHANGES_REQUESTED
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 6 ] || fail 'a push repeated an unchanged requested-changes review'
fixture OPEN dddddddddddddddddddddddddddddddddddddddd SUCCESS APPROVED
follow poll
fixture OPEN dddddddddddddddddddddddddddddddddddddddd SUCCESS CHANGES_REQUESTED
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = 7 ] || fail 'a new requested-changes review after approval was lost'
pass 'only a newly failing check name or a changed review value adds a line'

before=$(cksum < "$home/data/pr-follows.json")
printf 'not json\n' > "$FM_FOLLOW_FIXTURE"
follow poll
[ "$before" = "$(cksum < "$home/data/pr-follows.json")" ] || fail 'failed read advanced baseline'
reads=$(wc -l < "$FM_FOLLOW_READS")
rm "$home/config/pr-follow"
follow poll
[ "$reads" = "$(wc -l < "$FM_FOLLOW_READS")" ] || fail 'disabled poll read forge'
touch "$home/config/pr-follow"
surface codex
if follow add https://github.com/example/project/pull/2 --requested 'Follow this' > "$TMP_ROOT/out" 2>&1; then fail 'unsupported surface enrolled'; fi
assert_contains "$(< "$TMP_ROOT/out")" 'model-free outcome surface' 'missing clear surface refusal'
pass 'bad reads preserve evidence and disabled or unsupported homes do not enroll'

refused() {
  if follow add https://github.com/example/project/pull/2 --requested 'Follow this' > "$TMP_ROOT/out" 2>&1; then fail "$1 enrolled"; fi
  assert_contains "$(< "$TMP_ROOT/out")" 'model-free outcome surface' "$1 refusal is unclear"
}
surface pi
printf '1\n' > "$home/state/.lock"
refused 'a Pi heartbeat from another lock owner'
surface claude-calm
printf 'other-session\n' > "$home/state/.lock-session"
refused 'a Claude heartbeat from another session'
rm "$home/state/.lock-session"
refused 'a Claude heartbeat without the session sidecar'
pass 'a heartbeat from another owner or Claude session does not enroll'

surface claude-calm
fixture OPEN
follow remove "$url"
follow add "$url" --requested 'Follow my task PR' >/dev/null
printf 'kind=ship\npr=%s\n' "$url" > "$home/state/ship.meta"
fixture OPEN cccccccccccccccccccccccccccccccccccccccc FAILURE
[ -z "$(follow poll)" ] || fail 'task-owned failure also returned a duplicate check wake'
assert_contains "$(< "$home/state/.wake-queue")" "$url" 'task action is not durably queued'
pass 'task-owned failure still wakes supervision for action'
fixture MERGED
[ -z "$(follow poll)" ] || fail 'direct follow duplicated the task merge wake'
[ "$(bash "$ROOT/bin/fm-pr-poll.sh" --validated github "$url" github.com example/project 1)" = merged ] || fail 'task merge observer changed'
[ -f "$home/state/ship.meta" ] || fail 'direct follow removed task custody'

mr=https://gitlab.example/group/project/-/merge_requests/2
jq -n '{state:"opened",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",detailed_merge_status:"mergeable",head_pipeline:{status:"success",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$FM_FOLLOW_FIXTURE"
follow remove "$url"
follow add "$mr" --requested 'Follow this merge request' >/dev/null
count=$(jq -s length "$home/state/branch-outcomes.jsonl")
jq '.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .head_pipeline.status="failed"' "$FM_FOLLOW_FIXTURE" > "$TMP_ROOT/next"
mv "$TMP_ROOT/next" "$FM_FOLLOW_FIXTURE"
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$count" ] || fail 'old GitLab pipeline attributed to a new head'
jq '.head_pipeline.sha=.sha' "$FM_FOLLOW_FIXTURE" > "$TMP_ROOT/next"
mv "$TMP_ROOT/next" "$FM_FOLLOW_FIXTURE"
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$((count + 1))" ] || fail 'current GitLab failure missing'
jq '.state="merged"' "$FM_FOLLOW_FIXTURE" > "$TMP_ROOT/next"
mv "$TMP_ROOT/next" "$FM_FOLLOW_FIXTURE"
follow poll
jq -s -e --arg url "$mr" '.[-1].summary | contains("merged") and contains($url)' "$home/state/branch-outcomes.jsonl" >/dev/null
pass 'GitLab follows use the shared observer and outcome store'

follow remove "$mr"
url=https://github.com/example/project/pull/3
fixture OPEN
follow add "$url" --requested 'Follow through interruptions' >/dev/null
export FM_FOLLOW_CRASH="$TMP_ROOT/crash-next-save" FM_FOLLOW_CRASH_URL="$url"
export FM_FOLLOW_REAL_MV
FM_FOLLOW_REAL_MV=$(command -v mv)
cat > "$TMP_ROOT/tools/mv" <<'SH'
#!/usr/bin/env bash
args=("$@")
if [ "$#" -ge 2 ] && [ -e "$FM_FOLLOW_CRASH" ]; then
  destination=${args[${#args[@]}-1]}
  source=${args[${#args[@]}-2]}
  if [ "$destination" = "$FM_DATA_OVERRIDE/pr-follows.json" ] &&
    jq -e --arg url "$FM_FOLLOW_CRASH_URL" 'any(.follows[]; .url == $url and .revision > 0)' "$source" >/dev/null; then
    rm -f "$FM_FOLLOW_CRASH"
    kill -TERM "$PPID"
    exit 1
  fi
fi
exec "$FM_FOLLOW_REAL_MV" "$@"
SH
chmod +x "$TMP_ROOT/tools/mv"
touch "$FM_FOLLOW_CRASH"
fixture OPEN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FAILURE
count=$(jq -s length "$home/state/branch-outcomes.jsonl")
if follow poll > "$TMP_ROOT/interrupted.out" 2>&1; then fail 'observer did not stop before baseline replacement'; fi
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$((count + 1))" ] || fail 'interruption did not follow the actual outcome append'
jq -e --arg url "$url" '.follows[] | select(.url == $url) | .revision == 0 and .observation.head == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$home/data/pr-follows.json" >/dev/null || fail 'interrupted observer changed its baseline'
fixture OPEN cccccccccccccccccccccccccccccccccccccccc FAILURE
follow poll
follow poll
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$((count + 2))" ] || fail 'recovery lost or duplicated the later observation'
jq -s -e '.[-1].summary | contains("ccccccc")' "$home/state/branch-outcomes.jsonl" >/dev/null || fail 'recovery did not report the new commit'
pass 'interruption after append cannot make a later observation reuse a different event key'

second=https://github.com/example/project/pull/4
fixture OPEN
follow add "$second" --requested 'Follow the slow forge too' >/dev/null
fixture MERGED
count=$(jq -s length "$home/state/branch-outcomes.jsonl")
[ -z "$(FM_CHECK_TIMEOUT=10 follow poll)" ] || fail 'a pass that ran out of time printed a model wake'
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$((count + 1))" ] || fail 'a pass with no time to spare did not read exactly one follow'
[ -z "$(FM_CHECK_TIMEOUT=soon follow poll 2>&1)" ] || fail 'a non-numeric check timeout broke the resumed pass'
[ "$(jq -s length "$home/state/branch-outcomes.jsonl")" = "$((count + 2))" ] || fail 'the next pass did not resume at the follow it skipped'
jq -s -e --arg a "$url" --arg b "$second" '[.[-2:][].summary] | any(contains($a)) and any(contains($b))' "$home/state/branch-outcomes.jsonl" >/dev/null || fail 'the two passes did not cover both follows'
pass 'a pass out of time stops quietly after one follow and the next pass resumes'

if follow add "$url" > "$TMP_ROOT/out" 2>&1; then fail 'enrollment without request accepted'; fi
if follow add 'https://github.com/example/project/pull/1;touch-bad' --requested 'Follow this' > "$TMP_ROOT/out" 2>&1; then fail 'unsafe URL accepted'; fi
cp "$home/data/pr-follows.json" "$TMP_ROOT/safe.json"
rm "$home/data/pr-follows.json"
ln -s "$TMP_ROOT/safe.json" "$home/data/pr-follows.json"
if follow add "$url" --requested 'Follow this' > "$TMP_ROOT/out" 2>&1; then fail 'symlinked follow store accepted'; fi
pass 'enrollment requires explicit request, canonical URL, and a safe durable record'
