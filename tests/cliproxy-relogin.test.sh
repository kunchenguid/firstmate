#!/usr/bin/env bash
# tests/cliproxy-relogin.test.sh - the re-login helper must walk accounts in
# order, write each credential atomically without ever printing the token, prove
# the first account with one real request before spending nine more approvals,
# archive the superseded 30-day credential instead of deleting it, and record the
# login date the age alarm measures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/cliproxy-relogin.sh"
TMP_ROOT=$(fm_test_tmproot cliproxy-relogin)
FIXTURE_TOKEN='sk-ant-oat01-fixtureTOKEN123'
NEXT_YEAR=$(date -u -d '+1 year' +%Y 2>/dev/null || date -u -v+1y +%Y)
TODAY=$(date -u +%Y-%m-%d)

home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/auth" "$dir/config" "$dir/archive" "$dir/fakebin" "$dir/log"
  cat > "$dir/fakebin/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/log/claude"
printf '%s\n' 'Browser didn'"'"'t open? Open this URL:'
printf '%s\n' 'https://claude.ai/oauth/authorize?code=fixture&state=fixture'
sleep 1
printf '%s\n' 'Long-lived token created successfully'
printf '%s\n' '$FIXTURE_TOKEN'
SH
  chmod 0755 "$dir/fakebin/claude"
  cat > "$dir/fakebin/curl" <<SH
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' '{"error":"fixture"}' > "\${out:-/dev/null}"
printf '%s' "\${CURL_CODE:-200}"
SH
  chmod 0755 "$dir/fakebin/curl"
  cat > "$dir/config/cliproxy-login-registry.json" <<'SH'
{"_note":"human login date per Claude account","a@x.com":"2026-10-21","b@y.com":"2026-10-21"}
SH
  printf '%s\n' "$dir"
}

# An existing 30-day credential for each account, with a refresh token, so the
# helper has something real to supersede.
seed_oauth() {  # <dir>
  printf '%s\n' '{"email":"a@x.com","last_refresh":"2026-11-04T10:00:00Z","expired":"2026-11-04T18:00:00Z","refresh_token":"r-a"}' \
    > "$1/auth/claude-1111-a@x.com.json"
  printf '%s\n' '{"email":"b@y.com","last_refresh":"2026-11-04T10:00:00Z","expired":"2026-11-04T18:00:00Z","refresh_token":"r-b"}' \
    > "$1/auth/claude-2222-b@y.com.json"
}

registry_date() {  # <dir> <email>
  python3 - "$1/config/cliproxy-login-registry.json" "$2" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    print(json.load(handle).get(sys.argv[2], ""))
PY
}

run_helper() {  # <dir> [args...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" \
    FM_CLIPROXY_ARCHIVE_ROOT="$dir/archive" \
    FM_CLIPROXY_AUTH_DIR="$dir/auth" \
    FM_CLIPROXY_LOGIN_REGISTRY="$dir/config/cliproxy-login-registry.json" \
    FM_CLIPROXY_TIMEOUT_SECS=20 \
    "$HELPER" "$@"
}

# --- the happy path: two accounts, verified first, archived, recorded -------

DIR=$(home happy)
seed_oauth "$DIR"
out=$(run_helper "$DIR" --api-key fixture-key --accounts a@x.com,b@y.com 2>&1) \
  || fail "the helper must succeed on a verified pool: $out"

assert_contains "$out" "[1/2] a@x.com" "the first account runs first"
assert_contains "$out" "[2/2] b@y.com" "the second account runs after it"
assert_contains "$out" "https://claude.ai/oauth/authorize?code=fixture" "the approval URL is printed"
assert_contains "$out" "answered 200" "the first account is verified with one real request"
assert_not_contains "$out" "$FIXTURE_TOKEN" "the token is never printed"
assert_not_contains "$out" "sk-ant-oat01-" "no part of the token reaches standard output"

for account in a@x.com b@y.com; do
  file="$DIR/auth/claude-setup-$account.json"
  assert_present "$file" "the credential for $account is written"
  mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)
  [ "$mode" = 600 ] || fail "the credential for $account must be mode 600, got $mode"
  body=$(cat "$file")
  assert_contains "$body" '"is_setup_token": true' "the credential for $account is marked a setup token"
  assert_contains "$body" "\"expired\": \"$NEXT_YEAR" "the credential for $account expires in one year"
  assert_not_contains "$body" 'refresh_token' "the credential for $account carries no refresh token"
  assert_contains "$body" "\"email\": \"$account\"" "the credential for $account names its account"
