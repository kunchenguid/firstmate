#!/usr/bin/env bash
# Behavior tests for launch modes and the per-session Firstmate view:
# bin/firstmate mode selection and bin/fm-view.sh (docs/configuration.md
# "Launch modes").
#
# Pinned contracts:
#   - mode selection: unset mode on a host that cannot build the view falls
#     back to install mode with a one-line notice naming the reason, exported
#     as FM_LAUNCH_NOTICE; an explicit project mode there (flag or
#     config/launch-mode) refuses with the reason and never runs the harness;
#     --mode install needs no view; a launch with no project or org root runs
#     in install mode and refuses an explicit project mode; a launch root that
#     is another Firstmate checkout runs as its own install root; a bad mode
#     value fails loudly.
#   - codex is launched with -c project_doc_max_bytes=262144 in either mode.
#   - a claude launch has auto-memory switched off
#     (CLAUDE_CODE_DISABLE_AUTO_MEMORY=1) in install mode too, so homes
#     launched from the install root share no per-directory store.
#   - on a host that can build the view, an unset mode runs the harness at the
#     launch root (the repo top, or the org root) inside the view, and a claude
#     launch there has auto-memory switched off (CLAUDE_CODE_DISABLE_AUTO_MEMORY=1),
#     so it can land neither in the shared install .claude/ nor in a
#     per-directory store shared with plain sessions.
#   - the view: composed AGENTS.md (contract first, then the project's own),
#     merged bin/, Firstmate winning a docs/ collision, hidden .mcp.json and
#     CLAUDE.local.md (folded, never native); the
#     project and the Firstmate surface are read-only while .firstmate/ and
#     FM_LAUNCH_REAL_RW are writable; the host sees no view file.
#   - the git shim: clean status, `git add -A` stages nothing, the top level is
#     the launch path; a falsification pass removes the shim bind and asserts
#     the view then looks dirty, and removes the read-only remount and asserts a
#     write then lands, each after asserting that its mutation applied.
#   - the keeper presents a top-level entry created outside the session.
#   - worker placement: inside a view a process started in the view is
#     "inside", the tmux container refuses to start a server there, and outside
#     a view the guard is inert.
# View cases run only where this host can build a view (bin/fm-view.sh probe);
# they report an explicit skip otherwise. Every fixture is a disposable temp
# directory, including the install root the view presents.
# Scripts run inside the view expand their own variables there, so their
# single-quoted bodies are deliberate.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-view-tests)
# The view's runtime dir lives in the fixture, never the real runtime dir.
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
unset FM_VIEW FM_VIEW_ROOT FM_LAUNCH_REAL FM_LAUNCH_REAL_RW FM_LAUNCH_ROOT FM_LAUNCH_MODE FM_LAUNCH_NOTICE
unset CLAUDE_CODE_DISABLE_AUTO_MEMORY

VIEW_OK=0
if "$ROOT/bin/fm-view.sh" probe >/dev/null 2>&1; then
  VIEW_OK=1
fi

new_dir() {
  mktemp -d "$TMP_ROOT/case.XXXXXX"
}

skip_without_view() {
  if [ "$VIEW_OK" -ne 1 ]; then
    printf 'ok - SKIP %s: this host cannot build a Firstmate view (%s)\n' "$1" \
      "$("$ROOT/bin/fm-view.sh" probe 2>&1 | sed -n '1p')"
    return 0
  fi
  return 1
}

# make_fake_harness <dir> <name>: a harness stub that records its cwd, args,
# and launch environment, plus the first line of the AGENTS.md it sees.
make_fake_harness() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat > "$dir/$name" <<'SH'
#!/usr/bin/env bash
{
  printf 'PWD=%s\n' "$(pwd -P)"
  printf 'ARGS=%s\n' "$*"
  printf 'MODE=%s\n' "${FM_LAUNCH_MODE:-}"
  printf 'ROOT=%s\n' "${FM_LAUNCH_ROOT:-}"
  printf 'CODE_ROOT=%s\n' "${FM_ROOT_OVERRIDE:-}"
  printf 'VIEW=%s\n' "${FM_VIEW:-}"
  printf 'NOTICE=%s\n' "${FM_LAUNCH_NOTICE:-}"
  printf 'MEMORY_OFF=%s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}"
  printf 'AGENTS_HEAD=%s\n' "$(head -n 1 AGENTS.md 2>/dev/null)"
} > "$FM_FAKE_HARNESS_OUT"
SH
  chmod +x "$dir/$name"
}

