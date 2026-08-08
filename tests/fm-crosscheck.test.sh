#!/usr/bin/env bash
# Behavior tests for the exact-head crosscheck finding ledger.
#
# GitHub doubles derive their TOON from the checked-in gh-axi 0.1.25 fixtures.
# The Codex double rejects any invocation outside the exact CLI surface that was
# exercised against the installed 0.146.0-alpha.9.2 binary on 2026-08-02.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CROSSCHECK_PY="${FM_TEST_CROSSCHECK_PY:-$ROOT/bin/fm-crosscheck.py}"
fm_test_tmproot_into TMP_ROOT fm-crosscheck-tests
API_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-api.toon"
CLAIMS_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-view-full.toon"
PR_URL=https://github.com/ruby-dlee/firstmate/pull/72

make_case() {
  local name=$1 case_dir repo base head
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/repo"
  mkdir -p "$repo/tests" "$case_dir/state" "$case_dir/data" \
    "$case_dir/author-home" "$case_dir/reviewer-home" "$case_dir/fakebin"
  printf '{"tokens":{"access_token":"test-reviewer-token"}}\n' \
    > "$case_dir/reviewer-home/auth.json"
  printf '{}\n' > "$case_dir/reviewer-home/.credentials.json"
  printf '{}\n' > "$case_dir/reviewer-home/.claude.json"
  git -C "$repo" init -q -b main
  printf 'base\n' > "$repo/app.txt"
  printf 'base\n' > "$repo/other.txt"
  printf '#!/usr/bin/env bash\ngrep -qx fixed app.txt\n' > "$repo/tests/regression.test.sh"
  printf '#!/usr/bin/env bash\n[ ! -e .stateful-proof-marker ] || exit 19\ntouch .stateful-proof-marker\ngrep -qx fixed app.txt\n' \
    > "$repo/tests/stateful.test.sh"
  printf '#!/usr/bin/env bash\nfind .. -maxdepth 2 -name .baseline-readable-marker -print -quit | grep -q . && exit 19\ntouch .baseline-readable-marker\n' \
    > "$repo/tests/readable-state.test.sh"
  printf '#!/usr/bin/env bash\ngrep -qx fixed app.txt\n' > "$repo/tests/helper.sh"
  printf '#!/usr/bin/env bash\n. tests/helper.sh\n' > "$repo/tests/support.test.sh"
  printf '#!/usr/bin/env bash\ngrep -qx fixed app.txt\n' > "$repo/shared-test.sh"
  ln -s ../shared-test.sh "$repo/tests/symlink.test.sh"
  printf '#!/usr/bin/env bash\n# def test_app_is_fixed()\ngrep -qx fixed app.txt\n' \
    > "$repo/tests/nodeid.test.sh"
  # Passes whatever the mutation does, so it can never itself prove causality.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/vacuous.test.sh"
  # Reaches its assertion only through a helper found on PATH, so the proof
  # environment losing PATH is a real break rather than a hypothetical one.
  printf '#!/usr/bin/env bash\nfm-test-helper\n' > "$repo/tests/pathdep.test.sh"
  mkdir -p "$repo/real-tests"
  printf '#!/usr/bin/env bash\ngrep -qx fixed app.txt\n' > "$repo/real-tests/linked.test.sh"
  ln -s ../real-tests "$repo/tests/linked"
  chmod +x "$repo/tests/regression.test.sh" "$repo/tests/stateful.test.sh" \
    "$repo/tests/readable-state.test.sh" "$repo/tests/support.test.sh" \
    "$repo/tests/nodeid.test.sh" "$repo/tests/vacuous.test.sh" \
    "$repo/tests/pathdep.test.sh" "$repo/real-tests/linked.test.sh"
  git -C "$repo" add app.txt other.txt shared-test.sh tests/regression.test.sh \
    tests/helper.sh tests/readable-state.test.sh tests/stateful.test.sh \
    tests/support.test.sh tests/symlink.test.sh tests/nodeid.test.sh \
    tests/vacuous.test.sh tests/pathdep.test.sh real-tests/linked.test.sh \
    tests/linked
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb feature
  printf 'fixed\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -qm feature
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/pull/72/head "$head"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$repo" \
    "project=$repo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=codex" \
    "model=gpt-5.5" \
    "account_home=$case_dir/author-home"
  cat > "$case_dir/reviewer.json" <<EOF
{"reviewers":[{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh","account_home":"$case_dir/reviewer-home"}]}
EOF
  install_gh_axi_fake "$case_dir"
  install_codex_fake "$case_dir"
  install_claude_fake "$case_dir"
  install_sandbox_fake "$case_dir"
  install_pytest_fake "$case_dir"
  install_path_helper "$case_dir"
  printf '%s\t%s\t%s\n' "$case_dir" "$base" "$head"
}

# The one thing tests/pathdep.test.sh needs from PATH. Its verdict still tracks
# the mutated implementation, so the proof is sound while PATH survives.
install_path_helper() {
  local case_dir=$1
  mkdir -p "$case_dir/pathbin"
  printf '#!/usr/bin/env bash\ngrep -qx fixed app.txt\n' \
    > "$case_dir/pathbin/fm-test-helper"
  chmod +x "$case_dir/pathbin/fm-test-helper"
}

# A node-id runner standing in for pytest. It reproduces the three outcomes the
# gate must tell apart: the named test ran and passed (0), ran and failed (1),
# and never ran because the selector resolved to nothing (4 usage / 5 collected).
# Like pytest it accepts more than one positional target, collects them all, and
# fails the run when any one of them fails - which is what lets a second target
# supplied through test_invocation.arguments decide the verdict.
install_pytest_fake() {
  local case_dir=$1
  mkdir -p "$case_dir/pathbin"
  cat > "$case_dir/pathbin/pytest" <<'SH'
#!/usr/bin/env bash
targets=()
for argument in "$@"; do
  case "$argument" in
    -*) ;;
    *) targets+=("$argument") ;;
  esac
done
[ "${#targets[@]}" -gt 0 ] || exit 4
# pytest's locate_config walks every parent to the filesystem root and stops at
# the first config it finds, whose addopts then join the command line.
config_addopts=""
config_dir=$PWD
while :; do
  if [ -f "$config_dir/pytest.ini" ]; then
    echo "configfile: $config_dir/pytest.ini"
    config_addopts=$(sed -n 's/^addopts *= *//p' "$config_dir/pytest.ini")
    break
  fi
  [ "$config_dir" = / ] && break
  config_dir=$(dirname "$config_dir")
done
for selector in "${targets[@]}"; do
  file=${selector%%::*}
  [ -f "$file" ] || { echo "ERROR: file or directory not found: $file"; exit 4; }
  case "$selector" in
    *::*)
      name=${selector#*::}
      if ! grep -q "def $name(" "$file"; then
        echo "no tests ran"
        exit 5
      fi
      ;;
  esac
done
# A mutation that breaks collection reports a non-execution status, never a
# test failure. The gate must not read that as "the test caught the mutation".
# The switch lives beside this script rather than in the environment, because
# the gate now builds the proof environment from an allowlist and no test-only
# variable reaches here.
collection_exit=$(dirname "$0")/collection-exit
if [ -f "$collection_exit" ] && grep -qx broken app.txt; then
  echo "no tests ran"
  # Measured on pytest 9.1.1: --continue-on-collection-errors records the
  # collection error and reports it as an ordinary failure instead, which
  # carries no classification and so reads as a caught regression. pytest
  # appends PYTEST_ADDOPTS and the located config's addopts to the command
  # line, so both land here too.
  for argument in "$@" ${PYTEST_ADDOPTS:-} $config_addopts; do
    [ "$argument" = --continue-on-collection-errors ] || continue
    echo "ERROR collecting"
    exit 1
  done
  exit "$(cat "$collection_exit")"
fi
status=0
for selector in "${targets[@]}"; do
  bash "${selector%%::*}" || status=1
done
exit "$status"
SH
  chmod +x "$case_dir/pathbin/pytest"
}

install_gh_axi_fake() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  "api /repos/ruby-dlee/firstmate/pulls/72")
    [ "${FM_TEST_API_MODE:-ok}" = ok ] || exit 42
    sed \
      -e "s/c9cbe79154013efcec9aa478f1476d0eff6c63df/$FM_TEST_HEAD/" \
      -e "s/68f014697d0eea733a4e7c0294becff4e76c7bcf/$FM_TEST_BASE/" \
      "$FM_TEST_API_FIXTURE"
    ;;
  "pr view 72 --repo ruby-dlee/firstmate --full")
    [ "${FM_TEST_CLAIMS_MODE:-ok}" = ok ] || exit 43
    case "${FM_TEST_CLAIMS_VARIANT:-original}" in
      changed)
        sed 's/Complete claims returned by --full./Changed claims after review./' "$FM_TEST_CLAIMS_FIXTURE"
        ;;
      dynamic)
        sed 's/comment_count: 0/comment_count: 1/' "$FM_TEST_CLAIMS_FIXTURE"
        ;;
      *) cat "$FM_TEST_CLAIMS_FIXTURE" ;;
    esac
    ;;
  *)
    echo "unsupported fake gh-axi invocation: $*" >&2
    exit 97
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

install_codex_fake() {
  local case_dir=$1
  cat > "$case_dir/fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CODEX_LOG"
if [ -n "${FM_TEST_STATE_OBSERVATION:-}" ]; then
  find "$FM_TEST_EXPECTED_STATE" -mindepth 1 -maxdepth 1 \
    -name '.task-x1.crosscheck.*' -print > "$FM_TEST_STATE_OBSERVATION"
  find "$FM_TEST_CALLER_CWD" -mindepth 1 -maxdepth 1 \
    -name '.task-x1.crosscheck.*' -print >> "$FM_TEST_STATE_OBSERVATION"
fi
[ "${1:-}" = exec ] || exit 90
[ -f "${CODEX_HOME:-}/auth.json" ] || exit 89
for selector in OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_REFRESH_TOKEN CODEX_REVOKE_TOKEN; do
  [ -z "$(printenv "$selector" 2>/dev/null)" ] || exit 88
done
shift
workdir=
output=
model=
effort=no
approval=no
schema=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) workdir=$2; shift 2 ;;
    --sandbox) [ "$2" = workspace-write ] || exit 91; shift 2 ;;
    --ephemeral|--strict-config) shift ;;
    --model) model=$2; shift 2 ;;
    -c)
      [ "$2" = 'model_reasoning_effort="xhigh"' ] && effort=yes
      [ "$2" = 'approval_policy="never"' ] && approval=yes
      shift 2
      ;;
    --color) [ "$2" = never ] || exit 92; shift 2 ;;
    --output-schema) schema=$2; shift 2 ;;
    --output-last-message) output=$2; shift 2 ;;
    -) shift ;;
    *) echo "unsupported fake codex argument: $1" >&2; exit 93 ;;
  esac
done
[ "$model" = gpt-5.6-sol ] || exit 94
[ "$effort" = yes ] || exit 95
[ "$approval" = yes ] || exit 96
[ -f "$schema" ] || exit 98
[ -n "$workdir" ] && [ -n "$output" ] || exit 99
cat > "$FM_TEST_PROMPT_LOG"
if [ "$FM_TEST_REVIEW_SCENARIO" = noisy-reviewer ]; then
  python3 "$FM_TEST_REVIEW_DRIVER" "$workdir" "$output" "$FM_TEST_REVIEW_SCENARIO" "$FM_TEST_HEAD"
  python3 -c 'import sys; sys.stdout.write("R" * 210000)'
  exit 0
fi
if [ "$FM_TEST_REVIEW_SCENARIO" = noisy-reviewer-no-result ]; then
  python3 -c 'import sys; sys.stdout.write("R" * 210000)'
  exit 0
fi
python3 "$FM_TEST_REVIEW_DRIVER" "$workdir" "$output" "$FM_TEST_REVIEW_SCENARIO" "$FM_TEST_HEAD"
SH
  chmod +x "$case_dir/fakebin/codex"
}

install_claude_fake() {
  local case_dir=$1
  cat > "$case_dir/fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CLAUDE_LOG"
[ "${CLAUDE_CONFIG_DIR:-}" = "$FM_TEST_REVIEWER_HOME" ] || exit 80
[ "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" = "$FM_TEST_REVIEWER_HOME" ] || exit 73
case "${HOME:-}" in
  "$PWD"/.crosscheck/claude-home) ;;
  *) exit 74 ;;
esac
[ "$(cd "$HOME/.claude" 2>/dev/null && pwd -P)" = "$FM_TEST_REVIEWER_HOME" ] \
  || exit 72
case "${CLAUDE_CODE_TMPDIR:-}" in
  "$PWD"/.crosscheck/claude-tmp) ;;
  *) exit 76 ;;
esac
mkdir -p "$CLAUDE_CODE_TMPDIR/bash-runtime" || exit 75
mkdir -p "$HOME/.claude/session-env" || exit 77
printf 'reviewer runtime state\n' > "$HOME/.claude/session-env/crosscheck-runtime" \
  || exit 78
[ "${1:-}" = -p ] || exit 81
shift
model=
effort=
autonomous=no
format=
schema=
prompt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --dangerously-skip-permissions) autonomous=yes; shift ;;
    --tools) [ "$2" = Bash,Read,Glob,Grep ] || exit 89; shift 2 ;;
    --no-session-persistence) shift ;;
    --output-format) format=$2; shift 2 ;;
    --json-schema) schema=$2; shift 2 ;;
    *) prompt=$1; shift ;;
  esac
done
[ "$model" = claude-opus-5 ] || exit 82
[ "$effort" = xhigh ] || exit 83
[ "$autonomous" = yes ] || exit 84
[ "$format" = json ] || exit 85
[ -n "$schema" ] && [ -n "$prompt" ] || exit 86
if [ "$FM_TEST_REVIEW_SCENARIO" != reading-only-suspicion ]; then
  if ! git -C "$PWD" diff "$FM_TEST_BASE..$FM_TEST_HEAD" -- app.txt \
    > "$HOME/.claude/session-env/crosscheck-git-diff" \
    2> "$HOME/.claude/session-env/crosscheck-git-diff.err"; then
    cat "$HOME/.claude/session-env/crosscheck-git-diff.err" >&2
    exit 79
  fi
