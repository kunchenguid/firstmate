#!/usr/bin/env bash
# bin/fm-forge-detect.sh proposes a clone's forge binding at project-add intake
# from protocol facts in its own git config, and never records anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-forge-detect-tests)
DETECT="$ROOT/bin/fm-forge-detect.sh"

new_clone() {  # <name>
  local dir="$TMP_ROOT/$1"
  git init -q "$dir"
  printf '%s\n' "$dir"
}

test_ssh_port_29418_proposes_gerrit() {
  local clone out
  clone=$(new_clone ssh-port)
  git -C "$clone" remote add origin ssh://someone@review.example:29418/group/apps/console
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with an origin"
  case "$out" in
    'forge=gerrit evidence='*'29418'*) ;;
    *) fail "an origin on SSH port 29418 did not propose gerrit with its evidence: $out" ;;
  esac
  pass "an origin on SSH port 29418 proposes forge=gerrit and names the evidence"
}

test_refs_for_push_refspec_proposes_gerrit() {
  local clone out
  clone=$(new_clone refs-for)
  git -C "$clone" remote add origin https://review.example/group/apps/console
  git -C "$clone" config --add remote.origin.push 'HEAD:refs/for/master'
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with a push refspec"
  case "$out" in
    'forge=gerrit evidence='*'refs/for/'*) ;;
    *) fail "a refs/for push refspec did not propose gerrit with its evidence: $out" ;;
  esac
  pass "a refs/for/ push refspec proposes forge=gerrit and names the evidence"
}

test_other_remotes_propose_none() {
  local clone out
  clone=$(new_clone github)
  git -C "$clone" remote add origin git@github.com:owner/repo.git
  out=$("$DETECT" "$clone") || fail "detection failed on a GitHub clone"
  [ "$out" = forge=none ] || fail "a GitHub origin proposed a forge: $out"

  clone=$(new_clone other-port)
  git -C "$clone" remote add origin ssh://git@gitlab.example:2222/group/project.git
  out=$("$DETECT" "$clone") || fail "detection failed on a non-Gerrit SSH port"
  [ "$out" = forge=none ] || fail "an SSH origin on another port proposed a forge: $out"

  # Port 29418 in the path is not the SSH port, so it is not evidence.
  clone=$(new_clone port-in-path)
  git -C "$clone" remote add origin ssh://git@host.example/29418/project.git
  out=$("$DETECT" "$clone") || fail "detection failed on a path containing 29418"
  [ "$out" = forge=none ] || fail "29418 in the path was read as the SSH port: $out"

  clone=$(new_clone no-origin)
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with no origin"
  [ "$out" = forge=none ] || fail "a clone with no origin proposed a forge: $out"
  pass "a remote carrying neither Gerrit fact proposes forge=none"
}

# An origin on an Azure DevOps Services host proposes azure-devops, in both
# HTTPS URL forms and the SSH form, and the evidence names only the host: an
# HTTPS remote can carry a personal access token as its userinfo.
test_azure_devops_hosts_propose_azure_devops() {
  local clone out url host
  for url in \
    'https://fabrikam@dev.azure.com/fabrikam/Fabrikam/_git/web-app|dev.azure.com' \
    'https://fabrikam.visualstudio.com/DefaultCollection/Assistant/_git/Assistant|fabrikam.visualstudio.com' \
    'https://contoso.visualstudio.com/DefaultCollection/Contoso%20Core/_git/Evaluation|contoso.visualstudio.com' \
    'git@ssh.dev.azure.com:v3/fabrikam/Fabrikam/web-app|ssh.dev.azure.com' \
    'https://someone:fixture-token-value@Dev.Azure.com/org/project/_git/repo|dev.azure.com'
  do
    host=${url##*|}
    url=${url%|*}
    clone=$(new_clone "ado-$(printf '%s' "$url" | cksum | cut -d' ' -f1)")
    git -C "$clone" remote add origin "$url"
    out=$("$DETECT" "$clone") || fail "detection failed on an Azure DevOps origin"
    [ "$out" = "forge=azure-devops evidence=origin remote host $host is an Azure DevOps Services host" ] \
      || fail "an Azure DevOps origin did not propose azure-devops naming only its host: $out"
  done

  clone=$(new_clone ado-lookalike)
  git -C "$clone" remote add origin https://dev.azure.com.example/org/project/_git/repo
  out=$("$DETECT" "$clone") || fail "detection failed on a lookalike host"
  [ "$out" = forge=none ] || fail "a host that only starts with dev.azure.com proposed a forge: $out"

  clone=$(new_clone ado-gerrit-wins)
  git -C "$clone" remote add origin https://dev.azure.com/org/project/_git/repo
  git -C "$clone" config --add remote.origin.push 'HEAD:refs/for/master'
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with both facts"
  case "$out" in
    forge=gerrit*) ;;
    *) fail "a Gerrit push refspec no longer took precedence over the host: $out" ;;
  esac
  pass "an Azure DevOps Services origin host proposes forge=azure-devops and names only the host"
}

test_detection_writes_nothing() {
  local clone before after
  clone=$(new_clone read-only)
  git -C "$clone" remote add origin ssh://someone@review.example:29418/proj
  before=$(git -C "$clone" config --list --local | LC_ALL=C sort)
  "$DETECT" "$clone" >/dev/null || fail "detection failed"
  after=$(git -C "$clone" config --list --local | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "detection changed the clone's git config"
  pass "detection reads the clone's config and changes nothing"
}

test_not_a_clone_is_an_error() {
  local out rc
  mkdir -p "$TMP_ROOT/plain-dir"
  out=$("$DETECT" "$TMP_ROOT/plain-dir" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a plain directory did not exit 2 (got $rc)"
  assert_contains "$out" "not a git work tree" "the error did not say why"
  pass "a directory that is not a git work tree is refused with exit 2"
}

test_ssh_port_29418_proposes_gerrit
test_refs_for_push_refspec_proposes_gerrit
test_other_remotes_propose_none
test_azure_devops_hosts_propose_azure_devops
test_detection_writes_nothing
test_not_a_clone_is_an_error
echo "# all fm-forge-detect tests passed"
