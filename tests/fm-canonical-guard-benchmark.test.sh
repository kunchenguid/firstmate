#!/usr/bin/env bash
# Hermetic contract tests for the canonical-guard benchmark harness.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BENCH="$ROOT/bin/fm-canonical-guard-benchmark.sh"
TMP_ROOT=$(fm_test_tmproot fm-cgb)
SOURCE="$TMP_ROOT/source"
WORKSPACE="$TMP_ROOT/workspace"
FAKEBIN="$TMP_ROOT/fakebin"

assert_present "$BENCH" "canonical-guard benchmark harness missing"
[ -x "$BENCH" ] || fail "canonical-guard benchmark harness must be executable"
jq -e '.["$id"] == "https://github.com/pedromuller-del/firstmate/schemas/canonical-guard-run-manifest-v1.json"' \
  "$ROOT/scripts/canonical-guard-benchmark/manifest.schema.json" >/dev/null \
  || fail "manifest schema id does not name this repository"
mkdir -p "$SOURCE/packages/backend/api/logic" \
  "$SOURCE/packages/frontend/scripts/canonical" \
  "$SOURCE/.agents/rules" "$FAKEBIN"

git -C "$SOURCE" init -q -b dev
git -C "$SOURCE" config user.email benchmark@example.invalid
git -C "$SOURCE" config user.name Benchmark
cat >"$SOURCE/lefthook.yml" <<'YAML'
pre-push:
  commands:
    canonical-boundaries:
      # Fixture comment one.
      # Fixture comment two.
      # Fixture comment three.
      # Fixture comment four.
      run: pnpm check:canonical
    tests:
      run: pnpm test
YAML
cat >"$SOURCE/package.json" <<'JSON'
{"scripts":{"check:canonical":"node check.js"}}
JSON
cat >"$SOURCE/AGENTS.md" <<'MD'
# Fixture instructions

Canonical failures route to `.agents/rules/canonical-boundaries.md`.
MD
printf 'Reuse existing helpers.\n' >"$SOURCE/.agents/rules/canonical-boundaries.md"
printf '// fixture detector\n' >"$SOURCE/packages/frontend/scripts/canonical/check-canonical.ts"
cat >"$SOURCE/packages/backend/api/logic/donor.ts" <<'TS'
function pointToSegmentDistance(p: [number, number], a: [number, number], b: [number, number]): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const lenSq = dx * dx + dy * dy;
  if (lenSq === 0) return Math.hypot(p[0] - a[0], p[1] - a[1]);
  let t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / lenSq;
  if (t < 0) t = 0;
  else if (t > 1) t = 1;
  const cx = a[0] + t * dx;
  const cy = a[1] + t * dy;
  return Math.hypot(p[0] - cx, p[1] - cy);
}
TS
git -C "$SOURCE" add -A
git -C "$SOURCE" commit -q -m fixture
BASE_SHA=$(git -C "$SOURCE" rev-parse HEAD)

cat >"$FAKEBIN/pnpm" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  install|--filter) exit 0 ;;
  exec)
    mkdir -p .git/hooks
    cat >.git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
pnpm check:canonical
HOOK
    chmod +x .git/hooks/pre-push
    ;;
  check:canonical)
    if grep -q '"check:canonical":"exit 0"' package.json 2>/dev/null; then
      exit 0
    fi
    if [ -f packages/backend/api/logic/canonical-benchmark-verbatim.ts ]; then
      printf 'canonical-boundaries: duplicate implementation detected\n'
      printf 'Remediation: import the existing pointToSegmentDistance helper instead of copying it.\n'
      exit 1
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/pnpm"

PATH="$FAKEBIN:$PATH" "$BENCH" init \
  --workspace "$WORKSPACE" --source "$SOURCE" --ref "$BASE_SHA"

[ -d "$WORKSPACE/mirror.git" ] || fail "init did not create a bare mirror"
[ "$(git -C "$WORKSPACE/mirror.git" rev-parse --is-bare-repository)" = true ] \
  || fail "mirror is not bare"
[ -z "$(git -C "$WORKSPACE/mirror.git" remote 2>/dev/null)" ] \
  || fail "mirror retained a network-capable remote"
git -C "$WORKSPACE/template-guard-on" rev-parse --verify origin/dev >/dev/null \
  || fail "template cannot resolve the detector's origin/dev base"
[ "$(git -C "$WORKSPACE/mirror.git" for-each-ref --format='%(refname)')" = 'refs/heads/dev' ] \
  || fail "candidate origin exposes setup or prior-run refs"
