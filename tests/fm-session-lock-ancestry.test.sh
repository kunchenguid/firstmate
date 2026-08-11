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

test_mainthread_cursor_session_is_identified() {
  local dir fakebin proc_root got trusted_dir trusted_cursor identity_file boundary_file task_id
  dir="$TMP_ROOT/mainthread-cursor"
  fakebin=$(fm_fakebin "$dir")
  proc_root="$dir/proc"
  trusted_dir="$FM_TEST_HOME/.local/share/cursor-agent/versions/current"
  trusted_cursor="$trusted_dir/cursor-agent"
  task_id=mainthread-cursor
  identity_file="$dir/state/.$task_id.cursor-identity.abc123"
  boundary_file="$dir/state/.$task_id.cursor-boundary.abc123.proof.launch"
  fm_fake_cursor_alias "$trusted_dir" cursor-agent
  mkdir -p "$FM_TEST_HOME/.local/bin"
  ln -sf "$trusted_cursor" "$FM_TEST_HOME/.local/bin/cursor-agent"
  mkdir -p "$dir/state" "$proc_root/710"
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
  710:comm=) printf '%s\n' "${FM_TEST_CURSOR_COMM:-MainThread}" ;;
  710:args=) printf '%s\n' "${FM_TEST_CURSOR_ARGS:?}" ;;
  710:ppid=) printf '%s\n' 1 ;;
  710:lstart=) printf '%s\n' 'Mon Jan  1 00:00:00 2001' ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash tests/run.sh' ;;
  *:ppid=) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '710\n' > "$dir/state/.lock"
  printf 'abc123\n' > "$dir/state/$task_id.cursor-launch-token"
  : > "$dir/state/$task_id.meta"
  printf '710\tlstart=Mon Jan  1 00:00:00 2001\t\n' > "$boundary_file"
  printf 'abc123\t%s\n' "$trusted_cursor" >> "$boundary_file"
  printf 'abc123\t%s\n' "$trusted_cursor" > "$identity_file"
  printf 'FM_CURSOR_EXECUTABLE=%s\0FM_CURSOR_IDENTITY_FILE=%s\0FM_CURSOR_LAUNCH_TOKEN=abc123\0FM_CURSOR_BOUNDARY_LAUNCH_FILE=%s\0' \
    "$trusted_cursor" "$identity_file" "$boundary_file" > "$proc_root/710/environ"
  # Accepted: Cursor's own install path behind MainThread, under either
  # installed name. The legacy alias identifies through the cursor-agent
  # install tree it lives in, never through its own generic name.
  local accepted=(
    "MainThread|$FM_TEST_HOME/.local/share/cursor-agent/versions/current/cursor-agent --force"
    "cursor-agent|$FM_TEST_HOME/.local/share/cursor-agent/versions/current/cursor-agent --force"
  )
  # Rejected: an unrelated executable named agent, an unrelated install tree
  # whose directory merely happens to be named agent, another program running
  # from a path with an agent/ component, a later argv token shaped like
  # .../cursor-agent (must never classify via args after argv0), and a bare
  # MainThread with no Cursor evidence at all. Any of these owning the lock
  # would let an unrelated process claim this home's session.
  local rejected=(
    'agent|/opt/agent --serve'
    'MainThread|/opt/agent/versions/current/agent --force'
    'MainThread|/usr/bin/node /srv/cursor-agent/app.js'
    'MainThread|/usr/bin/node /tmp/cursor-agent --foo'
    'MainThread|/usr/bin/node /tmp/claude --foo'
    'MainThread|/usr/bin/node /tmp/codex --foo'
    'node|/usr/bin/node /tmp/cursor-agent --foo'
    'MainThread|/usr/bin/node /srv/agent/app.js'
    'MainThread|MainThread'
  )
  local entry comm args
  for entry in "${accepted[@]}"; do
    comm=${entry%%|*}; args=${entry#*|}
    printf '%s\0' "${args%% *}" > "$proc_root/710/cmdline"
    got=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_CURSOR_COMM="$comm" FM_TEST_CURSOR_ARGS="$args" \
      lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "Cursor session '$args' was not found in ancestry"
    [ "$got" = 710 ] || fail "Cursor ancestry for '$args' resolved '$got', expected 710"
    FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_CURSOR_COMM="$comm" FM_TEST_CURSOR_ARGS="$args" \
      lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "Cursor session '$args' did not own its lock"
  done
  for entry in "${rejected[@]}"; do
    comm=${entry%%|*}; args=${entry#*|}
    rm -f "$proc_root/710/environ"
    printf '%s\0' "${args%% *}" > "$proc_root/710/cmdline"
    if FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_CURSOR_COMM="$comm" FM_TEST_CURSOR_ARGS="$args" \
      lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null; then
      fail "a non-Cursor process '$args' was identified as a harness ancestor"
    fi
    if FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_CURSOR_COMM="$comm" FM_TEST_CURSOR_ARGS="$args" \
      lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "a non-Cursor process '$args' claimed the home's session lock"
    fi
  done
  pass "session-lock: Cursor ancestry accepts proven Cursor identity and rejects unrelated agents"
}

test_running_cursor_version_survives_binary_update() {
  local dir fakebin proc_root got old_dir new_dir old_cursor new_cursor identity_file boundary_file task_id
  dir="$TMP_ROOT/mainthread-cursor-update"
  fakebin=$(fm_fakebin "$dir")
  proc_root="$dir/proc"
  old_dir="$FM_TEST_HOME/.local/share/cursor-agent/versions/v1"
  new_dir="$FM_TEST_HOME/.local/share/cursor-agent/versions/v2"
  old_cursor="$old_dir/cursor-agent"
  new_cursor="$new_dir/cursor-agent"
  task_id=mainthread-cursor-update
  identity_file="$dir/state/.$task_id.cursor-identity.abc123"
  boundary_file="$dir/state/.$task_id.cursor-boundary.abc123.proof.launch"
  fm_fake_cursor_alias "$old_dir" cursor-agent
  fm_fake_cursor_alias "$new_dir" cursor-agent
  mkdir -p "$FM_TEST_HOME/.local/bin" "$dir/state" "$proc_root/720"
  ln -sf "$new_cursor" "$FM_TEST_HOME/.local/bin/cursor-agent"
  ln -sf "$new_cursor" "$fakebin/cursor-agent"
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
  720:comm=) printf '%s\n' MainThread ;;
  720:args=) printf '%s\n' "$FM_TEST_CURSOR_ARGS" ;;
  720:ppid=) printf '%s\n' 1 ;;
  720:lstart=) printf '%s\n' 'Mon Jan  1 00:00:00 2001' ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash tests/run.sh' ;;
  *:ppid=) printf '%s\n' 720 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '720\n' > "$dir/state/.lock"
  printf 'abc123\n' > "$dir/state/$task_id.cursor-launch-token"
  : > "$dir/state/$task_id.meta"
  printf '720\tlstart=Mon Jan  1 00:00:00 2001\t\n' > "$boundary_file"
  printf 'abc123\t%s\n' "$old_cursor" >> "$boundary_file"
  printf '%s\0--force\0' "$old_cursor" > "$proc_root/720/cmdline"
  printf 'abc123\t%s\n' "$old_cursor" > "$identity_file"
  printf 'FM_CURSOR_EXECUTABLE=%s\0FM_CURSOR_IDENTITY_FILE=%s\0FM_CURSOR_LAUNCH_TOKEN=abc123\0FM_CURSOR_BOUNDARY_LAUNCH_FILE=%s\0' \
    "$old_cursor" "$identity_file" "$boundary_file" > "$proc_root/720/environ"
  got=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_CURSOR_ARGS="$old_cursor --force" \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a running pre-update Cursor version was not found in ancestry"
  [ "$got" = 720 ] || fail "pre-update Cursor ancestry resolved '$got', expected 720"
  pass "session-lock: a running Cursor version remains valid after alias update"
}

