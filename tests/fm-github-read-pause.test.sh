#!/usr/bin/env bash
# Durable no-GitHub-read pause behavior across startup and PR registration.
# The initiating triggers are bootstrap's owned-contribution adoption and later
# fm-pr-check registration. The independent GitHub-auth diagnostic never gates
# either local publisher, so the visible symptom was a retired *.check.sh name
# silently returning while credentials were still intentionally unavailable.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-github-read-pause)
PAUSE="$ROOT/bin/fm-github-read-pause.sh"
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data/delivery" "$home/config" "$home/projects" \
    "$home/wt" "$home/fakebin" "$home/root/bin"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '# Backlog\n\n## Queued\n- [ ] delivery - Delivery https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    > "$home/data/backlog.md"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  jq -n --arg head "$HEAD" '{schema:"fm-contributions.v1",task:"delivery",records:[{
    url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:"2026-09-16T08:00:00Z",
    error:null,pending:[],seen:[],notified:[],verdict:null,
    observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
      review_decision:"APPROVED",can_merge:false,checks:[],reviews:[],events:[]}}]}' \
    > "$home/data/delivery/contributions.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${GH_CALLS:-}" ] || printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) printf '%s\n' "$TEST_HEAD" ;;
  auth\ status*) exit 1 ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/glab"
  chmod +x "$home/fakebin/glab"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf '%s\n' "$home"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" GH_CALLS="$home/gh.calls" TEST_HEAD="$HEAD" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home/root" "$@"
}

arm_pr() {
  local home=$1
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
}

pause_home() {
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$ROOT" "$PAUSE" pause >/dev/null
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

assert_retired_with_records() {
  local home=$1
  assert_absent "$home/state/contributions.check.sh" "pause left contribution observation armed"
  assert_absent "$home/state/contributions.check-trust" "pause left contribution trust armed"
  assert_absent "$home/state/delivery.check.sh" "pause left GitHub merge polling armed"
  assert_present "$home/state/delivery.pr-poll" "pause removed the resumable PR sidecar"
  assert_present "$home/state/delivery.pr-poll-registration" "pause removed PR registration data"
  assert_present "$home/data/delivery/contributions.json" "pause removed contribution records"
  assert_grep 'pr=https://github.com/o/r/pull/8' "$home/state/delivery.meta" "pause removed PR metadata"
  assert_grep "pr_head=$HEAD" "$home/state/delivery.meta" "pause removed PR head metadata"
}

test_startup_respects_pause() {
  local home record_hash poll_hash registration_hash out
  home=$(new_home startup)
  arm_pr "$home" || fail "could not establish the startup fixture"
  pause_home "$home" || fail "could not establish the durable GitHub-read pause"
  assert_retired_with_records "$home"
  : > "$home/gh.calls"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail "the contribution observer could not remain inert under the pause"
  [ ! -s "$home/gh.calls" ] || fail "paused contribution polling invoked GitHub: $(cat "$home/gh.calls")"
  record_hash=$(file_hash "$home/data/delivery/contributions.json")
  poll_hash=$(file_hash "$home/state/delivery.pr-poll")
  registration_hash=$(file_hash "$home/state/delivery.pr-poll-registration")

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh") || fail "local startup failed under the pause: $out"

  assert_retired_with_records "$home"
  [ "$(file_hash "$home/data/delivery/contributions.json")" = "$record_hash" ] \
    || fail "startup changed a preserved contribution record while reads were paused"
  [ "$(file_hash "$home/state/delivery.pr-poll")" = "$poll_hash" ] \
    || fail "startup changed a preserved PR sidecar while reads were paused"
  [ "$(file_hash "$home/state/delivery.pr-poll-registration")" = "$registration_hash" ] \
    || fail "startup changed preserved PR registration data while reads were paused"
  pass "startup keeps GitHub observers retired while preserving resumable records"
}

test_pr_registration_respects_pause_without_github() {
  local home record_hash
  home=$(new_home registration)
  arm_pr "$home" || fail "could not establish the PR-registration fixture"
  pause_home "$home" || fail "could not establish the durable GitHub-read pause"
  record_hash=$(file_hash "$home/data/delivery/contributions.json")
  : > "$home/gh.calls"

  arm_pr "$home" || fail "PR registration should retain local metadata while GitHub reads are paused"

  [ ! -s "$home/gh.calls" ] || fail "paused PR registration invoked GitHub: $(cat "$home/gh.calls")"
  assert_retired_with_records "$home"
  [ "$(file_hash "$home/data/delivery/contributions.json")" = "$record_hash" ] \
    || fail "paused PR registration changed a contribution record"
  pass "later PR registration stays local and cannot re-arm either GitHub reader"
}

test_normal_registration_still_arms() {
  local home out
  home=$(new_home normal)
  arm_pr "$home" || fail "ordinary PR registration failed without a pause"
  assert_present "$home/state/delivery.check.sh" "ordinary registration did not arm merge polling"
  assert_present "$home/state/contributions.check.sh" "ordinary registration did not arm contribution observation"
  assert_present "$home/state/contributions.check-trust" "ordinary contribution registration lacks trust"
  [ -s "$home/gh.calls" ] || fail "ordinary GitHub registration did not perform its normal forge reads"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-check-unregister.sh" contributions >/dev/null \
    || fail "could not retire the normal startup fixture"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh") || fail "normal local startup failed: $out"
  assert_present "$home/state/contributions.check.sh" "ordinary startup did not re-arm contribution observation"
  pass "normal startup and PR registration still arm observers when no pause exists"
}

