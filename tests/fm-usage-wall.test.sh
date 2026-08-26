#!/usr/bin/env bash
# tests/fm-usage-wall.test.sh - behavior tests for bin/fm-usage-wall.sh, the
# provider-usage-wall surface.
#
# The defect this command exists to prevent is a usage limit being read as a
# crash, so the cases below are weighted toward the ways that misreading
# happens rather than toward the happy path:
#
#   headroom
#     (a) a measurable provider reports its percent, bounding window, reset and
#         runway
#     (b) tight by percent, tight by runway, and exhausted are distinguishable
#         from ok
#     (c) EVERY unmeasurable path - quota-axi absent, erroring, hanging,
#         printing no effective block, or reporting auth_required - reports
#         `unknown` and is never reported as healthy
#     (d) the auth_required line names the one-time operator command
#     (e) the reading survives upstream reordering or adding fields, because it
#         is resolved by field name out of the block's own header
#     (f) a below-floor quota-axi still yields a reading, labelled as such
#     (g) credentials are never prompted for: --allow-keychain-prompt is never
#         passed
#
#   diagnose
#     (h) a vendor limit line in the endpoint output is a `wall`
#     (i) a vendor limit line in a failed step's log is a `wall`, which is where
#         the 2026-08-23 evidence actually was
#     (j) transient transport wording (HTTP 429, "rate limited") is NOT a wall
#     (k) a clean read is `no-signature`, an unreadable one is `unknown`, and a
#         cheap endpoint-only scan that finds nothing is `unknown` rather than a
#         clean bill of health
#
#   resume
#     (l) a record is generated from live durable state and is readable back
#         from a separate process after the generating one exits
#     (m) it carries merge posture, branch, head and pipeline custody
#     (n) two tasks sharing one local copy are named on both rows
#     (o) a failed generation leaves the previous record intact
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WALL="$ROOT/bin/fm-usage-wall.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-wall)
fm_git_identity

# --- fixtures ---------------------------------------------------------------

# quota_toon <mode>: a quota-axi default-TOON report. The `effective[7]{...}`
# header deliberately reproduces the vendor's own quirk of declaring a count
# that does not match its field list, so the parser is pinned against the real
# shape rather than a tidied one.
quota_toon() {  # <healthy|tight-pct|tight-runway|exhausted|auth|no-effective|reordered>
  case "$1" in
    no-effective)
      cat <<'EOF'
bin: /fake/quota-axi
providers[1]{provider,plan,source,status,authStatus,refreshedAt}:
  claude,max,oauth,fresh,unknown,none
windows[1]{provider,id,label,percentRemaining,resetsAt,pace,state}:
  claude,five_hour,session,84,"2026-08-27T02:19:59Z",ahead,fresh
EOF
      return 0
      ;;
    reordered)
      # Same facts, different field order, plus an unknown extra field.
      cat <<'EOF'
bin: /fake/quota-axi
providers[1]{authStatus,provider,plan,source,status,refreshedAt}:
  unknown,claude,max,oauth,fresh,none
windows[1]{resetsAt,provider,id,label,percentRemaining,pace,state}:
  "2026-08-27T02:19:59Z",claude,five_hour,session,84,ahead,fresh
effective[7]{someNewField,scope,provider,limitingWindowId,effectivePercentRemaining,usableRunwaySeconds,runway,projectionConfidence}:
  ignored,all_models,claude,five_hour,84,14400,projected_exhaustion,early
