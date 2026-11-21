#!/usr/bin/env bash
# Hermes TUI worker support. Sourced; no side effects.
# fm_hermes_profile_home <binary> <profile-or-empty> prints the native selected
# profile home, refusing unsafe names and non-absolute native config paths.
# fm_hermes_gateway_check <profile-home> <profile-name> allows the profile's own
# live gateway only when its native gateway_state.json shows it running with
# zero active agents at a fresh heartbeat. It refuses mid-turn, transitional,
# unreadable or malformed state, and a default-root or other-home gateway that
# may serve the profile. It never starts/stops a service, creates a lock, or
# changes a profile.
# fm_hermes_write_hooks <binary> <profile-home> <state> <id> <gen> stages a
# private native managed-scope overlay under <state>/<id>.hermes-hooks/.
# Existing managed scopes are refused rather than replaced. The native resolved
# hooks are preserved, then pre_llm_call/on_session_end are appended. No model,
# effort, SOUL, or profile configuration is changed. Requires python3 and jq.

fm_hermes_profile_home() {
  local binary=$1 profile=$2 config
  if [ -n "$profile" ] && ! [[ "$profile" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    echo 'error: --hermes-profile must be a lowercase Hermes profile name (1-64 letters, digits, underscores or hyphens)' >&2
    return 1
  fi
  local args=()
  [ -z "$profile" ] || args=(-p "$profile")
  config=$("$binary" "${args[@]}" config path) || return 1
  case "$config" in
    /*/config.yaml) printf '%s' "${config%/config.yaml}" ;;
    *) echo 'error: hermes config path did not return an absolute config.yaml path' >&2; return 1 ;;
  esac
}

fm_hermes_gateway_check() {
  local home=$1 profile=${2:-default} status=
  if [ "$(basename "${home%/*}")" = profiles ]; then
    profile=${home##*/}
  elif [ "$profile" = "${home##*/}" ]; then
    profile=default
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$profile" = default ]; then
      status=$(systemctl --user is-active hermes-gateway.service 2>/dev/null) || true
    else
      status=$(systemctl --user is-active "hermes-gateway-$profile.service" 2>/dev/null) || true
    fi
  fi
  python3 - "$home" "$profile" "$status" <<'PY_GATEWAY'
import fcntl, json, os, sys
from datetime import datetime, timezone
from pathlib import Path
home, profile, service = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
def refuse(reason):
    print(f"error: Hermes profile '{profile}': {reason}; choose a separate profile. No gateway was changed.", file=sys.stderr)
    raise SystemExit(1)
def read_record(path):
    try:
        text = path.read_text()
    except FileNotFoundError:
        return None
    except OSError:
        refuse('gateway state is unreadable')
    try:
        record = json.loads(text)
        pid = record.get('pid') if isinstance(record, dict) else record
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise ValueError()
    except (ValueError, TypeError):
        refuse('gateway state cannot prove the gateway stopped')
    return record, pid
def live(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        refuse('gateway process ownership is uninspectable')
    return True
def lock_held(path):
    try:
        with path.open('rb') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
    except FileNotFoundError:
        pass
    except OSError:
        refuse('the native gateway runtime lock is unreadable')
    return False
if service in ('activating', 'reloading', 'deactivating'):
    refuse(f'its gateway service is {service}')
# A named profile under a root whose own gateway is live may be served by that
# default-root gateway, whose activity cannot be attributed to this profile.
root = home.parent.parent if home.parent.name == 'profiles' else home
if root != home:
    for path in (root / 'gateway.pid', root / 'gateway_state.json'):
        found = read_record(path)
        if found and live(found[1]):
            refuse('a default-root gateway is live and may serve this profile')
    if lock_held(root / 'gateway.lock'):
        refuse('a default-root gateway runtime lock is held and may serve this profile')
own = set()
# Newer multiplexers publish a per-user host rendezvous with their launch
# home and served profile names. Match the root as well as the profile name.
lock_dir = os.environ.get('HERMES_GATEWAY_LOCK_DIR')
if not lock_dir:
    state_home = Path(os.environ.get('XDG_STATE_HOME', ''))
    if not state_home.is_absolute():
        state_home = Path.home() / '.local' / 'state'
    lock_dir = state_home / 'hermes' / 'gateway-locks'
record_path = Path(lock_dir) / 'host-gateway.json'
try:
    host = json.loads(record_path.read_text())
except FileNotFoundError:
    host = None
except (OSError, ValueError):
    refuse('the host gateway rendezvous is unreadable')
if host is not None:
    if not isinstance(host, dict) or not isinstance(host.get('home'), str):
        refuse('the host gateway rendezvous has no inspectable home')
    launch_home = Path(host['home'])
    launch_root = launch_home.parent.parent if launch_home.parent.name == 'profiles' else launch_home
    if launch_root.resolve() == root.resolve() and profile in host.get('profiles', []):
        pid = host.get('pid')
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            refuse('the host gateway rendezvous cannot prove the gateway stopped')
        if live(pid):
            if launch_home.resolve() != home.resolve():
                refuse('a gateway launched from another home serves this profile')
            own.add(pid)
found = read_record(home / 'gateway.pid')
if found and live(found[1]):
    own.add(found[1])
state = read_record(home / 'gateway_state.json')
if state and live(state[1]):
    own.add(state[1])
if not own and service != 'active' and not lock_held(home / 'gateway.lock'):
    raise SystemExit(0)
# The profile's own gateway is live. Coexist only when its native runtime
# status proves it serving with no agent work at a fresh heartbeat.
if not state or not isinstance(state[0], dict) or own != {state[1]}:
    refuse('a live gateway has no runtime status that identifies it')
record = state[0]
if record.get('gateway_state') != 'running' or record.get('restart_requested') is not False:
    refuse(f"its live gateway is not idle-serving (state {record.get('gateway_state')!r})")
agents = record.get('active_agents')
if not isinstance(agents, int) or isinstance(agents, bool) or agents != 0 or record.get('active_work'):
    refuse('its live gateway is mid-turn or reports no idle agent count')
try:
    stamp = datetime.fromisoformat(record['updated_at'])
    age = (datetime.now(timezone.utc) - stamp).total_seconds()
except (KeyError, TypeError, ValueError):
    refuse('its live gateway status has no readable heartbeat')
if not -5 <= age <= 120:
    refuse('its live gateway heartbeat is stale')
PY_GATEWAY
}

fm_hermes_write_hooks() {
  local binary=$1 home=$2 state=$3 id=$4 gen=$5 hooks dir command prefix
  fm_hermes_managed_check || return 1
  dir="$state/$id.hermes-hooks"
  (umask 077 && mkdir -p "$dir") || return 1
  chmod 700 "$dir" || return 1
  # Raw is required here so existing hook command values remain exact; this
  # private config is never printed. Hermes supplies an empty hooks mapping
  # in its defaults. Discovery failure refuses instead of dropping user hooks.
  hooks=$(HERMES_HOME="$home" "$binary" config get hooks --json --raw) || return 1
  prefix="$(fm_hermes_quote "${BASH_SOURCE[0]%/*}/fm-hermes-hook.sh") $(fm_hermes_quote "$state") $(fm_hermes_quote "$id") $(fm_hermes_quote "$gen")"
  command="$prefix busy"
  jq -en --argjson hooks "$hooks" --arg busy "$command" --arg idle "$prefix idle" '
    if ($hooks | type) != "object" then error("Hermes hooks must be an object") else
      {hooks: ($hooks | .pre_llm_call = ((.pre_llm_call // []) + [{command: $busy, timeout: 10}]) |
        .on_session_end = ((.on_session_end // []) + [{command: $idle, timeout: 10}]))}
    end' > "$dir/config.yaml.tmp" || return 1
  chmod 600 "$dir/config.yaml.tmp" && mv "$dir/config.yaml.tmp" "$dir/config.yaml"
}

fm_hermes_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# fm_hermes_startup_screen <capture> -> decline|ready|wait.
# Only the complete observed offer with the negative option ALREADY selected
# may be answered with Enter. Never navigate a positive choice or type a number.
fm_hermes_startup_screen() {
  local screen
  screen=$(printf '%s\n' "$1" | fm_composer_strip_ansi)
  if printf '%s\n' "$screen" | grep -Fq 'Help improve Hermes?' &&
     printf '%s\n' "$screen" | grep -Fq 'Collect and send to Nous' &&
     printf '%s\n' "$screen" | grep -Fq 'Collect locally only'; then
    if printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*(→[[:space:]]*)?\(●\)[[:space:]]*([0-9]+[.)][[:space:]]*)?No thanks[[:space:]]*$'; then
      printf decline
    else
      printf wait
    fi
  elif printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*─[[:space:]]+ready[[:space:]]*│' &&
       printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*([a-z0-9][a-z0-9_-]*[[:space:]]+)?❯'; then
    printf ready
  else
    printf wait
  fi
}

fm_hermes_managed_check() {
  if [ -n "${HERMES_MANAGED_DIR:-}" ] || [ -d /etc/hermes ]; then
    echo 'error: Hermes workers cannot replace an existing managed scope; use a runtime without HERMES_MANAGED_DIR or /etc/hermes' >&2
    return 1
  fi
}
