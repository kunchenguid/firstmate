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
# A second, DIFFERENT verified harness name, so a case can ask the same question
# from a session that is not the harness whose marker is in the environment.
ln -s /bin/bash "$FAKEBIN/codex"
NAMED_CODEX="$FAKEBIN/codex"
# A bare interpreter name, so a fixture can be identified as a harness by its
# script argument alone and by nothing about its own executable.
ln -s /bin/bash "$FAKEBIN/node"
NAMED_NODE="$FAKEBIN/node"

# The two ways a REAL Claude Code session's reported command name differs from
# the bare harness name. Both are the reporter's doing rather than the program's,
# and both were unidentifiable until the library normalized them, so both are
# built as real executables here: the name under test is then produced by the
# kernel and by ps, not by a fixture that was told what to print.
#
# Claude Code's installed executable is a single-file Bun build literally named
# claude.exe, and its background pty worker renames its own task to
# `claude bg-pty-host`, which the 15-character task-name limit cuts mid-word.
ln -s /bin/bash "$FAKEBIN/claude.exe"
SUFFIXED_CLAUDE="$FAKEBIN/claude.exe"
ln -s /bin/bash "$FAKEBIN/claude bg-pty-host"
WORKER_CLAUDE="$FAKEBIN/claude bg-pty-host"

# Near misses that differ from a harness name only in ways that normalization
# must NOT undo, so a widened rule fails here rather than in a real fleet.
ln -s /bin/bash "$FAKEBIN/claudette"
ln -s /bin/bash "$FAKEBIN/claude-code"
ln -s /bin/bash "$FAKEBIN/python3"

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

# node renames its own main thread, so an npm-installed harness reports
# `MainThread` and no interpreter name at all. Identity then has to come from
# the script path in argv - and only from there, by exact basename, so a name any
# node program can present cannot carry a harness verdict on its own.
#
# Every case below pins the `MainThread` branch and nothing else. An interpreter
# that reports its own name (`node`, `python3`) reaches a separate rule that stops
# at the first flag in the same way but reads whole path components rather than a
# basename, and the case after this one pins that rule on its own shapes.
test_node_main_thread_identity_comes_only_from_the_script_path() {
  local dir fakebin shape
  dir="$TMP_ROOT/main-thread"
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
case "$pid:$field:${FM_TEST_NODE_SHAPE:-harness}" in
  760:comm=:*) printf '%s\n' MainThread ;;
  760:args=:harness) printf '%s\n' 'node /home/u/.nvm/versions/node/v24.16.0/bin/codex' ;;
  760:args=:flagged) printf '%s\n' 'node --enable-source-maps /home/u/.nvm/versions/node/v24.16.0/bin/codex' ;;
  760:args=:sibling) printf '%s\n' 'node /work/codex-notes/build.js' ;;
  760:args=:flag) printf '%s\n' 'node /work/tools/run.js --profile codex' ;;
  760:args=:optionpath) printf '%s\n' 'node /work/tools/run.js --config /etc/codex/config.toml' ;;
  760:args=:requirepath) printf '%s\n' 'node --require /opt/hooks/claude/instrument.js /srv/app/server.js' ;;
  760:args=:evalpath) printf '%s\n' 'node -e require("/opt/claude/x")' ;;
  760:args=:requirejoined) printf '%s\n' 'node --require=/opt/x/claude /srv/app.js' ;;
  760:args=:loadervalue) printf '%s\n' 'node --loader /opt/tools/pi /srv/app.js' ;;
  760:args=:shortjoined) printf '%s\n' 'node -r/opt/x/codex /srv/app.js' ;;
  760:args=:bare) printf '%s\n' 'node' ;;
  760:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 760 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '760\n' > "$dir/state/.lock"

  # The plain shape is the one a real npm-installed codex reports, and the one
  # this branch exists for.
  FM_TEST_NODE_SHAPE=harness lib_eval "$fakebin" 'fm_harness_pid_alive 760' \
    || fail "an npm-installed harness reporting MainThread was not recognized as a harness at all"
  FM_TEST_NODE_SHAPE=harness lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "a MainThread-named harness session could not recognize its own lock"

  # Nothing else in an interpreter's argv may be read as a harness: not a script
  # merely living beside a harness-shaped name, not a passing argument that
  # happens to be one whether bare or the value of an option, and above all not
  # the path-shaped VALUE of an interpreter flag, which can be named anything at
  # all - `/opt/x/claude` and `/opt/tools/pi` included - and is the interpreter's
  # own argument rather than the program being run.
  #
  # `flagged` is a DELIBERATE refusal, not an oversight: once any flag precedes
  # the script this branch stops guessing which token is the script, because the
  # alternative is an allowlist of value-taking interpreter flags that would rot
  # silently as vendors add them. Do not restore a scan to make it pass; teach it
  # a shape only from a real release that reports it.
  for shape in flagged sibling flag optionpath requirepath evalpath requirejoined loadervalue shortjoined bare; do
    if FM_TEST_NODE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 760'; then
      fail "$shape: a node program reporting MainThread whose script is not the one plain token after the interpreter was treated as a harness"
    fi
    if FM_TEST_NODE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: a node program reporting MainThread claimed a home's session lock"
    fi
  done
  pass "session-lock: a MainThread-named harness is identified from the one plain script token, and only from there"
}

# An interpreter that reports its OWN exec name (`node`, `python3`) never reaches
# the MainThread branch above, so it has its own rule: the argv tokens before the
# first flag, matched by whole path component. The component rule rather than that
# branch's exact basename is what identifies a node-hosted harness whose bin entry
# is not named after the harness, which is the only shape this rule identifies at
# all.
#
# Every negative below was observed classifying as a Claude harness when this rule
# read the whole argument string instead, so each is a real regression guard.
test_bare_interpreter_identity_stops_at_the_first_flag() {
  local dir fakebin shape kind
  dir="$TMP_ROOT/bare-interpreter"
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
case "$pid:$field:${FM_TEST_ARGV_SHAPE:-claudecli}" in
  770:comm=:pyconfig|770:comm=:pisensors) printf '%s\n' python3 ;;
  770:comm=:*) printf '%s\n' node ;;
  770:args=:claudecli) printf '%s\n' 'node /path/to/claude/cli.js' ;;
  770:args=:codexcli) printf '%s\n' 'node /opt/tools/codex/cli.js' ;;
  770:args=:codexthenclaudearg) printf '%s\n' 'node /opt/tools/codex/cli.js --config /etc/claude/x.toml' ;;
  770:args=:hookarg) printf '%s\n' 'node /srv/app/server.js --hooks /home/u/.claude/hooks.json' ;;
  770:args=:transcriptarg) printf '%s\n' 'node /srv/x/server.js --transcript /home/u/.claude/p/t.jsonl' ;;
  770:args=:requirepath) printf '%s\n' 'node --require /opt/hooks/claude/instrument.js /srv/app.js' ;;
  770:args=:pyconfig) printf '%s\n' 'python3 /srv/app.py --config /etc/claude/x.toml' ;;
  770:args=:flagged) printf '%s\n' 'node --experimental-foo /path/to/claude/cli.js' ;;
  770:args=:dotcomponent) printf '%s\n' 'node /srv/app/server.js /home/u/.claude/hooks.json' ;;
  770:args=:pihome) printf '%s\n' 'node /home/pi/app.js' ;;
  770:args=:pisensors) printf '%s\n' 'python3 /home/pi/sensors/read.py' ;;
  770:args=:piscript) printf '%s\n' 'node /opt/tools/pi' ;;
  770:args=:bare) printf '%s\n' 'node' ;;
  770:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 770 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '770\n' > "$dir/state/.lock"

  # A node-hosted harness whose bin entry is `cli.js` is identified by the harness
  # component of its install path, and by nothing else in this file.
  for shape in claudecli codexcli codexthenclaudearg; do
    FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 770' \
      || fail "$shape: a node-hosted harness under a harness-named install path was not recognized as a harness"
    FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: a node-hosted harness session could not recognize its own lock"
  done

  # `pi` and `pi-signed` are anchored names, so they carry a verdict here only as
  # the token's own basename. `/home/pi` is the Raspberry Pi OS default home, so an
  # interior-component reading would turn ordinary node and python services into
  # verified Pi harnesses and wedge a real session out of its own home.
  FM_TEST_ARGV_SHAPE=piscript lib_eval "$fakebin" 'fm_harness_pid_alive 770' \
    || fail "a script named exactly pi was not identified as the Pi harness"

  # Identification here never carries the cohort's acceptance decision: an
  # argument list is data the process was handed, not the program it is running,
  # so none of these shapes names a harness kind.
  for shape in claudecli codexcli codexthenclaudearg; do
    if kind=$(FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 770'); then
      fail "$shape: a harness named only in an argument list was typed as '$kind' for the cohort's acceptance decision"
    fi
  done

  # Nothing at or after the first flag may decide the verdict, because a flag's
  # value is a path that can be named anything at all, and a component that merely
  # STARTS with a harness name is not one either - `.claude` is not `claude`.
  #
  # `flagged` is a DELIBERATE refusal, not an oversight: once any flag precedes the
  # script this rule stops guessing which token is the script, because the
  # alternative is an allowlist of value-taking interpreter flags that would rot
  # silently as vendors add them. Do not restore a whole-argv match to make it
  # pass; teach it a shape only from a real release that reports it.
  for shape in hookarg transcriptarg requirepath pyconfig flagged dotcomponent pihome pisensors bare; do
    if FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 770'; then
      fail "$shape: an interpreter argument at or after the first flag carried a harness verdict"
    fi
    if FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an unrelated interpreted program claimed a home's session lock"
    fi
    if FM_TEST_ARGV_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 770'; then
      fail "$shape: an unrelated interpreted program was named as a harness kind"
    fi
  done
  pass "session-lock: a bare interpreter is identified from the argv path components before the first flag"
}