# make_refusing_unshare <dir>: an unshare that fails the way a host refusing
# unprivileged user namespaces does.
make_refusing_unshare() {
  mkdir -p "$1"
  printf '#!/bin/sh\necho "unshare: write failed /proc/self/uid_map: Operation not permitted" >&2\nexit 1\n' > "$1/unshare"
  chmod +x "$1/unshare"
}

# make_project <dir>: a disposable project repo with its own instructions,
# a bin/ and docs/ that collide with Firstmate's, a hidden .mcp.json, a
# project .claude/, and a trusted per-project home.
make_project() {
  local p=$1
  mkdir -p "$p/bin" "$p/docs" "$p/src" "$p/.claude"
  printf '# demo project\nZQ_DEMO_PROJECT_MARKER\n' > "$p/AGENTS.md"
  printf '@AGENTS.md\n' > "$p/CLAUDE.md"
  printf '#!/bin/sh\necho serving\n' > "$p/bin/serve.sh"
  printf 'ZQ_PROJECT_CONFIGURATION\n' > "$p/docs/configuration.md"
  printf 'ZQ_PROJECT_NOTES\n' > "$p/docs/notes.md"
  printf 'app\n' > "$p/src/app.js"
  printf '{"mcpServers":{}}\n' > "$p/.mcp.json"
  printf '{}\n' > "$p/.claude/settings.json"
  printf '.firstmate/\n' > "$p/.gitignore"
  git -C "$p" init -q -b main
  git -C "$p" add -A
  git -C "$p" commit -qm fixture
  mkdir -p "$p/.firstmate/data" "$p/.firstmate/state" "$p/.firstmate/config"
  : > "$p/.firstmate/.fm-home"
}

# make_install <dir>: a disposable Firstmate install root for bin/fm-view.sh.
make_install() {
  local i=$1
  mkdir -p "$i/bin" "$i/docs" "$i/.claude" "$i/.agents/skills"
  printf '# Firstmate\nZQ_TEST_CONTRACT\n' > "$i/AGENTS.md"
  printf '@AGENTS.md\n' > "$i/CLAUDE.md"
  printf '#!/bin/sh\n' > "$i/bin/fm-session-start.sh"
  printf 'ZQ_FIRSTMATE_CONFIGURATION\n' > "$i/docs/configuration.md"
  printf '{}\n' > "$i/.claude/settings.json"
}

# --- mode selection ------------------------------------------------------------

