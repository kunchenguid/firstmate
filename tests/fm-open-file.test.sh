#!/usr/bin/env bash
# fm-open-file.sh - open a firstmate-home artifact in a review surface without
# dumping its content into chat.
#
# These tests pin the helper's contract hermetically (stubbed tmux + wezterm, no
# real terminal multiplexer):
#   1. A single Markdown report opens in a detached tmux review tab, the opened
#      line names a short collision-safe tab, focus returns to the caller's
#      window, and no file content leaks into the printed line.
#   2. Opening the same report twice yields a collision-safe second tab name.
#   3. Several paths open one WezTerm tab whose link list carries a real
#      file:// hyperlink per target, and again no content leaks.
#   4. Missing paths, directories, out-of-home paths, and a bare invocation are
#      rejected; --lavish refuses a non-HTML file and refuses multiple files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPEN="$ROOT/bin/fm-open-file.sh"

TMP_ROOT=$(fm_test_tmproot fm-open-file)

# A firstmate home with a scout report, a Lavish HTML artifact, and a directory.
# The report carries a sentinel secret so a content-dump regression is caught.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/fix-login-k3" "$HOME_DIR/data/audit-x9" "$HOME_DIR/.lavish" "$HOME_DIR/browsedir"
printf '# Report\n\nsecret-sentinel-XYZ must never reach the opened line\n' \
  > "$HOME_DIR/data/fix-login-k3/report.md"
printf '# Audit\nfindings here\n' > "$HOME_DIR/data/audit-x9/report.md"
printf '<html><body>plan</body></html>\n' > "$HOME_DIR/.lavish/plan.html"

OUTSIDE="$TMP_ROOT/outside.md"
printf 'outside the home\n' > "$OUTSIDE"

# --- stubs ------------------------------------------------------------------
# tmux: pretend we are inside a session called "firstmate"; record created and
# selected windows so collision naming and focus restore can be asserted. The
# set of existing window names lives in FM_FAKE_WINDOWS so a second open sees the
# first tab and must dodge its name.
FB=$(fm_fakebin "$TMP_ROOT")
export FM_FAKE_WINDOWS="$TMP_ROOT/windows.txt" FM_TMUX_LOG="$TMP_ROOT/tmux.log"
: > "$FM_FAKE_WINDOWS"; : > "$FM_TMUX_LOG"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
sub=${1:-}; shift || true
case "$sub" in
  display-message)
    fmt=""
    while [ "$#" -gt 0 ]; do [ "$1" = "-p" ] && { shift; fmt=${1:-}; }; shift || true; done
    case "$fmt" in
      '#S') printf 'firstmate\n' ;;
      '#S:#I') printf 'firstmate:2\n' ;;
      *) printf 'x\n' ;;
    esac ;;
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  list-windows) [ -f "$FM_FAKE_WINDOWS" ] && cat "$FM_FAKE_WINDOWS"; exit 0 ;;
  new-window)
    name=""
    while [ "$#" -gt 0 ]; do [ "$1" = "-n" ] && { shift; name=${1:-}; }; shift || true; done
    printf '%s\n' "$name" >> "$FM_FAKE_WINDOWS"
    printf 'new-window %s\n' "$name" >> "$FM_TMUX_LOG"
    exit 0 ;;
  select-window)
    printf 'select-window %s\n' "$*" >> "$FM_TMUX_LOG"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"

# wezterm: no existing tabs, spawn returns a pane id and logs the command it was
# handed so the generated link-list file can be inspected.
export FM_WEZTERM_LOG="$TMP_ROOT/wezterm.log"
: > "$FM_WEZTERM_LOG"
cat > "$FB/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "cli" ] && shift
case "${1:-}" in
  list) printf '[]\n' ;;            # no existing tabs
  spawn)
    printf '%s\n' "$*" >> "$FM_WEZTERM_LOG"
    printf '42\n' ;;                # the new pane id
  set-tab-title) : ;;