for arm in guard-on guard-off; do
  ! git -C "$WORKSPACE/template-$arm" branch -a | grep -Eiq 'benchmark|guard-on|guard-off|template' \
    || fail "$arm template exposes an arm or setup branch"
  [ -z "$(git -C "$WORKSPACE/template-$arm" log --format='%s' "$BASE_SHA..HEAD")" ] \
    || fail "$arm template exposes setup commits"
  [ -z "$(git -C "$WORKSPACE/template-$arm" reflog --all)" ] \
    || fail "$arm template exposes setup surgery in its reflog"
done
[ -x "$WORKSPACE/template-guard-on/.git/hooks/pre-push" ] \
  || fail "GUARD-ON template did not install lefthook"
[ -x "$WORKSPACE/template-guard-off/.git/hooks/pre-push" ] \
  || fail "GUARD-OFF template did not install lefthook"
git -C "$WORKSPACE/template-guard-on" diff --quiet \
  "$(git -C "$WORKSPACE/template-guard-on" rev-parse HEAD)" -- \
  || fail "GUARD-ON template is dirty"
git -C "$WORKSPACE/template-guard-off" diff --quiet \
  "$(git -C "$WORKSPACE/template-guard-off" rev-parse HEAD)" -- \
  || fail "GUARD-OFF template is dirty"
TREE_DIFF="$TMP_ROOT/template.diff"
git diff --no-index -- "$WORKSPACE/template-guard-on/lefthook.yml" \
  "$WORKSPACE/template-guard-off/lefthook.yml" >"$TREE_DIFF" || true
assert_grep 'canonical-boundaries:' "$TREE_DIFF" "arm diff omitted the canonical command"
if grep -E '^[+-][^+-]' "$TREE_DIFF" | grep -vE '^-(    canonical-boundaries:|      # Fixture comment (one|two|three|four)\.|      run: pnpm check:canonical)$' >/dev/null; then
  fail "arm templates differ by more than the canonical command block"
fi
pass "init creates a local mirror and fully installed one-deletion templates"

PATH="$FAKEBIN:$PATH" "$BENCH" fixture-check --workspace "$WORKSPACE"
FIXTURE_RESULT="$WORKSPACE/fixture-results.jsonl"
jq -e -s '
  length == 3
  and (map(select(.case == "top-level-verbatim" and .fired == true)) | length == 1)
  and (map(select(.case == "reshaped-top-level" and .fired == false)) | length == 1)
  and (map(select(.case == "subdirectory-verbatim" and .fired == false and .blind_spot == true)) | length == 1)
' "$FIXTURE_RESULT" >/dev/null || fail "fixture check did not record all three detector outcomes"
pass "fixture check records the firing, sensitivity case, and subdirectory blind spot"

if ! python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2]) / "capture-formats"
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
formats = {
    "codex": [
        {"timestamp":"2026-01-01T00:00:00Z","type":"CommandExecution","id":"c1","command":["/bin/sh","git push origin HEAD"],"aggregated_output":"duplicate implementation detected","exit_code":1},
    ],
    "claude": [
        {"timestamp":"2026-01-01T00:00:00Z","type":"tool_use","id":"c1","name":"Bash","input":{"command":"git push origin HEAD"}},
        {"timestamp":"2026-01-01T00:00:01Z","type":"tool_result","tool_use_id":"c1","content":"duplicate implementation detected"},
    ],
    "cursor-agent": [
        {"timestamp":"2026-01-01T00:00:00Z","type":"tool_use","id":"c1","name":"Shell","input":{"command":"git push origin HEAD"}},
        {"timestamp":"2026-01-01T00:00:01Z","type":"tool_result","tool_use_id":"c1","content":"duplicate implementation detected"},
    ],
    "kimi": [
        {"timestamp":"2026-01-01T00:00:00Z","type":"function_call","call_id":"c1","name":"exec","arguments":"{\"command\":\"git push origin HEAD\"}"},
        {"timestamp":"2026-01-01T00:00:01Z","type":"function_call_output","call_id":"c1","output":"duplicate implementation detected"},
    ],
    "pi": [
        {"timestamp":"2026-01-01T00:00:00Z","type":"toolCall","id":"c1","name":"bash","input":{"command":"git push origin HEAD"}},
        {"timestamp":"2026-01-01T00:00:01Z","type":"toolResult","tool_use_id":"c1","content":"duplicate implementation detected"},
    ],
}
for harness, rows in formats.items():
    path = tmp / f"{harness}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    _, gate = module.behavior_and_gate([path], tmp / "absent-session.log", [])
    if gate["firing_count"] != 1 or gate["push_commands_observed"] != 1 or gate["firings"][0]["push_ordinal"] != 1:
        raise SystemExit(f"positive capture failed for {harness}: {gate}")
    negative = tmp / f"{harness}-negative.jsonl"
    negative.write_text(json.dumps({"timestamp":"2026-01-01T00:00:00Z","type":"tool_use","id":"n1","name":"Bash","input":{"command":"git status"}}) + "\n")
    _, negative_gate = module.behavior_and_gate([negative], tmp / "absent-session.log", [])
    if negative_gate["firing_count"] != 0 or negative_gate["push_commands_observed"] != 0:
        raise SystemExit(f"negative capture failed for {harness}: {negative_gate}")
