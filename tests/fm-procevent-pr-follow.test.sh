#!/usr/bin/env bash
# Behavior tests for the pull-request lifecycle follow-through adapter of the
# process-to-event runner (bin/fm-procevent-pr-follow.sh).
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against stub gh/glab executables that serve representative
# forge API payloads as raw JSON; the adapter's own production projections
# (its real --jq filters and its real JSON::PP programs) produce every row the
# tests assert on, so no fixture can drift from what the forge path emits.
# Nothing here asserts implementation-source bytes. The suite proves the
# load-bearing guarantees: a silent creation baseline, one announcement per
# forge event across restarts and replayed captures, the shared-vocabulary
# contract (unknown check, review, pipeline, and lifecycle words round-trip
# instead of bricking tracking), bounded monitoring loss, the deterministic
# aggregate polling bound, the durable cursor surviving task cleanup and
# merge, the explicit retirement boundary, the bounded failure contract, and
# that remote text is always data and never a command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-pr-follow-tests)
# Claim ownership records a home's physically resolved state root and refuses
# any home whose path reaches it through a symlink, so a TMPDIR that is itself
# a link (macOS resolves /var to /private/var) would make every reconcile fail
# to claim and no child would ever poll. Resolve the suite's root once so the
# homes built under it are the same path the runner canonicalizes.
TMP_ROOT=$(cd -P -- "$TMP_ROOT" && pwd -P) \
  || fail "could not physically resolve the test temp root"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# Every reconcile-spawned child inherits these cadences, so polls are bounded
# to the test's timescale instead of the production defaults: one rotation
# slot per second and the minimum diagnostic pause.
export FM_PR_FOLLOW_INTERVAL=0.1
export FM_PR_FOLLOW_FETCH_TIMEOUT=5
export FM_PR_FOLLOW_ROTATION_SLOT=1
command -v jq >/dev/null 2>&1 \
  || fail "these tests apply the adapter's real forge projections with jq, which was not found"

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
  # Give the section its own poll log too: a previous section's child that
  # outlived its home's sweep keeps the log it started with, so it can never
  # be counted as a poll burst of the home under measurement.
  GH_TEST_POLL_LOG="$TMP_ROOT/gh-poll-$SECTION_N.log"
  export GH_TEST_POLL_LOG
  : > "$GH_TEST_POLL_LOG"
  sid=$(prf "$H" source-id "$GH_URL")
  glsid=$(prf "$H" source-id "$GL_URL")
  scheduler_id=$(prf "$H" scheduler-id)
}

new_home() { mkdir -p "$1/state"; HOMES+=("$1"); }

sweep_teardown() {
  local home seen=$'\n'
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+=$home$'\n'
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
scheduler_id=
GL_FIX="$TMP_ROOT/gl"
export GL_FIX
GH_SHA1=1111111111111111111111111111111111111111
GH_SHA2=2222222222222222222222222222222222222222
GH_TEST_POLL_LOG="$TMP_ROOT/gh-poll.log"
export GH_TEST_POLL_LOG

# The stub gh serves raw JSON payloads and applies the adapter's real --jq / -q
# projections with the real jq, so the tests exercise exactly the forge-side
# field selection, normalization, and token composition production uses.
cat > "$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
fix=${GH_FIX:?GH_FIX must name the fixture directory}
filter=
want=
for a in "$@"; do
  if [ "$want" = 1 ]; then
    filter=$a
    want=0
  else
    case "$a" in
      --jq|-q) want=1 ;;
    esac
  fi