esac
exit 0
SH
chmod +x "$FB/wezterm"

# run_open <env...> -- <args...>: invoke fm-open-file with the stubs on PATH and
# TMUX set so tmux_session takes the in-session branch. FM_ROOT_OVERRIDE points
# away from the repo so fm-guard's tangle check stays quiet. Captures stdout into
# the global OUT and returns the exit code.
run_open() {
  local env=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift  # drop --
  OUT=$(PATH="$FB:$PATH" TMUX="fake" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$TMP_ROOT" \
        TMPDIR="$TMP_ROOT" "${env[@]+"${env[@]}"}" "$OPEN" "$@" 2>/dev/null)
}

# 1. Single Markdown report -> tmux review tab.
run_open -- data/fix-login-k3/report.md
code=$?
expect_code 0 "$code" "single markdown open exits 0"
assert_contains "$OUT" "opened: data/fix-login-k3/report.md in tmux tab " "opened line names the relative path and a tmux tab"
assert_contains "$OUT" "report-fix" "tab name is short and derived from the task id"
assert_not_contains "$OUT" "secret-sentinel-XYZ" "opened line must not dump file content"
assert_grep "new-window report-fix" "$FM_TMUX_LOG" "a detached tmux window was created"
assert_grep "select-window -t firstmate:2" "$FM_TMUX_LOG" "focus is restored to the caller's window"
pass "single markdown report opens in a focus-preserving tmux tab without leaking content"

# 2. Opening it again must pick a collision-safe name.
run_open -- data/fix-login-k3/report.md
expect_code 0 "$?" "second open exits 0"
assert_contains "$OUT" "report-fix-2" "second tab dodges the first tab's name"
pass "repeat open yields a collision-safe tab name"

# 3. Several paths -> one WezTerm tab with a clickable link per target.
run_open -- data/fix-login-k3/report.md .lavish/plan.html data/audit-x9/report.md
expect_code 0 "$?" "multi-path open exits 0"
assert_contains "$OUT" "opened: 3 files in WezTerm tab " "multi-path opens a single WezTerm tab"
assert_not_contains "$OUT" "secret-sentinel-XYZ" "multi-path opened line must not dump content"
LIST_FILE=$(ls "$TMP_ROOT"/firstmate-review-links.* 2>/dev/null | head -1)
[ -n "$LIST_FILE" ] || fail "no generated review-links list file found"
assert_grep "file:///" "$LIST_FILE" "link list uses file:// hyperlinks"
for rel in data/fix-login-k3/report.md .lavish/plan.html data/audit-x9/report.md; do
  assert_grep "$rel" "$LIST_FILE" "link list labels target $rel"
done
assert_no_grep "secret-sentinel-XYZ" "$LIST_FILE" "link list shows labels, not file contents"
pass "multiple targets open one WezTerm tab of clickable file:// links"

# 4. Rejections.
run_open -- data/fix-login-k3/nope.md;          expect_code 1 "$?" "missing path is rejected"
run_open -- browsedir;                          expect_code 1 "$?" "a directory is rejected"
run_open -- "$OUTSIDE";                         expect_code 1 "$?" "an out-of-home path is rejected"
run_open --;                                    expect_code 2 "$?" "a bare invocation prints usage"
run_open -- --lavish data/fix-login-k3/report.md; expect_code 1 "$?" "--lavish refuses a non-HTML file"
run_open -- --lavish .lavish/plan.html data/audit-x9/report.md; expect_code 1 "$?" "--lavish refuses multiple files"
# --allow-outside lets an explicitly chosen outside file through (opens via tmux).
run_open -- --allow-outside "$OUTSIDE";         expect_code 0 "$?" "--allow-outside permits an explicit outside file"
pass "missing, directory, out-of-home, bare, and bad --lavish invocations are handled; --allow-outside opt-in works"
