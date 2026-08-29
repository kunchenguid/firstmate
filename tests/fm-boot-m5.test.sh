#!/usr/bin/env bash
# m5: a section that fails says so. Failure is never silent.
#
# The defect: bin/fm-captain-bootstrap.sh wraps the entire digest in a bare
#   try: ctx += build_digest()
#   except: pass
# so any unexpected exception drops the whole reconciliation digest with no
# trace. A boot that lost all of its fleet context then looks byte-for-byte
# like a healthy one, and the captain acts on a snapshot that silently is not
# there. Degrading is fine; degrading invisibly is the bug.
#
# The contract this gate freezes: when a section builder raises, the emitter
# still emits, and the output carries an explicit UNAVAILABLE marker naming the
# section and the reason. Nothing is ever dropped without a marker.
#
# Faults are injected through FM_BOOT_FORCE_FAIL, a documented test seam that
# makes the named section builder raise - the same shape as the FM_BOOTSTRAP_BIN
# stub seam the digest already uses. A real fault would only exercise failures
# the code already anticipates; the point here is the UNEXPECTED exception, and
# forcing one is the only way to test it.
#
# Mutation (LEDGER_MUTATE=1): the assertions are run against
# bin/fm-captain-bootstrap.sh, which carries the bare `except: pass`. It drops
# the digest silently and emits no marker, so the assertions fail. This keys the
# gate to the marker actually being produced, not to the seam existing.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-boot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

assert_present "$FM_BOOT_EMITTER" "bin/fm-boot-context.sh must exist"

TMP=$(fm_test_tmproot fm-boot-m5)
HOME_DIR="$TMP/home"; FLEET="$TMP/fleet"
fm_boot_make_home "$HOME_DIR" 3
fm_boot_make_fleet "$FLEET" 3

UNDER_TEST="$FM_BOOT_EMITTER"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  UNDER_TEST="$ROOT/bin/fm-captain-bootstrap.sh"
fi

# A generous budget, deliberately. This gate's subject is that failure is never
# silent, not that the budget holds - m4 owns that. Left on the shipped budget,
# a loaded machine can exhaust it before the lock helper runs, the emitter
# correctly degrades to Tier 1, and every assertion here about the digest fails
# for a reason that has nothing to do with silence. That is how this gate froze
# VACUOUS: under the ledger harness the normal arm failed, so the mutation check
# could not bite. A gate must control everything except the one thing it tests.
export FM_BOOT_TOTAL_BUDGET=30
export FM_BOOT_HELPER_TIMEOUT=10

run_with_fault() {
  fm_boot_hook_json | env \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_BOOT_FORCE_FAIL="$1" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"
}

# --- a healthy boot carries no marker, so the marker means something ---------
clean=$(fm_boot_run "$HOME_DIR" "$FLEET" FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain) \
  || fail "a healthy boot must exit 0"
clean_ctx=$(fm_boot_context "$clean")
assert_not_contains "$clean_ctx" "UNAVAILABLE" \
  "a healthy boot must carry no UNAVAILABLE marker - otherwise the marker proves nothing"

# --- the digest raising must be visible -------------------------------------
out=$(run_with_fault digest) || fail "a raising digest must not break the hook"
ctx=$(fm_boot_context "$out")
assert_contains "$ctx" "UNAVAILABLE" \
  "a raising digest must leave an explicit UNAVAILABLE marker, not vanish"
assert_contains "$ctx" "digest" \
  "the marker must name the section that failed"
assert_contains "$ctx" "FmBootForcedFault" \
  "the marker must carry the reason, so the failure is diagnosable from the block alone"

# The rest of the block must survive - one failed section is not a total loss.
assert_contains "$ctx" "## Fleet" \
  "a failed digest must not take the fleet section down with it"

# --- the fleet section raising must be visible too --------------------------
out2=$(run_with_fault fleet) || fail "a raising fleet section must not break the hook"
ctx2=$(fm_boot_context "$out2")
assert_contains "$ctx2" "UNAVAILABLE" \
  "a raising fleet section must leave an explicit marker"
assert_contains "$ctx2" "fleet" \
  "the marker must name the fleet section"

# --- total failure still emits, and still says why --------------------------
out3=$(run_with_fault all) || fail "a wholly failed build must still exit 0"
ctx3=$(fm_boot_context "$out3")
assert_contains "$ctx3" "UNAVAILABLE" \
  "even a total failure must emit a marker rather than an empty or absent block"

