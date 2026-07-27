#!/usr/bin/env bash
# Unit tests for bin/fm-git-transport-lib.sh.
#
# Covers pure URL conversion, dead-ssh-agent detection (stubbed SSH_AUTH_SOCK /
# ssh-add), SSH-failure classification, and the HTTPS fallback decision path for
# fetch (stubbed git). No network. Portable on bash 3.2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-git-transport-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-git-transport-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"

# --- pure URL conversion ----------------------------------------------------

test_ssh_to_https_scp_form() {
  local out
  out=$(fm_git_ssh_to_https 'git@github.com:kunchenguid/firstmate.git')
  [ "$out" = 'https://github.com/kunchenguid/firstmate.git' ] \
    || fail "scp-form conversion got '$out'"
  out=$(fm_git_ssh_to_https 'git@private-git.ocin.cloud:OpenCloud/core.git')
  [ "$out" = 'https://private-git.ocin.cloud/OpenCloud/core.git' ] \
    || fail "private-git scp-form got '$out'"
  pass "fm_git_ssh_to_https converts git@host:path to https://host/path"
}

test_ssh_to_https_ssh_url_form() {
  local out
  out=$(fm_git_ssh_to_https 'ssh://git@github.com/kunchenguid/firstmate.git')
  [ "$out" = 'https://github.com/kunchenguid/firstmate.git' ] \
    || fail "ssh:// form got '$out'"
  out=$(fm_git_ssh_to_https 'ssh://git@private-git.ocin.cloud:2222/OpenCloud/core.git')
  [ "$out" = 'https://private-git.ocin.cloud/OpenCloud/core.git' ] \
    || fail "ssh:// with port got '$out'"
  pass "fm_git_ssh_to_https converts ssh://git@host[/port]/path"
}

test_ssh_to_https_leaves_https_alone() {
  local out
  out=$(fm_git_ssh_to_https 'https://github.com/kunchenguid/firstmate.git')
  [ "$out" = 'https://github.com/kunchenguid/firstmate.git' ] \
    || fail "https passthrough got '$out'"
  pass "fm_git_ssh_to_https leaves https:// URLs unchanged"
}

test_cluster_http_to_public_https() {
  local out
  out=$(fm_git_cluster_http_to_https \
    'http://gitea-http.gitea.svc.cluster.local:3000/OpenCloud/console-backend.git')
  [ "$out" = 'https://private-git.ocin.cloud/OpenCloud/console-backend.git' ] \
    || fail "cluster http rewrite got '$out'"
  out=$(fm_git_prefer_https_url \
    'git@private-git.ocin.cloud:OpenCloud/console-backend.git')
  [ "$out" = 'https://private-git.ocin.cloud/OpenCloud/console-backend.git' ] \
    || fail "prefer_https ssh got '$out'"
  out=$(fm_git_prefer_https_url \
    'http://gitea-http.gitea.svc.cluster.local:3000/OpenCloud/core.git')
  [ "$out" = 'https://private-git.ocin.cloud/OpenCloud/core.git' ] \
    || fail "prefer_https cluster got '$out'"
  pass "cluster-HTTP and git@ both prefer public HTTPS"
}

# --- agent dead detection ---------------------------------------------------

test_ssh_agent_dead_when_sock_unset() {
  local old=${SSH_AUTH_SOCK-}
  unset SSH_AUTH_SOCK || true
  if ! fm_git_ssh_agent_dead; then
    if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
    fail "unset SSH_AUTH_SOCK must count as dead agent"
  fi
  if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
  pass "fm_git_ssh_agent_dead: unset SSH_AUTH_SOCK is dead"
}

test_ssh_agent_dead_when_sock_missing() {
  local old=${SSH_AUTH_SOCK-}
  export SSH_AUTH_SOCK="$TMP_ROOT/no-such-agent-socket"
  if ! fm_git_ssh_agent_dead; then
    if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
    fail "missing SSH_AUTH_SOCK path must count as dead"
  fi
  if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
  pass "fm_git_ssh_agent_dead: missing socket path is dead"
}

test_ssh_agent_dead_when_sock_not_socket() {
  local old=${SSH_AUTH_SOCK-}
  : > "$TMP_ROOT/not-a-socket"
  export SSH_AUTH_SOCK="$TMP_ROOT/not-a-socket"
  if ! fm_git_ssh_agent_dead; then
    if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
    fail "non-socket SSH_AUTH_SOCK must count as dead"
  fi
  if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
  pass "fm_git_ssh_agent_dead: non-socket path is dead"
}

