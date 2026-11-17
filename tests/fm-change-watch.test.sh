#!/usr/bin/env bash
# Tests for bin/fm-change-watch.sh, the post-merge change watch.
#
# The watch exists to catch a merge that is bad BY EFFECT rather than by
# content, so the cases here pin exactly that: a merged PR whose hunk lands in
# one Deployment of a multi-Deployment manifest registers that one target under
# the manifest's own namespace; a 5xx series that crosses its bar at +15m
# reports the first regression as a wake and a steer; an OOMKilled event reports
# on the sample that sees it; a clean series runs the whole 12h schedule and
# records the clean note and one durable row with all three readings; a schedule
# that never read a target ends unmeasurable-with-reason, queues a check wake,
# and blocks the done claim instead of completing quietly; a row missing a
# reading is never proven; the audit fails on an unmeasurable row and on a
# completed-unmeasured status line; an interrupted drive is never clean and can
# be re-armed; a re-registered completed watch re-measures from scratch and a
# deleted verdict cannot hide its durable row; the pool metric is scoped to the
# Deployment's own pool; the pool
# console is read as ubuntu through the admin unix socket with stdin closed and
# a hard bound, and the doctor states every failed pool read; a reused pid never
# reads as a live drive; and a docs-only PR registers nothing at all.
#
# The beta stage has its own cases: a web-credits-next route change is read on
# its beta target before any production target (asserted from the FM_CW_TRACE
# read record, so reversing the stage fails the case), a change touching no
# beta-served path completes clean with the reason stated, a beta regression is
# reported as beta and arms no production watch, an unlanded rollout and an
# unreadable fingerprint are unmeasured rather than passed, and the wait config
# is bounded. The beta map is also exercised as a tab-separated line, as two
# keys resolving to one target, and as two keys resolving to two targets.
#
# Every cluster and forge read is stubbed through the script's own seams
# (FM_CW_FORGE_DIR, FM_CW_CLUSTER_DIR, FM_CW_ARM_CMD, FM_CW_SEND_CMD) or a
# kubectl/ssh PATH shim, so no case reaches a cluster, the network, or the wiki.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CW="$ROOT/bin/fm-change-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-change-watch)
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MANIFEST='k8s/prod/core-services/deployments.yaml'

# --- helpers -----------------------------------------------------------------

# new_world <name> prints a fresh isolated home.
new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/forge/content" "$home/cluster"
  cat > "$home/arm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_ARM_LOG"
STUB
  cat > "$home/send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SEND_LOG"
STUB
  chmod +x "$home/arm.sh" "$home/send.sh"
  printf '%s\n' "$home"
}

# run_cw <home> <now> <args...> runs the watch with every seam pointed at <home>.
# CW_SLEEP overrides the drive's sleep command; CW_CLUSTER_DIR the series dir.
run_cw() {
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="${CW_CLUSTER_DIR-$home/cluster}" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_TRACE="$home/trace" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD="${CW_SLEEP:-true}" \
    "$CW" "$@"
}

# seed_pr <home> <manifest-path> <manifest-body-file> <files...> seeds the merged
# PR's file list, merge epoch, head ref, and the manifest content at that ref.
seed_pr() {
  local home=$1 manifest=$2 body=$3
  shift 3
  : > "$home/forge/files.txt"
  local f
  for f in "$@"; do printf '%s\n' "$f" >> "$home/forge/files.txt"; done
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/head-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}

# seed_diff <home> <path> <new-line...> writes one-line changes, one hunk each.
seed_diff() {
  local home=$1 path=$2 line
  shift 2
  {
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$path" "$path" "$path" "$path"
    for line in "$@"; do
      printf '@@ -%s,1 +%s,1 @@\n-          value: old\n+          value: new\n' "$line" "$line"
    done
  } > "$home/forge/diff.txt"
}

# seed_series <home> <metric> <target> <window> <lines...>
seed_series() {
  local home=$1 metric=$2 target=$3 window=$4
  shift 4
  : > "$home/cluster/$metric.$target.$window"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/cluster/$metric.$target.$window"; done
}

# The real tree's shape: one manifest per component declaring several
# Deployments, each under its own metadata.namespace, plus a Service.
MULTI_MANIFEST='apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-backend-api
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: core-backend-api
          env:
            - name: ENV
              value: production
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: feed-service
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: feed-service
          env:
            - name: DB_HOST
              value: db-pool
---
apiVersion: v1
kind: Service
metadata:
  name: feed
  namespace: muso-prod
spec:
  selector:
    app: feed-service
'
printf '%s' "$MULTI_MANIFEST" > "$TMP_ROOT/multi.yaml"
FEED_LINE=26     # inside the feed-service Deployment document
API_LINE=13      # inside the core-backend-api Deployment document
SERVICE_LINE=36  # inside the Service document

# --- (a) a hunk in one Deployment registers exactly that target -----------------

HOME_A=$(new_world a)
seed_pr "$HOME_A" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST" README.md
seed_diff "$HOME_A" "$MANIFEST" "$FEED_LINE"

out=$(run_cw "$HOME_A" 1790000000 register w1 "$PR_URL") || fail "register failed"
case "$out" in
  *"registered w1-3317"*"(1 target(s))"*) pass "register reports one derived target" ;;
  *) fail "unexpected register output: $out" ;;
esac

WATCH_A="$HOME_A/state/change-watch/w1-3317"
[ -f "$WATCH_A/targets" ] || fail "register did not write targets"
[ "$(cat "$WATCH_A/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "derived target is wrong: $(cat "$WATCH_A/targets")"
pass "the target is the Deployment the hunk landed in, under the manifest's namespace"

[ "$(grep -c '' "$WATCH_A/schedule")" -eq 15 ] || fail "schedule is not the bounded 15-sample set"
[ "$(head -1 "$WATCH_A/schedule" | cut -f1)" -eq 300 ] || fail "first sample is not +5m"
[ "$(tail -1 "$WATCH_A/schedule" | cut -f1)" -eq 43200 ] || fail "last sample is not +12h"
grep -q "^http_5xx_per_min@muso-prod/feed-service" "$WATCH_A/baseline" \
  || fail "baseline is missing the 5xx metric"
grep -q "^pgbouncer_cl_waiting@muso-prod/feed-service" "$WATCH_A/baseline" \
  || fail "baseline is missing the per-target pool metric"

grep -q -- "--condition $CW due w1-3317" "$HOME_A/arm.log" \
  || fail "arming did not bind the due condition"
grep -q -- "--action $CW drive w1-3317" "$HOME_A/arm.log" \
  || fail "arming did not bind the drive action"

# Registering the same merge twice is idempotent and re-arms nothing.
before=$(grep -c '' "$HOME_A/arm.log")
out=$(run_cw "$HOME_A" 1790000060 register w1 "$PR_URL") || fail "repeat register failed"
case "$out" in
  *"already registered"*) pass "repeat register is idempotent" ;;
  *) fail "repeat register did not report idempotence: $out" ;;
esac
[ "$(grep -c '' "$HOME_A/arm.log")" -eq "$before" ] || fail "repeat register armed a second watch"

# The condition is false before the first sample and true at it.
run_cw "$HOME_A" 1790000000 due w1-3317 && fail "due fired before the first sample"
run_cw "$HOME_A" 1790000300 due w1-3317 || fail "due did not fire at +5m"
pass "due gates the first sample"

# A hunk in the other Deployment picks that one; a hunk only in the Service picks nothing.
HOME_A2=$(new_world a2)
seed_pr "$HOME_A2" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A2" "$MANIFEST" "$API_LINE"
run_cw "$HOME_A2" 1790000000 register w2 "$PR_URL" >/dev/null || fail "register failed"
[ "$(cat "$HOME_A2/state/change-watch/w2-3317/targets")" = "$(printf 'muso-prod\tcore-backend-api')" ] \
  || fail "a hunk in core-backend-api did not target it alone"
HOME_A3=$(new_world a3)
seed_pr "$HOME_A3" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A3" "$MANIFEST" "$SERVICE_LINE"
out=$(run_cw "$HOME_A3" 1790000000 register w3 "$PR_URL") || fail "register failed"
case "$out" in
  *"no deployable service touched"*) pass "a hunk only in a Service document targets no Deployment" ;;
  *) fail "a Service-only hunk registered a watch: $out" ;;
esac

# Without a diff the whole manifest is watched and the registration says so.
HOME_A4=$(new_world a4)
seed_pr "$HOME_A4" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
out=$(run_cw "$HOME_A4" 1790000000 register w4 "$PR_URL") || fail "register failed"
case "$out" in
  *"(2 target(s); whole manifest: $MANIFEST)"*) pass "an unplaceable hunk falls back to the whole manifest and says so" ;;
  *) fail "whole-manifest fallback is not reported: $out" ;;
esac
[ "$(cat "$HOME_A4/state/change-watch/w4-3317/targets")" = "$(printf 'muso-prod\tcore-backend-api\nmuso-prod\tfeed-service')" ] \
  || fail "whole-manifest fallback targets are wrong"

# A PR changing several lines of one Deployment (the motivating merge's shape)
# still targets exactly that Deployment.
HOME_A5=$(new_world a5)
seed_pr "$HOME_A5" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A5" "$MANIFEST" $((FEED_LINE - 2)) "$FEED_LINE"
out=$(run_cw "$HOME_A5" 1790000000 register w5 "$PR_URL") || fail "register failed"
case "$out" in
  *"registered w5-3317"*"(1 target(s))"*) ;;
  *) fail "a two-hunk diff did not register one target: $out" ;;
esac
[ "$(cat "$HOME_A5/state/change-watch/w5-3317/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "two hunks in feed-service did not target it alone"
pass "several hunks in one Deployment target that Deployment once"

# A Deployment that declares no namespace is a measurement gap, never guessed
# and never recorded as a merge with nothing deployable.
HOME_A6=$(new_world a6)
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: argocd-server\nspec: {}\n' > "$TMP_ROOT/nons.yaml"
seed_pr "$HOME_A6" k8s/prod/argocd/install.yaml "$TMP_ROOT/nons.yaml" k8s/prod/argocd/install.yaml
seed_diff "$HOME_A6" k8s/prod/argocd/install.yaml 4
out=$(run_cw "$HOME_A6" 1790000000 register w6 "$PR_URL") || fail "register failed"
case "$out" in
  *"could not be watched"*"(no namespace: argocd-server in k8s/prod/argocd/install.yaml)"*) ;;
  *) fail "a Deployment without metadata.namespace was not recorded as a gap: $out" ;;
esac
[ -e "$HOME_A6/state/change-watch/w6-3317" ] && fail "a Deployment without a namespace was watched under a guess"
grep -q '"terminal_state": "unmeasurable-with-reason"' "$HOME_A6/state/change-watch/rows/w6-3317.json" \
  || fail "a Deployment without a namespace was recorded as not-applicable"
run_cw "$HOME_A6" 1790000100 audit 7 >/dev/null \
  && fail "the audit passed a Deployment that could not be watched"
pass "a Deployment without metadata.namespace is a stated gap, never guessed"

# A manifest that cannot be read is reported as unread, not as no service.
HOME_A7=$(new_world a7)
seed_pr "$HOME_A7" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A7" "$MANIFEST" "$FEED_LINE"
rm -f "$HOME_A7/forge/head-ref"
out=$(run_cw "$HOME_A7" 1790000000 register w7 "$PR_URL") || fail "register failed"
case "$out" in
  *"could not read 1 manifest(s) for $PR_URL; nothing registered"*) ;;
  *) fail "an unreadable manifest was not reported as unread: $out" ;;
esac
[ -e "$HOME_A7/state/change-watch/w7-3317" ] && fail "an unreadable manifest created a watch record"
grep -q '"terminal_state": "unmeasurable-with-reason"' "$HOME_A7/state/change-watch/rows/w7-3317.json" \
  || fail "an unreadable manifest was recorded as a merge with nothing to measure"
grep -qF "check: change-watch w7 $PR_URL unmeasurable (" "$HOME_A7/state/.wake-queue" \
  || fail "an unreadable manifest did not queue the unmeasurable wake"
run_cw "$HOME_A7" 1790000100 gate w7 >/dev/null \
  && fail "the done-claim gate passed a merge whose manifest could not be read"
run_cw "$HOME_A7" 1790000100 gate w7 --terminal-gap >/dev/null \
  && fail "the teardown gate passed a row-only measurement gap"
run_cw "$HOME_A7" 1790000100 audit 7 >/dev/null \
  && fail "the audit passed a merge whose manifest could not be read"
pass "an unreadable manifest is a stated measurement gap, not a PR without a service"

# A manifest the PR deletes is a decommission, not a forge read failure.
HOME_A8=$(new_world a8)
printf '%s\n' "$MANIFEST" > "$HOME_A8/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_A8/forge/merge-epoch"
printf '%s\n' deadbeefcafe > "$HOME_A8/forge/head-ref"
printf 'diff --git a/%s b/%s\ndeleted file mode 100644\n--- a/%s\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-apiVersion: apps/v1\n-kind: Deployment\n-metadata:\n' \
  "$MANIFEST" "$MANIFEST" "$MANIFEST" > "$HOME_A8/forge/diff.txt"
out=$(run_cw "$HOME_A8" 1790000000 register w8 "$PR_URL") || fail "register failed"
case "$out" in
  *"no deployable service touched by $PR_URL (manifest removed: $MANIFEST); nothing registered"*) ;;
  *) fail "a deleted manifest was not reported as removed: $out" ;;
esac
[ -e "$HOME_A8/state/change-watch/w8-3317" ] && fail "a deleted manifest created a watch record"
pass "a deleted manifest registers nothing and is named as removed, not unread"

# --- (b) a regressing 5xx series fires at +15m --------------------------------

HOME_B=$(new_world b)
seed_pr "$HOME_B" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_B" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_B" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_B" http_5xx_per_min muso-prod_feed-service sample 0.2 5
run_cw "$HOME_B" 1790000000 register b1 "$PR_URL" >/dev/null || fail "register failed"

run_cw "$HOME_B" 1790000300 sample b1-3317 >/dev/null || fail "sample at +5m failed"
run_cw "$HOME_B" 1790000300 verdict b1-3317 | grep -q "clean so far" \
  || fail "+5m sample should be clean"
run_cw "$HOME_B" 1790000900 sample b1-3317 >/dev/null || fail "sample at +15m failed"
line=$(run_cw "$HOME_B" 1790000900 verdict b1-3317)
[ "$line" = "change-watch regressed at +15m on http_5xx_per_min (5 vs baseline 0)" ] \
  || fail "verdict line is wrong: $line"
pass "5xx series reports the first regression at +15m"

grep -qF "check: change-watch b1 $PR_URL http_5xx_per_min regressed" "$HOME_B/state/.wake-queue" \
  || fail "the regression did not queue the check wake"
grep -q "regressed at +15m on http_5xx_per_min" "$HOME_B/send.log" \
  || fail "the regression did not steer the owning lane"
grep -q "measured 5" "$HOME_B/send.log" || fail "the steer does not carry the numbers"
pass "regression queues one wake and steers the lane with the numbers"

# A further sample must not re-report.
run_cw "$HOME_B" 1790001800 sample b1-3317 >/dev/null || true
[ "$(grep -cF "check: change-watch b1 $PR_URL" "$HOME_B/state/.wake-queue")" -eq 1 ] \
  || fail "the regression was reported more than once"
pass "the regression is reported exactly once"

# A relative bar with no baseline reading is recorded but never scored.
HOME_M=$(new_world m)
seed_pr "$HOME_M" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_M" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_M" restarts muso-prod_feed-service baseline ''
seed_series "$HOME_M" restarts muso-prod_feed-service sample 2
run_cw "$HOME_M" 1790000000 register m1 "$PR_URL" >/dev/null || fail "register failed"
run_cw "$HOME_M" 1790000300 sample m1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_M" 1790000300 verdict m1-3317 | grep -q "clean so far" \
  || fail "a restarts reading with no baseline was scored against zero"
awk -F'\t' '$3 == "restarts@muso-prod/feed-service" && $4 == "2" && $7 == "0" { ok = 1 } END { exit(ok ? 0 : 1) }' \
  "$HOME_M/state/change-watch/m1-3317/samples.log" \
  || fail "the unscored reading was not recorded with scored=0"
pass "a metric with a relative bar and no baseline is recorded but not scored"

# --- (c) an OOMKilled event regresses ------------------------------------------

HOME_C=$(new_world c)
seed_pr "$HOME_C" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_C" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_C" oomkilled muso-prod_feed-service baseline 0
seed_series "$HOME_C" oomkilled muso-prod_feed-service sample 0 1
run_cw "$HOME_C" 1790000000 register c1 "$PR_URL" >/dev/null || fail "register failed"

run_cw "$HOME_C" 1790000900 drive c1-3317 >/dev/null || fail "drive failed"
line=$(run_cw "$HOME_C" 1790000900 verdict c1-3317)
[ "$line" = "change-watch regressed at +15m on oomkilled (1 vs baseline 0)" ] \
  || fail "OOMKilled verdict is wrong: $line"
grep -qF "check: change-watch c1 $PR_URL oomkilled regressed" "$HOME_C/state/.wake-queue" \
  || fail "OOMKilled did not queue the check wake"
pass "an OOMKilled event regresses the watch"

# --- (d) a clean 12h series records the clean note -----------------------------

HOME_D=$(new_world d)
seed_pr "$HOME_D" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_D" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_D" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_D" http_5xx_per_min muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_D" restarts muso-prod_feed-service baseline 2
seed_series "$HOME_D" restarts muso-prod_feed-service sample \
  2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_D" 1790000000 register d1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_D/state/d1.meta"

run_cw "$HOME_D" 1790044000 drive d1-3317 >/dev/null || fail "clean drive failed"
[ "$(run_cw "$HOME_D" 1790044000 verdict d1-3317)" = "change-watch clean" ] \
  || fail "clean drive did not end clean"
grep -qF "note: change-watch clean for $PR_URL" "$HOME_D/state/d1.status" \
  || fail "the clean note was not appended to the task status log"
[ -e "$HOME_D/state/.wake-queue" ] && [ -s "$HOME_D/state/.wake-queue" ] \
  && fail "a clean watch must not queue a wake"
pass "a clean 12h series records the clean note and queues nothing"

# --- (e) a merge writes exactly one row with all three readings ----------------

ROW_D="$HOME_D/state/change-watch/rows/d1-3317.json"
[ -f "$ROW_D" ] || fail "a merge wrote no durable row"
[ "$(find "$HOME_D/state/change-watch/rows" -type f | wc -l | tr -d ' ')" = 1 ] \
  || fail "a merge wrote more than one durable row"
grep -q '"terminal_state": "proven"' "$ROW_D" || fail "a clean watch did not record terminal_state proven"
for offset in 900 3600 21600; do
  grep -q "\"$offset\": {\"at\":" "$ROW_D" \
    || fail "the row has no +$((offset / 60))m reading"
done
grep -q '"real_user_check": "observed"' "$ROW_D" \
  || fail "the row did not record the real-user check as observed"
grep -q '"completed_epoch": [0-9]' "$ROW_D" || fail "the row has no completion epoch"
run_cw "$HOME_D" 1790044000 gate d1 >/dev/null \
  || fail "the done-claim gate failed a proven watch"
run_cw "$HOME_D" 1790044000 gate no-such-task >/dev/null \
  || fail "the done-claim gate failed a task with no watch"
pass "a merge writes exactly one row with the +15m/+1h/+6h readings and a terminal state"

# --- (f) an unmeasurable watch wakes and blocks the done claim ----------------

# A schedule in which the target was never read is a FAILURE, not a quiet
# completion: it queues a check wake, blocks the done claim, and writes no
# status note at all.
HOME_U=$(new_world u)
seed_pr "$HOME_U" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_U" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_U" 1790000000 register u1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_U/state/u1.meta"
run_cw "$HOME_U" 1790044000 drive u1-3317 >/dev/null || fail "unmeasured drive failed"
line=$(run_cw "$HOME_U" 1790044000 verdict u1-3317)
case "$line" in
  "change-watch unmeasurable-with-reason: "*) ;;
  *) fail "an entirely unmeasured watch read as: $line" ;;
esac
run_cw "$HOME_U" 1790044000 verdict u1-3317 >/dev/null \
  && fail "an unmeasurable verdict exited 0, so it does not block the done claim"
run_cw "$HOME_U" 1790044000 gate u1 >/dev/null \
  && fail "the done-claim gate passed an unmeasurable watch"
grep -qF "check: change-watch u1 $PR_URL unmeasurable (" "$HOME_U/state/.wake-queue" \
  || fail "an unmeasurable watch did not queue a check wake"
[ -e "$HOME_U/state/u1.status" ] && grep -q 'change-watch' "$HOME_U/state/u1.status" \
  && fail "an unmeasurable watch still wrote a status note"
grep -q '"terminal_state": "unmeasurable-with-reason"' \
  "$HOME_U/state/change-watch/rows/u1-3317.json" \
  || fail "an unmeasurable watch did not record its terminal state"
pass "an unmeasurable watch queues a check wake and blocks the done claim"

# The teardown refusal tells the operator to re-register once the read path is
# fixed. That recovery must actually re-measure a completed schedule instead of
# recomputing the same gap.
run_cw "$HOME_U" 1790045000 register u1 "$PR_URL" >/dev/null \
  || fail "re-registering an unmeasurable watch failed"
grep -q '"terminal_state": "open"' "$HOME_U/state/change-watch/rows/u1-3317.json" \
  || fail "re-registering an unmeasurable watch did not reopen its durable row"
[ -e "$HOME_U/state/change-watch/u1-3317/verdict" ] \
  && fail "re-registering an unmeasurable watch kept its terminal verdict"
[ -e "$HOME_U/state/change-watch/u1-3317/sampled" ] \
  && fail "re-registering a completed watch kept its old samples"
run_cw "$HOME_U" 1790045000 gate u1 --terminal-gap >/dev/null \
  || fail "a re-registered watch still blocked teardown"
pass "re-registering an unmeasurable watch reopens it and re-measures"

