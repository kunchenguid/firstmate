#!/usr/bin/env bash
# tests/fm-redact-lib.test.sh - bin/fm-redact-lib.sh must actually keep a
# registered secret value out of any text it touches:
#
#   1. fm_redact replaces a registered value with [GEHEIM:<name>], leaves
#      unrelated text and the trailing newline untouched, and - when two
#      registered values overlap as substrings - redacts the LONGER one
#      first so no fragment of it survives the shorter one's pass.
#   2. fm_redact_check exits 0 and prints nothing when no registered value is
#      present, and exits 1 naming the value's registered name on stderr
#      (never the value itself) when one is.
#   3. An absent or empty state/secrets/ directory is passthrough for both
#      functions: fm_redact returns the input byte-for-byte, fm_redact_check
#      always exits 0.
#   4. fm-redact-lib.sh resolves the same secrets directory bin/fm-secret.sh
#      writes to (same FM_HOME/FM_STATE_OVERRIDE precedence), so a secret put
#      via the real script is what gets redacted here.
#
# Isolation: everything runs against a throwaway FM_HOME, in a bash -c child
# so each case gets a clean environment. Nothing touches the live fleet.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET="$REPO/bin/fm-secret.sh"
LIB="$REPO/bin/fm-redact-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

put() { printf '%s' "$2" | FM_HOME="$HOME_A" "$SECRET" put "$1" >/dev/null; }

# call_redact <stdin-text> : runs fm_redact against HOME_A, echoes the result.
# $(...) capture at the CALL SITE would silently strip a trailing newline
# before a caller could ever see it, so trailing-newline preservation is
# instead checked via call_redact_to_file below, never through this one.
call_redact() {
  printf '%s' "$1" | FM_HOME="$HOME_A" bash -c ". \"$LIB\"; fm_redact"
}

# call_redact_to_file <stdin-text> <out-file> : same as call_redact, but writes
# the byte-exact result to a file instead of returning it through $(...), so
# trailing newlines survive for a `cmp`/`wc -c` check.
call_redact_to_file() {
  printf '%s' "$1" | FM_HOME="$HOME_A" bash -c ". \"$LIB\"; fm_redact" > "$2"
}

# call_redact_check <stdin-text> : runs fm_redact_check, echoes "<rc> <stderr>"
call_redact_check() {
  local rc err
  err="$(printf '%s' "$1" | FM_HOME="$HOME_A" bash -c ". \"$LIB\"; fm_redact_check" 2>&1 1>/dev/null)"
  rc=$?
  printf '%s\t%s' "$rc" "$err"
}

put apitoken "sup3r-s3cr3t!"
put apitoken2 "sup3r-s3cr3t!-extended"

# --- 1. fm_redact replaces, preserves the rest, longest value wins ---------
out="$(call_redact $'log line: token=sup3r-s3cr3t!-extended and short=sup3r-s3cr3t!\nsecond line\n')"
case "$out" in
  *"[GEHEIM:apitoken2]"*) ok "fm_redact replaces the longer overlapping value with its own marker" ;;
  *) fail "fm_redact must replace the longer value (got: $out)" ;;
esac
case "$out" in
  *"[GEHEIM:apitoken2]-extended"*|*"sup3r-s3cr3t!-extended"*)
    fail "fm_redact left a fragment of the longer value exposed (got: $out)" ;;
  *) ok "fm_redact leaves no fragment of the longer value behind" ;;
esac
case "$out" in
  *"log line: token="*) ok "fm_redact preserves surrounding text" ;;
  *) fail "fm_redact must preserve surrounding text (got: $out)" ;;