done
serve() { jq -r "${filter:-.}" "$1" 2>/dev/null || exit 9; }
included() {
  local total=$1
  if [[ " $* " = *" --include "* ]]; then
    printf 'HTTP/2.0 200 OK\n'
    if [ "$total" -gt 1 ]; then
      printf 'Link: <https://api.github.test/items?per_page=100&page=%s>; rel="last"\n' "$total"
    fi
    printf '\n'
  fi
}
if [ "$1" = api ]; then
  case "$2" in
    *pulls/*/reviews*)
      total=$(cat "$fix/reviews.total-pages" 2>/dev/null || printf '1')
      page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p')
      page=${page:-1}
      included "$total" "$@"
      [ -f "$fix/reviews.page.$page" ] && serve "$fix/reviews.page.$page" || serve "$fix/reviews.json"
      ;;
    *issues/*/comments*)
      total=$(cat "$fix/comments.total-pages" 2>/dev/null || printf '1')
      page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); page=${page:-1}
      included "$total" "$@"
      [ -f "$fix/comments.page.$page" ] && serve "$fix/comments.page.$page" || serve "$fix/comments.json" ;;
    *pulls/*/comments*)
      total=$(cat "$fix/rc.total-pages" 2>/dev/null || printf '1')
      page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); page=${page:-1}
      included "$total" "$@"
      [ -f "$fix/rc.page.$page" ] && serve "$fix/rc.page.$page" || serve "$fix/rc.json" ;;
    repos/*/pulls/*)                [ -n "${GH_TEST_POLL_LOG:-}" ] && printf 'view\n' >> "$GH_TEST_POLL_LOG"; serve "$fix/pr.json" ;;
    *check-runs*)
      total=$(cat "$fix/checks.total-pages" 2>/dev/null || printf '1')
      page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); page=${page:-1}
      included "$total" "$@"
      [ -f "$fix/checks.page.$page" ] && serve "$fix/checks.page.$page" || serve "$fix/checks.json" ;;
    *) echo "unexpected gh api path: $2" >&2; exit 9 ;;
  esac
  exit 0
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
  projects/*/merge_requests/*/discussions*)
    total=$(file discussions.total-pages)
    total=${total:-1}
    page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p')
    page=${page:-1}
    if [[ " $* " = *" --include "* ]]; then
      printf 'HTTP/2.0 200 OK\nX-Total-Pages: %s\n\n' "$total"
    fi
    [ -f "$fix/discussions.page.$page" ] && file "discussions.page.$page" || file discussions
    ;;
  projects/*/merge_requests/*/pipelines*)
    total=$(file pipelines.total-pages); total=${total:-1}
    page=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); page=${page:-1}
    if [[ " $* " = *" --include "* ]]; then
      printf 'HTTP/2.0 200 OK\nX-Total-Pages: %s\n\n' "$total"
    fi
    [ -f "$fix/pipelines.page.$page" ] && file "pipelines.page.$page" || file pipelines ;;
  projects/*/merge_requests/*/approvals)
    file approvals
    [ ! -e "$fix/approvals.exit" ] || exit 1
    ;;
  projects/*/merge_requests/*)
    j=$(file mr)
    [ -n "$j" ] || j='{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}'
    printf '%s' "$j" ;;
  *) echo "unexpected glab call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$FAKEBIN/glab"

export PATH="$FAKEBIN:$PATH"

# gh fixtures: a stable open PR with one historical comment. Every file is a
# representative REST payload; the adapter's projections derive rows.
gh_fix_default() {
  mkdir -p "$GH_FIX"
  rm -f "$GH_FIX"/*.page.* "$GH_FIX"/*.total-pages
  printf '{"state":"open","merged_at":null,"head":{"sha":"%s"},"user":{"login":"alice"}}\n' "$GH_SHA1" > "$GH_FIX/pr.json"
  printf '[{"id":5,"user":{"login":"bob"}}]\n' > "$GH_FIX/comments.json"
  printf '[]\n' > "$GH_FIX/rc.json"
  printf '[]\n' > "$GH_FIX/reviews.json"
  printf '{"check_runs":[]}\n' > "$GH_FIX/checks.json"
}
GH_FIX="$TMP_ROOT/gh"
export GH_FIX
gh_fix_default

# gh_state <OPEN|CLOSED|MERGED|<anything>> [sha]: rewrite the core payload.
gh_state() {
  local state=${1:-OPEN} api_state merged=null
  case "$state" in
    OPEN) api_state=open ;;
    CLOSED) api_state=closed ;;
    MERGED) api_state=closed; merged='"2026-09-01T00:00:00Z"' ;;
    *) api_state=$state ;;
  esac
  printf '{"state":"%s","merged_at":%s,"head":{"sha":"%s"},"user":{"login":"alice"}}\n' \
    "$api_state" "$merged" "${2:-$GH_SHA1}" > "$GH_FIX/pr.json"
}

# gh_checks_json <json-array>: rewrite the check-run payload.
gh_checks() {
  printf '{"check_runs":%s}\n' "$1" > "$GH_FIX/checks.json"
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>
  local g scheduler
  scheduler=$(prf "$1" scheduler-id)
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  for g in "$1/state/procevent-inbox/$scheduler".*.result; do
    [ -e "$g" ] || continue
    [ "$(sed -n 's/^target: //p' "$g")" = "$2" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

result_count() {
  local n=0 g scheduler
  scheduler=$(prf "$1" scheduler-id)
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    n=$((n + 1))
  done
  for g in "$1/state/procevent-inbox/$scheduler".*.result; do
    [ -e "$g" ] || continue
    [ "$(sed -n 's/^target: //p' "$g")" = "$2" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Latest_result <home> <source-id>: the highest-sequence captured result.
latest_result() {
  local g best="" scheduler
  scheduler=$(prf "$1" scheduler-id)
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    best=$g
  done
  for g in "$1/state/procevent-inbox/$scheduler".*.result; do
    [ -e "$g" ] || continue
    [ "$(sed -n 's/^target: //p' "$g")" = "$2" ] || continue
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

# result_matching <home> <source-id> <fixed-string>: the first captured result
# for this source whose body carries the string, so an assertion about one
# announcement cannot depend on which capture happens to be newest.
result_matching() {
  local g scheduler target
  scheduler=$(prf "$1" scheduler-id)
  for g in "$1/state/procevent-inbox/$2".*.result "$1/state/procevent-inbox/$scheduler".*.result; do
    [ -e "$g" ] || continue
    target=$(sed -n 's/^target: //p' "$g")
    [ -z "$target" ] || [ "$target" = "$2" ] || continue
    grep -F -- "$3" "$g" >/dev/null || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result_matching() {  # <home> <source-id> <fixed-string> [tries]
  local n=${4:-150}
  for _ in $(seq 1 "$n"); do
    result_matching "$1" "$2" "$3" >/dev/null 2>&1 && return 0
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
  local capture seq
  capture=$(sed -n 's/^source: //p' "$4")
  seq=${4%.result}
  seq=${seq##*.}
  prf "$1" handle "$capture" "$seq" "$4" >/dev/null
}

handle_result() {
  local capture
  capture=$(sed -n 's/^source: //p' "$3")
  prf "$1" handle "$capture" "$2" "$3"
}

cursor_field() {  # <home> <sid> <key>
  sed -n "s/^$3=//p" "$1/state/pr-follow/$2.cursor" | head -1
}

cursor_set_field() {
  local file="$1/state/pr-follow/$2.cursor" tmp="$1/state/pr-follow/.test-cursor"
  awk -F= -v key="$3" -v value="$4" '$1 == key {$0 = key "=" value} {print}' "$file" > "$tmp" \
    || return 1
  chmod 600 "$tmp" && mv -f -- "$tmp" "$file"
}

wait_for_cursor() {  # <home> <sid> <key> <value> [tries]
  local n=${5:-150}
  for _ in $(seq 1 "$n"); do
    [ "$(cursor_field "$1" "$2" "$3")" = "$4" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_baseline() {  # <home> <sid> [tries]
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    [ "$(cursor_field "$1" "$2" baseline)" = "done" ] && return 0
    sleep 0.1
  done
  return 1
}

arm_gh() {  # <home> <task-id> [extra flags...]
  prf "$1" arm "${2:-task-a}" "$GH_URL" ${3+"${@:3}"} --seed-head "$GH_SHA1"
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
assert_present "$H/state/procevent/$scheduler_id.source" "arm registers one home scheduler"
assert_absent "$H/state/procevent/$sid.source" "arm does not register a resident process per PR"
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
out=$(FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
[ -z "$out" ] || fail "the first registration baseline announced: $out"
assert_contains "$(cursor_field "$H" "$sid" baseline)" "done" "the baseline is stored"
assert_contains "$(cursor_field "$H" "$sid" max_issue_comment)" 5 "the baseline stores the current comment maximum"
assert_contains "$(cursor_field "$H" "$sid" head)" "$GH_SHA1" "the baseline stores the head"
pass "the first registration baseline is silent and durable"

new_section baseline-boundary
gh_fix_default
arm_gh "$H" >/dev/null
printf '[{"id":5,"user":{"login":"bob"}},{"id":9,"user":{"login":"carol"},"created_at":"2099-01-01T00:00:00Z"}]\n' > "$GH_FIX/comments.json"
pe "$H" reconcile >/dev/null
wait_for_result "$H" "$sid" || fail "post-registration activity was swallowed by the baseline"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: comment id=9 author=carol' "$RESULT" \
  "the arm-time boundary preserves activity arriving during a paged baseline"
assert_no_grep 'event: head ' "$RESULT" \
  "a comment during baseline is not mislabeled as a head replacement"
assert_no_grep 'event: pr-state ' "$RESULT" \
  "a comment during baseline is not mislabeled as a lifecycle transition"
ack "$H" "$sid" 1 "$RESULT"
pass "the baseline distinguishes history from post-registration activity"

# --- an open PR comment reaches the durable wake queue as data ---------------
new_section comment
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed under the runner"
printf '[{"id":5,"user":{"login":"bob"}},{"id":9,"user":{"login":"carol"}}]\n' > "$GH_FIX/comments.json"
wait_for_result "$H" "$sid" || fail "a new open PR comment produced no captured result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: comment id=9 author=carol' "$RESULT" "the new comment is announced with its forge id"
assert_grep 'status: events' "$RESULT" "the document classifies as events"
wait_for_wake "$H" "procevent pr-follow $scheduler_id 1" || fail "the event never reached the durable wake queue"
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent pr-follow $scheduler_id 1" "the wake names the scheduler and sequence"
assert_not_contains "$payload" "carol" "remote author text never reaches the event line"
pass "an open PR comment is announced once through the durable queue"

# --- inline review comments and replies --------------------------------------
new_section inline
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf '[{"id":6,"in_reply_to_id":null,"user":{"login":"codex"},"path":"src/x.py","line":10}]\n' > "$GH_FIX/rc.json"
wait_for_result "$H" "$sid" || fail "a new inline review comment produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review-comment id=6 author=codex path=src/x.py line=10' "$RESULT" \
  "the inline comment is announced with its path and line"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '[{"id":7,"in_reply_to_id":6,"user":{"login":"alice"},"path":"src/x.py","line":10},{"id":6,"in_reply_to_id":null,"user":{"login":"codex"},"path":"src/x.py","line":10}]\n' > "$GH_FIX/rc.json"
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
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf '[{"id":30,"state":"APPROVED","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
wait_for_result "$H" "$sid" || fail "a new review produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review id=30 state=APPROVED author=carol' "$RESULT" "the review submission is announced"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '[{"id":30,"state":"DISMISSED","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
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
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
pkill -STOP -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null || true
sleep 0.3
pkill -KILL -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null || true
pkill -f "fm-procevent.sh _start $scheduler_id" 2>/dev/null || true
sleep 0.3
gh_checks '[{"id":70,"status":"completed","conclusion":"success","name":"ci/linux"},{"id":72,"status":"completed","conclusion":"failure","name":"ci/linux"}]'
gh_state OPEN "$GH_SHA2"
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
gh_checks '[{"id":72,"status":"completed","conclusion":"success","name":"ci/linux"}]'
wait_for_result_count "$H" "$sid" 2 || fail "a check recovery on the new head produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=red->green' "$RESULT" "the recovery is labeled"
ack "$H" "$sid" 2 "$RESULT"
pass "head replacement announces the move and re-baselines its checks"

# --- an unrecorded head heals instead of silencing every later transition ----
new_section headheal
gh_fix_default
gh_checks '[{"id":80,"status":"completed","conclusion":"success","name":"build"}]'
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
# Model a baseline whose announcement never reached the cursor: tracking is
# complete but the head it announced was never durably recorded.
cursor_set_field "$H" "$sid" head "" || fail "could not model the unrecorded head"
restart_runner "$H"
wait_for_result "$H" "$sid" || fail "an unrecorded head silenced every announcement"
RESULT=$(first_result "$H" "$sid")
assert_grep "event: head from=unknown to=${GH_SHA1%"${GH_SHA1#????????????}"}" "$RESULT" \
  "an unrecorded head is announced as a first observation"
ack "$H" "$sid" 1 "$RESULT"
wait_for_cursor "$H" "$sid" head "$GH_SHA1" || fail "the announced head never reached the cursor"
restart_runner "$H"
gh_checks '[{"id":80,"status":"completed","conclusion":"failure","name":"build"}]'
wait_for_result_count "$H" "$sid" 2 || fail "the check regression produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=green->red' "$RESULT" "check transitions resume once the head is recorded"
ack "$H" "$sid" 2 "$RESULT"
pass "an unrecorded head is announced instead of silencing check transitions"

# --- check regressions, pending transitions, and recovery --------------------
new_section checks
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
gh_checks '[{"id":80,"status":"in_progress","conclusion":null,"name":"build"}]'
wait_for_result "$H" "$sid" || fail "a new pending check produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: check id=80 name=build change=none->pending status=in_progress:none' "$RESULT" \
  "a new pending check is announced with its real composite token"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
gh_checks '[{"id":80,"status":"completed","conclusion":"success","name":"build"}]'
wait_for_result_count "$H" "$sid" 2 || fail "the pending->green transition produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=pending->green' "$RESULT" "the pending transition is announced"
ack "$H" "$sid" 2 "$RESULT"
restart_runner "$H"
gh_checks '[{"id":80,"status":"completed","conclusion":"failure","name":"build"}]'
wait_for_result_count "$H" "$sid" 3 || fail "the regression produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=green->red' "$RESULT" "a green->red regression is labeled"
ack "$H" "$sid" 3 "$RESULT"
restart_runner "$H"
gh_checks '[{"id":80,"status":"completed","conclusion":"success","name":"build"}]'
wait_for_result_count "$H" "$sid" 4 || fail "the recovery produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=red->green' "$RESULT" "a red->green recovery is labeled"
ack "$H" "$sid" 4 "$RESULT"
assert_contains "$(cursor_field "$H" "$sid" checks)" "80:completed:success" \
  "the cursor stores the composite token the real projection emits"
pass "check additions, pending transitions, regressions, and recoveries are announced"

# --- every live check-run state round-trips (the judge's disconfirming set) --
new_section vocab-checks
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
# The exact shapes the real --jq projection emits for live check runs: every
# in-flight status word arrives with a null conclusion.
gh_checks '[
  {"id":91,"status":"queued","conclusion":null,"name":"linux"},
  {"id":92,"status":"in_progress","conclusion":null,"name":"linux"},
  {"id":93,"status":"waiting","conclusion":null,"name":"deploy"},
  {"id":94,"status":"requested","conclusion":null,"name":"deploy"},
  {"id":95,"status":"pending","conclusion":null,"name":"windows"}]'
wait_for_result "$H" "$sid" || fail "live check runs produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: check id=91 name=linux change=none->pending status=queued:none' "$RESULT" "a queued check round-trips its composite token"
assert_grep 'event: check id=92 name=linux change=none->pending status=in_progress:none' "$RESULT" "an in_progress check round-trips"
assert_grep 'event: check id=93 name=deploy change=none->pending status=waiting:none' "$RESULT" "a waiting check round-trips"
assert_grep 'event: check id=94 name=deploy change=none->pending status=requested:none' "$RESULT" "a requested check round-trips"
assert_grep 'event: check id=95 name=windows change=none->pending status=pending:none' "$RESULT" "a pending check round-trips"
out=$(handle_result "$H" 1 "$RESULT")
assert_contains "$out" "applied: $scheduler_id 1" "the live-states document applies cleanly"
stored=$(cursor_field "$H" "$sid" checks)
for token in 91:queued:none 92:in_progress:none 93:waiting:none 94:requested:none 95:pending:none; do
  assert_contains "$stored" "$token" "the cursor stores $token"
done
restart_runner "$H"
gh_checks '[
  {"id":91,"status":"in_progress","conclusion":null,"name":"linux"},
  {"id":92,"status":"in_progress","conclusion":null,"name":"linux"},
  {"id":93,"status":"waiting","conclusion":null,"name":"deploy"},
  {"id":94,"status":"requested","conclusion":null,"name":"deploy"},
  {"id":95,"status":"pending","conclusion":null,"name":"windows"}]'
wait_for_result_count "$H" "$sid" 2 || fail "the queued to in_progress transition produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: check id=91 name=linux change=pending->pending status=in_progress:none' "$RESULT" \
  "same-category check states still announce and advance"
ack "$H" "$sid" 2 "$RESULT"
restart_runner "$H"
gh_checks '[
  {"id":91,"status":"completed","conclusion":"success","name":"linux"},
  {"id":92,"status":"completed","conclusion":"success","name":"linux"},
  {"id":93,"status":"completed","conclusion":"success","name":"deploy"},
  {"id":94,"status":"completed","conclusion":"success","name":"deploy"},
  {"id":95,"status":"completed","conclusion":"success","name":"windows"}]'
wait_for_result_count "$H" "$sid" 3 || fail "the completions produced no result"
RESULT=$(latest_result "$H" "$sid")
count=$(grep -c 'change=pending->green' "$RESULT" || true)
assert_contains "$count" 5 "every live-state check announces its completion"
ack "$H" "$sid" 3 "$RESULT"
out=$(handle_result "$H" 3 "$RESULT")
assert_contains "$out" "already-applied: $scheduler_id 3" "a byte-identical replay is receipt-deduplicated"
before=$(result_count "$H" "$sid")
pe "$H" reconcile >/dev/null
sleep 1
[ "$(result_count "$H" "$sid")" = "$before" ] \
  || fail "an applied live-states document re-announced on reconcile"
pass "queued, in_progress, waiting, requested, and pending checks apply, advance, and stay bounded"

# --- unknown conclusion words normalize to a safe explicit value -------------
new_section vocab-conclusion
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
gh_checks '[{"id":81,"status":"completed","conclusion":"exotic_future_conclusion","name":"weird"}]'
wait_for_result "$H" "$sid" || fail "an unknown conclusion produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: check id=81 name=weird change=none->red status=completed:unknown' "$RESULT" \
  "an unrecognized conclusion normalizes to completed:unknown and needs attention"
ack "$H" "$sid" 1 "$RESULT"
assert_contains "$(cursor_field "$H" "$sid" checks)" "81:completed:unknown" \
  "the normalized token is stored and readable"
restart_runner "$H"
gh_checks '[{"id":81,"status":"completed","conclusion":"success","name":"weird"}]'
wait_for_result_count "$H" "$sid" 2 || fail "the recovery from unknown produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'change=red->green' "$RESULT" "the recovery from unknown is announced"
ack "$H" "$sid" 2 "$RESULT"
pass "unknown check conclusions round-trip as a safe explicit red"

# --- unknown review states round-trip instead of dropping the event ----------
new_section vocab-review
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf '[{"id":31,"state":"SPEEDY_FUTURE_STATE","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
wait_for_result "$H" "$sid" || fail "an unknown review state produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review id=31 state=unknown author=carol' "$RESULT" \
  "an unrecognized review state is announced as unknown, never dropped"
ack "$H" "$sid" 1 "$RESULT"
assert_contains "$(cursor_field "$H" "$sid" reviews)" "31:unknown" \
  "the unknown review state is stored and readable"
restart_runner "$H"
printf '[{"id":31,"state":"APPROVED","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
wait_for_result_count "$H" "$sid" 2 || fail "the later approval produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: review-state id=31 state=APPROVED' "$RESULT" "the transition from unknown is announced"
ack "$H" "$sid" 2 "$RESULT"
pass "unknown review states round-trip through the whole production path"

# --- unknown PR lifecycle words round-trip ------------------------------------
new_section vocab-state
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
gh_state EXOTIC_FUTURE_STATE
wait_for_result "$H" "$sid" || fail "an unknown PR state produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: pr-state from=open state=unknown' "$RESULT" \
  "an unrecognized lifecycle word normalizes to unknown"
assert_grep 'state: unknown' "$RESULT" "the document carries the unknown state"
ack "$H" "$sid" 1 "$RESULT"
assert_contains "$(cursor_field "$H" "$sid" state)" "unknown" "the unknown state is stored and readable"
restart_runner "$H"
gh_state OPEN
wait_for_result_count "$H" "$sid" 2 || fail "the reopen from unknown produced no result"
RESULT=$(latest_result "$H" "$sid")
assert_grep 'event: pr-state from=unknown state=open' "$RESULT" "the transition from unknown is announced"
ack "$H" "$sid" 2 "$RESULT"
pass "unknown lifecycle words round-trip through the whole production path"

# --- merge keeps tracking: merge event, then post-merge comment --------------
new_section merge
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
gh_state MERGED
wait_for_result "$H" "$sid" || fail "the merge produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: pr-state from=open state=merged' "$RESULT" "the merge is announced"
assert_present "$H/state/procevent/$scheduler_id.source" "a merged PR stays on the scheduler roster"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
printf '[{"id":5,"user":{"login":"bob"}},{"id":13,"user":{"login":"dave"}}]\n' > "$GH_FIX/comments.json"
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
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
gh_state CLOSED
wait_for_result "$H" "$sid" || fail "the close produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: pr-state from=open state=closed' "$RESULT" "the close is announced"
ack "$H" "$sid" 1 "$RESULT"
restart_runner "$H"
gh_state OPEN
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
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf '[{"id":9,"user":{"login":"carol"}},{"id":9,"user":{"login":"carol"}},{"id":5,"user":{"login":"bob"}},{"id":5,"user":{"login":"bob"}}]\n' > "$GH_FIX/comments.json"
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
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
# Simulate a lost acknowledgement: capture the result, then run the child
# again before any apply happened.
printf '[{"id":5,"user":{"login":"bob"}},{"id":9,"user":{"login":"carol"}}]\n' > "$GH_FIX/comments.json"
wait_for_result "$H" "$sid" || fail "no result before the restart"
first=$(first_result "$H" "$sid")
capture=$(sed -n 's/^source: //p' "$first")
cp "$first" "$TMP_ROOT/restart-copy"
before=$(result_count "$H" "$sid")
out=$(FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
after=$(result_count "$H" "$sid")
[ "$after" = "$before" ] \
  || fail "a recomputed poll after an unapplied capture added a second document while the cursor held"
# The applied cursor advance makes the same poll silent.
FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" autohandle "$capture" 1 "$first" >/dev/null
out=$(FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
[ -z "$out" ] || fail "the applied cursor advance left the same remote state noisy: $out"
# Byte-identical replay of one generation acknowledges exactly once.
out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$capture" 1 "$first")
assert_contains "$out" "already-applied: $capture 1" "a byte-identical replay reports already-applied"
cp "$first" "$TMP_ROOT/tampered"
printf 'x' >> "$TMP_ROOT/tampered"
if FM_HOME="$H" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$capture" 1 "$TMP_ROOT/tampered" >/dev/null 2>&1; then
  fail "a conflicting generation under one sequence must be refused"
fi
pass "restart recomputes safely and replay is receipt-deduplicated"

# --- bounded API failure records diagnostics and later recovers --------------
cat > "$FAKEBIN/gh-flaky" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = api ] \
   && [[ "$2" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+$ ]] \
   && [ -e "$FLAKY_DOWN" ]; then
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
out=$(FM_HOME="$H" perl -e 'alarm 4; exec @ARGV' \
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
wait_for_baseline "$H" "$sid" || fail "tracking did not recover after the API healed"
pass "bounded failures record diagnostics and recovery resumes from the cursor"

# --- malformed and hostile remote payloads stay data --------------------------
new_section hostile
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
PWNED="$TMP_ROOT/pwned"
rm -f "$PWNED"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
printf '[{"id":9,"user":{"login":"$(touch %s)"}}]\n' "$PWNED" > "$GH_FIX/comments.json"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
printf '[{"id":6,"in_reply_to_id":null,"user":{"login":"codex"},"path":"$(touch %s)","line":10}]\n' "$PWNED" > "$GH_FIX/rc.json"
# shellcheck disable=SC2016 # The $( ) text is hostile fixture payload, never a command.
gh_checks "[{\"id\":70,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"\$(touch $PWNED)\"}]"
wait_for_result "$H" "$sid" || fail "hostile payload produced no result"
RESULT=$(first_result "$H" "$sid")
[ -e "$PWNED" ] && fail "remote text executed a command"
assert_grep 'event: comment id=9 author=invalid' "$RESULT" \
  "the hostile login is announced as the invalid sentinel"
payload=$(wake_payloads "$H")
assert_not_contains "$payload" 'touch' "hostile bytes never reach the wake line"
ack "$H" "$sid" 1 "$RESULT"
# A caller-selected file cannot self-assert adapter provenance.
gh_fix_default
number=$(printf '%s\n' "$GH_URL" | sed 's|.*/||')
printf '%s\n' \
  'schema: fm-pr-follow-event-v1' \
  "source: $sid" \
  'provider: github' \
  "url: $GH_URL" \
  "number: $number" \
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
out=$(prf "$H" handle "$sid" 2 "$TMP_ROOT/doctored" 2>&1) && fail "a doctored cursor document must be refused"
assert_contains "$out" "tampered or foreign" \
  "self-asserted provenance is classified as external tampering"