EOF
      return 0
      ;;
  esac
  local pct=84 runway=14400 cursor_row='  cursor,unresolved,unknown,unknown,unknown,unknown,unknown'
  case "$1" in
    tight-pct) pct=12 ;;
    tight-runway) pct=90; runway=600 ;;
    exhausted) pct=0 ;;
  esac
  printf 'bin: /fake/quota-axi\n'
  printf 'providers[2]{provider,plan,source,status,authStatus,refreshedAt}:\n'
  printf '  claude,max,oauth,fresh,unknown,none\n'
  if [ "$1" = auth ]; then
    printf '  cursor,unknown,unavailable,auth_required,unknown,none\n'
  else
    printf '  cursor,pro,oauth,fresh,unknown,none\n'
  fi
  printf 'windows[2]{provider,id,label,percentRemaining,resetsAt,pace,state}:\n'
  printf '  claude,five_hour,session,%s,"2026-08-27T02:19:59Z",ahead,fresh\n' "$pct"
  printf '  claude,seven_day,week,92,"2026-09-02T07:59:59Z",on_pace,fresh\n'
  printf 'effective[7]{provider,scope,effectivePercentRemaining,boundedBy,limitingWindowId,runway,usableRunwaySeconds,projectionConfidence}:\n'
  printf '  claude,all_models,%s,"five_hour + seven_day",five_hour,projected_exhaustion,%s,early\n' "$pct" "$runway"
  if [ "$1" = auth ]; then
    printf '%s\n' "$cursor_row"
  else
    printf '  cursor,all_models,77,seven_day,seven_day,projected_exhaustion,20000,early\n'
  fi
}

# fake_quota <fakebin> <mode> [version] [argv-log]
fake_quota() {
  local fb=$1 mode=$2 version=${3:-0.1.40} argv=${4:-}
  mkdir -p "$fb"
  quota_toon "$mode" > "$fb/.quota-report"
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
[ -n "$argv" ] && printf 'headroom-probe %s\n' "\$*" >> "$argv"
if [ "\${1:-}" = --version ]; then printf '%s\n' "$version"; exit 0; fi
cat "$fb/.quota-report"
SH
  chmod +x "$fb/quota-axi"
}

fake_quota_failing() {  # <fakebin> <exit-code>
  local fb=$1 code=$2
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '0.1.40\n'; exit 0; fi
printf 'quota-axi: no provider could be read\n' >&2
exit $code
SH
  chmod +x "$fb/quota-axi"
}

fake_quota_hanging() {  # <fakebin>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.1.40\n'; exit 0; fi
sleep 30
SH
  chmod +x "$fb/quota-axi"
}

run_headroom() {  # <fakebin> [args...]
  local fb=$1
  shift
  ( PATH="$fb:$PATH" "$WALL" headroom "$@" 2>&1 )
}

# --- headroom: a measurable provider ---------------------------------------

CASE="$TMP_ROOT/hr-healthy"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'a measurable provider reports ok with its percent'
assert_contains "$OUT" 'bound=five_hour' 'the reading names the bounding window'
assert_contains "$OUT" 'resets=2026-08-27T02:19:59Z' 'the reading names when the bounding window resets'
assert_contains "$OUT" 'runway=4h0m' 'the reading converts usable runway to whole units'
assert_contains "$OUT" 'confidence=early' 'the reading carries the projection confidence'
assert_contains "$OUT" 'verdict=ok measured=2 tight=0 wall=0 unknown=0' 'all-measured all-ok summarizes as ok'
assert_not_contains "$OUT" 'HEADROOM_NOTE' 'a fully measured healthy fleet needs no unmeasured warning'
pass 'headroom reports a measurable provider with window, reset and runway'

# --- headroom: tight and exhausted are distinguishable ----------------------

CASE="$TMP_ROOT/hr-tight-pct"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" tight-pct
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude tight pct=12' 'a low percent reads tight'
assert_contains "$OUT" 'verdict=tight' 'a tight provider makes the summary tight'
assert_contains "$OUT" 'HEADROOM_NEXT' 'a tight reading names the resume record as the next step'
pass 'headroom labels a low percent tight'

CASE="$TMP_ROOT/hr-tight-runway"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" tight-runway
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude tight pct=90' 'a short runway reads tight even at a high percent'
assert_contains "$OUT" 'runway=10m' 'the short runway itself is shown'
pass 'headroom labels a short runway tight independently of percent'

