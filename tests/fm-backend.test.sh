#!/usr/bin/env bash
# tests/fm-backend.test.sh - P1 runtime-backend extraction conformance
# (data/fm-backend-design-d7/report.md, herdr-addendum.md "events as the core
# abstraction"). bin/fm-backend.sh and bin/backends/tmux.sh move the tmux
# command sequences that fm-send.sh, fm-peek.sh, fm-spawn.sh, and
# fm-teardown.sh used to run inline into named adapter functions. This suite:
#
#   1. Unit-tests bin/fm-backend.sh's selection, meta, and dispatch helpers.
#   2. Runs the PRE-REFACTOR versions of fm-send.sh, fm-peek.sh, fm-spawn.sh,
#      and fm-teardown.sh (checked out from the merge-base with `main`, the
#      commit this branch started from) against the SAME fake tmux/treehouse
#      binaries and fixtures as the REFACTORED versions in this checkout, then
#      diffs the two command logs byte-for-byte - the report's P1 checklist
#      item "run current main scripts and refactored scripts against the same
#      fake tools and compare command logs".
#   3. Asserts the `--backend`/`FM_BACKEND` selection refuses unknown backends
#      and the blocked `codex-app` backend loudly.
#
# fm-watch.sh's signal/stale/check/heartbeat wake-string contract is already
# exercised end-to-end against this refactor by tests/fm-watch-triage.test.sh
# and tests/wake-helpers.sh (same fake-tmux convention, run against the
# now-refactored bin/fm-watch.sh); this suite adds one direct old-vs-new
# diff for the stale-pane path specifically, since that is the one wake path
# that now calls through fm_backend_capture instead of tmux directly.
# The real tmux smoke test (create session, send text + Enter, capture, list,
# kill) lives in tests/fm-backend-tmux-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)

# fm_backend_detect's cmux fallback (bundle id + process ancestry,
# docs/cmux-backend.md "Runtime auto-detection") consults uname, lsappinfo,
# and ps. FAKE_NONDARWIN_BIN pins uname to Linux so the whole fallback is
# deterministically inert for every assertion that expects NO detection,
# regardless of the ambient runtime this suite itself executes inside (a real
# cmux tab would otherwise leak a bundle-id or ancestry match into results).
FAKE_NONDARWIN_BIN="$TMP_ROOT/fake-nondarwin-bin"
mkdir -p "$FAKE_NONDARWIN_BIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKE_NONDARWIN_BIN/uname"
chmod +x "$FAKE_NONDARWIN_BIN/uname"

# make_cmux_fallback_fakebin: PATH fakes for the DETECTING side of the cmux
# fallback - uname pinned to Darwin, lsappinfo echoing $FM_FAKE_LSAPPINFO_OUT
# (empty output mirrors the real lsappinfo's app-not-running behavior: prints
# nothing, exit 0), and a ps answering `-o ppid=/-o comm= -p <pid>` from the
# tab-separated "pid ppid comm" table file named by $FM_FAKE_PS_TABLE.
make_cmux_fallback_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin-cmux-fallback"
  mkdir -p "$fb"
  printf '#!/bin/sh\necho Darwin\n' > "$fb/uname"
  cat > "$fb/lsappinfo" <<'SH'
#!/bin/sh
[ -n "${FM_FAKE_LSAPPINFO_OUT:-}" ] && printf '%s\n' "$FM_FAKE_LSAPPINFO_OUT"
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/bin/sh
# supports exactly: ps -o ppid= -p <pid> / ps -o comm= -p <pid>
field=${2:-} pid=${4:-}
while IFS="	" read -r tpid tppid tcomm; do
  if [ "$tpid" = "$pid" ]; then
    case "$field" in
      ppid=) printf '%s\n' "$tppid" ;;
      comm=) printf '%s\n' "$tcomm" ;;
    esac
    exit 0
  fi
done < "${FM_FAKE_PS_TABLE:?}"
exit 1
SH
  chmod +x "$fb/uname" "$fb/lsappinfo" "$fb/ps"
  printf '%s\n' "$fb"
}

# The commit this branch started from - the P1 "current main" baseline.
resolve_base_ref() {
  local ref base
  for ref in main refs/heads/main origin/main refs/remotes/origin/main origin/HEAD refs/remotes/origin/HEAD; do
    if git -C "$ROOT" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
      base=$(git -C "$ROOT" merge-base HEAD "$ref" 2>/dev/null) || continue
      [ -n "$base" ] || continue
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}
BASE_REF=$(resolve_base_ref) \
  || fail "fm-backend baseline requires local main or origin/main; fetch the default branch before running this test"

# --- shared: a pre-refactor bin/ shim --------------------------------------
#
# build_old_bin echoes a directory whose bin/ subdir holds the PRE-REFACTOR
# fm-send.sh, fm-peek.sh, fm-watch.sh, fm-spawn.sh, fm-teardown.sh, and any
# changed source-library dependency (all extracted from BASE_REF), plus copies
# of every OTHER sibling script those five entrypoints source, so those copies are exactly
# what BASE_REF would have used too. Copies keep BASH_SOURCE-based sibling
# resolution inside the synthetic tree on both macOS and Linux; symlinks make
# that resolution shell/platform-dependent. FM_ROOT_OVERRIDE pointed at this dir's
# root makes "$FM_ROOT/bin/fm-project-mode.sh" (etc.) resolve correctly.
# fm-backend.sh (and its bin/backends/ adapters) is the dispatcher every one
# of the five REFACTORED scripts sources; it must be a real, reachable file in
# the old bin/ too or `. "$SCRIPT_DIR/fm-backend.sh"` aborts under set -eu -
# hence it is a copied sibling, not an extracted-from-BASE_REF file: for a
# tmux-only conformance run the tmux adapter's behavior is what is under test,
# and that is unchanged by any later (e.g. non-tmux backend) addition to
# fm-backend.sh's own dispatch surface.
OLD_BIN_UNCHANGED_SIBLINGS="fm-gate-refuse-lib.sh fm-guard.sh fm-lock-lib.sh fm-tasks-axi-lib.sh fm-pr-lib.sh fm-tangle-lib.sh fm-tmux-lib.sh fm-composer-lib.sh fm-wake-lib.sh fm-classify-lib.sh fm-supervision-lib.sh fm-ff-lib.sh fm-config-inherit-lib.sh fm-project-mode.sh fm-harness.sh fm-crew-state.sh fm-decision-hold.sh fm-backend.sh"
# A pull-request merge may add a new main-only dependency that the branch's older baseline does not have yet.
OLD_BIN_OPTIONAL_SIBLINGS="fm-pending-reply-lib.sh"
OLD_BIN_REFACTORED="fm-send.sh fm-peek.sh fm-watch.sh fm-spawn.sh fm-teardown.sh fm-marker-lib.sh"

