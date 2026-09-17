#!/usr/bin/env bash
# tests/fm-remote-secondmate-parent-binding.test.sh - regression coverage for the
# fm-remote-sm-cleanup-parent-binding-s1 scout report: finished-worker cleanup
# inside a REMOTE second-mate home refused forever with "cannot resolve the
# primary home ... durable parent binding", because the remote launch hands the
# child the remote code checkout as its parent home (bin/fm-spawn.sh's sole
# writer of FM_PUBLIC_FOLLOWUP_PRIMARY_HOME receives FM_HOME=$FM_ROOT from
# bin/fm-remote-secondmate-control.sh's host-local launch), and that path can
# never carry the parent's real state or registry.
#
# The fix (report section 7, captain-approved same-machine scope): a durable
# .fm-secondmate-parent record, written once at seeding next to the
# .fm-secondmate-home identity marker, names this home's route to its parent as
# "local" or "remote". bin/fm-teardown.sh's cleanup gate reads it and treats a
# remote parent as OUT OF SCOPE (never refuses purely for being cross-machine,
# since the whole promised-public-reply subsystem is same-filesystem by
# construction) while still refusing on a genuine same-filesystem signal
# committed directly to this home's own .env file - never on an unrelated
# process-environment export, which is what let the remote host's own login
# shell mask into this home's binding before.
#
# This drives the REAL remote route (fm-remote-home-seed.sh -> fm-on.sh ->
# fm-remote-entrypoint.sh -> the host-local fm-remote-secondmate-control.sh ->
# the real bin/fm-spawn.sh --secondmate) across the repo's own deterministic SSH
# boundary and Herdr fixture, then runs the real bin/fm-teardown.sh for a
# finished child worker inside the produced remote home - never source-text
# matching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
# shellcheck source=bin/fm-repo-concurrency-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/fm-repo-concurrency-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-parent-binding)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
CLAIMS="$TMP_ROOT/claims"
PUBLISH_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

cleanup() {
  local worker_pid=''
  if [ -n "$PUBLISH_PID" ]; then
    touch "$PUBLISH_RELEASE" 2>/dev/null || true
    kill "$PUBLISH_PID" 2>/dev/null || true
    wait "$PUBLISH_PID" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

PUBLISH_HOME="$TMP_ROOT/publication-home"
PUBLISH_FAKEBIN=$(fm_fakebin "$TMP_ROOT/publication-fake")
PUBLISH_ENTERED="$TMP_ROOT/publication-marker-entered"
PUBLISH_RELEASE="$TMP_ROOT/publication-marker-release"
PUBLISH_MANIFEST="$TMP_ROOT/publication.manifest"
REAL_MV=$(command -v mv)
cat > "$PUBLISH_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "$destination" in
  */.fm-secondmate-home)
    touch "$FM_TEST_PUBLISH_ENTERED"
    while [ ! -f "$FM_TEST_PUBLISH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBLISH_FAKEBIN/mv"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
  "$(printf publication | base64 | tr -d '\n')" \
  "$(printf 'Publication-order regression charter.\n' | base64 | tr -d '\n')" \
  "$(printf publish-host | base64 | tr -d '\n')" > "$PUBLISH_MANIFEST"
PATH="$PUBLISH_FAKEBIN:$PATH" FM_HOME="$PUBLISH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PUBLISH_ENTERED="$PUBLISH_ENTERED" \
  FM_TEST_PUBLISH_RELEASE="$PUBLISH_RELEASE" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$PUBLISH_MANIFEST" >/dev/null 2>&1 &
PUBLISH_PID=$!
publish_wait=0
while [ ! -f "$PUBLISH_ENTERED" ]; do
  kill -0 "$PUBLISH_PID" 2>/dev/null || fail "remote provisioning exited before its completion marker"
  publish_wait=$((publish_wait + 1))
  [ "$publish_wait" -le 250 ] || fail "remote provisioning never reached its completion marker"
  sleep 0.02
done
cmp -s "$PUBLISH_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=publish-host\n'
) || fail "remote provisioning exposed completion before publishing the durable parent record"
assert_absent "$PUBLISH_HOME/.fm-secondmate-home" \
  "the remote identity marker must remain absent until durable parent publication completes"
