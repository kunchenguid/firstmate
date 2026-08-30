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
FAKE_PROC_ROOT="$TMP_ROOT/fixture-proc-unavailable"

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
  FM_PROC_ROOT_OVERRIDE="$FAKE_PROC_ROOT" PATH="$fakebin:$PATH" bash -c "
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
  local dir fakebin got diagnostic
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
  diagnostic=$(lib_eval "$fakebin" 'fm_harness_ancestry_diagnostic 900') \
    || fail "the gap diagnostic could not inspect the contiguous harness run"
  assert_contains "$diagnostic" 'pid=910' \
    "diagnostic reports the non-harness gap that ends the contiguous run"
  assert_not_contains "$diagnostic" 'hop=3 pid=920' \
    "diagnostic does not cross the non-harness gap into an unrelated harness"
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

test_unrecognized_ancestry_refuses_with_observed_evidence() {
  local dir fakebin out err status home
  dir="$TMP_ROOT/unrecognized-diagnostic"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
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
  701:comm=) printf '%s\n' herdr-worker ;;
  701:args=) printf '%s\n' 'herdr worker --lane remote' ;;
  701:ppid=) printf '%s\n' 702 ;;
  702:comm=) printf '%s\n' bash ;;
  702:args=) printf '%s\n' 'bash /opt/remote-job/worker.sh' ;;
  702:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' herdr-worker ;;
  *:args=) printf '%s\n' 'herdr worker --lane remote' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(FM_PROC_ROOT_OVERRIDE="$FAKE_PROC_ROOT" PATH="$fakebin:$PATH" \
    bash -c '. "$0"; fm_harness_ancestry_diagnostic 701' "$LIB") \
    || fail "the read-only ancestry diagnostic failed"
  assert_contains "$out" 'pid=701' "diagnostic names the inspected pid"
  assert_contains "$out" 'comm=herdr-worker' "diagnostic names the observed command"
  assert_contains "$out" 'args=redacted' "diagnostic redacts the observed arguments"
  assert_not_contains "$out" 'herdr\ worker\ --lane\ remote' "diagnostic does not expose process arguments"
  assert_contains "$out" 'match=reject:basename\,path-component\,interpreter-args\,cursor-structural' \
    "diagnostic names every rejected shared-matcher check"
  assert_contains "$out" 'result=no-verified-harness' "diagnostic preserves fail-closed absence of identity"

  err="$dir/fm-lock.err"
  FM_PROC_ROOT_OVERRIDE="$FAKE_PROC_ROOT" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-lock.sh" >"$dir/fm-lock.out" 2>"$err"
  status=$?
  expect_code 1 "$status" "unrecognized ancestry must still refuse the session lock"
  assert_contains "$(cat "$err")" 'inspected process evidence follows' \
    "lock refusal directs the operator to the diagnostic evidence"
  assert_contains "$(cat "$err")" 'comm=herdr-worker' \
    "lock refusal includes the observed command"
  [ ! -e "$home/state/.lock" ] || fail "unrecognized ancestry wrote a session lock"
  pass "session-lock: unrecognized process ancestry refuses loudly with observed matcher evidence"
}

