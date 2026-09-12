#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# Pin the native bridge without accepting a generic Codex session, a wrapper,
# a non-harness gap, a lookalike Pi process, or any node process other than the
# installed npm launcher running the same transport command, one hop deep.
test_pi_native_owner() {
  local dir fakebin shape got expected pids
  dir="$TMP_ROOT/pi-native"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/bin" "$dir/lib/node_modules/@openai/codex/bin"
  : > "$dir/lib/node_modules/@openai/codex/bin/codex.js"
  : > "$dir/other.js"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$dir/bin/codex"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field=$2 pid=$4
vendor=/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
case "$FM_TEST_NATIVE_SHAPE" in npm*) via_launcher=1 ;; *) via_launcher=0 ;; esac
case "$pid:$field" in
  700:comm=)
    if [ "$via_launcher" = 1 ]; then echo "$vendor"; else echo /Applications/ChatGPT.app/Contents/Resources/codex; fi ;;
  700:args=)
    case "$FM_TEST_NATIVE_SHAPE" in
      interactive) echo 'codex exec task' ;;
      npm*) echo "$vendor app-server --stdio" ;;
      *) echo '/Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --stdio' ;;
    esac ;;
  700:ppid=) if [ "$via_launcher" = 1 ]; then echo 750; else echo 800; fi ;;
  750:comm=) echo node ;;
  750:args=)
    case "$FM_TEST_NATIVE_SHAPE" in
      npm-other-script) echo "node $FM_TEST_NATIVE_DIR/other.js app-server --stdio" ;;
      npm-other-command) echo "node $FM_TEST_NATIVE_DIR/bin/codex exec task" ;;
      *) echo "node $FM_TEST_NATIVE_DIR/bin/codex app-server --stdio" ;;
    esac ;;
  750:ppid=) if [ "$FM_TEST_NATIVE_SHAPE" = npm-double ]; then echo 760; else echo 800; fi ;;
  760:comm=) echo node ;;
  760:args=) echo "node $FM_TEST_NATIVE_DIR/bin/codex app-server --stdio" ;;
  760:ppid=) echo 800 ;;
  800:comm=|800:args=)
    case "$FM_TEST_NATIVE_SHAPE" in
      gap|npm-gap) echo bash ;; lookalike) echo pi-helper ;; signed) echo pi-signed ;; *) echo pi ;;
    esac ;;
  800:ppid=) echo 900 ;;
  900:comm=|900:args=) echo pi-signed ;;
  900:ppid=) echo 1 ;;
  *:comm=|*:args=) echo bash ;;
  *:ppid=) echo 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  export FM_TEST_NATIVE_DIR="$dir"
  for shape in native signed interactive gap lookalike npm npm-other-script npm-other-command npm-gap npm-double; do
    expected=700
    case "$shape" in native|signed|npm) expected=800 ;; esac
    got=$(FM_TEST_NATIVE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "$shape: no owner"
    [ "$got" = "$expected" ] || fail "$shape: owner $got, expected $expected"
    pids=$(FM_TEST_NATIVE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pids')
    [ "$pids" = "$expected" ] || fail "$shape: ownership set '$pids', expected only $expected"
    printf '%s\n' "$expected" > "$dir/state/.lock"
    FM_TEST_NATIVE_SHAPE="$shape" FM_NATIVE_STATE="$dir/state" lib_eval "$fakebin" 'fm_session_lock_owned_by_self "$FM_NATIVE_STATE"' || fail "$shape: shell rejected canonical owner"
    for foreign in 750 900; do
      printf '%s\n' "$foreign" > "$dir/state/.lock"
      if FM_TEST_NATIVE_SHAPE="$shape" FM_NATIVE_STATE="$dir/state" lib_eval "$fakebin" 'fm_session_lock_owned_by_self "$FM_NATIVE_STATE"'; then
        fail "$shape: accepted launcher, outer wrapper, or foreign session $foreign"
      fi
    done
  done
  unset FM_TEST_NATIVE_DIR
  pass "Pi native owner: direct or one-hop npm-launched app-server bridge only; shell membership agrees"
}

# A Claude session running inside a native Codex child of Pi is reached first,
# so it stays its own session: the bridge never promotes the enclosing Pi into
# a Claude ancestry, and the Claude selection is what it was before the bridge.
test_claude_inside_native_codex_keeps_its_own_session() {
  local dir fakebin pids got
  dir="$TMP_ROOT/claude-in-native"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field=$2 pid=$4
case "$pid:$field" in
  600:comm=|600:args=) echo claude ;;
  600:ppid=) echo 700 ;;
  700:comm=) echo /Applications/ChatGPT.app/Contents/Resources/codex ;;
  700:args=) echo '/Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --stdio' ;;
  700:ppid=) echo 800 ;;
  800:comm=|800:args=) echo pi ;;
  800:ppid=) echo 900 ;;
  900:comm=|900:args=) echo pi-signed ;;
  900:ppid=) echo 1 ;;
  *:comm=|*:args=) echo bash ;;
  *:ppid=) echo 600 ;;
