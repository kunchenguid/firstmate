#!/usr/bin/env bash
# Durable local scheduler for the private nt-review-sweep skill.
#
# Usage:
#   fm-review-sweep-supervisor.sh install --source-home <firstmate-home>
#       Install an Aqua LaunchAgent, an isolated automation home, a private
#       host-job authorization contract, and the current script bytes. The
#       default schedule is every half hour from 07:00 through 17:00 in
#       America/Chicago, with the final daily slot at 17:00 and a maximum of
#       ten concurrent reviews. The source home is validated before any private
#       configuration is persisted, so a wrong path leaves nothing behind and
#       stays reinstallable. Installation pins the source repository's default
#       branch; later working-branch changes in the source home never disturb
#       the scheduled job. Existing private configuration is preserved;
#       rerunning install refreshes code, context, projects, and the launchd
#       contract idempotently, and backfills a pinned branch into a private
#       configuration written before that key existed.
#   fm-review-sweep-supervisor.sh tick
#       Claim and run the newest due slot for the current Chicago day. A single
#       process owns the slot through completion. A wake after sleep catches up
#       only the newest missed slot, never replays a backlog of old slots, and
#       never starts a cycle after the final slot's half-hour window closes.
#       A duplicate tick for a slot that already succeeded, or for a failed slot
#       whose retry is not yet due, decides that under the owner lock and exits
#       without synchronizing the automation home.
#   fm-review-sweep-supervisor.sh run-now
#       Run one manually named slot immediately, through the same lock, review
#       lifecycle, receipt, and retry machinery as a scheduled slot.
#   fm-review-sweep-supervisor.sh status
#       Print installation, launchd, active-run, and latest-slot state.
#   fm-review-sweep-supervisor.sh render-launchagent
#       Print the exact property list contract for inspection or tests.
#   fm-review-sweep-supervisor.sh slot-at <YYYYMMDD> <HH> <MM>
#       Print the newest due slot for supplied local clock fields, or nothing
#       outside the daily window. This is a deterministic diagnostic surface.
#   fm-review-sweep-supervisor.sh uninstall
#       Boot out the exact LaunchAgent and remove its property list. Runtime
#       state, logs, reports, the isolated home, and configuration are retained.
#
# The scheduler is deliberately thin. The installed nt-review-sweep skill owns
# Jira and GitHub discovery, watermark rules, review shape, publication, and the
# Slack author notification. This script owns only recurrence, an isolated
# execution home, the persisted host-job authorization, crash-safe slot claims,
# bounded process lifetime, bounded artifact retention, and terminal task
# reconciliation.
#
# Durability rules this script owns:
#   * A cycle runs in its own verified process group. A timeout or a supervisor
#     signal terminates that exact group, and the owner lock is released only
#     after the group is confirmed gone, so no authorized external writer
#     outlives the exclusion that stops a second cycle for the same slot.
#   * The recorded cycle process group is trusted only while it is still live,
#     still runs the configured codex binary, and is younger than any cycle
#     could legitimately be. A record that fails those checks - a reused group
#     id after a reboot, for example - is retired instead of wedging the job.
#   * A lock directory left behind by a crash between its creation and its owner
#     record is reclaimed after a short grace, so the job self-heals.
#   * A failed slot's retry deadline is measured from when the attempt actually
#     finished, never from when the tick started, and a failure to synchronize
#     the automation home is recorded against the slot under the same throttle.
#   * The cycle receipt is read and recorded whatever else went wrong. A slot
#     whose publication verified is never re-run, so a stray surviving process
#     is reported and the lock retained without duplicating comments or DMs.
#   * Slack author notifications may leave this job through exactly one route:
#     the captain's private direct Web API helper, provisioned into the
#     automation home and named in the host contract. The ChatGPT Slack
#     connector is forbidden because it appends agent attribution, and no
#     fallback transport exists: a notification that cannot use the authorized
#     helper is recorded as blocked in the receipt and in the captain's result.
#   * The automation home is a clone this script owns. When the pinned source
#     history is rewritten it is realigned to the exact source head, but only
#     after its identity, pinned branch, and clean tracked worktree re-verify.
#     Nothing here ever writes to source_home or a project worktree.
#   * A successful cycle keeps its prompt, final result, and receipt. Full Codex
#     event streams are not retained; only the most recent failure keeps a
#     bounded diagnostic tail. Supervisor-owned slot, result, and receipt
#     artifacts older than retention_days are removed after a cycle runs.
#
# Private files:
#   ~/Library/Application Support/Firstmate/review-sweep/config/supervisor.conf
#   ~/Library/Application Support/Firstmate/review-sweep/state/slots/<slot>/
#   ~/Library/Application Support/Firstmate/review-sweep/results/<slot>/
#   ~/Library/LaunchAgents/dev.firstmate.review-sweep.plist
#   ~/Library/Logs/dev.firstmate.review-sweep.log
#
# Tests may override FM_REVIEW_SWEEP_APP_ROOT, FM_REVIEW_SWEEP_CONFIG,
# FM_REVIEW_SWEEP_LAUNCH_AGENT_DIR, FM_REVIEW_SWEEP_LOG_DIR,
# FM_REVIEW_SWEEP_LAUNCHCTL, FM_REVIEW_SWEEP_NOW_FIELDS, and
# FM_REVIEW_SWEEP_NOW_FIELDS_FILE. A clock override is five space-separated
# fields: YYYYMMDD HH MM epoch UTC-offset. The file form is re-read on every
# clock query, so a fixture can advance the logical clock across a cycle.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LABEL=dev.firstmate.review-sweep
DEFAULT_TIMEZONE=America/Chicago
DEFAULT_START_HOUR=7
DEFAULT_END_HOUR=17
DEFAULT_INTERVAL_MINUTES=30
DEFAULT_MAX_CONCURRENT_REVIEWS=10
DEFAULT_RETRY_SECONDS=300
DEFAULT_MAX_RUNTIME_SECONDS=10800
DEFAULT_RETENTION_DAYS=90
SLACK_TRANSPORT_RELATIVE=data/tools/fm-slack-message.sh
LOCK_ORPHAN_GRACE_SECONDS=120
CYCLE_STOP_GRACE_SECONDS=15
CYCLE_KILL_GRACE_SECONDS=5
EVENT_TAIL_LINES=200

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

safe_single_line() {
  case ${1-} in *$'\n'*|*$'\r'*) return 1 ;; esac
}

safe_absolute_path() {
  safe_single_line "$1" || return 1
  case $1 in /*) ;; *) return 1 ;; esac
  [ "$1" != / ]
}

safe_project_name() {
  case $1 in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

safe_slot_id() {
  case $1 in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

safe_branch_name() {
  case $1 in ''|-*|*..*|*//*|*/|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case $1 in */.*|.*) return 1 ;; esac
}

safe_positive_integer() {
  case $1 in ''|*[!0-9]*|0) return 1 ;; esac
}

safe_nonnegative_integer() {
  case $1 in ''|*[!0-9]*) return 1 ;; esac
}

