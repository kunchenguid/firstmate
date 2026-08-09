#!/usr/bin/env bash
# tests/fm-composer-harness-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness's real, genuinely EMPTY composer still classifies
# `empty`, and that real typed text in it still classifies `pending`.
#
# Why this file exists: the composer verdict is read off the harness's own
# rendered input row, which the vendor controls and changes without notice.
# Claude Code began separating its prompt glyph from the composer's content with
# U+00A0 NO-BREAK SPACE instead of an ASCII space, and the shared classifier -
# which tested only POSIX `[[:space:]]` - read that lone separator as a human's
# half-typed text. Every caller that must not type over unsubmitted input then
# refused to act: away-mode escalation delivery deferred 2105 times across 8.3
# hours against an idle pane, `bin/fm-send.sh` reported landed messages as
# unconfirmed, and the away-mode wedge alarm was itself undeliverable because it
# shares the blocked channel (upstream kunchenguid/firstmate#1988).
#
# That class of regression is invisible from the output: the composer LOOKS
# empty in any plain capture, and only decoding the code points reveals the
# separator. A stubbed agent cannot see it either - a fixture can only confirm
# the separator that was already written into it. So this guard drives real
# harnesses and decodes what they actually draw, and prints those bytes on
# success too, because that decoded row is the evidence
# docs/verification/runtime-backends.md records.
#
# Both directions are checked for every harness, because the fix for a false
# `pending` would be trivially "achievable" by making the predicate permissive,
# and a false `empty` is the strictly worse failure: it types over a captain's
# half-written message, silently.
#
# The shared owner recognises several composer SHAPES on the way to that
# verdict, and they have failed independently - an unbordered row misreads as
# `pending`, a bordered box whose geometry cannot be proven blank misreads as
# `unknown`, and both make every caller refuse to act. Which shape a harness
# draws is the harness's own choice, so this guard reports the shape each one
# exercised (and says plainly when a run saw only one of them) rather than
# pretending a single-shape run covered the others.
#
# Backend scope: this drives the tmux adapter, the verified reference backend.
# The verdict itself comes from the ONE shared owner (bin/fm-composer-lib.sh's
# fm_composer_classify_content) that the tmux, herdr, orca, and cmux adapters
# all delegate to, and the drift being guarded is what the HARNESS renders, not
# what a backend captures - the same claude build was observed drawing the same
# `❯`+U+00A0 row through both tmux and herdr. Per-backend structural row-finding
# is covered by each adapter's own portable suite.
#
# Each harness is launched bare, with no prompt, and text is only ever TYPED,
# never submitted, so this consumes no model tokens. An unauthenticated harness
# that never reaches a composer is reported as unverified rather than passed
# over silently.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. Its portable counterparts pin the classifier logic in
# CI: tests/fm-composer-ghost.test.sh and the composer cases in
# tests/fm-backend-herdr.test.sh. Run this guard after any harness upgrade and
# before trusting refreshed per-harness evidence.
set -u

if [ "${FM_COMPOSER_HARNESS_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_HARNESS_DRIFT=1 to run the installed-harness composer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-composer-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch (kimi is not required to be on PATH).
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# The composer row as raw bytes, hex-dumped. A separator change is invisible in
# rendered text and only shows up here (U+00A0 reads as the byte pair c2 a0), so
# every verdict this guard reports - pass or fail - carries it.
composer_row_bytes() {  # <target>
  local row
  row=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null \
    | grep -a -e "$(printf '\xe2\x9d\xaf')" -e "$(printf '\xe2\x80\xba')" -e "$(printf '\xe2\x9f\xa9')" \
    | tail -1)
  [ -n "$row" ] || { printf '(no prompt-glyph row found in the capture)'; return 0; }
  printf '%s' "$row" | LC_ALL=C od -An -tx1 | tr -s ' \n' ' '
}

