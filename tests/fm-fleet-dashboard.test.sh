#!/usr/bin/env bash
# Behavior tests for the fleet cockpit: decisions ranked by importance, our
# PRs in review with gh-derived status, and the reviews domain's PR relationships.
set -u

# The managed sandbox denies the host ps call used by tests/lib.sh to identify
# its owner. Keep that safety check deterministic without weakening production.
TEST_BOOTSTRAP_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-ps.XXXXXX")
cat > "$TEST_BOOTSTRAP_BIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=unknown
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then pid=$argument; fi
  previous=$argument
done
[ "$pid" = 999999 ] && exit 1
printf 'Mon Jan  1 00:00:00 2024 fm-test-process-%s\n' "$pid"
SH
chmod +x "$TEST_BOOTSTRAP_BIN/ps"
export PATH="$TEST_BOOTSTRAP_BIN:$PATH"

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FM_TEST_CLEANUP_DIRS+=("$TEST_BOOTSTRAP_BIN")

# The dashboard derives its state directory from FM_STATE_OVERRIDE ahead of
# FM_HOME (the fleet override contract), so an ambient override from a caller's
# safety wrapper would silently swap the fixture home's state for scratch and
# blank every render. These renders are read-only, so pin the override away.
unset FM_STATE_OVERRIDE

DASHBOARD=${FM_DASHBOARD_UNDER_TEST:-"$ROOT/bin/fm-fleet-dashboard.mjs"}
if [ -n "${FM_DASHBOARD_TEST_TMP_ROOT:-}" ]; then
  TMP_ROOT=$FM_DASHBOARD_TEST_TMP_ROOT
  mkdir -p "$TMP_ROOT"
else
  TMP_ROOT=$(fm_test_tmproot fm-fleet-dashboard)
fi

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TRUNCATION_ARTIFACT="(truncated, 90 chars total - use show decision-task --full to see complete text)"
OUR_PR="https://github.com/monalee/artemis/pull/4001"
FIRSTMATE_PR="https://github.com/pedromuller-del/firstmate/pull/4004"
MERGED_PR="https://github.com/pedromuller-del/firstmate/pull/3972"
THEIR_PR="https://github.com/monalee/artemis/pull/912"
MERGED_THEIR_PR="https://github.com/monalee/artemis/pull/999"

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# No spelling of `sed -i` is portable: BSD sed needs the backup suffix as its
# own argument, while GNU sed reads that empty string as the script and then
# takes the real script as a filename. Filter to a sibling temp file instead.
sed_in_place() {  # <file> <sed-script>...
  local file=$1 tmp
  shift
  tmp=$file.sed-in-place
  sed "$@" "$file" > "$tmp" && mv "$tmp" "$file"
}

file_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_fakebin() {  # <home>
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ ! -f "$FM_HOME/count-local-frames" ] || printf '%s\n' "${1:-}" >> "$FM_HOME/tmux-calls"
if [ -f "$FM_HOME/slow-local-fixture" ] && [ ! -f "$FM_HOME/local-refresh-started" ]; then
  touch "$FM_HOME/local-refresh-started"
  sleep "${FM_TEST_LOCAL_SLEEP_SECONDS:-4}"
  touch "$FM_HOME/local-refresh-finished"
fi
case "${1:-}" in
  list-windows)
    printf '%s\n' fm-decision-task fm-review-task fm-stuck-pr fm-build-task fm-mm-alpha fm-zz-zulu
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'all quiet\n> \n'
    ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -f "$FM_HOME/slow-github-fixture" ] && [ ! -f "$FM_HOME/github-refresh-started" ]; then
  touch "$FM_HOME/github-refresh-started"
  sleep "${FM_TEST_GITHUB_SLEEP_SECONDS:-2}"
  touch "$FM_HOME/github-refresh-finished"
fi
if [ "${1:-}" = "search" ]; then
  if [ -f "$FM_HOME/fetch-priority-fixture" ]; then
    printf '[{"author":{"login":"one"},"number":950,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review one","url":"https://github.com/monalee/artemis/pull/950"},{"author":{"login":"two"},"number":951,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review two","url":"https://github.com/monalee/artemis/pull/951"},{"author":{"login":"three"},"number":952,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review three","url":"https://github.com/monalee/artemis/pull/952"},{"author":{"login":"four"},"number":953,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review four","url":"https://github.com/monalee/artemis/pull/953"},{"author":{"login":"five"},"number":954,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review five","url":"https://github.com/monalee/artemis/pull/954"},{"author":{"login":"six"},"number":955,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review six","url":"https://github.com/monalee/artemis/pull/955"}]'
    exit 0
  fi
  if [ -f "$FM_HOME/review-history-fixture" ]; then
    printf '[{"author":{"login":"colleague"},"createdAt":"2026-07-29T00:00:00Z","number":940,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Re-review the address refresh","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/940"},{"author":{"login":"colleague-two"},"createdAt":"2026-07-30T00:00:00Z","number":941,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review the audit export","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/941"}]'
    exit 0
  fi
  extra_request=''
  [ -f "$FM_HOME/new-review-request-fixture" ] \
    && extra_request=',{"author":{"login":"colleague-three"},"createdAt":"2026-08-02T00:01:00Z","number":942,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"New review request","updatedAt":"2026-08-02T00:01:00Z","url":"https://github.com/monalee/artemis/pull/942"}'
  printf '[{"author":{"login":"colleague"},"createdAt":"2026-07-20T00:00:00Z","number":930,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Tile cache manual validation required and outstanding","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/930"},{"author":{"login":"colleague-two"},"createdAt":"2026-07-31T00:00:00Z","number":912,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Payment refactor","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/912"}%s]' "$extra_request"
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case " $* " in
    *" graphql "*)
      if [ -f "$FM_HOME/no-thread-fixture" ] && [[ " $* " = *" number=4001 "* ]]; then
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      elif [ -f "$FM_HOME/external-thread-resolved-fixture" ] && [[ " $* " = *" number=4001 "* ]]; then
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread-1","isResolved":true,"resolvedBy":{"login":"reviewer-one"},"comments":{"nodes":[{"author":{"login":"reviewer-one"},"createdAt":"2026-08-01T01:30:00Z"}]}}]}}}}}'
      elif [ -f "$FM_HOME/own-thread-resolution-fixture" ] && [[ " $* " = *" number=4001 "* ]]; then
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread-1","isResolved":true,"resolvedBy":{"login":"pedromuller-del"},"comments":{"nodes":[{"author":{"login":"reviewer-one"},"createdAt":"2026-08-01T01:30:00Z"}]}}]}}}}}'
      elif [[ " $* " = *" number=4001 "* ]]; then
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread-1","isResolved":false,"resolvedBy":null,"comments":{"nodes":[{"author":{"login":"reviewer-one"},"createdAt":"2026-08-01T01:30:00Z"}]}}]}}}}}'
      else
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      fi
      ;;
    *" user "*)
      if [ -f "$FM_HOME/review-request-outage-fixture" ]; then
        printf 'temporary GitHub outage\n' >&2
        exit 1
      fi
      printf 'pedromuller-del\n'
      ;;
    *" repos/monalee/artemis/issues/930/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-20T00:00:00Z","requested_team":{"name":"webdev","slug":"webdev"}}]'
      ;;
    *" repos/monalee/artemis/issues/912/timeline "*)
      if [ -f "$FM_HOME/review-request-date-unknown-fixture" ]; then
        printf '[]'
      else
        printf '[{"event":"review_requested","created_at":"2026-07-31T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      fi
      ;;
    *" repos/monalee/artemis/issues/940/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-29T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/issues/941/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-30T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/issues/942/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-08-02T00:01:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/pulls/930/requested_reviewers "*)
      printf '{"users":[],"teams":[{"name":"webdev","slug":"webdev"}]}'
      ;;
    *" repos/monalee/artemis/pulls/912/requested_reviewers "*)
      printf '{"users":[{"login":"pedromuller-del"}],"teams":[]}'
      ;;
    *" repos/monalee/artemis/pulls/940/requested_reviewers "*|*" repos/monalee/artemis/pulls/941/requested_reviewers "*)
      printf '{"users":[{"login":"pedromuller-del"}],"teams":[]}'
      ;;
    *" repos/monalee/artemis/pulls/942/requested_reviewers "*)
      printf '{"users":[{"login":"pedromuller-del"}],"teams":[]}'
      ;;
    *)
      printf '[]'
      ;;
  esac
  exit 0
fi
url=${3:-}
case "$url" in
  *pull/4001*)
    pr_state=OPEN
    mergeable=MERGEABLE
    review_decision=CHANGES_REQUESTED
    if [ -f "$FM_HOME/merged-ours-fixture" ]; then
      pr_state=MERGED
      mergeable=UNKNOWN
      review_decision=APPROVED
    fi
    check='{"status":"COMPLETED","conclusion":"SUCCESS"}'
    [ -f "$FM_HOME/ci-red-fixture" ] && check='{"status":"COMPLETED","conclusion":"FAILURE"}'
    [ -f "$FM_HOME/ci-running-fixture" ] && check='{"status":"IN_PROGRESS","conclusion":null}'
    own_review=''
    [ -f "$FM_HOME/own-review-fixture" ] \
      && own_review=',{"author":{"login":"pedromuller-del"},"state":"APPROVED","submittedAt":"2026-08-01T04:00:00Z"}'
    latest_verdict=APPROVED
    [ -f "$FM_HOME/unattributable-dismissal-fixture" ] && latest_verdict=DISMISSED
    external_review=''
    [ -f "$FM_HOME/external-review-fixture" ] \
      && external_review=',{"author":{"login":"reviewer-three"},"state":"APPROVED","submittedAt":"2026-08-01T05:00:00Z"}'
    printf '{"state":"%s","isDraft":false,"mergeable":"%s","reviewDecision":"%s","statusCheckRollup":[%s],"reviews":[{"author":{"login":"reviewer-one"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-01T01:00:00Z"},{"author":{"login":"reviewer-two"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-01T02:00:00Z"},{"author":{"login":"reviewer-one"},"state":"%s","submittedAt":"2026-08-01T03:00:00Z"}%s%s],"reviewRequests":[]}' "$pr_state" "$mergeable" "$review_decision" "$check" "$latest_verdict" "$own_review" "$external_review"
    ;;
  *pull/4004*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"reviewRequests":[{"login":"local-reviewer"}]}'
    ;;
  *pull/930*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"d4d4d4d"}'
    ;;
  *pull/4188*)
    if [ -f "$FM_HOME/merged-review-fixture" ]; then
      printf '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"APPROVED","statusCheckRollup":[],"reviews":[],"reviewRequests":[],"headRefOid":"b2b2b2b"}'
    else
      printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[],"headRefOid":"b2b2b2b"}'
    fi
    ;;
  *pull/912*)
    if [ -f "$FM_HOME/merged-review-fixture" ]; then
      printf '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"APPROVED","statusCheckRollup":[],"reviews":[],"reviewRequests":[],"headRefOid":"b2b2b2b"}'
    else
      printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[],"headRefOid":"b2b2b2b"}'
    fi
    ;;
  *pull/940*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[{"author":{"login":"pedromuller-del"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-28T00:00:00Z","commit":{"oid":"aaa111"}}],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"bbb222"}'
    ;;
  *pull/941*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"ccc333"}'
    ;;
  *pull/95[0-5]*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[]}'
    ;;
  *pull/942*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[{"login":"pedromuller-del"}]}'
    ;;
  *pull/40[1][0-6]*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"reviewRequests":[]}'
    ;;
  *pull/888*|*pull/999*)
    printf '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"APPROVED","statusCheckRollup":[],"reviews":[],"reviewRequests":[]}'
    ;;
  *)
    echo "no such pull request" >&2
    exit 1
    ;;
esac
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"generatedAt":"2026-08-02T00:05:01Z","providers":[{"provider":"codex","label":"Codex","windows":[{"id":"weekly","label":"week","percentRemaining":73,"resetsAt":"2026-08-09T00:00:00Z"}],"state":{"status":"fresh"}}]}'
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Environment stand-in for the host tasks-axi binary. It lists in-flight rows
# from the caller-supplied backlog file and does not decide strandedness.
set -u
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.5'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    printf 'fm-fleet-dashboard test fixture: unsupported tasks-axi %s\n' "$*" >&2
    exit 1
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    printf 'fm-fleet-dashboard test fixture: unsupported tasks-axi %s\n' "$*" >&2
    exit 1
    ;;
  list) ;;
  *)
    printf 'fm-fleet-dashboard test fixture: unsupported tasks-axi %s\n' "$*" >&2
    exit 1
    ;;
esac
file=
state=
previous=
for argument in "$@"; do
  if [ "$previous" = "--file" ]; then
    file=$argument
  fi
  if [ "$previous" = "--state" ]; then
    state=$argument
  fi
  case "$argument" in
    --file=*) file=${argument#--file=} ;;
    --state=*) state=${argument#--state=} ;;
  esac
  previous=$argument
done
if [ -z "$file" ] || [ "$state" != in_flight ]; then
  printf 'fm-fleet-dashboard test fixture: expected list --file <backlog> --state in_flight\n' >&2
  exit 1
fi
[ -f "$file" ] || { printf 'count: 0\n'; exit 0; }
rows=$(LC_ALL=C awk '
  function section_state(line, heading) {
    heading = line
    sub(/^##[[:space:]]+/, "", heading)
    sub(/[[:space:]]+$/, "", heading)
    if (heading == "In flight") return "in_flight"
    return ""
  }
  /^##[[:space:]]+/ {
    state = section_state($0)
    next
  }
  state == "in_flight" && $0 ~ /^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+/ {
    row = $0
    sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", row)
    id = row
    sub(/[[:space:]].*$/, "", id)
    held = "no"
    if ($0 ~ /\(hold-kind:[[:space:]]*[^)]*\)/ || $0 ~ /\(hold:[[:space:]]*[^)]*\)/) held = "yes"
    blocked = "none"
    if ($0 ~ /blocked-by:[[:space:]]*"/) {
      blocked = $0
      sub(/^.*blocked-by:[[:space:]]*"/, "", blocked)
      sub(/".*$/, "", blocked)
    } else if ($0 ~ /blocked-by:[[:space:]]*[^[:space:]]+/) {
      blocked = $0
      sub(/^.*blocked-by:[[:space:]]*/, "", blocked)
      sub(/[[:space:]].*$/, "", blocked)
    }
    if (blocked ~ /,/) blocked = "\"" blocked "\""
    printf "%s,in_flight,ship,firstmate,work,%s,%s\n", id, blocked, held
  }
' "$file")
count=$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')
printf 'count: %s\n' "$count"
printf 'tasks[%s]{id,state,kind,repo,title,blocked_by,held}:\n' "$count"
if [ -n "$rows" ]; then
  printf '%s\n' "$rows" | awk 'NF { printf "  %s\n", $0 }'
fi
# Real tasks-axi 0.2.5 always closes a listing with this two-space-indented
# help block, so the fixture reproduces it too.
printf 'help[1]:\n'
printf '  - Run `tasks-axi show <id> --file=%s` for full notes on a task\n' "$file"
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux" "$fakebin/gh" "$fakebin/quota-axi" "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

make_reviews_home() {  # <name>
  local reviews_home=$TMP_ROOT/$1
  mkdir -p "$reviews_home/data" "$reviews_home/state" "$reviews_home/config" "$reviews_home/projects"
  mkdir -p "$reviews_home/projects/artemis"
  git -C "$reviews_home/projects/artemis" init -q
  git -C "$reviews_home/projects/artemis" remote add origin https://github.com/monalee/artemis.git
  cat > "$reviews_home/data/backlog.md" <<EOF
## In flight
- [ ] review-pr-912-b2b2b2b - Review the payment refactor round 2 $THEIR_PR (repo: artemis) (kind: ship) (since 2026-07-31) (hold: waiting on their fixes) (hold-kind: external)
- [ ] review-pr-930-c3c3c3c - Review the tile cache https://github.com/monalee/artemis/pull/930 (repo: artemis) (kind: ship) (since 2026-08-01)

## Queued

## Done
- [x] review-pr-912-a1a1a1a - Review the payment refactor first pass $THEIR_PR (repo: artemis) (kind: scout) (reported 2026-07-30)
- [x] review-pr-4188-1a1a1a1 - Review PR 4188 first pass (repo: unknown-project) (kind: scout) (reported 2026-08-01)
- [x] review-pr-4188-2b2b2b2 - Review PR 4188 second pass (repo: unknown-project) (kind: scout) (reported 2026-08-02)
- [x] review-pr-888-e8e8e8e - Review merged PR 888 without a recorded link (repo: artemis) (kind: scout) (reported 2026-08-02)
- [x] review-pr-999-d4d4d4d - Review merged PR 999 $MERGED_THEIR_PR (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  printf '%s\n' "$reviews_home"
}

write_live_fixture() {  # <home>
  local home=$1 reviews_home generation review_generation stuck_generation
  mkdir -p "$home/projects/decision" "$home/projects/review" "$home/projects/merged"
  reviews_home=$(make_reviews_home "reviews-home-$(basename "$home")")
  cat > "$home/data/secondmates.md" <<EOF
- reviews - Runs colleague PR review rounds (home: $reviews_home; scope: colleague PR review rounds; projects: ; added 2026-08-01)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] decision-task - Decide the public API (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] review-task - Ship the review branch (repo: artemis) (kind: ship) (since 2026-08-01)
- [ ] local-ci-pr - PR 4004: Ship the Firstmate local CI branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] unregistered-pr - PR 4002: Ship the unregistered review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] stuck-pr - PR 4003: Ship the stuck review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] deploy-window - Approve deployment window (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the deployment window.) (hold-kind: captain)
- [ ] hold-oldest - Renew the signing certificate (repo: firstmate) (kind: captain) (since 2026-07-20) (hold: The certificate expires soon.) (hold-kind: captain)
- [ ] hold-answered - Pick the flake-fix destination (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: CAPTAIN DECIDED 2026-08-02: use a separate test-hardening PR.) (hold-kind: captain)
- [ ] hold-undecided - Decide whether to rotate the credential (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: This is not yet decided and still needs Pedro.) (hold-kind: captain)