test_relative_process_names_cannot_claim_cursor() {
  local dir
  dir="$TMP_ROOT/relative-cursor-name"
  fm_fake_cursor_alias "$dir" node
  if (
    cd "$dir" || exit 1
    HOME="$FM_TEST_HOME" PATH="$dir:/usr/bin:/bin" bash -c \
      ". '$ROOT/bin/fm-cursor-lib.sh'; fm_cursor_process_matches node 'node --force' node"
  ); then
    fail "a relative node process name claimed Cursor identity"
  fi
  pass "session-lock: relative process names cannot claim Cursor identity"
}

test_cursor_identity_does_not_execute_pid_executable() {
  local dir proc_root executable side_effect got untrusted identity_file boundary_file task_id spoof_identity spoof_boundary
  dir="$TMP_ROOT/cursor-no-probe"
  proc_root="$dir/proc"
  executable="$FM_TEST_HOME/.local/share/cursor-agent/versions/no-probe/cursor-agent"
  side_effect="$dir/executed"
  task_id=cursor-no-probe
  identity_file="$dir/state/.$task_id.cursor-identity.abc123"
  boundary_file="$dir/state/.$task_id.cursor-boundary.abc123.proof.launch"
  mkdir -p "$proc_root/730" "$(dirname "$executable")" "$dir/state"
  cat > "$dir/ps" <<'SH'
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
  730:ppid=) printf '%s\n' 1 ;;
  730:lstart=) printf '%s\n' 'Mon Jan  1 00:00:00 2001' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/ps"
  printf 'abc123\n' > "$dir/state/$task_id.cursor-launch-token"
  : > "$dir/state/$task_id.meta"
  cat > "$executable" <<SH