# The cohort's acceptance decision is typed from EXECUTABLE identity alone: the
# reported command name's own basename, or a whole path component of that command
# name or of argv[0]. A launch marker proves a launch relationship rather than
# identity, so a codex session started from inside a Claude session carries a
# truthful CLAUDE_PID naming that holder; the process name is the only thing that
# separates it from the rehosted Claude session the marker path exists to accept,
# so an argument list may not decide it.
#
# Every shape below is identified for the ancestry walk exactly as it was. What
# this case pins is which of them may open the marker path.
test_acceptance_typing_comes_only_from_executable_identity() {
  local dir fakebin shape kind
  dir="$TMP_ROOT/acceptance-typing"
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
case "$pid:$field:${FM_TEST_EXEC_SHAPE:-nativepath}" in
  780:comm=:nativepath) printf '%s\n' 2.1.220 ;;
  780:args=:nativepath) printf '%s\n' '/home/u/.local/share/claude/versions/2.1.220 --resume' ;;
  780:comm=:binentry) printf '%s\n' claude ;;
  780:args=:binentry) printf '%s\n' '/usr/local/bin/claude' ;;
  780:comm=:codexname) printf '%s\n' codex ;;
  780:args=:codexname) printf '%s\n' 'codex' ;;
  780:comm=:suffixed) printf '%s\n' claude.exe ;;
  780:args=:suffixed) printf '%s\n' '/home/u/.nvm/versions/node/v24.16.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe --resume' ;;
  780:comm=:worker) printf '%s\n' 'claude bg-pty-h' ;;
  780:args=:worker) printf '%s\n' '/home/u/.nvm/versions/node/v24.16.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe bg-pty-host' ;;
  780:comm=:npmpath) printf '%s\n' node ;;
  780:args=:npmpath) printf '%s\n' 'node /home/u/.nvm/versions/node/v24.16.0/lib/node_modules/@anthropic-ai/claude-code/bin/cli.js' ;;
  780:comm=:nearmiss) printf '%s\n' claude-code ;;
  780:args=:nearmiss) printf '%s\n' '/opt/vendor/claude-code --serve' ;;
  780:comm=:lookalike) printf '%s\n' claudette ;;
  780:args=:lookalike) printf '%s\n' '/opt/claudette/bin/claudette' ;;
  780:comm=:pylike) printf '%s\n' python3 ;;
  780:args=:pylike) printf '%s\n' 'python3 /srv/app.py --config /etc/claude/x.toml' ;;
  780:comm=:mainthread) printf '%s\n' MainThread ;;
  780:args=:mainthread) printf '%s\n' 'node /home/u/.nvm/versions/node/v24.16.0/bin/codex' ;;
  780:comm=:*) printf '%s\n' node ;;
  780:args=:nodehosted) printf '%s\n' 'node /path/to/claude/cli.js' ;;
  780:args=:positional) printf '%s\n' 'node /srv/app/server.js /opt/claude/agent.json' ;;
  780:args=:hookflag) printf '%s\n' 'node /srv/app/server.js --hooks /home/u/.claude/hooks.json' ;;
  780:args=:pihome) printf '%s\n' 'node /home/pi/app.js' ;;
  780:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 780 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # A harness whose own executable names it may open the marker path: Claude
  # Code's version-named native install through its install path, and an ordinary
  # harness-named bin entry through its basename.
  for shape in nativepath binentry; do
    kind=$(FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 780' | tr -d '[:space:]')
    [ "$kind" = claude ] || fail "$shape: a real Claude install typed as '$kind' rather than claude, so its own accept path is closed"
  done
  kind=$(FM_TEST_EXEC_SHAPE=codexname lib_eval "$fakebin" 'fm_harness_pid_kind 780' | tr -d '[:space:]')
  [ "$kind" = codex ] || fail "a codex-named executable typed as '$kind' rather than codex"

  # The command name a real install reports, with the path deliberately unable to
  # carry the verdict: the npm layout's own directory is `claude-code`, which is
  # no harness component, so `suffixed` and `worker` can only be typed by the
  # command name itself. `npmpath` is the same argv with the harness named
  # nowhere else, and it must stay untyped - that is both the divergence proof
  # for the two cases above and the node-hosted limit the library states.
  for shape in suffixed worker; do
    kind=$(FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 780' | tr -d '[:space:]')
    [ "$kind" = claude ] || fail "$shape: the command name a real Claude Code install reports typed as '${kind:-nothing}' rather than claude, so its own session start refuses its home and degrades to read-only while it is the only session alive"
  done
  if kind=$(FM_TEST_EXEC_SHAPE=npmpath lib_eval "$fakebin" 'fm_harness_pid_kind 780'); then
    fail "the npm install path alone typed as '$kind', so the two cases above prove nothing about the command name"
  fi

  # Normalization strips two reporting artifacts before the SAME exact-equality
  # test; it must never become a prefix rule. Each name below shares a prefix
  # with a verified harness and is not one.
  for shape in nearmiss lookalike pylike; do
    if kind=$(FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 780'); then
      fail "$shape: a name that merely starts like a harness typed as '$kind', so an unrelated process could be accepted as a session's own harness"
    fi
  done

  # A harness named nowhere but in an argument list stays identified, and still
  # gets no accept path. That is the fail-closed direction and it is deliberate:
  # the alternative accepts a different harness that merely inherited the marker.
  for shape in nodehosted mainthread positional; do
    FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 780' \
      || fail "$shape: the shape this case is about stopped being identified at all, so it no longer tests the acceptance narrowing"
    if kind=$(FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 780'); then
      fail "$shape: a harness named only in an argument list was typed as '$kind', so an inherited launch marker could be believed for it"
    fi
  done

  # A shape that is no harness at all names nothing either way.
  for shape in hookflag pihome; do
    if FM_TEST_EXEC_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_kind 780'; then
      fail "$shape: an unrelated interpreted program was typed for the cohort's acceptance decision"
    fi
  done
  pass "session-lock: cohort acceptance is typed from executable identity and never from an argument list"
}

# Start a real background process under executable <1> and print its pid once the
# real ps can see it. The trailing no-op is what stops bash from exec'ing the
# sleep into its own pid, which would replace the command name this is all about.
start_named_process() {  # <path>
  local bin=$1 pid comm i=0
  "$bin" -c 'while :; do sleep 0.2; done; :' >/dev/null 2>&1 &
  pid=$!
  COHORT_PIDS+=("$pid")
  while [ "$i" -lt 200 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
    [ -n "$comm" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.05
    i=$((i + 1))
  done
  fail "the fixture process for $bin never became visible to ps"
}

# The reporter produces the name here, not a fixture. Every case above hands the
# library a command name a fake ps was told to print, and that is precisely the
# blind spot that let a real install shape go unidentified: a stub can only report
# a name someone already thought of, so every fixture in this suite named its
# executable exactly `claude` and none of them could see a suffixed or truncated
# name at all. These processes are real, their names come from real executables,
# and the name under test is read back through the same ps the library calls.
#
# Each case drives the two signals apart on purpose: the verdict is asked of the
# observed command name with NO argument list at all, so the command name is the
# only thing that can carry it, and the divergence between that name and the bare
# harness name is asserted first so the case cannot pass vacuously if a platform
# stops producing the artifact.
test_real_reported_command_names_are_typed_for_acceptance() {
  local pid comm base kind name
  for name in "$SUFFIXED_CLAUDE" "$WORKER_CLAUDE"; do
    pid=$(start_named_process "$name")
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
    base=${comm##*/}
    [ -n "$base" ] || fail "ps reported no command name at all for the fixture process from $name"
    [ "$base" != claude ] || fail \
      "$name was reported as the bare name 'claude', so this platform no longer reproduces the reporting artifact and the case would pass without testing it"
    kind=$(lib_probe "fm_harness_exec_kind '$base' ''" | tr -d '[:space:]') || kind=
    [ "$kind" = claude ] || fail \
      "a real process reporting command name '$comm' typed as '${kind:-nothing}' rather than claude. This is the shape Claude Code actually runs as, so its own session start would refuse its home and degrade to read-only while it is the only session alive."
    kind=$(lib_probe "fm_harness_pid_kind $pid" | tr -d '[:space:]') || kind=
    [ "$kind" = claude ] || fail \
      "the live-pid reading disagreed with the command-name reading for '$comm': it typed as '${kind:-nothing}'"
    kill "$pid" 2>/dev/null || true
  done

  # The truncation is a property of the reporter, so pin that it really happened
  # rather than trusting the length arithmetic: a name the reporter shortened must
  # still be more than the bare harness name.
  pid=$(start_named_process "$WORKER_CLAUDE")
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
  case "${comm##*/}" in
    'claude '*) : ;;
    *) fail "the worker fixture reported '$comm', which is not the multi-word command name this case exists to cover" ;;
  esac
  kill "$pid" 2>/dev/null || true

  # Real processes whose names differ from a harness only in ways normalization
  # must not undo. A widened rule fails here rather than in a real fleet.
  for name in claudette claude-code node python3; do
    pid=$(start_named_process "$FAKEBIN/$name")
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
    base=${comm##*/}
    [ "$base" = "$name" ] || fail \
      "the negative control for $name reported command name '$comm', so it is no longer the name this case means to refuse"
    if kind=$(lib_probe "fm_harness_exec_kind '$base' ''"); then
      fail "a real process named '$name' typed as '$kind', so an unrelated process could be accepted as a session's own harness and take over its home"
    fi
    if kind=$(lib_probe "fm_harness_pid_kind $pid"); then
      fail "a real process named '$name' typed as '$kind' through its live pid, so an unrelated process could be accepted as a session's own harness"
    fi
    kill "$pid" 2>/dev/null || true
  done
  pass "session-lock: the command names a real install reports are typed for acceptance, and near misses still are not"
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
  launcher=${FM_FIXTURE_LAUNCHER:-$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')}
  parent=$launcher
  i=0
  while [ "$i" -lt 200 ]; do
    parent=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
    if [ -n "$parent" ] && [ "$parent" != "$launcher" ]; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  printf 'launcher=%s parent=%s\n' "$launcher" "$parent" > "$FM_HOME/state/reparented"
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
launcher=${FM_FIXTURE_LAUNCHER:-$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')}
parent=$launcher
i=0
while [ "$i" -lt 200 ]; do
  parent=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  if [ -n "$parent" ] && [ "$parent" != "$launcher" ]; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf 'launcher=%s parent=%s\n' "$launcher" "$parent" > "$FM_HOME/state/daemon-reparented"
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Assert that a fixture really was reparented away from the launcher that started
# it, and print the pid it was reparented TO.
#
# Comparing against pid 1 is not enough to detect that: on a host with a process
# subreaper - systemd --user on modern Linux - an orphan is reparented to the
# subreaper rather than to init, so a fixture that waited for pid 1 waited out its
# whole timeout and then ran anyway. Each fixture records both pids so the
# detached shape every case below depends on is asserted rather than assumed.
assert_reparented() {  # <report> <what>
  local report=$1 what=$2 text launcher parent
  text=$(cat "$report" 2>/dev/null || true)
  launcher=$(printf '%s\n' "$text" | sed -n 's/^launcher=\([0-9]*\) .*$/\1/p')
  parent=$(printf '%s\n' "$text" | sed -n 's/^.* parent=\([0-9]*\)$/\1/p')
  [ -n "$launcher" ] && [ -n "$parent" ] && [ "$launcher" != "$parent" ] \
    || fail "$what was never reparented away from its launcher, so this fixture no longer reproduces a detached session (recorded: ${text:-nothing})"
  printf '%s\n' "$parent"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented away from it and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
  if [ -n "$daemon_bin" ]; then
    assert_reparented "$dir/state/daemon-reparented" "the fixture daemon" >/dev/null
  else
    assert_reparented "$dir/state/reparented" "the fixture session" >/dev/null
  fi
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


# --- session-cohort layer: real processes whose tree is not their session ----
#
# These cases run real processes and no harness. The shape they reproduce is a
# harness rehosting a session's work under its own pty: the resulting tree is
# orphaned away from its launcher and never reaches the pid that holds the lock,
# so ancestry alone reports one genuine session as two competing ones.
#
# Every fixture clears every environment signal the library reads before setting
# the ones its case means to drive, so a value inherited from the developer's
# own live session can never decide a verdict here. Each case also asserts the
# signals it drove APART, so a case whose fixture stopped diverging fails
# instead of passing on an accident.
fm_test_clear_signals_argv
COHORT_ENV_ARGV=("${FM_TEST_CLEAR_SIGNALS_ARGV[@]}")

COHORT_PIDS=()
COHORT_TMUX_SOCKET="fm-session-lock-cohort-$$"
cohort_cleanup() {
  local p
  for p in "${COHORT_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  if command -v tmux >/dev/null 2>&1; then
    tmux -L "$COHORT_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
}
trap 'cohort_cleanup; fm_test_cleanup' EXIT
trap 'cohort_cleanup; fm_test_cleanup; exit 130' INT
trap 'cohort_cleanup; fm_test_cleanup; exit 143' TERM

# Build one fixture home. The three scripts are deliberately separate processes:
# the holder must outlive the check, the session must be able to orphan itself,
# and the check must run BELOW the session so the ancestry walk starts where a
# real hook starts.
make_cohort_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  # A process a verified-harness name identifies. The trailing no-op keeps bash
  # from exec'ing the sleep and losing that name.
  cat > "$dir/holder.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FIX/holder-pid"
sleep 120
:
SH
  # A harness session. It overwrites the launch marker with its OWN pid for its
  # children, exactly as a real session does, so the pid that STARTED it
  # survives only in its exec-time environment and the check below has to reach
  # it through the ancestry rather than through its own inherited value.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_PID=$$
printf '%s\n' "$$" > "$FM_FIX/session-pid"
if [ "${FM_FIX_ORPHAN:-0}" = 1 ]; then
  launcher=${FM_FIXTURE_LAUNCHER:-$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')}
  parent=$launcher
  i=0
  while [ "$i" -lt 200 ]; do
    parent=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
    if [ -n "$parent" ] && [ "$parent" != "$launcher" ]; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  printf 'launcher=%s parent=%s\n' "$launcher" "$parent" > "$FM_FIX/reparented"
fi
bash "$FM_FIX/check.sh"
printf '%s\n' "$?" > "$FM_FIX/check-finished"
SH
  # One report of every signal the verdict rests on, so each case can assert the
  # verdict AND the divergence that produced it.
  cat > "$dir/check.sh" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$FM_FIX_LIB"
{
  printf 'ancestry=%s\n' "$(fm_harness_ancestry_pids 2>/dev/null | tr '\n' ' ')"
  printf 'container_self=%s\n' "$(fm_session_container_self 2>/dev/null || printf NONE)"
  printf 'container_holder=%s\n' "$(fm_session_container_of_pid "$FM_FIX_HOLDER" 2>/dev/null || printf NONE)"
  printf 'tty_self=%s\n' "$(fm_session_tty_of_pid "$$" 2>/dev/null || printf NONE)"
  printf 'tty_holder=%s\n' "$(fm_session_tty_of_pid "$FM_FIX_HOLDER" 2>/dev/null || printf NONE)"
  printf 'launcher_self=%s\n' "$(fm_session_launcher_pid "$$" claude 2>/dev/null || printf NONE)"
  printf 'kind_self=%s\n' "$(fm_harness_ancestry_pids 2>/dev/null | while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s ' "$(fm_harness_pid_kind "$m" 2>/dev/null || printf NONE)"
  done)"
  printf 'kind_holder=%s\n' "$(fm_harness_pid_kind "$FM_FIX_HOLDER" 2>/dev/null || printf NONE)"
  printf 'launcher_ancestry=%s\n' "$(fm_harness_ancestry_pids 2>/dev/null | while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s ' "$(fm_session_launcher_pid "$m" claude 2>/dev/null || printf NONE)"
  done)"
  printf 'launcher_holder=%s\n' "$(fm_session_launcher_pid "$FM_FIX_HOLDER" claude 2>/dev/null || printf NONE)"
  if fm_session_lock_owned_by_self "$FM_FIX/state"; then printf 'owned=yes\n'; else printf 'owned=no\n'; fi
  if fm_session_lock_holder_competes "$FM_FIX_HOLDER"; then printf 'competes=yes\n'; else printf 'competes=no\n'; fi
} > "$FM_FIX/${FM_FIX_OUT:-check}.out" 2> "$FM_FIX/${FM_FIX_OUT:-check}.err"
SH
  chmod +x "$dir/holder.sh" "$dir/session.sh" "$dir/check.sh"
}

wait_for_file() {  # <path> <what>
  local path=$1 what=$2 i=0
  while [ "$i" -lt 400 ] && [ ! -s "$path" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$path" ] || fail "$what never appeared"
  tr -d '[:space:]' < "$path"
}

# Start the holder as an ordinary background child and publish its pid in
# COHORT_HOLDER_PID. It is deliberately NOT captured through a command
# substitution: a long-lived background process holds that pipe open for its
# whole lifetime, and the capture would block instead of returning a pid.
COHORT_HOLDER_PID=
start_cohort_holder() {  # <dir> <container-var-assignments...>
  local dir=$1
  shift
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" "$@" "$NAMED_CLAUDE" "$dir/holder.sh" \
    > "$dir/holder.out" 2>&1 &
  COHORT_PIDS+=("$!")
  COHORT_HOLDER_PID=$(wait_for_file "$dir/holder-pid" "the fixture holder pid")
}

# Start the session detached, so the launcher exits immediately and the tree is
# reparented onto whatever adopts orphans here: the ancestry walk then terminates
# inside the fixture and can never reach the live session running this suite.
run_cohort_session() {  # <dir> <holder-pid> <launch-marker-pid> <env-assignments...>
  local dir=$1 holder=$2 marker=$3
  shift 3
  printf '%s\n' "$holder" > "$dir/state/.lock"
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" FM_FIX_LIB="$LIB" FM_FIX_HOLDER="$holder" \
    FM_FIX_ORPHAN=1 CLAUDE_PID="$marker" "$@" \
    bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$NAMED_CLAUDE" "$dir/session.sh"
  wait_for_file "$dir/check-finished" "the fixture check result" >/dev/null
  assert_reparented "$dir/reparented" "the fixture session" >/dev/null
}

cohort_field() {  # <dir> <key>
  cohort_field_of "$1" check "$2"
}

# The same field from one named report, for a case that checks the same fixture
# more than once.
cohort_field_of() {  # <dir> <report> <key>
  sed -n "s/^$3=//p" "$1/$2.out" 2>/dev/null
}

cohort_report() {  # <dir>
  cohort_report_of "$1" check
}

cohort_report_of() {  # <dir> <report>
  printf '%s' "--- observed signals ($2) ---"$'\n'"$(cat "$1/$2.out" 2>/dev/null)"
}

# The headline case: the lock names a live harness the process tree cannot
# reach, and it is nonetheless this session's own. Before the launch marker was
# consulted, every session start in this shape refused its own home and degraded
# to read-only while exactly one session existed.
test_rehosted_session_owns_the_lock_it_cannot_reach() {
  local dir holder session
  dir="$TMP_ROOT/cohort-rehosted"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane
  holder=$COHORT_HOLDER_PID
  run_cohort_session "$dir" "$holder" "$holder" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane
  session=$(tr -d '[:space:]' < "$dir/session-pid")

  # Divergence, asserted so this case cannot pass on an accidentally intact tree.
  assert_not_contains " $(cohort_field "$dir" ancestry)" " $holder " \
    "the holder was still inside the ancestry, so this fixture no longer reproduces a rehosted session"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" launcher_self)" = "$session" ] || fail \
    "the session did not overwrite the launch marker for its children, so the ancestry walk was never exercised"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" = "herdr=fixture-pane" ] || fail \
    "the fixture lost its own container signal"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = yes ] || fail \
    "a session reached only through the launch marker did not recognize its own lock"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = no ] || fail \
    "this session's own lock holder was treated as a competing session"$'\n'"$(cohort_report "$dir")"
  pass "session-lock: a session rehosted outside its own process tree still owns its lock"
}

# The mirror of the case above, and the shape ownership converges into: every
# acquisition rewrites the lock onto the acquiring session's own pid, so once a
# background session has claimed the home the lock names the session that was
# STARTED while the attended window session is the one asking whether it still
# owns its home. The relationship is then only readable in reverse - the holder's
# own recorded launch marker names this session - and while only the forward
# direction existed this shape moved the read-only degradation onto the window
# session for as long as the session it launched kept running.
test_launching_session_owns_a_lock_naming_the_session_it_started() {
  local dir window holder reparent
  dir="$TMP_ROOT/cohort-reverse"
  make_cohort_fixture "$dir"
  # The window session. It exports its own pid as the launch marker for
  # everything it starts, exactly as a real session does, then starts the second
  # session detached so that session is orphaned away from it and the two are
  # unreachable from each other's process tree in either direction.
  cat > "$dir/window.sh" <<'SH'
#!/usr/bin/env bash
set -u
export CLAUDE_PID=$$
printf '%s\n' "$$" > "$FM_FIX/window-pid"
launcher=${FM_FIXTURE_LAUNCHER:-$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')}
parent=$launcher
i=0
while [ "$i" -lt 200 ]; do
  parent=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  if [ -n "$parent" ] && [ "$parent" != "$launcher" ]; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf 'launcher=%s parent=%s\n' "$launcher" "$parent" > "$FM_FIX/window-reparented"
bash -c '"$0" "$1" &' "$FM_FIX_CLAUDE" "$FM_FIX/holder.sh"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_FIX/holder-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
holder=$(tr -d '[:space:]' < "$FM_FIX/holder-pid")
printf '%s\n' "$holder" > "$FM_FIX/state/.lock"
export FM_FIX_HOLDER="$holder"
bash "$FM_FIX/check.sh"
check_rc=$?
FM_HOME="$FM_FIX" "$FM_FIX_ROOT/bin/fm-lock.sh" > "$FM_FIX/lock.out" 2>&1
printf '%s\n' "$?" > "$FM_FIX/lock.rc"
printf '%s\n' "$check_rc" > "$FM_FIX/check-finished"
SH
  chmod +x "$dir/window.sh"
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" FM_FIX_LIB="$LIB" FM_FIX_CLAUDE="$NAMED_CLAUDE" \
    FM_FIX_ROOT="$ROOT" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane \
    bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$NAMED_CLAUDE" "$dir/window.sh"
  window=$(wait_for_file "$dir/window-pid" "the fixture window session pid")
  holder=$(wait_for_file "$dir/holder-pid" "the pid of the session the window session started")
  COHORT_PIDS+=("$holder" "$window")
  wait_for_file "$dir/check-finished" "the fixture check result" >/dev/null
  reparent=$(assert_reparented "$dir/window-reparented" "the fixture window session")
  # Whatever adopted the orphan - init, or a subreaper such as systemd --user - is
  # not a verified harness, so the walk still terminates inside the fixture.
  assert_not_contains " $(cohort_field "$dir" ancestry) " " $reparent " \
    "the ancestry walk crossed into the process that adopted the fixture, so it no longer terminates inside the fixture"$'\n'"$(cohort_report "$dir")"

  # Divergence, so the verdict can only be coming from the reverse direction:
  # the holder is outside the ancestry, and no marker on this side of the pair
  # names it.
  assert_contains " $(cohort_field "$dir" ancestry) " " $window " \
    "the window session was not in its own harness ancestry, so this fixture no longer reproduces the shape"$'\n'"$(cohort_report "$dir")"
  assert_not_contains " $(cohort_field "$dir" ancestry) " " $holder " \
    "the launched session was still inside the window session's ancestry, so ancestry alone could have decided this"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" launcher_self)" = "$window" ] || fail \
    "the window session did not publish its own pid as the launch marker its children inherit"$'\n'"$(cohort_report "$dir")"
  assert_not_contains " $(cohort_field "$dir" launcher_ancestry) " " $holder " \
    "a marker on this side of the pair named the holder, so the forward direction was not driven out"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" launcher_holder)" = "$window" ] || fail \
    "the launched session did not record the window session as its launcher, so nothing was left to relate them"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" = "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture lost the co-location the relationship is AND-ed with"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = yes ] || fail \
    "the window session did not recognize a lock naming the session it started as its own home"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = no ] || fail \
    "the session this one started was treated as a competing session"$'\n'"$(cohort_report "$dir")"

  # And the acquisition that follows says what it did. Converging one session's
  # own lock onto its own pid is not a home changing hands, and the two members of
  # a launcher/launched pair print this at each other on every session start.
  [ "$(tr -d '[:space:]' < "$dir/lock.rc")" = 0 ] || fail \
    "acquiring the home from inside its own cohort failed: $(cat "$dir/lock.out" 2>/dev/null)"
  assert_contains "$(cat "$dir/lock.out")" "converged onto this session's own holder pid $holder" \
    "acquisition did not name the holder it converged onto"
  assert_not_contains "$(cat "$dir/lock.out")" "not recognised as a harness" \
    "a live holder in this session's own cohort was reported as unidentified"
  assert_not_contains "$(cat "$dir/lock.out")" "took over from" \
    "acquisition told this session it took the home over from itself"
  pass "session-lock: a session still owns its home once the lock names the session it started"
}

# A launch marker is an ordinary environment variable, so a harness the captain
# starts from inside a Claude session inherits CLAUDE_PID naming that session.
# Believing it would hand a live Claude captain's home to a genuinely separate
# codex session, which is the one thing the lock exists to refuse, so a marker row
# is consulted only when the asking session and the holder are both the harness it
# was verified for.
#
# The two cases below run the SAME fixture and differ only in which harness asks,
# so neither can pass by never reaching the marker path: the codex asker must be
# refused, and the claude asker must still converge.
# Called DIRECTLY and never through a command substitution, for the same reason
# start_cohort_holder is: the holder pid it registers for cleanup would be
# appended to a subshell copy of COHORT_PIDS and discarded, leaving a live
# harness-named process behind after the suite exits. The holder pid is published
# in COHORT_HOLDER_PID rather than printed.
cross_harness_fixture() {  # <dir> <asker-bin> [<asker-script>]
  local dir=$1 asker_bin=$2 holder
  local script=${3:-$dir/asker.sh}
  make_cohort_fixture "$dir"
  mkdir -p "$(dirname -- "$script")"
  # The asker runs the check and then the REAL acquisition as its own children, so
  # the ancestry walk starts below it exactly as a hook's does. It is started from
  # this suite, whose shell is not a harness, so its harness ancestry is itself
  # alone - the shape the cross-harness ask actually has.
  cat > "$script" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_FIX/asker-pid"
bash "$FM_FIX/check.sh"
FM_HOME="$FM_FIX" "$FM_FIX_ROOT/bin/fm-lock.sh" > "$FM_FIX/lock.out" 2>&1
printf '%s\n' "$?" > "$FM_FIX/lock.rc"
SH
  chmod +x "$script"
  start_cohort_holder "$dir" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane
  holder=$COHORT_HOLDER_PID
  printf '%s\n' "$holder" > "$dir/state/.lock"
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" FM_FIX_LIB="$LIB" FM_FIX_HOLDER="$holder" \
    FM_FIX_ROOT="$ROOT" CLAUDE_PID="$holder" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane \
    "$asker_bin" "$script"
}

test_a_different_harness_never_believes_an_inherited_launch_marker() {
  local dir holder asker
  dir="$TMP_ROOT/cohort-cross-harness"
  cross_harness_fixture "$dir" "$NAMED_CODEX"
  holder=$COHORT_HOLDER_PID
  asker=$(tr -d '[:space:]' < "$dir/asker-pid")

  # Divergence: the marker IS present and DOES name the holder, and co-location
  # holds, so only the harness scoping can be producing the refusal.
  [ "$(cohort_field "$dir" launcher_self)" = "$holder" ] || fail \
    "the fixture did not carry an inherited marker naming the holder, so its refusal proves nothing"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" = "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture lost the co-location this case AND-s the relationship with"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" kind_holder)" = claude ] || fail \
    "the fixture holder did not resolve as a claude harness"$'\n'"$(cohort_report "$dir")"
  [ "$(printf '%s' "$(cohort_field "$dir" kind_self)" | tr -d '[:space:]')" = codex ] || fail \
    "the asking session did not resolve as codex alone, so this fixture no longer reproduces a cross-harness ask"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = no ] || fail \
    "a codex session accepted a live claude session's lock as its own"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = yes ] || fail \
    "a live claude holder was not treated as a competing session by a codex asker"$'\n'"$(cohort_report "$dir")"
  [ "$(tr -d '[:space:]' < "$dir/lock.rc")" = 1 ] || fail \
    "acquisition did not refuse: rc=$(cat "$dir/lock.rc") out=$(cat "$dir/lock.out")"
  assert_contains "$(cat "$dir/lock.out")" "another live firstmate session holds the lock" \
    "acquisition refused for some reason other than the competing live session"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail \
    "acquisition wrote the codex pid over a live claude holder: got $(cat "$dir/state/.lock"), holder $holder, asker $asker"
  pass "session-lock: a different harness never believes a launch marker it merely inherited"
}

# The third asker on the same fixture: a Claude session identified ONLY by its
# script argument. It is a harness for the ancestry walk and it carries the same
# inherited marker naming the same live holder, so the only thing refusing it is
# that its own executable names no harness. This is the fail-closed half of the
# acceptance narrowing, and the case below shows the identical fixture converging
# once the asker's own executable does name it.
test_a_session_named_only_in_argv_gets_no_accept_path() {
  local dir holder asker
  dir="$TMP_ROOT/cohort-argv-named"
  cross_harness_fixture "$dir" "$NAMED_NODE" "$dir/claude/cli.js"
  holder=$COHORT_HOLDER_PID
  asker=$(tr -d '[:space:]' < "$dir/asker-pid")

  # Divergence: the asker IS a resolved harness ancestry, the marker IS present
  # and DOES name the holder, and co-location holds, so the refusal can only come
  # from the acceptance typing.
  assert_contains " $(cohort_field "$dir" ancestry)" " $asker " \
    "the argv-named asker was not identified as a harness at all, so this case tests the ancestry walk rather than the acceptance typing"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" launcher_self)" = "$holder" ] || fail \
    "the fixture did not carry an inherited marker naming the holder, so its refusal proves nothing"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" = "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture lost the co-location this case AND-s the relationship with"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" kind_holder)" = claude ] || fail \
    "the fixture holder did not resolve as a claude harness"$'\n'"$(cohort_report "$dir")"
  [ "$(printf '%s' "$(cohort_field "$dir" kind_self)" | tr -d '[:space:]')" = NONE ] || fail \
    "the argv-named asker was typed for acceptance after all, so this fixture no longer reproduces the narrowing"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = no ] || fail \
    "a session named only in its argument list opened the marker accept path"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = yes ] || fail \
    "a live claude holder was not treated as a competing session by an argv-named asker"$'\n'"$(cohort_report "$dir")"
  [ "$(tr -d '[:space:]' < "$dir/lock.rc")" = 1 ] || fail \
    "acquisition did not refuse: rc=$(cat "$dir/lock.rc") out=$(cat "$dir/lock.out")"
  assert_contains "$(cat "$dir/lock.out")" "another live firstmate session holds the lock" \
    "acquisition refused for some reason other than the competing live session"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail \
    "acquisition wrote the argv-named pid over a live claude holder: got $(cat "$dir/state/.lock"), holder $holder, asker $asker"
  pass "session-lock: a session named only in its argument list gets no launch-marker accept path"
}

