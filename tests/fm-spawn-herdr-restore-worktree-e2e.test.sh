#!/usr/bin/env bash
# tests/fm-spawn-herdr-restore-worktree-e2e.test.sh - ISOLATED end-to-end
# real-Herdr test that a worker restored by a Herdr session restart comes back
# in its recorded Treehouse slot, and that the slot stays its own meanwhile.
#
# Herdr saves each pane's top-level shell cwd and, on restore, starts the shell
# and resumes the pane's agent there. `treehouse get` enters its slot in a
# nested subshell, so a crewmate whose top-level shell stayed in the project
# came back in the project's primary checkout, and the slot, held only by the
# vanished subshell's process lease, was handed to the next spawn. This drives
# the REAL bin/fm-spawn.sh and bin/fm-teardown.sh against a real Treehouse pool
# and restarts only the named lab session.
#
# Safety: every lifecycle operation goes through bin/fm-herdr-lab.sh, which
# appends the named session flag and verifies the default fleet session is
# unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-wt-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-restore-wt) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

PROJ="$TMP_ROOT/scratch-project"
POOL=
CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  [ ! -d "$PROJ" ] || (cd "$PROJ" && treehouse return --all --force >/dev/null 2>&1 && treehouse destroy --all --force >/dev/null 2>&1)
  # The scratch project's pool is this test's own; drop it with the project.
  [ -z "$POOL" ] || [ ! -f "$POOL/treehouse-state.json" ] || rm -rf "$POOL"
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

pane_field() {  # <pane_id> <field>
  lab pane get "$1" 2>/dev/null | jq -r --arg f "$2" '.result.pane[$f] // empty' 2>/dev/null
}

slot_field() {  # <worktree> <field>
  local wt
  wt=$(real "$1")
  (cd "$PROJ" && treehouse status --json) 2>/dev/null | jq -r --arg f "$2" '.[] | [.path, (.[$f] // "")] | @tsv' \
    | while IFS=$'\t' read -r path value; do
        [ "$(real "$path")" = "$wt" ] && printf '%s' "$value"
      done
}

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
git -C "$PROJ" fetch -q origin

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
for id in restA restB; do
  mkdir -p "$HOME_DIR/data/$id"
  printf "# Task\n## Captain's intent\nRestore %s in its own copy.\n\n## Firstmate spec\nNone.\n" "$id" > "$HOME_DIR/data/$id/brief.md"
done

spawn() {  # <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sleep 900" --backend herdr --mode no-mistakes --yolo off \
    >"$TMP_ROOT/$1.out" 2>"$TMP_ROOT/$1.err"
}

spawn restA || fail "spawn restA failed"$'\n'"$(cat "$TMP_ROOT/restA.err")"
WT_A=$(grep '^worktree=' "$HOME_DIR/state/restA.meta" | cut -d= -f2-)
PANE_A=$(grep '^herdr_pane_id=' "$HOME_DIR/state/restA.meta" | cut -d= -f2-)
[ -n "$WT_A" ] && [ -n "$PANE_A" ] || fail "restA's record names no worktree or pane"
POOL=$(dirname "$(dirname "$(real "$WT_A")")")
[ "$(real "$(pane_field "$PANE_A" cwd)")" = "$(real "$WT_A")" ] \
  || fail "restA's top-level pane shell is in '$(pane_field "$PANE_A" cwd)', not its slot $WT_A"
[ "$(slot_field "$WT_A" lease_holder)" = "firstmate:restA" ] \
  || fail "restA's slot is not durably leased to it (holder '$(slot_field "$WT_A" lease_holder)')"
pass "real herdr E2E: a spawned worker's top-level pane shell, which Herdr restores, is its leased slot"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the lab session"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not restore the lab session"
restored=
for _ in $(seq 1 50); do
  restored=$(pane_field "$PANE_A" cwd)
  [ -z "$restored" ] || break
  sleep 0.1
done
[ "$(real "$restored")" = "$(real "$WT_A")" ] \
  || fail "after a session restore restA's pane came back in '${restored:-nothing}', not its slot $WT_A"
[ "$(real "$(pane_field "$PANE_A" foreground_cwd)")" = "$(real "$WT_A")" ] \
  || fail "after a session restore restA's foreground is in '$(pane_field "$PANE_A" foreground_cwd)', not its slot"
[ "$(slot_field "$WT_A" status)" = leased ] \
  || fail "restA's slot reads '$(slot_field "$WT_A" status)' after the restore, not leased"
pass "real herdr E2E: after a session restore the worker's pane comes back in its own slot, still leased"

spawn restB || fail "spawn restB failed"$'\n'"$(cat "$TMP_ROOT/restB.err")"
WT_B=$(grep '^worktree=' "$HOME_DIR/state/restB.meta" | cut -d= -f2-)
[ -n "$WT_B" ] && [ "$(real "$WT_B")" != "$(real "$WT_A")" ] \
  || fail "the next spawn was handed restA's slot ($WT_B)"
grep -Fxq 'task=restA' "$(dirname "$(real "$WT_A")")/.fm-slot-owner" \
  || fail "restA's slot claim was overwritten"
pass "real herdr E2E: the next spawn after the restore gets another slot and leaves restA's claim alone"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" \
  "$ROOT/bin/fm-teardown.sh" restA --force >"$TMP_ROOT/teardown.out" 2>&1 \
  || fail "fm-teardown.sh failed for restA"$'\n'"$(cat "$TMP_ROOT/teardown.out")"
[ -z "$(slot_field "$WT_A" lease_holder)" ] \
  || fail "teardown left restA's slot leased to '$(slot_field "$WT_A" lease_holder)'"
pass "real herdr E2E: teardown returns the leased slot to the pool"
