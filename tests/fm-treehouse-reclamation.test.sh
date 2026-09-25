#!/usr/bin/env bash
# Exact-slot reclamation behavior with real Git and isolated pool metadata.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-reclamation)
export FM_HOME="$TMP_ROOT/home"
. "$ROOT/bin/fm-wake-lib.sh"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/project" "$TMP_ROOT/pool/1"
git -C "$TMP_ROOT/project" init -q -b main
git -C "$TMP_ROOT/project" commit -q --allow-empty -m baseline
printf '{}\n' > "$TMP_ROOT/pool/treehouse-state.json"
cat > "$TMP_ROOT/bin/treehouse" <<'MOCK'
#!/usr/bin/env bash
set -eu
[ "$#" = 3 ] && [ "$1" = destroy ] && [ "$3" = --yes ]
printf '%s\n' "$2" >> "$RECLAIM_CALLS"
case "$RECLAIM_MODE" in
  dirty) printf changed > "$2/untracked"; exit 1 ;;
  unmerged) git -C "$2" commit -q --allow-empty -m unlanded; exit 1 ;;
  leased|in-use) exit 1 ;;
  clean) git worktree remove "$2" ;;
  false-success) exit 0 ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$TMP_ROOT/bin/treehouse"
export PATH="$TMP_ROOT/bin:$PATH" RECLAIM_CALLS="$TMP_ROOT/calls"
for RECLAIM_MODE in clean dirty unmerged leased in-use false-success; do
  export RECLAIM_MODE
  wt="$TMP_ROOT/pool/1/project"
  git -C "$TMP_ROOT/project" worktree add -q --detach "$wt" main
  fm_treehouse_slot_owner_claim "$wt" task "$FM_HOME"
  fm_treehouse_reclaim_returned_slot "$TMP_ROOT/project" "$wt" task "$FM_HOME/data"
  receipt="$FM_HOME/data/task/reclamation"
  if [ "$RECLAIM_MODE" = clean ]; then
    [ ! -e "$wt" ]
    assert_grep 'status=reclaimed' "$receipt" 'missing reclaimed result'
    cp "$receipt" "$TMP_ROOT/saved-receipt"
    fm_treehouse_reclaim_returned_slot "$TMP_ROOT/project" "$wt" task "$FM_HOME/data"
    cmp "$receipt" "$TMP_ROOT/saved-receipt"
  else
    [ -d "$wt" ]
    assert_grep 'status=preserved' "$receipt" 'unsafe slot reported reclaimed'
    # Only discard this test-created fixture after checking preservation.
    git -C "$TMP_ROOT/project" worktree remove --force "$wt"
  fi
  pass "reclamation $RECLAIM_MODE"
done
for owner in absent other unsafe; do
  wt="$TMP_ROOT/pool/1/project"
  git -C "$TMP_ROOT/project" worktree add -q --detach "$wt" main
  rm -f "$TMP_ROOT/pool/1/.fm-slot-owner"
  case "$owner" in
    other) fm_treehouse_slot_owner_claim "$wt" another "$FM_HOME" ;;
    unsafe) printf invalid > "$TMP_ROOT/pool/1/.fm-slot-owner" ;;
  esac
  cp "$RECLAIM_CALLS" "$TMP_ROOT/saved-calls"
  fm_treehouse_reclaim_returned_slot "$TMP_ROOT/project" "$wt" task "$FM_HOME/data"
  cmp "$RECLAIM_CALLS" "$TMP_ROOT/saved-calls"
  [ -d "$wt" ]
  git -C "$TMP_ROOT/project" worktree remove "$wt"
  pass "reclamation preserves $owner ownership"
done
wt="$TMP_ROOT/pool/1/project"
git -C "$TMP_ROOT/project" worktree add -q --detach "$wt" main
fm_treehouse_slot_owner_claim "$wt" task "$FM_HOME"
rm "$FM_HOME/data/task/reclamation"
mkdir "$FM_HOME/data/task/reclamation"
cp "$RECLAIM_CALLS" "$TMP_ROOT/saved-calls"
if fm_treehouse_reclaim_returned_slot "$TMP_ROOT/project" "$wt" task "$FM_HOME/data"; then
  fail 'receipt failure unexpectedly succeeded'
fi
cmp "$RECLAIM_CALLS" "$TMP_ROOT/saved-calls"
[ -d "$wt" ]
pass 'receipt persistence failure preserves slot'
# A failure after deletion must not masquerade as a completed receipt.
rmdir "$FM_HOME/data/task/reclamation"
cat > "$TMP_ROOT/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -eu
if grep -q 'status=reclaimed' "$2"; then exit 1; fi
exec "$REAL_RECLAIM_MV" "$@"
MOCK
export REAL_RECLAIM_MV
REAL_RECLAIM_MV=$(command -v mv)
chmod +x "$TMP_ROOT/bin/mv"
hash -r
RECLAIM_MODE=clean
export RECLAIM_MODE
if fm_treehouse_reclaim_returned_slot "$TMP_ROOT/project" "$wt" task "$FM_HOME/data"; then
  fail 'final receipt persistence failure unexpectedly succeeded'
fi
[ ! -e "$wt" ]
assert_grep 'status=pending' "$FM_HOME/data/task/reclamation" 'lost incomplete receipt evidence'
pass 'post-delete receipt failure remains incomplete and loud'
