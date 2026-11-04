#!/usr/bin/env bash
# Tests for bin/fm-merge-queue.sh, the unattended merge queue: it decides from
# the live pull request whether a queued row may merge, hands the merge to
# bin/fm-pr-merge.sh, retires only terminal rows, keeps everything else queued,
# and appends exactly one durable line a day.
#
# Matrix:
#   (a) a green, QA-passed row merges through the merge entrypoint and retires
#   (b) a row whose head moved retires without any merge attempt
#   (c) a red check keeps the row queued and merges nothing
#   (d) a missing qa-review on the head keeps the row queued
#   (e) no configuration waives the qa-review requirement
#   (f) a fenced label retires the row and merges nothing
#   (g) an already-merged pull request retires without a merge attempt
#   (h) a refused merge retires the row after its attempt budget, as retired
#   (i) a duplicate row is attempted once and leaves with its key
#   (j) an unreadable forge never spends the attempt budget
#   (k) a bare repository row with no owner stays queued as unusable
#   (l) the queue rewrite preserves comments, blank lines, and file mode
#   (m) --dry-run reports the plan and changes nothing
#   (n) the first run of a day appends one daily line and writes the detail file
#   (o) status answers from records only, without any forge call
#   (p) unit prints a service and a timer bound to this home
#   (q) a waived credit-approval-guard merge says so in its line and the summary
#   (r) two owners of one repository name are two independent rows
#   (s) an uppercase expected head still matches the forge's lowercase object id
#   (t) two checks named qa-review cannot mask a failing instance
#   (u) a typo'd task id is unusable and never spends the attempt budget
#   (v) a run refuses when the forge tools are not on PATH
#   (w) the fence covers the natural spellings the queue actually uses
#   (x) a re-queued row with a new head supersedes the stale row, not dropped
#   (y) a body that names production DDL on a later line is fenced
#   (z) a pending credit guard holds the row and a failing one is named
#   (aa) a PR number that is not digits is unusable without a forge call
#   (ab) a failed staging copy publishes nothing and merges nothing
#   (ac) a hand-edit during a run is never overwritten by the rewrite
#   (ad) the daily window does not re-report the previous summary's second
#   (ae) a tick that overlaps a running tick merges nothing
#   (af) a lock left by a killed run does not wedge the timer
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUEUE_SCRIPT="$ROOT/bin/fm-merge-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-tests)

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab

# make_case <name>: a home with a data/ queue, a merge entrypoint stub that logs
# its argv, the task records a queued row must name, and a fakebin holding the
# gh mock. Echoes the case directory.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data" "$dir/bin" "$dir/state" "$dir/fakebin" "$dir/heads" "$dir/checks" "$dir/corebin"
  printf 'window=t\n' >"$dir/state/task-a.meta"
  printf 'window=t\n' >"$dir/state/task-b.meta"
  cat >"$dir/bin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_MERGE_LOG"
if [ -n "${FM_TEST_MERGE_FAIL:-}" ]; then
  printf 'fm-pr-merge: %s\n' "$FM_TEST_MERGE_FAIL" >&2
  exit 3
fi
printf 'verified merge of %s\n' "$2"
SH
  chmod +x "$dir/bin/fm-pr-merge.sh"
  write_gh_mock "$dir" OPEN
  : >"$dir/merge.log"
  : >"$dir/gh.log"
  printf '%s\n' "$dir"
}

# write_gh_mock <dir> <state>: the forge mock. It answers the two reads the
# queue makes and records every invocation.
write_gh_mock() {
  local dir=$1 state=$2
  printf '%s\n' "$state" >"$dir/pr-state"
  cat >"$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
num=${3##*/}
state=$(cat "$FM_TEST_DIR/pr-state")
case "${1:-} ${2:-}" in
  "pr view")
    head=${FM_TEST_HEAD:-}
    if [ -f "$FM_TEST_DIR/heads/$num" ]; then
      head=$(cat "$FM_TEST_DIR/heads/$num")
    fi
    printf '%s\037%s\037%s\037%s\n' "$state" "$head" "${FM_TEST_LABELS:-}" "${FM_TEST_BODY:-}"
    ;;
  "pr checks")
    if [ -f "$FM_TEST_DIR/checks/$num" ]; then
      cat "$FM_TEST_DIR/checks/$num"
      exit 0
    fi
    [ -n "${FM_TEST_CHECKS:-}" ] || exit 1
    printf '%s\n' "$FM_TEST_CHECKS"
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/gh"
  # The merge entrypoint shells out to gh-axi, so the run provably requires it.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/fakebin/gh-axi"
  chmod +x "$dir/fakebin/gh-axi"
}