#!/usr/bin/env bash
: > "$side_effect"
printf 'Start the Cursor Agent\n'
SH
  chmod +x "$executable"
  ln -s "$executable" "$proc_root/730/exe"
  printf '730\tlstart=Mon Jan  1 00:00:00 2001\t\n' > "$boundary_file"
  printf 'abc123\t%s\n' "$executable" >> "$boundary_file"
  printf 'abc123\t%s\n' "$executable" > "$identity_file"
  printf 'FM_CURSOR_EXECUTABLE=%s\0FM_CURSOR_IDENTITY_FILE=%s\0FM_CURSOR_LAUNCH_TOKEN=abc123\0FM_CURSOR_BOUNDARY_LAUNCH_FILE=%s\0' \
    "$executable" "$identity_file" "$boundary_file" > "$proc_root/730/environ"
  got=$(HOME="$FM_TEST_HOME" PATH="$dir:$PATH" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c ". '$ROOT/bin/fm-cursor-lib.sh'; fm_cursor_process_matches node 'node $executable --help' /usr/bin/node 730 && printf yes")
  [ "$got" = yes ] || fail "trusted Cursor launch metadata did not identify process"
  [ ! -e "$side_effect" ] || fail "process identity executed unrelated PID executable"
  untrusted="$dir/untrusted-cursor-agent"
  cp "$executable" "$untrusted"
  chmod +x "$untrusted"
  mkdir -p "$proc_root/731"
  ln -s "$untrusted" "$proc_root/731/exe"
  spoof_identity="$dir/state/.cursor-self-declared.cursor-identity.abc123"
  spoof_boundary="$dir/state/.cursor-self-declared.cursor-boundary.abc123.proof.launch"
  printf 'abc123\t%s\n' "$untrusted" > "$spoof_identity"
  printf '731\tlstart=Mon Jan  1 00:00:00 2001\t\n' > "$spoof_boundary"
  printf 'abc123\t%s\n' "$untrusted" >> "$spoof_boundary"
  printf 'FM_CURSOR_EXECUTABLE=%s\0FM_CURSOR_IDENTITY_FILE=%s\0FM_CURSOR_LAUNCH_TOKEN=abc123\0FM_CURSOR_BOUNDARY_LAUNCH_FILE=%s\0' \
    "$untrusted" "$spoof_identity" "$spoof_boundary" > "$proc_root/731/environ"
  if HOME="$FM_TEST_HOME" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c ". '$ROOT/bin/fm-cursor-lib.sh'; fm_cursor_process_matches node 'node $untrusted --help' /usr/bin/node 731"; then
    fail "self-declared non-Cursor executable claimed Cursor identity"
  fi
  pass "session-lock: Cursor identity does not execute PID executables"
}