reused = tmp / "reused-id.jsonl"
reused_rows = [
    {"timestamp":"2026-01-01T00:00:00Z","type":"tool_use","id":"same","name":"Bash","input":{"command":"git push origin HEAD"}},
    {"timestamp":"2026-01-01T00:01:00Z","type":"tool_use","id":"same","name":"Bash","input":{"command":"git push origin HEAD"}},
    {"timestamp":"2026-01-01T00:01:01Z","type":"tool_result","tool_use_id":"same","content":"duplicate implementation detected"},
]
reused.write_text("".join(json.dumps(row) + "\n" for row in reused_rows))
mirror = tmp / "reused-id-mirror.jsonl"
mirror.write_text(reused.read_text())
_, reused_gate = module.behavior_and_gate([reused, mirror], tmp / "absent-session.log", [])
if reused_gate["push_commands_observed"] != 2 or reused_gate["firing_count"] != 1 or reused_gate["firings"][0]["push_ordinal"] != 2:
    raise SystemExit(f"reused tool ids cross-joined or mirrored events double-counted: {reused_gate}")
sandbox_root = tmp / "linux-sandbox-root"
worktree = sandbox_root / "runs/current"
candidate_home = sandbox_root / "homes/current"
origin = candidate_home / "origin.git"
workspace = sandbox_root / "workspace"
for path in (worktree, origin, workspace):
    path.mkdir(parents=True, exist_ok=True)
argv = module.linux_sandbox_argv(pathlib.Path("/usr/bin/bwrap"), ["/bin/true"], worktree, origin, candidate_home, workspace)
parent_mask = ["--tmpfs", str(sandbox_root.resolve())]
if not any(argv[index:index + 2] == parent_mask for index in range(len(argv) - 1)):
    raise SystemExit(f"linux sandbox does not hide the run parent: {argv}")
for destination in (worktree.resolve(), origin.resolve(), candidate_home.resolve()):
    binding = ["--bind", str(destination), str(destination)]
    if not any(argv[index:index + 3] == binding for index in range(len(argv) - 2)):
        raise SystemExit(f"linux sandbox omitted current-run binding {destination}: {argv}")
if any("other-run" in item for item in argv):
    raise SystemExit(f"linux sandbox exposed another run: {argv}")
bwrap = pathlib.Path("/usr/bin/bwrap")
if bwrap.is_file():
    fake_home = tmp / "bwrap-home"
    fake_bin = fake_home / "bin"
    fake_bin.mkdir(parents=True)
    harness = fake_bin / "home-harness"
    harness.write_text("#!/usr/bin/env bash\nset -eu\nif [ -r \"$OTHER_SECRET\" ]; then exit 44; fi\nprintf runtime-ok >\"$1\"\n")
    harness.chmod(0o755)
    other_secret = sandbox_root / "homes/other-run/credential"
    other_secret.parent.mkdir(parents=True)
    other_secret.write_text("secret")
    output = worktree / "runtime-result"
    old_home, old_path = os.environ.get("HOME"), os.environ.get("PATH")
    os.environ["HOME"] = str(fake_home)
    os.environ["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    try:
        runtime_argv = module.linux_sandbox_argv(bwrap, ["home-harness", str(output)], worktree, origin, candidate_home, workspace)
        environment = dict(os.environ, OTHER_SECRET=str(other_secret))
        completed = subprocess.run(runtime_argv, env=environment, text=True, capture_output=True)
    finally:
        if old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = old_home
        if old_path is None:
            os.environ.pop("PATH", None)
        else:
            os.environ["PATH"] = old_path
    if completed.returncode != 0 or not output.is_file() or output.read_text() != "runtime-ok":
        raise SystemExit(f"real bwrap did not preserve the selected home runtime closure: rc={completed.returncode} stderr={completed.stderr}")
PY
then
  fail "supported harness capture formats lost call/result joins"
fi
pass "all supported harness formats join positive and negative tool evidence"

cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -eu
cwd=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C|--cd) cwd=$2; shift 2 ;;
    -o|--output-last-message) out=$2; shift 2 ;;
    -m|--model|-s|--sandbox) shift 2 ;;
    --json|--skip-git-repo-check) shift ;;
    *) shift ;;
  esac
