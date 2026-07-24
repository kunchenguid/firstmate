#!/usr/bin/env bash
# tests/fm-afk-crosshome-isolation.test.sh - the away-mode daemon must never
# inject one firstmate home's supervisor escalation into ANOTHER home's pane when
# both homes share one tmux server.
#
# The incident (afk-crosshome-inject-leak): two homes shared one tmux server, and
# a home running under a non-tmux primary (Codex) resolved its supervisor target
# to the home-agnostic literal fallback "firstmate:0", which on the shared server
# pointed at the OTHER home's firstmate pane. Its away daemon then injected its
# escalation digest into that foreign session. Nothing verified home ownership
# before injecting.
#
# The fix has two layers, both asserted here:
#   1. Injection hard floor - supervisor_target_home_ok compares the target tmux
#      session's @firstmate-home stamp (the SAME stamp a31df6e added for crew
#      sessions) against this home's physical FM_HOME and refuses on any mismatch,
#      missing stamp, or unreadable target. This is the last gate before typing,
#      so it catches a wrong target even if resolution was fooled.
#   2. Home-scoped fallback - supervisor_target_default / discover_supervisor_target
#      name the tmux fallback session after FM_HOME's basename instead of a bare
#      "firstmate", so the fallback stays inside this home.
#
# The refuse path is fully deterministic: the ownership guard returns before any
# send-keys, so the foreign pane is provably never typed into regardless of
# composer timing. The same-home ALLOW path is confirmed at the guard level (also
# deterministic) and, when the environment can drive a real tmux composer, end to
# end through escalate_flush.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="xhome-$$"
TMP_DIRS=()
SHIM_DIR=
PANE_A=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "${SHIM_DIR:-}" 2>/dev/null || true
  local d
  for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done
}
trap cleanup_all EXIT

mk_dir() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/fm-xhome.XXXXXX"); TMP_DIRS+=("$d"); ( cd "$d" && pwd -P ); }

# Source the daemon's pure functions (its main loop is guarded off under sourcing)
# to reach inject_msg / escalate_flush / supervisor_target_home_ok directly.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

# Two physical home dirs, resolved (a31df6e / the guard compare on physical paths).
HOME_A=$(mk_dir); HOME_B=$(mk_dir)
STATE_B="$HOME_B/state"; mkdir -p "$STATE_B"

# A composer loop that logs each submitted line with its classification, so we can
# prove exactly what (if anything) was typed into a pane. Shared with the afk
# inject e2e's model.
LOOP="$HOME_A/loop.pl"
LOG_A="$HOME_A/submitted.log"; : > "$LOG_A"
cat > "$LOOP" <<'LOOP'
#!/usr/bin/env perl
use strict; use warnings; use bytes;
$| = 1;
my $mark = "\xe2\x81\xa3";
my $log = shift @ARGV;
my $old = `stty -g 2>/dev/null`; chomp $old;
system('stty','-echo','-icanon','min','1','time','0') if $old ne '';
$SIG{INT} = $SIG{TERM} = sub { system('stty',$old) if $old ne ''; exit 0; };
END { system('stty',$old) if defined $old && $old ne ''; }
binmode STDIN; binmode STDOUT;
my $buf = '';
sub redraw { print "\r\033[K$buf"; }
sub submit {
  my $class = substr($buf,0,length($mark)) eq $mark ? 'injection' : 'user';
  open my $fh,'>>',$log or die $!; binmode $fh;
  print {$fh} unpack('H*',$buf)."\t$buf\t$class\n"; close $fh;
  $buf=''; print "\r\033[K\n"; redraw();
}
redraw();
while (sysread(STDIN,my $ch,1)) {
  if ($ch eq "\r" || $ch eq "\n") { submit(); }
  elsif ($ch eq "\177" || $ch eq "\b") { chop $buf; redraw(); }
  else { $buf .= $ch; redraw(); }
}
LOOP
chmod +x "$LOOP"

# ONE shared tmux server, TWO home sessions - exactly the incident topology.
# Session "home-a" is home A's firstmate pane (a real agent-like composer, not a
# shell, so the login-shell guard is not what stops a cross-home inject). Session
# "home-b" is home B's own pane. Each session is stamped with its owner's physical
# home, the same @firstmate-home stamp crew sessions carry.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s home-a -x 200 -y 50 "perl '$LOOP' '$LOG_A'"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s home-b -x 200 -y 50 "perl '$LOOP' '$HOME_B/b.log'"
PANE_A=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t home-a '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" set-option -t home-a "$FM_SUPERVISOR_HOME_OPT" "$HOME_A"
"$REAL_TMUX" -L "$SOCKET" set-option -t home-b "$FM_SUPERVISOR_HOME_OPT" "$HOME_B"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s unowned -x 200 -y 50 "perl '$LOOP' '$HOME_A/u.log'"
PANE_U=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t unowned '#{pane_id}')
sleep 1

# Shim so the daemon's bare `tmux` reaches the private socket.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-xhome-shim.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM_DIR/tmux"