test_the_same_harness_still_converges_on_the_identical_fixture() {
  local dir holder asker
  dir="$TMP_ROOT/cohort-same-harness"
  cross_harness_fixture "$dir" "$NAMED_CLAUDE"
  holder=$COHORT_HOLDER_PID
  asker=$(tr -d '[:space:]' < "$dir/asker-pid")

  [ "$(cohort_field "$dir" launcher_self)" = "$holder" ] || fail \
    "the fixture did not carry the marker this case rests on"$'\n'"$(cohort_report "$dir")"
  [ "$(printf '%s' "$(cohort_field "$dir" kind_self)" | tr -d '[:space:]')" = claude ] || fail \
    "the asking session did not resolve as claude, so this case does not diverge from the one above"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = yes ] || fail \
    "the same-harness cohort stopped recognizing its own holder, which is the authorized fix for the original defect"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = no ] || fail \
    "the same-harness cohort treated its own holder as a competitor"$'\n'"$(cohort_report "$dir")"
  [ "$(tr -d '[:space:]' < "$dir/lock.rc")" = 0 ] || fail \
    "acquisition failed for a same-harness cohort: $(cat "$dir/lock.out")"
  assert_contains "$(cat "$dir/lock.out")" "converged onto this session's own holder pid $holder" \
    "acquisition did not name the holder it converged onto"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$asker" ] || fail \
    "acquisition did not converge the lock onto the acquiring session: expected $asker, got $(cat "$dir/state/.lock")"
  pass "session-lock: the same harness still converges on the identical fixture"
}