done
[ -n "$cwd" ] && [ -n "$out" ]
if cat "$cwd/../../workspace/workspace.json" >/dev/null 2>&1; then
  printf 'candidate escaped its worktree\n' >"$cwd/sandbox-leak.txt"
fi
touch "$cwd/../../workspace/bundles/smoke-codex/forged-by-candidate" 2>/dev/null || true
printf 'smoke\n' >"$cwd/smoke.txt"
git -C "$cwd" add smoke.txt
git -C "$cwd" commit -q -m 'test: smoke push path'
git -C "$cwd" push -q origin HEAD
printf 'Smoke delivery note.\n' >"$out"
mkdir -p "$HOME/.codex/sessions/2026/01/01"
cat >"$HOME/.codex/sessions/2026/01/01/session.jsonl" <<JSONL
{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"fake-session","timestamp":"2026-01-01T00:00:00Z","cwd":"$cwd"}}
{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":70,"cache_write_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":3,"total_tokens":120}}}}
{"timestamp":"2026-01-01T00:00:02Z","type":"tool_use","id":"push-1","name":"Bash","input":{"command":"git push origin HEAD"}}
{"timestamp":"2026-01-01T00:00:03Z","type":"tool_result","tool_use_id":"push-1","content":"[duplicate-implementation] duplicate implementation detected\nRemediation: import the existing helper."}
JSONL
printf '{"type":"item.completed","item":{"type":"agent_message","text":"Smoke delivery note."}}\n'
SH
chmod +x "$FAKEBIN/codex"
mkdir -p "$TMP_ROOT/transcripts"
printf '0.10 0.09 0.08\n' >"$TMP_ROOT/load"
SMOKE_PROMPT="$TMP_ROOT/smoke-prompt.txt"
printf 'Create smoke.txt, commit it, push it to origin, and report completion.\n' >"$SMOKE_PROMPT"
if PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id exploratory-no-lane \
    --arm guard-on --harness codex --model fake-model --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage exploratory --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30 >/dev/null 2>&1; then
  fail "exploratory run accepted a missing lane"
fi
if PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id exploratory-unsafe-lane \
    --arm guard-on --harness codex --model fake-model --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage exploratory --lane '../../escaped' --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30 >/dev/null 2>&1; then
  fail "exploratory run accepted a traversing lane"
fi
pass "exploratory runs require safe lane ids"
PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id smoke-codex \
    --arm guard-on --harness codex --model fake-model --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage smoke --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30

MANIFEST="$WORKSPACE/bundles/smoke-codex/manifest.json"
jq -e '
  .run_id == "smoke-codex"
  and .git.push_count == 1
  and .transcript.status == "captured"
  and .usage.fresh_input_tokens == 30
  and .usage.cached_input_tokens == 70
  and .usage.cache_write_input_tokens == 5
  and .usage.output_tokens == 20
  and .work.commit_count == 1
  and .work.suite_passed == null
  and .gate.firing_count == 1
  and .gate.firings[0].push_ordinal == 1
  and .attrition.mechanical_failure == false
' "$MANIFEST" >/dev/null || {
  jq '{exit_code,attrition,transcript,git,gate,work}' "$MANIFEST" >&2
  printf '%s\n' '--- session log ---' >&2
  cat "$WORKSPACE/bundles/smoke-codex/session.log" >&2
  fail "smoke manifest lost push, transcript, usage, or work evidence"
}
[ ! -d "$TMP_ROOT/runs/smoke-codex" ] || fail "run teardown retained the worktree"
[ ! -e "$WORKSPACE/bundles/smoke-codex/forged-by-candidate" ] \
  || fail "candidate could mutate the evidence store"
! grep -q 'sandbox-leak.txt' "$WORKSPACE/bundles/smoke-codex/final.diff" \
  || fail "candidate could read the blinded workspace outside its worktree"
