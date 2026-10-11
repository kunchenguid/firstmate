#!/usr/bin/env bash
# Behavioral tests for GitHub pull requests on a host other than github.com:
# the URL parser, the one default-host rule, the per-command host selection, the
# merge poll, and the bounded state read. Each script that addresses a pull
# request is covered with its own gh stub in its own test file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-github-host-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
unset GH_HOST FM_GITHUB_HOST

# Print the parsed identity of a URL, or "refused". Runs under bash in a
# subshell so each parse starts from clean globals.
parse() {
  bash -c '
    . "$1"
    if fm_pr_url_parse "$2"; then
      printf "%s|%s|%s|%s|%s|%s\n" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER"
    else
      echo refused
    fi
  ' _ "$ROOT/bin/fm-pr-lib.sh" "$1"
}

test_parser_accepts_any_github_host() {
  assert_equals "github|github.com|o/r|o|r|7" "$(parse https://github.com/o/r/pull/7)" \
    "github.com identity changed"
  assert_equals "github|ghe.example.com|my-org/my.repo|my-org|my.repo|42" \
    "$(parse https://ghe.example.com/my-org/my.repo/pull/42)" \
    "a pull request on another host must keep that host"
  assert_equals "github|git.example.org|o/r|o|r|1" "$(parse https://git.example.org/o/r/pull/1)" \
    "a second host must be accepted the same way"
  assert_equals "github|code.corp.example.org|o/r|o|r|9" \
    "$(parse https://code.corp.example.org/o/r/pull/9)" \
    "a multi-label host must be accepted"
  pass "the parser accepts a pull request URL on any valid GitHub host and keeps the host"
}

test_parser_refuses_malformed_urls_on_every_host() {
  local url
  for url in \
    https://ghe.example.com/o/r/pull/0 \
    https://ghe.example.com/o/r/pull/07 \
    https://ghe.example.com/o/r/pull/7/ \
    https://ghe.example.com/o/r/pull/7/files \
    https://ghe.example.com/o/r/pull/7?x=1 \
    https://ghe.example.com/o/r/pull/7#c \
    https://ghe.example.com/o--x/r/pull/7 \
    https://ghe.example.com/-o/r/pull/7 \
    https://ghe.example.com/o/../pull/7 \
    https://ghe.example.com/o/./pull/7 \
    https://ghe.example.com/o/r/pulls/7 \
    http://ghe.example.com/o/r/pull/7 \
    https://GHE.example.com/o/r/pull/7 \
    https://ghe.example.com:8443/o/r/pull/7 \
    https://user@ghe.example.com/o/r/pull/7 \
    https://ghe.example.com./o/r/pull/7 \
    https://.ghe.example.com/o/r/pull/7 \
    https://ghe..example.com/o/r/pull/7 \
    https://-ghe.example.com/o/r/pull/7 \
    https://ghe_x.example.com/o/r/pull/7 \
    https://ghe.example.com/o/pull/7 \
    https://github.com/o/r/pull/7/ \
    https://GITHUB.com/o/r/pull/7; do
    assert_equals refused "$(parse "$url")" "a malformed URL was accepted: $url"
  done
  pass "the parser refuses malformed pull request URLs on every host"
}

test_parser_keeps_other_providers_apart() {
  assert_equals refused "$(parse https://github.com/o/r/-/merge_requests/1)" \
    "a GitLab-shaped URL on github.com must stay refused"
  assert_equals refused "$(parse https://github.com/c/o/+/1)" \
    "a Gerrit-shaped URL on github.com must stay refused"
  assert_equals "gitlab|git.example.org|g/s/p|||5" \
    "$(parse https://git.example.org/g/s/p/-/merge_requests/5)" \
    "a GitLab merge request on another host must stay GitLab"
  assert_equals "gerrit|git.example.org|proj|||3" \
    "$(parse https://git.example.org/c/proj/+/3)" \
    "a Gerrit change must stay Gerrit"
  pass "GitLab and Gerrit shapes keep their providers and github.com stays refused for them"
}

