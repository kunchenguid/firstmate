#!/usr/bin/env bash
# Behavior tests for the generic SSH transport and fixed remote entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-on)
# The helper is called in command substitution, so recreate the registered path
# and physicalize macOS's /var -> /private/var alias before transport validation.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
LOCAL_HOME="$TMP_ROOT/local-home"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SSH_LOG="$TMP_ROOT/ssh.log"
SSH_COUNT="$TMP_ROOT/ssh.count"
mkdir -p "$LOCAL_HOME/data" "$REMOTE_ROOT/bin" "$REMOTE_HOME"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh"

cat > "$REMOTE_ROOT/bin/fm-probe-one.sh" <<'SH'
#!/usr/bin/env bash
set -u
out=$1
rc=$2
shift 2
printf '%s\0' "$@" > "$out"
printf 'stdout: %s args\n' "$#"
printf 'stderr: separate\n' >&2
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin: %s\n' "$line"; done
exit "$rc"
SH
cat > "$REMOTE_ROOT/bin/fm-probe-two.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s\nroot=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE"
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
SH
cat > "$REMOTE_ROOT/bin/fm-probe-path.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PATH"
SH
cp "$ROOT/bin/fm-remote-doctor.sh" "$REMOTE_ROOT/bin/fm-remote-doctor.sh"
cat > "$REMOTE_ROOT/bin/fm-mutate.sh" <<'SH'
#!/usr/bin/env bash
printf 'mutation\n' >> "$1"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_FAKE_SSH_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

write_registry() {
  cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $REMOTE_HOME; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
}
write_registry

fm_on() {
  FM_HOME="$LOCAL_HOME" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_SSH_LOG="$SSH_LOG" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  "$ROOT/bin/fm-on.sh" "$@"
}

# The pre-feature user path had no executable transport at all. The regression
# exercises the adopted public surface end to end through a deterministic SSH
# process boundary rather than checking script source.
ARGV_ACTUAL="$REMOTE_HOME/argv.bin"
ARGV_EXPECTED="$TMP_ROOT/argv-expected.bin"
# shellcheck disable=SC2016 # Literal shell-looking argv is the injection probe.
printf '%s\0' 'plain' 'two words' '$(touch /tmp/fm-on-injected)' '' $'line one\nline two' > "$ARGV_EXPECTED"
printf 'payload one\npayload two\n' > "$TMP_ROOT/stdin"
set +e
# shellcheck disable=SC2016 # Literal shell-looking argv is the injection probe.
fm_on ios fm-probe-one.sh "$ARGV_ACTUAL" 23 \
  'plain' 'two words' '$(touch /tmp/fm-on-injected)' '' $'line one\nline two' \
  < "$TMP_ROOT/stdin" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
rc=$?
set -e
[ "$rc" -eq 23 ] || fail "remote exit status was not preserved (got $rc)"
cmp -s "$ARGV_EXPECTED" "$ARGV_ACTUAL" || fail "remote argv boundaries were not preserved byte-for-byte"
assert_grep 'stdout: 5 args' "$TMP_ROOT/stdout" "remote stdout was not preserved"
assert_grep 'stdin: payload one' "$TMP_ROOT/stdout" "remote stdin was not preserved"
assert_grep 'stdin: payload two' "$TMP_ROOT/stdout" "remote stdin lost its second line"
assert_grep 'stderr: separate' "$TMP_ROOT/stderr" "remote stderr was not preserved separately"
assert_absent /tmp/fm-on-injected "shell-looking argv was interpreted"
pass "fm-on preserves argv, stdin, stdout, stderr, and exit status without shell interpretation"