[ "$(git -C "$WORKSPACE/mirror.git" for-each-ref --format='%(refname)')" = 'refs/heads/dev' ] \
  || fail "run teardown retained a candidate solution ref"
jq -e '.blindness_check.passed == true and .blindness_check.remote_refs == ["refs/heads/dev"]' \
  "$MANIFEST" >/dev/null || fail "manifest omitted the expanded blindness proof"
pass "run driver captures a headless push end to end and tears down serially"

cat >"$FAKEBIN/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then printf 'cursor-agent fixture\n'; exit 0; fi
cwd=
model=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) cwd=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'cursor smoke\n' >"$cwd/cursor-smoke.txt"
git -C "$cwd" add cursor-smoke.txt
git -C "$cwd" commit -q -m 'test: cursor smoke'
git -C "$cwd" push -q origin HEAD
if [ "$model" = fake-cursor-tamper ]; then
  printf '{"scripts":{"check:canonical":"exit 0"}}\n' >"$cwd/package.json"
  printf '// candidate replaced the detector\n' >"$cwd/packages/frontend/scripts/canonical/check-canonical.ts"
  cp "$cwd/packages/backend/api/logic/donor.ts" "$cwd/packages/backend/api/logic/canonical-benchmark-verbatim.ts"
  git -C "$cwd" add package.json packages/frontend/scripts/canonical/check-canonical.ts packages/backend/api/logic/canonical-benchmark-verbatim.ts
  git -C "$cwd" commit -q -m 'test: attempt to disable canonical scoring'
fi
if [ "$model" = fake-cursor-hook-tamper ]; then
  printf '\n# candidate disabled the guard\n' >>"$cwd/lefthook.yml"
fi
project="$HOME/.cursor/projects/project"
mkdir -p "$project/agent-transcripts/conversation" "$project/terminals"
printf '{"workspacePath":"%s"}\n' "$cwd" >"$project/.workspace-trusted"
printf '{"role":"user","message":"cwd %s"}\n{"role":"assistant","message":"push completed outside the captured command stream"}\n' "$cwd" >"$project/agent-transcripts/conversation/conversation.jsonl"
printf '[duplicate-implementation] duplicate implementation detected\nExact replacement: import the existing helper.\n' >"$project/terminals/push.txt"
printf '{"role":"assistant","message":"Cursor smoke complete."}\n'
SH
chmod +x "$FAKEBIN/cursor-agent"
mkdir -p "$TMP_ROOT/cursor-projects"
PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id smoke-cursor \
    --arm guard-on --harness cursor-agent --model fake-cursor --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage smoke --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30
jq -e '.transcript.status == "captured" and (.transcript.terminal_paths | length) == 1 and .gate.firing_count == 1 and .gate.push_commands_observed == 0 and .gate.firings[0].push_ordinal == null and (.gate.firings[0].remediation_text | contains("Exact replacement"))' \
  "$WORKSPACE/bundles/smoke-cursor/manifest.json" >/dev/null \
  || fail "cursor terminal-buffer remediation evidence was not captured"
pass "cursor terminal buffers preserve exact gate remediation evidence"

jq '.gate.firing_count=0 | .gate.firings=[] | .gate.remediation_text_exact=[]' \
  "$WORKSPACE/bundles/smoke-cursor/manifest.json" >"$TMP_ROOT/cursor-manifest.json"
mv "$TMP_ROOT/cursor-manifest.json" "$WORKSPACE/bundles/smoke-cursor/manifest.json"
cat >"$TMP_ROOT/cursor-semantic-duplicate-id.json" <<'JSON'
{"scorers":[{"id":"same","verdict":"clean","rationale":"No duplicate."},{"id":"same","verdict":"clean","rationale":"No duplicate."}]}
JSON
if PATH="$FAKEBIN:$PATH" "$BENCH" score --workspace "$WORKSPACE" --run-id smoke-cursor --semantic-file "$TMP_ROOT/cursor-semantic-duplicate-id.json" >/dev/null 2>&1; then
  fail "score accepted two scorer rows with the same identity"
fi
cat >"$TMP_ROOT/cursor-semantic.json" <<'JSON'
{"scorers":[{"id":"human","verdict":"clean","rationale":"No duplicate."},{"id":"judge","verdict":"clean","rationale":"No duplicate."}]}
JSON
mkdir "$WORKSPACE/.score-lock"
if PATH="$FAKEBIN:$PATH" "$BENCH" score --workspace "$WORKSPACE" --run-id smoke-cursor --semantic-file "$TMP_ROOT/cursor-semantic.json" >"$TMP_ROOT/score-lock.out" 2>&1; then
  fail "score ignored an active scoring lock"