safe_timezone() {
  case $1 in ''|/*|*..*|*[!A-Za-z0-9_+./-]*) return 1 ;; esac
}

account_home() {
  local value=${HOME:-}
  safe_absolute_path "$value" || die 'HOME must be an absolute non-root path'
  printf '%s\n' "$value"
}

app_root_default() {
  printf '%s/Library/Application Support/Firstmate/review-sweep\n' "$(account_home)"
}

APP_ROOT=${FM_REVIEW_SWEEP_APP_ROOT:-$(app_root_default)}
safe_absolute_path "$APP_ROOT" || die 'review-sweep application root must be an absolute non-root path'
CONFIG_PATH=${FM_REVIEW_SWEEP_CONFIG:-$APP_ROOT/config/supervisor.conf}
safe_absolute_path "$CONFIG_PATH" || die 'review-sweep config path must be absolute'
LAUNCH_AGENT_DIR=${FM_REVIEW_SWEEP_LAUNCH_AGENT_DIR:-$(account_home)/Library/LaunchAgents}
LOG_DIR=${FM_REVIEW_SWEEP_LOG_DIR:-$(account_home)/Library/Logs}
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LABEL.plist"
LAUNCH_LOG="$LOG_DIR/$LABEL.log"
RUNTIME_SCRIPT="$APP_ROOT/runtime/fm-review-sweep-supervisor.sh"
STATE_ROOT="$APP_ROOT/state"
SLOTS_ROOT="$STATE_ROOT/slots"
RESULTS_ROOT="$APP_ROOT/results"
LOCK_DIR="$STATE_ROOT/run.lock"
LOCK_OWNER_FILE="$LOCK_DIR/owner"
LOCK_CYCLE_PGID_FILE="$LOCK_DIR/cycle-pgid"

SOURCE_HOME=
SOURCE_BRANCH=
AUTOMATION_HOME=
CODEX_BIN=
KNOWLEDGE_BASE_PATH=
RUNTIME_PATH=
TIMEZONE=$DEFAULT_TIMEZONE
START_HOUR=$DEFAULT_START_HOUR
END_HOUR=$DEFAULT_END_HOUR
INTERVAL_MINUTES=$DEFAULT_INTERVAL_MINUTES
MAX_CONCURRENT_REVIEWS=$DEFAULT_MAX_CONCURRENT_REVIEWS
RETRY_SECONDS=$DEFAULT_RETRY_SECONDS
MAX_RUNTIME_SECONDS=$DEFAULT_MAX_RUNTIME_SECONDS
RETENTION_DAYS=$DEFAULT_RETENTION_DAYS
ENABLED=1
JQ_BIN=
RUN_LOCK_HELD=0
RUN_LOCK_RETAINED=0
RUN_CHILD_PID=
RUN_CHILD_PGID=
SLOT_DIR=
SLOT_ADMISSION_MESSAGE=
CYCLE_PUBLICATION_VERIFIED=0

config_value_seen() {
  case " ${CONFIG_KEYS_SEEN:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

load_config() { # [--allow-missing-source-branch]
  local key value line_no=0 allow_legacy=0
  case ${1:-} in --allow-missing-source-branch) allow_legacy=1 ;; esac
  [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ] || die "missing private supervisor config: $CONFIG_PATH"
  CONFIG_KEYS_SEEN=
  while IFS='=' read -r key value || [ -n "${key:-}${value:-}" ]; do
    line_no=$((line_no + 1))
    case ${key:-} in ''|'#'*) continue ;; esac
    case ${key:-} in
      source_home|source_branch|automation_home|codex_bin|knowledge_base|runtime_path|timezone|start_hour|end_hour|interval_minutes|max_concurrent_reviews|retry_seconds|max_runtime_seconds|retention_days|enabled) ;;
      *) die "unknown config key '$key' on line $line_no" ;;
    esac
    config_value_seen "$key" && die "duplicate config key '$key'"
    CONFIG_KEYS_SEEN="${CONFIG_KEYS_SEEN:+$CONFIG_KEYS_SEEN }$key"
    safe_single_line "${value:-}" || die "config value for $key is not one line"
    case $key in
      source_home) SOURCE_HOME=$value ;;
      source_branch) SOURCE_BRANCH=$value ;;
      automation_home) AUTOMATION_HOME=$value ;;
      codex_bin) CODEX_BIN=$value ;;
      knowledge_base) KNOWLEDGE_BASE_PATH=$value ;;
      runtime_path) RUNTIME_PATH=$value ;;
      timezone) TIMEZONE=$value ;;
      start_hour) START_HOUR=$value ;;
      end_hour) END_HOUR=$value ;;
      interval_minutes) INTERVAL_MINUTES=$value ;;
      max_concurrent_reviews) MAX_CONCURRENT_REVIEWS=$value ;;
      retry_seconds) RETRY_SECONDS=$value ;;
      max_runtime_seconds) MAX_RUNTIME_SECONDS=$value ;;
      retention_days) RETENTION_DAYS=$value ;;
      enabled) ENABLED=$value ;;
    esac
  done < <(awk 'BEGIN { FS="=" } { key=$1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key); value=substr($0, index($0, "=")+1); if (index($0, "=")==0) { print $0 "=" } else { print key "=" value } }' "$CONFIG_PATH")

  safe_absolute_path "$SOURCE_HOME" || die 'source_home must be an absolute non-root path'
  if [ "$allow_legacy" = 1 ] && ! config_value_seen source_branch; then
    SOURCE_BRANCH=
  else
    safe_branch_name "$SOURCE_BRANCH" \
      || die "source_branch must name the pinned default branch of source_home; rerun install --source-home $SOURCE_HOME to repair it"
  fi
  safe_absolute_path "$AUTOMATION_HOME" || die 'automation_home must be an absolute non-root path'
  safe_absolute_path "$CODEX_BIN" || die 'codex_bin must be absolute'
  [ -x "$CODEX_BIN" ] || die "codex executable is unavailable: $CODEX_BIN"
  if [ -n "$KNOWLEDGE_BASE_PATH" ]; then
    safe_absolute_path "$KNOWLEDGE_BASE_PATH" || die 'knowledge_base must be empty or absolute'
  fi
  safe_absolute_path "$RUNTIME_PATH" || die 'runtime_path must be an absolute non-root path'
  safe_timezone "$TIMEZONE" || die 'timezone is invalid'
  safe_nonnegative_integer "$START_HOUR" || die 'start_hour must be an integer'
  safe_nonnegative_integer "$END_HOUR" || die 'end_hour must be an integer'
  [ "$START_HOUR" -le 23 ] && [ "$END_HOUR" -le 23 ] && [ "$START_HOUR" -le "$END_HOUR" ] \
    || die 'schedule hours must satisfy 0 <= start_hour <= end_hour <= 23'
  [ "$INTERVAL_MINUTES" = 30 ] || die 'interval_minutes must be 30'
  safe_positive_integer "$MAX_CONCURRENT_REVIEWS" || die 'max_concurrent_reviews must be positive'
  [ "$MAX_CONCURRENT_REVIEWS" -le 10 ] || die 'max_concurrent_reviews cannot exceed 10'
  safe_positive_integer "$RETRY_SECONDS" || die 'retry_seconds must be positive'
  safe_positive_integer "$MAX_RUNTIME_SECONDS" || die 'max_runtime_seconds must be positive'
  safe_positive_integer "$RETENTION_DAYS" || die 'retention_days must be positive'
  case $ENABLED in 0|1) ;; *) die 'enabled must be 0 or 1' ;; esac
  case ":$RUNTIME_PATH:" in *::*|*:$'\n'*|*:$'\r'*) die 'runtime_path is invalid' ;; esac
  JQ_BIN=$(command -v jq 2>/dev/null || true)
  [ -n "$JQ_BIN" ] && [ -x "$JQ_BIN" ] \
    || die 'jq is required to validate review-sweep cycle receipts but is not on PATH'
}

atomic_write() { # <path> <mode> <text>
  local path=$1 mode=$2 content=$3 parent tmp
  parent=${path%/*}
  [ -n "$parent" ] && [ "$parent" != "$path" ] || return 1
  mkdir -p "$parent"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  tmp=$(mktemp "$parent/.fm-review-sweep.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

path_mtime() { # <path>
  local value
  if [ "$(uname)" = Darwin ]; then
    value=$(stat -f %m -- "$1" 2>/dev/null || true)
  else
    value=$(stat -c %Y -- "$1" 2>/dev/null || true)
  fi
  safe_nonnegative_integer "${value:-}" || return 1
  printf '%s\n' "$value"
}

copy_private_file() { # <source> <destination> [mode]
  local src=$1 dest=$2 mode=${3:-0600} parent tmp
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    [ ! -e "$dest" ] && [ ! -L "$dest" ] || rm -f -- "$dest"
    return 0
  fi
  [ -f "$src" ] && [ ! -L "$src" ] || return 1
  parent=${dest%/*}
  mkdir -p "$parent"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"; then
    chmod "$mode" "$dest" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp "$parent/.fm-review-sweep-copy.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

write_empty_backlog() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] && return 0
  atomic_write "$path" 0600 '# Backlog

## In flight
## Queued
## Done'
}

validate_source_home() { # <path>
  local home=$1 top
  safe_absolute_path "$home" || die 'source_home must be an absolute non-root path'
  [ -d "$home" ] && [ ! -L "$home" ] || die "source home is unavailable: $home"
  top=$(git -C "$home" rev-parse --show-toplevel 2>/dev/null) || die 'source_home is not a git worktree'
  [ "$top" = "$home" ] || die 'source_home must name the Firstmate worktree root'
  [ -f "$home/AGENTS.md" ] && [ -x "$home/bin/fm-session-start.sh" ] \
    || die 'source_home is not a Firstmate home'
}

source_default_branch() { # <path>
  # Resolve the repository's default branch, never the transient working branch,
  # so a captain switching branches in the source home cannot disable the job.
  local home=$1 ref branch= candidate
  ref=$(git -C "$home" symbolic-ref --short --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  case $ref in origin/?*) branch=${ref#origin/} ;; esac
  if [ -z "$branch" ]; then
    for candidate in main master; do
      if git -C "$home" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1; then
        branch=$candidate
        break
      fi
    done
  fi
  if [ -z "$branch" ]; then
    branch=$(git -C "$home" symbolic-ref --short --quiet HEAD 2>/dev/null || true)
  fi
  safe_branch_name "${branch:-}" || return 1
  git -C "$home" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null 2>&1 || return 1
  printf '%s\n' "$branch"
}

ensure_automation_home() {
  validate_source_home "$SOURCE_HOME"
  source_branch_is_present \
    || die "source_home no longer carries its pinned branch '$SOURCE_BRANCH'; rerun install --source-home $SOURCE_HOME to repin it"

  if [ ! -e "$AUTOMATION_HOME" ]; then
    mkdir -p "${AUTOMATION_HOME%/*}"
    git clone --quiet --no-hardlinks --branch "$SOURCE_BRANCH" "$SOURCE_HOME" "$AUTOMATION_HOME" \
      || die 'failed to clone the isolated automation home'
  fi
  assert_supervisor_owned_automation_home
  mkdir -p "$AUTOMATION_HOME/data" "$AUTOMATION_HOME/state" "$AUTOMATION_HOME/config" "$AUTOMATION_HOME/projects"
  write_empty_backlog "$AUTOMATION_HOME/data/backlog.md" || die 'failed to initialize the automation backlog'
}

assert_supervisor_owned_automation_home() {
  local top
  safe_absolute_path "$AUTOMATION_HOME" || die 'automation_home must be an absolute non-root path'
  [ -d "$AUTOMATION_HOME" ] && [ ! -L "$AUTOMATION_HOME" ] || die 'automation_home is unsafe'
  [ "$AUTOMATION_HOME" != "$SOURCE_HOME" ] || die 'automation_home must differ from source_home'
  case "$AUTOMATION_HOME/" in "$SOURCE_HOME/"*) die 'automation_home cannot be inside source_home' ;; esac
  case "$SOURCE_HOME/" in "$AUTOMATION_HOME/"*) die 'source_home cannot be inside automation_home' ;; esac
  top=$(git -C "$AUTOMATION_HOME" rev-parse --show-toplevel 2>/dev/null || true)
  [ "$top" = "$AUTOMATION_HOME" ] || die 'automation_home is not an isolated git worktree root'
}

realign_automation_home() { # <source-head>
  # The automation home is a disposable clone this script owns, so a rewritten
  # pinned history is recoverable. Every identity, ref, and cleanliness fact is
  # re-proven immediately before the reset, and the reset never reaches the
  # source home, a project worktree, or any untracked private context.
  local source_head=$1 auto_branch dirty after
  assert_supervisor_owned_automation_home
  validate_source_home "$SOURCE_HOME"
  case $source_head in *[!0-9a-f]*|'') die 'refusing to realign to an unresolved source head' ;; esac
  [ "$(git -C "$SOURCE_HOME" rev-parse --verify --quiet "refs/heads/$SOURCE_BRANCH^{commit}" 2>/dev/null || true)" \
    = "$source_head" ] || die 'source head changed while realigning the automation home'
  auto_branch=$(git -C "$AUTOMATION_HOME" symbolic-ref --short HEAD 2>/dev/null || true)
  [ "$auto_branch" = "$SOURCE_BRANCH" ] || die 'refusing to realign an automation home off its pinned branch'
  dirty=$(git -C "$AUTOMATION_HOME" status --porcelain --untracked-files=no 2>/dev/null || true)
  [ -z "$dirty" ] || die 'automation_home has tracked local changes; refusing to overwrite them'
  git -C "$AUTOMATION_HOME" rev-parse --verify --quiet "$source_head^{commit}" >/dev/null 2>&1 \
    || die 'automation_home did not receive the pinned source head'
  git -C "$AUTOMATION_HOME" reset --hard --quiet "$source_head" \
    || die 'failed to realign the automation home to the pinned source head'
  after=$(git -C "$AUTOMATION_HOME" rev-parse HEAD 2>/dev/null || true)
  [ "$after" = "$source_head" ] || die 'automation home did not settle on the pinned source head'
  printf 'realigned: automation home reset to pinned %s at %s\n' "$SOURCE_BRANCH" "$source_head"
}

sync_automation_code() {
  local source_head auto_branch dirty
  assert_supervisor_owned_automation_home
  auto_branch=$(git -C "$AUTOMATION_HOME" symbolic-ref --short HEAD 2>/dev/null || true)
  [ "$auto_branch" = "$SOURCE_BRANCH" ] \
    || die "automation_home is on '${auto_branch:-a detached head}', expected the pinned branch '$SOURCE_BRANCH'"
  dirty=$(git -C "$AUTOMATION_HOME" status --porcelain --untracked-files=no 2>/dev/null || true)
  [ -z "$dirty" ] || die 'automation_home has tracked local changes; refusing to overwrite them'
  source_head=$(git -C "$SOURCE_HOME" rev-parse "refs/heads/$SOURCE_BRANCH^{commit}" 2>/dev/null) \
    || die "cannot resolve the pinned branch '$SOURCE_BRANCH' in source_home"
  git -C "$AUTOMATION_HOME" fetch --quiet "$SOURCE_HOME" "$SOURCE_BRANCH" \
    || die 'failed to refresh automation code from source_home'
  if git -C "$AUTOMATION_HOME" merge --quiet --ff-only "$source_head" 2>/dev/null; then
    return 0
  fi
  realign_automation_home "$source_head"
}

sync_private_context() {
  local name
  for name in projects.md captain.md learnings.md; do
    copy_private_file "$SOURCE_HOME/data/$name" "$AUTOMATION_HOME/data/$name" \
      || die "failed to synchronize data/$name"
  done
  # The only Slack transport this job may use is the captain's private direct
  # Web API helper, so it is provisioned here rather than discovered at run time.
  copy_private_file "$SOURCE_HOME/$SLACK_TRANSPORT_RELATIVE" "$AUTOMATION_HOME/$SLACK_TRANSPORT_RELATIVE" 0700 \
    || die "failed to synchronize $SLACK_TRANSPORT_RELATIVE"
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$AUTOMATION_HOME/bin/fm-config-inherit-lib.sh"
  propagate_secondmate_inheritance "$SOURCE_HOME" "$AUTOMATION_HOME" \
    || die 'failed to synchronize inherited Firstmate configuration'
}

sync_projects() {
  local registry name src dst origin dst_origin
  registry="$AUTOMATION_HOME/data/projects.md"
  [ -f "$registry" ] || die 'automation project registry is absent'
  # shellcheck source=bin/fm-project-origin-lib.sh
  . "$AUTOMATION_HOME/bin/fm-project-origin-lib.sh"
  while IFS= read -r name; do
    safe_project_name "$name" || die "unsafe project name in registry: $name"
    src="$SOURCE_HOME/projects/$name"
    dst="$AUTOMATION_HOME/projects/$name"
    [ -d "$src" ] && git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "registered source project is unavailable: $name"
    origin=$(git -C "$src" remote get-url origin 2>/dev/null || true)
    [ -n "$origin" ] && fm_project_origin_safe "$origin" || die "project $name has an unsafe or missing origin"
    if [ ! -e "$dst" ]; then
      git clone --quiet --filter=blob:none "$origin" "$dst" || die "failed to clone project $name"
    fi
    [ -d "$dst" ] && git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "automation project is not a git worktree: $name"
    dst_origin=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
    [ "$dst_origin" = "$origin" ] || die "automation project $name has unexpected origin $dst_origin"
  done < <(awk '$1 == "-" { print $2 }' "$registry")
}

slack_transport_state() {
  local path="$AUTOMATION_HOME/$SLACK_TRANSPORT_RELATIVE"
  if [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ]; then
    printf 'available\n'
  else
    printf 'unavailable\n'
  fi
}

host_contract_text() {
  cat <<EOF
version=1
enabled=1
timezone=$TIMEZONE
schedule=$START_HOUR:00-$END_HOUR:00/$INTERVAL_MINUTES-minutes-final-at-end-hour
max_concurrent_reviews=$MAX_CONCURRENT_REVIEWS
publish_review_comments=authorized
minimize_own_superseded_comments=authorized
slack_pr_author_direct_message=authorized
slack_message_template=Review posted: <direct PR comment URL>
slack_transport=$SLACK_TRANSPORT_RELATIVE
slack_transport_state=$(slack_transport_state)
slack_transport_requires=SLACK_BOT_TOKEN
slack_chatgpt_connector=forbidden
slack_any_other_transport=forbidden
agent_attribution=forbidden
edit_code=forbidden
merge_pull_requests=forbidden
mutate_jira=forbidden
EOF
}

write_host_contract() {
  atomic_write "$AUTOMATION_HOME/config/review-sweep-host-contract" 0600 "$(host_contract_text)" \
    || die 'failed to persist the review-sweep host contract'
}

runtime_path_default() {
  local path=${PATH:-}
  local account
  account=$(account_home)
  path="$account/.local/bin:/etc/profiles/per-user/${USER:-$(id -un)}/bin:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${path:+:$path}"
  printf '%s\n' "$path"
}

resolve_codex_bin() {
  local found
  found=$(command -v codex 2>/dev/null || true)
  [ -n "$found" ] && [ -x "$found" ] || die 'codex executable is required for installation'
  case $found in /*) ;; *) found=$(cd "${found%/*}" && printf '%s/%s\n' "$(pwd -P)" "${found##*/}") ;; esac
  printf '%s\n' "$found"
}

