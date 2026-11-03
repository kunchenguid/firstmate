#!/usr/bin/env bash
# Real Treehouse regression: crash a plain-get owner holding a detached commit,
# then acquire again and prove its copy survives. Lease takeover also survives
# ordinary shell exit and prune, until an explicit return releases the copy.
# A recorded unleased copy on a pool root reached through a symlink stays protected
# when bin/fm-spawn.sh acquires another copy.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
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
# The committed root keeps every Treehouse command in this scratch directory.
printf 'root = "%s"\n' "$TREEHOUSE_ROOT" > "$PROJECT/treehouse.toml"
git -C "$PROJECT" add treehouse.toml
git -C "$PROJECT" commit -qm pool-config
export FM_TREEHOUSE_TEST_BIN="$TREEHOUSE" FM_TREEHOUSE_TEST_RECORD="$TMP_ROOT/record"
cat > "$TMP_ROOT/worker-shell" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'paused scout only copy\n' > paused-scout.txt
git add paused-scout.txt
git commit -qm paused-scout
"$FM_TREEHOUSE_TEST_BIN" lease "$(basename "$(dirname "$PWD")")" --lease-holder paused-scout > "$FM_TREEHOUSE_TEST_RECORD.lease"
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
trap 'cleanup_owner; fm_test_cleanup' EXIT
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

# Treehouse reports a symlinked root unresolved, so the spawn's recorded-copy
# protection must match that row against the record's resolved path.
LINKED_ROOT="$TMP_ROOT/linked-pools"
LINKED_PROJECT="$TMP_ROOT/linked-project"
LINKED_HOME="$TMP_ROOT/linked-home"
LINKED_ID=linked-root-spawn
mkdir -p "$TMP_ROOT/real-pools" "$LINKED_HOME/state" "$LINKED_HOME/data/$LINKED_ID" "$LINKED_HOME/config"
ln -s "$TMP_ROOT/real-pools" "$LINKED_ROOT"
git init --quiet -b main "$LINKED_PROJECT"
printf 'root = "%s"\n' "$LINKED_ROOT" > "$LINKED_PROJECT/treehouse.toml"
git -C "$LINKED_PROJECT" add treehouse.toml
git -C "$LINKED_PROJECT" commit -qm pool-config
linked_treehouse() { (cd "$LINKED_PROJECT" && TREEHOUSE_ROOT="$LINKED_ROOT" "$TREEHOUSE" "$@"); }
RECORDED_WT=$(linked_treehouse get --lease --lease-holder setup) || fail 'recorded copy acquisition failed'
ACQUIRED_WT=$(linked_treehouse get --lease --lease-holder setup) || fail 'second copy acquisition failed'
linked_treehouse return --force "$RECORDED_WT" || fail 'recorded copy setup return failed'
linked_treehouse return --force "$ACQUIRED_WT" || fail 'second copy setup return failed'
[ "$(linked_treehouse status --json | jq -r --arg name "$(basename "$(dirname "$RECORDED_WT")")" '.[] | select(.name == $name) | .path')" != \
  "$(CDPATH='' cd -- "$RECORDED_WT" && pwd -P)" ] || fail 'Treehouse status resolved the symlinked root, so this case proves nothing'
printf 'kind=scout\nworktree=%s\nproject=%s\n' "$RECORDED_WT" "$LINKED_PROJECT" > "$LINKED_HOME/state/paused-scout.meta"
printf 'codex\n' > "$LINKED_HOME/config/crew-harness"
fm_test_spawn_brief "$LINKED_HOME" "$LINKED_ID"
touch "$LINKED_HOME/state/.last-watcher-beat"
LINKED_FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/linked-fake")
ln -sf "$TREEHOUSE" "$LINKED_FAKEBIN/treehouse"
LINKED_OUT=$(TREEHOUSE_ROOT="$LINKED_ROOT" fm_test_run_spawn "$LINKED_HOME" "$ACQUIRED_WT" "$LINKED_FAKEBIN" "$LINKED_ID" "$LINKED_PROJECT" --scout)
expect_code 0 "$?" "spawn should accept a recorded copy on a symlinked pool root"$'\n'"$LINKED_OUT"
linked_holder() { linked_treehouse status --json | jq -r --arg name "$(basename "$(dirname "$1")")" '.[] | select(.name == $name) | .lease_holder'; }
[ "$(linked_holder "$RECORDED_WT")" = paused-scout ] || fail 'spawn did not lease the recorded copy to its paused task'
[ "$(linked_holder "$ACQUIRED_WT")" = "$LINKED_ID" ] || fail 'spawn did not lease its acquired copy'
pass 'spawn protects a recorded copy whose pool root is reached through a symlink'