# --- re-registering a completed watch re-measures from scratch ----------------

# A completed watch that ended unmeasurable must not carry its old samples into
# the re-measurement: otherwise a re-registered watch could be proven by
# evidence taken before the re-registration.
HOME_W=$(new_world w)
seed_pr "$HOME_W" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_W" "$MANIFEST" "$FEED_LINE" "$API_LINE"
seed_series "$HOME_W" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_W" http_5xx_per_min muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_W" restarts muso-prod_feed-service baseline 2
seed_series "$HOME_W" restarts muso-prod_feed-service sample \
  2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_W" 1790000000 register w1 "$PR_URL" >/dev/null || fail "register failed"
run_cw "$HOME_W" 1790044000 drive w1-3317 >/dev/null || fail "drive failed"
grep -q '"terminal_state": "unmeasurable-with-reason"' \
  "$HOME_W/state/change-watch/rows/w1-3317.json" \
  || fail "a watch with one target never measured did not end unmeasurable"
run_cw "$HOME_W" 1790045000 register w1 "$PR_URL" >/dev/null \
  || fail "re-registering a completed unmeasurable watch failed"
[ -s "$HOME_W/state/change-watch/w1-3317/samples.log" ] \
  && fail "re-registering a completed watch kept its old samples"
[ -n "$(find "$HOME_W/state/change-watch/w1-3317" -name 'last.*' -print -quit)" ] \
  && fail "re-registering a completed watch kept its old previous values"
