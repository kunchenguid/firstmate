#!/usr/bin/env bash
# Create and manage bounded writable child agents for one ordinary Herdr worker.
#
# Parent-worker usage, from inside the recorded parent pane:
#   fm-child.sh create <name> --instructions <file> --path <repo-relative-path> [--path <path>...]
#   fm-child.sh list
#   fm-child.sh inspect <name>
#   fm-child.sh stop <name>
#   fm-child.sh ready
#   fm-child.sh cleanup
#
# `create` accepts only a regular instruction file outside the repository and
# one or more explicit non-overlapping repository-relative path assignments.
# It splits the recorded parent pane, verifies the response stayed in the same
# Herdr workspace and tab, starts the parent's recorded verified harness with
# the same model and effort profile, and sends generated child instructions.
# Private records, reports, command guards, and completion results live under
# the parent's recorded /tmp/fm-<task-id>/children directory, never in the repo.
# At most three child panes may exist for one parent. A child environment cannot
# invoke this helper, so delegation cannot recurse through the supported path.
# `ready` succeeds only after every child has reported completion and its pane
# has been stopped. Parent instructions require it before Git mutation, final
# validation, no-mistakes, push, or PR work.
#
# Teardown-only usage:
#   FM_CHILD_TEARDOWN=1 fm-child.sh quiesce <task-id>
#   FM_CHILD_TEARDOWN=1 fm-child.sh cleanup <task-id>
# `quiesce` stops exact recorded child panes but retains private records so a
# refused teardown loses no reports. `cleanup` removes records only after every
# child pane is confirmed absent. Neither action resets or discards repo edits.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || { echo "error: could not load the Herdr runtime adapter" >&2; exit 1; }
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_CHILD_MAX=3
FM_CHILD_LOCK=
FM_CHILD_LOCK_HELD=0
FM_CHILD_CREATE_STAGING=
FM_CHILD_CREATE_PANE=
FM_CHILD_PARENT_ID=
FM_CHILD_PARENT_SESSION=
FM_CHILD_PARENT_WORKSPACE=
FM_CHILD_PARENT_TAB=
FM_CHILD_PARENT_PANE=
FM_CHILD_PARENT_WORKTREE=
FM_CHILD_PARENT_HARNESS=
FM_CHILD_PARENT_MODEL=
FM_CHILD_PARENT_EFFORT=
FM_CHILD_PARENT_KIND=
FM_CHILD_TASK_TMP=
FM_CHILD_ROOT=

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

fm_child_release_lock() {
  if [ -n "$FM_CHILD_CREATE_PANE" ] && [ -n "$FM_CHILD_PARENT_SESSION" ]; then
    fm_child_close_created_pane "$FM_CHILD_CREATE_PANE" || true
    FM_CHILD_CREATE_PANE=
  fi
  if [ -n "$FM_CHILD_CREATE_STAGING" ] \
     && [ -e "$FM_CHILD_CREATE_STAGING" ] \
     && [ "$(dirname "$FM_CHILD_CREATE_STAGING")" = "$FM_CHILD_ROOT" ]; then
    rm -rf "$FM_CHILD_CREATE_STAGING"
  fi
  if [ "$FM_CHILD_LOCK_HELD" = 1 ]; then
    FM_CHILD_LOCK_HELD=0
    fm_lock_release "$FM_CHILD_LOCK" || true
  fi
}
trap fm_child_release_lock EXIT

fm_child_name_valid() {  # <name>
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

fm_child_task_id_valid() {  # <id>
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_child_meta_exact() {  # <meta> <key>
  local meta=$1 key=$2 count value
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_child_meta_optional_exact() {  # <meta> <key> <default>
  local meta=$1 key=$2 default=$3 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  case "$count" in
    0) printf '%s' "$default" ;;
    1) grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2- ;;
    *) return 1 ;;
  esac
}