# --- Layer 2: home-scoped fallback target -----------------------------------
test_fallback_is_home_scoped() {
  local out base
  base=${HOME_A##*/}
  out=$(FM_HOME="$HOME_A" supervisor_target_default)
  [ "$out" = "$base:0" ] || fail "supervisor_target_default not home-scoped: got '$out', want '$base:0'"
  # An unresolvable home degrades to the legacy literal, never crashes.
  out=$(FM_HOME="$HOME_A/does-not-exist" supervisor_target_default)
  [ "$out" = "firstmate:0" ] || fail "unresolvable home should fall back to the literal: got '$out'"
  # discover's bare fallback (no override, no TMUX_PANE, no herdr) is home-scoped.
  out=$(FM_HOME="$HOME_A" FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
    discover_supervisor_target) && fail "bare fallback should return non-zero (unresolved)"
  [ "$out" = "$base:0" ] || fail "discover_supervisor_target bare fallback not home-scoped: got '$out'"
  pass "home-scoped fallback: supervisor_target_default and discover fall back to <home-basename>:0, not a bare firstmate:0"
}

# --- Layer 1: injection ownership guard (real tmux stamps) -------------------
test_ownership_guard_matches_stamp() {
  # Home A injecting into its OWN stamped pane: allowed.
  PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_A" supervisor_target_home_ok tmux "$PANE_A" \
    || fail "guard refused home A's own stamped pane"
  # Home B injecting into home A's pane (the incident): refused.
  if PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_B" supervisor_target_home_ok tmux "$PANE_A"; then
    fail "guard ALLOWED home B to target home A's pane (cross-home leak)"
  fi
  # An unstamped session is not provably ours: refused (fail closed).
  if PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_A" supervisor_target_home_ok tmux "$PANE_U"; then
    fail "guard allowed an unstamped session (must fail closed)"
  fi
  # herdr targets are first-party by construction: allowed without a tmux stamp.
  FM_HOME="$HOME_A" supervisor_target_home_ok herdr "default:w1:p2" \
    || fail "guard should allow a herdr target (owned by construction)"
  pass "ownership guard: allows own-stamp, refuses foreign-stamp, refuses unstamped, allows herdr"
}

# --- The incident, end to end through escalate_flush ------------------------
# Home B's away daemon, afk active, with the exact escalation kind from the
# incident, resolves its target to home A's pane (as the shared-server fallback
# did) and flushes. It MUST refuse and leave home A's pane untouched.
test_crosshome_flush_refuses_and_never_types() {
  : > "$LOG_A"
  local logf="$STATE_B/.supervise-daemon.log"; : > "$logf"
  afk_enter "$STATE_B"
  escalate_add "$STATE_B" "voice-tts-server-151.status: done: ready"
  escalate_add "$STATE_B" "voice-tts-client.status: done: shipped"
  if PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_B" LOG="$logf" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$PANE_A" \
    FM_ESCALATE_BATCH_SECS=0 FM_INJECT_CONFIRM_SLEEP=0.1 \
    escalate_flush "$STATE_B"; then
    fail "escalate_flush from home B succeeded against home A's pane (cross-home leak)"
  fi
  # The foreign pane was NEVER typed into.
  [ ! -s "$LOG_A" ] || fail "home B's escalation reached home A's pane: $(cat "$LOG_A")"
  # Home B's buffer is preserved for its own catch-up, not silently dropped.
  grep -F "voice-tts-server-151" "$STATE_B/.subsuper-escalations" >/dev/null \
    || fail "home B's escalation buffer was not preserved after the refusal"
  # The refusal is loud and names the reason.
  grep -F "not owned by this firstmate home" "$logf" >/dev/null \
    || fail "daemon did not log the cross-home injection refusal"
  afk_exit "$STATE_B"
  pass "cross-home: home B's away daemon refuses to inject into home A's pane, never types, preserves its own buffer"
}

# --- Control: the same-home inject still works end to end (env permitting) ---
# Proves the guard does not over-block a legitimate own-home injection. Gated by a
# composer self-check so a CI that cannot drive a real tmux composer skips only
# this end-to-end leg (the guard-level ALLOW is already asserted above).
composer_selfcheck() {
  local probe="xhome-selfcheck-9271" i=0
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE_A" -l "$probe"
  while [ "$i" -lt 20 ]; do
    [ "$(PATH="$SHIM_DIR:$PATH" fm_backend_composer_state tmux "$PANE_A" 2>/dev/null)" = pending ] && {
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE_A" Enter; sleep 0.3; : > "$LOG_A"; return 0; }
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

test_samehome_flush_delivers() {
  if ! composer_selfcheck; then
    echo "ok - (skipped end-to-end same-home delivery: this environment cannot drive a real tmux composer; guard-level ALLOW already asserted)"
    return 0
  fi
  : > "$LOG_A"
  local state_a="$HOME_A/state"; mkdir -p "$state_a"
  local logf="$state_a/.supervise-daemon.log"; : > "$logf"
  afk_enter "$state_a"
  escalate_add "$state_a" "own-home.status: done: PR https://example/pull/7"
  PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_A" LOG="$logf" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$PANE_A" \
    FM_ESCALATE_BATCH_SECS=0 FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=5 \
    escalate_flush "$state_a" \
    || fail "same-home escalate_flush failed against home A's own pane"
  local i=0
  while [ "$i" -lt 20 ]; do grep -F 'injection' "$LOG_A" >/dev/null && break; sleep 0.2; i=$((i + 1)); done
  grep -F 'injection' "$LOG_A" >/dev/null \
    || fail "same-home injection did not reach home A's own pane"
  [ ! -s "$state_a/.subsuper-escalations" ] || fail "buffer not cleared after a successful same-home flush"
  afk_exit "$state_a"
  pass "same-home: home A's away daemon delivers its escalation into its own pane and clears the buffer"
}

test_fallback_is_home_scoped
test_ownership_guard_matches_stamp
test_crosshome_flush_refuses_and_never_types
test_samehome_flush_delivers

echo "all cross-home isolation checks passed"
