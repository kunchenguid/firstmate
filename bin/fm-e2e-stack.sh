#!/usr/bin/env bash
# fm-e2e-stack.sh - durable record and guarded removal of a task's local
# end-to-end test infrastructure (docker compose stacks).
#
# Usage:
#   fm-e2e-stack.sh record <task-id> --project <name> --stack <profile> \
#     --repo <repo> --scenario <name> --worktree <path> \
#     [--compose-file <path>]... [--service <name>]... \
#     [--external-volume <name>]... [--network <name>] [--created-network] \
#     [--port <NAME=port>]...
#   fm-e2e-stack.sh read <task-id>
#   fm-e2e-stack.sh gate <task-id>
#   fm-e2e-stack.sh down <task-id> [--dry-run]
#   fm-e2e-stack.sh clear <task-id>
#   fm-e2e-stack.sh strays
#
# WHY THIS EXISTS. A crewmate that provisions a local stack for an end-to-end
# test and then dies, or simply forgets, leaves containers, volumes and a
# network running with no record of who owns them. Recovering that ownership by
# hand costs a forensic session: reading database logs for a last-activity
# timestamp, testing whether the launching worktree still exists, and grepping
# old task reports for container names. This script is the durable half of the
# `revocall-e2e-provision` / `revocall-e2e-teardown` skill pair: the skills own
# the provisioning and cleanup PROCEDURE, this script owns the record format,
# the ownership gates, and the removal, so cleanup converges whether the worker
# runs it, teardown runs it, or a later session runs it.
#
# RECORD. state/<task-id>.e2e-stack holds one `key=value` block per provisioned
# stack, blank-line separated, in the same shape as state/<task-id>.meta. A
# repeated key is a list. `record` appends; re-recording the same project
# replaces that block, so a re-provision cannot leave two records of one stack.
#
# OWNERSHIP GATES. `gate` and `down` remove nothing until all four pass:
#   1. Every live container carrying label ai.revolab.fm.task=<task-id> belongs
#      to a project this record names, and every recorded project's containers
#      carry that label. A label without a record, or a record without matching
#      containers, is reported as a divergence and blocks removal.
#   2. Every recorded project name begins with the `fm-` prefix. Nothing a
#      person or another tool started is named that way, so a hand-run or
#      captain-owned stack can never be selected.
#   3. No OTHER task record in this home names the same project or worktree.
#      One project claimed by two task records is the collision itself,
#      whichever record is stale, and is never resolved by guessing.
#   4. Every recorded external volume name contains the task id. RevoCall's
#      deploy stack pins six `external: true` volumes to fixed names, and
#      compose removes external volumes on NO code path, including `down -v`
#      (verified; docs/verification/local-e2e-infra.md). Removing one whose
#      name carries no task suffix would destroy the shared local development
#      data those unsuffixed names hold.
# --dry-run prints the verdicts and the removal plan and changes nothing.
# There is no --force: this script's refusals protect OTHER work, and
# discarding this task's own work is never what they stand in the way of.
#
# NOT A SWEEPER. `strays` reports containers whose task record is gone; it
# never removes them, and it never reports an unlabelled container as
# removable. An anonymous container can be live work - a no-mistakes pipeline
# run brings up a project named after its own directory - so removal always
# needs a record, never an inference.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DOCKER="${FM_DOCKER:-docker}"
LABEL_TASK=ai.revolab.fm.task
PROJECT_PREFIX=fm-

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Print the header contract from `# Usage:` onward: the invocation forms plus
# the record and ownership-gate rules a caller has to know. Extracted by
# pattern rather than by line number so editing the header above can never
# silently truncate or misalign --help.
usage() {
  awk '/^# Usage:/ {on=1} on && /^#/ {sub(/^# ?/, ""); print; next} on {exit}' "$0" >&2
  exit 2
}

# A record field must survive the blank-line-separated key=value block format.
# A tab or newline would break the block; '=' is safe because every reader
# splits on the FIRST '=' only. An empty value is refused so an omitted flag
# can never read back as a recorded value.
field_valid() {  # <value>
  local v=${1-}
  [ -n "$v" ] || return 1
  case $v in
    *$'\t'* | *$'\n'*) return 1 ;;
  esac
  return 0
}

