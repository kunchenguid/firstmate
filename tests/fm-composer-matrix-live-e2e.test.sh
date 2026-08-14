#!/usr/bin/env bash
# tests/fm-composer-matrix-live-e2e.test.sh - the live composer-matrix guard
# (live-harness-optin family; task fm-composer-thin-adapter-refactor-r1).
#
# The shared composer classifier's shape catalogue (bin/fm-composer-lib.sh) is
# built entirely from vendor-rendered signals, so per
# .agents/skills/firstmate-coding-guidelines it must be proven against the
# REAL harnesses: a stub can only confirm the assumption already written into
# the stub. This guard launches every INSTALLED verified harness idle in an
# isolated tmux server and requires the real fm_tmux_composer_state to reach
# `empty`, failing loudly with the harness name and version. It also proves:
#   - the strict blank-row posture live: a plain shell pane with a blank
#     cursor row must classify unknown and defer injection;
#   - the zellij false-positive regression live (when zellij is installed): a
#     pane whose content changes for reasons unrelated to submission must NOT
#     report a delivered send, and a real claude-in-zellij `dump-screen
#     --ansi` capture must classify empty through the zellij thin adapter;
#   - the herdr titled-rule shape live (when herdr is running): a claude pane
#     whose composer's top rule carries the terminal title is the shape that
#     read `unknown` and deferred every away-mode escalation. Whether the
#     vendor draws that overlay changes between Claude releases, so the guard
#     asserts it when present and says so explicitly when it is absent. A rule
#     the classifier declines on one of its documented boundaries is noted with
#     that reason rather than reported as a regression, and is never a pass.
#     It also reads every idle claude pane through the shared classifier, expecting the
#     verdict that pane's own composer row calls for - `empty` when that row is
#     blank, and either `empty` or a pending read when it carries text, which
#     may be an unsubmitted draft or the vendor's own dim suggestion. A pane
#     showing no composer row at all is skipped and said so, never asserted.
#
# Run explicitly with FM_COMPOSER_MATRIX_LIVE=1. No prompt is ever submitted
# to any harness, so no model tokens are spent. An absent harness is reported
# explicitly and skipped; a run that verified nothing fails rather than
# passing vacuously. Refresh docs/verification/runtime-backends.md ("Composer
# classification matrix") from this guard's output after any harness upgrade.
#
# Folder trust: harnesses are launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails that harness's check.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_COMPOSER_MATRIX_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_MATRIX_LIVE=1 to run the live composer-matrix guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "not ok - FM_COMPOSER_MATRIX_LIVE=1 but tmux is not installed" >&2; exit 1; }

SOCKET="fm-cmx-live-$$"
SESSION="cmxlive"
ZELLIJ_SESSION="fm-cmx-live-zj-$$"
CHECKED=0
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${ZJ_BG:-}" ] || kill "$ZJ_BG" 2>/dev/null || true
  if command -v zellij >/dev/null 2>&1; then
    zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmx-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

check_harness_idle_empty() {  # <name> <launch-cmd...>
  local name=$1 win="hx-$1" verdict='' i=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45} version dismissed=0 startup_screen
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "$name ($version): could not launch in the isolated tmux server"
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    # A fresh harness may park on a vendor update-available modal (observed
    # live: codex 0.146.0 and opencode 1.14.46), which the strict classifier
    # correctly refuses to call a composer. Dismiss it once, mid-budget, with
    # a single Escape - the one key that submits nothing anywhere and is how
    # the audit declined the same prompts. Never Enter: on codex's dialog
    # Enter would RUN the upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      # Trust prompts also accept Escape, but there it exits the harness and
      # erases the actionable failure surface. Preserve those prompts; only
      # dismiss a non-trust startup modal.
      startup_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$startup_screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    printf '# %s pane tail at failure:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): idle composer never classified empty (last verdict: %s)\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): real idle composer classifies empty"
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# --- 1. Every installed verified harness must reach a proven-empty composer --
for h in claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

# --- 2. The strict blank-row posture, live ----------------------------------
# A plain shell pane parked on a blank line between two rules (the audit's
# sleep-pane counterexample): the permissive rule read this empty; strict must
# defer.
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n strictblank -c "$ROOT" \
  -- bash -c 'printf "────────────────────────\n\n"; printf "\033[A"; exec sleep 300'