test_remote_codex_session_binding_claims_only_the_matching_session() {
  local dir fakebin proc home session other out mode codex_root codex_script codex_launcher codex_exe
  local copied_script copied_exe copied_nvm_root copied_nvm_script copied_nvm_launcher copied_nvm_exe
  local standalone_release standalone_unlinked_release standalone_current standalone_launcher
  local copied_standalone_release vscode_exe chatgpt_exe system_home actual_system_home real_system_home
  local real_lib codex_lib node_bin binding HOME
  dir="$TMP_ROOT/remote-codex-binding"
  fakebin=$(fm_fakebin "$dir")
  proc="$dir/proc"
  home="$dir/home"
  HOME=$home
  node_bin=$(command -v node)
  session=4d5f9e9a-0e7c-4d32-9f3a-6fd1e2eb4a54
  other=16b9797f-12d9-4645-b3af-0d0f6c2e8b8a
  codex_root="$home/.nvm/versions/node/v24.19.0"
  codex_script="$codex_root/lib/node_modules/@openai/codex/bin/codex.js"
  codex_launcher="$codex_root/bin/codex"
  codex_exe="$codex_root/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  copied_script="$dir/copied/node_modules/@openai/codex/bin/codex.js"
  copied_exe="$dir/copied/codex"
  copied_nvm_root="$dir/copied-nvm/.nvm/versions/node/v24.19.0"
  copied_nvm_script="$copied_nvm_root/lib/node_modules/@openai/codex/bin/codex.js"
  copied_nvm_launcher="$copied_nvm_root/bin/codex"
  copied_nvm_exe="$copied_nvm_root/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  standalone_release="$home/.codex/packages/standalone/releases/0.146.0/bin/codex"
  standalone_unlinked_release="$home/.codex/packages/standalone/releases/0.145.0/bin/codex"
  standalone_current="$home/.codex/packages/standalone/current"
  standalone_launcher="$home/.local/bin/codex"
  copied_standalone_release="$dir/copied-standalone/.codex/packages/standalone/releases/0.146.0/bin/codex"
  vscode_exe="$home/.vscode/extensions/openai.chatgpt-26.825.31414-darwin-arm64/bin/macos-aarch64/codex"
  chatgpt_exe="$home/Applications/ChatGPT.app/Contents/Resources/codex"
  mkdir -p "$proc/4242" "$home/state" "$codex_root/bin" "$(dirname "$codex_script")" \
    "$(dirname "$codex_exe")" "$(dirname "$copied_script")" "$(dirname "$copied_exe")" \
    "$copied_nvm_root/bin" "$(dirname "$copied_nvm_script")" "$(dirname "$copied_nvm_exe")" \
    "$(dirname "$standalone_release")" "$(dirname "$standalone_unlinked_release")" \
    "$(dirname "$standalone_launcher")" "$(dirname "$copied_standalone_release")" \
    "$(dirname "$vscode_exe")" "$(dirname "$chatgpt_exe")"
  system_home=$(CDPATH='' cd -P -- "$home" && pwd -P)
  real_lib=$LIB
  real_system_home=$(unset HOME; CDPATH='' cd ~ && pwd -P)
  actual_system_home=$(HOME="$home" bash -c '. "$1"; fm_codex_system_home' _ "$real_lib") \
    || fail "the shared matcher could not resolve the invoking user's system home"
  [ "$actual_system_home" = "$real_system_home" ] \
    || fail "the shared matcher trusted HOME instead of the invoking user's system home"
  codex_lib="$dir/fm-session-lock-lib-fixture.sh"
  {
    printf '. %q\n' "$real_lib"
    printf 'fm_codex_system_home() { printf "%%s\\n" %q; }\n' "$system_home"
  } > "$codex_lib"
  LIB=$codex_lib
  printf '#!/usr/bin/env node\n' > "$codex_script"
  printf '#!/usr/bin/env node\n' > "$copied_script"
  printf '#!/usr/bin/env node\n' > "$copied_nvm_script"
  : > "$codex_exe"
  : > "$copied_exe"
  : > "$copied_nvm_exe"
  : > "$standalone_release"
  : > "$standalone_unlinked_release"
  : > "$copied_standalone_release"
  : > "$vscode_exe"
  : > "$chatgpt_exe"
  chmod +x "$codex_script" "$copied_script" "$copied_nvm_script" "$codex_exe" "$copied_exe" \
    "$copied_nvm_exe" "$standalone_release" "$standalone_unlinked_release" \
    "$copied_standalone_release" "$vscode_exe" "$chatgpt_exe"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$codex_launcher"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$copied_nvm_launcher"
  ln -s releases/0.146.0 "$standalone_current"
  ln -s "$standalone_current/bin/codex" "$standalone_launcher"
  ln -s "$node_bin" "$proc/4242/exe"
  mkdir -p "$proc/4343"
  ln -s "$standalone_release" "$proc/4343/exe"
  printf 'CODEX_SESSION_ID=%s\0PATH=/usr/bin\0' "$session" > "$proc/4242/environ"
  printf 'CODEX_SESSION_ID=%s\0PATH=/usr/bin\0' "$session" > "$proc/4343/environ"
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
  4242:comm=)
    case "${FM_TEST_CODEX_SHAPE:-exact}" in
      decoy) printf '%s\n' node ;;
      helper-script) printf '%s\n' node ;;
      copied-script) printf '%s\n' node ;;
      copied-nvm-script) printf '%s\n' node ;;
      launcher) printf '%s\n' "$FM_TEST_NODE_BIN" ;;
      script) printf '%s\n' node ;;
      vendor-name) printf '%s\n' codex-aarch64-a ;;
      helper) printf '%s\n' codex-helper ;;
      login) printf '%s\n' -codex ;;
      double-login) printf '%s\n' --codex ;;
      *) printf '%s\n' codex ;;
    esac
    ;;
  4242:args=)
    case "${FM_TEST_CODEX_SHAPE:-exact}" in
      decoy) printf '%s\n' 'node -e noop /tmp/codex/data' ;;
      helper-script) printf '%s\n' 'node /tmp/codex/helper.js' ;;
      copied-script) printf 'node %s\n' "$FM_TEST_COPIED_SCRIPT" ;;
      copied-nvm-script) printf 'node %s\n' "$FM_TEST_COPIED_NVM_SCRIPT" ;;
      launcher) printf '%s %s --interactive\n' "$FM_TEST_NODE_BIN" "$FM_TEST_CODEX_LAUNCHER" ;;
      script) printf 'node %s\n' "$FM_TEST_CODEX_SCRIPT" ;;
      helper) printf '%s\n' 'codex-helper --serve' ;;
      login) printf '%s\n' '-codex --interactive' ;;
      double-login) printf '%s\n' '--codex --interactive' ;;
      *) printf '%s\n' 'codex --interactive' ;;
    esac
    ;;
  4242:ppid=) printf '%s\n' 1 ;;
  4343:comm=) printf '%s\n' codex-linux-x64 ;;
  4343:args=) printf '%s\n' 'codex --interactive' ;;
  4343:ppid=)
    case "${FM_TEST_CODEX_PAIR:-related}" in
      related) printf '%s\n' 4242 ;;
      *) printf '%s\n' 1 ;;
    esac
    ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /workspace/bin/fm-lock.sh' ;;
  *:ppid=)
    if [ "${FM_TEST_NAMESPACE_TERMINATED:-0}" = 1 ]; then
      printf '%s\n' 1
    else
      printf '%s\n' 4242
    fi
    ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_PLATFORM:-Linux}"