fm_child_real_dir() {  # <path>
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_child_same_or_below() {  # <root> <path>
  [ "$1" = "$2" ] && return 0
  case "$2" in
    "$1"/*) return 0 ;;
  esac
  return 1
}

fm_child_expected_agent() {  # <harness>
  case "$1" in
    claude|codex|opencode|pi|grok|kimi) printf '%s' "$1" ;;
    pi-signed) printf '%s' pi ;;
    *) return 1 ;;
  esac
}

fm_child_parent_live_snapshot() {
  local pane_json agent_json pane workspace tab cwd agent expected status
  pane_json=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane get "$FM_CHILD_PARENT_PANE" 2>/dev/null) \
    || die "recorded parent pane is missing or unreadable"
  pane=$(printf '%s' "$pane_json" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  workspace=$(printf '%s' "$pane_json" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$pane_json" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  cwd=$(printf '%s' "$pane_json" | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null)
  [ "$pane" = "$FM_CHILD_PARENT_PANE" ] \
    && [ "$workspace" = "$FM_CHILD_PARENT_WORKSPACE" ] \
    && [ "$tab" = "$FM_CHILD_PARENT_TAB" ] \
    || die "recorded parent ownership does not match the live Herdr pane, workspace, and tab"
  [ -n "$cwd" ] || die "recorded parent pane has no readable foreground working directory"
  cwd=$(fm_child_real_dir "$cwd") || die "recorded parent pane working directory is not inspectable"
  fm_child_same_or_below "$FM_CHILD_PARENT_WORKTREE" "$cwd" \
    || die "recorded parent pane is not running inside its isolated working copy"

  agent_json=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" agent get "$FM_CHILD_PARENT_PANE" 2>/dev/null) \
    || die "recorded parent pane has no live registered worker"
  agent=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  status=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  expected=$(fm_child_expected_agent "$FM_CHILD_PARENT_HARNESS") \
    || die "parent runtime '$FM_CHILD_PARENT_HARNESS' is unsupported for child panes"
  [ "$agent" = "$expected" ] || die "live parent worker identity '$agent' does not match recorded runtime '$FM_CHILD_PARENT_HARNESS'"
  case "$status" in
    working|idle|done|blocked) ;;
    *) die "live parent worker has an unreadable state" ;;
  esac
}

fm_child_load_parent_meta() {  # <meta> <expected-id>
  local meta=$1 expected_id=$2 backend binding worktree worktree_real tasktmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "missing regular parent metadata"
  backend=$(fm_child_meta_optional_exact "$meta" backend tmux) || die "ambiguous parent backend metadata"
  [ "$backend" = herdr ] || die "child panes are supported only for an ordinary Herdr-backed worker"
  FM_CHILD_PARENT_ID=$expected_id
  binding=$(fm_child_meta_exact "$meta" endpoint_task_id) || die "parent metadata has no exact task binding"
  [ "$binding" = "$expected_id" ] || die "parent metadata belongs to task '$binding', not '$expected_id'"
  FM_CHILD_PARENT_KIND=$(fm_child_meta_optional_exact "$meta" kind ship) || die "ambiguous parent kind metadata"
  case "$FM_CHILD_PARENT_KIND" in
    ship|scout) ;;
    *) die "only ordinary ship and scout workers may create child panes" ;;
  esac
  FM_CHILD_PARENT_SESSION=$(fm_child_meta_exact "$meta" herdr_session) || die "parent metadata has no exact Herdr session"
  FM_CHILD_PARENT_WORKSPACE=$(fm_child_meta_exact "$meta" herdr_workspace_id) || die "parent metadata has no exact Herdr workspace"
  FM_CHILD_PARENT_TAB=$(fm_child_meta_exact "$meta" herdr_tab_id) || die "parent metadata has no exact Herdr tab"
  FM_CHILD_PARENT_PANE=$(fm_child_meta_exact "$meta" herdr_pane_id) || die "parent metadata has no exact Herdr pane"
  [ "$(fm_child_meta_exact "$meta" window)" = "$FM_CHILD_PARENT_SESSION:$FM_CHILD_PARENT_PANE" ] \
    || die "parent endpoint metadata is inconsistent"
  FM_CHILD_PARENT_HARNESS=$(fm_child_meta_exact "$meta" harness) || die "parent metadata has no exact worker runtime"
  fm_child_expected_agent "$FM_CHILD_PARENT_HARNESS" >/dev/null \
    || die "parent runtime '$FM_CHILD_PARENT_HARNESS' is unsupported for child panes"
  FM_CHILD_PARENT_MODEL=$(fm_child_meta_exact "$meta" model) || die "parent metadata has no exact model profile"
  FM_CHILD_PARENT_EFFORT=$(fm_child_meta_exact "$meta" effort) || die "parent metadata has no exact effort profile"
  case "$FM_CHILD_PARENT_EFFORT" in
    default|low|medium|high|xhigh|max) ;;
    *) die "parent effort profile is invalid" ;;
  esac
  worktree=$(fm_child_meta_exact "$meta" worktree) || die "parent metadata has no exact working copy"
  worktree_real=$(fm_child_real_dir "$worktree") || die "parent working copy is missing or unreadable"
  [ "$(git -C "$worktree_real" rev-parse --show-toplevel 2>/dev/null)" = "$worktree_real" ] \
    || die "parent working copy is not an isolated repository root"
  FM_CHILD_PARENT_WORKTREE=$worktree_real
  tasktmp=$(fm_child_meta_exact "$meta" tasktmp) || die "parent metadata has no private temporary area"
  [ "$tasktmp" = "/tmp/fm-$expected_id" ] || die "parent private temporary area is not the expected task-owned path"
  FM_CHILD_TASK_TMP=$tasktmp
  FM_CHILD_ROOT="$tasktmp/children"
}

fm_child_discover_parent() {
  local current_pane current_top meta id matches=0 matched=
  [ "${FM_CHILD_AGENT:-}" != 1 ] || die "child agents cannot create or manage child panes"
  [ "${HERDR_ENV:-}" = 1 ] || die "this command must run inside the recorded Herdr parent pane"
  current_pane=${HERDR_PANE_ID:-}
  [ -n "$current_pane" ] || die "current Herdr pane identity is missing"
  current_top=$(git rev-parse --show-toplevel 2>/dev/null) || die "current working directory is not in the parent repository"
  current_top=$(fm_child_real_dir "$current_top") || die "current repository root is unreadable"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_child_meta_optional_exact "$meta" backend tmux 2>/dev/null || true)" = herdr ] || continue
    [ "$(fm_child_meta_optional_exact "$meta" herdr_pane_id '' 2>/dev/null || true)" = "$current_pane" ] || continue
    [ "$(fm_child_meta_optional_exact "$meta" worktree '' 2>/dev/null || true)" = "$current_top" ] || continue
    matches=$((matches + 1))
    matched=$meta
  done
  [ "$matches" -eq 1 ] || die "parent ownership is missing or ambiguous for the current Herdr pane"
  id=$(basename "$matched" .meta)
  fm_child_task_id_valid "$id" || die "parent task id is invalid"
  fm_child_load_parent_meta "$matched" "$id"
  [ "$FM_CHILD_PARENT_PANE" = "$current_pane" ] || die "current pane is not the recorded parent pane"
  fm_child_parent_live_snapshot
}

fm_child_load_teardown_parent() {  # <id>
  local id=$1
  [ "${FM_CHILD_AGENT:-}" != 1 ] || die "child agents cannot manage child panes"
  [ "${FM_CHILD_TEARDOWN:-}" = 1 ] || die "off-pane child cleanup is reserved for parent teardown"
  fm_child_task_id_valid "$id" || die "invalid teardown task id"
  fm_child_load_parent_meta "$STATE/$id.meta" "$id"
}

fm_child_acquire_lock() {
  local attempt=0
  mkdir -p "$FM_CHILD_TASK_TMP" || die "cannot create the parent private temporary area"
  chmod 700 "$FM_CHILD_TASK_TMP" 2>/dev/null || true
  [ -d "$FM_CHILD_TASK_TMP" ] && [ ! -L "$FM_CHILD_TASK_TMP" ] \
    || die "parent private temporary area is unsafe"
  FM_CHILD_LOCK="$FM_CHILD_TASK_TMP/.children.lock"
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$FM_CHILD_LOCK"; then
      FM_CHILD_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  die "could not acquire the parent child-pane lifecycle lock"
}

fm_child_path_lexical_valid() {  # <relative-path>
  case "$1" in
    ''|.|..|/*|./*|*/.|*/..|*//*|*'*'*|*'?'*|*'['*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    .git|.git/*|.no-mistakes|.no-mistakes/*) return 1 ;;
  esac
  return 0
}

fm_child_path_valid() {  # <relative-path>
  local rel=$1 current component rest
  fm_child_path_lexical_valid "$rel" || return 1
  current=$FM_CHILD_PARENT_WORKTREE
  rest=$rel
  while :; do
    component=${rest%%/*}
    case "$component" in ''|.|..) return 1 ;; esac
    current="$current/$component"
    [ ! -L "$current" ] || return 1
    if [ "$rest" = "$component" ]; then
      break
    fi
    [ ! -e "$current" ] || [ -d "$current" ] || return 1
    rest=${rest#*/}
  done
  return 0
}

fm_child_paths_overlap() {  # <a> <b>
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

fm_child_record_meta() {  # <child-dir> <key>
  fm_child_meta_exact "$1/meta" "$2"
}

fm_child_record_valid() {  # <child-dir>
  local dir=$1 name path
  name=$(basename "$dir")
  fm_child_name_valid "$name" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    && [ -f "$dir/meta" ] && [ ! -L "$dir/meta" ] \
    && [ -f "$dir/paths" ] && [ ! -L "$dir/paths" ] && [ -s "$dir/paths" ] \
    && [ -f "$dir/state" ] && [ ! -L "$dir/state" ] || return 1
  [ "$(fm_child_record_meta "$dir" version 2>/dev/null || true)" = 1 ] \
    && [ "$(fm_child_record_meta "$dir" child_name 2>/dev/null || true)" = "$name" ] \
    && [ "$(fm_child_record_meta "$dir" parent_task_id 2>/dev/null || true)" = "$FM_CHILD_PARENT_ID" ] \
    && [ "$(fm_child_record_meta "$dir" parent_session 2>/dev/null || true)" = "$FM_CHILD_PARENT_SESSION" ] \
    && [ "$(fm_child_record_meta "$dir" parent_workspace_id 2>/dev/null || true)" = "$FM_CHILD_PARENT_WORKSPACE" ] \
    && [ "$(fm_child_record_meta "$dir" parent_tab_id 2>/dev/null || true)" = "$FM_CHILD_PARENT_TAB" ] \
    && [ "$(fm_child_record_meta "$dir" parent_pane_id 2>/dev/null || true)" = "$FM_CHILD_PARENT_PANE" ] \
    && [ "$(fm_child_record_meta "$dir" harness 2>/dev/null || true)" = "$FM_CHILD_PARENT_HARNESS" ] \
    && [ "$(fm_child_record_meta "$dir" model 2>/dev/null || true)" = "$FM_CHILD_PARENT_MODEL" ] \
    && [ "$(fm_child_record_meta "$dir" effort 2>/dev/null || true)" = "$FM_CHILD_PARENT_EFFORT" ] \
    && [ "$(fm_child_record_meta "$dir" kind 2>/dev/null || true)" = "$FM_CHILD_PARENT_KIND" ] \
    && [ "$(fm_child_record_meta "$dir" worktree 2>/dev/null || true)" = "$FM_CHILD_PARENT_WORKTREE" ] \
    || return 1
  while IFS= read -r path; do
    [ -n "$path" ] && fm_child_path_lexical_valid "$path" || return 1
  done < "$dir/paths"
}

fm_child_validate_records() {
  local entry name
  [ -e "$FM_CHILD_ROOT" ] || [ -L "$FM_CHILD_ROOT" ] || return 0
  [ -d "$FM_CHILD_ROOT" ] && [ ! -L "$FM_CHILD_ROOT" ] || die "private child record directory is unsafe"
  for entry in "$FM_CHILD_ROOT"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    if [ ! -d "$entry" ] || [ -L "$entry" ] || ! fm_child_name_valid "$name"; then
      die "private child record entry '$name' is unsafe"
    fi
    fm_child_record_valid "$entry" || die "private child record '$name' is malformed or belongs to another parent"
  done
}

fm_child_record_relation() {  # <child-dir> -> 0 exact, 1 missing, 2 ambiguous
  local dir=$1 pane session workspace tab out live_pane live_workspace live_tab
  fm_child_record_valid "$dir" || return 2
  pane=$(fm_child_record_meta "$dir" child_pane_id) || return 2
  session=$(fm_child_record_meta "$dir" parent_session) || return 2
  workspace=$(fm_child_record_meta "$dir" parent_workspace_id) || return 2
  tab=$(fm_child_record_meta "$dir" parent_tab_id) || return 2
  [ "$session" = "$FM_CHILD_PARENT_SESSION" ] \
    && [ "$workspace" = "$FM_CHILD_PARENT_WORKSPACE" ] \
    && [ "$tab" = "$FM_CHILD_PARENT_TAB" ] \
    && [ "$pane" != "$FM_CHILD_PARENT_PANE" ] || return 2
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1) || {
    if printf '%s' "$out" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      return 1
    fi
    return 2
  }
  live_pane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  live_workspace=$(printf '%s' "$out" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  live_tab=$(printf '%s' "$out" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  [ "$live_pane" = "$pane" ] \
    && [ "$live_workspace" = "$workspace" ] \
    && [ "$live_tab" = "$tab" ] || return 2
  return 0
}

fm_child_state() {  # <child-dir>
  local dir=$1 relation agent_out status persisted
  persisted=$(cat "$dir/state" 2>/dev/null || true)
  if fm_child_record_relation "$dir"; then
    if [ -f "$dir/result" ] && [ ! -L "$dir/result" ]; then
      printf 'complete'
      return 0
    fi
    agent_out=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" agent get "$(fm_child_record_meta "$dir" child_pane_id)" 2>&1) || {
      if printf '%s' "$agent_out" | jq -e '.error.code == "agent_not_found"' >/dev/null 2>&1; then
        printf 'dead'
      else
        printf 'ambiguous'
      fi
      return 0
    }
    status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
    case "$status" in
      working|idle|done|blocked) printf 'running:%s' "$status" ;;
      *) printf 'ambiguous' ;;
    esac
  else
    relation=$?
    if [ "$relation" -eq 1 ]; then
      if [ -f "$dir/result" ] && [ ! -L "$dir/result" ]; then
        printf 'complete-stopped'
      elif [ "$persisted" = stopped ]; then
        printf 'stopped'
      else
        printf 'dead'
      fi
    else
      printf 'ambiguous'
    fi
  fi
}

