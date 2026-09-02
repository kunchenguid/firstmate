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

# A candidate runtime installed under the operator's home (every one of them is:
# ~/.nvm, ~/.local, ~/.bun) must still start. Resolving its own path stats every
# ancestor, including the home directory node the profile denies, so denying that
# node outright refuses the runtime at startup before it reads anything.
if [ "$(uname -s)" = Darwin ] && command -v node >/dev/null 2>&1; then
  SANDBOX_HOME="$TMP_ROOT/sandbox-home"
  mkdir -p "$SANDBOX_HOME/.nvm" "$TMP_ROOT/sandbox/runs/current" \
    "$TMP_ROOT/sandbox/homes/current/origin.git" "$TMP_ROOT/sandbox/workspace"
  printf 'operator secret\n' >"$SANDBOX_HOME/private-note.txt"
  printf 'process.stdout.write("runtime-started");\n' >"$SANDBOX_HOME/.nvm/probe.js"
  if ! HOME="$SANDBOX_HOME" python3 - "$ROOT" "$TMP_ROOT/sandbox" "$SANDBOX_HOME" <<'PY'
import importlib.util
import pathlib
import subprocess
import sys

root, sandbox, home = (pathlib.Path(value) for value in sys.argv[1:4])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
worktree = sandbox / "runs/current"
candidate_home = sandbox / "homes/current"
origin = candidate_home / "origin.git"
workspace = sandbox / "workspace"


def sandboxed(command, harness=""):
    argv = module.macos_sandbox_command(command, worktree, origin, candidate_home, workspace, harness)
    return subprocess.run(argv, cwd=worktree, capture_output=True, text=True)

started = sandboxed(["node", str(home / ".nvm/probe.js")])
if started.returncode != 0 or started.stdout != "runtime-started":
    raise SystemExit(f"a runtime under the operator home could not start: rc={started.returncode} {started.stderr[:400]}")
for granted in module.runtime_scratch_paths("claude", worktree):
    probe = granted / "sandbox-probe"
    allowed = sandboxed(["/usr/bin/touch", str(probe)], harness="claude")
    probe.unlink(missing_ok=True)
    if allowed.returncode != 0:
        raise SystemExit(f"a runtime could not create its own scratch dir under {granted}: {allowed.stderr[:200]}")
    shared_root = granted.parent
    outside_own = sandboxed(["/usr/bin/touch", str(shared_root / "sibling-trespass")], harness="claude")
    if outside_own.returncode == 0:
        (shared_root / "sibling-trespass").unlink(missing_ok=True)
        raise SystemExit("the profile granted the shared scratch root instead of this run's own child")
outside = sandboxed(["/usr/bin/touch", "/tmp/canonical-guard-should-not-exist"], harness="claude")
if outside.returncode == 0:
    pathlib.Path("/tmp/canonical-guard-should-not-exist").unlink(missing_ok=True)
    raise SystemExit("the profile allowed writes across the whole temp directory")
secret = sandboxed(["/bin/cat", str(home / "private-note.txt")])
if secret.returncode == 0 or "operator secret" in secret.stdout:
    raise SystemExit("the profile leaked operator-home file content to the candidate")
listing = sandboxed(["/bin/ls", str(home)])
if listing.returncode == 0:
    raise SystemExit("the profile let the candidate list the operator home")
PY
  then
    fail "macOS profile must let a home-installed runtime start while still blinding the operator home"
  fi
  pass "macOS profile permits ancestor traversal without exposing the operator home"
else
  echo "skip: macOS sandbox profile check needs Darwin and node"
fi

# A runtime that reads the system trust store rather than bundling CAs cannot
# validate a certificate in the profile and retries until the run times out, so
# the environment must name a CA bundle the profile can actually read.
if ! python3 - "$ROOT" "$TMP_ROOT/sandbox-ca" <<'PY'
import importlib.util
import os
import pathlib
import subprocess
import sys

root, sandbox = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
worktree = sandbox / "runs/current"
candidate_home = sandbox / "homes/current"
origin = candidate_home / "origin.git"
workspace = sandbox / "workspace"
for path in (worktree, origin, workspace):
    path.mkdir(parents=True, exist_ok=True)

bundle = module.system_ca_bundle()
if bundle is None:
    print("skip: no system CA bundle on this host")
    raise SystemExit(0)
environment = module.candidate_environment("codex", candidate_home)
if environment.get("SSL_CERT_FILE") != bundle:
    raise SystemExit(f"candidate environment did not name a CA bundle: {environment.get('SSL_CERT_FILE')}")
if sys.platform == "darwin":
    argv = module.macos_sandbox_command(["/bin/cat", bundle], worktree, origin, candidate_home, workspace)
    readable = subprocess.run(argv, cwd=worktree, capture_output=True, text=True)
    if readable.returncode != 0 or "BEGIN CERTIFICATE" not in readable.stdout:
        raise SystemExit(f"the named CA bundle is unreadable inside the profile: {readable.stderr[:300]}")
chosen = module.candidate_environment("codex", candidate_home)
os.environ["SSL_CERT_FILE"] = "/operator/choice.pem"
try:
    if module.candidate_environment("codex", candidate_home).get("SSL_CERT_FILE") != "/operator/choice.pem":
        raise SystemExit("an operator-chosen CA bundle was overridden")
finally:
    os.environ.pop("SSL_CERT_FILE", None)
PY
then
  fail "candidate runs must get a CA bundle the sandbox profile can read"
fi
pass "candidate environment names a readable CA bundle without overriding the operator"

# Two runtime dependencies the run profile breaks silently: codex applying its
# own sandbox inside ours (macOS refuses a nested sandbox_apply, so every command
# fails while the model still burns tokens), and Claude's credential living in
# the login keychain, which sits inside the operator home the profile blinds.
cat >"$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = find-generic-password ] || exit 1
if [ "${3:-}" = "Claude Code-credentials" ]; then
  printf '{"claudeAiOauth":{"accessToken":"fixture-token"}}'
  exit 0
