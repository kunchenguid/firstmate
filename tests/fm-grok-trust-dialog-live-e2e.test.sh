#!/usr/bin/env bash
# Token-free live drift guard for Grok's project-folder trust frame and
# Firstmate's active-versus-historical classifier.
#
# The guard launches the installed Grok with no prompt in an isolated git
# directory containing one inert project hook. It copies only the existing
# authentication file into a private throwaway GROK_HOME, never answers the
# dialog, and never changes the operator's trust store. A missing credential is
# a capability skip by default and a failure when this guard or FM_LIVE is
# explicitly forced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_GROK_TRUST_DIALOG_LIVE grok tmux git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/bin/fm-grok-trust.sh"
REAL_GROK=$(command -v grok)
REAL_TMUX=$(command -v tmux)
SOURCE_GROK_HOME=${GROK_HOME:-${HOME:-}/.grok}
REQUESTED=${FM_GROK_TRUST_DIALOG_LIVE:-${FM_LIVE:-0}}

if [ ! -s "$SOURCE_GROK_HOME/auth.json" ]; then
  if [ "$REQUESTED" = 1 ]; then
    fail "FM_GROK_TRUST_DIALOG_LIVE was requested but $SOURCE_GROK_HOME/auth.json is absent or empty"
  fi
  printf 'skip: live: grok authentication absent at %s/auth.json\n' "$SOURCE_GROK_HOME"
  exit 0
fi

LAB=$(fm_test_tmproot fm-grok-trust-live)
PROJECT="$LAB/project"
ISOLATED_HOME="$LAB/grok-home"
SOCKET="fm-grok-trust-live-$$"
SESSION="grok-trust"
CAPTURE="$LAB/active.txt"
SCROLLED="$LAB/scrolled-out.txt"
SLICE="$LAB/visible-slice.txt"
VERSION=$($REAL_GROK --version 2>&1 | head -1)

cleanup_grok_trust_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_grok_trust_live EXIT
trap 'cleanup_grok_trust_live; exit 130' INT
trap 'cleanup_grok_trust_live; exit 143' TERM

mkdir -p "$PROJECT/.grok/hooks" "$ISOLATED_HOME"
chmod 700 "$ISOLATED_HOME"
cp "$SOURCE_GROK_HOME/auth.json" "$ISOLATED_HOME/auth.json"
chmod 600 "$ISOLATED_HOME/auth.json"
git -C "$PROJECT" init -q || fail "could not initialize the isolated Grok project"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
  > "$PROJECT/.grok/hooks/fm-trust-probe.json"

# The pane below has to be the pane bin/fm-spawn.sh creates, not one this guard
# configured to suit its own arms. Grok runs on the alternate screen by default,
# where tmux keeps no history at all, so a bounded read returns the viewport and
# nothing above it and the scrolled-out arm could never fire; a guard that
# turned that option off by hand would prove the detector only for a pane no
# spawn produces. So everything this pane owes to firstmate comes from the
# production primitive, called exactly as the spawn calls it, through the
# private-socket PATH shim tests/fm-backend-tmux-smoke.test.sh already uses to
# run the real adapter against an isolated server.
SHIM="$LAB/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

spawn_configures_pane() { # <target>
  PATH="$SHIM:$PATH" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_scrollback_retain tmux "$2"
  ' fm-grok-trust-live "$ROOT" "$1"
}
pane_alternate_screen() { # <target>
  "$REAL_TMUX" -L "$SOCKET" show-options -w -A -v -t "$1" alternate-screen
}

# The spawn configures a pane that exists and launches Grok into it afterwards,
# and the option only governs a harness that has not started yet. So the launch
# waits on a trigger here rather than racing Grok's own startup for the pane:
# the ordering this depends on is then a fact of the sequence, not of who won.
LAUNCHER="$LAB/launch-grok.sh"
cat > "$LAUNCHER" <<SH
#!/usr/bin/env bash
while [ ! -e "$LAB/launch-now" ]; do sleep 0.05; done
exec env GROK_HOME='$ISOLATED_HOME' '$REAL_GROK' --always-approve
SH
chmod +x "$LAUNCHER"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 80 -y 12 -c "$PROJECT" \
  "exec $LAUNCHER" \
  || fail "could not stage $VERSION in the isolated tmux server"
# Prove the instrument before using it: a tmux configuration that had already
# disabled the alternate screen would make the production call below a no-op and
# leave every arm that follows inert, so the pane is required to start on the
# default, and the primitive is required to be what moves it off.
[ "$(pane_alternate_screen "$SESSION")" = on ] \
  || fail "the isolated Grok pane did not start on tmux's default alternate screen, so this guard would not be testing the pane a spawn creates"
spawn_configures_pane "$SESSION" \
  || fail "the production scrollback-retention primitive failed on the isolated Grok pane"