write_config() { # <source-home> <source-branch>
  local source=$1 branch=$2 automation codex knowledge runtime
  automation=${FM_REVIEW_SWEEP_AUTOMATION_HOME:-$APP_ROOT/home}
  codex=$(resolve_codex_bin)
  knowledge=${KNOWLEDGE_BASE:-}
  runtime=$(runtime_path_default)
  safe_absolute_path "$source" || die 'install --source-home must be absolute'
  safe_branch_name "$branch" || die 'resolved source branch is unsafe'
  safe_absolute_path "$automation" || die 'automation home must be absolute'
  if [ -n "$knowledge" ]; then safe_absolute_path "$knowledge" || die 'KNOWLEDGE_BASE must be absolute'; fi
  mkdir -p "${CONFIG_PATH%/*}"
  atomic_write "$CONFIG_PATH" 0600 "source_home=$source
source_branch=$branch
automation_home=$automation
codex_bin=$codex
knowledge_base=$knowledge
runtime_path=$runtime
timezone=$DEFAULT_TIMEZONE
start_hour=$DEFAULT_START_HOUR
end_hour=$DEFAULT_END_HOUR
interval_minutes=$DEFAULT_INTERVAL_MINUTES
max_concurrent_reviews=$DEFAULT_MAX_CONCURRENT_REVIEWS
retry_seconds=$DEFAULT_RETRY_SECONDS
max_runtime_seconds=$DEFAULT_MAX_RUNTIME_SECONDS
retention_days=$DEFAULT_RETENTION_DAYS
enabled=1" || die 'failed to write private supervisor config'
}

