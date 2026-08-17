#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
fail() { echo "not ok - $*" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
lineage = json.loads((root / "docs/verification/prompt-lineage.json").read_text())
upstream = subprocess.check_output(["git", "show", "-s", "--format=%P", "HEAD"], cwd=root, text=True).strip()
if len(upstream.split()) != 1:
    raise SystemExit("installed overlay is not a single-parent commit")
changed = set(subprocess.check_output(
    ["git", "diff", "--name-only", upstream, "HEAD", "--"], cwd=root, text=True
).splitlines())
missing = sorted(changed - set(lineage["overlay_paths"]))
if missing:
    raise SystemExit(f"unregistered final overlay path: {missing[0]}")
PY

git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
printf 'base\n' > "$REPO/registered.txt"
printf 'base converged\n' > "$REPO/converged.txt"
printf 'base unrelated\n' > "$REPO/unrelated.txt"
printf 'authority base\n' > "$REPO/authoritative.txt"
printf 'overlay-doc base\nupstream-doc base\n' > "$REPO/shared-doc.txt"
cat > "$REPO/lineage.json" <<'EOF'
{"schema_version":4,"generations":[{"generation":0},{"generation":1,"kind":"live-overlay","upstream_commit":"0000000000000000000000000000000000000000"}],"overlay_paths":["authoritative.txt","converged.txt","lineage.json","registered.txt","shared-doc.txt","tool.sh"],"disjoint_merge_paths":["shared-doc.txt"]}
EOF
git -C "$REPO" add . && git -C "$REPO" commit -qm base
base=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -qc overlay
printf 'overlay\n' > "$REPO/registered.txt"
printf 'shared correction\n' > "$REPO/converged.txt"
printf 'authority overlay\n' > "$REPO/authoritative.txt"
printf 'overlay-doc changed\nupstream-doc base\n' > "$REPO/shared-doc.txt"
printf '#!/bin/sh\nexit 0\n' > "$REPO/tool.sh"
chmod +x "$REPO/tool.sh"
git -C "$REPO" add . && git -C "$REPO" commit -qm overlay
overlay=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q --detach "$base"
printf 'upstream unrelated\n' > "$REPO/unrelated.txt"
printf 'shared correction\n' > "$REPO/converged.txt"
printf 'authority upstream\n' > "$REPO/authoritative.txt"
printf 'overlay-doc base\nupstream-doc changed\n' > "$REPO/shared-doc.txt"
git -C "$REPO" add . && git -C "$REPO" commit -qm upstream
upstream=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q overlay
python3 - "$REPO/lineage.json" "$base" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["generations"][1]["upstream_commit"] = sys.argv[2]
authority = path.with_name("authoritative.txt").read_bytes()
data["live_authority_sha256"] = {"authoritative.txt": hashlib.sha256(authority).hexdigest()}
path.write_text(json.dumps(data) + "\n", encoding="utf-8")
PY
git -C "$REPO" add lineage.json && git -C "$REPO" commit -qm 'bind upstream baseline'
overlay=$(git -C "$REPO" rev-parse HEAD)
(
  cd "$REPO"
  python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$upstream" --overlay "$overlay" --lineage lineage.json --output "$TMP/plan.json" >/dev/null
)
git_dir=$(git -C "$REPO" rev-parse --absolute-git-dir)
git_state_snapshot() {
  shasum -a 256 "$git_dir/index"
  find "$git_dir/objects" "$git_dir/refs" -type f -exec shasum -a 256 {} \;
  if [ -f "$git_dir/packed-refs" ]; then
    shasum -a 256 "$git_dir/packed-refs"
  fi
}
touch -t 200001010000 "$REPO/registered.txt"
git_state_snapshot | sort > "$TMP/git-before"
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/missing-owner >/dev/null 2>&1); then
  fail "absent disclosure owner authorized an overlay rebuild"
fi
git_state_snapshot | sort > "$TMP/git-after"
cmp -s "$TMP/git-before" "$TMP/git-after" || fail "absent disclosure owner mutated Git state"

