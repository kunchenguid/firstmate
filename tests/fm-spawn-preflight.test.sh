#!/usr/bin/env bash
# Tests for the spawn SSH host-trust preflight: bin/fm-remote-preflight-lib.sh
# (the pure probe) and its wiring in bin/fm-spawn.sh (refuse BEFORE creating the
# crew terminal, never auto-accept an unknown key, leave no partial state).
#
# The bug: treehouse get's `git fetch origin` stops at a first-time SSH host
# authenticity prompt inside the crew pane. firstmate only polls the pane for a
# worktree cwd, and task metadata is not written until after the fetch, so the
# spawn wedges with no recoverable endpoint. The fix probes host trust up front.
#
# The two FALSE-BLOCK regressions these tests pin (both observed 2026-08-09):
#   1. the probe dropped the remote URL's SSH user, so `ssh://git@host/...` was
#      probed as a bare `host` - a connection as the probing process's own login,
#      not the identity git fetches with;
#   2. a known_hosts this process cannot READ produces stderr byte-identical to a
#      genuinely unknown host key, and was classified as untrusted - refusing the
#      spawn on a host whose key is in fact trusted, and pointing the captain at
#      their own trust configuration.
#
# The probe uses an isolated known_hosts file and a controllable ssh fixture (a
# fake ssh that reports trust from the known_hosts it is handed), so these cases
# are deterministic and never touch the real network or the host's known_hosts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-remote-preflight-lib.sh disable=SC1091
. "$ROOT/bin/fm-remote-preflight-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-preflight)

# A controllable ssh. It records its own argv to FM_FAKE_SSH_ARGS_LOG (so a test
# can assert the exact target and options the probe passes) and reproduces one of
# the observed OpenSSH_9.2p1 outcomes, selected by FM_FAKE_SSH_MODE:
#   trust  (default) report host trust from the UserKnownHostsFile it is passed:
#          a git-style "authenticated, no shell" success for a known host, and the
#          real unknown-host stderr - INCLUDING the benign `No such file or
#          directory` load_hostkeys lines a healthy run also prints - otherwise.
#   deny   the auth refusal `<target>: Permission denied (publickey).`
#   kh-unreadable   the known_hosts store cannot be read: the `-v` debug line plus
#                   stderr that is otherwise identical to a genuinely unknown key.
#   config-unreadable   `Can't open user config file ...: Permission denied`, which
#                       OpenSSH prints at DEFAULT verbosity before connecting.
#   bad-perms   `Bad owner or permissions on ...`, the other local-config refusal.
make_fake_ssh() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_SSH_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_SSH_ARGS_LOG"
kh=""; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) case "$2" in UserKnownHostsFile=*) kh=${2#UserKnownHostsFile=} ;; esac; shift 2 ;;
    --) shift; target=${1:-}; shift 2>/dev/null || shift ;;
    *) shift ;;
  esac
done
host=${target##*@}
case "${FM_FAKE_SSH_MODE:-trust}" in
  deny)
    echo "$target: Permission denied (publickey)." >&2
    exit 255
    ;;
  kh-unreadable)
    echo "debug1: load_hostkeys: fopen $kh: Permission denied" >&2
    echo "No ED25519 host key is known for $host and you have requested strict checking." >&2
    echo "Host key verification failed." >&2
    exit 255
    ;;
  config-unreadable)
    echo "Can't open user config file /root/.ssh/config: Permission denied" >&2
    exit 255
    ;;
  bad-perms)
    echo "Bad owner or permissions on /root/.ssh/config" >&2
    exit 255
    ;;
esac
if [ -n "$kh" ] && [ -n "$host" ] && grep -q "$host" "$kh" 2>/dev/null; then
  echo "Hi $host! You've successfully authenticated, but the host does not provide shell access." >&2
  exit 1
