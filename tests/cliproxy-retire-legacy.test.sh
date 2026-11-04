#!/usr/bin/env bash
# tests/cliproxy-retire-legacy.test.sh - retiring the ccflare access-sync unit
# and the dead credential copies must be reversible, idempotent, and must never
# delete a credential. The plan must change nothing at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETIRE="$ROOT/bin/cliproxy-retire-legacy.sh"
TMP_ROOT=$(fm_test_tmproot cliproxy-retire)
TODAY=$(date -u +%Y-%m-%d)

home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/auth/disabled" "$dir/archive" "$dir/fakebin" "$dir/log"
  cat > "$dir/fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/log/systemctl"
case "\$*" in
  *no-such.timer*) exit 0 ;;
  *"is-enabled"*) if [ -f "$dir/disabled.marker" ]; then printf 'disabled\n'; else printf 'enabled\n'; fi ;;
  *"is-active"*) if [ -f "$dir/active.marker" ]; then printf 'active\n'; else printf 'inactive\n'; fi ;;
  *"disable --now"*) touch "$dir/disabled.marker"; rm -f "$dir/active.marker" ;;
  *"stop"*) rm -f "$dir/active.marker" ;;
  *) exit 1 ;;
esac
SH
  chmod 0755 "$dir/fakebin/systemctl"
  touch "$dir/active.marker"
  printf '%s\n' '{"email":"retired@x.com","refresh_token":"dead"}' > "$dir/auth/disabled/claude-retired.json"
  printf '%s\n' '{"email":"old@x.com","refresh_token":"dead"}' > "$dir/auth/claude-old.json.bak"
  printf '%s\n' '{"email":"live@x.com","refresh_token":"live","expired":"2026-11-04T20:00:00Z"}' > "$dir/auth/claude-live.json"
  printf '%s\n' "$dir"
}

run_retire() {  # <dir> [args...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" \
    FM_CLIPROXY_AUTH_DIR="$dir/auth" \
    FM_CLIPROXY_ARCHIVE_ROOT="$dir/archive" \
    "$RETIRE" "$@"
}

# --- plan changes nothing ---------------------------------------------------

DIR=$(home plan)
out=$(run_retire "$DIR" plan) || fail "plan must succeed: $out"
assert_contains "$out" "would run: systemctl --user disable --now fm-ccflare-access-sync.timer" \
  "the plan names the disable command"
assert_contains "$out" "would move to $DIR/archive/$TODAY/" "the plan names the archive destination"
assert_contains "$out" "plan only: nothing was changed" "the plan says it changed nothing"
assert_no_grep "disable --now" "$DIR/log/systemctl" "the plan issues no disable"
assert_absent "$DIR/disabled.marker" "the plan leaves the unit enabled"
assert_present "$DIR/auth/disabled/claude-retired.json" "the plan moves no retired copy"
assert_present "$DIR/auth/claude-old.json.bak" "the plan moves no backup copy"
assert_absent "$DIR/archive/$TODAY" "the plan creates no archive directory"
pass "plan reports without changing anything"

# --- apply disables the unit and archives, never deletes -------------------

DIR=$(home apply)
out=$(run_retire "$DIR" apply) || fail "apply must succeed: $out"
assert_contains "$out" "disabled and stopped fm-ccflare-access-sync.timer" "apply disables the unit"
assert_contains "$out" "verified: disabled" "apply proves the unit now reads disabled"
assert_grep "disable --now fm-ccflare-access-sync.timer" "$DIR/log/systemctl" \
  "the real systemd disable command is the one issued"
assert_absent "$DIR/auth/disabled/claude-retired.json" "the retired copy leaves the disabled directory"
assert_absent "$DIR/auth/claude-old.json.bak" "the stray backup leaves the auth directory"
assert_present "$DIR/archive/$TODAY/claude-retired.json" "the retired copy is archived, not deleted"
assert_present "$DIR/archive/$TODAY/claude-old.json.bak" "the backup is archived, not deleted"
assert_contains "$(cat "$DIR/archive/$TODAY/claude-retired.json")" '"refresh_token":"dead"' \
  "the archived copy keeps its bytes"
assert_present "$DIR/auth/claude-live.json" "a live credential is never touched"
pass "apply disables the unit and archives the retired copies"

# --- apply is idempotent ----------------------------------------------------

out=$(run_retire "$DIR" apply) || fail "a second apply must succeed: $out"
assert_contains "$out" "already disabled" "a second apply finds the unit disabled"
assert_contains "$out" "none present in $DIR/auth" "a second apply finds nothing left to archive"
assert_present "$DIR/archive/$TODAY/claude-retired.json" "the archived copy stays put"
pass "apply is idempotent"

# --- an uninstalled unit is not a condition --------------------------------

DIR=$(home absent)
out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" FM_CLIPROXY_AUTH_DIR="$DIR/auth" \
  FM_CLIPROXY_ARCHIVE_ROOT="$DIR/archive" FM_CLIPROXY_CCFLARE_TIMER=no-such.timer \
  "$RETIRE" plan) || fail "plan on a host without the unit must succeed: $out"
assert_contains "$out" "not installed on this host" "an uninstalled unit is named, not treated as enabled"
pass "an uninstalled unit is not a condition"

printf 'all cliproxy-retire-legacy tests passed\n'
