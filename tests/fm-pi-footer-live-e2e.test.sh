#!/usr/bin/env bash
# Opt-in live guard for the Ollama reserve segment on a Pi worker's footer.
#
# Only Pi decides where a status entry lands, so the guarantee that
# ctx.ui.setStatus APPENDS a line rather than replacing Pi's own footer cannot
# be proven by a stub: a stub would only confirm the assumption written into it.
# This launches the REAL Pi against the extension bin/fm-spawn.sh actually
# generates and reads the rendered footer back.
#
# It needs no credentials - the footer renders offline - so it is cheap to run
# after every Pi upgrade. Dated results live in
# docs/verification/runtime-backends.md under "Pi worker footer".
set -u

if [ "${FM_PI_FOOTER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_FOOTER_LIVE_E2E=1 to run the live Pi footer guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# An absent harness is reported, never passed over silently: a guard that
# checked nothing must not look like a guard that passed.
command -v pi >/dev/null 2>&1 || fail "pi is not installed, so the live Pi footer guard verified nothing"
command -v tmux >/dev/null 2>&1 || fail "tmux is not installed, so the live Pi footer guard verified nothing"

PI_VERSION=$(pi --version 2>/dev/null || true)
[ -n "$PI_VERSION" ] || fail "could not determine the installed Pi version"

TMP_ROOT=$(fm_test_tmproot fm-pi-footer-live)
SOCKET="fm-pi-footer-$$"
SPAWN="$ROOT/bin/fm-spawn.sh"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# generate_ext <name> <id>: run the REAL fm-spawn for a Pi ship task against a
# fake pane, and print "<home>|<worktree>|<ext-path>".
generate_ext() {
  local name=$1 id=$2 case_dir home proj wt fakebin out
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$case_dir/tmux.src" <<'TMUXSH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
TMUXSH
  install -m 0755 "$case_dir/tmux.src" "$fakebin/tmux"
  # A fake pi only stands in for the LAUNCH; the real binary renders the footer
  # further down.
  fm_fake_exit0 "$fakebin" treehouse pi
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'pi\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "pi spawn for $name failed on Pi $PI_VERSION: $out"
  printf '%s|%s|%s\n' "$home" "$wt" "$home/state/$id.pi-ext.ts"
}

# render_footer <worktree> <ext> <capture-file>: run the real Pi with the
# generated extension until the footer settles, then store the pane.
render_footer() {
  local wt=$1 ext=$2 capture=$3 config attempt
  config="$TMP_ROOT/pi-config"
  mkdir -p "$config"
  tmux -L "$SOCKET" kill-session -t footer 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s footer -x 180 -y 40 \
    "cd '$wt' && env PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 pi --approve \
      --no-context-files --no-skills --no-prompt-templates --no-extensions \
      -e '$ext'; sleep 120"
  attempt=0
  while [ "$attempt" -lt 200 ]; do
    tmux -L "$SOCKET" capture-pane -p -t footer >"$capture" 2>/dev/null || true
    grep -q 'olla' "$capture" 2>/dev/null && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
  fail "Pi $PI_VERSION never rendered the reserve segment: $(tr '\n' '|' <"$capture")"
}

test_reserve_appends_below_pi_own_footer_segments() {
  local rec home wt ext capture pane branch
  rec=$(generate_ext appends olla-live-fresh)
  home=${rec%%|*}
  wt=$(printf '%s' "$rec" | cut -d'|' -f2)
  ext=${rec##*|}
  python3 - "$home/state/ollama-usage.json" <<'PY'
import json, sys, time
with open(sys.argv[1], "w") as handle:
    json.dump({
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session_free": 0.851,
        "weekly_free": 0.924,
    }, handle)
PY

  capture="$TMP_ROOT/fresh.pane"
  render_footer "$wt" "$ext" "$capture"
  pane=$(cat "$capture")

  # The reserve is present AND every segment Pi renders itself survived, which
  # is the whole point: the segment is added, never a rewritten footer.
  assert_contains "$pane" "olla 85%" \
    "Pi $PI_VERSION did not render the reserve read from the probe"
  assert_contains "$pane" "$(basename "$wt")" \
    "Pi $PI_VERSION lost its working-directory footer segment"
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  assert_contains "$pane" "$branch" \
    "Pi $PI_VERSION lost its branch footer segment"
  # The context ceiling itself is model-dependent and this pane runs with no
  # model, so assert the "consumed/ceiling" shape Pi always renders rather than
  # a particular ceiling. That same line carries the tokens and the right-
  # aligned model, so its survival covers all three.
  assert_contains "$pane" "%/" \
    "Pi $PI_VERSION lost its context footer segment"

  # Pi appends extension statuses BELOW its own lines; if a release ever made
  # setStatus replace the footer, the reserve would be the last line with
  # nothing above it.
  local reserve_line context_line
  reserve_line=$(printf '%s\n' "$pane" | grep -n 'olla 85%' | tail -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$pane" | grep -n '%/' | grep -v 'olla' | tail -1 | cut -d: -f1)
  [ -n "$reserve_line" ] && [ -n "$context_line" ] \
    || fail "Pi $PI_VERSION rendered an unreadable footer: $(tr '\n' '|' <"$capture")"
  [ "$reserve_line" -gt "$context_line" ] \
    || fail "Pi $PI_VERSION no longer appends status entries below its own footer lines"
  pass "Pi $PI_VERSION appends the reserve below its own footer segments and keeps all of them"
}

test_untrustworthy_reserve_renders_as_unknown_in_a_live_pane() {
  local rec home wt ext capture pane
  rec=$(generate_ext unknown olla-live-unknown)
  home=${rec%%|*}
  wt=$(printf '%s' "$rec" | cut -d'|' -f2)
  ext=${rec##*|}
  assert_absent "$home/state/ollama-usage.json" "the live unknown case must start with no probe file"

  capture="$TMP_ROOT/absent.pane"
  render_footer "$wt" "$ext" "$capture"
  pane=$(cat "$capture")
  assert_contains "$pane" "olla ?" \
    "Pi $PI_VERSION did not render an explicit unknown for an absent probe file"

  # Three hours old: well past the shelf life, with the probe's own field shape.
  python3 - "$home/state/ollama-usage.json" <<'PY'
import json, sys, time
with open(sys.argv[1], "w") as handle:
    json.dump({
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 10800)),
        "session_free": 0.851,
        "weekly_free": 0.924,
    }, handle)
PY
  capture="$TMP_ROOT/stale.pane"
  render_footer "$wt" "$ext" "$capture"
  pane=$(cat "$capture")
  assert_contains "$pane" "olla ?" \
    "Pi $PI_VERSION did not render an explicit unknown for a stale probe reading"
  assert_not_contains "$pane" "olla 85%" \
    "Pi $PI_VERSION presented a stale reserve reading as current"
  pass "Pi $PI_VERSION renders an absent or stale reserve as an explicit unknown"
}

test_reserve_appends_below_pi_own_footer_segments
test_untrustworthy_reserve_renders_as_unknown_in_a_live_pane

echo "all fm-pi-footer-live-e2e tests passed (Pi $PI_VERSION)"