# run_queue <dir> [args...]: run the queue against one home.
run_queue() {
  local dir=$1
  shift
  FM_HOME="$dir" \
    FM_ROOT_OVERRIDE="$dir" \
    FM_MERGE_QUEUE_MAX_ATTEMPTS="${FM_MERGE_QUEUE_MAX_ATTEMPTS:-}" \
    FM_TEST_MERGE_LOG="$dir/merge.log" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_DIR="$dir" \
    PATH="$dir/fakebin:$PATH" \
    "${QUEUE_SCRIPT}" "$@" 2>&1
}

queue_rows() {  # <dir>
  grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1/data/go-queue.txt" 2>/dev/null || true
}

# A green head with its QA review posted, which is what every merge case needs.
green_head() {
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tpass'
}

clear_head() {
  unset FM_TEST_HEAD FM_TEST_CHECKS FM_TEST_LABELS FM_TEST_BODY FM_TEST_MERGE_FAIL
}

# --- (a) a ready row merges and retires ------------------------------------

case_a() {
  local dir out
  dir=$(make_case a)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  expect_code 0 "$?" "(a) run exits 0"
  assert_contains "$out" "merged acme/widgets#12" "(a) the row reports a merge"
  assert_grep "task-a https://github.com/acme/widgets/pull/12 -- --squash --admin --match-head-commit $HEAD_A" \
    "$dir/merge.log" "(a) the merge goes through the entrypoint with the live head"
  expect_code 0 "$(queue_rows "$dir")" "(a) the merged row leaves the queue"
  assert_grep "merged" "$dir/state/merge-queue/ledger.tsv" "(a) the merge is in the ledger"
  clear_head
  pass "a ready row merges and retires"
}

# --- (b) a moved head retires without merging ------------------------------

case_b() {
  local dir out
  dir=$(make_case b)
  printf '# owner: acme\nwidgets 12 bbbbbbb task-a squash\n' >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "head moved" "(b) the moved head is reported"
  [ ! -s "$dir/merge.log" ] || fail "(b) a moved head must never reach the merge entrypoint"
  expect_code 0 "$(queue_rows "$dir")" "(b) the stale row leaves the queue"
  clear_head
  pass "a moved head retires without merging"
}

# --- (c) a red check keeps the row -----------------------------------------

case_c() {
  local dir out
  dir=$(make_case c)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tfail'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "not green" "(c) the red check is reported"
  [ ! -s "$dir/merge.log" ] || fail "(c) a red head must never reach the merge entrypoint"
  expect_code 1 "$(queue_rows "$dir")" "(c) the row stays queued"
  clear_head
  pass "a red check keeps the row queued"
}

# --- (d) a missing qa-review keeps the row ---------------------------------

case_d() {
  local dir out
  dir=$(make_case d)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'build\tpass'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "no qa-review on this head" "(d) the absent QA check is reported"
  [ ! -s "$dir/merge.log" ] || fail "(d) a head with no QA review must never merge"
  expect_code 1 "$(queue_rows "$dir")" "(d) the row stays queued"
  clear_head
  pass "a missing qa-review keeps the row queued"
}

# --- (e) no configuration waives QA ---------------------------------------

case_e() {
  local dir out
  dir=$(make_case e)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'build\tpass'
  # A home that used to be able to switch the QA gate off cannot any more.
  out=$(FM_MERGE_QUEUE_QA=optional run_queue "$dir" run)
  assert_contains "$out" "no qa-review on this head" "(e) the QA gate cannot be configured away"
  [ ! -s "$dir/merge.log" ] || fail "(e) no environment setting may merge an unreviewed head"
  expect_code 1 "$(queue_rows "$dir")" "(e) the row stays queued"
  clear_head
  pass "no configuration waives the qa-review requirement"
}

