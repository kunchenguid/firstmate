#!/usr/bin/env bash
# tests/fm-secondmate-parent-takeover.test.sh - behavior coverage for moving a
# secondmate's parent binding between the primary that reaches it over the remote
# route and a primary running on the secondmate's own host.
#
# The failure this covers: a primary on the mate's own host rewrote
# .fm-secondmate-parent from route=remote to route=local naming itself, so every
# reply the mate published landed in that primary's state/<id>.status. The remote
# primary saw none of them and its pending-reply expectations sat unanswered, while
# both primaries kept steering the same mate and nothing reported the split.
#
# Covered here, through the real executables and real files:
#   - take-over in both directions: a local primary claims a remotely bound mate,
#     and the remote primary claims it back through the real host-local leg over
#     the repo's deterministic SSH boundary;
#   - the reverse take-over restoring the exact binding the last claim displaced;
#   - the displaced primary refusing to steer (bin/fm-send.sh) or claim
#     (bin/fm-spawn.sh) the mate, and the host-local leg refusing the remote
#     primary's steer while the mate is bound to a parent on its own host;
#   - a malformed and a symlinked binding still failing closed on every one of
#     those paths rather than being overwritten or steered past;
#   - a repeated claim keeping the binding restore returns to, local and remote
#     re-seeding refusing to move a binding, and the host-local leg waiting on
#     the binding lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-parent-takeover)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOST_PRIMARY="$TMP_ROOT/host-primary"
REMOTE_PRIMARY="$TMP_ROOT/remote-primary"
MATE="$TMP_ROOT/mate-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

# The remote half starts the real account-owned remote job worker, so stop it
# before the shared fixture cleanup removes the tree it is serving.
reap_remote_worker() {
  local worker_pid worker_pgid own_pgid waited=0
  [ -f "$TMP_ROOT/remote-jobs/worker.pid" ] || return 0
  worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
  case "$worker_pid" in ''|*[!0-9]*) return 0 ;; esac
  # The worker runs in its own process group with children of its own, so
  # signalling only the recorded pid leaves a survivor that recreates the queue
  # directories under the fixture tree and races the cleanup that follows.
  worker_pgid=$(ps -o pgid= -p "$worker_pid" 2>/dev/null | tr -d ' ' || true)
  own_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)
  case "$worker_pgid" in ''|*[!0-9]*) worker_pgid= ;; esac
  if [ -n "$worker_pgid" ] && [ "$worker_pgid" != "$own_pgid" ]; then
    kill -TERM -- "-$worker_pgid" 2>/dev/null || true
  else
    kill "$worker_pid" 2>/dev/null || true
  fi
  while kill -0 "$worker_pid" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -le 250 ] || break
    sleep 0.02
  done
}
takeover_cleanup() {
  reap_remote_worker
  fm_test_cleanup
}
trap takeover_cleanup EXIT
trap 'takeover_cleanup; exit 130' INT
trap 'takeover_cleanup; exit 143' TERM
trap 'takeover_cleanup; exit 129' HUP

mkdir -p "$HOST_PRIMARY"/{data,state,config,projects} \
  "$REMOTE_PRIMARY"/{data,state,config,projects} \
  "$MATE"/{data,state,config,projects,bin}
cp "$ROOT/AGENTS.md" "$MATE/AGENTS.md"
printf 'ios\n' > "$MATE/.fm-secondmate-home"

