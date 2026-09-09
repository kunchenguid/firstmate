#!/usr/bin/env bash
# Tests for fm-gitlab-issues.sh, the GitLab issue intake poll.
#
# The check is what lets a firstmate home notice that a human handed it an issue
# by label without ever running a network call in a conversational turn, so the
# cases here pin the watcher-facing contract: exactly one line when there is
# something new and silence otherwise, a seen record that forgets a pair as soon
# as the label leaves the issue so a re-added label is news again, a pending file
# firstmate reads instead of calling GitLab, and a poll error that wakes firstmate
# once rather than on every sweep.
#
# Every case runs against a fake glab placed first on PATH that serves fixtures
# per label and records the arguments it was called with, so no case reaches a
# network. jq is the real one: the check's whole reading of GitLab's answer is jq
# programs, and a fake jq would only confirm assumptions written into the fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-gitlab-issues.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-gitlab-issues)

command -v jq >/dev/null 2>&1 || fail "these tests need the real jq on PATH"

HOST=gitlab.example.test
GROUP=acme/tools

# make_home <name>: a home with a fake glab of its own, a fixture directory the
# fake serves from, and a log of every glab call. Prints the home path; the fake's
# environment is exported per case through run_check.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/gitlab"
  cat > "$home/fakebin/glab" <<'SH'
#!/usr/bin/env bash
# Fake glab: record the call, then serve the fixture for the requested label.
printf '%s\n' "$*" >> "$FAKE_GLAB_LOG"
if [ -e "$FAKE_GLAB_DIR/fail" ]; then
  cat "$FAKE_GLAB_DIR/fail" >&2
  exit 1
fi
if [ -e "$FAKE_GLAB_DIR/hang" ]; then
  sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}"
  exit 1
fi
if [ -f "$FAKE_GLAB_DIR/delay" ]; then
  sleep "$(cat "$FAKE_GLAB_DIR/delay")"
fi
endpoint=${*: -1}
label=$(printf '%s' "$endpoint" | sed -n 's/.*labels=\([^&]*\).*/\1/p' | sed 's/%3A/:/g')
fixture="$FAKE_GLAB_DIR/$label.ndjson"
[ -f "$fixture" ] && cat "$fixture"
exit 0
SH
  chmod 0755 "$home/fakebin/glab"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/gitlab-issues.json"
}

# issue <project> <iid> <label...>: one GitLab issue as the API returns it, with
# the project only derivable from web_url and references.full.
issue() {
  local project=$1 iid=$2
  shift 2
  jq -cn --arg p "$project" --argjson iid "$iid" --arg host "$HOST" --args '
    {
      iid: $iid, title: "Issue \($iid)", state: "opened",
      labels: $ARGS.positional,
      web_url: "https://\($host)/\($p)/-/issues/\($iid)",
      references: { full: "\($p)#\($iid)" },
      author: { username: "alice" },
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-02T00:00:00Z",
      description: "Body of \($iid) with a tab\tand \"quotes\""
    }' "$@"
}

# issue_shape <web_url> <references-full-or-empty> <iid> <label...>: one issue with
# its project fields spelled out, for the install shapes `issue` does not cover -
# a GitLab under a relative URL root, and an answer with no references object.
issue_shape() {
  local url=$1 full=$2 iid=$3
  shift 3
  jq -cn --arg url "$url" --arg full "$full" --argjson iid "$iid" --args '
    {
      iid: $iid, title: "Issue \($iid)", state: "opened",
      labels: $ARGS.positional,
      web_url: $url,
      author: { username: "alice" },
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-02T00:00:00Z",
      description: "Body of \($iid)"
    }
    | if $full == "" then . else . + { references: { full: $full } } end' "$@"
}

# serve <home> <label> [issue-json...]: what the fake glab answers for that label.
serve() {
  local home=$1 label=$2
  shift 2
  if [ "$#" -eq 0 ]; then
    : > "$home/gitlab/$label.ndjson"
  else
    printf '%s\n' "$@" > "$home/gitlab/$label.ndjson"
  fi
}

# The watcher check timeout is pinned to its documented default so an operator's
# ambient value cannot change the sweep budget under a case.
run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" \
    "$CHECK" check >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "check exit"
}