assert_absent "$H/state/pr-follow/$sid.quarantine" \
  "external tampering cannot quarantine a tracked PR"
if [ -e "$H/state/pr-follow/$sid.2.applied" ]; then
  fail "a refused document must not leave an applied receipt"
fi
pass "hostile remote data stays data and doctored documents are refused"

# --- adapter-produced-invalid output is bounded, tampering stays loud ----------
new_section quarantine
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf 'capture=%s\nsequence=99\ngeneration=1\nstatus=events\n' "$scheduler_id" \
  > "$H/state/pr-follow/$sid.inflight"
chmod 600 "$H/state/pr-follow/$sid.inflight"
FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" >/dev/null 2>&1 || true
assert_absent "$H/state/pr-follow/$sid.inflight" \
  "a marker whose predicted capture never landed is recovered"
number=$(printf '%s\n' "$GH_URL" | sed 's|.*/||')
printf '%s\n' \
  'schema: fm-pr-follow-event-v1' \
  "source: $scheduler_id" \
  "target: $sid" \
  'provider: github' \
  "url: $GH_URL" \
  "number: $number" \
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
  'generation=1' > "$TMP_ROOT/baddoc"
mkdir -p "$H/state/procevent-inbox"
cp "$TMP_ROOT/baddoc" "$H/state/procevent-inbox/$scheduler_id.1.result"
printf 'pr-follow\n' > "$H/state/procevent-inbox/$scheduler_id.1.adapter"
printf 'capture=%s\nsequence=1\ngeneration=1\nstatus=events\n' "$scheduler_id" \
  > "$H/state/pr-follow/$sid.inflight"
