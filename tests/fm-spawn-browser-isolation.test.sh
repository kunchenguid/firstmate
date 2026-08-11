#!/usr/bin/env bash
# tests/fm-spawn-browser-isolation.test.sh - spawn-path regressions proving every
# firstmate-launched agent receives the browser-isolation environment, using fake
# tmux panes and real isolated git worktrees.
#
# AGENTS.md section 3 points every agent at chrome-devtools-axi and crewmates run
# with permissions bypassed, so the browser that tool reaches is inside the
# agent's blast radius. chrome-devtools-axi's own default is already an isolated
# throwaway profile, but a default is not a guarantee: any CHROME_DEVTOOLS_AXI_*
# value exported into firstmate's environment is inherited by every agent it
# launches, and the unnamed "default" session is one shared bridge. fm-spawn
# therefore pins the isolating choice on the launch command itself.
#
# These tests pin the assembled launch command, which is the interface firstmate
# actually ships to a pane, and the capability gate that decides whether the
# per-task-bridge half of that pin can be honoured at all. The companion guard
# tests/fm-browser-isolation-live-e2e.test.sh proves the two facts a launch string
# cannot show: that the pinned values really select an isolated profile in the
# installed chrome-devtools-axi, and that they survive into the shell a real
# harness gives its agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-browser-isolation)

# fm-spawn's per-task temp root is a fixed /tmp/fm-<id>, outside any fixture dir,
# and the refusal shim now lives inside it. Every id this file spawns therefore
# starts with this prefix so the roots are reclaimable as one namespace at the end.
TASK_ID_PREFIX=browseriso

# The temp root fm-spawn recorded for a task, read back from the task record so a
# test asserts on the directory teardown will actually reclaim rather than on a
# path spelled twice.
task_tmp_root() {  # <home> <task-id>
  sed -n 's/^tasktmp=//p' "$1/state/$2.meta"
}

# The session name through bin/fm-pr-lib.sh, the single owner both fm-spawn and
# fm-teardown call, so a test can compare what a launch actually shipped against
# it instead of restating the derivation.
derive_session_name() {  # <task-id>
  bash -c '. "$1"; fm_task_browser_session "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$1"
}

# The five profile inputs fm-spawn must neutralise, and the value each must carry.
# Written out here rather than derived from bin/fm-spawn.sh so this stays an
# independent pin: a change to the implementation has to be made twice, on purpose.
PINNED_AUTO_CONNECT='CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0'
PINNED_EMPTY_VARS=(
  'CHROME_DEVTOOLS_AXI_BROWSER_URL='
  'CHROME_DEVTOOLS_AXI_USER_DATA_DIR='
  'CHROME_DEVTOOLS_AXI_CHROME_ARGS='
  'CHROME_DEVTOOLS_AXI_PORT='
)

# make_fake_browser_tool <dir> <mode>: a stand-in chrome-devtools-axi whose --help
# either documents CHROME_DEVTOOLS_AXI_SESSION (capable), omits it (too old),
# cannot be read at all (inconclusive), blocks reading stdin, or never returns.
# The last two are not hypothetical shapes: the probe runs on every spawn, so an
# installed build that waits on a caller's terminal or hangs would wedge dispatch
# itself rather than resolve to an outcome. Every invocation that is not --help
# records itself in $FM_FAKE_BROWSER_RAN, so a test can prove the refusal really
# stopped the tool instead of only printing at it.
make_fake_browser_tool() {
  local dir=$1 mode=$2 help_body
  case "$mode" in
    capable) help_body="printf '%s\\n' 'environment:' '  CHROME_DEVTOOLS_AXI_PORT     Bridge port' '  CHROME_DEVTOOLS_AXI_SESSION  Named session for concurrent isolation'; exit 0" ;;
    old) help_body="printf '%s\\n' 'environment:' '  CHROME_DEVTOOLS_AXI_PORT     Bridge port'; exit 0" ;;
    unreadable) help_body="printf '%s\\n' 'chrome-devtools-axi: unrecognised flag --help' >&2; exit 2" ;;
    # Drains stdin BEFORE answering, so it only completes where the probe closed
    # stdin for it; with a caller's stdin inherited it would block indefinitely.
    stdin-reader) help_body="cat >/dev/null; printf '%s\\n' 'environment:' '  CHROME_DEVTOOLS_AXI_SESSION  Named session for concurrent isolation'; exit 0" ;;
    hangs) help_body="sleep 120; exit 0" ;;
    *) fail "make_fake_browser_tool: unknown mode '$mode'" ;;
  esac
  mkdir -p "$dir"
  cat > "$dir/chrome-devtools-axi" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = --help ] && { $help_body; }
