#!/usr/bin/env bash
# Behavior tests for the Linear mirror: the backlog parser (fm-backlog-tsv.sh),
# the PR linker (fm-linear-pr-link.sh) and its fm-pr-check.sh hook, and the
# in-place refresh (fm-linear-refresh.sh).
#
# The contract these pin, in priority order:
#   1. Linear NEVER gates delivery. Unconfigured, unreachable, unauthenticated,
#      slow, or simply missing an issue, the PR check still records the PR, arms
#      the merge poll, and exits 0.
#   2. The PR body edit is strictly additive and idempotent.
#   3. Refresh updates matched issues in place, creates only new ids, and only
#      REPORTS ids that left the backlog.
#
# The network is stubbed with a fakebin `curl` that answers per GraphQL
# operation name, so these stay hermetic: no ports, no server, deterministic in
# CI. jq stays the real tool. Live verification against the real Linear API is
# recorded in docs/linear.md.
#
# The single-quoted fixtures below contain literal backticks and GraphQL-shaped
# text, not shell expansions.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-linear-tests)

# A fakebin `curl` standing in for Linear's GraphQL endpoint. It extracts the
# operation name from the posted query, writes $FAKE_DIR/<op>.json to the -o
# file, prints $FAKE_DIR/<op>.code (default 200), and appends the operation plus
# its variables to $FAKE_DIR/calls.log. A missing fixture is a 500 with no body,
# which is how "Linear did not answer" is simulated.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=/dev/null data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -m|-w|-X|-H) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
op=$(printf '%s' "$data" | jq -r '.query' 2>/dev/null \
  | sed -n 's/^[[:space:]]*\(query\|mutation\)[[:space:]]\{1,\}\([A-Za-z0-9_]*\).*/\2/p' | head -n1)
printf '%s\t%s\n' "$op" "$(printf '%s' "$data" | jq -c '.variables' 2>/dev/null)" >> "$FAKE_DIR/calls.log"
if [ -n "${FAKE_CURL_FAIL:-}" ]; then exit 7; fi
if [ -f "$FAKE_DIR/$op.json" ]; then
  cat "$FAKE_DIR/$op.json" > "$ofile"
  if [ -f "$FAKE_DIR/$op.code" ]; then cat "$FAKE_DIR/$op.code"; else echo 200; fi
else
  : > "$ofile"
  echo 500
fi
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# A fakebin `gh` that serves a PR body from $FAKE_DIR/pr-body and records an
# edit by overwriting that file, so a second run sees the first run's result -
# which is what makes the idempotency test real rather than assumed.
make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh.log"
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${FAKE_GH_VIEW_FAIL:-}" ] || { echo "gh: pr view refused" >&2; exit 1; }
    cat "$FAKE_DIR/pr-body"
    ;;
  "pr edit")
    [ -z "${FAKE_GH_EDIT_FAIL:-}" ] || { echo "gh: pr edit refused" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "$FAKE_DIR/pr-body"; shift 2 ;; *) shift ;; esac
    done
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
}

# Set up a home with state/, an .env, and a fresh fake-fixture dir, then export
# the environment the stubs read. It assigns HOME_DIR directly rather than
# printing it, because the exports have to land in the caller's shell.
new_home() {
  local name=$1 fakebin
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/fake"
  fakebin=$(make_fake_curl "$HOME_DIR")
  make_fake_gh "$fakebin"
  export FAKE_DIR="$HOME_DIR/fake"
  : > "$FAKE_DIR/calls.log"
  : > "$FAKE_DIR/gh.log"
  export PATH="$fakebin:$BASE_PATH"
  unset FAKE_CURL_FAIL FAKE_GH_VIEW_FAIL FAKE_GH_EDIT_FAIL
}

issue_json() {
  # issue_json <identifier> <description-first-line> [state-type]
  jq -cn --arg ident "$1" --arg desc "$2" --arg st "${3:-backlog}" \
    '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
        {id:"uuid-\($ident)", identifier:$ident, url:"https://linear.app/x/issue/\($ident)",
         title:"t", description:$desc, state:{name:"Backlog", type:$st},
         team:{id:"team-uuid", key:"PSY"}}]}}}'
}