esac
SH
  chmod +x "$fakebin/ps"
  pids=$(lib_eval "$fakebin" 'fm_harness_ancestry_pids' | tr '\n' ' ')
  [ "$pids" = "600 700 " ] || fail "Claude inside native Codex: ownership set '$pids', expected '600 700 '"
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "Claude inside native Codex: no owner"
  [ "$got" = 700 ] || fail "Claude inside native Codex: lock owner $got, expected the outermost Claude-run pid 700"
  for own in 600 700; do
    printf '%s\n' "$own" > "$dir/state/.lock"
    FM_NATIVE_STATE="$dir/state" lib_eval "$fakebin" 'fm_session_lock_owned_by_self "$FM_NATIVE_STATE"' || fail "Claude inside native Codex: rejected its own ancestry pid $own"
  done
  printf '800\n' > "$dir/state/.lock"
  if FM_NATIVE_STATE="$dir/state" lib_eval "$fakebin" 'fm_session_lock_owned_by_self "$FM_NATIVE_STATE"'; then
    fail "Claude inside native Codex: the enclosing Pi entered the Claude session's ownership set"
  fi
  pass "a Claude session inside Pi's native Codex child stays separate from the enclosing Pi"
}

test_pi_native_real_processes() {
  local dir out
  dir="$TMP_ROOT/pi-native-processes"
  mkdir -p "$dir/state" "$dir/bin" "$dir/lib/node_modules/@openai/codex/bin"
  ln -s /bin/bash "$dir/pi"
  ln -s /bin/bash "$dir/codex"
  cat > "$dir/app-server" <<'SH'
#!/usr/bin/env bash
"$FM_NATIVE_ROOT/bin/fm-lock.sh" || exit
. "$FM_NATIVE_ROOT/bin/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$FM_HOME/state" || exit
[ "$(cat "$FM_HOME/state/.lock")" = "$FM_TEST_PI_PID" ] || exit 1
printf '%s\n' "$$" >> "$FM_HOME/state/children"
SH
  # The installed npm launcher's shape: a node script reached through a bin
  # symlink that spawns the vendor binary with its own arguments and stays its
  # parent.
  cat > "$dir/lib/node_modules/@openai/codex/bin/codex.js" <<'JS'
#!/usr/bin/env node
import { spawn } from "node:child_process";
const child = spawn(process.env.FM_TEST_VENDOR_CODEX, process.argv.slice(2), { stdio: "inherit" });
child.on("exit", (code, signal) => process.exit(signal ? 1 : code));
JS
  chmod +x "$dir/lib/node_modules/@openai/codex/bin/codex.js"
  printf '{"type":"module"}\n' > "$dir/lib/node_modules/@openai/codex/package.json"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$dir/bin/codex"
  cat > "$dir/pi-session" <<'SH'
#!/usr/bin/env bash
cd "$FM_HOME" || exit 1
export FM_TEST_PI_PID=$$ FM_TEST_VENDOR_CODEX="$FM_HOME/codex"
./codex app-server --stdio || exit
./codex app-server --stdio || exit
expected=2
if command -v node >/dev/null 2>&1; then
  "$FM_HOME/bin/codex" app-server --stdio || exit
  "$FM_HOME/bin/codex" app-server --stdio || exit
  expected=4
fi
[ "$(cat state/.lock)" = "$$" ] || exit 1
[ "$(sort -u state/children | wc -l | tr -d ' ')" = "$expected" ] || exit 1
SH
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_NATIVE_ROOT="$ROOT" "$dir/pi" "$dir/pi-session" 2>&1) || fail "real Pi/native tree: $out"
  pass "real Pi/native tree: lock acquisition and shell checks survive child replacement, direct and npm-launched"
}

test_pi_native_real_processes
test_pi_native_owner
test_claude_inside_native_codex_keeps_its_own_session
test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