chmod 600 "$H/state/procevent-inbox/$scheduler_id.1.result" \
  "$H/state/procevent-inbox/$scheduler_id.1.adapter" "$H/state/pr-follow/$sid.inflight"
# Attempt one of the bound: a distinct refusal naming the adapter class.
out=$(prf "$H" handle "$scheduler_id" 1 "$H/state/procevent-inbox/$scheduler_id.1.result" 2>&1) && fail "an unapplicable document must be refused"
assert_contains "$out" "attempt 1 of 2" "the first refusal names its attempt against the bound"
assert_grep 'count=1' "$H/state/pr-follow/$sid.quarantine" "the refusal is durably counted"
assert_present "$H/state/pr-follow/$sid.inflight" \
  "a retryable validation refusal keeps its capture provenance"
# Below the bound the source keeps polling: a counted attempt is not a pause,
# so this poll is the ordinary quiet one and surfaces no monitoring loss.
out=$(FM_HOME="$H" perl -e 'alarm 2; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
printf '%s' "$out" > "$TMP_ROOT/below-bound"
assert_no_grep 'monitoring loss' "$TMP_ROOT/below-bound" \
  "a refusal below the bound never pauses monitoring"
[ -z "$out" ] || fail "polling below the bound emitted a document: $out"
# Attempt two reaches the bound: acknowledge, pause, surface once.
out=$(prf "$H" handle "$scheduler_id" 1 "$H/state/procevent-inbox/$scheduler_id.1.result" 2>&1) || fail "the bounded refusal must settle"
assert_contains "$out" "monitoring-loss: $sid paused" "the bound surfaces an actionable monitoring-loss line"
assert_grep 'count=2' "$H/state/pr-follow/$sid.quarantine" "the quarantine record counts both refusals"
assert_absent "$H/state/pr-follow/$sid.inflight" \
  "the terminal validation refusal releases its in-flight capture"
# The paused source emits exactly one monitoring-loss document, then nothing.
printf 'capture=%s\nsequence=1\ngeneration=1\nstatus=events\n' "$scheduler_id" \
  > "$H/state/pr-follow/$sid.inflight"
chmod 600 "$H/state/pr-follow/$sid.inflight"
out=$(FM_HOME="$H" perl -e 'alarm 2; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
printf '%s' "$out" > "$TMP_ROOT/ml-doc"
assert_grep 'status: error' "$TMP_ROOT/ml-doc" "the paused source emits a monitoring-loss error document"
assert_grep "monitoring loss: source $sid paused" "$TMP_ROOT/ml-doc" "the document names the pause and the resume action"
assert_no_grep 'event:' "$TMP_ROOT/ml-doc" "a monitoring-loss document invents no forge event"
RESULT8="$H/state/procevent-inbox/$sid.2.result"
cp "$TMP_ROOT/ml-doc" "$RESULT8"
printf 'pr-follow\n' > "$H/state/procevent-inbox/$sid.2.adapter"
chmod 600 "$RESULT8" "$H/state/procevent-inbox/$sid.2.adapter"
out=$(prf "$H" handle "$sid" 2 "$RESULT8")
assert_contains "$out" "applied: $sid 2" "the monitoring-loss document applies"
assert_grep 'surfaced=1' "$H/state/pr-follow/$sid.quarantine" "applying it latches the surface"
out=$(FM_HOME="$H" perl -e 'alarm 1; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" 2>/dev/null || true)
[ -z "$out" ] || fail "a surfaced quarantine emitted more: $out"
before=$(result_count "$H" "$sid")
pe "$H" reconcile >/dev/null
sleep 1
[ "$(result_count "$H" "$sid")" = "$before" ] \
  || fail "a quarantined source produced further results on reconcile"
# Re-arming clears the quarantine and resumes tracking.
out=$(arm_gh "$H")
assert_contains "$out" "already armed: $sid" "re-arming reports the tracked identity"
[ ! -e "$H/state/pr-follow/$sid.quarantine" ] || fail "re-arm must clear the quarantine record"
assert_absent "$H/state/pr-follow/$sid.inflight" \
  "re-arm releases a terminal quarantine's stale marker"
# Publish the new comment before the runner restarts, so the first resumed
# poll cannot race the fixture and observe the pre-resume state instead.
printf '[{"id":5,"user":{"login":"bob"}},{"id":21,"user":{"login":"erin"}}]\n' > "$GH_FIX/comments.json"
restart_runner "$H"
wait_for_result_matching "$H" "$sid" 'event: comment id=21 author=erin' \
  || fail "tracking did not resume after re-arm"
RESULT=$(result_matching "$H" "$sid" 'event: comment id=21 author=erin')
seqn=${RESULT##*/"$scheduler_id".}
seqn=${seqn%.result}
assert_grep 'event: comment id=21 author=erin' "$RESULT" "resumed tracking announces new events"
ack "$H" "$sid" "$seqn" "$RESULT"
# Tampered or foreign documents never claim the adapter class and stay loudly
# refused every time, with no quarantine latch.
printf 'schema: not-this-adapter\nsource: %s\n' "$sid" > "$TMP_ROOT/foreign"
out=$(prf "$H" handle "$sid" 9 "$TMP_ROOT/foreign" 2>&1) && fail "a foreign document must be refused"
assert_contains "$out" "tampered or foreign" "the refusal names the tampering class"
out=$(prf "$H" handle "$sid" 9 "$TMP_ROOT/foreign" 2>&1) && fail "a repeated foreign document must stay refused"
assert_contains "$out" "tampered or foreign" "tampering is refused loudly on every attempt"
assert_absent "$H/state/pr-follow/$sid.quarantine" "a tampered refusal never quarantines"
pass "adapter-produced invalidity is bounded and tampering stays loudly refused"

# --- task cleanup never erases lifecycle tracking -----------------------------
new_section cleanup
gh_fix_default
arm_gh "$H" task-live >/dev/null
# Simulate the task landing: the merge poll retires task artifacts exactly as
# cleanup does, while lifecycle state lives elsewhere.
rm -f "$H/state/task-live.check.sh" "$H/state/task-live.pr-poll" \
  "$H/state/task-live.pr-poll-registration" "$H/state/task-live.pr-poll-retirement"
assert_present "$H/state/procevent/$scheduler_id.source" "cleanup leaves the lifecycle scheduler"
assert_present "$H/state/pr-follow/$sid.cursor" "cleanup leaves the lifecycle cursor"
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "tracking stopped after task cleanup"
printf '[{"id":5,"user":{"login":"bob"}},{"id":9,"user":{"login":"carol"}}]\n' > "$GH_FIX/comments.json"
wait_for_result "$H" "$sid" || fail "no events after task cleanup"
pass "task cleanup does not erase lifecycle follow-through"

# --- explicit auditable retirement --------------------------------------------
new_section retire
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the baseline never completed"
printf '[{"id":5,"user":{"login":"bob"}},{"id":9,"user":{"login":"carol"}}]\n' > "$GH_FIX/comments.json"
wait_for_result "$H" "$sid" || fail "no result before retirement"
if prf "$H" retire "$sid" >/dev/null 2>&1; then
  fail "retirement must refuse while unhandled captured results exist"
fi
assert_present "$H/state/procevent/$scheduler_id.source" \
  "a refused retirement keeps the scheduler"
assert_present "$H/state/pr-follow/$sid.cursor" \
  "a refused retirement keeps the durable cursor"
RESULT=$(first_result "$H" "$sid")
capture=$(sed -n 's/^source: //p' "$RESULT")
seqn=${RESULT%.result}
seqn=${seqn##*.}
out=$(handle_result "$H" "$seqn" "$RESULT")
case "$out" in
  *"applied: $capture $seqn"*|*"already-applied: $capture $seqn"*) ;;
  *) fail "the pending result was not durably applied before retirement: $out" ;;
esac
receipt="$H/state/pr-follow/$sid.$capture.$seqn.applied"
assert_present "$receipt" "applying the pending result records its replay receipt"
out=$(prf "$H" retire "$sid")
assert_contains "$out" "retired: $sid" "the explicit retirement reports what it retired"
assert_absent "$H/state/procevent/$scheduler_id.source" "retirement drops the empty scheduler"
assert_absent "$H/state/pr-follow/$sid.cursor" "retirement removes the cursor"
assert_present "$receipt" "retirement preserves the applied replay receipt"
out=$(handle_result "$H" "$seqn" "$RESULT")
assert_contains "$out" "already-applied: $capture $seqn" \
  "a queued replay remains safely acknowledgeable after retirement"
out=$(prf "$H" retire "$sid" --force)
assert_contains "$out" "retired: $sid" "retirement is idempotent"
pe "$H" reconcile >/dev/null
sleep 0.3
[ "$(result_count "$H" "$sid")" = 1 ] || fail "a retired source produced further results"
assert_absent "$H/state/pr-follow/$sid.cursor" "an in-flight poll recreated the retired cursor"
pass "explicit retirement is the one auditable off switch"

# --- backfill surfaces currently unanswered threads ---------------------------
new_section backfill
gh_fix_default
# The PR author is alice; codex holds the last word on one thread. Rows are
# newest first, as the descending API pages deliver them.
printf '2\n' > "$GH_FIX/rc.total-pages"
printf '[{"id":8,"in_reply_to_id":null,"user":{"login":"codex"},"path":"src/y.py","line":20},{"id":6,"in_reply_to_id":null,"user":{"login":"codex"},"path":"src/x.py","line":10}]\n' > "$GH_FIX/rc.page.1"
printf '[{"id":7,"in_reply_to_id":6,"user":{"login":"alice"},"path":"src/x.py","line":10}]\n' > "$GH_FIX/rc.page.2"
arm_gh "$H" task-old --backfill >/dev/null
out=$(FM_HOME="$H" FM_PR_FOLLOW_MAX_PAGES=1 perl -e 'alarm 10; exec @ARGV' "$ROOT/bin/fm-procevent.sh" start "$scheduler_id" 2>&1)
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
[ "$(result_count "$H" "$sid")" = "$before" ] \
  || fail "the backfill re-announced after it was applied"
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

new_section sweep-resume
gh_fix_default
for n in 1 2 3; do
  resume_url="https://github.com/octo/app/pull/$((700 + n))"
  prf "$H" arm "resume-$n" "$resume_url" --seed-head "$GH_SHA1" >/dev/null
  printf 'task=resume-%s\npr=%s\n' "$n" "$resume_url" \
    > "$H/state/resume-$n.meta"
done
for _ in 1 2 3; do
  FM_PR_FOLLOW_BACKFILL_SCAN_CAP=1 prf "$H" backfill >/dev/null
done
for n in 1 2 3; do
  rsid=$(prf "$H" source-id "https://github.com/octo/app/pull/$((700 + n))")
  # The sweep is the only path that arms with --backfill, so the flipped
  # backfill field is state no pre-existing registration can account for.
  assert_contains "$(cursor_field "$H" "$rsid" backfill)" "on" "resumable sweep reached PR $n"
done
assert_absent "$H/state/pr-follow/backfill.scan" "completed sweep clears its progress cursor"
assert_absent "$H/state/pr-follow/legacy.scan" "bounded legacy conversion clears after resumable passes"
assert_present "$H/state/pr-follow/legacy.done" "completed legacy conversion stays latched"
FM_PR_FOLLOW_BACKFILL_SCAN_CAP=1 prf "$H" backfill >/dev/null
assert_absent "$H/state/pr-follow/legacy.scan" "later sweeps do not restart legacy conversion"
prf "$H" backfill >/dev/null
# One record the adapter refuses must not end the pass: every later record and
# the sweep's own progress still have to be reached.
rsid=$(prf "$H" source-id "https://github.com/octo/app/pull/701")
printf 'bogus=1\n' >> "$H/state/pr-follow/$rsid.cursor"
out=$(prf "$H" backfill 2>/dev/null) || fail "a refused record aborted the migration sweep"
printf '%s\n' "$out" > "$TMP_ROOT/sweep-damaged"
assert_grep 'backfill summary: scanned=3 armed=0 already=2 skipped=1 capped=0' "$TMP_ROOT/sweep-damaged" \
  "the sweep counts the refused record and still finishes the later ones"
assert_absent "$H/state/pr-follow/backfill.scan" "the surviving sweep still clears its progress cursor"
pass "the capped migration sweep resumes beyond its first batch"

# --- a poll with nothing to report captures nothing --------------------------
new_section legacy-convert
gh_fix_default
arm_gh "$H" >/dev/null
pe "$H" register pr-follow "$sid" -- "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" >/dev/null
out=$(pe "$H" start "$sid" 2>&1) || fail "starting a legacy registration failed: $out"
assert_contains "$out" "no-result: $sid" "a converted legacy registration reports no usable result"
assert_absent "$H/state/procevent-inbox/$sid.1.result" \
  "a run with nothing to report never captures an empty document"
assert_present "$H/state/procevent/$scheduler_id.source" "the conversion keeps the home scheduler registered"
pass "a run with nothing to report captures no document"

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
wait_for_baseline "$H" "$glsid" || fail "the GitLab baseline never completed"
assert_contains "$(cursor_field "$H" "$glsid" checks)" "7:running" \
  "the baseline stores the real bare pipeline token"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"success"}]' > "$GL_FIX/pipelines"
printf '{"approved_by":[{"user":{"username":"dave"}}]}' > "$GL_FIX/approvals"
wait_for_result "$H" "$glsid" || fail "GitLab transitions produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: check id=7 change=pending->green status=success' "$RESULT" "the pipeline recovery is announced"
assert_grep 'event: review id=approval-dave state=APPROVED author=dave' "$RESULT" "the approval grant is announced"
ack "$H" "$glsid" 1 "$RESULT"
assert_contains "$(cursor_field "$H" "$glsid" approvals)" "dave" "the applied approval is durable"
# A second approver announces its own grant and revokes nobody, and a
# discussion opened after the baseline enters the durable thread map.
restart_runner "$H"
printf '{"approved_by":[{"user":{"username":"dave"}},{"user":{"username":"erin"}}]}' > "$GL_FIX/approvals"
printf '[{"id":"D1","resolved":false,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/x.py","new_line":10}},{"id":92,"author":{"username":"zoe"}}]},{"id":"D2","resolved":false,"notes":[{"id":91,"author":{"username":"erin"},"type":"DiffNote","position":{"new_path":"src/y.py","new_line":4}}]}]' > "$GL_FIX/discussions"
wait_for_result_count "$H" "$glsid" 2 || fail "the second approver produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: review id=approval-erin state=APPROVED author=erin' "$RESULT" \
  "the second approval grant is announced"
assert_grep 'event: comment id=92 author=zoe' "$RESULT" \
  "a plain GitLab note is announced"
assert_no_grep 'state=DISMISSED' "$RESULT" "a second approver never revokes the first"
ack "$H" "$glsid" 2 "$RESULT"
assert_contains "$(cursor_field "$H" "$glsid" approvals)" "dave,erin" "both approvals are durable"
assert_grep 'state=unresolved' "$H/state/pr-follow/$glsid.threads/D2" \
  "a discussion opened after the baseline is durably tracked from its first sighting"
# An approvals endpoint that stops answering is not evidence that anybody
# withdrew an approval, so the poll that carries an unrelated event must
# neither announce a revocation nor drop the durable set.
restart_runner "$H"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
touch "$GL_FIX/approvals.exit"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"failed"}]' > "$GL_FIX/pipelines"
wait_for_result_count "$H" "$glsid" 3 || fail "the unreadable approvals endpoint produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: check id=7 change=green->red status=failed' "$RESULT" \
  "the poll that could not read approvals still announced its other events"