run_link() { "$ROOT/bin/fm-linear-pr-link.sh" "$@" 2>&1; }

# --- 1. inert without a key -------------------------------------------------

new_home inert
: > "$HOME_DIR/.env"
out=$(FM_HOME="$HOME_DIR" run_link demo-a1 https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unconfigured linker exits 0"
assert_contains "$out" "no LINEAR_API_KEY configured" "unconfigured linker says what did not happen"
[ ! -s "$FAKE_DIR/calls.log" ] || fail "unconfigured linker must not touch the network"
[ ! -s "$FAKE_DIR/gh.log" ] || fail "unconfigured linker must not touch the PR"
pass "no LINEAR_API_KEY: the linker is a hard no-op that exits 0"

# --- 2. no mirrored issue is the normal case, not an error ------------------

new_home nomatch
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'body from the pipeline\n' > "$FAKE_DIR/pr-body"
jq -cn '{data:{issues:{nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 070-unmirrored https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "missing issue exits 0"
assert_contains "$out" "no mirrored issue for 070-unmirrored" "missing issue is reported plainly"
assert_no_grep "pr edit" "$FAKE_DIR/gh.log" "missing issue must not edit the PR"
pass "no mirrored issue: reported, PR untouched, exit 0"

# --- 3. a mirrored issue gets a strictly additive reference -----------------

new_home match
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf '## Evidence\n\n- review: pass\n- tests: pass\n' > "$FAKE_DIR/pr-body"
cp "$FAKE_DIR/pr-body" "$HOME_DIR/body.before"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`

body' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "successful link exits 0"
assert_contains "$out" "linked PSY-42" "the link is reported"
assert_contains "$out" "Part of PSY-42" "the appended reference is named"
assert_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "the magic-word line reached the PR body"
assert_grep "<!-- firstmate:linear -->" "$FAKE_DIR/pr-body" "the marker reached the PR body"
before_bytes=$(wc -c < "$HOME_DIR/body.before")
head -c "$before_bytes" "$FAKE_DIR/pr-body" | cmp -s - "$HOME_DIR/body.before" \
  || fail "the edit was not a pure append: the original body bytes changed"
pass "mirrored issue: the reference is appended and the original body survives byte-for-byte"

# --- 4. idempotent: running the check twice links exactly once ---------------

out2=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "second run exits 0"
assert_contains "$out2" "already referenced" "the second run reports it left the body alone"
n=$(grep -c 'Part of PSY-42' "$FAKE_DIR/pr-body")
[ "$n" = 1 ] || fail "expected exactly one reference after two runs, found $n"
n=$(grep -c 'pr edit' "$FAKE_DIR/gh.log")
[ "$n" = 1 ] || fail "expected exactly one PR edit across two runs, found $n"
pass "running the PR check twice adds the reference exactly once"

# A body that merely MENTIONS the identifier is not linked: Linear needs a magic
# word. Treating a bare mention as "already linked" would silently skip exactly
# the PRs that discuss their own issue - this feature's own PR among them.
new_home baremention
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'This PR is described in docs; see PSY-42 for background.\n' > "$FAKE_DIR/pr-body"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "linked PSY-42" "a bare mention must not be mistaken for an existing link"
assert_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "the reference is still appended over a bare mention"

# A magic word already present IS a link, whoever wrote it, so leave it alone.
printf 'Fixes PSY-42 in passing.\n' > "$FAKE_DIR/pr-body"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "already referenced" "a magic word already in the body counts as linked"
assert_no_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "no second reference is appended"

# The documented list form counts too.
printf 'Fixes ENG-1, DES-5 and PSY-42 together.\n' > "$FAKE_DIR/pr-body"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "already referenced" "a multi-issue magic-word list counts as linked"
pass "only a magic word counts as an existing link; a bare mention does not"

# --- 5. Linear unreachable never blocks anything ----------------------------

new_home unreachable
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'pipeline body\n' > "$FAKE_DIR/pr-body"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unreachable Linear still exits 0"
assert_contains "$out" "lookup unavailable" "an unreachable Linear is reported as unavailable"
assert_contains "$out" "PR unaffected" "the operator is told the PR was not touched"
assert_no_grep "pr edit" "$FAKE_DIR/gh.log" "an unreachable Linear must not edit the PR"
pass "Linear unreachable: reported, PR untouched, exit 0"

# An authenticated-but-refusing Linear (HTTP 401) takes the same path.
echo 401 > "$FAKE_DIR/fmFind.code"
jq -cn '{errors:[{message:"Authentication required"}]}' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unauthenticated Linear still exits 0"
assert_contains "$out" "lookup unavailable" "an unauthenticated Linear is reported as unavailable"
pass "Linear unauthenticated: reported, PR untouched, exit 0"

# A gh that refuses the edit is equally non-fatal.
new_home ghfail
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'pipeline body\n' > "$FAKE_DIR/pr-body"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FAKE_GH_EDIT_FAIL=1 FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "a refused PR edit still exits 0"
assert_contains "$out" "could not update the PR body" "a refused edit is reported"
pass "gh refusing the edit: reported, exit 0"

# --- 6. the join is the first line, exactly ---------------------------------

new_home strictjoin
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'body\n' > "$FAKE_DIR/pr-body"
# The server-side "contains" filter is deliberately loose; the client-side match
# is not. An issue that merely mentions the marker further down is not the join.
issue_json PSY-99 'Some other issue

see also `firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "no mirrored issue" "a marker below the first line is not a join"
# A longer id must not be matched by its prefix.
issue_json PSY-98 '`firstmate: 004-engine-surface-testers`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 004 https://github.com/o/r/pull/1)
assert_contains "$out" "no mirrored issue for 004" "a prefix of a longer id is not a join"
# A plain first line without backticks still joins.
issue_json PSY-97 'firstmate: 004' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 004 https://github.com/o/r/pull/1)
assert_contains "$out" "linked PSY-97" "a backtick-free first line still joins"
pass "the join is the description's first line and an exact id match"

# --- 7. fm-pr-check.sh keeps working regardless -----------------------------

new_home prcheck
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
fm_write_meta "$HOME_DIR/state/t1.meta" "window=fm-t1" "worktree=$HOME_DIR"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/o/r/pull/9 2>&1); rc=$?
expect_code 0 "$rc" "fm-pr-check exits 0 with Linear down"
assert_contains "$out" "armed: state/t1.check.sh" "the merge poll is still armed"
assert_contains "$out" "linear: lookup unavailable" "the Linear outcome is reported to the operator"
assert_grep "pr=https://github.com/o/r/pull/9" "$HOME_DIR/state/t1.meta" "the PR is still recorded in meta"
assert_present "$HOME_DIR/state/t1.check.sh" "the check shim is still written"
pass "fm-pr-check: records the PR and arms the poll even when Linear is down"

