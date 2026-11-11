#!/usr/bin/env bash
# fm-stow-guard.sh - Claude Stop hook that asks a primary session to /stow
# before context compaction.
#
# Opt in by creating the home-local config/stow-guard file. Absent means off.
# docs/configuration.md "Stow guard" owns that gate and its tunables. This
# header owns the transcript read, the state file, and the block message.
#
# With the file present, defaults are 300000 context tokens and 24 hours since
# the newest /stow this hook has seen. Optional lines are tokens=<n> and
# hours=<n>. Blank lines and lines starting with # are ignored. An unusable
# value keeps its default. An hour above 87600 or a token count above
# 100000000 is unusable, so the shell comparison stays inside integer range.
# FM_STOW_CONTEXT_TOKENS and FM_STOW_MAX_AGE_HOURS override those two lines
# when they are usable integers. FM_STOW_GUARD_NOW overrides the clock for tests.
#
# The context ask fires once when the newest usage in the transcript tail is at
# or above the token line, then again only after a later read falls below
# two-thirds of that line. The age ask fires when the newest seen /stow is
# older than the hour line, and then not again for an hour. It is skipped when
# a /stow timestamp cannot be read, including when python3 is missing, so a
# just-completed /stow is not asked for again from a stale clock. The stored
# state is what makes each ask once per crossing, so a continuation stop
# (stop_hook_active / stopHookActive) is handled like any other stop. The first
# opt-in stop with no /stow in the tail starts the age clock instead of asking.
#
# Context size is the same sum warm-cache compaction uses: input + cache_read
# + cache_creation on the newest usage object in the last 2MB of the transcript.
# A /stow is a Skill tool call whose skill is stow, in that same tail. The
# newest one is remembered in state/.stow-guard.json, so a later tail that no
# longer contains it does not rewind the clock.
#
# The hook prints one Claude block decision, or nothing. Any unreadable
# payload, missing jq, scope miss, or state-write failure exits 0 and prints
# nothing, so a Stop is never stuck on this hook. It is silent for a Cursor
# payload, for Grok, in a marked secondmate home, and outside a plain primary
# checkout. A Stop block in a secondmate home would leave its parent recording
# idle while that session was still working.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0

usage() {
  cat <<'EOF'
usage: fm-stow-guard.sh

Claude Stop hook. Reads the hook payload on stdin.
Create config/stow-guard to enable it. See the script header.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

if [ -n "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ]; then
  exit 0
fi

if [ -t 0 ]; then
  usage
  exit 0
fi

payload=$(cat || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
  exit 0
fi

cursor=$(jq -r '.cursor_version // .cursorVersion // empty' <<<"$payload" 2>/dev/null || true)
[ -z "$cursor" ] || exit 0

sid=$(jq -r '.session_id // .sessionId // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$sid" ] || sid=session
transcript=$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null || true)

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
[ -f "$CONFIG/stow-guard" ] || exit 0

threshold=300000
hours=24
line='' key='' value=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  case "$value" in
    ''|*[!0-9]*|0*) continue ;;
  esac
  case "$key" in
    tokens) threshold=$value ;;
    hours) hours=$value ;;
  esac
done < "$CONFIG/stow-guard"

if [ -n "${FM_STOW_CONTEXT_TOKENS:-}" ]; then
  case "$FM_STOW_CONTEXT_TOKENS" in
    ''|*[!0-9]*|0*) ;;
    *) threshold=$FM_STOW_CONTEXT_TOKENS ;;
  esac
fi
if [ -n "${FM_STOW_MAX_AGE_HOURS:-}" ]; then
  case "$FM_STOW_MAX_AGE_HOURS" in
    ''|*[!0-9]*|0*) ;;
    *) hours=$FM_STOW_MAX_AGE_HOURS ;;
  esac
fi
# Reject an over-long digit string before the shell compares it. A value past
# these widths is already above the caps below, and an unbounded integer would
# overflow the later arithmetic.
if [ "${#threshold}" -gt 9 ] || [ "$threshold" -gt 100000000 ]; then
  threshold=300000
fi
if [ "${#hours}" -gt 5 ] || [ "$hours" -gt 87600 ]; then
  hours=24