# --- a malformed budget must degrade, not detonate --------------------------
#
# The budget values are parsed at import time, outside the guard around the
# build, so a bare float() there takes the whole hook down with a traceback and
# zero stdout - a boot that lost all its context while looking like nothing ran.
# An empty-valued env var is an entirely ordinary thing for a hook config to
# produce, so this is a live failure mode and not a contrived one.
for bad in "" "abc" "-"; do
  bad_out=$(fm_boot_hook_json | env \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_BOOT_TOTAL_BUDGET="$bad" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"); bad_code=$?
  expect_code 0 "$bad_code" "a malformed budget ('$bad') must not take the hook down"
  bad_ctx=$(fm_boot_context "$bad_out")
  [ -n "$bad_ctx" ] || fail "a malformed budget ('$bad') must still inject a block"
  assert_contains "$bad_ctx" "## Fleet" \
    "a malformed budget ('$bad') must still render the fleet, on the default budget"
done

# A non-numeric value is a real misconfiguration and must be visible, not just
# tolerated. An empty value is ordinary absence, so it defaults silently.
noisy=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" \
  FM_BOOT_TOTAL_BUDGET=abc FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$UNDER_TEST")
noisy_ctx=$(fm_boot_context "$noisy")
assert_contains "$noisy_ctx" "UNAVAILABLE" \
  "a non-numeric budget must leave a visible marker, not be silently ignored"
assert_contains "$noisy_ctx" "FM_BOOT_TOTAL_BUDGET" \
  "the marker must name the setting that was wrong"

# --- UNREADABLE IS NOT EMPTY ------------------------------------------------
#
# The failure this section freezes, found by an independent verifier against an
# earlier version of this branch: a boot against a home that did not exist
# printed a fully confident, marker-free block - "0 in flight", "Wake queue:
# empty", "In-flight tasks: none". Byte-identical to a genuinely idle, healthy
# home.
#
# That is the single most consequential lie this block can tell. Recovery keys
# off exactly those lines: they say there is nothing to reconcile. And it was
# reachable through an ordinary FM_HOME misconfiguration, which the
# N-concurrent-firstmates design makes routine.
#
# The earlier m5 missed it because its observable was scoped to section
# builders that RAISE, and none of these paths raise - read_or, wake_queue and
# own_tasks each caught the error and returned the empty value, which is
# indistinguishable from the healthy one.
#
# Two kinds of not-knowing, which must not be conflated:
#   STRUCTURAL - the home or state/ cannot be listed, so the COUNT is unknown
#   DETAIL     - state/ lists fine, one status file will not read; the count is
#                real and must survive, only that detail is marked
unreadable_boot_fleet() {
  fm_boot_hook_json | env \
    FM_HOME="$1" \
    FM_BOOT_FLEET_DIR="$2" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"
}

unreadable_boot() {
  fm_boot_hook_json | env \
    FM_HOME="$1" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"
}

# The exact phrases a healthy idle home would print. None may appear when the
# thing they describe could not be read.
assert_no_false_calm() {
  local ctx=$1 label=$2
  assert_contains "$ctx" "UNAVAILABLE" \
    "$label: must carry an explicit marker, not a confident empty block"
  assert_not_contains "$ctx" "0 in flight, 0 need a decision" \
    "$label: must not count to zero off state it could not read"
  assert_not_contains "$ctx" "Wake queue: empty" \
    "$label: must not report an empty queue it could not read"
  assert_not_contains "$ctx" "In-flight tasks: none" \
    "$label: must not report no in-flight tasks it could not read"
}

# 1. a home that does not exist at all
GONE="$TMP/no-such-home"
gone_out=$(unreadable_boot "$GONE") || fail "an absent home must not break the hook"
gone_ctx=$(fm_boot_context "$gone_out")
assert_no_false_calm "$gone_ctx" "absent home"
assert_contains "$gone_ctx" "home is absent" "the marker must say the home is absent"

# 2. state/ present but unreadable
BLIND="$TMP/blind"
fm_boot_make_home "$BLIND" 3
chmod 000 "$BLIND/state"
blind_out=$(unreadable_boot "$BLIND"); blind_code=$?
blind_ctx=$(fm_boot_context "$blind_out")
chmod 755 "$BLIND/state"
expect_code 0 "$blind_code" "an unreadable state/ must not break the hook"
assert_no_false_calm "$blind_ctx" "unreadable state/"