test_mainthread_cursor_argv0_with_spaces_is_identified() {
  local dir fakebin proc_root got trusted_dir trusted_cursor identity_file boundary_file task_id
  dir="$TMP_ROOT/mainthread-cursor-spaces"
  fakebin=$(fm_fakebin "$dir")
  proc_root="$dir/proc"
  trusted_dir="$FM_TEST_HOME/.local/share/cursor-agent/versions/current release"
  trusted_cursor="$trusted_dir/cursor-agent"
  task_id=mainthread-cursor-spaces
  identity_file="$dir/state/.$task_id.cursor-identity.abc123"
  boundary_file="$dir/state/.$task_id.cursor-boundary.abc123.proof.launch"
  fm_fake_cursor_alias "$trusted_dir" cursor-agent
  mkdir -p "$FM_TEST_HOME/.local/bin"
  ln -sf "$trusted_cursor" "$FM_TEST_HOME/.local/bin/cursor-agent"
  mkdir -p "$dir/state" "$proc_root/710"
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
  710:comm=) printf '%s\n' MainThread ;;
  710:args=) printf '%s\n' "$FM_TEST_HOME/.local/share/cursor-agent/versions/current release/cursor-agent --force" ;;
  710:ppid=) printf '%s\n' 1 ;;
  710:lstart=) printf '%s\n' 'Mon Jan  1 00:00:00 2001' ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash tests/run.sh' ;;
  *:ppid=) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf 'abc123\n' > "$dir/state/$task_id.cursor-launch-token"
  : > "$dir/state/$task_id.meta"
  printf '710\tlstart=Mon Jan  1 00:00:00 2001\t\n' > "$boundary_file"
  printf 'abc123\t%s\n' "$trusted_cursor" >> "$boundary_file"
  printf '%s\0--force\0' "$FM_TEST_HOME/.local/share/cursor-agent/versions/current release/cursor-agent" > "$proc_root/710/cmdline"
  printf 'abc123\t%s\n' "$trusted_cursor" > "$identity_file"
  printf 'FM_CURSOR_EXECUTABLE=%s\0FM_CURSOR_IDENTITY_FILE=%s\0FM_CURSOR_LAUNCH_TOKEN=abc123\0FM_CURSOR_BOUNDARY_LAUNCH_FILE=%s\0' \
    "$trusted_cursor" "$identity_file" "$boundary_file" > "$proc_root/710/environ"
  printf '710\n' > "$dir/state/.lock"
  got=$(FM_PROC_ROOT_OVERRIDE="$proc_root" \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "Cursor argv0 with spaces was not found in ancestry"
  [ "$got" = 710 ] || fail "Cursor argv0 with spaces resolved '$got', expected 710"
  FM_PROC_ROOT_OVERRIDE="$proc_root" \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "Cursor argv0 with spaces did not own its lock"
  pass "session-lock: Cursor argv0 with spaces survives structured process parsing"
}