# The property the lock exists for. Same pane, same terminal, same everything a
# co-location signal can see - and no launch relationship, so it is a second
# agent started by hand in the captain's seat and must still be refused.
test_colocated_session_without_a_launch_relationship_is_refused() {
  local dir holder stranger
  dir="$TMP_ROOT/cohort-colocated-stranger"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane
  holder=$COHORT_HOLDER_PID
  stranger=$(nonexistent_cohort_pid)
  run_cohort_session "$dir" "$holder" "$stranger" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane

  # Divergence: co-location is fully present, so only the missing relationship
  # can be producing the refusal.
  [ "$(cohort_field "$dir" container_self)" = "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture failed to co-locate the stranger, so its refusal proves nothing"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" != NONE ] || fail \
    "the fixture produced no container signal at all, so its refusal proves nothing"$'\n'"$(cohort_report "$dir")"

  [ "$(cohort_field "$dir" owned)" = no ] || fail \
    "a separate concurrent session sharing one pane was accepted as this session's own"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" competes)" = yes ] || fail \
    "a separate concurrent session sharing one pane was not treated as a competitor"$'\n'"$(cohort_report "$dir")"
  pass "session-lock: co-location alone never grants ownership of another session's home"
}

# The mirror control: the launch relationship alone is not enough either, so a
# recycled holder pid in an unrelated container cannot be claimed.
test_related_session_in_another_container_is_refused() {
  local dir holder
  dir="$TMP_ROOT/cohort-elsewhere"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir" HERDR_ENV=1 HERDR_PANE_ID=holder-pane
  holder=$COHORT_HOLDER_PID
  run_cohort_session "$dir" "$holder" "$holder" HERDR_ENV=1 HERDR_PANE_ID=session-pane

  [ "$(cohort_field "$dir" container_self)" != "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture failed to separate the two containers, so its refusal proves nothing"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" owned)" = no ] || fail \
    "a launch marker alone granted ownership across two different containers"$'\n'"$(cohort_report "$dir")"
  pass "session-lock: a launch relationship alone never grants ownership across containers"
}