out=$(FM_LINEAR_DISABLE=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/o/r/pull/9 2>&1)
assert_contains "$out" "disabled by FM_LINEAR_DISABLE" "the kill switch is honoured"
pass "FM_LINEAR_DISABLE turns the Linear step off without touching the rest of the check"

# --- 8. the backlog parser --------------------------------------------------

new_home parse
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] 061-alpha - Do the alpha thing (repo: firstmate) (kind: ship) (since 2026-08-02)
  a note line
  another note line

## Queued
- [ ] 014-axifiable-backlog - Standing list of axify candidates at data/axifiable.md; review when new surface (since 2026-07-31)
- [ ] 016-beta - Wire beta blocked-by: 028-spine (since 2026-07-31) (hold: captain must (really) choose) (hold-kind: captain)

## Done
- [x] 011-gamma - Harden the gamma https://github.com/o/r/pull/38 blocked-by: 028-spine (merged 2026-08-02)
- [x] 060-delta - Scout the delta data/060-delta/report.md (reported 2026-08-02)
MD
cat > "$HOME_DIR/data/done-archive.md" <<'MD'
## Archived 2026-07-31
- [x] 001-ancient - An old shipped thing https://github.com/o/r/pull/2 (merged 2026-07-30)
MD
tsv=$("$ROOT/bin/fm-backlog-tsv.sh" "$HOME_DIR/data/backlog.md" "$HOME_DIR/data/done-archive.md")
printf '%s\n' "$tsv" > "$HOME_DIR/parsed.tsv"
assert_grep "in_flight	061-alpha	Do the alpha thing" "$HOME_DIR/parsed.tsv" "in-flight annotations are stripped from the title"
assert_grep "queued	014-axifiable-backlog	Standing list of axify candidates at data/axifiable.md; review when new surface" \
  "$HOME_DIR/parsed.tsv" "a path inside the sentence survives, only a trailing link is stripped"