# --- (f) a fenced label never merges --------------------------------------

case_f() {
  local dir out
  dir=$(make_case f)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_LABELS="money customer-copy"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider" "(f) the fence is reported"
  [ ! -s "$dir/merge.log" ] || fail "(f) a fenced change must never reach the merge entrypoint"
  expect_code 0 "$(queue_rows "$dir")" "(f) the fenced row leaves the queue"
  clear_head
  pass "a fenced label retires the row without merging"
}

# --- (g) an already-merged pull request retires ----------------------------

case_g() {
  local dir out
  dir=$(make_case g)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  write_gh_mock "$dir" MERGED
  out=$(run_queue "$dir" run)
  assert_contains "$out" "already merged" "(g) the already-merged row is reported"
  [ ! -s "$dir/merge.log" ] || fail "(g) an already-merged pull request must not be merged again"
  expect_code 0 "$(queue_rows "$dir")" "(g) the already-merged row leaves the queue"
  clear_head
  pass "an already-merged pull request retires without merging"
}

# --- (h) a refused merge spends the attempt budget ------------------------

case_h() {
  local dir out
  dir=$(make_case h)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_MERGE_FAIL='pr= metadata missing'
  export FM_MERGE_QUEUE_MAX_ATTEMPTS=1
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_MAX_ATTEMPTS
  assert_contains "$out" "merge refused: fm-pr-merge: pr= metadata missing" \
    "(h) the entrypoint's own refusal is reported"
  assert_contains "$out" "after 1 failed merge attempt" "(h) the budget retires the row"
  expect_code 0 "$(queue_rows "$dir")" "(h) an exhausted row leaves the queue"
  assert_grep $'\tabandoned\t' "$dir/state/merge-queue/ledger.tsv" \
    "(h) the abandoned row carries its own verdict"
  assert_grep "retired 1" "$dir/state/.wake-queue" "(h) the daily line counts it as retired"
  clear_head
  pass "a refused merge retires the row after its attempt budget"
}

# --- (i) duplicate rows are attempted once --------------------------------

case_i() {
  local dir out attempts
  dir=$(make_case i)
  printf '# owner: acme\nwidgets 12 %s task-a squash\nwidgets 12 %s task-a squash\n' "$HEAD_A" "$HEAD_A" \
    >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  attempts=$(wc -l <"$dir/merge.log" | tr -d ' ')
  expect_code 1 "$attempts" "(i) a duplicate row is merged once"
  expect_code 0 "$(queue_rows "$dir")" "(i) the duplicate leaves with its key"
  assert_contains "$out" "merged acme/widgets#12" "(i) the row reports the merge"
  clear_head
  pass "a duplicate row is attempted once"
}

# --- (j) an unreadable forge never spends the budget ---------------------

case_j() {
  local dir out
  dir=$(make_case j)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/fakebin/gh"
  chmod +x "$dir/fakebin/gh"
  export FM_MERGE_QUEUE_MAX_ATTEMPTS=1
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_MAX_ATTEMPTS
  assert_contains "$out" "forge did not answer" "(j) the failed read is reported"
  expect_code 1 "$(queue_rows "$dir")" "(j) a transient outage keeps the row queued"
  clear_head
  pass "an unreadable forge never spends the attempt budget"
}

# --- (k) an unusable row is kept, not deleted -----------------------------

case_k() {
  local dir out
  dir=$(make_case k)
  printf 'widgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "no repository owner for widgets" "(k) the missing owner is reported"
  assert_contains "$out" "unusable" "(k) the row reads as unusable"
  expect_code 1 "$(queue_rows "$dir")" "(k) a configuration mistake never deletes a row"
  [ ! -s "$dir/merge.log" ] || fail "(k) an unusable row must not reach the merge entrypoint"
  clear_head
  pass "a bare repository row with no owner stays queued"
}

# --- (l) the rewrite preserves the rest of the file ----------------------