test_mode_fallback_and_refusal() {
  local base proj fakebin nounshare out err
  base=$(new_dir)
  proj="$base/demo"
  make_project "$proj"
  fakebin="$base/fakebin"
  make_fake_harness "$fakebin" claude
  make_fake_harness "$fakebin" codex
  nounshare="$base/nounshare"
  make_refusing_unshare "$nounshare"

  # Unset mode on a host that cannot build the view: install mode, one notice.
  (cd "$proj/src" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out1" \
    PATH="$nounshare:$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err1") \
    || fail "fallback launch failed: $(cat "$base/err1")"
  assert_grep "PWD=$ROOT" "$base/out1" "fallback did not run from the install root"
  assert_grep "MODE=install" "$base/out1" "fallback did not export install mode"
  assert_grep "NOTICE=project mode unavailable (this host refuses an unprivileged user+mount namespace" "$base/out1" \
    "fallback did not export the notice naming the reason"
  err=$(cat "$base/err1")
  assert_contains "$err" "firstmate: notice: project mode unavailable" "fallback printed no launch notice"
  assert_equals 1 "$(grep -c 'notice' "$base/err1")" "fallback notice was not one line"
  assert_grep "ROOT=$proj" "$base/out1" "fallback did not export the launch root"
  assert_grep "MEMORY_OFF=1" "$base/out1" "a claude install-mode session left auto-memory on"

  # Explicit project mode there refuses with the reason; the harness never runs.
  rm -f "$base/out2"
  if (cd "$proj" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out2" \
      PATH="$nounshare:$fakebin:$PATH" "$ROOT/bin/firstmate" --mode project 2>"$base/err2"); then
    fail "explicit project mode on an unsupported host did not refuse"
  fi
  assert_grep "project mode unavailable: this host refuses an unprivileged user+mount namespace" "$base/err2" \
    "project-mode refusal did not name the reason"
  assert_absent "$base/out2" "a refused project-mode launch still ran the harness"

  # config/launch-mode=project is the same explicit choice.
  printf 'project\n' > "$proj/.firstmate/config/launch-mode"
  if (cd "$proj" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out3" \
      PATH="$nounshare:$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err3"); then
    fail "config/launch-mode=project on an unsupported host did not refuse"
  fi
  assert_grep "project mode unavailable" "$base/err3" "config project-mode refusal did not name the reason"
  # --mode wins over the home default.
  (cd "$proj" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out4" \
    PATH="$nounshare:$fakebin:$PATH" "$ROOT/bin/firstmate" --mode install 2>"$base/err4") \
    || fail "--mode install did not override config/launch-mode"
  assert_grep "PWD=$ROOT" "$base/out4" "--mode install did not run from the install root"
  assert_grep "MEMORY_OFF=1" "$base/out4" "an explicit install-mode claude session left auto-memory on"
  assert_no_grep "notice" "$base/err4" "an explicit install mode printed a fallback notice"
  printf 'sideways\n' > "$proj/.firstmate/config/launch-mode"
  if (cd "$proj" && env -u FM_HOME PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err5"); then
    fail "an unknown config/launch-mode value was accepted"
  fi
  assert_grep "launch mode must be project or install" "$base/err5" "bad mode value was not named"
  rm -f "$proj/.firstmate/config/launch-mode"
  if (cd "$proj" && env -u FM_HOME PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --mode bogus 2>/dev/null); then
    fail "an unknown --mode value was accepted"
  fi

  # Codex gets the raised instruction cap, ahead of the pass-through args.
  (cd "$proj" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out6" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --mode install --harness codex resume 2>/dev/null) \
    || fail "codex launch failed"
  assert_grep "ARGS=-c project_doc_max_bytes=262144 resume" "$base/out6" \
    "codex was not launched with the raised project_doc_max_bytes"
  assert_no_grep "MEMORY_OFF=1" "$base/out6" "a codex launch was given claude's auto-memory switch"

  # No project or org root: install mode without a notice; project refuses.
  local bare="$base/bare" globalhome="$base/globalhome"
  mkdir -p "$bare" "$globalhome/.firstmate"
  (cd "$bare" && env -u FM_HOME HOME="$globalhome" FM_FAKE_HARNESS_OUT="$base/out7" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err7") || fail "non-project launch failed"
  assert_grep "MODE=install" "$base/out7" "a launch with no project did not use install mode"
  assert_no_grep "notice" "$base/err7" "a launch with no project printed a fallback notice"
  if (cd "$bare" && env -u FM_HOME HOME="$globalhome" PATH="$fakebin:$PATH" \
      "$ROOT/bin/firstmate" --mode project 2>"$base/err8"); then
    fail "project mode with no project or org root did not refuse"
  fi
  assert_grep "inside no git repository and no org home" "$base/err8" "no-project refusal did not name the reason"

  # A launch root that is another Firstmate checkout runs as its own root.
  local other="$base/other-firstmate"
  mkdir -p "$other/bin"
  printf '# Firstmate\n' > "$other/AGENTS.md"
  : > "$other/bin/firstmate"
  : > "$other/bin/fm-session-start.sh"
  git -C "$other" init -q -b main
  git -C "$other" add -A
  git -C "$other" commit -qm checkout
  (cd "$other" && env FM_HOME="$proj/.firstmate" FM_FAKE_HARNESS_OUT="$base/out9" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err9") || fail "Firstmate-checkout launch failed"
  assert_grep "PWD=$other" "$base/out9" "a Firstmate checkout did not run as its own install root"
  assert_grep "CODE_ROOT=$other" "$base/out9" "a Firstmate checkout was not its own code root"
  assert_grep "MODE=install" "$base/out9" "a Firstmate checkout was viewed"

  pass "launch modes: fallback notice, explicit refusal, config default, install-mode auto-memory off, codex cap, no-project and self-checkout launches"
}

test_mode_project_default() {
  local base proj fakebin org
  skip_without_view "project mode by default" && return 0
  base=$(new_dir)
  proj="$base/demo"
  make_project "$proj"
  fakebin="$base/fakebin"
  make_fake_harness "$fakebin" claude

  (cd "$proj/src" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out1" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err1") \
    || fail "project-mode launch failed: $(cat "$base/err1")"
  assert_grep "PWD=$proj" "$base/out1" "project mode did not run at the repo top"
  assert_grep "MODE=project" "$base/out1" "project mode was not exported"
  assert_grep "VIEW=1" "$base/out1" "the harness did not run inside the view"
  assert_grep "AGENTS_HEAD=# Firstmate" "$base/out1" "the launch root did not present the composed contract"
  assert_grep "MEMORY_OFF=1" "$base/out1" "a claude view session left auto-memory on"
  assert_no_grep "notice" "$base/err1" "a supported project-mode launch printed a notice"

  # An org launch roots the view at the org, not at a sibling repo.
  org="$base/org"
  mkdir -p "$org/.firstmate/config" "$org/.firstmate/data" "$org/.firstmate/state"
  printf '..\n' > "$org/.firstmate/config/projects-root"
  : > "$org/.firstmate/.fm-home"
  make_project "$org/alpha"
  (cd "$org" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out2" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" 2>"$base/err2") \
    || fail "org project-mode launch failed: $(cat "$base/err2")"
  assert_grep "PWD=$org" "$base/out2" "an org launch was not rooted at the org"
  assert_grep "ROOT=$org" "$base/out2" "an org launch did not export the org root"

  pass "project mode is the default on a capable host; claude auto-memory is off there; org launches root at the org"
}

# --- the view itself -----------------------------------------------------------

# view_run <install> <project> <script>: run a bash script inside the view.
view_run() {
  local install=$1 proj=$2 script=$3
  (cd "$proj" && FM_HOME="$proj/.firstmate" FM_VIEW_POLL=1 \
    "${FM_VIEW_SCRIPT:-$ROOT/bin/fm-view.sh}" run --install "$install" --launch "$proj" -- bash -c "$script")
}

test_view_layout_and_read_only() {
  local base install proj out
  skip_without_view "view layout and read-only project" && return 0
  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"
  printf 'ZQ_LOCAL_CLAUDE_MARKER\n' > "$proj/CLAUDE.local.md"
  printf 'CLAUDE.local.md\n' >> "$proj/.git/info/exclude"

  out=$(view_run "$install" "$proj" '
    echo "cwd=$(pwd -P)"
    grep -q ZQ_LOCAL_CLAUDE_MARKER AGENTS.md && echo "local_folded=yes"
    [ -e CLAUDE.local.md ] || echo "local_hidden=yes"
    echo "agents_head=$(head -n 1 AGENTS.md)"
    grep -q ZQ_DEMO_PROJECT_MARKER AGENTS.md && echo "project_folded=yes"
    grep -q "FM_LAUNCH_REAL_RW" AGENTS.md && echo "rw_path_named=yes"
    echo "claude=$(cat CLAUDE.md)"
    [ -e bin/serve.sh ] && echo "project_bin=yes"
    [ -e bin/fm-session-start.sh ] && echo "firstmate_bin=yes"
    echo "docs_conf=$(cat docs/configuration.md)"
    echo "docs_notes=$(cat docs/notes.md)"
    [ -e .mcp.json ] || echo "mcp_hidden=yes"
    echo "claude_settings_from=$(cat .claude/settings.json)"
    touch newfile 2>/dev/null || echo "root_ro=yes"
    { echo x >> src/app.js; } 2>/dev/null || echo "project_file_ro=yes"
    touch .claude/new 2>/dev/null || echo "surface_ro=yes"
    touch .agents/new 2>/dev/null || echo "agents_ro=yes"
    { echo x >> bin/fm-session-start.sh; } 2>/dev/null || echo "merged_fm_ro=yes"
    touch .firstmate/state/probe && echo "home_rw=yes"
    echo written > "$FM_LAUNCH_REAL_RW/approved.txt" && echo "real_rw=yes"
    [ -e "$FM_LAUNCH_REAL/.mcp.json" ] && echo "real_ro_readable=yes"
    touch "$FM_LAUNCH_REAL/nope" 2>/dev/null || echo "real_ro=yes"
  ') || fail "view run failed"
  assert_contains "$out" "cwd=$proj" "the view did not run at the launch path"
  assert_contains "$out" "agents_head=# Firstmate" "AGENTS.md did not start with the Firstmate contract"
  assert_contains "$out" "project_folded=yes" "the project's own AGENTS.md was not folded in"
  assert_contains "$out" "rw_path_named=yes" "the composed file did not name the approved-operation path"
  assert_contains "$out" "claude=@AGENTS.md" "CLAUDE.md was not Firstmate's pointer"
  assert_contains "$out" "project_bin=yes" "the project's bin/ entries were not merged"
  assert_contains "$out" "firstmate_bin=yes" "Firstmate's bin/ entries were not presented"
  assert_contains "$out" "docs_conf=ZQ_FIRSTMATE_CONFIGURATION" "Firstmate did not win a docs/ collision"
  assert_contains "$out" "docs_notes=ZQ_PROJECT_NOTES" "a project-only docs/ entry was not presented"
  assert_contains "$out" "mcp_hidden=yes" "the project's .mcp.json was not hidden"
  assert_contains "$out" "local_folded=yes" "the project's CLAUDE.local.md was not folded into AGENTS.md"
  assert_contains "$out" "local_hidden=yes" "the project's CLAUDE.local.md was also presented natively"
  assert_contains "$("$ROOT/bin/fm-view.sh" shadowed "$proj")" "$(printf 'CLAUDE.local.md\tfolded')" \
    "shadowed did not report CLAUDE.local.md as folded"
  assert_contains "$out" "claude_settings_from={}" "the Firstmate .claude/ surface was not presented"
  assert_contains "$out" "root_ro=yes" "a new file could be created at the launch root"
  assert_contains "$out" "project_file_ro=yes" "a project file was writable"
  assert_contains "$out" "surface_ro=yes" "the Firstmate .claude/ surface was writable"
  assert_contains "$out" "agents_ro=yes" "the Firstmate .agents/ surface was writable"
  assert_contains "$out" "merged_fm_ro=yes" "a Firstmate script in the merged bin/ was writable"
  assert_contains "$out" "home_rw=yes" "the project's .firstmate/ home was not writable"
  assert_contains "$out" "real_rw=yes" "FM_LAUNCH_REAL_RW was not writable"
  assert_contains "$out" "real_ro_readable=yes" "FM_LAUNCH_REAL did not expose the real tree"
  assert_contains "$out" "real_ro=yes" "FM_LAUNCH_REAL was writable"

  # The host saw only the approved write and the home write, never a view file.
  assert_present "$proj/approved.txt" "the FM_LAUNCH_REAL_RW write did not land on the real tree"
  assert_present "$proj/.firstmate/state/probe" "the home write did not land on the real tree"
  assert_absent "$proj/newfile" "a view write reached the real tree"
  assert_absent "$proj/.agents" "the view leaked Firstmate's surface into the real tree"
  assert_absent "$install/.claude/new" "a view write reached the install surface"
  assert_equals '#!/bin/sh' "$(cat "$install/bin/fm-session-start.sh")" "a write through the merged bin/ changed the install"
  assert_equals '# demo project' "$(head -n 1 "$proj/AGENTS.md")" "the real AGENTS.md changed"
  assert_equals 'app' "$(cat "$proj/src/app.js")" "a project file changed"
  if command -v findmnt >/dev/null 2>&1; then
    assert_equals 0 "$(findmnt -rn 2>/dev/null | grep -c fm-view || true)" "a view mount leaked onto the host"
  fi
  rm -f "$proj/approved.txt"

  pass "view: composed contract, merged bin/, Firstmate docs win, hidden .mcp.json, read-only project and surface, writable home and approved path"
}

test_view_git_shim() {
  local base install proj out
  skip_without_view "view git shim" && return 0
  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"

  out=$(view_run "$install" "$proj" '
    echo "status_lines=$(git status --porcelain | wc -l | tr -d " ")"
    git add -A && echo "staged=$(git diff --cached --name-only | wc -l | tr -d " ")"
    echo "toplevel=$(git rev-parse --show-toplevel)"
    echo "head_agents=$(git show HEAD:AGENTS.md | head -n 1)"
    (cd src && echo "sub_status=$(git status --porcelain | wc -l | tr -d " ")")
  ') || fail "view git run failed"
  assert_contains "$out" "status_lines=0" "git status was not clean inside the view"
  assert_contains "$out" "staged=0" "git add -A staged a view file"
  assert_contains "$out" "toplevel=$proj" "git did not see the launch path as the top level"
  assert_contains "$out" "head_agents=# demo project" "git did not read the real tree"
  assert_contains "$out" "sub_status=0" "git status from a subdirectory was not clean"
  assert_equals 0 "$(git -C "$proj" status --porcelain | wc -l | tr -d ' ')" "the host tree is not clean"

  pass "git shim: clean status, nothing staged, real top level from the view"
}

# mutate <src> <dst> <line-pattern>: copy <src> to <dst> without the lines
# matching <line-pattern>, and fail loudly unless that changed the file.
mutate() {
  local src=$1 dst=$2 pattern=$3
  grep -v -- "$pattern" "$src" > "$dst"
  chmod +x "$dst"
  if cmp -s "$src" "$dst"; then
    fail "MUTATION DID NOT APPLY: no line of $src matches '$pattern'"
  fi
  printf '  mutation removed: %s\n' "$(diff "$src" "$dst" | sed -n 's/^< //p' | sed -n '1p' | sed 's/^ *//')"
}

test_view_falsification() {
  local base install proj out mutated
  skip_without_view "view falsification" && return 0
  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"

  # Without the shim bind, git inside the view sees the view and reports it.
  mutated="$base/fm-view-noshim.sh"
  mutate "$ROOT/bin/fm-view.sh" "$mutated" 'mount --bind -- "$RUN/git-shim" "$GIT_REAL"'
  out=$(FM_VIEW_SCRIPT=$mutated view_run "$install" "$proj" 'git status --porcelain | wc -l | tr -d " "') \
    || fail "falsification run without the shim failed"
  [ "$out" -gt 0 ] || fail "removing the git shim did not make the view look dirty; the clean-status test proves nothing"

  # Without the read-only remount of project entries, a project write lands.
  mutated="$base/fm-view-rw.sh"
  mutate "$ROOT/bin/fm-view.sh" "$mutated" '\[ "$mode" = rw \] || mount -o remount,bind,ro -- "$mp"'
  out=$(FM_VIEW_SCRIPT=$mutated view_run "$install" "$proj" 'echo mutated >> src/app.js && echo wrote') \
    || fail "falsification run without the read-only remount failed"
  assert_contains "$out" "wrote" "removing the read-only remount did not make the project writable; the read-only test proves nothing"
  assert_equals 2 "$(wc -l < "$proj/src/app.js" | tr -d ' ')" "the falsification write did not reach the disposable fixture"

  pass "falsification: the shim and the read-only binds are what keep git clean and the project read-only"
}

test_view_keeper_refresh() {
  local base install proj out
  skip_without_view "view keeper refresh" && return 0
  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"

  out=$(view_run "$install" "$proj" '
    [ -e late.txt ] || echo "absent_at_start=yes"
    touch "$FM_LAUNCH_REAL_RW/late.txt.sig"
    for i in $(seq 1 50); do [ -e late.txt ] && break; sleep 0.2; done
    [ -e late.txt ] && echo "late=$(cat late.txt)"
  ' &
  for i in $(seq 1 50); do [ -e "$proj/late.txt.sig" ] && break; sleep 0.2; done
  printf 'created outside\n' > "$proj/late.txt"
  wait) || fail "keeper run failed"
  assert_contains "$out" "absent_at_start=yes" "the late entry existed before it was created"
  assert_contains "$out" "late=created outside" "the keeper did not present an entry created outside the session"
  rm -f "$proj/late.txt" "$proj/late.txt.sig"

  pass "keeper: a top-level entry created outside the session appears inside it"
}

# --- worker placement ---------------------------------------------------------

test_worker_placement_guard() {
  local base install proj out fakebin
  # Outside a view the guard is inert.
  out=$(env -u FM_VIEW bash -c '. "$1"; fm_view_refuse_server_start tmux && echo inert; fm_view_pid_inside $$ || echo not-inside' \
    _ "$ROOT/bin/fm-view-lib.sh")
  assert_contains "$out" "inert" "the server-start guard refused outside a view"
  assert_contains "$out" "not-inside" "a process outside a view was reported inside one"
  skip_without_view "worker placement inside a view" && return 0

  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"
  fakebin="$base/fakebin"
  mkdir -p "$fakebin"
  # A tmux with no running server that records any attempt to start one.
  cat > "$fakebin/tmux" <<SH
#!/bin/sh
case "\$1" in
  display-message) exit 1 ;;
  *) echo "\$*" >> "$base/tmux-calls"; exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  sleep 60 &
  local host_pid=$!
  out=$(view_run "$install" "$proj" '
    . "'"$ROOT"'/bin/fm-view-lib.sh"
    sleep 30 & inner=$!
    fm_view_pid_inside "$inner" && echo "inner_inside=yes"
    fm_view_pid_inside "'"$host_pid"'" || echo "host_outside=yes"
    kill "$inner"
    fm_view_refuse_server_start zellij 2>&1 && echo "zellij_allowed" || true
    FM_BACKEND_LIB_DIR="'"$ROOT"'/bin"
    . "'"$ROOT"'/bin/backends/tmux.sh"
    unset TMUX
    PATH="'"$fakebin"':$PATH" fm_backend_tmux_container_ensure 2>&1 && echo "tmux_allowed" || echo "tmux_refused"
  ') || fail "worker placement run failed"
  kill "$host_pid" 2>/dev/null || true
  assert_contains "$out" "inner_inside=yes" "a process started inside the view was not reported inside"
  assert_contains "$out" "host_outside=yes" "a host process was reported inside the view"
  assert_not_contains "$out" "zellij_allowed" "starting a zellij server inside the view was allowed"
  assert_contains "$out" "tmux_refused" "the tmux container started a server inside the view"
  assert_contains "$out" "would show workers the view" "the refusal did not name the consequence"
  assert_absent "$base/tmux-calls" "tmux was asked to start a session inside the view"

  pass "worker placement: servers started inside a view are refused; outside a view the guard is inert"
}

# --- runtime dir cleanup --------------------------------------------------------

test_view_cleanup_on_hangup() {
  local base install proj pid i left
  skip_without_view "view cleanup on hangup" && return 0
  base=$(new_dir)
  install="$base/install"
  make_install "$install"
  proj="$base/demo"
  make_project "$proj"

  # A closed terminal hangs up the whole session's process group at once.
  (cd "$proj" && FM_HOME="$proj/.firstmate" exec setsid "$ROOT/bin/fm-view.sh" run \
    --install "$install" --launch "$proj" -- bash -c 'touch "$FM_LAUNCH_REAL_RW/.firstmate/started"; sleep 60') &
  pid=$!
  for i in $(seq 1 50); do [ -e "$proj/.firstmate/started" ] && break; sleep 0.2; done
  [ -e "$proj/.firstmate/started" ] || fail "the view session did not start"
  kill -HUP -- "-$pid"
  wait "$pid" 2>/dev/null || true
  left=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'firstmate-view.*')
  [ -z "$left" ] || fail "a hung-up session left its runtime dir behind: $left"
  rm -f "$proj/.firstmate/started"

  pass "cleanup: a hung-up session removes its runtime dir"
}

test_mode_fallback_and_refusal
test_mode_project_default
test_view_layout_and_read_only
test_view_git_shim
test_view_falsification
test_view_keeper_refresh
test_worker_placement_guard
test_view_cleanup_on_hangup

printf 'all view tests passed\n'