assert_grep "done	011-gamma	Harden the gamma	https://github.com/o/r/pull/38	028-spine" \
  "$HOME_DIR/parsed.tsv" "a Done PR URL and its blocked-by are extracted"
assert_grep "done	060-delta	Scout the delta	data/060-delta/report.md" \
  "$HOME_DIR/parsed.tsv" "a scout report path is extracted"
assert_grep "done	001-ancient" "$HOME_DIR/parsed.tsv" "the pruned archive is read too"
assert_grep "queued	016-beta	Wire beta" "$HOME_DIR/parsed.tsv" "a hold reason containing parentheses is cut whole"
[ "$(printf '%s\n' "$tsv" | wc -l)" = 6 ] || fail "expected 6 parsed items, got $(printf '%s\n' "$tsv" | wc -l)"
[ "$(printf '%s\n' "$tsv" | awk -F'\t' '$2=="061-alpha"{print $6}')" = 'a note line\nanother note line' ] \
  || fail "the indented note block was not captured with escaped newlines"
pass "the backlog parser reads every item form, both files, and strips only trailing bookkeeping"

# --- 9. refresh updates in place ---------------------------------------------

new_home refresh
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] 010-known - Known and already mirrored (repo: p) blocked-by: 028-spine
- [ ] 099-brandnew - Never mirrored before (repo: p)

## Done
- [x] 011-shipped - Shipped thing https://github.com/o/r/pull/38 (merged 2026-08-02)
MD
: > "$HOME_DIR/data/done-archive.md"
# Linear already holds 010-known (with a stale title), 011-shipped (still open),
# and 555-retired, which has left the backlog.
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"u1",identifier:"PSY-7",url:"l/7",title:"stale title",description:"`firstmate: 010-known`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u2",identifier:"PSY-8",url:"l/8",title:"Shipped thing",description:"`firstmate: 011-shipped`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u3",identifier:"PSY-9",url:"l/9",title:"gone",description:"`firstmate: 555-retired`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}}]}}}' > "$FAKE_DIR/fmList.json"
jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[
  {id:"s-backlog",name:"Backlog",type:"backlog",position:0},
  {id:"s-done",name:"Done",type:"completed",position:3}]}}]}}}' > "$FAKE_DIR/fmTeam.json"
jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmUpdate.json"
jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmState.json"
jq -cn '{data:{attachmentLinkURL:{success:true}}}' > "$FAKE_DIR/fmAttach.json"
jq -cn '{data:{issueCreate:{success:true,issue:{id:"u-new",identifier:"PSY-50"}}}}' > "$FAKE_DIR/fmCreate.json"

out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 0 "$rc" "refresh exits 0"
assert_contains "$out" "created 1, updated 2" "one create for the new id, updates for the two matched ids"
assert_contains "$out" "moved to Done 1" "the shipped item is transitioned"
assert_contains "$out" "PR links 1" "the shipped item carries its PR"
assert_contains "$out" "REPORTED ONLY, nothing was deleted" "retired ids are reported, not deleted"
assert_contains "$out" "555-retired" "the retired id is named"
n=$(grep -c '^fmCreate' "$FAKE_DIR/calls.log")
[ "$n" = 1 ] || fail "expected exactly 1 create, got $n"
grep -q '^fmCreate.*099-brandnew' "$FAKE_DIR/calls.log" || fail "the create was not for the genuinely new id"
# 010-known has a blocked-by but NO link: an empty middle TSV column must not
# shift later fields left. If it did, the body would land in "Blocked by" and
# the blocker id in "Delivered", silently corrupting a real issue.
sent=$(grep '^fmUpdate' "$FAKE_DIR/calls.log" | cut -f2 | jq -r 'select(.d | test("010-known")) | .d')
assert_contains "$sent" "**Blocked by:** 028-spine" "the blocked-by lands in the Blocked by line"
assert_not_contains "$sent" "**Delivered:**" "an item with no recorded link gets no Delivered line"
grep -q "555-retired" "$FAKE_DIR/gh.log" 2>/dev/null && fail "a retired id must never trigger an action"
pass "refresh: updates matched issues in place, creates only new ids, reports retired ids"