mkdir -p "$REPO/bin"
printf '/bin/\n' >> "$git_dir/info/exclude"
cat > "$REPO/bin/fm-operation-disclosure.py" <<'PY'
import json
import os
import sys
from pathlib import Path

Path(os.environ["DISCLOSURE_LOG"]).write_text(json.dumps(sys.argv[1:]))
raise SystemExit(0 if os.environ.get("DISCLOSURE_ALLOW") == "1" else 2)
PY
touch -t 200101010000 "$REPO/registered.txt"
git_state_snapshot | sort > "$TMP/git-before"
if (cd "$REPO" && DISCLOSURE_LOG="$TMP/disclosure.json" python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/refused >/dev/null 2>&1); then
  fail "refused disclosure authorized an overlay rebuild"
fi
git_state_snapshot | sort > "$TMP/git-after"
cmp -s "$TMP/git-before" "$TMP/git-after" || fail "refused disclosure mutated Git state"
(
  cd "$REPO"
  DISCLOSURE_ALLOW=1 DISCLOSURE_LOG="$TMP/disclosure.json" python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/test >/dev/null
  verify=$(python3 "$ROOT/bin/fm-prompt-overlay.py" verify --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/test)
  token=${verify##*token=}
  python3 "$ROOT/bin/fm-prompt-overlay.py" ready --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/test --token "$token" >/dev/null
)
python3 - "$TMP/disclosure.json" "$TMP/plan.json" <<'PY'
import json
import sys

actual = json.load(open(sys.argv[1]))
candidate_ref = "refs/firstmate/overlays/candidates/test"
expected = ["consume", "overlay-rebuild", candidate_ref, "--", "rebuild", "--plan", sys.argv[2], "--candidate-ref", candidate_ref]
if actual != expected:
    raise SystemExit(f"disclosure arguments differ: {actual!r}")
PY
candidate=$(git -C "$REPO" rev-parse refs/firstmate/overlays/candidates/test)
[ "$(git -C "$REPO" show -s --format=%P "$candidate")" = "$upstream" ] || fail "candidate parent is not exact upstream"
[ "$(git -C "$REPO" show "$candidate:registered.txt")" = overlay ] || fail "overlay owner was not rebuilt"
[ "$(git -C "$REPO" show "$candidate:converged.txt")" = 'shared correction' ] || fail "converged overlay owner was reclassified as upstream-owned"
[ "$(git -C "$REPO" show "$candidate:authoritative.txt")" = 'authority overlay' ] || fail "hash-bound live owner did not survive an upstream edit"
[ "$(git -C "$REPO" show "$candidate:shared-doc.txt")" = $'overlay-doc changed\nupstream-doc changed' ] || fail "disjoint owner edits were not both preserved"
[ "$(git -C "$REPO" show "$candidate:unrelated.txt")" = 'upstream unrelated' ] || fail "upstream owner was not preserved"
[ "$(git -C "$REPO" ls-tree "$candidate" tool.sh | awk '{print $1}')" = 100755 ] || fail "executable mode was lost"

# Ownership is measured from the true shared Git base, not the older semantic
# provenance baseline. This leaves an inherited workflow edit upstream-owned,
# supports multiple local overlay commits, and composes a later same-file
# upstream edit without treating the inherited line as local overlay work.
HISTORY_REPO="$TMP/history-repo"
git init -q "$HISTORY_REPO"
git -C "$HISTORY_REPO" config user.name test
git -C "$HISTORY_REPO" config user.email test@example.invalid
mkdir -p "$HISTORY_REPO/.github/workflows" "$HISTORY_REPO/bin"
printf 'jobs:\n  behavior:\n    timeout-minutes: 10\n  pointers:\n    legacy: true\n' > "$HISTORY_REPO/.github/workflows/ci.yml"
printf 'base\n' > "$HISTORY_REPO/owned.txt"
printf 'import sys\nraise SystemExit(0)\n' > "$HISTORY_REPO/bin/fm-operation-disclosure.py"
cat > "$HISTORY_REPO/lineage.json" <<'EOF'
{"schema_version":4,"generations":[{"generation":0},{"generation":1,"kind":"live-overlay","upstream_commit":"0000000000000000000000000000000000000000"}],"overlay_paths":["bin/fm-operation-disclosure.py","lineage.json","owned.txt"]}
EOF
git -C "$HISTORY_REPO" add . && git -C "$HISTORY_REPO" commit -qm semantic-baseline
semantic_base=$(git -C "$HISTORY_REPO" rev-parse HEAD)
printf 'jobs:\n  behavior:\n    timeout-minutes: 20\n  pointers:\n    legacy: true\n' > "$HISTORY_REPO/.github/workflows/ci.yml"
git -C "$HISTORY_REPO" add . && git -C "$HISTORY_REPO" commit -qm inherited-upstream-timeout
shared_base=$(git -C "$HISTORY_REPO" rev-parse HEAD)
git -C "$HISTORY_REPO" switch -qc local-overlay
python3 - "$HISTORY_REPO/lineage.json" "$semantic_base" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["generations"][1]["upstream_commit"] = sys.argv[2]
path.write_text(json.dumps(data) + "\n")
PY
printf 'overlay one\n' > "$HISTORY_REPO/owned.txt"
git -C "$HISTORY_REPO" add . && git -C "$HISTORY_REPO" commit -qm overlay-one
printf 'overlay two\n' > "$HISTORY_REPO/owned.txt"
git -C "$HISTORY_REPO" add . && git -C "$HISTORY_REPO" commit -qm overlay-two
overlay_tip=$(git -C "$HISTORY_REPO" rev-parse HEAD)
git -C "$HISTORY_REPO" switch -q --detach "$shared_base"
printf 'jobs:\n  behavior:\n    timeout-minutes: 20\n  pointers:\n    claude-md: pointer\n' > "$HISTORY_REPO/.github/workflows/ci.yml"
git -C "$HISTORY_REPO" add . && git -C "$HISTORY_REPO" commit -qm target-upstream-pointer
target_upstream=$(git -C "$HISTORY_REPO" rev-parse HEAD)
git -C "$HISTORY_REPO" switch -q local-overlay
(
  cd "$HISTORY_REPO"
  python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$semantic_base" --upstream "$target_upstream" --overlay "$overlay_tip" --lineage lineage.json --output "$TMP/history-plan.json" >/dev/null
)
python3 - "$TMP/history-plan.json" "$shared_base" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
if plan["ownership_base"] != sys.argv[2]:
    raise SystemExit("plan did not bind the true shared Git base")
record = next(item for item in plan["records"] if item["path"] == ".github/workflows/ci.yml")
if record["classification"] != "upstream-owner":
    raise SystemExit(f"inherited workflow edit classified as {record['classification']}")
if plan["ambiguous"]:
    raise SystemExit(f"history-aware plan remained ambiguous: {plan['ambiguous']}")
PY
(
  cd "$HISTORY_REPO"
  DISCLOSURE_ALLOW=1 DISCLOSURE_LOG="$TMP/history-disclosure.json" python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/history-plan.json" --candidate-ref refs/firstmate/overlays/candidates/history >/dev/null
)
history_candidate=$(git -C "$HISTORY_REPO" rev-parse refs/firstmate/overlays/candidates/history)
[ "$(git -C "$HISTORY_REPO" show "$history_candidate:owned.txt")" = 'overlay two' ] || fail "multi-commit overlay tip was not preserved"
[ "$(git -C "$HISTORY_REPO" show "$history_candidate:.github/workflows/ci.yml")" = $'jobs:\n  behavior:\n    timeout-minutes: 20\n  pointers:\n    claude-md: pointer' ] || fail "upstream-only workflow change was not preserved"

# Criss-cross histories have more than one best shared base and therefore do
# not provide one unambiguous ownership baseline.
CRISS_REPO="$TMP/criss-repo"
git init -q "$CRISS_REPO"
git -C "$CRISS_REPO" config user.name test
git -C "$CRISS_REPO" config user.email test@example.invalid
printf 'base\n' > "$CRISS_REPO/owned.txt"
cat > "$CRISS_REPO/lineage.json" <<'EOF'
{"schema_version":4,"generations":[{"generation":0},{"generation":1,"kind":"live-overlay","upstream_commit":"0000000000000000000000000000000000000000"}],"overlay_paths":["lineage.json","owned.txt"]}
EOF
git -C "$CRISS_REPO" add . && git -C "$CRISS_REPO" commit -qm base
criss_base=$(git -C "$CRISS_REPO" rev-parse HEAD)
criss_tree=$(git -C "$CRISS_REPO" show -s --format=%T "$criss_base")
left=$(printf 'left\n' | git -C "$CRISS_REPO" commit-tree "$criss_tree" -p "$criss_base")
right=$(printf 'right\n' | git -C "$CRISS_REPO" commit-tree "$criss_tree" -p "$criss_base")
merge_left=$(printf 'merge-left\n' | git -C "$CRISS_REPO" commit-tree "$criss_tree" -p "$left" -p "$right")
merge_right=$(printf 'merge-right\n' | git -C "$CRISS_REPO" commit-tree "$criss_tree" -p "$right" -p "$left")
git -C "$CRISS_REPO" switch -q --detach "$merge_left"
python3 - "$CRISS_REPO/lineage.json" "$criss_base" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["generations"][1]["upstream_commit"] = sys.argv[2]
path.write_text(json.dumps(data) + "\n")
PY
git -C "$CRISS_REPO" add lineage.json && git -C "$CRISS_REPO" commit -qm overlay
overlay_criss=$(git -C "$CRISS_REPO" rev-parse HEAD)
if criss_out=$(cd "$CRISS_REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$criss_base" --upstream "$merge_right" --overlay "$overlay_criss" --lineage lineage.json --output "$TMP/criss.json" 2>&1); then
  fail "multiple shared Git bases were accepted"
fi
case "$criss_out" in
  *"exactly one shared Git base"*) ;;
  *) fail "ambiguous shared-base refusal was not reported: $criss_out" ;;
