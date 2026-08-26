#!/usr/bin/env bash
# Durable local scheduler for the private nt-review-sweep skill.
#
# Usage:
#   fm-review-sweep-supervisor.sh install --source-home <firstmate-home>
#       Install an Aqua LaunchAgent, an isolated automation home, a private
#       host-job authorization contract, and the current script bytes. The
#       default schedule is every half hour from 07:00 through 17:00 in
#       America/Chicago, with the final daily slot at 17:00 and a maximum of
#       ten concurrent reviews. Existing private configuration is preserved;
#       rerunning install refreshes code, context, projects, and the launchd
#       contract idempotently.
#   fm-review-sweep-supervisor.sh tick
#       Claim and run the newest due slot for the current Chicago day. A single
#       process owns the slot through completion. A wake after sleep catches up
#       only the newest missed slot, never replays a backlog of old slots.
#   fm-review-sweep-supervisor.sh run-now
#       Run one manually named slot immediately, through the same lock, review
#       lifecycle, receipt, and retry machinery as a scheduled slot.
#   fm-review-sweep-supervisor.sh status
#       Print installation, launchd, active-run, and latest-slot state.
#   fm-review-sweep-supervisor.sh render-launchagent
#       Print the exact property list contract for inspection or tests.
#   fm-review-sweep-supervisor.sh slot-at <YYYYMMDD> <HH> <MM>
#       Print the newest due slot for supplied local clock fields, or nothing
#       before the daily window. This is a deterministic diagnostic surface.
#   fm-review-sweep-supervisor.sh uninstall
#       Boot out the exact LaunchAgent and remove its property list. Runtime
#       state, logs, reports, the isolated home, and configuration are retained.
#
# The scheduler is deliberately thin. The installed nt-review-sweep skill owns
# Jira and GitHub discovery, watermark rules, review shape, publication, and the
# Slack author notification. This script owns only recurrence, an isolated
# execution home, the persisted host-job authorization, crash-safe slot claims,
# bounded process lifetime, and terminal task reconciliation.
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
# FM_REVIEW_SWEEP_LAUNCHCTL, and FM_REVIEW_SWEEP_NOW_FIELDS. The last value is
# five space-separated fields: YYYYMMDD HH MM epoch UTC-offset.
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

SOURCE_HOME=
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
ENABLED=1

config_value_seen() {
  case " ${CONFIG_KEYS_SEEN:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

load_config() {
  local key value line_no=0
  [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ] || die "missing private supervisor config: $CONFIG_PATH"
  CONFIG_KEYS_SEEN=
  while IFS='=' read -r key value || [ -n "${key:-}${value:-}" ]; do
    line_no=$((line_no + 1))
    case ${key:-} in ''|'#'*) continue ;; esac
    case ${key:-} in
      source_home|automation_home|codex_bin|knowledge_base|runtime_path|timezone|start_hour|end_hour|interval_minutes|max_concurrent_reviews|retry_seconds|max_runtime_seconds|enabled) ;;
      *) die "unknown config key '$key' on line $line_no" ;;
    esac
    config_value_seen "$key" && die "duplicate config key '$key'"
    CONFIG_KEYS_SEEN="${CONFIG_KEYS_SEEN:+$CONFIG_KEYS_SEEN }$key"
    safe_single_line "${value:-}" || die "config value for $key is not one line"
    case $key in
      source_home) SOURCE_HOME=$value ;;
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
      enabled) ENABLED=$value ;;
    esac
  done < <(awk 'BEGIN { FS="=" } { key=$1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key); value=substr($0, index($0, "=")+1); if (index($0, "=")==0) { print $0 "=" } else { print key "=" value } }' "$CONFIG_PATH")

  safe_absolute_path "$SOURCE_HOME" || die 'source_home must be an absolute non-root path'
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
  case $ENABLED in 0|1) ;; *) die 'enabled must be 0 or 1' ;; esac
  case ":$RUNTIME_PATH:" in *::*|*:$'\n'*|*:$'\r'*) die 'runtime_path is invalid' ;; esac
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