nonexistent_cohort_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

# Evaluate one library expression against the REAL process table, with the same
# cleared signal environment every fixture uses.
lib_probe() {  # <expression>
  "${COHORT_ENV_ARGV[@]}" bash -c ". \"\$0\"; $1" "$LIB"
}

# The same, asked from a harness-named process, so this session has a resolvable
# harness ancestry. The marker path requires one on the asking side - ownership is
# a claim only a harness session can make - so a case that drives the marker path
# has to ask from a harness rather than from a bare shell, whose ancestry depends
# on whether the developer happens to be running the suite inside a live session.
harness_probe() {  # <expression>
  "${COHORT_ENV_ARGV[@]}" "$NAMED_CLAUDE" -c ". \"\$0\"
$1
exit \$?" "$LIB"
}

cohort_tmux() {
  tmux -L "$COHORT_TMUX_SOCKET" "$@"
}

cohort_tmux_ready() {
  command -v tmux >/dev/null 2>&1 || return 1
  cohort_tmux has-session -t cohort 2>/dev/null && return 0
  cohort_tmux new-session -d -s cohort -n control -c "$TMP_ROOT" 2>/dev/null
}

# A dead or recycled holder pid must never be matched through EITHER direction,
# so liveness is decided before any recorded identity of the holder is read.
# Driven with a recorded environment that satisfies every cohort signal at once,
# behind two pids that differ only in whether they are alive.
test_liveness_is_decided_before_any_recorded_cohort_signal() {
  local dir holder dead
  dir="$TMP_ROOT/cohort-liveness-first"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir"
  holder=$COHORT_HOLDER_PID
  dead=$(nonexistent_cohort_pid)

  # Positive control: with the same recorded identity behind a LIVE harness pid,
  # every signal the cohort proof reads is satisfied and the pid is accepted.
  cohort_probe_recorded_identity "$dir/proc" "$holder" \
    || fail "the recorded identity this case drives did not relate a live holder at all, so its refusal below would prove nothing"
  if cohort_probe_recorded_identity "$dir/proc" "$dead"; then
    fail "a dead pid whose recorded identity named this session was accepted as its own holder, so a recycled pid can be claimed"
  fi
  pass "session-lock: a dead holder pid is refused before its recorded identity is consulted"
}

# Populate a fabricated proc root with the /proc/<pid>/stat lines the marker
# ordering reads. `copy` takes a live process's REAL line, so a case can drive
# the ordering from actual process start times; `write` fabricates one with a
# chosen start time, for a case whose relationship the real times cannot express.
# The comm sits in parentheses exactly as the kernel writes it, so the reader
# under test parses a fabricated line the same way it parses a real one.
make_stat_tool() {  # <proc-root>
  local root=$1
  mkdir -p "$root"
  cat > "$root/stat-tool.sh" <<'SH'
#!/usr/bin/env bash
set -u
mode=$1
root=$2
pid=$3
mkdir -p "$root/$pid"
case "$mode" in
  copy) cat "/proc/$pid/stat" > "$root/$pid/stat" ;;
  write) printf '%s (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$4" > "$root/$pid/stat" ;;
  *) exit 2 ;;
esac
SH
}

