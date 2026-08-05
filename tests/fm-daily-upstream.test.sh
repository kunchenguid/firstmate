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
  local root="$TMP_ROOT/update-world/home" world="$TMP_ROOT/update-world" feed receipt out id offers before_lines
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
  offers="$root/state/daily-upstream/report-offers.index"
  private_mode=$(path_mode_test "$offers")
  [ "$private_mode" = 600 ] || fail "report offers mode is not 600"
  id=$(cut -f1 "$offers")
  assert_contains "$(FM_HOME="$root" "$root/state/daily-upstream-report.check.sh")" "daily-upstream-report $id" "authenticated check did not offer report"
  before_lines=$(wc -l < "$offers" | tr -d ' ')
  PATH="$FAKEBIN:$PATH" FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_DAILY_TEST_DATE=2026-08-05 FM_DAILY_TEST_EPOCH=400000 FM_DAILY_NOTIFICATION_EXEC=/usr/bin/false FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" report >/dev/null
  [ "$(wc -l < "$offers" | tr -d ' ')" = "$before_lines" ] || fail "idempotent report duplicated its offer"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" show-report "$id" | grep -F "Firstmate morning upstream report" >/dev/null || fail "pending report could not be read"
  FM_DAILY_TEST_MODE=1 FM_DAILY_TEST_TIMEZONE=America/Sao_Paulo FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$DAILY" acknowledge "$id" >/dev/null
  assert_absent "$root/state/daily-upstream-report.check.sh" "acknowledged final offer left executable check"
  pass "channel identities dedupe and report survives an absent notifier/session until exact acknowledgement"
}

path_mode_test() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
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
test_duplicate_run_lock
test_launchagent_install_verify_refusal_and_rollback

echo "# all fm-daily-upstream tests passed"
