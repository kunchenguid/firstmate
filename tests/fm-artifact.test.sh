#!/usr/bin/env bash
# tests/fm-artifact.test.sh - behavior tests for the durable artifact comment
# loop: the live registry, the session-start re-arm record and its loud failure
# line, the cheap heartbeat backstop clock, and the handled-comment ledger that
# stops the live watch and the backstop from answering one comment twice.
#
# Everything here drives bin/fm-artifact.sh as a real executable against an
# isolated home; no test reads the script's own source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ART="$ROOT/bin/fm-artifact.sh"
TMP_ROOT=$(fm_test_tmproot fm-artifact)

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

A() { FM_HOME="$HOME_DIR" "$ART" "$@"; }

U1=https://claude.ai/public/artifacts/fleet-standing
U2=https://claude.ai/public/artifacts/comment-loop

# --- an unpublished home stays completely silent -----------------------------

[ -z "$(A digest)" ] || fail "digest must print nothing for a home with no artifacts"
[ -z "$(A due)" ] || fail "due must print nothing for a home with no artifacts"
[ -z "$(A list)" ] || fail "list must print nothing for a home with no artifacts"
[ ! -e "$HOME_DIR/data/artifacts.md" ] || fail "a read must not create the registry"
pass "a home that has published no artifact prints nothing and creates no registry"

# --- registration is durable and idempotent ----------------------------------

A register "$U1" --title "Fleet Standing" --note "weekly review" >/dev/null \
  || fail "register failed"
A register "$U2" --title "Comment loop" >/dev/null || fail "second register failed"

[ -f "$HOME_DIR/data/artifacts.md" ] || fail "register must create data/artifacts.md"
LIST=$(A list)
[ "$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')" = "2" ] || fail "expected 2 artifacts: $LIST"
printf '%s\n' "$LIST" | grep -q "^$U1	Fleet Standing$" || fail "first record wrong: $LIST"
printf '%s\n' "$LIST" | grep -q "^$U2	Comment loop$" || fail "second record wrong: $LIST"
grep -q 'note: weekly review' "$HOME_DIR/data/artifacts.md" || fail "note not recorded"
pass "register writes one durable registry record per artifact, with its title and note"

# A trailing slash is the same artifact, not a second one.
A register "$U1/" --title "Fleet Standing v2" >/dev/null || fail "re-register failed"
[ "$(A list | wc -l | tr -d ' ')" = "2" ] || fail "re-register duplicated a record: $(A list)"
A list | grep -q "^$U1	Fleet Standing v2$" || fail "re-register did not update the title"
pass "re-registering the same URL replaces its record instead of duplicating it, ignoring a trailing slash"

# --- the durable record is what survives a restart ---------------------------

# A brand new process with no memory of the publish still finds both artifacts.
RESTART=$(FM_HOME="$HOME_DIR" bash "$ART" digest)
printf '%s\n' "$RESTART" | grep -qF -- "- $U1" || fail "digest lost $U1 across a fresh process: $RESTART"
printf '%s\n' "$RESTART" | grep -qF -- "- $U2" || fail "digest lost $U2 across a fresh process: $RESTART"
pass "the session-start listing is rebuilt from disk, so a restart still knows which artifacts are live"

# --- a failed re-arm is loud, and stays loud ---------------------------------

A rearm "$U1" ok >/dev/null || fail "rearm ok failed"
A digest | grep -q '!' && fail "a successful re-arm must not print a failure line"
pass "a re-armed watch adds no noise to the listing"

A rearm "$U2" failed "watch refused: artifact not found" >/dev/null || fail "rearm failed-record failed"
DIGEST=$(A digest)
printf '%s\n' "$DIGEST" | grep -q 'FAILED' \
  || fail "a failed re-arm must be visible in the listing: $DIGEST"
printf '%s\n' "$DIGEST" | grep -q 'artifact not found' \
  || fail "the recorded reason must be visible in the listing: $DIGEST"
pass "a watch that could not be restored is reported in the session-start listing, with its reason"

