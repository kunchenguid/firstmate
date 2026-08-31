#!/usr/bin/env bash
# Behavior tests for the pull-request lifecycle follow-through adapter of the
# process-to-event runner (bin/fm-procevent-pr-follow.sh).
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against stub gh/glab executables whose responses are files
# the tests rewrite between polls; nothing here asserts implementation-source
# bytes. The suite proves the load-bearing guarantees: a silent creation
# baseline, one announcement per forge event across restarts and replayed
# captures, the durable cursor surviving task cleanup and merge, the explicit
# retirement boundary, the bounded failure contract, and that remote text is
# always data and never a command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-pr-follow-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# Every reconcile-spawned child inherits this cadence, so polls are bounded to
# the test's timescale instead of the production default.
export FM_PR_FOLLOW_INTERVAL=0.1
export FM_PR_FOLLOW_FETCH_TIMEOUT=5

pe()     { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
prf()    { FM_HOME="$1" "$ROOT/bin/fm-procevent-pr-follow.sh" "${@:2}"; }

HOMES=()
PREV_HOME=
SECTION_N=0
# new_section <name-or-empty>: give this section its own PR identity (and so
# its own canonical source id, claim, and locks) plus its own home, and sweep
# the previous section's home so no lingering child can consume fixtures.
new_section() {
  if [ -n "$PREV_HOME" ]; then
    FM_HOME="$PREV_HOME" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  SECTION_N=$((SECTION_N + 1))
  GH_URL="https://github.com/octo/app/pull/$((SECTION_N + 100))"
  GL_URL="https://gitlab.example.com/grp/sub/app/-/merge_requests/$((SECTION_N + 100))"
  H="$TMP_ROOT/h-$1"
  new_home "$H"
  PREV_HOME=$H
  sid=$(prf "$H" source-id "$GH_URL")
  glsid=$(prf "$H" source-id "$GL_URL")
}

new_home() { mkdir -p "$1/state"; HOMES+=("$1"); }

sweep_teardown() {
  local home seen=$'\n'
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap sweep_teardown EXIT

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

GH_URL=
GL_URL=
sid=
glsid=
GL_FIX="$TMP_ROOT/gl"
export GL_FIX
GH_SHA1=1111111111111111111111111111111111111111
GH_SHA2=2222222222222222222222222222222222222222

# The stub gh serves every fixed query the adapter makes from TSV row files.
# Rows are what gh's own embedded jq would emit, so the tests pin the
# structural row contract while the adapter keeps doing its own validation.
cat > "$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
fix=${GH_FIX:?GH_FIX must name the fixture directory}
row() { [ -f "$fix/$1" ] && cat "$fix/$1" || printf ''; }
if [ "$1" = pr ]; then
  core=$(row core)
  [ -n "$core" ] || core=$(printf 'OPEN\t1111111111111111111111111111111111111111\talice')
  printf '%s\n' "$core"
  exit 0
fi
if [ "$1" = api ]; then
  case "$2" in
    graphql) row reviews; exit 0 ;;
    */issues/*/comments*) row comments; exit 0 ;;
    */pulls/*/comments*) row rc; exit 0 ;;
    */check-runs*) row checks; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2
exit 9
STUB
chmod +x "$FAKEBIN/gh"