sleep 1
verdict=$(fm_tmux_composer_state "$SESSION:strictblank")
if [ "$verdict" = unknown ]; then
  if fm_pane_input_pending "$SESSION:strictblank"; then
    CHECKED=$((CHECKED + 1))
    pass "strict posture live: a blank shell row classifies unknown and injection defers"
  else
    FAILED=1
    printf 'not ok - strict posture live: pane_input_pending did not defer on an unknown verdict\n' >&2
  fi
else
  FAILED=1
  printf 'not ok - strict posture live: blank shell row classified %s, expected unknown\n' "${verdict:-unreadable}" >&2
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:strictblank" 2>/dev/null || true

# --- 3. zellij: real classifier + the false-positive regression -------------
if command -v zellij >/dev/null 2>&1; then
  zj_version=$(zellij --version 2>/dev/null | head -1)
  [ -n "$zj_version" ] || zj_version='version-unknown'
  export FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source zellij 2>/dev/null \
    || fail "zellij ($zj_version): adapter source failed"

  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  zellij --session "$ZELLIJ_SESSION" options --default-shell bash >/dev/null 2>&1 &
  ZJ_BG=$!
  i=0
  while [ "$i" -lt 10 ] && ! fm_backend_zellij_session_exists "$ZELLIJ_SESSION"; do
    i=$((i + 1))
    sleep 0.5
  done
  fm_backend_zellij_session_exists "$ZELLIJ_SESSION" \
    || fail "zellij ($zj_version): probe session setup failed"
  panes=$(fm_backend_zellij_cli "$ZELLIJ_SESSION" action list-panes --json 2>/dev/null) \
    || fail "zellij ($zj_version): pane discovery command failed"
  pane_id=$(printf '%s' "$panes" | jq -r '.[]? | select(.is_plugin == false) | .id' 2>/dev/null | head -1)
  case "$pane_id" in
    ''|*[!0-9]*) fail "zellij ($zj_version): pane discovery returned no terminal pane" ;;
  esac
  target="$ZELLIJ_SESSION:$pane_id"

  fm_backend_zellij_send_literal "$target" 'while sleep 1; do date; done' \
    || fail "zellij ($zj_version): clock probe setup write failed"
  fm_backend_zellij_send_key "$target" Enter \
    || fail "zellij ($zj_version): clock probe setup submit failed"
  sleep 2
  probe='# audit-probe-never-submitted'
  fm_backend_zellij_send_literal "$target" "$probe" \
    || fail "zellij ($zj_version): false-positive probe write failed"
  sleep 0.5
  probe_capture=$(fm_backend_zellij_capture "$target" 40 2>/dev/null) \
    || fail "zellij ($zj_version): false-positive probe capture failed"
  case "$probe_capture" in
    *"$probe"*) ;;
    *) fail "zellij ($zj_version): false-positive probe text was not visible after typing" ;;
  esac
  verdict=$(fm_composer_submit_retry_core fm_backend_zellij_send_key fm_backend_zellij_composer_state \
    "$target" 2 0.5 2>/dev/null)
  case "$verdict" in
    pending|unknown)
      CHECKED=$((CHECKED + 1))
      pass "zellij ($zj_version): unrelated pane change never confirms delivery (verdict: $verdict)"
      ;;
    send-failed)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe text was not typed (send-failed)\n' "$zj_version" >&2
      ;;
    *)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe returned unexpected verdict %s (expected pending or unknown)\n' \
        "$zj_version" "${verdict:-none}" >&2
      ;;
  esac
  kill "$ZJ_BG" 2>/dev/null || true
  ZJ_BG=
  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
else
  note "harness absent, not verified here: zellij (false-positive regression not exercised)"
fi

# hd_rule_refusal_reason: the DOCUMENTED reason _fm_composer_rule_row declined a
# dashes-plus-text row, or nothing when the refusal is not one of the shape
# owner's authorized boundaries. Two are authorized here: a title that precedes
# the opening 8-column dash run, the one title position that predicate
# deliberately does not read, and a row whose mapped column count cannot be
# matched against its partner, which is what a double-width title glyph does.
# Anything else - a structural glyph, a malformed byte, no dash run at all - is
# not a documented refusal, so the caller must fail rather than excuse it.
hd_rule_refusal_reason() {  # <trimmed-row> <partner-spaces>
  local row=$1 expected=$2 cols
  case "$row" in
    ────────*)
      cols=$(fm_composer_column_spaces "${row//─/ }") || return 1
      [ "$cols" = "$expected" ] && return 1
      printf 'its mapped column count does not match the closing rule, so the width cannot be established honestly (a double-width title glyph, or rules of unequal width)'
      ;;
    *────────*)
      printf 'its title precedes the opening 8-column dash run, the one title position the rule predicate deliberately does not read'
      ;;
    *) return 1 ;;
  esac
}