esac

git -C "$REPO" update-ref refs/heads/main refs/heads/overlay
main_before=$(git -C "$REPO" rev-parse refs/heads/main)
git -C "$REPO" symbolic-ref refs/firstmate/overlays/candidates/symbolic refs/heads/main
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/symbolic >/dev/null 2>&1); then
  fail "symbolic candidate ref was accepted"
fi
[ "$(git -C "$REPO" rev-parse refs/heads/main)" = "$main_before" ] || fail "symbolic candidate ref moved main"
[ "$(git -C "$REPO" symbolic-ref refs/firstmate/overlays/candidates/symbolic)" = refs/heads/main ] \
  || fail "refused symbolic candidate ref was replaced"

# Planning refuses a lineage baseline that does not bind the previous upstream.
git -C "$REPO" switch -qc stale-binding
python3 - "$REPO/lineage.json" "$upstream" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["generations"][1]["upstream_commit"] = sys.argv[2]
path.write_text(json.dumps(data) + "\n", encoding="utf-8")
PY
git -C "$REPO" add lineage.json && git -C "$REPO" commit -qm 'stale upstream binding'
stale_overlay=$(git -C "$REPO" rev-parse HEAD)
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$upstream" --overlay "$stale_overlay" --lineage lineage.json --output "$TMP/stale.json" >/dev/null 2>&1); then
  fail "stale generated-parity baseline was accepted"
