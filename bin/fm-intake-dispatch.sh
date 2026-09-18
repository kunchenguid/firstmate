#!/usr/bin/env bash
# Create one ship or scout task and dispatch it through the existing public
# backlog, brief, and spawn commands.
#
# Usage: fm-intake-dispatch.sh --id <id> --title <title> --project <name>
#        --kind <ship|scout> --intent <text>|--intent-file <path>
#        --spec <text>|--spec-file <path> --harness <name> --model <name>
#        --effort <low|medium|high|xhigh|max|ultra|default> --backend <name>
#        [--mode <no-mistakes|direct-PR|local-only> --yolo <on|off>]
#        [--blocked-by <id>]... [--herdr-lab]
#        [--retry]
#
# All authority decisions are inputs. This command only validates the complete
# request, creates the queued item, renders and fills its instructions, and
# invokes fm-spawn.sh once. A launch failure deliberately leaves the queued item
# and its complete instructions for a later fm-spawn retry.
#
# Text flags preserve their argument bytes. File flags are preferred for long or
# multiline values; neither path uses eval or command substitution for content.
# The canonical artifact path is data/tasks/<id>; fm-task-path-lib.sh supplies
# the bounded read-only fallback to legacy data/<id> paths for --retry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-task-path-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-task-path-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

fail_usage() {
  printf 'fm-intake-dispatch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

resolve_directory() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    printf 'fm-intake-dispatch: %s directory cannot be resolved: %s\n' "$name" "$path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

scalar_valid() {  # <value>
  LC_ALL=C perl -e '
    my $v = shift;
    exit(($v eq "" || $v =~ /[\x00-\x1f\x7f]/) ? 1 : 0);
  ' -- "$1"
}

text_file_valid() {  # <path>
  LC_ALL=C perl -e '
    my $path = shift;
    open my $fh, "<", $path or exit 2;
    binmode $fh;
    local $/;
    my $v = <$fh> // "";
    exit(($v eq "" || $v !~ /\S/ || $v =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/) ? 1 : 0);
  ' -- "$1"
}

text_has_placeholder() {
  LC_ALL=C grep -F -q -e '{TASK}' -e '{FIRSTMATE_SPEC}' "$1"
}

ID=
TITLE=
PROJECT=
KIND=
INTENT=
INTENT_FILE=
SPEC=
SPEC_FILE=
HARNESS=
MODEL=
EFFORT=
BACKEND=
MODE=
YOLO=
RETRY=0
HERDR_LAB=0
ID_SET=0
TITLE_SET=0
PROJECT_SET=0
KIND_SET=0
INTENT_SET=0
SPEC_SET=0
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
DEPENDENCIES=()
POSITIONAL=()
WANT=

while [ "$#" -gt 0 ]; do
  arg=$1
  shift
  if [ -n "$WANT" ]; then
    case "$arg" in
      --*) fail_usage "--$WANT requires a value" ;;
    esac
    case "$WANT" in
      id) ID=$arg; ID_SET=1 ;;
      title) TITLE=$arg; TITLE_SET=1 ;;
      project) PROJECT=$arg; PROJECT_SET=1 ;;
      kind) KIND=$arg; KIND_SET=1 ;;
      intent) INTENT=$arg; INTENT_SET=1 ;;
      intent-file) INTENT_FILE=$arg; INTENT_SET=1 ;;
      spec) SPEC=$arg; SPEC_SET=1 ;;
      spec-file) SPEC_FILE=$arg; SPEC_SET=1 ;;
      harness) HARNESS=$arg; HARNESS_SET=1 ;;
      model) MODEL=$arg; MODEL_SET=1 ;;
      effort) EFFORT=$arg; EFFORT_SET=1 ;;
      backend) BACKEND=$arg; BACKEND_SET=1 ;;
      mode) MODE=$arg; MODE_SET=1 ;;
      yolo) YOLO=$arg; YOLO_SET=1 ;;
      blocked-by) DEPENDENCIES+=("$arg") ;;
      *) fail_usage "internal parser state for --$WANT" ;;
    esac
    WANT=
    continue
  fi
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --retry) RETRY=1 ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --id) WANT=id ;;
    --id=*) ID=${arg#--id=}; ID_SET=1 ;;
    --title) WANT=title ;;
    --title=*) TITLE=${arg#--title=}; TITLE_SET=1 ;;
    --project|--repo) WANT=project ;;
    --project=*|--repo=*) PROJECT=${arg#*=}; PROJECT_SET=1 ;;
    --kind) WANT=kind ;;
    --kind=*) KIND=${arg#--kind=}; KIND_SET=1 ;;
    --ship) KIND=ship; KIND_SET=1 ;;
    --scout) KIND=scout; KIND_SET=1 ;;
    --intent|--captain-intent) WANT=intent ;;
    --intent=*) INTENT=${arg#--intent=}; INTENT_SET=1 ;;
    --captain-intent=*) INTENT=${arg#*=}; INTENT_SET=1 ;;
    --intent-file) WANT=intent-file ;;
    --intent-file=*) INTENT_FILE=${arg#*=}; INTENT_SET=1 ;;
    --spec|--firstmate-spec) WANT=spec ;;
    --spec=*) SPEC=${arg#--spec=}; SPEC_SET=1 ;;
    --firstmate-spec=*) SPEC=${arg#*=}; SPEC_SET=1 ;;
    --spec-file) WANT=spec-file ;;
    --spec-file=*) SPEC_FILE=${arg#*=}; SPEC_SET=1 ;;
    --harness) WANT=harness ;;
    --harness=*) HARNESS=${arg#--harness=}; HARNESS_SET=1 ;;
    --model) WANT=model ;;
    --model=*) MODEL=${arg#--model=}; MODEL_SET=1 ;;
    --effort) WANT=effort ;;
    --effort=*) EFFORT=${arg#--effort=}; EFFORT_SET=1 ;;
    --backend) WANT=backend ;;
    --backend=*) BACKEND=${arg#--backend=}; BACKEND_SET=1 ;;
    --mode) WANT=mode ;;
    --mode=*) MODE=${arg#--mode=}; MODE_SET=1 ;;
    --yolo) WANT=yolo ;;
    --yolo=*) YOLO=${arg#--yolo=}; YOLO_SET=1 ;;
    --blocked-by|--depends-on|--dependency) WANT=blocked-by ;;
    --blocked-by=*|--depends-on=*|--dependency=*) DEPENDENCIES+=("${arg#*=}") ;;
    --*) fail_usage "unknown option: $arg" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
