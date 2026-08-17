#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - adapter tests for the CANDIDATE omp (Oh My Pi)
# crewmate/scout harness wired by bin/fm-spawn.sh, bin/fm-harness.sh,
# bin/fm-busy-lib.sh, and bin/backends/tmux.sh.
#
# Every case here runs the REAL fm-spawn against a fake tmux pane and a STUB
# `omp` executable on PATH. The installed Oh My Pi asset is never executed, no
# provider call, model discovery, prompt, or TUI/RPC session happens, and no
# live omp process is ever created. The stub answers `--version` only, which is
# the single identity probe the adapter performs.
#
# Two of the cases are POLICY MATRICES that report their own row counts rather
# than a bare pass, so a silently shrinking matrix cannot read as green:
#   - the model policy matrix, 12 equivalence classes of rejected model value;
#   - the selection policy matrix, 8 ways omp can be selected or refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# The backend libraries are loaded through the dispatcher, never sourced
# directly: bin/fm-backend.sh is what binds FM_BACKEND_LIB_DIR, which
# bin/backends/tmux.sh needs to resolve its own dependencies.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || { echo "unable to load the tmux backend library" >&2; exit 1; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

# The one release the adapter is pinned to; drift from this must refuse.
OMP_PINNED_VERSION="omp/17.2.9"

# Every omp launch requires an explicit, fully qualified provider/model. This is
# a STRUCTURAL fixture string only: no provider is contacted, no model catalog is
# queried, and the stub executable still refuses to open any session.
OMP_MODEL="anthropic/claude-sonnet-4-5"

make_omp_fakebin() {  # <dir> [omp-version|absent] -> echoes fakebin dir
  local dir=$1 version=${2:-$OMP_PINNED_VERSION} fakebin node_bin
  fakebin=$(fm_fakebin "$dir")
  node_bin=$(command -v node) || fail "the Orca fixture requires node for adapter JSON parsing"
  ln -sf "$node_bin" "$fakebin/node"
  # The tmux stub records send-keys payloads so a test can read back the exact
  # launch command the adapter would deliver to a pane, without a real pane.
  # FM_FAKE_WINDOW/FM_FAKE_COMMAND model an existing, agent-free endpoint for
  # the relaunch case; every other case leaves them unset and unused.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_COMMAND:-zsh}"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ] && [ -n "${FM_TMUX_LOG:-}" ]; then
  printf '%s\n' "${!#}" >> "$FM_TMUX_LOG"
fi
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW"; exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # The candidate is Orca-only. This stub returns the case's already-isolated
  # git worktree and records terminal-send text in the same log the assertions
  # have always inspected; no real Orca runtime or terminal is contacted.
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    ;;
  "repo show"|"repo add")
    printf '{"ok":true,"result":{"id":"repo-omp-fixture"}}\n'
    ;;
  "worktree create")
    printf '{"ok":true,"result":{"worktree":{"id":"wt-omp-fixture","path":"%s"},"terminal":{"handle":"term-omp-fixture"}}}\n' "${FM_FAKE_PANE_PATH:?}"
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-omp-fixture"}}}\n'
    ;;
  "terminal send")
    text= saw_text=0
    shift 2
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --text ] && [ "$#" -gt 1 ]; then
        text=$2
        saw_text=1
        shift 2
      else
        shift
      fi
    done
    if [ "$saw_text" -eq 1 ] && [ -n "${FM_TMUX_LOG:-}" ]; then
      printf '%s\n' "$text" >> "$FM_TMUX_LOG"
    fi
    printf '{"ok":true,"result":{}}\n'
    ;;
  "worktree rm")
    printf '{"ok":true,"result":{}}\n'
    ;;
  *)
    printf '{"ok":true,"result":{}}\n'
    ;;
esac
SH
  chmod +x "$fakebin/orca"
  fm_fake_exit0 "$fakebin" treehouse
  # `absent` deliberately installs no omp at all, so PATH resolution must fail.
  if [ "$version" != absent ]; then
    # The stub records every argv it is given, so a test can prove the adapter
    # probes ONLY --version and never opens a session.
    cat > "$fakebin/omp" <<SH
#!/usr/bin/env bash
set -u
if [ -n "\${FM_OMP_STUB_LOG:-}" ]; then
  {
    printf 'omp'
    for a in "\$@"; do printf '\x1f%s' "\$a"; done
    printf '\n'
  } >> "\$FM_OMP_STUB_LOG"
fi
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "$version"
  exit 0
fi
echo "omp stub refuses to run a session" >&2
exit 97
SH
    chmod +x "$fakebin/omp"
  fi
  printf '%s\n' "$fakebin"
}

make_omp_case() {  # <name> <crew-harness> <id> [omp-version|absent]
  local name=$1 harness=$2 id=$3 version=${4:-$OMP_PINNED_VERSION}
  local case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_omp_fakebin "$case_dir/fake" "$version")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# The absence case must prove the adapter's own refusal, so its PATH is the
# fakebin plus the base system directories ONLY. Inheriting the caller's PATH
# would let a REAL installed omp resolve, and the test would then silently prove
# nothing while also violating the stubs-only rule for deterministic
# verification.
OMP_ABSENT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 path
  shift 3
  path="$fakebin:${FM_TEST_BASE_PATH:-$PATH}"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$path" FM_BACKEND="${FM_TEST_BACKEND:-orca}" \
    FM_OMP_STUB_LOG="${FM_OMP_STUB_LOG:-}" FM_TMUX_LOG="${FM_TMUX_LOG:-}" \
    "$SPAWN" "$@" 2>&1
}

# The same environment as run_spawn but WITHOUT FM_SPAWN_NO_GUARD, so
# bin/fm-guard.sh actually runs. The guard is the earliest writer of home state
# on the spawn path, which is what makes it usable as an ordering probe.
run_spawn_guarded() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 path
  shift 3
  path="$fakebin:${FM_TEST_BASE_PATH:-$PATH}"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$path" FM_BACKEND="${FM_TEST_BACKEND:-orca}" \
    FM_OMP_STUB_LOG="${FM_OMP_STUB_LOG:-}" FM_TMUX_LOG="${FM_TMUX_LOG:-}" \
    "$SPAWN" "$@" 2>&1
}