build_old_bin() {  # <name> -> echoes root dir (root/bin/<script> is the entry point)
  local name=$1 root bin f
  root="$TMP_ROOT/$name"
  bin="$root/bin"
  mkdir -p "$bin"
  for f in $OLD_BIN_UNCHANGED_SIBLINGS; do
    cp "$ROOT/bin/$f" "$bin/$f"
  done
  for f in $OLD_BIN_OPTIONAL_SIBLINGS; do
    [ -f "$ROOT/bin/$f" ] || continue
    cp "$ROOT/bin/$f" "$bin/$f"
  done
  cp -R "$ROOT/bin/backends" "$bin/backends"
  for f in $OLD_BIN_REFACTORED; do
    git -C "$ROOT" show "$BASE_REF:bin/$f" > "$bin/$f"
    chmod +x "$bin/$f"
  done
  printf '%s\n' "$root"
}

# --- fm-backend.sh unit tests ------------------------------------------------

test_backend_name_precedence() {
  local dir cfg
  dir="$TMP_ROOT/name-precedence"; cfg="$dir/config"
  mkdir -p "$cfg"

  # TMUX/HERDR_ENV/CMUX_WORKSPACE_ID explicitly unset in a subshell so this
  # stays deterministic regardless of the runtime this test suite itself
  # happens to execute inside (e.g. a real tmux pane, which is the normal case
  # for a captain's session).
  # fm_backend_name reads FM_BACKEND_CONFIG_DIR (bound once, at fm-backend.sh
  # source time, from FM_CONFIG_OVERRIDE); a later FM_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # FM_BACKEND_CONFIG_DIR directly.
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "fm_backend_name should default to tmux with no env/config/detection markers"

  printf 'tmux\n' > "$cfg/backend"
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "fm_backend_name should read config/backend"

  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "FM_BACKEND env should win over config/backend"

  pass "fm_backend_name: FM_BACKEND env > config/backend > default tmux"
}

# fm_backend_detect: environment-marker runtime auto-detection (mirrors
# fm-harness.sh's detect_own layer). Every case explicitly controls TMUX,
# HERDR_ENV, and CMUX_WORKSPACE_ID - and, where no detection is expected, the
# cmux fallback inputs (__CFBundleIdentifier plus a non-Darwin uname fake) -
# so results never depend on the ambient shell this suite runs inside (a real
# tmux pane or cmux tab, both normal cases for a captain's session).
test_backend_detect_precedence() {
  local out

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" fm_backend_detect); then
    fail "fm_backend_detect should return 1 (undetected) with no markers set, got '$out'"
  fi

  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 fm_backend_detect) \
    || fail "fm_backend_detect should succeed when HERDR_ENV=1"
  [ "$out" = herdr ] || fail "fm_backend_detect should report herdr for HERDR_ENV=1 alone, got '$out'"

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when \$TMUX is set"
  [ "$out" = tmux ] || fail "fm_backend_detect should report tmux for \$TMUX alone, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when CMUX_WORKSPACE_ID is set"
  [ "$out" = cmux ] || fail "fm_backend_detect should report cmux for CMUX_WORKSPACE_ID alone, got '$out'"

  # Nesting: tmux started inside a herdr pane carries BOTH markers. Innermost
  # (tmux) must win, since that is the surface firstmate is actually running on.
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first (tmux over herdr), got '$out'"

  # Nesting: tmux started inside a cmux-provided shell carries BOTH markers.
  # cmux is a terminal application, not a nestable multiplexer, so the
  # innermost multiplexer (tmux) must still win.
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with tmux and cmux markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first (tmux over cmux), got '$out'"

  # Nesting: herdr started inside a cmux-provided shell carries BOTH markers.
  # Same reasoning: herdr (the innermost multiplexer) must win over cmux.
  out=$(unset TMUX; HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with herdr and cmux markers present"
  [ "$out" = herdr ] || fail "fm_backend_detect should resolve nesting innermost-first (herdr over cmux), got '$out'"

  # Pathological: all three markers present. tmux still wins (innermost of all).
  out=$(TMUX='fake,1,0' HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with all three markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first with all three markers (tmux wins), got '$out'"

  pass "fm_backend_detect: no markers -> undetected, HERDR_ENV=1 -> herdr, \$TMUX -> tmux, CMUX_WORKSPACE_ID -> cmux, nested combinations resolve innermost-first"
}

# fm_backend_detect's cmux FALLBACK signals (docs/cmux-backend.md "Runtime
# auto-detection"): cmux's bundled claude wrapper strips every CMUX_* env var
# on its passthrough path, so a claude-under-cmux firstmate has no
# CMUX_WORKSPACE_ID; detection then falls back to __CFBundleIdentifier and,
# after that, a process-ancestry walk - macOS-only, and never outranking the
# $TMUX/HERDR_ENV innermost-first checks.
test_backend_detect_cmux_fallback_bundle_id() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-bundle"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should fall back to the cmux bundle id when CMUX_WORKSPACE_ID is absent"
  [ "$out" = cmux ] || fail "bundle-id fallback should report cmux, got '$out'"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID
    PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECT_SIGNAL" = bundle-id ] || exit 2
  ) || fail "bundle-id fallback should set FM_BACKEND_DETECT_SIGNAL=bundle-id (subshell exit $?)"

  # A foreign bundle id (an ordinary terminal app) must not match.
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$dir/no-table" __CFBundleIdentifier='com.apple.Terminal' fm_backend_detect); then
    fail "a non-cmux __CFBundleIdentifier should not detect cmux, got '$out'"
  fi

  pass "fm_backend_detect: falls back to __CFBundleIdentifier=com.cmuxterm.app when CMUX_WORKSPACE_ID is absent (signal bundle-id; foreign bundle ids rejected)"
}

