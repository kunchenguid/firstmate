#!/usr/bin/env bash
# Behavior tests for custom-check registration and validated retirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-register)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_custom_check() {
  local home=$1 id=$2
  cat > "$home/state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
# Watch a finite fixture subject.
exit 0
SH
  chmod 0700 "$home/state/$id.check.sh"
}

seed_canonical_poll() {
  local home=$1 id=$2 url=https://github.com/o/r/pull/7
  fm_write_meta "$home/state/$id.meta" "window=fm-$id" "pr=$url"
  fm_pr_url_parse "$url" || fail "canonical poll fixture URL was invalid"
  fm_pr_poll_prepare "$home/state" "$id" "$FM_PR_PROVIDER" "$FM_PR_URL" \
    "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$POLL" \
    || fail "could not prepare canonical poll fixture"
  fm_pr_poll_publish_prepared || fail "could not publish canonical poll fixture"
}

test_retire_removes_a_registered_custom_check_only() {
  local home out
  home=$(make_home custom)
  write_custom_check "$home" finite-watch
  printf 'window=keep-me\n' > "$home/state/finite-watch.meta"
  printf 'working: keep me\n' > "$home/state/finite-watch.status"
  FM_HOME="$home" "$REGISTER" finite-watch > /dev/null 2> "$home/register.err" \
    || fail "could not register custom retirement fixture"
  [ ! -s "$home/register.err" ] || fail "successful registration wrote stderr: $(cat "$home/register.err")"

  out=$(FM_HOME="$home" "$REGISTER" retire finite-watch) \
    || fail "registered custom check retirement failed"
  [ "$out" = 'retired: finite-watch' ] || fail "custom retirement output changed: $out"
  assert_absent "$home/state/finite-watch.check.sh" "custom retirement left the check"
  assert_absent "$home/state/finite-watch.check-trust" "custom retirement left the trust binding"
  [ -f "$home/state/finite-watch.meta" ] || fail "custom retirement removed task metadata"
  [ -f "$home/state/finite-watch.status" ] || fail "custom retirement removed task status"

  out=$(FM_HOME="$home" "$REGISTER" retire finite-watch) \
    || fail "repeat retirement was not idempotent"
  [ "$out" = 'retired: finite-watch' ] || fail "repeat retirement output changed: $out"
  pass "retire removes only a validated custom check binding and is idempotent"
}

test_retire_removes_canonical_pr_poll_sidecars() {
  local home out
  home=$(make_home pr-poll)
  seed_canonical_poll "$home" finite-pr
  fm_pr_poll_snapshot_capture "$home/state" finite-pr "$POLL" \
    || fail "could not snapshot canonical poll retirement fixture"
  fm_pr_poll_retirement_publish "$home/state" finite-pr "$POLL" merged \
    || fail "could not publish canonical poll retirement receipt"

  out=$(FM_HOME="$home" "$REGISTER" retire finite-pr) \
    || fail "canonical PR poll retirement failed"
  [ "$out" = 'retired: finite-pr' ] || fail "PR poll retirement output changed: $out"
  assert_absent "$home/state/finite-pr.check.sh" "PR poll retirement left the check"
  assert_absent "$home/state/finite-pr.pr-poll" "PR poll retirement left the data sidecar"
  assert_absent "$home/state/finite-pr.pr-poll-registration" "PR poll retirement left the publication record"
  assert_absent "$home/state/finite-pr.pr-poll-retirement" "PR poll retirement left the crash-recovery receipt"
  [ -f "$home/state/finite-pr.meta" ] || fail "PR poll retirement removed task metadata"
  pass "retire removes a canonical PR poll and its related sidecars"
}

test_retire_refuses_an_unbound_or_unsafe_check() {
  local home alias before rc
  home=$(make_home unsafe)
  write_custom_check "$home" unbound
  rc=0
  FM_HOME="$home" "$REGISTER" retire unbound > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "retirement accepted an unbound check"
  [ -f "$home/state/unbound.check.sh" ] || fail "unbound-check refusal removed the check"

  write_custom_check "$home" linked
  FM_HOME="$home" "$REGISTER" linked > /dev/null 2> "$home/register.err" \
    || fail "could not register hard-link fixture"
  [ ! -s "$home/register.err" ] || fail "successful registration wrote stderr: $(cat "$home/register.err")"
  alias="$home/linked.alias"
  ln "$home/state/linked.check-trust" "$alias"
  before=$(shasum -a 256 "$home/state/linked.check.sh" "$home/state/linked.check-trust")
  rc=0
  FM_HOME="$home" "$REGISTER" retire linked > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "retirement accepted a hard-linked trust binding"
  [ -e "$alias" ] || fail "unsafe retirement removed the external hard link"
  [ "$(shasum -a 256 "$home/state/linked.check.sh" "$home/state/linked.check-trust")" = "$before" ] \
    || fail "unsafe retirement changed the bound check artifacts"
  pass "retire preserves unbound and unsafe check artifacts"
}

test_retire_removes_a_registered_custom_check_only
test_retire_removes_canonical_pr_poll_sidecars
test_retire_refuses_an_unbound_or_unsafe_check