# Docker's own project-name charset, so a recorded project can never carry
# filter or shell syntax into `docker ps --filter label=...=<project>`.
project_name_valid() {  # <name>
  case ${1-} in
    '' ) return 1 ;;
    [a-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case ${1-} in
    *[^a-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# Ports are the one field that legitimately contains '=' (NAME=port).
port_valid() {  # <NAME=port>
  case ${1-} in
    [A-Z_]*=[0-9]*) [ "${1#*=}" -ge 1 ] 2>/dev/null && [ "${1#*=}" -le 65535 ] ;;
    *) return 1 ;;
  esac
}

require_state_dir() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
}

record_path() { printf '%s/%s.e2e-stack\n' "$STATE" "$1"; }

# Print the value(s) of <key> from the block starting at <block-index>.
block_values() {  # <file> <index> <key>
  awk -v want="$2" -v key="$3" '
    BEGIN { idx = 0; started = 0 }
    /^[[:space:]]*$/ { if (started) { idx++; started = 0 } ; next }
    { started = 1; if (idx == want) { eq = index($0, "=");
        if (eq > 1 && substr($0, 1, eq - 1) == key) print substr($0, eq + 1) } }
  ' "$1"
}

block_count() {  # <file>
  [ -f "$1" ] || { printf '0\n'; return 0; }
  awk '
    BEGIN { idx = 0; started = 0 }
    /^[[:space:]]*$/ { if (started) { idx++; started = 0 } ; next }
    { started = 1 }
    END { if (started) idx++; print idx }
  ' "$1"
}

docker_available() { command -v "$DOCKER" >/dev/null 2>&1 && "$DOCKER" info >/dev/null 2>&1; }

project_containers() {  # <project>
  "$DOCKER" ps -aq --filter "label=com.docker.compose.project=$1" 2>/dev/null
}

project_volumes() {  # <project>
  "$DOCKER" volume ls -q --filter "label=com.docker.compose.project=$1" 2>/dev/null
}

project_networks() {  # <project>
  "$DOCKER" network ls -q --filter "label=com.docker.compose.project=$1" 2>/dev/null
}

labelled_containers() {  # <task-id>
  "$DOCKER" ps -aq --filter "label=$LABEL_TASK=$1" 2>/dev/null
}

container_project() {  # <container>
  "$DOCKER" inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null
}

container_task() {  # <container>
  "$DOCKER" inspect "$1" --format "{{index .Config.Labels \"$LABEL_TASK\"}}" 2>/dev/null
}

# Gate 3: no other task record in this home may name the same project or
# worktree. Reads only this home's own records, never a shared namespace.
other_record_claims() {  # <task-id> <project> <worktree>
  local id=$1 project=$2 worktree=$3 f other
  for f in "$STATE"/*.e2e-stack; do
    [ -f "$f" ] || continue
    other=${f##*/}; other=${other%.e2e-stack}
    [ "$other" = "$id" ] && continue
    if grep -qxF "project=$project" "$f" 2>/dev/null; then
      printf '%s claims project %s\n' "$other" "$project"
    fi
    if [ -n "$worktree" ] && grep -qxF "worktree=$worktree" "$f" 2>/dev/null; then
      printf '%s claims worktree %s\n' "$other" "$worktree"
    fi
  done
}