fm_child_existing_dirs() {
  local dir name
  [ -d "$FM_CHILD_ROOT" ] && [ ! -L "$FM_CHILD_ROOT" ] || return 0
  for dir in "$FM_CHILD_ROOT"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    name=$(basename "$dir")
    fm_child_name_valid "$name" || continue
    printf '%s\n' "$dir"
  done
}

fm_child_active_count() {
  local dir count=0 relation
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if fm_child_record_relation "$dir"; then
      count=$((count + 1))
    else
      relation=$?
      [ "$relation" -ne 2 ] || die "child record '$(basename "$dir")' has ambiguous live ownership"
    fi
  done <<EOF
$(fm_child_existing_dirs)
EOF
  printf '%s' "$count"
}

fm_child_instruction_copy() {  # <source> <dest>
  local source=$1 dest=$2 source_dir source_abs bytes
  [ -f "$source" ] && [ ! -L "$source" ] || die "instruction file must be a regular non-symlink file"
  source_dir=$(cd "$(dirname "$source")" 2>/dev/null && pwd -P) || die "instruction file directory is unreadable"
  source_abs="$source_dir/$(basename "$source")"
  fm_child_same_or_below "$FM_CHILD_PARENT_WORKTREE" "$source_abs" \
    && die "instruction file must stay outside the repository"
  bytes=$(wc -c < "$source" 2>/dev/null | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) die "instruction file size is unreadable" ;; esac
  [ "$bytes" -gt 0 ] && [ "$bytes" -le 65536 ] \
    || die "instruction file must be non-empty and at most 65536 bytes"
  cp "$source" "$dest" || die "could not persist the child instruction file"
  chmod 600 "$dest"
}

