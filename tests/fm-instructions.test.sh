#!/usr/bin/env bash
# Public-interface and negative-control tests for progressive disclosure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-instructions)
FIXTURE="$TMP_ROOT/repo"

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

prepare_fixture() {
  rm -rf "$FIXTURE"
  git clone -q --shared "$ROOT" "$FIXTURE"
  cp "$ROOT/AGENTS.md" "$FIXTURE/AGENTS.md"
  rm -rf "$FIXTURE/.agents/skills" "$FIXTURE/.agents/prompt-roles"
  mkdir -p "$FIXTURE/.agents" "$FIXTURE/docs/verification"
  cp -R "$ROOT/.agents/skills" "$FIXTURE/.agents/skills"
  cp -R "$ROOT/.agents/prompt-roles" "$FIXTURE/.agents/prompt-roles"
  cp "$ROOT"/FIRSTMATE_*.md "$FIXTURE/"
  cp "$ROOT/docs/verification/prompt-disclosure-manifest.json" "$FIXTURE/docs/verification/"
  cp "$ROOT/docs/verification/prompt-disclosure-measurements.json" "$FIXTURE/docs/verification/"
  cp "$ROOT/docs/verification/prompt-disclosure.md" "$FIXTURE/docs/verification/"
  cp "$ROOT/docs/prompt-runtime.md" "$FIXTURE/docs/"
  cp "$ROOT/docs/verification/prompt-lineage.json" "$FIXTURE/docs/verification/"
  cp -R "$ROOT/docs/verification/prompt-preservation" "$FIXTURE/docs/verification/"
  cp "$ROOT/bin/fm-instructions.sh" "$ROOT/bin/fm-instructions-verify.py" \
    "$ROOT/bin/fm-instructions-generated-parity.sh" "$ROOT/bin/fm-prompt-compile.py" \
    "$FIXTURE/bin/"
}

verify_fixture_without_generated() {
  python3 "$FIXTURE/bin/fm-instructions-verify.py" --root "$FIXTURE" --skip-generated
}

