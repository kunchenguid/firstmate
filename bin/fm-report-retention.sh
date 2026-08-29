#!/usr/bin/env bash
# Keep machine-global completion reports visible and undeleted for at least 30 days.
# Usage: fm-report-retention.sh ensure
#        fm-report-retention.sh install
#        fm-report-retention.sh run-once
#
# Installation publishes immutable, self-contained generations, then atomically
# replaces the LaunchAgent plist that points at one complete generation.
# The previously runnable generation remains in place until the replacement has
# completed a successful prune and heartbeat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACK_ROOT="${FM_REPORT_STACK_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/report-stack}"
INTERVAL=${FM_REPORT_RETENTION_INTERVAL:-300}
PROGRESS_INTERVAL=${FM_REPORT_RETENTION_PROGRESS_INTERVAL:-1}
COHORT_MS=${FM_REPORT_RETENTION_COHORT_MS:-300000}
ACTIVATION_WAIT_MS=${FM_REPORT_RETENTION_ACTIVATION_WAIT_MS:-}
LABEL=${FM_REPORT_RETENTION_LABEL:-com.firstmate.report-retention}
PLATFORM=${FM_REPORT_RETENTION_PLATFORM:-$(uname)}
INSTALL_ROOT=${FM_REPORT_RETENTION_INSTALL_ROOT:-$HOME/Library/Application Support/Firstmate/report-retention}
GENERATIONS="$INSTALL_ROOT/generations"
LAUNCH_AGENTS_DIR=${FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LAUNCHCTL=${FM_REPORT_RETENTION_LAUNCHCTL:-launchctl}
HEARTBEAT="$STACK_ROOT/.retention-heartbeat"
ERROR_FILE="$STACK_ROOT/.retention-error"
INSTALL_LOCK="$INSTALL_ROOT/.install-lock"
INSTALL_RECLAIM="$INSTALL_ROOT/.install-lock-reclaim"
CANDIDATE_FENCE="$INSTALL_ROOT/.candidate-fence"
OWNER_HANDOFF_FENCE="$INSTALL_ROOT/.owner-handoff-fence"
INSTALL_LOCK_TOKEN=
SOURCE_FILES=(fm-report-retention.sh fm-report-stack.mjs fm-markdown-structure.cjs fm-contained-read.py)

case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$COHORT_MS" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_COHORT_MS must be a positive integer" >&2; exit 2 ;; esac
[ -n "$ACTIVATION_WAIT_MS" ] || ACTIVATION_WAIT_MS=$((INTERVAL * 2000 + 60000))
case "$ACTIVATION_WAIT_MS" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_ACTIVATION_WAIT_MS must be a positive integer" >&2; exit 2 ;; esac
[ "$INTERVAL" -lt 1296000 ] || { echo "error: FM_REPORT_RETENTION_INTERVAL must be below 15 days" >&2; exit 2; }
[ "$PROGRESS_INTERVAL" -le "$INTERVAL" ] || { echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must not exceed the owner interval" >&2; exit 2; }

provenance() {
  local directory=$1 file
  for file in "${SOURCE_FILES[@]}"; do
    [ -f "$directory/$file" ] && [ ! -L "$directory/$file" ] || return 1
  done
  for file in "${SOURCE_FILES[@]}"; do shasum -a 256 "$directory/$file"; done \
    | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

resolve_runtime() {
  local configured=$1 name=$2 resolved
  if [ -n "$configured" ]; then resolved=$configured; else resolved=$(command -v "$name" 2>/dev/null) || return 1; fi
  case "$resolved" in /*) ;; *) return 1 ;; esac
  [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

publish_error() {
  local output=$1 temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-error.XXXXXX") || return 1
  printf '%s\n' "$output" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  if [ -e "$ERROR_FILE" ] || [ -L "$ERROR_FILE" ]; then
    [ -f "$ERROR_FILE" ] && [ ! -L "$ERROR_FILE" ] \
      || { rm -f "$temp"; echo "error: unsafe report-retention error control file" >&2; return 1; }
  fi
  mv -f "$temp" "$ERROR_FILE"
}

write_heartbeat() {
  local provenance_value=$1 activation_nonce=${FM_REPORT_RETENTION_ACTIVATION_NONCE:-} run_identity temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-heartbeat.XXXXXX") || return 1
  run_identity="$$.$RANDOM.$(date +%s)"
  printf '%s\n%s\n%s\n%s\n' "$(date +%s)" "$provenance_value" "$activation_nonce" "$run_identity" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$HEARTBEAT"
}

heartbeat_matches() {
  local expected=$1 expected_nonce=${2:-} previous_run=${3:-} epoch recorded nonce run_identity now
  [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || return 1
  epoch=$(sed -n '1p' "$HEARTBEAT")
  recorded=$(sed -n '2p' "$HEARTBEAT")
  nonce=$(sed -n '3p' "$HEARTBEAT")
  run_identity=$(sed -n '4p' "$HEARTBEAT")
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recorded" = "$expected" ] || return 1
  [ "$nonce" = "$expected_nonce" ] || return 1
  [ -n "$run_identity" ] && { [ -z "$previous_run" ] || [ "$run_identity" != "$previous_run" ]; } || return 1
  now=$(date +%s)
  [ "$((now - epoch))" -le "$((INTERVAL * 2 + 60))" ]
}

restore_prior_heartbeat() {
  local backup=$1 had_previous=$2 candidate_provenance=$3 candidate_nonce=$4
  local current_id backup_id python_runtime quarantine
  [ -e "$backup" ] || [ "$had_previous" = 0 ] || return 1
  if [ ! -f "$HEARTBEAT" ] || [ -L "$HEARTBEAT" ] \
    || [ "$(sed -n '2p' "$HEARTBEAT")" != "$candidate_provenance" ] \
    || { [ "$(sed -n '3p' "$HEARTBEAT")" != "$candidate_nonce" ] && [ -n "$(sed -n '3p' "$HEARTBEAT")" ]; }; then
    rm -f "$backup"
    return 0
  fi
  current_id=$(file_identity "$HEARTBEAT") || return 1
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) || return 1
  if [ "$had_previous" = 1 ]; then
    backup_id=$(file_identity "$backup") || return 1
    "$python_runtime" "$SCRIPT_DIR/fm-contained-read.py" exchange-files-fd \
      "$(basename "$backup")" "$(basename "$HEARTBEAT")" "$backup_id" "$current_id" 3< "$STACK_ROOT" \
      || return 1
    quarantine=".$(basename "$backup").discarded.$INSTALL_LOCK_TOKEN"
    "$python_runtime" "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
      "$(basename "$backup")" "$current_id" "$quarantine" 3< "$STACK_ROOT"
  else
    quarantine=".$(basename "$HEARTBEAT").discarded.$INSTALL_LOCK_TOKEN"
    "$python_runtime" "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
      "$(basename "$HEARTBEAT")" "$current_id" "$quarantine" 3< "$STACK_ROOT"
  fi
}

candidate_bootout_confirmed() {
  local domain=$1 job_label=$2
  "$LAUNCHCTL" bootout "$domain/$job_label" >/dev/null 2>&1 && return 0
  ! "$LAUNCHCTL" print "$domain/$job_label" >/dev/null 2>&1
}

retain_candidate_fence() {
  local domain=$1 job_label=$2 generation=$3 candidate_provenance=$4 candidate_nonce=$5
  local heartbeat_backup=$6 heartbeat_had_previous=$7 temp
  temp=$(mktemp "$INSTALL_ROOT/.candidate-fence.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$domain" "$job_label" "$generation" \
    "$candidate_provenance" "$candidate_nonce" "$heartbeat_backup" "$heartbeat_had_previous" > "$temp" \
    || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$CANDIDATE_FENCE"
}

recover_candidate_fence() {
  local domain job_label generation candidate_provenance candidate_nonce heartbeat_backup heartbeat_had_previous extra canonical_label canonical_program
  [ -e "$CANDIDATE_FENCE" ] || [ -L "$CANDIDATE_FENCE" ] || return 0
  [ -f "$CANDIDATE_FENCE" ] && [ ! -L "$CANDIDATE_FENCE" ] || return 1
  domain=$(sed -n '1p' "$CANDIDATE_FENCE")
  job_label=$(sed -n '2p' "$CANDIDATE_FENCE")
  generation=$(sed -n '3p' "$CANDIDATE_FENCE")
  candidate_provenance=$(sed -n '4p' "$CANDIDATE_FENCE")
  candidate_nonce=$(sed -n '5p' "$CANDIDATE_FENCE")
  heartbeat_backup=$(sed -n '6p' "$CANDIDATE_FENCE")
  heartbeat_had_previous=$(sed -n '7p' "$CANDIDATE_FENCE")
  extra=$(sed -n '8p' "$CANDIDATE_FENCE")
  case "$domain" in gui/*) ;; *) return 1 ;; esac
  case "$job_label" in "$LABEL".*) ;; *) return 1 ;; esac
  case "$generation" in "$GENERATIONS"/*) ;; *) return 1 ;; esac
  case "$heartbeat_backup" in "$STACK_ROOT"/.retention-heartbeat.previous.*) ;; *) return 1 ;; esac
  [ -d "$generation" ] && [ ! -L "$generation" ] && [ -n "$candidate_provenance" ] \
    && [ -n "$candidate_nonce" ] && [ -z "$extra" ] \
    && { [ "$heartbeat_had_previous" = 0 ] || [ "$heartbeat_had_previous" = 1 ]; } || return 1
  if [ -f "$PLIST" ] && [ ! -L "$PLIST" ]; then
    canonical_label=$(plist_label "$PLIST")
    canonical_program=$(plist_program "$PLIST")
    if [ "$canonical_label" = "$job_label" ] \
      && [ "$canonical_program" = "$generation/bin/fm-report-retention.sh" ]; then
      heartbeat_matches "$candidate_provenance" "$candidate_nonce" || return 1
      rm -f "$heartbeat_backup" "$CANDIDATE_FENCE"
      return 0
    fi
  fi
  candidate_bootout_confirmed "$domain" "$job_label" || return 1
  restore_prior_heartbeat "$heartbeat_backup" "$heartbeat_had_previous" "$candidate_provenance" "$candidate_nonce" || return 1
  rm -rf "$generation"
  rm -f "$CANDIDATE_FENCE"
}

retain_owner_handoff_fence() {
  local domain=$1 old_label=$2 old_generation=$3 new_label=$4 candidate_provenance=$5
  local candidate_nonce=$6 heartbeat_backup=$7 heartbeat_had_previous=$8 temp
  temp=$(mktemp "$INSTALL_ROOT/.owner-handoff-fence.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$domain" "$old_label" "$old_generation" "$new_label" \
    "$candidate_provenance" "$candidate_nonce" "$heartbeat_backup" "$heartbeat_had_previous" > "$temp" \
    || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$OWNER_HANDOFF_FENCE"
}

recover_owner_handoff_fence() {
  local domain old_label old_generation new_label candidate_provenance candidate_nonce
  local heartbeat_backup heartbeat_had_previous extra canonical_label current_program
  [ -e "$OWNER_HANDOFF_FENCE" ] || [ -L "$OWNER_HANDOFF_FENCE" ] || return 0
  [ -f "$OWNER_HANDOFF_FENCE" ] && [ ! -L "$OWNER_HANDOFF_FENCE" ] || return 1
  domain=$(sed -n '1p' "$OWNER_HANDOFF_FENCE")
  old_label=$(sed -n '2p' "$OWNER_HANDOFF_FENCE")
  old_generation=$(sed -n '3p' "$OWNER_HANDOFF_FENCE")
  new_label=$(sed -n '4p' "$OWNER_HANDOFF_FENCE")
  candidate_provenance=$(sed -n '5p' "$OWNER_HANDOFF_FENCE")
  candidate_nonce=$(sed -n '6p' "$OWNER_HANDOFF_FENCE")
  heartbeat_backup=$(sed -n '7p' "$OWNER_HANDOFF_FENCE")
  heartbeat_had_previous=$(sed -n '8p' "$OWNER_HANDOFF_FENCE")
  extra=$(sed -n '9p' "$OWNER_HANDOFF_FENCE")
  case "$domain" in gui/*) ;; *) return 1 ;; esac
  case "$old_label" in "$LABEL".*) ;; *) return 1 ;; esac
  case "$new_label" in "$LABEL".*) ;; *) return 1 ;; esac
  case "$old_generation" in -|"$GENERATIONS"/*) ;; *) return 1 ;; esac
  case "$heartbeat_backup" in "$STACK_ROOT"/.retention-heartbeat.previous.*) ;; *) return 1 ;; esac
  [ -n "$candidate_provenance" ] && [ -n "$candidate_nonce" ] && [ -z "$extra" ] \
    && { [ "$heartbeat_had_previous" = 0 ] || [ "$heartbeat_had_previous" = 1 ]; } || return 1
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] || return 1
  canonical_label=$(plist_label "$PLIST")
  if [ "$canonical_label" = "$old_label" ]; then
    candidate_bootout_confirmed "$domain" "$new_label" || return 1
    restore_prior_heartbeat "$heartbeat_backup" "$heartbeat_had_previous" \
      "$candidate_provenance" "$candidate_nonce" || return 1
    rm -f "$OWNER_HANDOFF_FENCE"
    return 0
  fi
  [ "$canonical_label" = "$new_label" ] || return 1
  candidate_bootout_confirmed "$domain" "$old_label" || return 1
  current_program=$(plist_program "$PLIST")
  if [ "$old_generation" != - ] && [ "$current_program" != "$old_generation/bin/fm-report-retention.sh" ]; then
    rm -rf "$old_generation"
  fi
  rm -f "$OWNER_HANDOFF_FENCE"
}

control_state() {
  local control=$1 pid started token extra current
  [ -f "$control" ] && [ ! -L "$control" ] || { printf 'unknown'; return; }
  pid=$(sed -n '1p' "$control"); started=$(sed -n '2p' "$control")
  token=$(sed -n '3p' "$control"); extra=$(sed -n '4p' "$control")
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  [ -n "$started" ] && [ -n "$token" ] && [ -z "$extra" ] || { printf 'unknown'; return; }
  if ! kill -0 "$pid" 2>/dev/null; then printf 'stale'; return; fi
  current=$(process_start_time "$pid") || { printf 'unknown'; return; }
  if [ "$current" = "$started" ]; then printf 'live'; else printf 'stale'; fi
}

file_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

remove_owned_install_file() {
  local file=$1 identity=$2 quarantine=$3 python_runtime
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) || return 1
  "$python_runtime" "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
    "$(basename "$file")" "$identity" "$quarantine" 3< "$INSTALL_ROOT"
}

remove_owned_launch_file() {
  local file=$1 identity=$2 quarantine=$3 python_runtime
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) || return 1
  "$python_runtime" "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
    "$(basename "$file")" "$identity" "$quarantine" 3< "$LAUNCH_AGENTS_DIR"
}

process_start_time() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

install_lock_state() {
  control_state "$INSTALL_LOCK"
}

install_reclaim_acquire() {
  local candidate started state quarantine expected observed
  started=$(process_start_time "$$") || return 1
  candidate=$(mktemp "$INSTALL_ROOT/.install-lock-reclaim.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$$" "$started" "$INSTALL_LOCK_TOKEN" > "$candidate" || { rm -f "$candidate"; return 1; }
  while :; do
    if ln "$candidate" "$INSTALL_RECLAIM" 2>/dev/null; then
      rm -f "$candidate"
      return 0
    fi
    observed=$(file_identity "$INSTALL_RECLAIM") || { rm -f "$candidate"; return 1; }
    state=$(control_state "$INSTALL_RECLAIM")
    [ "$state" = stale ] || { rm -f "$candidate"; return 1; }
    expected=$(sed -n '3p' "$INSTALL_RECLAIM")
    [ -n "$expected" ] && [ "$(file_identity "$INSTALL_RECLAIM")" = "$observed" ] \
      || { rm -f "$candidate"; return 1; }
    quarantine=".install-lock-reclaim.stale.$INSTALL_LOCK_TOKEN"
    remove_owned_install_file "$INSTALL_RECLAIM" "$observed" "$quarantine" || continue
  done
}

install_reclaim_recover() {
  local state quarantine expected observed
  [ -e "$INSTALL_RECLAIM" ] || [ -L "$INSTALL_RECLAIM" ] || return 0
  observed=$(file_identity "$INSTALL_RECLAIM") || return 1
  state=$(control_state "$INSTALL_RECLAIM")
  [ "$state" = stale ] || return 1
  expected=$(sed -n '3p' "$INSTALL_RECLAIM")
  [ -n "$expected" ] && [ "$(file_identity "$INSTALL_RECLAIM")" = "$observed" ] || return 1
  quarantine=".install-lock-reclaim.stale.$INSTALL_LOCK_TOKEN"
  remove_owned_install_file "$INSTALL_RECLAIM" "$observed" "$quarantine"
}

install_reclaim_release() {
  [ -f "$INSTALL_RECLAIM" ] && [ ! -L "$INSTALL_RECLAIM" ] || return 0
  [ "$(sed -n '3p' "$INSTALL_RECLAIM")" = "$INSTALL_LOCK_TOKEN" ] || return 0
  rm -f "$INSTALL_RECLAIM"
}

install_lock_acquire() {
  local candidate started state quarantine
  mkdir -p "$INSTALL_ROOT" || return 1
  INSTALL_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
  started=$(process_start_time "$$") || return 1
  candidate=$(mktemp "$INSTALL_ROOT/.install-lock.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$$" "$started" "$INSTALL_LOCK_TOKEN" > "$candidate" || return 1
  for _attempt in $(seq 1 100); do
    install_reclaim_recover >/dev/null 2>&1 || true
    if [ ! -e "$INSTALL_RECLAIM" ] && ln "$candidate" "$INSTALL_LOCK" 2>/dev/null; then
      rm -f "$candidate"
      return 0
    fi
    state=$(install_lock_state)
    if [ "$state" = stale ] && install_reclaim_acquire; then
      state=$(install_lock_state)
      if [ "$state" = stale ]; then
        quarantine="$INSTALL_LOCK.stale.$INSTALL_LOCK_TOKEN"
        mv "$INSTALL_LOCK" "$quarantine" 2>/dev/null || true
        rm -f "$quarantine"
      fi
      install_reclaim_release
      [ "$state" != stale ] || continue
    fi
    sleep 0.05
  done
  rm -f "$candidate"
  echo "error: report-retention installation is already in progress" >&2
  return 1
}

install_lock_release() {
  [ -f "$INSTALL_LOCK" ] && [ ! -L "$INSTALL_LOCK" ] || return 0
  [ "$(sed -n '3p' "$INSTALL_LOCK")" = "$INSTALL_LOCK_TOKEN" ] || return 0
  rm -f "$INSTALL_LOCK"
}

run_once() {
  local output pending provenance_value node_runtime
  provenance_value=$(provenance "$SCRIPT_DIR") || { echo "error: retention owner bundle is incomplete" >&2; return 1; }
  node_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_NODE:-}" node) \
    || { echo "error: report-retention Node runtime is unavailable" >&2; return 1; }
  while :; do
    if output=$("$node_runtime" "$SCRIPT_DIR/fm-report-stack.mjs" prune --status 2>&1); then
      rm -f "$ERROR_FILE"
      write_heartbeat "$provenance_value" || return 1
      case "$output" in *'"pending":true'*) pending=1 ;; *) pending=0 ;; esac
    else
      publish_error "$output" || return 1
      return 1
    fi
    [ "$pending" -eq 1 ] || return 0
    sleep "$PROGRESS_INTERVAL"
  done
}

plist_program() {
  sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$1" | sed -n '2p'
}

plist_label() {
  sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$1" | sed -n '1p'
}

plist_environment_value() {
  local file=$1 key=$2
  sed -n "s#.*<key>$key</key><string>\\([^<]*\\)</string>.*#\\1#p" "$file" | sed -n '1p'
}

write_generation_plist() {
  local destination=$1 bash_runtime=$2 node_runtime=$3 python_runtime=$4 generation=$5 job_label=$6 activation_nonce=$7 runtime_path
  runtime_path="$(dirname "$node_runtime"):$(dirname "$python_runtime"):/usr/bin:/bin:/usr/sbin:/sbin"
  cat > "$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml_escape "$job_label")</string>
<key>ProgramArguments</key><array>
<string>$(xml_escape "$bash_runtime")</string>
<string>$(xml_escape "$generation/bin/fm-report-retention.sh")</string>
<string>run-once</string>
</array>
<key>EnvironmentVariables</key><dict>
<key>PATH</key><string>$(xml_escape "$runtime_path")</string>
<key>FM_REPORT_RETENTION_NODE</key><string>$(xml_escape "$node_runtime")</string>
<key>FM_REPORT_PYTHON</key><string>$(xml_escape "$python_runtime")</string>
<key>FM_REPORT_STACK_ROOT</key><string>$(xml_escape "$STACK_ROOT")</string>
<key>FM_REPORT_RETENTION_INTERVAL</key><string>$(xml_escape "$INTERVAL")</string>
<key>FM_REPORT_RETENTION_COHORT_MS</key><string>$(xml_escape "$COHORT_MS")</string>
<key>FM_REPORT_RETENTION_PROGRESS_INTERVAL</key><string>$(xml_escape "$PROGRESS_INTERVAL")</string>
<key>FM_REPORT_RETENTION_ACTIVATION_NONCE</key><string>$(xml_escape "$activation_nonce")</string>
</dict>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>$INTERVAL</integer>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
}

install_test_interrupt() {
  [ "${FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT:-}" != "$1" ] || return 99
}

install_owner() {
  local token staging generation generation_plist plist_temp previous_plist domain file heartbeat_backup
  local bash_runtime node_runtime python_runtime source_provenance installed_provenance old_program='' old_label='' old_generation=''
  local job_label activation_nonce activation_started=0 activation_baseline='' activation_attempts heartbeat_had_previous=0
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent installation requires macOS" >&2; return 1; }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  mkdir -p "$GENERATIONS" "$LAUNCH_AGENTS_DIR" || return 1
  [ -d "$GENERATIONS" ] && [ ! -L "$GENERATIONS" ] && [ -d "$LAUNCH_AGENTS_DIR" ] && [ ! -L "$LAUNCH_AGENTS_DIR" ] \
    || { echo "error: unsafe report-retention installation directories" >&2; return 1; }
  bash_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_BASH:-}" bash) || return 1
  node_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_NODE:-}" node) || return 1
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) || return 1
  token="$(date +%s).$$.$RANDOM"
  job_label="$LABEL.$token"
  activation_nonce="$token.$RANDOM"
  staging=$(mktemp -d "$GENERATIONS/.staging.$token.XXXXXX") || return 1
  generation="$GENERATIONS/$token"
  generation_plist="$staging/$LABEL.plist"
  plist_temp=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.XXXXXX") || { rm -rf "$staging"; return 1; }
  previous_plist=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.previous.XXXXXX") || { rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  rm -f "$previous_plist"
  mkdir "$staging/bin" || return 1
  for file in "${SOURCE_FILES[@]}"; do cp "$SCRIPT_DIR/$file" "$staging/bin/$file" || return 1; done
  chmod 700 "$staging/bin/fm-report-retention.sh" "$staging/bin/fm-report-stack.mjs" "$staging/bin/fm-contained-read.py" || return 1
  source_provenance=$(provenance "$SCRIPT_DIR") || return 1
  installed_provenance=$(provenance "$staging/bin") || return 1
  [ "$source_provenance" = "$installed_provenance" ] || return 1
  write_generation_plist "$generation_plist" "$bash_runtime" "$node_runtime" "$python_runtime" "$generation" "$job_label" "$activation_nonce" || return 1
  chmod 600 "$generation_plist" || return 1
  cp "$generation_plist" "$plist_temp" || return 1
  chmod 600 "$plist_temp" || return 1
  mv "$staging" "$generation" || return 1
  generation_plist="$generation/$LABEL.plist"
  install_test_interrupt generation-published || return $?
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    [ -f "$PLIST" ] && [ ! -L "$PLIST" ] || { rm -f "$plist_temp" "$previous_plist"; rm -rf "$generation"; echo "error: unsafe installed report-retention plist" >&2; return 1; }
    cp -p "$PLIST" "$previous_plist" || { rm -f "$plist_temp" "$previous_plist"; rm -rf "$generation"; return 1; }
    old_program=$(plist_program "$previous_plist")
    old_label=$(plist_label "$previous_plist")
    case "$old_program" in "$GENERATIONS"/*/bin/fm-report-retention.sh) old_generation=${old_program%/bin/fm-report-retention.sh} ;; esac
  fi
  mkdir -p "$STACK_ROOT" || return 1
  heartbeat_backup=$(mktemp "$STACK_ROOT/.retention-heartbeat.previous.XXXXXX") || return 1
  rm -f "$heartbeat_backup"
  if [ -e "$HEARTBEAT" ] || [ -L "$HEARTBEAT" ]; then
    [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || return 1
    cp -p "$HEARTBEAT" "$heartbeat_backup" || return 1
    heartbeat_had_previous=1
  fi
  if ! FM_REPORT_RETENTION_NODE="$node_runtime" FM_REPORT_PYTHON="$python_runtime" \
    FM_REPORT_RETENTION_ACTIVATION_NONCE='' \
    "$bash_runtime" "$generation/bin/fm-report-retention.sh" run-once \
    || ! heartbeat_matches "$installed_provenance" ""; then
    restore_prior_heartbeat "$heartbeat_backup" "$heartbeat_had_previous" "$installed_provenance" "$activation_nonce" || true
    rm -f "$plist_temp" "$previous_plist" "$heartbeat_backup"
    rm -rf "$generation"
    echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
    return 1
  fi
  domain="gui/$(id -u)"
  if [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ]; then activation_baseline=$(sed -n '4p' "$HEARTBEAT"); fi
  retain_candidate_fence "$domain" "$job_label" "$generation" "$installed_provenance" \
    "$activation_nonce" "$heartbeat_backup" "$heartbeat_had_previous" \
    || { rm -f "$plist_temp" "$previous_plist"; return 1; }
  install_test_interrupt candidate-fenced || return $?
  if "$LAUNCHCTL" bootstrap "$domain" "$generation_plist"; then
    if [ "${FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_BOOTSTRAP:-}" = 1 ]; then
      FM_REPORT_RETENTION_NODE="$node_runtime" FM_REPORT_PYTHON="$python_runtime" \
        FM_REPORT_RETENTION_ACTIVATION_NONCE="$activation_nonce" \
        "$bash_runtime" "$generation/bin/fm-report-retention.sh" run-once || true
    fi
    if FM_REPORT_RETENTION_EXPECTED_NONCE="$activation_nonce" \
      FM_REPORT_RETENTION_EXPECTED_PROVENANCE="$installed_provenance" \
      "$LAUNCHCTL" kickstart "$domain/$job_label"; then
      activation_started=1
      if [ "${FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH:-}" = 1 ]; then
        FM_REPORT_RETENTION_NODE="$node_runtime" FM_REPORT_PYTHON="$python_runtime" \
          FM_REPORT_RETENTION_ACTIVATION_NONCE="$activation_nonce" \
          "$bash_runtime" "$generation/bin/fm-report-retention.sh" run-once || true
      fi
    fi
  fi
  if [ "$activation_started" -eq 1 ]; then
    activation_attempts=$(((ACTIVATION_WAIT_MS + 49) / 50))
    for _attempt in $(seq 1 "$activation_attempts"); do
      heartbeat_matches "$installed_provenance" "$activation_nonce" "$activation_baseline" && break
      sleep 0.05
    done
  fi
  if [ "$activation_started" -eq 1 ] && heartbeat_matches "$installed_provenance" "$activation_nonce" "$activation_baseline"; then
    if [ -n "$old_label" ] && [ "$old_label" != "$job_label" ]; then
      retain_owner_handoff_fence "$domain" "$old_label" "${old_generation:--}" "$job_label" \
        "$installed_provenance" "$activation_nonce" "$heartbeat_backup" "$heartbeat_had_previous" \
        || { rm -f "$plist_temp" "$previous_plist"; return 1; }
      rm -f "$CANDIDATE_FENCE" || { rm -f "$plist_temp" "$previous_plist"; return 1; }
      install_test_interrupt owner-handoff-prepointer || return $?
    fi
    if [ "${FM_REPORT_RETENTION_INSTALL_TEST_FAIL_POINTER:-}" = 1 ] || ! mv -f "$plist_temp" "$PLIST"; then
      rm -f "$OWNER_HANDOFF_FENCE"
      if candidate_bootout_confirmed "$domain" "$job_label"; then
        rm -f "$CANDIDATE_FENCE"
        restore_prior_heartbeat "$heartbeat_backup" "$heartbeat_had_previous" "$installed_provenance" "$activation_nonce" || true
        rm -f "$heartbeat_backup"
        rm -rf "$generation"
        echo "error: report-retention LaunchAgent pointer publication failed; previous generation preserved" >&2
      else
        retain_candidate_fence "$domain" "$job_label" "$generation" "$installed_provenance" \
          "$activation_nonce" "$heartbeat_backup" "$heartbeat_had_previous" || true
        echo "error: report-retention LaunchAgent pointer publication failed and candidate fencing is pending" >&2
      fi
      rm -f "$plist_temp" "$previous_plist"
      return 1
    fi
    install_test_interrupt pointer-published || return $?
    if [ -n "$old_label" ] && [ "$old_label" != "$job_label" ]; then
      if ! recover_owner_handoff_fence; then
        rm -f "$previous_plist"
        echo "error: report-retention previous owner fencing is pending" >&2
        return 1
      fi
    fi
    rm -f "$CANDIDATE_FENCE" "$heartbeat_backup"
    rm -f "$previous_plist"
    for file in "$GENERATIONS"/*; do
      [ -d "$file" ] || continue
      [ "$file" = "$generation" ] || [ "$file/bin/fm-report-retention.sh" = "$old_program" ] || rm -rf "$file"
    done
    return 0
  fi
  if candidate_bootout_confirmed "$domain" "$job_label"; then
    rm -f "$CANDIDATE_FENCE"
    restore_prior_heartbeat "$heartbeat_backup" "$heartbeat_had_previous" "$installed_provenance" "$activation_nonce" || true
    rm -f "$heartbeat_backup"
    rm -rf "$generation"
  else
    retain_candidate_fence "$domain" "$job_label" "$generation" "$installed_provenance" \
      "$activation_nonce" "$heartbeat_backup" "$heartbeat_had_previous" || true
  fi
  rm -f "$plist_temp" "$previous_plist"
  echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
  return 1
}

ensure_owner() {
  local program installed_provenance source_provenance domain job_label activation_nonce
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent requires macOS" >&2; return 1; }
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "error: report-retention LaunchAgent is not installed; run bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  program=$(plist_program "$PLIST")
  case "$program" in "$GENERATIONS"/*/bin/fm-report-retention.sh) ;; *) echo "error: report-retention LaunchAgent provenance is invalid" >&2; return 1 ;; esac
  [ -x "$program" ] && [ -f "$program" ] && [ ! -L "$program" ] || return 1
  installed_provenance=$(provenance "$(dirname "$program")") || return 1
  source_provenance=$(provenance "$SCRIPT_DIR") || return 1
  [ "$installed_provenance" = "$source_provenance" ] \
    || { echo "error: installed report-retention owner is stale; rerun bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  domain="gui/$(id -u)"
  job_label=$(plist_label "$PLIST")
  activation_nonce=$(plist_environment_value "$PLIST" FM_REPORT_RETENTION_ACTIVATION_NONCE)
  [ -n "$job_label" ] && [ -n "$activation_nonce" ] || { echo "error: report-retention LaunchAgent activation identity is invalid" >&2; return 1; }
  "$LAUNCHCTL" print "$domain/$job_label" >/dev/null 2>&1 || { echo "error: report-retention LaunchAgent is not loaded" >&2; return 1; }
  heartbeat_matches "$installed_provenance" "$activation_nonce" || { echo "error: report-retention successful-prune heartbeat is stale" >&2; return 1; }
}

run_with_install_lock() {
  local operation=$1 status
  install_lock_acquire || return 1
  trap 'install_lock_release >/dev/null 2>&1 || true' EXIT
  recover_owner_handoff_fence || { echo "error: report-retention previous owner fencing is still pending" >&2; install_lock_release; trap - EXIT; return 1; }
  recover_candidate_fence || { echo "error: report-retention candidate fencing is still pending" >&2; install_lock_release; trap - EXIT; return 1; }
  "$operation"; status=$?
  install_lock_release
  trap - EXIT
  return "$status"
}

case "${1:-}" in
  ensure) run_with_install_lock ensure_owner ;;
  install) run_with_install_lock install_owner ;;
  run-once) run_once ;;
  *) echo "usage: fm-report-retention.sh ensure|install|run-once" >&2; exit 2 ;;
esac