fi
max_age=$((hours * 3600))
rearm_below=$((threshold * 2 / 3))

now=${FM_STOW_GUARD_NOW:-$(date +%s)}
case "$now" in
  ''|*[!0-9]*) exit 0 ;;
esac

state_path="$STATE/.stow-guard.json"
last_stow=
asked=0
fired='{}'
if [ -f "$state_path" ]; then
  last_stow=$(jq -r '.last_stow // empty' "$state_path" 2>/dev/null || true)
  asked=$(jq -r '.asked // 0' "$state_path" 2>/dev/null || echo 0)
  fired=$(jq -c '.fired // {}' "$state_path" 2>/dev/null || echo '{}')
fi
case "$last_stow" in
  ''|*[!0-9]*) last_stow= ;;
esac
case "$asked" in
  ''|*[!0-9]*) asked=0 ;;
esac
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$fired"; then
  fired='{}'
fi

tokens=0
seen_stow=
saves_readable=0
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  tokens=$(tail -c 2000000 "$transcript" | jq -R -r '
      fromjson? | .message.usage // empty | select(type == "object")
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    ' | awk 'NF { n = $0 } END { if (n == "") print 0; else print n + 0 }') || tokens=0
  case "$tokens" in
    ''|*[!0-9]*) tokens=0 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if seen_stow=$(tail -c 2000000 "$transcript" | jq -R -r '
        fromjson? | .timestamp as $ts | select($ts != null)
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Skill" and .input.skill == "stow")
        | $ts
      ' | python3 -c 'import datetime, sys
best = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        stamp = int(datetime.datetime.fromisoformat(line.replace("Z", "+00:00")).timestamp())
    except Exception:
        continue
    if stamp > best:
        best = stamp
if best:
    print(best)
'); then
      saves_readable=1
    else
      seen_stow=
    fi
    case "$seen_stow" in
      ''|*[!0-9]*) seen_stow= ;;
    esac
  fi
fi

if [ "$tokens" -gt 0 ] && [ "$tokens" -lt "$rearm_below" ]; then
  fired=$(jq -c --arg sid "$sid" 'del(.[$sid])' <<<"$fired") || exit 0
fi
if [ -n "$seen_stow" ]; then
  if [ -z "$last_stow" ] || [ "$seen_stow" -gt "$last_stow" ]; then
    last_stow=$seen_stow
  fi
fi

reason=
has_fired=$(jq -r --arg sid "$sid" 'if .[$sid] == true then "1" else "0" end' <<<"$fired") || exit 0
if [ "$tokens" -ge "$threshold" ] && [ "$has_fired" -eq 0 ]; then
  reason="fm-stow-guard: context is ${tokens} tokens, near auto-compaction. Run the /stow skill now (full pass), then continue the turn you were in."
  fired=$(jq -c --arg sid "$sid" '.[$sid] = true' <<<"$fired") || exit 0
elif [ "$saves_readable" -eq 1 ] && [ -z "$last_stow" ]; then
  last_stow=$now
elif [ "$saves_readable" -eq 1 ] && [ $((now - last_stow)) -ge "$max_age" ] && [ $((now - asked)) -ge 3600 ]; then
  reason="fm-stow-guard: the last /stow is older than ${hours}h. Run the /stow skill now (full pass), then continue the turn you were in."
fi
if [ -n "$reason" ]; then
  asked=$now
fi

tmp=$(mktemp "$STATE/.stow-guard.json.XXXXXX") || exit 0
if [ -n "$last_stow" ]; then
  jq -n --argjson last_stow "$last_stow" --argjson asked "$asked" --argjson fired "$fired" \
    '{last_stow:$last_stow, asked:$asked, fired:$fired}' > "$tmp" || { rm -f "$tmp"; exit 0; }
else
  jq -n --argjson asked "$asked" --argjson fired "$fired" \
    '{asked:$asked, fired:$fired}' > "$tmp" || { rm -f "$tmp"; exit 0; }
fi
mv -f "$tmp" "$state_path" || { rm -f "$tmp"; exit 0; }

if [ -n "$reason" ]; then
  jq -nc --arg reason "$reason" '{decision:"block", reason:$reason}'
fi
exit 0