fi

# Planning refuses a tracked inventory that differs from the selected overlay.
git -C "$REPO" switch -qc mismatched-lineage
printf '\n' >> "$REPO/lineage.json"
git -C "$REPO" add lineage.json && git -C "$REPO" commit -qm 'mismatched lineage'
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$upstream" --overlay "$overlay" --lineage lineage.json --output "$TMP/mismatch.json" >/dev/null 2>&1); then
  fail "lineage graph outside the overlay commit was accepted"
fi

git -C "$REPO" show "$overlay:lineage.json" > "$TMP/external-lineage.json"
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$upstream" --overlay "$overlay" --lineage "$TMP/external-lineage.json" --output "$TMP/external.json" >/dev/null 2>&1); then
  fail "lineage graph outside the repository was accepted"
fi

# Divergent edits to one semantic owner are classified and refused, never auto-resolved.
git -C "$REPO" switch -q --detach "$base"
printf 'upstream conflict\n' > "$REPO/registered.txt"
git -C "$REPO" add . && git -C "$REPO" commit -qm conflict
conflict=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -qc overlay-conflict "$overlay"
conflict_overlay=$(git -C "$REPO" rev-parse HEAD)
(
  cd "$REPO"
  python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$conflict" --overlay "$conflict_overlay" --lineage lineage.json --output "$TMP/conflict.json" >/dev/null
  if python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/conflict.json" --candidate-ref refs/firstmate/overlays/candidates/conflict >/dev/null 2>&1; then
    fail "ambiguous semantic owner was rebuilt"
  fi
)