[ -n "\${FM_FAKE_BROWSER_RAN:-}" ] && printf '%s\n' "\$*" >> "\$FM_FAKE_BROWSER_RAN"
exit 0
SH
  chmod +x "$dir/chrome-devtools-axi"
}

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# argument, so the launch command firstmate would run is observable without
# starting a harness.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # A capable stand-in shadows whatever chrome-devtools-axi this machine has, so
  # the assertions below describe firstmate rather than the local install.
  make_fake_browser_tool "$fakebin" capable
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
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # pi resolves and probes a concrete executable before composing its template.
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --help ] && printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <harness> <task-id>: build an isolated home, project,
# worktree and fake bin dir, then echo the fields the run helpers need.
make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/$id/brief.md"
  : > "$launchlog"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

read_case_record() {
  local IFS='|'
  read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<< "$1"
}

# The PATH fm-spawn itself runs on. Tests that need a different chrome-devtools-axi
# on it - an older one, an unreadable one, or none at all - set this instead of
# duplicating the whole invocation below.
SPAWN_PATH=

# run_ship_spawn: drive a real fm-spawn ship dispatch through the fake pane.
# Extra arguments are appended to the fm-spawn invocation.
run_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  shift 6
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="${SPAWN_PATH:-$fakebin:$PATH}" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

# A PATH carrying no chrome-devtools-axi at all, for the not-installed branch.
# Filtering the inherited PATH beats hand-building one, which would drop whatever
# git and coreutils this host actually resolves fm-spawn's own calls to.
path_without_browser_tool() {
  local dir out=''
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ -x "$dir/chrome-devtools-axi" ] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s\n' "$out"
}

# The directory fm-spawn put on the agent's PATH ahead of everything else, or an
# empty string when it left PATH alone.
extract_refusal_dir() {
  local launch=$1 rest
  case "$launch" in
    "PATH='"*)
      rest=${launch#PATH=\'}
      printf '%s\n' "${rest%%\'*}"
      ;;
    *) printf '%s\n' '' ;;
  esac
}

# assert_profile_pin_survives <launch> <label>: the half of the guarantee that
# does not depend on the tool version. It must hold even where the per-task
# bridge is refused, because it is what keeps the operator's cookies out of any
# browser the agent does manage to start.
assert_profile_pin_survives() {
  local launch=$1 label=$2 var
  assert_contains "$launch" "$PINNED_AUTO_CONNECT" \
    "$label: launch no longer refuses the attach-to-the-captain's-Chrome mode"
  for var in "${PINNED_EMPTY_VARS[@]}"; do
    case "$launch" in
      *"$var "*) : ;;
      *) fail "$label: launch no longer neutralises $var" ;;
    esac
  done
}

# assert_refusal_actually_refuses <shim-dir> <real-tool-dir> <run-log> <label>:
# invoke the tool exactly as an agent would, with the real one still behind the
# shim on PATH. A refusal that prints and then runs the tool anyway, or that
# exits 0, would reproduce the silent degradation this gate exists to remove.
# The refusal text is published in REFUSAL_OUT rather than echoed, so `fail` here
# aborts the run instead of only exiting a command-substitution subshell.
REFUSAL_OUT=
assert_refusal_actually_refuses() {
  local shim=$1 realdir=$2 ran=$3 label=$4
  : > "$ran"
  REFUSAL_OUT=$(FM_FAKE_BROWSER_RAN="$ran" PATH="$shim:$realdir:$PATH" \
    env chrome-devtools-axi open https://mail.google.com 2>&1) \
    && fail "$label: the refusal exited 0, which an agent reads as a successful page load"
  [ ! -s "$ran" ] \
    || fail "$label: the refusal printed but the browser tool still ran ($(cat "$ran"))"
  assert_contains "$REFUSAL_OUT" 'chrome-devtools-axi' "$label: refusal does not name the tool"
  assert_contains "$REFUSAL_OUT" 'CHROME_DEVTOOLS_AXI_SESSION' \
    "$label: refusal does not name the missing capability"
  assert_contains "$REFUSAL_OUT" 'Still enforced' \
    "$label: refusal does not say which half of the guarantee still holds"
}

# assert_full_pin <launch> <expected-session> <label>: every pinned variable is
# present with its exact value, and the whole block precedes the harness binary.
assert_full_pin() {
  local launch=$1 session=$2 label=$3 var
  assert_contains "$launch" "$PINNED_AUTO_CONNECT" \
    "$label: launch does not refuse chrome-devtools-axi's attach-to-the-captain's-Chrome mode"
  for var in "${PINNED_EMPTY_VARS[@]}"; do
    # A space-or-end boundary distinguishes the pinned empty value from an
    # inherited non-empty one, which would read as "VAR=/some/path".
    case "$launch" in
      *"$var "*) : ;;
      *) fail "$label: launch does not neutralise $var (a non-empty inherited value would select a real profile)" ;;
    esac
  done
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$session'" \
    "$label: launch does not bind this task to its own browser session"
  case "$launch" in
    "CHROME_DEVTOOLS_AXI_"*|*" CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0 "*) : ;;
    *) fail "$label: the pin is not positioned as an environment prefix on the launch command" ;;
  esac
}

