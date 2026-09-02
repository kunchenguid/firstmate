#!/usr/bin/env bash
# End-to-end proof that a benchmark entrant's enforced confinement really denies
# sibling access, run against a real confinement mechanism rather than a stub.
#
# The adversarial review's finding was that opaque labels, detached commits, and
# a transcript grep hide metadata but neither prevent nor detect sibling access:
# `git fsck --unreachable`, `git cat-file --batch-all-objects`, `.git/worktrees`,
# object-directory traversal, process inspection, and an ordinary file read all
# bypass the named patterns. This test runs exactly those bypasses inside the
# confinement and requires every one of them to be denied.
#
# It is gated on a mechanism that can actually enforce storage, filesystem, AND
# process isolation. tests/fm-bench-gate.test.sh carries the portable half: the
# probes detect a real leak, a denial with no positive control is refused, and
# partial confinement earns no partial credit.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFINE="$ROOT/bin/fm-bench-confine.sh"
GATE="$ROOT/bin/fm-bench-gate.sh"
IMAGE=${FM_BENCH_CONFINE_IMAGE:-debian:stable-slim}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

MECHANISM=
if command -v bwrap >/dev/null 2>&1; then
  MECHANISM=bwrap
else
  for runtime in docker podman; do
    if command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1 \
      && "$runtime" image inspect "$IMAGE" >/dev/null 2>&1; then
      MECHANISM=container
      break
    fi
  done
fi
[ -n "$MECHANISM" ] || { echo "skip: no enforcing confinement (bwrap, or a container runtime with $IMAGE)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-bench-isolation)
ISO="$TMP_ROOT/iso"
mkdir -p "$ISO/sealed"
printf 'K7 -> Fable 5 High\nR2 -> GPT 5.6 Sol High\n' > "$ISO/sealed/key.json"

# Two provisioned entrants, each a real repository with a detached candidate
# commit, a worktree registry, and an object database a sibling could mine.
for entrant in e1 e2; do
  mkdir -p "$ISO/$entrant/objects" "$ISO/$entrant/tmp" "$ISO/$entrant/home" "$ISO/$entrant/session"
  fm_git_init_commit "$ISO/$entrant" >/dev/null
  printf 'candidate answer from %s\n' "$entrant" > "$ISO/$entrant/answer.txt"
  git -C "$ISO/$entrant" add -A
  git -C "$ISO/$entrant" -c user.name=t -c user.email=t@x commit -qm "candidate work"
  # A detached commit, exactly the shape the design uses to hide a candidate:
  # unreachable from any branch, and recoverable by anyone with object access.
  git -C "$ISO/$entrant" -c user.name=t -c user.email=t@x commit -qm detached --allow-empty
  git -C "$ISO/$entrant" reset -q --hard HEAD~1
  mkdir -p "$ISO/$entrant/.git/worktrees/w"
done

python3 - "$TMP_ROOT/benchmark" "$CONFINE" "$MECHANISM" "$ISO" <<'PY'
import json, sys
from pathlib import Path

bench, confine, mechanism, iso = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
bench.mkdir(parents=True, exist_ok=True)
# The isolation gate reads only the plan's schema, so a minimal valid plan is
# enough here; the full plan contract is exercised in fm-bench-gate.test.sh.
(bench / "benchmark.json").write_text(json.dumps({
    "schema": "fm-bench-plan.v1", "benchmark_id": "isolation-e2e", "tracks": {}}, indent=2) + "\n")
(bench / "isolation.json").write_text(json.dumps({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [confine, "--mechanism", mechanism, "--allow", "{root}", "--"],
    "leak_marker": "FM_BENCH_",
    "protected_paths": [f"{iso}/sealed"],
    "entrants": [
        {"id": f"bench-b1-{label}", "root": f"{iso}/{name}",
         "private_object_store": f"{iso}/{name}/objects",
         "private_tmp": f"{iso}/{name}/tmp",
         "private_home": f"{iso}/{name}/home",
         "private_session": f"{iso}/{name}/session"}
        for label, name in (("k7", "e1"), ("r2", "e2"))],
}, indent=2, sort_keys=True) + "\n")
PY

out=$("$GATE" --bench "$TMP_ROOT/benchmark" --probe-timeout 180 isolation-verify 2>&1) \
  && status=0 || status=$?
expect_code 0 "$status" "enforced isolation ($MECHANISM) must deny every sibling-access probe"

for label in k7 r2; do
  for probe in sibling_file_read sibling_worktree_enumeration sibling_object_enumeration \
               sibling_unreachable_objects protected_path_read process_inspection environment_leakage; do
    assert_contains "$out" "isolation.bench-b1-$label.$probe ok" \
      "$MECHANISM must deny $probe for bench-b1-$label"
  done
done
# Each denial is only meaningful because the same probe reaches the target when
# nothing confines it; the gate proves that before trusting any denial.
assert_contains "$out" "which is reachable without the confinement" \
  "every denial carries its positive control"
assert_contains "$out" "all 7 probe classes exercised" "no probe class was skipped"
assert_not_contains "$out" "PROBE LEAKED" "nothing leaked through the confinement"
pass "enforced isolation ($MECHANISM) denies file, worktree, object, unreachable-object, sealed-material, process, and environment access"

# The confinement must not be a wall that also blocks the entrant's own work:
# an entrant that cannot read its own clone is not isolated, it is broken.
own=$("$CONFINE" --mechanism "$MECHANISM" --allow "$ISO/e1" -- \
  /bin/cat "$ISO/e1/answer.txt" 2>&1) || fail "the entrant must still read its own clone: $own"
assert_contains "$own" "candidate answer from e1" "the entrant reaches its own private clone"
pass "the same confinement still lets an entrant work in its own private clone"