run_sub() {
  local home=$1
  shift
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" "$CHECK" "$@"
}

line_count() {
  wc -l < "$1" | tr -d '[:space:]'
}

# --- configuration ------------------------------------------------------------

test_absent_config_is_silent() {
  local home out
  home=$(make_home no-config)
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a home without config/gitlab-issues.json produced output: $(cat "$out")"
  pass "no config means no poll and no output"
}

test_config_problems_name_the_field() {
  local home out status err
  home=$(make_home bad-config)
  out="$home/out.txt"
  err="$home/err.txt"

  write_config "$home" '{"group":"acme/tools"}'
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue poll error:" "a config without host was not reported as a poll error"
  assert_contains "$(cat "$out")" "host" "the missing host field was not named"
  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "arm with a config missing host exit"
  assert_contains "$(cat "$err")" "host" "arm did not name the missing host field"
  assert_absent "$home/state/gitlab-issues.check.sh" "arm wrote a shim for a config it refused"

  write_config "$home" "{\"host\":\"$HOST\"}"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "group" "the missing group field was not named"

  write_config "$home" "{\"host\":\"Not_A_Host\",\"group\":\"$GROUP\"}"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "host Not_A_Host" "an invalid host name was not named"

  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"projects\":\"backend-app\"}"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "projects" "a non-array projects field was not named"

  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"intake_labels\":[]}"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "intake_labels" "an empty intake_labels field was not named"

  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"max_in_flight\":\"3\"}"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "max_in_flight" "a non-integer max_in_flight was not named"

  write_config "$home" '{not json'
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "not valid JSON" "unparseable config was not reported"

  # Every one of those was a different reason, so each was printed; none of them
  # reached GitLab.
  [ ! -e "$home/glab.log" ] || fail "a refused config still called glab: $(cat "$home/glab.log")"
  pass "a malformed or incomplete config is reported naming the field, and never polls"
}

# --- reporting ------------------------------------------------------------------

test_first_check_reports_and_records_then_stays_silent() {
  local home out report pending
  home=$(make_home first)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo bug)" "$(issue acme/tools/frontend-app 3 fm::todo)"
  serve "$home" fm::human-replied "$(issue acme/tools/backend-app 7 fm::human-replied)"
  out="$home/out.txt"

  run_check "$home" "$out"
  report=$(cat "$out")
  [ "$(line_count "$out")" = 1 ] || fail "the report must be exactly one line for the wake record: $report"
  assert_contains "$report" "gitlab-issue 3 new:" "the report does not carry its prefix and count"
  assert_contains "$report" "acme/tools/backend-app#12(fm::todo)" "issue 12 was not reported under fm::todo"
  assert_contains "$report" "acme/tools/frontend-app#3(fm::todo)" "issue 3 was not reported"
  assert_contains "$report" "acme/tools/backend-app#7(fm::human-replied)" "the human-replied issue was not reported"

  pending=$(run_sub "$home" pending)
  [ "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')" = 3 ] || fail "pending must hold one JSON line per reported pair: $pending"
  printf '%s\n' "$pending" | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#12" and .label == "fm::todo" and .iid == 12 and .project == "acme/tools/backend-app" and (.labels | index("bug") != null) and .title == "Issue 12" and (.web_url | endswith("/-/issues/12")) and (.description | contains("quotes")) and (.seen_epoch | type) == "number")' >/dev/null \
    || fail "the pending record for issue 12 does not carry the issue details: $pending"
  assert_present "$home/state/.gitlab-issues-seen" "the seen record was not written"

  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a second check with nothing new produced output: $(cat "$out")"
  [ "$(printf '%s\n' "$(run_sub "$home" pending)" | wc -l | tr -d ' ')" = 3 ] || fail "a silent check appended to pending again"
  pass "the first check reports every new pair once, writes the pending details, and the next check is silent"
}

