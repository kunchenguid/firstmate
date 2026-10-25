#!/usr/bin/env bash
# claude-accounts: run the quota reader against a fixture muxr registry and a stub quota-axi.
# Journey: two Claude accounts read, one failing account recorded with its cause, the stub sees
# only each profile folder in CLAUDE_CONFIG_DIR, and the output never carries a secret field.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/state" "$w/bin" "$w/a1" "$w/a2" "$w/a3"
cat > "$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"found-codex","provider":"codex","name":"","folder":"$w/codex"},
 {"id":"found-claude","provider":"claude","name":"","folder":"$w/a1"},
 {"id":"pa_two","provider":"claude","name":"Two","folder":"$w/a2","token":"SECRET-NOT-FOR-OUTPUT"},
 {"id":"pa_three","provider":"claude","name":"Three","folder":"$w/a3"}]}
R
cat > "$w/bin/quota-axi" <<'S'
#!/usr/bin/env bash
if [ -f "$QDIR/full" ]; then
  echo '{"providers":[{"windows":[{"id":"five_hour","percentRemaining":100},{"id":"seven_day","percentRemaining":100}]}]}'; exit 0
fi
case "$CLAUDE_CONFIG_DIR" in
*/codex) echo '{"providers":[{"provider":"codex","windows":[{"id":"five_hour","percentRemaining":60},{"id":"weekly","percentRemaining":10}]}]}' ;;
*/a1) [ ! -e "$QDIR/rate-limit" ] || { echo '{"providers":[{"windows":[],"state":{"error":"Claude quota endpoint rate limited"}}]}'; exit 1; }
  echo '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentRemaining":63,"resetsAt":"2026-10-21T08:00:00+00:00"},{"id":"seven_day","percentRemaining":34,"resetsAt":"2026-10-26T12:00:00+00:00"},{"id":"model:fable","percentRemaining":100}]}]}' ;;
*/a2) echo '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentRemaining":100},{"id":"seven_day","percentRemaining":69,"resetsAt":"2026-10-22T07:00:00+00:00"}]}]}' ;;
*) echo "error: not signed in" >&2; exit 2 ;;
esac
S
chmod +x "$w/bin/quota-axi"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
run() { out=$(env -i QDIR="$w" PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" FM_HOME="$w/home" FM_ACCOUNTS_PROVIDER="${PROVIDER:-claude}" FM_CLAUDE_ACCOUNTS_REGISTRY="${REG:-$w/registry.json}" bash "$here/../bin/claude-accounts-quota.sh" "$@" 2>&1); rc=$?; }
f=$w/home/state/claude-accounts.json

run --print
is "two good accounts and one failing: still exit 0" "$rc" 0
is "stdout is the file" "$out" "$(cat "$f")"
is "claude accounts only, in registry order" "$(jq -r '[.accounts[].id]|join(",")' "$f")" "found-claude,pa_two,pa_three"
is "an unnamed account is called default" "$(jq -r '.accounts[0].name' "$f")" default
is "5h and 7d left per account" "$(jq -r '.accounts[]|select(.problem==null)|"\(.five_hour.left)/\(.seven_day.left)"' "$f" | paste -sd,)" "63/34,100/69"
is "a failing account carries its cause" "$(jq -r '.accounts[2].problem' "$f")" "error: not signed in"
is "no secret field reaches the file" "$(grep -c 'SECRET-NOT-FOR-OUTPUT\|token' "$f")" 0

touch "$w/rate-limit"; run
is "a rate-limited account keeps its last good windows, marked stale, with the vendor's cause" "$(jq -r '.accounts[0]|"\(.five_hour.left)/\(.seven_day.left) \(.stale) \(.problem)"' "$f")" "63/34 true Claude quota endpoint rate limited"
rm "$w/rate-limit"; run
is "the next good read clears the stale mark" "$(jq -r '.accounts[0].stale' "$f")" false

printf '%s\n' '{"accounts":[{"id":"x","provider":"claude","name":"X","folder":"'"$w/a3"'"}]}' > "$w/only-bad.json"
REG=$w/only-bad.json run
is "every account failing: exit non-zero, cause recorded" "$rc|$(jq -r '.accounts[0].problem' "$f")" "1|error: not signed in"
REG=$w/missing.json run
is "missing registry: named error" "$rc|${out%%:*}" "1|error"

mkdir -p "$w/home/state/claude-accounts-rested"
printf '%s\n' "$(($(date +%s) + 3600))" > "$w/home/state/claude-accounts-rested/found-claude"
run
is "quota view exposes an active rest for the dashboard" "$(jq -r '.accounts[0].rested_until > now' "$f")" true
touch "$w/full"; run
is "100/100 headroom is never displayed as rested" "$(jq -r 'all(.accounts[]; .rested_until == null)' "$f")" true
mv "$w/full" "$w/full-used"
PROVIDER=codex run --print
is "Codex reads only its roster and normalizes its weekly window" "$rc|$(jq -r '.accounts[] | "\(.id) \(.five_hour.left)/\(.seven_day.left)"' "$w/home/state/codex-accounts.json")" "0|found-codex 60/10"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
