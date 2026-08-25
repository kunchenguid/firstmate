#!/usr/bin/env bash
# tests/fm-secret.test.sh - the secret path (bin/fm-secret.sh) must actually
# keep secret values off argv, off stdout, and off disk anywhere but its own
# locked-down directory:
#
#   1. put via stdin succeeds; the secrets dir lands at mode 0700 and the
#      secret file at mode 0600, holding the exact value.
#   2. put REFUSES a value given as a CLI argument, names the process-title
#      leak, and writes nothing.
#   3. put refuses an empty value and an invalid name; nothing is written.
#   4. list prints the name and an age, never the value.
#   5. `with` exports SECRET_<NAME> for each named secret and execs the
#      command; a dash-separated name uppercases with underscores.
#   6. `with` refuses a missing secret, a missing '--', and a missing command
#      after '--' - before ever exec'ing anything.
#   7. rm removes a secret; rm on a missing secret refuses.
#
# Isolation: everything runs against a throwaway FM_HOME. Nothing touches the
# live fleet or the real state/secrets/.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET="$REPO/bin/fm-secret.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"
SECRETS_DIR="$HOME_A/state/secrets"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

run() { FM_HOME="$HOME_A" "$SECRET" "$@"; }

# --- 1. put via stdin: modes and exact value -------------------------------
if ! printf 'sup3r-s3cr3t!' | run put apitoken >/dev/null; then
  fail "put via stdin must succeed"
fi
dir_mode="$(stat -c %a "$SECRETS_DIR" 2>/dev/null || stat -f %Lp "$SECRETS_DIR" 2>/dev/null)"
file_mode="$(stat -c %a "$SECRETS_DIR/apitoken" 2>/dev/null || stat -f %Lp "$SECRETS_DIR/apitoken" 2>/dev/null)"
[ "$dir_mode" = "700" ] || fail "secrets dir must be mode 0700, got $dir_mode"
[ "$file_mode" = "600" ] || fail "secret file must be mode 0600, got $file_mode"
[ "$(cat "$SECRETS_DIR/apitoken")" = "sup3r-s3cr3t!" ] || fail "secret file must hold the exact value"
ok "put via stdin writes 0700 dir / 0600 file with the exact value"

# --- 2. put refuses a CLI-argument value ------------------------------------
out="$(run put viaarg "the-value" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "put must refuse a value given as a CLI argument"
else
  ok "put refuses a value given as a CLI argument"
fi
printf '%s' "$out" | grep -qi "process-title" || fail "refusal must name the process-title leak"
printf '%s' "$out" | grep -qi "stdin" || fail "refusal must name the stdin escape hatch"
[ ! -f "$SECRETS_DIR/viaarg" ] || fail "refused put must not write a file"

# --- 3. put refuses empty value and invalid name ----------------------------
if printf '' | run put empty >/dev/null 2>&1; then
  fail "put must refuse an empty value"
else
  ok "put refuses an empty value"
fi
[ ! -f "$SECRETS_DIR/empty" ] || fail "refused empty put must not write a file"

if printf 'x' | run put "bad/name" >/dev/null 2>&1; then
  fail "put must refuse a name outside [A-Za-z0-9_-]+"
else
  ok "put refuses an invalid name"
fi

# --- 4. list: name and age, never the value ---------------------------------
list_out="$(run list)"
printf '%s' "$list_out" | grep -q "^apitoken	age=" || fail "list must show the name with an age field"
printf '%s' "$list_out" | grep -qF "sup3r-s3cr3t!" && fail "list must never print the secret value"
ok "list prints only name and age"

# --- 5. with: export and exec -----------------------------------------------
printf 'second-value' | run put my-second-secret >/dev/null || fail "second put must succeed"

# shellcheck disable=SC2016 # single quotes are deliberate: SECRET_* expand inside the exec'd child, not here
with_out="$(run with apitoken my-second-secret -- bash -c \
  'printf "%s|%s\n" "$SECRET_APITOKEN" "$SECRET_MY_SECOND_SECRET"')"
[ "$with_out" = "sup3r-s3cr3t!|second-value" ] \
  || fail "with must export SECRET_<NAME> per name (dashes -> underscores, uppercased); got '$with_out'"
ok "with exports SECRET_<NAME> for each named secret and execs the command"

# with must actually exec (replace this process), not fork: a command that
# reads its own parent pid equal to the caller's pid is exec's signature, but
# that's awkward to assert portably here, so instead assert the exit code of
# the command propagates unchanged (a fork+wait could also do that, so this is
# a weaker but still real behavioral check).
if run with apitoken -- bash -c 'exit 17' >/dev/null 2>&1; then
  fail "with must propagate the command's exit code"
else
  actual_rc=$?
  [ "$actual_rc" -eq 17 ] || fail "with must propagate the exact exit code (got $actual_rc)"
fi
ok "with propagates the command's exit code"

# --- 6. with refuses before exec'ing anything -------------------------------
out="$(run with does-not-exist -- bash -c 'echo ran' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "with must refuse a secret that was never put"
printf '%s' "$out" | grep -q "ran" && fail "with must not run the command when a secret is missing"
ok "with refuses a missing secret before running the command"

out="$(run with apitoken bash -c 'echo ran' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "with must refuse when '--' is missing"
printf '%s' "$out" | grep -q "^ran$" && fail "with must not run the command when '--' is missing"
ok "with refuses a missing '--' separator"

out="$(run with apitoken -- 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "with must refuse a missing command after '--'"
ok "with refuses a missing command after '--'"

# --- 7. rm ------------------------------------------------------------------
run rm apitoken >/dev/null || fail "rm must succeed on an existing secret"
[ ! -f "$SECRETS_DIR/apitoken" ] || fail "rm must remove the secret file"
ok "rm removes an existing secret"

if run rm apitoken >/dev/null 2>&1; then
  fail "rm must refuse a secret that no longer exists"
else
  ok "rm refuses a missing secret"
fi

echo "--- fm-secret.sh: $FAILS failing check(s) ---"
[ "$FAILS" -eq 0 ]