test_removed_label_forgets_the_pair_and_a_re_added_label_is_news() {
  local home out
  home=$(make_home relabel)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "backend-app#12(fm::todo)" "the first report is missing"

  # Firstmate moved the issue on: fm::todo is gone, so the label query no longer
  # returns it. Nothing is new, and the pair must be forgotten.
  serve "$home" fm::todo
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "removing the label produced a report: $(cat "$out")"

  # A human put fm::todo back: that is a new hand-over, reported again.
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#12(fm::todo)" "a re-added label was not reported again"

  # The other intake label on the same issue is its own pair, and news of its own.
  serve "$home" fm::todo
  serve "$home" fm::human-replied "$(issue acme/tools/backend-app 12 fm::human-replied)"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#12(fm::human-replied)" "a different intake label on a known issue was not reported"
  pass "a pair is forgotten when its label leaves the issue, so the same label put back is reported again"
}

test_projects_filter_keeps_only_configured_projects() {
  local home out report
  home=$(make_home projects)
  # One relative entry and one full path_with_namespace entry, both accepted.
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"projects\":[\"backend-app\",\"acme/tools/frontend-app\"]}"
  serve "$home" fm::todo \
    "$(issue acme/tools/backend-app 1 fm::todo)" \
    "$(issue acme/tools/frontend-app 2 fm::todo)" \
    "$(issue acme/tools/other-app 3 fm::todo)" \
    "$(issue acme/tools/sub/backend-app 4 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "gitlab-issue 2 new:" "the count must cover only configured projects"
  assert_contains "$report" "acme/tools/backend-app#1(fm::todo)" "a relative project entry did not match its project"
  assert_contains "$report" "acme/tools/frontend-app#2(fm::todo)" "a full project path entry did not match its project"
  assert_not_contains "$report" "other-app" "an unconfigured project leaked into the report"
  assert_not_contains "$report" "sub/backend-app" "a subgroup project with the same name matched a relative entry"
  pass "the projects list narrows the group's issues to the configured projects"
}

test_the_project_path_comes_from_the_canonical_reference() {
  local home out report
  # A GitLab served under a relative URL root ("/gitlab") puts the URL root in
  # front of the project path in every web_url, so the canonical references.full
  # is what the pair, the seen record and the pending details must be built from.
  home=$(make_home relative-root)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo \
    "$(issue_shape "https://example.com/gitlab/acme/tools/backend-app/-/issues/12" "acme/tools/backend-app#12" 12 fm::todo)" \
    "$(issue_shape "https://example.com/acme/tools/frontend-app/-/issues/3" "" 3 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "acme/tools/backend-app#12(fm::todo)" "the canonical reference did not give the project path"
  assert_not_contains "$report" "gitlab/acme" "the relative URL root leaked into the project path"
  assert_contains "$report" "acme/tools/frontend-app#3(fm::todo)" "the web_url fallback stopped working for an issue with no references"
  run_sub "$home" pending \
    | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#12" and .project == "acme/tools/backend-app")' >/dev/null \
    || fail "the pending record carries a project path that is not the project's path_with_namespace"
  assert_grep 'acme/tools/backend-app#12' "$home/state/.gitlab-issues-seen" "the seen record holds the wrong project path"
  pass "the project path is the API's canonical reference, with web_url as the fallback"
}

test_a_relative_url_root_still_matches_the_projects_filter() {
  local home out report
  home=$(make_home relative-root-projects)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"projects\":[\"backend-app\"]}"
  serve "$home" fm::todo \
    "$(issue_shape "https://example.com/gitlab/acme/tools/backend-app/-/issues/12" "acme/tools/backend-app#12" 12 fm::todo)" \
    "$(issue_shape "https://example.com/gitlab/acme/tools/other-app/-/issues/13" "acme/tools/other-app#13" 13 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "gitlab-issue 1 new: acme/tools/backend-app#12(fm::todo)" "a configured project under a relative URL root was not matched"
  assert_not_contains "$report" "other-app" "an unconfigured project leaked into the report"
  pass "the projects filter matches a configured project on a relative-URL-root install"
}