test_marker_blocks_a_snapshotted_reader_before_retirement() {
  local home rc
  home=$(new_home marker-first)
  arm_pr "$home" || fail "could not establish the marker-first fixture"
  printf 'fm-github-read-pause-v1\n' > "$home/state/.github-read-pause"
  chmod 600 "$home/state/.github-read-pause"
  : > "$home/gh.calls"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 \
    FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
    > "$home/watcher.out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "paused watcher did not remain silent: $(cat "$home/watcher.out") $(cat "$home/watcher.err")"
  [ ! -s "$home/gh.calls" ] || fail "a reader snapshotted before retirement invoked GitHub: $(cat "$home/gh.calls")"
  pass "the marker blocks an already snapshotted reader before local retirement finishes"
}

test_pause_does_not_retire_gitlab_polling() {
  local home
  home=$(new_home gitlab)
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery \
    https://gitlab.example/group/repo/-/merge_requests/7 >/dev/null \
    || fail "could not establish the GitLab disconfirming fixture"
  : > "$home/gh.calls"
  pause_home "$home" || fail "could not pause GitHub readers beside a GitLab poll"
  assert_present "$home/state/delivery.check.sh" "GitHub-only pause retired GitLab polling"
  assert_absent "$home/state/contributions.check.sh" "GitHub contribution observation remained armed"
  [ ! -s "$home/gh.calls" ] || fail "pausing beside GitLab invoked GitHub"
  pass "the GitHub-only pause leaves GitLab merge polling active"
}

test_pause_is_idempotent_and_preserves_records() {
  local home before after
  home=$(new_home idempotent)
  arm_pr "$home" || fail "could not establish the idempotence fixture"
  before=$(file_hash "$home/data/delivery/contributions.json")
  pause_home "$home" || fail "first pause failed"
  pause_home "$home" || fail "repeated pause failed"
  after=$(file_hash "$home/data/delivery/contributions.json")
  [ "$before" = "$after" ] || fail "repeated pause changed durable contribution evidence"
  assert_retired_with_records "$home"
  pass "the durable pause owner is idempotent and non-destructive"
}

test_startup_respects_pause
test_pr_registration_respects_pause_without_github
test_normal_registration_still_arms
test_marker_blocks_a_snapshotted_reader_before_retirement
test_pause_does_not_retire_gitlab_polling
test_pause_is_idempotent_and_preserves_records
