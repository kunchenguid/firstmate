#!/usr/bin/env bash
# fm-flow-snapshot.sh - read-only per-agent pipeline snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-flow-snapshot.v1`. This header owns that wire format, the flags, the
# environment knobs, and the exit codes.
#
# The command is read-only. It takes no session lock, drains no wakes, arms no
# watcher, and writes nothing. Nothing in firstmate calls it; it exists to be
# run by hand.
#
# It layers over bin/fm-fleet-snapshot.sh, which stays the single owner of fleet
# state, and adds two things that document does not carry: the named pipeline
# step each agent is on, and its GitHub check rollup.
#
# An agent here is a task with a LIVE worker behind it, whatever its kind. A
# `state/<id>.meta` outlives the window it names, so membership is decided by
# `endpoint.exists`, bin/fm-fleet-snapshot.sh's own reading of
# fm_backend_target_exists; a record that no longer resolves moves to `omitted`,
# named and counted rather than drawn. Kind decides only what an agent CARRIES:
# a `pipeline:true` agent carries a no-mistakes run, its steps and its GitHub
# checks, and a `pipeline:false` agent - a scout, a second mate - carries a
# `state` object read through bin/fm-crew-state.sh instead. Pipeline agents are
# emitted first, so the wire order is the draw order.
#
# Run attribution goes through bin/fm-nm-run-lib.sh, the repository's single
# owner of which no-mistakes run belongs to a branch. A worker cannot forge that
# answer, which is why it is read here rather than self-reported.
#
# Limits, stated because a blank cell should never read as a measured zero:
#
#   - Checks are read for GitHub pull requests only; a GitLab merge request or
#     a Gerrit change reports as not read. The read is a direct `gh pr view
#     --json statusCheckRollup` because fm_pr_github_read_record in
#     bin/fm-pr-lib.sh returns a PR's state and merged flag, not its rollup.
#   - The building phase starts at the task record's modification time, which is
#     approximate: bin/fm-pr-check.sh rewrites that record when it notes the PR.
#     Once a run exists the phase reports completed with no duration, because no
#     machine record states when the run began.
#   - A run whose pipeline executed outside the task's own copy of the
#     repository, such as a scratch clone raising a PR elsewhere, does not
#     resolve here, and that row reports its run as unestablished.
#
# Usage:
#   fm-flow-snapshot.sh [--json] [--no-ci] [--task <id>]
#
#   --json        emit the snapshot (default; accepted explicitly for symmetry
#                 with bin/fm-fleet-snapshot.sh)
#   --no-ci       skip every GitHub read, so the whole snapshot is local
#   --task <id>   restrict the snapshot to one task, for a targeted refresh
#
# Environment knobs:
#   FM_FLOW_SNAPSHOT_NM_TIMEOUT     seconds bounding one `no-mistakes axi
#                                   status` read (default 10)
#   FM_FLOW_SNAPSHOT_GH_TIMEOUT     seconds bounding one `gh pr view` (default
#                                   20)
#   FM_FLOW_SNAPSHOT_STATE_TIMEOUT  seconds bounding one bin/fm-crew-state.sh
#                                   read (default 15, above that reader's own
#                                   10s no-mistakes bound so its answer arrives
#                                   rather than being cut)
#   FM_FLOW_SNAPSHOT_FLEET_JSON     consume this file instead of running
#                                   bin/fm-fleet-snapshot.sh
#   FM_FLOW_SNAPSHOT_NOW_EPOCH      override the clock, in epoch seconds
#   FM_FLOW_SNAPSHOT_NOW            override the clock, as an ISO timestamp
#
# Exit codes: 0 snapshot emitted, 1 a dependency or the fleet read failed,
# 2 usage error. A per-agent collection failure is NOT an error: it is reported
# in that agent's `collection` object and the snapshot still succeeds, because
# one wedged worker must not blank the whole view.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

NM_TIMEOUT=${FM_FLOW_SNAPSHOT_NM_TIMEOUT:-10}
GH_TIMEOUT=${FM_FLOW_SNAPSHOT_GH_TIMEOUT:-20}
STATE_TIMEOUT=${FM_FLOW_SNAPSHOT_STATE_TIMEOUT:-15}