assert_no_grep 'state=DISMISSED' "$RESULT" \
  "an unreadable approvals endpoint faked a revocation"
ack "$H" "$glsid" 3 "$RESULT"
assert_contains "$(cursor_field "$H" "$glsid" approvals)" "dave,erin" \
  "the durable approval set survives an unreadable approvals endpoint"
# Recovery announces nothing: the approvals never changed, so nothing repeats.
restart_runner "$H"
rm -f "$GL_FIX/approvals.exit"
printf '{"approved_by":[{"user":{"username":"dave"}},{"user":{"username":"erin"}}]}' > "$GL_FIX/approvals"
printf '[{"id":"D1","resolved":false,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/x.py","new_line":10}},{"id":92,"author":{"username":"zoe"}}]},{"id":"D2","resolved":true,"notes":[{"id":91,"author":{"username":"erin"},"type":"DiffNote","position":{"new_path":"src/y.py","new_line":4}}]}]' > "$GL_FIX/discussions"
wait_for_result_count "$H" "$glsid" 4 || fail "the recovered approvals endpoint produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: thread id=D2 state=resolved' "$RESULT" \
  "a thread opened after the baseline announces its resolution"
assert_no_grep 'state=APPROVED' "$RESULT" \
  "a recovered approvals endpoint re-announced an unchanged approval"