fi
assert_grep "another scoring process holds the scoring lock" "$TMP_ROOT/score-lock.out" \
  "score did not report its concurrency refusal"
rmdir "$WORKSPACE/.score-lock"
PATH="$FAKEBIN:$PATH" "$BENCH" score --workspace "$WORKSPACE" --run-id smoke-cursor --semantic-file "$TMP_ROOT/cursor-semantic.json"
jq -e 'select(.run_id=="smoke-cursor") | .gate_firing_count == 1 and .false_fire == true and .fix_matches_remediation == null and .review_rounds == null and (.remediation_text_exact[0] | contains("Exact replacement"))' \
  "$WORKSPACE/verdicts.jsonl" >/dev/null \
  || fail "post-hoc scoring did not recover captured remediation evidence"
pass "post-hoc scoring repairs derivation without changing the raw evidence"

PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id smoke-tamper \
    --arm guard-on --harness cursor-agent --model fake-cursor-tamper --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage smoke --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30 >/dev/null
cat >"$TMP_ROOT/tamper-semantic.json" <<'JSON'
{"scorers":[{"id":"human","verdict":"duplicate","rationale":"Duplicate."},{"id":"judge","verdict":"duplicate","rationale":"Duplicate."}]}
JSON
PATH="$FAKEBIN:$PATH" "$BENCH" score --workspace "$WORKSPACE" --run-id smoke-tamper --semantic-file "$TMP_ROOT/tamper-semantic.json" >/dev/null
jq -e 'select(.run_id=="smoke-tamper") | .machine == "duplicate" and .machine_evidence.exit_code != 0' \
  "$WORKSPACE/verdicts.jsonl" >/dev/null \
  || fail "post-hoc scoring trusted candidate-modified detector execution surfaces"
pass "post-hoc scoring enforces the pinned detector after candidate tampering"

PATH="$FAKEBIN:$PATH" "$BENCH" run --workspace "$WORKSPACE" --run-id smoke-hook-tamper \
    --arm guard-off --harness cursor-agent --model fake-cursor-hook-tamper --prompt-file "$SMOKE_PROMPT" \
    --helper-family smoke --stage smoke --load-file "$TMP_ROOT/load" --max-load 8 --timeout 30 >/dev/null
assert_grep "candidate disabled the guard" "$WORKSPACE/bundles/smoke-hook-tamper/final.diff" \
  "GUARD-OFF assume-unchanged hid candidate hook tampering"
assert_grep "lefthook.yml" "$WORKSPACE/bundles/smoke-hook-tamper/status.txt" \
  "GUARD-OFF status capture hid candidate hook tampering"
pass "capture clears assume-unchanged before preserving GUARD-OFF tampering"

"$BENCH" schema-check --workspace "$WORKSPACE" >"$TMP_ROOT/schema-check.json"
jq -e '.supported_tables == 7 and (.unsupported_tables | length) == 0' \
  "$TMP_ROOT/schema-check.json" >/dev/null || fail "schema cannot derive all seven required tables"

SYNTH="$TMP_ROOT/synthetic-manifest.json"
jq '.run_id="synthetic-off" | .arm="guard-off" | .model="fake-model"' \
  "$MANIFEST" >"$SYNTH"
cp -R "$WORKSPACE/bundles/smoke-codex" "$WORKSPACE/bundles/synthetic-off"
cp "$SYNTH" "$WORKSPACE/bundles/synthetic-off/manifest.json"
cat >"$TMP_ROOT/verdict-invalid.json" <<'JSON'
{"run_id":"smoke-codex","machine":"maybe","semantic":"clean","outcome_class":"never-duplicated","false_fire":"false","ack":false,"review_rounds":-1,"scorers":[{"id":"same","verdict":"clean","rationale":"No duplicate."},{"id":"same","verdict":"clean","rationale":"No duplicate."}]}
JSON
if "$BENCH" record-verdict --workspace "$WORKSPACE" --file "$TMP_ROOT/verdict-invalid.json" >/dev/null 2>&1; then
  fail "record-verdict accepted invalid enums, types, counts, and duplicate scorer identities"