copy_private_file() { # <source> <destination>
  local src=$1 dest=$2 parent tmp
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    [ ! -e "$dest" ] && [ ! -L "$dest" ] || rm -f -- "$dest"
    return 0
  fi
  [ -f "$src" ] && [ ! -L "$src" ] || return 1
  parent=${dest%/*}
  mkdir -p "$parent"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"; then
    chmod 0600 "$dest" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp "$parent/.fm-review-sweep-copy.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
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

ensure_automation_home() {
  local source_top source_branch
  [ -d "$SOURCE_HOME" ] && [ ! -L "$SOURCE_HOME" ] || die "source home is unavailable: $SOURCE_HOME"
  source_top=$(git -C "$SOURCE_HOME" rev-parse --show-toplevel 2>/dev/null) || die 'source_home is not a git worktree'
  [ "$source_top" = "$SOURCE_HOME" ] || die 'source_home must name the Firstmate worktree root'
  [ -f "$SOURCE_HOME/AGENTS.md" ] && [ -x "$SOURCE_HOME/bin/fm-session-start.sh" ] \
    || die 'source_home is not a Firstmate home'
  source_branch=$(git -C "$SOURCE_HOME" symbolic-ref --short HEAD 2>/dev/null || true)
  [ -n "$source_branch" ] || die 'source_home must be on its default branch, not detached'

  if [ ! -e "$AUTOMATION_HOME" ]; then
    mkdir -p "${AUTOMATION_HOME%/*}"
    git clone --quiet --no-hardlinks --branch "$source_branch" "$SOURCE_HOME" "$AUTOMATION_HOME" \
      || die 'failed to clone the isolated automation home'
  fi
  [ -d "$AUTOMATION_HOME" ] && [ ! -L "$AUTOMATION_HOME" ] || die 'automation_home is unsafe'
  [ "$(git -C "$AUTOMATION_HOME" rev-parse --show-toplevel 2>/dev/null || true)" = "$AUTOMATION_HOME" ] \
    || die 'automation_home is not an isolated git worktree root'
  [ "$AUTOMATION_HOME" != "$SOURCE_HOME" ] || die 'automation_home must differ from source_home'
  case "$AUTOMATION_HOME/" in "$SOURCE_HOME/"*) die 'automation_home cannot be inside source_home' ;; esac
  mkdir -p "$AUTOMATION_HOME/data" "$AUTOMATION_HOME/state" "$AUTOMATION_HOME/config" "$AUTOMATION_HOME/projects"
  write_empty_backlog "$AUTOMATION_HOME/data/backlog.md" || die 'failed to initialize the automation backlog'
}

sync_automation_code() {
  local branch source_head auto_branch dirty
  branch=$(git -C "$SOURCE_HOME" symbolic-ref --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || die 'source_home became detached'
  auto_branch=$(git -C "$AUTOMATION_HOME" symbolic-ref --short HEAD 2>/dev/null || true)
  [ "$auto_branch" = "$branch" ] || die "automation_home is on '$auto_branch', expected '$branch'"
  dirty=$(git -C "$AUTOMATION_HOME" status --porcelain --untracked-files=no 2>/dev/null || true)
  [ -z "$dirty" ] || die 'automation_home has tracked local changes; refusing to overwrite them'
  source_head=$(git -C "$SOURCE_HOME" rev-parse "$branch^{commit}" 2>/dev/null) || die 'cannot resolve source_home head'
  git -C "$AUTOMATION_HOME" fetch --quiet "$SOURCE_HOME" "$branch" || die 'failed to refresh automation code from source_home'
  git -C "$AUTOMATION_HOME" merge --quiet --ff-only "$source_head" || die 'automation code cannot fast-forward to source_home'
}

sync_private_context() {
  local name
  for name in projects.md captain.md learnings.md; do
    copy_private_file "$SOURCE_HOME/data/$name" "$AUTOMATION_HOME/data/$name" \
      || die "failed to synchronize data/$name"
  done
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$AUTOMATION_HOME/bin/fm-config-inherit-lib.sh"
  propagate_secondmate_inheritance "$SOURCE_HOME" "$AUTOMATION_HOME" \
    || die 'failed to synchronize inherited Firstmate configuration'
}

project_origin_safe() {
  # shellcheck source=bin/fm-project-origin-lib.sh
  . "$AUTOMATION_HOME/bin/fm-project-origin-lib.sh"
  fm_project_origin_safe "$1"
}

sync_projects() {
  local registry name src dst origin dst_origin
  registry="$AUTOMATION_HOME/data/projects.md"
  [ -f "$registry" ] || die 'automation project registry is absent'
  while IFS= read -r name; do
    safe_project_name "$name" || die "unsafe project name in registry: $name"
    src="$SOURCE_HOME/projects/$name"
    dst="$AUTOMATION_HOME/projects/$name"
    [ -d "$src" ] && git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "registered source project is unavailable: $name"
    origin=$(git -C "$src" remote get-url origin 2>/dev/null || true)
    [ -n "$origin" ] && project_origin_safe "$origin" || die "project $name has an unsafe or missing origin"
    if [ ! -e "$dst" ]; then
      git clone --quiet --filter=blob:none "$origin" "$dst" || die "failed to clone project $name"
    fi
    [ -d "$dst" ] && git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "automation project is not a git worktree: $name"
    dst_origin=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
    [ "$dst_origin" = "$origin" ] || die "automation project $name has unexpected origin $dst_origin"
  done < <(awk '$1 == "-" { print $2 }' "$registry")
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

write_config() { # <source-home>
  local source=$1 automation codex knowledge runtime
  automation=${FM_REVIEW_SWEEP_AUTOMATION_HOME:-$APP_ROOT/home}
  codex=$(resolve_codex_bin)
  knowledge=${KNOWLEDGE_BASE:-}
  runtime=$(runtime_path_default)
  safe_absolute_path "$source" || die 'install --source-home must be absolute'
  safe_absolute_path "$automation" || die 'automation home must be absolute'
  if [ -n "$knowledge" ]; then safe_absolute_path "$knowledge" || die 'KNOWLEDGE_BASE must be absolute'; fi
  mkdir -p "${CONFIG_PATH%/*}"
  atomic_write "$CONFIG_PATH" 0600 "source_home=$source
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
enabled=1" || die 'failed to write private supervisor config'
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
  local fields=${FM_REVIEW_SWEEP_NOW_FIELDS:-}
  if [ -n "$fields" ]; then
    set -- $fields
    [ "$#" -eq 5 ] || die 'FM_REVIEW_SWEEP_NOW_FIELDS must have five fields'
    printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5"
    return
  fi
  TZ="$TIMEZONE" date '+%Y%m%d %H %M %s %z'
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
  if [ "$hour_n" -ge "$END_HOUR" ]; then
    slot_hour=$END_HOUR
    slot_minute=0
  else
    slot_hour=$hour_n
    if [ "$minute_n" -lt "$INTERVAL_MINUTES" ]; then slot_minute=0; else slot_minute=$INTERVAL_MINUTES; fi
  fi
  printf '%s-%02d%02d\n' "$day" "$slot_hour" "$slot_minute"
}

latest_due_slot() {
  local day hour minute epoch offset
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  safe_nonnegative_integer "$epoch" || die 'clock epoch is invalid'
  slot_at "$day" "$hour" "$minute"
}

process_is_live_owner() { # <pid>
  local pid=$1 command
  safe_positive_integer "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  [ -z "$command" ] && return 0
  case "$command" in *fm-review-sweep-supervisor.sh*) return 0 ;; *) return 1 ;; esac
}

acquire_run_lock() {
  local owner pid stale
  mkdir -p "$STATE_ROOT"
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] || die 'state root is unsafe'
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner="$LOCK_DIR/owner"
    [ -f "$owner" ] && [ ! -L "$owner" ] || {
      printf 'busy: review-sweep lock exists without a readable owner\n'
      return 1
    }
    pid=$(sed -n '1p' "$owner" 2>/dev/null || true)
    if process_is_live_owner "$pid"; then
      printf 'busy: review-sweep cycle already owned by pid %s\n' "$pid"
      return 1
    fi
    stale="$STATE_ROOT/run.lock.stale.$$"
    if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
      rm -f -- "$stale/owner" 2>/dev/null || true
      rmdir -- "$stale" 2>/dev/null || die 'cannot retire stale review-sweep lock safely'
    fi
  done
  atomic_write "$LOCK_DIR/owner" 0600 "$$" || {
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
    die 'cannot publish review-sweep lock owner'
  }
  RUN_LOCK_HELD=1
}

release_run_lock() {
  [ "${RUN_LOCK_HELD:-0}" = 1 ] || return 0
  rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
  rmdir -- "$LOCK_DIR" 2>/dev/null || true
  RUN_LOCK_HELD=0
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

review_cycle_prompt() { # <slot>
  local slot=$1
  cat <<EOF
Run the private /nt-review-sweep skill for scheduled slot $slot.

This is a verified host-job run. Read and enforce $AUTOMATION_HOME/config/review-sweep-host-contract before any external write. Read the private policy overlay and the current captain preferences emitted by session start. The captain explicitly approved the large-swarm tradeoff for this job, up to the contract's maximum of $MAX_CONCURRENT_REVIEWS concurrent independent PR reviews.

First reconcile every task already recorded in this isolated home. Recover unfinished review work, use absolute report paths under $AUTOMATION_HOME/data, complete the skill's authorized publication-and-Slack notification sequence, record the direct GitHub comment and Slack message links, resolve any review publication holds from the host-job authorization, mark terminal task metadata accurately, and run guarded teardown for every completed task. Do not start discovery while stale completed metadata remains.

Then refresh Jira live with complete pagination, discover eligible open PR heads, and execute one idempotent sweep. Dispatch no more than $MAX_CONCURRENT_REVIEWS focused reviewers at once. Review only: do not edit project code, merge, push, mutate Jira, or publish anything other than the skill's authorized review comments, minimization of the configured reviewer's own superseded watermark comments, and exact PR-author Slack direct message.

After dispatch, supervise in the foreground until every task from this cycle is terminal. Reconcile reports and receipts, complete publication followed immediately by Slack notification, close task records, and run guarded teardown. Do not finish while this home's state contains task metadata. If coverage is partial or an author identity is ambiguous, record that plainly and leave no fabricated success. If no PR needs review, send no Slack message and finish as a verified no-op.

Return the skill's required review table plus totals for discovered, reviewed, skipped, failed, comments published, Slack messages sent, and tasks left in flight. The final in-flight total must be zero for a successful cycle.

Before finishing, atomically write this machine receipt to $AUTOMATION_HOME/state/review-sweep-cycle-receipts/$slot.json. Use version 1, slot "$slot", coverage "complete" only after full Jira and GitHub verification, nonnegative integer fields discovered/reviewed/skipped/comments_published/slack_messages_sent, integer failed 0, integer tasks_left_in_flight 0, and a reviews array with exactly one row per reviewed PR. Each row must contain pr, full head, direct comment_url, and slack. slack is either {"status":"sent","message_url":"<direct Slack message URL>"} or {"status":"skipped","reason":"<no unique author match reason>"}. comments_published must equal reviewed. slack_messages_sent must equal the number of sent rows. A no-op sweep uses zero counts and an empty reviews array. Do not write coverage complete when any required coverage, publication, notification decision, metadata reconciliation, or teardown is unresolved.
EOF
}

run_codex_cycle() { # <slot> <result-dir>
  local slot=$1 result_dir=$2 prompt_file result_file event_log receipt pid start_epoch now_epoch deadline rc=0 inflight
  mkdir -p "$result_dir"
  [ -d "$result_dir" ] && [ ! -L "$result_dir" ] || die 'result directory is unsafe'
  prompt_file="$result_dir/prompt.txt"
  result_file="$result_dir/result.txt"
  event_log="$result_dir/events.jsonl"
  receipt="$AUTOMATION_HOME/state/review-sweep-cycle-receipts/$slot.json"
  atomic_write "$prompt_file" 0600 "$(review_cycle_prompt "$slot")" || die 'failed to write cycle prompt'
  if [ -L "$event_log" ] || [ -L "$result_file" ] || [ -L "$receipt" ]; then
    die 'refusing symlinked review-cycle output path'
  fi
  rm -f -- "$result_file" "$receipt"
  : > "$event_log"
  chmod 0600 "$event_log"
  start_epoch=$(date +%s)
  deadline=$((start_epoch + MAX_RUNTIME_SECONDS))
  (
    export HOME
    export PATH="$RUNTIME_PATH"
    export FM_HOME="$AUTOMATION_HOME"
    export TZ="$TIMEZONE"
    if [ -n "$KNOWLEDGE_BASE_PATH" ]; then export KNOWLEDGE_BASE="$KNOWLEDGE_BASE_PATH"; fi
    exec "$CODEX_BIN" exec --ephemeral --json --color never --approve-for-me \
      -C "$AUTOMATION_HOME" -o "$result_file" "$(cat "$prompt_file")"
  ) > "$event_log" 2>&1 &
  pid=$!
  RUN_CHILD_PID=$pid
  atomic_write "$result_dir/runner.pid" 0600 "$pid" || true
  while kill -0 "$pid" 2>/dev/null; do
    now_epoch=$(date +%s)
    if [ "$now_epoch" -ge "$deadline" ]; then
      printf 'timeout: slot %s exceeded %s seconds; stopping pid %s\n' "$slot" "$MAX_RUNTIME_SECONDS" "$pid" >&2
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 5
  done
  if [ "$rc" -eq 0 ]; then wait "$pid" || rc=$?; else wait "$pid" 2>/dev/null || true; fi
  RUN_CHILD_PID=
  inflight=$(automation_inflight_count)
  atomic_write "$result_dir/inflight-count" 0600 "$inflight" || true
  if [ "$inflight" -ne 0 ]; then
    printf 'error: slot %s ended with %s task metadata record(s) still in flight\n' "$slot" "$inflight" >&2
    [ "$rc" -ne 0 ] || rc=73
  fi
  if [ "$rc" -eq 0 ]; then
    if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
      printf 'error: slot %s did not publish its cycle receipt at %s\n' "$slot" "$receipt" >&2
      rc=74
    elif ! jq -e --arg slot "$slot" '
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
        (.pr | type == "string" and test("^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$")) and
        (.head | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
        (.comment_url | type == "string" and test("^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+#issuecomment-[0-9]+$")) and
        (.slack.status == "sent" or .slack.status == "skipped") and
        (if .slack.status == "sent" then
           (.slack.message_url | type == "string" and test("^https://[^/]*slack[.]com/archives/"))
         else
           (.slack.reason | type == "string" and length > 0)
         end)) and
      $receipt.slack_messages_sent == ([$receipt.reviews[] | select(.slack.status == "sent")] | length)
    ' "$receipt" >/dev/null 2>&1; then
      printf 'error: slot %s published an invalid or incomplete cycle receipt\n' "$slot" >&2
      rc=75
    fi
  fi
  return "$rc"
}

handle_cycle_signal() {
  local signal=${1:-TERM}
  if safe_positive_integer "${RUN_CHILD_PID:-}" && kill -0 "$RUN_CHILD_PID" 2>/dev/null; then
    kill -TERM "$RUN_CHILD_PID" 2>/dev/null || true
  fi
  release_run_lock
  case $signal in HUP) exit 129 ;; INT) exit 130 ;; *) exit 143 ;; esac
}

run_slot() { # <slot> <epoch>
  local slot=$1 now_epoch=$2 slot_dir result_dir status retry_at attempt rc
  safe_single_line "$slot" || die 'slot id is invalid'
  case $slot in ''|*[!A-Za-z0-9._-]*) die 'slot id is invalid' ;; esac
  mkdir -p "$SLOTS_ROOT" "$RESULTS_ROOT"
  slot_dir="$SLOTS_ROOT/$slot"
  result_dir="$RESULTS_ROOT/$slot"
  mkdir -p "$slot_dir"
  [ -d "$slot_dir" ] && [ ! -L "$slot_dir" ] || die 'slot state directory is unsafe'
  status=$(slot_file_value "$slot_dir" status 2>/dev/null || true)
  if [ "$status" = succeeded ]; then
    printf 'noop: slot %s already succeeded\n' "$slot"
    return 0
  fi
  retry_at=$(slot_file_value "$slot_dir" retry-at 2>/dev/null || printf '0')
  safe_nonnegative_integer "$retry_at" || retry_at=0
  if [ "$status" = failed ] && [ "$now_epoch" -lt "$retry_at" ]; then
    printf 'deferred: slot %s retry is due at epoch %s\n' "$slot" "$retry_at"
    return 0
  fi
  attempt=$(slot_file_value "$slot_dir" attempt 2>/dev/null || printf '0')
  safe_nonnegative_integer "$attempt" || attempt=0
  attempt=$((attempt + 1))
  slot_set "$slot_dir" attempt "$attempt"
  slot_set "$slot_dir" started-at "$now_epoch"
  slot_set "$slot_dir" owner-pid "$$"
  slot_set "$slot_dir" status running
  printf 'start: slot=%s attempt=%s max-concurrent-reviews=%s\n' "$slot" "$attempt" "$MAX_CONCURRENT_REVIEWS"
  if run_codex_cycle "$slot" "$result_dir"; then
    slot_set "$slot_dir" completed-at "$(date +%s)"
    slot_set "$slot_dir" status succeeded
    atomic_write "$STATE_ROOT/last-succeeded-slot" 0600 "$slot" || true
    printf 'complete: slot=%s status=succeeded\n' "$slot"
    return 0
  else
    rc=$?
    slot_set "$slot_dir" exit-code "$rc"
    slot_set "$slot_dir" completed-at "$(date +%s)"
    slot_set "$slot_dir" retry-at "$((now_epoch + RETRY_SECONDS))"
    slot_set "$slot_dir" status failed
    printf 'complete: slot=%s status=failed exit=%s retry-after=%s\n' "$slot" "$rc" "$RETRY_SECONDS" >&2
    return "$rc"
  fi
}

prepare_cycle_home() {
  ensure_automation_home
  sync_automation_code
  sync_private_context
  sync_projects
  write_host_contract
}

tick() {
  local fields day hour minute epoch offset slot rc=0
  load_config
  [ "$ENABLED" = 1 ] || { printf 'disabled: review-sweep supervisor\n'; return 0; }
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  slot=$(slot_at "$day" "$hour" "$minute" 2>/dev/null || true)
  [ -n "$slot" ] || { printf 'noop: no review-sweep slot is due\n'; return 0; }
  acquire_run_lock || return 0
  trap release_run_lock EXIT
  trap 'handle_cycle_signal HUP' HUP
  trap 'handle_cycle_signal INT' INT
  trap 'handle_cycle_signal TERM' TERM
  prepare_cycle_home
  run_slot "$slot" "$epoch" || rc=$?
  release_run_lock
  trap - EXIT HUP INT TERM
  return "$rc"
}

run_now() {
  local fields day hour minute epoch offset slot rc=0
  load_config
  [ "$ENABLED" = 1 ] || die 'review-sweep supervisor is disabled'
  read -r day hour minute epoch offset <<EOF
$(read_clock_fields)
EOF
  slot="manual-$day-$hour$minute-$epoch"
  acquire_run_lock || return 0
  trap release_run_lock EXIT
  trap 'handle_cycle_signal HUP' HUP
  trap 'handle_cycle_signal INT' INT
  trap 'handle_cycle_signal TERM' TERM
  prepare_cycle_home
  run_slot "$slot" "$epoch" || rc=$?
  release_run_lock
  trap - EXIT HUP INT TERM
  return "$rc"
}

install_supervisor() {
  local source= changed=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --source-home) [ "$#" -ge 2 ] || usage; source=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$source" ] || usage
  if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then
    load_config
    [ "$SOURCE_HOME" = "$source" ] || die "existing config belongs to source_home $SOURCE_HOME"
  else
    write_config "$source"
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
  printf 'automation-home: %s\n' "$AUTOMATION_HOME"
  printf 'config: %s\n' "$CONFIG_PATH"
}

status_supervisor() {
  local loaded=no lock=idle owner= latest=none slot_status=unknown
  if [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ]; then
    load_config
  else
    printf 'installed: no\nconfig: %s\n' "$CONFIG_PATH"
    return 1
  fi
  launchagent_loaded && loaded=yes
  if [ -f "$LOCK_DIR/owner" ] && [ ! -L "$LOCK_DIR/owner" ]; then
    owner=$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)
    if process_is_live_owner "$owner"; then lock="running pid=$owner"; else lock="stale pid=${owner:-unknown}"; fi
  fi
  if [ -f "$STATE_ROOT/last-succeeded-slot" ] && [ ! -L "$STATE_ROOT/last-succeeded-slot" ]; then
    latest=$(sed -n '1p' "$STATE_ROOT/last-succeeded-slot")
    slot_status=$(slot_file_value "$SLOTS_ROOT/$latest" status 2>/dev/null || printf unknown)
  fi
  printf 'installed: yes\n'
  printf 'enabled: %s\n' "$ENABLED"
  printf 'launchagent-loaded: %s\n' "$loaded"
  printf 'schedule: %02d:00-%02d:00 %s every %s minutes, final slot %02d:00\n' \
    "$START_HOUR" "$END_HOUR" "$TIMEZONE" "$INTERVAL_MINUTES" "$END_HOUR"
  printf 'max-concurrent-reviews: %s\n' "$MAX_CONCURRENT_REVIEWS"
  printf 'cycle: %s\n' "$lock"
  printf 'last-succeeded-slot: %s\n' "$latest"
  printf 'last-slot-status: %s\n' "$slot_status"
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