rm -f "$HOME_W"/cluster/*
run_cw "$HOME_W" 1790088200 drive w1-3317 >/dev/null || fail "re-measuring drive failed"
grep -q '"terminal_state": "unmeasurable-with-reason"' \
  "$HOME_W/state/change-watch/rows/w1-3317.json" \
  || fail "a re-registered watch was proven by samples taken before the re-registration"
pass "re-registering a completed watch re-measures from scratch"

# --- the durable row is the authority for recovery ----------------------------

# Deleting the verdict must not make an unmeasurable watch look already
# registered: the row still records the gap, so re-registering must reopen it
# and a later clean drive must reach proven.
HOME_X=$(new_world x)
seed_pr "$HOME_X" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_X" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_X" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_X" http_5xx_per_min muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_X" restarts muso-prod_feed-service baseline 2
seed_series "$HOME_X" restarts muso-prod_feed-service sample \
  2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_X" 1790000000 register v1 "$PR_URL" >/dev/null || fail "register failed"
rm -f "$HOME_X"/cluster/*
run_cw "$HOME_X" 1790044000 drive v1-3317 >/dev/null || fail "unmeasured drive failed"
rm -f "$HOME_X/state/change-watch/v1-3317/verdict"
run_cw "$HOME_X" 1790045000 register v1 "$PR_URL" >/dev/null \
  || fail "re-registering a watch whose verdict was deleted failed"
grep -q '"terminal_state": "open"' "$HOME_X/state/change-watch/rows/v1-3317.json" \
  || fail "a watch whose verdict was deleted was not reopened from its durable row"
seed_series "$HOME_X" http_5xx_per_min muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_X" restarts muso-prod_feed-service sample \
  2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_X" 1790088200 drive v1-3317 >/dev/null || fail "clean drive after recovery failed"
grep -q '"terminal_state": "proven"' "$HOME_X/state/change-watch/rows/v1-3317.json" \
  || fail "a recovered watch did not reach proven on a clean drive"
pass "a deleted verdict does not hide the durable row from recovery"

# --- (g) a row with a missing reading is not proven ---------------------------

# The schedule is cut to +15m and +1h only, so the +6h reading never happens.
# Every target is measured, so the old clean bar would have passed it; the row
# must still refuse to call it proven.
HOME_V=$(new_world v)
seed_pr "$HOME_V" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_V" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_V" restarts muso-prod_feed-service baseline 2
seed_series "$HOME_V" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_V" 1790000000 register r1 "$PR_URL" >/dev/null || fail "register failed"
printf '900\t1790000900\n3600\t1790003600\n' > "$HOME_V/state/change-watch/r1-3317/schedule"
run_cw "$HOME_V" 1790004000 drive r1-3317 >/dev/null || fail "short drive failed"
line=$(run_cw "$HOME_V" 1790004000 verdict r1-3317)
case "$line" in
  "change-watch unmeasurable-with-reason: "*"+360m"*) ;;
  *) fail "a row missing the +6h reading was not refused: $line" ;;
esac
ROW_V="$HOME_V/state/change-watch/rows/r1-3317.json"
grep -q '"21600": null' "$ROW_V" || fail "the missing +6h reading was not recorded as null"
grep -q '"terminal_state": "proven"' "$ROW_V" \
  && fail "a row with a missing reading was recorded as proven"
pass "a row with a missing reading is not proven"

# --- (h) the 7-day acceptance is measurable -----------------------------------

run_cw "$HOME_V" 1790004000 audit 7 >/dev/null \
  && fail "the audit passed while an unmeasurable row sat inside the window"
printf 'note: change-watch completed unmeasured for %s\n' "$PR_URL" >> "$HOME_V/state/r1.status"
run_cw "$HOME_V" 1790004000 audit 7 >/dev/null \
  && fail "the audit passed with a completed-unmeasured status line present"
run_cw "$HOME_V" 1790004000 audit 7 2>&1 | grep -q 'completed unmeasured' \
  || fail "the audit did not name the offending status line"
pass "the audit fails on an unmeasurable row and on a completed-unmeasured status line"

# --- the pool metric is the Deployment's own pool -------------------------------

HOME_P=$(new_world p)
seed_pr "$HOME_P" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_P" "$MANIFEST" "$FEED_LINE"
printf '10.0.0.17\t6432\tfeed\n' > "$HOME_P/cluster/pool.muso-prod_feed-service"
seed_series "$HOME_P" pgbouncer_cl_waiting muso-prod_feed-service baseline 0
seed_series "$HOME_P" pgbouncer_cl_waiting muso-prod_feed-service sample 3 3
run_cw "$HOME_P" 1790000000 register p1 "$PR_URL" >/dev/null || fail "register failed"
[ "$(cat "$HOME_P/state/change-watch/p1-3317/pools")" = "$(printf 'muso-prod/feed-service\t10.0.0.17\t6432\tfeed')" ] \
  || fail "the resolved pool was not recorded"
run_cw "$HOME_P" 1790000300 sample p1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_P" 1790000900 sample p1-3317 >/dev/null || fail "sample failed"
[ "$(run_cw "$HOME_P" 1790000900 verdict p1-3317)" = "change-watch regressed at +15m on pgbouncer_cl_waiting (3 vs baseline 0)" ] \
  || fail "two consecutive pool waits did not regress"
pass "the pool metric reads the Deployment's resolved pool"

HOME_Q=$(new_world q)
seed_pr "$HOME_Q" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_Q" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_Q" pgbouncer_cl_waiting muso-prod_feed-service baseline 0
seed_series "$HOME_Q" pgbouncer_cl_waiting muso-prod_feed-service sample 3 3
run_cw "$HOME_Q" 1790000000 register q1 "$PR_URL" >/dev/null || fail "register failed"
[ "$(awk -F'\t' '$1 == "pgbouncer_cl_waiting@muso-prod/feed-service" { print $2 }' "$HOME_Q/state/change-watch/q1-3317/baseline")" = "" ] \
  || fail "an unresolvable pool produced a baseline reading"
run_cw "$HOME_Q" 1790000300 sample q1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_Q" 1790000900 sample q1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_Q" 1790000900 verdict q1-3317 | grep -q "clean so far" \
  || fail "an unresolvable pool was scored from a series it does not own"
pass "an unresolvable pool leaves the pool metric unmeasured"

# --- an interrupted drive is never clean and can be re-armed ------------------

HOME_I=$(new_world i)
seed_pr "$HOME_I" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_I" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_I" restarts muso-prod_feed-service baseline 0
seed_series "$HOME_I" restarts muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
run_cw "$HOME_I" 1790000000 register i1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_I/state/i1.meta"
cat > "$HOME_I/kill-sleep.sh" <<'STUB'
#!/usr/bin/env bash
kill -TERM "$PPID"
sleep 5
STUB
chmod +x "$HOME_I/kill-sleep.sh"

CW_SLEEP="$HOME_I/kill-sleep.sh" run_cw "$HOME_I" 1790000900 drive i1-3317 >/dev/null 2>&1 \
  && fail "a drive stopped mid-schedule exited as if it completed"
[ "$(run_cw "$HOME_I" 1790000900 verdict i1-3317)" = "change-watch interrupted at +15m" ] \
  || fail "interrupted verdict is wrong: $(run_cw "$HOME_I" 1790000900 verdict i1-3317)"
[ "$(grep -c '' "$HOME_I/state/change-watch/i1-3317/sampled")" -eq 2 ] \
  || fail "the drive did not take the two due samples before the stop"
grep -qF "check: change-watch i1 $PR_URL interrupted at +15m" "$HOME_I/state/.wake-queue" \
  || fail "the interruption did not queue one check wake"
[ ! -e "$HOME_I/state/change-watch/i1-3317/drive.pid" ] || fail "the stopped drive left its pid record"
[ ! -e "$HOME_I/state/change-watch/i1-3317/drive.identity" ] || fail "the stopped drive left its identity record"
pass "a drive stopped mid-schedule records interrupted and queues one wake"

before=$(grep -c '' "$HOME_I/arm.log")
out=$(run_cw "$HOME_I" 1790001000 register i1 "$PR_URL") || fail "re-register failed"
case "$out" in
  *"re-armed i1-3317"*"(13 sample(s) remaining)"*) pass "re-registering an interrupted watch re-arms the remaining samples" ;;
  *) fail "re-register did not re-arm: $out" ;;
esac
[ "$(grep -c '' "$HOME_I/arm.log")" -eq $((before + 2)) ] \
  || fail "re-arm did not retire the old source and arm a new one: $(cat "$HOME_I/arm.log")"
grep -q "^retire cw-" "$HOME_I/arm.log" || fail "re-arm did not retire the stopped source"
run_cw "$HOME_I" 1790001000 verdict i1-3317 | grep -q "clean so far" \
  || fail "re-arm did not clear the interrupted verdict"
ROW_I="$HOME_I/state/change-watch/rows/i1-3317.json"
grep -q '"terminal_state": "open"' "$ROW_I" \
  || fail "re-arm left the durable row in its interrupted terminal state"
grep -q '"completed_epoch": null' "$ROW_I" \
  || fail "re-arm left a completion epoch on the durable row"
run_cw "$HOME_I" 1790001000 audit 7 >/dev/null \
  || fail "the audit false-failed a re-armed in-flight watch"

run_cw "$HOME_I" 1790044000 drive i1-3317 >/dev/null || fail "resumed drive failed"
[ "$(run_cw "$HOME_I" 1790044000 verdict i1-3317)" = "change-watch clean" ] \
  || fail "resumed drive did not end clean: $(run_cw "$HOME_I" 1790044000 verdict i1-3317)"
[ "$(grep -c '' "$HOME_I/state/change-watch/i1-3317/sampled")" -eq 15 ] \
  || fail "the resumed drive did not take exactly the remaining samples"
pass "a re-armed watch finishes its remaining schedule"

# A drive killed outright is found by its dead pid at the next read.
HOME_K=$(new_world k)
seed_pr "$HOME_K" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_K" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_K" 1790000000 register k1 "$PR_URL" >/dev/null || fail "register failed"
printf '%s\n' 999999 > "$HOME_K/state/change-watch/k1-3317/drive.pid"
printf '%s\n' 1790001800 > "$HOME_K/state/change-watch/k1-3317/drive.alive"
[ "$(run_cw "$HOME_K" 1790040000 verdict k1-3317)" = "change-watch interrupted at +30m" ] \
  || fail "a dead drive was not reported at its last heartbeat: $(run_cw "$HOME_K" 1790040000 verdict k1-3317)"
grep -qF "check: change-watch k1 $PR_URL interrupted at +30m" "$HOME_K/state/.wake-queue" \
  || fail "a dead drive did not queue the interruption wake"
pass "a drive killed outright is recorded as interrupted at its last heartbeat"

# A pid that is alive but belongs to another process (reused after a reboot) is
# not the drive; only a pid still carrying the recorded identity is.
HOME_R=$(new_world r)
seed_pr "$HOME_R" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_R" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_R" 1790000000 register r1 "$PR_URL" >/dev/null || fail "register failed"
printf '%s\n' "$$" > "$HOME_R/state/change-watch/r1-3317/drive.pid"
printf 'linux-starttime=1 cmdline-hex=00\n' > "$HOME_R/state/change-watch/r1-3317/drive.identity"
printf '%s\n' 1790001800 > "$HOME_R/state/change-watch/r1-3317/drive.alive"
[ "$(run_cw "$HOME_R" 1790040000 verdict r1-3317)" = "change-watch interrupted at +30m" ] \
  || fail "a reused live pid was read as the drive: $(run_cw "$HOME_R" 1790040000 verdict r1-3317)"
out=$(run_cw "$HOME_R" 1790040000 register r1 "$PR_URL") || fail "re-register failed"
case "$out" in
  *"re-armed r1-3317"*) ;;
  *) fail "a watch behind a reused pid was not re-armed: $out" ;;
esac
pass "a reused pid never reads as a live drive and the watch can be re-armed"

HOME_R2=$(new_world r2)
seed_pr "$HOME_R2" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_R2" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_R2" 1790000000 register r2 "$PR_URL" >/dev/null || fail "register failed"
printf '%s\n' "$$" > "$HOME_R2/state/change-watch/r2-3317/drive.pid"
printf '%s\n' "$FM_TEST_OWNER_IDENTITY" > "$HOME_R2/state/change-watch/r2-3317/drive.identity"
printf '%s\n' 1790001800 > "$HOME_R2/state/change-watch/r2-3317/drive.alive"
run_cw "$HOME_R2" 1790040000 verdict r2-3317 | grep -q "clean so far" \
  || fail "a live drive with its recorded identity was reported interrupted"
pass "a live pid with the recorded identity is the drive"

# --- (e) a docs-only PR registers nothing --------------------------------------

HOME_E=$(new_world e)
printf 'README.md\ndocs/notes.md\n' > "$HOME_E/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_E/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_E/forge/head-ref"
out=$(run_cw "$HOME_E" 1790000000 register e1 "$PR_URL") || fail "docs-only register failed"
case "$out" in
  *"no deployable service touched"*"nothing registered"*) pass "docs-only PR registers nothing" ;;
  *) fail "docs-only register did not report nothing: $out" ;;
esac
[ -e "$HOME_E/state/change-watch/e1-3317" ] && fail "docs-only PR created a watch record"
[ "$(grep -c '' "$HOME_E/arm.log" 2>/dev/null || echo 0)" -eq 0 ] \
  || fail "docs-only PR armed a watch"
# Every merge writes one durable row, including one with nothing to measure: the
# row says why, so the merge is never silently unrecorded.
grep -q '"terminal_state": "not-applicable"' "$HOME_E/state/change-watch/rows/e1-3317.json" \
  || fail "a docs-only merge wrote no not-applicable row"
run_cw "$HOME_E" 1790000100 audit 7 >/dev/null \
  || fail "the audit failed a docs-only merge with nothing to measure"
run_cw "$HOME_E" 1790000100 gate e1 --terminal-gap >/dev/null \
  || fail "teardown was refused for a docs-only merge with nothing to measure"
run_cw "$HOME_E" 1790000100 gate e1 >/dev/null \
  || fail "the done-claim gate failed a docs-only merge with nothing to measure"
[ -e "$HOME_E/state/.wake-queue" ] && [ -s "$HOME_E/state/.wake-queue" ] \
  && fail "a docs-only merge queued a wake"
pass "docs-only PR leaves no watch behind but still writes its row"

# --- an application repo resolves through its name -----------------------------

HOME_F=$(new_world f)
mkdir -p "$HOME_F/projects/H-DevOps/k8s/prod/core-services"
cp "$TMP_ROOT/multi.yaml" "$HOME_F/projects/H-DevOps/k8s/prod/core-services/deployments.yaml"
printf 'src/main.py\n' > "$HOME_F/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_F/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_F/forge/head-ref"
out=$(env FM_HOME="$HOME_F" FM_STATE_OVERRIDE="$HOME_F/state" FM_CW_NOW=1790000000 \
  FM_CW_FORGE_DIR="$HOME_F/forge" FM_CW_CLUSTER_DIR="$HOME_F/cluster" \
  FM_CW_HDEVOPS_K8S_DIR="$HOME_F/projects/H-DevOps/k8s/prod" \
  FM_CW_ARM_CMD="$HOME_F/arm.sh" FM_CW_ARM_LOG="$HOME_F/arm.log" \
  FM_CW_SEND_CMD="$HOME_F/send.sh" FM_CW_SEND_LOG="$HOME_F/send.log" \
  FM_CW_NO_WIKI=1 "$CW" register f1 'https://github.com/Muso-AI/feed-service/pull/42') \
  || fail "application-repo register failed"
case "$out" in
  *"registered f1-42"*) pass "an application repo resolves to its service Deployment" ;;
  *) fail "application-repo register did not resolve a target: $out" ;;
esac
[ "$(cat "$HOME_F/state/change-watch/f1-42/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "application-repo target is wrong (namespace must come from the manifest)"

# --- live reads through a kubectl shim -----------------------------------------
# The shim answers the exact kubectl calls a sample makes: two replicas with a
# 512Mi limit, metrics-server rows with a CPU column before the memory column,
# and a capped access log whose lines span two minutes.

HOME_L=$(new_world l)
mkdir -p "$HOME_L/bin"
cat > "$HOME_L/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *" --raw=/version "*) printf '{"major":"1","minor":"31","gitVersion":"v1.31.0"}\n' ;;
  *" get pods "*)
    cat <<'JSON'
{"items":[{"metadata":{"name":"feed-service-abc"},
  "spec":{"containers":[{"name":"feed-service","resources":{"limits":{"memory":"512Mi"}}}]},
  "status":{"containerStatuses":[{"name":"feed-service","restartCount":0,"lastState":{}}]}},
 {"metadata":{"name":"feed-service-def"},
  "spec":{"containers":[{"name":"feed-service","resources":{"limits":{"memory":"512Mi"}}}]},
  "status":{"containerStatuses":[{"name":"feed-service","restartCount":0,"lastState":{}}]}}]}
JSON
    ;;
  *" top pods "*)
    printf 'feed-service-abc   feed-service   500m   300Mi\nfeed-service-def   feed-service   250m   400Mi\n'
    ;;
  *" logs "*)
    awk 'BEGIN {
      for (i = 0; i < 2000; i++) {
        s = int(i * 120 / 1999)
        printf "[pod/feed-service-abc/feed-service] 2026-09-22T06:%02d:%02d.000000000Z 10.0.0.1 - \"GET /home HTTP/1.1\" %d 12\n", int(s / 60), s % 60, (i % 167 == 0 ? 502 : 200)
      }
    }'
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$HOME_L/bin/kubectl"
seed_pr "$HOME_L" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_L" "$MANIFEST" "$FEED_LINE"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000000 register l1 "$PR_URL" >/dev/null \
  || fail "live register failed"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000300 sample l1-3317 >/dev/null \
  || fail "live sample failed"
SAMPLES_L="$HOME_L/state/change-watch/l1-3317/samples.log"
[ "$(awk -F'\t' '$3 == "rss_ratio@muso-prod/feed-service" { print $4 }' "$SAMPLES_L")" = "0.7812" ] \
  || fail "rss_ratio did not take the worst replica's 400Mi of 512Mi from the memory column: $(cat "$SAMPLES_L")"
[ "$(awk -F'\t' '$3 == "http_5xx_per_min@muso-prod/feed-service" { print $4 "/" $5 }' "$SAMPLES_L")" = "6.0000/6.0000" ] \
  || fail "a capped log was not rated over the span it covers in both windows: $(cat "$SAMPLES_L")"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000300 verdict l1-3317 | grep -q "clean so far" \
  || fail "an unchanged service regressed on live reads"
pass "live reads take the worst replica's memory column and rate a capped log over its span"

# --- the pool console read and the doctor ---------------------------------------
# The ssh shim behaves like ssh where it matters: without -n it reads its stdin
# to the end (the real ssh forwards it to the remote session), it records its
# argv, and it answers SHOW POOLS with the console's unaligned rows. The kubectl
# shim resolves feed-service's DB env to the pooler and gives search-service,
# which sorts after it, no DB env at all.

POOL_MANIFEST='apiVersion: apps/v1
kind: Deployment
metadata:
  name: feed-service
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: feed-service
          env:
            - name: DB_HOST
              value: 10.0.0.17
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search-service
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: search-service
'
printf '%s' "$POOL_MANIFEST" > "$TMP_ROOT/pool.yaml"

pool_world() {  # <name> prints a home with the ssh and kubectl shims on its bin
  local home
  home=$(new_world "$1")
  mkdir -p "$home/bin"
  cat > "$home/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SSH_LOG"
case " $* " in *" -n "*) ;; *) cat >/dev/null ;; esac
[ -z "${FM_CW_SSH_SLEEP:-}" ] || sleep "$FM_CW_SSH_SLEEP"
if [ -n "${FM_CW_SSH_FAIL:-}" ]; then printf '%s\n' "$FM_CW_SSH_FAIL" >&2; exit 255; fi
printf 'database|user|cl_active|cl_waiting|sv_active|sv_idle|maxwait|pool_mode\n'
printf 'feed|muso-feed-pg|12|2|12|3|0|transaction\n'
printf 'stats|muso-stats-pg|40|0|40|10|0|transaction\n'
printf 'pgbouncer|pgbouncer|1|0|0|0|0|statement\n'
printf '(3 rows)\n'
SHIM
  cat > "$home/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *" --raw=/version "*) printf '{"major":"1","minor":"31","gitVersion":"v1.31.0"}\n' ;;
  *" set env deployment/feed-service "*) printf 'DB_HOST=10.0.0.17\nDB_PORT=6432\nDB_NAME=feed\n' ;;
  *" set env "*) printf 'ENV=production\n' ;;
  *" get pods "*)
    printf '{"items":[{"metadata":{"name":"p"},"spec":{"containers":[{"name":"c","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":{}}]}}]}\n'
    ;;
  *" top pods "*) printf 'p   c   500m   300Mi\n' ;;
  *" logs "*) : ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$home/bin/ssh" "$home/bin/kubectl"
  seed_pr "$home" "$MANIFEST" "$TMP_ROOT/pool.yaml" "$MANIFEST"
  printf '%s\n' "$home"
}

HOME_S=$(pool_world s)
CW_CLUSTER_DIR='' PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" \
  run_cw "$HOME_S" 1790000000 register s1 "$PR_URL" >/dev/null || fail "live register failed"
BASE_S="$HOME_S/state/change-watch/s1-3317/baseline"
[ "$(grep -c '' "$BASE_S")" -eq 12 ] \
  || fail "the pool read drained the metric key stream; baseline has $(grep -c '' "$BASE_S") of 12 keys"
grep -q "^restarts@muso-prod/search-service	" "$BASE_S" \
  || fail "the target sorted after the pool read was never read"
[ "$(awk -F'\t' '$1 == "pgbouncer_cl_waiting@muso-prod/feed-service" { print $2 }' "$BASE_S")" = "2" ] \
  || fail "the pool baseline is not the feed database's cl_waiting: $(cat "$BASE_S")"
pass "the pool read leaves every later metric key to be read"

[ "$(grep -c '' "$HOME_S/ssh.log")" -eq 1 ] || fail "expected one console read at registration: $(cat "$HOME_S/ssh.log")"
case " $(cat "$HOME_S/ssh.log") " in
  *" -n "*" ubuntu@10.0.0.17 sudo -u postgres psql -h /var/run/postgresql -p 6432 -U pgbouncer pgbouncer -Ac 'SHOW POOLS'"*) ;;
  *) fail "the console is not read as ubuntu through the admin unix socket: $(cat "$HOME_S/ssh.log")" ;;
esac
pass "the console is read as ubuntu through the pgbouncer admin unix socket"

# A metric kind read on one target is not evidence for another: search-service
# has no pool, so its pool metric is named as the gap while feed-service's is
# reported as measured.
CW_CLUSTER_DIR='' PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" \
  run_cw "$HOME_S" 1790000300 sample s1-3317 300 >/dev/null || true
line=$(CW_CLUSTER_DIR='' PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" \
  run_cw "$HOME_S" 1790000300 status s1-3317)
printf '%s\n' "$line" | grep -q 'pgbouncer_cl_waiting@muso-prod/search-service' \
  || fail "the status did not name the target whose pool was never resolved: $line"
printf '%s\n' "$line" | grep -q 'pgbouncer_cl_waiting@muso-prod/feed-service' \
  && fail "a metric measured on one target was reported as never measured: $line"
pass "an unmeasured metric is named per target, never collapsed to its metric kind"

out=$(CW_CLUSTER_DIR='' PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" \
  run_cw "$HOME_S" 1790000300 doctor s1-3317) && fail "doctor passed a watch with an unresolved pool"
case "$out" in
  *"doctor: ok muso-prod/feed-service pool read ubuntu@10.0.0.17:6432 returned 1 pool row(s) for database feed"*) ;;
  *) fail "doctor did not prove the resolved pool read: $out" ;;
esac
case "$out" in
  *"doctor: FAIL muso-prod/search-service pool unresolved"*) ;;
  *) fail "doctor did not name the unresolved pool: $out" ;;
esac
pass "doctor proves each target's pool read and names an unresolved pool"

out=$(PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" run_cw "$HOME_S" 1790000300 doctor) \
  || fail "doctor failed against a console that answers: $out"
printf '%s\n' "$out" | grep -qxF "doctor: ok pool read ubuntu@10.0.0.17:6432 returned 3 pool row(s)" \
  || fail "doctor's default read is not the documented pooler path: $out"
out=$(PATH="$HOME_S/bin:$PATH" FM_CW_SSH_LOG="$HOME_S/ssh.log" FM_CW_SSH_FAIL='Permission denied (publickey).' \
  run_cw "$HOME_S" 1790000300 doctor) && fail "doctor passed a failed console read"
printf '%s\n' "$out" | grep -qxF "doctor: FAIL pool read ubuntu@10.0.0.17:6432: Permission denied (publickey)." \
  || fail "doctor did not state the console failure: $out"
pass "doctor reads the documented pooler by default and states a failed read"

# A console that stops answering is cut at the sample budget: the pool metric is
# unmeasured, the later keys are still read, and the doctor says it timed out.
HOME_T=$(pool_world t)
CW_CLUSTER_DIR='' PATH="$HOME_T/bin:$PATH" FM_CW_SSH_LOG="$HOME_T/ssh.log" \
  FM_CW_SSH_SLEEP=30 FM_CW_SAMPLE_DEADLINE=2 \
  run_cw "$HOME_T" 1790000000 register t1 "$PR_URL" >/dev/null || fail "live register failed"
BASE_T="$HOME_T/state/change-watch/t1-3317/baseline"
[ "$(awk -F'\t' '$1 == "pgbouncer_cl_waiting@muso-prod/feed-service" { print $2 }' "$BASE_T")" = "" ] \
  || fail "a hung console read produced a pool reading: $(cat "$BASE_T")"
[ "$(grep -c '' "$BASE_T")" -eq 12 ] || fail "a hung console read lost the later keys"
out=$(PATH="$HOME_T/bin:$PATH" FM_CW_SSH_LOG="$HOME_T/ssh.log" FM_CW_SSH_SLEEP=30 FM_CW_SAMPLE_DEADLINE=2 \
  run_cw "$HOME_T" 1790000300 doctor) && fail "doctor passed a hung console read"
printf '%s\n' "$out" | grep -qxF "doctor: FAIL pool read ubuntu@10.0.0.17:6432: timed out after 2s" \
  || fail "doctor did not state the timed-out read: $out"
pass "a hung console read is bounded, unmeasured, and stated by the doctor"

# One unreachable pooler costs one connect timeout per sample, not one per
# target: the armed drive takes every sample in one process, so two Deployments
# behind the same dead console must not spend the sample budget twice.
SHARED_MANIFEST='apiVersion: apps/v1
kind: Deployment
metadata:
  name: notify-gateway
  namespace: messaging
spec:
  template:
    spec:
      containers:
        - name: notify-gateway
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: send-gateway
  namespace: messaging
spec:
  template:
    spec:
      containers:
        - name: send-gateway
'
printf '%s' "$SHARED_MANIFEST" > "$TMP_ROOT/shared.yaml"
HOME_PM=$(new_world poolmemo)
mkdir -p "$HOME_PM/bin"
cp "$HOME_S/bin/ssh" "$HOME_PM/bin/ssh"
cat > "$HOME_PM/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *" --raw=/version "*) printf '{"gitVersion":"v1.31.0"}\n' ;;
  *" set env "*) printf 'DB_HOST=10.0.0.17\nDB_PORT=6432\nDB_NAME=feed\n' ;;
  *" get pods "*)
    printf '{"items":[{"metadata":{"name":"p"},"spec":{"containers":[{"name":"c","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":{}}]}}]}\n'
    ;;
  *" top pods "*) printf 'p   c   500m   300Mi\n' ;;
  *" logs "*) : ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$HOME_PM/bin/kubectl"
seed_pr "$HOME_PM" "$MANIFEST" "$TMP_ROOT/shared.yaml" "$MANIFEST"
CW_CLUSTER_DIR='' PATH="$HOME_PM/bin:$PATH" FM_CW_SSH_LOG="$HOME_PM/ssh.log" \
  FM_CW_SSH_FAIL='Connection timed out' \
  run_cw "$HOME_PM" 1790000000 register pm1 "$PR_URL" >/dev/null || fail "shared-pooler register failed"
: > "$HOME_PM/ssh.log"
CW_CLUSTER_DIR='' PATH="$HOME_PM/bin:$PATH" FM_CW_SSH_LOG="$HOME_PM/ssh.log" \
  FM_CW_SSH_FAIL='Connection timed out' \
  run_cw "$HOME_PM" 1790000300 sample pm1-3317 300 >/dev/null || true
[ "$(grep -c '' "$HOME_PM/ssh.log")" -eq 1 ] \
  || fail "an unreachable pooler was dialled $(grep -c '' "$HOME_PM/ssh.log") times in one sample: $(cat "$HOME_PM/read-failures" 2>/dev/null)"
pass "an unreachable pooler is dialled once per sample, not once per target"

# --- the reader: kubeconfig, one probe, and a stated reason --------------------
# Every watch once completed unmeasured for months because the ambient kubectl
# pointed at a cluster this home could not reach. The reader now resolves the
# kubeconfig the home documents, proves the cluster answers once per sample, and
# records why each metric it could not read stayed unmeasured.

CORE_PR='https://github.com/Muso-AI/core-backend/pull/4242'
CORE_ID_SUFFIX='-4242'

# cluster_world <name> prints a home whose kubectl answers like a live cluster:
# it records the kubeconfig and argv it saw, proves the version probe, lists the
# workloads inventory when one is set, and answers pod reads with the image
# FM_CW_SHIM_IMAGE names.
cluster_world() {
  local home
  home=$(new_world "$1")
  mkdir -p "$home/bin" "$home/config" "$home/sentry"
  cat > "$home/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\t%s\n' "${KUBECONFIG:-}" "$*" >> "$FM_CW_SHIM_LOG"
case " $* " in
  *" --raw=/version "*) printf '{"gitVersion":"v1.31.0"}\n' ;;
  *" get deploy -A "*)
    [ -z "${FM_CW_SHIM_WORKLOADS:-}" ] || cat "$FM_CW_SHIM_WORKLOADS"
    ;;
  *" get pods "*)
    app=$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')
    [ -z "${FM_CW_SHIM_PODS_FAIL:-}" ] || exit 1
    hash=${FM_CW_SHIM_HASH:-h1}
    if [ -n "${FM_CW_SHIM_HASH_FILE:-}" ] && [ -f "$FM_CW_SHIM_HASH_FILE" ]; then
      hash=$(cat "$FM_CW_SHIM_HASH_FILE")
    fi
    last='{}'
    [ -z "${FM_CW_SHIM_OOM_AT:-}" ] || last="{\"terminated\":{\"reason\":\"OOMKilled\",\"finishedAt\":\"$(date -u -d "@$FM_CW_SHIM_OOM_AT" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '1970-01-01T00:00:00Z')\"}}"
    printf '{"items":[{"metadata":{"name":"%s-1","labels":{"pod-template-hash":"%s"}},"spec":{"containers":[{"name":"c","image":"%s","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":%s}]}}]}\n' \
      "$app" "$hash" "${FM_CW_SHIM_IMAGE:-}" "$last"
    ;;
  *" top pods "*) printf '%s-1   c   100m   128Mi\n' "$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')" ;;
  *" logs "*) : ;;
  *" set env "*) printf 'ENV=production\n' ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$home/bin/kubectl"
  printf '%s\n' "$home"
}

# seed_app_pr <home> seeds a merged application PR: source files only, no
# manifests, so the Deployments are resolved from the image inventory.
seed_app_pr() {
  printf 'src/server.ts\nsrc/routes/feed.ts\n' > "$1/forge/files.txt"
  printf '%s\n' 1790000000 > "$1/forge/merge-epoch"
  printf '%s\n' deadbeef > "$1/forge/head-ref"
  : > "$1/forge/diff.txt"
}

HOME_K=$(cluster_world k)
seed_app_pr "$HOME_K"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_K/workloads"
printf 'muso-dev\tcore-backend-api\t1\tlocalhost:30500/muso/core-backend:old-1\n' >> "$HOME_K/workloads"
printf '[]\n' > "$HOME_K/sentry/issues-core-backend.json"

# An explicit kubeconfig wins, and the ambient default never silently decides.
printf 'apiVersion: v1\n' > "$HOME_K/doc.kubeconfig"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_K/bin:$PATH" FM_CW_SHIM_LOG="$HOME_K/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_K/workloads" FM_CW_SHIM_IMAGE="${FM_CW_SHIM_IMAGE:-localhost:30500/muso/core-backend:old-1}" FM_CW_CONFIG_DIR="$HOME_K/config" \
  FM_CW_KUBECONFIG="$HOME_K/doc.kubeconfig" FM_CW_SENTRY_DIR="$HOME_K/sentry" \
  KUBECONFIG=/ambient/kubeconfig \
  run_cw "$HOME_K" 1790000000 register k1 "$CORE_PR") || fail "register failed: $out"
grep -q "$HOME_K/doc.kubeconfig" "$HOME_K/shim.log" \
  || fail "the explicit kubeconfig did not reach kubectl: $(head -2 "$HOME_K/shim.log" 2>/dev/null)"
grep -q '/ambient/kubeconfig' "$HOME_K/shim.log" \
  && fail "an explicit kubeconfig did not win over the ambient one"
pass "an explicit kubeconfig is what every cluster read uses"

# The home's own config file is next, ahead of the ambient default.
printf 'apiVersion: v1\n' > "$HOME_K/config/home.kubeconfig"
printf '%s\n' "$HOME_K/config/home.kubeconfig" > "$HOME_K/config/change-watch-kubeconfig"
: > "$HOME_K/shim.log"
CW_CLUSTER_DIR='' PATH="$HOME_K/bin:$PATH" FM_CW_SHIM_LOG="$HOME_K/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_K/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_K/config" FM_CW_SENTRY_DIR="$HOME_K/sentry" KUBECONFIG=/ambient/kubeconfig \
  run_cw "$HOME_K" 1790000300 sample "k1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
grep -q "$HOME_K/config/home.kubeconfig" "$HOME_K/shim.log" \
  || fail "the home's kubeconfig config file was not used: $(head -2 "$HOME_K/shim.log" 2>/dev/null)"
pass "a home's config/change-watch-kubeconfig is the next kubeconfig in line"

# An unreachable cluster is one probe, never a metric read per key, and every
# metric says why it stayed unmeasured.
HOME_X=$(new_world x)
mkdir -p "$HOME_X/bin"
cat > "$HOME_X/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SHIM_LOG"
printf 'Unable to connect to the server: dial tcp: lookup prod.example: no such host\n' >&2
exit 1
SHIM
chmod +x "$HOME_X/bin/kubectl"
seed_pr "$HOME_X" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_X" "$MANIFEST" "$FEED_LINE"
printf 'apiVersion: v1\n' > "$HOME_X/doc.kubeconfig"
CW_CLUSTER_DIR='' PATH="$HOME_X/bin:$PATH" FM_CW_SHIM_LOG="$HOME_X/shim.log" \
  FM_CW_KUBECONFIG="$HOME_X/doc.kubeconfig" FM_CW_SENTRY_DIR="$HOME_X/sentry" \
  run_cw "$HOME_X" 1790000000 register x1 "$PR_URL" >/dev/null || fail "register failed"
: > "$HOME_X/shim.log"
CW_CLUSTER_DIR='' PATH="$HOME_X/bin:$PATH" FM_CW_SHIM_LOG="$HOME_X/shim.log" \
  FM_CW_KUBECONFIG="$HOME_X/doc.kubeconfig" FM_CW_SENTRY_DIR="$HOME_X/sentry" \
  run_cw "$HOME_X" 1790000300 sample x1-3317 300 >/dev/null || fail "sample failed"
[ "$(grep -c '' "$HOME_X/shim.log")" -eq 1 ] \
  || fail "an unreachable cluster was probed $(grep -c '' "$HOME_X/shim.log") times, not once"
REASONS_X="$HOME_X/state/change-watch/x1-3317/read-failures"
[ "$(grep -c '' "$REASONS_X")" -eq 6 ] \
  || fail "not every metric recorded why it was unmeasured: $(cat "$REASONS_X")"
grep -q "cluster read failed: .*no such host" "$REASONS_X" \
  || fail "the recorded reason does not name the unreachable cluster: $(cat "$REASONS_X")"
pass "an unreachable cluster costs one probe and is named as every metric's reason"

out=$(CW_CLUSTER_DIR='' PATH="$HOME_X/bin:$PATH" FM_CW_SHIM_LOG="$HOME_X/shim.log" \
  FM_CW_KUBECONFIG="$HOME_X/doc.kubeconfig" FM_CW_SENTRY_DIR="$HOME_X/sentry" \
  run_cw "$HOME_X" 1790000300 doctor x1-3317) && fail "doctor passed an unreachable cluster"
printf '%s\n' "$out" | grep -q "doctor: FAIL cluster unreachable: .*no such host" \
  || fail "doctor did not state the unreachable cluster: $out"
pass "the doctor states an unreachable cluster instead of calling an unmeasured watch fine"

# --- an application release is watched by the image it deploys -----------------
# The target set comes from the Deployments that RUN the repository's image, in
# production namespaces only: a dev copy and a test copy are not the release,
# and a family larger than the cap is reduced to its busiest members.

HOME_C=$(cluster_world c)
seed_app_pr "$HOME_C"
{
  printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n'
  printf 'muso-prod\tcore-backend-worker\t3\tlocalhost:30500/muso/core-backend:old-1\n'
  printf 'muso-prod\tcore-backend-analytics\t2\tlocalhost:30500/muso/core-backend:old-1\n'
  printf 'muso-dev\tcore-backend-api\t1\tlocalhost:30500/muso/core-backend:old-1\n'
  printf 'muso-prod\tcore-backend-api-test\t1\tlocalhost:30500/muso/core-backend:old-1\n'
} > "$HOME_C/workloads"
printf '[]\n' > "$HOME_C/sentry/issues-core-backend.json"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_C/bin:$PATH" FM_CW_SHIM_LOG="$HOME_C/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_C/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_C/config" \
  FM_CW_SENTRY_DIR="$HOME_C/sentry" run_cw "$HOME_C" 1790000000 register c1 "$CORE_PR") \
  || fail "application register failed: $out"
TARGETS_C="$HOME_C/state/change-watch/c1$CORE_ID_SUFFIX/targets"
[ "$(cat "$TARGETS_C")" = "$(printf 'muso-prod\tcore-backend-analytics\nmuso-prod\tcore-backend-api\nmuso-prod\tcore-backend-worker')" ] \
  || fail "the image family resolved wrong: $(cat "$TARGETS_C")"
case "$out" in
  *"registered c1$CORE_ID_SUFFIX"*"(4 target(s)"*) pass "an application release is watched by the Deployments that run its image" ;;
  *) fail "the registration line does not count every target kind: $out" ;;
esac

# A family larger than the cap is watched by its busiest members, and the line
# says so instead of silently dropping the rest.
HOME_FAM=$(cluster_world fam)
seed_app_pr "$HOME_FAM"
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'muso-prod\tindustry-proc-%s\t%s\tlocalhost:30500/muso/industry-data-processing:old\n' "$i" "$i"
done > "$HOME_FAM/workloads"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_FAM/bin:$PATH" FM_CW_SHIM_LOG="$HOME_FAM/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_FAM/workloads" FM_CW_SHIM_IMAGE="${FM_CW_SHIM_IMAGE:-localhost:30500/muso/core-backend:old-1}" FM_CW_CONFIG_DIR="$HOME_FAM/config" \
  FM_CW_SENTRY_DIR="$HOME_FAM/sentry" FM_CW_MAX_TARGETS=3 \
  run_cw "$HOME_FAM" 1790000000 register fam1 \
  'https://github.com/Muso-AI/industry-data-processing/pull/620') || fail "family register failed: $out"
[ "$(grep -c '' "$HOME_FAM/state/change-watch/fam1-620/targets")" -eq 3 ] \
  || fail "the cap did not bound the target set"
head -1 "$HOME_FAM/state/change-watch/fam1-620/targets" | grep -q 'industry-proc-10' \
  || fail "the busiest Deployment was not the first target"
case "$out" in
  *"capped: watching the 3 busiest of 10"*) pass "a family over the cap is reduced to its busiest and says so" ;;
  *) fail "the cap was not stated: $out" ;;
esac

# A Deployment with more than one container renders its images space-separated,
# which is what kubectl's jsonpath emits, and a digest-pinned reference carries
# no tag. Both still match the image family the repository builds.
HOME_MC=$(cluster_world mc)
seed_app_pr "$HOME_MC"
{
  printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1 gcr.io/cloudsql-docker/gce-proxy:1.33\n'
  printf 'muso-prod\tcore-backend-worker\t2\tlocalhost:30500/muso/core-backend@sha256:abcdef\n'
  printf 'muso-prod\tfeed-proxy\t2\tlocalhost:30500/muso/unrelated:1\n'
} > "$HOME_MC/workloads"
CW_CLUSTER_DIR='' PATH="$HOME_MC/bin:$PATH" FM_CW_SHIM_LOG="$HOME_MC/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_MC/workloads" FM_CW_CONFIG_DIR="$HOME_MC/config" \
  FM_CW_SENTRY_DIR="$HOME_MC/sentry" \
  run_cw "$HOME_MC" 1790000000 register mc1 "$CORE_PR" >/dev/null || fail "multi-container register failed"
[ "$(cat "$HOME_MC/state/change-watch/mc1$CORE_ID_SUFFIX/targets")" = "$(printf 'muso-prod\tcore-backend-api\nmuso-prod\tcore-backend-worker')" ] \
  || fail "a multi-container or digest-pinned Deployment was not matched: $(cat "$HOME_MC/state/change-watch/mc1$CORE_ID_SUFFIX/targets" 2>/dev/null)"
pass "a Deployment with several containers or a digest-pinned image still matches its image family"

# A repository whose Deployment names differ from its image name is mapped. The
# diff touches all three service directories, so all three are in scope.
HOME_M2=$(cluster_world m2)
seed_app_pr "$HOME_M2"
printf 'notify-gateway/src/send.ts\nsend-gateway/src/send.ts\npreferences/src/read.ts\n' \
  > "$HOME_M2/forge/files.txt"
{
  printf 'messaging\tnotify-gateway\t2\tlocalhost:30500/muso/notify-gateway:prod-1\n'
  printf 'messaging\tsend-gateway\t2\tlocalhost:30500/muso/send-gateway:prod-1\n'
  printf 'messaging\tpreferences\t2\tlocalhost:30500/muso/preferences:prod-1\n'
} > "$HOME_M2/workloads"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_M2/bin:$PATH" FM_CW_SHIM_LOG="$HOME_M2/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_M2/workloads" FM_CW_SHIM_IMAGE="${FM_CW_SHIM_IMAGE:-localhost:30500/muso/core-backend:old-1}" FM_CW_CONFIG_DIR="$HOME_M2/config" \
  FM_CW_SENTRY_DIR="$HOME_M2/sentry" run_cw "$HOME_M2" 1790000000 register m21 \
  'https://github.com/Muso-AI/muso-messaging/pull/88') || fail "messaging register failed: $out"
[ "$(grep -c '' "$HOME_M2/state/change-watch/m21-88/targets")" -eq 3 ] \
  || fail "the messaging map did not resolve its three Deployments: $(cat "$HOME_M2/state/change-watch/m21-88/targets" 2>/dev/null)"
pass "a repository mapped to differently named Deployments resolves through the map"

# --- the deploy must land before anything is scored ----------------------------
# A sample taken while the pods still run the image they ran at registration
# measures the code the release replaced, so it is recorded as awaiting the
# deploy and never as health.

HOME_G=$(cluster_world g)
seed_app_pr "$HOME_G"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_G/workloads"
printf '[]\n' > "$HOME_G/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_G/bin:$PATH" FM_CW_SHIM_LOG="$HOME_G/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_G/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_G/config" FM_CW_SENTRY_DIR="$HOME_G/sentry" \
  run_cw "$HOME_G" 1790000000 register g1 "$CORE_PR" >/dev/null || fail "register failed"
CW_CLUSTER_DIR='' PATH="$HOME_G/bin:$PATH" FM_CW_SHIM_LOG="$HOME_G/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_G/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_G/config" FM_CW_SENTRY_DIR="$HOME_G/sentry" \
  run_cw "$HOME_G" 1790000300 sample "g1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
SAMPLES_G="$HOME_G/state/change-watch/g1$CORE_ID_SUFFIX/samples.log"
[ "$(awk -F'\t' '$7 == 1' "$SAMPLES_G" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "a target still on its pre-merge image was scored: $(cat "$SAMPLES_G")"
grep -q "awaiting the deploy" "$HOME_G/state/change-watch/g1$CORE_ID_SUFFIX/read-failures" \
  || fail "the awaiting-deploy state was not recorded as the reason"
pass "a sample before the rollout is recorded as awaiting the deploy, never as health"

# Once the pods carry a new image the same watch scores the release.
CW_CLUSTER_DIR='' PATH="$HOME_G/bin:$PATH" FM_CW_SHIM_LOG="$HOME_G/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_G/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_CONFIG_DIR="$HOME_G/config" FM_CW_SENTRY_DIR="$HOME_G/sentry" \
  run_cw "$HOME_G" 1790000900 sample "g1$CORE_ID_SUFFIX" 900 >/dev/null || fail "sample failed"
awk -F'\t' '$2 == 900 && $7 == 1' "$SAMPLES_G" | grep -q "restarts@muso-prod/core-backend-api" \
  || fail "the landed release was not scored: $(awk -F'\t' '$2 == 900' "$SAMPLES_G")"
pass "the new image lands and the same watch scores the release"

# --- awaiting the deploy is not a measurement gap ------------------------------
# A reading whose every sample was taken before the rollout landed has nothing
# to read yet. Counting that as a failed read would end a healthy merge
# unmeasurable and block its own done claim, which is the opposite of what the
# watch is for.

HOME_AW=$(cluster_world aw)
seed_app_pr "$HOME_AW"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_AW/workloads"
printf '[]\n' > "$HOME_AW/sentry/issues-core-backend.json"
AW_IMAGE='localhost:30500/muso/core-backend:old-1'
aw_cw() {  # <now> <args...>
  local now=$1
  shift
  CW_CLUSTER_DIR='' PATH="$HOME_AW/bin:$PATH" FM_CW_SHIM_LOG="$HOME_AW/shim.log" \
    FM_CW_SHIM_WORKLOADS="$HOME_AW/workloads" FM_CW_SHIM_IMAGE="$AW_IMAGE" \
    FM_CW_CONFIG_DIR="$HOME_AW/config" FM_CW_SENTRY_DIR="$HOME_AW/sentry" \
    run_cw "$HOME_AW" "$now" "$@"
}
aw_cw 1790000000 register aw1 "$CORE_PR" >/dev/null || fail "register failed"
printf '900\t1790000900\n3600\t1790003600\n21600\t1790021600\n' \
  > "$HOME_AW/state/change-watch/aw1$CORE_ID_SUFFIX/schedule"
aw_cw 1790000900 sample "aw1$CORE_ID_SUFFIX" 900 >/dev/null || fail "sample failed"
SAMPLES_AW="$HOME_AW/state/change-watch/aw1$CORE_ID_SUFFIX/samples.log"
[ "$(awk -F'\t' '$2 == 900 && $7 == 1' "$SAMPLES_AW" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "a pre-rollout sample scored something: $(cat "$SAMPLES_AW")"
[ "$(awk -F'\t' '$2 == 900 && $8 == 1' "$SAMPLES_AW" | wc -l | tr -d ' ')" -gt 0 ] \
  || fail "a pre-rollout sample was not recorded as awaiting the deploy: $(cat "$SAMPLES_AW")"
AW_IMAGE='localhost:30500/muso/core-backend:new-2'
aw_cw 1790021600 drive "aw1$CORE_ID_SUFFIX" >/dev/null || fail "drive failed"
[ "$(aw_cw 1790021600 verdict "aw1$CORE_ID_SUFFIX")" = "change-watch clean" ] \
  || fail "a watch whose first reading only awaited its deploy did not end clean: $(aw_cw 1790021600 verdict "aw1$CORE_ID_SUFFIX")"
ROW_AW="$HOME_AW/state/change-watch/rows/aw1$CORE_ID_SUFFIX.json"
grep -q '"terminal_state": "proven"' "$ROW_AW" \
  || fail "an awaiting-deploy reading made the row unproven: $(cat "$ROW_AW")"
grep -q '"900": {"at": [0-9]*, "scored": 0, "unmeasured": 0, "awaiting": [1-9]' "$ROW_AW" \
  || fail "the +15m reading did not record its awaiting samples: $(cat "$ROW_AW")"
pass "a reading that only awaited its deploy is measured, not a gap"

# One pod read serves the landing gate and every pod-backed metric of a sample.
# The armed drive takes all 15 samples in one process, so a read repeated per
# metric is what spends a family's sample budget before its later targets.
: > "$HOME_G/shim.log"
CW_CLUSTER_DIR='' PATH="$HOME_G/bin:$PATH" FM_CW_SHIM_LOG="$HOME_G/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_G/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-3' \
  FM_CW_CONFIG_DIR="$HOME_G/config" FM_CW_SENTRY_DIR="$HOME_G/sentry" \
  run_cw "$HOME_G" 1790001500 sample "g1$CORE_ID_SUFFIX" 1800 >/dev/null || fail "sample failed"
[ "$(grep -c 'get pods' "$HOME_G/shim.log")" -eq 1 ] \
  || fail "the sample read the pods $(grep -c 'get pods' "$HOME_G/shim.log") times, not once: $(cat "$HOME_G/shim.log")"
pass "one pod read per target serves the landing gate and every pod-backed metric"

# --- Sentry is the error signal for a repository that reports to it ------------
# New error and fatal issues after the merge are the release's own errors; a
# warning that reaches many users and an error first seen before the merge are
# not.

HOME_SN=$(cluster_world sn)
seed_app_pr "$HOME_SN"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_SN/workloads"
# Before the sample the project has only its pre-merge errors; the release's own
# errors appear afterwards, which is what the watch must catch.
cat > "$HOME_SN/sentry/issues-core-backend.json" <<'JSON'
[{"level":"error","firstSeen":"2026-09-20T06:00:00Z","count":100,"userCount":9}]
JSON
cat > "$HOME_SN/sentry/issues-after.json" <<'JSON'
[{"level":"error","firstSeen":"2026-09-22T06:20:00Z","count":9,"userCount":4},
 {"level":"error","firstSeen":"2026-09-22T06:21:00Z","count":4,"userCount":1},
 {"level":"fatal","firstSeen":"2026-09-22T06:22:00Z","count":2,"userCount":1},
 {"level":"warning","firstSeen":"2026-09-22T06:23:00Z","count":900,"userCount":40},
 {"level":"error","firstSeen":"2026-09-20T06:00:00Z","count":100,"userCount":9}]
JSON
CW_CLUSTER_DIR='' PATH="$HOME_SN/bin:$PATH" FM_CW_SHIM_LOG="$HOME_SN/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_SN/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_SN/config" FM_CW_SENTRY_DIR="$HOME_SN/sentry" \
  run_cw "$HOME_SN" 1790000000 register sn1 "$CORE_PR" >/dev/null || fail "register failed"
[ "$(cat "$HOME_SN/state/change-watch/sn1$CORE_ID_SUFFIX/sentry")" = "core-backend" ] \
  || fail "the Sentry project was not recorded as a target"
cp "$HOME_SN/sentry/issues-after.json" "$HOME_SN/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_SN/bin:$PATH" FM_CW_SHIM_LOG="$HOME_SN/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_SN/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_CONFIG_DIR="$HOME_SN/config" FM_CW_SENTRY_DIR="$HOME_SN/sentry" \
  run_cw "$HOME_SN" 1790000300 sample "sn1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
line=$(run_cw "$HOME_SN" 1790000300 verdict "sn1$CORE_ID_SUFFIX")
[ "$line" = "change-watch regressed at +5m on sentry_new_issues (3 vs baseline 0)" ] \
  || fail "new Sentry errors did not regress the watch: $line"
grep -qF "check: change-watch sn1 $CORE_PR sentry_new_issues regressed" "$HOME_SN/state/.wake-queue" \
  || fail "the Sentry regression did not queue a check wake"
pass "new Sentry error and fatal issues regress the release, warnings do not"

# No token: the Sentry target is not registered and the registration says why.
HOME_NT=$(cluster_world nt)
seed_app_pr "$HOME_NT"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_NT/workloads"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_NT/bin:$PATH" FM_CW_SHIM_LOG="$HOME_NT/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_NT/workloads" FM_CW_SHIM_IMAGE="${FM_CW_SHIM_IMAGE:-localhost:30500/muso/core-backend:old-1}" FM_CW_CONFIG_DIR="$HOME_NT/config" \
  FM_CW_SENTRY_VAULT="$HOME_NT/missing-vault.json" FM_CW_SENTRY_DIR='' \
  run_cw "$HOME_NT" 1790000000 register nt1 "$CORE_PR") || fail "register failed: $out"
case "$out" in
  *"sentry unmeasured: no token in $HOME_NT/missing-vault.json"*) ;;
  *) fail "a missing Sentry token was not stated at registration: $out" ;;
esac
[ -e "$HOME_NT/state/change-watch/nt1$CORE_ID_SUFFIX/sentry" ] \
  && fail "a Sentry target was registered without a token"
pass "a missing Sentry token is stated at registration, never a silent zero"

# A repository narrowed to its Sentry project on a home with no token has
# nothing to measure. Registering it anyway arms a watch whose every sample
# reads nothing, so its end-of-schedule verdict would report the release clean.
HOME_SO=$(cluster_world so)
seed_app_pr "$HOME_SO"
printf 'core-backend sentry:core-backend\n' > "$HOME_SO/config/change-watch-repos"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_SO/bin:$PATH" FM_CW_SHIM_LOG="$HOME_SO/shim.log" \
  FM_CW_CONFIG_DIR="$HOME_SO/config" FM_CW_SENTRY_VAULT="$HOME_SO/missing-vault.json" FM_CW_SENTRY_DIR='' \
  run_cw "$HOME_SO" 1790000000 register so1 "$CORE_PR") || fail "register failed: $out"
case "$out" in
  *"nothing measurable for $CORE_PR"*"sentry unmeasured: no token in $HOME_SO/missing-vault.json"*"nothing registered"*) ;;
  *) fail "a repository that resolves only an unreadable Sentry project was armed: $out" ;;
esac
[ -e "$HOME_SO/state/change-watch/so1$CORE_ID_SUFFIX" ] \
  && fail "a watch with nothing to measure created a watch record"
grep -q '"terminal_state": "unmeasurable-with-reason"' "$HOME_SO/state/change-watch/rows/so1$CORE_ID_SUFFIX.json" \
  || fail "an unreadable Sentry project was recorded as a merge with nothing to measure"
run_cw "$HOME_SO" 1790000100 audit 7 >/dev/null \
  && fail "the audit passed a merge whose only target could not be read"
[ "$(grep -c '' "$HOME_SO/arm.log" 2>/dev/null || echo 0)" -eq 0 ] \
  || fail "a watch with nothing to measure was armed"
pass "a repository with nothing measurable registers nothing instead of a clean verdict"

# --- a repository that deploys to a host is watched by its deploy workflow -----
# hydra is deployed by its own workflow, not by a rollout the cluster can see, so
# its release is the workflow run after the merge: a failed run regresses, and a
# run that has not happened yet is awaiting the deploy.

HYDRA_PR='https://github.com/Muso-AI/hydra/pull/1383'
HOME_R=$(new_world r)
mkdir -p "$HOME_R/gh/runs-Muso-AI"
printf 'src/hydra.py\n' > "$HOME_R/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_R/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_R/forge/head-ref"
out=$(CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_R/gh" FM_CW_SENTRY_DIR="$HOME_R/sentry" \
  FM_CW_CONFIG_DIR="$HOME_R/config" FM_CW_WORKLOADS_DIR='' \
  PATH="$HOME_R/bin:$PATH" run_cw "$HOME_R" 1790000000 register r1 "$HYDRA_PR") \
  || fail "hydra register failed: $out"
[ "$(cat "$HOME_R/state/change-watch/r1-1383/runs")" = "$(printf 'Muso-AI/hydra\t.github/workflows/deploy.yml')" ] \
  || fail "the hydra deploy workflow was not recorded as a target: $(cat "$HOME_R/state/change-watch/r1-1383/"* 2>/dev/null | tr '\n' '|')"
[ -e "$HOME_R/state/change-watch/r1-1383/targets" ] && fail "hydra resolved cluster targets it does not have"
CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_R/gh" FM_CW_SENTRY_DIR="$HOME_R/sentry" \
  FM_CW_CONFIG_DIR="$HOME_R/config" PATH="$HOME_R/bin:$PATH" \
  run_cw "$HOME_R" 1790000300 sample r1-1383 300 >/dev/null || true
grep -q "no .github/workflows/deploy.yml run since the merge" "$HOME_R/state/change-watch/r1-1383/read-failures" \
  || fail "a deploy that has not run yet was not recorded as awaiting it"
printf '%s\n' '[{"conclusion":"failure","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":9,"url":"https://github.com/Muso-AI/hydra/actions/runs/9"}]' \
  > "$HOME_R/gh/runs-Muso-AI/hydra-.github_workflows_deploy.yml.json"
CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_R/gh" FM_CW_SENTRY_DIR="$HOME_R/sentry" \
  FM_CW_CONFIG_DIR="$HOME_R/config" PATH="$HOME_R/bin:$PATH" \
  run_cw "$HOME_R" 1790000900 sample r1-1383 900 >/dev/null || true
grep -q 'awaiting the deploy: merge sha unreadable' "$HOME_R/state/change-watch/r1-1383/read-failures" \
  || fail "a run that cannot be tied to the merge was scored anyway: $(cat "$HOME_R/state/change-watch/r1-1383/read-failures" 2>/dev/null)"
[ -z "$(awk -F'\t' '$2 == 900 { print $4 }' "$HOME_R/state/change-watch/r1-1383/samples.log" 2>/dev/null | tail -1)" ] \
  || fail "a failed run of a commit the forge cannot name was read as this release's deploy"
line=$(run_cw "$HOME_R" 1790000900 verdict r1-1383)
case "$line" in
  *regressed*) fail "a run that cannot be proven to carry the merge regressed the release: $line" ;;
esac
pass "a deploy run the forge cannot tie to the merge is awaiting it, never a regression"

# A home's own map line for a workflow-deployed repository keeps its workflow
# path: a `run:` spec uses `#` as its separator, which the comment strip must not
# cut, while a whitespace-preceded comment still goes.
HOME_HM=$(cluster_world hm)
seed_app_pr "$HOME_HM"
printf 'hydra run:Muso-AI/hydra#.github/workflows/release.yml  # this home\047s workflow\n' \
  > "$HOME_HM/config/change-watch-repos"
out=$(CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_HM/gh" FM_CW_SENTRY_DIR="$HOME_HM/sentry" \
  FM_CW_CONFIG_DIR="$HOME_HM/config" FM_CW_WORKLOADS_DIR='' \
  PATH="$HOME_HM/bin:$PATH" run_cw "$HOME_HM" 1790000000 register hm1 "$HYDRA_PR") \
  || fail "mapped hydra register failed: $out"
[ "$(cat "$HOME_HM/state/change-watch/hm1-1383/runs")" = "$(printf 'Muso-AI/hydra\t.github/workflows/release.yml')" ] \
  || fail "a mapped deploy workflow lost its path: $(cat "$HOME_HM/state/change-watch/hm1-1383/runs" 2>/dev/null)"
pass "a map line keeps the workflow path of its run: spec and still drops its comment"

# --- a clean verdict still names what it never measured -----------------------
HOME_GAP=$(cluster_world gap)
seed_app_pr "$HOME_GAP"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_GAP/workloads"
printf '[]\n' > "$HOME_GAP/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_GAP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_GAP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_GAP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_GAP/config" FM_CW_SENTRY_DIR="$HOME_GAP/sentry" \
  run_cw "$HOME_GAP" 1790000000 register gap1 "$CORE_PR" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_GAP/state/gap1.meta"
for offset in 300 900; do
  CW_CLUSTER_DIR='' PATH="$HOME_GAP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_GAP/shim.log" \
    FM_CW_SHIM_WORKLOADS="$HOME_GAP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
    FM_CW_CONFIG_DIR="$HOME_GAP/config" FM_CW_SENTRY_DIR="$HOME_GAP/sentry" \
    run_cw "$HOME_GAP" "$((1790000000 + offset))" sample "gap1$CORE_ID_SUFFIX" "$offset" >/dev/null || true
done
line=$(CW_CLUSTER_DIR='' PATH="$HOME_GAP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_GAP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_GAP/workloads" FM_CW_SHIM_IMAGE="${FM_CW_SHIM_IMAGE:-localhost:30500/muso/core-backend:old-1}" FM_CW_CONFIG_DIR="$HOME_GAP/config" \
  FM_CW_SENTRY_DIR="$HOME_GAP/sentry" run_cw "$HOME_GAP" 1790001000 status "gap1$CORE_ID_SUFFIX")
printf '%s\n' "$line" | grep -q "unmeasured: .*http_5xx_per_min" \
  || fail "status did not name a metric no sample could read: $line"
printf '%s\n' "$line" | grep -q "unmeasured: .*pgbouncer_cl_waiting" \
  || fail "status did not name every unmeasured metric: $line"
pass "a watch reports the metrics it never measured instead of implying they were clean"

# --- the baseline epoch decides which terminations count ----------------------
# One pod read serves the landing gate and every pod-backed metric of a sample,
# so the OOMKilled count cannot come from a row read without an epoch bound. An
# OOMKilled pod that died BEFORE the merge must not be re-read as the release's
# own OOM.
HOME_OOM=$(cluster_world oom)
seed_app_pr "$HOME_OOM"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_OOM/workloads"
printf '[]\n' > "$HOME_OOM/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_OOM/bin:$PATH" FM_CW_SHIM_LOG="$HOME_OOM/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_OOM/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_OOM/config" FM_CW_SENTRY_DIR="$HOME_OOM/sentry" \
  run_cw "$HOME_OOM" 1790000000 register oom1 "$CORE_PR" >/dev/null || fail "register failed"
SAMPLES_OOM="$HOME_OOM/state/change-watch/oom1$CORE_ID_SUFFIX/samples.log"
# The pod died at 1789999000, well before the 1790000000 merge.
CW_CLUSTER_DIR='' PATH="$HOME_OOM/bin:$PATH" FM_CW_SHIM_LOG="$HOME_OOM/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_OOM/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_SHIM_OOM_AT=1789999000 FM_CW_CONFIG_DIR="$HOME_OOM/config" FM_CW_SENTRY_DIR="$HOME_OOM/sentry" \
  run_cw "$HOME_OOM" 1790000300 sample "oom1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
[ "$(awk -F'\t' '$3 == "oomkilled@muso-prod/core-backend-api" { print $4 }' "$SAMPLES_OOM")" = 0 ] \
  || fail "a termination from before the merge was counted as the release's: $(cat "$SAMPLES_OOM")"
line=$(run_cw "$HOME_OOM" 1790000300 verdict "oom1$CORE_ID_SUFFIX")
case "$line" in
  *oomkilled*) fail "a pre-merge OOMKilled regressed the watch: $line" ;;
esac
pass "an OOMKilled termination from before the merge is not the release's"

# The same pod dying AFTER the merge is the release's OOM, which proves the
# epoch filter is still applied rather than ignored.
CW_CLUSTER_DIR='' PATH="$HOME_OOM/bin:$PATH" FM_CW_SHIM_LOG="$HOME_OOM/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_OOM/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_SHIM_OOM_AT=1790000200 FM_CW_CONFIG_DIR="$HOME_OOM/config" FM_CW_SENTRY_DIR="$HOME_OOM/sentry" \
  run_cw "$HOME_OOM" 1790000900 sample "oom1$CORE_ID_SUFFIX" 900 >/dev/null || true
line=$(run_cw "$HOME_OOM" 1790000900 verdict "oom1$CORE_ID_SUFFIX")
[ "$line" = "change-watch regressed at +15m on oomkilled (1 vs baseline 0)" ] \
  || fail "an OOMKilled termination after the merge did not regress the watch: $line"
pass "an OOMKilled termination after the merge regresses the watch"

# --- a spent forge budget is stated as itself --------------------------------
# The armed drive is one long-lived process that takes every sample in-process,
# so a forge budget measured from process start silently disabled the deploy-run
# target after the first minute. It is now measured per sample, and a budget that
# is genuinely spent says so instead of "read exited 1 with no value".
HOME_FB=$(cluster_world fb)
seed_app_pr "$HOME_FB"
printf '%s\n' deadbeef > "$HOME_FB/forge/merge-sha"
cat > "$HOME_FB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":7,"headSha":"deadbeef","url":"https://github.com/Muso-AI/hydra/actions/runs/7"}]'
STUB
chmod +x "$HOME_FB/bin/gh"
FM_CW_GH="$HOME_FB/bin/gh" CW_CLUSTER_DIR='' FM_CW_SENTRY_DIR="$HOME_FB/sentry" \
  FM_CW_CONFIG_DIR="$HOME_FB/config" PATH="$HOME_FB/bin:$PATH" \
  run_cw "$HOME_FB" 1790000000 register fb1 'https://github.com/Muso-AI/hydra/pull/1400' >/dev/null \
  || fail "register failed"
FM_CW_GH="$HOME_FB/bin/gh" CW_CLUSTER_DIR='' FM_CW_SENTRY_DIR="$HOME_FB/sentry" \
  FM_CW_CONFIG_DIR="$HOME_FB/config" PATH="$HOME_FB/bin:$PATH" FM_CW_FORGE_BUDGET=0 \
  run_cw "$HOME_FB" 1790000300 sample fb1-1400 300 >/dev/null || true
grep -q "forge read budget for this sample was already spent" \
  "$HOME_FB/state/change-watch/fb1-1400/read-failures" \
  || fail "a spent forge budget was not stated as the reason: $(cat "$HOME_FB/state/change-watch/fb1-1400/read-failures" 2>/dev/null)"
FM_CW_GH="$HOME_FB/bin/gh" CW_CLUSTER_DIR='' FM_CW_SENTRY_DIR="$HOME_FB/sentry" \
  FM_CW_CONFIG_DIR="$HOME_FB/config" PATH="$HOME_FB/bin:$PATH" FM_CW_FORGE_BUDGET=30 \
  run_cw "$HOME_FB" 1790000900 sample fb1-1400 900 >/dev/null || fail "sample failed"
[ "$(awk -F'\t' '$3 == "deploy_run@run/Muso-AI/hydra#.github/workflows/deploy.yml" && $2 == 900 { print $7 }' \
  "$HOME_FB/state/change-watch/fb1-1400/samples.log")" = 1 ] \
  || fail "the deploy-run target was not scored when the forge budget was available: $(cat "$HOME_FB/state/change-watch/fb1-1400/samples.log")"
pass "the forge budget is per sample and a spent one is stated"

# --- a workflow-deployed repository's Sentry read waits for its deploy run ----
# hydra has no Deployment the cluster can see, so its landing is its own deploy
# workflow's run for this merge. Reading Sentry before that run reports the
# errors of the code the release replaced as the release's own.
HOME_RS=$(new_world rs)
mkdir -p "$HOME_RS/gh/runs-Muso-AI" "$HOME_RS/config" "$HOME_RS/sentry"
printf 'src/hydra.py\n' > "$HOME_RS/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_RS/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_RS/forge/head-ref"
printf '%s\n' deadbeef > "$HOME_RS/forge/merge-sha"
printf 'hydra sentry:hydra run:Muso-AI/hydra#.github/workflows/deploy.yml\n' \
  > "$HOME_RS/config/change-watch-repos"
printf '[]\n' > "$HOME_RS/sentry/issues-hydra.json"
CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_RS/gh" FM_CW_SENTRY_DIR="$HOME_RS/sentry" \
  FM_CW_CONFIG_DIR="$HOME_RS/config" FM_CW_WORKLOADS_DIR='' PATH="$HOME_RS/bin:$PATH" \
  run_cw "$HOME_RS" 1790000000 register rs1 "$HYDRA_PR" >/dev/null || fail "hydra register failed"
[ -f "$HOME_RS/state/change-watch/rs1-1383/sentry" ] \
  || fail "the hydra Sentry target was not registered"
CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_RS/gh" FM_CW_SENTRY_DIR="$HOME_RS/sentry" \
  FM_CW_CONFIG_DIR="$HOME_RS/config" PATH="$HOME_RS/bin:$PATH" \
  run_cw "$HOME_RS" 1790000300 sample rs1-1383 300 >/dev/null || true
awk -F'\t' '$1 == "sentry_new_issues@sentry/hydra" && $2 ~ /awaiting the deploy/ { found = 1 } END { exit(found ? 0 : 1) }' \
  "$HOME_RS/state/change-watch/rs1-1383/read-failures" \
  || fail "a Sentry read before the deploy run was not awaiting the deploy: $(cat "$HOME_RS/state/change-watch/rs1-1383/read-failures" 2>/dev/null)"
[ "$(awk -F'\t' '$3 == "sentry_new_issues@sentry/hydra" { print $7 }' \
  "$HOME_RS/state/change-watch/rs1-1383/samples.log")" = "0" ] \
  || fail "a Sentry read before the deploy run was scored: $(cat "$HOME_RS/state/change-watch/rs1-1383/samples.log" 2>/dev/null)"
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":9,"headSha":"deadbeef","url":"https://github.com/Muso-AI/hydra/actions/runs/9"}]' \
  > "$HOME_RS/gh/runs-Muso-AI/hydra-.github_workflows_deploy.yml.json"
CW_CLUSTER_DIR='' FM_CW_GH_DIR="$HOME_RS/gh" FM_CW_SENTRY_DIR="$HOME_RS/sentry" \
  FM_CW_CONFIG_DIR="$HOME_RS/config" PATH="$HOME_RS/bin:$PATH" \
  run_cw "$HOME_RS" 1790000900 sample rs1-1383 900 >/dev/null || fail "sample failed"
[ "$(awk -F'\t' '$3 == "sentry_new_issues@sentry/hydra" && $2 == 900 { print $4 "/" $7 }' \
  "$HOME_RS/state/change-watch/rs1-1383/samples.log")" = "0/1" ] \
  || fail "the sentry read did not proceed once the deploy run existed: $(cat "$HOME_RS/state/change-watch/rs1-1383/samples.log" 2>/dev/null)"
pass "a workflow-deployed release's Sentry read waits for its own deploy run"

# --- the rollout fingerprint, so an env-only change still opens the gate ------
# A Deployment rollout always mints a new pod-template hash, while an env, routing
# or resource-limit change leaves every image byte-identical. Proving the landing
# by the image alone would hold an H-DevOps manifest change at "awaiting the
# deploy" for the whole watch, which is the completed-unmeasured outcome this
# work exists to remove.
HOME_FP=$(cluster_world fp)
seed_app_pr "$HOME_FP"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_FP/workloads"
printf '[]\n' > "$HOME_FP/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_FP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_FP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_FP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_SHIM_HASH=h1 FM_CW_CONFIG_DIR="$HOME_FP/config" FM_CW_SENTRY_DIR="$HOME_FP/sentry" \
  run_cw "$HOME_FP" 1790000000 register fp1 "$CORE_PR" >/dev/null || fail "register failed"
SAMPLES_FP="$HOME_FP/state/change-watch/fp1$CORE_ID_SUFFIX/samples.log"
# The same image on a new ReplicaSet: the manifest changed an env value only.
CW_CLUSTER_DIR='' PATH="$HOME_FP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_FP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_FP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_SHIM_HASH=h2 FM_CW_CONFIG_DIR="$HOME_FP/config" FM_CW_SENTRY_DIR="$HOME_FP/sentry" \
  run_cw "$HOME_FP" 1790000300 sample "fp1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
awk -F'\t' '$2 == 300 && $7 == 1' "$SAMPLES_FP" | grep -q "restarts@muso-prod/core-backend-api" \
  || fail "an env-only rollout with an unchanged image did not open the landing gate: $(cat "$SAMPLES_FP" 2>/dev/null)"
grep -q "awaiting the deploy" "$HOME_FP/state/change-watch/fp1$CORE_ID_SUFFIX/read-failures" \
  && fail "an env-only rollout was still recorded as awaiting the deploy"
pass "an env-only rollout opens the landing gate with the image unchanged"

# The identical fingerprint is still awaiting, so a sample taken before the
# rollout is never scored as health.
HOME_FP2=$(cluster_world fp2)
seed_app_pr "$HOME_FP2"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_FP2/workloads"
printf '[]\n' > "$HOME_FP2/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_FP2/bin:$PATH" FM_CW_SHIM_LOG="$HOME_FP2/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_FP2/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_SHIM_HASH=h1 FM_CW_CONFIG_DIR="$HOME_FP2/config" FM_CW_SENTRY_DIR="$HOME_FP2/sentry" \
  run_cw "$HOME_FP2" 1790000000 register fp2 "$CORE_PR" >/dev/null || fail "register failed"
CW_CLUSTER_DIR='' PATH="$HOME_FP2/bin:$PATH" FM_CW_SHIM_LOG="$HOME_FP2/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_FP2/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_SHIM_HASH=h1 FM_CW_CONFIG_DIR="$HOME_FP2/config" FM_CW_SENTRY_DIR="$HOME_FP2/sentry" \
  run_cw "$HOME_FP2" 1790000300 sample "fp2$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
[ "$(awk -F'\t' '$7 == 1' "$HOME_FP2/state/change-watch/fp2$CORE_ID_SUFFIX/samples.log" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "an unchanged rollout fingerprint was scored as health"
grep -q "awaiting the deploy" "$HOME_FP2/state/change-watch/fp2$CORE_ID_SUFFIX/read-failures" \
  || fail "an unchanged fingerprint was not recorded as awaiting the deploy"
awk -F'\t' '{ exit !($2 != "" && $3 != "") }' "$HOME_FP2/state/change-watch/fp2$CORE_ID_SUFFIX/images-at-register" \
  || fail "registration recorded images without their rollout fingerprint: $(cat "$HOME_FP2/state/change-watch/fp2$CORE_ID_SUFFIX/images-at-register")"
pass "an unchanged rollout fingerprint stays awaiting the deploy"

# --- a spent budget bounds the pod reads, never a network read ----------------
# cw_sample_blocker used to ask for the target's landing fingerprint first, so a
# sample that had no budget left still paid a pod read per K8s metric. The budget
# is now checked before that pod read and stops that read only: the Sentry read
# goes over the network under its own bound, so a budget the pod reads spent
# never costs the watch its error signal.
HOME_BUD=$(cluster_world bud)
seed_app_pr "$HOME_BUD"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_BUD/workloads"
printf '[]\n' > "$HOME_BUD/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_BUD/bin:$PATH" FM_CW_SHIM_LOG="$HOME_BUD/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_BUD/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_BUD/config" FM_CW_SENTRY_DIR="$HOME_BUD/sentry" \
  run_cw "$HOME_BUD" 1790000000 register bud1 "$CORE_PR" >/dev/null || fail "register failed"
: > "$HOME_BUD/shim.log"
CW_CLUSTER_DIR='' PATH="$HOME_BUD/bin:$PATH" FM_CW_SHIM_LOG="$HOME_BUD/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_BUD/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_CONFIG_DIR="$HOME_BUD/config" FM_CW_SENTRY_DIR="$HOME_BUD/sentry" FM_CW_SAMPLE_DEADLINE=0 \
  run_cw "$HOME_BUD" 1790000300 sample "bud1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
[ "$(grep -c 'get pods' "$HOME_BUD/shim.log")" -eq 0 ] \
  || fail "a sample with no budget left still read the pods: $(cat "$HOME_BUD/shim.log")"
REASONS_BUD="$HOME_BUD/state/change-watch/bud1$CORE_ID_SUFFIX/read-failures"
[ "$(grep -c '' "$REASONS_BUD")" -ge 6 ] \
  || fail "a spent sample did not record the metrics it skipped: $(cat "$REASONS_BUD")"
awk -F'\t' '$1 ~ /^(sentry_new_issues|deploy_run)@/ { next }
  $2 ~ /^sample budget spent before this metric was read$/ { next }
  { print; exit 1 }' "$REASONS_BUD" \
  || fail "a spent sample blamed the landing read instead of the budget: $(cat "$REASONS_BUD")"
[ "$(awk -F'\t' '$3 == "sentry_new_issues@sentry/core-backend" && $2 == 300 { print $4 "/" $7 }' \
  "$HOME_BUD/state/change-watch/bud1$CORE_ID_SUFFIX/samples.log")" = "0/1" ] \
  || fail "a spent sample budget cost the watch its Sentry read: $(cat "$HOME_BUD/state/change-watch/bud1$CORE_ID_SUFFIX/samples.log")"
pass "a spent sample budget costs no pod read, states itself, and still reads Sentry"

HOME_PF=$(cluster_world pf)
seed_app_pr "$HOME_PF"
{
  printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n'
  printf 'muso-prod\tcore-backend-worker\t3\tlocalhost:30500/muso/core-backend:old-1\n'
} > "$HOME_PF/workloads"
printf '[]\n' > "$HOME_PF/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_PF/bin:$PATH" FM_CW_SHIM_LOG="$HOME_PF/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_PF/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_PF/config" FM_CW_SENTRY_DIR="$HOME_PF/sentry" \
  run_cw "$HOME_PF" 1790000000 register pf1 "$CORE_PR" >/dev/null || fail "register failed"
: > "$HOME_PF/shim.log"
CW_CLUSTER_DIR='' PATH="$HOME_PF/bin:$PATH" FM_CW_SHIM_LOG="$HOME_PF/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_PF/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_CONFIG_DIR="$HOME_PF/config" FM_CW_SENTRY_DIR="$HOME_PF/sentry" FM_CW_SHIM_PODS_FAIL=1 \
  run_cw "$HOME_PF" 1790000300 sample "pf1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
[ "$(grep -c 'get pods' "$HOME_PF/shim.log")" -eq 2 ] \
  || fail "a failing pod read was repeated per metric: $(grep -c 'get pods' "$HOME_PF/shim.log") reads: $(cat "$HOME_PF/shim.log")"
grep -q "deploy landing unreadable" "$HOME_PF/state/change-watch/pf1$CORE_ID_SUFFIX/read-failures" \
  || fail "an unreadable landing was not stated as the reason: $(cat "$HOME_PF/state/change-watch/pf1$CORE_ID_SUFFIX/read-failures")"
pass "a target whose pods cannot be read is attempted once per sample"

# --- an unreadable image inventory is not a repository that deploys nothing ----
# The target set of an application release comes from a live inventory. When that
# read fails, registration says so instead of claiming the merge touched no
# deployable service.
HOME_INV=$(cluster_world inv)
seed_app_pr "$HOME_INV"
INV_PR='https://github.com/Muso-AI/industry-data-processing/pull/620'
out=$(CW_CLUSTER_DIR='' PATH="$HOME_INV/bin:$PATH" FM_CW_SHIM_LOG="$HOME_INV/shim.log" \
  FM_CW_CONFIG_DIR="$HOME_INV/config" FM_CW_SENTRY_DIR="$HOME_INV/sentry" \
  run_cw "$HOME_INV" 1790000000 register inv1 "$INV_PR") || fail "register failed: $out"
case "$out" in
  *"could not read the image inventory for $INV_PR"*"nothing registered"*) ;;
  *) fail "an unreadable image inventory was reported as a repository that deploys nothing: $out" ;;
esac
[ -e "$HOME_INV/state/change-watch/inv1-620" ] \
  && fail "a watch with an unreadable inventory was armed"
grep -q '"terminal_state": "unmeasurable-with-reason"' "$HOME_INV/state/change-watch/rows/inv1-620.json" \
  || fail "an unreadable image inventory was recorded as a merge with nothing to measure"
run_cw "$HOME_INV" 1790000100 audit 7 >/dev/null \
  && fail "the audit passed a merge whose image inventory could not be read"
pass "an unreadable image inventory is stated instead of read as no deployable service"

# --- a status line states a rollout it could never prove ----------------------
# When the pre-merge fingerprint cannot be read the target is still measured, and
# the reader of the outcome must be able to tell that watch from one whose
# rollout was proven.
HOME_UP=$(cluster_world up)
seed_app_pr "$HOME_UP"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$HOME_UP/workloads"
printf '[]\n' > "$HOME_UP/sentry/issues-core-backend.json"
CW_CLUSTER_DIR='' PATH="$HOME_UP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_UP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_UP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:old-1' \
  FM_CW_CONFIG_DIR="$HOME_UP/config" FM_CW_SENTRY_DIR="$HOME_UP/sentry" FM_CW_SHIM_PODS_FAIL=1 \
  run_cw "$HOME_UP" 1790000000 register up1 "$CORE_PR" >/dev/null || fail "register failed"
CW_CLUSTER_DIR='' PATH="$HOME_UP/bin:$PATH" FM_CW_SHIM_LOG="$HOME_UP/shim.log" \
  FM_CW_SHIM_WORKLOADS="$HOME_UP/workloads" FM_CW_SHIM_IMAGE='localhost:30500/muso/core-backend:new-2' \
  FM_CW_CONFIG_DIR="$HOME_UP/config" FM_CW_SENTRY_DIR="$HOME_UP/sentry" \
  run_cw "$HOME_UP" 1790000300 sample "up1$CORE_ID_SUFFIX" 300 >/dev/null || fail "sample failed"
line=$(run_cw "$HOME_UP" 1790000300 status "up1$CORE_ID_SUFFIX")
printf '%s\n' "$line" | grep -q "rollout never proven: muso-prod/core-backend-api" \
  || fail "status did not state that the rollout was never proven: $line"
pass "a status line names every target whose rollout was never proven"

# --- the clean wiki note names only what the watch measured --------------------
# A deploy-workflow or Sentry-only watch reads no Deployment at all, so its durable
# note must not claim a 5xx, restart, or pool-wait result it never had.
HOME_WN=$(new_world wn)
mkdir -p "$HOME_WN/bin" "$HOME_WN/gh/runs-Muso-AI" "$HOME_WN/state"
cat > "$HOME_WN/bin/wiki-retro" <<'STUB'
#!/usr/bin/env bash
{ printf 'args: %s\n' "$*"; cat; } >> "$FM_CW_WIKI_LOG"
STUB
chmod +x "$HOME_WN/bin/wiki-retro"
printf 'src/hydra.py\n' > "$HOME_WN/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_WN/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_WN/forge/head-ref"
printf '%s\n' deadbeef > "$HOME_WN/forge/merge-sha"
env FM_HOME="$HOME_WN" FM_STATE_OVERRIDE="$HOME_WN/state" FM_CW_NOW=1790000000 \
  FM_CW_FORGE_DIR="$HOME_WN/forge" FM_CW_CLUSTER_DIR='' FM_CW_WORKLOADS_DIR='' \
  FM_CW_GH_DIR="$HOME_WN/gh" FM_CW_SENTRY_DIR="$HOME_WN/sentry" \
  FM_CW_CONFIG_DIR="$HOME_WN/config" FM_CW_ARM_CMD="$HOME_WN/arm.sh" \
  FM_CW_ARM_LOG="$HOME_WN/arm.log" FM_CW_SEND_CMD="$HOME_WN/send.sh" \
  FM_CW_SEND_LOG="$HOME_WN/send.log" PATH="$HOME_WN/bin:$PATH" \
  "$CW" register wn1 'https://github.com/Muso-AI/hydra/pull/1383' >/dev/null \
  || fail "hydra register failed"
printf 'kind=crewmate\n' > "$HOME_WN/state/wn1.meta"
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":9,"headSha":"deadbeef","url":"https://github.com/Muso-AI/hydra/actions/runs/9"}]' \
  > "$HOME_WN/gh/runs-Muso-AI/hydra-.github_workflows_deploy.yml.json"
FM_CW_WIKI_LOG="$HOME_WN/wiki.log" env FM_HOME="$HOME_WN" FM_STATE_OVERRIDE="$HOME_WN/state" \
  FM_CW_NOW=1790044000 FM_CW_FORGE_DIR="$HOME_WN/forge" FM_CW_CLUSTER_DIR='' \
  FM_CW_WORKLOADS_DIR='' FM_CW_GH_DIR="$HOME_WN/gh" FM_CW_SENTRY_DIR="$HOME_WN/sentry" \
  FM_CW_CONFIG_DIR="$HOME_WN/config" FM_CW_ARM_CMD="$HOME_WN/arm.sh" \
  FM_CW_ARM_LOG="$HOME_WN/arm.log" FM_CW_SEND_CMD="$HOME_WN/send.sh" \
  FM_CW_SEND_LOG="$HOME_WN/send.log" FM_CW_SLEEP_CMD=true PATH="$HOME_WN/bin:$PATH" \
  "$CW" drive wn1-1383 >/dev/null || fail "clean deploy-workflow drive failed"
[ "$(run_cw "$HOME_WN" 1790044000 verdict wn1-1383)" = "change-watch clean" ] \
  || fail "a successful deploy run did not complete clean: $(run_cw "$HOME_WN" 1790044000 verdict wn1-1383)"
[ -f "$HOME_WN/wiki.log" ] || fail "a clean watch recorded no wiki note"
grep -q "no regression on deploy_run" "$HOME_WN/wiki.log" \
  || fail "the wiki note did not name the metric it measured: $(cat "$HOME_WN/wiki.log")"
grep -q "run/Muso-AI/hydra" "$HOME_WN/wiki.log" \
  || fail "the wiki note did not name the target it watched: $(cat "$HOME_WN/wiki.log")"
grep -qE "5xx|OOMKilled|pool-wait" "$HOME_WN/wiki.log" \
  && fail "the wiki note claimed metrics this watch never read: $(cat "$HOME_WN/wiki.log")"
pass "a clean wiki note names only the metrics and targets the watch measured"

# ---------------------------------------------------------------------------
# The beta stage: a merged change is read against the pre-production copy of the
# service that serves it before any production target is read.
# ---------------------------------------------------------------------------

# beta_before_prod <trace-file> prints ok when every beta read happened before the
# first production read, or the reason the ordering was broken.
beta_before_prod() {  # <trace-file>
  awk -F'\t' '
    $1 == "prod" && !seen_prod { seen_prod = NR }
    $1 == "beta" {
      seen_beta = 1
      if (seen_prod) {
        printf "beta read after the production read on line %d: %s %s\n", seen_prod, $2, $3
        bad = 1
        exit
      }
    }
    END {
      if (bad) exit
      if (!seen_beta) print "no beta read was made at all"
      else if (!seen_prod) print "no production read was made at all, so the ordering proves nothing"
      else print "ok"
    }
  ' "$1"
}

# seed_beta_world <name> prints a home whose merged PR is a web-credits-next
# route change, with one production Deployment of that image, a kubectl shim
# whose pod-template hash is the beta target's rollout fingerprint, and a
# rollout script that flips that hash the way a real deploy would.
seed_beta_world() {
  local home
  home=$(cluster_world "$1")
  mkdir -p "$home/workloads"
  printf 'src/routes/credits.ts\n' > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeef > "$home/forge/head-ref"
  : > "$home/forge/diff.txt"
  printf 'muso-prod\tcredits-gate\t2\tregistry.muso.ai/muso/web-credits-next:1.2.3\n' \
    > "$home/workloads/workloads"
  # The beta target runs the pre-merge pods until the rollout lands.
  printf 'h1\n' > "$home/hash"
  cat > "$home/rollout.sh" <<'SH'
#!/usr/bin/env bash
printf 'h2\n' > "$FM_CW_SHIM_HASH_FILE"
SH
  chmod +x "$home/rollout.sh"
  printf '%s\n' "$home"
}

# run_beta <home> <now> <args...> runs the watch with its metric series seeded
# and a kubectl shim answering the beta target's pod fingerprint, with the
# rollout script standing in for the pause between fingerprint reads.
run_beta() {
  local home=$1 now=$2
  shift 2
  CW_SLEEP="$home/rollout.sh" \
  PATH="$home/bin:$PATH" FM_CW_SHIM_LOG="$home/shim.log" \
  FM_CW_SHIM_WORKLOADS="$home/workloads/workloads" \
  FM_CW_SHIM_IMAGE='registry.muso.ai/muso/web-credits-next:1.2.3' \
  FM_CW_SHIM_HASH_FILE="$home/hash" \
  FM_CW_WORKLOADS_DIR="$home/workloads" \
  FM_CW_BETA_WAIT_ATTEMPTS="${BETA_ATTEMPTS:-5}" \
  run_cw "$home" "$now" "$@"
}

# seed_beta_series <home> <metric> <baseline> <sample> seeds the beta target's
# pre-rollout reading and its post-rollout reading.
seed_beta_series() {
  printf '%s\n' "$3" > "$1/cluster/$2.muso-dev_credits-gate.baseline"
  printf '%s\n' "$4" > "$1/cluster/$2.muso-dev_credits-gate.sample"
}

# seed_clean_beta <home> seeds a beta target that is healthy before and after.
seed_clean_beta() {
  seed_beta_series "$1" restarts 0 0
  seed_beta_series "$1" oomkilled 0 0
  seed_beta_series "$1" rss_ratio 0.4 0.4
  seed_beta_series "$1" http_5xx_per_min 0 0
  seed_beta_series "$1" p95_ms 100 100
}

# seed_beta_regression <home> <metric> <baseline> <sample> seeds a healthy beta
# target whose one metric moved after the rollout.
seed_beta_regression() {
  seed_clean_beta "$1"
  seed_beta_series "$1" "$2" "$3" "$4"
}

# (a) A web-credits-next route change is read in beta before any production
# target is read, and the ordering is asserted from the read record rather than
# inferred from the outcome.
HOME_B1=$(seed_beta_world b1)
seed_clean_beta "$HOME_B1"
out=$(run_beta "$HOME_B1" 1790000000 register b1 \
  'https://github.com/Muso-AI/web-credits-next/pull/77') || fail "beta register failed"

case "$out" in
  *"registered b1-77"*"beta: beta clean: 5 metric(s) read on muso-dev/credits-gate, none crossed its bar"*)
    pass "a web-credits-next route change records a healthy beta reading" ;;
  *) fail "unexpected registration line: $out" ;;
esac

[ -f "$HOME_B1/trace" ] || fail "no metric read was traced"
[ "$(beta_before_prod "$HOME_B1/trace")" = ok ] \
  || fail "the beta stage did not read before production: $(beta_before_prod "$HOME_B1/trace")"
pass "a web-credits-next route change is read in beta before any production target"

[ "$(head -1 "$HOME_B1/trace" | cut -f1)" = beta ] \
  || fail "the first read was not a beta read: $(head -1 "$HOME_B1/trace")"
[ "$(head -1 "$HOME_B1/trace" | cut -f3)" = 'muso-dev/credits-gate' ] \
  || fail "the first beta read was not muso-dev/credits-gate: $(head -1 "$HOME_B1/trace")"
pass "the first read of the whole registration is the beta target muso-dev/credits-gate"

grep -q '^prod	' "$HOME_B1/trace" \
  || fail "no production target was read at all, so the ordering proves nothing"
pass "the production watch still reads its own targets after the beta stage"

BETA_B1="$HOME_B1/state/change-watch/b1-77/beta"
[ -f "$BETA_B1" ] || fail "the beta stage recorded no reading"
[ "$(awk -F'\t' '$1 == "verdict" { print $2 }' "$BETA_B1")" \
  = 'beta clean: 5 metric(s) read on muso-dev/credits-gate, none crossed its bar' ] \
  || fail "unexpected beta verdict: $(cat "$BETA_B1")"
pass "a healthy beta target records a beta clean verdict naming what it read"

# The stage proves the rollout instead of assuming it: it re-reads the beta
# target's fingerprint until the merged sha arrives.
[ "$(grep -c 'get pods' "$HOME_B1/shim.log" 2>/dev/null || printf 0)" -ge 3 ] \
  || fail "the beta stage did not re-read the pod fingerprint: $(cat "$HOME_B1/shim.log")"
pass "the beta stage re-reads the pod fingerprint until the rollout lands"

# (b) A change touching no beta-served path completes clean with the reason in
# the output, never a silent pass.
HOME_B2=$(new_world b2)
seed_pr "$HOME_B2" "$MANIFEST" /dev/null "src/routes/feed.ts"
out=$(run_cw "$HOME_B2" 1790000000 register b2 "$PR_URL") || fail "no-beta-path register failed"
case "$out" in
  *"beta clean: nothing to measure: no changed path is served by a beta target"*"web-credits-next -> muso-dev/credits-gate"*)
    pass "a change touching no beta-served path completes clean with the reason stated" ;;
  *) fail "nothing-beta-served did not state its reason: $out" ;;
esac
ROW_B2="$HOME_B2/state/change-watch/rows/b2-3317.json"
[ -f "$ROW_B2" ] || fail "a change with nothing deployable recorded no durable row"
grep -q 'nothing to measure: no changed path is served by a beta target' "$ROW_B2" \
  || fail "the durable row did not carry the beta reason: $(cat "$ROW_B2")"
pass "the reason a change measured nothing beta-served is durable, not only printed"

# (c) A beta failure is labelled beta, and it never reaches a production target.
HOME_B3=$(seed_beta_world b3)
seed_beta_regression "$HOME_B3" http_5xx_per_min 0 50
out=$(run_beta "$HOME_B3" 1790000000 register b3 \
  'https://github.com/Muso-AI/web-credits-next/pull/78') || fail "beta-failure register failed"

case "$out" in
  *"beta stage failed: beta regressed on http_5xx_per_min (50 vs baseline 0) at muso-dev/credits-gate"*)
    pass "a beta regression is reported as a beta failure" ;;
  *) fail "a beta regression was not reported as a beta failure: $out" ;;
esac
grep -q '^prod	' "$HOME_B3/trace" 2>/dev/null \
  && fail "a beta failure read a production target: $(cat "$HOME_B3/trace")"
pass "a beta failure reads no production target at all"
[ -s "$HOME_B3/arm.log" ] && fail "a beta failure armed a production watch: $(cat "$HOME_B3/arm.log")"
pass "a beta failure arms no production watch"

verdict=$(run_beta "$HOME_B3" 1790000000 verdict b3-78)
[ "$verdict" = 'change-watch beta regressed on http_5xx_per_min (50 vs baseline 0) at muso-dev/credits-gate' ] \
  || fail "the verdict did not read as a beta failure: $verdict"
run_beta "$HOME_B3" 1790000000 verdict b3-78 >/dev/null 2>&1 \
  && fail "a beta failure exited zero from verdict"
pass "the verdict states the beta failure and exits non-zero"

status=$(run_beta "$HOME_B3" 1790000000 status b3-78)
case "$status" in
  *"beta: beta regressed on http_5xx_per_min"*) ;;
  *) fail "status did not state the beta failure: $status" ;;
esac
case "$status" in
  *prod*) fail "status reported the beta failure as a production result: $status" ;;
esac
pass "status states the beta failure and never as a production result"

grep -qF "check: change-watch b3 https://github.com/Muso-AI/web-credits-next/pull/78 beta http_5xx_per_min regressed" \
  "$HOME_B3/state/.wake-queue" \
  || fail "no beta wake was queued for the beta failure: $(cat "$HOME_B3/state/.wake-queue" 2>/dev/null)"
pass "a beta failure queues its own beta wake"
steer=$(cat "$HOME_B3/send.log" 2>/dev/null || true)
case "$steer" in
  *"failed the beta stage: beta regressed on http_5xx_per_min"*) ;;
  *) fail "the lane was not steered about the beta failure: $steer" ;;
esac
case "$steer" in
  *"production watch was not armed"*) ;;
  *) fail "the steer did not say the production watch was not armed: $steer" ;;
esac
pass "the lane is steered with the beta failure and that no production watch was armed"

# A rollout that never lands is stated, never read as a pass, and the
# production watch still arms.
HOME_B5=$(seed_beta_world b5)
seed_clean_beta "$HOME_B5"
printf '#!/usr/bin/env bash\n:\n' > "$HOME_B5/rollout.sh"
out=$(run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/80') || fail "unlanded-beta register failed"
case "$out" in
  *"beta: beta unmeasured: awaiting the deploy:"*)
    pass "a beta rollout that has not landed is stated as unmeasured" ;;
  *) fail "an unlanded beta rollout was read anyway: $out" ;;
esac
case "$out" in
  *"beta clean"*) fail "an unlanded beta rollout was reported clean: $out" ;;
esac
[ "$(awk -F'\t' '$1 == "reading" && $4 != "" { n++ } END { print n + 0 }' \
  "$HOME_B5/state/change-watch/b5-80/beta")" = 0 ] \
  || fail "a beta reading was scored before the rollout landed"
pass "an unlanded beta rollout scores nothing"
[ -s "$HOME_B5/arm.log" ] || fail "an unlanded beta rollout stopped the production watch from arming"
pass "an unlanded beta rollout still arms the production watch"
# The wait can never outlive the watcher beacon grace, so a configured bound
# above a minute is clamped: register also runs in process inside the watcher.
out=$(BETA_ATTEMPTS=400 run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/85') || fail "clamped-wait register failed"
case "$out" in
  *"awaiting the deploy:"*"after 4 attempt(s)"*)
    pass "a beta wait configured above a minute is clamped to the four-attempt bound" ;;
  *) fail "the beta wait was not clamped to a minute: $out" ;;
esac
out=$(FM_CW_BETA_POLL_SECONDS=600 BETA_ATTEMPTS=10 run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/86') || fail "clamped-poll register failed"
case "$out" in
  *"awaiting the deploy:"*"after 1 attempt(s)"*)
    pass "a beta poll longer than the ceiling is clamped so the whole wait stays inside it" ;;
  *) fail "a long beta poll escaped the wait ceiling: $out" ;;
esac
# A configured bound that is not a usable count cannot opt out of the ceiling.
out=$(BETA_ATTEMPTS=4x run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/87') || fail "non-numeric-bound register failed"
case "$out" in
  *"awaiting the deploy:"*"after 4 attempt(s)"*)
    pass "a non-numeric beta wait bound falls back to the default" ;;
  *) fail "a non-numeric beta wait bound was honoured: $out" ;;
esac
out=$(FM_CW_BETA_POLL_SECONDS=0 BETA_ATTEMPTS=400 run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/88') || fail "zero-poll register failed"
case "$out" in
  *"awaiting the deploy:"*"after 60 attempt(s)"*)
    pass "a zero beta poll still bounds the wait by the ceiling" ;;
  *) fail "a zero beta poll left the beta wait unbounded: $out" ;;
esac
# A numeral with a leading zero is a decimal count, not an octal literal: it must
# neither abort the script nor escape the ceiling.
out=$(FM_CW_BETA_POLL_SECONDS=08 BETA_ATTEMPTS=400 run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/90') || fail "leading-zero poll register failed"
case "$out" in
  *"awaiting the deploy:"*"after 7 attempt(s)"*)
    pass "a leading-zero beta poll is read as decimal and still bounded" ;;
  *) fail "a leading-zero beta poll broke the wait bound: $out" ;;
esac
# A count wider than the ceiling cannot be a usable bound.
out=$(BETA_ATTEMPTS=99999999999999999999 run_beta "$HOME_B5" 1790000000 register b5 \
  'https://github.com/Muso-AI/web-credits-next/pull/91') || fail "overflowing-bound register failed"
case "$out" in
  *"awaiting the deploy:"*"after 4 attempt(s)"*)
    pass "an overflowing beta wait bound is clamped" ;;
  *) fail "an overflowing beta wait bound escaped the ceiling: $out" ;;
esac
# A beta fingerprint that could not be read is no proof the merged sha landed,
# so the stage states an unmeasured beta instead of reading the pre-change pods.
HOME_B9=$(seed_beta_world b9)
seed_clean_beta "$HOME_B9"
out=$(FM_CW_SHIM_PODS_FAIL=1 run_beta "$HOME_B9" 1790000000 register b9 \
  'https://github.com/Muso-AI/web-credits-next/pull/84') || fail "unreadable-fingerprint register failed"
case "$out" in
  *"beta: beta unmeasured: deploy landing unreadable:"*)
    pass "a beta fingerprint that cannot be read is stated as unmeasured" ;;
  *"beta clean"*) fail "an unproven beta rollout was read as clean: $out" ;;
  *) fail "an unreadable beta fingerprint was not stated: $out" ;;
esac

# The beta reason is durable, not only printed: a merge that DOES have production
# targets but no beta-served path records the reason in its registration row and
# again in its terminal rewrite, so the row alone states why nothing was measured
# in beta.
HOME_B10=$(new_world b10)
seed_pr "$HOME_B10" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_B10" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_B10" 1790000000 register b10 "$PR_URL" >/dev/null \
  || fail "production-with-no-beta register failed"
ROW_B10="$HOME_B10/state/change-watch/rows/b10-3317.json"
grep -q '"terminal_state": "open"' "$ROW_B10" \
  || fail "a merge with production targets did not record an open row: $(cat "$ROW_B10")"
grep -q 'nothing to measure: no changed path is served by a beta target' "$ROW_B10" \
  || fail "the open row did not carry the beta reason: $(cat "$ROW_B10")"
run_cw "$HOME_B10" 1790044000 drive b10-3317 >/dev/null || true
grep -q '"terminal_state": "unmeasurable-with-reason"' "$ROW_B10" \
  || fail "the drive did not rewrite the row's terminal state: $(cat "$ROW_B10")"
grep -q 'nothing to measure: no changed path is served by a beta target' "$ROW_B10" \
  || fail "the terminal row dropped the beta reason: $(cat "$ROW_B10")"
pass "the beta reason is durable in both the registration and terminal row"

# A beta target already above the absolute bar but unchanged is clean: the
# verdict is relative to the beta baseline, never to an absolute bar.
HOME_B6=$(seed_beta_world b6)
seed_beta_series "$HOME_B6" restarts 0 0
seed_beta_series "$HOME_B6" oomkilled 2 2
seed_beta_series "$HOME_B6" rss_ratio 0.86 0.86
seed_beta_series "$HOME_B6" http_5xx_per_min 40 40
seed_beta_series "$HOME_B6" p95_ms 900 900
out=$(run_beta "$HOME_B6" 1790000000 register b6 \
  'https://github.com/Muso-AI/web-credits-next/pull/81') || fail "unchanged-baseline register failed"
case "$out" in
  *"beta: beta clean: 5 metric(s) read on muso-dev/credits-gate"*)
    pass "a beta target already above the absolute bar but unchanged is clean" ;;
  *) fail "the beta verdict used an absolute bar instead of the beta baseline: $out" ;;
esac

# Every beta target a change is served by keeps its own fingerprint and
# baseline, so a second matching key cannot displace the first target's records.
HOME_B8=$(seed_beta_world b8)
seed_clean_beta "$HOME_B8"
printf 'src muso-dev/web\n' > "$HOME_B8/config/change-watch-beta"
printf 'muso-dev\tweb\t2\tregistry.muso.ai/muso/web:1.0.0\n' >> "$HOME_B8/workloads/workloads"
for m in restarts oomkilled rss_ratio http_5xx_per_min p95_ms; do
  case "$m" in
    rss_ratio) b=0.4; v=0.4 ;;
    p95_ms) b=100; v=100 ;;
    *) b=0; v=0 ;;
  esac
  printf '%s\n' "$b" > "$HOME_B8/cluster/$m.muso-dev_web.baseline"
  printf '%s\n' "$v" > "$HOME_B8/cluster/$m.muso-dev_web.sample"
done
out=$(run_beta "$HOME_B8" 1790000000 register b8 \
  'https://github.com/Muso-AI/web-credits-next/pull/83') || fail "multi-target beta register failed"
case "$out" in
  *"beta: beta clean: 10 metric(s) read on muso-dev/credits-gate, muso-dev/web"*)
    pass "every matching beta target is read, not only the last one" ;;
  *) fail "a matching beta target lost its baseline or fingerprint: $out" ;;
esac
[ "$(awk -F'\t' 'NF { n++ } END { print n + 0 }' "$HOME_B8/state/change-watch/b8-83/beta-landed")" = 2 ] \
  || fail "the beta fingerprints overwrote one another: $(cat "$HOME_B8/state/change-watch/b8-83/beta-landed")"
[ "$(awk -F'\t' 'NF { n++ } END { print n + 0 }' "$HOME_B8/state/change-watch/b8-83/beta-baseline")" = 10 ] \
  || fail "the beta baselines overwrote one another: $(cat "$HOME_B8/state/change-watch/b8-83/beta-baseline")"
pass "each matched beta target keeps its own fingerprint and baseline"

# Two keys can name the same beta target: here the built-in repository key and a
# home path prefix both resolve to muso-dev/credits-gate. The target is one
# deployment to fingerprint, wait for, and read, so it is read once.
HOME_B11=$(seed_beta_world b11)
seed_clean_beta "$HOME_B11"
printf 'src/routes/credits muso-dev/credits-gate\n' > "$HOME_B11/config/change-watch-beta"
out=$(run_beta "$HOME_B11" 1790000000 register b11 \
  'https://github.com/Muso-AI/web-credits-next/pull/84') || fail "same-target beta register failed"
case "$out" in
  *"beta: beta clean: 5 metric(s) read on muso-dev/credits-gate, none crossed its bar"*)
    pass "two keys resolving to one beta target read it once" ;;
  *) fail "a beta target named by two keys was read twice: $out" ;;
esac
[ "$(awk -F'\t' 'NF { n++ } END { print n + 0 }' "$HOME_B11/state/change-watch/b11-84/beta-landed")" = 1 ] \
  || fail "one beta target was fingerprinted more than once: $(cat "$HOME_B11/state/change-watch/b11-84/beta-landed")"
[ "$(awk -F'\t' 'NF { n++ } END { print n + 0 }' "$HOME_B11/state/change-watch/b11-84/beta-baseline")" = 5 ] \
  || fail "one beta target kept more than one baseline: $(cat "$HOME_B11/state/change-watch/b11-84/beta-baseline")"
pass "one beta target keeps exactly one fingerprint and baseline"

# The beta map is hand-edited, so any whitespace separates a key from its target:
# a tab-separated entry resolves the target it names instead of silently
# completing clean with nothing to measure.
HOME_B12=$(seed_beta_world b12)
seed_clean_beta "$HOME_B12"
printf 'web-credits-next\tmuso-dev/credits-gate\n' > "$HOME_B12/config/change-watch-beta"
out=$(run_beta "$HOME_B12" 1790000000 register b12 \
  'https://github.com/Muso-AI/web-credits-next/pull/89') || fail "tab-map beta register failed"
case "$out" in
  *"beta: beta clean: 5 metric(s) read on muso-dev/credits-gate, none crossed its bar"*)
    pass "a tab-separated beta map entry resolves its target" ;;
  *) fail "a tab-separated beta map entry measured nothing: $out" ;;
esac

# A metric with no readable baseline is unmeasured, never scored against an
# absolute bar, because an absolute bar is not evidence about the change.
HOME_B7=$(seed_beta_world b7)
seed_clean_beta "$HOME_B7"
rm -f "$HOME_B7/cluster/p95_ms.muso-dev_credits-gate.baseline"
out=$(run_beta "$HOME_B7" 1790000000 register b7 \
  'https://github.com/Muso-AI/web-credits-next/pull/82') || fail "no-baseline register failed"
case "$out" in
  *"beta: beta clean: 4 of 5 metric(s) read on muso-dev/credits-gate, none crossed its bar; unmeasured: p95_ms"*)
    pass "a metric with no readable beta baseline is unmeasured, not scored absolutely" ;;
  *) fail "a metric with no beta baseline was scored anyway: $out" ;;
esac

BETA_B7="$HOME_B7/state/change-watch/b7-82/beta"
[ "$(awk -F'\t' '$1 == "reading" && $2 == "p95_ms" { print $4 }' "$BETA_B7")" = '' ] \
  || fail "the metric with no baseline was given a value anyway"
grep -q 'no beta baseline was readable' "$BETA_B7" \
  || fail "the record did not state why the metric could not be scored"
pass "the record states why a metric with no beta baseline could not be scored"

# --- a Deployment is measured by its own selector ------------------------------
# The watch used to ask the cluster for pods labelled app=<name>. A Deployment
# labelled app.kubernetes.io/name=<name> matched nothing, the log read came back
# empty, and the watch reported an unmeasured rollout - a monitoring hole that
# looked exactly like a nuisance notice. 49 of the 266 Deployments in production
# select on app.kubernetes.io/name, so the selector is read from the Deployment
# itself. The shim below answers only the selector it is told to expect, so the
# assumed app=<name> read returns nothing: this case fails before the fix and
# passes after it.

# selector_world <name> <selector> prints a home whose kubectl answers the
# Deployment's own selector read and only the pods that carry <selector>.
selector_world() {
  local home
  home=$(new_world "$1")
  mkdir -p "$home/bin" "$home/config" "$home/sentry"
  printf '%s\n' "$2" > "$home/selector"
  cat > "$home/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\t%s\n' "${KUBECONFIG:-}" "$*" >> "$FM_CW_SHIM_LOG"
sel=''
case " $* " in
  *" -l "*) sel=$(printf '%s' "$*" | sed -n 's/.* -l \([^ ]*\).*/\1/p') ;;