done
assert_present "$DIR/archive/$(date -u +%Y-%m-%d)/claude-1111-a@x.com.json" \
  "the superseded 30-day credential is archived, not deleted"
assert_absent "$DIR/auth/claude-1111-a@x.com.json" "the superseded credential leaves the auth dir"
assert_absent "$DIR/auth/claude-2222-b@y.com.json" "every superseded credential leaves the auth dir"

registry=$(cat "$DIR/config/cliproxy-login-registry.json")
assert_contains "$registry" "\"a@x.com\": \"$TODAY\"" "the login date is recorded for the first account"
assert_contains "$registry" "\"b@y.com\": \"$TODAY\"" "the login date is recorded for the second account"
assert_contains "$registry" '"_note"' "the registry keeps its existing keys"
[ "$(wc -l < "$DIR/log/claude" | tr -d '[:space:]')" = 2 ] \
  || fail "both accounts must be attempted"
pass "re-login walks the pool, verifies the first, archives, and records"

# --- a failed first verification stops before the remaining approvals -------

DIR=$(home unverified)
seed_oauth "$DIR"
set +e
out=$(CURL_CODE=401 run_helper "$DIR" --api-key fixture-key --accounts a@x.com,b@y.com 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "a failed first verification must stop the run"
assert_contains "$out" "stopped after the first account" "the run says why it stopped"
[ "$(wc -l < "$DIR/log/claude" | tr -d '[:space:]')" = 1 ] \
  || fail "the remaining accounts must not be attempted after a failed verification"
assert_present "$DIR/auth/claude-1111-a@x.com.json" \
  "the working 30-day credential is untouched when the replacement is unproven"
assert_absent "$DIR/auth/claude-setup-a@x.com.json" \
  "the unverified setup credential does not stay in the pool"
[ "$(registry_date "$DIR" a@x.com)" = 2026-10-21 ] \
  || fail "an unverified account's login date must not be recorded"
pass "an unproven setup token stops the run before the other accounts"

# --- dry run changes nothing -----------------------------------------------

DIR=$(home dry)
seed_oauth "$DIR"
out=$(run_helper "$DIR" --dry-run --api-key fixture-key --accounts a@x.com 2>&1) \
  || fail "a dry run must succeed: $out"
assert_contains "$out" "would write: $DIR/auth/claude-setup-a@x.com.json" "the dry run names the credential it would write"
assert_contains "$out" "nothing changed" "the dry run says nothing changed"
assert_absent "$DIR/auth/claude-setup-a@x.com.json" "the dry run writes no credential"
assert_present "$DIR/auth/claude-1111-a@x.com.json" "the dry run archives nothing"
assert_absent "$DIR/log/claude" "the dry run starts no login"
[ "$(registry_date "$DIR" a@x.com)" = 2026-10-21 ] \
  || fail "the dry run must record no login date"
pass "dry run plans without touching anything"

# --- the Codex login is delegated to CLIProxyAPI itself --------------------

DIR=$(home codex)
cat > "$DIR/fakebin/fake-proxy" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DIR/log/codex"
SH
chmod 0755 "$DIR/fakebin/fake-proxy"
printf '%s\n' 'auth-dir: stub' > "$DIR/config/cliproxyapi.yaml"

out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" FM_CLIPROXY_BIN="$DIR/fakebin/fake-proxy" \
  FM_CLIPROXY_CONFIG="$DIR/config/cliproxyapi.yaml" "$HELPER" --add codex --dry-run 2>&1) \
  || fail "a Codex dry run must succeed: $out"
assert_contains "$out" "-codex-login -no-browser -config $DIR/config/cliproxyapi.yaml" \
  "the Codex dry run names the exact command"
assert_absent "$DIR/log/codex" "the Codex dry run starts nothing"

out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" FM_CLIPROXY_BIN="$DIR/fakebin/fake-proxy" \
  FM_CLIPROXY_CONFIG="$DIR/config/cliproxyapi.yaml" "$HELPER" --add codex 2>&1) \
  || fail "the Codex login must run: $out"
assert_contains "$(cat "$DIR/log/codex")" "-codex-login -no-browser -config $DIR/config/cliproxyapi.yaml" \
  "the Codex login hands the flow to CLIProxyAPI"
pass "the Codex login is delegated to CLIProxyAPI"

printf 'all cliproxy-relogin tests passed\n'