fi
cat >"$TMP_ROOT/verdict-contradictory.json" <<'JSON'
{"run_id":"smoke-codex","machine":"duplicate","semantic":"clean","outcome_class":"never-duplicated","false_fire":false,"ack":false,"review_rounds":0,"scorers":[{"id":"human","verdict":"clean","rationale":"No semantic duplicate."},{"id":"judge","verdict":"clean","rationale":"No semantic duplicate."}]}
JSON
if "$BENCH" record-verdict --workspace "$WORKSPACE" --file "$TMP_ROOT/verdict-contradictory.json" >/dev/null 2>&1; then
  fail "record-verdict accepted an outcome that contradicted machine and scorer evidence"
fi
cat >"$TMP_ROOT/verdict.json" <<'JSON'
{"run_id":"smoke-codex","machine":"clean","semantic":"clean","outcome_class":"caught-early","false_fire":true,"ack":false,"review_rounds":0,"scorers":[{"id":"human","verdict":"clean","rationale":"No duplicate."},{"id":"judge","verdict":"clean","rationale":"No duplicate."}]}
JSON
"$BENCH" record-verdict --workspace "$WORKSPACE" --file "$TMP_ROOT/verdict.json"
cat >"$TMP_ROOT/verdict-off.json" <<'JSON'
{"run_id":"synthetic-off","machine":"duplicate","semantic":"duplicate","outcome_class":"reached-review","false_fire":false,"ack":false,"review_rounds":1,"scorers":[{"id":"human","verdict":"duplicate","rationale":"Duplicate."},{"id":"judge","verdict":"duplicate","rationale":"Duplicate."}]}
JSON
"$BENCH" record-verdict --workspace "$WORKSPACE" --file "$TMP_ROOT/verdict-off.json"
for index in $(seq 1 14); do
  run_id=$(printf 'matrix-%02d' "$index")
  model=$(printf 'fixture-model-%02d' $(((index + 1) / 2)))
  if [ $((index % 2)) -eq 1 ]; then arm=guard-off; machine=duplicate; outcome=reached-review; rounds=1; else arm=guard-on; machine=clean; outcome=never-duplicated; rounds=0; fi
  cp -R "$WORKSPACE/bundles/smoke-codex" "$WORKSPACE/bundles/$run_id"
  jq --arg id "$run_id" --arg model "$model" --arg arm "$arm" '.run_id=$id | .model=$model | .arm=$arm | .stage="matrix" | .gate.firing_count=0 | .gate.firings=[] | .gate.remediation_text_exact=[]' \
    "$MANIFEST" >"$WORKSPACE/bundles/$run_id/manifest.json"
  jq -n --arg id "$run_id" --arg machine "$machine" --arg outcome "$outcome" --argjson rounds "$rounds" \
    '{run_id:$id,machine:$machine,semantic:"clean",outcome_class:$outcome,false_fire:false,ack:false,review_rounds:$rounds,scorers:[{id:"human",verdict:"clean",rationale:"No semantic duplicate."},{id:"judge",verdict:"clean",rationale:"No semantic duplicate."}],machine_evidence:{historical_duplicates:[]}}' \
    >"$TMP_ROOT/$run_id-verdict.json"
  "$BENCH" record-verdict --workspace "$WORKSPACE" --file "$TMP_ROOT/$run_id-verdict.json"
done
for sample_case in mixed unavailable; do
  cp -R "$WORKSPACE/bundles/smoke-codex" "$WORKSPACE/bundles/exploratory-load-$sample_case"
  if [ "$sample_case" = mixed ]; then samples='[{"one_minute":null},{"one_minute":1.25}]'; else samples='[{"one_minute":null}]'; fi
  jq --arg id "exploratory-load-$sample_case" --argjson samples "$samples" \
    '.run_id=$id | .stage="exploratory" | .model=$id | .load_samples=$samples' \
    "$MANIFEST" >"$WORKSPACE/bundles/exploratory-load-$sample_case/manifest.json"
done
cat >"$TMP_ROOT/reshape-report.md" <<'REPORT'
7 of 18 comparable codex-authored geometry functions were equivalent; 11 of 18 are DIVERGENT.
The distance formula (pointToSegmentDistance) was reproduced correctly in all 6 runs.
The donor at detect-plane-overlaps.ts:86 lacks the boundary handling promised by its comment.
Identity and mutant calibration controls passed. All three were caught on the first run.
REPORT
"$BENCH" scoreboard --workspace "$WORKSPACE" \
  --markdown "$TMP_ROOT/scoreboard.md" --html "$TMP_ROOT/scoreboard.html" \
  --reshape-report "$TMP_ROOT/reshape-report.md"
