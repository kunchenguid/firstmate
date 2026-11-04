#!/usr/bin/env bash
# Tests for bin/fm-change-watch.sh, the post-merge change watch.
#
# The watch exists to catch a merge that is bad BY EFFECT rather than by
# content, so the cases here pin exactly that: a merged PR whose hunk lands in
# one Deployment of a multi-Deployment manifest registers that one target under
# the manifest's own namespace; a 5xx series that crosses its bar at +15m
# reports the first regression as a wake and a steer; an OOMKilled event reports
# on the sample that sees it; a clean series runs the whole 12h schedule and
# records the clean note; a schedule that never read a target completes
# unmeasured instead of clean; an interrupted drive is never clean and can be
# re-armed; the pool metric is scoped to the Deployment's own pool; the pool
# console is read as ubuntu through the admin unix socket with stdin closed and
# a hard bound, and the doctor states every failed pool read; a reused pid never
# reads as a live drive; and a docs-only PR registers nothing at all.
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

# A Deployment that declares no namespace is skipped with its reason, never guessed.
HOME_A6=$(new_world a6)
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: argocd-server\nspec: {}\n' > "$TMP_ROOT/nons.yaml"
seed_pr "$HOME_A6" k8s/prod/argocd/install.yaml "$TMP_ROOT/nons.yaml" k8s/prod/argocd/install.yaml
seed_diff "$HOME_A6" k8s/prod/argocd/install.yaml 4
out=$(run_cw "$HOME_A6" 1790000000 register w6 "$PR_URL") || fail "register failed"
case "$out" in
  *"no deployable service touched"*"(no namespace: argocd-server in k8s/prod/argocd/install.yaml)"*) ;;
  *) fail "a Deployment without metadata.namespace was not skipped with its reason: $out" ;;
esac
[ -e "$HOME_A6/state/change-watch/w6-3317" ] && fail "a Deployment without a namespace was watched under a guess"
pass "a Deployment without metadata.namespace is skipped, never guessed"

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

# A schedule in which the target was never read completes unmeasured, not clean.
HOME_U=$(new_world u)
seed_pr "$HOME_U" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_U" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_U" 1790000000 register u1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_U/state/u1.meta"
run_cw "$HOME_U" 1790044000 drive u1-3317 >/dev/null || fail "unmeasured drive failed"
[ "$(run_cw "$HOME_U" 1790044000 verdict u1-3317)" = "change-watch completed unmeasured" ] \
  || fail "an entirely unmeasured watch read as: $(run_cw "$HOME_U" 1790044000 verdict u1-3317)"
grep -qF "note: change-watch completed unmeasured for $PR_URL (never measured: muso-prod/feed-service)" \
  "$HOME_U/state/u1.status" || fail "the unmeasured completion note was not appended"
grep -q "change-watch clean" "$HOME_U/state/u1.status" && fail "an unmeasured watch recorded a clean note"
[ -e "$HOME_U/state/.wake-queue" ] && [ -s "$HOME_U/state/.wake-queue" ] \
  && fail "an unmeasured completion must not queue a wake"
pass "a never-measured target completes unmeasured with its own note and no clean claim"

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
pass "docs-only PR leaves no watch behind"

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
    last='{}'
    [ -z "${FM_CW_SHIM_OOM_AT:-}" ] || last="{\"terminated\":{\"reason\":\"OOMKilled\",\"finishedAt\":\"$(date -u -d "@$FM_CW_SHIM_OOM_AT" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '1970-01-01T00:00:00Z')\"}}"
    printf '{"items":[{"metadata":{"name":"%s-1","labels":{"pod-template-hash":"%s"}},"spec":{"containers":[{"name":"c","image":"%s","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":%s}]}}]}\n' \
      "$app" "${FM_CW_SHIM_HASH:-h1}" "${FM_CW_SHIM_IMAGE:-}" "$last"
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

# A repository whose Deployment names differ from its image name is mapped.
HOME_M2=$(cluster_world m2)
seed_app_pr "$HOME_M2"
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
line=$(run_cw "$HOME_R" 1790000900 verdict r1-1383)
[ "$line" = "change-watch regressed at +15m on deploy_run (0 vs baseline unmeasured)" ] \
  || fail "a failed deploy run did not regress the watch: $line"
pass "a failed deploy-workflow run regresses the release and a missing run is awaiting it"

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
cat > "$HOME_FB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":7,"url":"https://github.com/Muso-AI/hydra/actions/runs/7"}]'
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
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":9,"url":"https://github.com/Muso-AI/hydra/actions/runs/9"}]' \
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
env FM_HOME="$HOME_WN" FM_STATE_OVERRIDE="$HOME_WN/state" FM_CW_NOW=1790000000 \
  FM_CW_FORGE_DIR="$HOME_WN/forge" FM_CW_CLUSTER_DIR='' FM_CW_WORKLOADS_DIR='' \
  FM_CW_GH_DIR="$HOME_WN/gh" FM_CW_SENTRY_DIR="$HOME_WN/sentry" \
  FM_CW_CONFIG_DIR="$HOME_WN/config" FM_CW_ARM_CMD="$HOME_WN/arm.sh" \
  FM_CW_ARM_LOG="$HOME_WN/arm.log" FM_CW_SEND_CMD="$HOME_WN/send.sh" \
  FM_CW_SEND_LOG="$HOME_WN/send.log" PATH="$HOME_WN/bin:$PATH" \
  "$CW" register wn1 'https://github.com/Muso-AI/hydra/pull/1383' >/dev/null \
  || fail "hydra register failed"
printf 'kind=crewmate\n' > "$HOME_WN/state/wn1.meta"
printf '%s\n' '[{"conclusion":"success","status":"completed","createdAt":"2026-09-22T06:10:00Z","databaseId":9,"url":"https://github.com/Muso-AI/hydra/actions/runs/9"}]' \
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