touch "$PUBLISH_RELEASE"
wait "$PUBLISH_PID" || fail "remote provisioning failed after publishing durable state"
PUBLISH_PID=
assert_present "$PUBLISH_HOME/.fm-secondmate-home" \
  "remote provisioning must publish its identity marker as the completion point"
pass "remote provisioning publishes durable parent state before its completion marker"

# --- the remote host's tracked code root, real git repos, one project --------
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
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

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"

# The primary home is the X-mode / relay home: the captain's real activation.
printf 'FMX_PAIRING_TOKEN=repro-token\n' > "$PARENT/.env"

# --- deterministic SSH boundary, identical shape to the lifecycle e2e suite --
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
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
   && [ "$_command_action" = launch ] \
   && [ -n "${FM_TEST_PUBLICATION_TARGET:-}" ]; then
  out=$("$FM_FAKE_REMOTE_ENTRYPOINT" "$@")
  rc=$?
  rm -f "$FM_TEST_PUBLICATION_TARGET"
  ln -s "$FM_TEST_PUBLICATION_FOREIGN" "$FM_TEST_PUBLICATION_TARGET" || exit 94
  printf '%s\n' "$out"
  exit "$rc"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# A clone-local insteadOf rule changes `git remote get-url` output without
# changing the configured origin. Remote seeding must use the same raw origin
# value as repository-authority hashing, or it can record and clone a different
# repository while overlap checks compare against the original one.
git init -q --bare "$TMP_ROOT/rewrite-real.git"
git init -q --bare "$TMP_ROOT/rewrite-decoy.git"
git -C "$PARENT/projects" init -q -b main rewrite
git -C "$PARENT/projects/rewrite" config user.email test@example.com
git -C "$PARENT/projects/rewrite" config user.name Test
printf 'rewrite\n' > "$PARENT/projects/rewrite/README.md"
git -C "$PARENT/projects/rewrite" add README.md
git -C "$PARENT/projects/rewrite" commit -qm init
REWRITE_ORIGIN="file://$TMP_ROOT/rewrite-real.git"
REWRITE_DECOY="file://$TMP_ROOT/rewrite-decoy.git"
git -C "$PARENT/projects/rewrite" remote add origin "$REWRITE_ORIGIN"
git -C "$PARENT/projects/rewrite" push -q -u origin main
git --git-dir="$TMP_ROOT/rewrite-real.git" symbolic-ref HEAD refs/heads/main
git -C "$PARENT/projects/rewrite" config --local "url.$REWRITE_DECOY.insteadOf" "$REWRITE_ORIGIN"
[ "$(git -C "$PARENT/projects/rewrite" remote get-url origin)" = "$REWRITE_DECOY" ] \
  || fail "insteadOf regression fixture did not rewrite the porcelain origin"
[ "$(git -C "$PARENT/projects/rewrite" config --local --get remote.origin.url)" = "$REWRITE_ORIGIN" ] \
  || fail "insteadOf regression fixture changed the stored origin"
printf '%s\n' '- rewrite [direct-PR] - rewrite project (added 2026-09-17)' >> "$PARENT/data/projects.md"
REWRITE_HOME="$TMP_ROOT/remote-rewrite-home"
FM_SECONDMATE_CHARTER='Own rewrite-origin work on the build Mac.' \
  FM_SECONDMATE_SCOPE='rewrite repository work' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" rewrite-route remote-mac "$REMOTE_ROOT" "$REWRITE_HOME" rewrite \
  >/dev/null || fail "remote seeding failed through an insteadOf-configured source clone"