fi
if [ "$FM_TEST_REVIEW_SCENARIO" = execution-home-drift ]; then
  CLAUDE_SECURESTORAGE_CONFIG_DIR=$FM_TEST_AUTHOR_HOME
  export CLAUDE_SECURESTORAGE_CONFIG_DIR
fi
temporary=$(mktemp "${TMPDIR:-/tmp}/fm-crosscheck-claude.XXXXXX") || exit 87
python3 "$FM_TEST_REVIEW_DRIVER" "$PWD" "$temporary" "$FM_TEST_REVIEW_SCENARIO" "$FM_TEST_HEAD" || exit 88
python3 - "$temporary" <<'PY'
import json
import os
import sys
structured = json.load(open(sys.argv[1]))
envelope = {
    "is_error": False,
    "subtype": "success",
    "terminal_reason": "completed",
    "structured_output": structured,
}
if os.environ["FM_TEST_REVIEW_SCENARIO"] == "noisy-reviewer":
    envelope["transcript"] = "R" * 210000
print(json.dumps(envelope))
PY
rm -f "$temporary"
SH
  chmod +x "$case_dir/fakebin/claude"
}

install_sandbox_fake() {
  local case_dir=$1
  cat > "$case_dir/fakebin/sandbox-exec" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -f ] || exit 70
[ -f "${2:-}" ] || exit 71
profile=$2
grep -qxF '(deny default)' "$profile" || exit 72
grep -qxF '(allow file-read*)' "$profile" || exit 73
case "${3:-}" in
  */claude)
    grep -qxF '(allow network*)' "$profile" || exit 74
    grep -qF "(subpath \"$FM_TEST_REVIEWER_HOME\")" "$profile" || exit 77
    if [ "$FM_TEST_AMBIENT_HOME" != "$FM_TEST_REVIEWER_HOME" ]; then
      ! grep -qF "(subpath \"$FM_TEST_AMBIENT_HOME/.claude/session-env\")" "$profile" \
        || exit 78
    fi
    ;;
  *)
    ! grep -qxF '(allow network*)' "$profile" || exit 76
    ;;
esac
grep -qF "(subpath \"$PWD\")" "$profile" || exit 75
shift 2
exec "$@"
SH
  chmod +x "$case_dir/fakebin/sandbox-exec"
}

cat > "$TMP_ROOT/review-driver.py" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

workdir = Path(sys.argv[1])
output = Path(sys.argv[2])
scenario = sys.argv[3]
head = sys.argv[4]

if scenario == "stopped":
    raise SystemExit(0)

protocol = workdir / ".crosscheck"
base_sha = os.environ["FM_TEST_BASE"]
execution = protocol / "reproductions" / "review-execution.sh"
receipt = protocol / "reproductions" / "review-execution.receipt"
execution.parent.mkdir(parents=True, exist_ok=True)
execution.write_text(
    "#!/usr/bin/env bash\n"
    "set -eu\n"
    "base=$1\n"
    "head=$2\n"
    "receipt=$3\n"
    "account=${CODEX_HOME:-${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}}\n"
    "git diff \"$base\" \"$head\" -- app.txt >/dev/null\n"
    "printf 'CROSSCHECK-REVIEW-EXECUTED base=%s head=%s HOME=%s account=%s\\n' "
    "\"$base\" \"$head\" \"$HOME\" \"$account\" | tee \"$receipt\"\n"
)
os.chmod(execution, 0o755)
command = (
    "bash .crosscheck/reproductions/review-execution.sh "
    f"{base_sha} {head} .crosscheck/reproductions/review-execution.receipt"
)
if scenario != "reading-only-suspicion":
    subprocess.run(
        [
            "bash",
            ".crosscheck/reproductions/review-execution.sh",
            base_sha,
            head,
            ".crosscheck/reproductions/review-execution.receipt",
        ],
        cwd=workdir,
        check=True,
        capture_output=True,
        text=True,
    )
account_selector = os.environ.get("CODEX_HOME") or os.environ.get(
    "CLAUDE_SECURESTORAGE_CONFIG_DIR", ""
)
base = {
    "schema": "firstmate.crosscheck-review.v2",
    "head_sha": head,
    "executing_account_home": str(Path(account_selector).resolve()),
    "execution_home": str(Path(os.environ["HOME"]).resolve()),
    "executed_reproduction": {
        "test_path": ".crosscheck/reproductions/review-execution.sh",
        "command": command,
        "expected_exit": 0,
        "output_contains": "CROSSCHECK-REVIEW-EXECUTED",
        "receipt_path": ".crosscheck/reproductions/review-execution.receipt",
        "receipt_contains": "CROSSCHECK-REVIEW-EXECUTED",
    },
    "summary": "review complete",
    "citations": [{"path": "app.txt", "line": 1}],
    "finding_updates": [],
    "new_findings": [],
    "suspicions": [],
}

if scenario == "wrong-head":
    base["head_sha"] = "f" * 40
elif scenario == "new-finding":
    reproduction = protocol / "reproductions" / "bug.sh"
    reproduction.parent.mkdir(parents=True, exist_ok=True)
    reproduction.write_text("#!/usr/bin/env bash\necho REPRODUCED-BUG\nexit 7\n")
    os.chmod(reproduction, 0o755)
    base["new_findings"] = [{
        "title": "Reproduced defect",
        "severity": "blocking",
        "description": "The executable reproduction demonstrates the defect.",
        "citations": [{"path": "app.txt", "line": 1}],
        "reproduction": {
            "test_path": ".crosscheck/reproductions/bug.sh",
            "command": "bash .crosscheck/reproductions/bug.sh",
            "expected_exit": 7,
            "output_contains": "REPRODUCED-BUG",
        },
    }]
elif scenario in {
    "verified-fixed",
    "missing-proof",
    "forged-command",
    "readable-state-forgery",
    "stateful-forgery",
    "support-forgery",
    "symlink-forgery",
    "unclassified-runner",
    "positional-target",
    "path-dependent",
}:
    patch = protocol / "mutations" / "revert.patch"
    if scenario in {
        "verified-fixed",
        "forged-command",
        "unclassified-runner",
        "positional-target",
        "path-dependent",
    }:
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text("""diff --git a/app.txt b/app.txt
--- a/app.txt
+++ b/app.txt
@@ -1 +1 @@
-fixed
+broken
""")
    elif scenario == "readable-state-forgery":
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text("""diff --git a/app.txt b/app.txt
--- a/app.txt
+++ b/app.txt
@@ -1 +1 @@
-fixed
+broken
""")
    elif scenario == "stateful-forgery":
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text("""diff --git a/other.txt b/other.txt
--- a/other.txt
+++ b/other.txt
@@ -1 +1 @@
-base
+irrelevant
""")
    elif scenario == "support-forgery":
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text("""diff --git a/tests/helper.sh b/tests/helper.sh
--- a/tests/helper.sh
+++ b/tests/helper.sh
@@ -1,2 +1,2 @@
 #!/usr/bin/env bash
-grep -qx fixed app.txt
+exit 41
""")
    elif scenario == "symlink-forgery":
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text("""diff --git a/shared-test.sh b/shared-test.sh
--- a/shared-test.sh
+++ b/shared-test.sh
@@ -1,2 +1,2 @@
 #!/usr/bin/env bash
-grep -qx fixed app.txt
+exit 41
""")
    test_path = {
        "readable-state-forgery": "tests/readable-state.test.sh",
        "stateful-forgery": "tests/stateful.test.sh",
        "support-forgery": "tests/support.test.sh",
        "symlink-forgery": "tests/symlink.test.sh",
        "positional-target": "tests/vacuous.test.sh",
        "path-dependent": "tests/pathdep.test.sh",
    }.get(scenario, "tests/regression.test.sh")
    # Only a runner whose non-execution the gate has measured can certify a
    # fix, so every scenario that must reach mutation causality names one.
    # The pytest double runs a plain `bash <file>` fixture unchanged.
    mutation_proof = {
        "test_path": test_path,
        "test_invocation": {
            "runner": "bash" if scenario == "unclassified-runner" else "pytest",
            # A second target whose result, unlike the vacuous named test's,
            # does depend on the mutated implementation.
            "arguments": (
                ["tests/regression.test.sh"]
                if scenario == "positional-target"
                else []
            ),
        },
        "mutation_patch_path": ".crosscheck/mutations/revert.patch",
    }
    if scenario == "forged-command":
        mutation_proof = {
            "test_path": test_path,
            "test_command": "git diff --quiet # tests/regression.test.sh",
            "mutation_patch_path": ".crosscheck/mutations/revert.patch",
        }
    base["finding_updates"] = [{
        "id": "cc-aaaaaaaaaaaa",
        "status": "verified-fixed",
        "note": "The named regression test detects a reverted fix.",
        "reproduction": None,
        "mutation_proof": mutation_proof,
        "equivalent_to": None,
    }]
elif scenario in {
    "node-id-proof",
    "node-id-unmatched",
    "node-id-mutated-nonexecution",
    "absent-runner",
    "linked-directory-test",
    "flag-argument",
}:
    patch = protocol / "mutations" / "revert.patch"
    patch.parent.mkdir(parents=True, exist_ok=True)
    patch.write_text("""diff --git a/app.txt b/app.txt
--- a/app.txt
+++ b/app.txt
@@ -1 +1 @@
-fixed
+broken
""")
    selector = {
        "node-id-unmatched": "tests/nodeid.test.sh::test_never_defined",
        "linked-directory-test": "tests/linked/linked.test.sh",
        "absent-runner": "tests/nodeid.test.sh",
    }.get(scenario, "tests/nodeid.test.sh::test_app_is_fixed")
    base["finding_updates"] = [{
        "id": "cc-aaaaaaaaaaaa",
        "status": "verified-fixed",
        "note": "A node-id selector names the regression test that pins the fix.",
        "reproduction": None,
        "mutation_proof": {
            "test_path": selector,
            "test_invocation": {
                "runner": "vitest" if scenario == "absent-runner" else "pytest",
                # A flag that turns a mutation the runner could not collect
                # into an ordinary failing test, which reads as a catch.
                "arguments": (
                    ["--continue-on-collection-errors"]
                    if scenario == "flag-argument"
                    else []
                ),
            },
            "mutation_patch_path": ".crosscheck/mutations/revert.patch",
        },
        "equivalent_to": None,
    }]
elif scenario == "escaped-reproduction":
    base["new_findings"] = [{
        "title": "Escaped evidence",
        "severity": "blocking",
        "description": "The helper resolves outside its designated subtree.",
        "citations": [{"path": "app.txt", "line": 1}],
        "reproduction": {
            "test_path": ".crosscheck/reproductions/../../tests/regression.test.sh",
            "command": "bash .crosscheck/reproductions/../../tests/regression.test.sh",
            "expected_exit": 0,
            "output_contains": "UNREACHABLE-MARKER",
        },
    }]
elif scenario == "reviewer-env-dependent-execution":
    # The reviewer's own run has its provider account environment; the gate's
    # independent re-run does not. A helper that requires it exits nonzero
    # there without ever reproducing anything.
    execution.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        "base=$1\n"
        "head=$2\n"
        "receipt=$3\n"
        "account=$CODEX_HOME\n"
        "git diff \"$base\" \"$head\" -- app.txt >/dev/null\n"
        "printf 'CROSSCHECK-REVIEW-EXECUTED base=%s head=%s HOME=%s account=%s\\n' "
        "\"$base\" \"$head\" \"$HOME\" \"$account\" | tee \"$receipt\"\n"
    )
    os.chmod(execution, 0o755)
    subprocess.run(
        [
            "bash",
            ".crosscheck/reproductions/review-execution.sh",
            base_sha,
            head,
            ".crosscheck/reproductions/review-execution.receipt",
        ],
        cwd=workdir,
        check=True,
        capture_output=True,
        text=True,
    )
elif scenario == "unfound-reproduction-command":
    reproduction = protocol / "reproductions" / "missing-tool.sh"
    reproduction.parent.mkdir(parents=True, exist_ok=True)
    reproduction.write_text(
        "#!/usr/bin/env bash\nexec fm-definitely-not-installed-xyz\n"
    )
    os.chmod(reproduction, 0o755)
    base["new_findings"] = [{
        "title": "Evidence needing absent tooling",
        "severity": "blocking",
        "description": "The helper invokes a tool the review checkout does not carry.",
        "citations": [{"path": "app.txt", "line": 1}],
        "reproduction": {
            "test_path": ".crosscheck/reproductions/missing-tool.sh",
            "command": "bash .crosscheck/reproductions/missing-tool.sh",
            "expected_exit": 7,
            "output_contains": "REPRODUCED-BUG",
        },
    }]
elif scenario == "noisy-reproduction":
    reproduction = protocol / "reproductions" / "noisy.sh"
    reproduction.parent.mkdir(parents=True, exist_ok=True)
    reproduction.write_text("#!/usr/bin/env bash\npython3 -c 'import sys; sys.stdout.write(\"E\" * 210000)'\n")
    os.chmod(reproduction, 0o755)
    base["new_findings"] = [{
        "title": "Noisy evidence",
        "severity": "blocking",
        "description": "The helper exceeds the evidence output budget.",
        "citations": [{"path": "app.txt", "line": 1}],
        "reproduction": {
            "test_path": ".crosscheck/reproductions/noisy.sh",
            "command": "bash .crosscheck/reproductions/noisy.sh",
            "expected_exit": 0,
            "output_contains": "E",
        },
    }]
elif scenario == "slow-reproduction":
    reproduction = protocol / "reproductions" / "slow.sh"
    reproduction.parent.mkdir(parents=True, exist_ok=True)
    reproduction.write_text("#!/usr/bin/env bash\nsleep 3\necho SLOW-REPRODUCTION\nexit 7\n")
    os.chmod(reproduction, 0o755)
    base["new_findings"] = [{
        "title": "Slow evidence",
        "severity": "blocking",
        "description": "The reproduction consumes the aggregate evidence budget.",
        "citations": [{"path": "app.txt", "line": 1}],
        "reproduction": {
            "test_path": ".crosscheck/reproductions/slow.sh",
            "command": "bash .crosscheck/reproductions/slow.sh",
            "expected_exit": 7,
            "output_contains": "SLOW-REPRODUCTION",
        },
    }]
