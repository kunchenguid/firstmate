#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: build the page from a tiny fixture
# home through the real script (and the real fleet snapshot), then read the
# page's visible text the way a person would, and over `serve`.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The page's visible text, one space between words.
page_text() {  # <page>
  python3 - "$1" <<'PY'
import html, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'<(style|title)>.*?</\1>', ' ', s, flags=re.S)
print(re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', s))))
PY
}

when() {  # <hours ago> -> UTC ISO time and the local day it falls on
  python3 -c 'import sys; from datetime import datetime, timedelta, timezone as z
t = datetime.now(z.utc) - timedelta(hours=float(sys.argv[1]))
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"), t.astimezone().date())' "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1" now_ts today y_ts tab
  tab=$(printf '\t')
  read -r now_ts today < <(when 0)
  read -r y_ts _ < <(when 24)
  mkdir -p "$home/data/metrics" "$home/state" "$home/config" "$home/projects/wt"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] alpha-fix - Fix the alpha thing (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] beta-next - Start the beta thing (repo: alpha) (kind: ship)

## Done
- [x] gamma-done - Landed gamma https://example.invalid/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-10)
EOF
  fm_write_meta "$home/state/alpha-fix.meta" "window=firstmate:fm-alpha-fix" "worktree=$home/projects/wt" \
    "project=alpha" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: building\n' > "$home/state/alpha-fix.status"
  sed "s/|/$tab/g" > "$home/data/metrics/prs.tsv" <<EOF
home|pr|created|merged|hours_to_merge|first_pass|escaped
alpha|1|$now_ts|$now_ts|1.0|1|0
alpha|2|$now_ts|$now_ts|2.0|1|0
alpha|3|$now_ts|$now_ts|3.0|0|0
beta|4|$y_ts|$y_ts|4.0|0|0
EOF
  sed "s/|/$tab/g" > "$home/data/metrics/daily.tsv" <<EOF
day|home|steers|s_correct|stall_alarms|self_rings|relaunches|skill_reads
$today|alpha|4|1|2|0|1|7
$today|beta|0|0|0|0|0|5
EOF
  sed "s/|/$tab/g" > "$home/data/metrics/skills.tsv" <<EOF
day|home|skill|reads
$today|alpha|verify-alpha|7
$today|beta|pre-review-check|5
EOF
  # A pulse file whose header predates its later columns, as long-lived ones do.
  sed "s/|/$tab/g" > "$home/data/fleet-pulse.tsv" <<EOF
time|home|merged2h|working|paused|blocked
${today}T01:00|alpha|0|1|0|0|5|3|2|1.5|10|0|900
${today}T01:00|beta|0|1|0|0|2|1|1|0.4|5|0|900
EOF
  sed "s/|/$tab/g" > "$home/config/metrics-targets.tsv" <<'EOF'
# metric|op|target|owner|rule
first_pass|>=|70|each home|prove before PR
stall_alarms|<=|0|each home|watcher wakes idle leads
EOF
  # A registered home with no metrics rows at all, under a made-up name.
  mkdir -p "$home/mates/zephyrine/data"
  printf -- '- quillwork [direct-PR] - made-up project (added 2026-07-11)\n' > "$home/mates/zephyrine/data/projects.md"
  printf -- '- zephyrine - made-up domain (home: %s; scope: made-up work; projects: other; added 2026-07-11)\n' \
    "$home/mates/zephyrine" > "$home/data/secondmates.md"
  printf -- '- alpha [no-mistakes] - fixture project (added 2026-07-11)\n' > "$home/data/projects.md"
  printf '%s\n' "$home"
}