## Queued
- [ ] launch-page - Ship the launch page blocked-by: deploy-window (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] queued-pr-note - PR 3999: Prepare a follow-up after another PR lands (repo: firstmate) (kind: ship) (since 2026-08-02)

## Done
- [x] merged-task - Ship the merged thing (repo: firstmate) (kind: ship) (merged 2026-07-31)
EOF

  fm_write_meta "$home/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" \
    "worktree=$home/projects/decision" \
    "project=$home/projects/firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'needs-decision [key=api-shape]: Choose the public API shape. %s\n' \
    "$TRUNCATION_ARTIFACT" > "$home/state/decision-task.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" decision-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" decision-task idle \
    --gen "$generation" --source claude-hook --event stop

  fm_write_meta "$home/state/review-task.meta" \
    "window=firstmate:fm-review-task" \
    "worktree=$home/projects/review" \
    "project=artemis" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$OUR_PR"
  printf 'done: PR %s checks green\n' "$OUR_PR" > "$home/state/review-task.status"
  review_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" review-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" review-task idle \
    --gen "$review_generation" --source claude-hook --event stop

  fm_write_meta "$home/state/local-ci-pr.meta" \
    "window=firstmate:fm-local-ci-pr" \
    "worktree=$home/projects/local-ci" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$FIRSTMATE_PR"
  mkdir -p "$home/projects/local-ci"
  printf 'done: local suite evidence was not recorded\n' > "$home/state/local-ci-pr.status"

  fm_write_meta "$home/state/merged-task.meta" \
    "window=firstmate:fm-merged-task" \
    "worktree=$home/projects/merged" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$MERGED_PR"
  printf 'done: PR %s checks green\n' "$MERGED_PR" > "$home/state/merged-task.status"

  fm_write_meta "$home/state/unregistered-pr.meta" \
    "window=firstmate:fm-unregistered-pr" \
    "worktree=$home/projects/unregistered" \
    "project=wrong-project" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  mkdir -p "$home/projects/unregistered"
  printf 'paused: PR 4002 is ready for review but was never registered\n' \
    > "$home/state/unregistered-pr.status"

  fm_write_meta "$home/state/stuck-pr.meta" \
    "window=firstmate:fm-stuck-pr" \
    "worktree=$home/projects/stuck" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  mkdir -p "$home/projects/stuck"
  printf 'blocked [key=stuck-pr]: Worker stopped before PR registration.\n' > "$home/state/stuck-pr.status"
  stuck_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stuck-pr)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stuck-pr idle \
    --gen "$stuck_generation" --source claude-hook --event stop

  # Pin status mtimes so age-in-state is deterministic against FM_SNAPSHOT_NOW.
  TZ=UTC touch -t 202608020000 "$home/state/decision-task.status" \
    "$home/state/review-task.status" "$home/state/merged-task.status"
}

render_terminal() {  # <home> <fakebin> [extra args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" "$@"
}

render_terminal_at() {  # <home> <fakebin> <snapshot-now> [extra args...]
  local home=$1 fakebin=$2 snapshot_now=$3
  shift 3
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW="$snapshot_now" \
    "$DASHBOARD" "$@"
}

line_number_of() {  # <haystack> <needle>
  printf '%s\n' "$1" | grep -n -F "$2" | head -1 | cut -d: -f1
}

test_cockpit_shows_action_sections_and_full_inventory() {
  local home fakebin out decisions ours obligations theirs decide hold_blocking hold_oldest total_lines pr_num pr_shown review_num review_shown
  home=$(make_home three)
  write_live_fixture "$home"
  awk -v repo="(repo: $home/projects/firstmate)" \
    'NR == 2 { sub(/\(repo: firstmate\)/, repo) } { print }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100 --all) || fail "terminal render failed"

  decisions=$(line_number_of "$out" "DECISIONS (6)")
  ours=$(line_number_of "$out" "OUR PRS IN REVIEW (4)")
  obligations=$(line_number_of "$out" "REVIEWS WAITING ON PEDRO (2)")
  theirs=$(line_number_of "$out" "REVIEWING (3)")
  [ -n "$decisions" ] || fail "no DECISIONS section counting all three items"
  [ -n "$ours" ] || fail "no OUR PRS IN REVIEW section"
  [ -n "$obligations" ] || fail "no requested-review obligation section"
  [ -n "$theirs" ] || fail "no REVIEWING section"
  { [ "$decisions" -lt "$ours" ] && [ "$ours" -lt "$obligations" ] && [ "$obligations" -lt "$theirs" ]; } \
    || fail "sections are not ordered decisions, ours, obligations, reviewing"
  assert_not_contains "$out" "UNDERWAY (" "a retired section is still rendered"
  assert_not_contains "$out" "UNHEALTHY (" "a retired section is still rendered"
  assert_not_contains "$out" "QUEUED (" "a retired section is still rendered"
  assert_not_contains "$out" "UNREADABLE (" "a retired section is still rendered"

  decide=$(line_number_of "$out" "◆ Decide the public API")
  hold_blocking=$(line_number_of "$out" "◆ Approve deployment window")
  hold_oldest=$(line_number_of "$out" "◆ Renew the signing certificate")
  [ -n "$decide" ] && [ -n "$hold_blocking" ] && [ -n "$hold_oldest" ] \
    || fail "a decision item is missing from the section"
  { [ "$decide" -lt "$hold_blocking" ] && [ "$hold_blocking" -lt "$hold_oldest" ]; } \
    || fail "importance order is broken: live ask, then delivery-blocking hold, then oldest"
  assert_contains "$out" " 1 d:decision-task-api~" \
    "rows do not colocate their position, stable id, marker, and title"

  assert_contains "$out" "PR 4002" "a current ship task in the PR stage was silently dropped"
  assert_contains "$out" "PR 4002 | local checks unknown | unregistered" \
    "an unregistered PR row implied established checks or readiness"
  assert_contains "$out" "project artemis" "mixed-project full inventory lacks an Artemis separator"
  assert_contains "$out" "project firstmate" "mixed-project full inventory lacks an internal-project separator"
  assert_not_contains "$out" "$home/projects/firstmate" \
    "an absolute project path leaked into the shareable cockpit"
  assert_contains "$out" "github status checked just now" "github data age is not printed"
  assert_not_contains "$out" "pull/3972" "a landed PR still renders as in review"

  pr_num=$(printf '%s\n' "$out" | grep -F "PR 4001 |" | tail -1 | awk '{print $1}')
  pr_shown=$(render_terminal "$home" "$fakebin" --show "$pr_num") || fail "our PR expansion failed"
  assert_contains "$pr_shown" "checks green" "green checks are missing from expanded status"
  assert_contains "$pr_shown" "changes requested by reviewer-two" \
    "review readiness is missing from expanded status"
  assert_contains "$pr_shown" "$OUR_PR" "expanded PR row lost its full link"

  assert_contains "$out" "PR 912" "review rounds were not grouped by PR"
  assert_contains "$out" "PR 4188" "completed review rounds were silently dropped"
  review_num=$(printf '%s\n' "$out" | grep -F "PR 912" | tail -1 | awk '{print $1}')
  review_shown=$(render_terminal "$home" "$fakebin" --show "$review_num") || fail "review expansion failed"
  assert_contains "$review_shown" "review x2" "expanded review lost its real round count"
  assert_contains "$review_shown" "waiting on their fixes" "expanded review lost its recorded status"
  assert_contains "$review_shown" "$THEIR_PR" "expanded review lost its full link"

  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "fresh recap did not report only next-hour attention"
  assert_contains "$out" "? Pick the flake-fix destination" \
    "an answered-looking open hold was not marked uncertain"

  assert_not_contains "$out" "token spend not measured" "measurement inventory leaked onto the list surface"
  assert_not_contains "$out" "truncated, 90 chars" "CLI truncation artifact leaked into the cockpit"

  total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$total_lines" -le 45 ] || fail "full inventory does not fit a 45-row terminal: $total_lines lines"
  pass "cockpit renders action sections and a reachable full inventory"
}