_make_unix_socket() {
  local path=$1
  python3 - "$path" <<'PY'
import os, socket, sys
path = sys.argv[1]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
PY
}

test_ssh_agent_live_when_ssh_add_reports_no_identities() {
  local old=${SSH_AUTH_SOCK-}
  _make_unix_socket "$TMP_ROOT/live.sock"
  cat > "$FAKEBIN/ssh-add" <<'SH'
#!/usr/bin/env bash
echo "The agent has no identities." >&2
exit 1
SH
  chmod +x "$FAKEBIN/ssh-add"
  export SSH_AUTH_SOCK="$TMP_ROOT/live.sock"
  if fm_git_ssh_agent_dead; then
    if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
    rm -f "$FAKEBIN/ssh-add"
    fail "live agent with no identities must NOT count as dead"
  fi
  if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
  rm -f "$FAKEBIN/ssh-add"
  pass "fm_git_ssh_agent_dead: live agent with no identities is not dead"
}

test_ssh_agent_dead_when_ssh_add_connection_refused() {
  local old=${SSH_AUTH_SOCK-}
  _make_unix_socket "$TMP_ROOT/deadish.sock"
  cat > "$FAKEBIN/ssh-add" <<'SH'
#!/usr/bin/env bash
echo "Error connecting to agent: Connection refused" >&2
exit 2
SH
  chmod +x "$FAKEBIN/ssh-add"
  export SSH_AUTH_SOCK="$TMP_ROOT/deadish.sock"
  if ! fm_git_ssh_agent_dead; then
    if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
    rm -f "$FAKEBIN/ssh-add"
    fail "ssh-add connection refused must count as dead"
  fi
  if [ -n "$old" ]; then export SSH_AUTH_SOCK=$old; else unset SSH_AUTH_SOCK; fi
  rm -f "$FAKEBIN/ssh-add"
  pass "fm_git_ssh_agent_dead: ssh-add connection refused is dead"
}

# --- failure classification -------------------------------------------------

test_output_looks_like_ssh_failure() {
  fm_git_output_looks_like_ssh_failure 'Permission denied (publickey).' \
    || fail "publickey deny should match"
  fm_git_output_looks_like_ssh_failure 'fatal: Could not read from remote repository.' \
    || fail "could not read should match"
  fm_git_output_looks_like_ssh_failure 'ssh: Could not resolve hostname github.com' \
    || fail "resolve hostname should match"
  if fm_git_output_looks_like_ssh_failure 'error: failed to push some refs'; then
    fail "generic push reject must not look like SSH failure"
  fi
  pass "fm_git_output_looks_like_ssh_failure matches SSH signatures only"
}

test_should_retry_https_for_ssh_url_even_without_signature() {
  fm_git_should_retry_https 'git@github.com:o/r.git' 'some unrelated failure' \
    || fail "ssh URL should always be eligible for HTTPS retry"
  fm_git_should_retry_https \
    'http://gitea-http.gitea.svc.cluster.local:3000/OpenCloud/core.git' 'x' \
    || fail "cluster HTTP should always be eligible"
  if fm_git_should_retry_https 'https://github.com/o/r.git' 'HTTP 500'; then
    fail "plain HTTPS 500 without SSH signature must not force retry"
  fi
  pass "fm_git_should_retry_https gates on URL class and SSH signatures"
}

# --- fetch fallback decision (stubbed git) ----------------------------------

install_git_stub() {
  local remote_url=$1
  cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
log="$TMP_ROOT/git-argv.log"
printf '%s\n' "\$*" >> "\$log"
args=("\$@")
i=0
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i + 2)) ;;
    -c) i=\$((i + 2)) ;;
    *) break ;;
  esac
done
set -- "\${args[@]:\$i}"
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ]; then
  printf '%s\n' '$remote_url'
  exit 0
fi
if [ "\$1" = "fetch" ]; then
  target="\$2"
  case "\$target" in
    origin|git@*|ssh://*)
      echo "git@host: Permission denied (publickey)." >&2
      echo "fatal: Could not read from remote repository." >&2
      exit 128
      ;;
    https://*)
      echo ok >> "$TMP_ROOT/git-https-ok"
      exit 0
      ;;
    *)
      echo "stub: unexpected fetch target '\$target'" >&2
      exit 2
      ;;
  esac