fi
echo "debug1: load_hostkeys: fopen $kh.other: No such file or directory" >&2
echo "No ED25519 host key is known for $host and you have requested strict checking." >&2
echo "Host key verification failed." >&2
exit 255
SH
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# UNIT: the probe TARGET keeps the remote URL's SSH user.
# ---------------------------------------------------------------------------
test_ssh_target_keeps_user() {
  local t
  t=$(fm_remote_ssh_target "ssh://git@code.byted.org/obric/coze-monorepo.git") \
    || fail "ssh:// url reported non-ssh"
  [ "$t" = "git@code.byted.org" ] || fail "ssh:// target dropped the user: $t"
  t=$(fm_remote_ssh_target "ssh://git@github.com:22/o/r.git") || fail "ssh://host:port reported non-ssh"
  [ "$t" = "git@github.com" ] || fail "ssh://host:port target wrong: $t"
  t=$(fm_remote_ssh_target "git@code.byted.org:obric/firstmate.git") || fail "scp-like url reported non-ssh"
  [ "$t" = "git@code.byted.org" ] || fail "scp-like target dropped the user: $t"
  t=$(fm_remote_ssh_target "ssh://code.byted.org/o/r.git") || fail "userless ssh:// reported non-ssh"
  [ "$t" = "code.byted.org" ] || fail "userless ssh:// target wrong: $t"
  t=$(fm_remote_ssh_target "host.example:path/to/repo") || fail "userless scp-like reported non-ssh"
  [ "$t" = "host.example" ] || fail "userless scp-like target wrong: $t"
  fm_remote_ssh_target "https://github.com/o/r.git" && fail "https treated as ssh"
  fm_remote_ssh_target "/local/path/repo" && fail "absolute local path treated as ssh"
  pass "the probe target keeps the remote URL's SSH user (git@host), and non-ssh remotes are still skipped"
}

# ---------------------------------------------------------------------------
# UNIT: host extraction from every common git remote URL shape. The host is what
# a host key belongs to, so trust wording still names it without the user.
# ---------------------------------------------------------------------------
test_ssh_host_extraction() {
  local h
  h=$(fm_remote_ssh_host "git@code.byted.org:obric/firstmate.git") || fail "scp-like url reported non-ssh"
  [ "$h" = "code.byted.org" ] || fail "scp-like host wrong: $h"
  h=$(fm_remote_ssh_host "ssh://git@github.com:22/o/r.git") || fail "ssh:// url reported non-ssh"
  [ "$h" = "github.com" ] || fail "ssh:// host wrong: $h"
  h=$(fm_remote_ssh_host "host.example:path/to/repo") || fail "userless scp-like reported non-ssh"
  [ "$h" = "host.example" ] || fail "userless scp-like host wrong: $h"
  fm_remote_ssh_host "https://github.com/o/r.git" && fail "https treated as ssh"
  fm_remote_ssh_host "git://x/y.git" && fail "git:// treated as ssh"
  fm_remote_ssh_host "file:///tmp/r" && fail "file:// treated as ssh"
  fm_remote_ssh_host "/local/path/repo" && fail "absolute local path treated as ssh"
  fm_remote_ssh_host "./rel/repo" && fail "relative local path treated as ssh"
  pass "ssh host is extracted from scp-like and ssh:// urls, non-ssh remotes are skipped"
}

# ---------------------------------------------------------------------------
# UNIT: the probe distinguishes untrusted, trusted, denied, and unrunnable.
# ---------------------------------------------------------------------------
test_preflight_probe_outcomes() {
  local d kh rc
  d="$TMP_ROOT/probe"
  mkdir -p "$d"
  kh="$d/known_hosts"
  : > "$kh"
  make_fake_ssh "$d/ssh"

  # Untrusted: host absent from the isolated known_hosts -> code 10. The fixture
  # also emits the benign `No such file or directory` load_hostkeys line a healthy
  # run prints, so this pins that an ABSENT store is still a real untrusted host.
  rc=0; FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 10 "$rc" "untrusted host must return 10"

  # Trusted: host present in the isolated known_hosts -> code 0.
  printf 'code.byted.org ssh-ed25519 AAAA\n' > "$kh"
  rc=0; FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 0 "$rc" "trusted host must return 0"

  # Auth refused -> code 11.
  rc=0; FM_FAKE_SSH_MODE=deny FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" \
    fm_remote_preflight_ssh git@code.byted.org || rc=$?
  expect_code 11 "$rc" "permission denied must return 11"

  # Probe cannot run (no ssh binary) -> code 20, fail-safe.
  rc=0; FM_SPAWN_SSH="$d/does-not-exist" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 20 "$rc" "an unrunnable probe must return 20 (fail-safe)"
  pass "the probe returns 10/0/11/20 for untrusted/trusted/denied/unrunnable"
}

