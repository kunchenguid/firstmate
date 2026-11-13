#!/usr/bin/env bash
# Exercise up's mate readiness path with both supervision-host settings.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo 'ok - skipped: tmux is not installed'; exit 0; }
# shellcheck disable=SC2119 # No bases: the gate checks the real default ones.
fm_tmux_isolation_gate
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
# An older revision's bare Treehouse acquisition uses the environment root.
mkdir -p "${TREEHOUSE_ROOT:-$HOME/.treehouse}/legacy-slot"
# The lab's explicit socket, never TMUX_TMPDIR alone, which falls back to the
# user's default server when its directory is missing.
lab_tmux() { tmux -S "${TMUX_TMPDIR:?}/tmux-$(id -u)/default" "$@"; }
lab_tmux new-window -d -t firstmate: -n "fm-$1" -c "$FM_HOME/../mate" 'exec sleep 45' || exit 1
pid=$(lab_tmux display-message -p -t "firstmate:=fm-$1" '#{pane_pid}')
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
git -C "$TMP_ROOT/source" tag legacy

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
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" SHELL=/bin/sh "$ROOT/bin/fm-live-lab.sh" up --harness claude --mate --supervision-host "$host" --source "$TMP_ROOT/source" --ref legacy --timeout 0 "$lab" 2>&1)
  rc=$?
  expect_code 1 "$rc" "unanswered probe leaves the $mode mate lab for inspection"
  assert_not_contains "$out" 'HOST_OFF: unbound variable' "up $mode sets mate readiness state"
  assert_contains "$out" 'ok mate:' "up $mode checks the launched mate"
  assert_contains "$out" 'primary: claude' "up $mode reaches primary launch"
  assert_present "$lab/treehouse/legacy-slot" "an older --ref uses the lab's private Treehouse pool"
  assert_absent "$HOME/.treehouse/legacy-slot" "an older --ref leaves the operator's pool unchanged"
  if [ "$mode" = off ]; then
    assert_present "$lab/mate/config/supervision-host-off" "off mate receives inherited opt-out"
  else
    assert_absent "$lab/mate/config/supervision-host-off" "on mate has no opt-out"
  fi
  pass "up --mate with supervision host $mode reaches readiness"
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1)
  expect_code 0 "$?" "down cleans the older revision's lab: $out"
  assert_absent "$lab" "down removes the older revision's pool with its lab"
done