test_intake_labels_and_host_come_from_the_config() {
  local home out log
  home=$(make_home labels)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"intake_labels\":[\"team::take\"]}"
  serve "$home" team::take "$(issue acme/tools/backend-app 5 team::take)"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 6 fm::todo)"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#5(team::take)" "the configured intake label was not polled"
  log=$(cat "$home/glab.log")
  assert_contains "$log" "--hostname $HOST" "glab was not pointed at the configured host"
  assert_contains "$log" "groups/acme%2Ftools/issues" "the group was not url-encoded into the group issues endpoint"
  assert_contains "$log" "labels=team%3A%3Atake" "the intake label was not url-encoded into the query"
  assert_contains "$log" "state=opened" "closed issues were not excluded"
  assert_contains "$log" "--paginate" "the poll does not paginate"
  assert_not_contains "$log" "fm%3A%3Atodo" "the default labels were polled although the config replaced them"
  [ "$(line_count "$home/glab.log")" = 1 ] || fail "one label must mean one glab call: $log"
  pass "the host and intake labels are read from the config, never from the working directory"
}

test_many_new_pairs_are_bounded_to_one_line() {
  local home out report n
  local -a issues=()
  home=$(make_home many)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  for n in 1 2 3 4 5 6 7 8; do
    issues+=("$(issue acme/tools/backend-app "$n" fm::todo)")
  done
  serve "$home" fm::todo "${issues[@]}"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  [ "$(line_count "$out")" = 1 ] || fail "the report must stay one line: $report"
  assert_contains "$report" "gitlab-issue 8 new:" "the count must cover every new pair"
  assert_contains "$report" "and 3 more" "the pairs past the listed handful were not counted"
  [ "$(printf '%s\n' "$(run_sub "$home" pending)" | wc -l | tr -d ' ')" = 8 ] || fail "every new pair must reach pending even when the line is cut"
  pass "a burst of new issues is reported as one bounded line with the rest counted"
}

# --- pending records -----------------------------------------------------------

test_handled_removes_that_issue_and_refuses_an_unknown_one() {
  local home out status err
  home=$(make_home handled)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)" "$(issue acme/tools/frontend-app 3 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"

  run_sub "$home" handled "acme/tools/backend-app#12" >/dev/null || fail "handled refused a pending issue"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#12") | not' >/dev/null \
    || fail "handled left the issue in pending"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/frontend-app#3")' >/dev/null \
    || fail "handled removed a different issue"

  status=0
  err="$home/err.txt"
  run_sub "$home" handled "acme/tools/backend-app#12" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "handled for an issue no longer pending exit"
  assert_contains "$(cat "$err")" "no pending entry" "an unknown issue was not refused"

  status=0
  run_sub "$home" handled "not-a-reference" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "handled without <path>#<iid> exit"

  # Handling is firstmate's bookkeeping, not GitLab's: the issue is still seen,
  # so the next poll must not report it again.
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a handled issue was reported again: $(cat "$out")"
  pass "handled removes exactly that issue's pending entries and refuses an unknown reference"
}