[ -z "$WANT" ] || fail_usage "--$WANT requires a value"
[ "${#POSITIONAL[@]}" -eq 0 ] || fail_usage "unexpected positional argument: ${POSITIONAL[0]}"

[ "$ID_SET" -eq 1 ] || fail_usage "--id is required"
[ "$PROJECT_SET" -eq 1 ] || fail_usage "--project is required"
[ "$KIND_SET" -eq 1 ] || fail_usage "--kind is required"
[ "$HARNESS_SET" -eq 1 ] || fail_usage "--harness is required"
[ "$MODEL_SET" -eq 1 ] || fail_usage "--model is required"
[ "$EFFORT_SET" -eq 1 ] || fail_usage "--effort is required"
[ "$BACKEND_SET" -eq 1 ] || fail_usage "--backend is required"
if [ "$RETRY" -eq 0 ]; then
  [ "$TITLE_SET" -eq 1 ] || fail_usage "--title is required"
  [ "$INTENT_SET" -eq 1 ] || fail_usage "--intent or --intent-file is required"
  [ "$SPEC_SET" -eq 1 ] || fail_usage "--spec or --spec-file is required"
fi
[ "$INTENT_SET" -eq 0 ] || [ "$INTENT_FILE" = "" ] || [ "$INTENT" = "" ] || fail_usage "provide one of --intent and --intent-file"
[ "$SPEC_SET" -eq 0 ] || [ "$SPEC_FILE" = "" ] || [ "$SPEC" = "" ] || fail_usage "provide one of --spec and --spec-file"

case "$KIND" in ship|scout) ;; *) fail_usage "--kind must be ship or scout" ;; esac
case "$HARNESS" in
  claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy) ;;
  *) fail_usage "--harness is not a verified worker harness: $HARNESS" ;;
esac
case "$EFFORT" in low|medium|high|xhigh|max|ultra|default) ;;
  *) fail_usage "--effort must be low, medium, high, xhigh, max, ultra, or default" ;;
esac
case "$BACKEND" in
  '') fail_usage "--backend requires a non-empty value" ;;
  *) ;;