esac
case " $* " in
  *" --raw=/version "*) printf '{"gitVersion":"v1.31.0"}\n' ;;
  *" get deploy -A "*) cat "$FM_CW_SHIM_WORKLOADS" ;;
  *" get deployment "*) cat "$FM_CW_SHIM_SELECTOR_FILE" ;;
  *" get pods "*)
    [ "$sel" = "$(cat "$FM_CW_SHIM_SELECTOR_FILE")" ] || { printf '{"items":[]}\n'; exit 0; }
    printf '{"items":[{"metadata":{"name":"demo-1","labels":{"pod-template-hash":"%s"}},"spec":{"containers":[{"name":"c","image":"%s","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":{}}]}}]}\n' \
      "${FM_CW_SHIM_HASH:-h1}" "${FM_CW_SHIM_IMAGE:-}"
    ;;
  *" top pods "*)
    [ "$sel" = "$(cat "$FM_CW_SHIM_SELECTOR_FILE")" ] || exit 1
    printf 'demo-1   c   100m   128Mi\n'
    ;;
  *" logs "*)
    [ "$sel" = "$(cat "$FM_CW_SHIM_SELECTOR_FILE")" ] || exit 0
    awk 'BEGIN {
      for (i = 0; i < 200; i++) {
        s = int(i * 120 / 199)
        printf "[pod/demo-1/c] 2026-09-22T06:%02d:%02d.000000000Z 10.0.0.1 - \"GET /home HTTP/1.1\" %d 12\n", int(s / 60), s % 60, (i % 20 == 0 ? 502 : 200)
      }
    }'
    ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$home/bin/kubectl"
  printf 'demo-service image:demo-service\n' > "$home/config/change-watch-repos"
  printf 'muso-prod\tdemo\t2\tlocalhost:30500/muso/demo-service:old\n' > "$home/workloads"
  printf 'src/server.ts\n' > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeef > "$home/forge/head-ref"
  : > "$home/forge/diff.txt"
  printf '%s\n' "$home"
}

