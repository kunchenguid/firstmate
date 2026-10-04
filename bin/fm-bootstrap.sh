#!/usr/bin/env bash
# Bootstrap detection, local setup, and deferred network refresh.
# Usage:
#   fm-bootstrap.sh
#   fm-bootstrap.sh install <tool>...
#
# Detection prints only actionable diagnostics plus explicit BOOTSTRAP_INFO
# facts. FM_BOOTSTRAP_DETECT_ONLY=1 skips all mutation. FM_BOOTSTRAP_NETWORK
# splits local detection from network work: skip runs local work only, only
# runs GitHub authentication and project clone refresh, and all runs both.
#
# The local phase validates tool/version floors, backend and crew dispatch
# configuration, startup-memory-budget, Feishu, backlog ownership, and checkout
# tangle state. Under a locked mutable session it also reconciles this home's
# worker records, materializes the startup-memory default, and configures Relay.
# The network phase checks GitHub authentication and refreshes registered project
# clones. All operations are scoped to this home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# fm-timing-lib.sh is inert unless FM_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/fm-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${FM_BOOTSTRAP_NETWORK:-all}" in
  skip|only) FM_BOOTSTRAP_NETWORK_PHASE=${FM_BOOTSTRAP_NETWORK:-all} ;;
  *) FM_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${FM_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    node|git|gh|curl|jq) echo "brew install $1  # or the platform's package manager" ;;
    python3) echo "brew install python  # or install Python 3.9+ with the platform package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). Retired configuration refuses
# instead of installing an old terminal. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh gh-axi chrome-devtools-axi tasks-axi python3 jq"
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
  echo 'INCOMPATIBLE: python3 (Firstmate requires Python 3.9 or newer)'
