#!/usr/bin/env bash
# Task fix-actionable-supervision: a leftover background helper process (a dev
# server, a build watcher, any long-running `cmd &` left echoing into the SAME
# pane) can leave busy-looking text (e.g. a generic "Working..." progress
# line) sitting in the last few non-blank lines of a pane's tail window even
# after the harness itself has returned to its own idle composer or a bare
# dead-shell terminal prompt. bin/fm-tmux-lib.sh's fm_pane_is_busy used to scan
# ONLY that tail window, so it could read such a pane as busy long after the
# harness's own turn ended - which then surfaces as bin/fm-crew-state.sh
# reporting `state: working · source: pane` for a crew that has actually
# stopped.
#
# The fix adds fm_tmux_cursor_busy: an authoritative, position-precise read of
# the pane's LIVE cursor row (every verified harness renders its busy
# indicator at/adjacent to the cursor). fm_pane_is_busy now trusts a cursor-row
# match outright (never a false negative on a genuinely busy pane), and when
# the cursor row is readable and does NOT match, corroborates against
# fm_tmux_composer_state: a genuinely idle composer or a bare dead-shell
# terminal prompt there means the tail-window busy text is stale/background
# noise, not current activity. An ambiguous (`pending`) or unreadable cursor
# row still falls through to the original tail scan, fail-closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-pane-busy)

# A fake tmux distinguishing the THREE distinct capture shapes fm_pane_is_busy
# now issues:
#   - `display-message ... '#{cursor_y}'`            -> FM_FAKE_CY
#   - `capture-pane -p -t <t> -S <n> -E <n>`  (no -e) -> FM_FAKE_CURSOR_LINE
#     (fm_tmux_cursor_busy's authoritative single-row read)
#   - `capture-pane -e -p -t <t> -S <n> -E <n>` (has -e) -> FM_FAKE_STYLED file
#     (fm_tmux_composer_state's ghost-aware single-row read)
#   - `capture-pane -p -t <t> -S -40`                 -> FM_FAKE_TAIL40 file
#     (the original tail-window regex fallback)
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    has_e=0; tail_scan=0; single_row=0
    prev=""
    for a in "$@"; do
      [ "$a" = "-e" ] && has_e=1
      if [ "$prev" = "-S" ]; then
        case "$a" in -40) tail_scan=1 ;; *) single_row=1 ;; esac
      fi
      prev=$a
    done
    if [ "$has_e" = 1 ]; then
      cat "${FM_FAKE_STYLED:-/dev/null}" 2>/dev/null
    elif [ "$single_row" = 1 ]; then
      printf '%s\n' "${FM_FAKE_CURSOR_LINE:-}"
    elif [ "$tail_scan" = 1 ]; then
      cat "${FM_FAKE_TAIL40:-/dev/null}" 2>/dev/null
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- Genuinely busy: the live cursor row itself carries the footer ----------

test_cursor_busy_footer_is_trusted_outright() {
  local dir fb
  dir="$TMP_ROOT/cursor-busy"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  # Tail window shows nothing busy-looking at all; only the live cursor row does.
  if ! PATH="$fb:$PATH" FM_FAKE_CY=5 FM_FAKE_CURSOR_LINE="esc to interrupt" \
        FM_FAKE_TAIL40=/dev/null fm_pane_is_busy "fakepane"; then
    fail "a busy footer on the live cursor row must be trusted as busy outright"
  fi
  pass "fm_pane_is_busy: a busy footer on the live cursor row is trusted outright"
}

# --- Genuinely idle: cursor and tail agree ------------------------------

test_genuinely_idle_pane_is_not_busy() {
  local dir fb tail
  dir="$TMP_ROOT/idle-both"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  tail="$dir/tail.txt"
  printf 'all quiet\n> \n' > "$tail"
  if PATH="$fb:$PATH" FM_FAKE_CY=3 FM_FAKE_CURSOR_LINE="> " \
       FM_FAKE_STYLED="$tail" FM_FAKE_TAIL40="$tail" fm_pane_is_busy "fakepane"; then
    fail "a genuinely idle pane (idle cursor, idle tail) must not read as busy"
  fi
  pass "fm_pane_is_busy: a genuinely idle pane is not busy"
}

# --- THE BUG: stale background helper text in the tail, idle composer live --