# 3. the wake queue alone is unreadable - the counts are still real
QBLIND="$TMP/qblind"
fm_boot_make_home "$QBLIND" 3
chmod 000 "$QBLIND/state/.wake-queue"
q_out=$(unreadable_boot "$QBLIND"); q_code=$?
q_ctx=$(fm_boot_context "$q_out")
chmod 644 "$QBLIND/state/.wake-queue"
expect_code 0 "$q_code" "an unreadable wake queue must not break the hook"
assert_contains "$q_ctx" "UNAVAILABLE" "an unreadable wake queue must be marked"
assert_not_contains "$q_ctx" "Wake queue: empty" \
  "an unreadable wake queue must never render as empty"
assert_contains "$q_ctx" "In-flight tasks: 3" \
  "a readable state/ must still report its real task count"

# 4. one status file unreadable - marked, but the count survives
DBLIND="$TMP/dblind"
fm_boot_make_home "$DBLIND" 3
chmod 000 "$DBLIND/state/task-2.status"
d_out=$(unreadable_boot "$DBLIND"); d_code=$?
d_ctx=$(fm_boot_context "$d_out")
chmod 644 "$DBLIND/state/task-2.status"
expect_code 0 "$d_code" "an unreadable status file must not break the hook"
assert_contains "$d_ctx" "UNAVAILABLE" "an unreadable status file must be marked"
assert_contains "$d_ctx" "task-2.status" "the marker must name the file it could not read"
assert_contains "$d_ctx" "3 in flight" \
  "a detail we could not read must not discard a count we do have"

# 5. an ABSENT wake queue is genuinely an empty queue, and says so plainly.
# Without this the fix could pass by marking everything, which would make the
# marker meaningless in the other direction.
EMPTYQ="$TMP/emptyq"
fm_boot_make_home "$EMPTYQ" 2
rm -f "$EMPTYQ/state/.wake-queue"
e_out=$(unreadable_boot "$EMPTYQ") || fail "a home with no wake queue must boot"
e_ctx=$(fm_boot_context "$e_out")
assert_contains "$e_ctx" "Wake queue: empty" \
  "an absent wake queue is genuinely empty and must say so, not cry UNAVAILABLE"
assert_not_contains "$e_ctx" "UNAVAILABLE" \
  "ordinary absence must not raise a marker - or the marker means nothing"

# 6. an unreadable FLEET DIR is not an empty fleet.
#
# The same defect one level out from the home: the fleet section collapsed an
# unreadable directory into "(no shared fleet view yet - only this home is
# reported)". Peers may exist and be invisible, so that line claims the fleet is
# just this home when nothing is known - in the one section whose entire job is
# answering "what is the fleet doing".
#
# Absence stays absence: no fleet dir at all is today's ordinary condition,
# because the writer for it does not exist yet, and it must keep saying so
# plainly or the marker means nothing.
NOFLEET="$TMP/no-fleet-dir"
absent=$(unreadable_boot_fleet "$HOME_DIR" "$NOFLEET") || fail "an absent fleet dir must boot"
absent_ctx=$(fm_boot_context "$absent")
assert_contains "$absent_ctx" "no shared fleet view yet" \
  "an ABSENT fleet dir is ordinary absence and must say so plainly"
assert_not_contains "$absent_ctx" "UNAVAILABLE" \
  "ordinary absence must not raise a marker - or the marker means nothing"

BLINDFLEET="$TMP/blind-fleet"
mkdir -p "$BLINDFLEET"
chmod 000 "$BLINDFLEET"
blind=$(unreadable_boot_fleet "$HOME_DIR" "$BLINDFLEET"); blind_rc=$?
blind_ctx=$(fm_boot_context "$blind")
chmod 755 "$BLINDFLEET"
expect_code 0 "$blind_rc" "an unreadable fleet dir must not break the hook"
assert_contains "$blind_ctx" "UNAVAILABLE" \
  "an UNREADABLE fleet dir must be marked, not reported as no-view-yet"
assert_not_contains "$blind_ctx" "no shared fleet view yet" \
  "an unreadable fleet dir must never claim the fleet is only this home"

# 7. a peer record that parses but lacks its required fields is not idle.
BADREC="$TMP/bad-record"
mkdir -p "$BADREC"
printf '{"id":"peer-x","watcher":"healthy"}' > "$BADREC/peer-x.json"
badrec=$(unreadable_boot_fleet "$HOME_DIR" "$BADREC") || fail "a malformed peer record must boot"
badrec_ctx=$(fm_boot_context "$badrec")
assert_contains "$badrec_ctx" "UNAVAILABLE" \
  "a peer record missing required fields must be marked"
