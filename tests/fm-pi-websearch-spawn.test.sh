#!/usr/bin/env bash
# tests/fm-pi-websearch-spawn.test.sh - who actually gets a web_search tool.
#
# Exposure is the whole cost control for this feature: every search spends
# metered quota, and only a scout has questions the repository cannot answer.
# Wiring the tool takes the captain's opt-in flag (config/pi-scout-websearch)
# on top of a usable key, because the key file predates this feature and its
# presence is a credential, not consent to spend. These cases drive the real
# bin/fm-spawn.sh against fake panes and a real worktree, and read the launch
# command it composes, so the scout-only rule and the consent rule are both
# enforced by a test rather than by a comment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
EXT="$ROOT/bin/fm-pi-websearch-ext.ts"
TMP_ROOT=$(fm_test_tmproot fm-pi-websearch-spawn)
KEY='sk-fixture-KEYVALUE-0123456789abcdef'

assert_present "$EXT" "the Pi web-search extension should exist at $EXT"

# Fake tmux that answers the pane-path query and logs the literal launch text.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # fm-spawn resolves and probes the pi executable before it creates anything.
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --help ] && { printf 'usage: pi [options]\n'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/pi"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# make_case <name> -> home|project|worktree|fakebin|launchlog|id
make_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# run_spawn <key-file-or-empty> <home> <wt> <fakebin> <launchlog> <spawn args...>
run_spawn() {
  local key_file=$1 home=$2 wt=$3 fakebin=$4 launchlog=$5
  shift 5
  : > "$launchlog"
  FM_OLLAMA_CLOUD_ENV="$key_file" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

write_key_file() {
  mkdir -p "$(dirname "$1")"
  printf 'OLLAMA_API_KEY=%s\n' "$KEY" > "$1"
}

KEY_FILE="$TMP_ROOT/ollama-cloud.env"
write_key_file "$KEY_FILE"
ABSENT_KEY="$TMP_ROOT/absent-ollama-cloud.env"

opt_in() {
  : > "$1/config/pi-scout-websearch"
}

# --- a Pi scout on an opted-in home with a key gets the tool -----------------

read_case "$(make_case scout)"
opt_in "$HOME_DIR"
out=$(run_spawn "$KEY_FILE" "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" \
  "$CASE_ID" "$PROJ_DIR" --scout --harness pi)
launch=$(cat "$LAUNCH_LOG")
# The path is shell-quoted into the launch, so match the flag and the resolved
# file rather than a bare concatenation.
grep -Eq -- "-e '?${EXT}'? " "$LAUNCH_LOG" ||
  fail "a Pi scout should launch with the web-search extension: $out"$'\n'"$launch"
assert_contains "$launch" ".pi-ext.ts" "a Pi scout should keep its existing per-task extension"
pass "a Pi scout on an opted-in home with a key launches with web search"

# The credential itself must not ride along into the worker's launch: the whole
# point is that the worker gets a tool, not a key.
assert_not_contains "$launch" "$KEY" "the launch command must never carry the key"
assert_not_contains "$launch" "OLLAMA_API_KEY" "the launch command must not name the key variable"
pass "the worker is launched with a tool, never with the credential"

# --- a key without the opt-in flag wires nothing -----------------------------
#
# The key file predates this feature: homes configured it for usage reporting
# long before scouts could spend through it. Its presence alone must therefore
# never turn the tool on, and the spawn stays silent because nothing the
# captain enabled is missing.

read_case "$(make_case keynoflag)"
out=$(run_spawn "$KEY_FILE" "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" \
  "$CASE_ID" "$PROJ_DIR" --scout --harness pi)
launch=$(cat "$LAUNCH_LOG")
assert_not_contains "$launch" "fm-pi-websearch-ext.ts" \
  "a key configured for usage reporting must not wire the tool without the captain's opt-in: $out"
assert_contains "$launch" ".pi-ext.ts" "the scout should still launch normally"
assert_not_contains "$out" "without web search" \
  "a home that never opted in should not be nagged about the tool"
pass "a key alone never wires web search; the opt-in flag is required"

# --- an implementation worker does not, even on an opted-in home -------------

read_case "$(make_case ship)"
opt_in "$HOME_DIR"
out=$(run_spawn "$KEY_FILE" "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" \
  "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off --harness pi)
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" ".pi-ext.ts" "a Pi ship worker should still get its per-task extension: $out"
assert_not_contains "$launch" "fm-pi-websearch-ext.ts" \
  "a Pi ship worker must not get web search"
pass "a Pi implementation worker launches without web search"

# --- opted in but no key configured means no tool, and no failed spawn -------

read_case "$(make_case nokey)"
opt_in "$HOME_DIR"
out=$(run_spawn "$ABSENT_KEY" "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" \
  "$CASE_ID" "$PROJ_DIR" --scout --harness pi)
launch=$(cat "$LAUNCH_LOG")
assert_not_contains "$launch" "fm-pi-websearch-ext.ts" \
  "a home with no key must not wire the tool: $out"
assert_contains "$launch" ".pi-ext.ts" "the scout should still launch normally"
assert_contains "$out" "without web search" "the spawn should say why the tool is absent"
pass "an opted-in home with no key launches the scout unchanged, and says so"

# --- other harnesses are untouched -------------------------------------------
#
# Claude workers already have their own web search, so wiring this one to them
# would be a duplicate; the placeholder must also never survive into a launch.

read_case "$(make_case claudescout)"
opt_in "$HOME_DIR"
out=$(run_spawn "$KEY_FILE" "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" \
  "$CASE_ID" "$PROJ_DIR" --scout --harness claude)
launch=$(cat "$LAUNCH_LOG")
assert_not_contains "$launch" "fm-pi-websearch-ext.ts" \
  "a Claude scout must not get the Ollama web-search tool: $out"
assert_not_contains "$launch" "__PIWEBSEARCH__" "no launch may carry an unsubstituted placeholder"
pass "a Claude scout is left alone"

printf 'ok - pi web-search spawn exposure\n'