esac
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || fail_usage "ship intake requires --mode"
  [ "$YOLO_SET" -eq 1 ] || fail_usage "ship intake requires --yolo"
  case "$MODE" in no-mistakes|direct-PR|local-only) ;; *) fail_usage "--mode must be no-mistakes, direct-PR, or local-only" ;; esac
  case "$YOLO" in on|off) ;; *) fail_usage "--yolo must be on or off" ;; esac
else
  [ "$MODE_SET" -eq 0 ] || fail_usage "--mode applies only to ships"
  [ "$YOLO_SET" -eq 0 ] || fail_usage "--yolo applies only to ships"
fi
fm_task_path_id_valid "$ID" || fail_usage "invalid task id: $ID"
[ "${#ID}" -le 64 ] || fail_usage "task id is longer than 64 characters"
scalar_valid "$TITLE" || [ "$TITLE_SET" -eq 0 ] || fail_usage "title must be non-empty and contain no control bytes"
scalar_valid "$PROJECT" || fail_usage "project must be non-empty and contain no control bytes"
scalar_valid "$HARNESS" || fail_usage "harness must contain no control bytes"
scalar_valid "$MODEL" || fail_usage "model must be non-empty and contain no control bytes"
scalar_valid "$EFFORT" || fail_usage "effort must contain no control bytes"
scalar_valid "$BACKEND" || fail_usage "backend must contain no control bytes"
for dependency in "${DEPENDENCIES[@]+${DEPENDENCIES[@]}}"; do
  fm_task_path_id_valid "$dependency" || fail_usage "invalid dependency id: $dependency"
done

# Resolve the active home before any lock or task mutation. The data directory
# must already exist because fm-tasks-axi owns its addressing and will refuse a
# home it cannot safely bind.
FM_HOME=$(resolve_directory FM_HOME "$FM_HOME") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
[ -d "$DATA" ] && [ ! -L "$DATA" ] || {
  printf 'fm-intake-dispatch: data directory is not a real directory: %s\n' "$DATA" >&2
  exit 1
}
export FM_HOME
FM_DATA_OVERRIDE=$DATA
FM_STATE_OVERRIDE=$STATE
export FM_DATA_OVERRIDE FM_STATE_OVERRIDE
if [ -e "$DATA/tasks" ] || [ -L "$DATA/tasks" ]; then
  [ -d "$DATA/tasks" ] && [ ! -L "$DATA/tasks" ] || {
    printf 'fm-intake-dispatch: canonical task directory is not a real directory: %s/tasks\n' "$DATA" >&2
    exit 1
  }
fi

# Backend validation is a read-only public adapter check. Harness executable and
# model catalog checks remain owned by fm-spawn.sh; a failed launch is preserved
# as a retryable queued task rather than silently selecting another profile.
BACKEND_DIAG=$(mktemp "${TMPDIR:-/tmp}/fm-intake-backend.XXXXXX") || exit 1
if ! fm_backend_validate_spawn "$BACKEND" >"$BACKEND_DIAG" 2>&1; then
  printf 'fm-intake-dispatch: refused id=%s during backend validation\n' "$ID" >&2
  cat "$BACKEND_DIAG" >&2
  rm -f "$BACKEND_DIAG"
  exit 1