CASE="$TMP_ROOT/hr-exhausted"; mkdir -p "$CASE"
OUT=$(fake_quota "$CASE/fakebin" exhausted; run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude wall pct=0' 'an exhausted window reads as a wall'
pass 'headroom distinguishes an exhausted window from a merely tight one'

# --- headroom: every unmeasurable path reads unknown ------------------------

CASE="$TMP_ROOT/hr-absent"; mkdir -p "$CASE/fakebin"
OUT=$( PATH="$CASE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'unknown reason=quota-axi is not installed' 'an absent gauge reports why it is unmeasurable'
assert_contains "$OUT" 'verdict=unknown' 'an absent gauge summarizes as unknown'
assert_contains "$OUT" 'UNMEASURED, not healthy' 'an absent gauge is explicitly not healthy'
assert_not_contains "$OUT" ' ok ' 'an absent gauge never reports ok'
pass 'headroom reports an absent quota-axi as unknown, never as healthy'

CASE="$TMP_ROOT/hr-error"; mkdir -p "$CASE"
fake_quota_failing "$CASE/fakebin" 3
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'unknown reason=quota-axi exited 3' 'a failing gauge names its exit status'
assert_contains "$OUT" 'verdict=unknown' 'a failing gauge summarizes as unknown'
pass 'headroom reports a failing quota-axi as unknown'

CASE="$TMP_ROOT/hr-hang"; mkdir -p "$CASE"
fake_quota_hanging "$CASE/fakebin"
OUT=$( PATH="$CASE/fakebin:$PATH" FM_USAGE_WALL_QUOTA_TIMEOUT=1 "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'did not answer within 1s' 'a hanging gauge is bounded and named'
assert_contains "$OUT" 'verdict=unknown' 'a hanging gauge summarizes as unknown'
pass 'headroom bounds a hanging quota-axi and reports unknown'

CASE="$TMP_ROOT/hr-noeff"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" no-effective
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'unknown reason=quota-axi printed no effective-headroom block' \
  'a report without derived headroom is unmeasurable, not inferred from raw windows'
assert_not_contains "$OUT" 'pct=84' 'a raw window percent is never presented as effective headroom'
pass 'headroom refuses to infer headroom from raw windows alone'

# --- headroom: auth_required is unknown, with the one-time command ----------

CASE="$TMP_ROOT/hr-auth"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" auth
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: cursor unknown reason=auth-required' 'a provider needing auth reads unknown'
assert_contains "$OUT" 'quota-axi --allow-keychain-prompt' 'the unknown line names the one-time operator command'
assert_contains "$OUT" 'HEADROOM: claude ok' 'one unmeasurable provider does not blank a measurable one'
assert_contains "$OUT" 'verdict=partial measured=1 tight=0 wall=0 unknown=1' \
  'a mixed fleet summarizes as partial, distinguishable from both ok and unknown'
assert_contains "$OUT" 'UNMEASURED, not healthy' 'a partial fleet still warns that unknown is not healthy'
pass 'headroom reports auth_required as unknown and names the fix'

# --- headroom: never prompts for credentials --------------------------------

CASE="$TMP_ROOT/hr-noprompt"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" auth 0.1.40 "$CASE/argv.log"
run_headroom "$CASE/fakebin" >/dev/null
assert_present "$CASE/argv.log" 'the gauge was invoked'
assert_grep 'headroom-probe' "$CASE/argv.log" 'the recorded argv is the real invocation, not an empty file'
assert_no_grep '--allow-keychain-prompt' "$CASE/argv.log" \
  'headroom must never trigger the blocking credential prompt itself'
pass 'headroom never passes --allow-keychain-prompt'

# --- headroom: resolved by field name, not column position ------------------

CASE="$TMP_ROOT/hr-reordered"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" reordered
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'a reordered report still yields the same percent'
assert_contains "$OUT" 'bound=five_hour' 'a reordered report still yields the same bounding window'
assert_contains "$OUT" 'runway=4h0m' 'a reordered report still yields the same runway'
pass 'headroom survives upstream field reordering and additions'

# --- headroom: a below-floor build still yields a reading -------------------

CASE="$TMP_ROOT/hr-floor"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy 0.0.1
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'an older but working build still produces a reading'
assert_contains "$OUT" 'build=below-floor' 'the reading discloses that the build is below the shared floor'
pass 'headroom reports a below-floor build rather than blanking its reading'

# --- headroom --json --------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  CASE="$TMP_ROOT/hr-json"; mkdir -p "$CASE"
  fake_quota "$CASE/fakebin" auth
  OUT=$(run_headroom "$CASE/fakebin" --json)
  printf '%s' "$OUT" | jq -e '.verdict == "partial"' >/dev/null \
    || fail "headroom --json must carry the same verdict as the text form: $OUT"
  printf '%s' "$OUT" | jq -e '[.providers[] | select(.provider == "cursor" and .verdict == "unknown")] | length == 1' >/dev/null \
    || fail "headroom --json must mark an unmeasurable provider unknown: $OUT"
  CASE="$TMP_ROOT/hr-json-absent"; mkdir -p "$CASE/fakebin"
  OUT=$( PATH="$CASE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom --json 2>&1 )
  printf '%s' "$OUT" | jq -e '.verdict == "unknown" and .measured == 0' >/dev/null \
    || fail "headroom --json must report an absent gauge as unknown: $OUT"
  pass 'headroom --json carries the same verdicts as the text form'
else
  pass 'headroom --json case skipped (jq unavailable)'
fi

# --- diagnose fixtures ------------------------------------------------------

WEEKLY_LIMIT_LINE="You've hit your weekly limit - resets Aug 26 at 10am (Europe/Rome)"

# make_task <case-dir> <task-id> -> exports CASE_HOME, CASE_WT, CASE_FB
make_task() {  # <case-dir> <task-id>
  local dir=$1 id=$2
  CASE_HOME="$dir/home"
  CASE_WT="$dir/wt"
  CASE_FB="$dir/fakebin"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data" "$CASE_HOME/config" "$CASE_FB"
  printf 'manual\n' > "$CASE_HOME/config/backlog-backend"
  fm_git_worktree "$dir/repo" "$CASE_WT" "fm/$id"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=fmtest:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$dir/repo" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=tmux" \
    "model=claude-opus-5" \
    "effort=high"
}

# fake_tmux <fakebin> <window> <capture-file|->
fake_tmux() {
  local fb=$1 window=$2 capture=$3
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' "$window"; exit 0 ;;
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane)
    if [ "$capture" = - ]; then exit 1; fi
    cat "$capture"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# fake_nm <fakebin> <branch> <run-id> <run-status> <steps-blob> <log-file|->
# Serves the two surfaces fm-usage-wall reads: the bare `axi` overview (which is
# scoped to the invoking worktree's own run) and `axi logs`.
fake_nm() {
  local fb=$1 branch=$2 run=$3 status=$4 steps=$5 log=$6
  cat > "$fb/nm-overview" <<SH
repo: /fake/repo
current_branch: $branch
daemon: running
active_run:
  id: "$run"
  branch: $branch
  status: $status
  head: deadbeef
  steps[9]{step,status,findings,duration_ms}:
$steps
branch_sync:
  state: pipeline_owned
  next_action:
    code: recover_custody
SH
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = logs ]; then
  if [ "$log" = - ]; then exit 1; fi
  cat "$log"
  exit 0
fi
if [ "\${1:-}" = axi ]; then cat "$fb/nm-overview"; exit 0; fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

run_wall() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2
  shift 2
  ( PATH="$fb:$PATH" FM_HOME="$home" "$WALL" "$@" 2>&1 )
}

# --- diagnose: the limit line in the endpoint output ------------------------

CASE="$TMP_ROOT/dx-endpoint"; mkdir -p "$CASE"
make_task "$CASE" wallcrew
printf 'building the fix\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-wallcrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose wallcrew)
assert_contains "$OUT" 'USAGE_WALL: wallcrew wall source=endpoint' 'a limit line in the endpoint output is a wall'
assert_contains "$OUT" "$WEEKLY_LIMIT_LINE" 'the verdict quotes the line it matched'
assert_contains "$OUT" 'not a crash' 'the wall verdict says plainly that this is not a crash'
assert_contains "$OUT" 'usage-limit-recovery' 'the wall verdict routes to the recovery procedure'
pass 'diagnose reads a usage wall out of the endpoint output'

# --- diagnose: the limit line in a failed step log --------------------------

CASE="$TMP_ROOT/dx-steplog"; mkdir -p "$CASE"
make_task "$CASE" logcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-logcrew "$CASE/capture.txt"
printf 'reviewing the diff\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/logcrew" RUN123 failed \
  '    intent,completed,0,0
    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose logcrew)
assert_contains "$OUT" 'USAGE_WALL: logcrew wall source=step-log:review' \
  'a limit line in the failed step log is a wall, which is where the evidence actually lives'
assert_contains "$OUT" "$WEEKLY_LIMIT_LINE" 'the step-log verdict quotes the line it matched'
pass 'diagnose reads a usage wall out of a failed pipeline step log'

# --- diagnose: transient transport wording is not a wall --------------------

CASE="$TMP_ROOT/dx-429"; mkdir -p "$CASE"
make_task "$CASE" ratecrew
printf 'HTTP 429 Too Many Requests\nrate limited, retrying in 5s\nretrying\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-ratecrew "$CASE/capture.txt"
printf 'HTTP 429 Too Many Requests\nrate limited, backing off\ntests failed: 3 assertions\n' > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/ratecrew" RUN429 failed '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose ratecrew)
assert_contains "$OUT" 'USAGE_WALL: ratecrew no-signature' \
  'transient transport throttling is not a usage wall'
assert_not_contains "$OUT" 'wall source=' 'a retryable 429 must never be reported as a wall'
assert_contains "$OUT" 'not proof the work crashed' 'a clean read still refuses to claim a crash'
pass 'diagnose does not mistake transient throttling for a usage wall'

# --- diagnose: unreadable and cheap-scan negatives are unknown --------------

CASE="$TMP_ROOT/dx-unreadable"; mkdir -p "$CASE"
make_task "$CASE" darkcrew
fake_tmux "$CASE_FB" fm-darkcrew -
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose darkcrew --endpoint-only)
assert_contains "$OUT" 'USAGE_WALL: darkcrew unknown' 'an unreadable endpoint is unknown'
assert_contains "$OUT" 'checked=none' 'an unreadable endpoint is not counted as checked'
pass 'diagnose reports an unreadable endpoint as unknown'

CASE="$TMP_ROOT/dx-cheap"; mkdir -p "$CASE"
make_task "$CASE" cheapcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-cheapcrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose cheapcrew --endpoint-only)
assert_contains "$OUT" 'unknown reason=endpoint-only-scan-inconclusive' \
  'a cheap scan that finds nothing is inconclusive, not a clean bill of health'