cmd_record() {
  local id=${1-}; shift || true
  fm_pr_task_id_valid "$id" || die "invalid task id"
  require_state_dir
  local project='' stack='' repo='' scenario='' worktree='' network=''
  local created_network=0
  # Newline-delimited accumulators rather than arrays: bash 3.2 is the system
  # shell on macOS and expanding an empty array under `set -u` aborts there.
  # Every value is validated newline-free before it is appended, so the
  # delimiter can never be ambiguous.
  local compose_files='' services='' external_volumes='' ports=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --project)         project=${2-}; shift 2 || die "--project needs a value" ;;
      --stack)           stack=${2-}; shift 2 || die "--stack needs a value" ;;
      --repo)            repo=${2-}; shift 2 || die "--repo needs a value" ;;
      --scenario)        scenario=${2-}; shift 2 || die "--scenario needs a value" ;;
      --worktree)        worktree=${2-}; shift 2 || die "--worktree needs a value" ;;
      --network)         network=${2-}; shift 2 || die "--network needs a value" ;;
      --created-network) created_network=1; shift ;;
      --compose-file)
        field_valid "${2-}" || die "invalid --compose-file value"
        compose_files=$compose_files${2}$'\n'; shift 2 ;;
      --service)
        field_valid "${2-}" || die "invalid --service value"
        services=$services${2}$'\n'; shift 2 ;;
      --external-volume)
        field_valid "${2-}" || die "invalid --external-volume value"
        external_volumes=$external_volumes${2}$'\n'; shift 2 ;;
      --port)
        port_valid "${2-}" || die "invalid --port value (want NAME=port): ${2-}"
        ports=$ports${2}$'\n'; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  local v
  for v in "$project" "$stack" "$repo" "$scenario" "$worktree"; do
    field_valid "$v" \
      || die "record needs --project, --stack, --repo, --scenario and --worktree, each non-empty and free of tabs and newlines"
  done
  project_name_valid "$project" \
    || die "project name must match docker's own charset [a-z0-9][a-z0-9_-]*: $project"
  case $project in
    "$PROJECT_PREFIX"*) : ;;
    *) die "project name must begin with '$PROJECT_PREFIX' so cleanup can never select a stack this repo did not provision" ;;
  esac
  [ -n "$compose_files" ] || die "record needs at least one --compose-file"
  [ -z "$network" ] || field_valid "$network" || die "invalid network name"
  # Gate 4 is enforced at write time as well as at removal time, so an
  # unsuffixed external volume can never enter the record in the first place.
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case $v in
      *"$id"*) : ;;
      *) die "external volume '$v' does not carry the task id; an unsuffixed name is shared local data and is never task-owned" ;;
    esac
  done <<EOF
$external_volumes
EOF

  local file; file=$(record_path "$id")
  umask 077
  local tmp; tmp=$(mktemp "$STATE/.fm-e2e-stack.XXXXXX") || die "cannot stage the record"
  # shellcheck disable=SC2064 # Expand tmp now: the trap must name this file.
  trap "rm -f -- '$tmp'" EXIT HUP INT TERM
  # Re-recording a project replaces its block rather than adding a second one.
  if [ -f "$file" ]; then
    awk -v drop="project=$project" '
      BEGIN { RS = ""; ORS = "\n\n" }
      { keep = 1
        n = split($0, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] == drop) keep = 0
        if (keep && $0 != "") print $0 }
    ' "$file" > "$tmp" || die "cannot rewrite the record"
  fi
  {
    printf 'schema=fm-e2e-stack.v1\n'
    printf 'task=%s\n' "$id"
    printf 'project=%s\n' "$project"
    printf 'stack=%s\n' "$stack"
    printf 'repo=%s\n' "$repo"
    printf 'scenario=%s\n' "$scenario"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'worktree=%s\n' "$worktree"
    printf '%s' "$compose_files" | while IFS= read -r v; do
      [ -n "$v" ] && printf 'compose_file=%s\n' "$v"; done
    printf '%s' "$services" | while IFS= read -r v; do
      [ -n "$v" ] && printf 'service=%s\n' "$v"; done
    printf '%s' "$external_volumes" | while IFS= read -r v; do
      [ -n "$v" ] && printf 'external_volume=%s\n' "$v"; done
    [ -z "$network" ] || printf 'network=%s\n' "$network"
    [ "$created_network" = 1 ] && printf 'created_network=1\n'
    printf '%s' "$ports" | while IFS= read -r v; do
      [ -n "$v" ] && printf 'port=%s\n' "$v"; done
    printf '\n'
  } >> "$tmp" || die "cannot write the record"
  chmod 0600 "$tmp" || die "cannot secure the record"
  mv -f -- "$tmp" "$file" || die "cannot publish the record"
  trap - EXIT HUP INT TERM
  printf 'recorded: state/%s.e2e-stack project=%s\n' "$id" "$project"
}