elif scenario == "too-many-items":
    base["suspicions"] = [{
        "description": f"Bounded suspicion {index}",
        "citations": [{"path": "app.txt", "line": 1}],
    } for index in range(33)]
elif scenario == "suspicion":
    base["suspicions"] = [{
        "description": "The reviewer could not finish a reproduction.",
        "citations": [{"path": "app.txt", "line": 1}],
    }]
elif scenario == "reading-only-suspicion":
    base["suspicions"] = [{
        "description": "The reviewer reported a concern without executing a command.",
        "citations": [{"path": "app.txt", "line": 1}],
    }]
    del base["executed_reproduction"]
    execution.unlink()
    receipt.unlink(missing_ok=True)

if scenario == "bulky-unauthorized-scratch":
    # Unauthorized scratch is a refusal either way. It must be refused by NAME,
    # not by the integrity inspection running out of output budget.
    for index in range(12000):
        (workdir / f"scratch-{index:06d}.txt").write_text("x")

if scenario == "tampered-checkout":
    # Collapsing untracked evidence into one status entry must not hide a
    # reviewer that edited tracked code or wrote outside .crosscheck/.
    (workdir / "app.txt").write_text("tampered\n")
    (workdir / "tests" / "sneaky.sh").write_text("#!/usr/bin/env bash\n")

if scenario == "bulky-evidence":
    # A reviewer that substantiates a finding writes real evidence. Listing it
    # file by file used to exceed the gate's bounded-output limit and refuse the
    # review for doing its job.
    bulk = protocol / "bulk"
    bulk.mkdir(parents=True, exist_ok=True)
    filler = "e" * 200
    for index in range(1200):
        (bulk / f"evidence-{index:05d}-{filler}").write_text("x")

if scenario == "oversized-artifact":
    base["summary"] = "A" * 210000

output.write_text(json.dumps(base))
PY

run_case() {
  local case_dir=$1 base=$2 head=$3 scenario=$4 command=${5:-run}
  shift 5 || true
  FM_ROOT_OVERRIDE="${FM_TEST_ROOT_OVERRIDE-$ROOT}" \
  FM_HOME="${FM_TEST_HOME-$case_dir/home}" \
  FM_STATE_OVERRIDE="${FM_TEST_STATE_OVERRIDE-$case_dir/state}" \
  FM_DATA_OVERRIDE="${FM_TEST_DATA_OVERRIDE-$case_dir/data}" \
  FM_GH_AXI_BIN="$case_dir/fakebin/gh-axi" \
  FM_CROSSCHECK_CODEX_BIN="$case_dir/fakebin/codex" \
  FM_CROSSCHECK_CLAUDE_BIN="$case_dir/fakebin/claude" \
  FM_CROSSCHECK_SANDBOX_BIN="$case_dir/fakebin/sandbox-exec" \
  FM_CROSSCHECK_FETCH_REMOTE="${FM_TEST_FETCH_REMOTE-$case_dir/repo}" \
  FM_CROSSCHECK_REVIEWER_CONFIG="$case_dir/reviewer.json" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_CODEX_LOG="$case_dir/codex.log" \
  FM_TEST_CLAUDE_LOG="$case_dir/claude.log" \
  FM_TEST_PROMPT_LOG="$case_dir/prompt.log" \
  FM_TEST_API_FIXTURE="$API_FIXTURE" \
  FM_TEST_CLAIMS_FIXTURE="$CLAIMS_FIXTURE" \
  FM_TEST_REVIEW_DRIVER="$TMP_ROOT/review-driver.py" \
  FM_TEST_REVIEW_SCENARIO="$scenario" \
  FM_TEST_REVIEWER_HOME="$case_dir/reviewer-home" \
  FM_TEST_AUTHOR_HOME="$case_dir/author-home" \
  FM_TEST_AMBIENT_HOME="$HOME" \
  FM_TEST_BASE="$base" \
  FM_TEST_HEAD="$head" \
  PATH="$case_dir/pathbin:$PATH" \
    python3 "$CROSSCHECK_PY" "$command" task-x1 "$PR_URL" "$@"
}

seed_open_ledger() {
  local case_dir=$1 head=$2
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<JSON
{
  "schema": "firstmate.crosscheck-ledger.v2",
  "task_id": "task-x1",
  "pull_request": "https://github.com/ruby-dlee/firstmate/pull/72",
  "findings": [{
    "id": "cc-aaaaaaaaaaaa",
    "lifecycle": "open",
    "title": "Prior blocker",
    "severity": "blocking",
    "description": "A durable reproduced blocker.",
    "citations": [{"path": "app.txt", "line": 1}],
    "history": [{
      "at": "2026-08-02T00:00:00Z",
      "head_sha": "$head",
      "status": "open",
      "note": "Seeded reproduced blocker.",
      "proof": null
    }]
  }],
  "runs": []
}
JSON
}

# A ledger recorded before mutation proofs had to be argument-free. It must
# still load - the durable findings in it are not disposable - while the proof
# itself no longer certifies anything.
seed_argument_proof_ledger() {
  local case_dir=$1 head=$2
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<JSON
{
  "schema": "firstmate.crosscheck-ledger.v2",
  "task_id": "task-x1",
  "pull_request": "https://github.com/ruby-dlee/firstmate/pull/72",
  "findings": [{
    "id": "cc-aaaaaaaaaaaa",
    "lifecycle": "verified-fixed",
    "title": "Prior blocker",
    "severity": "blocking",
    "description": "A durable reproduced blocker.",
    "citations": [{"path": "app.txt", "line": 1}],
    "history": [{
      "at": "2026-08-02T00:00:00Z",
      "head_sha": "$head",
      "status": "verified-fixed",
      "note": "Proof recorded before runner arguments were refused.",
      "proof": {
        "test_path": "tests/vacuous.test.sh",
        "test_invocation": {
          "runner": "pytest",
          "arguments": ["tests/regression.test.sh"]
        },
        "mutation_patch_sha256": "$(printf 'a%.0s' $(seq 64))",
        "mutated_files": ["app.txt"],
        "baseline_exit": 0,
        "mutated_exit": 1,
        "baseline_output": "",
        "mutated_output": ""
      }
    }]
  }],
  "runs": []
}
JSON
}

select_claude_reviewer() {
  local case_dir=$1
  sed -i.bak 's/model=gpt-5.5/model=gpt-5.6-sol/' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  cat > "$case_dir/reviewer.json" <<EOF
{"reviewers":[
  {"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh","account_home":"$case_dir/author-home"},
  {"harness":"claude","model":"claude-opus-5","effort":"xhigh","account_home":"$case_dir/reviewer-home"}
]}
EOF
}

test_clear_review_uses_policy_contract() {
  local record case_dir base head output
  record=$(make_case clear)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  : > "$case_dir/gh.log"
  : > "$case_dir/codex.log"
  output=$(run_case "$case_dir" "$base" "$head" clear run) \
    || fail "clear review did not complete"
  assert_contains "$output" "crosscheck clear" "clear review did not report success"
  assert_grep '--model gpt-5.6-sol' "$case_dir/codex.log" \
    "reviewer was not pinned to gpt-5.6-sol"
  assert_grep 'model_reasoning_effort="xhigh"' "$case_dir/codex.log" \
    "reviewer was not pinned to xhigh"
  assert_no_grep '--ask-for-approval' "$case_dir/codex.log" \
    "reviewer used a flag absent from the installed Codex contract"
  assert_grep 'BEGIN UNTRUSTED PR CLAIMS DATA' "$case_dir/prompt.log" \
    "PR claims were not delimited as untrusted data"
  assert_grep 'Do not spend this bounded independent-review run repeating the full suite' "$case_dir/prompt.log" \
    "reviewer was not directed toward focused evidence"
  pass "clear review uses the observed policy-grade Codex invocation"
}

test_empty_runtime_overrides_use_home_defaults() {
  local record case_dir base head output observation state_temp
  record=$(make_case empty-runtime-overrides)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data"
  mv "$case_dir/state/task-x1.meta" "$case_dir/home/state/task-x1.meta"
  observation="$case_dir/state-observation"
  output=$(
    cd "$case_dir" || exit 1
    FM_TEST_ROOT_OVERRIDE='' FM_TEST_STATE_OVERRIDE='' FM_TEST_DATA_OVERRIDE='' \
    FM_TEST_STATE_OBSERVATION="$observation" \
    FM_TEST_EXPECTED_STATE="$case_dir/home/state" \
    FM_TEST_CALLER_CWD="$case_dir" \
      run_case "$case_dir" "$base" "$head" clear run
  ) || fail "empty runtime overrides did not fall back to the home defaults"
  assert_contains "$output" 'crosscheck clear' \
    "empty runtime overrides did not reach the task metadata under FM_HOME"
  assert_present "$case_dir/home/data/task-x1/crosscheck-ledger.json" \
    "empty FM_DATA_OVERRIDE did not resolve to FM_HOME/data"
  assert_absent "$case_dir/task-x1.meta" \
    "empty FM_STATE_OVERRIDE was treated as the current working directory"
  assert_present "$case_dir/home/state/.task-x1.crosscheck.lock" \
    "the per-task lock did not use the resolved state directory"
  assert_grep "$case_dir/home/state/.task-x1.crosscheck.lock" "$observation" \
    "the reviewer did not observe the shared per-task lock under resolved state"
  state_temp=$(grep -F "$case_dir/home/state/.task-x1.crosscheck." "$observation" \
    | grep -vF '.crosscheck.lock' || true)
  [ -n "$state_temp" ] \
    || fail "the reviewer did not observe the temporary checkout under resolved state"
  assert_no_grep "$case_dir/.task-x1.crosscheck." "$observation" \
    "an empty state override placed a lock or temporary checkout in the caller cwd"
  assert_absent "$case_dir/.task-x1.crosscheck.lock" \
    "an empty state override created a cwd-local per-task lock"
  pass "empty overrides keep metadata, the shared task lock, and review temp space under home defaults"
}

test_empty_environment_fallback_is_generic() {
  python3 - "$CROSSCHECK_PY" <<'PY' \
    || fail "generic environment fallback did not treat empty as absent"
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
name = "FM_FUTURE_OPERATIONAL_OVERRIDE"
os.environ.pop(name, None)
assert module.environment_value(name, "/default") == "/default"
os.environ[name] = ""
assert module.environment_value(name, "/default") == "/default"
os.environ[name] = "/explicit"
assert module.environment_value(name, "/default") == "/explicit"
PY
  pass "the environment accessor handles absent, empty, and set values without a variable allowlist"
}

test_set_runtime_overrides_remain_authoritative() {
  local record case_dir base head explicit_state explicit_data observation output
  record=$(make_case set-runtime-overrides)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  explicit_state="$case_dir/explicit-state"
  explicit_data="$case_dir/explicit-data"
  observation="$case_dir/explicit-state-observation"
  mkdir -p "$explicit_state" "$explicit_data"
  mv "$case_dir/state/task-x1.meta" "$explicit_state/task-x1.meta"
  output=$(FM_TEST_STATE_OVERRIDE="$explicit_state" FM_TEST_DATA_OVERRIDE="$explicit_data" \
    FM_TEST_STATE_OBSERVATION="$observation" \
    FM_TEST_EXPECTED_STATE="$explicit_state" \
    FM_TEST_CALLER_CWD="$case_dir" \
    run_case "$case_dir" "$base" "$head" clear run) \
    || fail "nonempty runtime overrides were not honoured"
  assert_contains "$output" 'crosscheck clear' \
    "nonempty FM_STATE_OVERRIDE did not select the explicit task metadata"
  assert_present "$explicit_data/task-x1/crosscheck-ledger.json" \
    "nonempty FM_DATA_OVERRIDE did not select the explicit data directory"
  assert_absent "$case_dir/home/data/task-x1/crosscheck-ledger.json" \
    "the explicit data override was silently ignored"
  assert_present "$explicit_state/.task-x1.crosscheck.lock" \
    "the explicit state override did not own the shared per-task lock"
  assert_grep "$explicit_state/.task-x1.crosscheck.lock" "$observation" \
    "the reviewer did not observe the lock under the explicit state override"
  assert_no_grep "$case_dir/.task-x1.crosscheck." "$observation" \
    "a nonempty state override placed a lock or temporary checkout in the caller cwd"
  pass "nonempty state and data overrides remain authoritative for metadata, locks, temp space, and ledgers"
}

test_bad_state_override_is_a_named_tool_failure() {
  local record case_dir base head bad_state rc
  record=$(make_case bad-state-override)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  bad_state="$case_dir/incorrect-state"
  set +e
  FM_TEST_STATE_OVERRIDE="$bad_state" \
    run_case "$case_dir" "$base" "$head" clear run \
      > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "incorrect explicit state override"
  assert_grep "CROSSCHECK TOOL-FAILURE: task metadata inspection failed at $bad_state/task-x1.meta:" \
    "$case_dir/err" \
    "state-path failure did not name the inspected metadata path: $(tr '\n' ' ' < "$case_dir/err")"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "a pre-review environment failure was mislabeled as a review outcome"
  assert_absent "$case_dir/codex.log" \
    "reviewer launched after task metadata preflight failed"
  pass "an incorrect state override is a path-specific tool failure, not an unreviewed verdict"
}

test_review_fetches_exact_pr_head_when_author_worktree_is_behind() {
  local record case_dir base author_head pr_head output
  record=$(make_case behind-author-worktree)
  IFS=$'\t' read -r case_dir base author_head <<< "$record"
  pr_head=$(printf 'pipeline fix\n' | git -C "$case_dir/repo" commit-tree \
    "$(git -C "$case_dir/repo" rev-parse 'HEAD^{tree}')" -p "$author_head") \
    || fail "could not construct the pipeline-fix head fixture"
  git -C "$case_dir/repo" update-ref refs/pull/72/head "$pr_head"
  [ "$(git -C "$case_dir/repo" rev-parse HEAD)" = "$author_head" ] \
    || fail "pipeline-fix fixture moved the author worktree"
  output=$(run_case "$case_dir" "$base" "$pr_head" clear run) \
    || fail "exact PR-head review rejected a legitimately behind author worktree"
  assert_contains "$output" "crosscheck clear: $PR_URL at $pr_head" \
    "clear output did not name the fetched PR head"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
run = value["runs"][-1]
assert run["head_sha"] == sys.argv[2]
assert run["state"] == "clear"
' "$case_dir/data/task-x1/crosscheck-ledger.json" "$pr_head" \
    || fail "the durable verdict was not bound to the fetched PR head"
  assert_grep "exact head $pr_head" "$case_dir/prompt.log" \
    "reviewer prompt did not name the fetched exact head"
  pass "a pipeline-updated PR is reviewed at its exact remote head while the author worktree remains behind"
}

