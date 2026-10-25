#!/usr/bin/env bash
# run-proof-codex-rest.sh: prove a stale Codex rest clears when the reading has null
# five_hour and seven_day.left >= FM_ACCOUNT_POOL_REST_FLOOR (default 15). Copies the
# live pool Codex reading and rested list into a temp --state dir (never edits the live
# rest file), then runs pick. Requires a pool state with codex-accounts.json and
# codex-accounts-rested/<id> (set POOL_STATE, or FM_HOME with config/account-pool
# state=). Screen: none.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
pick=$repo/claude-accounts/bin/claude-accounts-pick

resolve_pool_state() {
  if [ -n "${POOL_STATE:-}" ]; then
    printf '%s\n' "$POOL_STATE"
    return
  fi
  [ -n "${FM_HOME:-}" ] || return 1
  local cfg=$FM_HOME/config/account-pool line=
  [ -r "$cfg" ] || return 1
  line=$(grep -E '^state=' "$cfg" | head -n1) || return 1
  printf '%s\n' "${line#state=}"
}

pool_state=$(resolve_pool_state) || {
  echo "error: set POOL_STATE or FM_HOME with config/account-pool state=" >&2
  exit 1
}
[ -r "$pool_state/codex-accounts.json" ] || {
  echo "error: no Codex reading at $pool_state/codex-accounts.json" >&2
  exit 1
}
rested_src=$pool_state/codex-accounts-rested
[ -d "$rested_src" ] || {
  echo "error: no Codex rested dir at $rested_src" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/state/codex-accounts-rested" "$work/folders" "$work/live-rest-snapshot"
cp "$pool_state/codex-accounts.json" "$work/state/"
# Copy only rested files; never write back to the live path.
cp -a "$rested_src/." "$work/state/codex-accounts-rested/" 2>/dev/null || true
cp -a "$rested_src/." "$work/live-rest-snapshot/" 2>/dev/null || true

jq -r '.accounts[]?.id // empty' "$work/state/codex-accounts.json" | while read -r id; do
  [ -n "$id" ] || continue
  mkdir -p "$work/folders/$id"
done
jq -n --argjson reading "$(cat "$work/state/codex-accounts.json")" --arg root "$work/folders" '
  {version:1, accounts: [
    $reading.accounts[]? | {id, provider:"codex", name:(.name // ""), folder:($root + "/" + .id)}
  ]}' >"$work/registry.json"

{
  echo "pool_state_basename=$(basename "$pool_state")"
  echo "live_rest_untouched=yes"
  echo "reading:"
  jq '{generated_at, accounts: [.accounts[] | {id, problem, five_hour, seven_day}]}' "$work/state/codex-accounts.json"
  echo "rested_before:"
  for f in "$work/state/codex-accounts-rested"/*; do
    [ -f "$f" ] || continue
    echo "  ${f##*/}=$(cat "$f")"
  done
} >"$evidence/codex-rest-before.txt"

bash "$repo/claude-accounts/tests/claude-accounts-pick.test.sh" >"$evidence/pick-test.txt" 2>&1

rc=0
out=$(env -i PATH="$PATH" HOME="$work" TMPDIR="$work" \
  FM_CLAUDE_ACCOUNTS_REGISTRY="$work/registry.json" FM_CLAUDE_ACCOUNTS_FRESH=999999 \
  "$pick" pick codex --json --state "$work/state" 2>"$work/stderr") || rc=$?
printf '%s\n' "$out" >"$evidence/codex-pick.json"
{
  echo "pick_rc=$rc"
  echo "pick_json=$out"
  echo "stderr=$(tr '\n' ' ' <"$work/stderr" 2>/dev/null || true)"
  echo "rested_after:"
  for f in "$work/state/codex-accounts-rested"/*; do
    [ -f "$f" ] || continue
    echo "  ${f##*/}=$(cat "$f")"
  done
} >"$evidence/codex-rest-after.txt"

ok=$(jq -r '.ok // false' <<<"$out" 2>/dev/null || echo false)
id=$(jq -r '.id // empty' <<<"$out" 2>/dev/null || true)
floor=${FM_ACCOUNT_POOL_REST_FLOOR:-15}
recovered=$(jq -r --argjson floor "$floor" '.accounts[]? | select(.problem == null and (
  if .five_hour == null and .seven_day != null then .seven_day.left >= $floor
  else ([.five_hour, .seven_day] | map(select(. != null)) | length > 0 and all(.left == 100))
  end)) | .id' "$work/state/codex-accounts.json")
for rid in $recovered; do
  [ -f "$work/state/codex-accounts-rested/$rid" ] || continue
  exp=$(tr -d '\n' <"$work/state/codex-accounts-rested/$rid")
  [ "$exp" = 0 ] || {
    echo "error: recovered account $rid rest still $exp" >&2
    exit 1
  }
done
[ "$ok" = true ] && [ -n "$id" ] && [ "$rc" -eq 0 ] || {
  echo "error: Codex pick failed after rest recovery (rc=$rc ok=$ok id=$id)" >&2
  cat "$evidence/codex-rest-after.txt" >&2
  exit 1
}

# Live rested files must match the snapshot taken before the temp pick.
for f in "$work/live-rest-snapshot"/*; do
  [ -f "$f" ] || continue
  name=${f##*/}
  cmp -s "$f" "$rested_src/$name" || {
    echo "error: live rest file $name changed during proof" >&2
    exit 1
  }
done
echo "live_rest_cmp=identical" >>"$evidence/codex-rest-after.txt"

echo "run-proof-codex-rest: pick ok id=$id; rest cleared in temp state; live rest untouched" | tee "$evidence/summary.txt"
cat "$evidence/codex-rest-before.txt" "$evidence/codex-rest-after.txt"
cat >"$evidence/steps.json" <<J
{"target":{"version":"claude-accounts-pick Codex weekly-window rest recovery"},
 "start":"a copy of the live pool Codex reading (null five_hour, seven_day at/above rest floor) and a future-dated rest file under a temp --state dir",
 "steps":["copy live codex-accounts.json and codex-accounts-rested into a disposable state dir","run claude-accounts-pick.test.sh including weekly-only quota window rest cases","run pick codex --json --state <temp> and confirm workers get a pick after rest expiry is 0 for recovered accounts","cmp live rested files to the pre-pick snapshot"],
 "result":"pick ok id=$id; temp rest cleared; live rest untouched; fixture test passed"}
J