# The pending record has two writers: the watcher's check appends, firstmate's
# handled rewrites by read-then-rename. Without one lock between them a check
# that lands between handled's read and its rename has its append thrown away
# while its seen record still says the pair was reported, so the issue is never
# offered again. The slow jq below holds handled exactly in that window: it lets
# jq read the record, then waits for the test before handing the lines back.
test_check_append_survives_a_concurrent_handled_rewrite() {
  local home out gate handled_out handled_status check_status handled_pid check_pid i
  home=$(make_home race)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 1 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"

  gate="$home/gate"
  mkdir -p "$gate" "$home/slowjq"
  cat > "$home/slowjq/jq" <<'SH'
#!/usr/bin/env bash
# Slow jq: on the first read of the pending record, read it for real, then hold
# the answer until the test says go. Every other call is the real jq.
if [ ! -e "$SLOW_JQ_GATE/read" ]; then
  for arg in "$@"; do
    if [ "$arg" = "$SLOW_JQ_PENDING" ]; then
      "$SLOW_JQ_REAL" "$@" > "$SLOW_JQ_GATE/answer"
      rc=$?
      : > "$SLOW_JQ_GATE/read"
      while [ ! -e "$SLOW_JQ_GATE/go" ]; do sleep 0.05; done
      cat "$SLOW_JQ_GATE/answer"
      exit "$rc"
    fi
  done
fi
exec "$SLOW_JQ_REAL" "$@"
SH
  chmod 0755 "$home/slowjq/jq"

  handled_out="$home/handled.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$home/slowjq:$home/fakebin:$PATH" \
    SLOW_JQ_GATE="$gate" SLOW_JQ_PENDING="$home/state/.gitlab-issues-pending" SLOW_JQ_REAL="$(command -v jq)" \
    "$CHECK" handled "acme/tools/backend-app#1" >"$handled_out" 2>&1 &
  handled_pid=$!
  i=0
  while [ ! -e "$gate/read" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || fail "handled never read the pending record: $(cat "$handled_out")"
    sleep 0.05
  done

  # handled has read the record and is about to rename over it. A new issue
  # arrives now and the check runs while handled is still in that window.
  serve "$home" fm::todo "$(issue acme/tools/backend-app 1 fm::todo)" "$(issue acme/tools/backend-app 2 fm::todo)"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" \
    "$CHECK" check >"$out" 2>"$out.err" &
  check_pid=$!
  sleep 1
  : > "$gate/go"
  handled_status=0
  wait "$handled_pid" || handled_status=$?
  check_status=0
  wait "$check_pid" || check_status=$?
  expect_code 0 "$handled_status" "handled during a concurrent check exit: $(cat "$handled_out")"
  expect_code 0 "$check_status" "check during a concurrent handled exit: $(cat "$out.err")"

  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#2(fm::todo)" "the check did not report the new issue"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#2")' >/dev/null \
    || fail "the pending record for issue 2 was lost to handled's rewrite: $(run_sub "$home" pending)"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#1") | not' >/dev/null \
    || fail "handled did not remove issue 1: $(run_sub "$home" pending)"
  assert_grep 'acme/tools/backend-app#2' "$home/state/.gitlab-issues-seen" "the seen record does not hold the reported pair"
  assert_absent "$home/state/.gitlab-issues.lock" "the pending lock was left held after both writers finished"

  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the pair reported during the race was reported again: $(cat "$out")"
  pass "a check append during handled's read-then-rewrite is kept, and neither writer loses the other's change"
}

# A paginated answer can list the same issue twice when issues shift between
# page fetches; the report counts the pair once and pending must agree.
test_a_lock_the_check_cannot_take_wakes_firstmate_once() {
  local home gate handled_out handled_pid first second i
  # A wedged writer holds the pending lock across two sweeps. The refusal is a
  # poll error, and the reason emit_error dedupes on must be the same on both
  # sweeps, or a stuck lock wakes firstmate on every FM_CHECK_INTERVAL.
  home=$(make_home lock-error)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 1 fm::todo)"
  serve "$home" fm::human-replied
  first="$home/first.txt"
  second="$home/second.txt"
  run_check "$home" "$first"

  gate="$home/gate"
  mkdir -p "$gate" "$home/slowjq"
  cat > "$home/slowjq/jq" <<'SH'
#!/usr/bin/env bash
# Slow jq: hold the first read of the pending record open, so its caller keeps
# the pending lock until the test says go. Every other call is the real jq.
if [ ! -e "$SLOW_JQ_GATE/read" ]; then
  for arg in "$@"; do
    if [ "$arg" = "$SLOW_JQ_PENDING" ]; then
      "$SLOW_JQ_REAL" "$@" > "$SLOW_JQ_GATE/answer"
      rc=$?
      : > "$SLOW_JQ_GATE/read"
      while [ ! -e "$SLOW_JQ_GATE/go" ]; do sleep 0.05; done
      cat "$SLOW_JQ_GATE/answer"
      exit "$rc"
    fi
  done
fi
exec "$SLOW_JQ_REAL" "$@"
SH
  chmod 0755 "$home/slowjq/jq"

  handled_out="$home/handled.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$home/slowjq:$home/fakebin:$PATH" \
    SLOW_JQ_GATE="$gate" SLOW_JQ_PENDING="$home/state/.gitlab-issues-pending" SLOW_JQ_REAL="$(command -v jq)" \
    "$CHECK" handled "acme/tools/backend-app#1" >"$handled_out" 2>&1 &
  handled_pid=$!
  i=0
  while [ ! -e "$gate/read" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || fail "handled never took the pending lock: $(cat "$handled_out")"
    sleep 0.05
  done

  # A new issue arrives while the lock is wedged. Each sweep spends a different
  # amount of its budget on the glab calls, so a reason built from the time left
  # would differ between the two.
  serve "$home" fm::todo "$(issue acme/tools/backend-app 1 fm::todo)" "$(issue acme/tools/backend-app 2 fm::todo)"
  run_check "$home" "$first" FM_CHECK_TIMEOUT=8
  # The second sweep spends most of its budget on the glab calls, so the time it
  # has left for the lock is not the time the first sweep had.
  printf '2\n' > "$home/gitlab/delay"
  run_check "$home" "$second" FM_CHECK_TIMEOUT=8
  rm -f "$home/gitlab/delay"
  : > "$gate/go"
  wait "$handled_pid" || fail "handled failed while the checks waited on its lock: $(cat "$handled_out")"

  assert_contains "$(cat "$first")" "gitlab-issue poll error:" "a pending lock the sweep could not take was not reported"
  [ ! -s "$second" ] || fail "the same wedged lock was reported twice, so it wakes firstmate on every sweep: $(cat "$second")"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#2") | not' >/dev/null \
    || fail "a sweep that could not take the lock still wrote the pending details"

  # The lock is free again, so the pair the refused sweeps left alone is reported.
  run_check "$home" "$first"
  assert_contains "$(cat "$first")" "gitlab-issue 1 new: acme/tools/backend-app#2(fm::todo)" "the pair the wedged lock deferred was never reported"
  pass "a pending lock the sweep cannot take is one wake, not one per sweep, and defers the pair"
}

test_a_symlink_at_the_pending_record_is_refused_and_reported() {
  local home out target
  # The append is the only write to the pending record that does not arrive by
  # rename, so a symlink there must be refused rather than followed: `pending`
  # and `handled` both refuse it, so a pair marked seen through a symlink would
  # be lost until a human took the label off and put it back.
  home=$(make_home pending-symlink)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 1 fm::todo)"
  serve "$home" fm::human-replied
  target="$home/not-the-pending-record"
  : > "$target"
  ln -s "$target" "$home/state/.gitlab-issues-pending"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue poll error:" "a refused pending record was not reported as a poll error"
  [ ! -s "$target" ] || fail "the append followed the symlink and wrote the issue details to its target"
  assert_absent "$home/state/.gitlab-issues-seen" "the pair was marked seen although its details were never written"

  # With the symlink gone the pair is still news, so the intake is not lost.
  rm -f "$home/state/.gitlab-issues-pending"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#1(fm::todo)" "the refused pair was not reported by the next poll"
  run_sub "$home" pending | jq -e -s 'any(.[]; .issue == "acme/tools/backend-app#1")' >/dev/null \
    || fail "the next poll did not record the pending details"
  pass "a symlink at the pending record is refused, reported, and leaves the pair to the next poll"
}