SH
  chmod +x "$fakebin/uname"
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1:${FM_TEST_PLATFORM:-Linux}" in
  -f:Darwin) printf '%s\n' 600 ;;
  -f:*) printf '%s\n' 'gnu-filesystem-format' ;;
  -c:*) printf '%s\n' 600 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/stat"
  if FM_TEST_CODEX_SHAPE=decoy FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_requirement_publish "$FM_HOME/state" "$FM_HOME" s1.2.3
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a generic interpreter with a later Codex-shaped argument became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected generic interpreter evidence published a Codex binding"
  if FM_TEST_CODEX_SHAPE=helper-script FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a generic interpreter with a helper script under a Codex directory became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected Codex-directory helper evidence published a binding"
  if FM_TEST_CODEX_SHAPE=copied-script FM_TEST_COPIED_SCRIPT="$copied_script" \
    FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a copied Codex package tree became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected copied Codex script evidence published a binding"
  if FM_TEST_CODEX_SHAPE=copied-nvm-script FM_TEST_COPIED_NVM_SCRIPT="$copied_nvm_script" \
    FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a copied NVM-shaped Codex script tree became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected copied NVM-shaped script evidence published a binding"
  if FM_TEST_CODEX_SHAPE=helper FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a Codex-named helper process became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected Codex helper evidence published a binding"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; fm_harness_process_matches codex "codex --interactive" codex' _ "$LIB"; then
    fail "a bare Codex launcher name became identity authority without process evidence"
  fi
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a Node executable reached through a Codex-named symlink became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected Node symlink evidence published a Codex binding"
  rm -f "$proc/4242/exe"
  ln -s "$copied_exe" "$proc/4242/exe"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a copied executable named Codex outside the supported install layout became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected copied executable evidence published a Codex binding"
  rm -f "$proc/4242/exe"
  ln -s "$copied_nvm_exe" "$proc/4242/exe"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a copied NVM-shaped Codex executable tree became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected copied NVM-shaped executable evidence published a binding"
  rm -f "$proc/4242/exe"
  ln -s "$copied_standalone_release" "$proc/4242/exe"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a copied standalone Codex release tree became binding authority"
  fi
  [ ! -e "$home/state/.fm-codex-session-binding" ] \
    || fail "rejected copied standalone evidence published a binding"
  rm -f "$proc/4242/exe"
  ln -s "$standalone_unlinked_release" "$proc/4242/exe"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB"; then
    fail "an unrelated installed standalone release became binding authority"
  fi
  rm -f "$proc/4242/exe"
  ln -s "$standalone_release" "$proc/4242/exe"
  FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "the active home standalone Codex release was not recognized"
  rm -f "$proc/4242/exe"
  ln -s "$codex_exe" "$proc/4242/exe"
  FM_TEST_CODEX_SHAPE=login FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "a login-style process backed by a verified Codex executable lost its supported identity"
  rm -f "$proc/4242/exe"
  ln -s "$node_bin" "$proc/4242/exe"
  if FM_TEST_CODEX_SHAPE=double-login FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB"; then
    fail "more than one leading dash became Codex identity authority"
  fi
  rm -f "$proc/4242/exe"
  ln -s "$(command -v node)" "$proc/4242/exe"
  FM_TEST_CODEX_SHAPE=script FM_TEST_CODEX_SCRIPT="$codex_script" \
    FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "the installed Codex script entrypoint was not recognized"
  FM_TEST_CODEX_SHAPE=launcher FM_TEST_NODE_BIN="$node_bin" FM_TEST_CODEX_LAUNCHER="$codex_launcher" \
    FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "the installed NVM Codex launcher was not recognized"
  rm -f "$proc/4242/exe"
  ln -s "$vscode_exe" "$proc/4242/exe"
  FM_TEST_PLATFORM=Darwin FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "the installed VS Code Codex executable was not recognized"
  FM_TEST_CODEX_SHAPE=vendor-name FM_TEST_PLATFORM=Darwin FM_PROC_ROOT_OVERRIDE="$proc" \
    PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "a verified Darwin Codex executable was rejected for its vendor-controlled process name"
  rm -f "$proc/4242/exe"
  ln -s "$chatgpt_exe" "$proc/4242/exe"
  FM_TEST_PLATFORM=Darwin FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_codex_host_agent_matches 4242' _ "$LIB" \
    || fail "the installed ChatGPT Codex executable was not recognized"
  rm -f "$proc/4242/exe"
  ln -s "$node_bin" "$proc/4242/exe"
  out=$(FM_TEST_CODEX_SHAPE=launcher FM_TEST_NODE_BIN="$node_bin" \
    FM_TEST_CODEX_LAUNCHER="$codex_launcher" FM_PROC_ROOT_OVERRIDE="$proc" \
    PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_host_agent_owner_for_pids 4242 4343 || exit 1
      printf "%s:%s:%s\n" "$FM_CODEX_HOST_OWNER_PID" \
        "$FM_CODEX_HOST_OWNER_VERIFIED_COUNT" "$FM_CODEX_HOST_OWNER_CANONICAL_COUNT"
    ' _ "$LIB") || fail "a related Codex launcher and native child were treated as ambiguous"
  [ "$out" = 4343:2:1 ] \
    || fail "canonical Codex process selection returned '$out', expected 4343:2:1"
  if FM_TEST_CODEX_PAIR=unrelated FM_TEST_CODEX_SHAPE=launcher FM_TEST_NODE_BIN="$node_bin" \
    FM_TEST_CODEX_LAUNCHER="$codex_launcher" FM_PROC_ROOT_OVERRIDE="$proc" \
    PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_host_agent_owner_for_pids 4242 4343
    ' _ "$LIB"; then
    fail "unrelated installed Codex processes collapsed to one canonical owner"
  fi
  rm -f "$proc/4242/exe"
  ln -s "$standalone_release" "$proc/4242/exe"
  binding="$home/state/.fm-codex-session-binding"
  mkdir "$binding"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session"; then
    fail "a directory at the binding pathname was reported as a successful publication"
  fi
  [ -d "$binding" ] || fail "rejected binding publication replaced its non-regular destination"
  rmdir "$binding"
  FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 0; }
      fm_codex_home_binding_requirement_publish "$FM_HOME/state" "$FM_HOME" s1.2.3
      fm_codex_home_binding_publish "$FM_HOME/state" "$FM_HOME" s1.2.3 4242 "$2"
    ' _ "$LIB" "$session" || fail "verified host-side Codex evidence did not publish the binding"
  rm -f "$proc/4242/exe" "$proc/4242/environ"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '
      . "$1"
      kill() { return 1; }
      CODEX_SESSION_ID="$2" fm_harness_ancestry_pid
    ' _ "$LIB" "$session") || fail "namespace-local Codex session did not consume its session binding"
  [ "$out" = 4242 ] || fail "remote Codex binding resolved '$out', expected host agent pid 4242"
  [ -f "$binding" ] && [ ! -L "$binding" ] || fail "remote Codex binding record was not published"
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    mode=$(stat -f '%Lp' "$binding" 2>/dev/null)
  else
    mode=$(stat -c '%a' "$binding" 2>/dev/null)
  fi
  [ "$mode" = 600 ] || fail "remote Codex binding record mode was $mode, not 600"
  out=$(FM_TEST_NAMESPACE_TERMINATED=1 FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" \
    FM_HOME="$home" CODEX_SESSION_ID="$session" "$ROOT/bin/fm-harness.sh" 2>"$dir/harness.err") \
    || fail "namespace-local Codex binding did not preserve the harness identity"
  [ "$out" = codex ] || fail "namespace-local Codex binding detected harness '$out', expected codex"
  printf '4242\n' > "$home/state/.lock"
  out=$(FM_TEST_NAMESPACE_TERMINATED=1 FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" \
    FM_HOME="$home" CODEX_SESSION_ID="$session" "$ROOT/bin/fm-lock.sh" status) \
    || fail "namespace-local Codex lock status could not inspect its binding"
  [ "$out" = 'lock: held by live harness pid 4242' ] \
    || fail "namespace-local Codex lock status reported '$out'"
  out=$(FM_TEST_NAMESPACE_TERMINATED=1 FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" \
    FM_HOME="$home" CODEX_SESSION_ID="$other" "$ROOT/bin/fm-lock.sh" status) \
    || fail "different Codex session lock status could not inspect the binding"
  [ "$out" = 'lock: stale (pid 4242 dead or not a harness)' ] \
    || fail "different Codex session trusted the caller-bound lock: '$out'"
  printf 'harness=codex\nhome=%s\nspawn_gen=s9.9.9\n' "$home" \
    > "$home/state/.fm-codex-session-binding-required"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID="$session" \
    bash -c '. "$1"; kill() { return 0; }; fm_harness_ancestry_pid' _ "$LIB" >/dev/null 2>&1; then
    fail "a stale remote Codex binding fell back to visible Codex ancestry"
  fi
  printf 'harness=codex\nhome=%s\nspawn_gen=s1.2.3\n' "$home" \
    > "$home/state/.fm-codex-session-binding-required"
  if FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID="$other" \
    bash -c '. "$1"; kill() { return 0; }; fm_harness_ancestry_pid' _ "$LIB" >/dev/null 2>&1; then
    fail "a different Codex session claimed the remote home through the binding"
  fi
  FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID="$session" \
    bash -c '. "$1"; kill() { return 0; }; fm_session_lock_owned_by_self "$FM_HOME/state"' _ "$LIB" \
    || fail "the matching remote Codex session did not recognize its published lock"
  rm -f "$home/state/.fm-codex-session-binding-required" "$home/state/.fm-codex-session-binding"
  ln -s "$codex_exe" "$proc/4242/exe"
  printf 'CODEX_SESSION_ID=%s\0PATH=/usr/bin\0' "$session" > "$proc/4242/environ"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" PATH="$fakebin:$PATH" FM_HOME="$home" \
    bash -c '. "$1"; kill() { return 0; }; fm_harness_ancestry_pid' _ "$LIB") \
    || fail "ordinary ancestry stopped working without a remote binding requirement"
  [ "$out" = 4242 ] || fail "ordinary ancestry resolved '$out', expected visible Codex pid 4242"
  pass "session-lock: remote Codex binds a host agent only to its matching session identity"
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

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_unrecognized_ancestry_refuses_with_observed_evidence
test_remote_codex_session_binding_claims_only_the_matching_session
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