assert_not_contains "$badrec_ctx" "peer-x         [0 in flight" \
  "a record missing its counts must not be rendered as an idle peer"

# 8. TRUNCATION IS REPORTED. A file too large to read whole is not a short file.
#
# read() took exactly READ_LIMIT bytes and could not tell a file that ends there
# from one that does not, while the code's own comment promised "truncation is
# reported, never silent". Measured: a 400KB status file rendered with no marker
# and dropped its real last line - a `done:` - so the boot reported a FINISHED
# task as still working. That is the same lie as "unreadable is not empty", and
# it is worse than an unreadable file, because an unreadable one at least looks
# wrong. One byte past the limit is now requested, and its presence proves the
# truncation.
BIGHOME="$TMP/bigstatus"
fm_boot_make_home "$BIGHOME" 2
python3 - "$BIGHOME/state/task-1.status" <<'PY'
import sys
open(sys.argv[1], "w").write("working: filler\n" * 30000 + "done: THE REAL LAST LINE\n")
PY
big=$(unreadable_boot "$BIGHOME") || fail "an oversized status file must not break the hook"
big_ctx=$(fm_boot_context "$big")
assert_contains "$big_ctx" "truncated" \
  "a file read past its limit must say it was truncated"
assert_contains "$big_ctx" "task-1.status" "the marker must name the truncated file"
# The critical half: it must not present the surviving prefix as the task's
# current state, because the real last line is exactly what was lost.
printf '%s\n' "$big_ctx" | grep -E '^- task-1 .* - working: filler' >/dev/null \
  && fail "a truncated status must not be rendered as the task's live state - the \
line that was dropped is the one that mattered"

# And an ordinary status is untouched, so the marker keeps its meaning.
printf 'working: one\ndone: finished properly\n' > "$BIGHOME/state/task-1.status"
small=$(unreadable_boot "$BIGHOME") || fail "a normal status must boot"
small_ctx=$(fm_boot_context "$small")
assert_not_contains "$small_ctx" "truncated" \
  "a normal-sized file must raise no truncation marker"
assert_contains "$small_ctx" "done: finished properly" \
  "a normal status must still be relayed verbatim"

# --- WHO IS STEERING IS ANSWERED, GUESSED AT, OR MARKED - NEVER GUESSED -----
#
# The same defect as "unreadable is not empty", one field over. The emitter
# decides whether this session is steering its home by asking whether the lock
# holder is one of its own ancestors, and both halves of that question can fail:
# the lock line may not read, and the ancestry probe may not run. Collapsing
# either failure into "not steering" makes the block state, flatly, that ANOTHER
# session is steering and this one should go ask it - which, for a resume or a
# /clear inside the steering session, is a self-referential falsehood produced
# from no evidence at all.
#
# So the verdict has three values, and each one is proved here. Until this
# section existed none of them was: every boot fixture writes a dead pid to
# state/.lock, fm-lock.sh calls that stale, and the stale branch returns
# "steering" without ever invoking the ancestry probe. The observing verdict and
# both unknown verdicts were rendered by no gate in the suite.
#
# The fixtures drive the lock line through the FM_BOOTSTRAP_BIN stub seam and
# the ancestry probe through a `ps` shim on PATH, which is what lets a test say
# "held by a live harness that is not us" and "ps is broken" without needing a
# second real session.
FOREIGN_SLEEPER=""
m5_cleanup() {
  [ -n "$FOREIGN_SLEEPER" ] && kill "$FOREIGN_SLEEPER" 2>/dev/null
  # Chain the library cleanup: replacing its EXIT trap without calling it is
  # what leaks a registry file per run.
  fm_test_cleanup
}
trap m5_cleanup EXIT

# A live process that is emphatically NOT one of our ancestors. Bounded, so a
# run that dies on an earlier assertion cannot leave it behind for long, and
# deliberately not the `sleep 999` signature tests/fm-reap-strays.sh hunts.
# Its output is detached from ours: tests/run-all.sh captures each test with a
# command substitution, which does not return until every holder of the pipe's
# write end closes it - so a sleeper that inherited stdout could stall the whole
# suite for a minute, with no output naming the test in flight, on any exit path
# that bypassed the trap above.
sleep 60 >/dev/null 2>&1 &
FOREIGN_SLEEPER=$!