# ---------------------------------------------------------------------------
# UNIT: a local SSH environment this process cannot READ is NOT a trust verdict.
# Each of these ran with an empty isolated known_hosts, i.e. the fixture would
# otherwise report the host as untrusted - so a 20 here can only come from the
# local-read classification, not from the store happening to hold the key.
# ---------------------------------------------------------------------------
test_local_read_failure_is_not_a_trust_verdict() {
  local d kh rc
  d="$TMP_ROOT/localread"
  mkdir -p "$d"
  kh="$d/known_hosts"
  : > "$kh"
  make_fake_ssh "$d/ssh"

  rc=0; FM_FAKE_SSH_MODE=kh-unreadable FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" \
    fm_remote_preflight_ssh git@code.byted.org || rc=$?
  expect_code 20 "$rc" "an unreadable known_hosts must return 20, never 10 (the host key may well be trusted)"

  rc=0; FM_FAKE_SSH_MODE=config-unreadable FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" \
    fm_remote_preflight_ssh git@code.byted.org || rc=$?
  expect_code 20 "$rc" "an unreadable ssh config must return 20, never 11 (it is not an auth refusal)"

  rc=0; FM_FAKE_SSH_MODE=bad-perms FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" \
    fm_remote_preflight_ssh git@code.byted.org || rc=$?
  expect_code 20 "$rc" "a refused local config (bad owner or permissions) must return 20"

  pass "an unreadable local known_hosts or ssh config returns 20 (proceed), not a remote-trust or credential verdict"
}

# ---------------------------------------------------------------------------
# UNIT: the probe passes the [user@]host target through, and runs verbose - the
# debug output is the ONLY signal that separates an unreadable known_hosts from a
# genuinely unknown host key, so dropping -v silently restores the false block.
# ---------------------------------------------------------------------------
test_probe_passes_target_and_runs_verbose() {
  local d kh log args
  d="$TMP_ROOT/args"
  mkdir -p "$d"
  kh="$d/known_hosts"
  log="$d/args.log"
  : > "$kh"
  make_fake_ssh "$d/ssh"

  FM_FAKE_SSH_ARGS_LOG="$log" FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" \
    fm_remote_preflight_ssh git@code.byted.org || :
  args=$(cat "$log")
  assert_contains "$args" "-- git@code.byted.org true" "the probe must connect as the remote URL's user"
  assert_contains "$args" "-v" "the probe must run verbose or it cannot see the local-read evidence"
  assert_contains "$args" "-o BatchMode=yes" "BatchMode must stay on so the probe can never hang on input"
  assert_contains "$args" "-o StrictHostKeyChecking=yes" "strict host key checking must stay on (never auto-accept)"
  pass "the probe connects as git@host with BatchMode, strict host-key checking, and verbose output"
}

# ---------------------------------------------------------------------------
# Build a spawnable home whose project origin is an SSH remote.
# ---------------------------------------------------------------------------
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj fakebin kh
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  fakebin=$(fm_fakebin "$case_dir")
  kh="$case_dir/known_hosts"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  git -C "$proj" remote add origin "ssh://git@fake-ssh-host/obric/firstmate.git"
  make_fake_ssh "$fakebin/ssh"
  # A permissive fake tmux: enough that a trusted spawn gets PAST the preflight
  # (the point under test) even though it then fails for lack of a real backend.
  fm_fake_exit0 "$fakebin" tmux
  : > "$kh"
  printf '%s\n' "$case_dir|$home|$proj|$fakebin|$kh"
}

read_spawn_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR FAKEBIN_DIR KH_FILE <<EOF
$1
EOF
}

run_preflight_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_WT_TIMEOUT=1 TMUX="fake,1,0" \
    FM_SPAWN_SSH="$FAKEBIN_DIR/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$KH_FILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# ---------------------------------------------------------------------------