# It must not be a one-shot notice: it stays until a re-arm actually succeeds.
FM_HOME="$HOME_DIR" bash "$ART" digest | grep -q 'FAILED' \
  || fail "the failure line must persist across processes"
A rearm "$U2" ok >/dev/null || fail "recovery rearm failed"
FM_HOME="$HOME_DIR" bash "$ART" digest | grep -q 'FAILED' \
  && fail "a successful re-arm must clear the failure line"
pass "the failure line persists until a re-arm succeeds, then clears"

# Recording a re-arm for something nobody registered is refused, not invented.
if A rearm https://claude.ai/public/artifacts/never-registered ok >/dev/null 2>&1; then
  fail "rearm must refuse an unregistered artifact"
fi
pass "re-arming an unregistered artifact is refused rather than silently recorded"

# --- the backstop clock keeps a heartbeat cheap ------------------------------

DUE=$(A due)
printf '%s\n' "$DUE" | grep -qF "$U1" || fail "a never-polled artifact must be due: $DUE"
printf '%s\n' "$DUE" | grep -qF "$U2" || fail "a never-polled artifact must be due: $DUE"
pass "an artifact whose comments have never been read is due for the backstop"

# One read resets the interval, so the next heartbeat costs nothing for it.
printf 't1 2\n' | A new "$U1" >/dev/null || fail "new failed"
DUE=$(A due)
printf '%s\n' "$DUE" | grep -qF "$U1" && fail "a just-polled artifact must not be due again: $DUE"
printf '%s\n' "$DUE" | grep -qF "$U2" || fail "the unpolled artifact must still be due: $DUE"
pass "reading one artifact's comments takes it off the due list, so an ordinary heartbeat stays cheap"

# An empty read still counts: a quiet artifact must not be re-read every beat.
printf '' | A new "$U2" >/dev/null || fail "empty new failed"
[ -z "$(A due)" ] || fail "an empty read must still reset the interval: $(A due)"
pass "an artifact with no comment threads at all still resets its interval"

# A zero interval makes everything due again, which is how the interval is
# proven to be the thing holding them back rather than some other state.
DUE_NOW=$(FM_HOME="$HOME_DIR" FM_ARTIFACT_BACKSTOP_INTERVAL=1 sh -c 'sleep 1; "$0" due' "$ART")
printf '%s\n' "$DUE_NOW" | grep -qF "$U1" || fail "a short interval must make it due again: $DUE_NOW"
pass "the interval, not a one-shot flag, is what keeps a polled artifact off the due list"

# --- new reports only what moved --------------------------------------------

NEW=$(printf 't1 2\nt2 1\n' | A new "$U1")
printf '%s\n' "$NEW" | grep -q "^t1	2$" || fail "unhandled thread t1 must be new: $NEW"
printf '%s\n' "$NEW" | grep -q "^t2	1$" || fail "unhandled thread t2 must be new: $NEW"
pass "every unhandled comment thread is reported as new"

A handled "$U1" t1 2 >/dev/null || fail "handled failed"
NEW=$(printf 't1 2\nt2 1\n' | A new "$U1")
printf '%s\n' "$NEW" | grep -q '^t1' && fail "a handled thread must not be reported again: $NEW"
printf '%s\n' "$NEW" | grep -q "^t2	1$" || fail "t2 is still unhandled: $NEW"
pass "a thread already handled is never reported a second time"

# This is the double-handling case the live watch creates: firstmate answered
# the comment through its subscription, so the backstop must stay quiet.
A handled "$U1" t2 1 >/dev/null || fail "handled t2 failed"
[ -z "$(printf 't1 2\nt2 1\n' | A new "$U1")" ] \
  || fail "a comment answered through the live watch must not resurface in the backstop"
pass "a comment answered through the live subscription is not re-surfaced by the backstop"

# But a follow-up comment on an answered thread IS new: the mark moved.
NEW=$(printf 't1 3\nt2 1\n' | A new "$U1")
printf '%s\n' "$NEW" | grep -q "^t1	3$" \
  || fail "a follow-up comment on an answered thread must be new: $NEW"