test_missing_pr_head_ref_fails_closed() {
  local record case_dir base head rc
  record=$(make_case missing-pr-head-ref)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  git -C "$case_dir/repo" update-ref -d refs/pull/72/head
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing remote PR head ref"
  assert_grep 'CROSSCHECK TOOL-FAILURE: review checkout preflight failed: PR head fetch failed:' \
    "$case_dir/err" \
    "unresolvable PR head did not fail as a named checkout tool fault: $(tr '\n' ' ' < "$case_dir/err")"
  assert_grep 'refs/pull/72/head' "$case_dir/err" \
    "PR-head failure did not name the exact remote ref inspected"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "unresolvable PR head collapsed into a review verdict"
  assert_no_grep 'CROSSCHECK BLOCKING' "$case_dir/err" \
    "unresolvable PR head collapsed into a blocking verdict"
  assert_absent "$case_dir/codex.log" \
    "reviewer launched without resolving the exact PR head"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
run = value["runs"][-1]
assert run["state"] == "tool-failure"
assert run["head_sha"] == sys.argv[2]
' "$case_dir/data/task-x1/crosscheck-ledger.json" "$head" \
    || fail "the exact-head fetch failure was not durably classified as a tool failure"
  pass "an absent remote PR head ref fails closed before review"
}

test_claude_reviewer_provides_model_separation_for_codex_author() {
  local record case_dir base head output
  record=$(make_case claude-reviewer)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  select_claude_reviewer "$case_dir"
  output=$(run_case "$case_dir" "$base" "$head" clear run) \
    || fail "Claude reviewer did not complete"
  assert_contains "$output" 'crosscheck clear' "Claude reviewer did not earn a clear result"
  assert_grep '--model claude-opus-5 --effort xhigh --dangerously-skip-permissions --tools Bash,Read,Glob,Grep' "$case_dir/claude.log" \
    "Claude reviewer was not pinned to the observed policy-grade invocation"
  assert_present "$case_dir/reviewer-home/session-env/crosscheck-runtime" \
    "Claude reviewer could not write runtime state beneath its bound HOME"
  assert_grep '+fixed' "$case_dir/reviewer-home/session-env/crosscheck-git-diff" \
    "Claude reviewer did not execute git diff between the exact base and head"
  assert_absent "$HOME/.claude/session-env/crosscheck-runtime" \
    "Claude reviewer wrote runtime state beneath the ambient operator HOME"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
reviewer = value["runs"][-1]["reviewer"]
assert reviewer["account_home"] == sys.argv[2]
assert reviewer["executing_account_home"] == sys.argv[2]
assert reviewer["execution_home"].endswith("/.crosscheck/claude-home")
assert reviewer["credential_source"] == "oauth-file"
assert reviewer["account_selector"] == "CLAUDE_SECURESTORAGE_CONFIG_DIR"
assert reviewer["execution_proof"]["actual_exit"] == 0
assert reviewer["execution_proof"]["reviewer_receipt"]["sha256"]
assert sys.argv[3] in reviewer["execution_proof"]["command"]
assert sys.argv[4] in reviewer["execution_proof"]["command"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "$case_dir/reviewer-home" "$base" "$head" \
    || fail "Claude verdict did not record the bound executing account and exact-SHA command proof"
  assert_absent "$case_dir/codex.log" "Codex reviewer launched without model separation"
  pass "Claude Opus xhigh binds HOME, account independence, sandbox writes, and exact-SHA execution evidence"
}

test_codex_reviewer_requires_bound_auth_and_clears_ambient_credentials() {
  local record case_dir base head rc output
  record=$(make_case codex-bound-auth)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  output=$(OPENAI_API_KEY=ambient-openai CODEX_API_KEY=ambient-codex \
    CODEX_ACCESS_TOKEN=ambient-access CODEX_REFRESH_TOKEN=ambient-refresh \
    CODEX_REVOKE_TOKEN=ambient-revoke \
    run_case "$case_dir" "$base" "$head" clear run) \
    || fail "Codex reviewer did not use its bound auth file"
  assert_contains "$output" 'crosscheck clear' \
    "bound Codex auth file did not earn a clear review"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
reviewer = value["runs"][-1]["reviewer"]
assert reviewer["credential_source"] == "codex-auth-file"
assert reviewer["credential_identifier"] == sys.argv[2]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "$case_dir/reviewer-home/auth.json" \
    || fail "Codex credential binding was not recorded"

  rm "$case_dir/reviewer-home/auth.json"
  set +e
  OPENAI_API_KEY=ambient-openai run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/missing-auth.out" 2> "$case_dir/missing-auth.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing Codex reviewer auth"
  assert_grep 'Codex executing-account credential inspection failed at' \
    "$case_dir/missing-auth.err" \
    "missing bound Codex auth did not fail credential preflight"
  assert_no_grep 'crosscheck clear' "$case_dir/missing-auth.out" \
    "ambient API key earned a review without bound Codex auth"

  printf '{}\n' > "$case_dir/reviewer-home/auth.json"
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/unusable-auth.out" 2> "$case_dir/unusable-auth.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unusable Codex reviewer auth"
  assert_grep 'CROSSCHECK TOOL-FAILURE: Codex executing-account credential is unusable' \
    "$case_dir/unusable-auth.err" \
    "unusable Codex auth was not classified as a tool failure"
  pass "Codex reviewer requires bound auth and rejects ambient credential selectors"
}

test_reviewer_execution_home_drift_fails_closed() {
  local record case_dir base head rc
  record=$(make_case reviewer-execution-home-drift)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  sed -i.bak 's/model=gpt-5.5/model=gpt-5.6-sol/' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  cat > "$case_dir/reviewer.json" <<EOF
{"reviewers":[{"harness":"claude","model":"claude-opus-5","effort":"xhigh","account_home":"$case_dir/reviewer-home"}]}
EOF
  set +e
  run_case "$case_dir" "$base" "$head" execution-home-drift run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reviewer execution-home drift"
  assert_grep 'CROSSCHECK TOOL-FAILURE:' "$case_dir/err" \
    "execution-account drift was not classified as a tool failure"
  assert_grep 'reviewer executing-account inspection found a provider account selector' "$case_dir/err" \
    "execution-account drift did not name the identity actually inspected"
  assert_no_grep 'CROSSCHECK BLOCKING' "$case_dir/err" \
    "a configured reviewer label overrode the executing account identity"
  assert_no_grep 'crosscheck clear' "$case_dir/out" \
    "a reviewer running under the author HOME earned a clear result"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["runs"][-1]["state"] == "tool-failure"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "execution-account drift was not durably classified as a tool failure"
  pass "reviewer independence is bound to the executing credential selector, not its configured label"
}

test_unrouted_author_uses_cross_provider_independence() {
  local record case_dir base head output
  record=$(make_case unrouted-cross-provider)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  sed -i.bak '/^account_home=/d' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  printf 'account_routing_emergency_bypass=1\n' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/reviewer.json" <<EOF
{"reviewers":[{"harness":"claude","model":"claude-opus-5","effort":"xhigh","account_home":"$case_dir/reviewer-home"}]}
EOF
  output=$(run_case "$case_dir" "$base" "$head" clear run) \
    || fail "cross-provider reviewer did not establish independence for an unrouted author"
  assert_contains "$output" 'crosscheck clear' \
    "structurally unrouted task did not earn a cross-provider clear result"
  assert_grep '--model claude-opus-5' "$case_dir/claude.log" \
    "the independent provider reviewer was not launched"
  assert_absent "$case_dir/codex.log" \
    "same-provider reviewer launched for an author with no account identity"
  pass "a structurally unrouted author can prove both model and account independence across providers"
}

test_unrouted_author_without_account_proof_fails_closed() {
  local record case_dir base head rc ledger
  record=$(make_case unrouted-same-provider)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  sed -i.bak '/^account_home=/d' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  printf 'account_routing_emergency_bypass=1\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "same-provider reviewer for an unrouted author"
  assert_grep 'CROSSCHECK TOOL-FAILURE: reviewer preflight failed: independence inspection found no configured reviewer' \
    "$case_dir/err" \
    "unprovable account independence did not fail as a reviewer preflight fault: $(tr '\n' ' ' < "$case_dir/err")"
  assert_grep 'same-provider account separation cannot be proved without account_home' \
    "$case_dir/err" "failure did not name the unavailable author-account proof"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "unprovable pre-review identity was mislabeled as a review outcome"
  assert_absent "$case_dir/codex.log" \
    "same-provider reviewer launched without author-account proof"
  ledger="$case_dir/data/task-x1/crosscheck-ledger.json"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["runs"][-1]["state"] == "tool-failure"
assert value["runs"][-1]["reviewer"] is None
' "$ledger" || fail "unprovable independence was not recorded as a tool failure"
  pass "an unrouted same-provider lane fails closed when account independence cannot be established"
}

test_missing_author_identity_is_a_named_tool_failure() {
  local record case_dir base head rc
  record=$(make_case missing-author-identity)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  sed -i.bak '/^account_home=/d' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "task metadata with no author identity structure"
  assert_grep 'author identity inspection found neither account_home nor account_routing_emergency_bypass=1' \
    "$case_dir/err" "metadata failure did not name both inspected identity fields"
  assert_grep 'CROSSCHECK TOOL-FAILURE:' "$case_dir/err" \
    "metadata preflight failure did not use the tool-failure outcome: $(tr '\n' ' ' < "$case_dir/err")"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "metadata preflight failure was mislabeled as a review outcome"
  pass "missing author identity structure is a named metadata tool failure"
}

test_new_finding_requires_executed_reproduction() {
  local record case_dir base head rc ledger
  record=$(make_case new-finding)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" new-finding run > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reproduced finding"
  assert_grep 'CROSSCHECK BLOCKING:' "$case_dir/err" \
    "a completed review with reproduced code evidence was not classified as blocking"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "a blocking code verdict collapsed into a non-verdict outcome"
  assert_no_grep 'CROSSCHECK TOOL-FAILURE' "$case_dir/err" \
    "a blocking code verdict collapsed into a tool failure"
  ledger="$case_dir/data/task-x1/crosscheck-ledger.json"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
finding = value["findings"][0]
proof = finding["history"][0]["proof"]
assert finding["lifecycle"] == "open"
assert proof["actual_exit"] == 7
assert "REPRODUCED-BUG" in proof["output"]
assert value["runs"][-1]["state"] == "blocking"
' "$ledger" || fail "executed reproduction was not durably recorded"
  pass "new finding enters the ledger only with gate-executed reproduction evidence"
}

test_silence_never_closes_prior_finding() {
  local record case_dir base head rc
  record=$(make_case silence)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" clear run > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "silent later review"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open"
assert value["runs"][-1]["active_blockers"] == ["cc-aaaaaaaaaaaa"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "silent review changed or dropped the prior blocker"
  pass "silence from a later run never closes an old finding"
}

test_verified_fix_executes_mutation_proof() {
  local record case_dir base head
  record=$(make_case verified-fixed)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/out" 2> "$case_dir/err" || fail "valid mutation proof did not clear"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
finding = value["findings"][0]
proof = finding["history"][-1]["proof"]
assert finding["lifecycle"] == "verified-fixed"
assert proof["baseline_exit"] == 0
assert proof["mutated_exit"] != 0
assert proof["mutated_files"] == ["app.txt"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "mutation proof execution was not durably recorded"
  pass "verified-fixed requires a passing named test that fails after implementation mutation"
}

test_node_id_selector_clears_a_passing_named_test() {
  local record case_dir base head
  record=$(make_case node-id-proof)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  run_case "$case_dir" "$base" "$head" node-id-proof run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "node-id mutation proof did not clear: $(cat "$case_dir/err")"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
finding = value["findings"][0]
proof = finding["history"][-1]["proof"]
assert finding["lifecycle"] == "verified-fixed", finding["lifecycle"]
assert proof["test_path"] == "tests/nodeid.test.sh::test_app_is_fixed", proof["test_path"]
assert proof["baseline_exit"] == 0
assert proof["mutated_exit"] != 0
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "node-id proof was not durably recorded with its full selector"
  pass "a runner node id names a test the gate can execute and clear"
}

test_absent_runner_is_never_a_test_outcome() {
  local record case_dir base head rc
  record=$(make_case absent-runner)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" absent-runner run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "absent named runner"
  assert_grep 'is not installed on PATH' "$case_dir/err" \
    "an uninstalled runner was not named as the reason no test ran"
  if grep -q 'does not pass before mutation' "$case_dir/err"; then
    fail "an uninstalled runner was misreported as a failing test"
  fi
  pass "an uninstalled runner is named, never reported as a failing test"
}

# A mutated run that never reached the test exits nonzero exactly like one that
# caught the regression. Only a runner whose non-execution status the gate has
# measured can tell those apart, so any other runner must be refused by name
# rather than certified on an exit status the gate would have to guess at.
test_unclassified_runner_cannot_clear_a_finding() {
  local record case_dir base head rc
  record=$(make_case unclassified-runner)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" unclassified-runner run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mutation proof on an unclassified runner"
  assert_grep 'bash' "$case_dir/err" \
    "the refusal did not name the runner whose non-execution is unclassified"
  assert_grep 'no measured non-execution signal' "$case_dir/err" \
    "the refusal did not say why that runner cannot certify a fix"
  assert_grep 'classify: pytest' "$case_dir/err" \
    "the refusal did not name the runners the gate can classify"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "an unclassified runner cleared a finding"
  pass "a runner with no measured non-execution signal cannot certify a fix"
}

# The classified non-execution signal is a property of the runner's DEFAULT exit
# semantics. --continue-on-collection-errors changes them: a mutation the runner
# could not collect stops reporting the no-tests-collected status and reports an
# ordinary failure instead, which carries no classification and so reads as a
# caught regression. Before arguments were refused, that cleared the finding.
test_flag_argument_cannot_rewrite_the_non_execution_signal() {
  local record case_dir base head rc
  record=$(make_case flag-argument)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  printf '5\n' > "$case_dir/pathbin/collection-exit"
  set +e
  run_case "$case_dir" "$base" "$head" flag-argument run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mutation proof carrying a runner flag"
  assert_grep "must be empty for a mutation proof, but names '--continue-on-collection-errors'" \
    "$case_dir/err" "the refusal did not name the rejected flag"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "a flag that rewrote the non-execution signal cleared a finding"
  pass "a runner flag cannot rewrite the exit semantics the gate classifies"
}

# The gate validates exactly one target: test_path, which it checks is tracked,
# refuses when it traverses a symlink, and protects from the mutation patch. A
# positional argument adds a second target that gets none of those checks, so
# the mutated run can fail on that file while the named test - here deliberately
# vacuous - proves nothing. Before this was refused, that cleared the finding.
test_positional_argument_cannot_supply_a_second_target() {
  local record case_dir base head rc
  record=$(make_case positional-target)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" positional-target run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mutation proof carrying a positional second target"
  assert_grep "must be empty for a mutation proof, but names 'tests/regression.test.sh'" \
    "$case_dir/err" "the refusal did not name the rejected positional argument"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "a vacuous named test cleared a finding through a second target"
  pass "a positional argument cannot smuggle in a second, unvalidated test target"
}

test_unmatched_selector_is_never_a_failing_test() {
  local record case_dir base head rc
  record=$(make_case node-id-unmatched)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" node-id-unmatched run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "selector matching no test"
  assert_grep 'never ran its named test' "$case_dir/err" \
    "a selector that matched no test was not reported as a non-execution"
  if grep -q 'does not pass before mutation' "$case_dir/err"; then
    fail "a test that never ran was misreported as a failing test"
  fi
  pass "a selector that matches no test is a non-execution, not a failure"
}

test_mutated_non_execution_cannot_clear_a_finding() {
  local record case_dir base head rc
  record=$(make_case node-id-mutated-nonexecution)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  printf '5\n' > "$case_dir/pathbin/collection-exit"
  set +e
  run_case "$case_dir" "$base" "$head" node-id-mutated-nonexecution run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mutated run that never executed the test"
  assert_grep 'never ran its named test' "$case_dir/err" \
    "a mutated run that never executed the test was not named as a non-execution"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "a mutation that only broke collection cleared the finding"
  pass "a mutated run that never executed the test cannot clear a finding"
}

# The same bypass again through a third channel needing no reviewer: pytest
# walks every parent to the filesystem root for a config, so an operator
# pytest.ini above the gate's temporary root sets addopts for every proof on
# the machine. The gate ends that walk with a neutral file in the root it owns.
# The second half asserts the deliberately accepted surface is still intact:
# the reviewed repository's own config sits closer to the named test and must
# still win, which is proved here rather than assumed.
test_ancestor_runner_config_cannot_rewrite_the_non_execution_signal() {
  local record case_dir base head rc
  record=$(make_case ancestor-runner-config)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  printf '2\n' > "$case_dir/pathbin/collection-exit"
  # Above the gate's temporary root, which it creates inside the state dir.
  printf '[pytest]\naddopts = --continue-on-collection-errors\n' \
    > "$case_dir/state/pytest.ini"
  set +e
  run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "operator runner config above the proof checkout"
  assert_grep 'never ran its named test' "$case_dir/err" \
    "an ancestor runner config still rewrote the classified exit semantics"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "an ancestor runner config cleared a finding"

  record=$(make_case repository-runner-config)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  printf '[pytest]\n' > "$case_dir/repo/pytest.ini"
  git -C "$case_dir/repo" add pytest.ini
  git -C "$case_dir/repo" commit -qm "repository runner config"
  head=$(git -C "$case_dir/repo" rev-parse HEAD)
  git -C "$case_dir/repo" update-ref refs/pull/72/head "$head"
  seed_open_ledger "$case_dir" "$head"
  printf '[pytest]\naddopts = --continue-on-collection-errors\n' \
    > "$case_dir/state/pytest.ini"
  run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "the repository's own runner config broke a sound proof: $(cat "$case_dir/err")"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
proof = value["findings"][0]["history"][-1]["proof"]
assert value["findings"][0]["lifecycle"] == "verified-fixed"
configs = [
    line.split(": ", 1)[1]
    for line in proof["baseline_output"].splitlines()
    if line.startswith("configfile: ")
]
assert configs, proof["baseline_output"]
assert "/proof-" in configs[0], configs
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "the repository's own runner config did not take precedence"
  pass "runner config above the gate's checkouts is inert; the repository's own still wins"
}

# The same bypass the argument rule closed, reached without any reviewer: pytest
# appends PYTEST_ADDOPTS to its command line, so an operator with
# --continue-on-collection-errors exported turns every mutation that broke
# collection into an ordinary failure. The proof runs must therefore carry an
# environment the gate builds, not the one it was launched with.
test_ambient_addopts_cannot_rewrite_the_non_execution_signal() {
  local record case_dir base head rc
  record=$(make_case ambient-addopts)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  printf '2\n' > "$case_dir/pathbin/collection-exit"
  set +e
  PYTEST_ADDOPTS=--continue-on-collection-errors \
    run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambient PYTEST_ADDOPTS during a mutation proof"
  assert_grep 'never ran its named test' "$case_dir/err" \
    "an exported runner option still rewrote the classified exit semantics"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "an exported runner option cleared a finding"
  pass "an exported runner option cannot reach the gate's own proof runs"
}

# The allowlist is only worth having if omitting something fails loudly, so
# prove it by execution rather than assertion. The same scenario runs twice: the
# named test reaches its assertion through a helper on PATH, so with the real
# allowlist it clears, and with PATH deleted from that constant in a real copy
# of the gate the BASELINE refuses and carries the shell's own diagnostic. A
# missing variable can therefore never degrade into a mutation outcome.
test_incomplete_proof_environment_fails_loudly() {
  local record case_dir base head rc
  record=$(make_case path-dependent-proof)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  run_case "$case_dir" "$base" "$head" path-dependent run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "the PATH-dependent proof did not clear: $(cat "$case_dir/err")"

  record=$(make_case narrow-proof-env)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  mkdir -p "$case_dir/narrowed"
  cp "$ROOT/bin/fm_bounded_io.py" "$case_dir/narrowed/"
  sed '/^    "PATH",/d' "$CROSSCHECK_PY" > "$case_dir/narrowed/fm-crosscheck.py"
  if grep -q '^    "PATH",' "$case_dir/narrowed/fm-crosscheck.py"; then
    fail "the narrowed copy still allowlists PATH"
  fi
  local CROSSCHECK_PY="$case_dir/narrowed/fm-crosscheck.py"
  set +e
  run_case "$case_dir" "$base" "$head" path-dependent run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "proof environment missing a variable the runner needs"
  assert_grep 'does not pass before mutation' "$case_dir/err" \
    "a proof environment missing PATH did not refuse at the baseline run"
  assert_grep 'fm-test-helper' "$case_dir/err" \
    "the refusal did not carry the diagnostic naming what could not be found"
  assert_no_grep 'still passes after mutation' "$case_dir/err" \
    "a broken proof environment was read as a mutation outcome"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open", value["findings"][0]["lifecycle"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "a proof that never ran cleared a finding"
  pass "an allowlist missing something the runner needs refuses at the baseline"
}

# `Path.stat(follow_symlinks=...)` is Python 3.10+. `fm-crosscheck.sh` execs
# whichever `python3` is first on PATH, so that form turns an older interpreter
# into an uncaught TypeError deep inside evidence capture instead of a gate
# verdict. `os.stat(path, follow_symlinks=...)` is the portable idiom the rest
# of bin/ already uses.
test_evidence_capture_runs_on_older_interpreters() {
  local offenders older probe
  # Scoped to the two evidence-path modules, where every such receiver is a
  # pathlib.Path. os.DirEntry.stat(follow_symlinks=...) elsewhere in bin/ is a
  # different API and is valid on every Python 3.
  offenders=$(grep -nE '\.stat\(follow_symlinks=' \
    "$ROOT/bin/fm-crosscheck.py" "$ROOT/bin/fm_bounded_io.py" || true)
  if [ -n "$offenders" ]; then
    fail "Path.stat(follow_symlinks=) is Python 3.10+ only: $offenders"
  fi
  older=""
  for probe in python3.9 /usr/bin/python3 python3.8; do
    command -v "$probe" > /dev/null 2>&1 || continue
    if "$probe" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 10) else 1)'; then
      older=$probe
      break
    fi
  done
  if [ -z "$older" ]; then
    echo "SKIP: no pre-3.10 interpreter available for the portability probe"
    pass "evidence capture avoids interpreter-version-only APIs"
    return
  fi
  printf '{"ok":1}\n' > "$TMP_ROOT/portability.json"
  "$older" - "$ROOT/bin" "$TMP_ROOT/portability.json" <<'PY' \
    || fail "evidence capture is unusable on $("$older" --version 2>&1)"
import importlib.util
import sys
from pathlib import Path

bindir = Path(sys.argv[1])
sys.path.insert(0, str(bindir))
from fm_bounded_io import read_bounded_json

assert read_bounded_json(Path(sys.argv[2]), maximum_bytes=4096) == {"ok": 1}

spec = importlib.util.spec_from_file_location("xc", bindir / "fm-crosscheck.py")
crosscheck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crosscheck)

review = Path(sys.argv[2]).parent / "portability-review"
(review / ".crosscheck" / "mutations").mkdir(parents=True, exist_ok=True)
patch = review / ".crosscheck" / "mutations" / "revert.patch"
patch.write_text("diff --git a/app.txt b/app.txt\n")
resolved = crosscheck.safe_artifact(
    review, ".crosscheck/mutations/revert.patch", ".crosscheck/mutations/"
)
assert resolved.name == "revert.patch", resolved
PY
  pass "evidence capture avoids interpreter-version-only APIs"
}