fm_child_write_guards() {  # <child-dir>
  local dir=$1 real_git
  real_git=$(command -v git 2>/dev/null) || die "git is required"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/git" <<EOF
#!/usr/bin/env bash
set -eu
real_git='$real_git'
args=("\$@")
index=0
while [ "\$index" -lt "\${#args[@]}" ]; do
  case "\${args[\$index]}" in
    -C|--git-dir|--work-tree|--namespace|--super-prefix)
      index=\$((index + 2))
      ;;
    --no-pager|--paginate|-P|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
      index=\$((index + 1))
      ;;
    *) break ;;
  esac
done
command=\${args[\$index]:-}
next=\${args[\$((index + 1))]:-}
case "\$command" in
  status|diff|log|show|rev-parse|ls-files|grep|blame|cat-file|merge-base|for-each-ref|name-rev|describe)
    exec "\$real_git" "\$@"
    ;;
  branch)
    case "\$next" in --show-current|--list|-l|-a|-r|-v|-vv|'') exec "\$real_git" "\$@" ;; esac
    ;;
  remote)
    case "\$next" in -v|get-url) exec "\$real_git" "\$@" ;; esac
    ;;
  config)
    case "\$next" in --get|--get-all|--get-regexp|--list|-l) exec "\$real_git" "\$@" ;; esac
    ;;
esac
echo 'REFUSED: bounded child agents may use only read-only Git inspection; the parent owns every Git mutation.' >&2
exit 64
EOF
  cat > "$dir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
echo 'REFUSED: bounded child agents cannot invoke no-mistakes; final exact-head validation belongs to the parent.' >&2
exit 64
EOF
  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo 'REFUSED: bounded child agents cannot perform PR or publication operations; the parent owns them.' >&2
exit 64
EOF
  cp "$dir/bin/gh" "$dir/bin/gh-axi"
  chmod 700 "$dir/bin/git" "$dir/bin/no-mistakes" "$dir/bin/gh" "$dir/bin/gh-axi"
}

fm_child_write_complete() {  # <child-dir> <name>
  local dir=$1 name=$2
  cat > "$dir/complete.sh" <<EOF
#!/usr/bin/env bash
set -eu
[ "\${FM_CHILD_AGENT:-}" = 1 ] || { echo 'REFUSED: completion is child-only.' >&2; exit 64; }
[ "\${FM_CHILD_NAME:-}" = '$name' ] || { echo 'REFUSED: child completion identity mismatch.' >&2; exit 64; }
report='$dir/report.md'
result='$dir/result'
[ -f "\$report" ] && [ ! -L "\$report" ] && [ -s "\$report" ] \
  || { echo 'REFUSED: write the private child report before completing.' >&2; exit 64; }
summary=\${1:-completed}
case "\$summary" in *\$'\\n'*|*\$'\\r'*|*\$'\\t'*) echo 'REFUSED: summary must be one line.' >&2; exit 64 ;; esac
[ "\${#summary}" -le 500 ] || { echo 'REFUSED: summary exceeds 500 characters.' >&2; exit 64; }
tmp="\$result.tmp.\$\$"
umask 077
{
  printf 'version=1\\n'
  printf 'status=done\\n'
  printf 'summary=%s\\n' "\$summary"
  printf 'completed_at=%s\\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "\$tmp"
mv "\$tmp" "\$result"
printf 'child result recorded at %s\\n' "\$result"
EOF
  chmod 700 "$dir/complete.sh"
}