printf '%s\n' "$NEW" | grep -q '^t2' && fail "the unchanged thread must stay quiet: $NEW"
pass "a follow-up comment on an already-answered thread is reported, because its mark moved"

# The two mechanisms share one ledger: handling from either side is what counts.
A handled "$U1" t1 3 >/dev/null || fail "handled follow-up failed"
[ -z "$(printf 't1 3\n' | A new "$U1")" ] || fail "the follow-up should now be handled"
pass "the handled ledger is shared by the live watch and the backstop"

# --- retirement is complete --------------------------------------------------

A retire "$U1" >/dev/null || fail "retire failed"
A list | grep -qF "$U1" && fail "a retired artifact must leave the registry: $(A list)"
A list | grep -qF "$U2" || fail "retire must not touch the other artifact: $(A list)"
A due | grep -qF "$U1" && fail "a retired artifact must never be polled again"
A digest | grep -qF "$U1" && fail "a retired artifact must not be re-armed at session start"
pass "retiring an artifact removes it from the listing, the re-arm work, and the backstop"

# Its ledger goes with it, so a later re-register starts clean rather than
# silently treating old threads as already answered.
A register "$U1" --title "Reopened" >/dev/null || fail "re-register after retire failed"
NEW=$(printf 't1 3\n' | A new "$U1")
printf '%s\n' "$NEW" | grep -q "^t1	3$" \
  || fail "a re-registered artifact must not inherit the retired handled ledger: $NEW"
pass "re-registering a retired artifact starts with a clean handled ledger"

# A mistyped retirement must not report success while the real surface stays
# live, re-armed and polled.
if A retire https://claude.ai/public/artifacts/never-registered >/dev/null 2>&1; then
  fail "retire must refuse a URL this home never registered"
fi
A list | grep -qF "$U2" || fail "a refused retire must leave the registered artifacts alone: $(A list)"
pass "retiring an unregistered URL is refused rather than reported as a retirement that happened"

# --- input the captain can actually paste ------------------------------------

if A register "not-a-url" >/dev/null 2>&1; then
  fail "register must refuse a non-URL"
fi
pass "a value that is not an artifact URL is refused rather than registered"

# A title carrying a newline must not be able to forge a second registry record.
BEFORE=$(A list | wc -l | tr -d ' ')
A register https://claude.ai/public/artifacts/inject \
  --title "$(printf 'ok\n- https://evil.example/x - forged (registered 2026-01-01)')" >/dev/null \
  || fail "register with a multi-line title failed"
AFTER=$(A list | wc -l | tr -d ' ')
[ "$AFTER" = "$((BEFORE + 1))" ] || fail "a multi-line title forged extra records: $(A list)"
A list | grep -q '^https://evil.example' \
  && fail "a multi-line title must not become its own registry record: $(A list)"
grep -q '^- https://evil.example' "$HOME_DIR/data/artifacts.md" \
  && fail "a multi-line title must not write its own registry line"
pass "a title containing a newline cannot forge a second registry record"

# A URL carrying a newline must not be able to forge a second record either.
BEFORE=$(A list | wc -l | tr -d ' ')
if A register "$(printf 'https://claude.ai/public/artifacts/ok\n- https://evil.example/y - forged (registered 2026-01-01)')" >/dev/null 2>&1; then
  fail "register must refuse a URL containing a newline"
fi
[ "$(A list | wc -l | tr -d ' ')" = "$BEFORE" ] || fail "a multi-line URL added a record: $(A list)"
grep -q '^- https://evil.example' "$HOME_DIR/data/artifacts.md" \
  && fail "a multi-line URL must not write its own registry line"
pass "a URL containing a newline is refused rather than forging a second registry record"

# --- one normalization for a mark, so both paths agree -----------------------