# The gate re-runs reviewer evidence without the reviewer's provider account
# environment. That is deliberate, but the refusal must name the environment
# difference and show the command's own output instead of reporting a bare
# unexpected exit that reads as a substantive verdict about the code.
test_reviewer_env_dependent_evidence_names_the_difference() {
  local record case_dir base head rc
  record=$(make_case reviewer-env-dependent)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" reviewer-env-dependent-execution run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reviewer evidence depending on reviewer-only environment"
  assert_grep 'none of the reviewer' "$case_dir/err" \
    "the refusal did not name the independent re-execution environment"
  assert_grep 'CODEX_HOME' "$case_dir/err" \
    "the refusal did not surface the command output that explains the exit"
  pass "evidence that needs reviewer-only environment is diagnosable, not a bare exit"
}

test_unfound_evidence_command_is_a_non_execution() {
  local record case_dir base head rc
  record=$(make_case unfound-reproduction)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" unfound-reproduction-command run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "evidence command that does not exist"
  assert_grep 'never ran' "$case_dir/err" \
    "an unfound evidence command was not reported as a non-execution"
  pass "an evidence command that was never found is a non-execution"
}

# The gate's own integrity check reads `git status` through the bounded-output
# limit. Listing evidence file by file meant a review that substantiated
# anything could exceed that limit and be refused, while a review that found
# nothing completed - the gate could block but never clear.
test_bulky_reviewer_evidence_still_completes() {
  local record case_dir base head
  record=$(make_case bulky-evidence)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  run_case "$case_dir" "$base" "$head" bulky-evidence run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "substantial reviewer evidence blocked the review: $(cat "$case_dir/err")"
  assert_grep 'crosscheck clear' "$case_dir/out" \
    "a clean review carrying substantial evidence did not clear"
  pass "a review carrying substantial evidence still reaches a verdict"
}

test_bulky_unauthorized_scratch_is_named_not_truncated() {
  local record case_dir base head rc
  record=$(make_case bulky-unauthorized)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" bulky-unauthorized-scratch run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "heavy unauthorized scratch in the review checkout"
  assert_grep 'changed tracked or unauthorized path' "$case_dir/err" \
    "heavy unauthorized scratch was not named as an unauthorized path"
  if grep -q 'aggregate output limit' "$case_dir/err"; then
    fail "the integrity inspection ran out of output budget instead of naming the path"
  fi
  pass "heavy unauthorized scratch is refused by name, not by output truncation"
}

test_tampered_review_checkout_is_still_detected() {
  local record case_dir base head rc
  record=$(make_case tampered-checkout)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" tampered-checkout run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reviewer that edited the review checkout"
  assert_grep 'changed tracked or unauthorized path' "$case_dir/err" \
    "a reviewer that edited tracked code was not detected"
  pass "a reviewer that edits tracked code or writes outside .crosscheck stays refused"
}

test_symlinked_directory_named_test_is_rejected() {
  local record case_dir base head rc
  record=$(make_case linked-directory-test)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" linked-directory-test run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "named test behind a symlinked directory"
  assert_grep 'symlink' "$case_dir/err" \
    "a named test reached through an in-repository symlink was accepted"
  pass "a named test behind an in-repository symlink stays rejected"
}

# The symlink check used to compare against a purely lexical absolute path, so a
# home reached through any symlinked ancestor - a macOS /tmp or /var path, say -
# could never clear a finding no matter how sound the change was.
test_symlinked_home_ancestor_still_clears() {
  local record case_dir base head
  record=$(make_case symlinked-home)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  ln -s state "$case_dir/state-link"
  FM_TEST_STATE_OVERRIDE="$case_dir/state-link" \
    run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "a symlinked home ancestor blocked a sound clearance: $(cat "$case_dir/err")"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "verified-fixed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "the clearance was not durably recorded"
  pass "a home reached through a symlinked ancestor can still clear a finding"
}

test_forged_git_diff_mutation_command_is_rejected() {
  local record case_dir base head rc
  record=$(make_case forged-command)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" forged-command run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "forged git-diff mutation command"
  assert_grep 'test_command' "$case_dir/err" \
    "free-form git-diff mutation command was not rejected"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open"
assert value["runs"][-1]["state"] == "unreviewed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "forged git-diff command cleared the durable finding"
  pass "forged git-diff command cannot impersonate a named test"
}