test_cursor_external_primary_identity_without_launch_metadata() {
  local dir fakebin got trusted_dir trusted_cursor
  dir="$TMP_ROOT/cursor-no-proc"
  fakebin=$(fm_fakebin "$dir")
  trusted_dir="$FM_TEST_HOME/.local/share/cursor-agent/versions/current"
  trusted_cursor="$trusted_dir/cursor-agent"
  fm_fake_cursor_alias "$trusted_dir" cursor-agent
  mkdir -p "$FM_TEST_HOME/.local/bin"
  ln -sf "$trusted_cursor" "$FM_TEST_HOME/.local/bin/cursor-agent"
  ln -sf "$trusted_cursor" "$fakebin/cursor-agent"
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
  case "$pid:$field:${FM_TEST_CURSOR_CASE:-valid}" in
  710:comm=:valid|710:comm=:custom|710:comm=:invalid|710:comm=:spoof) printf '%s\n' node ;;
  710:args=:valid) printf '%s\n' "$FM_TEST_HOME/.local/share/cursor-agent/versions/current/cursor-agent --force" ;;
  710:args=:custom) printf '%s\n' "$FM_TEST_HOME/opt/cursor/bin/cursor-agent --force" ;;
  710:args=:invalid) printf '%s\n' '/usr/bin/node /tmp/cursor-agent --force' ;;
  710:args=:spoof) printf '%s\n' "$dir/decoy/cursor-agent --force" ;;
  710:command=:valid|710:command=:custom|710:command=:invalid|710:command=:spoof) printf '%s\n' 'node cursor-agent CURSOR_AGENT=1' ;;
  710:ppid=*) printf '%s\n' 1 ;;
  *:comm=*) printf '%s\n' bash ;;
  *:args=*) printf '%s\n' 'bash tests/run.sh' ;;
  *:ppid=*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$fakebin/ps"
  mkdir -p "$FM_TEST_HOME/opt/cursor/bin"
  fm_fake_cursor_alias "$FM_TEST_HOME/opt/cursor/bin" cursor-agent
  printf '710\n' > "$dir/state/.lock"

  got=$(FM_PROC_ROOT_OVERRIDE="$dir/no-proc" FM_TEST_CURSOR_CASE=valid \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "external Cursor primary with CURSOR_AGENT=1 was rejected without launch metadata"
  [ "$got" = 710 ] || fail "external Cursor primary resolved '$got', expected 710"
  got=$(FM_PROC_ROOT_OVERRIDE="$dir/no-proc" FM_TEST_CURSOR_CASE=custom \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "probe-verified custom Cursor primary was rejected without launch metadata"
  [ "$got" = 710 ] || fail "custom Cursor primary resolved '$got', expected 710"
  if FM_PROC_ROOT_OVERRIDE="$dir/no-proc" FM_TEST_CURSOR_CASE=invalid \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null; then
    fail "a later cursor-agent argument was treated as Cursor identity"
  fi
  if FM_PROC_ROOT_OVERRIDE="$dir/no-proc" FM_TEST_CURSOR_CASE=spoof \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null; then
    fail "a decoy Cursor install version was treated as native Cursor identity"
  fi
  pass "session-lock: external Cursor primary identity accepts its verified marker without launch metadata"
}

test_cursor_external_child_script_is_not_probed() {
  local dir fakebin script side_effect
  dir="$TMP_ROOT/cursor-child-script"
  fakebin=$(fm_fakebin "$dir")
  script="$dir/marked-child.js"
  side_effect="$dir/probed"
  cat > "$script" <<SH
#!/usr/bin/env bash
: > "$side_effect"
echo 'Usage: child'
echo 'Start the Cursor Agent'
echo 'CURSOR_API_ENDPOINT api2.cursor.sh'
SH
  chmod +x "$script"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  711:comm=) echo node ;;
  711:args=) echo '/usr/bin/node $script --force' ;;
  711:command=) echo 'node $script --force CURSOR_AGENT=1' ;;
  711:ppid=) echo 1 ;;
  *:comm=) echo bash ;;
  *:args=) echo 'bash tests/run.sh' ;;
  *:ppid=) echo 711 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if FM_PROC_ROOT_OVERRIDE="$dir/no-proc" lib_eval "$fakebin" \
    "fm_cursor_process_matches node 'node $script --force' /usr/bin/node 711"; then
    fail "a marked Node child script claimed Cursor identity"
  fi
  [ ! -e "$side_effect" ] || fail "Cursor identity probed a marked child script"
  pass "session-lock: marked interpreter child scripts are not probed as Cursor primaries"
}

test_claude_node_worker_keeps_contiguous_ancestry() {
  local dir fakebin got
  dir="$TMP_ROOT/claude-node-worker"
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
  110:comm=) printf '%s\n' node ;;
  110:args=) printf '%s\n' '/usr/bin/node /opt/claude/versions/2.1.220/worker.js' ;;
  110:ppid=) printf '%s\n' 120 ;;
  120:comm=) printf '%s\n' claude ;;
  120:args=) printf '%s\n' claude ;;
  120:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /opt/claude/hooks/stop.sh' ;;
  *:ppid=) printf '%s\n' 110 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '120\n' > "$dir/state/.lock"
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "Claude Node worker ancestry did not reach outer session"
  [ "$got" = 120 ] \
    || fail "Claude Node worker ancestry resolved '$got', expected outer session pid 120"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "Claude Node worker ancestry did not recognize outer session lock owner"
  pass "session-lock: Claude Node worker ancestry remains contiguous through outer session"
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
test_mainthread_cursor_session_is_identified
test_running_cursor_version_survives_binary_update
test_relative_process_names_cannot_claim_cursor
test_cursor_identity_does_not_execute_pid_executable
test_mainthread_cursor_argv0_with_spaces_is_identified
test_cursor_external_primary_identity_without_launch_metadata
test_cursor_external_child_script_is_not_probed
test_claude_node_worker_keeps_contiguous_ancestry
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
