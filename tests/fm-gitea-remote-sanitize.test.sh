#!/usr/bin/env bash
# fm-gitea-remote-sanitize.test.sh - strip embedded remote userinfo and feed
# HTTPS Gitea auth through config/gitea-token without printing secrets.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity

# shellcheck source=bin/fm-git-remote-sanitize-lib.sh
. "$ROOT/bin/fm-git-remote-sanitize-lib.sh"

assert_eq() {
  local got=$1 want=$2 msg=${3:-}
  if [ "$got" != "$want" ]; then
    fail "assert_eq failed${msg:+: $msg}: got=[$got] want=[$want]"
  fi
}

test_strip_userinfo_variants() {
  assert_eq \
    "$(fm_git_remote_url_strip_userinfo 'https://user:s3cret@private-git.ocin.cloud/OpenCloud/core.git')" \
    'https://private-git.ocin.cloud/OpenCloud/core.git' \
    'user:pass https'
  assert_eq \
    "$(fm_git_remote_url_strip_userinfo 'https://user@private-git.ocin.cloud/OpenCloud/core.git')" \
    'https://private-git.ocin.cloud/OpenCloud/core.git' \
    'user-only https'
  assert_eq \
    "$(fm_git_remote_url_strip_userinfo 'http://user:pass@example.test/r.git')" \
    'http://example.test/r.git' \
    'http user:pass'
  assert_eq \
    "$(fm_git_remote_url_strip_userinfo 'git@private-git.ocin.cloud:OpenCloud/core.git')" \
    'git@private-git.ocin.cloud:OpenCloud/core.git' \
    'ssh untouched'
  assert_eq \
    "$(fm_git_remote_url_strip_userinfo 'https://private-git.ocin.cloud/OpenCloud/core.git')" \
    'https://private-git.ocin.cloud/OpenCloud/core.git' \
    'clean https untouched'
  pass "strip userinfo variants"
}

test_sanitize_repo_rewrites_and_is_quiet_on_secrets() {
  local repo out url
  repo=$(fm_test_tmproot sanitize-repo)
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin 'https://apinant:deadbeefdeadbeef@private-git.ocin.cloud/OpenCloud/core.git'
  git -C "$repo" remote add gitea-https 'https://apinant:deadbeefdeadbeef@private-git.ocin.cloud/OpenCloud/core.git'
  git -C "$repo" remote add clean 'https://private-git.ocin.cloud/OpenCloud/other.git'
  git -C "$repo" remote add ssh 'git@private-git.ocin.cloud:OpenCloud/core.git'

  out=$(fm_git_remote_sanitize_repo "$repo")
  printf '%s\n' "$out" | grep -Fq 'sanitized remote origin' \
    || fail "expected origin sanitize line, got: $out"
  printf '%s\n' "$out" | grep -Fq 'sanitized remote gitea-https' \
    || fail "expected gitea-https sanitize line, got: $out"
  printf '%s\n' "$out" | grep -Eqi 'deadbeef|apinant:|password' \
    && fail "sanitize output leaked secret material: $out"

  url=$(git -C "$repo" remote get-url origin)
  assert_eq "$url" 'https://private-git.ocin.cloud/OpenCloud/core.git' 'origin cleaned'
  url=$(git -C "$repo" remote get-url gitea-https)
  assert_eq "$url" 'https://private-git.ocin.cloud/OpenCloud/core.git' 'gitea-https cleaned'
  url=$(git -C "$repo" remote get-url clean)
  assert_eq "$url" 'https://private-git.ocin.cloud/OpenCloud/other.git' 'clean unchanged'
  url=$(git -C "$repo" remote get-url ssh)
  assert_eq "$url" 'git@private-git.ocin.cloud:OpenCloud/core.git' 'ssh unchanged'

  # Idempotent second pass produces no output.
  out=$(fm_git_remote_sanitize_repo "$repo")
  [ -z "$out" ] || fail "second sanitize should be quiet, got: $out"
  pass "sanitize repo rewrites without leaking"
}

