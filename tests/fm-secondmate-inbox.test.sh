#!/usr/bin/env bash
# Portable contract tests for secondmate steering-inbox backlog measurement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-inbox-lib.sh
. "$ROOT/bin/fm-secondmate-inbox-lib.sh"

case_dir=$(fm_test_tmproot fm-secondmate-inbox)
missing="$case_dir/missing.inbox"
summary=$(fm_secondmate_inbox_health "$missing") \
  || fail "an absent never-used inbox was treated as unsafe"
[ "$summary" = $'count=0\toldest_age=0\tnewest_ids=-' ] \
  || fail "an absent inbox did not report zero: $summary"
pass "an absent inbox has no unhandled steering"

inbox="$case_dir/mate.inbox"
mkdir -p "$inbox/handled"
for n in $(seq 1 21); do
  id=$(printf '%03d' "$n")
  printf 'instruction %s\n' "$id" > "$inbox/$id.msg"
done
printf 'handled\n' > "$inbox/handled/999.msg"
summary=$(fm_secondmate_inbox_health "$inbox") \
  || fail "a regular inbox could not be measured"
count=${summary%%$'\t'*}
newest=${summary##*$'\t'}
[ "$count" = count=21 ] || fail "the health summary did not count 21 root records: $summary"
[ "$newest" = newest_ids=019,020,021 ] \
  || fail "the health summary did not sample the newest three ids: $summary"
pass "measurement ignores handled records and samples newest ids"

! fm_secondmate_inbox_breached 20 7200 20 7200 \
  || fail "the exact count and age limits triggered an alarm"
fm_secondmate_inbox_breached 21 0 20 7200 \
  || fail "more than 20 records did not trigger an alarm"
fm_secondmate_inbox_breached 1 7201 20 7200 \
  || fail "an oldest record beyond two hours did not trigger an alarm"
pass "backlog thresholds are strictly more than 20 records or two hours"

old="$case_dir/old.inbox"
mkdir -p "$old"
printf 'old instruction\n' > "$old/001.msg"
if [ "$(uname)" = Darwin ]; then
  touch -t 202001010000 "$old/001.msg"
else
  touch -t 202001010000.00 "$old/001.msg"
fi
summary=$(fm_secondmate_inbox_health "$old") \
  || fail "the old inbox could not be measured"
age_field=${summary#*$'\t'}
age_field=${age_field%%$'\t'*}
age=${age_field#oldest_age=}
fm_secondmate_inbox_breached 1 "$age" 20 7200 \
  || fail "the measured oldest age did not trigger the alarm"
pass "oldest age comes from the host-local message mtime"

remote="$case_dir/remote-home"
mkdir -p "$remote/bin" "$remote/state/parent-route/mate.inbox"
printf 'mate\n' > "$remote/.fm-secondmate-home"
printf '# remote fixture\n' > "$remote/AGENTS.md"
printf 'remote instruction\n' > "$remote/state/parent-route/mate.inbox/007.msg"
summary=$(FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" inbox-health mate) \
  || fail "the remote control plane could not measure its parent-route inbox"
case "$summary" in
  $'count=1\toldest_age='*$'\tnewest_ids=007') ;;
  *) fail "the remote control plane measured the wrong inbox: $summary" ;;
esac
pass "remote measurement uses state/parent-route/<id>.inbox"

parent="$case_dir/parent-home"
mkdir -p "$parent/state/mate.inbox" "$parent/config"
printf 'kind=secondmate\nhome=%s\n' "$case_dir/not-the-parent-home" > "$parent/state/mate.meta"
for n in $(seq 1 21); do
  id=$(printf '%03d' "$n")
  printf 'local instruction %s\n' "$id" > "$parent/state/mate.inbox/$id.msg"
done
(
  FM_HOME="$parent"
  FM_STATE_OVERRIDE="$parent/state"
  FM_CONFIG_OVERRIDE="$parent/config"
  export FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  fm_wake_append() { printf '%s\n' "$3" > "$parent/alarm"; }
  wake() { :; }
  secondmate_health_inbox_alarm mate "$parent/state/mate.meta"
) || fail "the watcher could not measure the local parent-owned inbox"
grep -F 'mate=mate count=21' "$parent/alarm" >/dev/null \
  || fail "the watcher did not alarm on the local state/<id>.inbox"
pass "local measurement uses the parent state/<id>.inbox"

ln -s "$inbox" "$case_dir/symlink.inbox"
! fm_secondmate_inbox_health "$case_dir/symlink.inbox" >/dev/null \
  || fail "a symlinked inbox was accepted"
printf 'not a directory\n' > "$case_dir/file.inbox"
! fm_secondmate_inbox_health "$case_dir/file.inbox" >/dev/null \
  || fail "a non-directory inbox was accepted"
pass "unsafe inbox paths are refused without touching records"