test_a_duplicated_issue_in_one_answer_yields_one_pending_record() {
  local home out pending
  home=$(make_home dup)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)" "$(issue acme/tools/frontend-app 3 fm::todo)" "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue 2 new:" "the duplicated issue was counted twice"
  pending=$(run_sub "$home" pending)
  [ "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')" = 2 ] || fail "pending must hold one line per reported pair, not per returned object: $pending"
  printf '%s\n' "$pending" | jq -e -s 'map(select(.issue == "acme/tools/backend-app#12")) | length == 1' >/dev/null \
    || fail "the duplicated issue has more than one pending record: $pending"
  pass "an issue returned twice in one answer is one report entry and one pending record"
}

# --- poll errors ---------------------------------------------------------------

test_poll_error_is_reported_once_per_reason_per_hour() {
  local home out
  home=$(make_home error)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1000000
  assert_contains "$(cat "$out")" "backend-app#12(fm::todo)" "the first report is missing"

  printf '401 Unauthorized\n' > "$home/gitlab/fail"
  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1000300
  assert_contains "$(cat "$out")" "gitlab-issue poll error:" "a failing glab was not reported"
  assert_contains "$(cat "$out")" "401 Unauthorized" "the report does not carry glab's reason"
  [ "$(line_count "$out")" = 1 ] || fail "the error must be one line: $(cat "$out")"

  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1000600
  [ ! -s "$out" ] || fail "the same error was reported again within the hour: $(cat "$out")"

  printf '502 Bad Gateway\n' > "$home/gitlab/fail"
  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1000900
  assert_contains "$(cat "$out")" "502 Bad Gateway" "a different reason within the hour is news and was suppressed"

  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1004600
  assert_contains "$(cat "$out")" "502 Bad Gateway" "the same error was not reported again after an hour"

  # A failed poll must not forget what was seen: once GitLab answers again, the
  # issue it already reported is not news.
  rm -f "$home/gitlab/fail"
  run_check "$home" "$out" FM_GITLAB_ISSUES_NOW=1004900
  [ ! -s "$out" ] || fail "a poll failure dropped the seen record and re-reported: $(cat "$out")"
  pass "a poll error wakes firstmate once per reason per hour and never drops the seen record"
}

