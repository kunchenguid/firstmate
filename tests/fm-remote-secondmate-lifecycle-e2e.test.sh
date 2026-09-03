#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
LOCAL_HOME="$TMP_ROOT/local-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
cleanup() {
  local worker_pid='' wait_attempt=0
  touch "$TMP_ROOT/provision.release" "$TMP_ROOT/seed.release" "$TMP_ROOT/handoff.release" \
    "$TMP_ROOT/inherit.release" "$TMP_ROOT/launch.release" 2>/dev/null || true
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
    while kill -0 "$worker_pid" 2>/dev/null && [ "$wait_attempt" -lt 100 ]; do
      wait_attempt=$((wait_attempt + 1))
      sleep 0.05
    done
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# Materialize the current branch as the remote host's tracked code root. The
# fixture is a real git repository because provisioning and guarded sync exercise
# the same clone and fast-forward path as a second Mac.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
fail_send='$TMP_ROOT/tmux-send-fail'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) [ ! -f "\$fail_send" ] || exit 1; exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

# One remote-backed direct-PR project. The remote home clones its origin, never
# the primary working tree.
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
cat > "$PARENT/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-08-02)
EOF
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  inherit-partial:fm-remote-inherit.sh:config/crew-harness) exit 255 ;;
  inherit-block:fm-remote-inherit.sh:data/captain-shared.md)
    cat > "$FM_FAKE_INHERIT_PAYLOAD"
    touch "$FM_FAKE_INHERIT_ENTERED"
    while [ ! -f "$FM_FAKE_INHERIT_RELEASE" ]; do sleep 0.02; done
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" < "$FM_FAKE_INHERIT_PAYLOAD"
    exit $?
    ;;