test_pr_truthfulness_regressions() {
  local home fakebin out registered_num registered_shown unknown_num unknown_shown local_ci_num local_ci_shown
  home=$(make_home pr-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "truthfulness render failed"
  assert_contains "$out" "OUR PRS IN REVIEW (4)" "the PR review section contains a false or missing row"
  assert_not_contains "$out" "PR 3999" \
    "a queued backlog record that merely names a PR was misreported as our PR in review"
  assert_not_contains "$out" "github.com/pedromuller-del/firstmate/pull/4002" \
    "the cockpit fabricated a URL for an unregistered PR"
  registered_num=$(printf '%s\n' "$out" | grep -F "PR 4001 |" | tail -1 | awk '{print $1}')
  registered_shown=$(render_terminal "$home" "$fakebin" --show "$registered_num") \
    || fail "registered PR expansion failed"
  assert_contains "$registered_shown" "checks green · changes requested by reviewer-two" \
    "CI and review readiness are not independent dimensions"
  assert_contains "$registered_shown" "review: reviews recorded: reviewer-two (changes requested), reviewer-one (approved)" \
    "expanded PR does not say who reviewed it"
  assert_contains "$out" "PR 4001 | checks green | changes requested by reviewer-two" \
    "our PR line omits established check and review status"
  assert_not_contains "$out" "changes requested by reviewer-one" \
    "a superseded changes-requested review still names its author"
  assert_contains "$out" "PR 4004 | local checks unknown | waiting on local-reviewer" \
    "Firstmate PR line treated GitHub checks as local CI evidence"
  assert_contains "$out" "○ PR 4004 | local checks unknown | waiting on local-reviewer" \
    "structured waiting-review state became unknown after presentation rewriting"
  assert_not_contains "$out" "PR 4004 | checks red" \
    "Firstmate PR line reported a GitHub check as a signal"
  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unregistered PR expansion failed"
  assert_contains "$unknown_shown" "local checks unknown · readiness unknown (unregistered)" \
    "missing registration was rendered as a false CI state"
  assert_contains "$unknown_shown" "was never registered" "missing registration has no visible reason"
  local_ci_num=$(printf '%s\n' "$out" | grep -F "PR 4004 |" | tail -1 | awk '{print $1}')
  local_ci_shown=$(render_terminal "$home" "$fakebin" --show "$local_ci_num") \
    || fail "registered Firstmate PR expansion failed"
  assert_contains "$local_ci_shown" "exact local-suite evidence" \
    "registered Firstmate PR recommendation dead-ends on another GitHub check"
  pass "PR rows preserve unknown registration and independent CI/readiness truth"
}

test_review_relationships_survive_completed_rounds() {
  local home fakebin out pr912_num pr912_shown pr4188_num pr4188_shown
  home=$(make_home review-relationships)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "review relationship render failed"
  assert_contains "$out" "REVIEWING (3)" "completed rounds disappeared from review relationships"
  assert_contains "$out" "PR 912" "two rounds for one PR were not grouped"
  assert_contains "$out" "PR 4188" "a completed current relationship was dropped"
  assert_not_contains "$out" "PR 999" "terminal GitHub evidence did not retire a merged review relationship"
  assert_not_contains "$out" "PR 888" \
    "a merged review relationship survived despite a verified project remote and fresh GitHub state"
  pr912_num=$(printf '%s\n' "$out" | grep -F "PR 912" | tail -1 | awk '{print $1}')
  pr912_shown=$(render_terminal "$home" "$fakebin" --show "$pr912_num") || fail "PR 912 expansion failed"
  assert_contains "$pr912_shown" "review x2" "distinct recorded review heads did not produce round two"
  pr4188_num=$(printf '%s\n' "$out" | grep -F "PR 4188" | tail -1 | awk '{print $1}')
  pr4188_shown=$(render_terminal "$home" "$fakebin" --show "$pr4188_num") || fail "PR 4188 expansion failed"
  assert_contains "$pr4188_shown" "waiting on author after review x2" \
    "a completed round was mistaken for a completed PR relationship"
  assert_contains "$out" "PR 912 | waiting on their fixes | review x2" \
    "reviewing line omits the recorded round state"
  pass "reviewing is grouped by PR and retains completed rounds until terminal evidence"
}

test_followup_review_without_round_history_stays_unknown() {
  local home reviews_home fakebin out num shown
  home=$(make_home unknown-review-round)
  write_live_fixture "$home"
  reviews_home="$TMP_ROOT/reviews-home-$(basename "$home")"
  cat >> "$reviews_home/data/backlog.md" <<'EOF'
- [x] review-pr-777-final-a7a7a7a - PR 777 final anchored recheck (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "unknown review-round render failed"
  assert_contains "$out" "PR 777" "a follow-up review with incomplete history was dropped"
  num=$(printf '%s\n' "$out" | grep -F "PR 777" | tail -1 | awk '{print $1}')
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "unknown round expansion failed"
  assert_contains "$shown" "review round unknown (1 head recorded)" \
    "a follow-up review with incomplete history fabricated round one"
  pass "incomplete follow-up history renders an unknown round instead of a false ordinal"
}

test_numberless_review_record_never_invents_a_waiting_party() {
  local home reviews_home fakebin out
  home=$(make_home numberless-review)
  write_live_fixture "$home"
  reviews_home="$TMP_ROOT/reviews-home-$(basename "$home")"
  cat >> "$reviews_home/data/backlog.md" <<'EOF'
- [x] refresh-review-checklist - Refresh the review checklist (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "numberless review render failed"
  assert_contains "$out" "? PR unknown: Refresh the review checklist" \
    "numberless review record lost its identity"
  assert_not_contains "$out" "PR unknown: Refresh the review checklist | waiting on author" \
    "numberless review record invented a waiting party"
  pass "numberless review records state only their known workflow and PR identity"
}

test_decision_projection_labels_answered_and_aged_open_holds() {
  local home fakebin out answered_num answered_shown aged_num aged_shown
  home=$(make_home decision-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "decision truth render failed"
  assert_contains "$out" "DECISIONS (6)" "an open hold or blocker was silently removed"
  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "decision recap included deferred holds"
  assert_contains "$out" "? Pick the flake-fix destination" \
    "explicit answer text was reported as needing a new answer"
  answered_num=$(printf '%s\n' "$out" | grep -F "Pick the flake-fix destination" | tail -1 | awk '{print $1}')
  answered_shown=$(render_terminal "$home" "$fakebin" --show "$answered_num") \
    || fail "answered-looking hold expansion failed"
  assert_contains "$answered_shown" "looks answered; hold still open" \
    "the conservative answer hint is not labelled"
  aged_num=$(printf '%s\n' "$out" | grep -F "Renew the signing certificate" | tail -1 | awk '{print $1}')
  aged_shown=$(render_terminal "$home" "$fakebin" --show "$aged_num") || fail "aged hold expansion failed"
  assert_contains "$aged_shown" "aged hold; still open" "the old open hold lost its lifecycle caveat"
  assert_contains "$out" "◆ Decide whether to rotate the credential" \
    "ordinary not-yet-decided prose was mistaken for an answer declaration"
  pass "decision projection keeps every hold while separating actionable, answered-looking, and aged rows"
}

test_clean_list_uses_truthful_markers_and_priority_order() {
  local home fakebin out colored escape yellow red blue green unknown yellow_line red_line unknown_line blue_line green_line
  home=$(make_home interaction-markers)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130 --all) \
    || fail "marker render failed"
  yellow='◆'
  red='×'
  blue='○'
  green='●'
  unknown='?'
  assert_contains "$out" "$yellow Decide the public API" "needs-Pedro marker is absent without color"
  assert_contains "$out" "$red PR 4003: Ship the stuck review branch" "stuck marker is absent without color"
  assert_contains "$out" "$blue PR 912" "waiting-elsewhere marker is absent without color"
  assert_contains "$out" "$green PR 930" "progressing marker is absent without color"
  assert_contains "$out" "$unknown PR 4002" "unknown marker is absent without color"
  assert_contains "$out" "◆ needs Pedro | × stuck | ○ waiting elsewhere | ● progressing | ? unknown" \
    "the color-free legend does not distinguish every marker"

  yellow_line=$(line_number_of "$out" "$yellow Decide the public API")
  unknown_line=$(line_number_of "$out" "$unknown Pick the flake-fix destination")
  [ "$yellow_line" -lt "$unknown_line" ] || fail "unknown sorted ahead of needs-Pedro"
  red_line=$(line_number_of "$out" "$red PR 4003: Ship the stuck review branch")
  unknown_line=$(line_number_of "$out" "$unknown PR 4002")
  [ "$red_line" -lt "$unknown_line" ] || fail "unknown sorted ahead of stuck"
  assert_contains "$out" "$unknown PR 4001 | checks green | changes requested by reviewer-two" \
    "changes requested without fresh local stuck evidence was overreported as red"
  blue_line=$(line_number_of "$out" "$blue PR 912")
  green_line=$(line_number_of "$out" "$green PR 930")
  [ "$blue_line" -lt "$green_line" ] || fail "progressing sorted ahead of waiting-elsewhere"
  colored=$(NO_COLOR='' FORCE_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "colored marker render failed"
  escape=$(printf '\033')
  assert_contains "$colored" "${escape}[33m◆${escape}[0m ${escape}[2mRenew the signing certificate" \
    "aged decision title is not dimmed while preserving its yellow marker"
  pass "clean list markers survive NO_COLOR and follow attention priority"
}

test_default_rows_are_one_line_with_a_fresh_recap() {
  local home fakebin out title_line total_lines
  home=$(make_home interaction-list)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130) \
    || fail "clean-list render failed"
  assert_contains "$out" "ATTENTION NOW" "fresh recap band is absent"
  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "recap included deferred holds or omitted a review obligation"
  assert_not_contains "$out" "+4 more below" "recap repeats rows instead of staying a one-line summary"
  title_line=$(printf '%s\n' "$out" | grep -F "PR 4003 |" | tail -1)
  assert_not_contains "$title_line" "firstmate" "default row includes project detail"
  assert_not_contains "$title_line" "for " "default row includes age detail"
  assert_contains "$out" "PR 4003 | local checks unknown | unregistered" \
    "actionable PR row omits established status"
  assert_not_contains "$out" "PR 4001 |" "non-actionable PR detail stayed on the one-glance screen"
  assert_not_contains "$out" "PR 4004 |" "waiting PR detail stayed on the one-glance screen"
  assert_not_contains "$out" "PR 4002 |" "unknown PR detail stayed on the one-glance screen"
  assert_contains "$out" "3 deferred PRs" "collapsed PR status has no counted --all affordance"
  assert_not_contains "$out" "$OUR_PR" "default list leaked a PR link"
  assert_contains "$out" "github status checked just now" "cached forge facts lost their explicit age"
  total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  printf 'default_80_rows=%s\n' "$total_lines"
  [ "$total_lines" -le 23 ] || fail "default cockpit exceeds one glance: $total_lines rows"
  [ "${#title_line}" -le 80 ] || fail "fixed terminal measure exceeded 80 columns"
  pass "default view is a bounded one-glance list with a fresh local recap"
}

test_expansion_includes_evidence_derived_recommendation() {
  local home fakebin out num shown unknown_num unknown_shown
  home=$(make_home interaction-expansion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "expansion list render failed"
  num=$(printf '%s\n' "$out" | grep -F "Decide the public API" | tail -1 | awk '{print $1}')
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "decision expansion failed"
  assert_contains "$shown" "row id: d:decision-task-api~" \
    "expanded row omitted its stable quotable id"
  assert_contains "$shown" "current state:" "expanded row omitted current state"
  assert_contains "$shown" "age:" "expanded row omitted age"
  assert_contains "$shown" "blockers:" "expanded row omitted concrete blocker or status"
  assert_contains "$shown" "context and recommendation: Answer the recorded decision" \
    "expanded decision omitted its evidence-derived recommendation"

  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unknown PR expansion failed"
  assert_contains "$unknown_shown" "context and recommendation: Register PR 4002" \
    "unknown PR expansion invented a recommendation instead of naming missing registration"
  pass "expanded rows carry full context and evidence-derived recommendations"
}

test_show_expands_rows_with_full_context() {
  local home fakebin out all before num shown row_id id_shown pr_num pr_shown error rc
  home=$(make_home show)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100) || fail "terminal render failed"
  num=$(printf '%s\n' "$out" | grep -F "Decide the public API" | tail -1 | awk '{print $1}')
  [ -n "$num" ] || fail "could not read the decision row's number"
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "--show $num failed"
  assert_contains "$shown" "DECISIONS | ◆ needs Pedro" "expanded row does not name its section and marker"
  assert_contains "$shown" "Choose the public API shape." "expanded row lost its full reason"
  assert_contains "$shown" "why here: open needs-decision in the keyed decision fold" \
    "expanded row does not explain its routing"
  assert_contains "$shown" "recent events" "expanded row does not show its status events"

  row_id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  id_shown=$(render_terminal "$home" "$fakebin" --show "$row_id") \
    || fail "stable row id did not resolve"
  assert_contains "$id_shown" "row id: $row_id" \
    "expanded row does not preserve its quotable id"

  before=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-26T00:00:00Z \
    "$DASHBOARD" --width 80 --all) || fail "pre-aging render failed"
  assert_contains "$before" "d:hold-oldest ◆ Renew the signing certificate" \
    "hold id before aging is missing"
  all=$(render_terminal "$home" "$fakebin" --width 80 --all) || fail "full render failed"
  assert_contains "$all" "d:hold-oldest ◆ Renew the signing certificate" \
    "hold id changed when its attention class aged"

  pr_num=$(printf '%s\n' "$all" | grep -F "PR 4001 |" | head -1 | awk '{print $1}')
  [ -n "$pr_num" ] || fail "could not read our PR row's number"
  pr_shown=$(render_terminal "$home" "$fakebin" --show "$pr_num") || fail "--show $pr_num failed"
  assert_contains "$pr_shown" "$OUR_PR" "expanded PR row lost its link"
  assert_contains "$pr_shown" "why here: our PR recorded in task metadata" \
    "expanded PR row does not explain its routing"

  set +e
  error=$(render_terminal "$home" "$fakebin" --show 99 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--show accepted an out-of-range row"
  assert_contains "$error" "no such row" "out-of-range --show refusal is not actionable"
  pass "numbered rows expand to full context and bad numbers refuse loudly"
}

test_absent_sources_and_unreachable_reviews_stay_honest() {
  local home out output html
  home=$(make_home absent)

  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z "$DASHBOARD" --width 80) \
    || fail "absent-source terminal render failed"
  assert_contains "$out" "backlog absent" "missing backlog was not disclosed"
  assert_contains "$out" "github status not checked" \
    "empty fleet claimed a GitHub check without any PR URLs"
  assert_not_contains "$out" "telemetry absent" "source inventory leaked onto the default screen"
  assert_not_contains "$out" "token spend not measured" "measurement inventory leaked onto the default screen"
  assert_contains "$out" "captain holds unknown" "absent backlog rendered as an empty decisions list"
  assert_contains "$out" "unavailable - no secondmates registered" \
    "an unreachable reviews domain was not disclosed with its reason"

  output="$home/fleet-dashboard.html"
  FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "absent-source dashboard render failed"
  html=$(<"$output")
  assert_contains "$html" "Backlog source</span><strong>Absent</strong>" "missing backlog rendered as zero"
  assert_contains "$html" "Model telemetry</span><strong>Absent</strong>" "missing telemetry rendered as zero"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "missing telemetry implied zero spend"
  pass "missing sources and the unreachable reviews domain render as absent with reasons"
}

test_html_page_renders_minimal_sections_with_reachable_detail() {
  local home fakebin output html
  home=$(make_home html)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  output="$home/fleet-dashboard.html"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" 'id="decisions"' "page omitted the decisions section"
  assert_contains "$html" 'id="ours-in-review"' "page omitted our PRs section"
  assert_contains "$html" 'id="reviewing"' "page omitted the reviewing section"
  assert_contains "$html" 'id="review-obligations"' "page omitted requested-review obligations"
  assert_contains "$html" 'aria-label="needs Pedro"' "page omitted marker semantics"
  assert_contains "$html" 'aria-label="unknown"' "page omitted the unknown marker"
  assert_contains "$html" "Attention now" "page omitted the recap band"
  assert_contains "$html" "github status checked" "github data age missing from the page"
  assert_contains "$html" "PR 4001 | checks green | changes requested by reviewer-two" \
    "HTML PR row omits established status"
  assert_contains "$html" 'class="row row-aged"' "HTML list does not distinguish aged holds"
  assert_not_contains "$html" "truncated, 90 chars" "CLI truncation artifact leaked into the page"
  assert_not_contains "$html" "https://cdn" "dashboard depends on a CDN"
  pass "HTML page renders minimal sections with gh status and reachable detail"
}

test_section_selector_renders_intention_views_and_rejects_unknown() {
  local home fakebin default explicit_all building approvals reviewing output html error rc default_id building_id build_id build_shown tracked_before tracked_after build_generation
  home=$(make_home section-selector)
  write_live_fixture "$home"
  awk '/^## In flight$/ { print; print "- [ ] build-task - Build the fleet cockpit section views (repo: firstmate) (kind: ship) (since 2026-08-02)"; next } { print }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.updated"
  mv "$home/data/backlog.md.updated" "$home/data/backlog.md"
  mkdir -p "$home/projects/build-task"
  fm_write_meta "$home/state/build-task.meta" \
    "window=firstmate:fm-build-task-failed" "worktree=$home/projects/build-task" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  printf 'failed: worker exited before registering a PR\n' > "$home/state/build-task.status"
  build_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" build-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" build-task idle \
    --gen "$build_generation" --source claude-hook --event stop
  mkdir -p "$home/data/decision-task"
  cat > "$home/data/decision-task/report.md" <<'EOF'
# Decision task report

## Manual test script

1. Log in with captain@example.test / section-view-secret.
EOF
  fakebin=$(make_fakebin "$home")

  default=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "default section render failed"
  assert_not_contains "$default" "BUILDING" "no-selector default changed to include the new section"
  assert_contains "$default" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "no-selector recap counted a building-only stuck task that it does not display"
  if [ -n "${FM_DASHBOARD_CAPTURE_DEFAULT:-}" ]; then
    mkdir -p "$FM_DASHBOARD_CAPTURE_DEFAULT"
    printf '%s\n' "$default" > "$FM_DASHBOARD_CAPTURE_DEFAULT/terminal-all.txt"
    NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 \
      > "$FM_DASHBOARD_CAPTURE_DEFAULT/terminal.txt" \
      || fail "plain default capture failed"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
      "$DASHBOARD" --output "$FM_DASHBOARD_CAPTURE_DEFAULT/dashboard.html" >/dev/null \
      || fail "default HTML capture failed"
    pass "default render fixtures captured"
    return
  fi
  fm_write_meta "$home/state/build-task.meta" \
    "window=firstmate:fm-build-task" "worktree=$home/projects/build-task" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  printf 'working: implementing section-scoped cockpit views\n' > "$home/state/build-task.status"
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" build-task >/dev/null
  tracked_before=$(jq '[.rows | keys[] | select(startswith("d:") or startswith("v:"))] | length' \
    "$home/state/fleet-dashboard-observations.json")

  mv "$fakebin/gh" "$fakebin/gh-enabled"
  mv "$fakebin/quota-axi" "$fakebin/quota-axi-enabled"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/github-called"
echo "unexpected GitHub call in local-only section" >&2
exit 97
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/quota-called"
echo "unexpected quota call in local-only section" >&2
exit 98
SH
  chmod +x "$fakebin/gh" "$fakebin/quota-axi"

  building=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all --section building) \
    || fail "building section made a forge call"
  [ ! -e "$home/github-called" ] || fail "local-only section invoked GitHub"
  [ ! -e "$home/quota-called" ] || fail "local-only section invoked quota"
  tracked_after=$(jq '[.rows | keys[] | select(startswith("d:") or startswith("v:"))] | length' \
    "$home/state/fleet-dashboard-observations.json")
  [ "$tracked_after" = "$tracked_before" ] \
    || fail "section rendering retired another section's NEW-tracking rows"

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  pr\ view*|api\ graphql*)
    echo "approvals section fetched unrelated PR status" >&2
    exit 97
    ;;
esac
exec "$(dirname "$0")/gh-enabled" "$@"
SH
  chmod +x "$fakebin/gh"
  approvals=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all --section approvals) \
    || fail "approvals section did not limit forge work to review requests"
  [ ! -e "$home/quota-called" ] || fail "approvals section invoked quota"
  assert_contains "$approvals" "REVIEWS WAITING ON PEDRO (2)" \
    "approvals view omitted requested reviews"

  mv -f "$fakebin/gh-enabled" "$fakebin/gh"
  mv "$fakebin/quota-axi-enabled" "$fakebin/quota-axi"
  explicit_all=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all --section all) \
    || fail "explicit all-section render failed"
  assert_contains "$explicit_all" "BUILDING (1)" "all view omitted in-progress local work"
  assert_contains "$explicit_all" "DECISIONS (6)" "all view omitted decisions"
  assert_contains "$explicit_all" "OUR PRS IN REVIEW (4)" "all view omitted our PRs"
  assert_contains "$explicit_all" "REVIEWS WAITING ON PEDRO (2)" "all view omitted requested reviews"
  assert_contains "$explicit_all" "REVIEWING (3)" "all view omitted colleague review work"
  assert_contains "$explicit_all" "ATTENTION NOW | 3 need Pedro | 1 stuck | 2 reviews waiting" \
    "all view omitted the fleet-wide one-line recap"

  assert_contains "$building" "BUILDING (1)" "building view omitted in-progress local work"
  assert_contains "$building" "Build the fleet cockpit section views" "building view omitted the active task"
  assert_contains "$building" "OUR PRS IN REVIEW (4)" "building view omitted our PRs"
  assert_contains "$building" "ATTENTION NOW | 3 need Pedro | 1 stuck" \
    "building view omitted the local-only one-line recap"
  assert_not_contains "$building" "reviews waiting" "building recap included forge-derived counts"
  assert_not_contains "$building" "DECISIONS" "building view included approvals"
  assert_not_contains "$building" "REVIEWS WAITING ON PEDRO" "building view included review approvals"
  assert_not_contains "$building" "REVIEWING" "building view included colleague review work"
  default_id=$(printf '%s\n' "$default" | grep -F "PR 4001 |" | tail -1 | awk '{print $2}')
  building_id=$(printf '%s\n' "$building" | grep -F "PR 4001 |" | tail -1 | awk '{print $2}')
  [ "$building_id" = "$default_id" ] || fail "building view changed the stable row id"
  build_id=$(printf '%s\n' "$building" | grep -F "Build the fleet cockpit section views" | awk '{print $2}')
  case "$build_id" in
    b:build-task*) ;;
    *) fail "building row lacks a readable stable id: $build_id" ;;
  esac
  build_shown=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section building --show "$build_id") \
    || fail "building row did not expand by stable id"
  assert_contains "$build_shown" "implementing section-scoped cockpit views" \
    "building detail omitted the local current-state detail"

  assert_contains "$approvals" "DECISIONS (6)" "approvals view omitted decisions"
  assert_contains "$approvals" "PR 930 [artemis]" "approvals view omitted the longest-waiting review request"
  assert_contains "$approvals" "PR 912 [artemis]" "approvals view omitted the other review request"
  assert_contains "$approvals" "ATTENTION NOW | 3 need Pedro | 1 stuck | 2 reviews waiting" \
    "approvals view omitted review requests from the fleet-wide recap"
  assert_not_contains "$approvals" "OUR PRS IN REVIEW" "approvals view included building work"
  assert_not_contains "$approvals" "REVIEWING" "approvals view included colleague review work"

  reviewing=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all --section reviewing) \
    || fail "reviewing section render failed"
  assert_contains "$reviewing" "REVIEWING (3)" "reviewing view omitted colleague review work"
  assert_contains "$reviewing" "ATTENTION NOW | 3 need Pedro | 1 stuck | 2 reviews waiting" \
    "reviewing view omitted the fleet-wide one-line recap"
  assert_not_contains "$reviewing" "DECISIONS" "reviewing view included approvals"
  assert_not_contains "$reviewing" "OUR PRS IN REVIEW" "reviewing view included building work"
  assert_not_contains "$reviewing" "REVIEWS WAITING ON PEDRO" "reviewing view included review approvals"

  output="$home/approvals.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --section approvals --output "$output" >/dev/null \
    || fail "approvals HTML render failed"
  html=$(<"$output")
  assert_contains "$html" 'id="decisions"' "approvals HTML omitted decisions"
  assert_contains "$html" 'id="review-obligations"' "approvals HTML omitted requested reviews"
  assert_not_contains "$html" 'id="ours-in-review"' "approvals HTML included building work"
  assert_not_contains "$html" 'id="reviewing"' "approvals HTML included colleague review work"
  assert_contains "$html" "Attention now" "approvals HTML omitted the recap"
  assert_contains "$html" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "approvals HTML omitted review requests from the recap"
  assert_not_contains "$html" "section-view-secret" "section HTML leaked a recorded credential"

  set +e
  error=$(render_terminal "$home" "$fakebin" --section unknown 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unknown section name rendered the full fleet"
  assert_contains "$error" "valid sections: building, approvals, reviewing, all, peace" \
    "unknown section error omitted the valid names"
  pass "section selector renders intentional views and rejects unknown names"
}