cmd_read() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || die "invalid task id"
  require_state_dir
  local file; file=$(record_path "$id")
  [ -f "$file" ] || { printf 'ABSENT: state/%s.e2e-stack\n' "$id"; return 0; }
  cat "$file"
}

# Run the four gates for every recorded stack. Prints one verdict line per
# gate per stack and returns non-zero when any gate fails.
run_gates() {  # <task-id>
  local id=$1 file count i project worktree claims claim cs c ctask cproj vol mismatch
  file=$(record_path "$id")
  [ -f "$file" ] || { printf 'gate: ABSENT no record for %s\n' "$id"; return 1; }
  count=$(block_count "$file")
  [ "$count" -gt 0 ] || { printf 'gate: EMPTY record for %s\n' "$id"; return 1; }
  local rc=0 have_docker=1
  docker_available || have_docker=0
  [ "$have_docker" = 1 ] || printf 'gate: docker unavailable; container gates cannot be proved\n'
  i=0
  while [ "$i" -lt "$count" ]; do
    project=$(block_values "$file" "$i" project)
    worktree=$(block_values "$file" "$i" worktree)
    # Gate 2 first: it is a pure string test and needs no docker.
    case $project in
      "$PROJECT_PREFIX"*) printf 'gate2 ok      %s prefix\n' "$project" ;;
      *) printf 'gate2 REFUSED %s does not begin with %s\n' "$project" "$PROJECT_PREFIX"; rc=1 ;;
    esac
    # Gate 3.
    claims=$(other_record_claims "$id" "$project" "$worktree")
    if [ -n "$claims" ]; then
      printf '%s\n' "$claims" | while IFS= read -r claim; do
        [ -n "$claim" ] && printf 'gate3 REFUSED %s\n' "$claim"
      done
      rc=1
    else
      printf 'gate3 ok      %s claimed by no other task record\n' "$project"
    fi
    # Gate 4.
    while IFS= read -r vol; do
      [ -n "$vol" ] || continue
      case $vol in
        *"$id"*) printf 'gate4 ok      %s carries the task id\n' "$vol" ;;
        *) printf 'gate4 REFUSED %s carries no task id; shared local data is never task-owned\n' "$vol"; rc=1 ;;
      esac
    done < <(block_values "$file" "$i" external_volume)
    # Gate 1 needs docker.
    if [ "$have_docker" = 1 ]; then
      cs=$(project_containers "$project")
      mismatch=0
      for c in $cs; do
        ctask=$(container_task "$c")
        if [ "$ctask" != "$id" ]; then
          printf 'gate1 REFUSED container %s in %s carries task label %s\n' \
            "$c" "$project" "${ctask:-<none>}"
          mismatch=1; rc=1
        fi
      done
      if [ -n "$cs" ] && [ "$mismatch" = 0 ]; then
        printf 'gate1 ok      every container in %s carries task label %s\n' "$project" "$id"
      fi
    else
      rc=1
    fi
    i=$((i + 1))
  done
  # Gate 1, other direction: a labelled container whose project this record
  # does not name is a divergence, not a target.
  if [ "$have_docker" = 1 ]; then
    for c in $(labelled_containers "$id"); do
      cproj=$(container_project "$c")
      if ! grep -qxF "project=$cproj" "$file" 2>/dev/null; then
        printf 'gate1 REFUSED container %s labels task %s but its project %s is unrecorded\n' \
          "$c" "$id" "${cproj:-<none>}"; rc=1
      fi
    done
  fi
  return "$rc"
}

cmd_gate() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || die "invalid task id"
  require_state_dir
  run_gates "$id"
}