# Dirty input, malformed policy, stale token, and unregistered local changes refuse.
printf dirty > "$REPO/dirty"
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$conflict" --overlay "$overlay" --lineage lineage.json --output "$TMP/dirty.json" >/dev/null 2>&1); then
  fail "dirty input was accepted"
fi
rm "$REPO/dirty"
python3 - "$TMP/plan.json" "$TMP/malformed.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); v['resolution_policy']='ours'; json.dump(v,open(sys.argv[2],'w'))
PY
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/malformed.json" --candidate-ref refs/firstmate/overlays/candidates/bad >/dev/null 2>&1); then
  fail "automatic ours/theirs policy was accepted"
fi
python3 - "$TMP/plan.json" "$TMP/missing-object.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for item in v['records']:
    if item['classification']=='overlay-owner' and item['overlay']:
        item['overlay']['oid']='0'*40
        break
json.dump(v,open(sys.argv[2],'w'))
PY
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/missing-object.json" --candidate-ref refs/firstmate/overlays/candidates/missing >/dev/null 2>&1); then
  fail "missing overlay object was accepted"
fi
python3 - "$TMP/plan.json" "$TMP/mutable-plan.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for item in v['records']:
    if item['classification']=='overlay-owner':
        item['classification']='upstream-owner'
        break
json.dump(v,open(sys.argv[2],'w'))
PY
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" rebuild --plan "$TMP/mutable-plan.json" --candidate-ref refs/firstmate/overlays/candidates/mutable >/dev/null 2>&1); then
  fail "mutated overlay ownership plan was accepted"
fi
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" ready --plan "$TMP/plan.json" --candidate-ref refs/firstmate/overlays/candidates/test --token deadbeef >/dev/null 2>&1); then
  fail "stale readiness token was accepted"
fi

git -C "$REPO" switch -q --detach "$base"
printf local > "$REPO/unregistered.txt"
git -C "$REPO" add . && git -C "$REPO" commit -qm unregistered
bad_overlay=$(git -C "$REPO" rev-parse HEAD)
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$base" --upstream "$upstream" --overlay "$bad_overlay" --lineage lineage.json --output "$TMP/unregistered.json" >/dev/null 2>&1); then
  fail "unregistered local commit was accepted"
fi
other="$TMP/other"
git init -q "$other"
git -C "$other" config user.name test
git -C "$other" config user.email test@example.invalid
printf other > "$other/file" && git -C "$other" add file && git -C "$other" commit -qm other
unrelated=$(git -C "$other" rev-parse HEAD)
git -C "$REPO" fetch -q "$other" "$unrelated"
if (cd "$REPO" && python3 "$ROOT/bin/fm-prompt-overlay.py" check --previous-upstream "$unrelated" --upstream "$upstream" --overlay "$overlay" --lineage lineage.json --output "$TMP/graph.json" >/dev/null 2>&1); then
  fail "malformed unrelated graph was accepted"
fi

echo "ok isolated overlay rebuild, modes, exact bindings, and safety refusals"
