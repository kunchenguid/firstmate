#!/usr/bin/env bash
# Unit test for the wave-scoped poll cadence in bin/fm-watch.sh.
#
# The contract: with FM_IDLE_POLL set above the fast poll cadence, a cycle in
# which no crew pane shows a busy signature waits on the slow cadence, and a
# cycle in which one does shows live work waits on the fast cadence. The
# shipped default (no FM_IDLE_POLL, no tuning file) changes nothing.
#
# Every probe runs the real bin/fm-watch.sh in its own environment, so the
# assertions are about the script's behavior, never about its source text.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config" "$TMP/state" "$TMP/data"

# probe <config-dir> -> prints three lines:
#   <FM_IDLE_POLL> <FM_WEDGE_MAX_ESCALATIONS>
#   <poll seconds with an idle fleet>
#   <poll seconds with a busy fleet>
# shellcheck disable=SC2016 # The inner script must reach bash -c unexpanded.
probe() {
  env FM_HOME="$TMP" \
      FM_CONFIG_OVERRIDE="$1" \
      FM_STATE_OVERRIDE="$TMP/state" \
      FM_POLL=15 \
      bash -c '. "$1"
        printf "%s %s\n" "${FM_IDLE_POLL:-0}" "${FM_WEDGE_MAX_ESCALATIONS:-0}"
        printf "%s\n" "$(supervision_poll_seconds)"
        _fleet_busy=1
        printf "%s\n" "$(supervision_poll_seconds)"
      ' _ "$ROOT/bin/fm-watch.sh"
}

# 1. Without a tuning file the shipped cadence is unchanged.
out=$(probe "$TMP/nowhere")
idle=$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f1)
cap=$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f2)
fast=$(printf '%s\n' "$out" | sed -n '2p')
[ "$idle" = 0 ] || fail "without a tuning file the idle cadence is on: $idle"
[ "$cap" = 0 ] || fail "without a tuning file the wedge cap moved: $cap"
[ "$fast" = 15 ] || fail "without a tuning file the cadence changed: $fast"
ok "without a tuning file the shipped cadence is unchanged"

# 2. A tuning file reaches the watcher and switches the idle cadence on.
cat > "$TMP/config/supervision-tuning" <<'EOF'
idle_poll_secs=300
wedge_max_escalations=2
EOF
out=$(probe "$TMP/config")
idle=$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f1)
cap=$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f2)
slow=$(printf '%s\n' "$out" | sed -n '2p')
busy=$(printf '%s\n' "$out" | sed -n '3p')
[ "$idle" = 300 ] || fail "the tuning file did not reach the watcher: $idle"
[ "$cap" = 2 ] || fail "the wedge cap did not reach the watcher: $cap"
[ "$slow" = 300 ] || fail "an idle fleet did not get the slow cadence: $slow"
[ "$busy" = 15 ] || fail "a live crew did not get the fast cadence: $busy"
ok "an idle fleet waits on the slow cadence, a live crew on the fast one"

# 3. Every beacon-age reader derives the same default grace from the EFFECTIVE
# poll, not the fast poll: with idle_poll_secs=1800 the no-argument derivation
# (what the hook readers use) must equal the watcher's own max(300, 1860), and
# the stall bound must grow with it - or the arm and hooks evict a healthy
# slow watcher. An unset FM_HOME must be ignored, not read.
# shellcheck disable=SC2016
out=$(env FM_POLL=15 FM_CONFIG_OVERRIDE="$TMP/config" bash -c '
  . "$1"
  mkdir -p "$2"
  printf "idle_poll_secs=1800\n" > "$2/supervision-tuning"
  grace=$(fm_poll_derived_grace)
  bound=$(fm_watcher_stall_bound)
  unset FM_HOME
  grace_unsets=$(fm_poll_derived_grace)
  printf "%s %s %s\n" "$grace" "$bound" "$grace_unsets"
' _ "$ROOT/bin/fm-wake-lib.sh" "$TMP/config")
grace=$(printf '%s\n' "$out" | cut -d' ' -f1)
bound=$(printf '%s\n' "$out" | cut -d' ' -f2)
grace_unsets=$(printf '%s\n' "$out" | cut -d' ' -f3)
[ "$grace" = 1860 ] || fail "the hook-side grace used the fast poll, not the effective cadence: $grace"
[ "$bound" = 5580 ] || fail "the stall bound did not grow with the effective cadence: $bound"
[ "$grace_unsets" = 1860 ] || fail "an unset FM_HOME changed the derived grace: $grace_unsets"
ok "hook-side grace and stall bound derive from the same effective cadence the watcher waits on"

echo "PASS: fm-watch-idle-cadence"