# run_selector_cw <home> <now> <args...> runs the watch against the shim.
run_selector_cw() {
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR='' \
    FM_CW_CONFIG_DIR="$home/config" FM_CW_SENTRY_DIR="$home/sentry" \
    FM_CW_SHIM_LOG="$home/shim.log" FM_CW_SHIM_WORKLOADS="$home/workloads" \
    FM_CW_SHIM_SELECTOR_FILE="$home/selector" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true PATH="$home/bin:$PATH" \
    "$CW" "$@"
}

HOME_SEL=$(selector_world sel 'app.kubernetes.io/name=demo')
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:old' FM_CW_SHIM_HASH=h1 \
  run_selector_cw "$HOME_SEL" 1790000000 register sel1 \
  'https://github.com/Muso-AI/demo-service/pull/7' >/dev/null || fail "selector register failed"
[ "$(cat "$HOME_SEL/state/change-watch/sel1-7/targets")" = "$(printf 'muso-prod\tdemo')" ] \
  || fail "the selector fixture did not resolve its Deployment"
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:new' FM_CW_SHIM_HASH=h2 \
  run_selector_cw "$HOME_SEL" 1790000300 sample sel1-7 300 >/dev/null || fail "selector sample failed"
SAMPLES_SEL="$HOME_SEL/state/change-watch/sel1-7/samples.log"
[ "$(awk -F'\t' '$3 == "http_5xx_per_min@muso-prod/demo" { print $4 }' "$SAMPLES_SEL")" = "2.0000" ] \
  || fail "a Deployment labelled app.kubernetes.io/name was not measured: $(cat "$SAMPLES_SEL")"