test_backend_detect_cmux_fallback_requires_darwin() {
  local out
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$FAKE_NONDARWIN_BIN:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect); then
    fail "the cmux fallback must be macOS-only (cmux itself is), got '$out' on a non-Darwin uname"
  fi
  pass "fm_backend_detect: the cmux fallback signals are macOS-only (inert on a non-Darwin uname)"
}

# The false positive the innermost-first ordering must keep absorbing: a tmux
# server started from a cmux tab inherits __CFBundleIdentifier=com.cmuxterm.app
# into every pane (verified live, docs/cmux-backend.md), so the bundle-id
# fallback WILL match inside such panes - $TMUX winning first is what keeps
# the result correct. Same for a herdr pane whose server was started from a
# cmux tab.
test_backend_detect_cmux_fallback_tmux_nested_false_positive() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-nested"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" TMUX='fake,1,0' __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should still succeed with \$TMUX plus an inherited cmux bundle id"
  [ "$out" = tmux ] || fail "\$TMUX must win over an inherited cmux bundle id (tmux-inside-cmux pane), got '$out'"

  out=$(unset TMUX CMUX_WORKSPACE_ID; PATH="$fb:$PATH" HERDR_ENV=1 __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should still succeed with HERDR_ENV=1 plus an inherited cmux bundle id"
  [ "$out" = herdr ] || fail "HERDR_ENV=1 must win over an inherited cmux bundle id (herdr-inside-cmux pane), got '$out'"

  pass "fm_backend_detect: an inherited cmux bundle id never outranks \$TMUX or HERDR_ENV (tmux/herdr-inside-cmux false positive absorbed)"
}

test_backend_detect_cmux_fallback_ancestry_pid_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-pid"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # $$ is this test script's own pid - the walk starts there. The cmux app
  # pid (66666) is matched via the lsappinfo bundle-id resolution, with a
  # deliberately non-standard install path so only the pid can match.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/Users/x/Custom.app/Contents/MacOS/custom\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier
    PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" FM_FAKE_LSAPPINFO_OUT='"pid"=66666' fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$FM_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via the lsappinfo-resolved app pid (subshell exit $?)"

  pass "fm_backend_detect: ancestry fallback matches the lsappinfo-resolved (bundle-id) cmux app pid in the parent chain"
}

test_backend_detect_cmux_fallback_ancestry_comm_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-comm"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # lsappinfo resolves nothing (empty output, like the real one for a
  # non-running or non-GUI-visible app); the bundle-shaped comm path is the
  # remaining match, at a non-/Applications install location on purpose.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/Users/x/Applications/cmux.app/Contents/MacOS/cmux\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier FM_FAKE_LSAPPINFO_OUT
    PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$FM_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via a bundle-shaped comm path when lsappinfo resolves nothing (subshell exit $?)"

  pass "fm_backend_detect: ancestry fallback matches a bundle-shaped cmux comm path at any install location when lsappinfo cannot resolve a pid"
}

# From inside tmux, ancestry can never reach cmux: the tmux server reparents
# to launchd (verified live - the reference machine's own tmux server, started
# from a cmux tab, has ppid 1), so the walk stops at ppid 1 undetected. This
# pins the walk's launchd stop as the structural guarantee behind that.
test_backend_detect_cmux_fallback_ancestry_stops_at_launchd() {
  local dir fb table out
  dir="$TMP_ROOT/detect-ancestry-stop"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  printf '%s\t77777\t/bin/zsh\n77777\t1\ttmux\n' "$$" > "$table"

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier FM_FAKE_LSAPPINFO_OUT; PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" fm_backend_detect); then
    fail "ancestry fallback should stop undetected at a launchd-reparented chain, got '$out'"
  fi
  pass "fm_backend_detect: ancestry fallback stops undetected at launchd (a reparented tmux server never reaches cmux)"
}

# The auto-detect NOTICE must say when cmux was selected via a fallback
# signal, so a captain can tell a wrapper-stripped claude-under-cmux spawn
# apart from the primary-marker case.
test_backend_name_cmux_fallback_notice() {
  local dir cfg fb out errfile
  dir="$TMP_ROOT/name-fallback-notice"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  fb=$(make_cmux_fallback_fakebin "$dir")
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux via the bundle-id fallback, got '$out'"
  assert_contains "$(cat "$errfile")" "FALLBACK signal __CFBundleIdentifier" \
    "the fallback-detected cmux notice did not name the bundle-id fallback signal"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "the fallback-detected cmux notice lost the experimental warning"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "the fallback-detected cmux notice lost the opt-out"

  # The primary-marker notice is unchanged: it names CMUX_WORKSPACE_ID and
  # carries no FALLBACK wording.
  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "(CMUX_WORKSPACE_ID)" \
    "the primary-marker cmux notice no longer names CMUX_WORKSPACE_ID"
  case "$(cat "$errfile")" in
    *FALLBACK*) fail "the primary-marker cmux notice must not carry FALLBACK wording" ;;
  esac

  pass "fm_backend_name: a fallback-detected cmux prints a NOTICE naming the fallback signal; the primary-marker notice is unchanged"
}

# fm_backend_name's auto-detect step: fires only when FM_BACKEND/config/backend
# are both absent, selects between the three markers exactly as
# fm_backend_detect does, and is loud only when it selects herdr or cmux -
# never when it selects tmux (today's default-path behavior must stay
# byte-for-byte silent).
test_backend_name_autodetect_notice() {
  local dir cfg out errfile

  dir="$TMP_ROOT/name-autodetect"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "fm_backend_name should default to tmux with no detection markers, got '$out'"
  [ -s "$errfile" ] && fail "fm_backend_name must stay silent with no detection markers"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = herdr ] || fail "fm_backend_name should auto-detect herdr from HERDR_ENV=1, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL herdr backend" \
    "fm_backend_name did not print a loud notice when auto-detecting herdr"
  assert_contains "$(cat "$errfile")" "config/backend" \
    "fm_backend_name's auto-detect notice did not name the opt-out"

  : > "$errfile"
  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "fm_backend_name should auto-detect tmux from \$TMUX, got '$out'"
  [ -s "$errfile" ] && fail "auto-detecting tmux must stay silent (today's unchanged default-path behavior)"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "fm_backend_name did not print a loud notice when auto-detecting cmux"
  assert_contains "$(cat "$errfile")" "config/backend" \
    "fm_backend_name's cmux auto-detect notice did not name the opt-out"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "fm_backend_name's cmux auto-detect notice did not name the --backend tmux opt-out"

  : > "$errfile"
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-herdr should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-herdr auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-cmux should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-cmux auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  pass "fm_backend_name: auto-detect selects herdr or cmux (loud notice) or tmux (silent, including nested tmux-in-herdr/tmux-in-cmux)"
}