pin_source_branch() { # <branch>
  local branch=$1 existing
  safe_branch_name "$branch" || die 'resolved source branch is unsafe'
  existing=$(grep -v '^[[:space:]]*source_branch[[:space:]]*=' "$CONFIG_PATH") \
    || die 'cannot read the private supervisor config'
  atomic_write "$CONFIG_PATH" 0600 "$existing
source_branch=$branch" || die 'failed to persist source_branch in the private config'
}

source_branch_is_present() {
  [ -n "$SOURCE_BRANCH" ] || return 1
  git -C "$SOURCE_HOME" rev-parse --verify --quiet "refs/heads/$SOURCE_BRANCH^{commit}" >/dev/null 2>&1
}

install_runtime_script() {
  local parent tmp
  parent=${RUNTIME_SCRIPT%/*}
  mkdir -p "$parent"
  [ -d "$parent" ] && [ ! -L "$parent" ] || die 'runtime directory is unsafe'
  tmp=$(mktemp "$parent/.fm-review-sweep-runtime.XXXXXX") || die 'cannot stage runtime script'
  if ! cp "$0" "$tmp" || ! chmod 0755 "$tmp" || ! mv -f -- "$tmp" "$RUNTIME_SCRIPT"; then
    rm -f -- "$tmp" 2>/dev/null || true
    die 'failed to install runtime script'
  fi
}

xml_escape() {
  local value=$1
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\"/&quot;}
  printf '%s' "$value"
}

render_launchagent() {
  local script config home path log
  script=$(xml_escape "$RUNTIME_SCRIPT")
  config=$(xml_escape "$CONFIG_PATH")
  home=$(xml_escape "$(account_home)")
  path=$(xml_escape "${RUNTIME_PATH:-$(runtime_path_default)}")
  log=$(xml_escape "$LAUNCH_LOG")
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$script</string>
		<string>tick</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$home</string>
		<key>PATH</key>
		<string>$path</string>
		<key>FM_REVIEW_SWEEP_APP_ROOT</key>
		<string>$(xml_escape "$APP_ROOT")</string>
		<key>FM_REVIEW_SWEEP_CONFIG</key>
		<string>$config</string>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
XML
}

launchctl_bin() {
  local value=${FM_REVIEW_SWEEP_LAUNCHCTL:-}
  if [ -n "$value" ]; then printf '%s\n' "$value"; return; fi
  command -v launchctl 2>/dev/null || true
}

gui_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

launchagent_loaded() {
  local ctl loaded
  ctl=$(launchctl_bin)
  [ -n "$ctl" ] && [ -x "$ctl" ] || return 1
  loaded=$($ctl print "$(gui_domain)/$LABEL" 2>/dev/null) || return 1
  case "$loaded" in *"$RUNTIME_SCRIPT"*) ;; *) return 1 ;; esac
  case "$loaded" in *"$LAUNCH_AGENT_PLIST"*) ;; *) return 1 ;; esac
}

write_launchagent() {
  local tmp
  mkdir -p "$LAUNCH_AGENT_DIR" "$LOG_DIR"
  [ -d "$LAUNCH_AGENT_DIR" ] && [ ! -L "$LAUNCH_AGENT_DIR" ] || die 'LaunchAgents directory is unsafe'
  [ -d "$LOG_DIR" ] && [ ! -L "$LOG_DIR" ] || die 'log directory is unsafe'
  tmp=$(mktemp "$LAUNCH_AGENT_DIR/.$LABEL.XXXXXX") || die 'cannot stage LaunchAgent'
  if ! render_launchagent > "$tmp" || ! chmod 0644 "$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    die 'failed to render LaunchAgent'
  fi
  if [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] && cmp -s "$tmp" "$LAUNCH_AGENT_PLIST"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" || die 'failed to publish LaunchAgent'
  return 0
}

reload_launchagent() {
  local ctl domain out
  ctl=$(launchctl_bin)
  [ -n "$ctl" ] && [ -x "$ctl" ] || die 'launchctl is required on macOS'
  domain=$(gui_domain)
  $ctl print "$domain" >/dev/null 2>&1 || die "no Aqua launchd domain is available at $domain"
  $ctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  if ! out=$($ctl bootstrap "$domain" "$LAUNCH_AGENT_PLIST" 2>&1); then
    die "launchctl bootstrap refused: ${out:-no diagnostic}"
  fi
  if ! out=$($ctl kickstart -k "$domain/$LABEL" 2>&1); then
    die "launchctl kickstart refused: ${out:-no diagnostic}"
  fi
  launchagent_loaded || die 'LaunchAgent loaded but its script or property-list identity did not verify'
}

read_clock_fields() {
  local fields=${FM_REVIEW_SWEEP_NOW_FIELDS:-} file=${FM_REVIEW_SWEEP_NOW_FIELDS_FILE:-}
  if [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ]; then
    fields=$(sed -n '1p' "$file")
  fi
  if [ -n "$fields" ]; then
    set -- $fields
    [ "$#" -eq 5 ] || die 'a review-sweep clock override must have five fields'
    printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5"
    return
  fi
  TZ="$TIMEZONE" date '+%Y%m%d %H %M %s %z'
}

current_epoch() {
  local day hour minute epoch offset
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  safe_nonnegative_integer "$epoch" || die 'clock epoch is invalid'
  printf '%s\n' "$epoch"
}

strip_leading_zero() {
  local value=$1
  value=${value#0}
  [ -n "$value" ] || value=0
  printf '%s\n' "$value"
}

slot_at() { # <YYYYMMDD> <HH> <MM>
  local day=$1 hour=$2 minute=$3 hour_n minute_n slot_hour slot_minute
  case $day in ????????) ;; *) return 2 ;; esac
  case $day in *[!0-9]*) return 2 ;; esac
  case $hour in [0-2][0-9]) ;; *) return 2 ;; esac
  case $minute in [0-5][0-9]) ;; *) return 2 ;; esac
  hour_n=$(strip_leading_zero "$hour")
  minute_n=$(strip_leading_zero "$minute")
  [ "$hour_n" -le 23 ] || return 2
  if [ "$hour_n" -lt "$START_HOUR" ]; then return 3; fi
  # The final slot's catch-up window closes with its own half hour, so an
  # unattended cycle never begins an authorized external write after hours.
  if [ "$hour_n" -gt "$END_HOUR" ]; then return 3; fi
  if [ "$hour_n" -eq "$END_HOUR" ]; then
    [ "$minute_n" -lt "$INTERVAL_MINUTES" ] || return 3
    slot_hour=$END_HOUR
    slot_minute=0
  else
    slot_hour=$hour_n
    if [ "$minute_n" -lt "$INTERVAL_MINUTES" ]; then slot_minute=0; else slot_minute=$INTERVAL_MINUTES; fi
  fi
  printf '%s-%02d%02d\n' "$day" "$slot_hour" "$slot_minute"
}

process_is_live_owner() { # <pid>
  local pid=$1 command
  safe_positive_integer "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  [ -z "$command" ] && return 0
  case "$command" in *fm-review-sweep-supervisor.sh*) return 0 ;; *) return 1 ;; esac
}

process_group_of() { # <pid>
  local value
  safe_positive_integer "$1" || return 1
  value=$(ps -p "$1" -o pgid= 2>/dev/null | sed -n '1p' | tr -d '[:space:]')
  safe_positive_integer "${value:-}" || return 1
  printf '%s\n' "$value"
}

lock_dir_age_seconds() {
  local mtime now
  mtime=$(path_mtime "$LOCK_DIR") || return 1
  now=$(date +%s)
  safe_nonnegative_integer "$now" || return 1
  [ "$now" -ge "$mtime" ] || return 1
  printf '%s\n' "$((now - mtime))"
}

lock_cycle_record_field() { # <line-number>
  [ -f "$LOCK_CYCLE_PGID_FILE" ] && [ ! -L "$LOCK_CYCLE_PGID_FILE" ] || return 1
  sed -n "$1p" "$LOCK_CYCLE_PGID_FILE" 2>/dev/null || return 1
}

process_group_runs_codex() { # <pgid>
  safe_positive_integer "$1" || return 1
  [ -n "$CODEX_BIN" ] || return 1
  ps -A -o pgid=,command= 2>/dev/null | awk -v g="$1" '$1 == g { print }' | grep -Fq -- "$CODEX_BIN"
}

lock_cycle_record_age_seconds() {
  local epoch now
  epoch=$(lock_cycle_record_field 2) || epoch=
  if ! safe_nonnegative_integer "${epoch:-}"; then
    lock_dir_age_seconds
    return
  fi
  now=$(date +%s)
  safe_nonnegative_integer "$now" || return 1
  [ "$now" -ge "$epoch" ] || return 1
  printf '%s\n' "$((now - epoch))"
}

# Prints the recorded cycle process group id and reports:
#   0  a live group that cannot be positively ruled out as this cycle's writers
#   1  there is no usable record, or its group is already gone
#   2  positive evidence that the record is stale or its id was reused
#
# This classification is deliberately fail-closed. A live group that still holds
# GitHub and Slack write authorization keeps the lock even when the codex process
# itself has already exited, because a surviving reviewer is exactly what the
# exclusion exists for. Only the age bound - which no legitimate cycle can pass,
# since a cycle is terminated at max_runtime_seconds - retires a live record, and
# even then not while the group still positively runs the configured codex binary.
lock_cycle_group_status() {
  local pgid age bound
  pgid=$(lock_cycle_record_field 1) || return 1
  safe_positive_integer "${pgid:-}" || return 1
  printf '%s\n' "$pgid"
  kill -0 "-$pgid" 2>/dev/null || return 1
  age=$(lock_cycle_record_age_seconds) || return 0
  bound=$((MAX_RUNTIME_SECONDS + LOCK_ORPHAN_GRACE_SECONDS))
  [ "$age" -gt "$bound" ] || return 0
  if process_group_runs_codex "$pgid"; then return 0; fi
  return 2
}

retire_lock_directory() {
  local stale="$STATE_ROOT/run.lock.stale.$$"
  rm -rf -- "$stale" 2>/dev/null || true
  if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
    rm -f -- "$stale/owner" "$stale/cycle-pgid" 2>/dev/null || true
    rmdir -- "$stale" 2>/dev/null || die 'cannot retire stale review-sweep lock safely'
  fi
}

acquire_run_lock() {
  local owner pgid age cycle_rc
  mkdir -p "$STATE_ROOT"
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] || die 'state root is unsafe'
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die 'review-sweep lock path is unsafe'
    owner=
    if [ -f "$LOCK_OWNER_FILE" ] && [ ! -L "$LOCK_OWNER_FILE" ]; then
      owner=$(sed -n '1p' "$LOCK_OWNER_FILE" 2>/dev/null || true)
    fi
    if [ -n "$owner" ]; then
      if process_is_live_owner "$owner"; then
        printf 'busy: review-sweep cycle already owned by pid %s\n' "$owner"
        return 1
      fi
      # A dead supervisor whose cycle process group outlived it still holds the
      # external write authorization, so the lock is kept for any live group that
      # cannot be positively ruled out. Only positive evidence that the record is
      # stale or its id was reused retires it.
      cycle_rc=0
      pgid=$(lock_cycle_group_status) || cycle_rc=$?
      if [ "$cycle_rc" -eq 0 ]; then
        printf 'busy: review-sweep cycle process group %s outlived its supervisor\n' "$pgid"
        return 1
      fi
      if [ "$cycle_rc" -eq 2 ]; then
        printf 'reclaim: retiring a review-sweep cycle process group record (%s) that outlived any possible cycle\n' \
          "${pgid:-unknown}"
      fi
    else
      # A crash between the lock directory and its owner record leaves an
      # ownerless lock that nothing would ever release; reclaim it after a grace
      # long enough that a live claimant in that window is never stolen from.
      age=$(lock_dir_age_seconds) || {
        printf 'busy: review-sweep lock exists without a readable owner or age\n'
        return 1
      }
      if [ "$age" -lt "$LOCK_ORPHAN_GRACE_SECONDS" ]; then
        printf 'busy: review-sweep lock is being claimed by another process\n'
        return 1
      fi
      printf 'reclaim: retiring an ownerless review-sweep lock after %s seconds\n' "$age"
    fi
    retire_lock_directory
  done
  atomic_write "$LOCK_OWNER_FILE" 0600 "$$" || {
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
    die 'cannot publish review-sweep lock owner'
  }
  RUN_LOCK_HELD=1
  RUN_LOCK_RETAINED=0
}

release_run_lock() {
  [ "${RUN_LOCK_HELD:-0}" = 1 ] || return 0
  [ "${RUN_LOCK_RETAINED:-0}" = 0 ] || return 0
  rm -f -- "$LOCK_OWNER_FILE" "$LOCK_CYCLE_PGID_FILE" 2>/dev/null || true
  rmdir -- "$LOCK_DIR" 2>/dev/null || true
  RUN_LOCK_HELD=0
}

cycle_processes_live() {
  if safe_positive_integer "${RUN_CHILD_PGID:-}"; then
    if kill -0 "-$RUN_CHILD_PGID" 2>/dev/null; then return 0; fi
    return 1
  fi
  if safe_positive_integer "${RUN_CHILD_PID:-}"; then
    if kill -0 "$RUN_CHILD_PID" 2>/dev/null; then return 0; fi
  fi
  return 1
}

signal_cycle_processes() { # <signal>
  local signal=$1
  if safe_positive_integer "${RUN_CHILD_PGID:-}"; then
    kill -"$signal" "-$RUN_CHILD_PGID" 2>/dev/null || true
    return 0
  fi
  if safe_positive_integer "${RUN_CHILD_PID:-}"; then
    kill -"$signal" "$RUN_CHILD_PID" 2>/dev/null || true
  fi
  return 0
}

stop_cycle_processes() {
  local waited=0
  if ! cycle_processes_live; then return 0; fi
  signal_cycle_processes TERM
  while [ "$waited" -lt "$CYCLE_STOP_GRACE_SECONDS" ]; do
    if ! cycle_processes_live; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  signal_cycle_processes KILL
  waited=0
  while [ "$waited" -lt "$CYCLE_KILL_GRACE_SECONDS" ]; do
    if ! cycle_processes_live; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  if cycle_processes_live; then return 1; fi
  return 0
}

forget_cycle_processes() {
  RUN_CHILD_PID=
  RUN_CHILD_PGID=
  rm -f -- "$LOCK_CYCLE_PGID_FILE" 2>/dev/null || true
}

slot_file_value() { # <slot-dir> <name>
  local path="$1/$2"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  sed -n '1p' "$path"
}

slot_set() { # <slot-dir> <name> <value>
  atomic_write "$1/$2" 0600 "$3"
}

automation_inflight_count() {
  local count=0 meta
  for meta in "$AUTOMATION_HOME/state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

prune_expired_slot_dirs() { # <root> <cutoff>
  local root=$1 cutoff=$2 entry name mtime
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  for entry in "$root"/*; do
    [ -e "$entry" ] || continue
    name=${entry##*/}
    safe_slot_id "$name" || continue
    [ ! -L "$entry" ] && [ -d "$entry" ] || continue
    mtime=$(path_mtime "$entry") || continue
    [ "$mtime" -lt "$cutoff" ] || continue
    rm -rf -- "$entry" 2>/dev/null || true
  done
}