case_l() {
  local dir out
  dir=$(make_case l)
  printf '# owner: acme\n# a note from the captain\n\nwidgets 12 %s task-a squash\n\nwidgets 13 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab task-b squash\n' \
    "$HEAD_A" >"$dir/data/go-queue.txt"
  chmod 0640 "$dir/data/go-queue.txt"
  printf 'qa-review\tpass\nbuild\tfail\n' >"$dir/checks/13"
  green_head
  out=$(run_queue "$dir" run)
  assert_grep "# a note from the captain" "$dir/data/go-queue.txt" "(l) comments survive the rewrite"
  assert_grep "# owner: acme" "$dir/data/go-queue.txt" "(l) the owner directive survives"
  assert_grep "widgets 13 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab task-b squash" "$dir/data/go-queue.txt" "(l) untouched rows survive"
  assert_no_grep "widgets 12" "$dir/data/go-queue.txt" "(l) the retired row is gone"
  assert_contains "$out" "run: merged 1" "(l) one merge is reported"
  expect_code 640 "$(stat -c %a "$dir/data/go-queue.txt" 2>/dev/null || stat -f %Lp "$dir/data/go-queue.txt")" \
    "(l) the queue file keeps its mode"
  clear_head
  pass "the queue rewrite preserves comments, blank lines, and mode"
}

# --- (m) dry run changes nothing -----------------------------------------

case_m() {
  local dir out before
  dir=$(make_case m)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  before=$(cat "$dir/data/go-queue.txt")
  green_head
  out=$(run_queue "$dir" run --dry-run)
  assert_contains "$out" "merge acme/widgets#12" "(m) the dry run names the merge it would make"
  assert_contains "$out" "nothing changed" "(m) the dry run says it changed nothing"
  [ ! -s "$dir/merge.log" ] || fail "(m) a dry run must not merge"
  [ "$before" = "$(cat "$dir/data/go-queue.txt")" ] || fail "(m) a dry run must not rewrite the queue"
  assert_absent "$dir/state/merge-queue/ledger.tsv" "(m) a dry run writes no ledger"
  assert_absent "$dir/state/.wake-queue" "(m) a dry run appends no wake"
  clear_head
  pass "dry run reports the plan and changes nothing"
}

# --- (n) one daily line per day, with its detail file --------------------

case_n() {
  local dir out lines detail
  dir=$(make_case n)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "summary: check: merge queue" "(n) the first run of the day emits the daily line"
  assert_grep "merged 1" "$dir/state/.wake-queue" "(n) the daily line counts the merge"
  assert_grep "detail: $dir/state/merge-queue/daily-" "$dir/state/.wake-queue" \
    "(n) the daily line points at the detail file"
  assert_no_grep "acme/widgets#12" "$dir/state/.wake-queue" \
    "(n) the daily line does not truncate a row list into itself"
  lines=$(wc -l <"$dir/state/.wake-queue" | tr -d ' ')
  expect_code 1 "$lines" "(n) exactly one line is queued"
  detail=$(sed -n 's/.*detail: \([^;]*\).*/\1/p' "$dir/state/.wake-queue")
  assert_grep "acme/widgets#12" "$detail" "(n) the detail file names the merged row"
  assert_grep "https://github.com/acme/widgets/pull/12" "$detail" \
    "(n) the detail file carries the full pull request URL"
  out=$(run_queue "$dir" run)
  assert_not_contains "$out" "summary:" "(n) a later run the same day emits nothing"
  expect_code 1 "$(wc -l <"$dir/state/.wake-queue" | tr -d ' ')" "(n) the queue still holds one line"
  clear_head
  pass "the queue appends one line a day"
}

# --- (o) status reads records only ---------------------------------------

case_o() {
  local dir out
  dir=$(make_case o)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  run_queue "$dir" run >/dev/null
  : >"$dir/gh.log"
  out=$(run_queue "$dir" status)
  assert_contains "$out" "merge queue: 0 row(s)" "(o) status reports the queue size"
  assert_contains "$out" "merged 1" "(o) status reports the last run"
  [ ! -s "$dir/gh.log" ] || fail "(o) status must make no forge call"
  clear_head
  pass "status answers from records only"
}