REWRITE_EXPECTED_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$PARENT/projects/rewrite") \
  || fail "raw configured rewrite origin could not be normalized"
REWRITE_REMOTE_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$REWRITE_HOME/projects/rewrite") \
  || fail "remotely provisioned rewrite origin could not be normalized"
[ "$REWRITE_REMOTE_IDENTITY" = "$REWRITE_EXPECTED_IDENTITY" ] \
  || fail "remote seeding followed insteadOf-expanded porcelain output instead of the configured origin"
assert_grep "repo-identities: rewrite=sha256:$REWRITE_EXPECTED_IDENTITY" "$PARENT/data/secondmates.md" \
  "remote route registry identity did not use the configured origin under insteadOf"
pass "remote seeding and authority hashing share the raw configured origin under insteadOf"

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  >/dev/null || fail "real remote secondmate seeding failed"

# --- the durable record itself: the fundamental part of the fix -------------
assert_present "$REMOTE_HOME/.fm-secondmate-parent" \
  "real remote provisioning must write a durable parent record"
REMOTE_ALPHA_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$REMOTE_HOME/projects/alpha") \
  || fail "real remote project identity could not be normalized"
cmp -s "$REMOTE_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nrepo_scope_snapshot=fm-remote-repo-scope.v1\nrepo_scope_count=1\nrepo_authority_count=0\nrepo_scope_identity=sha256:%s\nparent_host=remote-mac\n' \
    "$REMOTE_ALPHA_IDENTITY"
) || fail "real remote provisioning must write the exact durable remote parent record"
assert_grep "repo-identities: alpha=sha256:$REMOTE_ALPHA_IDENTITY" "$PARENT/data/secondmates.md" \
  "a same-named remote route must durably record the actual seeded repository identity"

# A legacy remote row without durable identities cannot be refreshed from the
# same-named root clone alone, but an explicit origin can repair that route.
sed -E '/^- ios / s/; repo-identities: [^;]+//' "$PARENT/data/secondmates.md" > "$TMP_ROOT/legacy-route.registry"
mv "$TMP_ROOT/legacy-route.registry" "$PARENT/data/secondmates.md"
legacy_refresh_out=
if legacy_refresh_out=$(FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha 2>&1); then
  fail "legacy remote route refreshed from an unverified same-named root clone"
fi
assert_contains "$legacy_refresh_out" 'lacks durable repository identities' \
  "legacy route refusal did not explain the explicit-origin repair path"
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" \
    "alpha=file://$TMP_ROOT/alpha.git" >/dev/null \
  || fail "explicit-origin re-provision did not repair the legacy route"
assert_grep "repo-identities: alpha=sha256:$REMOTE_ALPHA_IDENTITY" "$PARENT/data/secondmates.md" \
  "explicit-origin re-provision did not restore the root-owned identity record"

# A remote route may intentionally provision a same-named project from a
# different origin than the root clone, so ownership checks must retain the
# seeded identity instead of reconstructing it from the root project name.
git init -q --bare "$TMP_ROOT/beta.git"
git -C "$PARENT/projects" init -q -b main beta
git -C "$PARENT/projects/beta" config user.email test@example.com
git -C "$PARENT/projects/beta" config user.name Test
printf 'beta\n' > "$PARENT/projects/beta/README.md"
git -C "$PARENT/projects/beta" add README.md
git -C "$PARENT/projects/beta" commit -qm init
git -C "$PARENT/projects/beta" remote add origin "file://$TMP_ROOT/beta.git"
git -C "$PARENT/projects/beta" push -q -u origin main
git --git-dir="$TMP_ROOT/beta.git" symbolic-ref HEAD refs/heads/main
printf '%s\n' '- beta [direct-PR] - beta project (added 2026-09-17)' >> "$PARENT/data/projects.md"
MISMATCH_HOME="$TMP_ROOT/remote-mismatch-home"
FM_SECONDMATE_CHARTER='Own beta-origin work under the alpha route.' \
  FM_SECONDMATE_SCOPE='alpha-named remote clone from beta origin' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios-mismatch remote-mac "$REMOTE_ROOT" "$MISMATCH_HOME" \
    "alpha=file://$TMP_ROOT/beta.git" >/dev/null \
  || fail "explicit-origin remote route provisioning failed"