test_credential_helper_get() {
  local home cfg helper out
  home=$(fm_test_tmproot gitea-cred-home)
  cfg="$home/config"
  mkdir -p "$cfg"
  printf 'tokensecretvalue00000000000000000001\n' > "$cfg/gitea-token"
  chmod 600 "$cfg/gitea-token"
  printf 'apinant\n' > "$cfg/gitea-username"
  printf 'private-git.ocin.cloud\n' > "$cfg/gitea-host"
  helper=$ROOT/bin/fm-gitea-credential.sh

  out=$(
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" \
      "$helper" get <<'EOF'
protocol=https
host=private-git.ocin.cloud
path=OpenCloud/core.git

EOF
  )
  printf '%s\n' "$out" | grep -Fx 'username=apinant' >/dev/null \
    || fail "helper missing username: $out"
  printf '%s\n' "$out" | grep -Fx 'password=tokensecretvalue00000000000000000001' >/dev/null \
    || fail "helper missing password"
  pass "credential helper get happy path"
}

test_credential_helper_host_gate_and_mode() {
  local home cfg helper out
  home=$(fm_test_tmproot gitea-cred-gate)
  cfg="$home/config"
  mkdir -p "$cfg"
  printf 'tokensecretvalue00000000000000000002\n' > "$cfg/gitea-token"
  chmod 600 "$cfg/gitea-token"
  printf 'apinant\n' > "$cfg/gitea-username"
  helper=$ROOT/bin/fm-gitea-credential.sh

  out=$(
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" \
      "$helper" get <<'EOF'
protocol=https
host=evil.example
path=OpenCloud/core.git

EOF
  )
  [ -z "$out" ] || fail "helper answered wrong host: $out"

  out=$(
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" \
      "$helper" get <<'EOF'
protocol=http
host=private-git.ocin.cloud

EOF
  )
  [ -z "$out" ] || fail "helper answered non-https: $out"

  chmod 644 "$cfg/gitea-token"
  out=$(
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" \
      "$helper" get <<'EOF'
protocol=https
host=private-git.ocin.cloud

EOF
  )
  [ -z "$out" ] || fail "helper answered world-readable token file: $out"
  pass "credential helper host gate and mode refuse"
}

test_fleet_sync_sanitizes_before_fetch() {
  # Build a bare origin + clone with an embedded-token extra remote; fleet-sync
  # must strip it even when origin fetch is the only network path.
  local home work remote_abs out url
  home=$(fm_test_tmproot fleet-san)
  mkdir -p "$home/projects" "$home/data" "$home/config" "$home/remotes"
  work=$(fm_test_tmproot fleet-san-work)
  fm_git_init_commit "$work"
  # Default branch name may be master on older git; rename to main for fleet-sync.
  git -C "$work" branch -M main 2>/dev/null || true
  git clone --quiet --bare "$work" "$home/remotes/alpha.git"
  remote_abs=$(cd "$home/remotes/alpha.git" && pwd)
  git clone --quiet "file://$remote_abs" "$home/projects/alpha"
  git -C "$home/projects/alpha" remote add gitea-https \
    'https://apinant:deadbeefdeadbeef@private-git.ocin.cloud/OpenCloud/core.git'
  printf -- '- alpha [direct-PR] - alpha (added 2026-06-22)\n' > "$home/data/projects.md"

  out=$(
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_PROJECTS_OVERRIDE="$home/projects" \
      "$ROOT/bin/fm-fleet-sync.sh" alpha 2>&1
  ) || fail "fleet-sync failed: $out"

  printf '%s\n' "$out" | grep -Fq 'sanitized remote gitea-https' \
    || fail "fleet-sync did not report sanitize: $out"
  url=$(git -C "$home/projects/alpha" remote get-url gitea-https)
  assert_eq "$url" 'https://private-git.ocin.cloud/OpenCloud/core.git' \
    'fleet-sync cleaned gitea-https'
  printf '%s\n' "$out" | grep -Eqi 'deadbeef' \
    && fail "fleet-sync leaked token: $out"
  pass "fleet-sync sanitizes embedded remote before fetch"
}

test_strip_userinfo_variants
test_sanitize_repo_rewrites_and_is_quiet_on_secrets
test_credential_helper_get
test_credential_helper_host_gate_and_mode
test_fleet_sync_sanitizes_before_fetch

echo "ok: fm-gitea-remote-sanitize"