# INTEGRATION: an untrusted host blocks the spawn up front - code 4, an
# actionable message, and NO task metadata or window (no partial lease).
# ---------------------------------------------------------------------------
test_untrusted_host_blocks_spawn_before_any_state() {
  local rec id out status
  id=preflight-untrusted-z1
  rec=$(make_spawn_case untrusted "$id")
  read_spawn_case "$rec"
  # Known_hosts intentionally empty -> the host is untrusted.

  out=$(run_preflight_spawn "$id"); status=$?
  expect_code 4 "$status" "untrusted host must exit with the distinct preflight-blocked code"
  assert_contains "$out" "is not trusted" "block message must name the host-trust problem"
  assert_contains "$out" "Refusing to create a terminal" "block message must state nothing was created"
  assert_absent "$HOME_DIR/state/$id.meta" "a blocked spawn must leave no task metadata (no partial lease)"
  pass "an untrusted SSH host blocks the spawn before any terminal or metadata is created"
}

# ---------------------------------------------------------------------------
# INTEGRATION: a trusted host passes the preflight - the spawn proceeds past it
# (it may fail later for lack of a real backend, but is NOT preflight-blocked).
# ---------------------------------------------------------------------------
test_trusted_host_passes_preflight() {
  local rec id out status
  id=preflight-trusted-z1
  rec=$(make_spawn_case trusted "$id")
  read_spawn_case "$rec"
  printf 'fake-ssh-host ssh-ed25519 AAAA\n' > "$KH_FILE"

  out=$(run_preflight_spawn "$id"); status=$?
  [ "$status" -ne 4 ] || fail "trusted host was wrongly preflight-blocked (status 4): $out"
  assert_not_contains "$out" "is not trusted" "trusted host must not emit the host-trust block"
  pass "a trusted SSH host passes the preflight and the spawn proceeds past it"
}

# ---------------------------------------------------------------------------
# INTEGRATION: spawn probes the origin's [user@]host, not a bare host.
# ---------------------------------------------------------------------------
test_spawn_probes_the_origin_user() {
  local rec id log args
  id=preflight-user-z1
  rec=$(make_spawn_case originuser "$id")
  read_spawn_case "$rec"
  log="$HOME_DIR/../ssh-args.log"
  printf 'fake-ssh-host ssh-ed25519 AAAA\n' > "$KH_FILE"

  FM_FAKE_SSH_ARGS_LOG="$log" run_preflight_spawn "$id" >/dev/null 2>&1 || :
  assert_present "$log" "the spawn preflight must actually run the ssh probe"
  args=$(cat "$log")
  assert_contains "$args" "-- git@fake-ssh-host true" \
    "the spawn preflight must probe the origin's git@host, not a bare host"
  pass "the spawn preflight probes the origin URL's git@host identity"
}

# ---------------------------------------------------------------------------
# INTEGRATION: an unreadable local known_hosts must NOT block the spawn. This is
# the regression that stopped a whole review line: the host key was trusted, the
# probe process just could not read the store, and the captain was told to change
# their trust configuration.
# ---------------------------------------------------------------------------
test_unreadable_known_hosts_does_not_block_spawn() {
  local rec id out status
  id=preflight-unreadable-z1
  rec=$(make_spawn_case unreadable "$id")
  read_spawn_case "$rec"

  out=$(FM_FAKE_SSH_MODE=kh-unreadable run_preflight_spawn "$id"); status=$?
  [ "$status" -ne 4 ] || fail "an unreadable local known_hosts wrongly blocked the spawn (status 4): $out"
  assert_not_contains "$out" "is not trusted" "an unreadable local store must not be reported as an untrusted host"
  assert_not_contains "$out" "known_hosts" "the captain must not be pointed at their trust configuration"
  pass "an unreadable local known_hosts leaves the spawn to proceed instead of falsely blocking it"
}

test_ssh_target_keeps_user
test_ssh_host_extraction
test_preflight_probe_outcomes
test_local_read_failure_is_not_a_trust_verdict
test_probe_passes_target_and_runs_verbose
test_untrusted_host_blocks_spawn_before_any_state
test_trusted_host_passes_preflight
test_spawn_probes_the_origin_user
test_unreadable_known_hosts_does_not_block_spawn

echo "# all fm-spawn-preflight tests passed"