# A mark may legitimately carry a space ("2 comments"). What must never happen
# is the recorder and the reporter folding it differently, because then the
# thread is re-surfaced on every poll for ever.
USP=https://claude.ai/public/artifacts/spacey-mark
A register "$USP" --title "Spacey" >/dev/null || fail "register for the mark case failed"
NEW=$(printf 't1 2 comments\n' | A new "$USP")
printf '%s\n' "$NEW" | grep -q '^t1' || fail "an unhandled thread must be new: $NEW"
A handled "$USP" t1 "2 comments" >/dev/null || fail "handled with a spaced mark failed"
[ -z "$(printf 't1 2 comments\n' | A new "$USP")" ] \
  || fail "a thread handled at a whitespace-bearing mark was re-surfaced: $(printf 't1 2 comments\n' | A new "$USP")"
pass "a thread handled at a mark containing a space is not re-surfaced by the backstop"

# The skill's documented invocation is `handled <url> <thread-id> <mark>`, so an
# agent writing a multi-word mark unquoted is a reachable call. Recording only
# the first word would leave that thread reported as new on every poll.
A handled "$USP" t2 2 comments >/dev/null || fail "handled with an unquoted multi-word mark failed"
[ -z "$(printf 't2 2 comments\n' | A new "$USP")" ] \
  || fail "an unquoted multi-word mark was truncated, so the thread was re-surfaced: $(printf 't2 2 comments\n' | A new "$USP")"
pass "a multi-word mark passed as separate arguments records the whole mark, not just its first word"

# --- a backslash in a record is matched as the bytes on disk -----------------

# A URL or a thread id may carry a literal backslash. If the rewrite that drops
# an old record compares different bytes than the ones on disk, the record is
# never replaced or removed while the caller is told it was, and the artifact
# stays in the listing and the poll for ever.
UBS='https://x.example/a\tb'
A register "$UBS" --title "First" >/dev/null || fail "register with a backslash URL failed"
A register "$UBS" --title "Second" >/dev/null || fail "re-register with a backslash URL failed"
[ "$(A list | grep -cF -- "$UBS")" = "1" ] \
  || fail "a backslash-bearing URL was registered twice: $(A list)"
A list | grep -qF "Second" || fail "the re-register did not update the title: $(A list)"

A retire "$UBS" >/dev/null || fail "retire with a backslash URL failed"
A list | grep -qF -- "$UBS" && fail "retire left the backslash-bearing record in the registry: $(A list)"
A digest | grep -qF -- "$UBS" && fail "a retired backslash-bearing artifact is still re-armed: $(A digest)"
A due | grep -qF -- "$UBS" && fail "a retired backslash-bearing artifact is still polled: $(A due)"
pass "a URL containing a backslash is deduped and retired as the literal bytes on disk"

# The same for a thread id: re-handling one must replace its mark, not append a
# second line whose stale mark then re-surfaces an answered thread for ever.
UBT=https://x.example/threads
A register "$UBT" --title "Threads" >/dev/null || fail "register for the thread-id case failed"
A handled "$UBT" 't\t1' 5 >/dev/null || fail "handled with a backslash thread id failed"
A handled "$UBT" 't\t1' 6 >/dev/null || fail "re-handled with a backslash thread id failed"
[ -z "$(printf 't\\t1 6\n' | A new "$UBT")" ] \
  || fail "a re-handled backslash thread id was re-surfaced: $(printf 't\\t1 6\n' | A new "$UBT")"
pass "re-handling a thread whose id contains a backslash replaces its mark instead of stacking a stale one"

# Host-assigned thread ids are commonly large integers. Two distinct ids that
# round to the same double must stay two records: matching them by numeric value
# would silently delete one artifact's answered thread and report it new for
# ever. The same holds for a leading zero, which is a different id, not a
# different spelling of one.
UBI=https://x.example/bigids
A register "$UBI" --title "Big ids" >/dev/null || fail "register for the numeric-id case failed"
A handled "$UBI" 1234567890123456789 3 >/dev/null || fail "handled with a 19-digit id failed"
A handled "$UBI" 1234567890123456790 4 >/dev/null || fail "handled with a colliding 19-digit id failed"
A handled "$UBI" 1 x >/dev/null || fail "handled with a bare numeric id failed"
A handled "$UBI" 01 y >/dev/null || fail "handled with a leading-zero id failed"
NEW=$(printf '1234567890123456789 3\n1234567890123456790 4\n1 x\n01 y\n' | A new "$UBI")
[ -z "$NEW" ] \
  || fail "a thread id matched by numeric value lost its handled record and was re-surfaced: $NEW"