# --- selection -------------------------------------------------------------

test_omp_token_is_not_normalized_to_pi() {
  local out
  # config/crew-harness carrying the exact token must resolve to omp, never to
  # the Pi family this fork descends from.
  mkdir -p "$TMP_ROOT/resolve/config"
  printf 'omp\n' > "$TMP_ROOT/resolve/config/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/resolve/config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = omp ] || fail "config/crew-harness omp must resolve to 'omp', got '$out'"

  # The firstmate-owned launch marker identifies an omp worker as omp. The
  # foreign markers are cleared here exactly as bin/fm-spawn.sh clears them on
  # the omp launch, which is what makes this marker reachable at all - the test
  # itself may be running under one of those harnesses.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS=1 must detect 'omp', got '$out'"

  # An UNcleared foreign marker still wins, proving adding omp changed no
  # pre-existing marker precedence. Both the oldest marker and the newest one
  # are checked, because the launch's clearing list is only correct while it
  # covers EVERY marker resolved ahead of omp.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    CLAUDECODE=1 FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "existing marker precedence changed, got '$out'"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_INVOKED_AS \
    CURSOR_AGENT=1 FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "an uncleared CURSOR_AGENT must still outrank omp, got '$out'"

  # Liveness classifies the exact process name only, never a substring.
  out=$(fm_backend_tmux_classify_process_name /usr/local/bin/omp)
  [ "$out" = agent ] || fail "exact process name omp must classify agent, got '$out'"
  out=$(fm_backend_tmux_classify_process_name /bin/compinit)
  [ "$out" != agent ] || fail "compinit must not classify as an omp agent"
  out=$(fm_backend_tmux_classify_process_name /usr/bin/composer)
  [ "$out" != agent ] || fail "composer must not classify as an omp agent"
  pass "omp is recognized as its own token, never normalized to pi, and matched exactly for liveness"
}

test_omp_is_unreachable_without_explicit_selection() {
  local rec id=omp-default out
  # crew-harness stays claude: nothing may reach omp implicitly.
  rec=$(make_omp_case omp-default claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "default spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=claude" "an unselected omp must not be reachable"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "no omp extension may be written for another harness"
  pass "omp is dormant: it is unreachable unless it is explicitly selected"
}

# --- version pin -----------------------------------------------------------

test_omp_accepts_only_the_exact_pinned_version() {
  local rec id=omp-version out stub_log
  rec=$(make_omp_case omp-version claude "$id")
  read_case_record "$rec"
  stub_log="$CASE_DIR/omp-argv"
  : > "$stub_log"
  out=$(FM_OMP_STUB_LOG="$stub_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn on the pinned version should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp kind=ship" "omp spawn did not report harness=omp"
  # The ONLY invocation of the executable is the identity probe. Anything else
  # would mean the adapter opened a session during deterministic verification.
  [ "$(cat "$stub_log")" = "omp"$'\x1f'"--version" ] \
    || fail "adapter must invoke omp exactly once, with --version only, got: $(cat "$stub_log")"
  pass "omp launches on the exact pinned version and probes the binary only with --version"
}

test_omp_refuses_a_missing_binary() {
  local rec id=omp-absent out status
  rec=$(make_omp_case omp-absent claude "$id" absent)
  read_case_record "$rec"
  # Guard the guard: if the isolated PATH could still see an omp, this case
  # would pass for the wrong reason.
  ! PATH="$FAKEBIN_DIR:$OMP_ABSENT_PATH" command -v omp >/dev/null 2>&1 \
    || fail "the absence fixture must not be able to resolve any omp executable"
  out=$(FM_TEST_BASE_PATH="$OMP_ABSENT_PATH" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail when the executable is absent: $out"
  assert_contains "$out" "omp executable not found on PATH" "absence refusal did not name the missing executable"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused omp spawn must not publish task metadata"
  pass "omp refuses to launch when no omp executable is on PATH"
}

test_omp_refuses_version_drift() {
  local rec id=omp-drift out status
  rec=$(make_omp_case omp-drift claude "$id" "omp/17.3.0")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail on version drift: $out"
  assert_contains "$out" "omp version drift" "drift refusal did not name the drift"
  assert_contains "$out" "$OMP_PINNED_VERSION" "drift refusal did not name the pinned version"
  assert_absent "$HOME_DIR/state/$id.meta" "a drifted omp spawn must not publish task metadata"
  pass "omp refuses a build whose reported version is not the pinned release"
}

test_omp_refuses_a_substituted_binary() {
  local rec id=omp-substitute out status
  # A different agent answering to the name `omp` is a substitution, not a pin.
  rec=$(make_omp_case omp-substitute claude "$id" "pi/0.82.0")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail on a substituted binary: $out"
  assert_contains "$out" "omp version drift" "substitution refusal did not refuse"
  pass "omp refuses a substituted executable that reports another agent's version"
}

# --- launch shape ----------------------------------------------------------

test_omp_launch_argv_is_contained() {
  local rec id=omp-argv out launch tmux_log tools ext_flags
  rec=$(make_omp_case omp-argv claude "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no omp launch command was delivered to the pane"

  # One contiguous assertion pins the whole head of the command line: the
  # foreign markers are cleared, the firstmate-owned marker replaces them, the
  # resolved absolute binary follows, and the FIRST argument after it is a flag
  # rather than one of omp's subcommands (auth, token, usage, setup, update,
  # plugin, marketplace, acp), which is what keeps those surfaces unreachable.
  assert_contains "$launch" \
    "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u TRACEPARENT FM_OMP_HARNESS=1 '$FAKEBIN_DIR/omp' --approval-mode yolo --no-title --no-extensions --no-skills --tools read,write,edit,ls,grep,find,bash --model '$OMP_MODEL' -e '$HOME_DIR/state/$id.omp-ext.ts'" \
    "omp launch argv is not the contained shape"

  # The allowlist is exact, so a later widening has to be deliberate.
  tools=$(printf '%s\n' "$launch" | sed -n 's/.*--tools \([^ ]*\).*/\1/p')
  [ "$tools" = "read,write,edit,ls,grep,find,bash" ] \
    || fail "omp tool allowlist drifted, got '$tools'"
  case ",$tools," in
    *,task,*) fail "omp allowlist must exclude the task subagent tool" ;;
    *,browser,*) fail "omp allowlist must exclude the browser tool" ;;
    *,computer,*) fail "omp allowlist must exclude the computer tool" ;;
    *,web_search,*) fail "omp allowlist must exclude web search" ;;
    *,mcp,*) fail "omp allowlist must exclude MCP tooling" ;;
  esac

  # Exactly one extension is loaded, and it is the firstmate-owned state file.
  # grep -c counts LINES, so the occurrences are counted explicitly.
  ext_flags=$(printf '%s\n' "$launch" | grep -o -- ' -e ' | wc -l | tr -d '[:space:]')
  [ "$ext_flags" = 1 ] || fail "omp launch must load exactly one extension, found $ext_flags"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "omp spawn did not write the state-owned extension"

  # A positional brief, and no effort axis reaching the launch. The model axis is
  # asserted in full by its own case below.
  assert_contains "$launch" "encode launch-brief" "omp launch missing the positional brief"
  assert_not_contains "$launch" "--thinking" "omp launch must not select an effort level"
  assert_not_contains "$launch" "--reasoning-effort" "omp launch must not select an effort level"
  pass "omp launch argv is contained: markers cleared, surface reduced, one extension, no delegation or network tooling"
}