fi
rm -f "$BACKEND_DIAG"
if [ "$EFFORT" = ultra ]; then
  NATIVE_MODEL=$MODEL
  if ! "$FM_ROOT/bin/fm-harness.sh" validate-native-effort "$HARNESS" "$NATIVE_MODEL" ultra >/dev/null 2>&1; then
    printf 'fm-intake-dispatch: refused id=%s: ultra effort requires a supported native Pi model\n' "$ID" >&2
    exit 1
  fi
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-dispatch.XXXXXX") || exit 1
LOCK_DIR=
TASK_DIR_CREATED=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT/HUP/INT/TERM trap.
cleanup() {
  if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT HUP INT TERM

# Stage text before taking the home lock. This validates and preserves every
# newline without placing an incomplete instruction in the task directory.
stage_text() {  # <destination> <value> <file> <label>
  local destination=$1 value=$2 source=$3 label=$4
  if [ -n "$source" ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || {
      printf 'fm-intake-dispatch: %s is not a readable regular file: %s\n' "$label" "$source" >&2
      return 1
    }
    cp "$source" "$destination" || {
      printf 'fm-intake-dispatch: could not read %s: %s\n' "$label" "$source" >&2
      return 1
    }
  else
    printf '%s' "$value" > "$destination" || return 1
  fi
  text_file_valid "$destination" || {
    printf 'fm-intake-dispatch: %s must be non-empty text without control bytes\n' "$label" >&2
    return 1
  }
  if text_has_placeholder "$destination"; then
    printf 'fm-intake-dispatch: %s must not contain brief placeholders\n' "$label" >&2
    return 1
  fi
  return 0
}
if [ "$RETRY" -eq 0 ]; then
  INTENT_STAGE="$TMP_DIR/intent"
  SPEC_STAGE="$TMP_DIR/spec"
  stage_text "$INTENT_STAGE" "$INTENT" "$INTENT_FILE" captain intent || exit 1
  stage_text "$SPEC_STAGE" "$SPEC" "$SPEC_FILE" Firstmate spec || exit 1
fi

# State is the only operational directory this command may create. The task-id
# lock makes two same-id calls deterministic: one owns the intake, the other
# refuses before either can publish a row or instructions.
if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  mkdir -p "$STATE" || {
    printf 'fm-intake-dispatch: could not create state directory: %s\n' "$STATE" >&2
    exit 1
  }
fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  printf 'fm-intake-dispatch: state directory is not a real directory: %s\n' "$STATE" >&2
  exit 1
}
LOCK_DIR="$STATE/.intake-$ID.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf 'fm-intake-dispatch: refused id=%s: another intake is already handling this id\n' "$ID" >&2
  exit 1
fi

CANON_TASK_DIR=$(fm_task_dir "$DATA" "$ID") || {
  printf 'fm-intake-dispatch: invalid canonical task path for %s\n' "$ID" >&2
  exit 1
}
LEGACY_TASK_DIR=$(fm_task_legacy_dir "$DATA" "$ID") || {
  printf 'fm-intake-dispatch: invalid legacy task path for %s\n' "$ID" >&2
  exit 1
}
CANON_EXISTED=0
LEGACY_EXISTED=0
[ -e "$CANON_TASK_DIR" ] || [ -L "$CANON_TASK_DIR" ] && CANON_EXISTED=1
[ -e "$LEGACY_TASK_DIR" ] || [ -L "$LEGACY_TASK_DIR" ] && LEGACY_EXISTED=1

show_row() {
  local output=$1 status
  if "$FM_ROOT/bin/fm-tasks-axi.sh" show "$ID" >"$output" 2>&1; then
    return 0
  else
    status=$?
  fi
  if grep -q '^code: NOT_FOUND$' "$output"; then
    return 1
  fi
  return "$status"
}

ROW_SHOW="$TMP_DIR/row-show"
if show_row "$ROW_SHOW"; then
  ROW_EXISTS=1
else
  row_status=$?
  if [ "$row_status" -eq 1 ]; then
    ROW_EXISTS=0
  else
    printf 'fm-intake-dispatch: refused id=%s while checking the backlog\n' "$ID" >&2
    cat "$ROW_SHOW" >&2
    exit 1
  fi
fi

if [ "$RETRY" -eq 1 ]; then
  [ "$ROW_EXISTS" -eq 1 ] || {
    printf 'fm-intake-dispatch: retry refused for %s: no existing queued task\n' "$ID" >&2
    exit 1
  }
  [ "$CANON_EXISTED" -eq 1 ] || [ "$LEGACY_EXISTED" -eq 1 ] || {
    printf 'fm-intake-dispatch: retry refused for %s: no existing task instructions\n' "$ID" >&2
    exit 1
  }
  grep -q '^  state: queued$' "$ROW_SHOW" || {
    printf 'fm-intake-dispatch: retry refused for %s: backlog item is not queued\n' "$ID" >&2
    cat "$ROW_SHOW" >&2
    exit 1
  }
  grep -q '^  blocked: no$' "$ROW_SHOW" || {
    printf 'fm-intake-dispatch: retry refused for %s: backlog item is blocked\n' "$ID" >&2
    cat "$ROW_SHOW" >&2
    exit 1
  }
  grep -q '^  held: no$' "$ROW_SHOW" || {
    printf 'fm-intake-dispatch: retry refused for %s: backlog item is held\n' "$ID" >&2
    cat "$ROW_SHOW" >&2
    exit 1
  }
  grep -F -q "  kind: $KIND" "$ROW_SHOW" || {
    printf 'fm-intake-dispatch: retry refused for %s: kind does not match the existing task\n' "$ID" >&2
    exit 1
  }
  grep -F -q "  repo: $PROJECT" "$ROW_SHOW" || {
    printf 'fm-intake-dispatch: retry refused for %s: project does not match the existing task\n' "$ID" >&2
    exit 1
  }
  RETRY_BRIEF=$(fm_task_read_path "$DATA" "$ID" brief.md) || {
    printf 'fm-intake-dispatch: retry refused for %s: task instructions are unsafe\n' "$ID" >&2
    exit 1
  }
  [ -f "$RETRY_BRIEF" ] && [ ! -L "$RETRY_BRIEF" ] || {
    printf 'fm-intake-dispatch: retry refused for %s: task instructions are missing\n' "$ID" >&2
    exit 1
  }
  if ! grep -q '^## Captain' "$RETRY_BRIEF" || ! grep -q '^## Firstmate spec' "$RETRY_BRIEF"; then
    printf 'fm-intake-dispatch: retry refused for %s: task instructions are incomplete\n' "$ID" >&2
    exit 1
  fi
  if text_has_placeholder "$RETRY_BRIEF"; then
    printf 'fm-intake-dispatch: retry refused for %s: task instructions still contain placeholders\n' "$ID" >&2
    exit 1
  fi
else
  [ "$ROW_EXISTS" -eq 0 ] || {
    printf 'fm-intake-dispatch: refused id=%s: backlog item already exists\n' "$ID" >&2
    cat "$ROW_SHOW" >&2
    exit 1
  }
  [ "$CANON_EXISTED" -eq 0 ] && [ "$LEGACY_EXISTED" -eq 0 ] || {
    printf 'fm-intake-dispatch: refused id=%s: task directory already exists\n' "$ID" >&2
    exit 1
  }
  for dependency in "${DEPENDENCIES[@]+${DEPENDENCIES[@]}}"; do
    DEP_SHOW="$TMP_DIR/dependency-$dependency"
    if ! "$FM_ROOT/bin/fm-tasks-axi.sh" show "$dependency" >"$DEP_SHOW" 2>&1; then
      printf 'fm-intake-dispatch: refused id=%s: dependency %s is unavailable\n' "$ID" "$dependency" >&2
      cat "$DEP_SHOW" >&2
      exit 1
    fi
  done

  ADD_LOG="$TMP_DIR/add"
  ADD_ARGS=(add "$ID" "$TITLE" --kind "$KIND" --repo "$PROJECT" --queue)
  for dependency in "${DEPENDENCIES[@]+${DEPENDENCIES[@]}}"; do
    ADD_ARGS+=(--blocked-by "$dependency")
  done
  if "$FM_ROOT/bin/fm-tasks-axi.sh" "${ADD_ARGS[@]}" >"$ADD_LOG" 2>&1; then
    :
  else
    printf 'fm-intake-dispatch: failed id=%s phase=backlog\n' "$ID" >&2
    cat "$ADD_LOG" >&2
    exit 1
  fi

  BRIEF_LOG="$TMP_DIR/brief"
  BRIEF_ARGS=("$ID" "$PROJECT")
  if [ "$KIND" = scout ]; then
    BRIEF_ARGS+=(--scout)
  else
    BRIEF_ARGS+=(--mode "$MODE")
  fi
  [ "$HERDR_LAB" -eq 1 ] && BRIEF_ARGS+=(--herdr-lab)
  if "$FM_ROOT/bin/fm-brief.sh" "${BRIEF_ARGS[@]}" >"$BRIEF_LOG" 2>&1; then
    :
  else
    printf 'fm-intake-dispatch: failed id=%s phase=instructions\n' "$ID" >&2
    cat "$BRIEF_LOG" >&2
    if "$FM_ROOT/bin/fm-tasks-axi.sh" rm "$ID" >"$TMP_DIR/rollback-row" 2>&1; then
      :
    else
      cat "$TMP_DIR/rollback-row" >&2
    fi
    if [ "$CANON_EXISTED" -eq 0 ] && [ -d "$CANON_TASK_DIR" ] && [ ! -L "$CANON_TASK_DIR" ]; then
      rm -rf -- "$CANON_TASK_DIR" || true
    fi
    exit 1
  fi
  if [ -d "$CANON_TASK_DIR" ] && [ ! -L "$CANON_TASK_DIR" ] && [ "$CANON_EXISTED" -eq 0 ]; then
    TASK_DIR_CREATED=1
  fi
  BRIEF=$(fm_task_path "$DATA" "$ID" brief.md) || {
    printf 'fm-intake-dispatch: failed id=%s phase=instructions: canonical brief path is invalid\n' "$ID" >&2
    exit 1
  }
  FILL_LOG="$TMP_DIR/fill"
  if ! LC_ALL=C perl -0 - "$BRIEF" "$INTENT_STAGE" "$SPEC_STAGE" "$TMP_DIR/filled" >"$FILL_LOG" 2>&1 <<'PERL'
use strict;
use warnings;
my ($brief_path, $intent_path, $spec_path, $output_path) = @ARGV;
sub read_raw {
  my ($path) = @_;
  open my $fh, '<', $path or die "$path: $!\n";
  binmode $fh;
  local $/;
  return <$fh> // '';
}
my $brief = read_raw($brief_path);
my $intent = read_raw($intent_path);
my $spec = read_raw($spec_path);
my $task_count = ($brief =~ s/\{TASK\}/$intent/g);
my $spec_count = ($brief =~ s/\{FIRSTMATE_SPEC\}/$spec/g);
die "brief fill expected one task placeholder and one spec placeholder\n"
  unless $task_count == 1 && $spec_count == 1;
open my $out, '>', $output_path or die "$output_path: $!\n";
binmode $out;
print {$out} $brief or die "$output_path: $!\n";
close $out or die "$output_path: $!\n";
PERL
  then
    printf 'fm-intake-dispatch: failed id=%s phase=instructions\n' "$ID" >&2
    cat "$FILL_LOG" >&2
    if "$FM_ROOT/bin/fm-tasks-axi.sh" rm "$ID" >"$TMP_DIR/rollback-row" 2>&1; then :; else cat "$TMP_DIR/rollback-row" >&2; fi
    if [ "$TASK_DIR_CREATED" -eq 1 ]; then rm -rf -- "$CANON_TASK_DIR" || true; fi
    exit 1
  fi
  if ! mv "$TMP_DIR/filled" "$BRIEF"; then
    printf 'fm-intake-dispatch: failed id=%s phase=instructions: could not publish complete instructions\n' "$ID" >&2
    if "$FM_ROOT/bin/fm-tasks-axi.sh" rm "$ID" >"$TMP_DIR/rollback-row" 2>&1; then :; else cat "$TMP_DIR/rollback-row" >&2; fi
    if [ "$TASK_DIR_CREATED" -eq 1 ]; then rm -rf -- "$CANON_TASK_DIR" || true; fi
    exit 1
  fi
  if text_has_placeholder "$BRIEF"; then
    printf 'fm-intake-dispatch: failed id=%s phase=instructions: generated instructions retain a placeholder\n' "$ID" >&2
    if "$FM_ROOT/bin/fm-tasks-axi.sh" rm "$ID" >"$TMP_DIR/rollback-row" 2>&1; then :; else cat "$TMP_DIR/rollback-row" >&2; fi
    if [ "$TASK_DIR_CREATED" -eq 1 ]; then rm -rf -- "$CANON_TASK_DIR" || true; fi
    exit 1
  fi
fi

SPAWN_LOG="$TMP_DIR/spawn"
SPAWN_ARGS=("$ID" "$PROJECT" --harness "$HARNESS" --model "$MODEL" --backend "$BACKEND")
if [ "$EFFORT" != default ]; then
  SPAWN_ARGS+=(--effort "$EFFORT")
fi
if [ "$KIND" = scout ]; then
  SPAWN_ARGS+=(--scout)
else
  SPAWN_ARGS+=(--mode "$MODE" --yolo "$YOLO")
fi
if "$FM_ROOT/bin/fm-spawn.sh" "${SPAWN_ARGS[@]}" >"$SPAWN_LOG" 2>&1; then
  printf 'intake-dispatch: dispatched id=%s kind=%s\n' "$ID" "$KIND"
  exit 0
fi
printf 'intake-dispatch: launch failed id=%s; queued task and complete instructions preserved for retry\n' "$ID" >&2
cat "$SPAWN_LOG" >&2
exit 1