assert_not_contains "$OUT" 'no-signature' 'the cheap scan must never claim the evidence was fully read'
pass 'diagnose downgrades an endpoint-only negative to unknown'

CASE="$TMP_ROOT/dx-nometa"; mkdir -p "$CASE/home/state"
OUT=$( FM_HOME="$CASE/home" "$WALL" diagnose ghost 2>&1 )
assert_contains "$OUT" 'unknown reason=no-durable-record' 'a task with no local record is unknown'
pass 'diagnose reports an unrecorded task as unknown'

# --- resume -----------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  pass 'resume cases skipped (jq unavailable)'
else

CASE="$TMP_ROOT/rs-record"; mkdir -p "$CASE"
make_task "$CASE" recordcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-recordcrew "$CASE/capture.txt"
fake_nm "$CASE_FB" "fm/recordcrew" RUNREC failed \
  '    review,failed,0,120' "$CASE/review.log"
printf 'nothing to see\n' > "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" resume)
RECORD="$CASE_HOME/state/resume-record.md"
assert_present "$RECORD" 'resume publishes a durable record'
assert_contains "$OUT" "$RECORD" 'resume prints the path of the record it published'

# Read it back from a separate process, which is the property that matters: the
# record has to outlive the session that generated it.
BACK=$( cat "$RECORD" )
assert_contains "$BACK" '## recordcrew' 'the record names the task'
assert_contains "$BACK" 'mode=no-mistakes yolo=off' 'the record carries the standing merge posture'
assert_contains "$BACK" 'the captain approves every merge' 'the record spells out what that posture means'
assert_contains "$BACK" 'branch: fm/recordcrew' 'the record carries the branch a recovery must return to'
assert_contains "$BACK" 'harness=claude model=claude-opus-5 effort=high' 'the record carries the runtime to relaunch on'
assert_contains "$BACK" 'GENERATED from live durable state' 'the record says it is generated, not hand-authored'
assert_contains "$BACK" 'usage-limit-recovery' 'the record points at the procedure instead of restating it'
assert_contains "$BACK" 'custody=pipeline_owned' 'the record carries pipeline branch custody'
assert_contains "$BACK" 'next-action=recover_custody' 'the record carries the custody action the pipeline asks for'
assert_contains "$BACK" 'commits this local copy does not have' \
  'the record warns when the pipeline holds commits the local copy lacks'