# --- (p) the units name this home and this script ------------------------

case_p() {
  local dir service timer
  dir=$(make_case p)
  service=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "${QUEUE_SCRIPT}" unit service)
  timer=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "${QUEUE_SCRIPT}" unit timer)
  assert_contains "$service" "ExecStart=$ROOT/bin/fm-merge-queue.sh run" "(p) the service runs this script"
  assert_contains "$service" "Environment=FM_HOME=$dir" "(p) the service names this home"
  assert_contains "$service" "Environment=PATH=%h/.local/bin" \
    "(p) the service puts the user's own tools on the timer's PATH"
  assert_contains "$timer" "OnUnitActiveSec=10min" "(p) the timer runs every ten minutes"
  assert_contains "$timer" "Unit=fm-merge-queue.service" "(p) the timer drives the service"
  pass "unit prints a service and a timer bound to this home"
}

# --- (q) the credit guard waiver is never silent -------------------------

case_q() {
  local dir out detail
  dir=$(make_case q)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tpass\ncredit-approval-guard\tfail'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged acme/widgets#12 https://github.com/acme/widgets/pull/12 (credit-guard waived)" \
    "(q) the merge names the waiver on its own line"
  assert_grep "credit-guard waived" "$dir/state/merge-queue/ledger.tsv" \
    "(q) the ledger records the waiver"
  assert_grep "1 with credit-guard waived" "$dir/state/.wake-queue" \
    "(q) the daily line counts the waived merge"
  detail=$(sed -n 's/.*detail: \([^;]*\).*/\1/p' "$dir/state/.wake-queue")
  assert_grep "credit-guard waived" "$detail" "(q) the detail file records the waiver"
  clear_head
  pass "a waived credit guard is reported, not hidden"
}

# --- (r) two owners of one repository name are two rows ------------------

case_r() {
  local dir out attempts
  dir=$(make_case r)
  printf 'acme/widgets 12 %s task-a squash\nbeta/widgets 12 %s task-b squash\n' "$HEAD_A" "$HEAD_A" \
    >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  attempts=$(wc -l <"$dir/merge.log" | tr -d ' ')
  expect_code 2 "$attempts" "(r) both owners' rows are attempted"
  assert_grep "https://github.com/acme/widgets/pull/12" "$dir/merge.log" "(r) the first owner merges"
  assert_grep "https://github.com/beta/widgets/pull/12" "$dir/merge.log" "(r) the second owner merges"
  expect_code 0 "$(queue_rows "$dir")" "(r) both rows leave the queue"
  clear_head
  pass "two owners of one repository name stay independent rows"
}

# --- (s) an uppercase expected head still matches ------------------------

case_s() {
  local dir out
  dir=$(make_case s)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB" \
    >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged acme/widgets#12" "(s) the uppercase head merges"
  [ -s "$dir/merge.log" ] || fail "(s) an uppercase head is a match, not a moved head"
  clear_head
  pass "an uppercase expected head still matches"
}

# --- (t) a duplicate qa-review name cannot mask a failure ----------------

case_t() {
  local dir out
  dir=$(make_case t)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tfail\nqa-review\tpass'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "qa-review=fail" "(t) the failing instance holds the row"
  [ ! -s "$dir/merge.log" ] || fail "(t) a passing duplicate must not mask a failing QA check"
  expect_code 1 "$(queue_rows "$dir")" "(t) the row stays queued"
  clear_head
  pass "a duplicate qa-review name cannot mask a failure"
}

# --- (u) a typo'd task id is unusable, not refused -----------------------

case_u() {
  local dir out
  dir=$(make_case u)
  printf '# owner: acme\nwidgets 12 %s task-typo squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_MERGE_QUEUE_MAX_ATTEMPTS=1
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_MAX_ATTEMPTS
  assert_contains "$out" "no such task in this home: task-typo" "(u) the bad task id is named"
  [ ! -s "$dir/merge.log" ] || fail "(u) an unreadable task id must never reach the merge entrypoint"
  expect_code 1 "$(queue_rows "$dir")" "(u) the row stays queued"
  assert_no_grep $'\tabandoned\t' "$dir/state/merge-queue/ledger.tsv" \
    "(u) a configuration mistake never spends the retry budget"
  clear_head
  pass "a typo'd task id is unusable and never spends the attempt budget"
}