fi
exit 44
SH
chmod +x "$FAKEBIN/security"
if ! PATH="$FAKEBIN:$PATH" python3 - "$ROOT" "$TMP_ROOT/runtime-deps" <<'PY'
import argparse
import importlib.util
import pathlib
import sys

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

worktree = scratch / "runs/current"
candidate_home = scratch / "homes/current"
for path in (worktree, candidate_home):
    path.mkdir(parents=True, exist_ok=True)

args = argparse.Namespace(
    harness="codex", model="fixture-model", effort="high", provider=None,
    mirror=candidate_home / "origin.git",
)
command = module.harness_command(args, worktree, candidate_home, "do the task")
modes = [command[index + 1] for index, item in enumerate(command) if item == "--sandbox"]
if modes != ["danger-full-access"]:
    raise SystemExit(f"codex must not apply a second sandbox inside the run profile: {modes}")

home_credential = pathlib.Path.home() / ".claude/.credentials.json"
if home_credential.is_file():
    print("skip: this operator keeps a Claude credential file, so the keychain path is unused")
    raise SystemExit(0)
if sys.platform != "darwin":
    print("skip: keychain credentials are a macOS path")
    raise SystemExit(0)
module.copy_candidate_credentials("claude", candidate_home)
materialised = candidate_home / ".claude/.credentials.json"
if not materialised.is_file() or "fixture-token" not in materialised.read_text():
    raise SystemExit("the keychain credential was not materialised into the candidate home")
if materialised.stat().st_mode & 0o077:
    raise SystemExit("the materialised credential is group or world readable")
PY
then
  fail "codex must not nest a sandbox and Claude must receive its keychain credential"
fi
pass "runtime dependencies the profile blinds are supplied instead of failing mid-run"

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

if "$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" >/dev/null 2>&1; then
  fail "freeze silently replaced an already-frozen plan"
fi
if "$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" --supersede >/dev/null 2>&1; then
  fail "freeze superseded a plan without a recorded reason"
fi
FROZEN_BEFORE=$(jq -r '.frozen_at' "$PLAN_WORKSPACE/frozen-plan.json")
"$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" \
  --supersede --reason "instrument defect found before any outcome was scored" >/dev/null