test_a_hung_glab_is_bounded_and_reported() {
  local home out
  home=$(make_home hang)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"intake_labels\":[\"fm::todo\"]}"
  : > "$home/gitlab/hang"
  out="$home/out.txt"
  run_check "$home" "$out" FM_GITLAB_ISSUES_CALL_SECS=1
  assert_contains "$(cat "$out")" "gitlab-issue poll error:" "a hung glab was not reported"
  assert_contains "$(cat "$out")" "timed out" "the report does not say the call was bounded"
  pass "a hung glab call is cut at its bound and reported instead of blocking the sweep"
}

test_an_error_body_with_exit_zero_is_not_read_as_no_issues() {
  local home out
  home=$(make_home error-body)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\",\"intake_labels\":[\"fm::todo\"]}"
  printf '{"message":"401 Unauthorized"}\n' > "$home/gitlab/fm::todo.ndjson"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "gitlab-issue poll error:" "an error body was read as a normal answer"
  assert_contains "$(cat "$out")" "401 Unauthorized" "the error body's message was not relayed"
  pass "an error body is reported by its message rather than read as an empty result"
}

# --- arm and disarm -----------------------------------------------------------

test_arm_registers_the_check_and_disarm_removes_every_trace() {
  local home out status owner
  home=$(make_home arm)
  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm without a config exit"
  assert_absent "$home/state/gitlab-issues.check.sh" "arm wrote a shim without a config"

  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/gitlab-issues.check.sh" "arm did not write the check shim"
  assert_present "$home/state/gitlab-issues.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/gitlab-issues.check.sh" 2>/dev/null || stat -f %Lp "$home/state/gitlab-issues.check.sh")" = 700 ] \
    || fail "the check shim is not mode 700"
  [ "$(stat -c %h "$home/state/gitlab-issues.check.sh" 2>/dev/null || stat -f %l "$home/state/gitlab-issues.check.sh")" = 1 ] \
    || fail "the check shim is not a single-link file"
  assert_grep 'fm-custom-check-v1' "$home/state/gitlab-issues.check-trust" "the trust binding has the wrong schema"

  # Arming twice must stay valid rather than invalidating its own binding.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/gitlab-issues.check-trust" "re-arming lost the trust binding"

  # The shim is what the watcher runs, from its own directory, with no FM_HOME of
  # its own: it must poll this home.
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  out="$home/out.txt"
  status=0
  (cd / && env -u FM_HOME PATH="$home/fakebin:$PATH" FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" FM_CHECK_TIMEOUT=30 \
    "$home/state/gitlab-issues.check.sh" >"$out" 2>&1) || status=$?
  expect_code 0 "$status" "shim run from another directory exit"
  assert_contains "$(cat "$out")" "backend-app#12(fm::todo)" "the shim did not poll the home it was armed for"

  # A holder killed mid-sweep leaves the lock link and its owner directory behind,
  # and once the check is retired nothing is left to reclaim them.
  owner=$(mktemp -d "$home/state/.gitlab-issues.lock.owner.XXXXXX")
  printf '1\n' > "$owner/pid"
  ln -s "$owner" "$home/state/.gitlab-issues.lock"

  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/gitlab-issues.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/gitlab-issues.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.gitlab-issues-seen" "disarm left the seen record behind"
  assert_absent "$home/state/.gitlab-issues-pending" "disarm left the pending record behind"
  [ ! -L "$home/state/.gitlab-issues.lock" ] && [ ! -e "$home/state/.gitlab-issues.lock" ] \
    || fail "disarm left the pending lock behind"
  assert_absent "$owner" "disarm left the pending lock's owner directory behind"
  pass "arm registers a trusted 0700 shim and disarm removes the shim, its binding, and the records"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target mode status
  home=$(make_home arm-symlink)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  target="$TMP_ROOT/arm-symlink/not-the-shim.txt"
  printf 'a file the shim must not touch\n' > "$target"
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  ln -s "$target" "$home/state/gitlab-issues.check.sh"
  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink exit"
  [ "$(cat "$target")" = 'a file the shim must not touch' ] || fail "arm followed the symlink and overwrote its target"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ] || fail "arm changed the mode of the symlink's target"
  assert_absent "$home/state/gitlab-issues.check-trust" "arm registered a shim it refused to write"
  pass "a symlink at the shim path is refused instead of followed"
}