assert_no_grep 'event: comment id=92' "$RESULT" \
  "an applied plain GitLab note does not repeat"
ack "$H" "$glsid" 4 "$RESULT"
restart_runner "$H"
printf '[{"id":"D1","resolved":true,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/x.py","new_line":10}},{"id":92,"author":{"username":"zoe"}}]},{"id":"D2","resolved":true,"notes":[{"id":91,"author":{"username":"erin"},"type":"DiffNote","position":{"new_path":"src/y.py","new_line":4}}]}]' > "$GL_FIX/discussions"
printf '{"state":"merged","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
wait_for_result_count "$H" "$glsid" 5 || fail "GitLab merge and resolve produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: thread id=D1 state=resolved' "$RESULT" "the thread resolution is announced"
assert_grep 'event: pr-state from=open state=merged' "$RESULT" "the GitLab merge is announced"
ack "$H" "$glsid" 5 "$RESULT"
assert_present "$H/state/procevent/$scheduler_id.source" "a merged GitLab MR stays scheduled"
pass "GitLab comments, pipelines, approvals, threads, and merge are tracked"

new_section legacy-approval
gh_fix_default
mkdir -p "$GL_FIX"
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[]' > "$GL_FIX/discussions"
printf '[]' > "$GL_FIX/pipelines"
printf '{"approved_by":[{"user":{"username":"dave"}}]}' > "$GL_FIX/approvals"
prf "$H" arm task-legacy-approval "$GL_URL" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$glsid" || fail "the legacy approval baseline never completed"
pkill -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null || true
pkill -f "fm-procevent.sh _start $scheduler_id" 2>/dev/null || true
rm -f "$H/state/pr-follow/$glsid.items/approval-dave"
cursor_set_field "$H" "$glsid" approval_ready 0 || fail "could not model the legacy approval cursor"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
restart_runner "$H"
wait_for_result "$H" "$glsid" || fail "the legacy approval revocation produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: review id=approval-dave state=DISMISSED author=dave' "$RESULT" \
  "legacy approval entries migrate before revocation comparison"
ack "$H" "$glsid" 1 "$RESULT"
pass "legacy approval state migrates without losing revocations"

# --- live and unknown GitLab pipeline states round-trip ------------------------
new_section vocab-gl
gh_fix_default
mkdir -p "$GL_FIX"
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[]' > "$GL_FIX/discussions"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
printf '[{"id":11,"sha":"2222222222222222222222222222222222222222","status":"created"},{"id":12,"sha":"2222222222222222222222222222222222222222","status":"preparing"},{"id":13,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines"
prf "$H" arm task-gl2 "$GL_URL" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$glsid" || fail "the GitLab baseline never completed"
stored=$(cursor_field "$H" "$glsid" checks)
assert_contains "$stored" "11:created" "the created pipeline word is stored"
assert_contains "$stored" "12:preparing" "the preparing pipeline word is stored"
assert_contains "$stored" "13:running" "the running pipeline word is stored"
printf '[{"id":11,"sha":"2222222222222222222222222222222222222222","status":"preparing"},{"id":12,"sha":"2222222222222222222222222222222222222222","status":"preparing"},{"id":13,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines"
wait_for_result "$H" "$glsid" || fail "the created to preparing transition produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: check id=11 change=pending->pending status=preparing' "$RESULT" \
  "created to preparing advances despite sharing a summary category"
ack "$H" "$glsid" 1 "$RESULT"
restart_runner "$H"
printf '[{"id":11,"sha":"2222222222222222222222222222222222222222","status":"running"},{"id":12,"sha":"2222222222222222222222222222222222222222","status":"preparing"},{"id":13,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines"
wait_for_result_count "$H" "$glsid" 2 || fail "the preparing to running transition produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: check id=11 change=pending->pending status=running' "$RESULT" \
  "preparing to running advances despite sharing a summary category"
ack "$H" "$glsid" 2 "$RESULT"
restart_runner "$H"
printf '[{"id":11,"sha":"2222222222222222222222222222222222222222","status":"success"},{"id":12,"sha":"2222222222222222222222222222222222222222","status":"failed"},{"id":13,"sha":"2222222222222222222222222222222222222222","status":"success"}]' > "$GL_FIX/pipelines"
wait_for_result_count "$H" "$glsid" 3 || fail "the pipeline transitions produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: check id=11 change=pending->green status=success' "$RESULT" "created->success is announced"
assert_grep 'event: check id=12 change=pending->red status=failed' "$RESULT" "preparing->failed is announced"
assert_grep 'event: check id=13 change=pending->green status=success' "$RESULT" "running->success is announced"
ack "$H" "$glsid" 3 "$RESULT"
out=$(handle_result "$H" 3 "$RESULT")
assert_contains "$out" "already-applied: $scheduler_id 3" "the GitLab transitions replay safely"
restart_runner "$H"
printf '[{"id":11,"sha":"2222222222222222222222222222222222222222","status":"success"},{"id":12,"sha":"2222222222222222222222222222222222222222","status":"failed"},{"id":13,"sha":"2222222222222222222222222222222222222222","status":"success"},{"id":14,"sha":"2222222222222222222222222222222222222222","status":"manual"}]' > "$GL_FIX/pipelines"
wait_for_result_count "$H" "$glsid" 4 || fail "the unknown pipeline word produced no result"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: check id=14 change=none->pending status=unknown' "$RESULT" \
  "an unknown pipeline word normalizes to unknown and is announced"
ack "$H" "$glsid" 4 "$RESULT"
assert_contains "$(cursor_field "$H" "$glsid" checks)" "14:unknown" "the unknown token round-trips"
pass "created, preparing, running, and unknown GitLab pipeline states round-trip"