grep -q -- '-l app.kubernetes.io/name=demo' "$HOME_SEL/shim.log" \
  || fail "the watch did not read the Deployment's own selector: $(cat "$HOME_SEL/shim.log")"
grep -q -- '-l app=demo' "$HOME_SEL/shim.log" \
  && fail "the watch still assumed app=<name> for a modern-labelled Deployment"
pass "a Deployment is measured by its own app.kubernetes.io/name selector"

# The ordinary app=<name> Deployment still measures, so the fallback and the
# common case did not regress.
HOME_SEL2=$(selector_world sel2 'app=demo')
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:old' FM_CW_SHIM_HASH=h1 \
  run_selector_cw "$HOME_SEL2" 1790000000 register sel2 \
  'https://github.com/Muso-AI/demo-service/pull/8' >/dev/null || fail "app-label register failed"
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:new' FM_CW_SHIM_HASH=h2 \
  run_selector_cw "$HOME_SEL2" 1790000300 sample sel2-8 300 >/dev/null || fail "app-label sample failed"
SAMPLES_SEL2="$HOME_SEL2/state/change-watch/sel2-8/samples.log"
[ "$(awk -F'\t' '$3 == "http_5xx_per_min@muso-prod/demo" { print $4 }' "$SAMPLES_SEL2")" = "2.0000" ] \
  || fail "an app-labelled Deployment stopped measuring: $(cat "$SAMPLES_SEL2")"