test_help_describes_the_fixed_terminal_measure() {
  local help
  help=$("$DASHBOARD" --help) || fail "dashboard help failed"
  assert_contains "$help" "terminal frame width request (minimum 40; output capped at 80)" \
    "--width help still claims an uncapped override"
  pass "help describes the fixed terminal measure"
}

test_watch_flag_needs_a_terminal_and_stays_exclusive() {
  local home fakebin error rc
  home=$(make_home watch)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  set +e
  error=$(render_terminal "$home" "$fakebin" --watch 2>&1 < /dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--watch ran without a terminal"
  assert_contains "$error" "requires a terminal" "non-tty watch refusal is not actionable"

  set +e
  error=$(render_terminal "$home" "$fakebin" --watch --output "$home/x.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--watch combined with --output"
  assert_contains "$error" "cannot be combined" "watch/output exclusivity is not enforced"
  pass "watch mode refuses non-terminals and stays exclusive with file output"
}

test_watch_paints_and_accepts_input_during_forge_refresh() {
  local home fakebin metrics paint_ms
  home=$(make_home watch-pty)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  touch "$home/slow-local-fixture" "$home/slow-github-fixture"

  metrics=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" <<'PY'
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time


def read_available(master_fd, output):
    readable, _, _ = select.select([master_fd], [], [], 0)
    if not readable:
        return
    try:
        chunk = os.read(master_fd, 65536)
    except OSError:
        return
    if chunk:
        output.extend(chunk)


dashboard, home = sys.argv[1:]
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "30",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "120",
    "FM_TEST_LOCAL_SLEEP_SECONDS": "4",
    "FM_TEST_GITHUB_SLEEP_SECONDS": "4",
    "NO_COLOR": "1",
})


def launch():
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    before = termios.tcgetattr(slave_fd)
    monitor_fd = os.dup(slave_fd)
    process = subprocess.Popen(
        [dashboard, "--watch", "--width", "80"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        env=environment,
    )
    os.close(slave_fd)
    return process, master_fd, monitor_fd, before


# Run 1: a digit is typed only after the deliberately slow local refresh starts.
local_started = os.path.join(home, "local-refresh-started")
local_finished = os.path.join(home, "local-refresh-finished")
process, master_fd, slave_fd, before = launch()
started_at = time.monotonic()
output = bytearray()
first_paint_ms = None
key_sent = False
key_honoured_during_local = False
deadline = started_at + 30
while time.monotonic() < deadline and process.poll() is None:
    read_available(master_fd, output)
    if first_paint_ms is None and b"FIRSTMATE FLEET" in output:
        first_paint_ms = (time.monotonic() - started_at) * 1000
    if not key_sent and os.path.exists(local_started) and not os.path.exists(local_finished):
        os.write(master_fd, b"1")
        key_sent = True
    if key_sent and b"select row: 1_ while local state loads" in output:
        key_honoured_during_local = not os.path.exists(local_finished)
        break
    time.sleep(0.01)
if process.poll() is None:
    q_sent_at = time.monotonic()
    os.write(master_fd, b"q")
else:
    q_sent_at = time.monotonic()
exit_deadline = q_sent_at + 3
while process.poll() is None and time.monotonic() < exit_deadline:
    read_available(master_fd, output)
    time.sleep(0.01)
q_during_local_latency_ms = (time.monotonic() - q_sent_at) * 1000
if process.poll() is None:
    process.kill()
exit_code = process.wait(timeout=3)
read_available(master_fd, output)
after = termios.tcgetattr(slave_fd)
cleanup = b"\x1b[?25h\x1b[?1049l"
first_cleanup = cleanup in output
first_tty_restored = bool(after[3] & termios.ICANON) and bool(before[3] & termios.ICANON)
os.close(master_fd)
os.close(slave_fd)

# Run 2: keep the established digit+Enter proof specifically inside forge refresh.
os.remove(os.path.join(home, "slow-local-fixture"))
for marker in ("github-refresh-started", "github-refresh-finished"):
    path = os.path.join(home, marker)
    if os.path.exists(path):
        os.remove(path)
forge_started = os.path.join(home, "github-refresh-started")
forge_finished = os.path.join(home, "github-refresh-finished")
process, master_fd, slave_fd, before = launch()
row_started_at = time.monotonic()
row_output = bytearray()
row_paint_ms = None
first_row_before_forge = False
key_sent = False
expanded_before_forge = False
deadline = row_started_at + 30
while time.monotonic() < deadline and process.poll() is None:
    read_available(master_fd, row_output)
    if row_paint_ms is None and b"d:decision-task-api" in row_output:
        row_paint_ms = (time.monotonic() - row_started_at) * 1000
        first_row_before_forge = not os.path.exists(forge_finished)
    if row_paint_ms is not None and not key_sent and os.path.exists(forge_started):
        os.write(master_fd, b"1\r")
        key_sent = True
    if key_sent and b"row id: d:decision-task-api" in row_output:
        expanded_before_forge = not os.path.exists(forge_finished)
        break
    time.sleep(0.01)
if process.poll() is None:
    forge_deadline = time.monotonic() + 8
    while not os.path.exists(forge_finished) and time.monotonic() < forge_deadline:
        read_available(master_fd, row_output)
        time.sleep(0.01)
    os.write(master_fd, b"q")
exit_deadline = time.monotonic() + 3
while process.poll() is None and time.monotonic() < exit_deadline:
    read_available(master_fd, row_output)
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
row_exit_code = process.wait(timeout=3)
read_available(master_fd, row_output)
row_after = termios.tcgetattr(slave_fd)
row_cleanup = cleanup in row_output
row_tty_restored = bool(row_after[3] & termios.ICANON) and bool(before[3] & termios.ICANON)
os.close(master_fd)
os.close(slave_fd)

print(f"first_paint_ms={first_paint_ms:.3f}" if first_paint_ms is not None else "first_paint_ms=missing")
print(f"keypress_during_local_honoured={int(key_honoured_during_local)}")
print(f"q_during_local_latency_ms={q_during_local_latency_ms:.3f}")
print(f"first_row_paint_ms={row_paint_ms:.3f}" if row_paint_ms is not None else "first_row_paint_ms=missing")
print(f"first_row_before_forge={int(first_row_before_forge)}")
print(f"keypress_during_forge_honoured={int(expanded_before_forge)}")
print(f"loading_label_seen={int(b'checking GitHub' in row_output)}")
print(f"exit_code={exit_code}")
print(f"row_exit_code={row_exit_code}")
print(f"cursor_and_alternate_restored={int(first_cleanup and row_cleanup)}")
print(f"tty_canonical_restored={int(first_tty_restored and row_tty_restored)}")
if first_paint_ms is None or row_paint_ms is None or not expanded_before_forge:
    print(f"output_tail={bytes(output[-500:] + row_output[-2000:])!r}")
PY
  ) \
    || fail "PTY dashboard driver failed"
  printf '%s\n' "$metrics"
  paint_ms=$(printf '%s\n' "$metrics" | awk -F= '$1 == "first_paint_ms" { print $2 }')
  [ "$paint_ms" != "missing" ] || fail "watch mode never painted an immediate loading frame"
  assert_contains "$metrics" "keypress_during_local_honoured=1" \
    "keypress was not handled while the local snapshot worker was still blocked"
  awk -F= '$1 == "q_during_local_latency_ms" { found = 1; if ($2 >= 1000) exit 1 } END { if (!found) exit 1 }' \
    <<< "$metrics" || fail "q during the local worker did not exit within one second"
  assert_contains "$metrics" "first_row_before_forge=1" \
    "first local row stayed behind the forge refresh"
  assert_contains "$metrics" "keypress_during_forge_honoured=1" \
    "row selection was not handled while the forge refresh was still blocked"
  assert_contains "$metrics" "loading_label_seen=1" "initial local paint hid the in-flight GitHub check"
  assert_contains "$metrics" "exit_code=0" "q during local refresh did not exit watch mode cleanly"
  assert_contains "$metrics" "row_exit_code=0" "q during forge refresh did not exit watch mode cleanly"
  assert_contains "$metrics" "cursor_and_alternate_restored=1" \
    "watch exit did not show the cursor and leave the alternate screen"
  assert_contains "$metrics" "tty_canonical_restored=1" "watch exit left the terminal in raw mode"
  pass "watch paints locally, handles input during forge refresh, and restores the terminal"
}

test_watch_redraw_clears_detail_tails_and_narrower_frames() {
  local home fakebin real_tmux metrics
  home=$(make_home watch-redraw)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  real_tmux=$(command -v tmux) || fail "tmux is required for the real-terminal redraw regression"
  sed_in_place "$home/data/backlog.md" \
    's/Decide the public API/Decide the public API AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA NARROW_FRAME_SENTINEL DETAIL_FRAME_SENTINEL/'

  metrics=$(python3 - "$real_tmux" "$DASHBOARD" "$home" "$fakebin" <<'PY'
import os, subprocess, sys, time

tmux, dashboard, home, fakebin = sys.argv[1:]
socket = os.path.join(home, "cockpit-redraw.sock")
target = "cockpit"
environment = (
    f"PATH={fakebin}:{os.environ['PATH']} "
    f"FM_HOME={home} FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z "
    "FM_FLEET_WATCH_LOCAL_SECONDS=30 FM_FLEET_WATCH_GITHUB_SECONDS=120 NO_COLOR=1"
)

def run(*arguments, check=True):
    return subprocess.run(
        [tmux, "-S", socket, *arguments], check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )

def capture():
    return run("capture-pane", "-p", "-t", target).stdout

def wait_for(needle, timeout=15):
    deadline = time.monotonic() + timeout
    screen = ""
    while time.monotonic() < deadline:
        screen = capture()
        if needle in screen:
            return screen
        time.sleep(0.02)
    return screen

command = f"env {environment} {dashboard} --watch"
run("new-session", "-d", "-x", "120", "-y", "50", "-s", target, command)
try:
    list_screen = wait_for("DETAIL_FRAME_SENTINEL")
    run("send-keys", "-t", target, "1", "Enter")
    detail_screen = wait_for("row id:")
    detail_wider = "DETAIL_FRAME_SENTINEL" in detail_screen
    run("send-keys", "-t", target, "b")
    returned_screen = wait_for("select: type row number + Enter")
    detail_tail_gone = "DETAIL_FRAME_SENTINEL" not in returned_screen

    run("resize-window", "-t", target, "-x", "50", "-y", "50")
    run("send-keys", "-t", target, "9")
    time.sleep(0.1)
    run("resize-window", "-t", target, "-x", "120", "-y", "50")
    resized_screen = capture()
    narrow_tail_gone = "NARROW_FRAME_SENTINEL" not in resized_screen
    run("send-keys", "-t", target, "q")
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and run("has-session", "-t", target, check=False).returncode == 0:
        time.sleep(0.02)
    exited = run("has-session", "-t", target, check=False).returncode != 0
finally:
    run("kill-server", check=False)

print(f"detail_frame_wider={int(detail_wider)}")
print(f"detail_tail_gone={int(detail_tail_gone)}")
print(f"narrow_resize_tail_gone={int(narrow_tail_gone)}")
print(f"exit_clean={int(exited)}")
PY
  ) || fail "tmux real-terminal redraw driver failed"
  printf '%s\n' "$metrics"
  assert_contains "$metrics" "detail_frame_wider=1" "redraw fixture never rendered its wide detail frame"
  assert_contains "$metrics" "detail_tail_gone=1" "detail-frame text survived the back-navigation redraw"
  assert_contains "$metrics" "narrow_resize_tail_gone=1" "wide-frame text survived a narrower redraw"
  assert_contains "$metrics" "exit_clean=1" "redraw PTY did not exit cleanly"
  pass "watch redraw clears every shortened line after detail navigation and resize"
}

test_watch_does_not_claim_a_github_check_without_github_work() {
  local home fakebin metrics
  home=$(make_home watch-no-github)
  fakebin=$(make_fakebin "$home")
  metrics=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

dashboard, home = sys.argv[1:]
master, slave = pty.openpty()
monitor = os.dup(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "30",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "120",
    "NO_COLOR": "1",
})
process = subprocess.Popen(
    [dashboard, "--watch", "--width", "80"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=environment,
)
os.close(slave)
output = bytearray()
deadline = time.monotonic() + 10
while process.poll() is None and time.monotonic() < deadline:
    if select.select([master], [], [], 0.02)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
    if b"github status not checked" in output and b"select: type row number" in output:
        break
if process.poll() is None:
    os.write(master, b"q")
exit_deadline = time.monotonic() + 2
while process.poll() is None and time.monotonic() < exit_deadline:
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
exit_code = process.wait(timeout=3)
print(f"checking_github_claimed={int(b'checking GitHub' in output)}")
print(f"not_checked_rendered={int(b'github status not checked' in output)}")
print(f"exit_code={exit_code}")
os.close(master)
os.close(monitor)
PY
  ) || fail "no-GitHub PTY driver failed"
  printf '%s\n' "$metrics"
  assert_contains "$metrics" "checking_github_claimed=0" \
    "watch claimed it was checking GitHub on a home that makes no GitHub call"
  assert_contains "$metrics" "not_checked_rendered=1" "watch did not render the truthful no-GitHub status"
  assert_contains "$metrics" "exit_code=0" "no-GitHub PTY did not exit cleanly"
  pass "watch does not claim a GitHub check when no GitHub work exists"
}

test_ignored_operational_directories_are_never_output_targets() {
  local home directory output error rc
  home=$(make_home forbidden-output)
  for directory in data state config; do
    output="$home/$directory/fleet-dashboard.html"
    set +e
    error=$(FM_HOME="$home" "$DASHBOARD" --output "$output" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "dashboard accepted a $directory/ output path"
    [ ! -e "$output" ] || fail "dashboard wrote into the ignored $directory directory"
    assert_contains "$error" "refusing dashboard output" "unsafe-output refusal was not actionable"
  done
  pass "dashboard refuses data, state, and config output roots"
}

test_default_screen_defers_non_actionable_rows_without_losing_full_inventory() {
  local home fakebin out all
  home=$(make_home minimal-default)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80) || fail "minimal render failed"
  assert_contains "$out" "4 deferred decisions" "non-immediate decisions have no counted affordance"
  assert_contains "$out" "3 review relationships" "review work in progress has no counted affordance"
  assert_contains "$out" "PR 4003 | local checks unknown | unregistered" \
    "the locally stuck PR did not earn a default row"
  assert_not_contains "$out" "PR 4001 |" "non-actionable PR stayed on the default screen"
  assert_not_contains "$out" "PR 4004 |" "waiting PR stayed on the default screen"
  assert_contains "$out" "3 deferred PRs" "deferred PRs have no counted affordance"
  assert_not_contains "$out" "Renew the signing certificate" "aged hold stayed on the default screen"
  assert_not_contains "$out" "Pick the flake-fix destination" "answered-looking hold stayed on the default screen"
  assert_not_contains "$out" "sources backlog" "non-actionable source inventory stayed on the default screen"

  all=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "expanded list render failed"
  assert_contains "$all" "Renew the signing certificate" "--all cannot reach an aged hold"
  assert_contains "$all" "Pick the flake-fix destination" "--all cannot reach an answered-looking hold"
  assert_contains "$all" "PR 4001 | checks green | changes requested by reviewer-two" \
    "--all cannot reach a deferred PR status"
  assert_contains "$all" "PR 4004 | local checks unknown | waiting on local-reviewer" \
    "--all cannot reach a waiting PR"
  assert_contains "$all" "PR 4188" "--all cannot reach a collapsed review relationship"
  pass "default screen defers non-actionable rows while --all preserves full status"
}

