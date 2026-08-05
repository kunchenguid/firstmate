#!/usr/bin/env bash
# Deterministic behavior tests for the guarded daily upstream owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAILY="$ROOT/bin/fm-daily-upstream.sh"
TMP_ROOT=$(fm_test_tmproot fm-daily-upstream-tests)
FAKEBIN="$TMP_ROOT/fakebin"
GH_DATA="$TMP_ROOT/gh-data"
mkdir -p "$FAKEBIN" "$GH_DATA"
fm_git_identity fmtest fmtest@example.invalid

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
path=${3:-}
case "$path" in
  /repos/*/commits/*/pulls)
    sha=${path#*/commits/}; sha=${sha%/pulls}
    printf '1\t%s\n' "$sha"
    ;;
  /repos/*/commits/*/check-runs)
    sha=${path#*/commits/}; sha=${sha%/check-runs}
    mode=$(cat "${FAKE_GH_DATA:?}/check-$sha" 2>/dev/null || echo green)
    case "$mode" in green) printf '1\t0\n' ;; red) printf '1\t1\n' ;; missing) printf '0\t0\n' ;; *) exit 1 ;; esac
    ;;
  /repos/*/commits/*/status)
    sha=${path#*/commits/}; sha=${sha%/status}
    mode=$(cat "${FAKE_GH_DATA:?}/check-$sha" 2>/dev/null || echo green)
    case "$mode" in green) printf '1\tsuccess\n' ;; red) printf '1\tfailure\n' ;; missing) printf '0\tsuccess\n' ;; *) exit 1 ;; esac
    ;;
  /repos/*/*)
    printf 'main\n'
    ;;
  *) exit 1 ;;
esac
printf '%s\n' 'AUTH_TOKEN_CANARY account@example.invalid host.private.invalid' >&2
SH

cat > "$FAKEBIN/brew" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"formulae":[],"casks":[]}'
SH

cat > "$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{}'
SH

cat > "$FAKEBIN/osascript" <<'SH'
#!/usr/bin/env bash
exit 127
SH

cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked >> "${FAKE_LAUNCHCTL_LOG:?}"
exit 99
SH
chmod +x "$FAKEBIN"/*

# new_repo <world> <name> <owner/repo>: creates a bare remote, seed, and clone.
# The clone keeps a canonical GitHub URL while a test-only insteadOf rule routes
# fetches to the local bare repository.
new_repo() {
  local world=$1 name=$2 identity=$3 remote seed clone
  remote="$world/remotes/$name.git"
  seed="$world/seeds/$name"
  clone="$world/clones/$name"
  mkdir -p "$world/remotes" "$world/seeds" "$world/clones"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git clone -q "$remote" "$seed" 2>/dev/null
  printf 'v1\n' > "$seed/README.md"
  printf 'data/\nstate/\nprojects/\n' > "$seed/.gitignore"
  git -C "$seed" add -A
  git -C "$seed" commit -qm initial
  git -C "$seed" push -q origin main
  git clone -q "$remote" "$clone"
  git -C "$clone" remote set-url origin "https://github.com/$identity.git"
  git -C "$clone" config url."file://$remote".insteadOf "https://github.com/$identity.git"
  printf '%s\n' "$clone"
}

advance_repo() {
  local seed=$1 label=$2
  printf '%s\n' "$label" >> "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm "$label (#1)"
  git -C "$seed" push -q origin main
  git -C "$seed" rev-parse HEAD
}

write_feed() {
  local file=$1 first=$2 second=${3:-}
  {
    printf '<feed>\n'
    printf '<entry><yt:videoId>%s</yt:videoId><title>Public update metadata</title><published>2026-08-02T00:00:00+00:00</published></entry>\n' "$first"
    if [ -n "$second" ]; then
      printf '<entry><yt:videoId>%s</yt:videoId><title>Earlier public metadata</title><published>2026-08-01T00:00:00+00:00</published></entry>\n' "$second"
    fi
    printf '</feed>\n'
  } > "$file"
}

run_daily() {
  local home=$1 root=$2 date=$3 epoch=$4 feed=$5
  shift 5
  PATH="$FAKEBIN:$PATH" FAKE_GH_DATA="$GH_DATA" \
  FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_ALLOW_URL_REWRITE=1 \
  FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_DATE="$date" \
  FM_DAILY_TEST_EPOCH="$epoch" FM_DAILY_TEST_CHANNEL_FEED="$feed" \
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$DAILY" "$@"
}

project_action() {
  local receipt=$1 wanted=$2
  awk -F '=' -v wanted="$wanted" '
    /^\[project\]$/ { in_project=1; matched=0; next }
    /^\[/ { in_project=0; matched=0 }
    in_project && $1=="name" { matched=(substr($0,index($0,"=")+1)==wanted) }
    in_project && matched && $1=="action" { print substr($0,index($0,"=")+1); exit }
  ' "$receipt"
}

head_sha() { git -C "$1" rev-parse HEAD; }
remote_sha() { git -C "$1" rev-parse refs/remotes/origin/main 2>/dev/null || git -C "$1" ls-remote origin refs/heads/main | awk '{print $1}'; }

build_update_world() {
  local world=$1 root name clone candidate
  mkdir -p "$world"
  root=$(new_repo "$world" firstmate kunchenguid/firstmate)
  mv "$root" "$world/home"
  root="$world/home"
  # The URL rewrite contains the old clone-independent bare path and survives mv.
  advance_repo "$world/seeds/firstmate" firstmate-update >/dev/null
  mkdir -p "$root/projects"
  : > "$root/data-projects.tmp"

  for name in green production local dirty offdefault diverged red missing ambiguous; do
    clone=$(new_repo "$world" "$name" "example/$name")
    mv "$clone" "$root/projects/$name"
    candidate=$(advance_repo "$world/seeds/$name" "$name-update")
    case "$name" in
      dirty) printf 'dirty\n' >> "$root/projects/$name/README.md" ;;
      offdefault) git -C "$root/projects/$name" checkout -qb feature ;;
      diverged)
        printf 'local\n' > "$root/projects/$name/local.txt"
        git -C "$root/projects/$name" add local.txt
        git -C "$root/projects/$name" commit -qm local
        ;;
      red) printf 'red\n' > "$GH_DATA/check-$candidate" ;;
      missing) printf 'missing\n' > "$GH_DATA/check-$candidate" ;;
      ambiguous) git -C "$root/projects/$name" remote set-url origin 'https://person:REMOTE_CANARY@github.com/example/ambiguous.git' ;;
    esac
  done
  mkdir -p "$root/projects/unregistered-copy"
  cat > "$root/data-projects.tmp" <<'EOF'
- green [no-mistakes +daily-sync] - safe fixture (added 2026-08-02)
- production [no-mistakes +daily-sync +production] - production fixture (added 2026-08-02)
- local [local-only +daily-sync] - local fixture (added 2026-08-02)
- dirty [no-mistakes +daily-sync] - dirty fixture (added 2026-08-02)
- offdefault [no-mistakes +daily-sync] - branch fixture (added 2026-08-02)
- diverged [no-mistakes +daily-sync] - divergence fixture (added 2026-08-02)
- red [no-mistakes +daily-sync] - red fixture (added 2026-08-02)
- missing [no-mistakes +daily-sync] - missing fixture (added 2026-08-02)
- ambiguous [no-mistakes +daily-sync] - ambiguous fixture (added 2026-08-02)
EOF
  mkdir -p "$root/data" "$root/state"
  mv "$root/data-projects.tmp" "$root/data/projects.md"
  chmod 700 "$root/data" "$root/state"
  printf '%s\n' "$root"
}

test_collection_matrix_and_redaction() {
  local world root feed out receipt before_production before_local before_dirty before_off before_diverged before_red before_missing
  world="$TMP_ROOT/update-world"
  root=$(build_update_world "$world")
  feed="$world/feed.xml"
  write_feed "$feed" videoOLD123
  before_production=$(head_sha "$root/projects/production")
  before_local=$(head_sha "$root/projects/local")
  before_dirty=$(head_sha "$root/projects/dirty")
  before_off=$(head_sha "$root/projects/offdefault")
  before_diverged=$(head_sha "$root/projects/diverged")
  before_red=$(head_sha "$root/projects/red")
  before_missing=$(head_sha "$root/projects/missing")

  out=$(run_daily "$root" "$root" 2026-08-02 100000 "$feed" collect 2>&1)
  assert_contains "$out" "collection=published" "collection did not publish"
  receipt="$root/data/daily-upstream/receipts/2026-08-02.receipt"
  assert_present "$receipt" "typed collection receipt missing"
  assert_grep "FIRSTMATE_DAILY_UPSTREAM_RECEIPT_V1" "$receipt" "receipt type missing"
  [ "$(head_sha "$root")" = "$(git -C "$world/seeds/firstmate" rev-parse HEAD)" ] || fail "official Firstmate candidate was not applied"
  [ "$(head_sha "$root/projects/green")" = "$(git -C "$world/seeds/green" rev-parse HEAD)" ] || fail "green opted-in project was not applied"
  [ "$(head_sha "$root/projects/production")" = "$before_production" ] || fail "production-bearing project moved"
  [ "$(head_sha "$root/projects/local")" = "$before_local" ] || fail "local-only project moved"
  [ "$(head_sha "$root/projects/dirty")" = "$before_dirty" ] || fail "dirty project moved"
  [ "$(head_sha "$root/projects/offdefault")" = "$before_off" ] || fail "off-default project moved"
  [ "$(head_sha "$root/projects/diverged")" = "$before_diverged" ] || fail "diverged project moved"
  [ "$(head_sha "$root/projects/red")" = "$before_red" ] || fail "red-check project moved"
  [ "$(head_sha "$root/projects/missing")" = "$before_missing" ] || fail "missing-check project moved"
  [ "$(project_action "$receipt" green)" = applied ] || fail "green project receipt action is not applied"
  [ "$(project_action "$receipt" production)" = report-only:production-bearing ] || fail "production posture was not report-only"
  [ "$(project_action "$receipt" local)" = report-only:local-only ] || fail "local-only posture was not report-only"
  assert_contains "$(project_action "$receipt" dirty)" "dirty" "dirty state not reported"
  assert_contains "$(project_action "$receipt" offdefault)" "off-default" "off-default state not reported"
  assert_contains "$(project_action "$receipt" diverged)" "diverged" "divergence not reported"
  assert_contains "$(project_action "$receipt" red)" "checks-red" "red checks not reported"
  assert_contains "$(project_action "$receipt" missing)" "checks-missing" "missing checks not reported"
  [ "$(project_action "$receipt" ambiguous)" = report-only:origin-ambiguous ] || fail "ambiguous origin was not report-only"
  assert_grep "unregistered-copy-count=1" "$receipt" "unregistered immediate copy was not counted"
  for canary in AUTH_TOKEN_CANARY account@example.invalid host.private.invalid REMOTE_CANARY; do
    assert_not_contains "$out" "$canary" "scheduled output leaked $canary"
    assert_no_grep "$canary" "$receipt" "receipt leaked $canary"
  done
  pass "green update matrix applies only pinned eligible copies and redacts canaries"
}

test_channel_dedupe_and_report_preservation() {
  local root="$TMP_ROOT/update-world/home" world="$TMP_ROOT/update-world" feed receipt out id offers before_lines bound_home
  feed="$world/feed.xml"
  # A second local date with the same newest identity is current, not resurfaced.
  run_daily "$root" "$root" 2026-08-03 200000 "$feed" collect >/dev/null
  receipt="$root/data/daily-upstream/receipts/2026-08-03.receipt"
  assert_grep "status=current" "$receipt" "same upload was not deduplicated"
  assert_grep "new-upload-count=0" "$receipt" "same upload resurfaced"
  # A new identity ahead of the prior identity is surfaced exactly once.
  write_feed "$feed" videoNEW456 videoOLD123
  run_daily "$root" "$root" 2026-08-04 300000 "$feed" collect >/dev/null
  receipt="$root/data/daily-upstream/receipts/2026-08-04.receipt"
  assert_grep "status=new" "$receipt" "new upload was not detected"
  assert_grep "new-upload-count=1" "$receipt" "new upload count is wrong"
  assert_grep "channel-entry=videoNEW456" "$receipt" "new upload metadata missing"
  run_daily "$root" "$root" 2026-08-05 400000 "$feed" collect >/dev/null
  assert_grep "new-upload-count=0" "$root/data/daily-upstream/receipts/2026-08-05.receipt" "new upload surfaced twice"

  out=$(PATH="$FAKEBIN:$PATH" FAKE_GH_DATA="$GH_DATA" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_DATE=2026-08-05 FM_DAILY_TEST_EPOCH=400000 FM_DAILY_NOTIFICATION_EXEC=/usr/bin/false FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" report 2>&1)
  assert_contains "$out" "local-notification=unavailable; report-preserved=yes" "notification absence did not preserve report"
  assert_grep "Evidence source: the 2026-08-05 collection receipt." "$root/data/daily-upstream/latest-report.md" "report did not attribute its own collection receipt"
  offers="$root/state/daily-upstream/report-offers.index"
  private_mode=$(path_mode_test "$offers")
  [ "$private_mode" = 600 ] || fail "report offers mode is not 600"
  id=$(cut -f1 "$offers")
  # The watcher execs the check as an external command and exports nothing, so
  # the generated check must bind its own home rather than inherit one.
  bound_home=$(cd "$root" && pwd -P)
  assert_grep "export FM_HOME=$(printf '%q' "$bound_home")" "$root/state/daily-upstream-report.check.sh" "generated check did not bind its owning absolute home"
  assert_contains "$(env -u FM_HOME -u FM_ROOT_OVERRIDE "$root/state/daily-upstream-report.check.sh")" "daily-upstream-report $id" "authenticated check did not offer report without an inherited environment"
  [ -z "$(FM_HOME="$root" "$root/state/daily-upstream-report.check.sh")" ] || fail "pending report re-offered on the immediately following sweep"
  [ "$(path_mode_test "$root/state/daily-upstream/report-offer.notified")" = 600 ] || fail "re-offer stamp mode is not 600"
  assert_contains "$(FM_HOME="$root" FM_DAILY_REPORT_REOFFER_SECS=0 "$root/state/daily-upstream-report.check.sh")" "daily-upstream-report $id" "elapsed re-offer interval did not surface the pending report"
  before_lines=$(wc -l < "$offers" | tr -d ' ')
  PATH="$FAKEBIN:$PATH" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_DATE=2026-08-05 FM_DAILY_TEST_EPOCH=400000 FM_DAILY_NOTIFICATION_EXEC=/usr/bin/false FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" report >/dev/null
  [ "$(wc -l < "$offers" | tr -d ' ')" = "$before_lines" ] || fail "idempotent report duplicated its offer"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" show-report "$id" | grep -F "Firstmate morning upstream report" >/dev/null || fail "pending report could not be read"
  FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" acknowledge "$id" >/dev/null
  assert_absent "$root/state/daily-upstream-report.check.sh" "acknowledged final offer left executable check"
  assert_absent "$root/state/daily-upstream/report-offer.notified" "acknowledged final offer left a re-offer stamp"
  pass "channel identities dedupe and report survives an absent notifier/session until exact acknowledgement"
}

test_channel_history_gap_preserves_state_without_resurfacing() {
  local root="$TMP_ROOT/update-world/home" feed="$TMP_ROOT/update-world/feed.xml" receipt
  # The prior identity falls outside the bounded feed, so nothing is deduplicated
  # and nothing is claimed or rendered as a new upload either.
  write_feed "$feed" videoGAPTWO videoGAPTHREE
  run_daily "$root" "$root" 2026-08-08 650000 "$feed" collect >/dev/null 2>&1
  receipt="$root/data/daily-upstream/receipts/2026-08-08.receipt"
  assert_grep "status=history-gap" "$receipt" "history gap was not detected"
  assert_grep "new-upload-count=0" "$receipt" "history gap claimed new uploads"
  assert_no_grep "channel-entry=" "$receipt" "history gap emitted upload entries it did not count"
  [ "$(cat "$root/data/daily-upstream/channel-last-seen")" = videoNEW456 ] || fail "history gap did not preserve the prior identity"
  write_feed "$feed" videoNEW456 videoOLD123
  pass "a channel history gap preserves state without resurfacing uncounted uploads"
}

test_scheduled_report_defers_instead_of_vanishing() {
  local root="$TMP_ROOT/update-world/home" lock out rc
  lock="$root/state/daily-upstream/run.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' collect > "$lock/action"
  chmod 700 "$lock"; chmod 600 "$lock/pid" "$lock/action"
  set +e
  out=$(PATH="$FAKEBIN:$PATH" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo \
    FM_DAILY_TEST_DATE=2026-08-07 FM_DAILY_TEST_EPOCH=600000 FM_DAILY_SCHEDULED=1 \
    FM_DAILY_REPORT_GRACE_SECS=0 FM_DAILY_REPORT_COLLECTION_WAIT_SECS=0 \
    FM_DAILY_LOCK_WAIT_SECS=0 FM_DAILY_REPORT_MAX_LOCK_WAIT_SECS=1 \
    FM_DAILY_NOTIFICATION_EXEC=/usr/bin/false FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" report 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 75 ] || fail "scheduled report contending with a live collection returned $rc instead of 75"
  assert_contains "$out" "report=deferred; reason=run-lock-busy" "lock contention did not record an explicit deferral"
  rm -f "$lock/pid" "$lock/action"; rmdir "$lock"
  pass "a scheduled report contending with a live collection defers explicitly"
}

test_report_attributes_an_earlier_receipt() {
  local root="$TMP_ROOT/update-world/home" feed="$TMP_ROOT/update-world/feed.xml" out report
  # A report-only assessment publishes the latest receipt, and the next morning
  # report must not present its conclusions as that morning's collection.
  run_daily "$root" "$root" 2026-08-09 700000 "$feed" assess >/dev/null 2>&1
  out=$(PATH="$FAKEBIN:$PATH" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo \
    FM_DAILY_TEST_DATE=2026-08-10 FM_DAILY_TEST_EPOCH=800000 FM_DAILY_NOTIFICATION_EXEC=/usr/bin/false \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" report 2>&1)
  assert_contains "$out" "report=preserved" "fallback report was not preserved"
  report="$root/data/daily-upstream/latest-report.md"
  assert_grep "Report date: 2026-08-10." "$report" "fallback report lost its own date"
  assert_grep "Evidence source: an earlier assess receipt dated 2026-08-09, so no collection is claimed for 2026-08-10." "$report" "fallback report presented an earlier assessment as today's collection"
  pass "a report rendered from an earlier receipt names that receipt's date and mode"
}

path_mode_test() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_bounded_retention_preserves_pending_and_unrelated_evidence() {
  local root="$TMP_ROOT/update-world/home" data offers pending unrelated out
  data="$root/data/daily-upstream"
  offers="$root/state/daily-upstream/report-offers.index"
  pending=$(cut -f2 "$offers" | tail -1)
  [ -n "$pending" ] || fail "retention fixture has no pending report to preserve"
  unrelated="$data/operator-note.txt"
  printf 'operator evidence\n' > "$unrelated"
  chmod 600 "$unrelated"
  assert_present "$data/receipts/2026-08-02.receipt" "retention fixture lost its oldest receipt"

  # Every indexed receipt predates the threshold, but the pending report and
  # unindexed operator evidence must survive.
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_EPOCH=900000 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" cleanup --keep-days 1 2>&1)
  assert_contains "$out" "cleanup=complete" "bounded cleanup did not complete"
  assert_absent "$data/receipts/2026-08-02.receipt" "expired indexed receipt was retained"
  assert_present "$data/$pending" "cleanup removed a pending report"
  assert_present "$unrelated" "cleanup removed unindexed operator evidence"
  assert_present "$data/latest-report.md" "cleanup removed the unindexed latest-report pointer"
  assert_grep "$pending" "$data/retention.index" "cleanup dropped the pending report from the index"
  assert_no_grep "receipts/2026-08-02.receipt" "$data/retention.index" "cleanup kept an index entry for a removed file"
  [ "$(path_mode_test "$data/retention.index")" = 600 ] || fail "rewritten retention index is not 600"

  # A second pass over the same index removes nothing further.
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_EPOCH=900000 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" cleanup --keep-days 1 2>&1)
  assert_contains "$out" "removed=0" "repeated cleanup removed evidence twice"
  rm -f "$unrelated"
  pass "bounded retention removes only expired indexed evidence and never a pending report"
}

test_lock_recovery_refuses_before_it_preserves() {
  local root="$TMP_ROOT/update-world/home" lock preserved dead out rc
  lock="$root/state/daily-upstream/run.lock"
  set +e
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$DAILY" recover-lock --older-than-seconds 3600 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "absent lock recovery"
  assert_contains "$out" "recover-lock=none" "absent lock was not reported as none"

  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' collect > "$lock/action"
  chmod 700 "$lock"; chmod 600 "$lock/pid" "$lock/action"

  set +e
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$DAILY" recover-lock --older-than-seconds 60 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "sub-hour threshold"
  assert_contains "$out" "must be at least 3600 seconds" "sub-hour threshold was not refused"
  assert_present "$lock/pid" "refused sub-hour recovery touched the lock"

  set +e
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$DAILY" recover-lock --older-than-seconds 3600 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery moved aside a lock whose owner is still alive"
  assert_contains "$out" "still alive" "live owner refusal is not explicit"
  assert_present "$lock/pid" "refused live-owner recovery touched the lock"

  # A dead owner is still preserved while the lock is younger than the threshold.
  ( : ) & dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$lock/pid"
  chmod 600 "$lock/pid"
  set +e
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$DAILY" recover-lock --older-than-seconds 3600 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery cleared a young dead lock"
  assert_contains "$out" "not old enough" "young dead lock refusal is not explicit"
  assert_present "$lock/action" "refused young-lock recovery touched the lock"

  # Only an aged dead lock is moved aside, and its evidence is preserved.
  touch -t 202601010000 "$lock"
  out=$(FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$DAILY" recover-lock --older-than-seconds 3600 2>&1)
  assert_contains "$out" "recover-lock=preserved-and-cleared" "aged dead lock was not cleared"
  assert_absent "$lock" "aged dead lock was not moved aside"
  preserved=$(find "$root/state/daily-upstream" -maxdepth 1 -name 'preserved-run-lock-*' | head -1)
  [ -n "$preserved" ] || fail "aged dead lock was deleted instead of preserved"
  assert_grep "$dead" "$preserved/pid" "preserved lock lost its owner evidence"
  rm -rf "$preserved"
  pass "lock recovery refuses live, young, and sub-hour cases and only preserves an aged dead lock"
}

test_duplicate_run_lock() {
  local root="$TMP_ROOT/update-world/home" feed="$TMP_ROOT/update-world/feed.xml" lock out rc
  lock="$root/state/daily-upstream/run.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' collect > "$lock/action"
  chmod 700 "$lock"; chmod 600 "$lock/pid" "$lock/action"
  set +e
  out=$(run_daily "$root" "$root" 2026-08-06 500000 "$feed" collect 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 75 ] || fail "duplicate run lock returned $rc instead of 75"
  assert_contains "$out" "busy: another daily-upstream run owns this home" "duplicate lock refusal missing"
  rm -f "$lock/pid" "$lock/action"; rmdir "$lock"
  pass "duplicate collection is excluded by one home-local lock"
}

test_launchagent_install_verify_refusal_and_rollback() {
  local home="$TMP_ROOT/install/home" agents="$TMP_ROOT/install/agents" log="$TMP_ROOT/install/launchctl.log" out first_hash second_hash collection report unrelated
  mkdir -p "$home" "$agents"
  chmod 700 "$home" "$agents"
  : > "$log"
  unrelated="$agents/unrelated.plist"
  printf 'unrelated\n' > "$unrelated"
  chmod 600 "$unrelated"
  collection="$agents/com.kunchenguid.firstmate.daily-upstream.collection.plist"
  report="$agents/com.kunchenguid.firstmate.daily-upstream.report.plist"
  out=$(PATH="$FAKEBIN:$PATH" FAKE_LAUNCHCTL_LOG="$log" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_LAUNCHAGENTS_OVERRIDE="$agents" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$DAILY" install)
  assert_contains "$out" "install=definitions-ready" "install did not complete"
  first_hash=$(shasum -a 256 "$collection" "$report")
  PATH="$FAKEBIN:$PATH" FAKE_LAUNCHCTL_LOG="$log" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_LAUNCHAGENTS_OVERRIDE="$agents" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$DAILY" install >/dev/null
  second_hash=$(shasum -a 256 "$collection" "$report")
  [ "$first_hash" = "$second_hash" ] || fail "idempotent install changed exact definitions"
  PATH="$FAKEBIN:$PATH" FAKE_LAUNCHCTL_LOG="$log" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_LAUNCHAGENTS_OVERRIDE="$agents" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$DAILY" verify-install | grep -F 'verification=exact' >/dev/null || fail "exact verification failed"
  assert_grep '<integer>4</integer>' "$collection" "04:00 calendar hour missing"
  assert_grep '<integer>8</integer>' "$report" "08:00 calendar hour missing"
  assert_no_grep '<key>RunAtLoad</key>' "$collection" "collection unexpectedly runs at login"
  assert_no_grep '<key>RunAtLoad</key>' "$report" "report unexpectedly runs at login"
  [ ! -s "$log" ] || fail "static deployment invoked launchctl"
  printf '\nmodified\n' >> "$report"
  set +e
  PATH="$FAKEBIN:$PATH" FAKE_LAUNCHCTL_LOG="$log" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_LAUNCHAGENTS_OVERRIDE="$agents" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$DAILY" uninstall >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "uninstall accepted a modified definition"
  assert_present "$collection" "rollback refusal removed the other exact definition"
  assert_present "$report" "rollback refusal removed the modified definition"
  assert_present "$unrelated" "deployment touched unrelated launchd state"

  # Unsafe symlinks are refused without replacing them.
  rm -f "$collection" "$report"
  ln -s "$unrelated" "$collection"
  set +e
  PATH="$FAKEBIN:$PATH" FAKE_LAUNCHCTL_LOG="$log" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_LAUNCHAGENTS_OVERRIDE="$agents" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$DAILY" install >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "install accepted an unsafe existing symlink"
  [ -L "$collection" ] || fail "unsafe existing symlink was replaced"
  assert_absent "$report" "refused install partially created the report definition"
  assert_present "$unrelated" "refused install touched unrelated launchd state"
  pass "LaunchAgent definitions are 04:00/08:00 exact, idempotent, static, and transactional on refusal"
}

test_collection_matrix_and_redaction
test_channel_dedupe_and_report_preservation
test_channel_history_gap_preserves_state_without_resurfacing
test_duplicate_run_lock
test_scheduled_report_defers_instead_of_vanishing
test_report_attributes_an_earlier_receipt
test_bounded_retention_preserves_pending_and_unrelated_evidence
test_lock_recovery_refuses_before_it_preserves
test_launchagent_install_verify_refusal_and_rollback

echo "# all fm-daily-upstream tests passed"