# hd_documented_unknown: the DOCUMENTED reason a pane's composer reads `unknown`,
# or nothing when that verdict is a real disagreement. A pane with no titled rule
# above its composer row has no boundary of this exception's in play, so its
# `unknown` stays a failure - that is the defect this guard exists to catch.
hd_documented_unknown() {  # <capture> <glyph-row>
  local cap=$1 g=$2 above below probe limit row
  [ "$g" -ge 1 ] || return 1
  above=$(_fm_composer_screen_row "$((g - 1))" "$cap")
  fm_composer_normalize_trim_var above
  ! _fm_composer_pi_separator_row "$above" || return 1
  below=$(_fm_composer_screen_row "$((g + 1))" "$cap")
  fm_composer_normalize_trim_var below
  if _fm_composer_pi_separator_row "$below"; then
    hd_rule_refusal_reason "$above" "${below//─/ }"
    return
  fi
  # A closing rule further down is the single-row adjacency limit the sandwich
  # exception deliberately does not cross, which is what a ghost suggestion
  # wrapping onto a second row produces on a narrow pane.
  probe=$((g + 2))
  limit=$((g + 4))
  while [ "$probe" -le "$limit" ]; do
    row=$(_fm_composer_screen_row "$probe" "$cap")
    fm_composer_normalize_trim_var row
    if _fm_composer_pi_separator_row "$row"; then
      case "$above" in
        ────────*)
          printf 'its closing rule sits %s rows below the composer row, outside the single-row adjacency the sandwich exception requires' \
            "$((probe - g))"
          return 0
          ;;
      esac
      return 1
    fi
    probe=$((probe + 1))
  done
  return 1
}

# --- 4. herdr: the real live composer through the herdr adapter ---------------
# The titled-rule regression: Claude draws its borderless composer between two
# horizontal `─` rules, and a terminal-title overlay burned into the TOP rule
# makes that rule dashes PLUS text, so the separated pair never opens and the
# composer's own bottom rule reads as an unmatched separator below the already
# matched `❯` row. That shape classified `unknown` and deferred every away-mode
# escalation, silently.
#
# Whether the overlay is drawn at all is the vendor's choice and it has already
# changed once inside a patch release, so this guard asserts the RENDERING it
# finds and reports explicitly when the shape is absent. Absence is not a pass:
# the standing proof of the classifier's behaviour is the portable regression
# `test_matrix_claude_titled_composer_rule` in tests/fm-composer-lib.test.sh,
# which builds the shape itself and therefore holds on every Claude release.
#
# A titled rule the classifier declines on one of its DOCUMENTED boundaries is
# noted with the reason and is not a regression: the boundary is the specified
# behaviour, and failing there would cry wolf on a classifier doing exactly what
# it says. A refusal for any other reason fails loudly, because a live composer
# reading `unknown` is the defect that cost the outage. Neither a note nor a skip
# counts as a live pass, so this section can never go vacuously green.
#
# Read-only throughout: pane list and pane capture on the explicitly named
# `default` session, and nothing submitted. This section makes no lifecycle call
# itself, though pane capture reaches fm_backend_herdr_server_ensure, which
# backgrounds a server start when the session's server is not running; that is
# unreachable here in practice because capture only runs after `pane list`
# already returned output, which only a live server produces.
if command -v herdr >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
  hd_version=$(herdr --version 2>/dev/null | head -1)
  [ -n "$hd_version" ] || hd_version='version-unknown'
  cl_version=$(harness_version claude)
  export FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  if fm_backend_source herdr 2>/dev/null; then
    hd_checked=0
    hd_titled=0
    hd_clean=0
    hd_examined=0
    hd_shaped=0
    hd_noted=0
    hd_panes=$(fm_backend_herdr_cli default pane list 2>/dev/null || true)
    if [ -n "$hd_panes" ]; then
      # EVERY claude pane is scanned, not only the focused one. The 2026-08-11
      # observation that only a focused pane carried the overlay was true of
      # claude 2.1.226.634 and false of 2.1.228.649, so filtering on focus would
      # narrow this guard to one vendor build.
      while IFS= read -r hd_pane; do
        [ -n "$hd_pane" ] || continue
        hd_cap=$(fm_backend_herdr_capture "default:$hd_pane" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null || true)
        [ -n "$hd_cap" ] || continue
        hd_glyph_row=-1
        hd_row=0
        while IFS= read -r hd_line; do
          hd_trim=$hd_line
          fm_composer_normalize_trim_var hd_trim
          if fm_composer_leading_agent_glyph_var hd_g "$hd_trim"; then hd_glyph_row=$hd_row; fi
          hd_row=$((hd_row + 1))
        done <<EOF