test_default_slots_prioritize_new_rows_and_name_hidden_reviews() {
  local home fakebin seeded changed updated review_home review_fakebin review_out
  home=$(make_home priority-slots)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  seeded=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "priority-slot baseline render failed"
  assert_not_contains "$seeded" "[NEW]" "priority-slot baseline was not seeded quietly"
  updated="$home/data/backlog.md.updated"
  awk '{ sub(/This is not yet decided and still needs Pedro\./, "Pedro must now choose the credential rotation window."); print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80) \
    || fail "priority-slot changed render failed"
  printf '%s\n' "$changed" | grep -F "Decide whether to rotate the credential" | grep -F "[NEW]" >/dev/null \
    || fail "a NEW decision behind the cap did not win a default slot: $changed"

  review_home=$(make_home review-slot-label)
  write_live_fixture "$review_home"
  touch "$review_home/fetch-priority-fixture"
  review_fakebin=$(make_fakebin "$review_home")
  review_out=$(NO_COLOR=1 render_terminal "$review_home" "$review_fakebin" --width 80) \
    || fail "review-slot label render failed"
  assert_contains "$review_out" "4 review requests - --all shows" \
    "hidden review requests were mislabeled as generic items"
  pass "NEW work wins default slots and hidden review requests keep their meaning"
}

test_readable_ids_survive_colliding_rows_and_support_prefix_lookup() {
  local home fakebin out first_id with_collision survivor_id after_removal removed_id shown updated error rc
  home=$(make_home readable-ids)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] toolsmith-endpoint-collision - Decide how endpoint collisions are reported (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the collision wording.) (hold-kind: captain)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "readable-id render failed"
  first_id=$(printf '%s\n' "$out" | grep -F "endpoint collisions are reported" | awk '{print $2}')
  case "$first_id" in
    d:toolsmith-endpoint*) ;;
    *) fail "long record id became opaque: $first_id" ;;
  esac

  awk '/^## Queued$/ { print "- [ ] toolsmith-endpoint-copy - Decide how endpoint copies are reported (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the copy wording.) (hold-kind: captain)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  with_collision=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "collision render failed"
  survivor_id=$(printf '%s\n' "$with_collision" | grep -F "endpoint collisions are reported" | awk '{print $2}')
  [ "$first_id" = "$survivor_id" ] || fail "another row changed a survivor id: $first_id -> $survivor_id"
  grep -v -F 'toolsmith-endpoint-copy - Decide how endpoint copies are reported' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  after_removal=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-collision-removal render failed"
  removed_id=$(printf '%s\n' "$after_removal" | grep -F "endpoint collisions are reported" | awk '{print $2}')
  [ "$first_id" = "$removed_id" ] || fail "removing another row changed a survivor id: $first_id -> $removed_id"
  set +e
  error=$(render_terminal "$home" "$fakebin" --show "${first_id%?}" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an implicit prefix could make a stale id resolve to another row"
  assert_contains "$error" "no row has that id" "stale exact-id refusal is not explicit"
  shown=$(render_terminal "$home" "$fakebin" --show "${first_id%?}*") || fail "explicit unambiguous id prefix did not resolve"
  assert_contains "$shown" "endpoint collisions are reported" "prefix lookup resolved the wrong row"
  pass "readable row ids depend only on their own stable record identity"
}

test_detail_contract_uses_report_evidence_and_slow_quota_without_fabrication() {
  local home fakebin out id shown output html
  home=$(make_home detail-contract)
  write_live_fixture "$home"
  mkdir -p "$home/data/decision-task"
  cat > "$home/data/decision-task/report.md" <<'EOF'
# Decision task report

## What this affects

People choosing the API will see one stable method instead of two competing entry points.

## Manual test script

1. Open the API preview.
2. Call the documented method.
Expected: the documented method succeeds.
Failure: either competing entry point remains visible.

### Credentials

Login: `captain@example.test` / `secret-test-password`
EOF
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "detail list render failed"
  id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "detail expansion failed"
  assert_contains "$shown" "token usage: not measured" "detail implied per-task token usage exists"
  assert_contains "$shown" "quota: Codex week 73% remaining; resets in 6d 23h" "quota and reset are absent from detail"
  assert_contains "$shown" "quota data: checked just now" "freshly fetched quota was rendered with an impossible age"
  assert_contains "$shown" "what this affects: People choosing the API" "report-backed impact is absent"
  assert_contains "$shown" "manual test script (task report):" "manual script source is not identified"
  assert_contains "$shown" "secret-test-password" "interactive detail omitted recorded credentials"

  output="$home/cockpit.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" >/dev/null || fail "HTML detail render failed"
  html=$(<"$output")
  assert_contains "$html" "manual test script: omitted from shareable HTML" \
    "HTML does not explain its fail-safe script omission"
  assert_not_contains "$html" "Open the API preview" "shareable HTML retained a manual script body"
  assert_not_contains "$html" "secret-test-password" "shareable HTML leaked credentials"
  pass "detail carries sourced impact, manual validation, honest token status, and quota"
}

test_review_obligations_are_distinct_and_oldest_first() {
  local home fakebin out obligation reviewing oldest newer id shown
  home=$(make_home review-obligations)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80) || fail "review-obligation render failed"
  obligation=$(line_number_of "$out" "REVIEWS WAITING ON PEDRO")
  reviewing=$(line_number_of "$out" "REVIEWING")
  [ -n "$obligation" ] || fail "requested-review obligation section is absent"
  [ -n "$reviewing" ] || fail "review work-in-progress affordance is absent"
  [ "$obligation" -lt "$reviewing" ] || fail "obligations are buried under our review process"
  oldest=$(line_number_of "$out" "PR 930 [artemis] | waiting 13d")
  newer=$(line_number_of "$out" "PR 912 [artemis] | waiting 2d")
  [ -n "$oldest" ] && [ -n "$newer" ] && [ "$oldest" -lt "$newer" ] \
    || fail "requested reviews are not sorted by longest wait"
  assert_contains "$out" "PR 930 [artemis] | waiting 13d" "waiting time is not prominent"
  assert_contains "$out" "re-review 2" "review round is absent"
  id=$(printf '%s\n' "$out" | grep -F "PR 930 [artemis] | waiting 13d" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "review obligation expansion failed"
  assert_contains "$shown" "author pushed since review" "head change did not reuse recorded review heads"
  assert_contains "$shown" "manual validation outstanding" "manual validation obligation is absent"
  pass "review obligations are a distinct longest-wait-first action queue"
}

test_decision_ids_bind_task_key_and_verb_across_membership_changes() {
  local home fakebin updated before alpha_id after alpha_after zulu_id shown generation
  home=$(make_home decision-id-membership)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] mm-alpha - Fix the alpha ingest (repo: firstmate) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fm_write_meta "$home/state/mm-alpha.meta" \
    "window=firstmate:fm-mm-alpha" "worktree=$home/projects/mm-alpha" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  mkdir -p "$home/projects/mm-alpha"
  printf 'needs-decision [key=rotate-cert]: Choose alpha rotation.\n' > "$home/state/mm-alpha.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mm-alpha)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" mm-alpha idle \
    --gen "$generation" --source claude-hook --event stop
  fakebin=$(make_fakebin "$home")

  before=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "single-key render failed"
  alpha_id=$(printf '%s\n' "$before" | grep -F "Fix the alpha ingest" | awk '{print $2}')
  case "$alpha_id" in
    d:mm-alpha-rotate-cert-ask*) ;;
    *) fail "decision id omits task, key, or verb: $alpha_id" ;;
  esac

  awk '/^## Queued$/ { print "- [ ] zz-zulu - Fix the zulu exporter (repo: firstmate) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fm_write_meta "$home/state/zz-zulu.meta" \
    "window=firstmate:fm-zz-zulu" "worktree=$home/projects/zz-zulu" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  mkdir -p "$home/projects/zz-zulu"
  printf 'needs-decision [key=rotate-cert]: Choose zulu rotation.\n' > "$home/state/zz-zulu.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" zz-zulu)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" zz-zulu idle \
    --gen "$generation" --source claude-hook --event stop

  after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "colliding-key render failed"
  alpha_after=$(printf '%s\n' "$after" | grep -F "Fix the alpha ingest" | awk '{print $2}')
  zulu_id=$(printf '%s\n' "$after" | grep -F "Fix the zulu exporter" | awk '{print $2}')
  [ "$alpha_id" = "$alpha_after" ] || fail "unrelated membership changed an existing decision id"
  [ "$alpha_id" != "$zulu_id" ] || fail "two tasks sharing a decision key received one id"
  shown=$(render_terminal "$home" "$fakebin" --show "$alpha_id") || fail "stale decision id stopped resolving"
  assert_contains "$shown" "Fix the alpha ingest" "stale decision id silently resolved to a different row"
  pass "decision ids bind task, key, and verb independently of list membership"
}

test_registered_pr_number_comes_from_registered_url() {
  local home fakebin updated out
  home=$(make_home registered-pr-number)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '{ gsub("review-task - Ship the review branch", "review-task - PR 4999: Ship the review branch"); print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "registered-number render failed"
  assert_contains "$out" "PR 4001 | checks green" "registered URL number was not rendered"
  assert_not_contains "$out" "PR 4999 | checks green" "title number mislabeled status fetched for another PR"
  pass "registered PR URL outranks a conflicting title number"
}

test_our_pr_ids_keep_the_pr_number_through_an_engineered_collision() {
  local home fakebin updated out first_shown second_shown duplicates
  home=$(make_home duplicate-our-pr)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] collision-a-14 - Follow up on the review branch (repo: artemis) (kind: ship) (since 2026-08-02)"; print "- [ ] collision-a-20 - Recheck the review branch (repo: artemis) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  mkdir -p "$home/projects/collision-a-14" "$home/projects/collision-a-20"
  fm_write_meta "$home/state/collision-a-14.meta" \
    "window=firstmate:fm-collision-a-14" "worktree=$home/projects/collision-a-14" "project=artemis" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off" "pr=$OUR_PR"
  fm_write_meta "$home/state/collision-a-20.meta" \
    "window=firstmate:fm-collision-a-20" "worktree=$home/projects/collision-a-20" "project=artemis" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off" "pr=$OUR_PR"
  printf 'working: addressing follow-up findings on %s\n' "$OUR_PR" > "$home/state/collision-a-14.status"
  printf 'working: rechecking follow-up findings on %s\n' "$OUR_PR" > "$home/state/collision-a-20.status"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "engineered two-hex collision refused the complete render"
  assert_contains "$out" "o:4001~bf59" "first engineered-collision row lost its readable PR identity"
  assert_contains "$out" "o:4001~bf3f" "second engineered-collision row lost its readable PR identity"
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]+[0-9]+[[:space:]]+o:4001~bf59[[:space:]]+[?◆×○●][[:space:]]+PR 4001' \
    || fail "OUR PRS row lost its position number before the readable id"
  duplicates=$(printf '%s\n' "$out" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[dorv]:/) print $i }' | sort | uniq -d)
  [ -z "$duplicates" ] || fail "dashboard emitted duplicate row identities: $duplicates"
  first_shown=$(render_terminal "$home" "$fakebin" --show o:4001~bf59) || fail "first collision row id did not resolve"
  second_shown=$(render_terminal "$home" "$fakebin" --show o:4001~bf3f) || fail "second collision row id did not resolve"
  assert_contains "$first_shown" "Follow up on the review branch" "first collision id resolved to the wrong task"
  assert_contains "$second_shown" "Recheck the review branch" "second collision id resolved to the wrong task"
  pass "our PR ids keep the PR number and survive an engineered digest collision"
}

test_registered_ours_are_fetched_before_capped_optional_urls() {
  local home fakebin out pr id
  home=$(make_home github-fetch-priority)
  write_live_fixture "$home"
  touch "$home/fetch-priority-fixture"
  for pr in 4010 4011 4012 4013 4014 4015 4016; do
    id="priority-$pr"
    mkdir -p "$home/projects/$id"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=artemis" \
      "harness=claude" "kind=ship" "mode=ship" "yolo=off" \
      "pr=https://github.com/monalee/artemis/pull/$pr"
    printf 'working: PR %s is in review\n' "$pr" > "$home/state/$id.status"
  done
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "fetch-priority render failed"
  assert_contains "$out" "github status checked just now" "successful bounded GitHub fetch lost its freshness header"
  assert_contains "$out" "PR 4001 | checks green | changes requested by reviewer-two" \
    "registered OURS URL was displaced from the bounded GitHub fetch set"
  assert_not_contains "$out" "PR 4001 | checks unknown - not checked" \
    "fresh header contradicted an unfetched registered OURS row"
  for pr in 4010 4011 4012 4013 4014 4015 4016; do
    assert_contains "$out" "PR $pr | checks green | waiting on human review" \
      "registered OURS PR $pr fell outside the fetch set"
  done
  pass "registered OURS rows are covered before capped optional GitHub enrichment"
}