test_every_verified_harness_carries_the_pin() {
  local harness rec id launch checked=0
  # muse and kimi resolve a real installed binary before composing a template, so
  # they cannot be driven from a fake bin dir here; the live guard covers them.
  for harness in claude codex opencode grok pi; do
    id="browseriso-$harness-b1"
    rec=$(make_spawn_case "browseriso-$harness" "$harness" "$id")
    read_case_record "$rec"
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
      || fail "$harness spawn failed"
    launch=$(cat "$LAUNCH_LOG")
    assert_full_pin "$launch" "fm-$id" "$harness"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 5 ] || fail "expected 5 harnesses checked, got $checked"
  pass "every verified harness template launches inside the browser-isolation environment"
}

test_raw_launch_command_escape_hatch_carries_the_pin() {
  local rec id launch
  # The escape hatch bypasses launch_template entirely. It is the case a
  # per-template pin would silently miss, so it is pinned explicitly.
  id=browseriso-raw-b2
  rec=$(make_spawn_case browseriso-raw claude "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'some-unverified-agent --flag' >/dev/null || fail "raw launch command spawn failed"
  launch=$(cat "$LAUNCH_LOG")
  assert_full_pin "$launch" "fm-$id" "raw launch command"
  assert_contains "$launch" 'some-unverified-agent --flag' \
    "raw launch command was not preserved"
  pass "the unverified-adapter escape hatch is covered by the same pin"
}

test_each_task_gets_its_own_browser_session() {
  local rec launch_a launch_b id_a=browseriso-sess-a-b3 id_b=browseriso-sess-b-b3
  rec=$(make_spawn_case browseriso-sess-a claude "$id_a")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null \
    || fail "first spawn failed"
  launch_a=$(cat "$LAUNCH_LOG")

  rec=$(make_spawn_case browseriso-sess-b claude "$id_b")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null \
    || fail "second spawn failed"
  launch_b=$(cat "$LAUNCH_LOG")

  assert_contains "$launch_a" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_a'" "first task got the wrong session"
  assert_contains "$launch_b" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_b'" "second task got the wrong session"
  assert_not_contains "$launch_a" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_b'" \
    "two tasks would share one browser, so one could read a page the other authenticated"
  pass "two tasks launch on two separate browser sessions"
}

test_longest_accepted_task_id_still_yields_a_usable_session_name() {
  local rec id launch session
  # chrome-devtools-axi rejects a session name outside 1-64 chars of
  # [A-Za-z0-9._-], and that rejection breaks EVERY browser command for the agent
  # that inherits it. fm_task_id_creation_valid accepts ids up to 64 chars, so the
  # "fm-" prefix is exactly what can push the name out of range.
  id="$TASK_ID_PREFIX-longid-$(printf '%46s' '' | tr ' ' 'b')"
  [ "${#id}" -eq 64 ] || fail "fixture id is ${#id} chars, not the 64-char maximum this case exists to cover"
  rec=$(make_spawn_case browseriso-longid claude "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn with a maximum-length task id failed"
  launch=$(cat "$LAUNCH_LOG")
  session=$(printf '%s\n' "$launch" | sed -n "s/.*CHROME_DEVTOOLS_AXI_SESSION='\([^']*\)'.*/\1/p")
  [ -n "$session" ] || fail "no browser session name in the launch command"
  [ "${#session}" -le 64 ] \
    || fail "session name is ${#session} chars; chrome-devtools-axi refuses over 64 and the agent loses the browser entirely"
  case "$session" in
    fm-*) : ;;
    *) fail "session name '$session' is not recognisable as firstmate's" ;;
  esac
  printf '%s' "$session" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || fail "session name '$session' is outside the charset chrome-devtools-axi accepts"
  # fm-teardown closes this task's bridge by re-deriving the name from the shared
  # owner, so a launch that spelled it any other way would leave the bridge and its
  # headless Chrome running past teardown.
  [ "$session" = "$(derive_session_name "$id")" ] \
    || fail "the launch pinned '$session' but the shared owner derives '$(derive_session_name "$id")'; teardown would aim at a session this task never opened"
  pass "a maximum-length task id still produces a session name the browser tool accepts, and the one teardown will look for"
}

