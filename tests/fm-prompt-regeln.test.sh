#!/usr/bin/env bash
# tests/fm-prompt-regeln.test.sh - bin/fm-prompt-regeln.sh must stay silent on
# machine-injected input and on a missing fm-regeln, and must actually attach
# ranked rules - once as full text, and only as an id line on repeat within
# the same session - when a well-formed fm-regeln answers.
#
# Isolation: everything runs against a throwaway FM_HOME; a shims/ dir is
# prepended to PATH so a fake fm-regeln stands in without touching the repo's
# real bin/. Nothing touches the live fleet or a real VERFASSUNG.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/fm-prompt-regeln.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$TMP/shims"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

MARK=$'\xE2\x81\xA3'

# --- 1. Machine-injected prompt: silent exit 0 -----------------------------
inj_payload=$(jq -n --arg p "${MARK}FIRSTMATE_OP: v1 watcher: something" --arg s "sess-inj" \
  '{prompt: $p, session_id: $s}')
inj_out=$(printf '%s' "$inj_payload" | FM_HOME="$HOME_A" "$HOOK" 2>"$TMP/inj.err")
inj_rc=$?
if [ "$inj_rc" -eq 0 ] && [ -z "$inj_out" ] && [ ! -s "$TMP/inj.err" ]; then
  ok "an injected (U+2063 FIRSTMATE_OP) prompt produces no output and exits 0"
else
  fail "injected prompt must be silent (rc=$inj_rc out='$inj_out' err='$(cat "$TMP/inj.err")')"
fi

# --- 2. Missing fm-regeln: fail open, exit 0, no output --------------------
rm -rf "$HOME_A/state"
mkdir -p "$HOME_A/state"
normal_payload=$(jq -n --arg p "how do orders get recorded" --arg s "sess-missing" \
  '{prompt: $p, session_id: $s}')
PATH_NO_FMREGELN="/usr/bin:/bin"
missing_out=$(printf '%s' "$normal_payload" | FM_HOME="$HOME_A" FM_REGELN_BIN="$TMP/kein-fm-regeln" PATH="$PATH_NO_FMREGELN" "$HOOK" 2>"$TMP/missing.err")
missing_rc=$?
if [ "$missing_rc" -eq 0 ] && [ -z "$missing_out" ]; then
  ok "a missing fm-regeln fails open with exit 0 and no stdout"
else
  fail "missing fm-regeln must fail open (rc=$missing_rc out='$missing_out')"
fi
if grep -qF 'WRIT_FM: MISSING' "$TMP/missing.err"; then
  ok "a missing fm-regeln prints the one-time MISSING diagnostic"
else
  fail "expected the WRIT_FM: MISSING diagnostic on stderr"
fi
[ -e "$HOME_A/state/writ-fm/.missing-notified" ] || fail "missing-notified sentinel must be written"

# second call must not repeat the diagnostic
printf '%s' "$normal_payload" | FM_HOME="$HOME_A" FM_REGELN_BIN="$TMP/kein-fm-regeln" PATH="$PATH_NO_FMREGELN" "$HOOK" >/dev/null 2>"$TMP/missing2.err"
if [ ! -s "$TMP/missing2.err" ]; then
  ok "the MISSING diagnostic does not repeat once the sentinel exists"
else
  fail "the MISSING diagnostic must not repeat: $(cat "$TMP/missing2.err")"
fi

# --- 3 & 4. Mocked fm-regeln: full text once, id-only on repeat ------------
rm -rf "$HOME_A/state"
mkdir -p "$HOME_A/state"
cat > "$TMP/shims/fm-regeln" <<'SHIM'
#!/usr/bin/env bash
cat <<'RULES'
{"id":"R12","text":"Every captain word becomes a durable record."}
RULES
SHIM
chmod +x "$TMP/shims/fm-regeln"
PATH_WITH_SHIM="$TMP/shims:/usr/bin:/bin"

rule_payload=$(jq -n --arg p "what happens to a captain decision" --arg s "sess-1" \
  '{prompt: $p, session_id: $s}')

first_out=$(printf '%s' "$rule_payload" | FM_HOME="$HOME_A" FM_REGELN_BIN="$TMP/shims/fm-regeln" PATH="$PATH_WITH_SHIM" "$HOOK" 2>"$TMP/first.err")
first_rc=$?
first_ctx=$(printf '%s' "$first_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if [ "$first_rc" -eq 0 ] && printf '%s' "$first_ctx" | grep -qF 'R12' \
   && printf '%s' "$first_ctx" | grep -qF 'Every captain word becomes a durable record.'; then
  ok "a normal prompt with a mocked fm-regeln attaches the rule as additionalContext"
else
  fail "expected R12 with full text in additionalContext (rc=$first_rc out='$first_out')"
fi
printf '%s' "$first_out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1 \
  || fail "additionalContext must be wrapped in the UserPromptSubmit hookSpecificOutput contract"

second_out=$(printf '%s' "$rule_payload" | FM_HOME="$HOME_A" FM_REGELN_BIN="$TMP/shims/fm-regeln" PATH="$PATH_WITH_SHIM" "$HOOK" 2>"$TMP/second.err")
second_ctx=$(printf '%s' "$second_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if printf '%s' "$second_ctx" | grep -qF 'R12' \
   && ! printf '%s' "$second_ctx" | grep -qF 'Every captain word becomes a durable record.'; then
  ok "the second call in the same session repeats only the rule id, not the full text"
else
  fail "second call must be id-only for R12 (ctx='$second_ctx')"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all fm-prompt-regeln checks passed"