# Explicit configuration (FM_BACKEND env or config/backend) always wins over
# runtime auto-detection, even when a detection marker points the other way.
test_backend_name_explicit_beats_detection() {
  local dir cfg out

  dir="$TMP_ROOT/name-explicit-beats-detect"
  cfg="$dir/config-tmux"; mkdir -p "$cfg"; printf 'tmux\n' > "$cfg/backend"
  mkdir -p "$dir/config-empty"

  # fm_backend_name reads FM_BACKEND_CONFIG_DIR (bound once, at fm-backend.sh
  # source time, from FM_CONFIG_OVERRIDE); a later FM_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # FM_BACKEND_CONFIG_DIR directly to control which config dir is checked.
  out=$(unset TMUX; HERDR_ENV=1 FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$dir/config-empty" fm_backend_name)
  [ "$out" = tmux ] || fail "FM_BACKEND=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  out=$(unset TMUX; HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  # The same opt-out must work for an ambient cmux auto-detect marker: a
  # captain who is running firstmate inside a cmux terminal but explicitly
  # wants tmux is never overridden by CMUX_WORKSPACE_ID.
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$dir/config-empty" fm_backend_name)
  [ "$out" = tmux ] || fail "FM_BACKEND=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  pass "fm_backend_name: an explicit FM_BACKEND or config/backend setting always wins over runtime auto-detection, including an ambient cmux marker"
}

test_backend_validate_refuses_unknown() {
  fm_backend_validate tmux 2>/dev/null || fail "fm_backend_validate should accept tmux"
  fm_backend_validate orca 2>/dev/null || fail "fm_backend_validate should accept orca"
  local out
  # bogus names a backend with no adapter at all; tmux, herdr, zellij, orca,
  # and cmux are all known adapters and spawn-supported.
  out=$(fm_backend_validate bogus 2>&1) && fail "fm_backend_validate should refuse bogus (no such adapter)"
  assert_contains "$out" "unknown backend 'bogus'" "fm_backend_validate did not name the rejected backend"
  out=$(fm_backend_validate codex-app 2>&1) && fail "fm_backend_validate should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "fm_backend_validate accepted codex-app"
  out=$(fm_backend_validate "tmux herdr" 2>&1) && fail "fm_backend_validate should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "fm_backend_validate accepted a multi-token backend name"
  pass "fm_backend_validate: implemented adapters accepted, unknown and blocked codex-app backends refused loudly"
}

test_backend_source_shell_portable() {
  local out status
  # zsh does not word-split unquoted expansions; sourcing fm-backend.sh from
  # an interactive zsh session must still recognize known backend names.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && whence -w fm_backend_herdr_capture >/dev/null" 2>/dev/null \
      || fail "zsh: fm_backend_source herdr should load the adapter when sourced"
    out=$(zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
      && fail "zsh: fm_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" \
      "zsh: fm_backend_source did not reject bogus with the expected error"
    pass "zsh: fm_backend_source recognizes known backends and rejects unknown ones"
  else
    pass "zsh: shell-portable backend matching skipped (zsh not found)"
  fi

  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && declare -F fm_backend_herdr_capture >/dev/null" 2>/dev/null \
    || fail "bash: fm_backend_source herdr should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
    && fail "bash: fm_backend_source bogus should fail"
  assert_contains "$out" "unknown backend 'bogus'" \
    "bash: fm_backend_source did not reject bogus with the expected error"
  pass "bash: fm_backend_source recognizes known backends and rejects unknown ones"
}

test_backend_validate_spawn_accepts_orca() {
  local out
  fm_backend_validate_spawn tmux 2>/dev/null || fail "fm_backend_validate_spawn should accept tmux"
  fm_backend_validate_spawn herdr 2>/dev/null || fail "fm_backend_validate_spawn should accept herdr"
  fm_backend_validate_spawn zellij 2>/dev/null || fail "fm_backend_validate_spawn should accept zellij"
  fm_backend_validate_spawn orca 2>/dev/null || fail "fm_backend_validate_spawn should accept orca"
  fm_backend_validate_spawn cmux 2>/dev/null || fail "fm_backend_validate_spawn should accept cmux"
  out=$(fm_backend_validate_spawn bogus 2>&1) && fail "fm_backend_validate_spawn should still refuse unknown backends"
  assert_contains "$out" "unknown backend 'bogus'" "fm_backend_validate_spawn did not preserve unknown-backend validation"
  out=$(fm_backend_validate_spawn codex-app 2>&1) && fail "fm_backend_validate_spawn should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "fm_backend_validate_spawn accepted codex-app"
  out=$(fm_backend_validate_spawn "tmux herdr" 2>&1) && fail "fm_backend_validate_spawn should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "fm_backend_validate_spawn accepted a multi-token backend name"
  pass "fm_backend_validate_spawn: all implemented lifecycle backends are spawn-supported"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta
  fm_write_meta "$meta" "window=firstmate:fm-x1" "harness=claude"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:fm-x1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should default absent backend= to tmux"

  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should read an explicit backend=tmux"

  pass "fm_meta_get / fm_backend_of_meta: read key=value, default backend to tmux"
}

test_resolve_selector_three_forms() {
  local state=$TMP_ROOT/resolve-state fakebin out
  mkdir -p "$state"
  fm_write_meta "$state/task1.meta" "window=firstmate:fm-task1"
  fm_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"

  [ "$(fm_backend_resolve_selector 'sess:win' "$state")" = "sess:win" ] \
    || fail "explicit session:window should be used as-is"

  [ "$(fm_backend_resolve_selector 'dotfiles-d6' "$state")" = "default:wA:p2" ] \
    || fail "bare non-fm task id should resolve through exact metadata"
  [ "$(fm_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id should use its recorded backend"
  [ "$(fm_backend_expected_label_of_selector 'dotfiles-d6' "$state")" = "fm-dotfiles-d6" ] \
    || fail "bare non-fm task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-turnend-all-harnesses-v9' "$state")" = "default:wB:p3" ] \
    || fail "exact fm-* task id should resolve through its exact metadata"
  [ "$(fm_backend_of_selector 'fm-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact fm-* task id should use exact metadata without stripping fm-"
  [ "$(fm_backend_expected_label_of_selector 'fm-turnend-all-harnesses-v9' "$state")" = "fm-fm-turnend-all-harnesses-v9" ] \
    || fail "exact fm-* task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-task1' "$state")" = "firstmate:fm-task1" ] \
    || fail "legacy fm-<id> label should resolve through <id>.meta's window="
  [ "$(fm_backend_expected_label_of_selector 'fm-task1' "$state")" = "fm-task1" ] \
    || fail "legacy fm-<id> label should preserve its backend label"

  out=$(fm_backend_resolve_selector 'fm-missing' "$state" 2>&1) && fail "fm-<id> with no meta should fail"
  assert_contains "$out" "no metadata for fm-missing" "missing-meta error text changed"

  fakebin="$TMP_ROOT/resolve-fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'firstmate:adhoc\nother:otherwin\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" fm_backend_resolve_selector 'fm-adhoc' "$state" 2>&1) || true
  # fm-adhoc carries no meta file, so it is NOT the bare-name fallback path - it
  # is the fm-* meta-miss error path after exact-id and legacy-label metadata
  # lookup both miss.
  # Only a NON fm-* bare name falls through to the live-window search.
  assert_contains "$out" "no metadata for fm-adhoc" "an fm-* selector must always require meta, not silently fall back to a live search"

  out=$(PATH="$fakebin:$PATH" fm_backend_resolve_selector 'adhoc' "$state")
  [ "$out" = "firstmate:adhoc" ] || fail "an ad hoc bare name should resolve via the tmux live-window fallback, got '$out'"

  pass "fm_backend_resolve_selector: session:window literal, exact task id first, legacy fm-<id> label fallback, ad hoc bare name via tmux list-windows"
}

test_backend_of_selector_matches_explicit_target_meta() {
  local state=$TMP_ROOT/backend-selector-state
  mkdir -p "$state"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  fm_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"
  fm_write_meta "$state/tmux-task.meta" "window=firstmate:fm-tmux-task"
  fm_write_meta "$state/custom-window-task.meta" "window=custom-window"
  fm_write_meta "$state/orca-task.meta" "window=fm-orca-task" "terminal=term-orca-task" "backend=orca"

  [ "$(fm_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id selector should use its recorded backend"
  [ "$(fm_backend_of_selector 'fm-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact fm-* task id selector should use exact metadata before legacy stripping"
  [ "$(fm_backend_of_selector 'fm-herdr-task' 'default:w1:p2' "$state")" = herdr ] \
    || fail "legacy fm-<id> selector should use its recorded backend"
  [ "$(fm_backend_resolve_selector 'fm-orca-task' "$state")" = term-orca-task ] \
    || fail "Orca fm-<id> selector should resolve to terminal=, not window="
  [ "$(fm_backend_resolve_selector 'term-orca-task' "$state")" = term-orca-task ] \
    || fail "raw Orca terminal selector should resolve through metadata"
  [ "$(fm_backend_resolve_selector 'custom-window' "$state")" = custom-window ] \
    || fail "raw window selector matching metadata should not require tmux fallback"
  [ "$(fm_backend_of_selector 'term-orca-task' 'term-orca-task' "$state")" = orca ] \
    || fail "matching an explicit Orca terminal handle should inherit metadata backend"
  [ "$(fm_backend_of_selector 'default:w1:p2' 'default:w1:p2' "$state")" = herdr ] \
    || fail "explicit backend target matching metadata should use that task's backend"
  [ "$(fm_backend_of_selector 'firstmate:fm-tmux-task' 'firstmate:fm-tmux-task' "$state")" = tmux ] \
    || fail "explicit tmux-shaped target with absent backend= should default to tmux"
  [ "$(fm_backend_of_selector 'manual:outside' 'manual:outside' "$state")" = tmux ] \
    || fail "explicit target with no matching metadata should keep the tmux compatibility default"

  pass "fm_backend_of_selector: exact task ids, legacy fm-<id> labels, and matching explicit targets inherit metadata backend"
}

# --- old vs new: fm-send.sh --------------------------------------------------

make_send_fakebin() {  # <dir> -> echoes fakebin dir; logs every tmux call to $FM_TMUX_LOG
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send_case() {  # <bin-root> <fakebin> <log> <home> -- <send args...>
  local bin=$1 fb=$2 log=$3 home=$4; shift 4
  [ "${1:-}" = -- ] && shift
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$bin" FM_HOME="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$bin/bin/fm-send.sh" "$@" >/dev/null 2>&1
}

strip_send_preflight() {  # <log>
  local preflight
  preflight=$'tmux\x1fdisplay-message\x1f-p\x1f-t\x1fsess:win\x1f#{pane_id}'
  awk -v preflight="$preflight" '$0 != preflight { print }' "$1"
}

test_send_conformance_old_vs_new() {
  local old_bin fb log_old log_new home rc_old rc_new filtered_old filtered_new
  old_bin=$(build_old_bin send-old)
  fb=$(make_send_fakebin "$TMP_ROOT/send-fake")
  home="$TMP_ROOT/send-home"; mkdir -p "$home/state"
  log_old="$TMP_ROOT/send-old.log"; log_new="$TMP_ROOT/send-new.log"
  filtered_old="$TMP_ROOT/send-old.filtered.log"; filtered_new="$TMP_ROOT/send-new.filtered.log"

  # Case 1: --key path.
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" --key Escape
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" --key Escape
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send --key: old vs new exit code"
  assert_contains "$(cat "$log_new")" $'\x1f''display-message'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''#{pane_id}' \
    "fm-send --key did not verify the explicit tmux target before sending"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-key.txt" 2>&1 \
    || fail "fm-send --key: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-key.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''Escape' "fm-send --key did not send the named key"

  # Case 2: plain text (0.3s settle, no popup).
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" hello captain
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" hello captain
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send plain text: old vs new exit code"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-plain.txt" 2>&1 \
    || fail "fm-send plain text: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-plain.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''send-keys'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-l'$'\x1f''hello captain' \
    "fm-send did not send the literal text with send-keys -l"
  assert_contains "$(cat "$log_new")" $'\x1f''Enter' "fm-send did not submit with Enter"

  # Case 3: a slash command still opens the popup-settle path (verified
  # elsewhere in tests/fm-send-popup-settle.test.sh) and still ends in the
  # same tmux command shape: send-keys -l, then a retried Enter.
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" /some-skill
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" /some-skill
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send /skill: old vs new exit code"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-slash.txt" 2>&1 \
    || fail "fm-send /skill: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-slash.txt")"

  pass "fm-send.sh: explicit tmux targets are verified, while --key/plain/slash send command shape stays old-compatible"
}

# --- old vs new: fm-peek.sh --------------------------------------------------

make_peek_fakebin() {  # <dir> <capture-output> -> echoes fakebin dir
  local dir=$1 payload=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '%s' "$payload" > "$dir/capture.out"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  capture-pane) cat "$dir/capture.out" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_peek_conformance_old_vs_new() {
  local old_bin fb log_old log_new home out_old out_new payload neutral_root
  payload=$'line one\nline two\ncaptain on deck'
  old_bin=$(build_old_bin peek-old)
  fb=$(make_peek_fakebin "$TMP_ROOT/peek-fake" "$payload")
  home="$TMP_ROOT/peek-home"; mkdir -p "$home/state"
  log_old="$TMP_ROOT/peek-old.log"; log_new="$TMP_ROOT/peek-new.log"
  # A fresh non-git dir keeps fm-guard.sh's worktree-tangle check inert (it warns
  # to stderr, discarded below) - neither run needs FM_ROOT for anything beyond
  # that guard, since STATE/HOME are already overridden directly.
  neutral_root="$TMP_ROOT/peek-neutral-root"; mkdir -p "$neutral_root"

  : > "$log_old"
  out_old=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral_root" FM_HOME="$home" FM_TMUX_LOG="$log_old" \
    "$old_bin/bin/fm-peek.sh" "sess:win" 25 2>/dev/null)
  : > "$log_new"
  out_new=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral_root" FM_HOME="$home" FM_TMUX_LOG="$log_new" \
    "$ROOT/bin/fm-peek.sh" "sess:win" 25 2>/dev/null)

  [ "$out_old" = "$out_new" ] || fail "fm-peek output differs old vs new"$'\n'"--- old ---"$'\n'"$out_old"$'\n'"--- new ---"$'\n'"$out_new"
  [ "$out_new" = "$payload" ] || fail "fm-peek did not pass through the fake capture-pane output exactly"
  diff -u "$log_old" "$log_new" > "$TMP_ROOT/peek-diff.txt" 2>&1 \
    || fail "fm-peek: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/peek-diff.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''capture-pane'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-S'$'\x1f''-25' \
    "fm-peek did not call capture-pane -p -t <target> -S -<lines> exactly"

  pass "fm-peek.sh: capture-pane invocation and output are byte-identical old vs new"
}

# --- old vs new: fm-spawn.sh --------------------------------------------------

make_spawn_fakebin() {  # <dir> <fake-worktree-path> -> echoes fakebin dir
  local dir=$1 wt=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*) printf '%s\\n' "$wt"; exit 0 ;; esac; done
    printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

run_spawn_case() {  # <bin-root> <fakebin> <log> <state> <data> <config> <proj> -- <spawn args...>
  local bin=$1 fb=$2 log=$3 state=$4 data=$5 config=$6 proj=$7; shift 7
  [ "${1:-}" = -- ] && shift
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$bin" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_TMUX_LOG="$log" \
    "$bin/bin/fm-spawn.sh" "$@"
}

# NOTE: the old-vs-new spawn command-log conformance test that used to live here
# was retired. It asserted the P1 backend refactor was a byte-for-byte pure
# extraction of the spawn window-creation/targeting sequence, but that sequence
# is now DELIBERATELY changed: fm-spawn drives the tmux backend to capture a
# stable window id, pin the window name (automatic-rename/allow-rename off), and
# target that id for the rename-critical spawn steps (robustness under a
# captain's non-default tmux config). A byte-identical old-vs-new diff can no
# longer hold there by design. That intended sequence is now authoritatively and
# comprehensively verified - via a recording fake-tmux - by
# tests/fm-tangle-guard.test.sh ("fm-spawn: appends windows by session-colon,
# pins the name, and targets the window id"), and the real tmux create/kill path
# by tests/fm-backend-tmux-smoke.test.sh. The send/peek/teardown conformance
# tests below remain pure extractions and stay. (make_spawn_fakebin and
# run_spawn_case are retained: test_spawn_default_backend_writes_no_meta_field
# uses make_spawn_fakebin, and #294's run_spawn_symlink_case uses run_spawn_case.)

# --- symlinked project prefix must not false-refuse the isolation guard -----
#
# docs/herdr-backend.md "Known gaps": a real backend's pane_current_path read
# (tmux, herdr) reports the OS-level PHYSICALLY-resolved cwd. When the project
# itself lives under a symlinked prefix (e.g. macOS's /tmp -> /private/tmp),
# fm-spawn.sh's PROJ_ABS - a logical `cd && pwd` - differs string-for-string
# from that physical read even before treehouse moves the pane at all, so the
# worktree-discovery poll used to mistake an UNMOVED pane for one that had
# already left the project, handing validate_spawn_worktree the project's own
# directory as "the worktree" and tripping its false isolation refusal.
# make_spawn_symlink_fakebin's tmux stub returns an unmoved project path on the
# first pane_current_path poll, then the real worktree path from the second poll
# onward, so this test fails loudly if the PROJ_ABS/PROJ_ABS_REAL
# canonicalization in bin/fm-spawn.sh ever regresses.
make_spawn_symlink_fakebin() {  # <dir> <initial-project-path> <worktree-path> -> echoes fakebin dir
  local dir=$1 initial_path=$2 wt=$3 fb="$1/fakebin" counter="$1/poll-count"
  mkdir -p "$fb"
  : > "$counter"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*)
      printf x >> "$counter"
      if [ "\$(wc -c < "$counter")" -le 1 ]; then
        printf '%s\\n' "$initial_path"
      else
        printf '%s\\n' "$wt"
      fi
      exit 0
    ;; esac; done
    printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

run_spawn_symlink_case() {  # <label> <physical|logical>
  local label=$1 first_reply=$2 real_root link_root proj wt id fb data state config log out rc proj_phys initial_path
  real_root="$TMP_ROOT/symlink-real-$label"; link_root="$TMP_ROOT/symlink-link-$label"
  mkdir -p "$real_root"
  ln -s "$real_root" "$link_root"
  proj="$link_root/proj"
  wt="$TMP_ROOT/symlink-wt-$label"
  id="spawnsymlink$label"
  fm_git_worktree "$real_root/proj" "$wt" "fm/$id"
  # TMP_ROOT itself can already sit behind an OS-level symlink (e.g. macOS's
  # /var -> /private/var), so resolve the fakebin's "physical" reply with
  # pwd -P rather than string concatenation - it must match exactly what
  # fm-spawn.sh's own PROJ_ABS_REAL computes, including any symlink layers
  # ABOVE this test's own synthetic real_root/link_root pair.
  proj_phys=$(cd "$real_root/proj" && pwd -P)
  case "$first_reply" in
    physical) initial_path=$proj_phys ;;
    logical) initial_path=$proj ;;
    *) fail "unknown symlink first-reply mode: $first_reply" ;;
  esac
  fb=$(make_spawn_symlink_fakebin "$TMP_ROOT/symlink-fake-$label" "$initial_path" "$wt")
  data="$TMP_ROOT/symlink-data-$label"
  mkdir -p "$data/$id"
  printf 'test brief content\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/symlink-state-$label"; config="$TMP_ROOT/symlink-config-$label"
  mkdir -p "$state" "$config"
  log="$TMP_ROOT/symlink-spawn-$label.log"

  out=$(run_spawn_case "$ROOT" "$fb" "$log" "$state" "$data" "$config" "$proj" -- "$id" "$proj" claude 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-spawn.sh should succeed for a project reached through a symlinked prefix when the backend reports $first_reply cwd"$'\n'"$out"
  assert_contains "$out" "worktree=$wt" \
    "fm-spawn.sh did not resolve a symlinked-prefix project to its real worktree when the backend reports $first_reply cwd"

  rm -rf "/tmp/fm-$id"
}

test_spawn_symlinked_project_prefix_avoids_false_refusal() {
  run_spawn_symlink_case physical physical
  run_spawn_symlink_case logical logical
  pass "fm-spawn.sh: a project reached through a symlinked prefix (e.g. macOS /tmp -> /private/tmp) does not trip the isolation guard's false refusal"
}

# --- old vs new: fm-teardown.sh ----------------------------------------------

make_teardown_fakebin() {  # <dir> -> echoes fakebin dir; logs tmux+treehouse calls
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
exit 0
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse"
  printf '%s\n' "$fb"
}

# run_teardown_case <script> <fm-root-override> <fakebin> <log> <state> <data> <config> <id>
# FM_ROOT_OVERRIDE is passed separately from <script> so both the old and new
# runs can point it at the SAME neutral (non-git) shim root - that root's
# bin/fm-guard.sh is a symlink to the real, unchanged script, so the
# worktree-tangle check runs identically (and silently) for both, regardless
# of which fm-teardown.sh (old or new) is actually being invoked.
run_teardown_case() {
  local script=$1 fmroot=$2 fb=$3 log=$4 state=$5 data=$6 config=$7 id=$8
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$fmroot" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_TMUX_LOG="$log" \
    "$script" "$id"
}

test_teardown_conformance_old_vs_new() {
  local old_bin fb proj wt id
  local state_old state_new config_old config_new data log_old log_new out_old out_new rc_old rc_new
  old_bin=$(build_old_bin teardown-old)
  proj="$TMP_ROOT/teardown-project"; wt="$TMP_ROOT/teardown-wt"
  id="teardownconform1"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_teardown_fakebin "$TMP_ROOT/teardown-fake")

  data="$TMP_ROOT/teardown-data"
  mkdir -p "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"

  state_old="$TMP_ROOT/teardown-state-old"; state_new="$TMP_ROOT/teardown-state-new"
  config_old="$TMP_ROOT/teardown-config-old"; config_new="$TMP_ROOT/teardown-config-new"
  mkdir -p "$state_old" "$state_new" "$config_old" "$config_new"

  fm_write_meta "$state_old/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  fm_write_meta "$state_new/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  touch "$state_old/.last-watcher-beat" "$state_new/.last-watcher-beat"

  log_old="$TMP_ROOT/teardown-old.log"; log_new="$TMP_ROOT/teardown-new.log"
  out_old=$(run_teardown_case "$old_bin/bin/fm-teardown.sh" "$old_bin" "$fb" "$log_old" "$state_old" "$data" "$config_old" "$id" 2>&1)
  rc_old=$?
  out_new=$(run_teardown_case "$ROOT/bin/fm-teardown.sh" "$old_bin" "$fb" "$log_new" "$state_new" "$data" "$config_new" "$id" 2>&1)
  rc_new=$?

  expect_code 0 "$rc_old" "old fm-teardown.sh (scout, report present) should succeed"$'\n'"$out_old"
  expect_code 0 "$rc_new" "new fm-teardown.sh (scout, report present) should succeed"$'\n'"$out_new"
  diff -u "$log_old" "$log_new" > "$TMP_ROOT/teardown-diff.txt" 2>&1 \
    || fail "fm-teardown.sh: tmux+treehouse command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/teardown-diff.txt")"
  assert_contains "$(cat "$log_new")" "treehouse"$'\x1f''return'$'\x1f''--force'$'\x1f'"$wt" \
    "teardown did not call treehouse return --force <worktree>"
  assert_contains "$(cat "$log_new")" "tmux"$'\x1f''kill-window'$'\x1f''-t'$'\x1f'"firstmate:fm-$id" \
    "teardown did not call tmux kill-window -t <window>"

  pass "fm-teardown.sh: treehouse return + tmux kill-window command log is byte-identical old vs new for a scout task"
}