rebind_fixture_manifest() {
  python3 - "$FIXTURE" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = root / "docs/verification/prompt-disclosure-manifest.json"
lineage = root / "docs/verification/prompt-lineage.json"
data = json.loads(lineage.read_text(encoding="utf-8"))
phase_one = next(item for item in data["generations"] if item["kind"] == "local-transformation")
phase_one["manifest_sha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
phase_one["manifest_object"] = subprocess.check_output(
    ["git", "hash-object", "--no-filters", str(manifest.relative_to(root))],
    cwd=root,
    text=True,
).strip()
lineage.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

test_public_interface() {
  local list output bundle
  list=$($TOOL list) || fail "fm-instructions list failed"
  [ "$list" = $'operational-home\ndispatch\nrecovery\nproject-knowledge\ntask-lifecycle\nbacklog\nbriefing' ] \
    || fail "fm-instructions list order changed"
  while IFS= read -r bundle; do
    output=$($TOOL "$bundle") || fail "fm-instructions $bundle failed"
    assert_contains "$output" "# Firstmate deferred instructions: $bundle" \
      "bundle $bundle omitted its identity"
    printf '%s\n' "$output" | grep -Eq '(Current authoritative upstream-derived|Verbatim preserved baseline) block starts' \
      || fail "bundle $bundle omitted its authority boundary"
  done <<< "$list"
  run_expect_failure "unknown command or bundle" "$TOOL" missing-bundle
  pass "fm-instructions public interface lists, reads, and rejects deterministically"
}

test_measurement_interface() {
  local help
  help=$("$ROOT/bin/fm-instructions-measure.py" --help) \
    || fail "measurement interface help failed without optional tokenizer setup"
  assert_contains "$help" "--timing-runs" "measurement help omitted timing control"
  assert_contains "$help" "--output" "measurement help omitted artifact output"
  run_expect_failure "--timing-runs must be at least 1" \
    "$ROOT/bin/fm-instructions-measure.py" --timing-runs 0
  pass "measurement interface documents inputs and rejects invalid timing counts"
}

test_repository_verification() {
  local out
  out=$($TOOL verify) || fail "repository preservation verification failed: $out"
  assert_contains "$out" "PASS preservation: 286 changed/removed physical lines" \
    "verification omitted complete changed-line accounting"
  assert_contains "$out" "ok generated briefs ship/scout/secondmate" \
    "verification omitted generated brief parity"
  pass "fm-instructions verifies preservation, reachability, links, and generated parity"
}

test_negative_unmapped_line() {
  prepare_fixture
  python3 - "$FIXTURE/docs/verification/prompt-disclosure-manifest.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); data=json.loads(path.read_text()); data['entries'].pop(0)
path.write_text(json.dumps(data,indent=2)+'\n')
PY
  rebind_fixture_manifest
  run_expect_failure "unmapped changed baseline line" verify_fixture_without_generated
  pass "preservation verifier rejects an unmapped changed line"
}

test_negative_duplicate_owner() {
  prepare_fixture
  python3 - "$FIXTURE/docs/verification/prompt-disclosure-manifest.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["entries"].append(dict(data["entries"][0]))
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  rebind_fixture_manifest
  run_expect_failure "duplicate source ownership" verify_fixture_without_generated
  pass "preservation verifier rejects duplicate ownership"
}

test_negative_non_verbatim_destination() {
  prepare_fixture
  python3 - "$FIXTURE/FIRSTMATE_BACKLOG.md" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("`data/backlog.md` is the durable queue.", "The backlog is altered.", 1), encoding="utf-8")
PY
  run_expect_failure "live authority bytes changed" verify_fixture_without_generated
  pass "preservation verifier rejects changed current authority bytes"
}

test_negative_refreshed_live_hash() {
  prepare_fixture
  python3 - "$FIXTURE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
path = root / "FIRSTMATE_BACKLOG.md"
text = path.read_text(encoding="utf-8")
path.write_text(
    text.replace("`data/backlog.md` is the durable queue.", "The durable queue instruction was removed.", 1),
    encoding="utf-8",
)
lineage = root / "docs/verification/prompt-lineage.json"
data = json.loads(lineage.read_text(encoding="utf-8"))
data["live_authority_sha256"]["FIRSTMATE_BACKLOG.md"] = hashlib.sha256(path.read_bytes()).hexdigest()
lineage.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  run_expect_failure "fixed live-authority binding" verify_fixture_without_generated
  pass "preservation verifier rejects changed authority despite a refreshed live hash"
}

test_negative_coordinated_live_authority_refresh() {
  prepare_fixture
  python3 - "$FIXTURE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
path = root / "AGENTS.md"
text = path.read_text(encoding="utf-8")
path.write_text(
    text.replace("Every runtime must obtain the exact argument-bound receipt from `bin/fm-operation-disclosure.py disclose` before spawn, merge, cleanup, or lifecycle control; each mutating owner consumes it before side effects.\n", ""),
    encoding="utf-8",
)
lineage = root / "docs/verification/prompt-lineage.json"
data = json.loads(lineage.read_text(encoding="utf-8"))
data["live_authority_sha256"]["AGENTS.md"] = hashlib.sha256(path.read_bytes()).hexdigest()
lineage.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  run_expect_failure "fixed live-authority binding" verify_fixture_without_generated
  pass "preservation verifier rejects coordinated live-authority hash refreshes"
}

test_negative_refreshed_upstream_artifact() {
  prepare_fixture
  python3 - "$FIXTURE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
needle = "`data/backlog.md` is the durable queue."
lineage = root / "docs/verification/prompt-lineage.json"
data = json.loads(lineage.read_text(encoding="utf-8"))
overlay = next(item for item in data["generations"] if item.get("kind") == "live-overlay")
artifact = root / overlay["upstream_artifact"]
artifact.write_text(artifact.read_text(encoding="utf-8").replace(needle, "Removed durable instruction.", 1), encoding="utf-8")
overlay["upstream_artifact_sha256"] = hashlib.sha256(artifact.read_bytes()).hexdigest()
lineage.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  run_expect_failure "fixed upstream preservation artifact" verify_fixture_without_generated
  pass "preservation verifier rejects coordinated live and upstream hash refreshes"
}

test_self_contained_preservation_without_upstream_object() {
  prepare_fixture
  rm -rf "$FIXTURE/.git"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.name test
  git -C "$FIXTURE" config user.email test@example.invalid
  git -C "$FIXTURE" add .
  git -C "$FIXTURE" commit -qm fixture
  upstream=$(python3 - "$FIXTURE/docs/verification/prompt-lineage.json" <<'PY'
import json,sys
print(next(item for item in json.load(open(sys.argv[1]))['generations'] if item['kind']=='live-overlay')['upstream_commit'])
PY
)
  if git -C "$FIXTURE" cat-file -e "$upstream^{commit}" 2>/dev/null; then
    fail "isolated preservation fixture unexpectedly contains the upstream commit"
  fi
  verify_fixture_without_generated >/dev/null \
    || fail "self-contained preservation verification required the upstream Git object"
  pass "preservation verifier uses the hashed upstream artifact without Git history"
}

test_self_contained_generated_parity_without_upstream_object() {
  local out
  prepare_fixture
  rm -rf "$FIXTURE/.git"
  out=$("$FIXTURE/bin/fm-instructions-generated-parity.sh") \
    || fail "generated parity required the fixed upstream Git object: $out"
  assert_contains "$out" "ok generated briefs ship/scout/secondmate" \
    "self-contained generated parity omitted brief verification"
  pass "generated parity uses the fixed tracked archive without Git history"
}

test_negative_dead_trigger() {
  prepare_fixture
  python3 - "$FIXTURE/docs/verification/prompt-disclosure-manifest.json" <<'PY'
import json,sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
bundle = data["entries"][0]["bundle"]
for entry in data["entries"]:
    if entry["bundle"] == bundle:
        entry["trigger_stub_exact_text"] = "This trigger is absent from the emitted prompt."
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  rebind_fixture_manifest
  run_expect_failure "emitted prompt is missing or duplicates trigger stub" verify_fixture_without_generated
  pass "preservation verifier rejects a missing trigger before accepting disclosure"
}

test_negative_broken_link() {
  prepare_fixture
  python3 - "$FIXTURE/docs/verification/prompt-disclosure.md" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("](prompt-disclosure-measurements.json)", "](missing-evidence.json)", 1), encoding="utf-8")
PY
  run_expect_failure "broken local link" verify_fixture_without_generated
  pass "preservation verifier rejects a broken local link"
}