# --- the event bound truncates review noise but never the lifecycle line -------
new_section cap
gh_fix_default
mkdir -p "$GL_FIX"
# One event per document: enough to prove that the bound truncates the review
# collections while the head and pr-state lines the cursor advance depends on
# still reach the reader, and that the truncated remainder is re-announced.
export FM_PR_FOLLOW_MAX_EVENTS=1
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[{"id":"D1","resolved":false,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/1.py","new_line":3}}]},{"id":"D2","resolved":false,"notes":[{"id":91,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/2.py","new_line":3}}]},{"id":"D3","resolved":false,"notes":[{"id":92,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/3.py","new_line":3}}]}]' > "$GL_FIX/discussions"
printf '[]' > "$GL_FIX/pipelines"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
prf "$H" arm task-cap "$GL_URL" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$glsid" || fail "the bounded-document baseline never completed"
# Three resolutions and a merge land in one poll: the bound keeps one thread
# event, and the merge announcement rides along instead of being truncated.
printf '[{"id":"D1","resolved":true,"notes":[{"id":90,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/1.py","new_line":3}}]},{"id":"D2","resolved":true,"notes":[{"id":91,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/2.py","new_line":3}}]},{"id":"D3","resolved":true,"notes":[{"id":92,"author":{"username":"codex"},"type":"DiffNote","position":{"new_path":"src/3.py","new_line":3}}]}]' > "$GL_FIX/discussions"
printf '{"state":"merged","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
wait_for_result "$H" "$glsid" || fail "the bounded poll produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'dropped: 1' "$RESULT" "the overflowed poll records that it dropped events"
assert_grep 'events: 2' "$RESULT" "the bound keeps one review event plus the exempt lifecycle line"
assert_grep 'event: pr-state from=open state=merged' "$RESULT" \
  "the lifecycle line is exempt from the event bound"
[ "$(grep -c 'event: thread' "$RESULT")" = 1 ] \
  || fail "the thread events were not truncated to exactly the bound"
ack "$H" "$glsid" 1 "$RESULT"
restart_runner "$H"
wait_for_result_count "$H" "$glsid" 2 || fail "the truncated remainder was never re-announced"
RESULT=$(latest_result "$H" "$glsid")
assert_grep 'event: thread' "$RESULT" "the remainder of an overflowed poll is announced later"
assert_no_grep 'event: pr-state' "$RESULT" "an announced lifecycle change is never re-announced"
ack "$H" "$glsid" 2 "$RESULT"
# A bound the apply step would refuse never starts polling: the 200-event
# document limit and the map validators' character limit own the range, so a
# configured bound above them is refused up front instead of composing a
# document this adapter's own apply would reject and quarantine it for.
out=$(FM_HOME="$H" FM_PR_FOLLOW_MAX_EVENTS=250 perl -e 'alarm 3; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$glsid" 2>&1 || true)
assert_contains "$out" "environment bounds are invalid" \
  "an event bound above the document limit was accepted"
out=$(FM_HOME="$H" FM_PR_FOLLOW_MAP_LIMIT=99999 perl -e 'alarm 3; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$glsid" 2>&1 || true)
assert_contains "$out" "environment bounds are invalid" \
  "a map bound above the cursor validators' limit was accepted"
out=$(FM_HOME="$H" FM_PR_FOLLOW_MAX_EVENTS=198 perl -e 'alarm 3; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$glsid" 2>&1 || true)
assert_not_contains "$out" "environment bounds are invalid" \
  "the largest bound the apply step accepts was refused"
unset FM_PR_FOLLOW_MAX_EVENTS
pass "the event bound truncates review noise and never the lifecycle line"

# --- a bounded check map never re-announces what the bound evicted -----------
new_section checkbound
gh_fix_default
# Two map entries against three check runs on one head: the lowest id is
# evicted by the bound on every store, so only the durable maximum keeps it
# from reading back as a check nobody has announced yet.
export FM_PR_FOLLOW_MAP_LIMIT=2
gh_checks '[{"id":11,"status":"completed","conclusion":"success","name":"a"},{"id":12,"status":"completed","conclusion":"success","name":"b"},{"id":13,"status":"completed","conclusion":"success","name":"c"}]'
arm_gh "$H" task-cb >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the bounded-map baseline never completed"
stored=$(cursor_field "$H" "$sid" checks)
assert_not_contains "$stored" "11:" "the bound kept more entries than it was given"
assert_contains "$(cursor_field "$H" "$sid" max_check)" 13 \
  "the baseline did not record the highest check id it saw"
gh_checks '[{"id":11,"status":"completed","conclusion":"success","name":"a"},{"id":12,"status":"completed","conclusion":"success","name":"b"},{"id":13,"status":"completed","conclusion":"failure","name":"c"}]'
wait_for_result "$H" "$sid" || fail "the check regression produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: check id=13 name=c change=green->red status=completed:failure' "$RESULT" \
  "the tracked check regression is announced"
assert_no_grep 'change=none->' "$RESULT" \
  "a check the map bound evicted was re-announced as new"
ack "$H" "$sid" 1 "$RESULT"
# The evicted id must stay silent on every later poll, not just the first.
restart_runner "$H"
sleep 2
[ "$(result_count "$H" "$sid")" = 1 ] \
  || fail "the evicted check kept producing a fresh document on later polls"
unset FM_PR_FOLLOW_MAP_LIMIT
pass "a bounded check map never re-announces what the bound evicted"

# --- reviews that predate the baseline stay tracked --------------------------
new_section prereview
gh_fix_default
# The migration case the backfill sweep exists for: a PR already carrying a
# review when monitoring is armed.
printf '[{"id":100,"state":"APPROVED","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
arm_gh "$H" task-pre >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the pre-existing-review baseline never completed"
assert_contains "$(cursor_field "$H" "$sid" reviews)" "100:APPROVED" \
  "a review that predates the baseline never entered the durable map"
printf '[{"id":100,"state":"DISMISSED","user":{"login":"carol"}}]\n' > "$GH_FIX/reviews.json"
wait_for_result "$H" "$sid" || fail "the dismissal of a pre-existing review produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review-state id=100 state=DISMISSED' "$RESULT" \
  "the dismissal of a review that predates the baseline is announced"
ack "$H" "$sid" 1 "$RESULT"
pass "reviews that predate the baseline keep their state tracked"

# --- GET-only review pagination starts at the newest bounded pages -----------
new_section reviewpaging
gh_fix_default
printf '6\n' > "$GH_FIX/reviews.total-pages"
printf '[{"id":100,"state":"APPROVED","user":{"login":"dana"}}]\n' > "$GH_FIX/reviews.page.1"
printf '[{"id":500,"state":"APPROVED","user":{"login":"erin"}}]\n' > "$GH_FIX/reviews.page.5"
printf '[{"id":600,"state":"COMMENTED","user":{"login":"frank"}}]\n' > "$GH_FIX/reviews.page.6"
FM_PR_FOLLOW_MAX_PAGES=2 FM_PR_FOLLOW_MAP_LIMIT=2 prf "$H" arm task-rp "$GH_URL" >/dev/null
FM_PR_FOLLOW_MAX_PAGES=2 FM_PR_FOLLOW_MAP_LIMIT=2 pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$sid" || fail "the paged REST review baseline never completed"
assert_contains "$(cursor_field "$H" "$sid" reviews)" "600:COMMENTED" \
  "the newest review page beyond the old five-page head was not baselined"
assert_contains "$(cursor_field "$H" "$sid" reviews)" "500:APPROVED" \
  "the second-newest bounded review page was not baselined"
printf '[{"id":100,"state":"CHANGES_REQUESTED","user":{"login":"dana"}}]\n' > "$GH_FIX/reviews.page.1"
wait_for_result "$H" "$sid" 200 || fail "an older paged review transition was never revisited"
RESULT=$(first_result "$H" "$sid")
assert_grep 'event: review-state id=100 state=CHANGES_REQUESTED author=dana' "$RESULT" \
  "review state was lost after compatibility-map eviction"
ack "$H" "$sid" 1 "$RESULT"
pass "GET-only pagination revisits evicted review state"

new_section page-growth
gh_fix_default
printf '6\n' > "$GH_FIX/reviews.total-pages"
for n in 1 2 3 4 5 6 7; do
  printf '[]\n' > "$GH_FIX/reviews.page.$n"
done
arm_gh "$H" task-page-growth >/dev/null
FM_PR_FOLLOW_MAX_PAGES=1 FM_PR_FOLLOW_ROTATION_SLOT=10 FM_HOME="$H" \
  perl -e 'alarm 1; exec @ARGV' "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" >/dev/null 2>&1 || true
assert_contains "$(cursor_field "$H" "$sid" gh_review_page)" 5 \
  "the first bounded review scan advances toward older pages"
printf '7\n' > "$GH_FIX/reviews.total-pages"
FM_PR_FOLLOW_MAX_PAGES=1 FM_PR_FOLLOW_ROTATION_SLOT=10 FM_HOME="$H" \
  perl -e 'alarm 1; exec @ARGV' "$ROOT/bin/fm-procevent-pr-follow.sh" run "$sid" >/dev/null 2>&1 || true
assert_contains "$(cursor_field "$H" "$sid" gh_review_page)" 4 \
  "a growing collection does not abandon older scan progress"
pass "page growth preserves durable traversal progress"

# --- opaque GitLab thread state survives map eviction and page rotation ------
new_section gitlabpaging
gh_fix_default
mkdir -p "$GL_FIX"
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[]' > "$GL_FIX/discussions"
printf '6\n' > "$GL_FIX/discussions.total-pages"
printf '[]' > "$GL_FIX/discussions.page.1"
printf '[]' > "$GL_FIX/discussions.page.5"
printf '[{"id":"opaqueA","resolved":false,"notes":[{"id":901,"author":{"username":"erin"},"type":"DiffNote","position":{"new_path":"src/a.py","new_line":3}}]},{"id":"opaqueB","resolved":false,"notes":[{"id":902,"author":{"username":"frank"},"type":"DiffNote","position":{"new_path":"src/b.py","new_line":4}}]}]' > "$GL_FIX/discussions.page.6"
printf '6\n' > "$GL_FIX/pipelines.total-pages"
printf '[{"id":80,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines.page.1"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines.page.6"
printf '[]' > "$GL_FIX/pipelines"
printf '{"approved_by":[]}' > "$GL_FIX/approvals"
FM_PR_FOLLOW_MAP_LIMIT=1 FM_PR_FOLLOW_MAX_PAGES=5 prf "$H" arm task-gp "$GL_URL" >/dev/null
FM_PR_FOLLOW_MAP_LIMIT=1 FM_PR_FOLLOW_MAX_PAGES=5 pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$glsid" || fail "the rotating GitLab baseline never completed"
printf '[{"id":"opaqueA","resolved":true,"notes":[{"id":901,"author":{"username":"erin"},"type":"DiffNote","position":{"new_path":"src/a.py","new_line":3}}]},{"id":"opaqueB","resolved":true,"notes":[{"id":902,"author":{"username":"frank"},"type":"DiffNote","position":{"new_path":"src/b.py","new_line":4}}]}]' > "$GL_FIX/discussions.page.6"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"success"}]' > "$GL_FIX/pipelines.page.6"
wait_for_result "$H" "$glsid" || fail "the rotated GitLab thread transitions produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: thread id=opaqueA state=resolved' "$RESULT" \
  "the first opaque thread transition was lost after map eviction"
assert_grep 'event: thread id=opaqueB state=resolved' "$RESULT" \
  "the second opaque thread transition was lost after map eviction"
assert_grep 'event: check id=7 change=pending->green status=success' "$RESULT" \
  "an older pipeline transition was lost after map eviction"
ack "$H" "$glsid" 1 "$RESULT"
before=$(result_count "$H" "$glsid")
restart_runner "$H"
sleep 3
[ "$(result_count "$H" "$glsid")" = "$before" ] \
  || fail "an applied opaque thread transition repeated after eviction"
pass "GitLab paging and opaque thread state remain replay-safe"
rm -f "$GL_FIX"/discussions.page.* "$GL_FIX/discussions.total-pages" \
  "$GL_FIX"/pipelines.page.* "$GL_FIX/pipelines.total-pages"

# --- approval state survives the compatibility-map bound ---------------------
new_section approvalbound
gh_fix_default
mkdir -p "$GL_FIX"
printf '{"state":"opened","sha":"2222222222222222222222222222222222222222","author":{"username":"alice"}}' > "$GL_FIX/mr"
printf '[]' > "$GL_FIX/discussions"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"running"}]' > "$GL_FIX/pipelines"
# More maximum-length approvers than the durable approval set can hold: the
# ones the bound refuses must not be announced as a fresh grant on every poll.
{
  printf '{"approved_by":['
  for i in $(seq 1 80); do
    [ "$i" -gt 1 ] && printf ','
    printf '{"user":{"username":"approver%03d%s"}}' "$i" "$(printf 'x%.0s' $(seq 1 49))"
  done
  printf ']}'
} > "$GL_FIX/approvals"
prf "$H" arm task-ab "$GL_URL" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_baseline "$H" "$glsid" || fail "the bounded-approval baseline never completed"
printf '[{"id":7,"sha":"2222222222222222222222222222222222222222","status":"success"}]' > "$GL_FIX/pipelines"
wait_for_result "$H" "$glsid" || fail "the pipeline transition produced no result"
RESULT=$(first_result "$H" "$glsid")
assert_grep 'event: check id=7 change=pending->green status=success' "$RESULT" \
  "the poll that could not record every approver still announced its other events"
assert_no_grep 'state=APPROVED' "$RESULT" \
  "an approver the set bound refused was announced as a fresh grant"
assert_grep 'dropped: 0' "$RESULT" \
  "the durable approval records are not truncated with the compatibility map"
ack "$H" "$glsid" 1 "$RESULT"
restart_runner "$H"
sleep 2
[ "$(result_count "$H" "$glsid")" = 1 ] \
  || fail "the refused approvers kept producing a fresh document on later polls"
pass "approval state survives the bounded compatibility map"

# --- deterministic rotation bounds aggregate load without starvation ----------
new_section rotation
gh_fix_default
# Five tracked PRs share one home; with a two-second slot each source owns one
# slot per five, so at most one poll burst happens per slot.
FM_PR_FOLLOW_ROTATION_SLOT=2
export FM_PR_FOLLOW_ROTATION_SLOT
sids=()
urls=("https://github.com/octo/app/pull/941" "https://github.com/octo/app/pull/942" "https://github.com/octo/app/pull/943" "https://github.com/octo/app/pull/944" "https://github.com/octo/app/pull/945")
for u in "${urls[@]}"; do
  s=$(prf "$H" source-id "$u")
  sids+=("$s")
  prf "$H" arm task-rot-"${u##*/}" "$u" >/dev/null
done
: > "$GH_TEST_POLL_LOG"
# Reconciling the whole retained roster at once starts every source together:
# the startup polls are rotated like any other poll, so the burst that lands
# before the last baseline stays inside one per elapsed slot (plus one for the
# boundary the window may straddle) instead of one per tracked PR.
rot_start=$(date +%s)
pe "$H" reconcile >/dev/null
# One scheduler for this home is the steady state, so sample that home's own
# scheduler id until it holds instead of once: a child exiting while its
# replacement starts is a momentary overlap, while a process per retained PR
# never settles.
resident=0
per_pr=0
settled=0
for _ in $(seq 1 40); do
  resident=$(pgrep -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null | wc -l | tr -d ' ')
  per_pr=0
  pgrep -f 'fm-procevent-pr-follow.sh run prf-(gh|gl)-' >/dev/null 2>&1 && per_pr=1
  if [ "$resident" -le 1 ] && [ "$per_pr" -eq 0 ]; then
    settled=$((settled + 1))
    [ "$settled" -ge 3 ] && break
  else
    settled=0
  fi
  sleep 0.1
done
[ "$settled" -ge 3 ] \
  || fail "rotation kept $resident resident schedulers and $per_pr per-PR processes"
for s in "${sids[@]}"; do
  wait_for_baseline "$H" "$s" 200 || fail "rotation starved $s of its baseline poll"
done
rot_elapsed=$(( $(date +%s) - rot_start ))
startup_bursts=$(grep -c . "$GH_TEST_POLL_LOG" || true)
startup_allowed=$(( rot_elapsed / 2 + 2 ))
[ "$startup_bursts" -le "$startup_allowed" ] \
  || fail "simultaneous startup burst: $startup_bursts poll bursts in ${rot_elapsed}s (bound $startup_allowed)"
# Measure a stable eight-slot window: with five sources every one of them owns
# at least one slot, at most one poll burst may start per slot, and the lower
# bound tolerates a bounded number of boundary misses under load without
# allowing starvation (the deterministic starvation bound in the adapter
# header: every source owns one slot per five).
: > "$GH_TEST_POLL_LOG"
sleep 16
bursts=$(grep -c . "$GH_TEST_POLL_LOG" || true)
[ "$bursts" -ge 4 ] || fail "rotation starved a source: only $bursts poll bursts in eight slots"
[ "$bursts" -le 9 ] || fail "rotation exceeded the aggregate bound: $bursts poll bursts in eight slots"
for s in "${sids[@]}"; do
  assert_contains "$(cursor_field "$H" "$s" baseline)" "done" "$s kept its baseline"
done
FM_PR_FOLLOW_ROTATION_SLOT=5
export FM_PR_FOLLOW_ROTATION_SLOT
# The bound under test is the durable served-slot record, not the wall clock,
# so both restarts have to land inside one slot: start each attempt on a slot
# boundary and discard an attempt that still straddled the next one.
restarted_bursts=0
measured=0
for _ in $(seq 1 5); do
  pkill -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null || true
  pkill -f "fm-procevent.sh _start $scheduler_id" 2>/dev/null || true
  sleep "$(( 5 - $(date +%s) % 5 ))"
  : > "$GH_TEST_POLL_LOG"
  slot_before=$(( $(date +%s) / 5 ))
  restart_runner "$H"
  sleep 0.3
  pkill -f "fm-procevent-pr-follow.sh run $scheduler_id" 2>/dev/null || true
  pkill -f "fm-procevent.sh _start $scheduler_id" 2>/dev/null || true
  restart_runner "$H"
  sleep 0.5
  restarted_bursts=$(grep -c . "$GH_TEST_POLL_LOG" || true)
  if [ "$slot_before" = "$(( $(date +%s) / 5 ))" ]; then
    measured=1
    break
  fi
done
[ "$measured" -eq 1 ] || fail "two restarts never fitted inside one rotation slot"
[ "$restarted_bursts" -le 1 ] \
  || fail "restarting within one served slot repeated $restarted_bursts poll bursts"
FM_PR_FOLLOW_ROTATION_SLOT=1
export FM_PR_FOLLOW_ROTATION_SLOT
pass "rotation keeps every source polled at a bounded aggregate rate"

printf 'all fm-procevent-pr-follow tests passed\n'