ARCHIVED=$(ls "$PLAN_WORKSPACE/superseded"/*.json)
jq -e --arg was "$FROZEN_BEFORE" '.frozen_at == $was and (.superseded_reason | length) > 0' "$ARCHIVED" >/dev/null \
  || fail "the superseded plan was not archived with its reason"
[ ! -w "$ARCHIVED" ] || fail "the archived plan stayed writable"
jq -e '.supersedes.reason == "instrument defect found before any outcome was scored"' \
  "$PLAN_WORKSPACE/frozen-plan.json" >/dev/null || fail "the new plan does not name what it replaced"
cat >"$TMP_ROOT/plan-verdict.json" <<'JSON'
{"run_id":"pair-1-guard-on","machine":"clean","semantic":"clean","outcome_class":"never-duplicated","false_fire":false,"ack":false,"review_rounds":0,"scorers":[{"id":"human","verdict":"clean","rationale":"No duplicate."},{"id":"judge","verdict":"clean","rationale":"No duplicate."}],"machine_evidence":{"historical_duplicates":[]}}
JSON
mkdir -p "$PLAN_WORKSPACE/bundles/pair-1-guard-on"
jq '.run_id="pair-1-guard-on" | .stage="matrix" | .gate.firing_count=0 | .gate.firings=[] | .gate.remediation_text_exact=[]' \
  "$MANIFEST" >"$PLAN_WORKSPACE/bundles/pair-1-guard-on/manifest.json"
"$BENCH" record-verdict --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/plan-verdict.json" >/dev/null
if "$BENCH" freeze --workspace "$PLAN_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" \
    --supersede --reason "too late, an outcome is already known" >/dev/null 2>&1; then
  fail "freeze superseded a plan after an outcome had been scored"
fi
pass "a frozen plan is replaceable only before any outcome exists, and only on the record"

RANK_WORKSPACE="$TMP_ROOT/rank-workspace"
mkdir -p "$RANK_WORKSPACE/bundles"
cp "$WORKSPACE/workspace.json" "$RANK_WORKSPACE/workspace.json"
RUBRIC="$TMP_ROOT/rank-rubric.json"
cat >"$RUBRIC" <<'JSON'
{"weights":{"suite":30,"duplicate":15,"equivalence":15,"judged":40},
 "criteria":[{"id":"Q1","name":"Contract fidelity"},{"id":"Q2","name":"Reads like the neighbours"}]}
JSON
RUBRIC_SHA=$(shasum -a 256 "$RUBRIC" | cut -d' ' -f1)
SUITE_COMMAND="fake-suite run"
python3 - "$TMP_ROOT" "$RUBRIC_SHA" "$SUITE_COMMAND" <<'PY'
import json
import pathlib
import sys

root, rubric_sha, suite_command = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def entry(run_id, model, lane, arm="guard-on", lane_order=1, provider=None):
    return {
        "run_id": run_id, "arm": arm, "harness": "codex", "model": model, "provider": provider,
        "effort": None, "helper_family": "distance-helper", "lane": lane,
        "lane_order": lane_order, "concurrent_lane_count": 1,
    }


def plan(runs, **overrides):
    value = {
        "plan_shape": "ranking", "condition_arm": "guard-on", "rubric_sha256": rubric_sha,
        "suite_command": suite_command, "ratified_at": "2026-01-01T00:00:00Z", "amendment": "fixture",
        "prompt_sha256": "a" * 64, "max_load": 8, "timeout_seconds": 30, "runs": runs,
    }
    value.update(overrides)
    return value


healthy = [entry("rank-fast", "fixture-fast", "lane-1"), entry("rank-slow", "fixture-slow", "lane-2"), entry("rank-blind", "fixture-blind", "lane-3")]
cases = {
    "rank-mixed-arm-plan.json": plan([entry("rank-fast", "fixture-fast", "lane-1"), entry("rank-slow", "fixture-slow", "lane-2", arm="guard-off")]),
    "rank-repeat-candidate-plan.json": plan([entry("rank-fast", "fixture-fast", "lane-1"), entry("rank-again", "fixture-fast", "lane-2")]),
    "rank-paired-lane-plan.json": plan([entry("rank-fast", "fixture-fast", "lane-1"), entry("rank-slow", "fixture-slow", "lane-1", lane_order=2)]),
    "rank-single-candidate-plan.json": plan([entry("rank-fast", "fixture-fast", "lane-1")]),
    "rank-no-rubric-plan.json": plan(healthy, rubric_sha256="not-a-digest"),
    "rank-no-suite-plan.json": plan(healthy, suite_command="   "),
    "rank-bad-shape-plan.json": plan(healthy, plan_shape="freeform"),
    "rank-valid-plan.json": plan(healthy),
    # A plan that omits plan_shape must still face the confirmatory slate rules.
    "rank-unshaped-plan.json": {key: value for key, value in plan(healthy).items() if key != "plan_shape"},
}
for name, value in cases.items():
    (root / name).write_text(json.dumps(value))
PY
for refusal in mixed-arm repeat-candidate paired-lane single-candidate no-rubric no-suite bad-shape unshaped; do
  if "$BENCH" freeze --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/rank-$refusal-plan.json" >/dev/null 2>&1; then
    fail "freeze accepted a ranking plan with a $refusal defect"
  fi
done
"$BENCH" freeze --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/rank-valid-plan.json" >/dev/null
jq -e '.plan_shape == "ranking" and .condition_arm == "guard-on" and (.runs | length) == 3 and (.runs | map(.arm) | unique | length) == 1' \
  "$RANK_WORKSPACE/frozen-plan.json" >/dev/null \
  || fail "freeze did not bind the single-condition ranking slate"
pass "freeze binds a single-condition ranking slate and refuses arms, repeats, and an unfrozen rubric"

cat >"$FAKEBIN/fake-suite" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = run ] || exit 3
shift
[ "$#" -eq 1 ] || exit 4
case "$1" in
  probe.test.ts) exit 0 ;;
  broken.test.ts) exit 1 ;;
  *) exit 5 ;;
esac
SH
chmod +x "$FAKEBIN/fake-suite"
rank_bundle() {
  bundle="$RANK_WORKSPACE/bundles/$1"
  mkdir -p "$bundle"
  jq --arg id "$1" --arg model "$2" --argjson tokens "$4" \
    '.run_id=$id | .model=$model | .stage="matrix" | .arm="guard-on" | .lane="lane-x" | .usage.total_tokens=$tokens
     | .gate.firing_count=0 | .gate.firings=[] | .gate.remediation_text_exact=[]' \
    "$WORKSPACE/bundles/smoke-codex/manifest.json" >"$bundle/manifest.json"
  if [ -n "$3" ]; then
    path="packages/backend/api/logic/__tests__/$3"
  else
    path="packages/backend/api/logic/rank-fixture-module.ts"
  fi
  {
    printf 'diff --git a/%s b/%s\n' "$path" "$path"
    printf 'new file mode 100644\n--- /dev/null\n+++ b/%s\n' "$path"
    printf '@@ -0,0 +1,1 @@\n+// generated by the ranking fixture\n'
  } >"$bundle/final.diff"
}
rank_bundle rank-fast fixture-fast probe.test.ts 1000
rank_bundle rank-slow fixture-slow broken.test.ts 4000
rank_bundle rank-blind fixture-blind '' null
if "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id rank-fast --suite-command 'fake-suite other' >/dev/null 2>&1; then
  fail "rank-suite ran a command the plan did not freeze"
fi
PATH="$FAKEBIN:$PATH" "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id rank-fast --suite-command "$SUITE_COMMAND" >/dev/null
PATH="$FAKEBIN:$PATH" "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id rank-slow --suite-command "$SUITE_COMMAND" >/dev/null
PATH="$FAKEBIN:$PATH" "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id rank-blind --suite-command "$SUITE_COMMAND" >/dev/null
if PATH="$FAKEBIN:$PATH" "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id rank-fast --suite-command "$SUITE_COMMAND" >/dev/null 2>&1; then
  fail "rank-suite overwrote an already recorded executable verdict"
fi
jq -se '
  (map(select(.run_id=="rank-fast")) | first) as $fast
  | (map(select(.run_id=="rank-slow")) | first) as $slow
  | (map(select(.run_id=="rank-blind")) | first) as $blind
  | $fast.status == "pass" and $fast.filters == ["probe.test.ts"]
    and ($fast.test_paths | first | endswith("__tests__/probe.test.ts"))
    and $slow.status == "fail" and $slow.exit_code == 1
    and $blind.status == "no-tests" and $blind.test_paths == []
' "$RANK_WORKSPACE/suite-results.jsonl" >/dev/null \
  || fail "rank-suite did not execute the frozen suite against each run's own added tests"
pass "rank-suite replays each captured tree and executes the frozen suite independently"

for run_id in rank-fast rank-slow rank-blind; do
  jq -n --arg id "$run_id" \
    '{run_id:$id,machine:"clean",semantic:"clean",outcome_class:"never-duplicated",false_fire:false,ack:false,review_rounds:0,scorers:[{id:"human",verdict:"clean",rationale:"No duplicate."},{id:"judge",verdict:"clean",rationale:"No duplicate."}],machine_evidence:{historical_duplicates:[]}}' \
    >"$TMP_ROOT/$run_id-rank-verdict.json"
  "$BENCH" record-verdict --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/$run_id-rank-verdict.json" >/dev/null
done
cat >"$TMP_ROOT/rank-quality.json" <<'JSON'
{"runs":{
  "rank-fast":{"Q1":{"score":2,"evidence":"final.diff returns the specified row shape."},"Q2":{"score":2,"evidence":"final.diff follows the neighbouring module layout."}},
  "rank-slow":{"Q1":{"score":1,"evidence":"final.diff inverts the threshold comparison."},"Q2":{"score":1,"evidence":"final.diff leaves a commented-out branch."}},
  "rank-blind":{"Q1":{"score":2,"evidence":"final.diff returns the specified row shape."},"Q2":{"score":2,"evidence":"final.diff follows the neighbouring module layout."}}}}
JSON
cat >"$TMP_ROOT/rank-quality-missing.json" <<'JSON'
{"runs":{"rank-fast":{"Q1":{"score":2,"evidence":"only one criterion read."}}}}
JSON
cat >"$TMP_ROOT/rank-quality-unevidenced.json" <<'JSON'
{"runs":{"rank-fast":{"Q1":{"score":2,"evidence":"  "},"Q2":{"score":2,"evidence":"fine."}}}}
JSON
cat >"$TMP_ROOT/rank-quality-boolean.json" <<'JSON'
{"runs":{"rank-fast":{"Q1":{"score":true,"evidence":"a boolean is not a judged score."},"Q2":{"score":2,"evidence":"fine."}}}}
JSON
cat >"$TMP_ROOT/rank-quality-float.json" <<'JSON'
{"runs":{"rank-fast":{"Q1":{"score":1.0,"evidence":"a float is not a judged score."},"Q2":{"score":2,"evidence":"fine."}}}}
JSON
cat >"$TMP_ROOT/rank-equivalence.json" <<'JSON'
{"runs":{"rank-fast":{"comparable":2,"equivalent":2},"rank-slow":{"comparable":2,"equivalent":1}}}
JSON
printf '{"weights":{"suite":1,"duplicate":1,"equivalence":1,"judged":1},"criteria":[{"id":"Q1","name":"Swapped"}]}\n' >"$TMP_ROOT/rank-rubric-swapped.json"
if "$BENCH" rank-scoreboard --workspace "$RANK_WORKSPACE" --markdown "$TMP_ROOT/rank.md" --html "$TMP_ROOT/rank.html" \
    --rubric "$TMP_ROOT/rank-rubric-swapped.json" --quality "$TMP_ROOT/rank-quality.json" >/dev/null 2>&1; then
  fail "rank-scoreboard scored against a rubric the plan never froze"
fi
for bad in missing unevidenced boolean float; do
  if "$BENCH" rank-scoreboard --workspace "$RANK_WORKSPACE" --markdown "$TMP_ROOT/rank.md" --html "$TMP_ROOT/rank.html" \
      --rubric "$RUBRIC" --quality "$TMP_ROOT/rank-quality-$bad.json" >/dev/null 2>&1; then
    fail "rank-scoreboard accepted a $bad judged read"
  fi
done
"$BENCH" rank-scoreboard --workspace "$RANK_WORKSPACE" --markdown "$TMP_ROOT/rank.md" --html "$TMP_ROOT/rank.html" \
  --rubric "$RUBRIC" --quality "$TMP_ROOT/rank-quality.json" --equivalence "$TMP_ROOT/rank-equivalence.json" >"$TMP_ROOT/rank.json"
jq -e '.ranked == 2 and .unranked == 1 and .missing_lanes == 0' "$TMP_ROOT/rank.json" >/dev/null \
  || fail "rank-scoreboard miscounted ranked, token-blind, and unrun candidates"
for heading in 'Ranking by quality per million tokens' 'Quality only' 'Executable verdicts' 'Judged code-quality read' \
  'Run conditions' 'Lanes that produced no scored run' 'Honesty footer'; do
  assert_grep "$heading" "$TMP_ROOT/rank.md" "ranking scoreboard omitted $heading"
done
grep -Eq '^\| 1 \| fixture-fast \|' "$TMP_ROOT/rank.md" \
  || fail "ranking scoreboard did not rank the cheaper equal-quality candidate first"
grep -Fq 'fixture-blind' "$TMP_ROOT/rank.md" \
  || fail "ranking scoreboard dropped the candidate whose runtime reports no tokens"
if grep -Eq '^\| [0-9]+ \| fixture-blind \|' "$TMP_ROOT/rank.md"; then
  fail "ranking scoreboard ranked a candidate whose token count it had to invent"
fi
assert_grep 'final.diff inverts the threshold comparison' "$TMP_ROOT/rank.md" \
  "ranking scoreboard omitted the judged evidence line"
assert_grep 'n=1 per model on one fixed task' "$TMP_ROOT/rank.md" "ranking scoreboard omitted its honesty footer"
assert_grep 'no comparable pair' "$TMP_ROOT/rank.md" \
  "ranking scoreboard imputed an equivalence result it never measured"
[ -s "$TMP_ROOT/rank.html" ] || fail "ranking scoreboard HTML was not generated"
pass "rank-scoreboard ranks by quality per token and never imputes a missing measurement"

python3 - "$TMP_ROOT" "$RUBRIC_SHA" "$SUITE_COMMAND" <<'PY'
import json
import pathlib
import sys

root, rubric_sha, suite_command = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def entry(run_id, model, lane, effort="medium", harness="codex", provider=None):
    return {
        "run_id": run_id, "arm": "guard-on", "harness": harness, "model": model, "provider": provider,
        "effort": effort, "helper_family": "distance-helper", "lane": lane,
        "lane_order": 1, "concurrent_lane_count": 1,
    }


def wave(runs, **overrides):
    value = {
        "wave": "effort-medium", "condition_arm": "guard-on", "rubric_sha256": rubric_sha,
        "suite_command": suite_command, "ratified_at": "2026-01-02T00:00:00Z",
        "amendment": "second wave at medium effort", "prompt_sha256": "a" * 64,
        "max_load": 8, "timeout_seconds": 30, "runs": runs,
    }
    value.update(overrides)
    return value


healthy = [entry("wave-fast", "fixture-fast", "wlane-1"), entry("wave-slow", "fixture-slow", "wlane-2")]
cases = {
    "wave-reused-id-plan.json": wave([entry("rank-fast", "fixture-fast", "wlane-1")]),
    "wave-repeat-cell-plan.json": wave([entry("wave-fast", "fixture-fast", "wlane-1", effort=None)]),
    "wave-no-effort-plan.json": wave([entry("wave-fast", "fixture-fast", "wlane-1", effort="  ")]),
    "wave-other-prompt-plan.json": wave(healthy, prompt_sha256="b" * 64),
    "wave-other-rubric-plan.json": wave(healthy, rubric_sha256="c" * 64),
    "wave-other-suite-plan.json": wave(healthy, suite_command="fake-suite elsewhere"),
    "wave-unlabelled-plan.json": wave(healthy, wave="../escape"),
    "wave-valid-plan.json": wave(healthy),
}
for name, value in cases.items():
    (root / name).write_text(json.dumps(value))
PY
for refusal in reused-id repeat-cell no-effort other-prompt other-rubric other-suite unlabelled; do
  if "$BENCH" freeze-wave --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/wave-$refusal-plan.json" >/dev/null 2>&1; then
    fail "freeze-wave accepted a wave with a $refusal defect"
  fi
done
"$BENCH" freeze-wave --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/wave-valid-plan.json" >/dev/null
[ ! -w "$RANK_WORKSPACE/waves/effort-medium.json" ] || fail "a frozen wave plan stayed writable"
if "$BENCH" freeze-wave --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/wave-valid-plan.json" >/dev/null 2>&1; then
  fail "freeze-wave re-froze a label that already exists"
fi
jq -e '.runs | length == 2' "$RANK_WORKSPACE/frozen-plan.json" >/dev/null 2>&1 \
  && fail "freezing a wave rewrote the already-frozen primary slate"
jq -e '(.runs | length) == 3 and .plan_shape == "ranking"' "$RANK_WORKSPACE/frozen-plan.json" >/dev/null \
  || fail "the primary slate changed when a wave was frozen"
pass "freeze-wave adds a labelled wave without touching the frozen slate"

for run_id in wave-fast wave-slow; do
  case "$run_id" in
    wave-fast) rank_bundle "$run_id" fixture-fast probe.test.ts 500 ;;
    wave-slow) rank_bundle "$run_id" fixture-slow probe.test.ts 8000 ;;
  esac
  jq --arg id "$run_id" '.stage="wave" | .wave="effort-medium" | .effort="medium"' \
    "$RANK_WORKSPACE/bundles/$run_id/manifest.json" >"$TMP_ROOT/$run_id-manifest.json"
  mv "$TMP_ROOT/$run_id-manifest.json" "$RANK_WORKSPACE/bundles/$run_id/manifest.json"
  PATH="$FAKEBIN:$PATH" "$BENCH" rank-suite --workspace "$RANK_WORKSPACE" --run-id "$run_id" --suite-command "$SUITE_COMMAND" >/dev/null
  jq -n --arg id "$run_id" \
    '{run_id:$id,machine:"clean",semantic:"clean",outcome_class:"never-duplicated",false_fire:false,ack:false,review_rounds:0,scorers:[{id:"human",verdict:"clean",rationale:"No duplicate."},{id:"judge",verdict:"clean",rationale:"No duplicate."}],machine_evidence:{historical_duplicates:[]}}' \
    >"$TMP_ROOT/$run_id-verdict.json"
  "$BENCH" record-verdict --workspace "$RANK_WORKSPACE" --file "$TMP_ROOT/$run_id-verdict.json" >/dev/null
done
python3 - "$TMP_ROOT/rank-quality.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
for run_id in ("wave-fast", "wave-slow"):
    document["runs"][run_id] = {
        "Q1": {"score": 2, "evidence": "final.diff returns the specified row shape."},
        "Q2": {"score": 1, "evidence": "final.diff drops one unparseable-input guard."},
    }
path.write_text(json.dumps(document))
PY
"$BENCH" rank-scoreboard --workspace "$RANK_WORKSPACE" --markdown "$TMP_ROOT/rank2.md" --html "$TMP_ROOT/rank2.html" \
  --rubric "$RUBRIC" --quality "$TMP_ROOT/rank-quality.json" --equivalence "$TMP_ROOT/rank-equivalence.json" >"$TMP_ROOT/rank2.json"
jq -e '.ranked == 2 and .unranked == 1' "$TMP_ROOT/rank2.json" >/dev/null \
  || fail "wave runs leaked into the primary ranking counts"
assert_grep 'Second wave: effort-medium' "$TMP_ROOT/rank2.md" "scoreboard omitted the labelled second wave"
assert_grep 'Model by effort' "$TMP_ROOT/rank2.md" "scoreboard omitted the model-by-effort comparison"
assert_grep 'every later wave is reported in its own table and never merged into it' "$TMP_ROOT/rank2.md" \
  "scoreboard did not disclose that waves stay out of the primary ranking"
primary_section=$(awk '/^## Ranking by quality per million tokens/,/^## Quality only/' "$TMP_ROOT/rank2.md")
if printf '%s' "$primary_section" | grep -Fq 'wave-fast'; then
  fail "a second-wave run appeared inside the primary ranking table"
fi
grep -Eq '^\| fixture-fast \| codex \| medium \|' "$TMP_ROOT/rank2.md" \
  || fail "model-by-effort table lost the medium-effort row"
pass "a labelled wave reports separately and only joins the primary slate in the effort comparison"

# Review finding 4: an unchecked ranking input does not merely crash, it awards a
# score share no measurement supports.
for bad in non-object-runs non-object-row negative oversized fractional; do
  case "$bad" in
    non-object-runs) printf '{"runs":[]}\n' ;;
    non-object-row)  printf '{"runs":{"rank-fast":7}}\n' ;;
    negative)        printf '{"runs":{"rank-fast":{"comparable":3,"equivalent":-1}}}\n' ;;
    oversized)       printf '{"runs":{"rank-fast":{"comparable":2,"equivalent":5}}}\n' ;;
    fractional)      printf '{"runs":{"rank-fast":{"comparable":2.5,"equivalent":1}}}\n' ;;
  esac >"$TMP_ROOT/rank-eq-$bad.json"
  if "$BENCH" rank-scoreboard --workspace "$RANK_WORKSPACE" --markdown "$TMP_ROOT/rank-bad.md" \
      --html "$TMP_ROOT/rank-bad.html" --rubric "$RUBRIC" --quality "$TMP_ROOT/rank-quality.json" \
      --equivalence "$TMP_ROOT/rank-eq-$bad.json" >/dev/null 2>&1; then
    fail "rank-scoreboard scored against a $bad equivalence input"
  fi
done
for bad in nonfinite negative-weight wrong-total duplicate-id unsafe-id; do
  case "$bad" in
    nonfinite)       printf '{"weights":{"suite":1e999,"duplicate":15,"equivalence":15,"judged":40},"criteria":[{"id":"Q1","name":"A"}]}\n' ;;
    negative-weight) printf '{"weights":{"suite":-30,"duplicate":15,"equivalence":15,"judged":100},"criteria":[{"id":"Q1","name":"A"}]}\n' ;;
    wrong-total)     printf '{"weights":{"suite":30,"duplicate":15,"equivalence":15,"judged":10},"criteria":[{"id":"Q1","name":"A"}]}\n' ;;
    duplicate-id)    printf '{"weights":{"suite":30,"duplicate":15,"equivalence":15,"judged":40},"criteria":[{"id":"Q1","name":"A"},{"id":"Q1","name":"B"}]}\n' ;;
    unsafe-id)       printf '{"weights":{"suite":30,"duplicate":15,"equivalence":15,"judged":40},"criteria":[{"id":"../escape","name":"A"}]}\n' ;;
  esac >"$TMP_ROOT/rank-rubric-$bad.json"
  BAD_SHA=$(shasum -a 256 "$TMP_ROOT/rank-rubric-$bad.json" | cut -d' ' -f1)
  BAD_WORKSPACE="$TMP_ROOT/rank-workspace-$bad"
  mkdir -p "$BAD_WORKSPACE/bundles"
  cp "$WORKSPACE/workspace.json" "$BAD_WORKSPACE/workspace.json"
  python3 - "$TMP_ROOT/rank-valid-plan.json" "$BAD_WORKSPACE/plan.json" "$BAD_SHA" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text())
plan["rubric_sha256"] = sys.argv[3]
pathlib.Path(sys.argv[2]).write_text(json.dumps(plan))
PY
  "$BENCH" freeze --workspace "$BAD_WORKSPACE" --file "$BAD_WORKSPACE/plan.json" >/dev/null
  if "$BENCH" rank-scoreboard --workspace "$BAD_WORKSPACE" --markdown "$TMP_ROOT/rank-bad.md" \
      --html "$TMP_ROOT/rank-bad.html" --rubric "$TMP_ROOT/rank-rubric-$bad.json" \
      --quality "$TMP_ROOT/rank-quality.json" >/dev/null 2>&1; then
    fail "rank-scoreboard scored against a $bad rubric"
  fi
done
pass "ranking inputs are refused before any published score is computed"

# Review finding 3: a refused replacement must not destroy the active
# registration, and a slate must not be reshaped once a run has produced output.
GUARD_WORKSPACE="$TMP_ROOT/freeze-guard-workspace"
mkdir -p "$GUARD_WORKSPACE/bundles"
cp "$WORKSPACE/workspace.json" "$GUARD_WORKSPACE/workspace.json"
"$BENCH" freeze --workspace "$GUARD_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" >/dev/null
GUARD_SHA_BEFORE=$(shasum -a 256 "$GUARD_WORKSPACE/frozen-plan.json" | cut -d' ' -f1)
printf '{"ratified_at":"x","amendment":"y","runs":[]}\n' >"$TMP_ROOT/rejected-plan.json"
if "$BENCH" freeze --workspace "$GUARD_WORKSPACE" --file "$TMP_ROOT/rejected-plan.json" \
    --supersede --reason "probe with an invalid replacement" >/dev/null 2>&1; then
  fail "freeze accepted an invalid replacement plan"
fi
[ -f "$GUARD_WORKSPACE/frozen-plan.json" ] \
  || fail "a refused supersession destroyed the active frozen plan"
[ "$(shasum -a 256 "$GUARD_WORKSPACE/frozen-plan.json" | cut -d' ' -f1)" = "$GUARD_SHA_BEFORE" ] \
  || fail "a refused supersession altered the active frozen plan"
[ ! -d "$GUARD_WORKSPACE/superseded" ] || [ -z "$(ls -A "$GUARD_WORKSPACE/superseded")" ] \
  || fail "a refused supersession archived the active plan anyway"
mkdir -p "$GUARD_WORKSPACE/bundles/pair-1-guard-on"
jq '.run_id="pair-1-guard-on" | .stage="matrix"' "$MANIFEST" \
  >"$GUARD_WORKSPACE/bundles/pair-1-guard-on/manifest.json"
if "$BENCH" freeze --workspace "$GUARD_WORKSPACE" --file "$TMP_ROOT/valid-plan.json" \
    --supersede --reason "an outcome already exists" >/dev/null 2>&1; then
  fail "freeze superseded a slate after a run had produced output"
fi
pass "supersession validates first, publishes atomically, and closes once a run produced output"

# Review findings 1 and 2: replayed candidate code is confined, and one run's
# runtime scratch is not another run's to read or overwrite.
if [ "$(uname -s)" = Darwin ]; then
  if ! python3 - "$ROOT" "$TMP_ROOT/replay" <<'PY'
import importlib.util
import pathlib
import subprocess
import sys

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

mine = scratch / "runs/mine"
theirs = scratch / "runs/theirs"
workspace = scratch / "workspace"
replay_home = scratch / "replay-home"
for path in (mine, theirs, workspace, replay_home):
    path.mkdir(parents=True, exist_ok=True)

# The scratch grant must name this run's own child, not a shared root.
granted = module.runtime_scratch_paths("claude", mine)
if not granted:
    raise SystemExit("claude was given no scratch path at all")
for path in granted:
    if path.parent == pathlib.Path(path.anchor) or path.name in {".cursor", f"claude-{__import__('os').getuid()}"}:
        raise SystemExit(f"a shared scratch root was granted instead of this run's child: {path}")
if module.runtime_scratch_paths("codex", mine):
    raise SystemExit("a runtime that needs no scratch root was granted one")
if module.runtime_scratch_paths("cursor-agent", mine):
    raise SystemExit("cursor-agent is unsupported under the profile and must be granted nothing")

neighbour = module.runtime_scratch_paths("claude", theirs)[0]
(neighbour / "secret.txt").write_text("another run's file")
argv = module.macos_sandbox_command(
    ["/usr/bin/touch", str(neighbour / "trespass")], mine, mine / "origin.git", replay_home, workspace, "claude"
)
trespass = subprocess.run(argv, cwd=mine, capture_output=True, text=True)
if trespass.returncode == 0:
    raise SystemExit("one run could write into another run's runtime scratch")


def as_mine(command):
    return subprocess.run(
        module.macos_sandbox_command(command, mine, mine / "origin.git", replay_home, workspace, "claude"),
        cwd=mine, capture_output=True, text=True,
    )


# Denying only writes leaves a concurrent run's scratch, and the operator's own
# session scratch, readable: the profile starts from allow-default.
read_secret = as_mine(["/bin/cat", str(neighbour / "secret.txt")])
if read_secret.returncode == 0 or "another run's file" in read_secret.stdout:
    raise SystemExit("one run could read another run's runtime scratch")
if as_mine(["/bin/ls", str(neighbour)]).returncode == 0:
    raise SystemExit("one run could list another run's runtime scratch")
if as_mine(["/bin/ls", str(granted[0].parent)]).returncode == 0:
    raise SystemExit("a candidate could list the shared scratch root")
own = subprocess.run(
    module.macos_sandbox_command(["/usr/bin/touch", str(granted[0] / "ok")], mine, mine / "origin.git", replay_home, workspace, "claude"),
    cwd=mine, capture_output=True, text=True,
)
if own.returncode != 0:
    raise SystemExit(f"a run could not write its own runtime scratch: {own.stderr[:200]}")

# The replay environment must not hand candidate-authored tests the operator's
# home or provider credentials.
environment = module.replay_environment(replay_home)
if environment.get("HOME") != str(replay_home):
    raise SystemExit("replayed candidate code kept the operator home")
leaked = [name for name in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CURSOR_API_KEY", "KIMI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN") if name in environment]
if leaked:
    raise SystemExit(f"replay environment carried provider credentials: {leaked}")
PY
  then
    fail "the suite replay must be confined and runtime scratch must be per-run"
  fi
  pass "replayed candidate code is confined and cannot reach another run's scratch"
else
  echo "skip: sandbox confinement assertions need Darwin"
fi

if ! python3 - "$ROOT" "$TMP_ROOT/surface" <<'PY'
import importlib.util
import pathlib
import shutil
import sys

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

template = scratch / "template"
replay = scratch / "replay"
(template / "packages/backend").mkdir(parents=True, exist_ok=True)
(replay / "packages/backend").mkdir(parents=True, exist_ok=True)
(template / "package.json").write_text('{"scripts":{"test":"vitest run"}}')
(template / "packages/backend/package.json").write_text('{"scripts":{"test":"vitest run"}}')
(replay / "package.json").write_text('{"scripts":{"test":"echo owned && exit 0"}}')
(replay / "packages/backend/package.json").write_text('{"scripts":{"test":"echo owned && exit 0"}}')

restored = module.restore_suite_surface(replay, template)
if not restored:
    raise SystemExit("a candidate-rewritten suite surface was left in place")
for relative in ("package.json", "packages/backend/package.json"):
    if "owned" in (replay / relative).read_text():
        raise SystemExit(f"candidate control of {relative} survived into the scored suite run")

# A candidate can put anything at those paths. A symlink must not be hashed or
# copied through, which would read a file outside the reconstructed tree, and a
# directory in a file's place must not raise.
outside = scratch / "outside-the-tree.txt"
outside.write_text("operator-only content")
(replay / "package.json").unlink()
(replay / "package.json").symlink_to(outside)
shutil.rmtree(replay / "packages/backend")
(replay / "packages/backend/package.json").mkdir(parents=True)
(replay / "packages/backend/package.json/planted").write_text("directory in a file's place")
module.restore_suite_surface(replay, template)
for relative in ("package.json", "packages/backend/package.json"):
    target = replay / relative
    if target.is_symlink():
        raise SystemExit(f"a candidate symlink survived at {relative}")
    if not target.is_file():
        raise SystemExit(f"{relative} was not restored to a plain file")
    if "vitest run" not in target.read_text():
        raise SystemExit(f"{relative} was not restored from the template")
if outside.read_text() != "operator-only content":
    raise SystemExit("restoring the suite surface wrote through a candidate symlink")
PY
then
  fail "a candidate must not choose what the scored suite executes"
fi
pass "the scored suite surface is restored from the template, not the candidate"

# The Darwin probes above cannot see the Linux profile, and a root that does not
# exist when the profile is written must still be denied.
if ! python3 - "$ROOT" "$TMP_ROOT/scratch-isolation" <<'PY'
import importlib.util
import json
import os
import pathlib
import shutil
import sys

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

worktree = scratch / "runs/current"
candidate_home = scratch / "homes/current"
origin = candidate_home / "origin.git"
workspace = scratch / "workspace"
for path in (worktree, origin, candidate_home, workspace):
    path.mkdir(parents=True, exist_ok=True)

roots = module.shared_scratch_roots()
if len(roots) < 2:
    raise SystemExit(f"both known runtime scratch roots must be named: {roots}")

# A root absent at profile-generation time is created later by another run or an
# operator session; denying only what exists lets it escape confinement.
absent = [path for path in roots if not path.exists()]
profile_roots = [path for path in roots]
argv = module.macos_sandbox_command(["/bin/true"], worktree, origin, candidate_home, workspace, "claude")
profile = pathlib.Path(argv[argv.index("-f") + 1]).read_text()
denied = profile.split("(allow file-read-metadata")[0]
for path in profile_roots:
    if json.dumps(str(path)) not in denied:
        raise SystemExit(f"shared scratch root not denied regardless of existence: {path} (absent at build: {path in absent})")
granted = module.runtime_scratch_paths("claude", worktree)[0]
if json.dumps(str(granted)) not in profile:
    raise SystemExit("this run's own scratch child was not granted back")

# Linux masks nothing by default under --ro-bind / /, so the roots need an
# explicit tmpfs and only this run's child re-bound.
linux = module.linux_sandbox_argv(
    pathlib.Path("/usr/bin/bwrap"), ["/bin/true"], worktree, origin, candidate_home, workspace, "claude"
)
for path in profile_roots:
    mask = ["--tmpfs", str(path)]
    if not any(linux[index:index + 2] == mask for index in range(len(linux) - 1)):
        raise SystemExit(f"linux profile does not mask the shared scratch root {path}")
rebind = ["--bind", str(granted), str(granted)]
if not any(linux[index:index + 3] == rebind for index in range(len(linux) - 2)):
    raise SystemExit("linux profile masked the root without re-binding this run's own child")
if module.linux_sandbox_argv(pathlib.Path("/usr/bin/bwrap"), ["/bin/true"], worktree, origin, candidate_home, workspace, "codex").count(str(granted)):
    raise SystemExit("a runtime that needs no scratch child was granted one on linux")

# A deep worktree path must still produce a usable directory name.
deep = scratch / ("nested/" * 40)
deep.mkdir(parents=True, exist_ok=True)
long_child = module.runtime_scratch_paths("claude", deep)[0]
if len(long_child.name.encode()) > 255:
    raise SystemExit(f"scratch child name exceeds the filesystem limit: {len(long_child.name)} bytes")
if not long_child.is_dir():
    raise SystemExit("a deep worktree path did not produce a usable scratch child")
if module.runtime_scratch_paths("claude", deep)[0] != long_child:
    raise SystemExit("the scratch child name is not stable for the same worktree")
shutil.rmtree(long_child, ignore_errors=True)
PY
then
  fail "shared runtime scratch must be masked on both platforms regardless of existence"
fi
pass "shared runtime scratch is masked on macOS and Linux, and only this run's child is granted"

# Copilot: the active plan is made writable just before the rename, so a failure
# after that point must not leave the supposedly immutable registration mutable.
if ! python3 - "$ROOT" "$WORKSPACE" "$TMP_ROOT/chmod-rollback" "$TMP_ROOT/valid-plan.json" <<'PY'
import importlib.util
import os
import pathlib
import shutil
import sys

root, source_workspace, scratch, plan_file = (pathlib.Path(value) for value in sys.argv[1:5])
spec = importlib.util.spec_from_file_location("benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

scratch.mkdir(parents=True, exist_ok=True)
(scratch / "bundles").mkdir(exist_ok=True)
shutil.copy2(source_workspace / "workspace.json", scratch / "workspace.json")

import argparse

module.command_freeze(argparse.Namespace(workspace=str(scratch), file=str(plan_file), supersede=False, reason=None))
active = scratch / "frozen-plan.json"
mode_before = active.stat().st_mode & 0o777
if mode_before & 0o222:
    raise SystemExit(f"a freshly frozen plan is writable: {oct(mode_before)}")

original_replace = os.replace


def failing_replace(*args, **kwargs):
    raise OSError("simulated failure after the plan was made writable")


os.replace = failing_replace
try:
    module.command_freeze(argparse.Namespace(workspace=str(scratch), file=str(plan_file), supersede=True, reason="probe"))
except BaseException:
    pass
finally:
    os.replace = original_replace

if not active.is_file():
    raise SystemExit("a failed publish left no active frozen plan")
mode_after = active.stat().st_mode & 0o777
if mode_after & 0o222:
    raise SystemExit(f"a failed publish left the active plan writable: {oct(mode_after)}")
PY
then
  fail "a failed supersession must leave the active plan read-only"
fi
pass "a failed supersession restores the active plan's immutability"

pass "all canonical-guard benchmark tests passed"