fm_child_write_launch_brief() {  # <child-dir> <name>
  local dir=$1 name=$2 path
  {
    cat <<EOF
You are a bounded child agent delegated by an ordinary FirstMate worker.
Do not address the captain or write FirstMate parent-facing status notifications.
Your only authority is the parent task below, and you must not expand its scope.

Parent task: $FM_CHILD_PARENT_ID
Parent task kind: $FM_CHILD_PARENT_KIND
Runtime profile: harness=$FM_CHILD_PARENT_HARNESS model=$FM_CHILD_PARENT_MODEL effort=$FM_CHILD_PARENT_EFFORT
Shared working copy: $FM_CHILD_PARENT_WORKTREE
Child name: $name

You share the parent's existing writable working copy and branch with concurrent agents.
Your edits are not isolated.
Edit only the explicitly owned paths below, and do not touch any other path.
EOF
    while IFS= read -r path; do
      [ -n "$path" ] && printf -- '- %s\n' "$path"
    done < "$dir/paths"
    cat <<EOF

The parent is the sole owner of every Git mutation and publication action.
You may run only read-only Git inspection through the guarded git command on PATH.
Do not stage, commit, switch branches, rebase, merge, reset, restore, clean, push, create or edit a PR, invoke no-mistakes, or bypass the command guards.
Do not invoke the FirstMate child helper or create another agent, pane, tab, window, worktree, or delegation.
Only when your assigned subtask explicitly tests this bounded-child lifecycle may you invoke the generated guarded prohibited interfaces solely to prove they refuse; never bypass a guard or perform the prohibited action.
Do not choose another provider, runtime, model, or effort level.
Do not act outside the accepted parent task.
EOF
    if [ "$FM_CHILD_PARENT_KIND" = scout ]; then
      printf '%s\n' 'This is a scout parent, so no child work may publish, push, open a PR, or become implementation authority.'
    fi
    cat <<'EOF'

Read and follow the project instructions already present in the shared working copy.
Your assigned subtask follows.

EOF
    cat "$dir/request.md"
    cat <<EOF

When the subtask is complete, review your own changes for the assigned paths, then write a self-contained report to:
$dir/report.md
The report must list the paths changed, checks run, result, and anything the parent must review.
After the report exists, run:
$dir/complete.sh "<one-line result>"
Then stop work and wait for the parent to inspect and close this pane.
Do not send routine progress or completion to FirstMate or the captain.
EOF
  } > "$dir/launch.md"
  chmod 600 "$dir/launch.md"
}

fm_child_profile_args() {  # <harness>, writes FM_CHILD_PROFILE_ARGS
  local harness=$1 model=$FM_CHILD_PARENT_MODEL effort=$FM_CHILD_PARENT_EFFORT
  FM_CHILD_PROFILE_ARGS=()
  case "$harness" in
    claude)
      FM_CHILD_PROFILE_ARGS+=(--dangerously-skip-permissions --setting-sources user)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      case "$effort" in default) ;; *) FM_CHILD_PROFILE_ARGS+=(--effort "$effort") ;; esac
      ;;
    codex)
      FM_CHILD_PROFILE_ARGS+=(--dangerously-bypass-approvals-and-sandbox)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      case "$effort" in low|medium|high|xhigh) FM_CHILD_PROFILE_ARGS+=(-c "model_reasoning_effort=\"$effort\"") ;; esac
      ;;
    opencode)
      FM_CHILD_PROFILE_ARGS+=(--pure)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      ;;
    pi)
      FM_CHILD_PROFILE_ARGS+=(--approve --no-extensions)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      case "$effort" in default) ;; *) FM_CHILD_PROFILE_ARGS+=(--thinking "$effort") ;; esac
      ;;
    pi-signed)
      FM_CHILD_PROFILE_ARGS+=(--approve --no-extensions)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      case "$effort" in default) ;; *) FM_CHILD_PROFILE_ARGS+=(--thinking "$effort") ;; esac
      ;;
    grok)
      FM_CHILD_PROFILE_ARGS+=(--always-approve)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      case "$effort" in low|medium|high) FM_CHILD_PROFILE_ARGS+=(--reasoning-effort "$effort") ;; esac
      ;;
    kimi)
      FM_CHILD_PROFILE_ARGS+=(--auto)
      [ "$model" = default ] || FM_CHILD_PROFILE_ARGS+=(--model "$model")
      ;;
    *) return 1 ;;
  esac
}

fm_child_shell_quote() {  # <value>
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

fm_child_runtime_binary() {  # <harness>
  case "$1" in
    claude|codex|opencode|pi|grok|kimi) command -v "$1" 2>/dev/null ;;
    pi-signed) command -v pi-signed 2>/dev/null ;;
    *) return 1 ;;
  esac
}

fm_child_runtime_start() {  # <pane> <private-startup-log>
  local pane=$1 startup_log=$2 binary command arg attempts=0 agent_out expected
  binary=$(fm_child_runtime_binary "$FM_CHILD_PARENT_HARNESS") || return 1
  [ -x "$binary" ] || return 1
  expected=$(fm_child_expected_agent "$FM_CHILD_PARENT_HARNESS") || return 1
  command="exec $(fm_child_shell_quote "$binary")"
  case "$FM_CHILD_PARENT_HARNESS" in
    pi|pi-signed) command="FM_PI_HARNESS=$FM_CHILD_PARENT_HARNESS $command" ;;
  esac
  for arg in "${FM_CHILD_PROFILE_ARGS[@]}"; do
    command="$command $(fm_child_shell_quote "$arg")"
  done
  fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane run "$pane" "$command" >"$startup_log" 2>&1 \
    || return 1
  while [ "$attempts" -lt 240 ]; do
    agent_out=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" agent get "$pane" 2>/dev/null || true)
    if printf '%s' "$agent_out" | jq -e --arg expected "$expected" \
      '.result.agent.agent == $expected and (.result.agent.agent_status == "idle" or .result.agent.agent_status == "done" or .result.agent.agent_status == "blocked")' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    attempts=$((attempts + 1))
  done
  {
    printf '\nlast agent response:\n%s\nlast pane output:\n' "$agent_out"
    fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane read "$pane" --source recent --lines 200 2>/dev/null || true
  } >> "$startup_log"
  return 1
}

fm_child_pending_delivery_is_busy() {  # <child-dir> <pane> <private-startup-log>
  local dir=$1 pane=$2 startup_log=$3 expected agent_out agent capture
  fm_child_record_relation "$dir" || {
    printf 'pending_corroboration=ownership-mismatch\n' >> "$startup_log"
    return 1
  }
  expected=$(fm_child_expected_agent "$FM_CHILD_PARENT_HARNESS") || return 1
  agent_out=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" agent get "$pane" 2>/dev/null) || {
    printf 'pending_corroboration=agent-unreadable\n' >> "$startup_log"
    return 1
  }
  agent=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  if [ "$agent" != "$expected" ]; then
    printf 'pending_corroboration=agent-mismatch expected=%s actual=%s\n' \
      "$expected" "${agent:-empty}" >> "$startup_log"
    return 1
  fi
  capture=$(fm_backend_capture herdr "$FM_CHILD_PARENT_SESSION:$pane" 40 2>/dev/null) || {
    printf 'pending_corroboration=capture-failed agent=%s\n' "$agent" >> "$startup_log"
    return 1
  }
  if printf '%s' "$capture" | grep -v '^[[:space:]]*$' | tail -12 \
      | fm_busy_lines_match "$FM_CHILD_PARENT_HARNESS"; then
    printf 'pending_corroboration=busy-signature agent=%s harness=%s\n' \
      "$agent" "$FM_CHILD_PARENT_HARNESS" >> "$startup_log"
    return 0
  fi
  printf 'pending_corroboration=no-busy-signature agent=%s harness=%s\n' \
    "$agent" "$FM_CHILD_PARENT_HARNESS" >> "$startup_log"
  return 1
}