test_stateful_test_cannot_fabricate_mutation_causality() {
  local record case_dir base head rc
  record=$(make_case stateful-forgery)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  python3 - "$case_dir/data/task-x1/crosscheck-ledger.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
value["findings"][0]["citations"] = [{"path": "other.txt", "line": 1}]
with open(path, "w") as stream:
    json.dump(value, stream)
PY
  set +e
  run_case "$case_dir" "$base" "$head" stateful-forgery run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "stateful mutation fabrication"
  assert_grep 'named test still passes after mutation' "$case_dir/err" \
    "baseline state leaked into the mutated checkout"
  pass "baseline and mutation tests run in independent clean checkouts"
}

test_baseline_readable_state_is_destroyed_before_mutation() {
  local record case_dir base head rc
  record=$(make_case readable-state-forgery)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" readable-state-forgery run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "readable baseline-state mutation fabrication"
  assert_grep 'named test still passes after mutation' "$case_dir/err" \
    "mutated proof observed state retained from the baseline proof"
  pass "baseline proof state is destroyed before the same checkout path is recreated"
}

test_mutation_is_bound_to_cited_non_test_implementation() {
  local mode record case_dir base head rc
  for mode in outside-citation cited-test-support; do
    record=$(make_case "support-$mode")
    IFS=$'\t' read -r case_dir base head <<< "$record"
    seed_open_ledger "$case_dir" "$head"
    if [ "$mode" = cited-test-support ]; then
      python3 - "$case_dir/data/task-x1/crosscheck-ledger.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
value["findings"][0]["citations"] = [{"path": "tests/helper.sh", "line": 1}]
with open(path, "w") as stream:
    json.dump(value, stream)
PY
    fi
    set +e
    run_case "$case_dir" "$base" "$head" support-forgery run \
      > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode mutation support fabrication"
    if [ "$mode" = outside-citation ]; then
      assert_grep 'outside finding implementation citations' "$case_dir/err" \
        "mutation changed a path the finding never identified as implementation"
    else
      assert_grep 'mutation changes test or evidence support' "$case_dir/err" \
        "a cited test helper was accepted as implementation mutation"
    fi
  done
  pass "mutation proof changes only cited non-test implementation paths"
}

test_final_wait_and_residual_processes_are_bounded() {
  python3 - "$CROSSCHECK_PY" "$TMP_ROOT/residual-child-marker" <<'PY' \
    || fail "process lifetime escaped its deadline or process group"
import importlib.util
from pathlib import Path
import shlex
import sys
import time

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

started = time.monotonic()
try:
    module.run_command(
        ["/bin/bash", "-c", "exec 1>&- 2>&-; sleep 2"],
        timeout=1,
        description="closed-pipe command",
    )
except module.CrosscheckError as exc:
    assert "timed out" in str(exc)
else:
    raise AssertionError("closed-pipe command escaped its deadline")
assert time.monotonic() - started < 1.6

marker = Path(sys.argv[2])
module.run_command(
    [
        "/bin/bash",
        "-c",
        f"(exec 1>&- 2>&-; sleep 1; printf leaked > {shlex.quote(str(marker))}) &",
    ],
    timeout=2,
    description="residual-child command",
)
time.sleep(1.2)
assert not marker.exists()
PY
  pass "pipe EOF cannot escape deadlines or leave residual child processes"
}