$hd_cap
EOF
        [ "$hd_glyph_row" -ge 1 ] || continue
        hd_examined=$((hd_examined + 1))
        hd_above=$(_fm_composer_screen_row "$((hd_glyph_row - 1))" "$hd_cap")
        fm_composer_normalize_trim_var hd_above
        hd_below=$(_fm_composer_screen_row "$((hd_glyph_row + 1))" "$hd_cap")
        fm_composer_normalize_trim_var hd_below
        # The rule below the glyph is this composer's closing rule and supplies
        # the width the titled rule above must match.
        _fm_composer_pi_separator_row "$hd_below" || continue
        hd_shaped=$((hd_shaped + 1))
        if _fm_composer_pi_separator_row "$hd_above"; then
          hd_clean=$((hd_clean + 1))
          continue
        fi
        if _fm_composer_rule_row "$hd_above" "${hd_below//─/ }"; then
          hd_titled=$((hd_titled + 1))
          CHECKED=$((CHECKED + 1))
          pass "herdr ($hd_version) + claude ($cl_version): pane $hd_pane titled composer rule is recognized as a rule"
          continue
        fi
        hd_reason=$(hd_rule_refusal_reason "$hd_above" "${hd_below//─/ }" || true)
        if [ -n "$hd_reason" ]; then
          hd_noted=$((hd_noted + 1))
          note "herdr ($hd_version) + claude ($cl_version): pane $hd_pane draws a titled composer rule the classifier declines on a documented boundary - $hd_reason; the refusal is the specified behaviour and not a regression, and this pane is NOT a live pass"
          printf '#   rule above the glyph row: [%s]\n' "$hd_above"
          continue
        fi
        FAILED=1
        hd_cols=$(fm_composer_column_spaces "${hd_above//─/ }" || true)
        hd_residue=${hd_cols//[[:space:]]/}
        printf '# pane %s rule above the glyph row:\n#   [%s]\n' "$hd_pane" "$hd_above" >&2
        if [ -n "$hd_residue" ]; then
          printf '#   the column proof could not count: [%s]\n' "$hd_residue" >&2
        else
          printf '#   the column proof refused the row before counting anything (a structural box-drawing glyph)\n' >&2
        fi
        printf 'not ok - herdr (%s) + claude (%s): pane %s titled composer rule was NOT recognized; the away-mode titled-rule regression is live again\n' \
          "$hd_version" "$cl_version" "$hd_pane" >&2
      done <<EOF
$(printf '%s' "$hd_panes" | jq -r '
  .result.panes[]?
  | select(.agent == "claude")
  | .pane_id' 2>/dev/null)
EOF
      # Every live claude pane herdr reports idle, read through the shared
      # classifier. The expected verdict comes from the pane's OWN composer row,
      # not from herdr's agent-state: an idle agent whose operator has typed a
      # draft and not submitted it is legitimately `pending`, and a guard that
      # demanded `empty` there would fail on any real fleet with an unsent
      # message in it - crying wolf on the exact panes it is meant to protect.
      #
      # The expectation is read from the raw glyph row rather than through
      # fm_composer_extract_selected_content, which would route it back through
      # the selector under test and make the assertion circular. That row comes
      # from the PLAIN capture, while the classifier reads the STYLED one and
      # strips claude's dim rotating suggestion, so the two see different bytes
      # whenever the row carries text: `❯ Try "..."` is a draft to this loop and
      # correctly nothing to the classifier. So the exact `empty` is asserted
      # only where the plain row is blank and the derivation is unambiguous, and
      # a row carrying text accepts either direction of the read. What is never
      # accepted, in both cases, is `unknown` or an unreadable verdict on a
      # composer this loop can see - the defect that deferred every away-mode
      # escalation, and the whole reason this guard exists.
      #
      # A pane with no readable capture or no composer glyph row at all is
      # SKIPPED, not asserted: herdr reports `idle` for a pane parked on a
      # `/model` picker or a compaction prompt the classifier rightly refuses,
      # and for a pane scrolled into its own scrollback. Skipped panes count
      # toward nothing, so the "no idle claude pane to read" note below still
      # fires rather than the guard passing vacuously.
      while IFS=$'\t' read -r hd_pane hd_focused; do
        [ -n "$hd_pane" ] || continue
        hd_cap=$(fm_backend_herdr_capture "default:$hd_pane" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null || true)
        if [ -z "$hd_cap" ]; then
          note "herdr ($hd_version): idle pane $hd_pane returned no capture; skipped, not asserted"
          continue
        fi
        hd_glyph_row=-1
        hd_row=0
        hd_draft=''
        while IFS= read -r hd_line; do
          hd_trim=$hd_line
          fm_composer_normalize_trim_var hd_trim
          if fm_composer_leading_agent_glyph_var hd_g "$hd_trim"; then
            hd_glyph_row=$hd_row
            hd_draft=${hd_trim#*"$hd_g"}
            fm_composer_normalize_trim_var hd_draft
          fi
          hd_row=$((hd_row + 1))
        done <<EOF2
$hd_cap
EOF2
        if [ "$hd_glyph_row" -lt 0 ]; then
          note "herdr ($hd_version): idle pane $hd_pane renders no composer row (modal or scrollback); skipped, not asserted"
          continue
        fi
        if [ -n "$hd_draft" ]; then
          hd_accept='empty pending pending-unproven'
          hd_why="composer row carries text that is either a draft or the vendor's dim suggestion"
        else
          hd_accept='empty'
          hd_why="composer row is blank"
        fi
        hd_verdict=$(fm_backend_herdr_composer_state "default:$hd_pane" 2>/dev/null || true)
        hd_ok=0
        case " $hd_accept " in
          *" ${hd_verdict:-unreadable} "*) hd_ok=1 ;;
        esac
        if [ "$hd_ok" -eq 1 ]; then
          hd_checked=$((hd_checked + 1))
          CHECKED=$((CHECKED + 1))
          pass "herdr ($hd_version) + claude ($cl_version): idle pane $hd_pane (focused=$hd_focused) $hd_why and classifies $hd_verdict"
        elif [ "$hd_verdict" = unknown ] \
             && hd_reason=$(hd_documented_unknown "$hd_cap" "$hd_glyph_row") \
             && [ -n "$hd_reason" ]; then
          note "herdr ($hd_version) + claude ($cl_version): idle pane $hd_pane (focused=$hd_focused) $hd_why and classifies unknown on a documented boundary - $hd_reason; reported, not asserted, and not a live pass"
        else
          FAILED=1
          printf '# herdr pane %s tail at failure:\n' "$hd_pane" >&2
          fm_backend_herdr_capture "default:$hd_pane" 6 2>/dev/null \
            | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
          printf 'not ok - herdr (%s) + claude (%s): idle pane %s (focused=%s) %s but classified %s, expected one of: %s\n' \
            "$hd_version" "$cl_version" "$hd_pane" "$hd_focused" "$hd_why" "${hd_verdict:-unreadable}" "$hd_accept" >&2
        fi
      done <<EOF
$(printf '%s' "$hd_panes" | jq -r '
  .result.panes[]?
  | select(.agent == "claude")
  | select(.agent_status == "idle" or .agent_status == "done")
  | [.pane_id, (.focused | tostring)] | @tsv' 2>/dev/null)
EOF
    fi
    if [ "$hd_checked" -eq 0 ]; then
      note "herdr ($hd_version) running but no idle claude pane to read; live empty verdicts not exercised here"
    fi
    if [ "$hd_titled" -eq 0 ]; then
      note "herdr ($hd_version) + claude ($cl_version) read NO titled composer rule live: of $hd_examined claude composer pane(s) examined, $hd_shaped carried a rule directly below the composer row, $hd_clean of those drew a plain rule, and $hd_noted drew a titled rule declined on a documented boundary (noted above); the titled-rule regression was NOT exercised live here and rests on the portable regression in tests/fm-composer-lib.test.sh"
    fi
  else
    note "herdr present but adapter source failed; titled-rule shape not exercised here"
  fi
else
  note "harness absent, not verified here: herdr+claude (titled composer rule not exercised)"
fi

# --- refuse a vacuous pass ---------------------------------------------------
[ "$FAILED" -eq 0 ] || fail "live composer-matrix guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live composer-matrix guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live composer-matrix guard verified $CHECKED live surface(s)"
