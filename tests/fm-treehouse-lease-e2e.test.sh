#!/usr/bin/env bash
# Real Treehouse regression: crash a plain-get owner holding a detached commit,
# then acquire again and prove its copy survives. Lease takeover also survives
# ordinary shell exit and prune, until an explicit return releases the copy.
# FM_TREEHOUSE_TEST_LEASE=0 reproduces the old, unprotected acquisition on v2.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_TEST_TREEHOUSE_LEASE,FM_LIVE treehouse || exit $?
fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease)
TREEHOUSE=$(command -v treehouse)
export HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
mkdir -p "$HOME" "$TMP_ROOT/project"
export TREEHOUSE_ROOT="$TMP_ROOT/pools"
PROJECT="$TMP_ROOT/project"
git init --quiet -b main "$PROJECT"
printf 'base\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm base
# The pool root is explicit even for v2, which predates TREEHOUSE_ROOT.
printf 'root = "%s"\n' "$TREEHOUSE_ROOT" > "$PROJECT/treehouse.toml"
git -C "$PROJECT" add treehouse.toml
git -C "$PROJECT" commit -qm pool-config
export FM_TREEHOUSE_TEST_BIN="$TREEHOUSE" FM_TREEHOUSE_TEST_RECORD="$TMP_ROOT/record"
export FM_TREEHOUSE_TEST_LEASE="${FM_TREEHOUSE_TEST_LEASE:-1}"
cat > "$TMP_ROOT/worker-shell" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'paused scout only copy\n' > paused-scout.txt
git add paused-scout.txt
git commit -qm paused-scout
if [ "$FM_TREEHOUSE_TEST_LEASE" = 1 ]; then
  "$FM_TREEHOUSE_TEST_BIN" lease "$(basename "$(dirname "$PWD")")" --lease-holder paused-scout > "$FM_TREEHOUSE_TEST_RECORD.lease"
fi
printf '%s\n%s\n%s\n' "$PWD" "$(git rev-parse HEAD)" "$$" > "$FM_TREEHOUSE_TEST_RECORD"
if [ "${FM_TREEHOUSE_TEST_EXIT:-0}" = 1 ]; then exit 0; fi
while :; do sleep 0.1; done
SH
chmod +x "$TMP_ROOT/worker-shell"
OWNER_PID=
SHELL_PID=
cleanup_owner() {
  # Only the exact child PIDs this test launched, never a text-pattern kill.
  [ -z "$OWNER_PID" ] || kill -KILL "$OWNER_PID" 2>/dev/null || true
  [ -z "$SHELL_PID" ] || kill -KILL "$SHELL_PID" 2>/dev/null || true
  [ -z "$OWNER_PID" ] || wait "$OWNER_PID" 2>/dev/null || true
}
# fm_test_tmproot owns fixture removal; run PID cleanup first on failure.
trap 'cleanup_owner; rm -rf "$TMP_ROOT"' EXIT
(cd "$PROJECT" && SHELL="$TMP_ROOT/worker-shell" exec "$TREEHOUSE" get) > "$TMP_ROOT/get.log" 2>&1 &
OWNER_PID=$!
for _ in $(seq 1 300); do
  [ ! -s "$FM_TREEHOUSE_TEST_RECORD" ] || break
  kill -0 "$OWNER_PID" 2>/dev/null || { cat "$TMP_ROOT/get.log"; fail 'plain get exited before recording the detached commit'; }
  sleep 0.1
done
[ -s "$FM_TREEHOUSE_TEST_RECORD" ] || fail 'plain get did not enter its isolated copy'
WT=$(sed -n '1p' "$FM_TREEHOUSE_TEST_RECORD")
BEFORE=$(sed -n '2p' "$FM_TREEHOUSE_TEST_RECORD")
SHELL_PID=$(sed -n '3p' "$FM_TREEHOUSE_TEST_RECORD")
cleanup_owner
OWNER_PID=''
SHELL_PID=''
RETRY=$(cd "$PROJECT" && "$TREEHOUSE" get --lease --lease-holder retry) || fail 'retry acquisition failed'
printf '# %s: paused=%s retry=%s before=%s after=%s\n' \
  "$("$TREEHOUSE" --version)" "$WT" "$RETRY" "$BEFORE" "$(git -C "$WT" rev-parse HEAD)"
[ "$RETRY" != "$WT" ] || fail 'retry reused the dead owner detached commit copy'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'retry reset the detached commit'
assert_grep 'paused scout only copy' "$WT/paused-scout.txt" 'retry removed the paused file'
(cd "$PROJECT" && "$TREEHOUSE" prune) || fail 'prune failed'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'prune touched the leased copy'
pass 'real Treehouse keeps the crashed owner copy and detached commit on retry and prune'
[ "$FM_TREEHOUSE_TEST_LEASE" != 0 ] || exit 0
# Ordinary shell exit must not return or reset a slot after lease takeover.
FM_TREEHOUSE_TEST_EXIT=1 SHELL="$TMP_ROOT/worker-shell" \
  bash -c 'cd "$1" && exec "$2" get' _ "$PROJECT" "$TREEHOUSE" > "$TMP_ROOT/exit.log" 2>&1 \
  || { cat "$TMP_ROOT/exit.log"; fail 'ordinary shell exit failed'; }
EXIT_WT=$(sed -n '1p' "$FM_TREEHOUSE_TEST_RECORD")
EXIT_HEAD=$(sed -n '2p' "$FM_TREEHOUSE_TEST_RECORD")
assert_contains "$(cat "$TMP_ROOT/exit.log")" 'Not returning' 'shell exit did not preserve lease takeover'
[ "$(git -C "$EXIT_WT" rev-parse HEAD)" = "$EXIT_HEAD" ] || fail 'shell exit reset the leased copy'
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf '# Ordinary shell exit\n'; cat "$TMP_ROOT/exit.log"
  printf 'Exited worker copy=%s HEAD=%s\n' "$EXIT_WT" "$EXIT_HEAD"
  printf '$ treehouse status --json\n'
  (cd "$PROJECT" && "$TREEHOUSE" status --json) || fail 'status failed'
  printf '$ treehouse return --force %s\n' "$WT"
fi
(cd "$PROJECT" && "$TREEHOUSE" return --force "$WT") || fail 'explicit return failed'
[ "$(git -C "$WT" rev-parse HEAD)" != "$BEFORE" ] || fail 'explicit return did not release and reset its copy'
[ "$(git -C "$EXIT_WT" rev-parse HEAD)" = "$EXIT_HEAD" ] || fail 'return touched a different leased copy'
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf 'Explicitly returned copy HEAD before=%s after=%s\n' "$BEFORE" "$(git -C "$WT" rev-parse HEAD)"
  printf 'Other leased copy HEAD before=%s after=%s\n' "$EXIT_HEAD" "$(git -C "$EXIT_WT" rev-parse HEAD)"
fi
pass 'lease takeover survives shell exit and only explicit return resets its copy'