# --- backend selection loudly refuses an unknown backend --------------------

test_spawn_refuses_unknown_backend_flag() {
  local out status
  # bogus names a backend with no adapter at all; zellij and orca both
  # graduated to real adapters and have their own spawn tests.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" nope-backend-z1 projects/none claude --backend bogus 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn --backend bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "fm-spawn did not name the rejected backend"
  pass "fm-spawn.sh --backend bogus is refused loudly"
}

test_spawn_refuses_codex_app_backend_flag() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" nope-codex-app-z1 projects/none claude --backend codex-app 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn --backend codex-app should refuse"
  assert_contains "$out" "unknown backend 'codex-app'" "fm-spawn did not preserve the blocked codex-app contract"
  pass "fm-spawn.sh --backend codex-app is refused"
}

test_spawn_refuses_unknown_fm_backend_env() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND=bogus \
    "$ROOT/bin/fm-spawn.sh" nope-backend-z2 projects/none claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "FM_BACKEND=bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "fm-spawn did not name the rejected FM_BACKEND"
  pass "fm-spawn.sh honors FM_BACKEND and refuses an unimplemented value loudly"
}

test_spawn_default_backend_writes_no_meta_field() {
  local proj wt data id state config out
  proj="$TMP_ROOT/nobackend-project"; wt="$TMP_ROOT/nobackend-wt"; data="$TMP_ROOT/nobackend-data"
  id="nobackendz3"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  local fb
  fb=$(make_spawn_fakebin "$TMP_ROOT/nobackend-fake" "$wt")
  mkdir -p "$data/$id"; printf 'brief\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/nobackend-state"; config="$TMP_ROOT/nobackend-config"
  mkdir -p "$state" "$config"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMP_ROOT/nobackend.log" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend tmux 2>&1)
  expect_code 0 $? "explicit --backend tmux should spawn successfully"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "an explicit --backend tmux (the default) must not write backend= to meta (P1 compatibility contract)"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: an explicit --backend tmux resolves silently and writes no backend= (missing means tmux)"
}