test_obligation_round_uses_viewer_review_history_or_stays_unknown() {
  local home fakebin out reviewed_id reviewed_shown unknown_id unknown_shown
  home=$(make_home obligation-review-history)
  write_live_fixture "$home"
  touch "$home/review-history-fixture"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "review-history obligation render failed"
  reviewed_id=$(printf '%s\n' "$out" | grep -F "PR 940 [artemis]" | awk '{print $2}')
  reviewed_shown=$(render_terminal "$home" "$fakebin" --show "$reviewed_id") \
    || fail "viewer-reviewed obligation detail failed"
  assert_contains "$reviewed_shown" "re-review 2+ · author pushed since review" \
    "viewer-authored GitHub review did not establish the round floor and head change"
  unknown_id=$(printf '%s\n' "$out" | grep -F "PR 941 [artemis]" | awk '{print $2}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_id") \
    || fail "unknown-history obligation detail failed"
  assert_contains "$unknown_shown" "round unknown · head change unknown" \
    "absent local and GitHub review history became a positive round claim"
  assert_not_contains "$reviewed_shown$unknown_shown" "first pass" "absent review history still renders as first pass"
  pass "review obligations derive a round floor from GitHub or render unknown"
}

test_shareable_html_omits_unstructured_manual_scripts_by_default() {
  local home fakebin out id shown output html
  home=$(make_home inline-credentials)
  write_live_fixture "$home"
  mkdir -p "$home/data/decision-task"
  cat > "$home/data/decision-task/report.md" <<'EOF'
# Decision task report

## Manual test script

1. Open the API preview.
2. Log in with buyer@example.test / hunter2-inline-password.
Expected: the documented method succeeds.
EOF
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "inline-credential list render failed"
  id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "inline-credential terminal detail failed"
  assert_contains "$shown" "hunter2-inline-password" "interactive terminal omitted the recorded credential"

  output="$home/cockpit.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" >/dev/null || fail "inline-credential HTML render failed"
  html=$(<"$output")
  assert_not_contains "$html" "hunter2-inline-password" "shareable HTML leaked an inline credential"
  assert_not_contains "$html" "Open the API preview" "shareable HTML included an unstructured manual script body"
  assert_contains "$html" "manual test script: omitted from shareable HTML" \
    "shareable HTML did not explain the fail-safe script omission"
  pass "shareable HTML omits unstructured manual scripts while terminal detail retains them"
}

test_first_newness_run_seeds_without_flagging_rows() {
  local home fakebin out store
  home=$(make_home newness-first-run)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"

  [ ! -e "$store" ] || fail "newness fixture unexpectedly started with a store"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "first newness render failed"
  assert_not_contains "$out" "[NEW]" "first render cried wolf by flagging seeded rows"
  [ -f "$store" ] || fail "first render did not seed the observation store"
  pass "first newness run seeds observations without flagging rows"
}

test_corrupt_observation_store_reseeds_silently() {
  local home fakebin out store
  home=$(make_home newness-corrupt-store)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"
  printf '{ this is not json' > "$store"

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "corrupt observation store prevented the cockpit from rendering"
  assert_contains "$out" "FIRSTMATE FLEET" "corrupt-store recovery omitted the cockpit header"
  assert_contains "$out" "OUR PRS IN REVIEW" "corrupt-store recovery omitted supported rows"
  assert_contains "$out" "PR 4001" "corrupt-store recovery omitted a supported PR row"
  assert_not_contains "$out" "[NEW]" "corrupt-store recovery cried wolf after reseeding"
  jq -e '.version == 1 and (.rows | type == "object")' "$store" >/dev/null \
    || fail "corrupt observation store was not replaced with a valid seed"
  pass "corrupt observation stores reseed silently and preserve cockpit rendering"
}

test_empty_observation_store_reseeds_silently() {
  local home fakebin out store
  home=$(make_home newness-empty-store)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"
  : > "$store"

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "empty observation store prevented the cockpit from rendering"
  assert_contains "$out" "FIRSTMATE FLEET" "empty-store recovery omitted the cockpit header"
  assert_contains "$out" "OUR PRS IN REVIEW" "empty-store recovery omitted supported rows"
  assert_contains "$out" "PR 4001" "empty-store recovery omitted a supported PR row"
  assert_not_contains "$out" "[NEW]" "empty-store recovery cried wolf after reseeding"
  jq -e '.version == 1 and (.rows | type == "object")' "$store" >/dev/null \
    || fail "empty observation store was not replaced with a valid seed"
  pass "empty observation stores reseed silently and preserve cockpit rendering"
}

test_identical_newness_render_stays_quiet_and_does_not_mark_seen() {
  local home fakebin first_checksum second_checksum out store
  home=$(make_home newness-identical)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness baseline render failed"
  [ -f "$store" ] || fail "baseline render did not create the observation store"
  first_checksum=$(cksum "$store")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "identical newness render failed"
  second_checksum=$(cksum "$store")
  assert_not_contains "$out" "[NEW]" "identical observed values were flagged as new"
  [ "$first_checksum" = "$second_checksum" ] || fail "list rendering marked observations seen"
  pass "identical renders stay quiet and list rendering does not mark rows seen"
}

test_expansion_marks_only_the_selected_row_seen() {
  local home fakebin changed after decision_id decision_line new_count html_path
  home=$(make_home newness-expansion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness baseline render failed"
  touch "$home/ci-red-fixture"
  printf 'needs-decision [key=api-shape]: Choose the versioned public API shape.\n' \
    > "$home/state/decision-task.status"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "changed newness render failed"
  new_count=$(printf '%s\n' "$changed" | grep -F -o '[NEW]' | wc -l | tr -d ' ')
  [ "$new_count" = 2 ] || fail "expected two changed rows before expansion, got $new_count"

  html_path="$home/cockpit.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$html_path" >/dev/null || fail "newness HTML render failed"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-HTML newness render failed"
  new_count=$(printf '%s\n' "$changed" | grep -F -o '[NEW]' | wc -l | tr -d ' ')
  [ "$new_count" = 2 ] || fail "static HTML rendering acknowledged a NEW row"

  decision_id=$(printf '%s\n' "$changed" | grep -F "Decide the public API" | awk '{print $2}')
  render_terminal "$home" "$fakebin" --show "$decision_id" >/dev/null \
    || fail "new decision row expansion failed"
  after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-expansion newness render failed"
  decision_line=$(printf '%s\n' "$after" | grep -F "Decide the public API")
  assert_not_contains "$decision_line" "[NEW]" "expanded row remained new"
  assert_contains "$after" "PR 4001" "unexpanded changed row disappeared"
  printf '%s\n' "$after" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "expanding one row marked another row seen"
  pass "expansion marks only the selected row seen"
}

test_watch_expansion_acknowledges_new_row_during_forge_loading() {
  local home fakebin changed row_id row_number store metrics
  home=$(make_home watch-newness-ack)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"
  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "watch-newness baseline render failed"
  printf 'needs-decision [key=api-shape]: Choose the versioned public API shape.\n' \
    > "$home/state/decision-task.status"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "watch-newness changed render failed"
  row_id=$(printf '%s\n' "$changed" | grep -F "Decide the public API" | awk '{print $2}')
  row_number=$(printf '%s\n' "$changed" | grep -F "Decide the public API" | awk '{print $1}')
  [ -n "$row_id" ] && [ -n "$row_number" ] || fail "watch-newness row was not addressable"
  touch "$home/slow-github-fixture"

  metrics=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" "$row_id" "$row_number" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

dashboard, home, row_id, row_number = sys.argv[1:]
master, slave = pty.openpty()
monitor = os.dup(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "30",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "120",
    "FM_TEST_GITHUB_SLEEP_SECONDS": "4",
    "NO_COLOR": "1",
})
process = subprocess.Popen(
    [dashboard, "--watch", "--width", "80"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=environment,
)
os.close(slave)
output = bytearray()
selected_during_forge = False
deadline = time.monotonic() + 30
started = os.path.join(home, "github-refresh-started")
finished = os.path.join(home, "github-refresh-finished")
sent = False
while process.poll() is None and time.monotonic() < deadline:
    if select.select([master], [], [], 0.02)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
    if not sent and os.path.exists(started) and row_id.encode() in output and b"[NEW]" in output:
        os.write(master, row_number.encode() + b"\r")
        sent = True
    if sent and b"row id: " + row_id.encode() in output:
        selected_during_forge = not os.path.exists(finished)
        break
while not os.path.exists(finished) and time.monotonic() < deadline:
    if select.select([master], [], [], 0.02)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
if process.poll() is None:
    os.write(master, b"q")
exit_deadline = time.monotonic() + 3
while process.poll() is None and time.monotonic() < exit_deadline:
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
exit_code = process.wait(timeout=3)
os.close(master)
os.close(monitor)
print(f"selected_during_forge={int(selected_during_forge)}")
print(f"exit_code={exit_code}")
PY
  ) || fail "watch-newness PTY driver failed"
  assert_contains "$metrics" "selected_during_forge=1" \
    "NEW row was not expanded while forge data was still loading"
  assert_contains "$metrics" "exit_code=0" "watch-newness PTY did not exit cleanly"
  jq -e --arg id "$row_id" '.rows[$id].pending == false' "$store" >/dev/null \
    || fail "expansion during forge loading did not persist the seen marker"
  pass "watch expansion during forge loading persistently acknowledges a NEW row"
}

test_watch_keeps_forge_newness_visible_until_it_can_be_acknowledged() {
  local home fakebin changed row_id store pending_before metrics
  home=$(make_home watch-forge-newness-ack)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"
  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "forge-newness baseline render failed"
  touch "$home/ci-red-fixture"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "forge-newness changed render failed"
  row_id=$(printf '%s\n' "$changed" | grep -F "PR 4001" | awk '{print $2}')
  [ -n "$row_id" ] || fail "forge-derived NEW row was not addressable"
  pending_before=$(jq -c '[.rows | to_entries[] | select(.value.pending == true) | .key] | sort' "$store")
  touch "$home/slow-github-fixture"

  metrics=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" "$row_id" <<'PY'
import fcntl, json, os, pty, re, select, struct, subprocess, sys, termios, time

dashboard, home, row_id = sys.argv[1:]
master, slave = pty.openpty()
monitor = os.dup(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "30",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "120",
    "FM_TEST_GITHUB_SLEEP_SECONDS": "15",
    "NO_COLOR": "1",
})
process = subprocess.Popen(
    [dashboard, "--watch", "--all", "--width", "80"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=environment,
)
os.close(slave)
output = bytearray()
started = os.path.join(home, "github-refresh-started")
finished = os.path.join(home, "github-refresh-finished")
sent = False
back_sent = False
badge_stayed_visible = False
deadline = time.monotonic() + 60
while process.poll() is None and time.monotonic() < deadline:
    if select.select([master], [], [], 0.02)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
    latest_frame = bytes(output).rsplit(b"\x1b[H", 1)[-1].split(b"\x1b[J", 1)[0]
    if not sent and os.path.exists(started):
        row_line = next((line for line in latest_frame.splitlines() if row_id.encode() in line and b"[NEW]" in line), None)
        row_match = re.match(rb"\s*(\d+)\s", row_line or b"")
        if row_match:
            os.write(master, row_match.group(1) + b"\r")
            sent = True
    if sent and not back_sent and b"row id: " + row_id.encode() in latest_frame:
        output.clear()
        os.write(master, b"b")
        back_sent = True
    if back_sent and b"select: type row number" in latest_frame and b"PR 4001" in latest_frame:
        badge_stayed_visible = any(
            b"PR 4001" in line and b"[NEW]" in line
            for line in latest_frame.splitlines()
        )
        break
if process.poll() is None:
    os.write(master, b"q")
exit_deadline = time.monotonic() + 2
while process.poll() is None and time.monotonic() < exit_deadline:
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
exit_code = process.wait(timeout=3)
with open(os.path.join(home, "state", "fleet-dashboard-observations.json"), encoding="utf-8") as handle:
    store = json.load(handle)
pending_after = sorted(key for key, value in store["rows"].items() if value.get("pending") is True)
os.close(master)
os.close(monitor)
print(f"badge_stayed_visible={int(badge_stayed_visible)}")
print(f"selection_sent={int(sent)}")
print(f"back_sent={int(back_sent)}")
print(f"store_version={store.get('version')}")
print(f"pending_after={json.dumps(pending_after, separators=(',', ':'))}")
print(f"forge_still_loading={int(not os.path.exists(finished))}")
print(f"exit_code={exit_code}")
PY
  ) || fail "forge-newness PTY driver failed"
  printf '%s\n' "$metrics"
  assert_contains "$metrics" "badge_stayed_visible=1" \
    "forge-derived NEW badge flickered off after an acknowledgement the stale model could not persist"
  assert_contains "$metrics" "selection_sent=1" "forge-derived NEW row was not selected in the PTY"
  assert_contains "$metrics" "back_sent=1" "forge-derived NEW detail was not closed in the PTY"
  assert_contains "$metrics" "store_version=1" "loading-window acknowledgement changed the observation-store schema"
  assert_contains "$metrics" "pending_after=$pending_before" \
    "loading-window acknowledgement invented or silently ate a pending NEW marker"
  assert_contains "$metrics" "forge_still_loading=1" \
    "forge-newness assertion did not run inside the loading window"
  pass "forge-derived NEW stays visible until a revision-complete acknowledgement is possible"
}

test_watch_forge_refresh_has_a_deadline() {
  local home fakebin metrics
  home=$(make_home watch-forge-timeout)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  touch "$home/slow-github-fixture"
  metrics=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

dashboard, home = sys.argv[1:]
master, slave = pty.openpty()
monitor = os.dup(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "30",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "120",
    "FM_FLEET_FORGE_TIMEOUT_MS": "250",
    "FM_TEST_GITHUB_SLEEP_SECONDS": "4",
    "NO_COLOR": "1",
})
process = subprocess.Popen(
    [dashboard, "--watch", "--width", "80"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=environment,
)
os.close(slave)
output = bytearray()
timeout_seen = False
timeout_before_command_finished = False
q_latency_ms = None
deadline = time.monotonic() + 8
finished = os.path.join(home, "github-refresh-finished")
while process.poll() is None and time.monotonic() < deadline:
    if select.select([master], [], [], 0.02)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
    if b"forge refresh timed out" in output:
        timeout_seen = True
        timeout_before_command_finished = not os.path.exists(finished)
        break
if process.poll() is None:
    q_sent_at = time.monotonic()
    os.write(master, b"q")
    exit_deadline = q_sent_at + 1
    while process.poll() is None and time.monotonic() < exit_deadline:
        if select.select([master], [], [], 0.01)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
        time.sleep(0.01)
    q_latency_ms = (time.monotonic() - q_sent_at) * 1000
if process.poll() is None:
    process.kill()
exit_code = process.wait(timeout=3)
os.close(master)
os.close(monitor)
print(f"forge_timeout_seen={int(timeout_seen)}")
print(f"forge_timeout_before_command_finished={int(timeout_before_command_finished)}")
print(f"q_after_forge_timeout_latency_ms={q_latency_ms:.3f}" if q_latency_ms is not None else "q_after_forge_timeout_latency_ms=missing")
print(f"exit_code={exit_code}")
PY
  ) || fail "forge-timeout PTY driver failed"
  printf '%s\n' "$metrics"
  assert_contains "$metrics" "forge_timeout_seen=1" "wedged forge worker had no visible deadline"
  assert_contains "$metrics" "forge_timeout_before_command_finished=1" \
    "forge deadline did not settle before the blocked command"
  awk -F= '$1 == "q_after_forge_timeout_latency_ms" { found = 1; if ($2 >= 1000) exit 1 } END { if (!found) exit 1 }' \
    <<< "$metrics" || fail "timed-out forge worker kept the dashboard alive after q"
  assert_contains "$metrics" "exit_code=0" "q after a forge timeout did not exit cleanly"
  pass "watch forge refresh fails visibly at a bounded deadline"
}

