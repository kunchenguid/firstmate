#!/usr/bin/env bash
# Behavior tests for bin/fm-latent.sh.
# Every case uses disposable Git repositories and a temporary Treehouse pool.
# No live fleet task, worktree, branch, remote, or pull request is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LATENT="$ROOT/bin/fm-latent.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-latent-tests)

[ -x "$LATENT" ] || fail "fm-latent.sh is missing"

write_fakes() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "pr view" ]; then
  case "$*" in
    *reviewDecision*) printf '%s\t%s\t%s\n' "${FM_FAKE_GH_STATE:-OPEN}" "${FM_FAKE_GH_HEAD:-}" "${FM_FAKE_GH_REVIEW:-}" ;;
    *'--json headRefOid'*) printf '%s\n' "${FM_FAKE_GH_HEAD:-}" ;;
    *) printf '%s\t%s\n' "${FM_FAKE_GH_STATE:-OPEN}" "${FM_FAKE_GH_HEAD:-}" ;;
  esac
  exit 0
fi
exit 1
SH
  cp "$fakebin/gh" "$fakebin/gh-axi"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
cmd=${1:-}
shift || true
case "$cmd" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  new-window)
    : > "${FM_FAKE_TMUX_ENDPOINT:?}"
    printf '@latent\n'
    ;;
  list-windows)
    if [ -e "${FM_FAKE_TMUX_ENDPOINT:?}" ]; then
      printf 'fm-%s\n' "${FM_FAKE_TASK_ID:?}"
    fi
    ;;
  kill-window)
    rm -f -- "${FM_FAKE_TMUX_ENDPOINT:?}"
    ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*)
        if [ -e "${FM_FAKE_TMUX_GOT_TREEHOUSE:?}" ]; then
          printf '%s\n' "${FM_FAKE_RESUME_WT:?}"
        else
          printf '%s\n' "${FM_FAKE_PROJECT:?}"
        fi
        ;;
      *'#{pane_current_command}'*) printf 'zsh\n' ;;
      *'#{pane_tty}'*) printf '\n' ;;
      *'#{pane_pid}'*) printf '%s\n' "$$" ;;
      *'#{pane_id}'*) printf '%%latent\n' ;;
      *'#S'*) printf 'fleet\n' ;;
    esac
    ;;
  send-keys)
    case "$*" in *'treehouse get'*) : > "${FM_FAKE_TMUX_GOT_TREEHOUSE:?}" ;; esac
    ;;
  capture-pane) printf '\n' ;;
  show-options) printf '0\n' ;;
  set-option|select-window) ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/no-mistakes" "$fakebin/tmux"
}