test_negative_generated_behavior() {
  prepare_fixture
  # shellcheck disable=SC2016 # Variables expand in the generated fixture script, not this test shell.
  printf '%s\n' 'printf "changed generated brief\n" >> "$FM_HOME/data/$1/brief.md"' >> "$FIXTURE/bin/fm-brief.sh"
  run_expect_failure "changed generated prompt behavior" "$FIXTURE/bin/fm-instructions.sh" verify
  pass "preservation verifier rejects changed generated prompt behavior"
}

test_negative_committed_generated_behavior() {
  prepare_fixture
  git -C "$FIXTURE" config user.name test
  git -C "$FIXTURE" config user.email test@example.invalid
  # shellcheck disable=SC2016 # Variables expand in the generated fixture script, not this test shell.
  printf '%s\n' 'printf "committed generated drift\n" >> "$FM_HOME/data/$1/brief.md"' >> "$FIXTURE/bin/fm-brief.sh"
  git -C "$FIXTURE" add bin/fm-brief.sh
  git -C "$FIXTURE" commit -qm 'generated behavior drift'
  printf 'later gate follow-up\n' > "$FIXTURE/gate-follow-up.txt"
  git -C "$FIXTURE" add gate-follow-up.txt
  git -C "$FIXTURE" commit -qm 'later gate follow-up'
  run_expect_failure "changed generated prompt behavior" "$FIXTURE/bin/fm-instructions.sh" verify
  pass "preservation verifier rejects committed drift behind a later commit"
}

test_negative_descendant_semantic_producer() {
  prepare_fixture
  python3 - "$FIXTURE/docs/verification/prompt-lineage.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["semantic_refresh"]["overlay"] = data["semantic_refresh_review"]["reviewer_overlay"]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  run_expect_failure "producer is a descendant" verify_fixture_without_generated
  pass "semantic refresh rejects descendant commits claimed as candidate producers"
}

test_negative_mutable_generated_baseline() {
  prepare_fixture
  fixture_head=$(git -C "$FIXTURE" rev-parse HEAD)
  python3 - "$FIXTURE" "$fixture_head" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
lineage = root / "docs/verification/prompt-lineage.json"
artifact = root / "docs/verification/prompt-preservation/upstream/AGENTS.md.txt"
artifact.write_bytes((root / "AGENTS.md").read_bytes())
data = json.loads(lineage.read_text(encoding="utf-8"))
live = next(item for item in data["generations"] if item["kind"] == "live-overlay")
live["upstream_commit"] = sys.argv[2]
live["upstream_artifact_sha256"] = hashlib.sha256(artifact.read_bytes()).hexdigest()
lineage.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  run_expect_failure "fixed upstream baseline" "$FIXTURE/bin/fm-instructions-generated-parity.sh"
  pass "generated parity rejects a self-selected mutable upstream baseline"
}

test_public_interface
test_measurement_interface
test_repository_verification
test_negative_unmapped_line
test_negative_duplicate_owner
test_negative_non_verbatim_destination
test_negative_refreshed_live_hash
test_negative_coordinated_live_authority_refresh
test_negative_refreshed_upstream_artifact
test_self_contained_preservation_without_upstream_object
test_self_contained_generated_parity_without_upstream_object
test_negative_dead_trigger
test_negative_broken_link
test_negative_generated_behavior
test_negative_committed_generated_behavior
test_negative_descendant_semantic_producer
test_negative_mutable_generated_baseline