test_a_failed_re_arm_puts_the_bound_shim_back() {
  local home moved out err status
  # An armed, polling home is re-armed from a second copy of bin/, the shape a
  # re-arm takes after the repo has moved: the shim embeds its own script path, so
  # its bytes differ and are rewritten, and this copy's registration step fails.
  # The home was working, so it must still be working afterwards.
  home=$(make_home arm-rollback)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null || fail "could not arm the issue check"

  moved="$home/bin-moved"
  mkdir -p "$moved"
  ln -s "$ROOT/bin"/*.sh "$moved/"
  rm -f "$moved/fm-check-register.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$moved/fm-check-register.sh"
  chmod 0755 "$moved/fm-check-register.sh"

  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$moved/fm-gitlab-issues.sh" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a re-arm that cannot register must fail"
  assert_present "$home/state/gitlab-issues.check.sh" "a failed re-arm deleted the shim the working home was using"
  assert_present "$home/state/gitlab-issues.check-trust" "a failed re-arm dropped the trust binding"

  # The shim and its binding still agree, so the watcher runs the check instead of
  # rejecting it as an unauthenticated state check.
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" \
    FM_CHECK_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#12(fm::todo)" "the home is no longer polling after a failed re-arm"
  pass "a re-arm that cannot register puts the previously bound shim back"
}

test_armed_check_wakes_the_watcher() {
  local home out err status
  # End to end through the real watcher: the armed check must reach it as a
  # `check:` wake carrying the same report line, with no new machinery.
  home=$(make_home wake)
  write_config "$home" "{\"host\":\"$HOST\",\"group\":\"$GROUP\"}"
  serve "$home" fm::todo "$(issue acme/tools/backend-app 12 fm::todo)"
  serve "$home" fm::human-replied
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" arm >/dev/null || fail "could not arm the issue check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" FAKE_GLAB_DIR="$home/gitlab" FAKE_GLAB_LOG="$home/glab.log" \
    FM_CHECK_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "gitlab-issue 1 new: acme/tools/backend-app#12(fm::todo)" "the wake did not carry the report line"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

test_absent_config_is_silent
test_config_problems_name_the_field
test_first_check_reports_and_records_then_stays_silent
test_removed_label_forgets_the_pair_and_a_re_added_label_is_news
test_projects_filter_keeps_only_configured_projects
test_the_project_path_comes_from_the_canonical_reference
test_a_relative_url_root_still_matches_the_projects_filter
test_intake_labels_and_host_come_from_the_config
test_many_new_pairs_are_bounded_to_one_line
test_handled_removes_that_issue_and_refuses_an_unknown_one
test_check_append_survives_a_concurrent_handled_rewrite
test_a_lock_the_check_cannot_take_wakes_firstmate_once
test_a_symlink_at_the_pending_record_is_refused_and_reported
test_a_duplicated_issue_in_one_answer_yields_one_pending_record
test_poll_error_is_reported_once_per_reason_per_hour
test_a_hung_glab_is_bounded_and_reported
test_an_error_body_with_exit_zero_is_not_read_as_no_issues
test_arm_registers_the_check_and_disarm_removes_every_trace
test_arm_refuses_a_symlink_at_the_shim_path
test_a_failed_re_arm_puts_the_bound_shim_back
test_armed_check_wakes_the_watcher
