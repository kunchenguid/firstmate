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

# A controllable ssh: reports host trust from the UserKnownHostsFile it is passed
# (grep for the host), a git-style "authenticated, no shell" success for a trusted
# host, "Host key verification failed." for an untrusted one, and "Permission
# denied" when FM_FAKE_SSH_DENY=1. This exercises the real option passing.
make_fake_ssh() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
kh=""; host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) case "$2" in UserKnownHostsFile=*) kh=${2#UserKnownHostsFile=} ;; esac; shift 2 ;;
    --) shift; host=${1:-}; shift 2>/dev/null || shift ;;
    *) shift ;;
  esac
done
if [ "${FM_FAKE_SSH_DENY:-0}" = 1 ]; then echo "Permission denied (publickey)." >&2; exit 255; fi
if [ -n "$kh" ] && [ -n "$host" ] && grep -q "$host" "$kh" 2>/dev/null; then
  echo "Hi $host! You've successfully authenticated, but the host does not provide shell access." >&2
  exit 1
fi
echo "Host key verification failed." >&2
exit 255
SH
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# UNIT: host extraction from every common git remote URL shape.
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

  # Untrusted: host absent from the isolated known_hosts -> code 10.
  rc=0; FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 10 "$rc" "untrusted host must return 10"

  # Trusted: host present in the isolated known_hosts -> code 0.
  printf 'code.byted.org ssh-ed25519 AAAA\n' > "$kh"
  rc=0; FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 0 "$rc" "trusted host must return 0"

  # Auth refused -> code 11.
  rc=0; FM_FAKE_SSH_DENY=1 FM_SPAWN_SSH="$d/ssh" FM_SPAWN_SSH_KNOWN_HOSTS="$kh" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 11 "$rc" "permission denied must return 11"

  # Probe cannot run (no ssh binary) -> code 20, fail-safe.
  rc=0; FM_SPAWN_SSH="$d/does-not-exist" fm_remote_preflight_ssh code.byted.org || rc=$?
  expect_code 20 "$rc" "an unrunnable probe must return 20 (fail-safe)"
  pass "the probe returns 10/0/11/20 for untrusted/trusted/denied/unrunnable"
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
  git -C "$proj" remote add origin "git@fake-ssh-host:obric/firstmate.git"
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
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
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

test_ssh_host_extraction
test_preflight_probe_outcomes
test_untrusted_host_blocks_spawn_before_any_state
test_trusted_host_passes_preflight

echo "# all fm-spawn-preflight tests passed"