# Which shape from the shared owner's catalogue this harness's composer takes.
# The shapes reach the same verdict by different routes and have failed
# independently: an unbordered row misreads as `pending`, while a bordered box
# whose geometry cannot be proven blank misreads as `unknown`. Both refuse to
# act, so a fix for one is not evidence for the other, and every verdict below
# names the path it was reached through. The shape comes from the SAME row scan
# the verdict does (bin/fm-composer-lib.sh's _fm_composer_scan_screen), so this
# label can never disagree with the classification it is describing.
composer_structural_path() {  # <target>
  local cy pane plain
  cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$1" '#{cursor_y}' 2>/dev/null) || cy=
  case "$cy" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
  pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S 0 -E - 2>/dev/null) || {
    printf 'unreadable'; return 0
  }
  plain=$(printf '%s\n' "$pane" | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" "$cy"
  if [ "$FM_COMPOSER_SCAN_BOX_TOP" -ge 0 ]; then
    printf 'bordered-box'
  elif [ "$FM_COMPOSER_SCAN_LEFTBAR_START" -ge 0 ]; then
    printf 'left-bar'
  elif [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" = 1 ]; then
    printf 'separated'
  elif [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 0 ]; then
    printf 'bare-row'
  else
    printf 'unrecognised'
  fi
}

# Read the verdict twice so a mid-redraw frame cannot be mistaken for a settled
# one; an unstable pair reports empty, which the callers below treat as not yet
# settled rather than as a verdict.
stable_composer_state() {  # <target>
  local first second
  first=$(fm_backend_composer_state tmux "$1")
  sleep 1
  second=$(fm_backend_composer_state tmux "$1")
  [ "$first" = "$second" ] || return 0
  printf '%s' "$first"
}

# Poll until <target>'s settled verdict is one of <wanted...>, or the bound
# expires; echo whatever the last settled verdict was.
await_composer_state() {  # <target> <deadline-iterations> <wanted...>
  local target=$1 tries=$2 state='' want
  shift 2
  while [ "$tries" -gt 0 ]; do
    state=$(stable_composer_state "$target")
    for want in "$@"; do
      [ "$state" = "$want" ] && { printf '%s' "$state"; return 0; }
    done
    tries=$((tries - 1))
  done
  printf '%s' "$state"
}

# A marker this guard types itself. Establishing "this pane is really sitting at
# a composer" from our OWN input is what makes the empty verdict affirmative
# rather than assumed: a harness parked on a startup dialog (claude's "1. Yes, I
# trust this folder" menu row even begins with the `❯` glyph) never takes the
# marker, and is reported unverified instead of being read as a composer.
# Letters only - no `/` or `$`, which would open a completion popup.
PROBE_MARKER=zqxfmcomposerprobe

pane_has_marker() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null \
    | LC_ALL=C grep -qa "$PROBE_MARKER"
}

await_marker() {  # <target> <present|absent> <tries>
  local target=$1 want=$2 tries=$3
  while [ "$tries" -gt 0 ]; do
    if pane_has_marker "$target"; then
      [ "$want" = present ] && return 0
    else
      [ "$want" = absent ] && return 0
    fi
    sleep 0.5
    tries=$((tries - 1))
  done
  return 1
}