out=$(TOP_SECRET='must-not-cross' fm_on remote-mac fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "remote FM_HOME was not explicit"
assert_contains "$out" "root=$REMOTE_ROOT" "remote root was not explicit"
assert_contains "$out" 'secret=absent' "the primary ambient environment crossed the transport"
pass "the fixed entrypoint sets only its explicit environment"

# The child PATH is the entrypoint's own composition, so it is asserted on the
# PATH a real child receives rather than on the script that builds it. The
# expectation is rebuilt here from the documented contract - fixed head, the
# package-manager directories that exist on this host, fixed tail - so a host
# with nix, homebrew, or neither exercises both the include and omit directions.
ACCOUNT_HOME=$(unset HOME; CDPATH='' cd ~ && pwd -P)
ACCOUNT_USER=$(id -un)
OPTIONAL_DIRS=(
  "$ACCOUNT_HOME/.nix-profile/bin"
  "/etc/profiles/per-user/$ACCOUNT_USER/bin"
  /run/current-system/sw/bin
  /opt/homebrew/bin
  /usr/local/bin
)
EXPECTED_PATH=
expect_dir() {
  case ":$EXPECTED_PATH:" in *":$1:"*) return 0 ;; esac
  EXPECTED_PATH="${EXPECTED_PATH:+$EXPECTED_PATH:}$1"
}
path_has() { case ":$1:" in *":$2:"*) return 0 ;; esac; return 1; }
expect_dir "$REMOTE_ROOT/bin"
expect_dir "$ACCOUNT_HOME/.local/bin"
for candidate in "${OPTIONAL_DIRS[@]}"; do
  [ -d "$candidate" ] && expect_dir "$candidate"
done
for fixed in /usr/bin /bin /usr/sbin /sbin; do expect_dir "$fixed"; done

CHILD_PATH=$(fm_on ios fm-probe-path.sh)
[ "$CHILD_PATH" = "$EXPECTED_PATH" ] \
  || fail "composed child PATH did not match the portable contract"$'\n'"expected: $EXPECTED_PATH"$'\n'"actual:   $CHILD_PATH"
[ "${CHILD_PATH%%:*}" = "$REMOTE_ROOT/bin" ] || fail "the remote code root's bin was not first on the child PATH"
[ "$(printf '%s' "$CHILD_PATH" | cut -d: -f2)" = "$ACCOUNT_HOME/.local/bin" ] \
  || fail "the account's ~/.local/bin was not second on the child PATH"
case "$CHILD_PATH" in *:/usr/bin:/bin:/usr/sbin:/sbin) ;; *) fail "the child PATH did not end with the portable system tail" ;; esac
DUPES=$(printf '%s\n' "$CHILD_PATH" | tr ':' '\n' | sort | uniq -d)
[ -z "$DUPES" ] || fail "the child PATH repeated entries: $DUPES"
PRESENT_CHECKED=0
ABSENT_CHECKED=0
for candidate in "${OPTIONAL_DIRS[@]}"; do
  if [ -d "$candidate" ]; then
    path_has "$CHILD_PATH" "$candidate" || fail "an existing package-manager directory was dropped: $candidate"
    PRESENT_CHECKED=$((PRESENT_CHECKED + 1))
  else
    path_has "$CHILD_PATH" "$candidate" && fail "an absent directory was added to the child PATH: $candidate"
    ABSENT_CHECKED=$((ABSENT_CHECKED + 1))
  fi
done
pass "the entrypoint composes a deduplicated child PATH (kept $PRESENT_CHECKED existing, omitted $ABSENT_CHECKED absent)"

set +e
out=$(
  # The entrypoint's subprocess invokes this indirectly through export -f.
  # shellcheck disable=SC2329
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then return 1; fi
    builtin command "$@"
  }
  if command -v git >/dev/null 2>&1; then
    fail "the missing-git fixture still resolved git"
  fi
  export -f command
  fm_on ios fm-remote-doctor.sh 2>&1
)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "the entrypoint passed when git did not resolve on its operator PATH"
assert_contains "$out" 'required tool git does not resolve on the remote operator PATH' "the entrypoint did not name the missing prerequisite"
assert_contains "$out" '/.local/bin' "the entrypoint did not point at the wrapper escape hatch"
assert_not_contains "$out" 'command is not tracked by the configured remote root' "missing git was misreported as an untracked command"
pass "the entrypoint gives an actionable missing-git diagnostic"