test_unseen_newness_survives_a_watched_value_reverting() {
  local home fakebin out
  home=$(make_home newness-pending-reversion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness baseline render failed"
  touch "$home/ci-red-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "red CI render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "red CI did not become NEW"
  rm "$home/ci-red-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "reverted CI render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "rendering forgot an unseen CI change after the value reverted"
  pass "unseen newness survives watched-value reversion until expansion"
}

test_review_request_enrichment_drift_stays_quiet() {
  local home fakebin out
  home=$(make_home newness-review-request-drift)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "review-request baseline render failed"
  touch "$home/review-request-date-unknown-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "review-request enrichment-loss render failed"
  assert_not_contains "$out" "[NEW]" "request-date availability drift became a new review request"
  pass "review-request date enrichment drift stays quiet"
}

test_external_reviews_require_new_attributable_activity() {
  local home fakebin out
  home=$(make_home newness-external-review)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "external-review baseline render failed"
  touch "$home/unattributable-dismissal-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "dismissal render failed"
  assert_not_contains "$out" "[NEW]" "verdict-only dismissal was misattributed to the original reviewer"

  rm "$home/unattributable-dismissal-fixture"
  touch "$home/external-review-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "external-review activity render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "a newly submitted external review was not NEW"
  pass "only newly attributable external review activity becomes NEW"
}

test_external_thread_changes_require_an_external_actor() {
  local home fakebin out opening_home opening_fakebin reopen_home reopen_fakebin
  home=$(make_home newness-external-thread)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "external-thread baseline render failed"
  touch "$home/own-thread-resolution-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "own thread-resolution render failed"
  assert_not_contains "$out" "[NEW]" "our own thread resolution was treated as NEW"

  rm "$home/own-thread-resolution-fixture"
  touch "$home/external-thread-resolved-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "external thread-resolution render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "a thread resolved by someone else was not NEW"

  opening_home=$(make_home newness-external-thread-opened)
  write_live_fixture "$opening_home"
  opening_fakebin=$(make_fakebin "$opening_home")
  touch "$opening_home/no-thread-fixture"
  NO_COLOR=1 render_terminal "$opening_home" "$opening_fakebin" --width 80 --all >/dev/null \
    || fail "thread-opening baseline render failed"
  rm "$opening_home/no-thread-fixture"
  out=$(NO_COLOR=1 render_terminal "$opening_home" "$opening_fakebin" --width 80 --all) \
    || fail "external thread-opening render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "a thread opened by someone else was not NEW"

  reopen_home=$(make_home newness-unattributable-thread-reopen)
  write_live_fixture "$reopen_home"
  reopen_fakebin=$(make_fakebin "$reopen_home")
  touch "$reopen_home/external-thread-resolved-fixture"
  NO_COLOR=1 render_terminal "$reopen_home" "$reopen_fakebin" --width 80 --all >/dev/null \
    || fail "thread-reopen baseline render failed"
  rm "$reopen_home/external-thread-resolved-fixture"
  out=$(NO_COLOR=1 render_terminal "$reopen_home" "$reopen_fakebin" --width 80 --all) \
    || fail "unattributable thread-reopen render failed"
  assert_not_contains "$out" "[NEW]" "a thread reopen with no actor was misattributed to the opener"
  pass "external thread openings and resolutions become NEW while our own resolution stays quiet"
}

test_new_review_request_and_worker_failure_become_new() {
  local home fakebin out new_count
  home=$(make_home newness-request-failure)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "request-and-failure baseline render failed"
  touch "$home/new-review-request-fixture"
  printf 'failed: implementation worker crashed.\n' > "$home/state/review-task.status"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "request-and-failure changed render failed"
  new_count=$(printf '%s\n' "$out" | grep -F -o '[NEW]' | wc -l | tr -d ' ')
  [ "$new_count" = 2 ] || fail "new review request plus worker failure flagged $new_count rows"
  printf '%s\n' "$out" | grep -F "PR 942" | grep -F "[NEW]" >/dev/null \
    || fail "new review request was not NEW"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "worker failure was not NEW"
  pass "new review requests and worker failures become NEW"
}

test_terminal_review_relationship_surfaces_once_as_new() {
  local home fakebin out id after
  home=$(make_home newness-terminal-review)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "terminal-review baseline render failed"
  touch "$home/merged-review-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "merged-review render failed"
  printf '%s\n' "$out" | grep -F "r:912" | grep -F "[NEW]" >/dev/null \
    || fail "a newly merged review relationship did not surface as NEW"
  id=$(printf '%s\n' "$out" | grep -F "r:912" | awk '{print $2}')
  render_terminal "$home" "$fakebin" --show "$id" >/dev/null \
    || fail "merged-review expansion failed"
  after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-acknowledgement terminal-review render failed"
  assert_not_contains "$after" "r:912" "acknowledged terminal review relationship remained in the cockpit"
  pass "terminal review relationships surface once and retire after expansion"
}

test_completed_ours_surfaces_terminal_forge_change_once() {
  local home fakebin out id after
  home=$(make_home newness-terminal-ours)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "terminal-OURS baseline render failed"
  sed_in_place "$home/data/backlog.md" '/^- \[ \] review-task /d'
  sed_in_place "$home/data/backlog.md" '/^## Done$/a\
- [x] review-task - Ship the review branch (repo: artemis) (kind: ship) (reported 2026-08-02)
'
  rm "$home/state/review-task.meta" "$home/state/review-task.status"
  touch "$home/merged-ours-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "merged-OURS render failed"
  printf '%s\n' "$out" | grep -F "o:4001" | grep -F "[NEW]" >/dev/null \
    || fail "a completed OURS row did not preserve its newly merged forge event"
  id=$(printf '%s\n' "$out" | grep -F "o:4001" | awk '{print $2}')
  render_terminal "$home" "$fakebin" --show "$id" >/dev/null \
    || fail "merged-OURS expansion failed"
  after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-acknowledgement merged-OURS render failed"
  assert_not_contains "$after" "o:4001" "acknowledged merged OURS row remained in the cockpit"
  pass "completed OURS rows surface terminal forge changes once"
}

test_source_outages_do_not_erase_newness_baselines() {
  local home fakebin out
  home=$(make_home newness-source-outages)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "source-outage baseline render failed"
  touch "$home/review-request-outage-fixture"
  mv "$home/data/backlog.md" "$home/data/backlog.md.absent"
  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "source-outage render failed"
  rm "$home/review-request-outage-fixture"
  mv "$home/data/backlog.md.absent" "$home/data/backlog.md"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "source-recovery render failed"
  assert_not_contains "$out" "[NEW]" "source outage erased baselines and made unchanged rows NEW"
  pass "source outages preserve decision and review-request baselines"
}

test_stale_model_cannot_acknowledge_a_newer_pending_event() {
  local home fakebin out id store future
  home=$(make_home newness-stale-expansion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  store="$home/state/fleet-dashboard-observations.json"

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "stale-expansion baseline render failed"
  touch "$home/ci-red-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "stale-expansion changed render failed"
  id=$(printf '%s\n' "$out" | grep -F "PR 4001" | awk '{print $2}')
  future=$(( $(date +%s) * 1000 + 60000 ))
  jq --arg id "$id" --argjson future "$future" \
    '.rows[$id].pendingRevision.forge = $future' "$store" > "$store.tmp"
  mv "$store.tmp" "$store"
  render_terminal "$home" "$fakebin" --show "$id" >/dev/null \
    || fail "stale row expansion failed"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "post-stale-expansion render failed"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "a stale expansion cleared a newer pending event"
  pass "stale models cannot acknowledge newer pending events"
}

test_stale_observation_lock_recovery_is_serialized() {
  local home fakebin lock out1 out2 pid1 pid2
  home=$(make_home newness-stale-lock)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  lock="$home/state/.fleet-dashboard-observations.lock"
  mkdir "$lock"
  printf '{"pid":999999,"processStart":"definitely-not-the-current-process","token":"stale"}\n' \
    > "$lock/owner.json"

  render_terminal "$home" "$fakebin" --width 80 --all > "$home/out1" & pid1=$!
  render_terminal "$home" "$fakebin" --width 80 --all > "$home/out2" & pid2=$!
  wait "$pid1" || fail "first stale-lock contender failed"
  wait "$pid2" || fail "second stale-lock contender failed"
  out1=$(<"$home/out1")
  out2=$(<"$home/out2")
  assert_not_contains "$out1$out2" "[NEW]" "serialized stale-lock recovery produced false NEW rows"
  [ ! -e "$lock" ] || fail "observation lock remained after serialized recovery"
  [ ! -e "$home/state/.fleet-dashboard-observations-recovery.lock" ] \
    || fail "observation recovery lock remained after serialized recovery"
  pass "stale observation-lock recovery serializes concurrent contenders"
}

test_observation_store_is_private() {
  local home fakebin mode
  home=$(make_home newness-private-store)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "private-store baseline render failed"
  mode=$(file_mode "$home/state/fleet-dashboard-observations.json") \
    || fail "could not inspect observation-store mode"
  [ "$mode" = 600 ] || fail "observation store mode is $mode, expected 600"
  pass "observation store is private to the captain's account"
}

test_concurrent_expansions_preserve_both_acknowledgements() {
  local home fakebin baseline changed decision_id pr_id after new_count
  home=$(make_home newness-concurrent-expansion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "concurrent-expansion baseline render failed"
  baseline="$home/state/fleet-dashboard-observations.baseline.json"
  cp "$home/state/fleet-dashboard-observations.json" "$baseline"
  touch "$home/ci-red-fixture"
  printf 'needs-decision [key=api-shape]: Choose the versioned public API shape.\n' \
    > "$home/state/decision-task.status"
  changed=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "concurrent-expansion changed render failed"
  decision_id=$(printf '%s\n' "$changed" | grep -F "Decide the public API" | awk '{print $2}')
  pr_id=$(printf '%s\n' "$changed" | grep -F "PR 4001" | awk '{print $2}')

  for _ in 1 2; do
    cp "$baseline" "$home/state/fleet-dashboard-observations.json"
    render_terminal "$home" "$fakebin" --show "$decision_id" >/dev/null &
    local decision_pid=$!
    render_terminal "$home" "$fakebin" --show "$pr_id" >/dev/null &
    local pr_pid=$!
    wait "$decision_pid" || fail "concurrent decision expansion failed"
    wait "$pr_pid" || fail "concurrent PR expansion failed"
    after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
      || fail "post-concurrency render failed"
    new_count=$(printf '%s\n' "$after" | grep -F -o '[NEW]' | wc -l | tr -d ' ')
    [ "$new_count" = 0 ] || fail "concurrent expansion lost an acknowledgement ($new_count rows still NEW)"
  done
  pass "concurrent expansions preserve both row acknowledgements"
}

test_watched_field_change_flags_exactly_one_row() {
  local home fakebin out new_count
  home=$(make_home newness-watched-change)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness baseline render failed"
  touch "$home/ci-red-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "watched-field render failed"
  new_count=$(printf '%s\n' "$out" | grep -F -o '[NEW]' | wc -l | tr -d ' ')
  [ "$new_count" = 1 ] || fail "one CI outcome change flagged $new_count rows"
  printf '%s\n' "$out" | grep -F "PR 4001" | grep -F "[NEW]" >/dev/null \
    || fail "CI outcome change did not flag its own row"
  pass "a watched field change flags exactly its row"
}

test_excluded_events_never_flag_newness() {
  local home fakebin out
  home=$(make_home newness-exclusions)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness baseline render failed"
  [ -f "$home/state/fleet-dashboard-observations.json" ] \
    || fail "baseline render did not create the observation store"
  out=$(NO_COLOR=1 render_terminal_at "$home" "$fakebin" 2026-08-03T00:05:00Z --width 80 --all) \
    || fail "elapsed-time render failed"
  assert_not_contains "$out" "[NEW]" "elapsed time was treated as new"

  touch "$home/ci-running-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "in-progress render failed"
  assert_not_contains "$out" "[NEW]" "an in-progress check was treated as new"

  rm "$home/ci-running-fixture"
  printf 'working: implementation is still in progress.\n' > "$home/state/review-task.status"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "working-state render failed"
  assert_not_contains "$out" "[NEW]" "a run still in progress was treated as new"
  printf 'heartbeat: worker remains responsive.\n' >> "$home/state/review-task.status"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "heartbeat render failed"
  assert_not_contains "$out" "[NEW]" "a heartbeat was treated as new"

  touch "$home/own-review-fixture"
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "own-action render failed"
  assert_not_contains "$out" "[NEW]" "the authenticated viewer's own review was treated as new"
  pass "elapsed time, running work, heartbeats, and our own review stay quiet"
}

test_newness_render_fixture_can_be_inspected() {
  local home fakebin baseline changed html_path
  home=$(make_home newness-render)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all >/dev/null \
    || fail "newness visual baseline failed"
  touch "$home/ci-red-fixture"
  printf 'needs-decision [key=api-shape]: Choose the versioned public API shape.\n' \
    > "$home/state/decision-task.status"
  baseline="$TMP_ROOT/newness-width-130.txt"
  changed="$TMP_ROOT/newness-width-80.txt"
  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130 --all > "$baseline" \
    || fail "width-130 newness render failed"
  NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all > "$changed" \
    || fail "width-80 newness render failed"
  html_path="$TMP_ROOT/newness.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$html_path" >/dev/null || fail "newness HTML render failed"
  printf 'NEWNESS_RENDER_HOME=%s\nWIDTH_130=%s\nWIDTH_80=%s\nHTML=%s\n' \
    "$home" "$baseline" "$changed" "$html_path"
  printf '%s\n' '--- WIDTH 130 ---'
  cat "$baseline"
  printf '%s\n' '--- WIDTH 80 ---'
  cat "$changed"
}

write_empty_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
EOF
}

fingerprint_truth_records() {  # <home>
  local home=$1
  {
    [ -f "$home/data/backlog.md" ] && openssl dgst -sha256 "$home/data/backlog.md"
    find "$home/state" -maxdepth 1 -name '*.meta' -type f 2>/dev/null | sort | while IFS= read -r file; do
      openssl dgst -sha256 "$file"
    done
    find "$home/data" "$home/state" \( -iname '*hold*' -o -name 'backlog.md' \) -type f 2>/dev/null | sort | while IFS= read -r file; do
      openssl dgst -sha256 "$file"
    done
  }
}

assert_peace_omits_other_health() {  # <output>
  local out=$1
  assert_not_contains "$out" "needs you" "peace section invented a needs-you count"
  assert_not_contains "$out" "lanes:" "peace section invented a lanes line"
  assert_not_contains "$out" "problems:" "peace section invented a problems line"
  assert_not_contains "$out" "ATTENTION NOW" "peace section projected the attention recap"
  assert_not_contains "$out" "DECISIONS" "peace section listed decisions"
  assert_not_contains "$out" "BUILDING" "peace section listed building work"
  assert_not_contains "$out" "https://" "peace section printed a URL"
}

peace_digest_total() {  # <home>
  local home=$1
  FM_HOME="$home" /bin/bash -c \
    '. "$1/fm-backend.sh" && . "$1/fm-pr-lib.sh" && . "$1/fm-record-contradictions-lib.sh" && fm_record_contradictions_total "$2" "$3"' \
    peace-digest-total "$ROOT/bin" "$home/data" "$home/state"
}

write_peace_gh_axi() {  # <fakebin>
  cat > "$1/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.1.29'; exit 0 ;;
  api)
    case "${2:-}" in
      /repos/example/repo/pulls/9)
        printf '%s\n' 'api_response:' '  body: "MERGED:UNKNOWN"' '  truncated: false'
        ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/gh-axi"
}

test_peace_records_disagree_one_ghost() {
  local home fakebin before after out
  home=$(make_home peace-ghost)
  write_empty_backlog "$home"
  fm_write_meta "$home/state/ghost-task.meta" "kind=ship"
  fakebin=$(make_fakebin "$home")
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on a ghost-meta fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: disagree (1 ghost, 0 stranded)" \
    "one meta-without-backlog did not light the truth lamp"
  assert_not_contains "$out" "ghost-task" "peace section named the ghost id"
  assert_peace_omits_other_health "$out"
  pass "peace records disagree for one ghost meta and no stranded row"
}

test_peace_records_no_meta_is_digest_not_stranded() {
  local home fakebin before after out
  home=$(make_home peace-no-meta)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] stranded-task - Stranded in-flight work (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home")
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on a no-meta in-flight fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: disagree (1 ghost, 0 stranded)" \
    "a no-meta in-flight row was double-counted or left the lamp dark"
  assert_not_contains "$out" "stranded-task" "peace section named the no-meta id"
  assert_peace_omits_other_health "$out"
  pass "no-meta in-flight work is a digest finding, not a stranded row"
}

test_peace_records_disagree_one_stranded() {
  local home fakebin before after out
  home=$(make_home peace-stranded)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] stranded-task - Stranded in-flight work (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/stranded-task.meta" "kind=ship"
  printf 'failed: worker finished without advancing the backlog row\n' \
    > "$home/state/stranded-task.status"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'liveness: absent · source: fixture\n'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    FM_CREW_STATE_OVERRIDE="$fakebin/fm-crew-state.sh" \
    "$DASHBOARD" --section peace) \
    || fail "peace section failed on an unadvanceable fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: disagree (0 ghost, 1 stranded)" \
    "one finished worker still in flight did not light the truth lamp"
  assert_not_contains "$out" "stranded-task" "peace section named the stranded id"
  assert_not_contains "$out" "Stranded in-flight work" "peace section named the stranded title"
  assert_peace_omits_other_health "$out"
  pass "peace records disagree for one stranded row and no digest finding"
}

test_peace_records_count_every_digest_kind() {
  local home fakebin before after out expected
  home=$(make_home peace-all-kinds)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] missing-meta - In-flight work without metadata (repo: firstmate) (kind: ship)
- [ ] held-flight - Held in-flight work (repo: firstmate) (kind: ship) (hold: wait) (hold-kind: parked)
- [ ] closed-pr - Recorded pull request that is no longer open (repo: firstmate) (kind: ship)

## Queued

## Done
- [x] complete-meta - Completed work with live metadata (repo: firstmate) (kind: ship)
EOF
  fm_write_meta "$home/state/ghost-meta.meta" "kind=ship"
  fm_write_meta "$home/state/complete-meta.meta" \
    "window=firstmate:fm-complete-meta" \
    "kind=ship"
  printf 'done: leftover completion event\n' > "$home/state/complete-meta.status"
  fm_write_meta "$home/state/held-flight.meta" "kind=ship"
  fm_write_meta "$home/state/closed-pr.meta" \
    "kind=ship" \
    "pr=https://github.com/example/repo/pull/9"
  printf 'resolved: archival candidate\n' > "$home/state/stale-orphan.status"
  touch -t 202608010000 "$home/state/stale-orphan.status"
  fakebin=$(make_fakebin "$home")
  write_peace_gh_axi "$fakebin"
  expected=$(PATH="$fakebin:$PATH" peace_digest_total "$home")
  [ "$expected" -ge 4 ] || fail "all-kinds fixture produced only $expected digest findings"
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on a multi-kind digest fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  # The closed-pr row's leftover metadata has no live worktree, so the
  # centralized worker-liveness verdict resolves it to absent and the
  # unadvanceable-work detector counts that one row as stranded.
  assert_contains "$out" "records: disagree ($expected ghost, 1 stranded)" \
    "the lamp did not project the digest owner's total"
  assert_peace_omits_other_health "$out"
  pass "peace records count every digest kind the owner reports"
}

test_peace_ghost_count_is_the_owners_total_not_its_displayed_entries() {
  local home fakebin before after out digest id
  home=$(make_home peace-over-cap)
  write_empty_backlog "$home"
  # Five metas of one kind: past the digest's per-kind display cap of 3, so the
  # owner's total (5) and anything derived from its printed entries (3) differ.
  for id in ghost-1 ghost-2 ghost-3 ghost-4 ghost-5; do
    fm_write_meta "$home/state/$id.meta" "kind=ship"
  done
  fakebin=$(make_fakebin "$home")
  digest=$(PATH="$fakebin:$PATH" FM_HOME="$home" /bin/bash -c \
    '. "$1/fm-backend.sh" && . "$1/fm-pr-lib.sh" && . "$1/fm-record-contradictions-lib.sh" && fm_record_contradictions_render "$2" "$3"' \
    peace-digest-render "$ROOT/bin" "$home/data" "$home/state")
  assert_contains "$digest" "+2 more" \
    "the fixture no longer exceeds the digest's display cap"
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on an over-cap digest fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: disagree (5 ghost, 0 stranded)" \
    "the lamp did not project the owner's machine-readable total"
  assert_not_contains "$out" "3 ghost" \
    "the lamp counted the digest's displayed entries instead of its total"
  assert_peace_omits_other_health "$out"
  pass "the ghost count is the owner's total, not its displayed entries"
}

test_peace_records_agree_on_clean_fixture() {
  local home fakebin before after out
  home=$(make_home peace-clean)
  write_empty_backlog "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/github-called"
echo "unexpected GitHub call in peace section" >&2
exit 97
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/quota-called"
echo "unexpected quota call in peace section" >&2
exit 98
SH
  # gh-axi is reachable from peace: the digest half queries every meta that
  # records a PR. With no such meta it must stay unqueried.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/gh-axi-called"
exit 97
SH
  chmod +x "$fakebin/gh" "$fakebin/quota-axi" "$fakebin/gh-axi"
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on a clean fixture"
  [ ! -e "$home/github-called" ] || fail "peace section ran the cockpit's GitHub fetch"
  [ ! -e "$home/quota-called" ] || fail "peace section ran the cockpit's quota fetch"
  [ ! -e "$home/gh-axi-called" ] || fail "peace section queried a PR that no metadata records"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: agree" "clean records did not report agree"
  assert_not_contains "$out" "disagree" "clean records invented a disagreement"
  assert_not_contains "$out" "ghost" "clean records invented a ghost count"
  assert_not_contains "$out" "stranded" "clean records invented a stranded count"
  assert_peace_omits_other_health "$out"
  pass "peace records agree on a clean fixture and invent no other health"
}