esac
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. tests/fm-remote-doctor.test.sh
# owns the doctor's real behavior against controlled account fixtures; this
# boundary owns only what the callers do with its verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s %s\n' "${FM_FAKE_SSH_MODE:-normal}" "${_command_action:--}" >> "$FM_FAKE_DOCTOR_LOG"
  case "${FM_FAKE_SSH_MODE:-normal}" in
    unreachable) exit 255 ;;
    doctor-fix-unknown)
      if [ "${_command_action:-}" = --fix ]; then
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        exit 255
      fi
      printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
      exit 1
      ;;
    doctor-human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
    doctor-fixable)
      # Red until --fix runs on this host, green on every later read-only run.
      if [ "${_command_action:-}" = --fix ]; then
        touch "$FM_FAKE_DOCTOR_REPAIRED"
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      [ -f "$FM_FAKE_DOCTOR_REPAIRED" ] || {
        printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
        exit 1
      }
      ;;
  esac
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = doctor-fixable ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$_command_action" = state ] \
  && [ ! -f "$FM_FAKE_DOCTOR_REPAIRED" ]; then
  printf 'unreadable\n'
  exit 0
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  launch-nonherdr-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=tmux\n'
    printf 'target=firstmate:fm-ios\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  launch-default-session-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=default:w1:p2\n'
    printf 'herdr_session=default\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  provision-block-fail:fm-remote-home-provision.sh:*)
    touch "$FM_FAKE_SEED_ENTERED"
    while [ ! -f "$FM_FAKE_SEED_RELEASE" ]; do sleep 0.02; done
    exit 1
    ;;
  launch-block:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    touch "$FM_FAKE_LAUNCH_ENTERED"
    while [ ! -f "$FM_FAKE_LAUNCH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous) "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255 ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

publish_healthy_watcher_identity() { # <state> <home> <watch-script>
  local state=$1 home=$2 watch=$3 identity
  identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not derive fixture watcher identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  touch "$state/.last-watcher-beat"
}

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/inherit.entered" \
  FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/inherit.release" \
  FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/inherit.payload" \
  FM_FAKE_LAUNCH_ENTERED="$TMP_ROOT/launch.entered" \
  FM_FAKE_LAUNCH_RELEASE="$TMP_ROOT/launch.release" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# The correlation token of the newest record in the remote secondmate's
# steering inbox: a remote steer is delivered as a durable record there, so
# the corr a reply must echo is read from the record body, never from typed
# pane bytes.
newest_remote_inbox_corr() {
  grep -Eoh 'corr=[a-f0-9]{16}' "$REMOTE_HOME"/state/parent-route/ios.inbox/*.msg 2>/dev/null \
    | tail -1 | cut -d= -f2-
}

seed_env() {
  FM_HOME="$TMP_ROOT/seed-parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  "$@"
}

REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = clone ] && [ "\${!#}" = "$TMP_ROOT/concurrent-home" ]; then
  printf 'clone\n' >> "$TMP_ROOT/provision-clones"
  if mkdir "$TMP_ROOT/provision-first" 2>/dev/null; then
    touch "$TMP_ROOT/provision.entered"
    while [ ! -f "$TMP_ROOT/provision.release" ]; do sleep 0.02; done
  fi
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKEBIN/git"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf ios | base64 | tr -d '\n')" \
  "$(printf 'Concurrent provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/provision.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-one.out" 2>&1 &
provision_one=$!
provision_wait=0
while [ ! -f "$TMP_ROOT/provision.entered" ]; do
  kill -0 "$provision_one" 2>/dev/null || fail "first provisioning attempt exited before cloning"
  provision_wait=$((provision_wait + 1))
  [ "$provision_wait" -le 250 ] || fail "first provisioning attempt never reached cloning"
  sleep 0.02
done
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-two.out" 2>&1 &
provision_two=$!
sleep 0.2
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "overlapping provisioning reached home classification concurrently"
touch "$TMP_ROOT/provision.release"
wait "$provision_one" || fail "first serialized provisioning attempt failed"
wait "$provision_two" || fail "reconciled provisioning attempt failed"
[ "$(cat "$TMP_ROOT/concurrent-home/.fm-secondmate-home")" = ios ] \
  || fail "serialized provisioning lost the published home"
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "reconciled provisioning cloned the already-published home"
pass "overlapping remote home provisioning serializes through publication and rollback"
if [ "${FM_TEST_PROVISION_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

mkdir -p "$TMP_ROOT/seed-parent/data" "$TMP_ROOT/seed-parent/state"
FM_SECONDMATE_CHARTER='Failing seed charter.' FM_SECONDMATE_SCOPE='failed seed' \
  FM_FAKE_SSH_MODE=provision-block-fail seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-fail remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-fail-home" --no-projects \
  > "$TMP_ROOT/seed-fail.out" 2>&1 &
seed_fail_pid=$!
seed_wait=0
while [ ! -f "$TMP_ROOT/seed.entered" ]; do
  kill -0 "$seed_fail_pid" 2>/dev/null || fail "failing seed exited before remote provisioning"
  seed_wait=$((seed_wait + 1))
  [ "$seed_wait" -le 250 ] || fail "failing seed never reached remote provisioning"
  sleep 0.02
done
FM_SECONDMATE_CHARTER='Successful seed charter.' FM_SECONDMATE_SCOPE='successful seed' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-keep remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-keep-home" --no-projects > "$TMP_ROOT/seed-keep.out" 2>&1 &
seed_keep_pid=$!
sleep 0.2
kill -0 "$seed_keep_pid" 2>/dev/null || fail "competing seed bypassed the shared registry transaction"
touch "$TMP_ROOT/seed.release"
if wait "$seed_fail_pid"; then
  fail "known-failing seed unexpectedly succeeded"
fi
wait "$seed_keep_pid" || fail "serialized successful seed failed"
assert_no_grep '- seed-fail ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed route survived rollback"
assert_grep '- seed-keep ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed rollback removed a competing successful route"
assert_present "$TMP_ROOT/seed-keep-home/.fm-secondmate-home" "serialized seed lost its published remote home"
pass "remote seed rollback preserves serialized competing routes"

: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unknown readiness charter.' FM_SECONDMATE_SCOPE='unknown readiness' \
  FM_FAKE_SSH_MODE=doctor-fix-unknown seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-unknown remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-unknown-home" --no-projects \
  > "$TMP_ROOT/seed-unknown.out" 2>&1; then
  fail "seeding claimed success after readiness repair completion became unknown"
fi
assert_grep 'remote readiness completion is unknown' "$TMP_ROOT/seed-unknown.out" \
  "unknown readiness did not report its distinct completion state"
assert_grep '- seed-unknown ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "unknown readiness removed the registered route"
assert_present "$TMP_ROOT/seed-parent/data/seed-unknown/brief.md" \
  "unknown readiness removed the scaffolded brief"
assert_absent "$TMP_ROOT/seed-unknown-home" \
  "unknown readiness proceeded into remote home provisioning"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fix-unknown -
doctor-fix-unknown --fix' ] || fail "unknown readiness did not occur during the repair stage"$'\n'"$(cat "$DOCTOR_LOG")"
pass "unknown readiness preserves its route and brief for reconciliation"

# A host that cannot hold a durable second mate must be rejected by the
# readiness gate before any home is created on it, and the operator must get the
# gap text rather than a bare refusal.
: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unready host charter.' FM_SECONDMATE_SCOPE='unready host' \
  FM_FAKE_SSH_MODE=doctor-human seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-toolless remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-toolless-home" --no-projects \
  > "$TMP_ROOT/seed-toolless.out" 2>&1; then
  fail "seeding proceeded against a host that is not ready for a remote second mate"
fi
assert_grep 'check gui-session=human:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the remaining human gap"
assert_grep 'action: gui-session:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the operator step that closes the gap"
assert_grep 'remote runtime preflight failed' "$TMP_ROOT/seed-toolless.out" \
  "the seed did not report the failing stage"
assert_absent "$TMP_ROOT/seed-toolless-home" "the seed provisioned a home despite a failing preflight"
assert_no_grep '- seed-toolless ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the refused route survived the preflight rollback"
assert_absent "$TMP_ROOT/seed-parent/data/seed-toolless/brief.md" \
  "the refused route left its scaffolded charter behind"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-human -
doctor-human --fix
doctor-human -' ] || fail "the seed did not run the check, repair, re-check sequence"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding checks, repairs, and re-checks readiness, then stops on a remaining gap"

# The same gate must accept a host whose only gaps were repairable.
: > "$DOCTOR_LOG"
rm -f "$TMP_ROOT/doctor.repaired"
out=$(FM_SECONDMATE_CHARTER='Repairable host charter.' FM_SECONDMATE_SCOPE='repairable host' \
  FM_FAKE_SSH_MODE=doctor-fixable seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-repair remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-repair-home" --no-projects 2>&1) \
  || fail "seeding refused a host whose gaps the repair closed"$'\n'"$out"
assert_present "$TMP_ROOT/seed-repair-home/.fm-secondmate-home" "the repaired host was never provisioned"
assert_grep '- seed-repair ' "$TMP_ROOT/seed-parent/data/secondmates.md" "the repaired route was not registered"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "the repaired seed did not re-check after its repair"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding proceeds once the repair closes every gap"

# Seeding must not need a copy of the project in this home: firstmate names the
# origin it already resolved, the seed validates and transports it, and the
# primary project tree is left exactly as it was found.
projects_snapshot() { # <dir>
  local dir=$1 path
  (
    cd "$dir" 2>/dev/null || exit 0
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        printf '%s %s\n' "$path" "$(sha256_file "$path")"
      else
        printf '%s\n' "$path"
      fi
    done
  )
}
mkdir -p "$TMP_ROOT/seed-parent/projects"
fm_git_init_commit "$TMP_ROOT/seed-parent/projects/resident"
git init -q --bare "$TMP_ROOT/beta.git"
fm_git_init_commit "$TMP_ROOT/beta-src"
git -C "$TMP_ROOT/beta-src" remote add origin "file://$TMP_ROOT/beta.git"
git -C "$TMP_ROOT/beta-src" push -q -u origin HEAD
rm -rf "$TMP_ROOT/beta-src"
cat > "$TMP_ROOT/seed-parent/data/projects.md" <<'EOF'
- beta [direct-PR] - beta project (added 2026-08-06)
- delta [local-only] - delta project (added 2026-08-06)
EOF
BETA_ORIGIN="file://$TMP_ROOT/beta.git"
PROJECTS_BEFORE=$(projects_snapshot "$TMP_ROOT/seed-parent/projects")

if FM_SECONDMATE_CHARTER='Unsupplied origin charter.' FM_SECONDMATE_SCOPE='unsupplied origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noorigin remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noorigin-home" beta > "$TMP_ROOT/seed-noorigin.out" 2>&1; then
  fail "seeding an uncloned project with no origin claimed success"
fi
assert_grep 'pass beta=<origin-url>' "$TMP_ROOT/seed-noorigin.out" \
  "the refusal did not name how to supply the origin"
assert_absent "$TMP_ROOT/seed-noorigin-home" "the unresolvable origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Unsafe origin charter.' FM_SECONDMATE_SCOPE='unsafe origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unsafe remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unsafe-home" 'beta=ext::git-upload-pack' \
  > "$TMP_ROOT/seed-unsafe.out" 2>&1; then
  fail "seeding accepted a remote-helper origin the remote host would execute"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/seed-unsafe.out" \
  "the unsafe-origin refusal did not name the reason"
assert_absent "$TMP_ROOT/seed-unsafe-home" "the unsafe origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Local-only charter.' FM_SECONDMATE_SCOPE='local only' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-localonly remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-localonly-home" "delta=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-localonly.out" 2>&1; then
  fail "a supplied origin bypassed the local-only delivery-mode refusal"
fi
assert_grep 'is local-only and cannot be provisioned remotely' "$TMP_ROOT/seed-localonly.out" \
  "the local-only refusal did not name the registered mode"

if FM_SECONDMATE_CHARTER='Unregistered charter.' FM_SECONDMATE_SCOPE='unregistered' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unregistered remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unregistered-home" "gamma=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-unregistered.out" 2>&1; then
  fail "a supplied origin bypassed the project registry requirement"
fi
assert_grep 'has no registry record' "$TMP_ROOT/seed-unregistered.out" \
  "the unregistered-project refusal did not name the missing record"

out=$(FM_SECONDMATE_CHARTER='Own beta delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='beta delivery and validation' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noclone remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noclone-home" "beta=$BETA_ORIGIN" 2>&1) \
  || fail "seeding refused a registered project whose origin was supplied"$'\n'"$out"
assert_contains "$out" "home=remote-mac:$TMP_ROOT/seed-noclone-home" \
  "the no-clone seed did not report the host-qualified home"
assert_grep '- seed-noclone ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the no-clone seed did not register the remote route"
assert_present "$TMP_ROOT/seed-noclone-home/projects/beta/README.md" \
  "the remote host did not clone the supplied origin"
[ "$(git -C "$TMP_ROOT/seed-noclone-home/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
  || fail "the remote clone did not come from the supplied origin"
assert_grep '- beta [direct-PR]' "$TMP_ROOT/seed-noclone-home/data/projects.md" \
  "the remote home did not publish the project's registered posture"
assert_absent "$TMP_ROOT/seed-parent/projects/beta" \
  "seeding cloned the project into the primary project tree"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding changed the primary project tree"
pass "remote seeding provisions a supplied origin without touching the primary project tree"

# The receiving host validates the origin itself rather than trusting whatever
# reached it, so a manifest naming an executable transport provisions nothing.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\nproject=%s|%s|%s|%s\n' \
  "$(printf unsafe-origin | base64 | tr -d '\n')" \
  "$(printf 'Unsafe origin manifest charter.\n' | base64 | tr -d '\n')" \
  "$(printf beta | base64 | tr -d '\n')" \
  "$(printf 'ext::git-upload-pack' | base64 | tr -d '\n')" \
  "$(printf -- '- beta [direct-PR] - beta project (added 2026-08-06)' | base64 | tr -d '\n')" \
  "$(printf direct-PR | base64 | tr -d '\n')" \
  > "$TMP_ROOT/unsafe-origin.manifest"
if FM_HOME="$TMP_ROOT/unsafe-origin-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/unsafe-origin.manifest" \
  > "$TMP_ROOT/unsafe-origin.out" 2>&1; then
  fail "remote provisioning accepted an origin the transport had not validated"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/unsafe-origin.out" \
  "remote provisioning did not name the rejected origin"
assert_absent "$TMP_ROOT/unsafe-origin-home" "the rejected manifest left a remote home behind"
pass "remote provisioning re-validates a supplied origin at the receiving host"

# Firstmate is a shared template, so seeding must carry a project origin from any
# forge or host, not a privileged one. These four URL shapes have to survive the
# parent's validation, the manifest, the transport, and the receiving host's own
# validation, and arrive at git unchanged. A fixture resolver records the exact
# clone source the remote side hands to git and then serves it from a local bare
# repository, because an offline run cannot reach bitbucket.org itself.
FORGE_CLONE_LOG="$TMP_ROOT/forge-clone.log"
FORGE_ORIGIN_MAP="$TMP_ROOT/forge-origin.map"
: > "$FORGE_CLONE_LOG"
: > "$FORGE_ORIGIN_MAP"
forge_project() { # <project> <origin-url>
  local project=$1 origin=$2 tab
  tab=$(printf '\t')
  fm_git_init_commit "$TMP_ROOT/forge-src-$project"
  printf 'served from %s\n' "$origin" > "$TMP_ROOT/forge-src-$project/ORIGIN.txt"
  git -C "$TMP_ROOT/forge-src-$project" add ORIGIN.txt
  git -C "$TMP_ROOT/forge-src-$project" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm origin
  git clone --quiet --bare "$TMP_ROOT/forge-src-$project" "$TMP_ROOT/forge-$project.git"
  rm -rf "$TMP_ROOT/forge-src-$project"
  printf '%s%s%s\n' "$origin" "$tab" "$TMP_ROOT/forge-$project.git" >> "$FORGE_ORIGIN_MAP"
  printf -- '- %s [direct-PR] - %s project (added 2026-08-06)\n' "$project" "$project" \
    >> "$TMP_ROOT/seed-parent/data/projects.md"
}
forge_project bitbucket-app 'https://bitbucket.org/team/bitbucket-app.git'
forge_project ghe-app 'https://git.example.com/org/ghe-app.git'
forge_project gitlab-app 'ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git'
forge_project scp-app 'git@host.internal:group/scp-app.git'

cat > "$REMOTE_ROOT/bin/git" <<SH
#!/usr/bin/env bash
# Fixture origin resolver for the remote side: record the clone source exactly as
# the production code hands it to git, then serve any recorded URL from a local
# bare repository so the run stays offline. Everything else is real git.
set -u
if [ "\${1:-}" = clone ]; then
  printf '%s\n' "\$*" >> '$FORGE_CLONE_LOG'
  args=()
  for arg in "\$@"; do
    replacement=\$(awk -v k="\$arg" -F'\t' '\$1 == k { print \$2; exit }' '$FORGE_ORIGIN_MAP' 2>/dev/null)
    if [ -n "\$replacement" ]; then args+=("\$replacement"); else args+=("\$arg"); fi
  done
  exec '$REAL_GIT' "\${args[@]}"
fi
exec '$REAL_GIT' "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/git"

FORGE_HOME="$TMP_ROOT/seed-forge-home"
out=$(FM_SECONDMATE_CHARTER='Own delivery for projects hosted anywhere.' \
  FM_SECONDMATE_SCOPE='multi-forge delivery' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-forge remote-mac "$REMOTE_ROOT" \
  "$FORGE_HOME" \
  'bitbucket-app=https://bitbucket.org/team/bitbucket-app.git' \
  'ghe-app=https://git.example.com/org/ghe-app.git' \
  'gitlab-app=ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git' \
  'scp-app=git@host.internal:group/scp-app.git' 2>&1) \
  || fail "seeding refused origins hosted outside GitHub"$'\n'"$out"

while IFS="$(printf '\t')" read -r forge_origin _; do
  [ -n "$forge_origin" ] || continue
  assert_grep "$forge_origin" "$FORGE_CLONE_LOG" \
    "the remote host did not clone from the supplied origin $forge_origin"
done < "$FORGE_ORIGIN_MAP"
for forge_project_name in bitbucket-app ghe-app gitlab-app scp-app; do
  assert_present "$FORGE_HOME/projects/$forge_project_name/.git" \
    "the remote home has no clone for $forge_project_name"
  assert_grep "$forge_project_name" "$FORGE_HOME/data/projects.md" \
    "the remote registry omitted $forge_project_name"
  assert_absent "$TMP_ROOT/seed-parent/projects/$forge_project_name" \
    "seeding $forge_project_name cloned it into the primary project tree"
done
# Each clone must carry its own origin's content, so one shared fixture repo
# cannot make a mismatched route look routed.
[ "$(cat "$FORGE_HOME/projects/bitbucket-app/ORIGIN.txt")" = \
  'served from https://bitbucket.org/team/bitbucket-app.git' ] \
  || fail "the bitbucket route did not clone its own origin"
[ "$(cat "$FORGE_HOME/projects/scp-app/ORIGIN.txt")" = \
  'served from git@host.internal:group/scp-app.git' ] \
  || fail "the scp-like route did not clone its own origin"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding non-GitHub projects changed the primary project tree"
assert_grep '- seed-forge ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the multi-forge route was not registered"

rm -f "$REMOTE_ROOT/bin/git"
[ -z "$(git -C "$REMOTE_ROOT" status --porcelain)" ] \
  || fail "the fixture origin resolver was left behind in the remote code root"
pass "seeding carries bitbucket, self-hosted, and scp-like origins through to the remote clone"

# Provision and register the remote route from the captain-facing primary.
out=$(FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha)
assert_contains "$out" "home=remote-mac:$REMOTE_HOME" "remote seed did not report the host-qualified home"
assert_grep 'host: remote-mac; root:' "$PARENT/data/secondmates.md" "registry did not record the remote host dimension"
assert_present "$REMOTE_HOME/.fm-secondmate-home" "remote provisioning did not publish the identity marker"
assert_present "$REMOTE_HOME/projects/alpha/.git" "remote provisioning did not clone the project on that host"
assert_grep "$REMOTE_HOME/state/parent-replies.status" "$REMOTE_HOME/data/charter.md" "remote charter did not use its append-only reply log"
assert_no_grep "$PARENT/state/ios.status" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local status path"
if FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$TMP_ROOT/other-home" alpha \
  >/dev/null 2>&1; then
  fail "remote seed allowed an existing id to move to another home"
fi
assert_grep "home: $REMOTE_HOME" "$PARENT/data/secondmates.md" "refused remote reassignment changed the durable route"
pass "remote seed registers the route and provisions the whole home and project clone on that host"

PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
printf 'complete inherited payload\n' > "$TMP_ROOT/inherit-complete"
inherit_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-complete" | tr -d ' ')
inherit_hash=$(sha256_file "$TMP_ROOT/inherit-complete")
if printf 'complete' | FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 1 >/dev/null 2>&1; then
  fail "remote inheritance published a truncated payload"
fi
assert_absent "$PROTOCOL_HOME/config/crew-harness" "truncated inheritance published a destination"
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 2 \
  < "$TMP_ROOT/inherit-complete" >/dev/null
printf 'stale inherited payload\n' > "$TMP_ROOT/inherit-stale"
inherit_stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-stale" | tr -d ' ')
inherit_stale_hash=$(sha256_file "$TMP_ROOT/inherit-stale")
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_stale_bytes" "$inherit_stale_hash" 1 \
  < "$TMP_ROOT/inherit-stale" >/dev/null 2>&1; then
  fail "remote inheritance accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/inherit-complete" "$PROTOCOL_HOME/config/crew-harness" \
  || fail "superseded inheritance replaced the current payload"
pass "remote inheritance rejects incomplete and superseded payload generations"

# Add one local route to prove mixed fleets remain parseable and projected.
mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
cat >> "$PARENT/data/secondmates.md" <<EOF
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
EOF
remote_env "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "mixed local and remote registry validation failed"
pass "mixed local and remote routes validate without migration"

# Launch on the remote home's own configured backend. Parent metadata records
# host placement separately from that backend and arms the reply source.
printf 'pi\n' > "$PARENT/config/crew-harness"
printf 'codex --dash-model high\n' > "$PARENT/config/secondmate-harness"
launches_before_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_before_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
if FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-inherit-partial.out" 2>&1; then
  fail "remote spawn launched after ambiguous partial inheritance"
fi
launches_after_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_after_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_inherit" -eq "$launches_after_inherit" ] \
  || fail "remote spawn reached launch after ambiguous partial inheritance"
assert_absent "$PARENT/state/ios.meta" "failed remote inheritance published launch metadata"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate)
assert_contains "$out" 'remote=remote-mac backend=herdr' "remote spawn did not report separate host and backend dimensions"
assert_grep 'remote_host=remote-mac' "$PARENT/state/ios.meta" "parent metadata omitted the remote host"
assert_grep 'remote_backend=herdr' "$PARENT/state/ios.meta" "parent metadata omitted the remote-local backend"
assert_grep 'remote_herdr_session=fm-remote' "$PARENT/state/ios.meta" "parent metadata omitted the pinned remote Herdr session"
assert_grep 'remote_target=fm-remote:' "$PARENT/state/ios.meta" "parent metadata did not record an fm-remote endpoint"
assert_grep 'model=--dash-model' "$PARENT/state/ios.meta" "parent metadata stripped a leading dash from the remote model"
assert_grep 'effort=high' "$PARENT/state/ios.meta" "parent metadata did not preserve the remote effort"
assert_grep 'herdr_session=fm-remote' "$REMOTE_HOME/state/parent-route/ios.meta" "remote metadata did not record the pinned Herdr session"
assert_grep '--session fm-remote' "$HERDR_LOG" "remote launch did not target the fm-remote session"
assert_no_grep '--session default' "$HERDR_LOG" "remote launch targeted the interactive default session"
assert_grep 'window=remote:ios' "$PARENT/state/ios.meta" "parent metadata pretended the endpoint was local"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" "remote spawn did not arm its reply source"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "remote endpoint was not projected alive from its own host"
# Herdr reports a native agent state, so the delivery observation resolves
# without the rendered-output fallback a tmux endpoint needs.
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios)" = idle ] \
  || fail "remote endpoint delivery observation did not execute on its own host"
pass "remote spawn launches on the remote-local backend and records a host-qualified route"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-default-session.meta"
legacy_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  /^herdr_session=/ { print "herdr_session=default"; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
cp "$HERDR_LOG" "$TMP_ROOT/herdr-before-default-session.log"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "legacy default-session metadata was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios probe >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh capture ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios --force >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr >/dev/null 2>&1; then
  fail "legacy default-session metadata remained operational"
fi
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "legacy default-session metadata caused a Herdr operation"
assert_present "$REMOTE_HOME" "refused legacy retirement removed the remote home"
assert_grep 'herdr_session=default' "$remote_route_meta" "refused legacy retirement rewrote endpoint metadata"

awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "mismatched fm-remote target was not classified unverified"
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "mismatched fm-remote target caused a Herdr operation"
mv -f "$TMP_ROOT/remote-ios-before-default-session.meta" "$remote_route_meta"
pass "legacy and mismatched remote endpoints fail closed before backend access"

cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-nonherdr.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-nonherdr.md"
set +e
FM_FAKE_SSH_MODE=launch-nonherdr-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-nonherdr-route.out" 2>&1
nonherdr_parent_rc=$?
set -e
[ "$nonherdr_parent_rc" -ne 0 ] || fail "parent accepted a non-herdr remote launch route"
assert_grep "remote launch returned backend 'tmux', expected herdr" "$TMP_ROOT/spawn-nonherdr-route.out" \
  "parent refusal did not name the returned remote backend"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a non-herdr route refusal"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "parent removed or changed the registry route after a non-herdr route refusal"

set +e
FM_FAKE_SSH_MODE=launch-default-session-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-default-session-route.out" 2>&1
default_session_parent_rc=$?
set -e
[ "$default_session_parent_rc" -ne 0 ] || fail "parent accepted an interactive default-session remote route"
assert_grep "remote launch returned Herdr session 'default', expected 'fm-remote'" "$TMP_ROOT/spawn-default-session-route.out" \
  "parent refusal did not name the default session"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a default-session route refusal"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-legacy.meta"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-legacy-before-refusal.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
set +e
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr \
  > "$TMP_ROOT/legacy-alive-refusal.out" 2>&1
legacy_alive_rc=$?
set -e
[ "$legacy_alive_rc" -ne 0 ] || fail "remote control reused an alive legacy tmux endpoint"
assert_grep "endpoint is recorded on backend 'tmux', expected 'herdr'" "$TMP_ROOT/legacy-alive-refusal.out" \
  "remote refusal did not name the endpoint's recorded backend"
cmp -s "$TMP_ROOT/remote-ios-legacy-before-refusal.meta" "$remote_route_meta" \
  || fail "remote refusal changed the legacy endpoint metadata"
assert_present "$TMUX_STATE" "remote refusal killed the alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "remote legacy refusal removed or changed the registry route"
mv -f "$TMP_ROOT/remote-ios-before-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "non-herdr remote endpoints are refused without changing either route"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale spawn preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-concurrent.out" 2>&1 &
spawn_concurrent=$!
spawn_inherit_wait=0
# Earlier inherited files traverse the worker before captain-shared.md, so give
# a loaded portable runner 30 seconds to reach this deliberately blocked write.
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$spawn_concurrent" 2>/dev/null || fail "remote spawn exited before its blocked inheritance write"
  spawn_inherit_wait=$((spawn_inherit_wait + 1))
  [ "$spawn_inherit_wait" -le 1500 ] || fail "remote spawn never reached its blocked inheritance write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current post-spawn preference
EOF
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/spawn-concurrent-push.out" 2>&1 &
spawn_config_push=$!
sleep 0.2
kill -0 "$spawn_config_push" 2>/dev/null \
  || fail "config push bypassed the active remote spawn inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$spawn_concurrent" || fail "serialized remote spawn failed"
wait "$spawn_config_push" || fail "config push failed after serialized remote spawn"$'\n'"$(cat "$TMP_ROOT/spawn-concurrent-push.out")"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current post-spawn preference' ] \
  || fail "stale spawn inheritance overwrote later config convergence"
pass "remote spawn serializes inheritance through launch publication"

# A normal marked parent request traverses SSH as a durable remote inbox
# record plus a rung doorbell - the payload is never typed into the pane. An
# ambiguous transport (the remote leg executed, then ssh exit 255) is retried
# identically once, and the idempotent remote write lands both executions on
# ONE record; the send reports itself unconfirmed with a correlation-preserving
# resend command, and the expectation resolves only after the correlated remote log
# delta is ingested.
ssh_before_send=$(cat "$SSH_COUNT")
records_before_send=$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
set +e
FM_FAKE_SSH_MODE=ambiguous remote_env "$ROOT/bin/fm-send.sh" fm-ios \
  'report the build result' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
send_rc=$?
set -e
[ "$send_rc" -ne 0 ] || fail "ambiguous remote send claimed definite delivery"
assert_grep 'Only the correlation-reusing resend below is idempotent' "$TMP_ROOT/send.err" "ambiguous remote send did not state the correlation-preserving resend boundary"
assert_no_grep 'do not resend' "$TMP_ROOT/send.err" "ambiguous remote send kept the deleted do-not-resend trap"
ssh_after_send=$(cat "$SSH_COUNT")
[ "$ssh_after_send" -eq $((ssh_before_send + 2)) ] \
  || fail "ambiguous remote send was not retried exactly once (ssh calls: $((ssh_after_send - ssh_before_send)))"
records_after_send=$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
[ "$records_after_send" -eq $((records_before_send + 1)) ] \
  || fail "the retried remote steer did not dedup onto one new record, went $records_before_send -> $records_after_send"
assert_no_grep 'report the build result' "$HERDR_LOG" "the steer payload was typed into the remote pane"
assert_grep 'Firstmate instruction waiting' "$HERDR_LOG" "the remote doorbell never rang"
CORR=$(newest_remote_inbox_corr)
[ -n "$CORR" ] || fail "remote send did not carry a correlation token"
assert_grep "FM_PENDING_REPLY_EXISTING_CORR=$CORR" "$TMP_ROOT/send.err" "ambiguous remote send did not print its correlation-reusing command"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = delivery_unknown ] || fail "ambiguous remote send did not preserve its pending expectation"
printf 'done [corr=%s]: remote build passed\n' "$CORR" >> "$REMOTE_HOME/state/parent-replies.status"
SID='remote-reply-ios'
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the correlated answer"
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 1 "$RESULT" >/dev/null \
  || fail "remote reply ingest failed"
assert_grep "done [corr=$CORR]: remote build passed" "$PARENT/state/ios.status" "correlated remote reply did not reach the parent status channel"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = resolved ] || fail "correlated remote reply did not resolve the parent expectation"
pass "marked send and routed reply complete through the existing parent correlation owner"
rm -f "$PARENT/state/.wake-queue"

printf '{"revision":2}\n' > "$PARENT/config/crew-dispatch.json"
printf 'grok\n' > "$PARENT/config/crew-harness"
set +e
FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-partial.out" 2>&1
config_partial_rc=$?
set -e
[ "$config_partial_rc" -ne 0 ] || fail "partial remote inheritance claimed complete convergence"
assert_grep '"revision":2' "$REMOTE_HOME/config/crew-dispatch.json" "partial inheritance did not apply its first file"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" != grok ] \
  || fail "partial inheritance unexpectedly applied the failed file"
NUDGE_MARKER="$PARENT/state/.secondmate-nudge-pending/ios.pending"
assert_grep 'remote=1' "$NUDGE_MARKER" "partial inheritance left no durable remote reread marker"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-partial-retry.out" \
  || fail "bootstrap did not converge partial remote inheritance"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = grok ] \
  || fail "bootstrap did not apply the remaining inherited file"
assert_absent "$NUDGE_MARKER" "bootstrap cleared no remote reread marker after convergence"
PARTIAL_CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$PARTIAL_CONFIG_CORR" ] || fail "bootstrap config reread did not carry a correlation token"
printf 'done [corr=%s]: converged inherited config re-read\n' "$PARTIAL_CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the converged config acknowledgment"
PARTIAL_CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.2.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 2 "$PARTIAL_CONFIG_RESULT" >/dev/null \
  || fail "converged remote config acknowledgment was not ingested"
pass "partial remote inheritance retains reread intent through bootstrap convergence"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale concurrent preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-concurrent-first.out" 2>&1 &
config_first=$!
inherit_wait=0
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$config_first" 2>/dev/null || fail "first inheritance transaction exited before its blocked write"
  inherit_wait=$((inherit_wait + 1))
  # Match the earlier spawn/inheritance wait: a loaded portable runner can
  # spend several seconds in the remote entrypoint before reaching this write.
  [ "$inherit_wait" -le 1500 ] || fail "first inheritance transaction never reached its blocked write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current concurrent preference
EOF
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-concurrent-second.out" 2>&1 &
config_second=$!
sleep 0.2
kill -0 "$config_second" 2>/dev/null \
  || fail "bootstrap bypassed the active remote inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$config_first" || fail "first serialized inheritance transaction failed"
wait "$config_second" || fail "bootstrap inheritance transaction failed after waiting"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current concurrent preference' ] \
  || fail "later bootstrap convergence was overwritten by stale inherited bytes"
pass "config push and bootstrap serialize remote inheritance convergence"

printf 'codex\n' > "$PARENT/config/crew-harness"
# A failed reread nudge now means the durable remote inbox RECORD could not be
# written (a swallowed doorbell alone no longer fails a recorded steer), so
# the failure is induced by making the remote steering inbox unwritable.
chmod 555 "$REMOTE_HOME/state/parent-route/ios.inbox"
if remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-fail.out" 2>&1; then
  chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
  fail "remote config push claimed success after its reread record could not be written"
fi
if [ ! -f "$NUDGE_MARKER" ]; then
  chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
  printf 'config push failure output:\n%s\n' "$(cat "$TMP_ROOT/config-push-fail.out")" >&2
  fail "failed remote config reread did not retain a retry marker"
fi
assert_grep 'remote=1' "$NUDGE_MARKER" "remote config reread marker lost its placement"
chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-retry.out" \
  || fail "unchanged remote config push did not retry its pending reread"
assert_absent "$NUDGE_MARKER" "successful remote config reread left its retry marker"
assert_grep 'config-reread: sent' "$TMP_ROOT/config-push-retry.out" "remote config reread retry was not reported"
CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$CONFIG_CORR" ] || fail "remote config reread did not carry a correlation token"
printf 'done [corr=%s]: inherited config re-read\n' "$CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the config reread acknowledgement"
CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 3 "$CONFIG_RESULT" >/dev/null \
  || fail "remote config reread acknowledgement was not ingested"
pass "remote inherited config retains and retries a failed live reread nudge"

resolve_ios_pending() {
  local pending_record pending_corr pending_result pending_seq
  for pending_record in "$PARENT/state/pending-replies"/*; do
    [ -f "$pending_record" ] || continue
    [ "$(grep '^task_id=' "$pending_record" | cut -d= -f2-)" = ios ] || continue
    [ "$(grep '^phase=' "$pending_record" | cut -d= -f2-)" != resolved ] || continue
    pending_corr=$(basename "$pending_record")
    printf 'done [corr=%s]: concurrent inherited data re-read\n' "$pending_corr" \
      >> "$REMOTE_HOME/state/parent-replies.status"
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
      || fail "remote reply source did not capture a concurrent inheritance acknowledgment"
    pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print | sort | tail -1)
    pending_seq=${pending_result%.result}
    pending_seq=${pending_seq##*.}
    remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "$pending_seq" "$pending_result" >/dev/null \
      || fail "concurrent inheritance acknowledgment was not ingested"
  done
}
resolve_ios_pending

# Structured fleet state comes from each home's own snapshot. The remote host is
# explicit, and the local route remains alongside it.
SNAPSHOT=$(remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == true' >/dev/null \
  || fail "remote structured observation did not prove the remote home present"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
tmux_state_before=$(cat "$TMUX_STATE")
launches_before_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
[ "$(cat "$TMUX_STATE")" = "$tmux_state_before" ] \
  || fail "liveness changed or killed the alive legacy endpoint"
launches_after_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "startup reports alive legacy backends without changing their routes"

# Host loss maps to unknown/unavailable and never creates a local replacement.
launches_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
rm -rf -- "$PARENT/state/.watch.lock"
rm -f -- "$PARENT/state/.last-watcher-beat"
BOOT_UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_UNAVAILABLE" 'SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown' \
  "bootstrap did not preserve an unreachable remote endpoint as unknown"
UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$UNAVAILABLE" | jq -e '.secondmate_current.records | any(.id == "ios" and .current.state == "unknown")' >/dev/null \
  || fail "unreachable remote host was not projected unknown"
printf '%s' "$UNAVAILABLE" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null' >/dev/null \
  || fail "unreachable remote home presence was not projected unknown"
rm -f "$PARENT/state/.wake-queue"
launches_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before" -eq "$launches_after" ] || fail "unreachable projection attempted a replacement launch"
assert_present "$PARENT/state/ios.meta" "unreachable readiness removed the parent route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "unreachable readiness removed the registry route"
pass "unreachable remote state remains unknown with no local respawn or failover"

# Retirement delegates its safety check to the remote home. An in-flight child
# record refuses cleanup and preserves both machines' durable routes.
# A sibling remote secondmate workspace shares fm-remote and must survive every
# refusal and the eventual successful retirement of ios.
# This fixture overrides FM_ROOT for transport, so teardown's root-owned guard
# sees the fixture root rather than the source script path used by fm-send.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
resolve_ios_pending
SIBLING_CREATE=$("$REMOTE_ROOT/bin/herdr" workspace create --cwd "$REMOTE_ROOT" \
  --label 2ndmate-macos --no-focus --session fm-remote)
SIBLING_WORKSPACE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.workspace.workspace_id')
SIBLING_PANE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.root_pane.pane_id')
[ -n "$SIBLING_WORKSPACE" ] && [ "$SIBLING_WORKSPACE" != null ] \
  || fail "the shared-session sibling fixture did not create a workspace"
[ -n "$SIBLING_PANE" ] && [ "$SIBLING_PANE" != null ] \
  || fail "the shared-session sibling fixture did not create a pane"
printf 'kind=ship\n' > "$REMOTE_HOME/state/child.meta"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement ignored in-flight child work"
fi
assert_present "$REMOTE_HOME" "refused remote retirement removed the home"
assert_present "$PARENT/state/ios.meta" "refused remote retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "refused remote retirement removed the route"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
remote_env "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
  || fail "bootstrap failed while repairing a preserved remote reply source"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" \
  "bootstrap did not repair reply registration after retirement rollback"
resolve_ios_pending
rm -f "$REMOTE_HOME/state/child.meta"
mkdir -p "$PARENT/data/handoff"
ln -s "$TMP_ROOT/missing-outbox-target" "$PARENT/data/handoff/ios.outbox.md"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted an unsafe backlog outbox"
fi
assert_present "$REMOTE_HOME" "unsafe backlog outbox retirement removed the remote home"
rm -f "$PARENT/data/handoff/ios.outbox.md"
mkdir -p "$TMP_ROOT/external-pending"
printf 'task_id=ios\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
mv "$PARENT/state/pending-replies" "$PARENT/state/pending-replies.safe"
ln -s "$TMP_ROOT/external-pending" "$PARENT/state/pending-replies"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted a symlinked pending-replies directory"
fi
assert_present "$REMOTE_HOME" "unsafe pending-replies retirement removed the remote home"
assert_present "$TMP_ROOT/external-pending/escape" "unsafe retirement removed an external pending reply"
rm -f "$PARENT/state/pending-replies"
mv "$PARENT/state/pending-replies.safe" "$PARENT/state/pending-replies"
retired_wake_corr=$(FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_create "$2" "$2/state" ios "New routed work is in your backlog."
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT") \
  || fail "could not seed remote receiver wake retirement state"
retired_wake_rec="$PARENT/state/pending-replies/$retired_wake_corr"
FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_set "$2" phase resolved
  fm_pending_reply_set "$2" delivered_epoch 1
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$retired_wake_rec" \
  || fail "could not settle remote receiver wake retirement state"
printf 'confirmed:%s\n' "$retired_wake_corr" > "$PARENT/state/.backlog-handoff-ios.wake-pending"
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -f "$4" ]; do sleep 0.02; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$handoff_lock" "$TMP_ROOT/handoff.entered" \
  "$TMP_ROOT/handoff.release" &
handoff_holder_pid=$!
handoff_wait=0
while [ ! -f "$TMP_ROOT/handoff.entered" ]; do
  kill -0 "$handoff_holder_pid" 2>/dev/null || fail "handoff lock holder exited before acquiring the route lock"
  handoff_wait=$((handoff_wait + 1))
  [ "$handoff_wait" -le 250 ] || fail "handoff lock holder never acquired the route lock"
  sleep 0.02
done
rm -f "$TMUX_STATE" "$TMP_ROOT/launch.entered" "$TMP_ROOT/launch.release"
FM_FAKE_SSH_MODE=launch-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-retirement.out" 2>&1 &
spawn_retirement_pid=$!
launch_wait=0
# The respawn performs readiness and inheritance jobs before launch, so allow
# the same 30-second loaded-runner bound as the earlier blocked worker path.
while [ ! -f "$TMP_ROOT/launch.entered" ]; do
  kill -0 "$spawn_retirement_pid" 2>/dev/null || fail "remote respawn exited before its blocked launch"
  launch_wait=$((launch_wait + 1))
  [ "$launch_wait" -le 1500 ] || fail "remote respawn never reached its blocked launch"
  sleep 0.02
done
remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/teardown-serialized.out" 2>&1 &
teardown_pid=$!
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active remote respawn"
assert_present "$REMOTE_HOME" "remote retirement removed the home during an active remote respawn"
touch "$TMP_ROOT/launch.release"
if ! wait "$spawn_retirement_pid"; then
  printf 'serialized respawn output:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
  fail "serialized remote respawn failed"
fi
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active backlog handoff"
touch "$TMP_ROOT/handoff.release"
wait "$handoff_holder_pid" || fail "handoff lock holder failed to release"
if ! wait "$teardown_pid"; then
  printf 'serialized retirement output:\n%s\n' "$(cat "$TMP_ROOT/teardown-serialized.out")" >&2
  fail "safe remote retirement failed after handoff serialization"
fi
assert_absent "$REMOTE_HOME" "remote retirement did not remove the remote home"
assert_absent "$PARENT/state/ios.meta" "remote retirement did not remove parent metadata"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote retirement left receiver wake state that could poison a replacement route"
assert_absent "$retired_wake_rec" "remote retirement left the retired receiver wake correlation"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" "remote retirement did not remove the registry route"
jq -e --arg workspace "$SIBLING_WORKSPACE" --arg pane "$SIBLING_PANE" '
  any(.workspaces[]; .workspace_id == $workspace and .label == "2ndmate-macos")
  and any(.tabs[]; .workspace_id == $workspace and .pane_id == $pane)
' "$HERDR_STATE" >/dev/null \
  || fail "remote retirement removed the sibling secondmate workspace or pane from fm-remote"
assert_no_grep 'session stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote session"
assert_no_grep 'server stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote server"
pass "remote retirement refuses child work, then removes only its own endpoint while a shared-session sibling survives"

echo "ALL TESTS PASSED"