fm_child_capture_delivery_evidence() {  # <pane> <private-startup-log>
  local pane=$1 startup_log=$2 capture
  capture=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane read "$pane" \
    --source recent --lines 200 2>/dev/null || true)
  {
    printf '\nsanitized_composer_capture:\n'
    printf '%s\n' "$capture" \
      | fm_composer_strip_ansi \
      | LC_ALL=C tr -cd '\11\12\15\40-\176' \
      | sed -E \
          -e 's/(sk-|gh[pousr]_)[A-Za-z0-9_-]+/[credential-redacted]/g' \
          -e 's/((token|password|secret|api[_-]?key)[=:][[:space:]]*)[^[:space:]]+/\1[credential-redacted]/Ig' \
      | tail -n 80 \
      | head -c 16384
    printf '\n'
  } >> "$startup_log"
}

fm_child_close_created_pane() {  # <pane>
  local pane=$1 out
  [ "$pane" != "$FM_CHILD_PARENT_PANE" ] || return 0
  out=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane get "$pane" 2>/dev/null || true)
  if printf '%s' "$out" | jq -e \
    --arg pane "$pane" --arg workspace "$FM_CHILD_PARENT_WORKSPACE" --arg tab "$FM_CHILD_PARENT_TAB" \
    '.result.pane.pane_id == $pane and .result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab' \
    >/dev/null 2>&1; then
    fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane close "$pane" >/dev/null 2>&1 || true
  fi
}

fm_child_create() {
  local name instructions path existing other dir active out pane agent_name encoded
  local seen_paths startup_log delivery_verdict delivery_file
  local -a paths
  name=${1:-}
  instructions=
  paths=()
  seen_paths=
  startup_log=
  delivery_verdict=
  delivery_file=
  fm_child_name_valid "$name" || die "child name must be 1-32 letters, digits, dots, underscores, or dashes"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instructions)
        [ "$#" -ge 2 ] || die "--instructions requires a file"
        instructions=$2
        shift 2
        ;;
      --instructions=*) instructions=${1#--instructions=}; shift ;;
      --path)
        [ "$#" -ge 2 ] || die "--path requires a repository-relative path"
        paths+=("$2")
        shift 2
        ;;
      --path=*) paths+=("${1#--path=}"); shift ;;
      *) die "unknown create argument '$1'" ;;
    esac
  done
  [ -n "$instructions" ] || die "create requires --instructions <file>"
  [ "${#paths[@]}" -gt 0 ] || die "create requires at least one --path assignment"

  fm_child_acquire_lock
  mkdir -p "$FM_CHILD_ROOT" || die "cannot create the private child record directory"
  chmod 700 "$FM_CHILD_ROOT"
  [ -d "$FM_CHILD_ROOT" ] && [ ! -L "$FM_CHILD_ROOT" ] || die "private child record directory is unsafe"
  fm_child_validate_records
  dir="$FM_CHILD_ROOT/$name"
  [ ! -e "$dir" ] && [ ! -L "$dir" ] || die "child name '$name' already exists for this parent"
  active=$(fm_child_active_count)
  [ "$active" -lt "$FM_CHILD_MAX" ] || die "parent already has the maximum of $FM_CHILD_MAX concurrent child panes"

  for path in "${paths[@]}"; do
    fm_child_path_valid "$path" || die "path assignment '$path' is external, symlinked, globbed, or ambiguous"
    case "$seen_paths" in
      *$'\n'"$path"$'\n'*) die "path assignment '$path' was supplied more than once" ;;
    esac
    seen_paths="${seen_paths}"$'\n'"$path"$'\n'
    for other in "${paths[@]}"; do
      [ "$path" = "$other" ] && continue
      if fm_child_paths_overlap "$path" "$other"; then
        die "path assignments '$path' and '$other' overlap"
      fi
    done
    while IFS= read -r existing; do
      [ -n "$existing" ] || continue
      [ -f "$existing/paths" ] && [ ! -L "$existing/paths" ] || die "existing child path ownership is ambiguous"
      while IFS= read -r other; do
        [ -n "$other" ] || continue
        if fm_child_paths_overlap "$path" "$other"; then
          die "path assignment '$path' overlaps child '$(basename "$existing")' ownership '$other'"
        fi
      done < "$existing/paths"
    done <<EOF