fi
echo "stub: unhandled git args: \$*" >&2
exit 3
SH
  chmod +x "$FAKEBIN/git"
  : > "$TMP_ROOT/git-argv.log"
  rm -f "$TMP_ROOT/git-https-ok"
}

test_fetch_fallback_retries_https_after_ssh_failure() {
  install_git_stub 'git@github.com:kunchenguid/firstmate.git'
  unset FM_GITEA_TOKEN || true
  unset FM_GITEA_TOKEN_FILE || true
  local dir="$TMP_ROOT/repo-fetch"
  mkdir -p "$dir"
  if ! fm_git_fetch_with_fallback "$dir" origin --prune --quiet; then
    fail "fetch_with_fallback should succeed via HTTPS after SSH failure; out=$FM_GIT_LAST_OUTPUT"
  fi
  [ -f "$TMP_ROOT/git-https-ok" ] \
    || fail "HTTPS fetch path was never taken; argv=$(cat "$TMP_ROOT/git-argv.log")"
  grep -q 'fetch origin' "$TMP_ROOT/git-argv.log" \
    || fail "native origin fetch was never attempted first; argv=$(cat "$TMP_ROOT/git-argv.log")"
  pass "fm_git_fetch_with_fallback retries HTTPS after SSH failure"
}

test_fetch_fallback_does_not_retry_on_unrelated_https_failure() {
  cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/git-argv.log"
if [ "\$1" = "-C" ]; then shift 2; fi
while [ "\$1" = "-c" ]; do shift 2; done
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ]; then
  echo 'https://github.com/kunchenguid/firstmate.git'
  exit 0
fi
if [ "\$1" = "fetch" ]; then
  echo "error: RPC failed; HTTP 500" >&2
  exit 128
fi
exit 3
SH
  chmod +x "$FAKEBIN/git"
  : > "$TMP_ROOT/git-argv.log"
  local dir="$TMP_ROOT/repo-https"
  mkdir -p "$dir"
  if fm_git_fetch_with_fallback "$dir" origin --prune --quiet; then
    fail "unrelated HTTPS failure must not be reported as success"
  fi
  local n
  n=$(grep -cE '(^| )fetch( |$)' "$TMP_ROOT/git-argv.log" || true)
  [ "$n" = "1" ] || fail "expected exactly one fetch attempt, got $n: $(cat "$TMP_ROOT/git-argv.log")"
  pass "fm_git_fetch_with_fallback does not HTTPS-retry a plain HTTPS 500"
}

# --- gitea token resolution (no persist) ------------------------------------

test_gitea_token_reads_env_not_disk_write() {
  export FM_GITEA_TOKEN='env-token-value'
  local got
  got=$(fm_git_gitea_token) || fail "env token should resolve"
  [ "$got" = 'env-token-value' ] || fail "got '$got'"
  unset FM_GITEA_TOKEN
  local tf="$TMP_ROOT/gitea-token"
  printf 'file-token-value\n' > "$tf"
  export FM_GITEA_TOKEN_FILE=$tf
  got=$(fm_git_gitea_token) || fail "file token should resolve"
  [ "$got" = 'file-token-value' ] || fail "file got '$got'"
  unset FM_GITEA_TOKEN_FILE
  if git config --global --get-regexp 'url\..*\.insteadof' 2>/dev/null | grep -q 'oauth2:'; then
    fail "lib must not write token-bearing insteadOf into global git config"
  fi
  pass "fm_git_gitea_token reads env/file and never writes global git config"
}

# --- run --------------------------------------------------------------------

test_ssh_to_https_scp_form
test_ssh_to_https_ssh_url_form
test_ssh_to_https_leaves_https_alone
test_cluster_http_to_public_https
test_ssh_agent_dead_when_sock_unset
test_ssh_agent_dead_when_sock_missing
test_ssh_agent_dead_when_sock_not_socket
test_ssh_agent_live_when_ssh_add_reports_no_identities
test_ssh_agent_dead_when_ssh_add_connection_refused
test_output_looks_like_ssh_failure
test_should_retry_https_for_ssh_url_even_without_signature
test_fetch_fallback_retries_https_after_ssh_failure
test_fetch_fallback_does_not_retry_on_unrelated_https_failure
test_gitea_token_reads_env_not_disk_write

echo "# fm-git-transport-lib.test.sh: all assertions passed"
