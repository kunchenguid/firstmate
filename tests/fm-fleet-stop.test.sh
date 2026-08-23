#!/usr/bin/env bash
# tests/fm-fleet-stop.test.sh - the captain-ordered fleet stop must actually stop
# the machinery. Covers the three enforcement surfaces plus the CLI contract:
#
#   1. CLI: `set` refuses without an explicit wording; set/status/lift round-trip
#      with the documented file contract (line 1 `set=<utc>`, wording after it).
#   2. Spawn gate: with the flag present, bin/fm-spawn.sh refuses BEFORE argument
#      validation; without the flag the same call fails differently (divergence
#      asserted so the case cannot go vacuous).
#   3. Bootstrap sweeps: with the flag present, all four mutating network sweeps
#      stand down with an explanatory line; without it none of those lines print.
#   4. Banner: a detect-only bootstrap run prints the FLEET_STOP banner iff the
#      flag exists.
#
# Isolation: everything runs against a throwaway FM_HOME; a `gh` shim keeps the
# network-phase auth probe off the real network. Nothing touches the live fleet.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$HOME_A/data" "$HOME_A/config" "$HOME_A/projects" "$TMP/shims"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/shims/gh"
chmod +x "$TMP/shims/gh"
PATH="$TMP/shims:$PATH"
FLAG="$HOME_A/state/.fleet-stop"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# --- 1. CLI contract -------------------------------------------------------
if FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --wortlaut "" >/dev/null 2>&1; then
  fail "set without wording must refuse"
else
  ok "set refuses an empty wording"
fi
[ ! -f "$FLAG" ] || fail "refused set must not create the flag"

if ! FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --wortlaut "Alle Heime alles stoppen." >/dev/null; then
  fail "set with wording must succeed"
fi
[ -f "$FLAG" ] || fail "set must create the flag file"
head -1 "$FLAG" | grep -q '^set=20' || fail "flag line 1 must carry set=<utc timestamp>"
grep -qF "Alle Heime alles stoppen." "$FLAG" || fail "flag must carry the verbatim wording"
ok "set writes the documented file contract"

if FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status | grep -q ACTIVE; then
  ok "status reports ACTIVE while the flag exists"
else
  fail "status must report ACTIVE and exit 0 while the flag exists"
fi

# --- 2. Spawn gate ---------------------------------------------------------
spawn_out=$(FM_HOME="$HOME_A" "$REPO/bin/fm-spawn.sh" some-task /nowhere 2>&1)
spawn_rc=$?
if [ "$spawn_rc" -ne 0 ] && printf '%s' "$spawn_out" | grep -q "fleet stop active"; then
  ok "spawn refuses with the fleet-stop reason while the flag exists"
else
  fail "spawn must refuse naming the fleet stop (rc=$spawn_rc out=$spawn_out)"
fi

# --- 3. Mutating sweeps stand down ----------------------------------------
sweeps_on=$(FM_HOME="$HOME_A" FM_BOOTSTRAP_NETWORK=only "$REPO/bin/fm-bootstrap.sh" 2>&1)
for label in 'dead-secondmate relaunch' 'secondmate convergence' 'pending handoff delivery' 'project clone refresh'; do
  printf '%s\n' "$sweeps_on" | grep -qF "fleet stop active, so '$label' stood down" \
    || fail "network run must stand down '$label' under the flag"
done
ok "all four mutating network sweeps stand down under the flag"

# --- 4. Banner and divergence without the flag -----------------------------
banner_on=$(FM_HOME="$HOME_A" FM_BOOTSTRAP_DETECT_ONLY=1 "$REPO/bin/fm-bootstrap.sh" 2>&1)
printf '%s\n' "$banner_on" | grep -q '^FLEET_STOP: active since ' \
  && ok "detect-only run prints the FLEET_STOP banner" \
  || fail "detect-only run must print the FLEET_STOP banner"

FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" lift >/dev/null || fail "lift must succeed"
[ ! -f "$FLAG" ] || fail "lift must remove the flag"
if FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status >/dev/null 2>&1; then
  fail "status must exit nonzero without the flag"
else
  ok "status exits nonzero without the flag"
fi

spawn_out2=$(FM_HOME="$HOME_A" "$REPO/bin/fm-spawn.sh" some-task /nowhere 2>&1)
if printf '%s' "$spawn_out2" | grep -q "fleet stop active"; then
  fail "without the flag, spawn must not name the fleet stop"
else
  ok "spawn failure diverges once the flag is lifted (different refusal)"
fi

sweeps_off=$(FM_HOME="$HOME_A" FM_BOOTSTRAP_NETWORK=only "$REPO/bin/fm-bootstrap.sh" 2>&1)
if printf '%s\n' "$sweeps_off" | grep -q "fleet stop active, so"; then
  fail "without the flag, no sweep may claim a fleet stop"
else
  ok "sweeps run normally once the flag is lifted"
fi
banner_off=$(FM_HOME="$HOME_A" FM_BOOTSTRAP_DETECT_ONLY=1 "$REPO/bin/fm-bootstrap.sh" 2>&1)
if printf '%s\n' "$banner_off" | grep -q '^FLEET_STOP:'; then
  fail "without the flag, no FLEET_STOP banner may print"
else
  ok "banner absent once the flag is lifted"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all fleet-stop checks passed"