pass 'resume generates a durable record that survives the process that wrote it'

# A regenerated record reflects state as it is now, not as it was.
git -C "$CASE_WT" checkout -q -b fm/recordcrew-moved
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
assert_grep 'branch: fm/recordcrew-moved' "$RECORD" 'regenerating the record picks up the new branch'
assert_no_grep 'branch: fm/recordcrew ' "$RECORD" 'the regenerated record does not keep the stale branch'
pass 'resume regenerates from current state rather than accumulating'

# --- resume: an empty home ---------------------------------------------------

CASE="$TMP_ROOT/rs-empty"; mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/fakebin"
printf 'manual\n' > "$CASE/home/config/backlog-backend"
run_wall "$CASE/home" "$CASE/fakebin" resume >/dev/null
assert_grep 'No task metadata is present' "$CASE/home/state/resume-record.md" \
  'an empty home produces a record that says so rather than an empty file'
pass 'resume records an empty home explicitly'

# --- resume: two tasks recording one local copy -----------------------------

CASE="$TMP_ROOT/rs-shared"; mkdir -p "$CASE"
make_task "$CASE" sharedone
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-sharedone "$CASE/capture.txt"
fm_write_meta "$CASE_HOME/state/sharedtwo.meta" \
  "window=fmtest:fm-sharedtwo" "endpoint_task_id=sharedtwo" "worktree=$CASE_WT" \
  "project=$CASE/repo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=tmux"
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
SHARED_HITS=$(grep -c 'SHARED: another task in this home records the same local copy' "$CASE_HOME/state/resume-record.md")
[ "$SHARED_HITS" = 2 ] || fail "both tasks sharing one local copy must be flagged, got $SHARED_HITS"
pass 'resume names a local copy claimed by two tasks on both rows'