# Running it again against a Linear that now reflects the first run must be a
# no-op: this is the property that stops a second refresh doubling the board.
# The second fixture is built from the titles and descriptions the FIRST run
# actually sent, so this is a real feedback loop rather than a hand-written
# guess at what convergence looks like.
jq -s --slurpfile ids <(jq -cn '[{k:"010-known",i:"u1",d:"PSY-7"},{k:"011-shipped",i:"u2",d:"PSY-8"},{k:"099-brandnew",i:"u-new",d:"PSY-50"}]') '
  [ .[] | select(.ti and .d) ] as $sent
  | {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},
      nodes:[ $sent[] as $s
        | ($s.d | split("\n")[0] | gsub("`"; "") | ltrimstr("firstmate: ")) as $key
        | ($ids[0][] | select(.k == $key)) as $m
        | {id:$m.i, identifier:$m.d, url:"l", title:$s.ti, description:$s.d,
           state:{name:(if $key == "011-shipped" then "Done" else "Backlog" end),
                  type:(if $key == "011-shipped" then "completed" else "backlog" end)},
           team:{id:"team-uuid", key:"PSY"}} ]}}}' \
  <(grep -E '^fm(Update|Create)' "$FAKE_DIR/calls.log" | cut -f2 | jq -c '.') \
  > "$FAKE_DIR/fmList.json"
: > "$FAKE_DIR/calls.log"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1)
assert_contains "$out" "created 0, updated 0, unchanged 3" "a converged refresh changes nothing"
n=$(grep -c '^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not create anything, got $n creates"
n=$(grep -c '^fmUpdate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not update anything, got $n updates"
n=$(grep -c '^fmAttach\|^fmAttachCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not attach anything, got $n attachment calls"
pass "refresh is convergent: a second run against its own result performs no mutations"

# A successful HTTP/GraphQL exchange can still carry a rejected mutation.
# That item is failed, while later items continue reconciling normally.
new_home refreshreject
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] 010-rejected - Linear rejects this update (repo: p)
- [ ] 011-continues - This update must still run (repo: p)
MD
: > "$HOME_DIR/data/done-archive.md"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"u1",identifier:"PSY-7",url:"l/7",title:"stale",description:"`firstmate: 010-rejected`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u2",identifier:"PSY-8",url:"l/8",title:"stale",description:"`firstmate: 011-continues`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}}]}}}' > "$FAKE_DIR/fmList.json"
jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[]}}]}}}' > "$FAKE_DIR/fmTeam.json"
jq -cn '{data:{issueUpdate:{success:false}}}' > "$FAKE_DIR/fmUpdate.json"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 4 "$rc" "a rejected mutation makes refresh incomplete"
assert_contains "$out" "FAILED    PSY-7" "a success:false mutation is reported as failed"
assert_contains "$out" "FAILED    PSY-8" "refresh continues after the first rejected mutation"
assert_contains "$out" "updated 0" "rejected mutations are not counted as updates"
assert_contains "$out" "failed 2" "rejected mutations contribute to the failed tally"
n=$(grep -c '^fmUpdate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 2 ] || fail "expected both updates to be attempted after rejection, got $n"
pass "refresh treats success:false as failure and continues remaining items"

# --- 10. refresh degrades quietly -------------------------------------------

new_home refreshdown
: > "$HOME_DIR/.env"
mkdir -p "$HOME_DIR/data"; printf '# Backlog\n' > "$HOME_DIR/data/backlog.md"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 0 "$rc" "unconfigured refresh exits 0"
assert_contains "$out" "refresh did not run" "unconfigured refresh says what did not happen"

printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 3 "$rc" "unreachable refresh reports a distinct exit code"
assert_contains "$out" "refresh did not run" "unreachable refresh says what did not happen"
pass "refresh degrades quietly when Linear is unconfigured or unreachable"

printf '\nall linear tests passed\n'
