#!/usr/bin/env bash
# Empty-array expansions must survive stock macOS Bash 3.2 under `set -u`.
#
# `"${arr[@]}"` on an EMPTY array is an unbound-variable error in Bash 3.2 and
# harmless from Bash 4.4 on. The syntax is valid either way, so the parse-only
# stock-bash sweep in CI cannot see it; only executing the line finds it.
#
# Both scripts below reach such a loop with a genuinely empty array on their
# first real use: a delivered outbox that carries no Queued keys, and
# `fm-remote-home-seed.sh --no-projects`. Each case runs the real script
# through /bin/bash rather than the newer bash on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -x /bin/bash ] || { echo "skip: no /bin/bash"; exit 0; }

# The defect only exists below Bash 4.4, so on a newer /bin/bash these cases pass
# whether or not the guards are present. Skip loudly rather than reporting a pass
# that proves nothing.
BIN_BASH_VERSION=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')
case $BIN_BASH_VERSION in
  3.*) ;;
  4.[0-3]) ;;
  *)
    echo "skip: /bin/bash is $BIN_BASH_VERSION; the empty-array unbound error this covers only occurs below 4.4"
    exit 0
    ;;
esac

TMP_ROOT=$(fm_test_tmproot fm-bash32-empty-array)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

test_backlog_receive_accepts_an_outbox_with_no_keys_under_bash32() {
  local home rel delivered bytes hash out err rc
  home="$TMP_ROOT/receive-home"
  mkdir -p "$home/bin" "$home/data" "$home/state/handoff"
  : > "$home/AGENTS.md"
  : > "$home/.fm-secondmate-home"

  rel=state/handoff/ios.outbox.md
  delivered="$home/$rel"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$delivered"
  bytes=$(LC_ALL=C wc -c < "$delivered" | tr -d ' ')
  hash=$(sha256_of "$delivered")
  printf '1\n%s\n%s\n' "$bytes" "$hash" > "$home/state/handoff/.ios.upload-generation"

  out="$TMP_ROOT/receive.out"
  err="$TMP_ROOT/receive.err"
  set +e
  FM_HOME="$home" /bin/bash "$ROOT/bin/fm-backlog-receive.sh" \
    "$rel" "$bytes" "$hash" 1 >"$out" 2>"$err"
  rc=$?
  set -e
  assert_no_grep 'unbound variable' "$err" \
    "receiving an outbox with no keys hit an unbound-variable crash under /bin/bash"
  [ "$rc" -eq 0 ] || fail "receiving an outbox with no keys failed under /bin/bash (exit $rc): $(cat "$err" "$out")"
  assert_grep 'received: ios moved=0 already=0' "$out" \
    "an empty receipt must report that it moved nothing"
  assert_absent "$delivered" "a confirmed empty receipt must remove the delivered scratch file"
  pass "backlog receive accepts an outbox with no keys under /bin/bash"
}

test_remote_home_seed_passes_its_project_loop_with_no_projects_under_bash32() {
  local seed_home err ssh_stub reached rc
  seed_home="$TMP_ROOT/seed-home"
  mkdir -p "$seed_home/data" "$seed_home/state" "$seed_home/config" "$seed_home/projects"

  err="$TMP_ROOT/seed.err"
  ssh_stub="$TMP_ROOT/offline-ssh"
  reached="$TMP_ROOT/seed-reached-transport"
  cat > "$ssh_stub" <<'SH'
#!/usr/bin/env bash
printf 'reached\n' > "$FM_TEST_SEED_REACHED"
exit 255
SH
  chmod +x "$ssh_stub"
  set +e
  FM_SSH_BIN="$ssh_stub" FM_TEST_SEED_REACHED="$reached" \
    FM_HOME="$seed_home" FM_SECONDMATE_CHARTER='Own the build Mac.' \
    FM_SECONDMATE_SCOPE='remote build validation' \
    /bin/bash "$ROOT/bin/fm-remote-home-seed.sh" \
    ios remote-mac /remote/code /remote/home --no-projects \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  # A recording transport refuses without any network operation. Reaching it
  # proves the empty project loop actually ran, rather than failing earlier.
  [ "$rc" -eq 1 ] || fail "the offline transport must leave provisioning unconfirmed (exit $rc): $(cat "$err")"
  assert_grep reached "$reached" "empty project seed never reached the transport after its loop"
  assert_no_grep 'unbound variable' "$err" \
    "seeding with --no-projects hit an unbound-variable crash under /bin/bash"
  assert_no_grep 'PROJECT_NAMES' "$err" \
    "seeding with --no-projects must not fail on its empty project list"
  pass "remote home seed passes its project loop with no projects under /bin/bash"
}

test_backlog_receive_accepts_an_outbox_with_no_keys_under_bash32
test_remote_home_seed_passes_its_project_loop_with_no_projects_under_bash32
echo "# all fm-bash32-empty-array tests passed"