out=$(fm_on ios fm-remote-doctor.sh)
rc=$?
expect_code 0 "$rc" "the remote doctor failed through the transport"
assert_contains "$out" "path=$EXPECTED_PATH" "the remote doctor did not report the entrypoint child PATH"
assert_contains "$out" 'entrypoint=yes' "the remote doctor did not detect its entrypoint launch"
assert_contains "$out" 'required git=' "the remote doctor did not report the required tool"
pass "the remote doctor reports the same PATH the entrypoint hands its children"

DOCTOR_BIN="$TMP_ROOT/doctor-bin"
mkdir -p "$DOCTOR_BIN"
ln -sf "$(command -v bash)" "$DOCTOR_BIN/bash"
set +e
out=$(PATH="$DOCTOR_BIN" "$ROOT/bin/fm-remote-doctor.sh" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "the remote doctor passed with a missing required tool"
assert_contains "$out" 'required git=MISSING' "the remote doctor did not mark the missing required tool"
assert_contains "$out" 'required tools do not resolve on the remote runtime PATH: git' "the remote doctor did not name the missing tool"
assert_contains "$out" '.local/bin' "the remote doctor did not offer the wrapper escape hatch"
ln -sf "$(command -v git)" "$DOCTOR_BIN/git"
set +e
out=$(PATH="$DOCTOR_BIN" "$ROOT/bin/fm-remote-doctor.sh" 2>&1)
rc=$?
set -e
expect_code 0 "$rc" "the remote doctor failed with every required tool present"
assert_contains "$out" "required git=$DOCTOR_BIN/git" "the remote doctor did not report where the required tool resolved"
assert_contains "$out" 'optional tmux=absent' "the remote doctor did not report an absent optional tool"
pass "the remote doctor fails only on missing required tools and names them"

out=$(fm_on ios fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "first dynamic command stopped resolving"
ARGV_TWO="$REMOTE_HOME/argv-two.bin"
printf 'second command\0' > "$TMP_ROOT/argv-two-expected.bin"
fm_on ios fm-probe-one.sh "$ARGV_TWO" 0 'second command' >/dev/null 2>/dev/null
cmp -s "$TMP_ROOT/argv-two-expected.bin" "$ARGV_TWO" || fail "second dynamic command did not execute"
pass "multiple fm-*.sh executables work without a command table"

for bad in '../fm-probe-one.sh' 'fm-probe-one.sh/extra' 'sh' 'fm-../../bin/sh'; do
  if fm_on ios "$bad" >/dev/null 2>&1; then
    fail "unsafe command name was accepted: $bad"
  fi
done
ln -s fm-probe-one.sh "$REMOTE_ROOT/bin/fm-symlink.sh"
if fm_on ios fm-symlink.sh >/dev/null 2>&1; then
  fail "a symlinked command was accepted"
fi
cat > "$REMOTE_ROOT/bin/fm-untracked.sh" <<'SH'
#!/usr/bin/env bash
printf 'untracked command ran\n'
SH
chmod +x "$REMOTE_ROOT/bin/fm-untracked.sh"
GIT_SHADOW_LOG="$TMP_ROOT/git-shadow.log"
cat > "$REMOTE_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'consulted\n' >> "$FM_GIT_SHADOW_LOG"
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/git"
FM_GIT_SHADOW_LOG="$GIT_SHADOW_LOG" "$REMOTE_ROOT/bin/git" -C "$REMOTE_ROOT" ls-files --error-unmatch bin/fm-untracked.sh \
  || fail "the checkout-local git shim did not demonstrate that it would authorize the untracked command"
untracked_root_b64=$(printf '%s' "$REMOTE_ROOT" | base64 | tr -d '\n')
untracked_home_b64=$(printf '%s' "$REMOTE_HOME" | base64 | tr -d '\n')
untracked_argv_b64=$(printf '%s\0' fm-untracked.sh | base64 | tr -d '\n')
set +e
out=$(FM_GIT_SHADOW_LOG="$GIT_SHADOW_LOG" "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  1 "$untracked_root_b64" "$untracked_home_b64" "$untracked_argv_b64" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "an untracked fm-*.sh executable was accepted"
fi
assert_contains "$out" 'command is not tracked by the configured remote root' "the untracked command did not fail at tracked-command authorization"
[ "$(wc -l < "$GIT_SHADOW_LOG" | tr -d ' ')" -eq 1 ] \
  || fail "the tracked-command authorization consulted checkout-local git"
pass "tracked-command authorization excludes checkout-local git"
if FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  "$ROOT/bin/fm-on.sh" '-oProxyCommand=bad' fm-probe-two.sh >/dev/null 2>&1; then
  fail "an option-shaped SSH route was accepted"
fi
ssh_before_bad_path=$(cat "$SSH_COUNT")
cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT/../remote-root; home: $REMOTE_HOME; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
if fm_on ios fm-probe-two.sh >/dev/null 2>&1; then
  fail "a configured remote root with traversal was accepted"
fi
[ "$(cat "$SSH_COUNT")" -eq "$ssh_before_bad_path" ] || fail "unsafe configured paths reached SSH"
write_registry
pass "transport rejects shell escape, traversal, symlink, and option-injection surfaces"

root_b64=$(printf '%s' "$REMOTE_ROOT" | base64 | tr -d '\n')
home_b64=$(printf '%s' "$REMOTE_HOME" | base64 | tr -d '\n')
argv_b64=$(printf '%s\0' fm-probe-two.sh | base64 | tr -d '\n')
if "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 2 "$root_b64" "$home_b64" "$argv_b64" >/dev/null 2>&1; then
  fail "an incompatible transport protocol was accepted"
fi
traversal_root_b64=$(printf '%s' "$REMOTE_ROOT/../remote-root" | base64 | tr -d '\n')
if "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 "$traversal_root_b64" "$home_b64" "$argv_b64" >/dev/null 2>&1; then
  fail "the fixed entrypoint accepted traversal in the configured root"
fi
pass "the fixed entrypoint refuses incompatible protocols and unsafe roots"

cat >> "$LOCAL_HOME/data/secondmates.md" <<EOF
- build - build delivery (host: remote-mac; root: $REMOTE_ROOT; home: $TMP_ROOT/other-remote-home; scope: build work; projects: beta; added 2026-08-02)
EOF
if fm_on remote-mac fm-probe-two.sh >/dev/null 2>&1; then
  fail "an ambiguous SSH alias was accepted"
fi
out=$(fm_on ios fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "secondmate-id routing broke after alias ambiguity"
write_registry
pass "ambiguous aliases refuse while exact secondmate ids remain routable"

: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=unreachable fm_on ios fm-mutate.sh "$REMOTE_HOME/mutations" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 255 ] || fail "unreachable transport did not preserve ssh status 255 (got $rc)"
[ "$(cat "$SSH_COUNT")" -eq 1 ] || fail "unreachable transport was retried"
assert_absent "$REMOTE_HOME/mutations" "unreachable transport ran the mutation"

: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=ambiguous fm_on ios fm-mutate.sh "$REMOTE_HOME/mutations" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 255 ] || fail "ambiguous completion did not surface status 255 (got $rc)"
[ "$(cat "$SSH_COUNT")" -eq 1 ] || fail "ambiguous completion was retried"
[ "$(grep -c mutation "$REMOTE_HOME/mutations")" -eq 1 ] || fail "ambiguous mutation did not execute exactly once"
pass "unreachable and ambiguous transport failures are surfaced without retry"

echo "ALL TESTS PASSED"
