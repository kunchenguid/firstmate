#!/usr/bin/env bash
# m2: the boot-context emitter is strictly read-only.
#
# This is the gate that retires D-11. The ban on registering
# bin/fm-captain-bootstrap.sh as a SessionStart hook was recorded with a stated
# reason - "a SessionStart hook that moves and deletes files" - and that reason
# is true: it shutil.move()s the handoff and os.remove()s the resume directive
# on every boot. bin/fm-boot-context.sh exists so the reason no longer applies
# to anything that gets registered. This gate is what makes that a fact rather
# than a promise.
#
# Two arms, because either alone is a false green:
#
#   A. WRITABLE arm - the real proof. Take a full manifest of the home (every
#      path, size, mtime, ctime, inode, mode), run a full boot with writing
#      fully available, take the manifest again, and demand they are identical.
#      A writable tree is the only condition under which a write would actually
#      land, so this is where "zero writes" is really tested.
#
#   B. READ-ONLY arm - the anti-silence proof. Hold the home, its state/, its
#      data/ and the fleet-view dir read-only with `chmod a-w`, then boot again
#      and demand the emitter still exits 0 and still emits a valid, non-empty
#      SessionStart envelope. Without this, an emitter that silently died under
#      a read-only tree would sail through arm A.
#
# Why chmod a-w and not strace / fs_usage / a read-only bind mount: the design
# names those, and none is available here. fs_usage requires root on macOS, and
# macOS has no bind mounts. `chmod a-w` needs no privileges, works on any
# filesystem, and - paired with arm A's manifest diff - is strictly stronger
# than observing syscalls, because it proves both that no write happened and
# that no write was needed.
#
# Directories held read-only in arm B: <home>, <home>/state, <home>/data, and
# the fleet-view directory, plus every file in them.
#
# Mutation (LEDGER_MUTATE=1): arm A runs bin/fm-captain-bootstrap.sh - the
# known-mutating script this one was split out of - instead of the emitter. It
# archives the handoff and deletes the resume directive, so the manifest differs
# and the assertion fails. This keys the gate to real observed writes rather
# than to the emitter merely existing.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-boot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

assert_present "$FM_BOOT_EMITTER" "bin/fm-boot-context.sh must exist"

TMP=$(fm_test_tmproot fm-boot-m2)
HOME_DIR="$TMP/home"; FLEET="$TMP/fleet"
fm_boot_make_home "$HOME_DIR" 3
fm_boot_make_fleet "$FLEET" 4

UNDER_TEST="$FM_BOOT_EMITTER"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  UNDER_TEST="$ROOT/bin/fm-captain-bootstrap.sh"
fi

# --- arm A: writable. Zero writes, proved by manifest identity. --------------
before=$(fm_boot_manifest "$TMP")

out=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  bash "$UNDER_TEST") || fail "emitter must exit 0 on a writable home"

after=$(fm_boot_manifest "$TMP")

if [ "$before" != "$after" ]; then
  fail "a boot must write NOTHING, but the tree changed:"$'\n'"$(
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -40)"
fi

# The two rehydrate files specifically - named because they are the exact
# artifacts D-11 objected to being moved and deleted.
assert_present "$HOME_DIR/state/handoff-probe-session.md" \
  "the handoff must still be there - the emitter never archives it"
assert_present "$HOME_DIR/state/resume-probe-session.directive" \
  "the resume directive must still be there - the emitter never consumes it"
assert_absent "$HOME_DIR/state/handoff-archive" \
  "the emitter must not create a handoff archive"

# And it must have produced something worth injecting.
ctx=$(fm_boot_context "$out")
[ -n "$ctx" ] || fail "a captain boot must inject a non-empty context block"

# --- arm B: read-only. Still exits 0, still emits valid output. --------------
chmod -R a-w "$HOME_DIR" "$FLEET"
# Confirm the harness is actually in force before trusting what it proves.
if (: > "$HOME_DIR/state/canary-write") 2>/dev/null; then
  chmod -R u+w "$HOME_DIR" "$FLEET"
  fail "read-only harness did not take: state/ is still writable, so arm B would prove nothing"
fi

# Baseline taken AFTER the chmod, so the comparison is not confounded by the
# mode and ctime changes the harness itself makes.
ro_before=$(fm_boot_manifest "$TMP")

ro_out=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER"); ro_code=$?
ro_after=$(fm_boot_manifest "$TMP")

chmod -R u+w "$HOME_DIR" "$FLEET"

expect_code 0 "$ro_code" "the emitter must exit 0 with the home held read-only"
ro_ctx=$(fm_boot_context "$ro_out")
[ -n "$ro_ctx" ] || fail "a read-only boot must still inject a non-empty context block"
assert_contains "$ro_ctx" "## Fleet" \
  "a read-only boot must still render the fleet section, not a stub"

# Nothing appeared while the tree was locked, either.
[ "$ro_before" = "$ro_after" ] \
  || fail "the read-only boot changed the tree:"$'\n'"$(
    diff <(printf '%s\n' "$ro_before") <(printf '%s\n' "$ro_after") | head -40)"

# --- arm C: a home with no state/ dir must not gain one ----------------------
# Read-only means read-only even where a directory is missing. This is not
# hypothetical: fm-lock.sh used to `mkdir -p "$STATE"` before dispatching, so
# relaying `fm-lock.sh status` created the very directory it was reporting on.
# A writable home is used deliberately - under chmod a-w the mkdir would fail
# rather than be shown not to happen.
BARE="$TMP/bare"
mkdir -p "$BARE"
bare_out=$(fm_boot_hook_json | env \
  FM_HOME="$BARE" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER") || fail "the emitter must exit 0 on a home with no state/"
assert_absent "$BARE/state" \
  "a boot must not create state/ - a reporting path that makes directories is not read-only"
assert_absent "$BARE/data" "a boot must not create data/"
[ "$(find "$BARE" -mindepth 1 | wc -l)" -eq 0 ] \
  || fail "a boot must leave a bare home completely empty, but it now holds: $(find "$BARE" -mindepth 1)"
bare_ctx=$(fm_boot_context "$bare_out")
[ -n "$bare_ctx" ] || fail "even a bare home must produce a context block"

pass "m2 boot-context emitter is read-only"