# --- resume: a failed generation keeps the previous record -------------------

CASE="$TMP_ROOT/rs-atomic"; mkdir -p "$CASE"
make_task "$CASE" atomiccrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-atomiccrew "$CASE/capture.txt"
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
printf 'PRIOR RECORD SENTINEL\n' > "$CASE_HOME/state/resume-record.md"
# Break the snapshot the record is composed from, mid-flight, and require that
# the previous complete record is still the one on disk afterwards.
cat > "$CASE_FB/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$CASE_FB/jq"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" resume)
RC=$?
[ "$RC" -ne 0 ] || fail "resume must refuse when the fleet snapshot cannot be read: $OUT"
assert_contains "$OUT" 'fleet snapshot could not be read' 'the refusal names what it could not read'
assert_contains "$OUT" 'no record was written' 'the refusal says the previous record is still the one on disk'
assert_grep 'PRIOR RECORD SENTINEL' "$CASE_HOME/state/resume-record.md" \
  'a failed generation must leave the previous record readable'
pass 'resume refuses rather than replacing a good record with a broken one'

fi

# --- usage errors -----------------------------------------------------------

"$WALL" >/dev/null 2>&1; expect_code 2 $? 'no command is a usage error'
"$WALL" nonsense >/dev/null 2>&1; expect_code 2 $? 'an unknown command is a usage error'
"$WALL" diagnose >/dev/null 2>&1; expect_code 2 $? 'diagnose without a task id is a usage error'
"$WALL" --help >/dev/null 2>&1; expect_code 0 $? '--help succeeds'
pass 'usage errors are refused with a usage exit status'
