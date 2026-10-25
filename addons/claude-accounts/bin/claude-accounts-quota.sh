#!/usr/bin/env bash
# claude-accounts-quota.sh - one quota view of every Claude account the owner has signed in.
# Reads the account list from the muxr registry, asks `quota-axi --profile-only` about each profile
# folder (the folder path is the only thing passed; nothing inside a login folder is opened), and writes
# <home>/state/claude-accounts.json for the dashboard card and for dispatch input.
# Usage: claude-accounts-quota.sh [--print]     (--print: also show the file on stdout)
# Env:   FM_HOME (required), FM_CLAUDE_ACCOUNTS_REGISTRY
#        (default: ~/.muxr/plans/accounts-v1.json), FM_CLAUDE_ACCOUNTS_SECONDS (per-account read limit, 60).
#        FM_ACCOUNTS_PROVIDER=claude|codex (default claude); writes <provider>-accounts.json.
set -uo pipefail

FM_HOME=${FM_HOME:?set FM_HOME to the Firstmate home}
REGISTRY=${FM_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
SECONDS_MAX=${FM_CLAUDE_ACCOUNTS_SECONDS:-60}
PROVIDER=${FM_ACCOUNTS_PROVIDER:-claude}
case "$PROVIDER" in claude | codex) ;; *) echo "error: unsupported quota provider $PROVIDER" >&2; exit 1 ;; esac
OUT=$FM_HOME/state/$PROVIDER-accounts.json
REST_STATE=$(sed -n 's/^state=//p' "$FM_HOME/config/account-pool" 2>/dev/null | head -n 1)
case "$REST_STATE" in /*) ;; *) REST_STATE=$FM_HOME/state ;; esac
PRINT=0
[ "${1:-}" = --print ] && PRINT=1
for tool in jq quota-axi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: claude-accounts needs $tool on PATH" >&2; exit 1; }
done
[ -r "$REGISTRY" ] || { echo "error: muxr account registry not readable: $REGISTRY" >&2; exit 1; }

# id, name and folder only: the filter names these three fields, so nothing else is ever printed.
mapfile -t ROWS < <(jq -r --arg provider "$PROVIDER" '.accounts[]? | select(.provider == $provider and (.folder | type) == "string" and (.folder | startswith("/")))
  | [.id, (.name // ""), .folder] | join("\u001f")' "$REGISTRY")
[ "${#ROWS[@]}" -gt 0 ] || { echo "error: no Claude account in $REGISTRY" >&2; exit 1; }

read_one() { # id name folder -> one account JSON object
  local id=$1 name=$2 folder=$3 raw err rc errf rested
  rested=$(cat "$REST_STATE/$PROVIDER-accounts-rested/$id" 2>/dev/null) || rested=0
  case "$rested" in '' | *[!0-9]*) rested=0 ;; esac
  errf=$(mktemp "${TMPDIR:-/tmp}/claude-accounts.XXXXXX") || return 1
  raw=$(CLAUDE_CONFIG_DIR=$folder CODEX_HOME=$folder timeout "$SECONDS_MAX" quota-axi --provider "$PROVIDER" --profile-only --json 2>"$errf")
  rc=$?
  err=$(sed -n '1p' "$errf" | cut -c1-160)
  rm -f "$errf"
  # A failed read (a vendor rate limit, say) keeps the account's last good windows, marked stale with their own read_at.
  jq -cn --arg id "$id" --arg name "${name:-default}" --arg folder "$folder" --arg raw "$raw" --arg err "$err" --argjson rc "$rc" \
    --argjson now "$NOW" --argjson rested "$rested" --argjson prev "$(jq -c --arg id "$id" '(.generated_at) as $g | [.accounts[]? | select(.id == $id and (.five_hour != null or .seven_day != null)) | . + {read_at: (.read_at // $g)}] | first // null' "$OUT" 2>/dev/null || echo null)" '
    def win($w): ([ $raw | fromjson? | (.providers[0]? // .) | .windows[]? | select(.id == $w or ($w == "seven_day" and .id == "weekly")) ] | first) as $x
      | if $x == null then null else {left: $x.percentRemaining, resets_at: $x.resetsAt} end;
    (win("five_hour")) as $h | (win("seven_day")) as $d
    | ([$raw | fromjson? | (.providers[0]? // .) | .state.error?] | first) as $verr
    | (if $rc != 0 then (if $err != "" then $err else ($verr // "quota-axi exited \($rc)") end)
       elif $h == null and $d == null then ($verr // "no 5h or 7d window in the reading") else null end) as $problem
    | {id: $id, name: $name, folder: $folder, five_hour: $h, seven_day: $d, read_at: $now, problem: $problem, stale: false}
    | if .problem != null and $prev != null then . + {five_hour: $prev.five_hour, seven_day: $prev.seven_day, read_at: $prev.read_at, stale: true} else . end
    | . + {rested_until: (if $rested > $now and (.five_hour.left != 100 or .seven_day.left != 100) then $rested else null end)}'
}

NOW=$(date +%s)
ACCOUNTS=()
for row in "${ROWS[@]}"; do
  IFS=$'\037' read -r id name folder <<<"$row"
  ACCOUNTS+=("$(read_one "$id" "$name" "$folder")") || exit 1
done
JSON=$(printf '%s\n' "${ACCOUNTS[@]}" | jq -sc --argjson at "$(date +%s)" '{schema: 1, generated_at: $at, accounts: .}') || exit 1
mkdir -p "$FM_HOME/state"
tmp=$(mktemp "$OUT.XXXXXX") && printf '%s\n' "$JSON" >"$tmp" && mv -f "$tmp" "$OUT" || { echo "error: cannot write $OUT" >&2; exit 1; }
[ "$PRINT" -eq 0 ] || printf '%s\n' "$JSON"
jq -e 'any(.accounts[]; .problem == null)' "$OUT" >/dev/null