MISMATCH_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$MISMATCH_HOME/projects/alpha") \
  || fail "mismatched-name remote clone identity could not be normalized"
BETA_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$PARENT/projects/beta") \
  || fail "beta project identity could not be normalized"
[ "$MISMATCH_IDENTITY" = "$BETA_IDENTITY" ] \
  || fail "the alpha-named remote clone did not retain beta's repository identity"
assert_grep "repo-identities: alpha=sha256:$BETA_IDENTITY" "$PARENT/data/secondmates.md" \
  "an explicit-origin remote route did not record the actual canonical origin identity"

git init -q --bare "$TMP_ROOT/gamma.git"
git -C "$PARENT/projects" init -q -b main gamma
git -C "$PARENT/projects/gamma" config user.email test@example.com
git -C "$PARENT/projects/gamma" config user.name Test
printf 'gamma\n' > "$PARENT/projects/gamma/README.md"
git -C "$PARENT/projects/gamma" add README.md
git -C "$PARENT/projects/gamma" commit -qm init
git -C "$PARENT/projects/gamma" remote add origin "file://$TMP_ROOT/gamma.git"
git -C "$PARENT/projects/gamma" push -q -u origin main
git --git-dir="$TMP_ROOT/gamma.git" symbolic-ref HEAD refs/heads/main
printf '%s\n' '- gamma [direct-PR] - gamma project (added 2026-09-17)' >> "$PARENT/data/projects.md"
GAMMA_IDENTITY=$(fm_repo_scope_canonical_origin_identity "$PARENT/projects/gamma") \
  || fail "gamma project identity could not be normalized"
FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='Own the gamma repository.' \
  FM_SECONDMATE_SCOPE='all gamma repository work' \
  "$ROOT/bin/fm-home-seed.sh" gamma-pfm "$TMP_ROOT/gamma-pfm" --project-firstmate gamma >/dev/null \
  || fail "non-overlapping gamma project Firstmate seeding failed"
FM_SECONDMATE_CHARTER='Own beta-origin work under the alpha route.' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios-mismatch remote-mac "$REMOTE_ROOT" "$MISMATCH_HOME" \
    "alpha=file://$TMP_ROOT/beta.git" >/dev/null \
  || fail "remote route refresh with a non-overlapping project authority failed"
. "$ROOT/bin/fm-secondmate-parent-lib.sh"
fm_secondmate_parent_record_parse "$MISMATCH_HOME/.fm-secondmate-parent" \
  || fail "refreshed remote route parent attestation could not be parsed"
printf '%s' "$FM_SECONDMATE_PARENT_REPO_AUTHORITY_IDENTITIES" | grep -Fqx "sha256:$GAMMA_IDENTITY" \
  || fail "refreshed remote runtime attestation omitted the current gamma authority identity"
fm_repo_scope_root_route_guard "$MISMATCH_HOME" "$MISMATCH_HOME/projects/alpha" \
  || fail "refreshed non-overlapping remote route was not permitted: $FM_REPO_SCOPE_LAST_ERROR"

beta_seed_out=
if beta_seed_out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='Own the beta repository.' \
  FM_SECONDMATE_SCOPE='all beta repository work' \
  "$ROOT/bin/fm-home-seed.sh" beta-pfm "$TMP_ROOT/beta-pfm" --project-firstmate beta 2>&1); then
  fail "root admitted a project Firstmate for an explicit remote origin hidden behind a different project name"
fi
assert_contains "$beta_seed_out" 'already in remote ordinary route' \
  "mismatched-name repository overlap refusal did not name the remote authority"