cmd_down() {
  local id=${1-}; shift || true
  fm_pr_task_id_valid "$id" || die "invalid task id"
  require_state_dir
  local dry=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  local file; file=$(record_path "$id")
  [ -f "$file" ] || { printf 'down: nothing recorded for %s\n' "$id"; return 0; }
  run_gates "$id" || die "ownership gates refused; nothing was removed"
  local count i project network vol f residue rc=0
  local -a args
  count=$(block_count "$file")
  i=0
  while [ "$i" -lt "$count" ]; do
    project=$(block_values "$file" "$i" project)
    args=(-p "$project")
    # Read line by line: a recorded path may legitimately contain a space, and
    # `for f in $(...)` would split one such path into two bogus -f arguments.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      args+=(-f "$f")
    done < <(block_values "$file" "$i" compose_file)
    if [ "$dry" = 1 ]; then
      printf 'down: would run %s compose %s down -v --remove-orphans\n' "$DOCKER" "${args[*]}"
    else
      "$DOCKER" compose "${args[@]}" down -v --remove-orphans --timeout 20 >&2 || rc=1
      while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        "$DOCKER" volume rm -- "$vol" >/dev/null 2>&1 || true
      done < <(block_values "$file" "$i" external_volume)
      network=$(block_values "$file" "$i" network)
      if [ -n "$network" ] && [ "$(block_values "$file" "$i" created_network)" = 1 ]; then
        "$DOCKER" network rm -- "$network" >/dev/null 2>&1 || true
      fi
      # Verify once, over everything this stack owned: a removal that leaves
      # residue is a failure, not a success, and the record stays for retry.
      residue=$(project_containers "$project")$(project_volumes "$project")$(project_networks "$project")
      while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        if "$DOCKER" volume inspect "$vol" >/dev/null 2>&1; then
          residue=$residue$vol
          printf 'down: RESIDUE external volume %s remains\n' "$vol" >&2
        fi
      done < <(block_values "$file" "$i" external_volume)
      if [ -n "$residue" ]; then
        printf 'down: RESIDUE remains for %s; the record is preserved for retry\n' "$project" >&2
        rc=1
      else
        printf 'down: %s removed (containers, volumes, network)\n' "$project"
      fi
    fi
    i=$((i + 1))
  done
  [ "$dry" = 1 ] && return 0
  [ "$rc" = 0 ] || return 1
  cmd_clear "$id"
}

cmd_clear() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || die "invalid task id"
  require_state_dir
  local file; file=$(record_path "$id")
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'clear: no record for %s\n' "$id"; return 0; }
  rm -f -- "$file" || die "cannot remove the record"
  printf 'cleared: state/%s.e2e-stack\n' "$id"
}

# Read-only report. Never a removal path: an unlabelled container can be live
# work, so this only says what it saw and who, if anyone, still claims it.
cmd_strays() {
  [ "$#" -eq 0 ] || die "strays takes no arguments"
  # Required, not optional: without the state directory every task's record
  # reads as absent and the report would claim every container is abandoned.
  require_state_dir
  docker_available || { printf 'strays: docker unavailable\n'; return 0; }
  local c name task proj wd claim live
  for c in $("$DOCKER" ps -aq 2>/dev/null); do
    name=$("$DOCKER" inspect "$c" --format '{{.Name}}' 2>/dev/null | tr -d /)
    task=$(container_task "$c")
    proj=$(container_project "$c")
    wd=$("$DOCKER" inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    if [ -n "$task" ]; then
      claim="task=$task"
      # The label is written by whoever started the container, so it is never
      # trusted as a path component: a garbled or hostile value must not send
      # this probe outside the state directory.
      if ! fm_pr_task_id_valid "$task"; then
        live=record=UNREADABLE
      elif [ -f "$STATE/$task.meta" ]; then
        live=record=LIVE
      else
        live=record=GONE
      fi
    else
      claim=unlabelled; live=record=none
    fi
    printf '%s\t%s\t%s\tworkdir=%s\tproject=%s\n' \
      "$name" "$claim" "$live" \
      "$([ -n "$wd" ] && { [ -d "$wd" ] && echo EXISTS || echo GONE; } || echo unknown)" \
      "${proj:-<none>}"
  done
}

[ "$#" -ge 1 ] || usage
SUB=$1; shift
case $SUB in
  record) cmd_record "$@" ;;
  read)   cmd_read "$@" ;;
  gate)   cmd_gate "$@" ;;
  down)   cmd_down "$@" ;;
  clear)  cmd_clear "$@" ;;
  strays) cmd_strays "$@" ;;
  -h|--help) usage ;;
  *) die "unknown subcommand: $SUB" ;;
esac