# --- (v) a run refuses when the forge tools are missing -----------------

case_v() {
  local dir out shell_bin
  dir=$(make_case v)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  # Resolve the shell before the PATH is emptied, so only the forge tools are
  # missing from the run's own PATH.
  shell_bin=$(command -v bash)
  out=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_TEST_DIR="$dir" \
    FM_TEST_MERGE_LOG="$dir/merge.log" FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/corebin" "$shell_bin" "${QUEUE_SCRIPT}" run 2>&1)
  expect_code 1 "$?" "(v) the run refuses instead of reporting an unanswered forge"
  assert_contains "$out" "is not on PATH" "(v) the refusal names the missing tool"
  [ ! -s "$dir/merge.log" ] || fail "(v) a run with no forge tools must merge nothing"
  expect_code 1 "$(queue_rows "$dir")" "(v) the queued row is untouched"
  clear_head
  pass "a run refuses when the forge tools are not on PATH"
}

# --- (w) the fence covers the natural spellings -------------------------

case_w() {
  local dir out
  dir=$(make_case w)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_LABELS="secrets"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider: secrets" "(w) a plural label spelling is fenced"
  [ ! -s "$dir/merge.log" ] || fail "(w) a secrets label must never merge unattended"

  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  : >"$dir/merge.log"
  export FM_TEST_LABELS="customer copy"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider: customercopy" "(w) a two-word label is fenced"
  [ ! -s "$dir/merge.log" ] || fail "(w) customer copy must never merge unattended"

  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  : >"$dir/merge.log"
  unset FM_TEST_LABELS
  export FM_TEST_BODY="This ships the production DDL for the new table."
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider: prod-ddl" "(w) a body naming production DDL is fenced"
  [ ! -s "$dir/merge.log" ] || fail "(w) production DDL must never merge unattended"
  clear_head
  pass "the fence covers the natural spellings"
}

# --- (x) a re-queued row supersedes the stale row -------------------------

case_x() {
  local dir out detail
  dir=$(make_case x)
  # Exactly the re-queue the docs prescribe after a push: the stale row is still
  # in the file when the row for the new head is added.
  printf '# owner: acme\nwidgets 12 bbbbbbb task-a squash\nwidgets 12 %s task-a squash\n' "$HEAD_A" \
    >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "superseded by the newer row at $HEAD_A" \
    "(x) the stale row is reported as superseded"
  assert_contains "$out" "merged acme/widgets#12" "(x) the re-queued row merges"
  expect_code 1 "$(wc -l <"$dir/merge.log" | tr -d ' ')" "(x) exactly one merge is attempted"
  expect_code 0 "$(queue_rows "$dir")" "(x) neither row is left behind"
  assert_grep $'\tsuperseded\t' "$dir/state/merge-queue/ledger.tsv" \
    "(x) the superseded row carries its own verdict"
  detail=$(sed -n 's/.*detail: \([^;]*\).*/\1/p' "$dir/state/.wake-queue")
  assert_grep "acme/widgets#12@bbbbbbb" "$detail" "(x) the detail file names the superseded row"
  assert_grep "superseded" "$detail" "(x) the detail file records its verdict"
  assert_grep "https://github.com/acme/widgets/pull/12" "$detail" \
    "(x) the superseded row keeps its full pull request URL"

  # A row this home cannot read is a configuration mistake, not a newer head:
  # it stays queued for the operator and never supersedes a readable row.
  printf '# owner: acme\nwidgets 12 %s task-a squash\nwidgets 12 cccccccccccccccccccccccccccccccccccccc task-typo squash\n' \
    "$HEAD_A" >"$dir/data/go-queue.txt"
  : >"$dir/merge.log"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged acme/widgets#12" "(x) the readable row is not superseded by a broken one"
  assert_contains "$out" "no such task in this home: task-typo" "(x) the broken row is still reported"
  expect_code 1 "$(queue_rows "$dir")" "(x) the broken row stays queued for the operator"
  clear_head
  pass "a re-queued row supersedes the stale row instead of being dropped"
}