steer_bin() {
  local dir=$1 holder=$2
  mkdir -p "$dir"
  cat > "$dir/fm-lock.sh" <<SH
#!/usr/bin/env bash
echo "lock: held by live harness pid $holder"
SH
  cat > "$dir/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "watcher: healthy (beacon 2s old)"
SH
  chmod +x "$dir/fm-lock.sh" "$dir/fm-watch-arm.sh"
}

# A `ps` shim that answers the way the argument says, shadowing the real one.
ps_shim() {
  local dir=$1 mode=$2
  mkdir -p "$dir"
  if [ "$mode" = fails ]; then
    cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
echo "ps: cannot read the process table" >&2
exit 1
SH
  else
    cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fi
  chmod +x "$dir/ps"
  printf '%s
' "$dir"
}

steer_boot() {
  fm_boot_hook_json | env \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    "$@" \
    bash "$UNDER_TEST"
}

# 1. STEERING. The shipped fixture's lock is stale, so this session is about to
#    take it. The verdict must be plain, and it must carry the digest a steering
#    session reconciles from.
assert_contains "$clean_ctx" "(steering)" \
  "a stale lock means this session is steering, and the identity line must say so"
assert_not_contains "$clean_ctx" "steering unknown" \
  "a lock that read fine leaves nothing unknown about who is steering"
assert_not_contains "$clean_ctx" "Another session is steering" \
  "the steering session must not be told to go ask itself"
assert_contains "$clean_ctx" "## Reconciliation digest" \
  "the steering session must receive the digest it reconciles from"

# 2. OBSERVING. The lock is held by a live harness that is not in our ancestry,
#    which is the one case where the assertive wording is TRUE.
OBIN="$TMP/observing-bin"
steer_bin "$OBIN" "$FOREIGN_SLEEPER"
obs=$(steer_boot FM_BOOTSTRAP_BIN="$OBIN") || fail "an observing boot must exit 0"
obs_ctx=$(fm_boot_context "$obs")
assert_contains "$obs_ctx" "(observing)" \
  "a lock held by a live harness outside our ancestry means this session is observing"
assert_contains "$obs_ctx" "Another session is steering this home" \
  "the observing session must be told to ask rather than act"
assert_not_contains "$obs_ctx" "## Reconciliation digest" \
  "an observing session must not be handed the steering session's digest"

# 3. UNKNOWN, because the probe BROKE. ps exits non-zero, so nothing is known
#    about the ancestry, and a verdict either way would be invented.
FAILPS=$(ps_shim "$TMP/ps-fails" fails)
unk=$(steer_boot FM_BOOTSTRAP_BIN="$OBIN" PATH="$FAILPS:$PATH") \
  || fail "a broken ancestry probe must not break the hook"
unk_ctx=$(fm_boot_context "$unk")
assert_contains "$unk_ctx" "(steering unknown)" \
  "a probe that could not run leaves the steering question unknown, and the identity line must say so"
assert_contains "$unk_ctx" "## steering - UNAVAILABLE" \
  "an unknown verdict must carry an explicit marker, not degrade quietly into observing"
assert_contains "$unk_ctx" "re-read the lock before acting" \
  "the marker must tell the reader what to do about it"
assert_not_contains "$unk_ctx" "Another session is steering" \
  "THE POINT: a degraded probe must never assert that another session is steering"
assert_not_contains "$unk_ctx" "## Reconciliation digest" \
  "an unknown verdict must not hand out the steering digest either"

# 4. UNKNOWN, because the probe answered but said NOTHING. This is the sharper
#    half: ps exits 0 with an empty table, the ancestry walk still yields our own
#    pid, and "the holder is not in that one-element chain" reads exactly like a
#    real observing verdict. Silence from ps is not evidence.
MUTEPS=$(ps_shim "$TMP/ps-mute" mute)
mute=$(steer_boot FM_BOOTSTRAP_BIN="$OBIN" PATH="$MUTEPS:$PATH") \
  || fail "an empty ancestry probe must not break the hook"
mute_ctx=$(fm_boot_context "$mute")
assert_contains "$mute_ctx" "(steering unknown)" \
  "a probe that returned no chain for this process knows nothing, and must say so"
assert_not_contains "$mute_ctx" "Another session is steering" \
  "an empty process table must not be read as proof that someone else holds the lock"

kill "$FOREIGN_SLEEPER" 2>/dev/null
FOREIGN_SLEEPER=""

pass "m5 boot context never fails silently"
