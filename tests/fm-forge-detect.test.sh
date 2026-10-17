#!/usr/bin/env bash
# bin/fm-forge-detect.sh proposes a clone's forge binding at project-add intake
# from protocol facts in its own git config or, for GitLab, from the origin host
# and glab's local config, and never records anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-forge-detect-tests)
DETECT="$ROOT/bin/fm-forge-detect.sh"
# Never read this machine's own glab setup; the cases that need one write it.
GLAB_CONFIG_DIR="$TMP_ROOT/no-glab-config"
export GLAB_CONFIG_DIR
FAKE_SSH_BIN=$(fm_fakebin "$TMP_ROOT/ssh")
cat > "$FAKE_SSH_BIN/ssh" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do target=$arg; done
host=${target##*@}
case "$host" in git-storage) host=code.corp.example ;; esac
printf 'hostname %s\n' "$host"
SH
chmod +x "$FAKE_SSH_BIN/ssh"
PATH="$FAKE_SSH_BIN:$PATH"
export PATH

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
  git -C "$clone" remote add origin ssh://git@git.example:2222/group/project.git
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

test_gitlab_host_proposes_gitlab() {
  local clone out url
  for url in git@gitlab.example.com:group/project.git https://gitlab.com/group/sub/project.git \
    ssh://git@GitLab.Example.com:2222/group/project.git; do
    clone=$(new_clone "gitlab-host-$RANDOM")
    git -C "$clone" remote add origin "$url"
    out=$("$DETECT" "$clone") || fail "detection failed on $url"
    case "$out" in
      'forge=gitlab evidence=origin host '*' names GitLab') ;;
      *) fail "an origin on a GitLab-named host did not propose gitlab with its evidence: $out" ;;
    esac
  done
  clone=$(new_clone gitlab-token-origin)
  git -C "$clone" remote add origin 'https://oauth2:not-a-real-token@gitlab.example.com/group/project.git'
  out=$("$DETECT" "$clone") || fail "detection failed on an authenticated origin"
  [ "$out" = 'forge=gitlab evidence=origin host gitlab.example.com names GitLab' ] \
    || fail "forge evidence did not contain only the safe hostname"
  assert_not_contains "$out" 'not-a-real-token' "forge evidence leaked an origin credential"
  # A host that merely contains the word is not a GitLab label.
  clone=$(new_clone gitlab-substring)
  git -C "$clone" remote add origin git@mygitlab.example:group/project.git
  out=$("$DETECT" "$clone") || fail "detection failed on a host containing gitlab"
  [ "$out" = forge=none ] || fail "a host merely containing gitlab proposed a forge: $out"
  pass "an origin host that is or has the label gitlab proposes forge=gitlab"
}

test_glab_configured_host_proposes_gitlab() {
  local clone out config_dir="$TMP_ROOT/glab-config"
  mkdir -p "$config_dir"
  printf '%s\n' 'host: code.corp.example' 'hosts:' '    gitlab.com:' '        api_host: gitlab.com' \
    '    code.corp.example:' '        api_host: code.corp.example' '        user: someone' \
    'no_prompt: false' > "$config_dir/config.yml"
  clone=$(new_clone glab-host)
  git -C "$clone" remote add origin git@code.corp.example:group/project.git
  out=$(GLAB_CONFIG_DIR="$config_dir" "$DETECT" "$clone") || fail "detection failed with a glab config"
  [ "$out" = "forge=gitlab evidence=origin host code.corp.example is configured in glab ($config_dir/config.yml)" ] \
    || fail "a glab-configured host did not propose gitlab with its evidence: $out"
  # A setting nested under a host is not itself a host.
  clone=$(new_clone glab-setting)
  git -C "$clone" remote add origin git@api_host:group/project.git
  out=$(GLAB_CONFIG_DIR="$config_dir" "$DETECT" "$clone") || fail "detection failed with a glab config"
  [ "$out" = forge=none ] || fail "a nested glab setting was read as a host: $out"
  # Gerrit's protocol fact outranks a glab-configured host.
  clone=$(new_clone glab-and-gerrit)
  git -C "$clone" remote add origin ssh://someone@code.corp.example:29418/project
  out=$(GLAB_CONFIG_DIR="$config_dir" "$DETECT" "$clone") || fail "detection failed with a glab config"
  case "$out" in
    'forge=gerrit evidence='*) ;;
    *) fail "a Gerrit SSH port lost to a glab-configured host: $out" ;;
  esac
  clone=$(new_clone glab-ssh-alias)
  git -C "$clone" remote add origin git@git-storage:group/project.git
  out=$(GLAB_CONFIG_DIR="$config_dir" "$DETECT" "$clone") || fail "SSH-alias intake failed"
  assert_contains "$out" 'forge=gitlab evidence=origin host code.corp.example is configured in glab' \
    "intake did not resolve the SSH alias to the configured host"
  pass "an origin host configured in glab proposes forge=gitlab, below Gerrit's protocol facts"
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
test_gitlab_host_proposes_gitlab
test_glab_configured_host_proposes_gitlab
test_detection_writes_nothing
test_not_a_clone_is_an_error
echo "# all fm-forge-detect tests passed"
