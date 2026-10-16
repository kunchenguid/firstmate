#!/usr/bin/env bash
# Exercise up's mate readiness path with both supervision-host settings.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo 'ok - skipped: tmux is not installed'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-live-up-mate)
export HOME="$TMP_ROOT/user"
mkdir -p "$HOME/.pi/agent" "$HOME/.treehouse" "$TMP_ROOT/source/bin" "$TMP_ROOT/fakebin"
printf '{}\n' > "$HOME/.pi/agent/trust.json"
unset CLAUDE_CONFIG_DIR TMUX

# A source checkout with a stubbed mate launch: it creates the same observable
# mate window/lock and opt-out material, without contacting a model.
cp -R "$ROOT/bin/." "$TMP_ROOT/source/bin/"
cp "$ROOT/AGENTS.md" "$TMP_ROOT/source/AGENTS.md"
cat > "$TMP_ROOT/source/bin/fm-home-seed.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$2/state" "$2/config" "$2/bin"
cp "$FM_HOME/bin/fm-supervision-engine-lib.sh" "$2/bin/"
if [ -f "$FM_HOME/config/supervision-host-off" ]; then
  : > "$2/config/supervision-host-off"
fi
SH
cat > "$TMP_ROOT/source/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
tmux new-window -d -t firstmate: -n "fm-$1" -c "$FM_HOME/../mate" 'exec sleep 45' || exit 1
pid=$(tmux display-message -p -t "firstmate:=fm-$1" '#{pane_pid}')
printf '%s\n' "$pid" > "$FM_HOME/../mate/state/.lock"
printf 'window=firstmate:fm-%s\n' "$1" > "$FM_HOME/state/$1.meta"
SH
cat > "$TMP_ROOT/fakebin/claude" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45
SH
chmod +x "$TMP_ROOT/source/bin/"{fm-home-seed,fm-spawn}.sh "$TMP_ROOT/fakebin/claude"
git -C "$TMP_ROOT/source" init -q -b main
git -C "$TMP_ROOT/source" add -A
git -C "$TMP_ROOT/source" -c user.name=t -c user.email=t@example.invalid commit -qm stub
# The worker block below re-stubs the spawn in its own checkout and leaves
# fm-brief.sh, fm-tasks-axi.sh, and the project seeding real.
cp -R "$TMP_ROOT/source" "$TMP_ROOT/source-worker"

cleanup_labs() {
  local root
  for root in "$TMP_ROOT"/lab-*; do
    [ -f "$root/.fm-live-lab" ] || continue
    PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$root" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_labs EXIT

for mode in off on; do
  lab="$TMP_ROOT/lab-$mode"
  host=claude
  [ "$mode" = off ] && host=off
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" SHELL=/bin/sh "$ROOT/bin/fm-live-lab.sh" up --harness claude --mate --supervision-host "$host" --source "$TMP_ROOT/source" --timeout 0 "$lab" 2>&1)
  rc=$?
  expect_code 1 "$rc" "unanswered probe leaves the $mode mate lab for inspection"
  assert_not_contains "$out" 'HOST_OFF: unbound variable' "up $mode sets mate readiness state"
  assert_contains "$out" 'ok mate:' "up $mode checks the launched mate"
  assert_contains "$out" 'primary: claude' "up $mode reaches primary launch"
  if [ "$mode" = off ]; then
    assert_present "$lab/mate/config/supervision-host-off" "off mate receives inherited opt-out"
  else
    assert_absent "$lab/mate/config/supervision-host-off" "on mate has no opt-out"
  fi
  pass "up --mate with supervision host $mode reaches readiness"
done

# A gated-worker lab: the real project seeding runs, with only the worker
# launch stubbed. Treehouse resolves its pool root from a treehouse.toml inside
# the repo and never from TREEHOUSE_ROOT (v2.0.1 has no such variable), so up
# must wire that config into the lab home and the lab project; a lab copy that
# lands anywhere else is this test's failure, because the default root is $HOME
# and HOME here is the test user's real-feeling home treehouse.
cat > "$TMP_ROOT/source-worker/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
# Stubbed worker launch: the same observable window, metadata, and parked
# status as a real gated worker, without contacting a model. kind=secondmate
# is the suite's fixture convention (make_lab uses it too): it routes
# crew-state to the status log instead of harness busy detection a sleep pane
# cannot answer.
tmux new-window -d -t firstmate: -n "fm-$1" -c "$2" 'exec sleep 45' || exit 1
pid=$(tmux display-message -p -t "firstmate:=fm-$1" '#{pane_pid}')
printf 'window=firstmate:fm-%s\nworktree=%s\nkind=secondmate\ntasktmp=/tmp/fm-%s\n' "$1" "$2" "$1" > "$FM_HOME/state/$1.meta"
printf 'paused [at=1]: waiting on gate file %s to exist\n' "$FM_HOME/data/$1/gate" > "$FM_HOME/state/$1.status"
SH
chmod +x "$TMP_ROOT/source-worker/bin/fm-spawn.sh"
git -C "$TMP_ROOT/source-worker" add -A
git -C "$TMP_ROOT/source-worker" -c user.name=t -c user.email=t@example.invalid commit -qm 'worker spawn stub'

wlab="$TMP_ROOT/lab-worker"
home_treehouse_before=$(find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
out=$(PATH="$TMP_ROOT/fakebin:$PATH" SHELL=/bin/sh "$ROOT/bin/fm-live-lab.sh" up --harness claude --worker --model claude-haiku-5-5 --supervision-host none --expect-host no --timeout 0 --source "$TMP_ROOT/source-worker" "$wlab" 2>&1)
rc=$?
expect_code 1 "$rc" "unanswered probe leaves the worker lab for inspection"
assert_contains "$out" 'ok worker:' "up checks the launched gated worker"
assert_contains "$out" 'ok treehouse:' "up sees no home treehouse growth"
assert_contains "$(cat "$wlab/home/treehouse.toml")" "root = \"$wlab/treehouse\"" "up wires the lab home's treehouse root"
assert_contains "$(cat "$wlab/home/projects/notes/treehouse.toml")" "root = \"$wlab/treehouse\"" "up wires the lab project's treehouse root"
if command -v treehouse >/dev/null 2>&1; then
  allocated=$(cd "$wlab/home/projects/notes" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease --lease-holder "labt$$-worker-probe" 2>/dev/null)
  case "$allocated" in
    "$wlab/treehouse/"*) ;;
    *) fail "lab copy landed outside the lab treehouse root: ${allocated:-none}" ;;
  esac
  home_treehouse_after=$(find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
  [ "$home_treehouse_after" = "$home_treehouse_before" ] \
    || fail "the lab copy leaked into the home treehouse: $(comm -13 <(printf '%s\n' "$home_treehouse_before") <(printf '%s\n' "$home_treehouse_after") | tr '\n' ' ')"
  pass "lab treehouse copy allocates under the lab root only"
else
  echo "ok - treehouse not installed; the allocation probe is capability-skipped"
fi
pass "up --worker keeps every copy under the lab treehouse root"