test_installed_sandbox_denies_shared_private_tmp() {
  local marker profile
  marker="/private/tmp/fm-crosscheck-shared-state-$$"
  profile="$TMP_ROOT/isolated-proof.sb"
  python3 - "$CROSSCHECK_PY" "$profile" "$marker" <<'PY' \
    || fail "generated proof sandbox permits shared host state"
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
profile = Path(sys.argv[2])
marker = Path(sys.argv[3])
module.write_sandbox_profile(
    profile,
    profile.parent,
    allow_network=False,
    allow_posix_ipc=False,
)
profile_text = profile.read_text()
writable_root = profile.parent.resolve()
assert profile_text.splitlines() == [
    "(version 1)",
    "(deny default)",
    "(allow process*)",
    "(allow file-read*)",
    "(allow sysctl-read)",
    "(allow mach-lookup)",
    "(allow file-ioctl)",
    "(allow file-write*",
    f"  (subpath {json.dumps(str(writable_root))})",
    '  (literal "/dev/null"))',
]
assert "(allow ipc-posix*)" not in profile_text
try:
    marker.resolve().relative_to(writable_root)
except ValueError:
    pass
else:
    raise AssertionError("shared host marker unexpectedly resolves inside proof root")
try:
    sandbox = Path(
        os.environ.get("FM_TEST_INSTALLED_SANDBOX_BIN", "/usr/bin/sandbox-exec")
    )
    if sandbox.is_file():
        result = subprocess.run(
            [
                str(sandbox),
                "-f",
                str(profile),
                "/bin/sh",
                "-c",
                f": > {shlex.quote(str(marker))}",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode != 0
    assert not marker.exists()
finally:
    marker.unlink(missing_ok=True)
PY
  pass "generated sandbox confines proof writes; installed enforcement denies shared private tmp when available"
}

test_real_claude_sandbox_executes_exact_sha_git_diff() {
  local repo base head nonce profile output event claude_bin sandbox_bin reviewer_home execution_home
  if [ "${FM_TEST_REAL_CLAUDE_SANDBOX_GIT_DIFF:-0}" != 1 ]; then
    printf 'SKIP: real Claude sandbox exact-SHA git-diff proof; set FM_TEST_REAL_CLAUDE_SANDBOX_GIT_DIFF=1 and FM_TEST_REAL_CLAUDE_CONFIG_DIR\n'
    return
  fi
  reviewer_home=${FM_TEST_REAL_CLAUDE_CONFIG_DIR:-}
  [ -n "$reviewer_home" ] \
    || fail "FM_TEST_REAL_CLAUDE_CONFIG_DIR is required for the real Claude sandbox proof"
  claude_bin=${FM_TEST_REAL_CLAUDE_BIN:-$(command -v claude || true)}
  sandbox_bin=${FM_TEST_INSTALLED_SANDBOX_BIN:-/usr/bin/sandbox-exec}
  [ -x "$claude_bin" ] || fail "real Claude binary is unavailable"
  [ -x "$sandbox_bin" ] || fail "installed sandbox-exec is unavailable"
  repo="$TMP_ROOT/real-claude-sandbox-git-diff/repo"
  mkdir -p "$repo/.crosscheck/claude-tmp"
  git -C "$repo" init -q -b main
  printf 'base\n' > "$repo/runtime-proof.txt"
  git -C "$repo" add runtime-proof.txt
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  nonce="real-claude-git-diff-$RANDOM-$$"
  printf '%s\n' "$nonce" > "$repo/runtime-proof.txt"
  git -C "$repo" add runtime-proof.txt
  git -C "$repo" commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)
  profile="$repo/.crosscheck/real-claude-sandbox.sb"
  output="$repo/.crosscheck/real-claude-output.json"
  event="$repo/.crosscheck/observed-bash-event"
  python3 - "$CROSSCHECK_PY" "$profile" "$repo" "$reviewer_home" <<'PY' \
    || fail "real Claude sandbox profile did not retain the narrow write contract"
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
profile = Path(sys.argv[2])
repo = Path(sys.argv[3])
reviewer_home = Path(sys.argv[4]).resolve()
ambient_home = Path.home().resolve()
shared_session_env = ambient_home / ".claude" / "session-env"
reviewer_session_env = reviewer_home / "session-env"
try:
    reviewer_home.relative_to(ambient_home / ".claude")
except ValueError:
    pass
else:
    raise AssertionError("reviewer home must be independent of shared ~/.claude")
execution_home, credential_source, credential_identifier = (
    module.prepare_claude_execution_home(repo / ".crosscheck", reviewer_home)
)
module.write_sandbox_profile(
    profile,
    repo,
    allow_network=True,
    additional_writable_roots=(reviewer_home,),
)
text = profile.read_text()
assert f"  (subpath {json.dumps(str(reviewer_home))})" in text
assert f"  (subpath {json.dumps(str(shared_session_env))})" not in text
assert reviewer_session_env.is_relative_to(reviewer_home)
assert execution_home == repo / ".crosscheck" / "claude-home"
assert execution_home.joinpath(".claude").resolve() == reviewer_home
assert credential_source in {"oauth-file", "scoped-keychain"}
assert credential_identifier
assert f"  (subpath {json.dumps(str(repo.resolve() / '.crosscheck' / 'claude-tmp'))})" not in text
PY
  execution_home="$repo/.crosscheck/claude-home"
  (
    cd "$repo" || exit 1
    HOME="$execution_home" \
    CLAUDE_CONFIG_DIR="$reviewer_home" \
    CLAUDE_SECURESTORAGE_CONFIG_DIR="$reviewer_home" \
    CLAUDE_CODE_TMPDIR="$repo/.crosscheck/claude-tmp" \
    "$sandbox_bin" -f "$profile" "$claude_bin" -p \
      --model claude-opus-5 \
      --effort xhigh \
      --dangerously-skip-permissions \
      --tools Bash \
      --no-session-persistence \
      --output-format json \
      --json-schema '{"type":"object","properties":{"base":{"type":"string"},"head":{"type":"string"},"cwd":{"type":"string"},"home":{"type":"string"},"config":{"type":"string"},"secure_config":{"type":"string"},"diff":{"type":"string"},"claude_code_tmpdir":{"type":"string"}},"required":["base","head","cwd","home","config","secure_config","diff","claude_code_tmpdir"],"additionalProperties":false}' \
      "Use Bash in the current repository to run git diff $base $head -- runtime-proof.txt. Save an execution record containing those exact SHAs, pwd, HOME, CLAUDE_CONFIG_DIR, CLAUDE_SECURESTORAGE_CONFIG_DIR, CLAUDE_CODE_TMPDIR, and the exact diff output to .crosscheck/observed-bash-event. Return all of those exact values. This is the real sandboxed Claude Bash exact-SHA git-diff proof."
  ) > "$output" 2> "$repo/.crosscheck/real-claude-stderr.log" \
    || {
      tail -c 4000 "$output" 2>/dev/null || true
      tail -c 4000 "$repo/.crosscheck/real-claude-stderr.log" 2>/dev/null || true
      fail "real installed Claude could not execute git diff under the generated sandbox"
    }
  assert_present "$event" \
    "real Claude Bash did not create the exact-repository execution event"
  assert_grep "$nonce" "$event" \
    "real Claude Bash event did not contain the temporary repository's exact-SHA diff"
  assert_grep "$base" "$event" \
    "real Claude Bash event was not bound to the temporary repository's base SHA"
  assert_grep "$head" "$event" \
    "real Claude Bash event was not bound to the temporary repository's head SHA"
  assert_grep "$repo" "$event" \
    "real Claude Bash event was not bound to the temporary repository cwd"
  assert_grep "$repo/.crosscheck/claude-tmp" "$event" \
    "real Claude Bash event did not observe the isolated CLAUDE_CODE_TMPDIR"
  python3 - "$output" "$base" "$head" "$nonce" "$repo" "$execution_home" "$reviewer_home" "$repo/.crosscheck/claude-tmp" <<'PY' \
    || fail "real Claude output did not prove exact-SHA git diff with isolated scratch"
import json
import sys

envelope = json.load(open(sys.argv[1]))
assert envelope["is_error"] is False
assert envelope["subtype"] == "success"
assert envelope["terminal_reason"] == "completed"
proof = envelope["structured_output"]
assert proof["base"] == sys.argv[2]
assert proof["head"] == sys.argv[3]
assert sys.argv[4] in proof["diff"]
assert proof["cwd"] == sys.argv[5]
assert proof["home"] == sys.argv[6]
assert proof["config"] == sys.argv[7]
assert proof["secure_config"] == sys.argv[7]
assert proof["claude_code_tmpdir"] == sys.argv[8]
PY
  printf 'REAL CLAUDE PROOF: reviewer=claude-opus-5/xhigh account_home=%s command=git diff %s %s -- runtime-proof.txt verdict=completed\n' \
    "$reviewer_home" "$base" "$head"
  pass "real sandboxed Claude Bash executed exact-SHA git diff with scoped account credentials, private HOME, and isolated scratch"
}

test_symlinked_named_test_cannot_hide_test_mutation() {
  local record case_dir base head rc
  record=$(make_case symlink-forgery)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" symlink-forgery run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked named test"
  assert_grep 'test_path must be a regular file' "$case_dir/err" \
    "symlinked test alias hid a mutation to its executed target"
  pass "symlinked named tests cannot hide mutations to executed test code"
}

test_evidence_batch_item_limit_precedes_execution() {
  local record case_dir base head rc
  record=$(make_case too-many-items)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" too-many-items run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "oversized reviewer batch"
  assert_grep 'reviewer verdict suspicions has too many entries' "$case_dir/err" \
    "oversized reviewer arrays reached application"
  pass "reviewer item limits are validated before evidence application"
}

test_evidence_batch_has_aggregate_deadline() {
  local record case_dir base head rc started elapsed
  record=$(make_case aggregate-evidence-deadline)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  started=$(date +%s)
  set +e
  FM_CROSSCHECK_EVIDENCE_TIMEOUT_SECONDS=10 \
  FM_CROSSCHECK_EVIDENCE_RUN_TIMEOUT_SECONDS=1 \
    run_case "$case_dir" "$base" "$head" slow-reproduction run \
      > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  elapsed=$(($(date +%s) - started))
  expect_code 1 "$rc" "aggregate evidence deadline"
  [ "$elapsed" -lt 10 ] || fail "aggregate evidence deadline took ${elapsed}s"
  assert_grep 'timed out' "$case_dir/err" \
    "aggregate evidence deadline did not block loudly"
  pass "all reviewer evidence shares one bounded execution deadline"
}

test_artifacts_cannot_escape_designated_subtrees() {
  local record case_dir base head rc
  record=$(make_case escaped-reproduction)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" escaped-reproduction run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "escaped reproduction artifact"
  assert_grep 'artifact path escapes .crosscheck/reproductions/' "$case_dir/err" \
    "resolved artifact containment was not enforced: $(tr '\n' ' ' < "$case_dir/err")"
  pass "resolved evidence paths remain inside designated subtrees"
}

test_reviewer_output_uses_separate_capture_limit() {
  local record case_dir base head rc
  record=$(make_case noisy-codex-reviewer)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  run_case "$case_dir" "$base" "$head" noisy-reviewer run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "valid Codex review failed on incidental transcript volume"
  assert_grep 'crosscheck clear' "$case_dir/out" \
    "large Codex transcript did not reach its authoritative verdict"

  record=$(make_case noisy-claude-reviewer)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  select_claude_reviewer "$case_dir"
  run_case "$case_dir" "$base" "$head" noisy-reviewer run \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "valid Claude review failed on its larger result envelope"
  assert_grep 'crosscheck clear' "$case_dir/out" \
    "large Claude envelope did not reach its structured verdict"

  record=$(make_case noisy-reviewer-no-result)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" noisy-reviewer-no-result run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "large reviewer transcript without result"
  assert_no_grep 'exceeded the 200000-byte aggregate output limit' "$case_dir/err" \
    "missing result was obscured by the ordinary capture limit"
  assert_grep 'reviewer verdict artifact is malformed' "$case_dir/err" \
    "missing authoritative result did not fail closed"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["runs"][-1]["state"] == "unreviewed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "missing authoritative result was recorded as reviewed"
  pass "both reviewers accept larger bounded output while a missing verdict stays unreviewed"
}

test_reviewer_capture_override_is_validated() {
  local value record case_dir base head rc
  record=$(make_case reviewer-capture-override)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES=200000 \
    run_case "$case_dir" "$base" "$head" noisy-reviewer run \
      > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reviewer capture override"
  assert_grep 'exceeded the 200000-byte aggregate output limit' "$case_dir/err" \
    "reviewer capture override was not applied"

  for value in invalid 199999 67108865; do
    record=$(make_case "invalid-reviewer-capture-$value")
    IFS=$'\t' read -r case_dir base head <<< "$record"
    set +e
    FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES=$value \
      run_case "$case_dir" "$base" "$head" clear run \
        > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "invalid reviewer capture $value"
    assert_grep 'FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES' "$case_dir/err" \
      "invalid reviewer capture $value did not fail explicitly"
    assert_absent "$case_dir/codex.log" \
      "invalid reviewer capture $value still launched the reviewer"
  done
  pass "reviewer capture override is bounded and invalid values fail before launch"
}

test_ordinary_output_paths_remain_bounded() {
  local record case_dir base head rc
  python3 - "$CROSSCHECK_PY" <<'PY' \
    || fail "ordinary run_command output did not retain the original ceiling"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
assert module.MAX_CAPTURE == 200_000
try:
    module.run_command(
        [sys.executable, "-c", 'import sys; sys.stdout.write("O" * 210000)'],
        description="ordinary command",
    )
except module.CrosscheckError as exc:
    assert str(exc) == (
        "ordinary command: bounded command exceeded the "
        "200000-byte aggregate output limit"
    )
else:
    raise AssertionError("ordinary command crossed the original capture limit")
PY

  record=$(make_case noisy-reproduction)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" noisy-reproduction run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "noisy reproduction output limit"
  assert_grep 'exceeded the 200000-byte aggregate output limit' "$case_dir/err" \
    "reproduction command did not retain the ordinary output limit"

  record=$(make_case oversized-artifact)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" oversized-artifact run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "oversized reviewer verdict artifact"
  assert_grep 'reviewer verdict artifact is malformed at' \
    "$case_dir/err" \
    "oversized verdict artifact was not classified as malformed"
  assert_grep 'bounded JSON artifact exceeds 200000 bytes' "$case_dir/err" \
    "oversized verdict artifact bypassed the output ceiling: $(tr '\n' ' ' < "$case_dir/err")"
  pass "ordinary commands and authoritative reviewer artifacts retain the 200000-byte limit"
}

test_prompt_uses_only_bounded_ledger_projection() {
  local record case_dir base head rc size
  record=$(make_case bounded-ledger-prompt)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  python3 - "$case_dir/data/task-x1/crosscheck-ledger.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
finding = value["findings"][0]
finding["title"] = "PERSISTED-TITLE-INSTRUCTION"
finding["description"] = "PERSISTED-DESCRIPTION-INSTRUCTION"
finding["history"][0]["note"] = "PERSISTED-NOTE-INSTRUCTION"
finding["history"][0]["proof"] = {"output": "PERSISTED-OUTPUT-INSTRUCTION" * 10000}
with open(path, "w") as stream:
    json.dump(value, stream)
PY
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "durable open finding"
  assert_no_grep 'PERSISTED-TITLE-INSTRUCTION' "$case_dir/prompt.log" \
    "repository-controlled ledger title reached the reviewer prompt"
  assert_no_grep 'PERSISTED-DESCRIPTION-INSTRUCTION' "$case_dir/prompt.log" \
    "repository-controlled ledger description reached the reviewer prompt"
  assert_no_grep 'PERSISTED-NOTE-INSTRUCTION' "$case_dir/prompt.log" \
    "repository-controlled ledger note reached the reviewer prompt"
  assert_no_grep 'PERSISTED-OUTPUT-INSTRUCTION' "$case_dir/prompt.log" \
    "repository-controlled evidence output reached the reviewer prompt"
  assert_grep 'proof_sha256' "$case_dir/prompt.log" \
    "reviewer prompt omitted the durable proof digest"
  size=$(wc -c < "$case_dir/prompt.log")
  [ "$size" -lt 100000 ] || fail "reviewer prompt was not bounded: $size bytes"
  pass "later reviewers receive bounded lifecycle metadata and proof digests only"
}

test_nonexistent_mutation_proof_is_unreviewed() {
  local record case_dir base head rc
  record=$(make_case missing-proof)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" missing-proof run > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing mutation proof"
  assert_grep 'artifact is absent' "$case_dir/err" \
    "missing mutation proof did not fail loudly"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "open"
assert value["runs"][-1]["state"] == "unreviewed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "missing mutation proof cleared the durable blocker"
  pass "nonexistent mutation proof cannot clear a finding"
}

test_mutation_proof_does_not_float_to_a_new_head() {
  local record case_dir base head next_head rc
  record=$(make_case proof-head)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_open_ledger "$case_dir" "$head"
  run_case "$case_dir" "$base" "$head" verified-fixed run \
    > "$case_dir/first.out" 2> "$case_dir/first.err" || fail "setup mutation proof failed"
  printf 'unrelated follow-up\n' > "$case_dir/repo/notes.txt"
  git -C "$case_dir/repo" add notes.txt
  git -C "$case_dir/repo" commit -qm follow-up
  next_head=$(git -C "$case_dir/repo" rev-parse HEAD)
  set +e
  run_case "$case_dir" "$base" "$next_head" clear run \
    > "$case_dir/second.out" 2> "$case_dir/second.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "proof from earlier head"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["findings"][0]["lifecycle"] == "verified-fixed"
assert value["runs"][-1]["active_blockers"] == ["cc-aaaaaaaaaaaa"]
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "old-head mutation proof floated to a new head"
  pass "mutation proof remains durable but cannot clear a different head"
}

# A recorded proof that would not be accepted today must degrade the FINDING,
# never the file. Failing ledger load instead would wedge the task: the gate
# stops before it can record a run, so nothing on disk explains the stop and
# every later run fails identically until someone hand-edits the ledger.
test_recorded_argument_proof_loads_but_no_longer_clears() {
  local record case_dir base head rc
  record=$(make_case legacy-argument-proof)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  seed_argument_proof_ledger "$case_dir" "$head"
  set +e
  run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded proof whose invocation carried arguments"
  assert_no_grep 'finding-ledger preflight failed' "$case_dir/err" \
    "a ledger holding an argument-bearing proof failed to load"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["runs"], "the run was not recorded"
assert value["runs"][-1]["active_blockers"] == ["cc-aaaaaaaaaaaa"], value["runs"][-1]
assert value["findings"][0]["lifecycle"] == "verified-fixed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "the argument-bearing proof still cleared its finding"
  pass "a recorded argument-bearing proof loads but no longer certifies its finding"
}

test_equivalent_finding_reopens_when_direct_proof_regresses() {
  python3 - "$CROSSCHECK_PY" <<'PY' || fail "equivalent finding did not fail closed after target regression"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

head = "a" * 40
verified = {
    "id": "cc-aaaaaaaaaaaa",
    "lifecycle": "verified-fixed",
    "history": [{
        "status": "verified-fixed",
        "head_sha": head,
        "proof": {"test_invocation": {"runner": "pytest", "arguments": []}},
    }],
}
equivalent = {
    "id": "cc-bbbbbbbbbbbb",
    "lifecycle": "closed-equivalent",
    "history": [{
        "status": "closed-equivalent",
        "head_sha": head,
        "proof": {"equivalent_to": verified["id"]},
    }],
}
ledger = {"findings": [verified, equivalent]}
assert module.active_findings_for_head(ledger, head) == []
verified["lifecycle"] = "open"
verified["history"].append({"status": "open", "head_sha": head})
assert module.active_findings_for_head(ledger, head) == [
    "cc-aaaaaaaaaaaa",
    "cc-bbbbbbbbbbbb",
]
PY
  pass "closed-equivalent reopens safely when its direct verified proof regresses"
}

test_null_ledger_fails_without_normalization() {
  local record case_dir base head rc
  record=$(make_case null-ledger)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<'JSON'
{"schema":"firstmate.crosscheck-ledger.v2","task_id":"task-x1","pull_request":"https://github.com/ruby-dlee/firstmate/pull/72","findings":null,"runs":[]}
JSON
  set +e
  run_case "$case_dir" "$base" "$head" clear run > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "null findings ledger"
  assert_grep 'CROSSCHECK TOOL-FAILURE: finding-ledger preflight failed at' \
    "$case_dir/err" "malformed ledger did not report a tool failure"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "malformed ledger was mislabeled as a review outcome"
  assert_grep 'ledger.findings must be an array' "$case_dir/err" \
    "null ledger was not rejected explicitly"
  grep -q '"findings":null' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "null ledger was rewritten or normalized"
  assert_absent "$case_dir/codex.log" "reviewer ran against a malformed ledger"
  # This stop cannot record a run: appending to a ledger that failed to parse
  # would risk destroying the durable findings it still holds. The readable
  # report must therefore carry the cause, or nothing on disk explains why
  # every later run stops the same way.
  assert_grep 'TOOL-FAILURE' "$case_dir/data/task-x1/crosscheck.md" \
    "the report did not record the stop"
  assert_grep 'finding-ledger preflight failed' \
    "$case_dir/data/task-x1/crosscheck.md" \
    "the report did not name the cause of the stop"
  pass "null findings ledger fails closed and is never normalized to empty"
}

test_claims_lookup_error_never_reaches_reviewer() {
  local record case_dir base head rc
  record=$(make_case claims-error)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  FM_TEST_CLAIMS_MODE=error run_case "$case_dir" "$base" "$head" clear run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "claims lookup failure"
  assert_grep 'CROSSCHECK TOOL-FAILURE: GitHub snapshot preflight failed:' \
    "$case_dir/err" "GitHub lookup failure did not report a tool failure"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "GitHub lookup failure was mislabeled as a review outcome"
  assert_grep 'GitHub lookup failed closed' "$case_dir/err" \
    "claims error was swallowed"
  assert_absent "$case_dir/codex.log" "reviewer ran without PR claims"
  assert_absent "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "claims lookup error fabricated a ledger verdict"
  pass "PR claims lookup errors are tool failures and never become a review run"
}

test_reviewer_configuration_failures_are_tool_failures() {
  local mode record case_dir base head rc
  for mode in absent same-model same-account; do
    record=$(make_case "reviewer-$mode")
    IFS=$'\t' read -r case_dir base head <<< "$record"
    case "$mode" in
      absent) rm "$case_dir/reviewer.json" ;;
      same-model)
        sed -i.bak 's/model=gpt-5.5/model=gpt-5.6-sol/' "$case_dir/state/task-x1.meta"
        rm "$case_dir/state/task-x1.meta.bak"
        ;;
      same-account)
        sed "s#${case_dir}/reviewer-home#${case_dir}/author-home#" "$case_dir/reviewer.json" \
          > "$case_dir/reviewer-same.json"
        mv "$case_dir/reviewer-same.json" "$case_dir/reviewer.json"
        ;;
    esac
    set +e
    run_case "$case_dir" "$base" "$head" clear run > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode reviewer"
    assert_grep 'CROSSCHECK TOOL-FAILURE: reviewer preflight failed:' "$case_dir/err" \
      "$mode reviewer configuration did not fail as a named tool preflight"
    assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
      "$mode reviewer configuration collapsed into a review verdict"
    assert_no_grep 'CROSSCHECK BLOCKING' "$case_dir/err" \
      "$mode reviewer configuration collapsed into a blocking verdict"
    assert_absent "$case_dir/codex.log" "$mode reviewer still launched"
  done
  pass "absent reviewer, same model, and same account are tool failures that fail closed"
}

test_stopped_reviewer_and_wrong_head_are_unreviewed() {
  local scenario record case_dir base head rc
  for scenario in stopped wrong-head; do
    record=$(make_case "$scenario")
    IFS=$'\t' read -r case_dir base head <<< "$record"
    set +e
    run_case "$case_dir" "$base" "$head" "$scenario" run > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$scenario reviewer"
    assert_grep 'CROSSCHECK UNREVIEWED:' "$case_dir/err" \
      "$scenario reviewer did not report that no valid exact-head review exists"
    assert_no_grep 'CROSSCHECK TOOL-FAILURE' "$case_dir/err" \
      "$scenario reviewer collapsed into a different outcome class"
    assert_no_grep 'CROSSCHECK BLOCKING' "$case_dir/err" \
      "$scenario reviewer collapsed into a blocking outcome"
    python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
assert value["runs"][-1]["state"] == "unreviewed"
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
      || fail "$scenario reviewer created a trusted verdict"
  done
  pass "stopped and wrong-head reviewer artifacts remain unreviewed"
}