make_case() {
  local name=$1 seed clone
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  PROJECT="$CASE/project"
  ORIGIN="$CASE/origin.git"
  POOL="$CASE/pool"
  FAKEBIN="$CASE/fakebin"
  ID="latent-$name"
  BRANCH="fm/$name"
  URL="https://github.com/example/project/pull/1"
  ENDPOINT="$CASE/endpoint"
  GOT_TREEHOUSE="$CASE/got-treehouse"
  mkdir -p "$STATE" "$DATA/$ID" "$HOME_DIR/config" "$FAKEBIN"
  write_fakes "$FAKEBIN"

  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  seed="$CASE/seed"
  git init -q -b main "$seed"
  git -C "$seed" config user.name fmtest
  git -C "$seed" config user.email fmtest@example.invalid
  printf 'base\n' > "$seed/file.txt"
  printf 'max_trees = 2\nroot = "%s"\n' "$POOL" > "$seed/treehouse.toml"
  git -C "$seed" add file.txt treehouse.toml
  git -C "$seed" commit -qm base
  git -C "$seed" remote add origin "$ORIGIN"
  git -C "$seed" push -q -u origin main
  git clone -q "$ORIGIN" "$PROJECT"
  git -C "$PROJECT" config user.name fmtest
  git -C "$PROJECT" config user.email fmtest@example.invalid
  WT=$(cd "$PROJECT" && treehouse get --lease --lease-holder "$ID" 2>/dev/null) || fail "$name: temporary Treehouse acquire failed"
  git -C "$WT" checkout -qb "$BRANCH"
  printf '%s\n' "$name" >> "$WT/file.txt"
  git -C "$WT" add file.txt
  git -C "$WT" commit -qm "$name"
  HEAD_OID=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" push -q origin "HEAD:refs/heads/$BRANCH"
  git -C "$ORIGIN" update-ref refs/pull/1/head "$HEAD_OID"
  git -C "$PROJECT" fetch -q origin "refs/pull/1/head"

  cat > "$STATE/$ID.meta" <<EOF
window=fleet:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJECT
harness=codex
kind=ship
mode=direct-PR
yolo=off
tasktmp=$CASE/tasktmp
model=default
effort=default
pr=$URL
pr_head=$HEAD_OID
pr_ready_head=$HEAD_OID
EOF
  chmod 0600 "$STATE/$ID.meta"
  printf 'done: PR %s\n' "$URL" > "$STATE/$ID.status"
  mkdir -p "$CASE/tasktmp" "$DATA/$ID"
  printf '# Original task\n\nDelivery contract: mode=direct-PR\n' > "$DATA/$ID/brief.md"
  : > "$ENDPOINT"
  rm -f "$GOT_TREEHOUSE"
  export FM_FAKE_TASK_ID="$ID" FM_FAKE_TMUX_ENDPOINT="$ENDPOINT"
  export FM_FAKE_TMUX_GOT_TREEHOUSE="$GOT_TREEHOUSE" FM_FAKE_PROJECT="$PROJECT"
  export FM_FAKE_RESUME_WT="$WT" FM_FAKE_GH_STATE=OPEN FM_FAKE_GH_HEAD="$HEAD_OID"
  FM_FAKE_GH_REVIEW=''
  FM_FAKE_AXI_STATUS=''
  export FM_FAKE_GH_REVIEW FM_FAKE_AXI_STATUS

  FM_STATE_FIXTURE="$STATE" FM_ID_FIXTURE="$ID" FM_URL_FIXTURE="$URL" \
    bash -c '. "$1"; fm_pr_url_parse "$2"; fm_pr_poll_prepare "$3" "$4" "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$5"; fm_pr_poll_publish_prepared' \
      _ "$ROOT/bin/fm-pr-lib.sh" "$URL" "$STATE" "$ID" "$POLL" \
      || fail "$name: canonical PR poll fixture failed"
}

run_latent() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$LATENT" "$@"
}

expect_refusal() {
  local description=$1
  shift
  set +e
  "$@" > "$CASE/refusal.out" 2>&1
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: command unexpectedly succeeded"
}

replace_meta_head() {
  local oid=$1 tmp="$STATE/.meta.tmp"
  sed -e "s/^pr_head=.*/pr_head=$oid/" -e "s/^pr_ready_head=.*/pr_ready_head=$oid/" "$STATE/$ID.meta" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$STATE/$ID.meta"
  FM_FAKE_GH_HEAD=$oid
  export FM_FAKE_GH_HEAD
}

new_pr_head() {
  local mode=${1:-descendant} clone="$CASE/pr-head" parent
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" config user.name fmtest
  git -C "$clone" config user.email fmtest@example.invalid
  if [ "$mode" = descendant ]; then
    git -C "$clone" checkout -q "$BRANCH"
  else
    git -C "$clone" checkout -q main
  fi
  printf '%s\n' "$mode-$(date +%s%N)" >> "$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" commit -qm "$mode head"
  parent=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" push -q origin "HEAD:refs/heads/fm-latent-test-head"
  git -C "$ORIGIN" update-ref refs/pull/1/head "$parent"
  git -C "$ORIGIN" update-ref -d refs/heads/fm-latent-test-head
  git -C "$PROJECT" fetch -q origin "refs/pull/1/head"
  printf '%s\n' "$parent"
}

assert_latent() {
  local out
  if ! out=$(run_latent verify "$ID"); then
    printf '%s\n' "verify output: $out" >&2
    printf '%s\n' 'metadata:' >&2
    cat "$STATE/$ID.meta" >&2
    printf '%s\n' 'manifest:' >&2
    cat "$DATA/$ID/latent/manifest" >&2
    fail "$ID: latent verification failed"
  fi
  [ "$out" = latent ] || fail "$ID: expected latent, got $out"
  [ ! -e "$ENDPOINT" ] || fail "$ID: backend endpoint survived hibernation"
  [ "$(grep '^window=' "$STATE/$ID.meta")" = 'window=' ] || fail "$ID: endpoint metadata survived hibernation"
  [ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$(grep '^pr_head=' "$STATE/$ID.meta" | cut -d= -f2-)" ] \
    || fail "$ID: protected ref does not match recorded PR head"
  [ "$(cd "$PROJECT" && treehouse status --json | jq -r '.[0].status')" = available ] \
    || fail "$ID: temporary Treehouse slot was not released"
}

# Exact-head entry.
make_case exact
run_latent enter "$ID" >/dev/null || fail "clean exact-head entry failed"
assert_latent
CREW_STATE=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-crew-state.sh" "$ID")
case "$CREW_STATE" in 'state: latent · source: latent-manifest'*) ;; *) fail "crew-state did not report latent: $CREW_STATE" ;; esac
expect_refusal "ordinary steer to latent task" env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-send.sh" "$ID" continue
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-sync.sh" "$PROJECT" >/dev/null \
  || fail "fleet sync refused a healthy project with a protected latent ref"
[ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$HEAD_OID" ] || fail "fleet sync pruned a latent recovery ref"
expect_refusal "project removal with latent task" run_latent project-removal-check "$PROJECT"
SNAPSHOT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh") \
  || fail "fleet snapshot failed for latent task"
[ "$(printf '%s' "$SNAPSHOT" | jq -r '.tasks[0].lifecycle.tier')" = latent ] || fail "fleet snapshot omitted latent tier"
[ "$(printf '%s' "$SNAPSHOT" | jq -r '.tasks[0].lifecycle.integrity')" = valid ] || fail "fleet snapshot omitted latent integrity"
pass "latent entry seals an exact clean PR head, releases its temporary Treehouse slot, and integrates with fleet reads and guards"

# The ready registration is a durable trigger, independent of the last status verb.
make_case auto-ready
rm -f "$STATE/$ID.check.sh" "$STATE/$ID.pr-poll" "$STATE/$ID.pr-poll-registration"
awk '!/^pr(_head|_ready_head)?=/' "$STATE/$ID.meta" > "$STATE/.meta.tmp"
chmod 0600 "$STATE/.meta.tmp"
mv "$STATE/.meta.tmp" "$STATE/$ID.meta"
printf 'resolved [key=bookkeeping]: appended after the completion event\n' >> "$STATE/$ID.status"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" >/dev/null \
  || fail "GitHub ready registration failed"
assert_latent
pass "GitHub ready registration records durable eligibility and hibernates despite later status bookkeeping"

# Local HEAD may lag the PR head when it is an ancestor.
make_case ancestor
PR_DESCENDANT=$(new_pr_head descendant)
replace_meta_head "$PR_DESCENDANT"
run_latent enter "$ID" >/dev/null || fail "local-head-ancestor entry failed"
assert_latent
pass "latent entry accepts a clean local HEAD that is an ancestor of the exact PR head"

# Dirty and divergent local state remain active.
make_case dirty
printf 'dirty\n' >> "$WT/file.txt"
expect_refusal "dirty worktree" run_latent enter "$ID"
[ -e "$ENDPOINT" ] || fail "dirty refusal terminated the worker"
pass "latent entry refuses dirty state without terminating the worker"

make_case divergent
printf 'divergent\n' >> "$WT/file.txt"
git -C "$WT" add file.txt
git -C "$WT" commit -qm divergent
expect_refusal "divergent local head" run_latent enter "$ID"
[ -e "$ENDPOINT" ] || fail "divergence refusal terminated the worker"
pass "latent entry refuses a local head outside the protected PR history"

# A forge OID that cannot be fetched exactly is not recoverability proof.
make_case missing-object
MISSING_OID=1111111111111111111111111111111111111111
replace_meta_head "$MISSING_OID"
expect_refusal "missing PR object" run_latent enter "$ID"
[ ! -e "$DATA/$ID/latent/manifest" ] || fail "missing object produced a manifest"
pass "latent entry refuses when the exact PR object cannot be fetched"

make_case gitlab
GITLAB_URL=https://gitlab.example/group/project/-/merge_requests/1
sed "s#^pr=.*#pr=$GITLAB_URL#" "$STATE/$ID.meta" > "$STATE/.meta.tmp"
chmod 0600 "$STATE/.meta.tmp"
mv "$STATE/.meta.tmp" "$STATE/$ID.meta"
expect_refusal "GitLab v1 exclusion" run_latent enter "$ID"
[ -e "$ENDPOINT" ] || fail "GitLab exclusion terminated the worker"
pass "GitLab tasks stay active until an exact GitLab head identity path exists"

# Force-push and branch deletion never move or erase the saved generation.
make_case force-push
SAVED=$HEAD_OID
run_latent enter "$ID" >/dev/null || fail "force-push setup entry failed"
NEW_HEAD=$(new_pr_head divergent)
FM_FAKE_GH_HEAD=$NEW_HEAD
export FM_FAKE_GH_HEAD
TOKEN=$(PATH="$FAKEBIN:$PATH" "$POLL" --validated github "$URL" github.com example/project 1 "$SAVED" '')
[ "$TOKEN" = "head-changed:$NEW_HEAD" ] || fail "force-push transition token was $TOKEN"
run_latent transition "$ID" "$TOKEN"
[ "$(run_latent verify "$ID")" = attention ] || fail "force-push did not move latent task to attention"
[ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$SAVED" ] || fail "force-push moved the saved recovery ref"
pass "force-push becomes attention while the old generation stays pinned"

make_case deleted-branch
SAVED=$HEAD_OID
run_latent enter "$ID" >/dev/null || fail "deleted-branch setup entry failed"
git -C "$ORIGIN" update-ref -d "refs/heads/$BRANCH"
git -C "$ORIGIN" update-ref -d refs/pull/1/head
[ "$(run_latent verify "$ID")" = latent ] || fail "remote branch deletion invalidated the local recovery proof"
[ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$SAVED" ] || fail "deleted branch erased the saved commit"
pass "remote branch deletion leaves the protected local generation recoverable"

# Integrity failures quarantine rather than guessing.
make_case missing-ref
run_latent enter "$ID" >/dev/null || fail "missing-ref setup entry failed"
git -C "$PROJECT" update-ref -d "refs/firstmate/latent/$ID"
expect_refusal "missing recovery ref" run_latent verify "$ID"
grep -Fxq quarantined "$CASE/refusal.out" || fail "missing ref did not report quarantined"
pass "missing latent ref reports quarantined"

make_case corrupt-manifest
run_latent enter "$ID" >/dev/null || fail "corrupt-manifest setup entry failed"
printf 'corrupt\n' > "$DATA/$ID/latent/manifest"
chmod 0600 "$DATA/$ID/latent/manifest"
expect_refusal "corrupt manifest" run_latent verify "$ID"
grep -Fxq quarantined "$CASE/refusal.out" || fail "corrupt manifest did not report quarantined"
pass "corrupt latent manifest reports quarantined"

# The keyed fold, not the last event, owns decision eligibility.
make_case buried-decision
cat > "$STATE/$ID.status" <<'EOF'
needs-decision [key=api]: choose the API
paused: waiting for review
EOF
expect_refusal "decision masked by later pause" run_latent enter "$ID"
[ -e "$ENDPOINT" ] || fail "buried decision refusal terminated the worker"
pass "an open keyed decision masked by a later pause keeps the task active"

# A pause tail is deliberately not a tier predicate: benign bookkeeping after a
# pause cancels watcher pause classification but cannot affect manifest-based entry.
make_case pause-cancelled
cat > "$STATE/$ID.status" <<'EOF'
paused: waiting for review
resolved [key=unrelated]: bookkeeping completed
EOF
run_latent enter "$ID" >/dev/null || fail "resolved bookkeeping after pause incorrectly blocked latent entry"
assert_latent
pass "later bookkeeping that cancels a pause tail does not affect durable latent eligibility"

# Active validation state is runtime context and cannot hibernate in v1.
make_case active-gate
FM_FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01RUN"
  branch: $BRANCH
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$HEAD_OID"
  pr: "$URL"
  findings: none
gate: review
EOF
)
export FM_FAKE_AXI_STATUS
expect_refusal "active validation gate" run_latent enter "$ID"
[ -e "$ENDPOINT" ] || fail "validation refusal terminated the worker"
pass "active or parked validation keeps the task active"

# Incomplete transactions converge on restart.
make_case crash-ref
set +e
FM_LATENT_CRASH_AFTER=ref run_latent enter "$ID" >/dev/null 2>&1
CRASH_RC=$?
set -e
[ "$CRASH_RC" -eq 86 ] || fail "ref crash injection exited $CRASH_RC"
run_latent recover "$ID" >/dev/null || fail "ref-pinned crash recovery failed"
[ ! -e "$DATA/$ID/latent/transaction" ] || fail "ref crash journal survived rollback"
[ ! -e "$DATA/$ID/latent/manifest" ] || fail "ref crash manifest survived rollback"
[ -e "$ENDPOINT" ] || fail "ref crash recovery lost the active endpoint"
pass "crash after ref pinning and before return rolls back to active without discarding work"

make_case crash-return
set +e
FM_LATENT_CRASH_AFTER="return" run_latent enter "$ID" >/dev/null 2>&1
CRASH_RC=$?
set -e
[ "$CRASH_RC" -eq 87 ] || fail "return crash injection exited $CRASH_RC"
[ ! -e "$ENDPOINT" ] || fail "return crash left the endpoint alive"
run_latent recover "$ID" >/dev/null || fail "post-return crash recovery failed"
assert_latent
pass "crash after return and before metadata commit converges to latent"

# Rehydrate from a fresh temporary Treehouse acquisition and the protected data.
make_case rehydrate
run_latent enter "$ID" >/dev/null || fail "rehydrate setup entry failed"
RESUME_WT=$(cd "$PROJECT" && treehouse get --lease --lease-holder "resume-$ID" 2>/dev/null) || fail "rehydrate Treehouse acquire failed"
FM_FAKE_RESUME_WT=$RESUME_WT
export FM_FAKE_RESUME_WT
rm -f "$GOT_TREEHOUSE"
FM_SPAWN_NO_GUARD=1 run_latent resume "$ID" >/dev/null || fail "latent resume failed"
[ "$(grep '^tier=' "$STATE/$ID.meta" | cut -d= -f2-)" = active ] || fail "resume did not restore active metadata"
[ "$(grep '^worktree=' "$STATE/$ID.meta" | cut -d= -f2-)" = "$RESUME_WT" ] || fail "resume did not bind the fresh worktree"
[ "$(git -C "$RESUME_WT" rev-parse HEAD)" = "$HEAD_OID" ] || fail "resume worktree is not at the authenticated PR head"
[ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$HEAD_OID" ] || fail "resume removed the saved generation too early"
pass "rehydration reacquires a temporary slot and reconstructs a worker from durable artifacts"

# Closed-unmerged is attention, never deletion.
make_case closed
SAVED=$HEAD_OID
run_latent enter "$ID" >/dev/null || fail "closed setup entry failed"
FM_FAKE_GH_STATE=CLOSED
export FM_FAKE_GH_STATE
run_latent transition "$ID" closed-unmerged
expect_refusal "closed-unmerged resume" run_latent resume "$ID"
[ "$(git -C "$PROJECT" rev-parse "refs/firstmate/latent/$ID")" = "$SAVED" ] || fail "closed-unmerged removed recovery ref"
[ -f "$STATE/$ID.meta" ] || fail "closed-unmerged removed task metadata"
pass "closed-unmerged stays slot-free in attention with its recovery ref"

# Merge finalization returns through teardown and removes only after containment.
make_case merged
run_latent enter "$ID" >/dev/null || fail "merge setup entry failed"
FM_FAKE_GH_STATE=MERGED
export FM_FAKE_GH_STATE
run_latent finish "$ID" >/dev/null || fail "merged latent finalization failed"
[ ! -e "$STATE/$ID.meta" ] || fail "merge finalization left task metadata"
[ ! -e "$DATA/$ID/latent" ] || fail "merge finalization left latent manifest"
if git -C "$PROJECT" rev-parse --verify "refs/firstmate/latent/$ID" >/dev/null 2>&1; then
  fail "merge finalization left the recovery ref"
fi
pass "verified merge finalization delegates to teardown and removes the protected generation"

# A fatal shell abort raised AFTER the EXIT trap is installed must still leave a
# non-zero exit status. Under `set -e`, sourcing a missing file is a fatal abort
# that reaches an EXIT trap with $? already 0, so an unguarded trap silently
# converts that failure into a reported success. This matters most here:
# bin/fm-watch.sh branches on `fm-latent.sh enter`, so a masked 0 would be read
# as a completed hibernation and the worker treated as released.
# The trigger is real rather than synthetic - the backend adapter that
# fm-backend.sh sources lazily is removed from a copied tree.
make_case fatal-abort-status
FATAL_ROOT="$CASE/adapterless"
mkdir -p "$FATAL_ROOT"
cp -R "$ROOT/bin" "$FATAL_ROOT/bin"
rm -f "$FATAL_ROOT/bin/backends/tmux.sh"
set +e
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  "$FATAL_ROOT/bin/fm-latent.sh" enter "$ID" > "$CASE/fatal.out" 2>&1
FATAL_RC=$?
set -e
grep -q "No such file or directory" "$CASE/fatal.out" \
  || fail "fatal-abort fixture did not actually trigger the missing-adapter abort: $(cat "$CASE/fatal.out")"
[ "$FATAL_RC" -ne 0 ] \
  || fail "fm-latent.sh enter reported success (rc=0) after a fatal abort; bin/fm-watch.sh would read that as a completed hibernation"
pass "fm-latent.sh preserves a non-zero exit status through its EXIT trap on a fatal abort"

printf 'all latent lifecycle cases passed\n'