# --- (y) a multi-line body still reaches the fence ------------------------

case_y() {
  local dir out
  dir=$(make_case y)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_BODY=$'A one-line summary.\n\nThis change ships the production DDL for the orders table.\n'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider: prod-ddl" "(y) the later body line is fenced"
  [ ! -s "$dir/merge.log" ] || fail "(y) production DDL named below the first line must never merge"
  clear_head
  pass "a body that names production DDL on a later line is fenced"
}

# --- (z) the credit guard holds while pending, waives when failing -------

case_z() {
  local dir out
  dir=$(make_case z)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tpass\ncredit-approval-guard\tpending'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "credit-approval-guard pending" "(z) a pending guard is reported"
  [ ! -s "$dir/merge.log" ] || fail "(z) a guard that has not finished must hold the row"
  expect_code 1 "$(queue_rows "$dir")" "(z) the held row stays queued"

  # Two instances of the one check name: the failing one is the waiver, and a
  # passing duplicate cannot hide it.
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tpass\ncredit-approval-guard\tfail\ncredit-approval-guard\tpass'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged acme/widgets#12 https://github.com/acme/widgets/pull/12 (credit-guard waived)" \
    "(z) a failing instance beside a passing one is still named as the waiver"
  assert_grep "credit-guard waived" "$dir/state/merge-queue/ledger.tsv" \
    "(z) the ledger records the waiver"
  clear_head
  pass "a pending credit guard holds and a failing one is named"
}

# --- (aa) a non-numeric PR number is unusable ----------------------------

case_aa() {
  local dir out
  dir=$(make_case aa)
  printf '# owner: acme\nwidgets 12, %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "unusable row" "(aa) the pasted number is classified unusable"
  assert_contains "$out" "1 queued row(s) need the queue file fixed" \
    "(aa) the daily line counts it as a row the file must fix"
  [ ! -s "$dir/gh.log" ] || fail "(aa) an unusable number must never be asked of the forge"
  [ ! -s "$dir/merge.log" ] || fail "(aa) an unusable number must never merge"
  expect_code 1 "$(queue_rows "$dir")" "(aa) the row stays queued for the operator to fix"
  clear_head
  pass "a PR number that is not digits is unusable without a forge call"
}

# --- (ab) a failed staging copy publishes nothing -----------------------

case_ab() {
  local dir out before mode
  dir=$(make_case ab)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  chmod 0640 "$dir/data/go-queue.txt"
  before=$(cat "$dir/data/go-queue.txt")
  green_head
  # The mode copy of the queue is what makes the rewrite safe to publish, so a
  # copy that cannot be made must stop the run before it decides any row.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/fakebin/cp"
  chmod +x "$dir/fakebin/cp"
  out=$(run_queue "$dir" run)
  expect_code 1 "$?" "(ab) the run fails when the queue cannot be staged"
  assert_contains "$out" "mode copy failed" "(ab) the failure names the staging copy"
  [ ! -s "$dir/merge.log" ] || fail "(ab) a run that cannot stage the queue must merge nothing"
  [ "$before" = "$(cat "$dir/data/go-queue.txt")" ] || fail "(ab) a failed staging copy must not rewrite the queue"
  mode=$(stat -c %a "$dir/data/go-queue.txt" 2>/dev/null || stat -f %Lp "$dir/data/go-queue.txt")
  expect_code 640 "$mode" "(ab) the queue keeps its mode"
  clear_head
  pass "a failed staging copy publishes nothing and merges nothing"
}

# --- (ac) a hand-edit during the run is never overwritten ----------------