test_default_host_rule() {
  local out
  out=$(bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh")
  assert_equals github.com "$out" "the default host must be github.com"
  out=$(FM_GITHUB_HOST=git.example.org bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh")
  assert_equals git.example.org "$out" "FM_GITHUB_HOST must override the default"
  out=$(FM_GITHUB_HOST=github.com bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh")
  assert_equals github.com "$out" "FM_GITHUB_HOST=github.com must be accepted"
  if FM_GITHUB_HOST='bad host/x' bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh" >/dev/null 2>&1; then
    fail "an invalid FM_GITHUB_HOST was passed on instead of refused"
  fi
  pass "the default host is github.com and overridable with FM_GITHUB_HOST"
}

test_default_host_ignores_ambient_gh_host() {
  local value out
  for value in ghe.example.com GHE.example.com ghe.example.com:8443 'bad host/x'; do
    out=$(GH_HOST=$value bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh") \
      || fail "an exported GH_HOST of '$value' broke the default host lookup"
    assert_equals github.com "$out" "an exported GH_HOST of '$value' must not change the default host"
    out=$(GH_HOST=$value FM_GITHUB_HOST=git.example.org \
      bash -c '. "$1"; fm_github_default_host' _ "$ROOT/bin/fm-pr-lib.sh") \
      || fail "an exported GH_HOST of '$value' broke the FM_GITHUB_HOST lookup"
    assert_equals git.example.org "$out" "FM_GITHUB_HOST must win over an exported GH_HOST of '$value'"
  done
  pass "the default host never reads an exported GH_HOST, whatever its form"
}

test_gh_at_selects_the_host_for_one_command() {
  local log="$TMP_ROOT/at.log"
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_HOST-unset}" "$*" >> "$FM_TEST_AT_LOG"
SH
  chmod +x "$FAKEBIN/gh"
  : > "$log"
  FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" bash -c '
    . "$1"
    fm_gh_at github.com gh api a
    fm_gh_at ghe.example.com gh api b
    fm_gh_at git.example.org gh pr merge 3 --repo o/r
    printf "after=%s\n" "${GH_HOST-unset}" >> "$FM_TEST_AT_LOG"
  ' _ "$ROOT/bin/fm-pr-lib.sh"
  assert_equals $'unset|api a\nghe.example.com|api b\ngit.example.org|pr merge 3 --repo o/r\nafter=unset' "$(cat "$log")" \
    "gh must see the host only for the command addressed at it"
  : > "$log"
  FM_TEST_AT_LOG="$log" GH_HOST=ghe.example.com PATH="$FAKEBIN:$PATH" bash -c '
    . "$1"
    fm_gh_at github.com gh api a
  ' _ "$ROOT/bin/fm-pr-lib.sh"
  assert_equals 'ghe.example.com|api a' "$(cat "$log")" \
    "a github.com address must leave gh's own host selection untouched"
  pass "the host is selected for the one command and github.com is left untouched"
}

test_read_record_targets_the_host() {
  local log="$TMP_ROOT/record.log" out
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_HOST-unset}" "$*" >> "$FM_TEST_AT_LOG"
printf 'state=MERGED\nmerged=true\n'
SH
  chmod +x "$FAKEBIN/gh"
  : > "$log"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" bash -c '
    . "$1"
    fm_pr_github_read_record o r 7 ghe.example.com || exit 1
    printf "%s %s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
  ' _ "$ROOT/bin/fm-pr-lib.sh") || fail "the record read failed"
  assert_equals "MERGED true" "$out" "the record was not read"
  assert_contains "$(cat "$log")" 'ghe.example.com|api graphql' "the record read did not target the host"
  : > "$log"
  if FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" bash -c '. "$1"; fm_pr_github_read_record o r 7' _ "$ROOT/bin/fm-pr-lib.sh"; then
    fail "a record read without a host must be refused"
  fi
  [ ! -s "$log" ] || fail "a record read without a host reached gh: $(cat "$log")"
  pass "the pull request record is read at the given host"
}

# The poll runs from a sidecar, so it is driven directly with the validated
# identity it would have been armed with.
test_poll_reads_the_pull_request_at_its_host() {
  local log="$TMP_ROOT/poll.log" out longhost longlabel
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_HOST-unset}" "$*" >> "$FM_TEST_AT_LOG"
printf 'MERGED\n'
SH
  chmod +x "$FAKEBIN/gh"
  : > "$log"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://ghe.example.com/o/r/pull/7 ghe.example.com o/r 7)
  assert_equals merged "$out" "a merged pull request on another host did not report merged"
  assert_equals 'ghe.example.com|pr view https://ghe.example.com/o/r/pull/7 --json state -q .state' "$(cat "$log")" \
    "the poll did not read the pull request at its own host"

  : > "$log"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://github.com/o/r/pull/7 github.com o/r 7)
  assert_equals merged "$out" "a merged github.com pull request did not report merged"
  assert_equals 'unset|pr view https://github.com/o/r/pull/7 --json state -q .state' "$(cat "$log")" \
    "the github.com poll must be unchanged"

  : > "$log"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://git.example.org/o/r/pull/7 ghe.example.com o/r 7)
  [ -z "$out" ] && [ ! -s "$log" ] \
    || fail "a URL that does not match its recorded host must not be polled: $out $(cat "$log")"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://GHE.example.com/o/r/pull/7 GHE.example.com o/r 7)
  [ -z "$out" ] && [ ! -s "$log" ] \
    || fail "a non-canonical host must not be polled: $out $(cat "$log")"

  : > "$log"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://-ghe.example.com/o/r/pull/7 -ghe.example.com o/r 7)
  [ -z "$out" ] && [ ! -s "$log" ] \
    || fail "a host with a leading-hyphen label must not be polled: $out $(cat "$log")"
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://ghe-.example.com/o/r/pull/7 ghe-.example.com o/r 7)
  [ -z "$out" ] && [ ! -s "$log" ] \
    || fail "a host with a trailing-hyphen label must not be polled: $out $(cat "$log")"
  longlabel=$(printf 'a%.0s' {1..64})
  longhost=$longlabel.example.com
  out=$(FM_TEST_AT_LOG="$log" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github "https://$longhost/o/r/pull/7" "$longhost" o/r 7)
  [ -z "$out" ] && [ ! -s "$log" ] \
    || fail "a host with an over-long label must not be polled: $out $(cat "$log")"
  pass "the merge poll reads a pull request at its own host and refuses an inconsistent record"
}

test_parser_accepts_any_github_host
test_parser_refuses_malformed_urls_on_every_host
test_parser_keeps_other_providers_apart
test_default_host_rule
test_default_host_ignores_ambient_gh_host
test_gh_at_selects_the_host_for_one_command
test_read_record_targets_the_host
test_poll_reads_the_pull_request_at_its_host