test_stale_background_helper_text_does_not_fool_busy_detection() {
  local dir fb tail styled
  dir="$TMP_ROOT/stale-helper"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  tail="$dir/tail.txt"
  styled="$dir/styled.txt"
  # A leftover `npm run dev &` (or similar) left its own progress banner in the
  # pane's recent scrollback, sharing the literal busy vocabulary ("Working...")
  # even though the harness's own composer, rendered just below it, is idle.
  printf '[dev server] Working...\n[dev server] ready on :3000\n\n\xe2\x94\x82 >            \xe2\x94\x82\n' > "$tail"
  printf '\xe2\x94\x82 >            \xe2\x94\x82\n' > "$styled"
  if PATH="$fb:$PATH" FM_FAKE_CY=6 FM_FAKE_CURSOR_LINE=$'\xe2\x94\x82 >            \xe2\x94\x82' \
       FM_FAKE_STYLED="$styled" FM_FAKE_TAIL40="$tail" fm_pane_is_busy "fakepane"; then
    fail "a leftover background helper's stale busy-looking text must not read as the harness being busy"
  fi
  pass "fm_pane_is_busy: a leftover background helper's stale tail text does not fool busy detection"
}

# --- Terminal-state case: bare dead shell, stale helper noise in the tail ---

test_bare_shell_prompt_with_stale_helper_text_is_not_busy() {
  local dir fb tail
  dir="$TMP_ROOT/bare-shell"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  tail="$dir/tail.txt"
  printf 'Working on cleanup...\n\n$ \n' > "$tail"
  if PATH="$fb:$PATH" FM_FAKE_CY=4 FM_FAKE_CURSOR_LINE='$ ' \
       FM_FAKE_STYLED="$tail" FM_FAKE_TAIL40="$tail" fm_pane_is_busy "fakepane"; then
    fail "a bare dead-shell terminal prompt with stale helper noise in the tail must not read as busy"
  fi
  pass "fm_pane_is_busy: a bare dead-shell terminal prompt is not busy despite stale tail noise"
}

# --- Fail-closed: ambiguous pending content still falls through to the tail -

test_pending_cursor_content_falls_through_to_tail_scan() {
  local dir fb tail
  dir="$TMP_ROOT/pending-fallthrough"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  tail="$dir/tail.txt"
  printf 'work in progress\nesc to interrupt\n' > "$tail"
  # The cursor row holds real, unsubmitted text (not busy, not idle) - ambiguous.
  if ! PATH="$fb:$PATH" FM_FAKE_CY=2 FM_FAKE_CURSOR_LINE="some unsubmitted text" \
        FM_FAKE_STYLED="$dir/pending-styled.txt" FM_FAKE_TAIL40="$tail" \
        bash -c '
          printf "some unsubmitted text\n" > "'"$dir"'/pending-styled.txt"
          . "'"$LIB"'"
          fm_pane_is_busy fakepane
        '; then
    fail "an ambiguous (pending) cursor row must fail closed and fall through to the tail scan"
  fi
  pass "fm_pane_is_busy: an ambiguous pending cursor row falls through to the tail scan (fail-closed)"
}

# --- Fail-closed: unreadable cursor still falls through to the tail scan ----

test_unreadable_cursor_falls_through_to_tail_scan() {
  local dir fb tail
  dir="$TMP_ROOT/unreadable-cursor"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  tail="$dir/tail.txt"
  printf 'work in progress\nesc to interrupt\n' > "$tail"
  if ! PATH="$fb:$PATH" FM_FAKE_TMUX_MISSING=1 FM_FAKE_TAIL40="$tail" \
        bash -c '
          FM_FAKE_TMUX_MISSING=0
          # Simulate a cursor read that fails (bad tmux target) while capture-pane
          # for the tail scan still succeeds, by using a tmux stub that only
          # rejects display-message.
          cat > "'"$dir"'/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) exit 1 ;;
  capture-pane)
    prev=""
    tail_scan=0
    for a in "\$@"; do
      if [ "\$prev" = "-S" ] && [ "\$a" = "-40" ]; then tail_scan=1; fi
      prev=\$a
    done
    [ "\$tail_scan" = 1 ] && cat "'"$tail"'"
    exit 0 ;;
esac
exit 1
SH
          chmod +x "'"$dir"'/fakebin/tmux"
          . "'"$LIB"'"
          fm_pane_is_busy fakepane
        '; then
    fail "an unreadable cursor row must fail closed and fall through to the tail scan"
  fi
  pass "fm_pane_is_busy: an unreadable cursor row falls through to the tail scan unchanged"
}

test_cursor_busy_footer_is_trusted_outright
test_genuinely_idle_pane_is_not_busy
test_stale_background_helper_text_does_not_fool_busy_detection
test_bare_shell_prompt_with_stale_helper_text_is_not_busy
test_pending_cursor_content_falls_through_to_tail_scan
test_unreadable_cursor_falls_through_to_tail_scan