case_ac() {
  local dir out
  dir=$(make_case ac)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  # The captain hand-edits the queue while a tick is held by the merge call.
  cat >"$dir/bin/fm-pr-merge.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\$FM_TEST_MERGE_LOG"
printf '# a note added by hand\\n' >>"$dir/data/go-queue.txt"
printf 'verified merge\\n'
SH
  chmod +x "$dir/bin/fm-pr-merge.sh"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "changed during this run" "(ac) the deferred rewrite is reported"
  assert_grep "# a note added by hand" "$dir/data/go-queue.txt" \
    "(ac) the hand-edit survives the run"
  assert_grep "widgets 12 $HEAD_A task-a squash" "$dir/data/go-queue.txt" \
    "(ac) nothing is published over the edited queue"
  clear_head
  pass "a hand-edit during a run is never overwritten by the rewrite"
}

# --- (ad) the daily window does not re-report the summary's second -------

case_ad() {
  local dir out detail epoch
  dir=$(make_case ad)
  mkdir -p "$dir/state/merge-queue"
  epoch=$(date -u +%s)
  # A merge recorded in the very second the previous summary was written
  # belongs to that summary, so this window must not count or list it again.
  printf '%s\tacme/widgets#12@%s\tmerged\tsquash\thttps://github.com/acme/widgets/pull/12\n' \
    "$epoch" "$HEAD_A" >"$dir/state/merge-queue/ledger.tsv"
  printf '2020-01-01\t%s\n' "$epoch" >"$dir/state/merge-queue/.summary"
  printf '# owner: acme\n# nothing queued\n' >"$dir/data/go-queue.txt"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged 0" "(ad) the previous summary's merge is not counted again"
  detail=$(sed -n 's/.*detail: \([^;]*\).*/\1/p' "$dir/state/.wake-queue")
  assert_no_grep "https://github.com/acme/widgets/pull/12" "$detail" \
    "(ad) the detail file does not list a row the earlier summary already named"
  clear_head
  pass "the daily window does not re-report the previous summary's second"
}

# --- (ae) an overlapping tick merges nothing -----------------------------

case_ae() {
  local dir out
  dir=$(make_case ae)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  # A merge call can hold a tick for minutes, and the timer fires every ten, so
  # two ticks really can overlap: the second must decide nothing at all.
  mkdir -p "$dir/state/merge-queue/.lock"
  printf '%s\n' "$$" >"$dir/state/merge-queue/.lock/pid"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "another run is in progress" "(ae) the overlapping tick reports the run in progress"
  [ ! -s "$dir/merge.log" ] || fail "(ae) an overlapping tick must merge nothing"
  expect_code 1 "$(queue_rows "$dir")" "(ae) the queued row is untouched"
  assert_absent "$dir/state/merge-queue/ledger.tsv" "(ae) the skipped tick records no verdict"
  # The running tick still owns the lock, so the skipped tick must not remove it.
  assert_present "$dir/state/merge-queue/.lock/pid" "(ae) the running tick keeps its lock"
  clear_head
  pass "an overlapping tick merges nothing"
}

# --- (af) a lock left by a killed run does not wedge the timer ------------

case_af() {
  local dir out dead
  dir=$(make_case af)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  # A run killed mid-merge (a reboot, or systemd stopping the unit) leaves its
  # lock behind. Without recovery every later tick would skip forever.
  sh -c 'exit 0' &
  dead=$!
  wait "$dead" 2>/dev/null || true
  mkdir -p "$dir/state/merge-queue/.lock"
  printf '%s\n' "$dead" >"$dir/state/merge-queue/.lock/pid"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "merged acme/widgets#12" "(af) the tick after a killed run still merges"
  expect_code 0 "$(queue_rows "$dir")" "(af) the row lands instead of waiting forever"
  assert_absent "$dir/state/merge-queue/.lock/pid" "(af) the stale lock is released"
  clear_head
  pass "a lock left by a killed run does not wedge the timer"
}

case_a
case_b
case_c
case_d
case_e
case_f
case_g
case_h
case_i
case_j
case_k
case_l
case_m
case_n
case_o
case_p
case_q
case_r
case_s
case_t
case_u
case_v
case_w
case_x
case_y
case_z
case_aa
case_ab
case_ac
case_ad
case_ae
case_af

printf 'ok - fm-merge-queue suite complete\n'