test_session_name_is_unique_and_tool_legal_for_every_accepted_task_id() {
  local id name seen='' prefix
  local -a ids
  # The session name is the ONLY handle teardown has on a task's bridge, so the
  # derivation has to be injective as well as legal: two ids mapping to one name
  # would put two live tasks on one bridge, and tearing either down would close the
  # other's browser and headless Chrome mid-work. Ids sharing a long prefix are
  # exactly what plain truncation collapses, so they lead the list here.
  prefix=$(printf '%61s' '' | tr ' ' 'c')
  ids=(
    "${prefix}aaa"
    "${prefix}aab"
    "${prefix}ab"
    "${prefix}a"
    "$prefix"
    "$(printf '%64s' '' | tr ' ' 'd')"
    "$(printf '%60s' '' | tr ' ' 'e')"
    "$(printf '%61s' '' | tr ' ' 'e')"
    x
    a.b_c-d
    browseriso-plain
  )
  for id in "${ids[@]}"; do
    [ "${#id}" -le 64 ] || fail "fixture id '$id' is longer than fm_task_id_creation_valid accepts"
    name=$(derive_session_name "$id")
    printf '%s' "$name" | grep -Eq '^fm-[A-Za-z0-9._-]{1,61}$' \
      || fail "session name '$name' for id '$id' is outside the 1-64 chars of [A-Za-z0-9._-] chrome-devtools-axi accepts, so every browser command for that agent would be rejected"
    [ "$name" = "$(derive_session_name "$id")" ] \
      || fail "the session name for '$id' is not deterministic, so a later teardown would aim at a name the spawn never opened"
    case "$seen" in
      *"<$name>"*)
        fail "two task ids fm_task_id_creation_valid accepts map to the session name '$name', so two live tasks would share one bridge and tearing either down would close the other's browser"
        ;;
    esac
    seen="$seen<$name>"
  done
  pass "every accepted task id gets a distinct session name inside the charset and length the browser tool accepts"
}

test_secondmate_agents_are_isolated_too() {
  local case_dir home smhome launchlog fakebin id=browseriso-sm-b5 launch out
  # A secondmate is a firstmate instance that also browses, so it needs its own
  # isolated session for the same reason a crewmate does.
  case_dir="$TMP_ROOT/browseriso-sm"
  home="$case_dir/home"
  smhome="$case_dir/smhome"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$smhome/data" "$smhome/state" "$smhome/config" "$smhome/projects" "$smhome/bin"
  printf '%s\n' claude > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  touch "$smhome/AGENTS.md"
  printf '%s\n' 'charter' > "$home/data/$id/brief.md"
  : > "$launchlog"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$smhome" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$smhome" --secondmate 2>&1) \
    || fail "secondmate spawn failed"$'\n'"$out"

  launch=$(cat "$launchlog")
  assert_full_pin "$launch" "fm-$id" "secondmate"
  pass "a secondmate agent launches inside its own browser-isolation environment"
}

# --- capability gate -------------------------------------------------------
#
# The SESSION pin is only a per-task bridge if the installed chrome-devtools-axi
# supports named sessions. A tool that does not ignores the variable and puts the
# agent back on the shared "default" bridge on port 9224 while the launch string
# still looks isolated, so fm-spawn probes for the capability and refuses the tool
# for that agent rather than make a promise it is not keeping.