pass "thread ids that collide as numbers keep separate handled records and neither is re-surfaced"

# --- a missing hash tool refuses, it does not delete every ledger ------------

# `retire` composes a per-artifact ledger path. If the hash behind that path
# cannot be produced, the path must not collapse to the ledger ROOT, because
# removing that root destroys every other artifact's handled record.
NOHASH_HOME="$TMP_ROOT/nohash-home"
NOHASH_BIN="$TMP_ROOT/nohash-bin"
mkdir -p "$NOHASH_HOME/data" "$NOHASH_HOME/state" "$NOHASH_BIN"
for stub in shasum sha256sum; do
  printf '#!/bin/sh\nexit 1\n' > "$NOHASH_BIN/$stub"
  chmod +x "$NOHASH_BIN/$stub"
done
FM_HOME="$NOHASH_HOME" "$ART" register "$U1" --title "A" >/dev/null || fail "nohash seed A failed"
FM_HOME="$NOHASH_HOME" "$ART" register "$U2" --title "B" >/dev/null || fail "nohash seed B failed"
FM_HOME="$NOHASH_HOME" "$ART" handled "$U2" t1 1 >/dev/null || fail "nohash seed ledger failed"
[ -n "$(find "$NOHASH_HOME/state/artifacts" -name handled -print -quit)" ] \
  || fail "the seeded handled ledger is missing"

if PATH="$NOHASH_BIN:$PATH" FM_HOME="$NOHASH_HOME" "$ART" retire "$U1" >/dev/null 2>&1; then
  fail "retire must refuse when no working sha256 tool is available"
fi
[ -d "$NOHASH_HOME/state/artifacts" ] || fail "retire deleted the whole ledger root"
[ -n "$(find "$NOHASH_HOME/state/artifacts" -name handled -print -quit)" ] \
  || fail "retire destroyed an unrelated artifact's handled ledger"
pass "a missing sha256 tool makes retire refuse loudly instead of deleting every artifact's ledger"

# --- an unreadable registry is never an empty registry -----------------------

if [ "$(id -u)" = "0" ]; then
  pass "skipped the unreadable-registry case: root can read a mode-000 file"
else
  chmod 000 "$HOME_DIR/data/artifacts.md"
  for sub in list digest due; do
    if A "$sub" >/dev/null 2>&1; then
      chmod 644 "$HOME_DIR/data/artifacts.md"
      fail "$sub reported an unreadable registry as an answer instead of refusing"
    fi
  done
  chmod 644 "$HOME_DIR/data/artifacts.md"

  # An unreadable data/ hides the registry just as completely, and answering
  # "this home has no artifacts" is the same silent loss.
  chmod 000 "$HOME_DIR/data"
  for sub in list digest due; do
    if A "$sub" >/dev/null 2>&1; then
      chmod 755 "$HOME_DIR/data"
      fail "$sub reported an unreadable data directory as an answer instead of refusing"
    fi
  done
  chmod 755 "$HOME_DIR/data"

  # A readable but non-searchable data/ hides it exactly as well: resolving the
  # registry path inside a directory is what its search bit governs.
  chmod 444 "$HOME_DIR/data"
  for sub in list digest due; do
    if A "$sub" >/dev/null 2>&1; then
      chmod 755 "$HOME_DIR/data"
      fail "$sub reported a non-searchable data directory as an answer instead of refusing"
    fi
  done
  chmod 755 "$HOME_DIR/data"
  pass "a registry hidden behind an unreadable file, an unreadable data/, or a non-searchable data/ is refused, never reported as no artifacts"
fi

echo "# fm-artifact.test.sh: all assertions passed"