# Recreate the impossible overlap as a manual registry edit to prove startup
# audits the durable seeded identity rather than alpha's different root clone.
grep -F -- '- ios-mismatch ' "$PARENT/data/secondmates.md" > "$TMP_ROOT/mismatch-route.line" \
  || fail "mismatched remote route record was not available for the bootstrap counterexample"
grep -vE '^- ios-mismatch( |$)' "$PARENT/data/secondmates.md" > "$TMP_ROOT/secondmates.without-mismatch"
mv "$TMP_ROOT/secondmates.without-mismatch" "$PARENT/data/secondmates.md"
FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='Own the beta repository.' \
  FM_SECONDMATE_SCOPE='all beta repository work' \
  "$ROOT/bin/fm-home-seed.sh" beta-pfm "$TMP_ROOT/beta-pfm" --project-firstmate beta >/dev/null \
  || fail "manual-overlap bootstrap fixture could not seed the conflicting beta authority"
cat "$TMP_ROOT/mismatch-route.line" >> "$PARENT/data/secondmates.md"
if fm_repo_scope_audit_remote_overlaps "$PARENT/data/secondmates.md"; then
  fail "bootstrap overlap audit missed explicit beta origin behind remote project name alpha"
fi
assert_contains "$FM_REPO_SCOPE_LAST_ERROR" 'overlaps project Firstmate repository alpha' \
  "bootstrap overlap report did not identify the mismatched-name remote repo"
mkdir -p "$TMP_ROOT/bootstrap-home"
BOOTSTRAP_OUT=$(HOME="$TMP_ROOT/bootstrap-home" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_LOCKED=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
  || fail "bootstrap failed while surfacing the manually introduced mismatch: $BOOTSTRAP_OUT"
assert_contains "$BOOTSTRAP_OUT" 'remote repository ownership needs review: remote ordinary route' \
  "startup did not surface the explicit-origin remote ownership collision"
pass "remote ordinary route identities, refreshed attestations, and bootstrap audits use seeded origins"
pass "remote ordinary route identities, not same-named root clones, govern project authority"

remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null \
  || fail "real remote secondmate launch failed"

DELIVERED_LINE=$(grep -F 'FM_PUBLIC_FOLLOWUP_PRIMARY_HOME' "$HERDR_LOG" | tail -1 || true)
DELIVERED=$(printf '%s\n' "$DELIVERED_LINE" | tr ' ' '\n' \
  | sed -n "s/^FM_PUBLIC_FOLLOWUP_PRIMARY_HOME='\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" | tail -1)
[ -n "$DELIVERED" ] || fail "the remote launch did not deliver a primary-home binding to assert against"
case "$DELIVERED" in
  "$REMOTE_ROOT") : ;;
  *) fail "test setup drifted: expected the remote code root to be delivered as the (wrong) parent binding, got: $DELIVERED" ;;
esac

# --- a finished child worker inside the remote secondmate home --------------
CHILD_WT="$REMOTE_HOME/projects/alpha"
mkdir -p "$REMOTE_HOME/state"
# This regression exercises remote-parent binding, not backlog mutation. Keep
# its synthetic child home on the supported hand-edited backend so teardown's
# fused automatic close is correctly exempt without requiring a tasks-axi mock.
printf '%s\n' manual > "$REMOTE_HOME/config/backlog-backend"
write_child_meta() {
  fm_write_meta "$REMOTE_HOME/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$CHILD_WT" "project=$CHILD_WT" "harness=codex" "kind=ship" \
    "mode=local-only" "yolo=off"
}
mkdir -p "$TMP_ROOT/childfake"
for t in tmux treehouse gh gh-axi tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/childfake/$t"
  chmod +x "$TMP_ROOT/childfake/$t"
done

