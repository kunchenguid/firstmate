#!/usr/bin/env bash
# Resumable scouts: the durable native-session record a finished scout leaves
# behind, and the follow-up launch decision that consumes it. Sourced by
# bin/fm-spawn.sh and bin/fm-teardown.sh; this header owns the record format
# and the resume rule.
#
# Record: data/<id>/session.ref, key=value lines written by bin/fm-teardown.sh
# at cleanup of a scout whose report exists, after every refusal and before the
# task record is removed:
#   harness=    adapter the scout ran on
#   model=      model as recorded at spawn
#   effort=     effort as recorded at spawn
#   project=    absolute project directory
#   session=    harness-native session id; empty when the runtime gave none
#   report=     absolute path of the scout's report
#   torn_down=  UTC cleanup time, ISO-8601
# It lives in data/<id>/ beside report.md because that directory is the only
# per-scout home that survives cleanup, while backlog notes stay free of
# ephemeral identifiers. Capture never blocks or fails a teardown.
#
# Capture: only Claude scouts carry a session id. bin/fm-spawn.sh launches a
# verified Claude scout with an explicit `--session-id <uuid>` and records it as
# the task record key claude_session; every other harness records session=
# empty, so a follow-up from it is a fresh scout.
#
# Follow-up (bin/fm-spawn.sh <new-id> <project> --scout --follow-up <old-id>):
# the new scout always gets a fresh local copy at the base branch and a brief
# prefixed by fm_scout_follow_up_preamble. It resumes the earlier session only
# when the new launch is the verified claude template, the record names
# harness=claude with a session, and that transcript exists in the Claude store
# the new launch uses (<config>/projects/*/<session>.jsonl). The launch then
# carries `--resume <old> --fork-session --session-id <new>`: Claude 2.1.311
# resumes a session recorded under another directory, and the fork writes a new
# transcript under the new cwd, leaving the old one untouched and the follow-up
# itself resumable. Any other case launches a fresh scout.

# fm_scout_session_kv <file> <key>: last value of <key>, empty when absent.
fm_scout_session_kv() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

fm_scout_session_id_valid() {
  printf '%s' "$1" | grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
}

# fm_scout_session_new_id: a lowercase UUID, or status 1 when none is available.
fm_scout_session_new_id() {
  local id=
  if command -v uuidgen >/dev/null 2>&1; then
    id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
  fi
  if ! fm_scout_session_id_valid "$id" && [ -r /proc/sys/kernel/random/uuid ]; then
    id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  fi
  fm_scout_session_id_valid "$id" || return 1
  printf '%s\n' "$id"
}

# fm_scout_session_record <task-meta> <data-dir> <id>: write data/<id>/session.ref.
fm_scout_session_record() {
  local meta=$1 data=$2 id=$3 dir harness session tmp
  dir="$data/$id"
  mkdir -p "$dir" || return 1
  harness=$(fm_scout_session_kv "$meta" harness)
  session=
  [ "$harness" != claude ] || session=$(fm_scout_session_kv "$meta" claude_session)
  fm_scout_session_id_valid "$session" || session=
  tmp="$dir/.session.ref.${BASHPID:-$$}"
  {
    echo "harness=$harness"
    echo "model=$(fm_scout_session_kv "$meta" model)"
    echo "effort=$(fm_scout_session_kv "$meta" effort)"
    echo "project=$(fm_scout_session_kv "$meta" project)"
    echo "session=$session"
    echo "report=$dir/report.md"
    echo "torn_down=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$dir/session.ref" || {
    rm -f "$tmp"
    return 1
  }
}

# fm_scout_follow_up_resume_id <data-dir> <old-id> <new-harness> <raw-launch> <claude-config-dir>
# Prints the session id to resume, or prints why not and returns 1.
fm_scout_follow_up_resume_id() {
  local ref="$1/$2/session.ref" harness=$3 raw=$4 cfg=$5 rec session t
  [ -f "$ref" ] || {
    echo "no session record at $ref"
    return 1
  }
  rec=$(fm_scout_session_kv "$ref" harness)
  session=$(fm_scout_session_kv "$ref" session)
  [ "$raw" = 0 ] && [ "$harness" = claude ] || {
    echo "native resume is wired only for the verified claude launch; this follow-up runs on ${harness:-a raw launch command}"
    return 1
  }
  [ "$rec" = claude ] || {
    echo "the earlier scout ran on ${rec:-an unrecorded harness}, not claude"
    return 1
  }
  fm_scout_session_id_valid "$session" || {
    echo "the earlier scout recorded no session id"
    return 1
  }
  for t in "$cfg"/projects/*/"$session".jsonl; do
    [ -f "$t" ] || continue
    printf '%s\n' "$session"
    return 0
  done
  echo "session $session is not in the Claude store at $cfg"
  return 1
}

# fm_scout_follow_up_preamble <old-id> <report-path>: the brief section every
# follow-up scout reads first, on either path.
fm_scout_follow_up_preamble() {
  cat <<EOF
# Follow-up to scout $1
This scout follows up the finished scout \`$1\`; its report is at \`$2\`.
If you remember an earlier conversation, it was that scout's session: its task id, status file, steering inbox, and local copy no longer apply, so use only the paths in this brief.
That earlier work, the report included, may describe code that has changed since: your local copy is fresh at the current base branch, so re-verify every claim against it before relying on it, and say in your report which earlier findings still hold.

EOF
}