test_peace_records_ignore_blocked_worker() {
  local home fakebin before after out
  home=$(make_home peace-blocked)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] blocked-task - Blocked worker with live records (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  mkdir -p "$home/projects/blocked-task"
  fm_write_meta "$home/state/blocked-task.meta" \
    "window=firstmate:fm-blocked-task" \
    "worktree=$home/projects/blocked-task" \
    "kind=ship"
  printf 'blocked [key=wait]: Waiting on an external dependency.\n' \
    > "$home/state/blocked-task.status"
  fakebin=$(make_fakebin "$home")
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section failed on a blocked-worker fixture"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: agree" \
    "a blocked worker with live meta and a current backlog row lit the truth lamp"
  assert_not_contains "$out" "disagree" "a blocked worker was treated as a record contradiction"
  assert_not_contains "$out" "blocked-task" "peace section named the blocked worker"
  assert_peace_omits_other_health "$out"
  pass "a blocked worker with matching records does not light the truth lamp"
}

test_peace_keeps_the_ghost_half_without_a_backlog_backend() {
  local home fakebin before after out
  home=$(make_home peace-manual-backend)
  write_empty_backlog "$home"
  fm_write_meta "$home/state/ghost-task.meta" "kind=ship"
  printf 'manual\n' > "$home/config/backlog-backend"
  fakebin=$(make_fakebin "$home")
  before=$(fingerprint_truth_records "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section died with the strandedness instrument unavailable"
  after=$(fingerprint_truth_records "$home")
  [ "$before" = "$after" ] || fail "peace render wrote backlog, metadata, or holds"
  assert_contains "$out" "records: disagree (1 ghost, stranded unknown)" \
    "an unreadable strandedness instrument took the ghost half down with it"
  assert_peace_omits_other_health "$out"
  pass "an unreadable strandedness instrument still reports the ghost half"
}

test_peace_degrades_when_the_ghost_instrument_is_unavailable() {
  local home fakebin broken_bin out err rc
  home=$(make_home peace-ghost-unavailable)
  write_empty_backlog "$home"
  fakebin=$(make_fakebin "$home")
  broken_bin="$home/bin"
  cp -R "$(dirname "$DASHBOARD")" "$broken_bin"
  rm "$broken_bin/fm-record-contradictions-lib.sh"
  set +e
  out=$(NO_COLOR=1 PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$broken_bin/fm-fleet-dashboard.mjs" --section peace 2>"$TMP_ROOT/peace-ghost-unavailable.err")
  rc=$?
  set -e
  err=$(cat "$TMP_ROOT/peace-ghost-unavailable.err")
  [ "$rc" -eq 0 ] || fail "peace section failed with the ghost instrument unavailable (rc=$rc): $err"
  assert_contains "$out" "records: unknown (ghost unknown, 0 stranded)" \
    "an unavailable ghost instrument did not degrade alone on the records value"
  assert_not_contains "$out" "records: agree" \
    "an unavailable ghost instrument was reported as agreement"
  assert_not_contains "$out" "stranded unknown" \
    "an unavailable ghost instrument took the answering strandedness half down with it"
  assert_contains "$err" "ghost unknown" \
    "peace degraded without naming the unavailable ghost instrument"
  assert_contains "$err" "fm-record-contradictions-lib.sh" \
    "peace discarded the ghost instrument's own reason for being unavailable"
  pass "peace degrades when the ghost instrument is unavailable"
}

test_peace_ranks_a_stranded_finding_above_an_unavailable_ghost_half() {
  local home fakebin broken_bin out err rc
  home=$(make_home peace-ghost-unavailable-stranded)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] stranded-task - Stranded in-flight work (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/stranded-task.meta" "kind=ship"
  printf 'failed: worker finished without advancing the backlog row\n' \
    > "$home/state/stranded-task.status"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'liveness: absent · source: fixture\n'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  broken_bin="$home/bin"
  cp -R "$(dirname "$DASHBOARD")" "$broken_bin"
  rm "$broken_bin/fm-record-contradictions-lib.sh"
  set +e
  out=$(NO_COLOR=1 PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    FM_CREW_STATE_OVERRIDE="$fakebin/fm-crew-state.sh" \
    "$broken_bin/fm-fleet-dashboard.mjs" --section peace \
    2>"$TMP_ROOT/peace-ghost-unavailable-stranded.err")
  rc=$?
  set -e
  err=$(cat "$TMP_ROOT/peace-ghost-unavailable-stranded.err")
  [ "$rc" -eq 0 ] || fail "peace section failed with a stranded row and no ghost instrument (rc=$rc): $err"
  assert_contains "$out" "records: disagree (ghost unknown, 1 stranded)" \
    "a stranded finding did not outrank the unavailable ghost half"
  assert_not_contains "$out" "records: unknown" \
    "an unavailable ghost half buried the answering stranded finding as unknown"
  assert_not_contains "$out" "stranded-task" "peace section named the stranded id"
  assert_peace_omits_other_health "$out"
  pass "a stranded finding outranks unknown when the ghost half cannot run"
}

test_peace_never_reads_an_unavailable_instrument_as_agreement() {
  local home fakebin out
  home=$(make_home peace-manual-backend-clean)
  write_empty_backlog "$home"
  printf 'manual\n' > "$home/config/backlog-backend"
  fakebin=$(make_fakebin "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace) \
    || fail "peace section died with the strandedness instrument unavailable"
  assert_contains "$out" "records: unknown (0 ghost, stranded unknown)" \
    "peace did not report the unreadable strandedness instrument as unknown"
  assert_not_contains "$out" "agree" \
    "an unreadable strandedness instrument was reported as agreement"
  assert_peace_omits_other_health "$out"
  pass "an unreadable strandedness instrument never reads as agreement"
}

test_peace_names_the_reason_an_instrument_could_not_run() {
  local home fakebin out err
  home=$(make_home peace-degraded-reason)
  write_empty_backlog "$home"
  fm_write_meta "$home/state/ghost-task.meta" "kind=ship"
  printf 'manual\n' > "$home/config/backlog-backend"
  fakebin=$(make_fakebin "$home")
  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --section peace 2>"$TMP_ROOT/peace-degraded.err") \
    || fail "peace section died with the strandedness instrument unavailable"
  err=$(cat "$TMP_ROOT/peace-degraded.err")
  assert_contains "$out" "records: disagree (1 ghost, stranded unknown)" \
    "the degraded records line changed"
  assert_not_contains "$out" "backlog backend" \
    "the degradation diagnostic leaked onto the records line"
  assert_peace_omits_other_health "$out"
  assert_contains "$err" "stranded unknown" \
    "peace degraded to unknown without naming it on stderr"
  assert_contains "$err" "tasks-axi backlog backend is disabled or incompatible" \
    "peace discarded the instrument's own reason for being unavailable"
  pass "an unavailable instrument names its reason on stderr, not on the records line"
}

test_watch_peace_refetches_github_on_the_slow_cadence() {
  local home fakebin out calls probes
  home=$(make_home peace-watch)
  write_empty_backlog "$home"
  fm_write_meta "$home/state/closed-pr.meta" \
    "kind=ship" \
    "window=firstmate:fm-closed-pr" \
    "pr=https://github.com/example/repo/pull/9"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.1.29'; exit 0 ;;
  api)
    printf '%s\n' "${2:-}" >> "$FM_HOME/gh-axi-calls"
    printf '%s\n' 'api_response:' '  body: "MERGED:UNKNOWN"' '  truncated: false'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  touch "$home/count-local-frames"

  out=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" <<'PY'
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

dashboard, home = sys.argv[1:]
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "1",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "600",
    "NO_COLOR": "1",
})

master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
process = subprocess.Popen(
    [dashboard, "--watch", "--section", "peace", "--width", "80"],
    stdin=slave_fd,
    stdout=slave_fd,
    stderr=slave_fd,
    close_fds=True,
    env=environment,
)
os.close(slave_fd)

output = bytearray()


def pump():
    readable, _, _ = select.select([master_fd], [], [], 0)
    if not readable:
        return
    try:
        chunk = os.read(master_fd, 65536)
    except OSError:
        return
    if chunk:
        output.extend(chunk)


def backend_probes():
    try:
        with open(os.path.join(home, "tmux-calls"), encoding="utf-8") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


# Every local frame re-probes the recorded backend, so backend probes witness
# frames. Hold the loop open until enough have run that several fast frames
# demonstrably elapsed, so a slow machine cannot pass this by completing one.
deadline = time.monotonic() + 40
while time.monotonic() < deadline and process.poll() is None and backend_probes() < 8:
    pump()
    time.sleep(0.01)
observed_probes = backend_probes()
if process.poll() is None:
    os.write(master_fd, b"q")
exit_deadline = time.monotonic() + 5
while process.poll() is None and time.monotonic() < exit_deadline:
    pump()
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
process.wait(timeout=5)
pump()
os.close(master_fd)

print(f"backend_probes={observed_probes}")
print(output.decode("utf-8", "replace"))
PY
  ) || fail "watch peace run failed"

  probes=$(printf '%s\n' "$out" | sed -n 's/^backend_probes=\([0-9][0-9]*\)$/\1/p' | sed -n '1p')
  [ -n "$probes" ] && [ "$probes" -ge 8 ] \
    || fail "watch never ran enough fast local frames to prove a cadence: got '${probes:-none}' probes"
  calls=$(wc -l < "$home/gh-axi-calls" 2>/dev/null | tr -d '[:space:]')
  [ -n "$calls" ] || calls=0
  [ "$calls" -eq 1 ] \
    || fail "watch peace issued $calls GitHub PR calls across $probes backend probes; expected 1"
  assert_contains "$out" "records: disagree" \
    "throttling the peace refresh dropped the data the lamp needs"
  pass "watch peace keeps the lamp lit while refetching GitHub on the slow cadence"
}

test_watch_peace_holds_its_diagnostic_until_the_screen_is_restored() {
  local home fakebin out before_teardown after_teardown
  home=$(make_home peace-watch-diagnostic)
  write_empty_backlog "$home"
  fm_write_meta "$home/state/ghost-task.meta" \
    "kind=ship" \
    "window=firstmate:fm-ghost-task"
  printf 'manual\n' > "$home/config/backlog-backend"
  fakebin=$(make_fakebin "$home")
  touch "$home/count-local-frames"

  # The terminal control stream is the contract under test: everything the
  # dashboard paints before the alternate screen is torn down lands on the live
  # frame, everything after it lands on the restored screen.
  out=$(PATH="$fakebin:$PATH" python3 - "$DASHBOARD" "$home" <<'PY'
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

dashboard, home = sys.argv[1:]
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_SNAPSHOT_NOW": "2026-08-02T00:05:00Z",
    "FM_FLEET_WATCH_LOCAL_SECONDS": "1",
    "FM_FLEET_WATCH_GITHUB_SECONDS": "1",
    "NO_COLOR": "1",
})

master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
process = subprocess.Popen(
    [dashboard, "--watch", "--section", "peace", "--width", "80"],
    stdin=slave_fd,
    stdout=slave_fd,
    stderr=slave_fd,
    close_fds=True,
    env=environment,
)
os.close(slave_fd)

output = bytearray()


def pump():
    readable, _, _ = select.select([master_fd], [], [], 0)
    if not readable:
        return
    try:
        chunk = os.read(master_fd, 65536)
    except OSError:
        return
    if chunk:
        output.extend(chunk)


def backend_probes():
    try:
        with open(os.path.join(home, "tmux-calls"), encoding="utf-8") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


# The refresh cadence is 1s here, so several degraded collects run before quit.
deadline = time.monotonic() + 40
while time.monotonic() < deadline and process.poll() is None and backend_probes() < 8:
    pump()
    time.sleep(0.01)
if process.poll() is None:
    os.write(master_fd, b"q")
exit_deadline = time.monotonic() + 5
while process.poll() is None and time.monotonic() < exit_deadline:
    pump()
    time.sleep(0.01)
if process.poll() is None:
    process.kill()
process.wait(timeout=5)
pump()
os.close(master_fd)

stream = output.decode("utf-8", "replace")
teardown = "[?1049l"
index = stream.rfind(teardown)
print(f"teardown_seen={int(index >= 0)}")
print("---BEFORE-TEARDOWN---")
print(stream if index < 0 else stream[:index])
print("---AFTER-TEARDOWN---")
print("" if index < 0 else stream[index + len(teardown):])
PY
  ) || fail "watch peace diagnostic run failed"

  assert_contains "$out" "teardown_seen=1" "watch never restored the normal screen"
  before_teardown=${out%%---AFTER-TEARDOWN---*}
  after_teardown=${out#*---AFTER-TEARDOWN---}
  assert_contains "$before_teardown" "records: disagree (1 ghost, stranded unknown)" \
    "the degraded lamp stopped rendering in watch mode"
  assert_not_contains "$before_teardown" "fm-fleet-dashboard: stranded unknown:" \
    "the degradation diagnostic painted over the live watch frame"
  assert_contains "$after_teardown" "fm-fleet-dashboard: stranded unknown:" \
    "watch dropped the reason the lamp does not know"
  assert_contains "$after_teardown" "tasks-axi backlog backend is disabled or incompatible" \
    "watch surfaced a diagnostic without the instrument's own reason"
  pass "watch holds the stranded-unknown reason until the screen is restored"
}

if [ -n "${FM_DASHBOARD_TEST_ONLY:-}" ]; then
  "$FM_DASHBOARD_TEST_ONLY"
  exit
fi

test_shareable_html_omits_unstructured_manual_scripts_by_default
test_obligation_round_uses_viewer_review_history_or_stays_unknown
test_our_pr_ids_keep_the_pr_number_through_an_engineered_collision
test_registered_ours_are_fetched_before_capped_optional_urls
test_cockpit_shows_action_sections_and_full_inventory
test_pr_truthfulness_regressions
test_review_relationships_survive_completed_rounds
test_followup_review_without_round_history_stays_unknown
test_numberless_review_record_never_invents_a_waiting_party
test_decision_projection_labels_answered_and_aged_open_holds
test_clean_list_uses_truthful_markers_and_priority_order
test_default_rows_are_one_line_with_a_fresh_recap
test_expansion_includes_evidence_derived_recommendation
test_show_expands_rows_with_full_context
test_absent_sources_and_unreachable_reviews_stay_honest
test_html_page_renders_minimal_sections_with_reachable_detail
test_section_selector_renders_intention_views_and_rejects_unknown
test_peace_records_disagree_one_ghost
test_peace_records_no_meta_is_digest_not_stranded
test_peace_records_disagree_one_stranded
test_peace_records_count_every_digest_kind
test_peace_ghost_count_is_the_owners_total_not_its_displayed_entries
test_peace_records_agree_on_clean_fixture
test_peace_records_ignore_blocked_worker
test_peace_keeps_the_ghost_half_without_a_backlog_backend
test_peace_degrades_when_the_ghost_instrument_is_unavailable
test_peace_ranks_a_stranded_finding_above_an_unavailable_ghost_half
test_peace_never_reads_an_unavailable_instrument_as_agreement
test_peace_names_the_reason_an_instrument_could_not_run
test_watch_peace_refetches_github_on_the_slow_cadence
test_watch_peace_holds_its_diagnostic_until_the_screen_is_restored
test_help_describes_the_fixed_terminal_measure
test_watch_flag_needs_a_terminal_and_stays_exclusive
test_watch_paints_and_accepts_input_during_forge_refresh
test_watch_redraw_clears_detail_tails_and_narrower_frames
test_watch_does_not_claim_a_github_check_without_github_work
test_ignored_operational_directories_are_never_output_targets
test_default_screen_defers_non_actionable_rows_without_losing_full_inventory
test_default_slots_prioritize_new_rows_and_name_hidden_reviews
test_readable_ids_survive_colliding_rows_and_support_prefix_lookup
test_detail_contract_uses_report_evidence_and_slow_quota_without_fabrication
test_review_obligations_are_distinct_and_oldest_first
test_decision_ids_bind_task_key_and_verb_across_membership_changes
test_registered_pr_number_comes_from_registered_url
test_first_newness_run_seeds_without_flagging_rows
test_corrupt_observation_store_reseeds_silently
test_empty_observation_store_reseeds_silently
test_identical_newness_render_stays_quiet_and_does_not_mark_seen
test_expansion_marks_only_the_selected_row_seen
test_watch_expansion_acknowledges_new_row_during_forge_loading
test_watch_keeps_forge_newness_visible_until_it_can_be_acknowledged
test_watch_forge_refresh_has_a_deadline
test_watched_field_change_flags_exactly_one_row
test_excluded_events_never_flag_newness
test_unseen_newness_survives_a_watched_value_reverting
test_review_request_enrichment_drift_stays_quiet
test_external_reviews_require_new_attributable_activity
test_external_thread_changes_require_an_external_actor
test_new_review_request_and_worker_failure_become_new
test_terminal_review_relationship_surfaces_once_as_new
test_completed_ours_surfaces_terminal_forge_change_once
test_source_outages_do_not_erase_newness_baselines
test_stale_model_cannot_acknowledge_a_newer_pending_event
test_stale_observation_lock_recovery_is_serialized
test_observation_store_is_private
test_concurrent_expansions_preserve_both_acknowledgements