# Ask the cohort question about <pid> with a fabricated recorded environment for
# it under proc root <root>: a launch marker naming the asking process, plus the
# container the asking process is in. Both cohort signals are then satisfiable,
# so only liveness is left to decide the verdict.
#
# The recorded start times are fabricated to AGREE with the relationship the
# environ claims - the asking process launched the holder, so the holder starts
# one tick later - because the marker path also requires that ordering. The real
# holder here was started before the probe, so copying its real start time would
# make this fixture assert an impossible launch and refuse for that reason
# instead of the one under test. The case below drives that ordering apart on
# purpose.
cohort_probe_recorded_identity() {  # <proc-root> <pid>
  local root=$1 pid=$2
  mkdir -p "$root/$pid"
  make_stat_tool "$root"
  harness_probe "
    HERDR_ENV=1
    HERDR_PANE_ID=fixture-pane
    FM_PROC_ROOT_OVERRIDE='$root'
    bash '$root/stat-tool.sh' copy '$root' \"\$\$\"
    bash '$root/stat-tool.sh' write '$root' $pid \$(( \$(fm_session_pid_start_time \"\$\$\") + 1 ))
    printf 'CLAUDE_PID=%s\0HERDR_ENV=1\0HERDR_PANE_ID=fixture-pane\0' \"\$\$\" > '$root/$pid/environ'
    fm_session_same_cohort $pid
  "
}

# The launch relationship is a number compared against a live pid, so a pid the
# kernel has recycled onto an unrelated session of the same harness satisfies a
# stale marker on identity alone. Ordering is what tells the two apart: a
# launcher necessarily starts before whatever inherited its environment.
#
# Both cases below run the SAME fixture, with the SAME marker naming the SAME
# live claude-typed holder and the same co-location, and differ ONLY in whether
# the recorded start times can express the launch the marker claims. Neither can
# pass by never reaching the marker path, because the other one must accept.
cohort_probe_forward_marker() {  # <dir> real|launched
  local dir=$1 order=$2 root="$1/proc"
  mkdir -p "$dir"
  make_stat_tool "$root"
  cat > "$dir/probe.sh" <<'SH'
# Runs INSIDE a claude-named process with the library already sourced, so this
# process is the asking session and its own start time is the carrier's.
set -u
i=0
# The holder is started HERE, so it genuinely starts after the asking process
# and cannot be the launcher the marker below claims it is. The pause puts it
# several clock ticks later rather than one: the ordering rule deliberately
# accepts an equal tick, because a real launcher and the child it spawns can
# share one, so a holder started in the same instant would prove nothing.
sleep 0.3
# The trailing no-op keeps bash from exec'ing the sleep and losing its name.
"$FM_FIX_CLAUDE" -c 'printf "%s\n" "$$" > "$1/holder-pid"; sleep 120; :' _ "$FM_FIX_DIR" &
while [ "$i" -lt 400 ] && [ ! -s "$FM_FIX_DIR/holder-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
holder=$(tr -d '[:space:]' < "$FM_FIX_DIR/holder-pid")
bash "$FM_FIX_ROOT/stat-tool.sh" copy "$FM_FIX_ROOT" "$$"
case "$FM_FIX_ORDER" in
  # The holder's REAL line, so its actual start time decides.
  real) bash "$FM_FIX_ROOT/stat-tool.sh" copy "$FM_FIX_ROOT" "$holder" ;;
  # A start time that agrees with the claim: our launcher predates us.
  launched) bash "$FM_FIX_ROOT/stat-tool.sh" write "$FM_FIX_ROOT" "$holder" \
    $(( $(fm_session_pid_start_time "$$") - 1 )) ;;
esac
printf 'HERDR_ENV=1\0HERDR_PANE_ID=fixture-pane\0' > "$FM_FIX_ROOT/$holder/environ"
printf 'CLAUDE_PID=%s\0HERDR_ENV=1\0HERDR_PANE_ID=fixture-pane\0' "$holder" > "$FM_FIX_ROOT/$$/environ"
{
  printf 'holder=%s\n' "$holder"
  printf 'launcher_self=%s\n' "$(fm_session_launcher_pid "$$" claude 2>/dev/null || printf NONE)"
  printf 'kind_holder=%s\n' "$(fm_harness_pid_kind "$holder" 2>/dev/null || printf NONE)"
  printf 'container_self=%s\n' "$(fm_session_container_self 2>/dev/null || printf NONE)"
  printf 'container_holder=%s\n' "$(fm_session_container_of_pid "$holder" 2>/dev/null || printf NONE)"
  printf 'start_self=%s\n' "$(fm_session_pid_start_time "$$" 2>/dev/null || printf NONE)"
  printf 'start_holder=%s\n' "$(fm_session_pid_start_time "$holder" 2>/dev/null || printf NONE)"
} > "$FM_FIX_DIR/report"
fm_session_same_cohort "$holder"
SH
  harness_probe "
    HERDR_ENV=1
    HERDR_PANE_ID=fixture-pane
    FM_PROC_ROOT_OVERRIDE='$root'
    FM_FIX_ROOT='$root'
    FM_FIX_DIR='$dir'
    FM_FIX_CLAUDE='$NAMED_CLAUDE'
    FM_FIX_ORDER='$order'
    . '$dir/probe.sh'
  "
}

forward_field() {  # <dir> <key>
  sed -n "s/^$2=//p" "$1/report"
}

test_a_recycled_holder_pid_cannot_satisfy_a_stale_launch_marker() {
  local ok bad
  ok="$TMP_ROOT/cohort-marker-ordered"
  bad="$TMP_ROOT/cohort-marker-recycled"

  # Positive control on the identical fixture: with a start time that can express
  # the launch the marker claims, the relationship is still accepted. Without it
  # the refusal below could come from anything.
  cohort_probe_forward_marker "$ok" launched \
    || fail "a marker naming a holder that predates this process stopped being a launch relationship"$'\n'"$(cat "$ok/report" 2>/dev/null)"
  COHORT_PIDS+=("$(forward_field "$ok" holder)")

  if cohort_probe_forward_marker "$bad" real; then
    COHORT_PIDS+=("$(forward_field "$bad" holder)")
    fail "a live harness holder that started after this process was accepted as the launcher its recycled pid names, so an unrelated session takes this home"$'\n'"$(cat "$bad/report" 2>/dev/null)"
  fi
  COHORT_PIDS+=("$(forward_field "$bad" holder)")

  # Divergence: the marker IS present and DOES name a live claude holder, and
  # co-location holds, so only the ordering can be producing the refusal.
  [ "$(forward_field "$bad" launcher_self)" = "$(forward_field "$bad" holder)" ] || fail \
    "the fixture did not carry a marker naming the holder, so its refusal proves nothing"$'\n'"$(cat "$bad/report")"
  [ "$(forward_field "$bad" kind_holder)" = claude ] || fail \
    "the fixture holder did not resolve as a claude harness"$'\n'"$(cat "$bad/report")"
  [ "$(forward_field "$bad" container_self)" = "$(forward_field "$bad" container_holder)" ] || fail \
    "the fixture lost the co-location the relationship is AND-ed with"$'\n'"$(cat "$bad/report")"
  # And the two fixtures really did diverge on the one thing under test.
  [ "$(forward_field "$bad" start_holder)" -gt "$(forward_field "$bad" start_self)" ] || fail \
    "the refused fixture's holder did not start after the asking process, so it does not reproduce a recycled pid"$'\n'"$(cat "$bad/report")"
  [ "$(forward_field "$ok" start_holder)" -le "$(forward_field "$ok" start_self)" ] || fail \
    "the accepted fixture's holder did not predate the asking process, so the pair does not differ on ordering"$'\n'"$(cat "$ok/report")"
  pass "session-lock: a recycled holder pid cannot satisfy a stale launch marker"
}

# The reverse direction must survive the same rule, because the invariant is
# stated about the CARRIER of the marker rather than about the asking side. A
# blanket "the holder must predate us" rule would silently refuse every session
# that recognizes a lock naming the session it started, which is the case
# test_launching_session_owns_a_lock_naming_the_session_it_started pins
# end-to-end; this asserts the ordering read itself agrees with it.
test_marker_ordering_reads_both_directions_of_a_real_pair() {
  local dir parent child
  dir="$TMP_ROOT/cohort-marker-directions"
  mkdir -p "$dir"
  # A real launcher/launched pair: the parent necessarily starts first.
  "$NAMED_CLAUDE" -c 'printf "%s\n" "$$" > "$1/parent-pid"; sleep 120; :' _ "$dir" &
  COHORT_PIDS+=("$!")
  parent=$(wait_for_file "$dir/parent-pid" "the ordering fixture parent pid")
  "$NAMED_CLAUDE" -c 'printf "%s\n" "$$" > "$1/child-pid"; sleep 120; :' _ "$dir" &
  COHORT_PIDS+=("$!")
  child=$(wait_for_file "$dir/child-pid" "the ordering fixture child pid")

  lib_probe "fm_session_marker_ordered $child $parent" \
    || fail "a marker carried by the later process naming the earlier one was refused, which would break the forward direction"
  if lib_probe "fm_session_marker_ordered $parent $child"; then
    fail "a marker carried by the earlier process naming the later one was accepted, so ordering is not being read at all"
  fi
  # An unreadable start time refuses rather than accepts, so the marker path
  # degrades to the ancestry verdict instead of opening up.
  if lib_probe "fm_session_marker_ordered $child $(nonexistent_cohort_pid)"; then
    fail "an unreadable start time was accepted, so the ordering check fails open"
  fi
  pass "session-lock: marker ordering accepts a launcher that predates its carrier and refuses one that does not"
}

# The start time is field 22 of /proc/<pid>/stat, and field 2 is the command name
# in parentheses, which CAN contain spaces. A whole-line field index reads 0 for
# this task's own truncated worker shape - the earliest start time expressible,
# which would satisfy every forward comparison and fail open silently on exactly
# the process this work exists to identify.
test_start_time_survives_a_command_name_containing_spaces() {
  local dir spaced plain
  dir="$TMP_ROOT/cohort-spaced-comm-start"
  mkdir -p "$dir"
  "$WORKER_CLAUDE" -c 'printf "%s\n" "$$" > "$1/spaced-pid"; sleep 120; :' _ "$dir" &
  COHORT_PIDS+=("$!")
  spaced=$(wait_for_file "$dir/spaced-pid" "the spaced-comm fixture pid")
  [ "$(ps -o comm= -p "$spaced")" != "$(basename -- "$NAMED_CLAUDE")" ] || fail \
    "the spaced-comm fixture reported a plain command name, so it no longer reproduces the shape"

  plain=$(lib_probe "fm_session_pid_start_time $spaced") \
    || fail "the start time of a process whose command name contains spaces could not be read at all"
  case "$plain" in
    ''|*[!0-9]*) fail "the start time of a spaced command name did not parse as a number: '$plain'" ;;
    0) fail "the start time of a spaced command name read as 0, which accepts every ordering comparison and fails open" ;;
  esac
  # And it agrees with the ordering rule: this process started before the
  # fixture, so a marker the fixture carried could not name it as a launcher.
  if lib_probe "fm_session_marker_ordered $$ $spaced"; then
    fail "a spaced-comm process that started later was ordered as predating this one, so its start time was misread"
  fi
  pass "session-lock: a start time is read correctly when the command name contains spaces"
}

# Co-location has two providers so that neither is load-bearing alone. These two
# cases drive them apart with a real pty and assert that each one carries the
# verdict by itself while the other is provably gone.
test_container_signal_alone_carries_co_location() {
  local dir holder
  if ! cohort_tmux_ready; then
    printf '# skip: tmux is unavailable, so the diverged-terminal case did not run here\n'
    return 0
  fi
  dir="$TMP_ROOT/cohort-container-only"
  make_cohort_fixture "$dir"
  # The holder gets a real controlling terminal that the session cannot share.
  cohort_tmux new-window -d -t cohort: -n holder -c "$dir" -- \
    "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane \
    "$NAMED_CLAUDE" "$dir/holder.sh" \
    || fail "could not start the fixture holder in a real pty"
  holder=$(wait_for_file "$dir/holder-pid" "the pty-hosted fixture holder pid")
  COHORT_PIDS+=("$holder")
  run_cohort_session "$dir" "$holder" "$holder" HERDR_ENV=1 HERDR_PANE_ID=fixture-pane

  [ "$(cohort_field "$dir" tty_holder)" != NONE ] || fail \
    "the holder did not get a real controlling terminal, so nothing was driven apart"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" tty_self)" != "$(cohort_field "$dir" tty_holder)" ] || fail \
    "the terminals did not diverge, so the container signal was not proven sufficient"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" container_self)" = "$(cohort_field "$dir" container_holder)" ] || fail \
    "the fixture lost the container signal it was meant to isolate"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" owned)" = yes ] || fail \
    "ownership did not survive losing the terminal signal"$'\n'"$(cohort_report "$dir")"
  pass "session-lock: the runtime container signal carries co-location with the terminals driven apart"
}