esac
multiline_in=$'log line: token=sup3r-s3cr3t!-extended and short=sup3r-s3cr3t!\nsecond line\n'
multiline_out="$TMP/multiline.out"
call_redact_to_file "$multiline_in" "$multiline_out"
in_bytes=$(printf '%s' "$multiline_in" | wc -c)
out_bytes=$(wc -c < "$multiline_out")
# each occurrence of a secret value is replaced by its own marker; the byte
# delta is therefore exactly known.
val1="sup3r-s3cr3t!-extended"; marker1="[GEHEIM:apitoken2]"
val2="sup3r-s3cr3t!"; marker2="[GEHEIM:apitoken]"
expected_delta=$(( (${#marker1} - ${#val1}) + (${#marker2} - ${#val2}) ))
[ "$out_bytes" -eq "$((in_bytes + expected_delta))" ] \
  || fail "fm_redact must preserve every byte outside the redacted spans, incl. the trailing newline (in=$in_bytes out=$out_bytes expected_delta=$expected_delta)"
[ -z "$(tail -c1 "$multiline_out")" ] \
  || fail "fm_redact must preserve the input's trailing newline"
grep -qF "second line" "$multiline_out" || fail "fm_redact must preserve later lines"
ok "fm_redact preserves multi-line text and the trailing newline"

out2="$(call_redact "no secrets in here")"
[ "$out2" = "no secrets in here" ] || fail "fm_redact must leave text with no registered value untouched"

# --- 2. fm_redact_check ------------------------------------------------------
result="$(call_redact_check "clean text, nothing to see")"
rc="${result%%$'\t'*}"
[ "$rc" -eq 0 ] || fail "fm_redact_check must exit 0 on clean text (rc=$rc)"
ok "fm_redact_check exits 0 on clean text"

result="$(call_redact_check "leaked: sup3r-s3cr3t!")"
rc="${result%%$'\t'*}"
err="${result#*$'\t'}"
[ "$rc" -eq 1 ] || fail "fm_redact_check must exit 1 when a registered value is present (rc=$rc)"
printf '%s' "$err" | grep -qF "apitoken" || fail "fm_redact_check must name the registered secret on stderr"
printf '%s' "$err" | grep -qF "sup3r-s3cr3t!" && fail "fm_redact_check must never print the value itself"
ok "fm_redact_check exits 1 and names the secret, never the value"

# --- 3. empty/absent secrets dir is passthrough -----------------------------
EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"
empty_out="$(printf 'plain text unchanged' | FM_HOME="$EMPTY_HOME" bash -c ". \"$LIB\"; fm_redact")"
[ "$empty_out" = "plain text unchanged" ] \
  || fail "fm_redact must pass text through unchanged with no secrets directory"
ok "fm_redact passes through unchanged when state/secrets/ is absent"

empty_rc="$(printf 'plain text' | FM_HOME="$EMPTY_HOME" bash -c ". \"$LIB\"; fm_redact_check"; echo $?)"
[ "$(printf '%s' "$empty_rc" | tail -1)" = "0" ] \
  || fail "fm_redact_check must exit 0 with no secrets directory"
ok "fm_redact_check exits 0 when state/secrets/ is absent"

mkdir -p "$EMPTY_HOME/state/secrets"
empty_dir_out="$(printf 'still unchanged' | FM_HOME="$EMPTY_HOME" bash -c ". \"$LIB\"; fm_redact")"
[ "$empty_dir_out" = "still unchanged" ] \
  || fail "fm_redact must pass text through unchanged with an empty secrets directory"
ok "fm_redact passes through unchanged when state/secrets/ exists but is empty"

# --- 4. same path resolution as fm-secret.sh (FM_STATE_OVERRIDE too) -------
OTHER_STATE="$TMP/other-state"
mkdir -p "$OTHER_STATE"
FM_STATE_OVERRIDE="$OTHER_STATE" FM_HOME=/nonexistent-should-be-unused "$SECRET" put viaoverride \
  <<< "override-value" >/dev/null || fail "put with FM_STATE_OVERRIDE must succeed"
override_out="$(printf 'has override-value inside' | \
  FM_STATE_OVERRIDE="$OTHER_STATE" FM_HOME=/nonexistent-should-be-unused bash -c ". \"$LIB\"; fm_redact")"
case "$override_out" in
  *"[GEHEIM:viaoverride]"*) ok "fm-redact-lib.sh honors FM_STATE_OVERRIDE exactly like fm-secret.sh" ;;
  *) fail "fm_redact must resolve the same secrets dir as fm-secret.sh under FM_STATE_OVERRIDE (got: $override_out)" ;;
esac

echo "--- fm-redact-lib.sh: $FAILS failing check(s) ---"
[ "$FAILS" -eq 0 ]
