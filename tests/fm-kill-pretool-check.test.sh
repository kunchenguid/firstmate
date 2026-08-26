#!/usr/bin/env bash
# tests/fm-kill-pretool-check.test.sh - the AGENTS.md HR3' kill TOR must
# actually deny a broad-pattern or unowned kill, and only when armed.
#
#   1. Scharfschalt-Flag: with state/.tor-kill-scharf ABSENT, every one of the
#      denyable commands below allows instead (ROT-without-condition proven,
#      matching the GRUEN-with-condition proof further down).
#   2. With the flag present:
#      - an owned pid (registered via fm-owned.sh) allows;
#      - an unowned/unregistered pid denies, citing HR3' and the escape hatch;
#      - `pkill -f` and `killall` deny unconditionally, even for a pattern
#        that happens to match nothing owned-related;
#      - an env-var prefix (`X=1 kill <unowned>`) does not evade the deny;
#      - a simple chain (`echo hi && kill <unowned>`) still denies;
#      - FM_KILL_FREMD='<reason>' as a literal command prefix allows the
#        denied kill through AND is recorded via fm_tor_log (verified against
#        a stub lib through FM_TOR_LOG_LIB_OVERRIDE, since the real
#        bin/fm-tor-log-lib.sh is a separate, not-yet-landed change).
#      - a plain, unrelated command (no kill/pkill/killall) allows.
#   3. Fail-open: malformed/non-JSON stdin allows rather than blocking the
#      turn, even with the flag armed.
#
# Isolation: throwaway FM_HOME; the flag and owned files live only under it.
# Nothing touches the real fleet state or any real process.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/fm-kill-pretool-check.sh"
OWNED="$REPO/bin/fm-owned.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"
FLAG="$HOME_A/state/.tor-kill-scharf"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

guard() { FM_HOME="$HOME_A" "$GUARD" "$@"; }
owned() { FM_HOME="$HOME_A" "$OWNED" "$@"; }

owned add taska pid 4242 >/dev/null

# --- 1. flag absent: every denyable command allows instead -----------------
[ ! -f "$FLAG" ] || fail "test setup: flag must not pre-exist"
for cmd in "pkill -f something" "killall node" "kill 5555" \
           "FM_KILL_FREMD='x' kill 5555"; do
  if guard --command "$cmd" >/dev/null 2>&1; then
    :
  else
    fail "without the scharf-flag, '$cmd' must allow (rc should be 0)"
  fi
done
ok "every otherwise-denyable command allows while the scharf-flag is absent"

# --- arm the flag ------------------------------------------------------------
touch "$FLAG"

# --- 2. armed: owned pid allows ---------------------------------------------
if guard --command "kill 4242"; then
  ok "an owned pid allows"
else
  fail "kill of an owned pid must allow once armed"
fi

# --- unowned pid denies, citing HR3' and the escape hatch -------------------
out="$(guard --command "kill 5555" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an unowned pid denies (exit 2)"
else
  fail "kill of an unowned pid must deny with exit 2 (got rc=$rc)"
fi
printf '%s' "$out" | grep -qF "HR3'" || fail "deny message must cite HR3'"
printf '%s' "$out" | grep -q "kill targets outside registered ownership are refused" \
  || fail "deny message must quote the current AGENTS.md HR3' source wording"
printf '%s' "$out" | grep -q "FM_KILL_FREMD='<reason>'" \
  || fail "deny message must spell out the FM_KILL_FREMD escape hatch verbatim"
ok "deny message carries the source quote and the named escape hatch"

# --- pkill -f and killall deny unconditionally ------------------------------
if guard --command "pkill -f anything"; then
  fail "'pkill -f' must always deny"
else
  ok "'pkill -f' always denies"
fi
if guard --command "killall somename"; then
  fail "'killall' must always deny"
else
  ok "'killall' always denies"
fi

# --- env-prefix evasion does not work ---------------------------------------
if guard --command "X=1 kill 5555"; then
  fail "an env-var prefix must not evade the deny for an unowned pid"
else
  ok "env-var prefix (X=1 kill <unowned>) still denies"
fi

# --- a simple chain still denies --------------------------------------------
if guard --command "echo hi && kill 5555"; then
  fail "a chained unowned kill must still deny"
else
  ok "a chained command (echo hi && kill <unowned>) still denies"
fi

# --- FM_KILL_FREMD escape hatch allows, and is logged -----------------------
CAPTURE="$TMP/tor-log-capture.tsv"
STUB="$TMP/stub-tor-log-lib.sh"
cat > "$STUB" <<STUBEOF
fm_tor_log() { printf '%s\t%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\$4" "\$5" >> "$CAPTURE"; }
STUBEOF
if FM_HOME="$HOME_A" FM_TOR_LOG_LIB_OVERRIDE="$STUB" \
    "$GUARD" --command "FM_KILL_FREMD='captain approved cleanup' kill 5555"; then
  ok "FM_KILL_FREMD='<reason>' allows the otherwise-denied kill"
else
  fail "FM_KILL_FREMD='<reason>' must allow the otherwise-denied kill"
fi
[ -f "$CAPTURE" ] || fail "the escaped kill must call fm_tor_log at least once"
grep -qF "$(printf "kill\tHR3'\twarn\tcaptain approved cleanup\t")" "$CAPTURE" \
  && ok "fm_tor_log is called with tor=kill regel-id=HR3' verdikt=warn and the reason as ausweg-genutzt" \
  || fail "fm_tor_log must be called with the documented signature and the captain's reason (got: $(cat "$CAPTURE" 2>/dev/null))"

# --- an ordinary, unrelated command allows ----------------------------------
if guard --command "echo hello world"; then
  ok "an ordinary command with no kill/pkill/killall allows"
else
  fail "an ordinary command must allow"
fi

# --- 3. fail-open on malformed stdin, even armed ----------------------------
if printf 'not json at all' | FM_HOME="$HOME_A" "$GUARD" >/dev/null 2>&1; then
  ok "malformed/non-JSON stdin allows (fail-open) even with the flag armed"
else
  fail "malformed stdin must fail open (allow), not deny"
fi
if printf '' | FM_HOME="$HOME_A" "$GUARD" >/dev/null 2>&1; then
  ok "empty stdin allows (fail-open)"
else
  fail "empty stdin must fail open (allow)"
fi

# --- proper JSON transport still denies (both Grok- and Claude-shaped keys) -
json_out="$(printf '{"tool_input":{"command":"kill 5555"}}' | FM_HOME="$HOME_A" "$GUARD" 2>/dev/null)"
json_rc=$?
if [ "$json_rc" -eq 2 ]; then
  ok "Claude-shaped stdin JSON (.tool_input.command) is classified and denied"
else
  fail "Claude-shaped stdin JSON must deny an unowned kill (got rc=$json_rc)"
fi
printf '%s' "$json_out" | grep -q '"decision":"deny"' \
  && ok "stdout carries the Grok-shaped deny object by default" \
  || fail "stdout must carry the Grok-shaped deny object without --claude"

printf '{"toolInput":{"command":"kill 5555"}}' | FM_HOME="$HOME_A" "$GUARD" >/dev/null 2>&1
grok_rc=$?
[ "$grok_rc" -eq 2 ] \
  && ok "Grok-shaped stdin JSON (.toolInput.command) is classified and denied" \
  || fail "Grok-shaped stdin JSON must deny an unowned kill (got rc=$grok_rc)"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all fm-kill-pretool-check checks passed"