$(fm_child_existing_dirs)
EOF
  done

  umask 077
  mkdir "$dir" || die "cannot create the private record for child '$name'"
  FM_CHILD_CREATE_STAGING=$dir
  fm_child_instruction_copy "$instructions" "$dir/request.md"
  printf '%s\n' "${paths[@]}" > "$dir/paths"
  chmod 600 "$dir/paths"
  fm_child_write_guards "$dir"
  fm_child_write_complete "$dir" "$name"
  fm_child_write_launch_brief "$dir" "$name"
  agent_name="fm-child-$(printf '%s' "$FM_HOME:$FM_CHILD_PARENT_ID:$FM_CHILD_PARENT_PANE" | cksum | awk '{print $1}')-$name"

  out=$(fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane split "$FM_CHILD_PARENT_PANE" \
    --direction right --ratio 0.5 --cwd "$FM_CHILD_PARENT_WORKTREE" \
    --env "FM_CHILD_AGENT=1" \
    --env "FM_CHILD_PARENT_ID=$FM_CHILD_PARENT_ID" \
    --env "FM_CHILD_NAME=$name" \
    --env "FM_CHILD_COMPLETE=$dir/complete.sh" \
    --env "FM_CHILD_REPORT=$dir/report.md" \
    --env "FM_HOME=$FM_HOME" \
    --env "PATH=$dir/bin:$PATH" \
    --env "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" \
    --env 'OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}' \
    --env "FM_PI_HARNESS=$FM_CHILD_PARENT_HARNESS" \
    --no-focus 2>/dev/null) || {
      rm -rf "$dir"
      die "Herdr refused the same-tab child pane split"
    }
  pane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ -z "$pane" ] || [ "$pane" = "$FM_CHILD_PARENT_PANE" ] || ! printf '%s' "$out" | jq -e \
      --arg pane "$pane" --arg workspace "$FM_CHILD_PARENT_WORKSPACE" --arg tab "$FM_CHILD_PARENT_TAB" \
      '.result.pane.pane_id == $pane and .result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab' \
      >/dev/null 2>&1; then
    [ -z "$pane" ] || fm_child_close_created_pane "$pane"
    rm -rf "$dir"
    die "Herdr child split did not return one exact pane inside the parent's recorded tab"
  fi
  FM_CHILD_CREATE_PANE=$pane
  {
    printf 'version=1\n'
    printf 'parent_task_id=%s\n' "$FM_CHILD_PARENT_ID"
    printf 'parent_session=%s\n' "$FM_CHILD_PARENT_SESSION"
    printf 'parent_workspace_id=%s\n' "$FM_CHILD_PARENT_WORKSPACE"
    printf 'parent_tab_id=%s\n' "$FM_CHILD_PARENT_TAB"
    printf 'parent_pane_id=%s\n' "$FM_CHILD_PARENT_PANE"
    printf 'child_name=%s\n' "$name"
    printf 'child_pane_id=%s\n' "$pane"
    printf 'agent_name=%s\n' "$agent_name"
    printf 'harness=%s\n' "$FM_CHILD_PARENT_HARNESS"
    printf 'model=%s\n' "$FM_CHILD_PARENT_MODEL"
    printf 'effort=%s\n' "$FM_CHILD_PARENT_EFFORT"
    printf 'kind=%s\n' "$FM_CHILD_PARENT_KIND"
    printf 'worktree=%s\n' "$FM_CHILD_PARENT_WORKTREE"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dir/meta"
  chmod 600 "$dir/meta"
  printf 'starting\n' > "$dir/state"
  FM_CHILD_CREATE_STAGING=
  FM_CHILD_CREATE_PANE=
  chmod 600 "$dir/state"

  fm_child_profile_args "$FM_CHILD_PARENT_HARNESS" \
    || { fm_child_close_created_pane "$pane"; die "unsupported inherited child runtime"; }
  startup_log="$dir/startup.log"
  : > "$startup_log"
  chmod 600 "$startup_log"
  if ! fm_child_runtime_start "$pane" "$startup_log"; then
    fm_child_close_created_pane "$pane"
    printf 'dead\n' > "$dir/state"
    die "inherited child runtime '$FM_CHILD_PARENT_HARNESS' did not become ready; private details: $startup_log"
  fi
  if ! fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" agent get "$pane" >/dev/null 2>&1; then
    fm_child_close_created_pane "$pane"
    printf 'dead\n' > "$dir/state"
    die "inherited child runtime '$FM_CHILD_PARENT_HARNESS' lost registration before startup instructions; private details: $startup_log"
  fi
  encoded=$(printf 'Read and follow the child brief at %s.\n' "$dir/launch.md" \
    | "$SCRIPT_DIR/fm-operational-input.sh" encode launch-brief) \
    || { fm_child_close_created_pane "$pane"; printf 'dead\n' > "$dir/state"; die "could not encode the child brief pointer"; }
  # Reuse fm-send's verified Herdr composer path: type once, retry Enter only,
  # and accept only its exact proof-carrying `empty` verdict. Raw `herdr agent
  # prompt` is not a verified Pi composer path and can report a stalled native
  # transition after merely filling the composer.
  delivery_file="$dir/delivery.verdict"
  if ! fm_backend_send_text_submit herdr \
      "$FM_CHILD_PARENT_SESSION:$pane" "$encoded" 3 0.4 0.3 \
      >"$delivery_file" 2>>"$startup_log"; then
    printf 'submit_baseline_raw=%s\n' "${FM_BACKEND_HERDR_SUBMIT_BASELINE_RAW:-unknown}" >> "$startup_log"
    printf 'delivery_call=failed\n' >> "$startup_log"
    rm -f "$delivery_file"
    fm_child_capture_delivery_evidence "$pane" "$startup_log"
    fm_child_close_created_pane "$pane"
    printf 'dead\n' > "$dir/state"
    die "child instruction delivery failed; private details: $startup_log"
  fi
  delivery_verdict=$(cat "$delivery_file" 2>/dev/null || true)
  rm -f "$delivery_file"
  printf 'submit_baseline_raw=%s\n' "${FM_BACKEND_HERDR_SUBMIT_BASELINE_RAW:-unknown}" >> "$startup_log"
  printf 'delivery_verdict=%s\n' "${delivery_verdict:-unknown}" >> "$startup_log"
  case "$delivery_verdict" in
    empty)
      ;;
    pending)
      if ! fm_child_pending_delivery_is_busy "$dir" "$pane" "$startup_log"; then
        fm_child_capture_delivery_evidence "$pane" "$startup_log"
        fm_child_close_created_pane "$pane"
        printf 'dead\n' > "$dir/state"
        die "child instruction delivery remained unconfirmed after busy-signature corroboration (verdict=pending); private details: $startup_log"
      fi
      ;;
    *)
      fm_child_capture_delivery_evidence "$pane" "$startup_log"
      fm_child_close_created_pane "$pane"
      printf 'dead\n' > "$dir/state"
      die "child instruction delivery was not confirmed (verdict=${delivery_verdict:-unknown}); private details: $startup_log"
      ;;
  esac
  printf 'running\n' > "$dir/state"
  printf 'created child %s pane=%s paths=%s report=%s\n' \
    "$name" "$pane" "$(paste -sd, "$dir/paths")" "$dir/report.md"
}

fm_child_require_dir() {  # <name>
  local name=$1 dir
  fm_child_name_valid "$name" || die "invalid child name"
  fm_child_validate_records
  dir="$FM_CHILD_ROOT/$name"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "no child named '$name'"
  fm_child_record_valid "$dir" || die "child record '$name' is malformed"
  printf '%s' "$dir"
}