CHECKED=0
SKIPPED=
UNVERIFIED=
PATHS_SEEN=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its composer rendering is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the composer probe"

  state=
  for _ in $(seq 1 150); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  [ "$state" = alive ] || {
    UNVERIFIED="$UNVERIFIED $harness"
    note "unverified: $harness $version never reached an 'alive' process, so its composer was never read"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  }

  # Let the harness paint its first full frame, then record what it starts on
  # purely as evidence - the startup frame is NOT asserted on, because a trust
  # or login dialog is a legitimate thing to start on and is not a composer.
  sleep 3
  note "$harness $version: startup row bytes $(composer_row_bytes "$target")"

  # Step 1, the pending direction, which also PROVES this pane is at a composer:
  # type a marker literally, never submitted, and require the harness to render
  # it back.
  #
  # A first launch in a fresh directory can sit on a trust or bypass-permissions
  # confirmation instead (.agents/skills/harness-adapters/SKILL.md: accept with
  # Enter, or the choice the dialog requires). Enter is sent ONLY after the pane
  # has demonstrably NOT reflected typed input, so it can never submit a real
  # composer and start a billed turn; two rounds cover a trust dialog followed
  # by a permissions one.
  at_composer=0
  for _ in 1 2 3; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -l -t "$target" "$PROBE_MARKER" \
      || fail "$harness ($version): could not type into the pane"
    if await_marker "$target" present 20; then at_composer=1; break; fi
    note "$harness $version: typed input was not rendered back; accepting a startup confirmation with Enter and retrying"
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" C-u >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter >/dev/null 2>&1 || true
    sleep 3
  done
  if [ "$at_composer" -ne 1 ]; then
    UNVERIFIED="$UNVERIFIED $harness"
    note "unverified: $harness $version never rendered typed input back, so it is not sitting at a composer (a login or trust dialog it does not accept with Enter, or it needs credentials). Row bytes: $(composer_row_bytes "$target")"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi

  structural_path=$(composer_structural_path "$target")
  note "$harness $version: composer reached through the $structural_path path"

  typed=$(await_composer_state "$target" 20 pending)
  [ "$typed" = pending ] || fail \
    "COMPOSER DRIFT: $harness $version is rendering real unsubmitted text in its composer (reached through the $structural_path path), yet it classifies '$typed' instead of 'pending'. This is the DANGEROUS direction: firstmate will type over a captain's half-written message, and the loss is silent. Decoded composer row: $(composer_row_bytes "$target")."

  # Step 2, the empty direction. Clearing our own marker is what makes the
  # composer AFFIRMATIVELY empty: the row is empty because this guard just
  # emptied it and confirmed the marker is gone from the rendered pane, not
  # because the verdict said so.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" C-u >/dev/null 2>&1 || true
  if ! await_marker "$target" absent 40; then
    UNVERIFIED="$UNVERIFIED $harness"
    note "unverified: $harness $version did not clear its composer on C-u, so no affirmatively empty composer could be produced to read. Row bytes: $(composer_row_bytes "$target")"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi

  empty_path=$(composer_structural_path "$target")
  cleared=$(await_composer_state "$target" 20 empty)
  [ "$cleared" = empty ] || fail \
    "COMPOSER DRIFT: $harness $version has a composer this guard just emptied - the typed marker is gone from the rendered pane - yet it classifies '$cleared' instead of 'empty', reached through the $empty_path path. Every caller that must not overwrite unsubmitted input now refuses to act against this harness: away-mode escalations stop being delivered and steer confirmations report landed messages as unconfirmed. On the $empty_path path a '$cleared' verdict means the separator or prompt glyph this release renders is not one bin/fm-composer-lib.sh recognises (bare-row drift usually reads 'pending'; a bordered box whose blanked geometry no longer matches its border reads 'unknown'). Decoded composer row: $(composer_row_bytes "$target") (U+00A0 NO-BREAK SPACE is the byte pair c2 a0; fm_composer_normalize_trim_var maps every Unicode White_Space=Yes code point, so a byte run outside that property is the thing to add)."

  note "$harness $version: EMPTY composer row bytes $(composer_row_bytes "$target")"

  case " $PATHS_SEEN " in
    *" $empty_path "*) : ;;
    *) PATHS_SEEN="$PATHS_SEEN $empty_path" ;;
  esac
  pass "composer drift: $harness $version reads pending with real typed text and empty once cleared (via the $empty_path path)"
  CHECKED=$((CHECKED + 1))
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] || fail \
  "no installed harness reached a readable composer, so this run proved nothing; install and authenticate at least one harness before trusting a pass"

[ -n "$SKIPPED" ] && note "not installed on this machine:$SKIPPED"
[ -n "$UNVERIFIED" ] && note "installed but composer unverified (no readable composer reached):$UNVERIFIED"
note "checked $CHECKED installed harness(es) end to end"
# Which structural paths this run actually covered. Which one a harness takes is
# the HARNESS's choice, not this guard's, so a machine with only bare-row
# harnesses installed cannot be failed for it - but a run that saw only one path
# is not evidence about the other, and says so rather than reading as full
# coverage. The portable suites pin both paths unconditionally.
note "structural paths exercised:$PATHS_SEEN"
case " $PATHS_SEEN " in
  *" bordered-box "*) : ;;
  *) note "no installed harness drew a BORDERED composer box, so the bordered structural path is unverified by this run (tests/fm-composer-ghost.test.sh pins it portably)" ;;
esac
case " $PATHS_SEEN " in
  *" bare-row "*) : ;;
  *) note "no installed harness drew a BARE composer row, so the unbordered structural path is unverified by this run (tests/fm-composer-ghost.test.sh pins it portably)" ;;
esac

cleanup_all
trap - EXIT