run_child_teardown() { # <extra env assignments...>
  local out rc=0
  write_child_meta
  out=$(env "$@" PATH="$TMP_ROOT/childfake:$PATH" \
    FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_HOME/state" \
    FM_DATA_OVERRIDE="$REMOTE_HOME/data" FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" \
    "$REMOTE_ROOT/bin/fm-teardown.sh" work-child 2>&1) || rc=$?
  CHILD_TEARDOWN_OUT=$out
  CHILD_TEARDOWN_RC=$rc
}

# Case B-equivalent: the delivered (wrong) binding points at the remote code
# root, and that root itself carries an X-mode .env - a plausible real-world
# state (a captain who also runs Firstmate directly on the build Mac). Before
# the fix this refused; the durable record now makes it out of scope.
printf 'FMX_PAIRING_TOKEN=remote-host-token\n' > "$REMOTE_ROOT/.env"
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED"
rm -f "$REMOTE_ROOT/.env"
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only the remote code root looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a cross-machine parent must never be reported as an unresolved binding"
pass "a remote secondmate's finished worker cleans up when the remote code root's own .env looked relay-active"

# Case C-equivalent: FMX_PAIRING_TOKEN exported directly in the process
# environment, simulating the remote host's own login-shell export reaching the
# agent's pane. fm_pf_relay_active's environment-wins rule would make this look
# identical to a genuine same-home commitment; the fix must tell them apart by
# reading only $FM_HOME/.env, never the process environment, once the durable
# record says the parent is remote.
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED" FMX_PAIRING_TOKEN=ambient-login-token
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only an ambient exported token looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "an ambient exported token from the remote host's own shell must never bind this child"
pass "a remote secondmate's finished worker cleans up when only an ambient exported token looked relay-active"

# Baseline: no signal anywhere. Must keep succeeding exactly as before the fix.
run_child_teardown
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child with no relay signal anywhere must allow cleanup (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
pass "a remote secondmate's finished worker cleans up with no relay signal anywhere"

# Protection-preserved case: THIS home's own .env file (not the process
# environment, not the remote code root) carries a real token. That is a
# genuine same-filesystem signal this child's own home could hold, so it must
# still refuse even though the parent route is remote.
printf 'FMX_PAIRING_TOKEN=child-own-token\n' > "$REMOTE_HOME/.env"
run_child_teardown
rm -f "$REMOTE_HOME/.env"
[ "$CHILD_TEARDOWN_RC" -ne 0 ] \
  || fail "a remote secondmate's own committed .env token must still refuse cleanup, got rc=0: $CHILD_TEARDOWN_OUT"
assert_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a genuine same-filesystem token on this home must remain an actionable refusal"
assert_present "$REMOTE_HOME/state/work-child.meta" \
  "a genuine refusal must preserve the child work metadata"
pass "a remote secondmate's own committed relay token still refuses cleanup"

FOREIGN_META="$TMP_ROOT/foreign-ios.meta"
LOCAL_META="$PARENT/state/ios.meta"
printf 'foreign sentinel\n' > "$FOREIGN_META"
rm -f "$LOCAL_META"
PUBLICATION_RC=0
PUBLICATION_OUT=$(FM_TEST_PUBLICATION_TARGET="$LOCAL_META" \
  FM_TEST_PUBLICATION_FOREIGN="$FOREIGN_META" \
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) || PUBLICATION_RC=$?
[ "$PUBLICATION_RC" -ne 0 ] \
  || fail "remote secondmate publication accepted a target resolving outside its home"
assert_contains "$PUBLICATION_OUT" "task record could not be published" \
  "remote secondmate publication did not report its record-boundary refusal"
cmp -s "$FOREIGN_META" <(printf 'foreign sentinel\n') \
  || fail "remote secondmate publication wrote through the foreign target"
[ -L "$LOCAL_META" ] \
  || fail "remote secondmate publication replaced the refused target boundary"
pass "remote secondmate publication refuses targets outside its home"

echo "ALL TESTS PASSED"