test_capable_browser_tool_leaves_the_launch_untouched() {
  local rec id launch
  # The normal case must cost nothing: same pinned environment, no PATH rewrite,
  # nothing written to disk.
  id=browseriso-capable-b6
  rec=$(make_spawn_case browseriso-capable claude "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn with a capable browser tool failed"
  launch=$(cat "$LAUNCH_LOG")
  assert_full_pin "$launch" "fm-$id" "capable tool"
  assert_not_contains "$launch" 'PATH=' \
    "a capable browser tool must not have the agent's PATH rewritten"
  [ ! -e "$(task_tmp_root "$HOME_DIR" "$id")/browser-refusal" ] \
    || fail "a capable browser tool left a refusal shim on disk"
  pass "a browser tool that supports named sessions changes nothing about the launch"
}

test_browser_tool_without_named_sessions_is_refused() {
  local rec id launch shim realdir
  id=browseriso-oldtool-b7
  rec=$(make_spawn_case browseriso-oldtool claude "$id")
  read_case_record "$rec"
  realdir="$TMP_ROOT/browseriso-oldtool/oldbin"
  make_fake_browser_tool "$realdir" old
  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn must still succeed when the browser tool is too old; a task that never browses is not this gate's business"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")

  assert_profile_pin_survives "$launch" "too-old tool"
  shim=$(extract_refusal_dir "$launch")
  [ -n "$shim" ] \
    || fail "a browser tool without named sessions produced no refusal, so the agent would attach to the shared default bridge"
  [ -x "$shim/chrome-devtools-axi" ] || fail "refusal directory holds no executable shim"

  assert_refusal_actually_refuses "$shim" "$realdir" "$TMP_ROOT/browseriso-oldtool/ran.log" "too-old tool"
  assert_contains "$REFUSAL_OUT" 'does not support named sessions' \
    "refusal does not diagnose the tool as too old"
  pass "a browser tool without named sessions is refused for the agent instead of silently sharing the default bridge"
}

test_unreadable_browser_tool_help_resolves_toward_refusal() {
  local rec id launch shim realdir
  # An unreadable --help is "could not confirm", never "capable". It is worded
  # apart from the too-old case so an operator can tell the two diagnoses apart,
  # and so a release that stops documenting the variable is diagnosable.
  id=browseriso-unreadable-b8
  rec=$(make_spawn_case browseriso-unreadable claude "$id")
  read_case_record "$rec"
  realdir="$TMP_ROOT/browseriso-unreadable/oddbin"
  make_fake_browser_tool "$realdir" unreadable
  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn must still succeed when the browser tool's help cannot be read"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")

  assert_profile_pin_survives "$launch" "unconfirmed tool"
  shim=$(extract_refusal_dir "$launch")
  [ -n "$shim" ] \
    || fail "an unconfirmed browser tool was treated as capable, which is the silent promise this gate exists to prevent"

  assert_refusal_actually_refuses "$shim" "$realdir" "$TMP_ROOT/browseriso-unreadable/ran.log" "unconfirmed tool"
  assert_contains "$REFUSAL_OUT" 'could not confirm' \
    "refusal does not distinguish 'unconfirmed' from 'too old'"
  assert_not_contains "$REFUSAL_OUT" 'does not support named sessions' \
    "an unconfirmed tool must not be reported as a confirmed-too-old one"
  pass "a browser tool whose capability cannot be confirmed is refused, and says so differently from a too-old one"
}

test_browser_tool_that_reads_stdin_still_resolves() {
  local rec id launch realdir
  # The probe must not hand a third-party executable the caller's stdin. fm-spawn
  # runs it on every dispatch, so a build that drains stdin before answering would
  # otherwise sit on the dispatching terminal forever instead of producing one of
  # the three outcomes.
  id=browseriso-stdin-b10
  rec=$(make_spawn_case browseriso-stdin claude "$id")
  read_case_record "$rec"
  realdir="$TMP_ROOT/browseriso-stdin/stdinbin"
  make_fake_browser_tool "$realdir" stdin-reader
  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn hung or failed against a browser tool whose help reads stdin"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")

  assert_full_pin "$launch" "fm-$id" "stdin-reading tool"
  assert_not_contains "$launch" 'PATH=' \
    "a tool that answered the probe once its stdin was closed must be treated as capable"
  pass "the capability probe closes stdin, so a tool that drains it still resolves instead of wedging the spawn"
}