WANT_CI=1
ONLY_TASK=

usage() {
  sed -n '2,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) ;;
    --no-ci) WANT_CI=0 ;;
    --task)
      shift
      [ $# -gt 0 ] || { echo "fm-flow-snapshot: --task needs an id" >&2; exit 2; }
      ONLY_TASK=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-flow-snapshot: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# The ONE owner of the pull request link grammar. A recorded link is read
# through fm_pr_url_parse rather than by stripping its trailing number, because
# the number alone does not say WHICH repository it belongs to: `gh pr view <n>`
# with no --repo resolves the repository from the working directory, and this
# view runs from the firstmate root while the PR belongs to the task's project.
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# The ONE owner of no-mistakes run attribution, and of bounding a call to it.
# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

NOW_EPOCH=${FM_FLOW_SNAPSHOT_NOW_EPOCH:-$(date -u +%s)}
NOW_ISO=${FM_FLOW_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# Portable mtime in epoch seconds, the repository's own idiom for it.
path_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# `no-mistakes axi status` emits TOON on stdout; the version banner goes to
# stderr, so stdout needs no pre-filtering. A block is a header line naming its
# columns followed by one comma-separated row per entry.
#
# Both parsers below index by the COLUMN NAMES that header declares, never by
# position. The tool has already inserted a column mid-block between versions -
# `round_active_for` arrives fourth in active_steps on some builds and not at
# all on others - and a positional read silently relabels every column after it,
# so the row would still parse and every value in it would be wrong.
steps_json() {  # <axi-status-output>
  printf '%s\n' "$1" | awk '
    function read_header(line,   body, names, i, n) {
      body = line
      sub(/^[^{]*\{/, "", body)
      sub(/\}:[[:space:]]*$/, "", body)
      n = split(body, names, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+/, "", names[i]); gsub(/[ \t]+$/, "", names[i])
        col[names[i]] = i
      }
      return n
    }
    /^  steps\[[0-9]+\]\{/ { read_header($0); in_steps = 1; next }
    in_steps {
      if ($0 !~ /^    [a-z]/) { in_steps = 0; next }
      line = $0
      sub(/^    /, "", line)
      n = split(line, f, ",")
      if (!col["step"] || !col["status"] || n < col["duration_ms"]) next
      printf "%s{\"step\":\"%s\",\"status\":\"%s\",\"findings\":%d,\"duration_ms\":%d}",
        (emitted++ ? "," : ""), f[col["step"]], f[col["status"]],
        f[col["findings"]], f[col["duration_ms"]]
    }
  ' | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]\n" }'
}

active_steps_json() {  # <axi-status-output>
  printf '%s\n' "$1" | awk '
    # A RUNNING step publishes no duration; the only elapsed the tool states
    # for it is the humanised `active_for` ("23h11m", "2m59s"), parsed back to
    # milliseconds here so the renderer needs no second time format. The value
    # is validated END TO END before a single token is summed, so a unit this
    # parser does not know ("2w3d") yields null rather than the materially
    # understated time a partial parse would give.
    function active_ms(v,   total, tok, num, unit, rest) {
      if (v !~ /^([0-9]+(\.[0-9]+)?(ms|[dhms]))+$/) return "null"
      rest = v; total = 0
      while (match(rest, /[0-9]+(\.[0-9]+)?(ms|[dhms])/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (tok ~ /ms$/) { num = substr(tok, 1, length(tok) - 2) + 0; unit = "ms" }
        else { num = substr(tok, 1, length(tok) - 1) + 0; unit = substr(tok, length(tok)) }
        if (unit == "ms") total += num
        else if (unit == "s") total += num * 1000
        else if (unit == "m") total += num * 60000
        else if (unit == "h") total += num * 3600000
        else if (unit == "d") total += num * 86400000
      }
      return sprintf("%d", total)
    }
    function read_header(line,   body, names, i, n) {
      body = line
      sub(/^[^{]*\{/, "", body)
      sub(/\}:[[:space:]]*$/, "", body)
      n = split(body, names, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+/, "", names[i]); gsub(/[ \t]+$/, "", names[i])
        col[names[i]] = i
      }
      return n
    }
    # An optional column the running build does not declare reads as empty
    # rather than as whichever value happens to sit at that position.
    function field(name,   v) {
      if (!col[name] || col[name] > n) return ""
      v = f[col[name]]
      gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
      return v
    }
    /^  active_steps\[[0-9]+\]\{/ { read_header($0); in_a = 1; next }
    in_a {
      if ($0 !~ /^    [a-z]/) { in_a = 0; next }
      line = $0
      sub(/^    /, "", line)
      # Fields can be quoted and can themselves contain commas, so split on
      # commas that sit outside quotes rather than on every comma.
      n = 0; cur = ""; q = 0
      delete f
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { q = !q; continue }
        if (c == "," && !q) { f[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      f[++n] = cur
      if (!col["step"] || !col["status"] || !col["active_for"] || n < col["active_for"]) next
      printf "%s{\"step\":\"%s\",\"status\":\"%s\",\"active_for\":\"%s\",\"active_ms\":%s,\"last_activity\":\"%s\",\"agent_pid\":\"%s\",\"round\":\"%s\"}",
        (emitted++ ? "," : ""), field("step"), field("status"), field("active_for"),
        active_ms(field("active_for")), field("last_activity"), field("agent_pid"),
        field("round")
    }
  ' | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]\n" }'
}

toon_field() {  # <axi-status-output> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    $0 ~ "^  " key ": " {
      sub("^  " key ": ", "")
      gsub(/^"|"$/, "")
      print
      exit
    }'
}

CI_EMPTY='{"collection":{"ok":false,"reason":""},"checks":[],"total":0,"passed":0,"failed":0,"pending":0,"skipped":0,"head":"","pr_state":""}'
ci_unread() {  # <reason>
  printf '%s' "$CI_EMPTY" | jq --arg r "$1" '.collection.reason = $r'
}

ci_json() {  # <pr-url>
  local url=$1 raw norm head pr_state
  # A link the one parser refuses is NOT EVALUATED, never guessed at: reading a
  # trailing number off an unrecognised string and querying it is how a view
  # like this reports another repository's PR of the same number as its own.
  if ! fm_pr_url_parse "$url"; then
    ci_unread "not a pull request link this view can read"
    return
  fi
  if [ "$FM_PR_PROVIDER" != github ]; then
    ci_unread "checks are read for GitHub pull requests only"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    ci_unread "gh not found"
    return
  fi
  # --repo is what makes the answer the TASK's repository, because gh otherwise
  # resolves it from the working directory, which is the firstmate root for
  # every task this view draws. headRefOid rides the same call as the commit
  # these checks describe, so the renderer can tell checks that passed on a head
  # the run will replace from checks on the head that will land. `state` rides
  # it as the PR's OWN lifecycle - OPEN, MERGED or CLOSED - because a green
  # check tally is not evidence that anything is still open.
  raw=$(fm_nm_bounded "$FM_ROOT" "$GH_TIMEOUT" \
    gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" \
    --json statusCheckRollup,headRefOid,state 2>/dev/null) || raw=
  if [ -z "$raw" ]; then
    ci_unread "gh read failed or timed out"
    return
  fi
  # The counts have ONE job: agree with what `gh pr checks <n>` prints for the
  # same PR. Three rules get there.
  #
  # 1. Supersession. Checks are keyed on workflow PLUS name, because names alone
  #    are not unique, and the rollup keeps EVERY attempt of a key. The latest
  #    attempt wins; the rest are counted nowhere.
  # 2. Exclusive buckets. Reading `conclusion` without first checking `status`
  #    counts a re-running check as both passed and pending, on a conclusion
  #    left over from its previous attempt.
  # 3. A deliberately-not-run check is its OWN class: a job GitHub reports
  #    SKIPPED verified nothing, so it is never folded into passing.
  #
  # A StatusContext, a commit status rather than a check run, carries `state`
  # and `context` instead; gh counts those too, so they are normalised rather
  # than dropped into the pending bucket for want of a `status` field.
  norm=$(printf '%s' "$raw" | jq -c '
    def normalize:
      if (.__typename // "") == "StatusContext" then
        { workflow: "", name: (.context // ""), started: (.createdAt // ""),
          status: (if (.state // "") == "PENDING" or (.state // "") == "EXPECTED"
                   then "IN_PROGRESS" else "COMPLETED" end),
          conclusion: (if (.state // "") == "SUCCESS" then "SUCCESS" else (.state // "") end) }
      else
        { workflow: (.workflowName // ""), name: (.name // ""),
          started: (.startedAt // ""),
          status: (.status // ""), conclusion: (.conclusion // "") }
      end;
    (.statusCheckRollup // [])
    | map(normalize)
    | to_entries
    | map(.value + {seq: .key})
    | group_by([.workflow, .name])
    | map(max_by([.started, .seq]))
    | sort_by(.seq)
    | map(del(.seq))
    | map(. + {verdict:
        (if .status != "COMPLETED" then "pending"
         elif .conclusion == "SKIPPED" then "skipped"
         elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" then "passed"
         else "failed" end)})') || norm=
  if [ -z "$norm" ]; then
    ci_unread "check rollup could not be read"
    return
  fi
  head=$(printf '%s' "$raw" | jq -r '.headRefOid // ""' 2>/dev/null) || head=
  # Empty when GitHub did not report it, which the renderer treats as a state it
  # could not read rather than as an open PR.
  pr_state=$(printf '%s' "$raw" | jq -r '.state // ""' 2>/dev/null) || pr_state=
  printf '%s' "$norm" | jq --arg head "$head" --arg pr_state "$pr_state" '{
      collection: {ok: true, reason: ""},
      checks: .,
      total: length,
      passed: (map(select(.verdict == "passed")) | length),
      failed: (map(select(.verdict == "failed")) | length),
      pending: (map(select(.verdict == "pending")) | length),
      skipped: (map(select(.verdict == "skipped")) | length),
      head: $head,
      pr_state: $pr_state
    }'
}

# The failed read's own words: its first line of stdout, and failing that the
# first line of stderr that is not the version banner. An exit code alone tells
# the captain a read failed and nothing they can act on. The diagnosis is on
# STDOUT because stderr carries that banner on every call including the ones
# that work, which is also why the two streams are never merged: doing so would
# put the banner into the TOON the step parsers read.
axi_error() {  # <stdout> <stderr-file>
  local line
  line=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -1)
  if [ -z "$line" ] && [ -s "$2" ]; then
    line=$(sed 's/\x1b\[[0-9;]*m//g' "$2" 2>/dev/null |
      grep -v -e '^[[:space:]]*$' -e 'version of no-mistakes' -e '^Run "no-mistakes update"' |
      head -1)
  fi
  printf '%s' "$line" | cut -c1-160
}

# The fields every agent carries whether or not it has a pipeline, resolved once
# so the two builders below cannot drift apart in how they read the fleet
# document. Sets the FM_ROW_* globals rather than echoing, because several of
# them are needed as separate jq arguments.
row_common() {  # <task-json>
  local task=$1
  FM_ROW_ID=$(printf '%s' "$task" | jq -r '.id')
  FM_ROW_KIND=$(printf '%s' "$task" | jq -r '.kind // ""')
  FM_ROW_MODE=$(printf '%s' "$task" | jq -r '.mode // ""')
  FM_ROW_PROJECT=$(printf '%s' "$task" | jq -r '.project // ""')
  FM_ROW_WORKTREE=$(printf '%s' "$task" | jq -r '.paths.worktree.path // ""')
  FM_ROW_WINDOW=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  FM_ROW_ENDPOINT_ALIVE=$(printf '%s' "$task" | jq -r 'if .endpoint.exists then "true" else "false" end')
  # `endpoint.exists` only says a pane is there; this probe asks what is RUNNING
  # in it. It reads the pane's foreground command, so it cannot see a WEDGED
  # agent - a stuck agent is still that agent's process - and upgrades "a pane
  # exists" to "an agent process exists" and nothing further.
  FM_ROW_AGENT_ALIVE=$(printf '%s' "$task" | jq -r '.endpoint.agent_alive // "not_checked"')
  if [ "$FM_ROW_AGENT_ALIVE" = "not_checked" ] \
     && [ "$FM_ROW_ENDPOINT_ALIVE" = true ] && [ -n "$FM_ROW_WINDOW" ]; then
    local backend
    backend=$(printf '%s' "$task" | jq -r '.backend // "tmux"')
    FM_ROW_AGENT_ALIVE=$(fm_backend_agent_alive "$backend" "$FM_ROW_WINDOW" 2>/dev/null || printf 'unknown')
  fi
  FM_ROW_PR_URL=$(printf '%s' "$task" | jq -r '.pr.url // ""')
  # The path comes from the fleet document when it carries one, because
  # bin/fm-fleet-snapshot.sh is this view's owner of fleet state and already
  # resolved it; the standard construction is the fallback.
  FM_ROW_META=$(printf '%s' "$task" | jq -r '.paths.meta.path // ""')
  [ -n "$FM_ROW_META" ] || FM_ROW_META="$STATE_DIR/$FM_ROW_ID.meta"
  # Which model and effort the WORKER itself runs on, from the one machine
  # record of it: the fields bin/fm-spawn.sh wrote at dispatch. `default` means
  # the harness picked, which is not the name of a model, so it is emitted as
  # absent rather than as the word.
  FM_ROW_HARNESS=$(printf '%s' "$task" | jq -r '.harness // ""')
  [ -n "$FM_ROW_HARNESS" ] || FM_ROW_HARNESS=$(fm_meta_get "$FM_ROW_META" harness)
  FM_ROW_MODEL=$(fm_meta_get "$FM_ROW_META" model)
  [ "$FM_ROW_MODEL" != default ] || FM_ROW_MODEL=
  FM_ROW_EFFORT=$(fm_meta_get "$FM_ROW_META" effort)
  [ "$FM_ROW_EFFORT" != default ] || FM_ROW_EFFORT=
}

agent_json() {  # <task-json>
  local task=$1 id kind mode project worktree window branch endpoint_alive agent_alive pr_url
  local rundir overview sel axi rc steps actives ci meta
  local run_id run_status run_head run_error

  row_common "$task"
  id=$FM_ROW_ID
  kind=$FM_ROW_KIND
  mode=$FM_ROW_MODE
  project=$FM_ROW_PROJECT
  worktree=$FM_ROW_WORKTREE
  window=$FM_ROW_WINDOW
  endpoint_alive=$FM_ROW_ENDPOINT_ALIVE
  agent_alive=$FM_ROW_AGENT_ALIVE
  pr_url=$FM_ROW_PR_URL
  meta=$FM_ROW_META
  branch="fm/$id"

  steps='[]'
  actives='[]'
  run_id=''
  run_status=''
  run_head=''
  run_error=''
  local collect_ok=true collect_reason=''

  # `no-mistakes axi status` resolves its repository from the WORKING
  # DIRECTORY, so the read is done in the task's own copy. The subshell inside
  # fm_nm_bounded keeps that change local: this collector reads several tasks in
  # one pass and must not carry one task's directory into the next.
  rundir=$worktree
  if [ -z "$rundir" ] || [ ! -d "$rundir" ]; then rundir=$project; fi
  if [ -z "$rundir" ] || [ ! -d "$rundir" ]; then
    collect_ok=false
    collect_reason='no copy of the repository left to read the run from'
  elif ! command -v no-mistakes >/dev/null 2>&1; then
    collect_ok=false
    collect_reason='no-mistakes not found'
  else
    overview=$(fm_nm_run "$rundir" "$NM_TIMEOUT" axi status)
    sel=$(fm_nm_select_run "$branch" "$overview" "$rundir" "$NM_TIMEOUT")
    case $sel in
      selected\|*)
        run_id=$(printf '%s' "$sel" | cut -d'|' -f2)
        run_status=$(printf '%s' "$sel" | cut -d'|' -f3)
        ;;
      absent)
        collect_reason='no pipeline run for this branch' ;;
      unavailable)
        collect_ok=false
        collect_reason='no-mistakes listed no runs to read' ;;
      *)
        # unknown|<reason>: the library's own words, kept verbatim rather than
        # collapsed, because which way the run list was unreadable is the whole
        # of what the captain can act on.
        collect_ok=false
        collect_reason=${sel#unknown|} ;;
    esac
  fi

  if [ -n "$run_id" ]; then
    local axi_err
    axi_err="${TMPDIR:-/tmp}/fm-flow-axi-err.$$.$id"
    axi=$(fm_nm_run_bounded "$rundir" "$NM_TIMEOUT" axi status --run "$run_id" 2>"$axi_err")
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$axi" ]; then
      # Exit 0 with an empty stdout is its own outcome, neither of the other
      # two, and is reported as such rather than as a silent success.
      local why
      if [ "$rc" = 124 ]; then
        why="axi status timed out after ${NM_TIMEOUT}s"
      elif [ "$rc" = 0 ]; then
        why='axi printed nothing'
      else
        why=$(axi_error "$axi" "$axi_err")
        if [ -n "$why" ]; then
          why="axi status failed (exit $rc): $why"
        else
          why="axi status failed (exit $rc)"
        fi
      fi
      collect_ok=false
      collect_reason="$why"
    fi
    rm -f "$axi_err"
    if [ "$collect_ok" = true ]; then
      steps=$(steps_json "$axi")
      actives=$(active_steps_json "$axi")
      run_head=$(toon_field "$axi" head)
      run_error=$(toon_field "$axi" error)
      [ -n "$pr_url" ] || pr_url=$(toon_field "$axi" pr)
    fi
  fi

  # The worker's own implementation phase, which no pipeline record describes
  # because it happens before the pipeline exists. Its start and its precision
  # are the header's third limit. No readable record leaves the step `unknown`
  # rather than `pending`: not started yet is a claim, and it is the wrong one
  # for a worker that is demonstrably running.
  local built_at build_step build_active=''
  built_at=$(path_mtime "$meta")
  if [ -n "$run_id" ]; then
    build_step='{"step":"building","status":"completed","findings":0,"duration_ms":null}'
  elif [ -n "$built_at" ]; then
    build_step='{"step":"building","status":"running","findings":0,"duration_ms":0}'
    # active_for is the tool's own humanised string for a step it owns; this
    # step is not one of its own, so the field is empty and active_ms - the only
    # value the renderer reads - is computed from the two epochs directly.
    local since=$(( (NOW_EPOCH - built_at) * 1000 ))
    [ "$since" -ge 0 ] || since=0
    build_active="{\"step\":\"building\",\"status\":\"running\",\"active_for\":\"\",\"active_ms\":$since,\"last_activity\":\"\",\"agent_pid\":\"\",\"round\":\"\"}"
  else
    build_step='{"step":"building","status":"unknown","findings":0,"duration_ms":0}'
  fi

  # Only when the pipeline read succeeded. `collection.ok` false means the whole
  # of this agent's step list could not be established, and the renderer draws
  # every cell unknown on the strength of it; one step slipped in beside that
  # would be a fact reported inside a frame that says nothing is known.
  if [ "$collect_ok" = true ]; then
    steps=$(printf '%s' "$steps" | jq -c --argjson b "$build_step" '[$b] + .')
    if [ -n "$build_active" ]; then
      actives=$(printf '%s' "$actives" | jq -c --argjson b "$build_active" '[$b] + .')
    fi
  else
    actives='[]'
  fi

  ci=$(ci_unread "skipped")
  if [ "$WANT_CI" = 1 ] && [ -n "$pr_url" ]; then
    ci=$(ci_json "$pr_url")
  fi

  # The number the view labels the PR with comes from the same parser the CI
  # read used, so a link one of them refuses cannot be numbered by the other.
  local pr_num=
  if [ -n "$pr_url" ] && fm_pr_url_parse "$pr_url"; then
    pr_num=$FM_PR_NUMBER
  fi

  jq -n \
    --arg id "$id" \
    --arg branch "$branch" \
    --arg project "$project" \
    --arg worktree "$worktree" \
    --arg window "$window" \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg pr_url "$pr_url" \
    --arg run_id "$run_id" \
    --arg run_status "$run_status" \
    --arg run_error "$run_error" \
    --arg run_head "$run_head" \
    --arg agent_alive "$agent_alive" \
    --arg collect_reason "$collect_reason" \
    --arg now_iso "$NOW_ISO" \
    --argjson now_epoch "$NOW_EPOCH" \
    --argjson endpoint_alive "$endpoint_alive" \
    --argjson collect_ok "$collect_ok" \
    --argjson pr_num "${pr_num:-null}" \
    --arg harness "$FM_ROW_HARNESS" \
    --arg w_model "$FM_ROW_MODEL" \
    --arg w_effort "$FM_ROW_EFFORT" \
    --argjson steps "$steps" \
    --argjson actives "$actives" \
    --argjson ci "$ci" \
    '{
      id:$id, branch:$branch, project:$project, worktree:$worktree,
      window:$window, kind:$kind, mode:$mode,
      pipeline:true,
      state:null,
      endpoint_alive:$endpoint_alive,
      agent_alive:$agent_alive,
      worker:{
        harness:(if $harness == "" then null else $harness end),
        model:(if $w_model == "" then null else $w_model end),
        effort:(if $w_effort == "" then null else $w_effort end)
      },
      pr:{url:(if $pr_url == "" then null else $pr_url end), number:$pr_num},
      collection:{ok:$collect_ok, reason:$collect_reason, source:"axi",
                  at:$now_iso, epoch:$now_epoch},
      run:{
        present:($run_id != ""),
        id:$run_id, status:$run_status,
        error:$run_error, head:$run_head
      },
      steps:$steps,
      active_steps:$actives,
      ci:$ci
    }'
}

# A live worker that runs no no-mistakes pipeline: a scout, a second mate. It
# gets an agent record like any other live worker, because being drawn is what
# liveness earns, but no run, steps or checks: nine permanently empty boxes
# would be an invented journey, and `pipeline:false` states that rather than
# leaving the renderer to infer it from the kind string. Its one substantive
# fact is the state, and bin/fm-crew-state.sh already owns reconciling that out
# of a crew's run step, pane and status log. A read that fails or times out
# reports ok:false; it never falls back to the status log's last line, which is
# a wake EVENT and not a current state.
crew_state_json() {  # <task-id>
  local id=$1 line rest
  # FM_HOME and FM_ROOT_OVERRIDE are passed because this script defaults them
  # internally and an internal default is not in the environment. Anything the
  # CALLER set - FM_STATE_OVERRIDE above all - is already exported and inherits
  # on its own, so re-passing it would be a second copy that could disagree.
  line=$(
    fm_nm_bounded "$FM_ROOT" "$STATE_TIMEOUT" env \
      FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1
  ) || line=
  case "$line" in
    "state: "*) ;;
    *)
      jq -n --arg r "${line:-current-state read failed or timed out}" \
        '{ok:false, value:"", source:"", detail:"", reason:$r}'
      return ;;
  esac
  # `state: <v> · source: <s> · <detail>`, whose separator and field order are
  # bin/fm-crew-state.sh's own contract. The detail is everything after the
  # second separator and may contain further separators of its own, so it is
  # taken as the remainder rather than as a third field.
  rest=${line#state: }
  local value=${rest%% · *}
  rest=${rest#"$value"}
  rest=${rest# · }
  local source=${rest%% · *}
  source=${source#source: }
  local detail=${rest#*" · "}
  [ "$detail" != "$rest" ] || detail=
  jq -n --arg v "$value" --arg s "$source" --arg d "$detail" \
    '{ok:true, value:$v, source:$s, detail:$d, reason:""}'
}

compact_json() {  # <task-json>
  local task=$1 state

  row_common "$task"
  state=$(crew_state_json "$FM_ROW_ID")

  jq -n \
    --arg id "$FM_ROW_ID" \
    --arg branch "fm/$FM_ROW_ID" \
    --arg project "$FM_ROW_PROJECT" \
    --arg worktree "$FM_ROW_WORKTREE" \
    --arg window "$FM_ROW_WINDOW" \
    --arg kind "$FM_ROW_KIND" \
    --arg mode "$FM_ROW_MODE" \
    --arg agent_alive "$FM_ROW_AGENT_ALIVE" \
    --arg harness "$FM_ROW_HARNESS" \
    --arg w_model "$FM_ROW_MODEL" \
    --arg w_effort "$FM_ROW_EFFORT" \
    --arg pr_url "$FM_ROW_PR_URL" \
    --arg now_iso "$NOW_ISO" \
    --argjson now_epoch "$NOW_EPOCH" \
    --argjson endpoint_alive "$FM_ROW_ENDPOINT_ALIVE" \
    --argjson state "$state" \
    --argjson ci "$CI_EMPTY" \
    '{
      id:$id, branch:$branch, project:$project, worktree:$worktree,
      window:$window, kind:$kind, mode:$mode,
      pipeline:false,
      state:$state,
      endpoint_alive:$endpoint_alive,
      agent_alive:$agent_alive,
      worker:{
        harness:(if $harness == "" then null else $harness end),
        model:(if $w_model == "" then null else $w_model end),
        effort:(if $w_effort == "" then null else $w_effort end)
      },
      pr:{url:(if $pr_url == "" then null else $pr_url end), number:null},
      collection:{ok:true, reason:"this worker runs no pipeline", source:"",
                  at:$now_iso, epoch:$now_epoch},
      run:{present:false, id:"", status:"", error:"", head:""},
      steps:[],
      active_steps:[],
      ci:($ci | .collection.reason = "this worker opens no PR")
    }'
}

if [ -n "${FM_FLOW_SNAPSHOT_FLEET_JSON:-}" ]; then
  FLEET=$(cat "$FM_FLOW_SNAPSHOT_FLEET_JSON") || {
    echo "fm-flow-snapshot: cannot read $FM_FLOW_SNAPSHOT_FLEET_JSON" >&2
    exit 1
  }
else
  FLEET=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null
  ) || FLEET=
fi

# The fleet read is the one hard dependency: without the agent list there is
# nothing to draw, and an empty document would read as an empty fleet, which is
# a different and much more dangerous claim than a failure.
if [ -z "$FLEET" ] || ! printf '%s' "$FLEET" | jq -e '.tasks' >/dev/null 2>&1; then
  echo "fm-flow-snapshot: fleet snapshot unavailable; refusing to emit an empty fleet" >&2
  exit 1
fi

SCOPED=$(printf '%s' "$FLEET" | jq -c --arg only "$ONLY_TASK" '
  [ .tasks[] | select($only == "" or .id == $only) ]')
# Membership is liveness and nothing else, and `endpoint.exists` is consumed
# rather than re-derived so the view can never disagree with the rest of
# firstmate about which workers are running. null means no endpoint was ever
# recorded, which is not a live worker either and is a different reason worth
# naming.
ORDER='([ .[] | select(.kind == "ship") ] + [ .[] | select(.kind != "ship") ])[]'
TASKS=$(printf '%s' "$SCOPED" | jq -c "[ .[] | select(.endpoint.exists == true) ] | $ORDER")
OMITTED=$(printf '%s' "$SCOPED" | jq -c '[
  .[]
  | select(.endpoint.exists != true)
  | {id, kind:(.kind // ""), window:(.endpoint.target // null),
     reason:(if .endpoint.exists == false
             then "recorded window no longer exists"
             else "no endpoint recorded" end)}
]')

AGENTS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-flow-agents.XXXXXX")
trap 'rm -f "$AGENTS_FILE"' EXIT INT TERM
printf '[' > "$AGENTS_FILE"
FIRST=1
while IFS= read -r task; do
  [ -n "$task" ] || continue
  [ "$FIRST" = 1 ] || printf ',' >> "$AGENTS_FILE"
  FIRST=0
  if [ "$(printf '%s' "$task" | jq -r '.kind // ""')" = ship ]; then
    agent_json "$task" | jq -c '.' >> "$AGENTS_FILE"
  else
    compact_json "$task" | jq -c '.' >> "$AGENTS_FILE"
  fi
done <<EOF
$TASKS
EOF
printf ']' >> "$AGENTS_FILE"

# The agents array is passed by FILE, never as an argv string, so the document
# does not stop being emittable once the fleet outgrows ARG_MAX.
jq -n \
  --arg generated "$NOW_ISO" \
  --argjson generated_epoch "$NOW_EPOCH" \
  --arg fm_home "$FM_HOME" \
  --argjson omitted "$OMITTED" \
  --slurpfile agents "$AGENTS_FILE" \
  '{
    schema:"fm-flow-snapshot.v1",
    generated:$generated,
    generated_epoch:$generated_epoch,
    fm_home:$fm_home,
    agents:($agents[0] // []),
    omitted:$omitted
  }'