prune_expired_receipts() { # <root> <cutoff>
  local root=$1 cutoff=$2 entry name mtime
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  for entry in "$root"/*.json; do
    [ -e "$entry" ] || continue
    name=${entry##*/}
    name=${name%.json}
    safe_slot_id "$name" || continue
    [ ! -L "$entry" ] && [ -f "$entry" ] || continue
    mtime=$(path_mtime "$entry") || continue
    [ "$mtime" -lt "$cutoff" ] || continue
    rm -f -- "$entry" 2>/dev/null || true
  done
}

prune_expired_artifacts() {
  # Retention is measured against real file times, and only supervisor-owned
  # regular slot directories, result directories, and receipt files qualify.
  # Anything symlinked or unexpectedly shaped is left untouched.
  local now cutoff
  now=$(date +%s)
  safe_nonnegative_integer "$now" || return 0
  cutoff=$((now - RETENTION_DAYS * 86400))
  [ "$cutoff" -gt 0 ] || return 0
  prune_expired_slot_dirs "$SLOTS_ROOT" "$cutoff"
  prune_expired_slot_dirs "$RESULTS_ROOT" "$cutoff"
  prune_expired_receipts "$AUTOMATION_HOME/state/review-sweep-cycle-receipts" "$cutoff"
}

prune_other_failure_tails() { # <keep-path>
  local keep=$1 entry
  [ -d "$RESULTS_ROOT" ] && [ ! -L "$RESULTS_ROOT" ] || return 0
  for entry in "$RESULTS_ROOT"/*/events.tail.jsonl; do
    [ -e "$entry" ] || continue
    [ "$entry" != "$keep" ] || continue
    [ ! -L "$entry" ] && [ -f "$entry" ] || continue
    rm -f -- "$entry" 2>/dev/null || true
  done
}

bound_cycle_telemetry() { # <result-dir> <event-log> <exit-code>
  local result_dir=$1 event_log=$2 rc=$3 tail_file="$1/events.tail.jsonl" tmp
  if [ "$rc" -eq 0 ]; then
    # A verified cycle keeps its prompt, final result, and receipt. The raw
    # event stream is unbounded telemetry and is not an audit record.
    rm -f -- "$event_log" "$tail_file" "$result_dir/runner.pid" 2>/dev/null || true
    return 0
  fi
  if [ -f "$event_log" ] && [ ! -L "$event_log" ]; then
    rm -f -- "$tail_file" 2>/dev/null || true
    tmp=$(mktemp "$result_dir/.fm-review-sweep-tail.XXXXXX" 2>/dev/null || true)
    if [ -n "$tmp" ]; then
      if tail -n "$EVENT_TAIL_LINES" "$event_log" > "$tmp" 2>/dev/null && chmod 0600 "$tmp" \
        && mv -f -- "$tmp" "$tail_file"; then
        :
      else
        rm -f -- "$tmp" 2>/dev/null || true
      fi
    fi
  fi
  rm -f -- "$event_log" 2>/dev/null || true
  prune_other_failure_tails "$tail_file"
}

review_cycle_prompt() { # <slot>
  local slot=$1
  cat <<EOF
Run the private /nt-review-sweep skill for scheduled slot $slot.

This is a verified host-job run. Read and enforce $AUTOMATION_HOME/config/review-sweep-host-contract before any external write. Read the private policy overlay and the current captain preferences emitted by session start. The captain explicitly approved the large-swarm tradeoff for this job, up to the contract's maximum of $MAX_CONCURRENT_REVIEWS concurrent independent PR reviews.

First reconcile every task already recorded in this isolated home. Recover unfinished review work, use absolute report paths under $AUTOMATION_HOME/data, complete the skill's authorized publication-and-Slack notification sequence, record the direct GitHub comment and Slack message links, resolve any review publication holds from the host-job authorization, mark terminal task metadata accurately, and run guarded teardown for every completed task. Do not start discovery while stale completed metadata remains.

Then refresh Jira live with complete pagination, discover eligible open PR heads, and execute one idempotent sweep. Dispatch no more than $MAX_CONCURRENT_REVIEWS focused reviewers at once. Review only: do not edit project code, merge, push, mutate Jira, or publish anything other than the skill's authorized review comments, minimization of the configured reviewer's own superseded watermark comments, and exact PR-author Slack direct message.

Slack notification transport is restricted to exactly one route: run $AUTOMATION_HOME/$SLACK_TRANSPORT_RELATIVE with an available SLACK_BOT_TOKEN, send the exact authorized message, and capture the direct permalink that helper returns. The ChatGPT Slack connector is forbidden for every message in this job, because it appends agent attribution the captain prohibits; no message may carry any agent or AI attribution. Any other Slack transport, tool, connector, or MCP server is forbidden too. If that helper is missing or not executable, if SLACK_BOT_TOKEN is unavailable, or if the helper fails or returns no permalink, send nothing at all: do not retry through another route, and record that PR's notification as blocked with the exact reason. The host contract's slack_transport_state field states whether the transport was provisioned for this cycle.

After dispatch, supervise in the foreground until every task from this cycle is terminal. Reconcile reports and receipts, complete publication followed immediately by Slack notification, close task records, and run guarded teardown. Do not finish while this home's state contains task metadata. If coverage is partial or an author identity is ambiguous, record that plainly and leave no fabricated success. If no PR needs review, send no Slack message and finish as a verified no-op.

Return the skill's required review table plus totals for discovered, reviewed, skipped, failed, comments published, Slack messages sent, Slack notifications blocked, and tasks left in flight. Name every blocked notification and its reason in that result so the captain sees which authors were not told. The final in-flight total must be zero for a successful cycle.

Before finishing, atomically write this machine receipt to $AUTOMATION_HOME/state/review-sweep-cycle-receipts/$slot.json. Use version 1, slot "$slot", coverage "complete" only after full Jira and GitHub verification, nonnegative integer fields discovered/reviewed/skipped/comments_published/slack_messages_sent, integer failed 0, integer tasks_left_in_flight 0, and a reviews array with exactly one row per reviewed PR. Each row must contain pr, full head, direct comment_url, and slack. slack is exactly one of {"status":"sent","message_url":"<direct Slack permalink returned by the transport>"}, {"status":"skipped","reason":"<no unique author match reason>"}, or {"status":"blocked","reason":"<why the authorized transport could not be used>"}. Use blocked, never skipped, when the author was identified but the private transport was unavailable or failed. comments_published must equal reviewed. slack_messages_sent must equal the number of sent rows, and every sent row must carry the permalink the transport returned. A no-op sweep uses zero counts and an empty reviews array. Do not write coverage complete when any required coverage, publication, notification decision, metadata reconciliation, or teardown is unresolved.
EOF
}

receipt_gate_program() {
  cat <<'JQ'
. as $receipt |
($receipt | type) == "object" and
$receipt.version == 1 and
$receipt.slot == $slot and
$receipt.coverage == "complete" and
($receipt.discovered | type == "number" and . >= 0 and floor == .) and
($receipt.reviewed | type == "number" and . >= 0 and floor == .) and
($receipt.skipped | type == "number" and . >= 0 and floor == .) and
$receipt.failed == 0 and
($receipt.comments_published == $receipt.reviewed) and
($receipt.slack_messages_sent | type == "number" and . >= 0 and floor == .) and
$receipt.tasks_left_in_flight == 0 and
($receipt.reviews | type) == "array" and
($receipt.reviews | length) == $receipt.reviewed and
all($receipt.reviews[];
  (type == "object") and
  (.pr | type == "string" and test("^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$")) and
  (.head | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
  (.comment_url | type == "string" and test("^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+#issuecomment-[0-9]+$")) and
  ((.slack | type) == "object") and
  (.slack.status == "sent" or .slack.status == "skipped" or .slack.status == "blocked") and
  (if .slack.status == "sent" then
     (.slack.message_url | type == "string" and test("^https://[^/]*slack[.]com/archives/"))
   else
     (.slack.reason | type == "string" and length > 0)
   end)) and
$receipt.slack_messages_sent == ([$receipt.reviews[] | select(.slack.status == "sent")] | length)
JQ
}

# Receipt outcomes are distinct so a missing tool, unreadable JSON, and a
# semantically invalid receipt are never reported as the same failure:
#   74  the cycle published no receipt
#   75  the receipt is valid JSON but does not satisfy the publication contract,
#       including a field whose type makes the contract unevaluable
#   76  the receipt is not parseable as a JSON object
#   77  jq itself could not run the receipt gate
verify_cycle_receipt() { # <slot> <receipt-path>
  local slot=$1 receipt=$2 status=0
  if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
    printf 'error: slot %s did not publish its cycle receipt at %s\n' "$slot" "$receipt" >&2
    return 74
  fi
  "$JQ_BIN" -e 'type == "object"' "$receipt" >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'error: slot %s published a receipt that is not a readable JSON object (jq exit %s)\n' \
      "$slot" "$status" >&2
    return 76
  fi
  status=0
  "$JQ_BIN" -e --arg slot "$slot" "$(receipt_gate_program)" "$receipt" >/dev/null 2>&1 || status=$?
  case $status in
    0) return 0 ;;
    1|4|5)
      printf 'error: slot %s published an invalid or incomplete cycle receipt\n' "$slot" >&2
      return 75
      ;;
    *)
      printf 'error: slot %s receipt gate could not be run by jq (exit %s)\n' "$slot" "$status" >&2
      return 77
      ;;
  esac
}

run_codex_cycle() { # <slot> <result-dir>
  local slot=$1 result_dir=$2 prompt prompt_file result_file event_log receipt
  local pid pgid self_pgid job_control=0 start_epoch now_epoch deadline rc=0 inflight receipt_rc
  mkdir -p "$result_dir"
  [ -d "$result_dir" ] && [ ! -L "$result_dir" ] || die 'result directory is unsafe'
  prompt_file="$result_dir/prompt.txt"
  result_file="$result_dir/result.txt"
  event_log="$result_dir/events.jsonl"
  receipt="$AUTOMATION_HOME/state/review-sweep-cycle-receipts/$slot.json"
  prompt=$(review_cycle_prompt "$slot")
  atomic_write "$prompt_file" 0600 "$prompt" || die 'failed to write cycle prompt'
  if [ -L "$event_log" ] || [ -L "$result_file" ] || [ -L "$receipt" ]; then
    die 'refusing symlinked review-cycle output path'
  fi
  rm -f -- "$result_file" "$receipt" "$result_dir/events.tail.jsonl"
  : > "$event_log"
  chmod 0600 "$event_log"
  start_epoch=$(date +%s)
  deadline=$((start_epoch + MAX_RUNTIME_SECONDS))
  self_pgid=$(process_group_of "$$" || true)
  # Job control puts the cycle in its own process group, so every reviewer the
  # cycle spawns can be terminated as one owned group rather than one pid.
  set -m
  case $- in *m*) job_control=1 ;; esac
  (
    export HOME
    export PATH="$RUNTIME_PATH"
    export FM_HOME="$AUTOMATION_HOME"
    export TZ="$TIMEZONE"
    if [ -n "$KNOWLEDGE_BASE_PATH" ]; then export KNOWLEDGE_BASE="$KNOWLEDGE_BASE_PATH"; fi
    exec "$CODEX_BIN" exec --ephemeral --json --color never --approve-for-me \
      -C "$AUTOMATION_HOME" -o "$result_file" "$prompt"
  ) > "$event_log" 2>&1 < /dev/null &
  pid=$!
  set +m
  RUN_CHILD_PID=$pid
  RUN_CHILD_PGID=
  pgid=$(process_group_of "$pid" || true)
  if safe_positive_integer "${pgid:-}"; then
    if [ "$pgid" = "$pid" ] && [ "$pgid" != "${self_pgid:-}" ]; then RUN_CHILD_PGID=$pgid; fi
  elif [ "$job_control" = 1 ] && [ "$pid" != "${self_pgid:-}" ]; then
    RUN_CHILD_PGID=$pid
  fi
  if [ -n "$RUN_CHILD_PGID" ]; then
    if [ "${RUN_LOCK_HELD:-0}" = 1 ]; then
      atomic_write "$LOCK_CYCLE_PGID_FILE" 0600 "$RUN_CHILD_PGID
$(date +%s)" || true
    fi
  else
    printf 'warning: slot %s did not obtain an owned cycle process group; only its direct child can be stopped\n' \
      "$slot" >&2
  fi
  atomic_write "$result_dir/runner.pid" 0600 "$pid" || true
  while kill -0 "$pid" 2>/dev/null; do
    now_epoch=$(date +%s)
    if [ "$now_epoch" -ge "$deadline" ]; then
      printf 'timeout: slot %s exceeded %s seconds; stopping its cycle process group\n' \
        "$slot" "$MAX_RUNTIME_SECONDS" >&2
      stop_cycle_processes || true
      rc=124
      break
    fi
    sleep 5
  done
  if [ "$rc" -eq 0 ]; then wait "$pid" || rc=$?; else wait "$pid" 2>/dev/null || true; fi
  # The exclusion lock is only meaningful while no authorized writer from this
  # cycle survives, so confirm the whole group is gone before anything releases.
  if stop_cycle_processes; then
    forget_cycle_processes
  else
    printf 'error: slot %s left cycle processes running after termination escalation\n' "$slot" >&2
    [ "$rc" -ne 0 ] || rc=71
    RUN_LOCK_RETAINED=1
  fi
  inflight=$(automation_inflight_count)
  atomic_write "$result_dir/inflight-count" 0600 "$inflight" || true
  if [ "$inflight" -ne 0 ]; then
    printf 'error: slot %s ended with %s task metadata record(s) still in flight\n' "$slot" "$inflight" >&2
    [ "$rc" -ne 0 ] || rc=73
  fi
  # The receipt is the only durable evidence of what this cycle published, so it
  # is read and recorded whatever else went wrong. Nothing may re-run a slot
  # whose publication verified, or duplicate comments and author DMs follow.
  receipt_rc=0
  verify_cycle_receipt "$slot" "$receipt" || receipt_rc=$?
  atomic_write "$result_dir/receipt-status" 0600 "$receipt_rc" || true
  if [ "$receipt_rc" -eq 0 ] && [ "$inflight" -eq 0 ]; then
    CYCLE_PUBLICATION_VERIFIED=1
  else
    CYCLE_PUBLICATION_VERIFIED=0
  fi
  if [ "$rc" -eq 0 ] && [ "$receipt_rc" -ne 0 ]; then rc=$receipt_rc; fi
  bound_cycle_telemetry "$result_dir" "$event_log" "$rc"
  return "$rc"
}

handle_cycle_signal() {
  local signal=${1:-TERM}
  if stop_cycle_processes; then
    forget_cycle_processes
    release_run_lock
  else
    printf 'error: review-sweep cycle processes survived termination; retaining the owner lock\n' >&2
    RUN_LOCK_RETAINED=1
  fi
  case $signal in HUP) exit 129 ;; INT) exit 130 ;; *) exit 143 ;; esac
}

slot_admission() { # <slot> <now-epoch>
  local slot=$1 now_epoch=$2 status retry_at
  safe_single_line "$slot" || die 'slot id is invalid'
  safe_slot_id "$slot" || die 'slot id is invalid'
  mkdir -p "$SLOTS_ROOT" "$RESULTS_ROOT"
  SLOT_DIR="$SLOTS_ROOT/$slot"
  mkdir -p "$SLOT_DIR"
  [ -d "$SLOT_DIR" ] && [ ! -L "$SLOT_DIR" ] || die 'slot state directory is unsafe'
  SLOT_ADMISSION_MESSAGE=
  status=$(slot_file_value "$SLOT_DIR" status 2>/dev/null || true)
  if [ "$status" = succeeded ]; then
    SLOT_ADMISSION_MESSAGE="noop: slot $slot already succeeded"
    return 1
  fi
  retry_at=$(slot_file_value "$SLOT_DIR" retry-at 2>/dev/null || printf '0')
  safe_nonnegative_integer "$retry_at" || retry_at=0
  if [ "$status" = failed ] && [ "$now_epoch" -lt "$retry_at" ]; then
    SLOT_ADMISSION_MESSAGE="deferred: slot $slot retry is due at epoch $retry_at"
    return 1
  fi
  # A slot left in "running" by a crash is deliberately admitted so the next
  # tick recovers it under the same slot identity.
  return 0
}

record_slot_failure() { # <slot> <exit-code> <reason>
  local slot=$1 rc=$2 reason=$3 completed
  # The retry deadline is measured from when the attempt actually finished, so a
  # cycle longer than retry_seconds still waits a full throttle before attempt N+1,
  # and a repeatedly failing preparation costs one attempt per slot, not per tick.
  completed=$(current_epoch)
  slot_set "$SLOT_DIR" completed-at "$completed"
  slot_set "$SLOT_DIR" exit-code "$rc"
  slot_set "$SLOT_DIR" retry-at "$((completed + RETRY_SECONDS))"
  slot_set "$SLOT_DIR" status failed
  printf 'complete: slot=%s status=failed exit=%s retry-after=%s reason=%s\n' \
    "$slot" "$rc" "$RETRY_SECONDS" "$reason" >&2
}

claim_slot_attempt() { # <slot> <now-epoch>
  local slot=$1 now_epoch=$2 attempt
  attempt=$(slot_file_value "$SLOT_DIR" attempt 2>/dev/null || printf '0')
  safe_nonnegative_integer "$attempt" || attempt=0
  attempt=$((attempt + 1))
  slot_set "$SLOT_DIR" attempt "$attempt"
  slot_set "$SLOT_DIR" started-at "$now_epoch"
  slot_set "$SLOT_DIR" owner-pid "$$"
  slot_set "$SLOT_DIR" status running
  printf '%s\n' "$attempt"
}

run_slot() { # <slot> <now-epoch> <attempt>
  local slot=$1 now_epoch=$2 attempt=$3 result_dir rc=0 completed
  result_dir="$RESULTS_ROOT/$slot"
  CYCLE_PUBLICATION_VERIFIED=0
  printf 'start: slot=%s attempt=%s max-concurrent-reviews=%s\n' "$slot" "$attempt" "$MAX_CONCURRENT_REVIEWS"
  run_codex_cycle "$slot" "$result_dir" || rc=$?
  slot_set "$SLOT_DIR" receipt-status "$(slot_receipt_status "$result_dir")"
  if [ "$rc" -eq 0 ]; then
    completed=$(current_epoch)
    slot_set "$SLOT_DIR" completed-at "$completed"
    slot_set "$SLOT_DIR" status succeeded
    atomic_write "$STATE_ROOT/last-succeeded-slot" 0600 "$slot" || true
    printf 'complete: slot=%s status=succeeded\n' "$slot"
  elif [ "${CYCLE_PUBLICATION_VERIFIED:-0}" = 1 ]; then
    completed=$(current_epoch)
    slot_set "$SLOT_DIR" completed-at "$completed"
    slot_set "$SLOT_DIR" exit-code "$rc"
    slot_set "$SLOT_DIR" status succeeded
    atomic_write "$STATE_ROOT/last-succeeded-slot" 0600 "$slot" || true
    printf 'complete: slot=%s status=succeeded exit=%s publication=verified\n' "$slot" "$rc" >&2
  else
    record_slot_failure "$slot" "$rc" cycle
  fi
  prune_expired_artifacts
  return "$rc"
}

slot_receipt_status() { # <result-dir>
  local value
  value=$(slot_file_value "$1" receipt-status 2>/dev/null || true)
  safe_nonnegative_integer "${value:-}" || value=unknown
  printf '%s\n' "$value"
}

prepare_cycle_home() {
  ensure_automation_home
  sync_automation_code
  sync_private_context
  sync_projects
  write_host_contract
}

run_supervised_cycle() { # <slot> <now-epoch>
  local slot=$1 now_epoch=$2 rc=0 attempt prepare_rc=0
  acquire_run_lock || return 0
  trap release_run_lock EXIT
  trap 'handle_cycle_signal HUP' HUP
  trap 'handle_cycle_signal INT' INT
  trap 'handle_cycle_signal TERM' TERM
  # Slot admission is decided under the lock and before any synchronization, so
  # a duplicate minute tick costs one state read instead of a full home sync.
  if slot_admission "$slot" "$now_epoch"; then
    attempt=$(claim_slot_attempt "$slot" "$now_epoch")
    # Preparation runs in a subshell so a synchronization failure is recorded
    # against the slot and throttled, instead of being retried every minute.
    ( prepare_cycle_home ) || prepare_rc=$?
    if [ "$prepare_rc" -eq 0 ]; then
      run_slot "$slot" "$now_epoch" "$attempt" || rc=$?
    else
      rc=$prepare_rc
      record_slot_failure "$slot" "$rc" preparation
    fi
  else
    printf '%s\n' "$SLOT_ADMISSION_MESSAGE"
  fi
  release_run_lock
  trap - EXIT HUP INT TERM
  return "$rc"
}

tick() {
  local day hour minute epoch offset slot rc=0
  load_config
  [ "$ENABLED" = 1 ] || { printf 'disabled: review-sweep supervisor\n'; return 0; }
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  safe_nonnegative_integer "$epoch" || die 'clock epoch is invalid'
  slot=$(slot_at "$day" "$hour" "$minute" 2>/dev/null || true)
  [ -n "$slot" ] || { printf 'noop: no review-sweep slot is due\n'; return 0; }
  run_supervised_cycle "$slot" "$epoch" || rc=$?
  return "$rc"
}

run_now() {
  local day hour minute epoch offset slot rc=0
  load_config
  [ "$ENABLED" = 1 ] || die 'review-sweep supervisor is disabled'
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  safe_nonnegative_integer "$epoch" || die 'clock epoch is invalid'
  slot="manual-$day-$hour$minute-$epoch"
  run_supervised_cycle "$slot" "$epoch" || rc=$?
  return "$rc"
}

install_supervisor() {
  local source= branch= changed=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --source-home) [ "$#" -ge 2 ] || usage; source=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$source" ] || usage
  if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then
    load_config --allow-missing-source-branch
    [ "$SOURCE_HOME" = "$source" ] \
      || die "existing config belongs to source_home $SOURCE_HOME; remove $CONFIG_PATH to install a different source home"
    if ! source_branch_is_present; then
      # A config written before the branch pin, or one pinned to a branch the
      # source home no longer carries, is repaired in place rather than requiring
      # a hand edit under the private application-support directory. A pin that
      # still resolves is never rewritten.
      validate_source_home "$SOURCE_HOME"
      branch=$(source_default_branch "$SOURCE_HOME") \
        || die 'cannot resolve the default branch of source_home'
      pin_source_branch "$branch"
      load_config
      printf 'repinned: source_branch=%s\n' "$SOURCE_BRANCH"
    fi
  else
    # Nothing is persisted until the supplied home proves it is a Firstmate
    # worktree root, so a mistyped path leaves the installer reusable.
    validate_source_home "$source"
    branch=$(source_default_branch "$source") \
      || die 'cannot resolve the default branch of source_home'
    write_config "$source" "$branch"
    load_config
  fi
  install_runtime_script
  ensure_automation_home
  sync_automation_code
  sync_private_context
  sync_projects
  write_host_contract
  if write_launchagent; then changed=1; else changed=0; fi
  if [ "$changed" -eq 1 ] || ! launchagent_loaded; then reload_launchagent; fi
  printf 'installed: %s\n' "$LABEL"
  printf 'schedule: %02d:00-%02d:00 %s every %s minutes, final slot %02d:00\n' \
    "$START_HOUR" "$END_HOUR" "$TIMEZONE" "$INTERVAL_MINUTES" "$END_HOUR"
  printf 'max-concurrent-reviews: %s\n' "$MAX_CONCURRENT_REVIEWS"
  printf 'source-branch: %s\n' "$SOURCE_BRANCH"
  printf 'retention-days: %s\n' "$RETENTION_DAYS"
  printf 'slack-transport: %s (%s)\n' "$SLACK_TRANSPORT_RELATIVE" "$(slack_transport_state)"
  printf 'automation-home: %s\n' "$AUTOMATION_HOME"
  printf 'config: %s\n' "$CONFIG_PATH"
}

status_supervisor() {
  local loaded=no lock=idle owner= pgid cycle_rc latest=none slot_status=unknown slot_receipt=unknown
  if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then
    load_config
  else
    printf 'installed: no\nconfig: %s\n' "$CONFIG_PATH"
    return 1
  fi
  launchagent_loaded && loaded=yes
  if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
    if [ -f "$LOCK_OWNER_FILE" ] && [ ! -L "$LOCK_OWNER_FILE" ]; then
      owner=$(sed -n '1p' "$LOCK_OWNER_FILE" 2>/dev/null || true)
      cycle_rc=0
      pgid=$(lock_cycle_group_status) || cycle_rc=$?
      if process_is_live_owner "$owner"; then
        lock="running pid=$owner"
      elif [ "$cycle_rc" -eq 0 ]; then
        lock="orphaned cycle process group=$pgid"
      elif [ "$cycle_rc" -eq 2 ]; then
        lock="reclaimable expired cycle process group record=${pgid:-unknown}"
      else
        lock="stale pid=${owner:-unknown}"
      fi
    else
      lock="ownerless since $(lock_dir_age_seconds || printf unknown) seconds"
    fi
  fi
  if [ -f "$STATE_ROOT/last-succeeded-slot" ] && [ ! -L "$STATE_ROOT/last-succeeded-slot" ]; then
    latest=$(sed -n '1p' "$STATE_ROOT/last-succeeded-slot")
    slot_status=$(slot_file_value "$SLOTS_ROOT/$latest" status 2>/dev/null || printf unknown)
    slot_receipt=$(slot_file_value "$SLOTS_ROOT/$latest" receipt-status 2>/dev/null || printf unknown)
  fi
  printf 'installed: yes\n'
  printf 'enabled: %s\n' "$ENABLED"
  printf 'launchagent-loaded: %s\n' "$loaded"
  printf 'schedule: %02d:00-%02d:00 %s every %s minutes, final slot %02d:00\n' \
    "$START_HOUR" "$END_HOUR" "$TIMEZONE" "$INTERVAL_MINUTES" "$END_HOUR"
  printf 'max-concurrent-reviews: %s\n' "$MAX_CONCURRENT_REVIEWS"
  printf 'source-branch: %s\n' "$SOURCE_BRANCH"
  printf 'retention-days: %s\n' "$RETENTION_DAYS"
  printf 'slack-transport: %s (%s)\n' "$SLACK_TRANSPORT_RELATIVE" "$(slack_transport_state)"
  printf 'cycle: %s\n' "$lock"
  printf 'last-succeeded-slot: %s\n' "$latest"
  printf 'last-slot-status: %s\n' "$slot_status"
  printf 'last-slot-receipt-status: %s\n' "$slot_receipt"
  printf 'automation-inflight: %s\n' "$(automation_inflight_count)"
  [ "$loaded" = yes ]
}

uninstall_supervisor() {
  local ctl domain
  ctl=$(launchctl_bin)
  domain=$(gui_domain)
  if [ -n "$ctl" ] && [ -x "$ctl" ]; then $ctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true; fi
  if [ -L "$LAUNCH_AGENT_PLIST" ]; then die 'refusing to remove symlinked LaunchAgent path'; fi
  rm -f -- "$LAUNCH_AGENT_PLIST"
  printf 'uninstalled: %s\n' "$LABEL"
  printf 'retained-runtime: %s\n' "$APP_ROOT"
}

command=${1:-}
case $command in
  install) shift; install_supervisor "$@" ;;
  tick) [ "$#" -eq 1 ] || usage; tick ;;
  run-now) [ "$#" -eq 1 ] || usage; run_now ;;
  status) [ "$#" -eq 1 ] || usage; status_supervisor ;;
  render-launchagent)
    [ "$#" -eq 1 ] || usage
    if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then load_config; fi
    render_launchagent
    ;;
  slot-at)
    [ "$#" -eq 4 ] || usage
    if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then load_config; fi
    slot_at "$2" "$3" "$4"
    ;;
  uninstall) [ "$#" -eq 1 ] || usage; uninstall_supervisor ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