[ "$(pane_alternate_screen "$SESSION")" = off ] \
  || fail "the production scrollback-retention primitive left the isolated Grok pane on a screen that keeps no history"
: > "$LAB/launch-now"

found=0
for _ in $(seq 1 40); do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -120 > "$CAPTURE" 2>/dev/null || true
  if grep -Fq 'Do you trust the contents of this directory?' "$CAPTURE"; then
    found=1
    break
  fi
  sleep 0.1
done
[ "$found" -eq 1 ] || fail "$VERSION did not render the project-folder trust dialog"

"$CLASSIFIER" active < "$CAPTURE" \
  || fail "$VERSION rendered a trust dialog that the production classifier did not recognize"
if tail -n 2 "$CAPTURE" | "$CLASSIFIER" active; then
  fail "the classifier accepted a visible tail that omitted the active dialog"
fi
if { cat "$CAPTURE"; printf '%s\n' 'Tip: current Grok session' 'Weekly limit left: 50%'; } \
  | "$CLASSIFIER" active; then
  fail "the classifier accepted trust text followed by a newer session surface"
fi
# Something nonblank painted after the newest complete trust frame is the whole
# reason the old "nothing follows the footer" rule could not fire on a displaced
# dialog. Asserting the loop below landed on a capture that carries it is what
# stops this arm from passing against a pane the retired rule would have passed
# too: the resize is observed to push the frame out of view a beat before Grok
# repaints, and in that beat the complete frame IS the last thing the capture
# holds.
frame_is_followed() { # <bounded-capture-file>
  awk -v title="Do you trust the contents of this directory?" '
    index($0, title) { start = NR; quit = 0; footer = 0 }
    start && /No, quit[[:space:]]+n[[:space:]]*$/ { quit = NR }
    start && quit && !footer &&
      /Grok Build[[:space:]]+[0-9][^[:space:]]*[[:space:]]+\[[^]]+\][[:space:]]*$/ { footer = NR }
    /[^[:space:]]/ { last = NR }
    END { exit !(footer > 0 && last > footer) }
  ' "$1"
}

# The behavior the gate exists for: the dialog is still waiting, but the pane is
# now too short to show it. Grok repaints a clipped frame - header row and build
# footer, no title and no shortcuts - which is what pushes the complete frame
# above the visible slice in the first place. So a complete frame is never the
# last thing this capture holds, and any rule demanding that it be cannot fire
# here at all.
"$REAL_TMUX" -L "$SOCKET" resize-window -t "$SESSION" -x 80 -y 5 \
  || fail "could not shrink the isolated Grok pane below its trust frame"
# A visible slice that is no tail of its own bounded history is a pane no
# terminal geometry produces, and a verdict proven only against one proves
# nothing about a real operator's pane. The two reads below are separate tmux
# round trips, though, so a repaint landing between them pairs a slice with a
# history read of a DIFFERENT pane state - observed here as a footer row the
# slice holds and the history taken milliseconds later has already moved. That
# pair describes no pane at all, so the loop keeps polling until one settled
# pane answers both reads, and each way this can time out fails with its own
# reason rather than being asserted against a straddled pair.
displaced=0
repainted=0
settled=0
for _ in $(seq 1 40); do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -0 > "$SLICE" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -120 > "$SCROLLED" 2>/dev/null || true
  if ! grep -Fq 'Do you trust the contents of this directory?' "$SLICE" \
    && grep -Fq 'Do you trust the contents of this directory?' "$SCROLLED"; then
    displaced=1
    if frame_is_followed "$SCROLLED"; then
      repainted=1
      if [ "$(tail -n "$(wc -l < "$SLICE")" "$SCROLLED")" = "$(cat "$SLICE")" ]; then
        settled=1
        break
      fi
    fi
  fi
  sleep 0.1
done
[ "$displaced" -eq 1 ] \
  || fail "$VERSION did not push its trust frame above the visible slice of a shortened pane"
[ "$repainted" -eq 1 ] \
  || fail "$VERSION left its complete trust frame as the last content of the shortened pane, so this arm never exercised a displaced dialog the retired rule could not classify"
[ "$settled" -eq 1 ] \
  || fail "the shortened pane's visible slice never settled as the tail of its own bounded history"
"$CLASSIFIER" active < "$SCROLLED" \
  || fail "$VERSION left a trust dialog waiting above the visible slice that the production classifier did not recognize"
if "$CLASSIFIER" active < "$SLICE"; then
  fail "the classifier read the clipped visible slice alone as an active trust frame"
fi
if "$CLASSIFIER" superseded < "$SCROLLED"; then
  fail "the classifier read a clipped repaint of the waiting frame as a session that had moved past it"
fi
[ ! -e "$ISOLATED_HOME/trusted_folders.toml" ] \
  || fail "the live guard changed its isolated trust store despite never answering the dialog"

printf 'ok - %s: active trust frame recognized in view and scrolled above the visible slice; clipped and historical forms rejected\n' "$VERSION"