test_the_page_answers_the_questions_with_the_fixture_numbers() {
  local home page text out want
  home=$(make_home full)
  out=$(FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  page="$home/state/dashboard/index.html"
  [ "$out" = "$page" ] || fail "build did not print the page path: $out"
  ! grep -Eq '<script|https?://[^"]*\.(css|js)' "$page" || fail "page is not self-contained"
  text=$(page_text "$page")
  for want in "Running now 1" "Finished, not landed 3" "Merged today 3 yesterday 1" "Queued and ready 4" \
    "Not automatic yet: 2 lead stalls reached Main" "12 skill reads today" "verify-alpha 7" \
    "First-pass merges 50%" "Fix the alpha thing" "Start the beta thing" "Landed gamma" \
    "Projects: quillwork" "Main" "Projects: alpha"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  ! grep -q '<details open' "$page" || fail "a work list starts open"
  grep -q '<h3>zephyrine</h3>' "$page" || fail "a registered home with no metrics rows has no card"
  grep -q 'class="q bad"><span>First-pass merges' "$page" || fail "a missed first-pass target is not marked as a miss"
  pass "the page answers the questions with the fixture's numbers"
}

green_pr() {  # <home> <task> <url>: a fresh observed open PR with green checks the captain could merge
  mkdir -p "$1/data/$2"
  jq -n --arg task "$2" --arg url "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",state:"open",draft:false,mergeable:"mergeable",
        review_decision:"",can_merge:true,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$1/data/$2/contributions.json"
}

test_totals_count_only_work_that_waits() {
  local home page text out want
  home=$(make_home live)
  # alpha-fix's own record names its project, so its PR resolves to alpha whatever the repo is called.
  printf -- '- alpha [no-mistakes +yolo] - fixture project (added 2026-07-11)\n- delta [direct-PR] - fixture project (added 2026-07-11)\n' \
    > "$home/data/projects.md"
  green_pr "$home" alpha-fix https://github.com/o/alpha-repo/pull/11
  green_pr "$home" delta-pr https://github.com/o/delta/pull/12
  green_pr "$home" ghost-pr https://github.com/o/ghost/pull/13
  printf '# parked by the captain\nbeta\n' > "$home/config/parked-homes"
  mkdir -p "$home/mates/alpha/data"
  printf -- '- alpha - fixture domain (home: %s; scope: fixture; projects: alpha; added 2026-07-11)\n' \
    "$home/mates/alpha" >> "$home/data/secondmates.md"
  # The home's flow check reports two finished lanes for every home it is asked about.
  cat > "$home/config/fm-flow-check.sh" <<'EOF'
#!/bin/sh
[ -d "$1/data" ] || exit 1
printf 'x\t3\t1\t0\t2\t0\t-1\n'
EOF
  chmod +x "$home/config/fm-flow-check.sh"
  out=$(FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  page="$home/state/dashboard/index.html"
  text=$(page_text "$page")
  for want in "Waiting on you 2 2 merge approvals, 0 decisions" "delta-pr main Merge approval ghost-pr main Merge approval" \
    "Finished, not landed 6 waiting to merge Merged today" "Merged today 3 yesterday 0" \
    "Queued and ready 3" "of 6 open lanes" "beta Parked"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  ! grep -q 'pull/11' "$page" || fail "a green PR in a +yolo project waits on the captain: $text"
  grep -q '<h3>beta</h3><span class="chip ">Parked</span></div></div>' "$page" || fail "the parked home card shows numbers"
  pass "totals leave out parked homes and self-merged PRs, and count finished lanes now"
}

SERVE_PID=
trap '[ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null; fm_test_cleanup' EXIT

test_serve_answers_the_page_and_nothing_else() {
  local home url got
  home=$(make_home served)
  FM_HOME="$home" "$DASH" serve --port 0 > "$home/serve.out" 2> "$home/serve.err" &
  SERVE_PID=$!
  for _ in $(seq 1 100); do
    url=$(sed -n 's/^serving //p' "$home/serve.out")
    [ -n "$url" ] && break
    kill -0 "$SERVE_PID" 2>/dev/null || fail "serve exited: $(cat "$home/serve.err")"
    sleep 0.1
  done
  [ -n "$url" ] || fail "serve never reported its address: $(cat "$home/serve.err")"
  case "$url" in http://127.0.0.1:*/) ;; *) fail "serve did not default to loopback: $url" ;; esac
  got=$(python3 - "$url" <<'PY'
import sys, urllib.request, urllib.error
def get(u):
    try:
        with urllib.request.urlopen(u, timeout=60) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, ''
code, body = get(sys.argv[1])
print(code, 'Merged today' in body and 'Fleet dashboard' in body)
for path in ('state/', 'index.html/..', '../data/metrics/prs.tsv', 'data/metrics/prs.tsv'):
    print(get(sys.argv[1] + path)[0])
PY
)
  [ "$got" = "$(printf '200 True\n404\n404\n404\n404')" ] || fail "serve answers were not page-then-404s: $got"
  # An old page is answered at once, as it is, while a rebuild runs behind it.
  printf '<p>old page<!--age--></p>\n' > "$home/state/dashboard/index.html"
  touch -d '-5 minutes' "$home/state/dashboard/index.html"
  got=$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$url")
  case "$got" in *"old page · updated 3"[0-9][0-9]" s ago · refreshing"*) ;; *) fail "an old page was not answered at once: $got" ;; esac
  for _ in $(seq 1 600); do grep -q 'old page' "$home/state/dashboard/index.html" || break; sleep 0.1; done
  grep -q 'Fleet dashboard' "$home/state/dashboard/index.html" || fail "the background rebuild did not replace the old page"
  kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
  pass "serve returns the page with 200 at once, rebuilds an old one behind it, and 404s every other path"
}

test_missing_or_malformed_sources_hide_only_their_part() {
  local home page text out
  home=$(make_home partial)
  rm "$home/data/metrics/skills.tsv" "$home/data/fleet-pulse.tsv"
  printf 'nonsense\n1\n' > "$home/data/metrics/daily.tsv"
  printf 'alpha\n' >> "$home/data/metrics/prs.tsv"  # a cut-off appended line
  # A broken snapshot bound makes the fleet snapshot itself exit non-zero.
  out=$(FM_HOME="$home" FM_BEARINGS_LANDED=0 "$DASH" build 2>&1) || fail "a missing source failed the build: $out"
  page="$home/state/dashboard/index.html"
  text=$(page_text "$page")
  for want in "data/metrics/skills.tsv : not found" "data/fleet-pulse.tsv : not found" \
    "data/metrics/daily.tsv : malformed" "data/metrics/prs.tsv : 1 short row(s) skipped" "fleet snapshot exited 2: fm-bearings-snapshot: FM_BEARINGS_LANDED must be a positive integer" "Merged today 3 yesterday 1"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  case "$text" in *"Running now"*) fail "snapshot tile shown without a snapshot: $text" ;; esac
  pass "missing or malformed sources hide only their own part and never fail the build"
}

test_the_page_answers_the_questions_with_the_fixture_numbers
test_totals_count_only_work_that_waits
test_missing_or_malformed_sources_hide_only_their_part
test_serve_answers_the_page_and_nothing_else