REMOTE_RECORD=$(printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-mac\n')
HOST_RECORD=$(printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOST_PRIMARY")

write_binding() { # <record-text>
  printf '%s\n' "$1" > "$MATE/.fm-secondmate-parent"
}
binding_is() { # <expected-record-text> <msg>
  cmp -s "$MATE/.fm-secondmate-parent" <(printf '%s\n' "$1") || fail "$2"
}
prior_is() { # <expected-record-text> <msg>
  cmp -s "$MATE/.fm-secondmate-parent-prior" <(printf '%s\n' "$1") || fail "$2"
}

# Both primaries list the same mate: the host primary as a plain local secondmate,
# the remote primary as a remote route reached through the SSH alias remote-mac.
printf -- '- ios - Own iOS delivery. (home: %s; scope: iOS work; projects: ; added 2026-09-27)\n' "$MATE" \
  > "$HOST_PRIMARY/data/secondmates.md"

takeover() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-secondmate-takeover.sh" "$@" 2>&1
}

# --- take-over direction 1: a primary on the mate's own host claims it ---------
write_binding "$REMOTE_RECORD"
OUT=$(takeover "$HOST_PRIMARY" claim ios) || fail "the host primary could not claim the mate: $OUT"
binding_is "$HOST_RECORD" "claim must bind the mate to the claiming home with the exact local record"
prior_is "$REMOTE_RECORD" "claim must preserve the displaced remote binding verbatim"
assert_contains "$OUT" "takeover: ios is now bound to this home" \
  "claim must report the new owner"
assert_contains "$OUT" "replies now land in $HOST_PRIMARY/state/ios.status" \
  "claim must say where the mate's replies land from now on"
pass "a primary on the secondmate's own host claims a remotely bound mate"

# A repeated or retried claim must not overwrite the binding restore hands back,
# nor report this home's own expectations as a displaced parent's.
mkdir -p "$HOST_PRIMARY/state/pending-replies"
cat > "$HOST_PRIMARY/state/pending-replies/corr-own001" <<REC
schema=fm-pending-reply.v1
corr_id=corr-own001
task_id=ios
parent_home=$HOST_PRIMARY
parent_status=$HOST_PRIMARY/state/ios.status
request_summary=report the nightly build
phase=awaiting_report
REC
OUT=$(takeover "$HOST_PRIMARY" claim ios) || fail "a repeated claim failed: $OUT"
binding_is "$HOST_RECORD" "a repeated claim must keep the mate bound to the claiming home"
prior_is "$REMOTE_RECORD" "a repeated claim must keep the originally displaced binding for restore"
assert_contains "$OUT" "takeover: ios is already bound to this home $HOST_PRIMARY; nothing was displaced" \
  "a repeated claim must say it displaced nothing"
assert_not_contains "$OUT" "the displaced parent" \
  "a repeated claim must not describe a displaced parent"
assert_contains "$OUT" "this home is still waiting on these replies, which can now arrive:" \
  "a repeated claim must still list this home's own expectations as its own"
rm -f "$HOST_PRIMARY/state/pending-replies/corr-own001"
pass "a repeated claim keeps the displaced binding restore returns to"

# --- the reverse take-over restores exactly what the claim displaced -----------
OUT=$(takeover "$HOST_PRIMARY" restore ios) || fail "restore failed: $OUT"
binding_is "$REMOTE_RECORD" "restore must reinstate the displaced binding byte for byte"
prior_is "$HOST_RECORD" "restore must itself preserve the binding it displaces"
assert_contains "$OUT" "takeover-restore: ios is now bound to its previous parent" \
  "restore must report the handover"
assert_contains "$OUT" "this home no longer receives replies from ios" \
  "restore must say this home stops receiving the mate's replies"
pass "the reverse take-over restores the saved binding and keeps switching back one command"

# --- re-seeding never moves the binding ---------------------------------------
# Seeding is the other writer of a local record, so a primary on the mate's own
# host re-seeding a remotely bound home must refuse rather than displace the
# remote parent with no saved binding to restore.
reseed() { # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='Reseed charter.' \
    FM_SECONDMATE_SCOPE='reseed scope' \
    "$ROOT/bin/fm-home-seed.sh" ios "$MATE" --no-projects 2>&1
}
cp "$MATE/.fm-secondmate-parent-prior" "$TMP_ROOT/prior-before-reseed"
OUT=$(reseed "$HOST_PRIMARY") && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "re-seeding a remotely bound home must refuse: $OUT"
assert_contains "$OUT" "currently bound to a parent that reaches it over the remote route" \
  "the re-seed refusal must name the parent that holds the mate"
assert_contains "$OUT" "fm-secondmate-takeover.sh claim" \
  "the re-seed refusal must name the one command that moves the binding"
binding_is "$REMOTE_RECORD" "a refused re-seed must leave the remote binding untouched"
cmp -s "$MATE/.fm-secondmate-parent-prior" "$TMP_ROOT/prior-before-reseed" \
  || fail "a refused re-seed must leave the saved binding untouched"
pass "re-seeding a remotely bound home refuses and leaves the binding untouched"

MALFORMED_RECORD=$(printf 'schema=fm-secondmate-parent.v1\nroute=remote\nroute=remote\n')
write_binding "$MALFORMED_RECORD"
OUT=$(reseed "$HOST_PRIMARY") && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "re-seeding a home with a malformed binding must refuse: $OUT"
assert_contains "$OUT" "no usable parent binding" \
  "the re-seed refusal must report the malformed binding as unusable"
binding_is "$MALFORMED_RECORD" "a refused re-seed must leave the malformed binding for the operator"
write_binding "$REMOTE_RECORD"
pass "re-seeding a home with a malformed binding refuses rather than rewriting it"

# Provisioning is the remote-side writer, so the remote primary re-seeding a mate
# a host primary has claimed must refuse rather than silently take it back.
remote_reseed() {
  {
    printf 'schema=fm-remote-home-provision.v1\n'
    printf 'id_b64=%s\n' "$(printf 'ios' | base64)"
    printf 'charter_b64=%s\n' "$(printf 'Reseed charter.\n' | base64 | tr -d '\n')"
    printf 'parent_host_b64=%s\n' "$(printf 'remote-mac' | base64)"
    printf 'project_count=0\n'
  } | FM_HOME="$MATE" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-home-provision.sh" 2>&1
}
rm -f "$MATE/.fm-secondmate-parent-prior"
takeover "$HOST_PRIMARY" claim ios >/dev/null || fail "the host primary could not claim the mate"
OUT=$(remote_reseed) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "remote re-seeding a host-claimed home must refuse: $OUT"
assert_contains "$OUT" "is currently bound to the firstmate home $HOST_PRIMARY on its own host" \
  "the remote re-seed refusal must name the parent that holds the mate"
assert_contains "$OUT" "fm-secondmate-takeover.sh claim ios" \
  "the remote re-seed refusal must name the one command that moves the binding"
binding_is "$HOST_RECORD" "a refused remote re-seed must leave the host binding untouched"
prior_is "$REMOTE_RECORD" "a refused remote re-seed must leave the saved binding untouched"
takeover "$HOST_PRIMARY" restore ios >/dev/null || fail "the host primary could not hand the mate back"
OUT=$(remote_reseed) || fail "remote re-seeding a remotely bound home must still converge: $OUT"
binding_is "$REMOTE_RECORD" "a converged remote re-seed must keep the remote binding"
pass "remote re-seeding refuses a host-claimed home and still converges a remotely bound one"

# A claim that lands while provisioning is still converging the home must not be
# overwritten by its final binding write, nor by the rollback that follows.
CLAIM_HELD="$TMP_ROOT/provision-claim-held"
CLAIM_GO="$TMP_ROOT/provision-claim-go"
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
FM_STATE_OVERRIDE="$HOST_PRIMARY/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-secondmate-parent-lib.sh"
  fm_lock_acquire_wait "$2/.fm-secondmate-parent.lock" || exit 1
  : > "$3"
  while [ ! -e "$4" ]; do sleep 0.05; done
  fm_secondmate_parent_rebind "$2" local "$5"
  rc=$?
  fm_lock_release "$2/.fm-secondmate-parent.lock"
  exit "$rc"
' _ "$ROOT" "$MATE" "$CLAIM_HELD" "$CLAIM_GO" "$HOST_PRIMARY" &
CLAIMER_PID=$!
waited=0
while [ ! -e "$CLAIM_HELD" ]; do
  waited=$((waited + 1))
  [ "$waited" -le 200 ] || fail "test setup drifted: the concurrent claim never took the binding lock"
  sleep 0.05
done
remote_reseed > "$TMP_ROOT/racing-provision.out" 2>&1 &
PROVISION_PID=$!
sleep 2
: > "$CLAIM_GO"
wait "$CLAIMER_PID" || fail "the concurrent claim failed"
wait "$PROVISION_PID" && RC=0 || RC=$?
OUT=$(cat "$TMP_ROOT/racing-provision.out")
[ "$RC" -ne 0 ] || fail "provisioning must refuse once a concurrent claim has moved the binding: $OUT"
assert_contains "$OUT" "fm-secondmate-takeover.sh claim ios" \
  "the late provisioning refusal must name the one command that moves the binding"
binding_is "$HOST_RECORD" "provisioning must not overwrite a claim made while it was running"
prior_is "$REMOTE_RECORD" "provisioning must leave the concurrent claim's saved binding for restore"
takeover "$HOST_PRIMARY" restore ios >/dev/null || fail "the host primary could not hand the mate back"
pass "a claim made while provisioning runs is not overwritten by its write or its rollback"

# --- the displaced primary refuses to claim or steer --------------------------
# The mate is bound to the remote route again, so the host primary is displaced.
fm_write_secondmate_meta "$HOST_PRIMARY/state/ios.meta" "$MATE"
SPAWN_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
[ "$SPAWN_RC" -ne 0 ] || fail "a displaced primary must refuse to claim the mate: $SPAWN_OUT"
assert_contains "$SPAWN_OUT" "currently bound to a parent that reaches it over the remote route" \
  "the claim refusal must name the parent that holds the mate"
assert_contains "$SPAWN_OUT" "fm-secondmate-takeover.sh claim ios" \
  "the claim refusal must name the one command that moves the binding"
pass "a displaced primary refuses to claim the secondmate and names the holder"

SEND_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" ios 'status check' 2>&1) && SEND_RC=0 || SEND_RC=$?
[ "$SEND_RC" -ne 0 ] || fail "a displaced primary must refuse to steer the mate: $SEND_OUT"
assert_contains "$SEND_OUT" "currently bound to a parent that reaches it over the remote route" \
  "the steer refusal must name the parent that holds the mate"
assert_contains "$SEND_OUT" "refusing to steer it in parallel" \
  "the steer refusal must say it is refusing rather than splitting supervision"
pass "a displaced primary refuses to steer the secondmate and names the holder"

# The same primary works normally once the binding names it again.
takeover "$HOST_PRIMARY" claim ios >/dev/null || fail "the host primary could not reclaim the mate"
SEND_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" ios 'status check' 2>&1) && SEND_RC=0 || SEND_RC=$?
assert_not_contains "$SEND_OUT" "refusing to steer it in parallel" \
  "a primary the binding names must not be refused by the displacement guard"
pass "the guard clears as soon as the binding names the steering primary"

# --- a malformed or symlinked binding still fails closed ----------------------
printf 'schema=fm-secondmate-parent.v1\nroute=local\nroute=local\nparent_home=%s\n' "$HOST_PRIMARY" \
  > "$MATE/.fm-secondmate-parent"
OUT=$(takeover "$HOST_PRIMARY" claim ios) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "a duplicate-field binding must not be silently overwritten: $OUT"
assert_contains "$OUT" "the live parent binding is unsafe or malformed" \
  "a malformed binding must be reported as corrupt rather than replaced"
SEND_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" ios 'status check' 2>&1) && SEND_RC=0 || SEND_RC=$?
[ "$SEND_RC" -ne 0 ] || fail "a malformed binding must still refuse a steer: $SEND_OUT"
assert_contains "$SEND_OUT" "no usable parent binding" \
  "a malformed binding must refuse the steer as unusable, never as a match"
pass "a malformed parent binding fails closed on take-over and on steering"

printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOST_PRIMARY" \
  > "$TMP_ROOT/elsewhere-binding"
rm -f "$MATE/.fm-secondmate-parent"
ln -s "$TMP_ROOT/elsewhere-binding" "$MATE/.fm-secondmate-parent"
OUT=$(takeover "$HOST_PRIMARY" claim ios) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "a symlinked binding must not be followed and rewritten: $OUT"
assert_contains "$OUT" "the live parent binding is unsafe or malformed" \
  "a symlinked binding must be reported as unsafe"
[ -L "$MATE/.fm-secondmate-parent" ] || fail "the refused take-over replaced the symlink boundary"
cmp -s "$TMP_ROOT/elsewhere-binding" <(printf '%s\n' "$HOST_RECORD") \
  || fail "the refused take-over wrote through the symlink"
SEND_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" ios 'status check' 2>&1) && SEND_RC=0 || SEND_RC=$?
[ "$SEND_RC" -ne 0 ] || fail "a symlinked binding must still refuse a steer: $SEND_OUT"
assert_contains "$SEND_OUT" "no usable parent binding" \
  "a symlinked binding must refuse the steer as unusable, never as a match"
pass "a symlinked parent binding fails closed on take-over and on steering"

# --- a home with no binding at all names no parent ----------------------------
# Homes seeded before this record existed have none. Nothing else has claimed such
# a mate, so steering it is not a split, and a claim simply establishes the record.
rm -f "$MATE/.fm-secondmate-parent" "$MATE/.fm-secondmate-parent-prior"
SEND_OUT=$(FM_HOME="$HOST_PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" ios 'status check' 2>&1) && SEND_RC=0 || SEND_RC=$?
assert_not_contains "$SEND_OUT" "no usable parent binding" \
  "a home with no binding must not be treated as displaced"
OUT=$(takeover "$HOST_PRIMARY" claim ios) || fail "claim must establish a binding where none exists: $OUT"
binding_is "$HOST_RECORD" "claim must establish the local record on a home that had none"
assert_absent "$MATE/.fm-secondmate-parent-prior" \
  "a home with no binding has no displaced parent to preserve"
pass "a home with no parent binding is claimable and is not reported as displaced"

# --- a missing saved binding is reported, never guessed -----------------------
rm -f "$MATE/.fm-secondmate-parent" "$MATE/.fm-secondmate-parent-prior"
write_binding "$HOST_RECORD"
OUT=$(takeover "$HOST_PRIMARY" restore ios) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "restore with nothing saved must refuse: $OUT"
assert_contains "$OUT" "no usable saved previous parent binding" \
  "restore must say there is nothing preserved to restore"
binding_is "$HOST_RECORD" "a refused restore must leave the live binding untouched"
pass "restore refuses rather than inventing a parent when nothing was preserved"

# --- the replies the displaced parent was waiting on are named, not lost -------
# A second primary on this same filesystem claims a mate the host primary holds,
# while the host primary still has an unresolved expectation for it.
printf -- '- ios - Own iOS delivery. (home: %s; scope: iOS work; projects: ; added 2026-09-27)\n' "$MATE" \
  > "$REMOTE_PRIMARY/data/secondmates.md"
mkdir -p "$HOST_PRIMARY/state/pending-replies"
cat > "$HOST_PRIMARY/state/pending-replies/corr-abc123" <<REC
schema=fm-pending-reply.v1
corr_id=corr-abc123
task_id=ios
parent_home=$HOST_PRIMARY
parent_status=$HOST_PRIMARY/state/ios.status
request_summary=confirm the release branch is cut
phase=awaiting_report
REC
write_binding "$HOST_RECORD"
rm -f "$MATE/.fm-secondmate-parent-prior"
OUT=$(takeover "$REMOTE_PRIMARY" claim ios) || fail "the second local primary could not claim the mate: $OUT"
assert_contains "$OUT" "the displaced parent $HOST_PRIMARY was still waiting on these replies" \
  "a take-over must name the replies the displaced parent was waiting on"
assert_contains "$OUT" "corr-abc123 phase=awaiting_report request=confirm the release branch is cut" \
  "a take-over must identify each unanswered expectation it strands"
pass "a take-over names the replies the displaced parent was still waiting on"

# --- a taken-over home stays clean for the guarded pre-launch sync -------------
# A secondmate home is a worktree of this repo, and the guarded fast-forward that
# runs before every launch refuses a dirty home. So the record a take-over
# preserves must be ignored there, or claiming a mate would quietly stop its
# pre-launch sync from ever running again.
TRACKED_MATE="$TMP_ROOT/tracked-mate"
TRACKED_PRIMARY="$TMP_ROOT/tracked-primary"
mkdir -p "$TRACKED_PRIMARY"/{data,state,config,projects} "$TRACKED_MATE"/{data,state,config,projects,bin}
cp "$ROOT/AGENTS.md" "$ROOT/.gitignore" "$TRACKED_MATE/"
printf 'tracked\n' > "$TRACKED_MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-mac\n' \
  > "$TRACKED_MATE/.fm-secondmate-parent"
git -C "$TRACKED_MATE" init -q -b main
fm_git_identity "$TRACKED_MATE"
git -C "$TRACKED_MATE" add AGENTS.md .gitignore
git -C "$TRACKED_MATE" commit -qm 'seeded secondmate home'
[ -z "$(git -C "$TRACKED_MATE" status --porcelain)" ] \
  || fail "test setup drifted: the seeded home was not clean before the take-over"
printf -- '- tracked - Own tracked work. (home: %s; scope: tracked work; projects: ; added 2026-09-27)\n' \
  "$TRACKED_MATE" > "$TRACKED_PRIMARY/data/secondmates.md"
takeover "$TRACKED_PRIMARY" claim tracked >/dev/null || fail "claiming the tracked home failed"
assert_present "$TRACKED_MATE/.fm-secondmate-parent-prior" \
  "the claim must have preserved a displaced binding to assert against"
[ -z "$(git -C "$TRACKED_MATE" status --porcelain)" ] \
  || fail "a taken-over home is dirty, which would stop its guarded pre-launch sync: $(git -C "$TRACKED_MATE" status --porcelain)"
pass "a taken-over secondmate home stays clean for its guarded pre-launch sync"

# --- the remote direction, over the repo's deterministic SSH boundary ----------
REMOTE_ROOT="$TMP_ROOT/remote-root"
mkdir -p "$REMOTE_ROOT"
# The host's own Firstmate checkout, as a real git-tracked code root: fm-on.sh
# refuses a command its checkout does not track, and the job worker stops itself
# once its code root stops looking like a Firstmate checkout. Only bin/ and the
# instruction root are reached on this path, so the copy stays to those.
(
  cd "$ROOT" || exit
  tar -cf - bin AGENTS.md CLAUDE.md
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
fm_git_identity "$REMOTE_ROOT"
git -C "$REMOTE_ROOT" add bin AGENTS.md CLAUDE.md
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf -- '- ios - Own iOS delivery. (host: remote-mac; root: %s; home: %s; scope: iOS work; projects: ; added 2026-09-27)\n' \
  "$REMOTE_ROOT" "$MATE" > "$REMOTE_PRIMARY/data/secondmates.md"

remote_takeover() { # <args...>
  FM_HOME="$REMOTE_PRIMARY" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$REMOTE_ROOT/bin/fm-secondmate-takeover.sh" "$@" 2>&1
}
remote_leg() { # <control args...>
  FM_HOME="$REMOTE_PRIMARY" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$REMOTE_ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh "$@" 2>&1
}
# The mate is currently bound to the host primary: exactly the split state the
# captain found by hand. The remote primary takes it back with one command.
write_binding "$HOST_RECORD"
rm -f "$MATE/.fm-secondmate-parent-prior"
OUT=$(remote_takeover claim ios) || fail "the remote primary could not claim the mate: $OUT"
binding_is "$REMOTE_RECORD" "the remote claim must bind the mate to the remote route with the parent's host alias"
prior_is "$HOST_RECORD" "the remote claim must preserve the displaced host-local binding verbatim"
assert_contains "$OUT" "takeover: ios is now bound to its remote parent" \
  "the remote claim must report the new owner through the host-local leg"
assert_contains "$OUT" "prior_route=local" \
  "the remote claim must report the binding it preserved"
assert_contains "$OUT" "replies now land in the secondmate home's state/parent-replies.status" \
  "the remote claim must say where the mate's replies land from now on"
assert_contains "$OUT" "its own records stay on that host" \
  "the remote claim must say the displaced parent's own expectations are not readable from here"
pass "the remote primary claims a host-bound mate through the real host-local leg"

OUT=$(remote_takeover claim ios) || fail "a repeated remote claim failed: $OUT"
binding_is "$REMOTE_RECORD" "a repeated remote claim must keep the remote binding"
prior_is "$HOST_RECORD" "a repeated remote claim must keep the binding restore returns to"
assert_contains "$OUT" "is already bound to its remote parent; nothing was displaced" \
  "a repeated remote claim must say it displaced nothing"
assert_not_contains "$OUT" "the displaced parent was a firstmate" \
  "a repeated remote claim must not infer a displacement from the saved binding"
pass "a repeated remote claim reports that it displaced nothing"

OUT=$(remote_takeover restore ios) || fail "the remote restore failed: $OUT"
binding_is "$HOST_RECORD" "the remote restore must reinstate the displaced binding byte for byte"
prior_is "$REMOTE_RECORD" "the remote restore must itself preserve the binding it displaces"
assert_contains "$OUT" "takeover-restore: ios is now bound to its previous parent" \
  "the remote restore must report the handover"
pass "the remote primary hands the mate back to its host parent in one command"

# The mate is bound to the host primary, so the remote primary's own steer must be
# refused on the mate's host rather than delivered in parallel.
OUT=$(remote_leg send ios 'status check') && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "the host-local leg must refuse a remote steer while the mate is bound elsewhere: $OUT"
assert_contains "$OUT" "is currently bound to the firstmate home $HOST_PRIMARY on its own host" \
  "the leg refusal must name the parent that holds the mate"
assert_contains "$OUT" "refusing to steer or claim it from a remote parent" \
  "the leg must say it is refusing rather than splitting supervision"
pass "the host-local leg refuses a remote steer while the mate is bound to a parent on its own host"

# Reading the binding stays available from the displaced side, which is how the
# split gets diagnosed at all.
OUT=$(remote_leg parent ios) || fail "reading the binding from the remote side failed: $OUT"
assert_contains "$OUT" "parent_home=$HOST_PRIMARY" \
  "the remote side must be able to read which parent currently holds the mate"
pass "the binding stays readable from the displaced remote primary"

# The host-local leg takes the same binding lock a local claim holds, so a claim
# arriving over the remote route waits instead of interleaving with it.
LOCK_HELD="$TMP_ROOT/binding-lock-held"
LOCK_DONE="$TMP_ROOT/binding-lock-done"
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
FM_STATE_OVERRIDE="$HOST_PRIMARY/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2" || exit 1
  : > "$3"
  while [ ! -e "$4" ]; do sleep 0.05; done
  fm_lock_release "$2"
' _ "$ROOT" "$MATE/.fm-secondmate-parent.lock" "$LOCK_HELD" "$LOCK_DONE" &
HOLDER_PID=$!
waited=0
while [ ! -e "$LOCK_HELD" ]; do
  waited=$((waited + 1))
  [ "$waited" -le 200 ] || fail "test setup drifted: the binding lock was never taken"
  sleep 0.05
done
remote_takeover claim ios > "$TMP_ROOT/locked-claim.out" &
CLAIM_PID=$!
sleep 2
cp "$MATE/.fm-secondmate-parent" "$TMP_ROOT/binding-while-locked"
: > "$LOCK_DONE"
wait "$HOLDER_PID" || fail "the lock holder failed"
cmp -s "$TMP_ROOT/binding-while-locked" <(printf '%s\n' "$HOST_RECORD") \
  || fail "the host-local leg must not rebind while another claim holds the binding lock"
wait "$CLAIM_PID" || fail "the waiting remote claim failed: $(cat "$TMP_ROOT/locked-claim.out")"
binding_is "$REMOTE_RECORD" "the waiting remote claim must complete once the lock is released"
prior_is "$HOST_RECORD" "the waiting remote claim must preserve the binding it displaced"
pass "the host-local leg serializes its claim behind the binding lock"

# A legacy-provisioned remote record carries no parent_host. A remote claim over
# it names the same parent, so it refreshes the host without overwriting the
# binding restore returns to.
LEGACY_REMOTE_RECORD=$(printf 'schema=fm-secondmate-parent.v1\nroute=remote\n')
write_binding "$LEGACY_REMOTE_RECORD"
rm -f "$MATE/.fm-secondmate-parent-prior"
takeover "$HOST_PRIMARY" claim ios >/dev/null || fail "the host primary could not claim the legacy-bound mate"
takeover "$HOST_PRIMARY" restore ios >/dev/null || fail "the host primary could not hand the legacy-bound mate back"
binding_is "$LEGACY_REMOTE_RECORD" "restore must reinstate the legacy remote record byte for byte"
OUT=$(remote_takeover claim ios) || fail "the remote claim over a legacy record failed: $OUT"
binding_is "$REMOTE_RECORD" "a remote claim over a legacy record must refresh its parent_host"
prior_is "$HOST_RECORD" "a remote claim over a legacy record must keep the binding restore returns to"
OUT=$(remote_takeover restore ios) || fail "the remote restore after a legacy claim failed: $OUT"
binding_is "$HOST_RECORD" "restore after a legacy remote claim must return the host parent"
pass "a remote claim over a legacy no-host record keeps the binding restore returns to"

# A symlinked binding must not become a remote claim either.
rm -f "$MATE/.fm-secondmate-parent"
ln -s "$TMP_ROOT/elsewhere-binding" "$MATE/.fm-secondmate-parent"
OUT=$(remote_takeover claim ios) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "a symlinked binding must not be rewritten through the remote leg: $OUT"
[ -L "$MATE/.fm-secondmate-parent" ] || fail "the refused remote take-over replaced the symlink boundary"
cmp -s "$TMP_ROOT/elsewhere-binding" <(printf '%s\n' "$HOST_RECORD") \
  || fail "the refused remote take-over wrote through the symlink"
pass "a symlinked parent binding fails closed through the remote leg too"

reap_remote_worker

echo "ALL TESTS PASSED"