for heading in \
  'Confirmatory model scoreboard' 'Pooled primary result' 'Per-run engineering detail' 'Primary outcome classes by arm' \
  'Results by helper family' 'Clean-path breakdown' 'Did the guard teach' 'Attrition and exclusions' \
  'Appendix: Codex reshaping differential check'; do
  assert_grep "$heading" "$TMP_ROOT/scoreboard.md" "scoreboard omitted $heading"
done
[ -s "$TMP_ROOT/scoreboard.html" ] || fail "scoreboard HTML was not generated"
assert_grep "7 of 18 comparable function pairs behaviorally identical" "$TMP_ROOT/scoreboard.md" \
  "scoreboard omitted the differential-execution result"
assert_grep "existing helper's purpose (behavior may differ)" "$TMP_ROOT/scoreboard.md" \
  "scoreboard still overstates reshaped behavior"
grep -Eq '^\| exploratory-load-mixed .*\| 1\.25 \|' "$TMP_ROOT/scoreboard.md" \
  || fail "scoreboard lost the finite exploratory load sample"
grep -Eq '^\| exploratory-load-unavailable .*\| unknown \|' "$TMP_ROOT/scoreboard.md" \
  || fail "scoreboard did not render all-unavailable exploratory load as unknown"
for scoreboard in "$TMP_ROOT/scoreboard.md" "$TMP_ROOT/scoreboard.html"; do
  assert_grep "per-run convenience fields for suites, remediation, pushes, reviews, and firing counts are not authoritative" \
    "$scoreboard" "scoreboard omitted the convenience-field reliability disclosure"
  assert_grep "Every published duplicate/result count and outcome was re-derived from final diffs plus pinned-detector evidence and independently recomputed" \
    "$scoreboard" "scoreboard omitted the published-evidence provenance"
  if grep -Fq "data/cgb-v3/semantic-packets" "$scoreboard"; then
    fail "fresh-workspace scoreboard hardcoded another workspace's packet path"
  fi
  if grep -Fq "were recovered post-teardown" "$scoreboard"; then
    fail "fresh-workspace scoreboard claimed a recovery ledger it did not receive"
  fi
done
[ "$(wc -l <"$WORKSPACE/verdicts.jsonl" | tr -d ' ')" -eq 18 ] \
  || fail "verdict ledger is not separate and append-only"
pass "separate verdicts generate all seven tables without hand-entered aggregates"

PLAN_WORKSPACE="$TMP_ROOT/plan-workspace"
mkdir -p "$PLAN_WORKSPACE"
cp "$WORKSPACE/workspace.json" "$PLAN_WORKSPACE/workspace.json"
cat >"$TMP_ROOT/invalid-plan.json" <<'JSON'
{"ratified_at":"2026-01-01T00:00:00Z","amendment":"fixture","prompt_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runs":[{"run_id":"only","arm":"guard-on","harness":"codex","model":"fixture","lane":"../unsafe"}]}
JSON
if "$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/invalid-plan.json" >/dev/null 2>&1; then
  fail "freeze accepted a partial, unsafe, unpaired plan"
fi
python3 - "$TMP_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
def plan(pair_count):
    runs = []
    for index in range(1, pair_count + 1):
        lane = f"lane-{index}"
        for order, arm in enumerate(("guard-on", "guard-off"), 1):
            runs.append({"run_id":f"pair-{index}-{arm}","arm":arm,"harness":"codex","model":f"fixture-{index}","provider":None,"effort":None,"helper_family":"distance-helper","lane":lane,"lane_order":order,"concurrent_lane_count":1})
    return {"ratified_at":"2026-01-01T00:00:00Z","amendment":"fixture","prompt_sha256":"a" * 64,"max_load":8,"timeout_seconds":30,"runs":runs}
for name, count in (("under-plan.json", 1), ("valid-plan.json", 7), ("over-plan.json", 8)):
    (root / name).write_text(json.dumps(plan(count)))
PY
for invalid_size in under over; do
  if "$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/$invalid_size-plan.json" >/dev/null 2>&1; then
    fail "freeze accepted a $invalid_size-sized confirmatory slate"
  fi
done
"$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" >/dev/null
jq -e '.max_load == 8 and .timeout_seconds == 30 and (.runs | length) == 14' "$PLAN_WORKSPACE/frozen-plan.json" >/dev/null \
  || fail "freeze did not preserve the complete seven-pair execution design"
pass "freeze validates and binds the complete paired execution design"

pass "all canonical-guard benchmark tests passed"