test_omp_records_exact_task_metadata() {
  local rec id=omp-meta out meta
  rec=$(make_omp_case omp-meta claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn should succeed: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_present "$meta" "omp spawn did not publish task metadata"
  assert_grep "harness=omp" "$meta" "meta must record harness=omp"
  assert_grep "kind=ship" "$meta" "meta must record the crewmate kind"
  assert_no_grep "traceparent=" "$meta" "omp must not enable trace propagation"
  assert_no_grep "home=" "$meta" "a crewmate must not record secondmate home state"
  assert_absent "$HOME_DIR/config/secondmate-harness" "omp must not write secondmate configuration"
  pass "omp records harness=omp with no trace context and no secondmate configuration"
}

test_omp_accepts_a_scout_launch() {
  local rec id=omp-scout out
  rec=$(make_omp_case omp-scout claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness omp --model "$OMP_MODEL")
  expect_code 0 $? "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp kind=scout" "omp must be accepted for a scout launch"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "an omp scout must still get its busy-state extension"
  pass "omp is accepted for crewmate and scout launches"
}

test_omp_launch_carries_exactly_one_qualified_model_flag() {
  local rec id=omp-model-argv out launch tmux_log stub_log flags value
  rec=$(make_omp_case omp-model-argv claude "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  stub_log="$CASE_DIR/omp-argv"
  : > "$tmux_log"
  : > "$stub_log"
  out=$(FM_TMUX_LOG="$tmux_log" FM_OMP_STUB_LOG="$stub_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn with a qualified model should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no omp launch command was delivered to the pane"

  # Exactly one --model, carrying the exact identifier that was supplied.
  flags=$(printf '%s\n' "$launch" | grep -o -- '--model' | wc -l | tr -d '[:space:]')
  [ "$flags" = 1 ] || fail "omp launch must carry exactly one --model flag, found $flags"
  value=$(printf '%s\n' "$launch" | sed -n "s/.*--model '\\([^']*\\)'.*/\\1/p")
  [ "$value" = "$OMP_MODEL" ] \
    || fail "omp --model must carry the exact supplied identifier, got '$value'"

  # omp's legacy provider flag and every fuzzy, cycling, or fallback selector
  # stay off the launch: one qualified identifier is the whole selection.
  assert_not_contains "$launch" "--provider" "omp launch must not pass a provider flag"
  assert_not_contains "$launch" "--fallback" "omp launch must not pass a fallback selector"
  assert_not_contains "$launch" "--cycle" "omp launch must not pass a model cycler"

  # The pinned executable is still probed ONLY for its identity, so no model
  # catalog, provider list, or account query happens on the spawn path.
  [ "$(cat "$stub_log")" = "omp"$'\x1f'"--version" ] \
    || fail "adapter must invoke omp exactly once, with --version only, got: $(cat "$stub_log")"

  # The recorded model is the supplied one, and no configuration was written.
  assert_grep "model=$OMP_MODEL" "$HOME_DIR/state/$id.meta" "meta must record the exact launch model"
  [ "$(cat "$HOME_DIR/config/crew-harness")" = claude ] \
    || fail "an omp launch must not rewrite config/crew-harness"
  assert_absent "$HOME_DIR/config/crew-dispatch.json" "an omp launch must not write a dispatch profile"
  assert_absent "$HOME_DIR/config/secondmate-harness" "an omp launch must not write secondmate configuration"
  pass "an omp launch carries exactly one --model with the exact supplied provider/model, no provider flag, and writes no configuration"
}

test_omp_requires_orca_before_any_mutation() {
  local rec id=omp-backend-allowed out backend n=0
  rec=$(make_omp_case omp-backend-allowed claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --backend orca --mode no-mistakes --yolo off)
  expect_code 0 $? "an explicit Orca OMP spawn should succeed: $out"
  assert_grep 'backend=orca' "$HOME_DIR/state/$id.meta" "the allowed OMP spawn must record backend=orca"

  rec=$(make_omp_case omp-backend-refused claude omp-backend-0)
  read_case_record "$rec"
  for backend in tmux herdr zellij cmux; do
    n=$((n + 1))
    assert_omp_launch_refused "omp-backend-$n" "omp requires backend=orca" \
      --model "$OMP_MODEL" --backend "$backend"
  done
  [ "$n" -eq 4 ] || fail "the OMP non-Orca backend matrix must carry four rows, found $n"
  pass "OMP accepts Orca and refuses tmux, Herdr, Zellij, and cmux before every mutation"
}

test_omp_forces_trace_off_and_clears_ambient_carrier() {
  local rec id=omp-trace-off out launch tmux_log meta
  local carrier='00-0123456789abcdef0123456789abcdef-0123456789abcdef-01'
  rec=$(make_omp_case omp-trace-off claude "$id")
  read_case_record "$rec"
  # Freeze this home session to trace=on, then also seed an ambient carrier.
  # OMP must override both independent inputs.
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  printf '%s on\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
  tmux_log="$CASE_DIR/endpoint-sends"
  : > "$tmux_log"
  out=$(TRACEPARENT="$carrier" FM_TMUX_LOG="$tmux_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --backend orca --mode no-mistakes --yolo off)
  expect_code 0 $? "OMP should launch with trace forced off: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no OMP launch command was delivered"
  assert_contains "$launch" '-u TRACEPARENT' "the OMP child must explicitly clear an ambient carrier"
  assert_not_contains "$launch" "$carrier" "the ambient carrier must not reach the OMP child argv"
  # assert_no_grep is a FIXED-string search, so a leading ^ would be matched
  # literally and the assertion could never fail. These two carry the enforced
  # half of the suppression - that omp never resolves trace on - so they must
  # stay anchorless to actually bite.
  assert_no_grep 'export TRACEPARENT=' "$tmux_log" "the enabled home must not export trace context to OMP"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep 'traceparent=' "$meta" "OMP metadata must not record a trace carrier"
  pass "OMP forces effective trace propagation off and clears an ambient TRACEPARENT carrier"
}

# --- refusal ordering probes ------------------------------------------------

# Arms the two ordering probes in the current case home, and re-arms them between
# runs:
#   - the watcher guard writes state/.guard-watcher-stale-banner when a task is in
#     flight and supervision is unhealthy, so a decoy task metadata file is seeded
#     and the liveness beacon removed;
#   - the per-task spawn lock is held by this live test process, so any spawn that
#     reaches acquisition is refused by name.
arm_ordering_probes() {  # <task-id>
  local id=$1
  rm -f "$HOME_DIR/state/.last-watcher-beat"
  rm -f "$HOME_DIR/state/.guard-watcher-stale-banner"
  printf 'window=fm-decoy\nharness=claude\n' > "$HOME_DIR/state/decoy.meta"
  mkdir -p "$HOME_DIR/state/.spawn-$id.lock"
  printf '%s\n' "$$" > "$HOME_DIR/state/.spawn-$id.lock/pid"
}

test_ordering_probes_are_live() {
  local rec id=omp-probe out status guard_marker
  # Both ordering probes must actually fire on a launch that is ALLOWED to run
  # the whole preamble. Without this control, every "refused before the guard
  # and the lock" assertion below could pass while proving nothing.
  rec=$(make_omp_case omp-probe-control omp "$id")
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  arm_ordering_probes "$id"
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the held per-task spawn lock must refuse this spawn: $out"
  assert_contains "$out" "another spawn is already creating task $id" \
    "the held-lock probe is not blocking acquisition: $out"
  assert_present "$guard_marker" \
    "the watcher-guard probe never fired, so it cannot prove anything about ordering"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"
  pass "both refusal-ordering probes fire on a launch that runs the whole spawn preamble"
}

# assert_omp_launch_refused <task-id> <expected-message> [extra spawn args...]
#
# One omp spawn that must be refused, plus the proof that the refusal landed
# before any mutation: the watcher guard never wrote its episode marker, the
# per-task spawn lock was never reached, no task metadata, no busy contract, no
# extension, nothing sent to a pane, and the pinned executable never even probed
# for its version. The caller supplies the fixture, so a whole table of rejected
# values shares one worktree - a refused spawn creates nothing to isolate.
assert_omp_launch_refused() {  # <task-id> <expected-message> [extra spawn args...]
  local id=$1 want=$2 out status stub_log tmux_log
  shift 2
  stub_log="$CASE_DIR/omp-argv-$id"
  tmux_log="$CASE_DIR/tmux-sends-$id"
  : > "$stub_log"
  : > "$tmux_log"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  arm_ordering_probes "$id"
  out=$(FM_OMP_STUB_LOG="$stub_log" FM_TMUX_LOG="$tmux_log" \
    run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp "$@" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "$id: the spawn must be refused: $out"
  assert_contains "$out" "$want" "$id: refusal did not name the launch pin: $out"
  assert_not_contains "$out" "another spawn is already creating" \
    "$id: the refusal must precede per-task spawn-lock acquisition: $out"
  assert_absent "$HOME_DIR/state/.guard-watcher-stale-banner" \
    "$id: the refusal must precede the watcher guard's own state write"
  assert_absent "$HOME_DIR/state/$id.meta" "$id: refused spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$id: refused spawn wrote the extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "$id: refused spawn armed a busy contract"
  [ ! -s "$tmux_log" ] || fail "$id: refused spawn sent a command to a pane: $(cat "$tmux_log")"
  [ ! -s "$stub_log" ] || fail "$id: refused spawn invoked the pinned executable: $(cat "$stub_log")"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"
}

# --- policy matrix 1: the model pin, 12 equivalence classes -----------------

# Row counters for the model policy matrix. Class-scoped rather than
# test-scoped so a class that silently stops asserting cannot go unnoticed: the
# matrix reports both the class count and the concrete-value count.
OMP_MODEL_CLASSES=0
OMP_MODEL_VALUES=0
OMP_MODEL_LABELS=

# omp_model_class <label> <expected-message> [rejected values...]
# One equivalence class of model value omp must never launch on. With no values
# the class is "the flag was never passed at all". Every value is asserted
# through assert_omp_launch_refused, so widening a class cannot quietly shrink
# the matrix.
omp_model_class() {
  local label=$1 want=$2 bad
  shift 2
  OMP_MODEL_CLASSES=$((OMP_MODEL_CLASSES + 1))
  OMP_MODEL_LABELS="$OMP_MODEL_LABELS$OMP_MODEL_CLASSES. $label"$'\n'
  if [ "$#" -eq 0 ]; then
    OMP_MODEL_VALUES=$((OMP_MODEL_VALUES + 1))
    assert_omp_launch_refused "omp-m$OMP_MODEL_VALUES" "$want"
    return 0
  fi
  for bad in "$@"; do
    OMP_MODEL_VALUES=$((OMP_MODEL_VALUES + 1))
    assert_omp_launch_refused "omp-m$OMP_MODEL_VALUES" "$want" --model "$bad"
  done
}

test_omp_model_policy_matrix() {
  local rec want_absent want_shape
  want_absent="omp requires an explicit --model <provider>/<model>"
  want_shape="omp --model must be exactly '<provider>/<model>'"
  rec=$(make_omp_case omp-model-matrix claude omp-m0)
  read_case_record "$rec"

  # Twelve equivalence classes. Classes 1-2 are the "no usable model at all"
  # shapes; class 3 is what omp's own fuzzy matcher would resolve across
  # providers; classes 4-12 are structurally malformed or ambiguous. No catalog
  # is consulted for any of them - the refusal is purely structural.
  omp_model_class 'absent' "$want_absent"
  omp_model_class 'no-model sentinel' "$want_absent" default
  omp_model_class 'unqualified bare identifier' "$want_shape" opus claude-sonnet-4-5
  omp_model_class 'empty provider segment' "$want_shape" '/claude-sonnet-4-5'
  omp_model_class 'empty model segment' "$want_shape" 'anthropic/' 'anthropic/claude/'
  omp_model_class 'doubled separator' "$want_shape" 'anthropic//claude-sonnet-4-5'
  omp_model_class 'extra path segment' "$want_shape" 'anthropic/claude/sonnet'
  omp_model_class 'embedded whitespace' "$want_shape" 'anthropic claude' 'anthropic/claude sonnet'
  omp_model_class 'glob metacharacter' "$want_shape" 'anthropic/claude*' '*/claude-sonnet-4-5' 'anthropic/claude?'
  # shellcheck disable=SC2016  # the metacharacter cases must stay LITERAL: they are rejected input, not expansions
  omp_model_class 'shell metacharacter' "$want_shape" 'anthropic/claude;id' 'anthropic/$(id)' 'anthropic/`id`' 'anthropic/claude|tee'
  omp_model_class 'non-identifier segment start' "$want_shape" '-anthropic/claude' 'anthropic/-claude' '.anthropic/claude'
  omp_model_class 'wrong separator' "$want_shape" 'anthropic:claude'

  [ "$OMP_MODEL_CLASSES" -eq 12 ] \
    || fail "the omp model policy matrix must carry 12 classes, found $OMP_MODEL_CLASSES"$'\n'"$OMP_MODEL_LABELS"
  printf 'omp model-policy matrix: %d/%d classes refused before any mutation (%d concrete values)\n' \
    "$OMP_MODEL_CLASSES" 12 "$OMP_MODEL_VALUES"
  printf '%s' "$OMP_MODEL_LABELS"
  pass "omp model policy matrix: $OMP_MODEL_CLASSES/12 rejected-model classes refuse before the watcher guard, the task lock, and every other mutation"
}

# --- policy matrix 2: selection shapes, 8 rows ------------------------------

test_omp_selection_policy_matrix() {
  local rec out status guard_marker sub_home launch tmux_log rows=0 enforced=0
  local want_model="omp requires an explicit --model"
  local want_second="omp is a candidate crewmate/scout adapter only"

  # Row 1: an explicit --harness omp with no model.
  rec=$(make_omp_case omp-sel-explicit claude omp-s1)
  read_case_record "$rec"
  rows=$((rows + 1))
  assert_omp_launch_refused omp-s1 "$want_model"
  assert_absent "$HOME_DIR/state/omp-s1.meta" "explicit shape published task metadata"
  enforced=$((enforced + 1))

  # Row 2: the back-compat positional harness argument.
  rec=$(make_omp_case omp-sel-positional claude omp-s2)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  rows=$((rows + 1))
  arm_ordering_probes omp-s2
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s2 "$PROJ_DIR" omp --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a positional omp with no model must be refused: $out"
  assert_contains "$out" "$want_model" "positional shape: $out"
  assert_not_contains "$out" "another spawn is already creating" "positional shape reached the task lock: $out"
  assert_absent "$guard_marker" "positional shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s2.meta" "positional shape published task metadata"
  rm -rf "$HOME_DIR/state/.spawn-omp-s2.lock"
  enforced=$((enforced + 1))

  # Row 3: config/crew-harness selects omp, so the launch passes no --harness at
  # all. A harness configuration file is not a provider decision, and omp's own
  # default is never consulted.
  rec=$(make_omp_case omp-sel-config omp omp-s3)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  rows=$((rows + 1))
  arm_ordering_probes omp-s3
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s3 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a config-resolved omp launch with no model must be refused: $out"
  assert_contains "$out" "$want_model" "config-resolved refusal did not name the launch pin: $out"
  assert_not_contains "$out" "another spawn is already creating" "config shape reached the task lock: $out"
  assert_absent "$guard_marker" "config shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s3.meta" "config shape published task metadata"
  [ ! -s "$tmux_log" ] || fail "refused config-resolved omp spawn sent a command to a pane"
  rm -rf "$HOME_DIR/state/.spawn-omp-s3.lock"
  # The same config-resolved launch proceeds once the flag supplies the model.
  touch "$HOME_DIR/state/.last-watcher-beat"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s3 "$PROJ_DIR" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "a config-resolved omp launch with an explicit model should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  assert_contains "$launch" "--model '$OMP_MODEL'" \
    "the config-resolved omp launch did not carry the explicit model"
  enforced=$((enforced + 1))

  # Row 4: batch dispatch, refused once up front so no pair is ever re-exec'd.
  rec=$(make_omp_case omp-sel-batch claude omp-s4)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  mkdir -p "$HOME_DIR/data/omp-s4b"
  printf 'brief for omp-s4b\n' > "$HOME_DIR/data/omp-s4b/brief.md"
  rows=$((rows + 1))
  arm_ordering_probes omp-s4
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "omp-s4=$PROJ_DIR" "omp-s4b=$PROJ_DIR" --harness omp --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a batch selecting omp with no model must be refused: $out"
  assert_contains "$out" "$want_model" "batch shape: $out"
  assert_not_contains "$out" "spawned " "a refused batch must not spawn any pair"
  assert_not_contains "$out" "batch: FAILED" "a refused batch must be refused before any pair is attempted"
  assert_absent "$guard_marker" "batch shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s4.meta" "batch shape published task metadata"
  assert_absent "$HOME_DIR/state/omp-s4b.meta" "batch shape published task metadata"
  rm -rf "$HOME_DIR/state/.spawn-omp-s4.lock"
  enforced=$((enforced + 1))

  # Rows 5-7: a secondmate is refused on adapter identity ALONE, so the model
  # never changes the verdict - absent, structurally invalid, and fully qualified
  # all land on the same refusal, before every mutation.
  rec=$(make_omp_case omp-sel-secondmate claude omp-s5)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  sub_home="$CASE_DIR/secondmate-home"
  local model_args
  for model_args in "" "--model opus" "--model $OMP_MODEL"; do
    rows=$((rows + 1))
    rm -rf "$sub_home"
    mkdir -p "$sub_home"
    arm_ordering_probes omp-s5
    # shellcheck disable=SC2086  # deliberate word split: the empty case must pass NO model flag at all
    out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      omp-s5 "$sub_home" --harness omp $model_args --secondmate)
    status=$?
    [ "$status" -ne 0 ] || fail "omp must be refused for a secondmate ('$model_args'): $out"
    assert_contains "$out" "$want_second" "secondmate refusal missing for '$model_args': $out"
    assert_not_contains "$out" "requires an explicit --model" \
      "the secondmate refusal must not depend on the model ('$model_args'): $out"
    assert_not_contains "$out" "another spawn is already creating" \
      "the secondmate refusal must precede task-lock acquisition ('$model_args'): $out"
    assert_absent "$guard_marker" \
      "the secondmate refusal must precede the watcher guard's own state write ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.meta" "refused omp secondmate published task metadata ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.omp-ext.ts" "refused omp secondmate wrote the extension ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.busy-gen" "refused omp secondmate armed a busy contract ('$model_args')"
    assert_absent "$HOME_DIR/data/secondmates.md" "refused omp secondmate touched the registry ('$model_args')"
    assert_absent "$sub_home/config" "refused omp secondmate mutated the secondmate home config ('$model_args')"
    assert_absent "$sub_home/state" "refused omp secondmate mutated the secondmate home state ('$model_args')"
    enforced=$((enforced + 1))
  done
  rm -rf "$HOME_DIR/state/.spawn-omp-s5.lock"

  # Row 8: the negative control. The pin is omp-only, so a claude launch that
  # requested no model must carry no model or provider flag at all, exactly as
  # before.
  rec=$(make_omp_case omp-sel-nonomp claude omp-s8)
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  rows=$((rows + 1))
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s8 "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "default claude spawn should succeed: $out"
  launch=$(grep -F -- 'dangerously-skip-permissions' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no claude launch command was delivered to the pane"
  assert_not_contains "$launch" "--model" \
    "a non-omp launch that requested no model must carry no model flag"
  assert_not_contains "$launch" "--provider" "a non-omp launch must never carry a provider flag"
  enforced=$((enforced + 1))

  [ "$rows" -eq 8 ] || fail "the omp selection policy matrix must carry 8 rows, found $rows"
  [ "$enforced" -eq "$rows" ] || fail "omp selection policy matrix: only $enforced/$rows rows enforced"
  printf 'omp selection-policy matrix: %d/%d rows enforced before any mutation\n' "$enforced" "$rows"
  pass "omp selection policy matrix: $enforced/$rows selection shapes - explicit, positional, configured, batch, three secondmate models, and the non-omp control - enforce the pin before any mutation"
}

# --- relaunch ---------------------------------------------------------------

case_tree_fingerprint() {
  local path rel
  while IFS= read -r path; do
    rel=${path#"$HOME_DIR"/}
    if [ -L "$path" ]; then
      printf 'link\t%s\t%s\n' "$rel" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'file\t%s\t' "$rel"
      cksum < "$path"
    elif [ -d "$path" ]; then
      printf 'dir\t%s\n' "$rel"
    elif [ -p "$path" ]; then
      printf 'fifo\t%s\n' "$rel"
    else
      printf 'other\t%s\n' "$rel"
    fi
  done < <(find "$HOME_DIR" -mindepth 1 -print | LC_ALL=C sort)
}

assert_relaunch_record_refused_without_mutation() {  # <task-id> <message> [extra-positional...]
  local id=$1 want=$2 out status before after wt_before wt_after proj_before proj_after stub_log tmux_log
  shift 2
  stub_log="$CASE_DIR/omp-relaunch-preflight-argv"
  tmux_log="$CASE_DIR/omp-relaunch-preflight-sends"
  : > "$stub_log"
  : > "$tmux_log"
  rm -f "$HOME_DIR/state/.last-watcher-beat"
  printf 'window=fm-decoy\nharness=claude\n' > "$HOME_DIR/state/decoy.meta"
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) : ;;
    *)
      mkdir -p "$HOME_DIR/state/.control-$id.lock" "$HOME_DIR/state/.spawn-$id.lock"
      printf '%s\n' "$$" > "$HOME_DIR/state/.control-$id.lock/pid"
      printf '%s\n' "$$" > "$HOME_DIR/state/.spawn-$id.lock/pid"
      ;;
  esac
  before=$(case_tree_fingerprint)
  wt_before=$(/usr/bin/git -C "$WT_DIR" status --porcelain=v1)
  proj_before=$(/usr/bin/git -C "$PROJ_DIR" status --porcelain=v1)
  out=$(FM_OMP_STUB_LOG="$stub_log" FM_TMUX_LOG="$tmux_log" \
    run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$@" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "$id: unsafe relaunch metadata must be refused: $out"
  assert_contains "$out" "$want" "$id: refusal did not identify the relaunch preflight: $out"
  assert_not_contains "$out" "another lifecycle action" "$id: refusal reached the control lock: $out"
  assert_not_contains "$out" "another spawn is already creating" "$id: refusal reached the task lock: $out"
  after=$(case_tree_fingerprint)
  wt_after=$(/usr/bin/git -C "$WT_DIR" status --porcelain=v1)
  proj_after=$(/usr/bin/git -C "$PROJ_DIR" status --porcelain=v1)
  [ "$after" = "$before" ] || fail "$id: refused relaunch mutated the First Mate home"
  [ "$wt_after" = "$wt_before" ] || fail "$id: refused relaunch mutated the worktree"
  [ "$proj_after" = "$proj_before" ] || fail "$id: refused relaunch mutated the project repository"
  assert_absent "$HOME_DIR/state/.guard-watcher-stale-banner" "$id: refusal ran after the watcher guard"
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) : ;;
    *)
      assert_present "$HOME_DIR/state/.control-$id.lock" "$id: refusal altered the control-lock probe"
      assert_present "$HOME_DIR/state/.spawn-$id.lock" "$id: refusal altered the task-lock probe"
      assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$id: refusal wrote an OMP extension"
      assert_absent "$HOME_DIR/state/$id.busy-gen" "$id: refusal armed busy state"
      ;;
  esac
  [ ! -s "$tmux_log" ] || fail "$id: refused relaunch contacted an endpoint"
  [ ! -s "$stub_log" ] || fail "$id: refused relaunch invoked OMP"
}

test_relaunch_rejects_unsafe_metadata_before_every_mutation() {
  local rec id target meta

  id=omp-relaunch-missing
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  assert_relaunch_record_refused_without_mutation "$id" "regular, non-symlink metadata file"

  id=omp-relaunch-symlink
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/targets"
  target="$HOME_DIR/targets/task.meta"
  printf 'harness=omp\n' > "$target"
  ln -s ../targets/task.meta "$HOME_DIR/state/$id.meta"
  assert_relaunch_record_refused_without_mutation "$id" "regular, non-symlink metadata file"

  id=omp-relaunch-directory
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  mkdir "$HOME_DIR/state/$id.meta"
  assert_relaunch_record_refused_without_mutation "$id" "regular, non-symlink metadata file"

  id=omp-relaunch-fifo
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  mkfifo "$HOME_DIR/state/$id.meta"
  assert_relaunch_record_refused_without_mutation "$id" "regular, non-symlink metadata file"

  rec=$(make_omp_case omp-relaunch-invalid claude omp-relaunch-fixture)
  read_case_record "$rec"
  assert_relaunch_record_refused_without_mutation '../omp-relaunch-invalid' "--relaunch requires a valid task id"

  id=omp-relaunch-arity
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  assert_relaunch_record_refused_without_mutation "$id" \
    "--relaunch takes the task id only" "$PROJ_DIR"
  pass "missing, symlinked, directory, FIFO, invalid-id, and multi-positional relaunches refuse before every mutation"
}

test_relaunch_detects_a_path_swap_while_binding_the_snapshot() {
  local rec id=omp-relaunch-snapshot-race out status meta target trigger real_cat
  local before after wt_before wt_after proj_before proj_after stub_log tmux_log
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  target="$CASE_DIR/swapped-task.meta"
  trigger="$CASE_DIR/swap-on-path-read"
  stub_log="$CASE_DIR/omp-relaunch-race-argv"
  tmux_log="$CASE_DIR/omp-relaunch-race-sends"
  real_cat=$(command -v cat) || fail "race fixture requires the system cat"
  fm_write_meta "$meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-$id" \
    "orca_worktree_id=wt-$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca"
  printf 'harness=claude\nbackend=tmux\n' > "$target"
  cat > "$FAKEBIN_DIR/cat" <<'SH'
#!/usr/bin/env bash
set -u
path=
if [ "$#" -eq 2 ] && [ "$1" = -- ]; then
  path=$2
elif [ "$#" -eq 1 ]; then
  path=$1
fi
if [ -n "$path" ] && [ "$path" = "${FM_RELAUNCH_SWAP_META:-}" ] \
   && [ -e "${FM_RELAUNCH_SWAP_TRIGGER:-}" ]; then
  rm -f -- "$path"
  ln -s -- "${FM_RELAUNCH_SWAP_TARGET:?}" "$path"
  rm -f -- "$FM_RELAUNCH_SWAP_TRIGGER"
fi
exec "${FM_REAL_CAT:?}" "$@"
SH
  chmod +x "$FAKEBIN_DIR/cat"
  : > "$stub_log"
  : > "$tmux_log"
  : > "$trigger"
  rm -f "$HOME_DIR/state/.last-watcher-beat"
  printf 'window=fm-decoy\nharness=claude\n' > "$HOME_DIR/state/decoy.meta"
  mkdir -p "$HOME_DIR/state/.control-$id.lock" "$HOME_DIR/state/.spawn-$id.lock"
  printf '%s\n' "$$" > "$HOME_DIR/state/.control-$id.lock/pid"
  printf '%s\n' "$$" > "$HOME_DIR/state/.spawn-$id.lock/pid"
  before=$(case_tree_fingerprint)
  wt_before=$(/usr/bin/git -C "$WT_DIR" status --porcelain=v1)
  proj_before=$(/usr/bin/git -C "$PROJ_DIR" status --porcelain=v1)
  out=$(FM_REAL_CAT="$real_cat" FM_RELAUNCH_SWAP_META="$meta" \
    FM_RELAUNCH_SWAP_TARGET="$target" FM_RELAUNCH_SWAP_TRIGGER="$trigger" \
    FM_OMP_STUB_LOG="$stub_log" FM_TMUX_LOG="$tmux_log" \
    run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --relaunch --model "$OMP_MODEL")
  status=$?
  [ "$status" -ne 0 ] || fail "metadata path swap must refuse the relaunch: $out"
  assert_contains "$out" "could not bind a stable regular, non-symlink metadata snapshot" \
    "metadata path swap did not fail the stable-snapshot acquisition: $out"
  assert_absent "$trigger" "race fixture never swapped the metadata path"
  [ -L "$meta" ] || fail "race fixture did not replace metadata with a symlink"
  rm -f "$meta"
  fm_write_meta "$meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-$id" \
    "orca_worktree_id=wt-$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca"
  after=$(case_tree_fingerprint)
  wt_after=$(/usr/bin/git -C "$WT_DIR" status --porcelain=v1)
  proj_after=$(/usr/bin/git -C "$PROJ_DIR" status --porcelain=v1)
  [ "$after" = "$before" ] || fail "metadata race refusal changed the First Mate home"
  [ "$wt_after" = "$wt_before" ] || fail "metadata race refusal changed the worktree"
  [ "$proj_after" = "$proj_before" ] || fail "metadata race refusal changed the project"
  assert_absent "$HOME_DIR/state/.guard-watcher-stale-banner" "metadata race reached the watcher guard"
  assert_not_contains "$out" "another lifecycle action" "metadata race reached the control lock"
  assert_not_contains "$out" "another spawn is already creating" "metadata race reached the task lock"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "metadata race wrote an OMP extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "metadata race armed busy state"
  [ ! -s "$tmux_log" ] || fail "metadata race contacted an endpoint"
  [ ! -s "$stub_log" ] || fail "metadata race invoked OMP"
  pass "a deterministic metadata symlink swap during snapshot acquisition refuses before every mutation"
}

test_valid_nonomp_relaunch_passes_the_preflight() {
  local rec id=claude-relaunch-valid out meta tmux_log
  rec=$(make_omp_case "$id" claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  tmux_log="$CASE_DIR/tmux-relaunch-sends"
  : > "$tmux_log"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(FM_TEST_BACKEND=tmux FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh FM_TMUX_LOG="$tmux_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --relaunch)
  expect_code 0 $? "a valid non-OMP relaunch should pass the preflight and launch: $out"
  assert_contains "$out" "spawned $id harness=claude" "valid non-OMP relaunch did not launch: $out"
  assert_grep 'harness=claude' "$meta" "valid non-OMP relaunch did not preserve its harness"
  pass "a valid non-OMP regular task record passes the relaunch preflight"
}

test_omp_relaunch_still_requires_the_model() {
  local rec id=omp-relaunch out status meta guard_marker
  # A --relaunch adopts its harness from the task's own record. Its read-only,
  # regular-file preflight applies the model/backend gates before every lock;
  # the full locked endpoint validation below remains authoritative.
  # It must still refuse: a relaunch carries no recorded model forward, and omp
  # would otherwise resolve the provider itself.
  rec=$(make_omp_case omp-relaunch claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch of an omp task with no model must be refused: $out"
  assert_contains "$out" "omp requires an explicit --model" \
    "the relaunch refusal did not name the launch pin: $out"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "a refused relaunch must not write the extension"

  # Supplying the model must not make a legacy non-Orca record launchable.
  # This read-only metadata preflight also precedes the watcher guard and task
  # lock, while the normal locked endpoint validation remains authoritative.
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  arm_ordering_probes "$id"
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --relaunch --model "$OMP_MODEL")
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch of an OMP task recorded on tmux must be refused: $out"
  assert_contains "$out" "omp requires backend=orca" "the relaunch refusal did not enforce Orca: $out"
  assert_not_contains "$out" "another spawn is already creating" "the relaunch backend refusal reached the task lock"
  assert_absent "$guard_marker" "the relaunch backend refusal ran after the watcher guard"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"

  # A complete Orca record passes both new relaunch preflight checks and OMP's
  # adapter checks, then retains the existing recovery boundary: Orca still has
  # no recovery-grade agent-state classifier, so the replacement is refused
  # rather than risking a duplicate agent. That downstream verdict is the
  # current valid-OMP relaunch behavior and must not be shadowed by this patch.
  fm_write_meta "$meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-$id" \
    "orca_worktree_id=wt-$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --relaunch --model "$OMP_MODEL")
  status=$?
  [ "$status" -ne 0 ] || fail "an OMP relaunch must retain its recovery-grade endpoint gate: $out"
  assert_contains "$out" "has no recovery-grade agent-state classifier" \
    "a valid OMP record did not pass both early preflights to the existing recovery gate: $out"
  assert_not_contains "$out" "regular, non-symlink metadata" \
    "a valid OMP record was incorrectly rejected by the new metadata preflight: $out"
  pass "an OMP relaunch still requires a qualified model and Orca record, and valid metadata reaches the existing recovery gate"
}

# --- busy-state trust table ------------------------------------------------

test_omp_trusts_only_its_own_semantic_source() {
  local trusted
  trusted=$(fm_busy_sources_for_harness omp)
  case " $trusted " in
    *" omp-ext "*) : ;;
    *) fail "omp must trust its own omp-ext source, got '$trusted'" ;;
  esac
  case " $trusted " in
    *" pi-ext "*) fail "omp must not inherit the Pi extension source" ;;
  esac
  fm_busy_source_trusted omp omp-ext || fail "omp-ext must be trusted for omp"
  ! fm_busy_source_trusted omp pi-ext || fail "pi-ext must not be trusted for omp"
  ! fm_busy_source_trusted pi omp-ext || fail "omp-ext must not be trusted for pi"
  pass "omp trusts exactly its own omp-ext semantic source"
}

test_omp_token_is_not_normalized_to_pi
test_omp_is_unreachable_without_explicit_selection
test_omp_accepts_only_the_exact_pinned_version
test_omp_refuses_a_missing_binary
test_omp_refuses_version_drift
test_omp_refuses_a_substituted_binary
test_omp_launch_argv_is_contained
test_omp_records_exact_task_metadata
test_omp_accepts_a_scout_launch
test_omp_launch_carries_exactly_one_qualified_model_flag
test_omp_requires_orca_before_any_mutation
test_omp_forces_trace_off_and_clears_ambient_carrier
test_ordering_probes_are_live
test_omp_model_policy_matrix
test_omp_selection_policy_matrix
test_relaunch_rejects_unsafe_metadata_before_every_mutation
test_relaunch_detects_a_path_swap_while_binding_the_snapshot
test_valid_nonomp_relaunch_passes_the_preflight
test_omp_relaunch_still_requires_the_model
test_omp_trusts_only_its_own_semantic_source

echo "all fm-omp-harness tests passed"