grep -q -- '-l app=demo' "$HOME_SEL2/shim.log" \
  || fail "an app-labelled Deployment was not read by its own selector: $(cat "$HOME_SEL2/shim.log")"
pass "an app-labelled Deployment still measures through its own selector"

# One selector read per Deployment per sample: the per-sample memo is stored with
# a real tab separator, so the lookup hits and the metrics that follow reuse the
# read instead of spending the sample's budget on one cluster call per metric.
HOME_SEL3=$(selector_world sel3 'app.kubernetes.io/name=demo')
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:old' FM_CW_SHIM_HASH=h1 \
  run_selector_cw "$HOME_SEL3" 1790000000 register sel3 \
  'https://github.com/Muso-AI/demo-service/pull/9' >/dev/null || fail "memo register failed"
: > "$HOME_SEL3/shim.log"
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:new' FM_CW_SHIM_HASH=h2 \
  run_selector_cw "$HOME_SEL3" 1790000300 sample sel3-9 300 >/dev/null || fail "memo sample failed"
[ "$(grep -c -- ' get deployment ' "$HOME_SEL3/shim.log" || true)" = 1 ] \
  || fail "the selector memo did not hit: one sample read the Deployment $(grep -c -- ' get deployment ' "$HOME_SEL3/shim.log" || true) times"
pass "one sample reads a Deployment's selector once"

# --- an application repository is scoped to what its diff can affect -----------
# muso-messaging holds notify-gateway, preferences, send-gateway and the email
# templates. A change under scripts/ touches none of them, so it deploys nothing
# and must say so instead of reporting an unproven rollout of all three.

HOME_MS=$(new_world ms)
printf 'scripts/only/winback.py\n' > "$HOME_MS/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_MS/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_MS/forge/head-ref"
: > "$HOME_MS/forge/diff.txt"
out=$(run_cw "$HOME_MS" 1790000000 register ms1 \
  'https://github.com/Muso-AI/muso-messaging/pull/90') || fail "scripts-only register failed"
case "$out" in
  *"no deployable service touched"*"the change deploys nothing"*"nothing registered"*) ;;
  *) fail "a change that deploys nothing was not reported as such: $out" ;;
esac
[ -e "$HOME_MS/state/change-watch/ms1-90" ] \
  && fail "a change that deploys nothing created a watch record"
pass "a monorepo change under scripts/ deploys nothing and says so"

# The Sentry project and the deploy workflow are kept regardless: those reads
# never touch the cluster, so the watch still registers and completes clean.
HOME_MS2=$(cluster_world ms2)
printf 'muso-messaging messaging/notify-gateway messaging/send-gateway messaging/preferences sentry:messaging\n' \
  > "$HOME_MS2/config/change-watch-repos"
printf 'scripts/only/winback.py\n' > "$HOME_MS2/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_MS2/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_MS2/forge/head-ref"
: > "$HOME_MS2/forge/diff.txt"
printf '[]\n' > "$HOME_MS2/sentry/issues-messaging.json"
out=$(CW_CLUSTER_DIR='' PATH="$HOME_MS2/bin:$PATH" FM_CW_SHIM_LOG="$HOME_MS2/shim.log" \
  FM_CW_SHIM_WORKLOADS='' FM_CW_CONFIG_DIR="$HOME_MS2/config" \
  FM_CW_SENTRY_DIR="$HOME_MS2/sentry" \
  run_cw "$HOME_MS2" 1790000000 register ms2 \
  'https://github.com/Muso-AI/muso-messaging/pull/91') \
  || fail "sentry-only register failed: $out"
[ -e "$HOME_MS2/state/change-watch/ms2-91/targets" ] \
  && fail "a change that deploys nothing still registered cluster targets"
[ "$(cat "$HOME_MS2/state/change-watch/ms2-91/sentry")" = "messaging" ] \
  || fail "the Sentry project was dropped with the cluster targets"
CW_CLUSTER_DIR='' PATH="$HOME_MS2/bin:$PATH" FM_CW_SHIM_LOG="$HOME_MS2/shim.log" \
  FM_CW_SHIM_WORKLOADS='' FM_CW_CONFIG_DIR="$HOME_MS2/config" \
  FM_CW_SENTRY_DIR="$HOME_MS2/sentry" \
  run_cw "$HOME_MS2" 1790044000 drive ms2-91 >/dev/null || fail "sentry-only drive failed"
[ "$(run_cw "$HOME_MS2" 1790044000 verdict ms2-91)" = "change-watch clean" ] \
  || fail "a change that deploys nothing did not complete clean: $(run_cw "$HOME_MS2" 1790044000 verdict ms2-91)"
pass "a change that deploys nothing completes clean on its Sentry project alone"

# A diff that touches one service directory watches exactly that Deployment.
HOME_MS3=$(new_world ms3)
printf 'notify-gateway/src/send.ts\n' > "$HOME_MS3/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_MS3/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_MS3/forge/head-ref"
: > "$HOME_MS3/forge/diff.txt"
out=$(run_cw "$HOME_MS3" 1790000000 register ms3 \
  'https://github.com/Muso-AI/muso-messaging/pull/92') || fail "scoped register failed: $out"
[ "$(cat "$HOME_MS3/state/change-watch/ms3-92/targets")" = "$(printf 'messaging\tnotify-gateway')" ] \
  || fail "a one-service diff did not scope to that one Deployment: $(cat "$HOME_MS3/state/change-watch/ms3-92/targets" 2>/dev/null)"
pass "a monorepo diff is scoped to the one service it touches"

# seed_files <home> <path>... seeds the merged PR's touched paths.
seed_files() {
  local home=$1
  shift
  printf '%s
' "$@" > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeef > "$home/forge/head-ref"
  : > "$home/forge/diff.txt"
}

# A monorepo that keeps its services a directory down places them the same way:
# services/<name>/... names <name>, so the nested layout is not read as a diff
# that touches no service at all.
HOME_MS4=$(new_world ms4)
seed_files "$HOME_MS4" 'services/send-gateway/src/queue.ts'
out=$(run_cw "$HOME_MS4" 1790000000 register ms4 \
  'https://github.com/Muso-AI/muso-messaging/pull/93') || fail "nested register failed: $out"
[ "$(cat "$HOME_MS4/state/change-watch/ms4-93/targets")" = "$(printf 'messaging\tsend-gateway')" ] \
  || fail "a nested service path did not place its Deployment: $(cat "$HOME_MS4/state/change-watch/ms4-93/targets" 2>/dev/null)"
pass "a service kept one directory down is still placed by its name"

# A path every Deployment of the repository consumes stays in scope: a root-level
# build input is not a diff that touches no deployable path, and concluding clean
# on it would hide a rollout failure the change really could cause.
HOME_MS5=$(new_world ms5)
seed_files "$HOME_MS5" 'package.json'
out=$(run_cw "$HOME_MS5" 1790000000 register ms5 \
  'https://github.com/Muso-AI/muso-messaging/pull/94') || fail "root-shared register failed: $out"
[ "$(printf '%s\n' "$(cat "$HOME_MS5/state/change-watch/ms5-94/targets" 2>/dev/null)" | grep -c '^messaging	')" = 3 ] \
  || fail "a root-shared path concluded clean instead of watching the Deployments that consume it: $(cat "$HOME_MS5/state/change-watch/ms5-94/targets" 2>/dev/null)"
pass "a root-shared path keeps every Deployment that consumes it in scope"

# A deployable path no service owns is shared build input, not nothing: every
# Deployment of the repository consumes a library or an internal package, so the
# diff stays in scope instead of concluding that it deploys nothing.
HOME_SH1=$(new_world sh1)
seed_files "$HOME_SH1" 'lib/delivery.ts'
out=$(run_cw "$HOME_SH1" 1790000000 register sh1 \
  'https://github.com/Muso-AI/muso-messaging/pull/105') || fail "shared-lib register failed: $out"
[ "$(printf '%s\n' "$(cat "$HOME_SH1/state/change-watch/sh1-105/targets" 2>/dev/null)" | grep -c '^messaging	')" = 3 ] \
  || fail "a shared library path concluded clean instead of watching the Deployments that consume it: $(cat "$HOME_SH1/state/change-watch/sh1-105/targets" 2>/dev/null)"
HOME_SH2=$(new_world sh2)
seed_files "$HOME_SH2" 'internal/notify/retry.ts'
out=$(run_cw "$HOME_SH2" 1790000000 register sh2 \
  'https://github.com/Muso-AI/muso-messaging/pull/106') || fail "shared-internal register failed: $out"
[ "$(printf '%s\n' "$(cat "$HOME_SH2/state/change-watch/sh2-106/targets" 2>/dev/null)" | grep -c '^messaging	')" = 3 ] \
  || fail "an unmatched internal path concluded clean instead of watching the Deployments that consume it: $(cat "$HOME_SH2/state/change-watch/sh2-106/targets" 2>/dev/null)"
pass "a deployable path no service owns keeps every Deployment in scope"

# The map's path: prefix says where the services and their shared build inputs
# live. A path under it that names a service scopes to that service; one that
# names none is shared by all of them.
HOME_MS6=$(new_world ms6)
mkdir -p "$HOME_MS6/config"
printf 'muso-messaging path:services messaging/notify-gateway messaging/send-gateway\n' \
  > "$HOME_MS6/config/change-watch-repos"
seed_files "$HOME_MS6" 'services/notify-gateway/src/send.ts'
out=$(FM_CW_CONFIG_DIR="$HOME_MS6/config" run_cw "$HOME_MS6" 1790000000 register ms6 \
  'https://github.com/Muso-AI/muso-messaging/pull/95') || fail "prefix register failed: $out"
[ "$(cat "$HOME_MS6/state/change-watch/ms6-95/targets")" = "$(printf 'messaging\tnotify-gateway')" ] \
  || fail "a mapped path prefix did not scope to the one service under it: $(cat "$HOME_MS6/state/change-watch/ms6-95/targets" 2>/dev/null)"
HOME_MS7=$(new_world ms7)
mkdir -p "$HOME_MS7/config"
printf 'muso-messaging path:services messaging/notify-gateway messaging/send-gateway\n' \
  > "$HOME_MS7/config/change-watch-repos"
seed_files "$HOME_MS7" 'services/shared/logger.ts'
out=$(FM_CW_CONFIG_DIR="$HOME_MS7/config" run_cw "$HOME_MS7" 1790000000 register ms7 \
  'https://github.com/Muso-AI/muso-messaging/pull/96') || fail "prefix-shared register failed: $out"
[ "$(printf '%s\n' "$(cat "$HOME_MS7/state/change-watch/ms7-96/targets" 2>/dev/null)" | grep -c '^messaging	')" = 2 ] \
  || fail "a shared path under the map's prefix concluded clean: $(cat "$HOME_MS7/state/change-watch/ms7-96/targets" 2>/dev/null)"
pass "a mapped path prefix scopes its own services and keeps their shared paths in scope"

# A single-service application repository is not exempt from the same rule: a diff
# of documentation, tests, and non-deploy CI deploys nothing and says so, while a
# build or script path still measures the rollout.
HOME_SS=$(new_world ss)
mkdir -p "$HOME_SS/config" "$HOME_SS/sentry"
printf 'demo-service image:demo-service sentry:demo\n' > "$HOME_SS/config/change-watch-repos"
printf '[]\n' > "$HOME_SS/sentry/issues-demo.json"
seed_files "$HOME_SS" 'README.md' 'docs/setup.md' 'tests/smoke.ts' '.github/workflows/lint.yml'
out=$(FM_CW_CONFIG_DIR="$HOME_SS/config" FM_CW_SENTRY_DIR="$HOME_SS/sentry" \
  run_cw "$HOME_SS" 1790000000 register ss1 \
  'https://github.com/Muso-AI/demo-service/pull/97') || fail "docs-only register failed: $out"
[ -e "$HOME_SS/state/change-watch/ss1-97/targets" ] \
  && fail "a docs-only diff in a single-service repository still watched a Deployment"
pass "a single-service repository concludes a docs-only diff deploys nothing"

HOME_SS2=$(selector_world ss2 'app=demo')
seed_files "$HOME_SS2" 'scripts/release.sh'
FM_CW_SHIM_IMAGE='localhost:30500/muso/demo-service:old' \
  run_selector_cw "$HOME_SS2" 1790000000 register ss2 \
  'https://github.com/Muso-AI/demo-service/pull/98' >/dev/null || fail "script-path register failed"
[ "$(cat "$HOME_SS2/state/change-watch/ss2-98/targets" 2>/dev/null)" = "$(printf 'muso-prod\tdemo')" ] \
  || fail "a script path in a single-service repository was reported as deploying nothing"
pass "a single-service repository still measures a build or script change"

# --- a deploy run has to carry the merged commit -------------------------------
# hydra deploys from a daily schedule and a manual dispatch, never a push, so the
# earliest run created after a merge can belong to an older branch tip. Reading
# that run as failed reported six healthy releases as regressions on 2026-11-14,
# and a run still in flight is a deploy that has not landed yet rather than a
# measurement gap that ends the watch.

hydra_runs() {  # <home> <json>
  mkdir -p "$1/gh/runs-Muso-AI"
  printf '%s\n' "$2" > "$1/gh/runs-Muso-AI/hydra-.github_workflows_deploy.yml.json"
}
hydra_world() {  # <name> [<merge-sha>]
  local home
  home=$(new_world "$1")
  mkdir -p "$home/gh/runs-Muso-AI" "$home/sentry" "$home/config" "$home/bin" "$home/state"
  printf 'src/hydra.py\n' > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeef > "$home/forge/head-ref"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$home/forge/merge-sha"
  printf '%s\n' "$home"
}
# hydra_run <created> <state> <conclusion> <sha>: one entry of the run list.
hydra_run() {  # <created> <status> <conclusion> <head-sha>
  printf '{"conclusion":%s,"status":"%s","createdAt":"%s","databaseId":9,"headSha":"%s","url":"https://github.com/Muso-AI/hydra/actions/runs/9"}' \
    "$(printf '%s' "$3" | sed 's/^/"/; s/$/"/; s/^"null"$/null/')" "$2" "$1" "$4"
}
# run_hydra_cw <home> <now> <args...>: hydra reads its run list from the stubbed
# forge, so every call in this section carries the stub directory. Without it the
# reader would reach the live forge, which a test must never do. The cluster stub
# directory is empty here for the same reason: a run target is a forge read, and a
# set cluster dir makes every metric read a stubbed series file instead.
run_hydra_cw() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  CW_CLUSTER_DIR='' FM_CW_GH_DIR="$home/gh" run_cw "$home" "$now" "$@"
}

deploy_run_value() {  # <home> <watch-id> <offset>
  awk -F'\t' '$2 == "'"$3"'" { print $4 }' "$1/state/change-watch/$2/samples.log" 2>/dev/null | tail -1
}

MERGED='aaaa1111bbbb'
OLDER='cccc2222dddd'

# A merge the forge cannot name has no provable carrier, so no candidate run is
# scored: an unrelated failed run in the window is neither this release's
# regression nor its success, only a deploy that cannot be attributed yet.
HOME_NS=$(hydra_world ns)
out=$(run_hydra_cw "$HOME_NS" 1790000000 register ns1 'https://github.com/Muso-AI/hydra/pull/1961') \
  || fail "hydra register failed: $out"
hydra_runs "$HOME_NS" "[$(hydra_run 2026-09-21T15:00:00Z completed failure "$OLDER")]"
run_hydra_cw "$HOME_NS" 1790000900 sample ns1-1961 900 >/dev/null || fail "sample failed"
grep -q 'awaiting the deploy: merge sha unreadable' "$HOME_NS/state/change-watch/ns1-1961/read-failures" \
  || fail "an unreadable merge sha was not stated as the reason nothing was measured: $(cat "$HOME_NS/state/change-watch/ns1-1961/read-failures" 2>/dev/null)"