test_probe_bound_rejects_values_that_are_not_bounds() {
  local bound value
  # `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline, so an
  # override of 0 would silently restore the unbounded hang the bound above exists
  # to remove, on every spawn and every teardown. A non-numeric one fails the
  # runner itself, which reads as unconfirmed and degrades every spawn to the
  # refusal shim with no diagnosis. Asserting on the resolved value keeps this
  # fast and exact rather than waiting out a fallback bound against a hung tool.
  for value in 0 00 -1 '' abc 1.5 ' '; do
    bound=$(FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS="$value" bash -c \
      '. "$1"; printf "%s" "$FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS"' _ "$ROOT/bin/fm-pr-lib.sh") \
      || fail "sourcing fm-pr-lib.sh failed with FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS='$value'"
    [ "$bound" = 10 ] \
      || fail "FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS='$value' resolved to '$bound' instead of the default bound; a value that is not a positive integer must never reach fm_run_timed"
  done
  bound=$(FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS=3 bash -c \
    '. "$1"; printf "%s" "$FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS"' _ "$ROOT/bin/fm-pr-lib.sh")
  [ "$bound" = 3 ] || fail "a legitimate override was discarded (got '$bound' for 3)"
  pass "a probe bound that is not a positive integer falls back to the default instead of disabling the deadline"
}

test_browser_tool_help_that_never_returns_is_refused() {
  local rec id launch shim realdir
  # A hung help is the same diagnosis as an unreadable one - unconfirmed, never
  # capable - and the bound is what makes that outcome reachable at all.
  id=browseriso-hang-b11
  rec=$(make_spawn_case browseriso-hang claude "$id")
  read_case_record "$rec"
  realdir="$TMP_ROOT/browseriso-hang/hangbin"
  make_fake_browser_tool "$realdir" hangs
  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS=2 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "a browser tool whose help never returns wedged the spawn instead of resolving to a refusal"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")

  assert_profile_pin_survives "$launch" "hung tool"
  shim=$(extract_refusal_dir "$launch")
  [ -n "$shim" ] \
    || fail "a browser tool whose capability could not be probed within the bound was treated as capable"
  assert_refusal_actually_refuses "$shim" "$realdir" "$TMP_ROOT/browseriso-hang/ran.log" "hung tool"
  assert_contains "$REFUSAL_OUT" 'could not confirm' \
    "a probe that hit its bound must read as unconfirmed, not as a confirmed-too-old tool"
  pass "a browser tool whose help never returns is bounded and refused rather than wedging dispatch"
}

test_absent_browser_tool_is_left_alone() {
  local rec id launch
  # Nothing installed means nothing to refuse and nothing to run, so the launch
  # must be identical to the capable case rather than carrying an invented error.
  id=browseriso-notool-b9
  rec=$(make_spawn_case browseriso-notool claude "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/chrome-devtools-axi"
  SPAWN_PATH="$FAKEBIN_DIR:$(path_without_browser_tool)"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn failed with no chrome-devtools-axi installed"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")
  assert_full_pin "$launch" "fm-$id" "absent tool"
  assert_not_contains "$launch" 'PATH=' \
    "an absent browser tool must not have the agent's PATH rewritten"
  [ ! -e "$(task_tmp_root "$HOME_DIR" "$id")/browser-refusal" ] \
    || fail "an absent browser tool produced a refusal shim for a tool that cannot be run"
  pass "an uninstalled browser tool is neither refused nor shimmed"
}