test_spawn_explicit_backend_flag_beats_autodetect_herdr_env() {
  local proj wt data id state config out fb
  proj="$TMP_ROOT/explicit-backend-project"; wt="$TMP_ROOT/explicit-backend-wt"; data="$TMP_ROOT/explicit-backend-data"
  id="explicitbackendz4"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/explicit-backend-fake" "$wt")
  mkdir -p "$data/$id"; printf 'brief\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/explicit-backend-state"; config="$TMP_ROOT/explicit-backend-config"
  mkdir -p "$state" "$config"

  # HERDR_ENV=1 is present (as if firstmate itself were running under herdr),
  # but an explicit --backend tmux flag must still win outright.
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HERDR_ENV=1 \
    FM_TMUX_LOG="$TMP_ROOT/explicit-backend.log" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend tmux 2>&1)
  expect_code 0 $? "explicit --backend tmux should spawn successfully even with HERDR_ENV=1 set"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "an explicit --backend tmux must win over an ambient HERDR_ENV=1 auto-detect marker"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: explicit --backend tmux wins over an ambient HERDR_ENV=1 auto-detect marker"
}

test_spawn_autodetect_nesting_resolves_tmux_silently() {
  local proj wt data id state config out fb
  proj="$TMP_ROOT/nest-project"; wt="$TMP_ROOT/nest-wt"; data="$TMP_ROOT/nest-data"
  id="nestbackendz5"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/nest-fake" "$wt")
  mkdir -p "$data/$id"; printf 'brief\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/nest-state"; config="$TMP_ROOT/nest-config"
  mkdir -p "$state" "$config"

  # No --backend, no FM_BACKEND, no config/backend: nothing is explicitly
  # configured, so auto-detect runs. $TMUX and HERDR_ENV=1 are both present
  # (tmux nested inside a herdr pane) - the full fm-spawn.sh pipeline, not just
  # fm_backend_name, must resolve this to tmux and stay completely silent about
  # it (today's default path, byte-identical).
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HERDR_ENV=1 \
    FM_TMUX_LOG="$TMP_ROOT/nest.log" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1)
  expect_code 0 $? "fm-spawn.sh should auto-detect tmux and spawn successfully for nested tmux-in-herdr"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "auto-detected nested tmux-in-herdr must resolve to tmux (missing backend= means tmux)"
  case "$out" in
    *NOTICE*) fail "auto-detecting tmux (even nested inside herdr) must stay silent, no NOTICE expected"$'\n'"$out" ;;
  esac
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: auto-detect resolves nested tmux-in-herdr to tmux and stays silent end to end"
}