fm_child_list() {
  local dir name state pane paths report
  [ -d "$FM_CHILD_ROOT" ] || { echo "no children"; return 0; }
  fm_child_validate_records
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    name=$(basename "$dir")
    pane=$(fm_child_record_meta "$dir" child_pane_id 2>/dev/null || printf '?')
    state=$(fm_child_state "$dir")
    paths=$(paste -sd, "$dir/paths" 2>/dev/null || printf '?')
    if [ -s "$dir/report.md" ] && [ ! -L "$dir/report.md" ]; then report=present; else report=missing; fi
    printf '%s state=%s pane=%s paths=%s report=%s\n' "$name" "$state" "$pane" "$paths" "$report"
  done <<EOF
$(fm_child_existing_dirs)
EOF
}

fm_child_inspect() {  # <name>
  local dir=$1 state pane summary
  state=$(fm_child_state "$dir")
  pane=$(fm_child_record_meta "$dir" child_pane_id) || die "child pane record is ambiguous"
  printf 'name=%s\nstate=%s\npane=%s\nreport=%s\n' \
    "$(basename "$dir")" "$state" "$pane" "$dir/report.md"
  printf 'paths:\n'
  sed 's/^/  /' "$dir/paths"
  if [ -f "$dir/result" ] && [ ! -L "$dir/result" ]; then
    summary=$(fm_child_meta_optional_exact "$dir/result" summary '' 2>/dev/null || true)
    printf 'result=%s\n' "${summary:-recorded}"
  fi
  if fm_child_record_relation "$dir"; then
    printf 'pane-tail:\n'
    fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane read "$pane" --source recent --lines 200 2>/dev/null \
      | tail -n 20 | sed 's/^/  /' || true
  fi
}

fm_child_stop_dir() {  # <child-dir>
  local dir=$1 pane relation
  pane=$(fm_child_record_meta "$dir" child_pane_id) || die "child '$(basename "$dir")' has ambiguous pane metadata"
  if fm_child_record_relation "$dir"; then
    fm_backend_herdr_cli "$FM_CHILD_PARENT_SESSION" pane close "$pane" >/dev/null 2>&1 \
      || die "could not stop exact child pane '$pane'"
    if fm_child_record_relation "$dir"; then
      die "exact child pane '$pane' still exists after stop"
    else
      relation=$?
      [ "$relation" -eq 1 ] || die "child pane ownership became ambiguous after stop"
    fi
  else
    relation=$?
    [ "$relation" -eq 1 ] || die "child '$(basename "$dir")' no longer belongs to the recorded parent tab"
  fi
  printf 'stopped\n' > "$dir/state"
}

fm_child_stop() {  # <child-dir>
  local dir=$1
  fm_child_acquire_lock
  fm_child_stop_dir "$dir"
  printf 'stopped child %s\n' "$(basename "$dir")"
}

fm_child_quiesce() {
  local dir
  fm_child_acquire_lock
  [ -d "$FM_CHILD_ROOT" ] || return 0
  fm_child_validate_records
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    fm_child_stop_dir "$dir"
  done <<EOF
$(fm_child_existing_dirs)
EOF
}

fm_child_ready() {
  local dir state failures=0
  [ -d "$FM_CHILD_ROOT" ] || { echo "children ready"; return 0; }
  fm_child_validate_records
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    state=$(fm_child_state "$dir")
    case "$state" in
      complete-stopped)
        [ -s "$dir/report.md" ] && [ ! -L "$dir/report.md" ] || failures=1
        ;;
      *)
        echo "not ready: child $(basename "$dir") state=$state" >&2
        failures=1
        ;;
    esac
  done <<EOF
$(fm_child_existing_dirs)
EOF
  [ "$failures" -eq 0 ] || return 1
  echo "children ready"
}

fm_child_cleanup() {
  local dir relation
  fm_child_acquire_lock
  [ -e "$FM_CHILD_ROOT" ] || return 0
  [ -d "$FM_CHILD_ROOT" ] && [ ! -L "$FM_CHILD_ROOT" ] || die "private child record directory is unsafe"
  fm_child_validate_records
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    fm_child_stop_dir "$dir"
    if fm_child_record_relation "$dir"; then
      die "child pane still exists during cleanup"
    else
      relation=$?
      [ "$relation" -eq 1 ] || die "child pane ownership is ambiguous during cleanup"
    fi
  done <<EOF
$(fm_child_existing_dirs)
EOF
  rm -rf "$FM_CHILD_ROOT"
}

command=${1:-}
case "$command" in
  -h|--help|help)
    usage
    exit 0
    ;;
  create|list|inspect|stop|ready)
    [ "${FM_CHILD_TEARDOWN:-}" != 1 ] || die "teardown mode accepts only quiesce or cleanup"
    fm_child_discover_parent
    ;;
  cleanup)
    if [ "${FM_CHILD_TEARDOWN:-}" = 1 ]; then
      [ "$#" -eq 2 ] || die "teardown cleanup requires one task id"
      fm_child_load_teardown_parent "$2"
    else
      [ "$#" -eq 1 ] || die "parent cleanup accepts no task id"
      fm_child_discover_parent
    fi
    ;;
  quiesce)
    [ "${FM_CHILD_TEARDOWN:-}" = 1 ] || die "quiesce is teardown-only"
    [ "$#" -eq 2 ] || die "teardown quiesce requires one task id"
    fm_child_load_teardown_parent "$2"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "$command" in
  create)
    [ "$#" -ge 2 ] || die "create requires a child name"
    shift
    fm_child_create "$@"
    ;;
  list)
    [ "$#" -eq 1 ] || die "list accepts no arguments"
    fm_child_list
    ;;
  inspect)
    [ "$#" -eq 2 ] || die "inspect requires one child name"
    fm_child_inspect "$(fm_child_require_dir "$2")"
    ;;
  stop)
    [ "$#" -eq 2 ] || die "stop requires one child name"
    fm_child_stop "$(fm_child_require_dir "$2")"
    ;;
  ready)
    [ "$#" -eq 1 ] || die "ready accepts no arguments"
    fm_child_ready
    ;;
  quiesce) fm_child_quiesce ;;
  cleanup) fm_child_cleanup ;;
esac