test_terminal_signal_alone_carries_co_location() {
  local dir holder
  if ! cohort_tmux_ready; then
    printf '# skip: tmux is unavailable, so the diverged-container case did not run here\n'
    return 0
  fi
  dir="$TMP_ROOT/cohort-terminal-only"
  make_cohort_fixture "$dir"
  # Holder and session share ONE real pty and carry no container identity at all.
  cat > "$dir/pane.sh" <<'SH'
#!/usr/bin/env bash
"$FM_FIX_CLAUDE" "$FM_FIX/holder.sh" &
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_FIX/holder-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
holder=$(tr -d '[:space:]' < "$FM_FIX/holder-pid")
printf '%s\n' "$holder" > "$FM_FIX/state/.lock"
FM_FIX_HOLDER="$holder" FM_FIX_ORPHAN=0 CLAUDE_PID="$holder" "$FM_FIX_CLAUDE" "$FM_FIX/session.sh"
SH
  chmod +x "$dir/pane.sh"
  cohort_tmux new-window -d -t cohort: -n shared -c "$dir" -- \
    "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" FM_FIX_LIB="$LIB" FM_FIX_CLAUDE="$NAMED_CLAUDE" \
    bash "$dir/pane.sh" \
    || fail "could not start the shared-pty fixture"
  holder=$(wait_for_file "$dir/holder-pid" "the shared-pty fixture holder pid")
  COHORT_PIDS+=("$holder")
  wait_for_file "$dir/check-finished" "the shared-pty fixture check result" >/dev/null

  [ "$(cohort_field "$dir" container_self)" = NONE ] && [ "$(cohort_field "$dir" container_holder)" = NONE ] || fail \
    "the fixture still carried a container signal, so the terminal signal was not proven sufficient"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" tty_self)" != NONE ] || fail \
    "the shared-pty fixture had no controlling terminal to share"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" tty_self)" = "$(cohort_field "$dir" tty_holder)" ] || fail \
    "holder and session did not share one terminal"$'\n'"$(cohort_report "$dir")"
  [ "$(cohort_field "$dir" owned)" = yes ] || fail \
    "ownership did not survive losing the container signal"$'\n'"$(cohort_report "$dir")"
  pass "session-lock: the controlling terminal carries co-location with the containers driven apart"
}

# Ask the REAL bin/fm-lock.sh what it reports about a home's recorded holder.
lock_status() {  # <dir>
  "${COHORT_ENV_ARGV[@]}" FM_HOME="$1" "$ROOT/bin/fm-lock.sh" status 2>&1
}

wait_for_state() {  # <pid> <T|running> <what>
  local pid=$1 want=$2 what=$3 i=0 state
  while [ "$i" -lt 200 ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$want:$state" in
      T:T*) return 0 ;;
      running:T*) : ;;
      running:?*) return 0 ;;
    esac
    sleep 0.05
    i=$((i + 1))
  done
  fail "$what"
}

# A stopped holder never released the lock, because kill -0 succeeds on a
# stopped process. The decision recorded in the library is that a stopped
# process is not holding: these are the real signals and the real transition.
test_suspended_holder_releases_and_resumes() {
  local dir holder
  dir="$TMP_ROOT/cohort-suspended"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir"
  holder=$COHORT_HOLDER_PID

  lib_probe "fm_session_lock_holder_competes $holder" \
    || fail "a running holder in another session was not treated as a competitor"
  if lib_probe "fm_harness_pid_suspended $holder"; then
    fail "a running holder was classified as suspended"
  fi

  kill -STOP "$holder" 2>/dev/null || fail "could not suspend the fixture holder"
  wait_for_state "$holder" T "the fixture holder never reached the stopped state"

  lib_probe "fm_harness_pid_alive $holder" \
    || fail "a stopped harness stopped being reported as alive, which is a separate fact from holding"
  lib_probe "fm_harness_pid_suspended $holder" \
    || fail "a durably stopped harness was not recognized as suspended"

  # The decision is required to be observable, and status is the other half of
  # that surface: an operator diagnosing a wedged home must not be told a durably
  # stopped holder is simply live.
  printf '%s\n' "$holder" > "$dir/state/.lock"
  assert_contains "$(lock_status "$dir")" SUSPENDED \
    "fm-lock.sh status did not report a durably stopped holder as suspended"
  assert_contains "$(lock_status "$dir")" reclaimable \
    "fm-lock.sh status did not report a suspended holder as reclaimable"
  if lib_probe "fm_session_lock_holder_competes $holder"; then
    fail "a suspended harness still blocked acquisition, which is the lockout this decision removes"
  fi

  kill -CONT "$holder" 2>/dev/null || fail "could not resume the fixture holder"
  wait_for_state "$holder" running "the fixture holder never resumed"
  if lib_probe "fm_harness_pid_suspended $holder"; then
    fail "a resumed harness was still classified as suspended"
  fi
  assert_contains "$(lock_status "$dir")" "held by live harness pid $holder" \
    "fm-lock.sh status did not go back to reporting a resumed holder as live"
  lib_probe "fm_session_lock_holder_competes $holder" \
    || fail "a resumed holder did not go back to being a competitor"
  pass "session-lock: a suspended holder stops holding and holds again once it resumes"
}

# The other half of that sentence, through the acquisition path itself: taking a
# home from a durably stopped session genuinely does change hands, so this one is
# reported as a takeover and names the pid it came from.
test_acquisition_names_a_takeover_from_a_suspended_holder() {
  local dir holder out acquirer
  dir="$TMP_ROOT/cohort-suspended-takeover"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir"
  holder=$COHORT_HOLDER_PID
  printf '%s\n' "$holder" > "$dir/state/.lock"
  kill -STOP "$holder" 2>/dev/null || fail "could not suspend the fixture holder"
  wait_for_state "$holder" T "the fixture holder never reached the stopped state"

  # The acquiring session is a harness-named process of its own, so the ancestry
  # terminates inside the fixture; the explicit exit keeps bash from exec'ing
  # fm-lock.sh in its place and sending that walk out to the ambient session.
  out=$("${COHORT_ENV_ARGV[@]}" FM_HOME="$dir" "$NAMED_CLAUDE" \
    -c 'printf "acquirer=%s\n" "$$"; "$0"; exit $?' "$ROOT/bin/fm-lock.sh" 2>&1)
  kill -CONT "$holder" 2>/dev/null || true
  acquirer=$(printf '%s\n' "$out" | sed -n 's/^acquirer=//p')

  [ -n "$acquirer" ] && [ "$acquirer" != "$holder" ] || fail \
    "the fixture did not produce a distinct acquiring session: acquirer=$acquirer holder=$holder"$'\n'"$out"
  assert_contains "$out" "took over from suspended harness pid $holder" \
    "acquisition did not name the suspended holder it took the home from"$'\n'"$out"
  assert_not_contains "$out" 'converged onto' \
    "a takeover from a separate suspended session was reported as this session converging its own lock"$'\n'"$out"
  assert_not_contains "$out" 'not recognised as a harness' \
    "a live holder the identity rules DID type as a harness was reported as unidentified"$'\n'"$out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$acquirer" ] || fail \
    "acquisition did not converge the lock onto the acquiring session: expected $acquirer, got $(cat "$dir/state/.lock")"
  wait_for_state "$holder" running "the fixture holder never resumed"
  pass "session-lock: acquisition names a takeover from a suspended holder and converges the lock"
}

# The suspension verdict is confirmed over several samples on purpose, so a
# momentary stop - a debugger, a profiler, a job control keystroke immediately
# undone - is not read as a session that will never let go.
test_momentary_stop_is_not_a_suspended_holder() {
  local dir holder
  dir="$TMP_ROOT/cohort-momentary-stop"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir"
  holder=$COHORT_HOLDER_PID

  kill -STOP "$holder" 2>/dev/null || fail "could not suspend the fixture holder"
  wait_for_state "$holder" T "the fixture holder never reached the stopped state"
  # Positive control first: left stopped, the same sampling settings must say so.
  lib_probe "FM_SESSION_STOP_SAMPLES=2 FM_SESSION_STOP_SAMPLE_SLEEP=2; fm_harness_pid_suspended $holder" \
    || fail "the multi-sample confirmation could not recognize a genuinely stopped holder"

  ( sleep 0.2; kill -CONT "$holder" 2>/dev/null ) &
  COHORT_PIDS+=("$!")
  if lib_probe "FM_SESSION_STOP_SAMPLES=2 FM_SESSION_STOP_SAMPLE_SLEEP=2; fm_harness_pid_suspended $holder"; then
    fail "a stop undone during the confirmation window was still classified as a suspended session"
  fi
  wait_for_state "$holder" running "the fixture holder never resumed"
  pass "session-lock: a stop undone during confirmation is not a suspended holder"
}