[ -z "$(deploy_run_value "$HOME_NS" ns1-1961 900)" ] \
  || fail "a failed run that carries nothing provable about the merge was scored: $(cat "$HOME_NS/state/change-watch/ns1-1961/samples.log" 2>/dev/null)"
line=$(run_hydra_cw "$HOME_NS" 1790000900 verdict ns1-1961)
case "$line" in
  *regressed*) fail "an unrelated failed run regressed a release the forge cannot tie to a commit: $line" ;;
esac
pass "an unreadable merge sha leaves the deploy unmeasured instead of scoring a run"
HOME_DS=$(hydra_world ds "$MERGED")
out=$(run_hydra_cw "$HOME_DS" 1790000000 register ds1 'https://github.com/Muso-AI/hydra/pull/1957') \
  || fail "hydra register failed: $out"
case "$out" in
  *"deploys nothing"*) fail "a repository watched through its deploy workflow claimed the change deploys nothing: $out" ;;
  *"1 target(s)"*) ;;
  *) fail "the deploy workflow target was not registered: $out" ;;
esac
pass "a repository watched through its deploy workflow measures the change"
hydra_runs "$HOME_DS" "[$(hydra_run 2026-09-21T15:00:00Z completed failure "$OLDER"),$(hydra_run 2026-09-21T15:30:00Z completed success "$MERGED")]"
run_hydra_cw "$HOME_DS" 1790000900 sample ds1-1957 900 >/dev/null || fail "sample failed"
[ "$(deploy_run_value "$HOME_DS" ds1-1957 900)" = 1 ] \
  || fail "a deploy run carrying the merged commit was not measured: $(cat "$HOME_DS/state/change-watch/ds1-1957/samples.log" 2>/dev/null)"
line=$(run_hydra_cw "$HOME_DS" 1790000900 verdict ds1-1957)
case "$line" in
  *regressed*) fail "a failed run of an older tip regressed a healthy release: $line" ;;
esac

# The same older-tip run is the release's once the forge proves its tree carries
# the merged commit, and a failed run that genuinely carries it still regresses.
hydra_runs "$HOME_DS" "[$(hydra_run 2026-09-21T15:00:00Z completed failure "$OLDER")]"
printf '%s\n' "$MERGED" > "$HOME_DS/gh/contains-$OLDER"
run_hydra_cw "$HOME_DS" 1790003600 sample ds1-1957 3600 >/dev/null || fail "sample failed"
[ "$(deploy_run_value "$HOME_DS" ds1-1957 3600)" = 0 ] \
  || fail "a failed run whose tree carries the merge was not read as a failed deploy: $(deploy_run_value "$HOME_DS" ds1-1957 3600)"

# A run of an unrelated tip with no proof it carries the merge is awaited, never
# read as a failure.
rm -f "$HOME_DS/gh/contains-$OLDER"
run_hydra_cw "$HOME_DS" 1790007200 sample ds1-1957 7200 >/dev/null || fail "sample failed"
[ -z "$(deploy_run_value "$HOME_DS" ds1-1957 7200)" ] \
  || fail "an unrelated run was read as this release's deploy"
grep -q 'carrying aaaa1111 yet' "$HOME_DS/state/change-watch/ds1-1957/read-failures" \
  || fail "an unrelated run was not stated as awaiting a run that carries the merge: $(cat "$HOME_DS/state/change-watch/ds1-1957/read-failures" 2>/dev/null)"
pass "a deploy run is the one whose tree carries the merged commit"

# However many unrelated runs were created before the one whose tree carries the
# merge, the carrier is still found and scored: a bounded scan of the oldest few
# dropped it and ended the watch unmeasured instead of reporting the failure.
HOME_CC=$(hydra_world cc "$MERGED")
run_hydra_cw "$HOME_CC" 1790000000 register cc1 'https://github.com/Muso-AI/hydra/pull/1980' >/dev/null \
  || fail "hydra register failed"
CC_RUNS=$(hydra_run 2026-09-21T15:00:00Z completed failure oldtip01)
for n in 02 03 04 05 06; do
  CC_RUNS="$CC_RUNS,$(hydra_run "2026-09-21T15:0${n#0}:00Z" completed success "oldtip$n")"
done
hydra_runs "$HOME_CC" "[$CC_RUNS,$(hydra_run 2026-09-21T15:30:00Z completed failure "$OLDER")]"
printf '%s\n' "$MERGED" > "$HOME_CC/gh/contains-$OLDER"
run_hydra_cw "$HOME_CC" 1790000900 sample cc1-1980 900 >/dev/null || fail "sample failed"
[ "$(deploy_run_value "$HOME_CC" cc1-1980 900)" = 0 ] \
  || fail "a carrier created after more than five unrelated runs was not read as a failed deploy: $(cat "$HOME_CC/state/change-watch/cc1-1980/samples.log" 2>/dev/null)"
line=$(run_hydra_cw "$HOME_CC" 1790000900 verdict cc1-1980)
case "$line" in
  *"regressed at +15m on deploy_run"*) ;;
  *) fail "a failed carrier run after six unrelated runs did not regress the release: $line" ;;
esac
hydra_runs "$HOME_CC" "[$CC_RUNS,$(hydra_run 2026-09-21T15:30:00Z completed success "$OLDER")]"
run_hydra_cw "$HOME_CC" 1790003600 sample cc1-1980 3600 >/dev/null || fail "sample failed"
[ "$(deploy_run_value "$HOME_CC" cc1-1980 3600)" = 1 ] \
  || fail "a successful carrier created after more than five unrelated runs was not proven: $(cat "$HOME_CC/state/change-watch/cc1-1980/samples.log" 2>/dev/null)"
rm -f "$HOME_CC/gh/contains-$OLDER"
run_hydra_cw "$HOME_CC" 1790007200 sample cc1-1980 7200 >/dev/null || fail "sample failed"
[ -z "$(deploy_run_value "$HOME_CC" cc1-1980 7200)" ] \
  || fail "a run whose tree carries nothing of the merge was scored"
grep -q 'carrying aaaa1111 yet' "$HOME_CC/state/change-watch/cc1-1980/read-failures" \
  || fail "a window of unrelated runs was not stated as awaiting a carrier: $(cat "$HOME_CC/state/change-watch/cc1-1980/read-failures" 2>/dev/null)"
pass "the carrier scan finds the run carrying the merge past many unrelated runs"

# A run still in flight is the deploy not having landed yet: the reading waits,
# it is not a gap, and the watch still reaches proven once the deploy succeeds.
HOME_IF=$(hydra_world if "$MERGED")
run_hydra_cw "$HOME_IF" 1790000000 register if1 'https://github.com/Muso-AI/hydra/pull/1970' >/dev/null \
  || fail "hydra register failed"
hydra_runs "$HOME_IF" "[$(hydra_run 2026-09-21T14:30:00Z in_progress '-' "$MERGED")]"
run_hydra_cw "$HOME_IF" 1790000900 sample if1-1970 900 >/dev/null || fail "sample failed"
grep -q 'awaiting the deploy: the .github/workflows/deploy.yml run is in_progress' \
  "$HOME_IF/state/change-watch/if1-1970/read-failures" \
  || fail "a run in flight was not recorded as awaiting the deploy: $(cat "$HOME_IF/state/change-watch/if1-1970/read-failures" 2>/dev/null)"
[ "$(awk -F'\t' '$2 == 900 { print $8 }' "$HOME_IF/state/change-watch/if1-1970/samples.log" | tail -1)" = 1 ] \
  || fail "a run in flight was counted as a measurement gap"
hydra_runs "$HOME_IF" "[$(hydra_run 2026-09-21T14:30:00Z completed success "$MERGED")]"
run_hydra_cw "$HOME_IF" 1790044000 drive if1-1970 >/dev/null || fail "resumed drive failed"
ROW_IF="$HOME_IF/state/change-watch/rows/if1-1970.json"
grep -q '"900": {[^}]*"measured": true' "$ROW_IF" \
  || fail "a +15m reading that was only awaiting the deploy was not measured: $(cat "$ROW_IF" 2>/dev/null)"
grep -q '"terminal_state": "proven"' "$ROW_IF" \
  || fail "a watch whose scheduled deploy landed after +15m was not proven: $(cat "$ROW_IF" 2>/dev/null)"
pass "a deploy still in flight at +15m waits instead of ending the watch unmeasurable"

# --- a merge already running at registration is measured, not awaited --------
# credit-removal-i1-1839: the watch registered while the pods already ran an
# image built from a tree carrying the merge, so the fingerprint it recorded
# could never change again and every sample waited for a deploy that had
# already happened. The image tag names the deploy run that built it
# (YYYYMMDD-<run-number>), and that run's log names the commit it built.
IDP_PR='https://github.com/Muso-AI/industry-data-processing/pull/1839'
IDP_MERGE=3295463db3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IDP_BUILT=6271d8f5dc070f9f563a415c69858b399b4e9394
IDP_OLD_BUILT=1111111111111111111111111111111111111111
IDP_BUILD_STUB='build-Muso-AI-H-DevOps-.github_workflows_deploy-idp.yaml'
idp_world() {  # <name> <image>
  local home
  home=$(cluster_world "$1")
  seed_app_pr "$home"
  printf '%s\n' "$IDP_MERGE" > "$home/forge/merge-sha"
  printf 'muso-prod\tindustry-proc-catalog-v2\t4\t%s\n' "$2" > "$home/workloads"
  mkdir -p "$home/gh"
  printf 'Resolved Muso-AI/industry-data-processing main \342\206\222 %s\n' "$IDP_BUILT" \
    > "$home/gh/$IDP_BUILD_STUB-702"
  printf '%s\n' "$IDP_MERGE" > "$home/gh/contains-$IDP_BUILT"
  printf 'Resolved Muso-AI/industry-data-processing main \342\206\222 %s\n' "$IDP_OLD_BUILT" \
    > "$home/gh/$IDP_BUILD_STUB-700"
  : > "$home/gh/contains-$IDP_OLD_BUILT"
  printf '%s\n' "$home"
}
idp_cw() {  # <home> <image> <now> <args...>
  local home=$1 image=$2 now=$3
  shift 3
  CW_CLUSTER_DIR='' PATH="$home/bin:$PATH" FM_CW_SHIM_LOG="$home/shim.log" \
    FM_CW_SHIM_WORKLOADS="$home/workloads" FM_CW_SHIM_IMAGE="$image" \
    FM_CW_CONFIG_DIR="$home/config" FM_CW_SENTRY_DIR="$home/sentry" FM_CW_GH_DIR="$home/gh" \
    run_cw "$home" "$now" "$@"
}
IDP_702='localhost:30500/muso/industry-data-processing:20261115-702'
IDP_700='localhost:30500/muso/industry-data-processing:20261113-700'

HOME_AD=$(idp_world ad "$IDP_702")
out=$(idp_cw "$HOME_AD" "$IDP_702" 1790000000 register ad1 "$IDP_PR") || fail "register failed: $out"
DIR_AD="$HOME_AD/state/change-watch/ad1-1839"
printf '900\t1790000900\n3600\t1790003600\n21600\t1790021600\n' > "$DIR_AD/schedule"
idp_cw "$HOME_AD" "$IDP_702" 1790000900 sample ad1-1839 900 >/dev/null || fail "sample failed"
awk -F'\t' '$2 == 900 && $7 == 1' "$DIR_AD/samples.log" | grep -q 'restarts@muso-prod/industry-proc-catalog-v2' \
  || fail "a target already running the merge was not scored: $(cat "$DIR_AD/samples.log")"
[ "$(awk -F'\t' '$2 == 900 && $8 == 1' "$DIR_AD/samples.log" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "a target already running the merge was recorded as awaiting the deploy: $(cat "$DIR_AD/samples.log")"
grep -q 'awaiting the deploy' "$DIR_AD/read-failures" 2>/dev/null \
  && fail "a merge already running was reported as awaiting the deploy: $(cat "$DIR_AD/read-failures")"
[ "$(awk -F'\t' '$2 == 900 && $3 == "restarts@muso-prod/industry-proc-catalog-v2" { print $5 }' "$DIR_AD/samples.log")" = 0 ] \
  || fail "the restarts bar of a post-deploy registration was not held absolute: $(cat "$DIR_AD/samples.log")"
printf '%s\n' "$out" | grep -q 'already running at registration on muso-prod/industry-proc-catalog-v2 (20261115-702 built from 6271d8f5)' \
  || fail "registration did not state that the merge was already running: $out"
idp_cw "$HOME_AD" "$IDP_702" 1790021600 drive ad1-1839 >/dev/null || fail "drive failed"
verdict=$(idp_cw "$HOME_AD" "$IDP_702" 1790021600 verdict ad1-1839 || true)
case "$verdict" in
  unmeasurable*) fail "a merge already running at registration ended unmeasurable: $verdict" ;;
esac
grep -q '"terminal_state": "proven"' "$HOME_AD/state/change-watch/rows/ad1-1839.json" \
  || fail "a merge already running at registration was not proven: $(cat "$HOME_AD/state/change-watch/rows/ad1-1839.json")"
grep -q 'no pre-merge baseline was readable' "$HOME_AD/state/change-watch/rows/ad1-1839.json" \
  || fail "the row did not say how a post-deploy baseline was taken: $(cat "$HOME_AD/state/change-watch/rows/ad1-1839.json")"
pass "a merge already running at registration is measured, never awaiting the deploy"

# The same mapping keeps the gate shut when the running image predates the
# merge, and the answer is remembered so later samples do not read the forge.
HOME_AN=$(idp_world an "$IDP_700")
out=$(idp_cw "$HOME_AN" "$IDP_700" 1790000000 register an1 "$IDP_PR") || fail "register failed: $out"
DIR_AN="$HOME_AN/state/change-watch/an1-1839"
printf '%s\n' "$out" | grep -q 'already running' && fail "a pre-merge image was read as carrying the merge: $out"
[ "$(cat "$DIR_AN/builds" 2>/dev/null)" = "$(printf '20261113-700\t%s\tnot' "$IDP_OLD_BUILT")" ] \
  || fail "the build answer for a pre-merge image was not remembered: $(cat "$DIR_AN/builds" 2>/dev/null)"
rm -f "$HOME_AN/gh/$IDP_BUILD_STUB-700"
idp_cw "$HOME_AN" "$IDP_700" 1790000300 sample an1-1839 300 >/dev/null || fail "sample failed"
[ "$(awk -F'\t' '$7 == 1' "$DIR_AN/samples.log" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "a target on a pre-merge image was scored: $(cat "$DIR_AN/samples.log")"
grep -q 'awaiting the deploy' "$DIR_AN/read-failures" \
  || fail "a target on a pre-merge image was not awaiting the deploy"
idp_cw "$HOME_AN" "$IDP_702" 1790000900 sample an1-1839 900 >/dev/null || fail "sample failed"
awk -F'\t' '$2 == 900 && $7 == 1' "$DIR_AN/samples.log" | grep -q 'restarts@muso-prod/industry-proc-catalog-v2' \
  || fail "the rollout that landed after registration was not scored: $(cat "$DIR_AN/samples.log")"
[ ! -s "$DIR_AN/carried-at-register" ] \
  || fail "a rollout after registration was recorded as already running: $(cat "$DIR_AN/carried-at-register")"
pass "a pre-merge image still awaits its deploy, and its build answer is remembered"

# An image whose build answer cannot be read is not "awaiting the deploy": the
# pods stayed on that image, so the gate cannot tell whether the merge is live,
# and the sample names the read that failed instead of blaming a rollout.
HOME_AO=$(idp_world ao "$IDP_702")
rm -f "$HOME_AO/gh/contains-$IDP_BUILT"
out=$(idp_cw "$HOME_AO" "$IDP_702" 1790000000 register ao1 "$IDP_PR") || fail "register failed: $out"
DIR_AO="$HOME_AO/state/change-watch/ao1-1839"
printf '%s\n' "$out" | grep -q 'already running' \
  && fail "an unreadable build answer was read as carrying the merge: $out"
idp_cw "$HOME_AO" "$IDP_702" 1790000300 sample ao1-1839 300 >/dev/null || fail "sample failed"
grep -q 'deploy landing unreadable: whether image 20261115-702 carries the merge could not be read from Muso-AI/industry-data-processing' \
  "$DIR_AO/read-failures" \
  || fail "an unreadable build answer did not name the read that failed: $(cat "$DIR_AO/read-failures")"
grep -q 'awaiting the deploy' "$DIR_AO/read-failures" \
  && fail "an unreadable build answer was reported as awaiting the deploy: $(cat "$DIR_AO/read-failures")"
[ "$(awk -F'\t' '$8 == 1' "$DIR_AO/samples.log" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "an unreadable build answer was recorded as awaiting: $(cat "$DIR_AO/samples.log")"
[ "$(awk -F'\t' '$7 == 1' "$DIR_AO/samples.log" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "a metric was scored though the landing could not be read: $(cat "$DIR_AO/samples.log")"
[ ! -s "$DIR_AO/builds" ] \
  || fail "an unreadable build answer was remembered: $(cat "$DIR_AO/builds")"
pass "an unreadable build answer names the failed read, never the awaiting deploy"

# The build answer is asked once per target per sample: the gate runs once per
# Kubernetes metric, and an unreadable answer repeated for each of them would
# spend the sample budget before the later metrics were read.
HOME_AP=$(idp_world ap "$IDP_702")
rm -f "$HOME_AP/gh/contains-$IDP_BUILT"
out=$(idp_cw "$HOME_AP" "$IDP_702" 1790000000 register ap1 "$IDP_PR") || fail "register failed: $out"
DIR_AP="$HOME_AP/state/change-watch/ap1-1839"
: > "$HOME_AP/trace"
idp_cw "$HOME_AP" "$IDP_702" 1790000300 sample ap1-1839 300 >/dev/null || fail "sample failed"
reads=$(awk -F'\t' '$1 == "prod" && $2 == "build"' "$HOME_AP/trace" | wc -l | tr -d ' ')
[ "$reads" -eq 1 ] \
  || fail "one sample read the build answer $reads time(s) for one target: $(cat "$HOME_AP/trace")"
grep -q 'deploy landing unreadable' "$DIR_AP/read-failures" \
  || fail "the single build read was not recorded as the sample's reason: $(cat "$DIR_AP/read-failures")"
grep -q 'sample budget spent before this metric was read' "$DIR_AP/read-failures" \
  && fail "metrics after the build read were lost to the sample budget: $(cat "$DIR_AP/read-failures")"
pass "one sample asks the build answer once per target"

# A build read that stalls must not spend the sample's budget: it is cut at its
# share of the deadline, recorded as the named unreadable read, and the target's
# other metrics are still read instead of being reported as budget loss.
HOME_AT=$(idp_world at "$IDP_702")
rm -f "$HOME_AT/gh/contains-$IDP_BUILT"
register_now=$(( $(date +%s) - 86400 ))
out=$(idp_cw "$HOME_AT" "$IDP_702" "$register_now" register at1 "$IDP_PR") || fail "register failed: $out"
DIR_AT="$HOME_AT/state/change-watch/at1-1839"
cat > "$HOME_AT/bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SHIM_GH_LOG"
case "$*" in
  *"--json mergeCommit"*) printf '%s\n' "$FM_CW_SHIM_MERGE" ;;
  *"--json mergedAt"*) printf '2026-11-15T00:00:00Z\n' ;;
  *"--json files"*) : ;;
  *"--json headRefOid"*) printf 'deadbeef\n' ;;
  *"pr diff"*) : ;;
  *"actions/workflows/"*) printf '9001\n' ;;
  *"actions/runs/"*"/jobs"*) printf '111\tdetermine-env\n222\tbuild\n333\tbuild2\n' ;;
  *"actions/jobs/"*"/logs"*) sleep 60 ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$HOME_AT/bin/gh"
at_cw() {
  env FM_HOME="$HOME_AT" FM_STATE_OVERRIDE="$HOME_AT/state" FM_CW_NOW='' \
    FM_CW_CLUSTER_DIR='' PATH="$HOME_AT/bin:$PATH" FM_CW_SHIM_LOG="$HOME_AT/shim.log" \
    FM_CW_SHIM_WORKLOADS="$HOME_AT/workloads" FM_CW_SHIM_IMAGE="$IDP_702" \
    FM_CW_CONFIG_DIR="$HOME_AT/config" FM_CW_SENTRY_DIR="$HOME_AT/sentry" \
    FM_CW_ARM_CMD="$HOME_AT/arm.sh" FM_CW_ARM_LOG="$HOME_AT/arm.log" \
    FM_CW_SEND_CMD="$HOME_AT/send.sh" FM_CW_SEND_LOG="$HOME_AT/send.log" \
    FM_CW_TRACE="$HOME_AT/trace" FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    FM_CW_FORGE_TIMEOUT=6 FM_CW_SAMPLE_DEADLINE=25 FM_CW_SHIM_GH_LOG="$HOME_AT/gh.log" \
    FM_CW_SHIM_MERGE="$IDP_MERGE" \
    "$CW" "$@"
}
started=$SECONDS
at_cw sample at1-1839 300 >/dev/null || fail "a sample with a stalled build read failed"
elapsed=$((SECONDS - started))
grep -q 'deploy landing unreadable: the build commit of image 20261115-702 could not be read from Muso-AI/H-DevOps .github/workflows/deploy-idp.yaml' \
  "$DIR_AT/read-failures" \
  || fail "a stalled build read was not named as the unreadable read: $(cat "$DIR_AT/read-failures")"
grep -q 'sample budget spent before this metric was read' "$DIR_AT/read-failures" \
  && fail "a stalled build read spent the rest of the sample's budget: $(cat "$DIR_AT/read-failures")"
[ "$elapsed" -lt 15 ] || fail "a stalled build read ran past its bound (${elapsed}s)"
awk -F'\t' '$2 == 300 && $3 == "oomkilled@muso-prod/industry-proc-catalog-v2"' "$DIR_AT/samples.log" | grep -q . \
  || fail "the target's other metrics were not read after the build gate: $(cat "$DIR_AT/samples.log")"
pass "a stalled build read is cut at its share of the sample and later metrics are read"