fi
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
# Agent-facing wrappers are discovered through their installed help at use time.
# Presence is sufficient here, as for chrome-devtools-axi; actual operations
# retain their exit-status and authoritative readback requirements.

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(/usr/bin/stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(/usr/bin/stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$FM_HOME" in
    /*) shim_home=$FM_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["codex","pi","traex"] | index($h);
    def effort_ok($h; $m; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $e == "ultra" then (($h == "pi") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
      elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
      elif $h == "traex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "pi" then (["low","medium","high","xhigh","max"] | index($e))
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def removed_load_preferences:
      configured_profiles | any(has("preferWhileLoadBelowPercent"));
    def duplicate_profile_array($value):
      if ($value | type) != "array" then false
      else ([$value[] | tojson] | length) != ([$value[] | tojson] | unique | length)
      end;
    def bad_efforts:
      configured_profiles
      | map({h: .harness, m: .model, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.m; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "ordered")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "ordered") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(duplicate_profile_array(.use?))] | length > 0 then "profile arrays must not contain duplicate profiles"
    elif has("default") and duplicate_profile_array(.default) then "profile arrays must not contain duplicate profiles"
    elif removed_load_preferences then "preferWhileLoadBelowPercent is no longer supported; order profiles by preference"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end)
      ;
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "ordered") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

# Same-home record reconciliation. Every ordinary dispatch and completion now
# moves the backlog row inside the script that moves the task's record
# (bin/fm-backlog-transition-lib.sh), so remaining recovery cases include a
# process killed mid-transition and drift this home was already carrying. Heal
# this home's OWN books on its own restart. Never reads or writes another home.
backlog_record_reconcile() {
  local marker meta control_lock meta_lock id row label has_record=0 has_work=0 gate_status
  # A fresh home with no state directory has no physical task records to pair.
  # Keep bootstrap diagnostics working without creating state just for a no-op.
  [ -e "$STATE" ] || [ -L "$STATE" ] || return 0
  if ! fm_backlog_directory_present "$STATE" "state directory"; then
    echo "error: backlog reconciliation refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  fi
  for marker in "$STATE"/*.backlog-close "$STATE"/*.meta; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    has_work=1
    break
  done
  [ "$has_work" = 1 ] || return 0
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    gate_status=$?
    if [ "$gate_status" -eq 2 ]; then
      echo "error: backlog reconciliation cannot access configured data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 2
    fi
    return 0
  fi
  # Keep the wake/lock library's source-time state-directory creation inside
  # this mutating sweep, so FM_BOOTSTRAP_DETECT_ONLY remains read-only.
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  # Finish any close an interrupted cleanup recorded but never landed.
  for marker in "$STATE"/*.backlog-close; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    if ! fm_backlog_record_present "$marker" "pending-close record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe pending close refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    label=$(basename "$marker" .backlog-close)
    control_lock="$STATE/.control-$label.lock"
    meta_lock=$(fm_meta_lock_path "$STATE/$label.meta") || continue
    fm_lock_try_acquire "$control_lock" || continue
    if ! fm_lock_try_acquire "$meta_lock"; then
      fm_lock_release "$control_lock"
      continue
    fi
    if fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"; then
      case "$FM_BACKLOG_CLOSE_REPLAY_RESULT" in
        closed)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label that an interrupted cleanup left open"
          ;;
        closed_incomplete)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        retained)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after an interrupted cleanup"
          ;;
        retained_incomplete)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        answered)
          echo "BOOTSTRAP_INFO: finished the interrupted cleanup for $label; the captain had already answered its call"
          ;;
      esac
    else
      echo "BACKLOG_RECONCILE: $label: recorded backlog close could not be replayed: $FM_BACKLOG_TRANSITION_ERROR"
    fi
    fm_lock_release "$meta_lock"
    fm_lock_release "$control_lock"
  done

  # A home that owns no records has nothing to pair, so it never pays for a
  # backlog read. A pending close remains authoritative even when replay failed:
  # the record sweep below must not start that item while its marker survives.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    has_record=1
    break
  done
  [ "$has_record" = 1 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    id=$(basename "$meta" .meta)
    meta_lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$meta_lock" || continue
    if [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
      fm_lock_release "$meta_lock"
      continue
    fi
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: $id: post-lock worker record check refused: $FM_BACKLOG_TRANSITION_ERROR"
      fm_lock_release "$meta_lock"
      return 2
    fi
    if [ "$(fm_meta_get "$meta" kind)" != secondmate ] \
       && [ "$(fm_meta_get "$meta" cleanup_recovery)" != orca ]; then
      row=
      if fm_backlog_row_probe "$DATA" "$id"; then
        row=$FM_BACKLOG_ROW_STATE
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be read: $FM_BACKLOG_ROW_ERROR"
      fi
      # Heal only the unambiguous case: a queued row for a record this home
      # already owns. A held row is the captain's to move, and a closed row is a
      # contradiction this sweep must not resolve by resurrecting the item.
      if [ "$row" = "queued no no" ]; then
        if fm_backlog_start "$DATA" "$id"; then
          echo "BOOTSTRAP_INFO: marked $id in flight to match the worker this home already owns"
        else
          echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be moved to In flight: $FM_BACKLOG_TRANSITION_ERROR"
        fi
      fi
    fi
    fm_lock_release "$meta_lock"
  done
}

startup_memory_budget_setup() {
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. Detect-only
# sessions never touch state, and the deferred network pass never repeats it:
# the local pass that ran first already closed that window.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  BOOTSTRAP_BACKLOG_GATE_KIND=none
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    if ! fm_backlog_directory_present "$STATE" "state directory"; then
      echo "error: bootstrap cannot reconcile task state ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    for BOOTSTRAP_BACKLOG_MARKER in "$STATE"/*.backlog-close; do
      [ -e "$BOOTSTRAP_BACKLOG_MARKER" ] || [ -L "$BOOTSTRAP_BACKLOG_MARKER" ] || continue
      if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_MARKER" "pending-close record" "$STATE"; then
        echo "error: bootstrap refused unsafe pending close ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      fi
      BOOTSTRAP_BACKLOG_GATE_KIND=ship
      break
    done
    if [ "$BOOTSTRAP_BACKLOG_GATE_KIND" = none ]; then
      for BOOTSTRAP_BACKLOG_META in "$STATE"/*.meta; do
        [ -e "$BOOTSTRAP_BACKLOG_META" ] || [ -L "$BOOTSTRAP_BACKLOG_META" ] || continue
        if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_META" "task record" "$STATE"; then
          echo "error: bootstrap refused unsafe worker record ($FM_BACKLOG_TRANSITION_ERROR)" >&2
          exit 1
        fi
        if [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" kind)" != secondmate ] \
           && [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" cleanup_recovery)" != orca ]; then
          BOOTSTRAP_BACKLOG_GATE_KIND=ship
          break
        fi
      done
    fi
  fi
  if [ "$BOOTSTRAP_BACKLOG_GATE_KIND" = ship ]; then
    if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
      :
    else
      BOOTSTRAP_BACKLOG_GATE_STATUS=$?
      if [ "$BOOTSTRAP_BACKLOG_GATE_STATUS" -eq 2 ]; then
        echo "error: bootstrap cannot access configured backlog data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      fi
    fi
  fi
  startup_memory_budget_setup
  if backlog_record_reconcile; then
    :
  else
    BOOTSTRAP_BACKLOG_RECONCILE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_RECONCILE_STATUS" -eq 2 ]; then
      exit 1
    fi
  fi
  "$SCRIPT_DIR/fm-procevent-lavish.sh" retire-registered \
    || { echo "error: bootstrap could not retire legacy Lavish sources" >&2; exit 1; }
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend requires Treehouse; retired selectors must refuse before setup.
  if fm_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

feishu_channel_detect() {
  local config_status sdk_module
  [ -e "$CONFIG/feishu.env" ] || [ -L "$CONFIG/feishu.env" ] || return 0
  if ! config_status=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-feishu-transport.sh" config-check 2>/dev/null); then
    echo "FEISHU: local config refused; run bin/fm-feishu-transport.sh config-check and inspect docs/feishu-channel.md"
    return 0
  fi
  [ "$config_status" = '{"status":"enabled"}' ] || return 0
  sdk_module=${FM_FEISHU_SDK_MODULE:-@larksuiteoapi/node-sdk}
  if ! node -e 'const fs=require("fs");const s=process.argv[1];if(s.startsWith("/"))fs.accessSync(s);else require.resolve(s,{paths:[process.argv[2]]})' "$sdk_module" "$FM_ROOT" >/dev/null 2>&1; then
    echo "MISSING_MANUAL: @larksuiteoapi/node-sdk (instructions: docs/feishu-channel.md)"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
  # default branch, not a feature branch (see fm-tangle-lib.sh). Detached-HEAD
  # worktrees never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${FM_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  case "$crew" in
    ''|default|pi|codex|traex) ;;
    *) echo "CREW_DISPATCH: unsupported config/crew-harness '$crew'; select pi, codex, or traex explicitly; existing work is preserved" ;;
  esac
  crew_dispatch_validate
  feishu_channel_detect
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
}

# This home's ledger publication is deliberately best-effort: every lifecycle
# trigger calls it with --best-effort so a failure can never change the result
# of a session start, a spawn, a teardown, or a watcher poll. That is correct,
# and it also means a home that never manages to publish says nothing at all -
# the failures land only in the bounded home-local record nobody reads.
#
# So read that same record here, where a session start already looks, and say so
# once when the evidence is a pattern rather than a blip: the ledger has not
# been (re)published, and at least FM_HOME_SUMMARY_FAILURE_REPORT attempts have
# failed since whenever it last was. No new record, no new state, no retry
# policy - just the existing evidence, surfaced.
# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# fm-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # Clone refresh can run in the background while local setup continues.
  fleet_sync_pid=
  fleet_sync_out=
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    fleet_sync_out=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-fleet.XXXXXX") || fleet_sync_out=
    if [ -n "$fleet_sync_out" ]; then
      (
        __fm_timing_stamp=$(fm_timing_now_ms)
        fleet_sync
        fm_timing_record phase fleet-sync "$__fm_timing_stamp"
      ) >"$fleet_sync_out" 2>&1 &
      fleet_sync_pid=$!
    else
      __fm_timing_stamp=$(fm_timing_now_ms)
      fleet_sync
      fm_timing_record phase fleet-sync "$__fm_timing_stamp"
    fi
  fi
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  if [ -n "$fleet_sync_pid" ]; then
    wait "$fleet_sync_pid" || true
    cat "$fleet_sync_out"
    rm -f "$fleet_sync_out"
  fi
fi
exit 0