test_refusal_shim_is_private_to_the_task_it_was_written_for() {
  local rec realdir launch shim_a shim_b out
  local id_a=browseriso-priv-a-b12 id_b=browseriso-priv-b-b12
  # The refusal directory is prepended to that agent's PATH ahead of every system
  # directory, and agents run same-uid with permissions bypassed. A directory
  # shared by every task in the home would therefore let anything one agent drops
  # there shadow an arbitrary command - git, node, npx - for every later-launched
  # agent that takes this path. Each task gets its own instead.
  realdir="$TMP_ROOT/browseriso-priv/oldbin"
  make_fake_browser_tool "$realdir" old

  rec=$(make_spawn_case browseriso-priv-a claude "$id_a")
  read_case_record "$rec"
  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null \
    || fail "first refused spawn failed"
  launch=$(cat "$LAUNCH_LOG")
  shim_a=$(extract_refusal_dir "$launch")
  [ -n "$shim_a" ] || fail "the first refused spawn put no refusal directory on the agent's PATH"
  # The shim has to sit under the temp root the task recorded, because that root is
  # what teardown removes; anywhere else and the shim outlives the task.
  case "$shim_a" in
    "$(task_tmp_root "$HOME_DIR" "$id_a")"/*) : ;;
    *) fail "the refusal shim at '$shim_a' is outside the temp root task $id_a recorded, so teardown would not reclaim it" ;;
  esac

  rec=$(make_spawn_case browseriso-priv-b claude "$id_b")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null \
    || fail "second refused spawn failed"
  SPAWN_PATH=
  launch=$(cat "$LAUNCH_LOG")
  shim_b=$(extract_refusal_dir "$launch")
  [ -n "$shim_b" ] || fail "the second refused spawn put no refusal directory on the agent's PATH"

  [ "$shim_a" != "$shim_b" ] \
    || fail "two tasks were given the same refusal directory on their PATH, so anything either agent writes into it shadows a command for the other"

  # The concrete consequence, exercised rather than argued: one agent plants a
  # `git` in its own refusal directory, and the other's PATH must not resolve to it.
  printf '%s\n' '#!/bin/sh' 'echo HIJACKED-BY-THE-OTHER-TASK' > "$shim_a/git"
  chmod +x "$shim_a/git"
  [ ! -e "$shim_b/git" ] \
    || fail "a binary planted in one task's refusal directory appeared in another task's"
  out=$(PATH="$shim_b:$PATH" git --version 2>&1) || true
  assert_not_contains "$out" HIJACKED-BY-THE-OTHER-TASK \
    "a binary one agent planted in its refusal directory shadowed git for another task's launch"
  pass "each refused launch gets a refusal directory private to its own task, so one agent cannot shadow another's commands"
}

test_refusal_shim_that_cannot_be_written_refuses_the_spawn() {
  local rec id=browseriso-shimfail-b13 realdir out rc=0 task_tmp
  # The refusal is the whole point of the gate: an agent launched without it
  # silently reaches the shared `default` bridge on port 9224, which is the
  # operator's own. Writing it into the task's temp root is a per-spawn write that
  # can fail, so the spawn must abort loudly rather than launch without it.
  rec=$(make_spawn_case browseriso-shimfail claude "$id")
  read_case_record "$rec"
  realdir="$TMP_ROOT/browseriso-shimfail/oldbin"
  make_fake_browser_tool "$realdir" old
  # Occupy the shim directory's own path with a plain file so it cannot be created.
  task_tmp="/tmp/fm-$id"
  mkdir -p "$task_tmp"
  : > "$task_tmp/browser-refusal"

  SPAWN_PATH="$realdir:$FAKEBIN_DIR:$PATH"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || rc=$?
  SPAWN_PATH=

  [ "$rc" -ne 0 ] \
    || fail "the spawn succeeded although the refusal shim could not be written, so the agent would reach the operator's shared default bridge"
  assert_contains "$out" 'could not write the browser-refusal shim' \
    "the spawn failed without saying the refusal shim was what could not be installed"
  assert_not_contains "$(cat "$LAUNCH_LOG")" CHROME_DEVTOOLS_AXI_SESSION \
    "a launch command was sent to the pane despite the refusal never being installed"
  pass "a refusal shim that cannot be written aborts the spawn instead of launching an unprotected agent"
}

test_every_verified_harness_carries_the_pin
test_raw_launch_command_escape_hatch_carries_the_pin
test_each_task_gets_its_own_browser_session
test_longest_accepted_task_id_still_yields_a_usable_session_name
test_session_name_is_unique_and_tool_legal_for_every_accepted_task_id
test_secondmate_agents_are_isolated_too
test_capable_browser_tool_leaves_the_launch_untouched
test_browser_tool_without_named_sessions_is_refused
test_unreadable_browser_tool_help_resolves_toward_refusal
test_browser_tool_that_reads_stdin_still_resolves
test_probe_bound_rejects_values_that_are_not_bounds
test_browser_tool_help_that_never_returns_is_refused
test_absent_browser_tool_is_left_alone
test_refusal_shim_is_private_to_the_task_it_was_written_for
test_refusal_shim_that_cannot_be_written_refuses_the_spawn

# The per-task temp roots fm-spawn creates live at a fixed /tmp/fm-<id>, outside
# TMP_ROOT, so they are reclaimed here as one prefixed namespace.
rm -rf "/tmp/fm-$TASK_ID_PREFIX"-*
fm_test_cleanup "$TMP_ROOT"