# The stub glab serves raw JSON, so the adapter's own structural perl parsing
# is exercised for real.
cat > "$FAKEBIN/glab" <<'STUB'
#!/usr/bin/env bash
fix=${GL_FIX:?GL_FIX must name the fixture directory}
file() { [ -f "$fix/$1" ] && cat "$fix/$1" || printf ''; }
case "$2" in
  projects/*/merge_requests/*/discussions*) file discussions ;;
  projects/*/merge_requests/*/pipelines*) file pipelines ;;
  projects/*/merge_requests/*/approvals) file approvals ;;
  projects/*/merge_requests/*)
    j=$(file mr)
    [ -n "$j" ] || j='{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}'
    printf '%s' "$j" ;;
  *) echo "unexpected glab call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$FAKEBIN/glab"

export PATH="$FAKEBIN:$PATH"

# gh fixtures: a stable open PR with one historical comment.
gh_fix_default() {
  mkdir -p "$GH_FIX"
  printf 'OPEN\t%s\talice\n' "$GH_SHA1" > "$GH_FIX/core"
  printf '5\tbob\n' > "$GH_FIX/comments"
  : > "$GH_FIX/rc"
  : > "$GH_FIX/reviews"
  : > "$GH_FIX/checks"
}
GH_FIX="$TMP_ROOT/gh"
export GH_FIX
gh_fix_default

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

result_count() {
  local n=0 g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Latest_result <home> <source-id>: the highest-sequence captured result.
latest_result() {
  local g best=""
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    best=$g
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

wait_for_result() {  # <home> <source-id> [tries]: any result at all
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# restart_runner <home>: reconcile until a runner actually started, so a
# previous generation still releasing its machine-wide claim cannot silently
# swallow the restart.
restart_runner() {  # <home>
  local out
  for _ in $(seq 1 60); do
    out=$(pe "$1" reconcile 2>&1) || true
    case "$out" in
      *"started=1"*|*"stopped=1"*) return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

wait_for_result_count() {  # <home> <source-id> <count> [tries]
  local want=$3 n=${4:-150}
  for _ in $(seq 1 "$n"); do
    [ "$(result_count "$1" "$2")" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_wake() {  # <home> <payload-substring> [tries]
  local n=${3:-150} payload
  for _ in $(seq 1 "$n"); do
    payload=$(wake_payloads "$1")
    case "$payload" in
      *"$2"*) return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

ack() {  # <home> <sid> <sequence> <result-file>: the adapter-owned apply+ack
  prf "$1" handle "$2" "$3" "$4" >/dev/null
}

cursor_field() {  # <home> <sid> <key>
  sed -n "s/^$3=//p" "$1/state/pr-follow/$2.cursor" | head -1
}

wait_for_cursor() {  # <home> <sid> <key> <value> [tries]
  local n=${5:-150}
  for _ in $(seq 1 "$n"); do
    [ "$(cursor_field "$1" "$2" "$3")" = "$4" ] && return 0
    sleep 0.1
  done
  return 1
}

arm_gh() {  # <home> <task-id> [extra flags...]
  prf "$1" arm "${2:-task-a}" "$GH_URL" ${3+"${@:3}"}
}

# --- identity, arm, and idempotent re-arm ------------------------------------
new_section arm
gh_fix_default
assert_contains "$sid" "prf-gh-" "the GitHub source id uses the gh prefix"
sid2=$(prf "$H" source-id "$GH_URL")
assert_contains "$sid" "$sid2" "the source id is deterministic for one identity"
glsid=$(prf "$H" source-id "$GL_URL")
assert_contains "$glsid" "prf-gl-" "the GitLab source id uses the gl prefix"
if prf "$H" source-id https://github.com/octo/app/pull/seven >/dev/null 2>&1; then
  fail "a nonnumeric PR number must be refused"
fi
out=$(arm_gh "$H")
assert_contains "$out" "armed: $sid" "arm reports the canonical source id"
assert_present "$H/state/pr-follow/$sid.cursor" "arm writes the private cursor seed"
assert_present "$H/state/procevent/$sid.source" "arm registers the process-event source"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H/state/pr-follow/$sid.cursor")
assert_contains "$mode" 600 "the cursor is private"
if arm_gh "$H" task-a https://github.com/other/repo/pull/9 >/dev/null 2>&1; then
  fail "re-arming one identity with a different PR url must be refused"
fi
out=$(arm_gh "$H")
assert_contains "$out" "already armed: $sid" "re-arming is idempotent"
if prf "$H" arm 'bad task id!' "$GH_URL" >/dev/null 2>&1; then
  fail "an invalid task id must be refused"
fi
pass "arm validates identity, registers, and re-arms idempotently"

# --- the first registration baseline is silent -------------------------------
new_section baseline
gh_fix_default
arm_gh "$H" >/dev/null
out=$(FM_PR_FOLLOW_INTERVAL=0.1 FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
assert_contains "$(printf '%s' "$out" | wc -c | tr -d ' ')" 0 \
  "the first registration baseline announces nothing"
assert_contains "$(cursor_field "$H" "$sid" baseline)" "done" "the baseline is stored"
assert_contains "$(cursor_field "$H" "$sid" max_issue_comment)" 5 "the baseline stores the current comment maximum"
assert_contains "$(cursor_field "$H" "$sid" head)" "$GH_SHA1" "the baseline stores the head"
pass "the first registration baseline is silent and durable"

# --- an open PR comment reaches the durable wake queue as data ---------------
new_section comment
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
[ "$(cursor_field "$H" "$sid" baseline)" = "done" ] || fail "the baseline never completed under the runner"
printf '5\tbob\n9\tcarol\n' > "$GH_FIX/comments"
wait_for_result "$H" "$sid" || fail "a new open PR comment produced no captured result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: comment id=9 author=carol' "$RESULT" "the new comment is announced with its forge id"
assert_grep 'status: events' "$RESULT" "the document classifies as events"
wait_for_wake "$H" "procevent pr-follow $sid 1" || fail "the event never reached the durable wake queue"
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent pr-follow $sid 1" "the wake names the stable source and sequence"
assert_not_contains "$payload" "carol" "remote author text never reaches the event line"
pass "an open PR comment is announced once through the durable queue"

# --- inline review comments and replies --------------------------------------
new_section inline
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf '6\t0\tcodex\tsrc/x.py\t10\n' > "$GH_FIX/rc"
wait_for_result "$H" "$sid" || fail "a new inline review comment produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review-comment id=6 author=codex path=src/x.py line=10' "$RESULT" \
  "the inline comment is announced with its path and line"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '6\t0\tcodex\tsrc/x.py\t10\n7\t6\talice\tsrc/x.py\t10\n' > "$GH_FIX/rc"
if ! wait_for_result_count "$H" "$sid" 2; then
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" list >&2
  ls -la "$H/state/procevent-inbox/" >&2
  cat "$H/state/pr-follow/$sid.cursor" >&2
  fail "an inline reply produced no result"
fi
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: review-comment id=7 author=alice reply-to=6' "$RESULT" \
  "the reply is announced against its thread root"
ack "$H" "$sid" 2 "$RESULT"
pass "inline review comments and replies are announced with thread identity"

# --- review submissions and state changes ------------------------------------
new_section review
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf '30\tAPPROVED\tcarol\n' > "$GH_FIX/reviews"
wait_for_result "$H" "$sid" || fail "a new review produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review id=30 state=APPROVED author=carol' "$RESULT" "the review submission is announced"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '30\tDISMISSED\tcarol\n' > "$GH_FIX/reviews"
wait_for_result_count "$H" "$sid" 2 || fail "a review state change produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: review-state id=30 state=DISMISSED' "$RESULT" "the dismissal is announced as a state change"
ack "$H" "$sid" 2 "$RESULT"
pass "review submissions and state changes are announced"

# --- head replacement re-baselines checks and announces the move -------------
# Deterministic by construction: the live child is stopped, the fixture set is
# rewritten whole, and one direct child poll observes the finished state.
new_section head
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
pkill -STOP -f "fm-procevent-pr-follow.sh run $sid" 2>/dev/null || true
sleep 0.3
pkill -KILL -f "fm-procevent-pr-follow.sh run $sid" 2>/dev/null || true
pkill -f "fm-procevent.sh _start pr-follow $sid" 2>/dev/null || true
sleep 0.3
printf '70\tcompleted:success\tci/linux\n' > "$GH_FIX/checks"
printf '72\tcompleted:failure\tci/linux\n' >> "$GH_FIX/checks"
printf 'OPEN\t%s\talice\n' "$GH_SHA2" > "$GH_FIX/core"
out=$(FM_HOME="$H" perl -e 'alarm 2; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
printf '%s\n' "$out" > "$TMP_ROOT/head-doc"
assert_grep "event: head from=${GH_SHA1%"${GH_SHA1#????????????}"} to=${GH_SHA2%"${GH_SHA2#????????????}"}" "$TMP_ROOT/head-doc" \
  "the head move is announced with both short shas"
assert_no_grep 'event: check id=72' "$TMP_ROOT/head-doc" \
  "the new head's existing checks are re-baselined silently, not announced"
assert_no_grep 'event: check id=70' "$TMP_ROOT/head-doc" \
  "the new head's surviving checks are re-baselined silently too"
# File the observed document as this generation's capture and apply it, so the
# cursor advances exactly as the runner would have advanced it.
mkdir -p "$H/state/procevent-inbox"
RESULT="$H/state/procevent-inbox/$sid.1.result"
cp "$TMP_ROOT/head-doc" "$RESULT"
printf 'pr-follow\n' > "$H/state/procevent-inbox/$sid.1.adapter"
chmod 600 "$RESULT" "$H/state/procevent-inbox/$sid.1.adapter"
ack "$H" "$sid" 1 "$RESULT"
wait_for_cursor "$H" "$sid" head "$GH_SHA2" || fail "the runner never applied the head move"
assert_contains "$(cursor_field "$H" "$sid" head)" "$GH_SHA2" "the cursor advanced to the new head"
restart_runner "$H"
printf '72\tcompleted:success\tci/linux\n' > "$GH_FIX/checks"
wait_for_result_count "$H" "$sid" 2 || fail "a check recovery on the new head produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=red->green' "$RESULT" "the recovery is labeled"
ack "$H" "$sid" 2 "$RESULT"
pass "head replacement announces the move and re-baselines its checks"

# --- check regressions, pending transitions, and recovery --------------------
new_section checks
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf '80\tin_progress\tbuild\n' > "$GH_FIX/checks"
wait_for_result "$H" "$sid" || fail "a new pending check produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: check id=80 name=build change=none->pending' "$RESULT" "a new pending check is announced"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '80\tcompleted:success\tbuild\n' > "$GH_FIX/checks"
wait_for_result_count "$H" "$sid" 2 || fail "the pending->green transition produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=pending->green' "$RESULT" "the pending transition is announced"
ack "$H" "$sid" 2 "$RESULT"
restart_runner "$H"
printf '80\tcompleted:failure\tbuild\n' > "$GH_FIX/checks"
wait_for_result_count "$H" "$sid" 3 || fail "the regression produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=green->red' "$RESULT" "a green->red regression is labeled"
ack "$H" "$sid" 3 "$RESULT"
restart_runner "$H"
printf '80\tcompleted:success\tbuild\n' > "$GH_FIX/checks"
wait_for_result_count "$H" "$sid" 4 || fail "the recovery produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=red->green' "$RESULT" "a red->green recovery is labeled"
ack "$H" "$sid" 4 "$RESULT"
pass "check additions, pending transitions, regressions, and recoveries are announced"

# --- merge keeps tracking: merge event, then post-merge comment --------------
new_section merge
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf 'MERGED\t%s\talice\n' "$GH_SHA1" > "$GH_FIX/core"
wait_for_result "$H" "$sid" || fail "the merge produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: pr-state from=open state=merged' "$RESULT" "the merge is announced"
assert_present "$H/state/procevent/$sid.source" "a merged PR keeps its lifecycle registration"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '5\tbob\n13\tdave\n' > "$GH_FIX/comments"
wait_for_result_count "$H" "$sid" 2 || fail "a post-merge comment produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: comment id=13 author=dave' "$RESULT" "a post-merge comment is still announced"
ack "$H" "$sid" 2 "$RESULT"
pass "merge is announced, tracking continues after merge"

# --- close and reopen ---------------------------------------------------------
new_section close
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf 'CLOSED\t%s\talice\n' "$GH_SHA1" > "$GH_FIX/core"
wait_for_result "$H" "$sid" || fail "the close produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: pr-state from=open state=closed' "$RESULT" "the close is announced"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf 'OPEN\t%s\talice\n' "$GH_SHA1" > "$GH_FIX/core"
wait_for_result_count "$H" "$sid" 2 || fail "the reopen produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: pr-state from=closed state=open' "$RESULT" "the reopen is announced"
ack "$H" "$sid" 2 "$RESULT"
pass "close and reopen are announced"

# --- duplicate and reordered API pages announce once -------------------------
new_section pages
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf '5\tbob\n9\tcarol\n9\tcarol\n5\tbob\n' > "$GH_FIX/comments"
wait_for_result "$H" "$sid" || fail "the new comment behind duplicate rows produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: comment id=9 author=carol' "$RESULT" "the comment is announced"
count=$(grep -c 'event: comment id=9' "$RESULT" || true)
assert_contains "$count" 1 "a duplicate row announces the event exactly once"
ack "$H" "$sid" 1 "$RESULT"
pass "duplicate API rows never duplicate an announcement"

# --- restart and byte-identical replay ---------------------------------------
new_section restart
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
# Simulate a lost acknowledgement: capture the result, then run the child
# again before any apply happened.
printf '5\tbob\n9\tcarol\n' > "$GH_FIX/comments"
wait_for_result "$H" "$sid" || fail "no result before the restart"
first="$H/state/procevent-inbox/$sid.1.result"
cp "$first" "$TMP_ROOT/restart-copy"
before=$(result_count "$H" "$sid")
out=$(FM_PR_FOLLOW_INTERVAL=0.1 FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
after=$(result_count "$H" "$sid")
assert_contains "$after" "$before" "a recomputed poll after an unapplied capture adds no second document while the cursor holds"
# The applied cursor advance makes the same poll silent.
FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" autohandle "$sid" 1 "$first" >/dev/null
out=$(FM_PR_FOLLOW_INTERVAL=0.1 FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
assert_contains "$(printf '%s' "$out" | wc -c | tr -d ' ')" 0 \
  "after the applied cursor advance the same remote state is silent"
# Byte-identical replay of one generation acknowledges exactly once.
out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$sid" 1 "$first")
assert_contains "$out" "already-applied: $sid 1" "a byte-identical replay reports already-applied"
cp "$first" "$TMP_ROOT/tampered"
printf 'x' >> "$TMP_ROOT/tampered"
if FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$sid" 1 "$TMP_ROOT/tampered" >/dev/null 2>&1; then
  fail "a conflicting generation under one sequence must be refused"
fi
pass "restart recomputes safely and replay is receipt-deduplicated"

# --- bounded API failure records diagnostics and later recovers --------------
cat > "$FAKEBIN/gh-flaky" <<'STUB'
#!/usr/bin/env bash
if [ -e "$FLAKY_DOWN" ]; then
  echo "gh: server error" >&2
  exit 1
fi
exec "$FAKEBIN_REAL_GH" "$@"
STUB
chmod +x "$FAKEBIN/gh-flaky"
new_section error
gh_fix_default
mv "$FAKEBIN/gh" "$FAKEBIN/gh-save"
cp "$FAKEBIN/gh-flaky" "$FAKEBIN/gh"
FAKEBIN_REAL_GH="$FAKEBIN/gh-save"
export FAKEBIN_REAL_GH
FLAKY_DOWN="$TMP_ROOT/down"
export FLAKY_DOWN
touch "$FLAKY_DOWN"
arm_gh "$H" >/dev/null
# The baseline itself fails: the error budget produces one diagnostic doc.
out=$(FM_PR_FOLLOW_INTERVAL=0.1 FM_HOME="$H" perl -e 'alarm 4; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
printf '%s' "$out" > "$TMP_ROOT/errdoc"
assert_grep 'status: error' "$TMP_ROOT/errdoc" "the exhausted error budget produces a diagnostic document"
assert_no_grep 'event:' "$TMP_ROOT/errdoc" "an error document invents no forge event"
assert_not_contains "$out" "server error" "remote stderr text never reaches the document"
assert_contains "$(cursor_field "$H" "$sid" baseline)" pending "a failed baseline never invents one"
# Recovery: the stub heals, and the next healthy poll baselines normally.
mv "$FAKEBIN/gh-save" "$FAKEBIN/gh"
rm -f "$FLAKY_DOWN"
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
[ "$(cursor_field "$H" "$sid" baseline)" = "done" ] || fail "tracking did not recover after the API healed"
pass "bounded failures record diagnostics and recovery resumes from the cursor"

# --- malformed and hostile remote payloads stay data --------------------------
new_section hostile
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
PWNED="$TMP_ROOT/pwned"
rm -f "$PWNED"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
printf '9\t$(touch %s)\n' "$PWNED" > "$GH_FIX/comments"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
printf '6\t0\tcodex\t$(touch %s)\t10\n' "$PWNED" > "$GH_FIX/rc"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
printf '70\tcompleted:success\t$(touch %s)\n' "$PWNED" > "$GH_FIX/checks"
wait_for_result "$H" "$sid" || fail "hostile payload produced no result"
RESULT=$(first_result "$H" "$sid")
[ -e "$PWNED" ] && fail "remote text executed a command"
assert_grep 'event: comment id=9' "$RESULT" "the hostile comment is still announced as an event"
# shellcheck disable=SC2016 # The needle is literal hostile payload text.
assert_not_contains '$(touch' "$RESULT" "command substitution text is sanitized out of the document"
ack "$H" "$sid" 1 "$RESULT"
# A doctored cursor section is refused whole.
printf '%s\n' \
  'schema: fm-pr-follow-event-v1' \
  "source: $sid" \
  'provider: github' \
  "url: $GH_URL" \
  'number: 7' \
  'status: events' \
  "head: $GH_SHA1" \
  'state: open' \
  'dropped: 0' \
  'events: 0' \
  'cursor:' \
  'head=not-a-sha' \
  'state=open' \
  'max_issue_comment=0' \
  'max_review=0' \
  'max_review_comment=0' \
  'reviews=' \
  'checks=' \
  'threads=' \
  'approvals=' \
  'backfill=off' \
  'generation=1' > "$TMP_ROOT/doctored"
if FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$sid" 2 "$TMP_ROOT/doctored" >/dev/null 2>&1; then
  fail "a doctored cursor document must be refused"
fi
if [ -e "$H/state/pr-follow/$sid.2.applied" ]; then
  fail "a refused document must not leave an applied receipt"
fi
pass "hostile remote data stays data and doctored documents are refused"

# --- task cleanup never erases lifecycle tracking -----------------------------
new_section cleanup
gh_fix_default
arm_gh "$H" task-live >/dev/null
# Simulate the task landing: the merge poll retires task artifacts exactly as
# cleanup does, while lifecycle state lives elsewhere.
rm -f "$H/state/task-live.check.sh" "$H/state/task-live.pr-poll" \
  "$H/state/task-live.pr-poll-registration" "$H/state/task-live.pr-poll-retirement"
assert_present "$H/state/procevent/$sid.source" "cleanup leaves the lifecycle registration"
assert_present "$H/state/pr-follow/$sid.cursor" "cleanup leaves the lifecycle cursor"
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
[ "$(cursor_field "$H" "$sid" baseline)" = "done" ] || fail "tracking stopped after task cleanup"
printf '5\tbob\n9\tcarol\n' > "$GH_FIX/comments"
wait_for_result "$H" "$sid" || fail "no events after task cleanup"
pass "task cleanup does not erase lifecycle follow-through"

# --- explicit auditable retirement --------------------------------------------
new_section retire
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$sid" baseline)" = "done" ] && break
  sleep 0.1
done
printf '5\tbob\n9\tcarol\n' > "$GH_FIX/comments"
wait_for_result "$H" "$sid" || fail "no result before retirement"
if prf "$H" retire "$sid" >/dev/null 2>&1; then
  fail "retirement must refuse while unhandled captured results exist"
fi
out=$(prf "$H" retire "$sid" --force)
assert_contains "$out" "retired: $sid" "the explicit retirement reports what it retired"
assert_absent "$H/state/procevent/$sid.source" "retirement drops the registration"
assert_absent "$H/state/pr-follow/$sid.cursor" "retirement removes the cursor"
out=$(prf "$H" retire "$sid" --force)
assert_contains "$out" "retired: $sid" "retirement is idempotent"
pe "$H" reconcile >/dev/null
sleep 0.3
assert_contains "$(result_count "$H" "$sid")" 1 "a retired source produces no further results"
pass "explicit retirement is the one auditable off switch"

# --- backfill surfaces currently unanswered threads ---------------------------
new_section backfill
gh_fix_default
# The PR author is alice; codex holds the last word on one thread. Rows are
# newest first, as the descending API pages deliver them.
printf '8\t0\tcodex\tsrc/y.py\t20\n' > "$GH_FIX/rc"
printf '7\t6\talice\tsrc/x.py\t10\n' >> "$GH_FIX/rc"
printf '6\t0\tcodex\tsrc/x.py\t10\n' >> "$GH_FIX/rc"
arm_gh "$H" task-old --backfill >/dev/null
out=$(FM_HOME="$H" perl -e 'alarm 10; exec @ARGV' "$ROOT/bin/fm-procevent.sh" start "$sid" 2>&1)
printf '%s\n' "$out" > "$TMP_ROOT/bf-start"
assert_grep 'captured:' "$TMP_ROOT/bf-start" "the runner captured the backfill document"
RESULT=$(first_result "$H" "$sid")
assert_grep 'status: backfill' "$RESULT" "the backfill document classifies as backfill"
assert_grep 'event: backfill-thread id=8 last-author=codex' "$RESULT" \
  "the unanswered thread is surfaced"
assert_no_grep 'backfill-thread id=6' "$RESULT" \
  "a thread the PR author answered is not surfaced"
ack "$H" "$sid" 1 "$RESULT"
assert_contains "$(cursor_field "$H" "$sid" backfill)" "done" "the applied backfill latches done"
before=$(result_count "$H" "$sid")
pe "$H" reconcile >/dev/null
sleep 0.5
assert_contains "$(result_count "$H" "$sid")" "$before" "the backfill never re-announces after it is applied"
pass "existing-PR backfill surfaces unanswered threads exactly once"

# --- the guarded migration sweep arms every recorded PR once ------------------
new_section sweep
gh_fix_default
cat > "$H/state/pr-one.meta" <<META
task=pr-one
pr=https://github.com/octo/app/pull/7
META
cat > "$H/state/pr-two.meta" <<META
task=pr-two
pr=https://github.com/octo/app/pull/8
META
cat > "$H/state/plain.meta" <<META
task=plain
branch=feature/no-pr
META
out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" backfill)
printf '%s\n' "$out" > "$TMP_ROOT/sweep"
assert_grep 'backfill: armed prf-gh-' "$TMP_ROOT/sweep" "the sweep arms recorded PRs"
assert_grep 'backfill summary: scanned=3 armed=2 already=0 skipped=0 capped=0' "$TMP_ROOT/sweep" \
  "the sweep summary counts every recorded meta"
out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" backfill)
printf '%s\n' "$out" > "$TMP_ROOT/sweep2"
assert_grep 'backfill summary: scanned=3 armed=0 already=2 skipped=0 capped=0' "$TMP_ROOT/sweep2" \
  "the sweep is idempotent"
pass "the guarded migration sweep arms every recorded PR exactly once"

# --- GitLab lifecycle events through the real JSON parser ---------------------
new_section gitlab
gh_fix_default
mkdir -p "$GL_FIX"
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[{"id":"D1","resolved":false,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/x.py","new_line":10}}]}]' > "$GL_FIX/discussions"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
out=$(prf "$H" arm task-gl "$GL_URL")
assert_contains "$out" "armed: $glsid" "the GitLab identity arms"
pe "$H" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(cursor_field "$H" "$glsid" baseline)" = "done" ] && break
  sleep 0.1
done
[ "$(cursor_field "$H" "$glsid" baseline)" = "done" ] || fail "the GitLab baseline never completed"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"success"}]' > "$GL_FIX/pipelines"
printf '{"approved_by":[{"user":{"username":"dave"}}]}' > "$GL_FIX/approvals"
wait_for_result "$H" "$glsid" || fail "GitLab transitions produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: check id=7 change=pending->green status=success' "$RESULT" "the pipeline recovery is announced"
assert_grep 'event: review id=approval-dave state=APPROVED author=dave' "$RESULT" "the approval grant is announced"
ack "$H" "$glsid" 1 "$RESULT"
restart_runner "$H"
printf '[{"id":"D1","resolved":true,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/x.py","new_line":10}}]}]' > "$GL_FIX/discussions"
printf '{"state":"merged","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
wait_for_result_count "$H" "$glsid" 2 || fail "GitLab merge and resolve produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: thread id=D1 state=resolved' "$RESULT" "the thread resolution is announced"
assert_grep 'event: pr-state from=open state=merged' "$RESULT" "the GitLab merge is announced"
ack "$H" "$glsid" 2 "$RESULT"
assert_present "$H/state/procevent/$glsid.source" "a merged GitLab MR keeps its registration"
pass "GitLab comments, pipelines, approvals, threads, and merge are tracked"

printf 'all fm-procevent-pr-follow tests passed\n'