test_completed_reviewer_suspicion_is_blocking() {
  local record case_dir base head rc
  record=$(make_case completed-suspicion)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  set +e
  run_case "$case_dir" "$base" "$head" suspicion run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "completed reviewer suspicion"
  assert_grep 'CROSSCHECK BLOCKING:' "$case_dir/err" \
    "a completed reviewer decline was not classified as blocking: $(tr '\n' ' ' < "$case_dir/err")"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "a completed reviewer decline collapsed into a non-verdict outcome"
  assert_no_grep 'CROSSCHECK TOOL-FAILURE' "$case_dir/err" \
    "a completed reviewer decline collapsed into a tool failure"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
run = value["runs"][-1]
assert run["state"] == "blocking"
assert run["suspicions"][0]["description"] == "The reviewer could not finish a reproduction."
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "completed reviewer suspicion was not durably recorded as blocking"
  pass "a completed review that declines clearance is blocking code evidence"
}

test_reading_only_suspicion_is_a_tool_failure() {
  local record case_dir base head rc
  record=$(make_case reading-only-suspicion)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  sed -i.bak 's/model=gpt-5.5/model=gpt-5.6-sol/' "$case_dir/state/task-x1.meta"
  rm "$case_dir/state/task-x1.meta.bak"
  cat > "$case_dir/reviewer.json" <<EOF
{"reviewers":[{"harness":"claude","model":"claude-opus-5","effort":"xhigh","account_home":"$case_dir/reviewer-home"}]}
EOF
  set +e
  run_case "$case_dir" "$base" "$head" reading-only-suspicion run \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "reading-only reviewer suspicion"
  assert_grep 'CROSSCHECK TOOL-FAILURE:' "$case_dir/err" \
    "a verdict without command execution was not classified as a tool failure"
  assert_grep 'reviewer verdict carries no executed reproduction' "$case_dir/err" \
    "the command-execution failure did not name the missing inspected artifact"
  assert_no_grep 'CROSSCHECK BLOCKING' "$case_dir/err" \
    "a reading-only concern was accepted as blocking code evidence"
  assert_no_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
    "a reviewer runtime failure collapsed into a generic review outcome"
  assert_absent "$case_dir/reviewer-home/session-env/crosscheck-git-diff" \
    "the dead-Bash fixture unexpectedly executed git diff"
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
run = value["runs"][-1]
assert run["state"] == "tool-failure"
assert run["suspicions"] == []
' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    || fail "reading-only verdict was not durably classified as a tool failure"
  pass "a verdict without an executed reproduction is a tool failure, never blocking code evidence"
}

test_launcher_requires_supported_python() {
  local candidate case_dir fakebin launcher marker modern rc
  case_dir="$TMP_ROOT/python-launcher"
  fakebin="$case_dir/fakebin"
  launcher="$ROOT/bin/fm-crosscheck.sh"
  marker="$case_dir/launched.args"
  mkdir -p "$fakebin"

  cat > "$fakebin/python-old" <<'SH'
#!/bin/bash
if [ "${1:-}" = -c ]; then
  printf '3.9.6\n'
  exit 1
fi
exit 97
SH
  chmod +x "$fakebin/python-old"

  set +e
  FM_CROSSCHECK_PYTHON="$fakebin/python-old" "$launcher" --help \
    > "$case_dir/old.out" 2> "$case_dir/old.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "explicit too-old crosscheck interpreter"
  assert_grep 'Python 3.11 or newer is required' "$case_dir/old.err" \
    "the launcher did not name its interpreter requirement"
  assert_grep "looked for FM_CROSSCHECK_PYTHON='$fakebin/python-old'" \
    "$case_dir/old.err" "the launcher did not name the requested interpreter"
  assert_grep 'Python 3.9.6, too old' "$case_dir/old.err" \
    "the launcher did not report the version it found"
  assert_absent "$marker" "the launcher executed the gate under a too-old interpreter"

  cat > "$fakebin/python3.11" <<'SH'
#!/bin/bash
if [ "${1:-}" = -c ]; then
  printf '3.11.9\n'
  exit 0
fi
printf '%s\n' "$@" > "$FM_TEST_CROSSCHECK_LAUNCH_MARKER"
SH
  chmod +x "$fakebin/python3.11"
  for name in python3.14 python3.13 python3.12; do
    ln -s python-old "$fakebin/$name"
  done

  env -u FM_CROSSCHECK_PYTHON \
    PATH="$fakebin:/usr/bin:/bin" \
    FM_TEST_CROSSCHECK_LAUNCH_MARKER="$marker" \
    "$launcher" --help > "$case_dir/modern.out" 2> "$case_dir/modern.err" \
    || fail "the launcher rejected a discoverable Python 3.11 interpreter: $(cat "$case_dir/modern.err")"
  [ "$(sed -n '1p' "$marker")" = "$ROOT/bin/fm-crosscheck.py" ] \
    || fail "the launcher did not execute fm-crosscheck.py with the supported interpreter"
  [ "$(sed -n '2p' "$marker")" = --help ] \
    || fail "the launcher did not preserve crosscheck arguments"

  modern=
  for candidate in python3.14 python3.13 python3.12 python3.11 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' \
      >/dev/null 2>&1; then
      modern=$(command -v "$candidate")
      break
    fi
  done
  [ -n "$modern" ] || fail "the Crosscheck test environment has no Python 3.11 or newer"
  FM_CROSSCHECK_PYTHON="$modern" "$launcher" --help \
    > "$case_dir/real-modern.out" 2> "$case_dir/real-modern.err" \
    || fail "the launcher rejected the real conforming interpreter: $(cat "$case_dir/real-modern.err")"
  assert_grep 'usage: fm-crosscheck.py' "$case_dir/real-modern.out" \
    "the real conforming interpreter did not execute the Crosscheck entrypoint"
  pass "crosscheck launcher refuses old Python and discovers Python 3.11 or newer"
}

test_verify_rechecks_live_head_and_claims() {
  local record case_dir base head next_base rc verified
  record=$(make_case verify-live)
  IFS=$'\t' read -r case_dir base head <<< "$record"
  run_case "$case_dir" "$base" "$head" clear run > "$case_dir/out" 2> "$case_dir/err" \
    || fail "setup clear review failed"
  verified=$(run_case "$case_dir" "$base" "$head" clear verify) \
    || fail "verify rejected the unchanged exact head"
  [ "$verified" = "$head" ] || fail "verify did not emit the exact reviewed SHA"

  set +e
  FM_TEST_CLAIMS_VARIANT=changed run_case "$case_dir" "$base" "$head" clear verify \
    > "$case_dir/changed.out" 2> "$case_dir/changed.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "changed claims"
  assert_grep 'no crosscheck attempt exists for the live head, base, and PR claims' "$case_dir/changed.err" \
    "changed claims reused a stale verdict"

  verified=$(FM_TEST_CLAIMS_VARIANT=dynamic run_case "$case_dir" "$base" "$head" clear verify) \
    || fail "dynamic full-document metadata invalidated stable PR claims"
  [ "$verified" = "$head" ] || fail "dynamic metadata verify did not emit the exact head"

  next_base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  set +e
  run_case "$case_dir" "$next_base" "$head" clear verify \
    > "$case_dir/base.out" 2> "$case_dir/base.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "changed base"
  assert_grep 'no crosscheck attempt exists for the live head, base, and PR claims' "$case_dir/base.err" \
    "changed base reused a stale verdict"
  pass "merge verification rechecks the exact live head, base, and stable claims digest"
}

if [ -n "${FM_TEST_CASE:-}" ]; then
  case "$FM_TEST_CASE" in
    test_empty_runtime_overrides_use_home_defaults|\
    test_empty_environment_fallback_is_generic|\
    test_set_runtime_overrides_remain_authoritative|\
    test_bad_state_override_is_a_named_tool_failure|\
    test_review_fetches_exact_pr_head_when_author_worktree_is_behind|\
    test_missing_pr_head_ref_fails_closed|\
    test_claude_reviewer_provides_model_separation_for_codex_author|\
    test_codex_reviewer_requires_bound_auth_and_clears_ambient_credentials|\
    test_reviewer_execution_home_drift_fails_closed|\
    test_unrouted_author_uses_cross_provider_independence|\
    test_unrouted_author_without_account_proof_fails_closed|\
    test_missing_author_identity_is_a_named_tool_failure|\
    test_launcher_requires_supported_python|\
    test_completed_reviewer_suspicion_is_blocking|\
    test_reading_only_suspicion_is_a_tool_failure|\
    test_new_finding_requires_executed_reproduction|\
    test_silence_never_closes_prior_finding|\
    test_baseline_readable_state_is_destroyed_before_mutation|\
    test_mutation_is_bound_to_cited_non_test_implementation|\
    test_reviewer_output_uses_separate_capture_limit|\
    test_reviewer_capture_override_is_validated|\
    test_ordinary_output_paths_remain_bounded|\
    test_final_wait_and_residual_processes_are_bounded|\
    test_installed_sandbox_denies_shared_private_tmp|\
    test_real_claude_sandbox_executes_exact_sha_git_diff|\
    test_symlinked_named_test_cannot_hide_test_mutation|\
    test_evidence_batch_item_limit_precedes_execution|\
    test_node_id_selector_clears_a_passing_named_test|\
    test_absent_runner_is_never_a_test_outcome|\
    test_unclassified_runner_cannot_clear_a_finding|\
    test_positional_argument_cannot_supply_a_second_target|\
    test_flag_argument_cannot_rewrite_the_non_execution_signal|\
    test_recorded_argument_proof_loads_but_no_longer_clears|\
    test_null_ledger_fails_without_normalization|\
    test_unmatched_selector_is_never_a_failing_test|\
    test_mutated_non_execution_cannot_clear_a_finding|\
    test_ambient_addopts_cannot_rewrite_the_non_execution_signal|\
    test_ancestor_runner_config_cannot_rewrite_the_non_execution_signal|\
    test_incomplete_proof_environment_fails_loudly|\
    test_symlinked_directory_named_test_is_rejected|\
    test_symlinked_home_ancestor_still_clears|\
    test_reviewer_env_dependent_evidence_names_the_difference|\
    test_unfound_evidence_command_is_a_non_execution|\
    test_bulky_reviewer_evidence_still_completes|\
    test_tampered_review_checkout_is_still_detected|\
    test_bulky_unauthorized_scratch_is_named_not_truncated|\
    test_evidence_capture_runs_on_older_interpreters|\
    test_evidence_batch_has_aggregate_deadline)
      "$FM_TEST_CASE"
      exit 0
      ;;
    *) fail "unknown focused Crosscheck test: $FM_TEST_CASE" ;;
  esac
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-3 ]; then
  test_verified_fix_executes_mutation_proof
  test_baseline_readable_state_is_destroyed_before_mutation
  test_mutation_is_bound_to_cited_non_test_implementation
  test_final_wait_and_residual_processes_are_bounded
  test_installed_sandbox_denies_shared_private_tmp
  test_symlinked_named_test_cannot_hide_test_mutation
  test_evidence_batch_item_limit_precedes_execution
  test_evidence_batch_has_aggregate_deadline
  exit 0
fi

test_launcher_requires_supported_python
test_clear_review_uses_policy_contract
test_empty_runtime_overrides_use_home_defaults
test_empty_environment_fallback_is_generic
test_set_runtime_overrides_remain_authoritative
test_bad_state_override_is_a_named_tool_failure
test_review_fetches_exact_pr_head_when_author_worktree_is_behind
test_missing_pr_head_ref_fails_closed
test_claude_reviewer_provides_model_separation_for_codex_author
test_codex_reviewer_requires_bound_auth_and_clears_ambient_credentials
test_reviewer_execution_home_drift_fails_closed
test_unrouted_author_uses_cross_provider_independence
test_unrouted_author_without_account_proof_fails_closed
test_missing_author_identity_is_a_named_tool_failure
test_new_finding_requires_executed_reproduction
test_silence_never_closes_prior_finding
test_verified_fix_executes_mutation_proof
test_node_id_selector_clears_a_passing_named_test
test_absent_runner_is_never_a_test_outcome
test_unclassified_runner_cannot_clear_a_finding
test_positional_argument_cannot_supply_a_second_target
test_flag_argument_cannot_rewrite_the_non_execution_signal
test_unmatched_selector_is_never_a_failing_test
test_mutated_non_execution_cannot_clear_a_finding
test_ambient_addopts_cannot_rewrite_the_non_execution_signal
test_ancestor_runner_config_cannot_rewrite_the_non_execution_signal
test_incomplete_proof_environment_fails_loudly
test_symlinked_directory_named_test_is_rejected
test_symlinked_home_ancestor_still_clears
test_reviewer_env_dependent_evidence_names_the_difference
test_unfound_evidence_command_is_a_non_execution
test_bulky_reviewer_evidence_still_completes
test_tampered_review_checkout_is_still_detected
test_bulky_unauthorized_scratch_is_named_not_truncated
test_evidence_capture_runs_on_older_interpreters
test_forged_git_diff_mutation_command_is_rejected
test_stateful_test_cannot_fabricate_mutation_causality
test_baseline_readable_state_is_destroyed_before_mutation
test_mutation_is_bound_to_cited_non_test_implementation
test_final_wait_and_residual_processes_are_bounded
test_installed_sandbox_denies_shared_private_tmp
test_real_claude_sandbox_executes_exact_sha_git_diff
test_symlinked_named_test_cannot_hide_test_mutation
test_evidence_batch_item_limit_precedes_execution
test_evidence_batch_has_aggregate_deadline
test_artifacts_cannot_escape_designated_subtrees
test_reviewer_output_uses_separate_capture_limit
test_reviewer_capture_override_is_validated
test_ordinary_output_paths_remain_bounded
test_prompt_uses_only_bounded_ledger_projection
test_nonexistent_mutation_proof_is_unreviewed
test_mutation_proof_does_not_float_to_a_new_head
test_recorded_argument_proof_loads_but_no_longer_clears
test_equivalent_finding_reopens_when_direct_proof_regresses
test_null_ledger_fails_without_normalization
test_claims_lookup_error_never_reaches_reviewer
test_reviewer_configuration_failures_are_tool_failures
test_stopped_reviewer_and_wrong_head_are_unreviewed
test_completed_reviewer_suspicion_is_blocking
test_reading_only_suspicion_is_a_tool_failure
test_verify_rechecks_live_head_and_claims