# The sampling settings are environment overrides, and an unusable one must not
# be able to report a live holder as suspended: that is the one verdict that lets
# an acquisition take over a genuinely separate concurrent session's home.
test_unusable_stop_sampling_settings_cannot_release_a_live_holder() {
  local dir holder setting
  dir="$TMP_ROOT/cohort-unusable-sampling"
  make_cohort_fixture "$dir"
  start_cohort_holder "$dir"
  holder=$COHORT_HOLDER_PID

  for setting in \
    'FM_SESSION_STOP_SAMPLES=0' \
    'FM_SESSION_STOP_SAMPLES=abc' \
    'FM_SESSION_STOP_SAMPLES=-1' \
    'FM_SESSION_STOP_SAMPLES=' \
    'FM_SESSION_STOP_SAMPLE_SLEEP=abc' \
    'FM_SESSION_STOP_SAMPLE_SLEEP=0'
  do
    if lib_probe "$setting; fm_harness_pid_suspended $holder"; then
      fail "$setting: a running holder was classified as suspended, so an ambient setting hands another session's home over"
    fi
    lib_probe "$setting; fm_session_lock_holder_competes $holder" \
      || fail "$setting: a running holder in another session stopped being a competitor"
  done

  # The fallback is the documented default rather than a blanket refusal, so a
  # genuinely stopped holder is still recognized under either unusable setting.
  # A non-numeric gap is the sharper of the two: unvalidated it is handed to
  # `sleep`, which fails, and the sequence that cannot complete reports a really
  # stopped holder as live - the permanent lockout this decision removes.
  kill -STOP "$holder" 2>/dev/null || fail "could not suspend the fixture holder"
  wait_for_state "$holder" T "the fixture holder never reached the stopped state"
  lib_probe "FM_SESSION_STOP_SAMPLES=abc; fm_harness_pid_suspended $holder" \
    || fail "an unusable sample count refused every suspension instead of falling back to the default"
  lib_probe "FM_SESSION_STOP_SAMPLE_SLEEP=abc; fm_harness_pid_suspended $holder" \
    || fail "an unusable sample gap made a genuinely stopped holder look live, so its home would never be reclaimable"

  # A zero gap is the other direction: unvalidated, every sample lands inside the
  # same instant, so the stop below - undone well inside the real confirmation
  # window - would be read as a suspended session.
  ( sleep 0.4; kill -CONT "$holder" 2>/dev/null ) &
  COHORT_PIDS+=("$!")
  if lib_probe "FM_SESSION_STOP_SAMPLES=20 FM_SESSION_STOP_SAMPLE_SLEEP=0; fm_harness_pid_suspended $holder"; then
    fail "a zero sample gap collapsed the confirmation window, so a momentary stop was read as a suspended session"
  fi
  wait_for_state "$holder" running "the fixture holder never resumed"
  pass "session-lock: unusable stop-sampling settings fall back to the default and never release a live holder"
}

# Ask the shared predicate about a recorded holder and print the clause it left
# behind, so a case can assert what an operator would be told rather than only
# the verdict. A competing holder prints nothing and exits non-zero, which no
# case below drives.
yield_reason() {  # <pid>
  "${COHORT_ENV_ARGV[@]}" bash -c '. "$0"
if fm_session_lock_holder_competes "$1"; then exit 1; fi
printf "%s\n" "$FM_SESSION_HOLDER_YIELD_REASON"' "$LIB" "$1"
}

# A live process whose reported command name is `node` and whose script argument
# is an npm `claude-code` layout path. Identification declines it on purpose -
# the package component is `claude-code` and not `claude` - and the same rule
# also judges a RECORDED holder, so a lock an older firstmate wrote for a session
# of exactly this shape is reclaimed while that session is still running. The
# reclaim is not being changed; it is required to announce itself.
test_reclaim_of_a_live_unidentified_holder_names_itself() {
  local dir layout holder out acquirer reason
  dir="$TMP_ROOT/cohort-unidentified-holder"
  make_cohort_fixture "$dir"
  # A real interpreter-named executable, so `node` is produced by the kernel and
  # by ps rather than by a fixture that was told what to print.
  layout="$dir/npm/lib/node_modules/@anthropic-ai/claude-code"
  mkdir -p "$layout" "$dir/npm/bin"
  cp /bin/bash "$dir/npm/bin/node"
  cat > "$layout/cli.js" <<'SH'
printf '%s\n' "$$" > "$FM_FIX/holder-pid"
sleep 120
:
SH
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" "$dir/npm/bin/node" "$layout/cli.js" \
    > "$dir/holder.out" 2>&1 &
  COHORT_PIDS+=("$!")
  holder=$(wait_for_file "$dir/holder-pid" "the npm-layout fixture holder pid")

  # The case is only about the holder the identity rules decline, so prove they
  # decline it before asserting anything about the reclaim.
  if lib_probe "fm_harness_pid_alive $holder"; then
    fail "the npm-layout fixture was identified as a harness, so this case cannot reach the reclaim it exists to pin"
  fi
  kill -0 "$holder" 2>/dev/null || fail "the npm-layout fixture holder was not a live process"

  reason=$(yield_reason "$holder") || fail \
    "a live but unidentified holder blocked acquisition, which is the read-only lockout this must not introduce"
  [ -n "$reason" ] || fail "reclaiming a live but unidentified holder stayed silent"
  assert_contains "$reason" "$holder" \
    "the reclaim clause did not name the holder pid an operator would have to look up"
  assert_contains "$reason" 'alive but not recognised as a harness' \
    "the reclaim clause did not say the holder was alive and unrecognised"

  # The line the captain would actually see, through the real acquisition path.
  printf '%s\n' "$holder" > "$dir/state/.lock"
  out=$("${COHORT_ENV_ARGV[@]}" FM_HOME="$dir" "$NAMED_CLAUDE" \
    -c 'printf "acquirer=%s\n" "$$"; "$0"; exit $?' "$ROOT/bin/fm-lock.sh" 2>&1)
  acquirer=$(printf '%s\n' "$out" | sed -n 's/^acquirer=//p')
  [ -n "$acquirer" ] && [ "$acquirer" != "$holder" ] || fail \
    "the fixture did not produce a distinct acquiring session: acquirer=$acquirer holder=$holder"$'\n'"$out"
  assert_contains "$out" "lock acquired: harness pid $acquirer" \
    "acquisition did not succeed against a live but unidentified holder"$'\n'"$out"
  assert_contains "$out" "alive but not recognised as a harness" \
    "acquisition reclaimed a visibly live holder without saying so"$'\n'"$out"
  assert_contains "$out" "$holder" \
    "acquisition did not name the live holder it reclaimed the home from"$'\n'"$out"
  assert_not_contains "$out" 'converged onto' \
    "a reclaim from an unidentified process was reported as this session converging its own lock"$'\n'"$out"
  assert_not_contains "$out" 'took over from suspended' \
    "a reclaim from an unidentified process was reported as a takeover from a suspended session"$'\n'"$out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$acquirer" ] || fail \
    "acquisition did not converge the lock onto the acquiring session: expected $acquirer, got $(cat "$dir/state/.lock")"
  kill -0 "$holder" 2>/dev/null || fail \
    "the unidentified holder died during the case, so the reclaim it pinned may have been the ordinary silent one"
  pass "session-lock: reclaiming a live but unidentified holder names it instead of moving the lock silently"
}

# The other side of that distinction, and the common case by far: a holder that
# is simply gone has always been reclaimed in silence, so an ordinary session
# start must gain no new line at all.
test_a_gone_holder_is_reclaimed_silently() {
  local dir gone out acquirer reason i
  dir="$TMP_ROOT/cohort-gone-holder"
  make_cohort_fixture "$dir"
  "${COHORT_ENV_ARGV[@]}" FM_FIX="$dir" "$NAMED_CLAUDE" \
    -c 'printf "%s\n" "$$" > "$FM_FIX/gone-pid"' &
  gone=$!
  wait "$gone" 2>/dev/null || true
  gone=$(wait_for_file "$dir/gone-pid" "the exited fixture holder pid")
  i=0
  while kill -0 "$gone" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if kill -0 "$gone" 2>/dev/null; then
    fail "the fixture holder never exited, so this case cannot pin the gone reclaim"
  fi

  reason=$(yield_reason "$gone") || fail "a holder that no longer exists blocked acquisition"
  [ -z "$reason" ] || fail \
    "reclaiming a holder that no longer exists announced itself: '$reason'"

  printf '%s\n' "$gone" > "$dir/state/.lock"
  out=$("${COHORT_ENV_ARGV[@]}" FM_HOME="$dir" "$NAMED_CLAUDE" \
    -c 'printf "acquirer=%s\n" "$$"; "$0"; exit $?' "$ROOT/bin/fm-lock.sh" 2>&1)
  acquirer=$(printf '%s\n' "$out" | sed -n 's/^acquirer=//p')
  [ -n "$acquirer" ] || fail "the fixture did not produce an acquiring session"$'\n'"$out"
  assert_contains "$out" "lock acquired: harness pid $acquirer" \
    "acquisition did not succeed against a holder that no longer exists"$'\n'"$out"
  assert_not_contains "$out" '(' \
    "reclaiming a holder that no longer exists gained a reason clause, so every ordinary session start now reports one"$'\n'"$out"
  pass "session-lock: a holder that no longer exists is still reclaimed silently"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_node_main_thread_identity_comes_only_from_the_script_path
test_bare_interpreter_identity_stops_at_the_first_flag
test_acceptance_typing_comes_only_from_executable_identity
test_real_reported_command_names_are_typed_for_acceptance
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_rehosted_session_owns_the_lock_it_cannot_reach
test_launching_session_owns_a_lock_naming_the_session_it_started
test_a_different_harness_never_believes_an_inherited_launch_marker
test_a_session_named_only_in_argv_gets_no_accept_path
test_the_same_harness_still_converges_on_the_identical_fixture
test_colocated_session_without_a_launch_relationship_is_refused
test_related_session_in_another_container_is_refused
test_liveness_is_decided_before_any_recorded_cohort_signal
test_a_recycled_holder_pid_cannot_satisfy_a_stale_launch_marker
test_marker_ordering_reads_both_directions_of_a_real_pair
test_start_time_survives_a_command_name_containing_spaces
test_container_signal_alone_carries_co_location
test_terminal_signal_alone_carries_co_location
test_suspended_holder_releases_and_resumes
test_acquisition_names_a_takeover_from_a_suspended_holder
test_reclaim_of_a_live_unidentified_holder_names_itself
test_a_gone_holder_is_reclaimed_silently
test_momentary_stop_is_not_a_suspended_holder
test_unusable_stop_sampling_settings_cannot_release_a_live_holder