test_backend_name_precedence
test_backend_detect_precedence
test_backend_detect_cmux_fallback_bundle_id
test_backend_detect_cmux_fallback_requires_darwin
test_backend_detect_cmux_fallback_tmux_nested_false_positive
test_backend_detect_cmux_fallback_ancestry_pid_match
test_backend_detect_cmux_fallback_ancestry_comm_match
test_backend_detect_cmux_fallback_ancestry_stops_at_launchd
test_backend_name_cmux_fallback_notice
test_backend_name_autodetect_notice
test_backend_name_explicit_beats_detection
test_backend_validate_refuses_unknown
test_backend_source_shell_portable
test_backend_validate_spawn_accepts_orca
test_meta_get_and_backend_of_meta
test_resolve_selector_three_forms
test_backend_of_selector_matches_explicit_target_meta
test_send_conformance_old_vs_new
test_peek_conformance_old_vs_new
test_spawn_symlinked_project_prefix_avoids_false_refusal
test_teardown_conformance_old_vs_new
test_spawn_refuses_unknown_backend_flag
test_spawn_refuses_codex_app_backend_flag
test_spawn_refuses_unknown_fm_backend_env
test_spawn_default_backend_writes_no_meta_field
test_spawn_explicit_backend_flag_beats_autodetect_herdr_env
test_spawn_autodetect_nesting_resolves_tmux_silently
