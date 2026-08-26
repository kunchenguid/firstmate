#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-runtime)
PI_PACKAGE="$TMP_ROOT/pi"
FAST_PACKAGE="$TMP_ROOT/fast"
KETCH_PACKAGE="$TMP_ROOT/ketch"
mkdir -p "$PI_PACKAGE/dist" "$FAST_PACKAGE/src" "$KETCH_PACKAGE/src"

cat > "$PI_PACKAGE/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","version":"0.84.2"}
JSON
cat > "$PI_PACKAGE/dist/cli.js" <<'SH'
#!/bin/sh
set -eu
[ "$PI_CODING_AGENT_DIR" = "$HOME/pi-agent" ]
case "$*" in *--no-extensions*) ;; *) echo "Pi discovery was not disabled" >&2; exit 21 ;; esac
case "$*" in *pi-openai-fast-mode/src/index.ts*) ;; *) echo "fast mode was not pinned" >&2; exit 22 ;; esac
case "$*" in *fast-mode-all-codex-accounts.ts*) ;; *) echo "fleet fast mode was not pinned" >&2; exit 23 ;; esac
case "$*" in *pi-ketch/src/index.ts*) ;; *) echo "Ketch was not pinned" >&2; exit 24 ;; esac
case " $* " in *" --version "*) printf '%s\n' '0.84.2'; exit 0 ;; esac
[ -s "$PI_CODING_AGENT_DIR/auth.json" ]
printf '%s\n' "$HOME" > "$HOME/pi-started-under-home"
printf '%s\n' '{"type":"session","id":"11111111-1111-4111-8111-111111111111"}'
SH
cat > "$FAST_PACKAGE/package.json" <<'JSON'
{"name":"pi-openai-fast-mode","version":"0.3.0"}
JSON
printf 'export default function () {}\n' > "$FAST_PACKAGE/src/index.ts"
cat > "$KETCH_PACKAGE/package.json" <<'JSON'
{"name":"pi-ketch","version":"0.1.6"}
JSON
printf 'export default function () {}\n' > "$KETCH_PACKAGE/src/index.ts"
printf 'export default function () {}\n' > "$TMP_ROOT/fast-fleet.ts"

cat > "$TMP_ROOT/node" <<'SH'
#!/bin/sh
exec /bin/sh "$@"
SH
cat > "$TMP_ROOT/no-mistakes" <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 8 ]
[ "$1" = worker ] && [ "$2" = run ] && [ "$3" = --role ] && [ "$4" = review ]
[ "$5" = --brief ] && [ "$7" = --result ] && [ "$8" = outcome.json ]
case "$6" in /*/.fm-task/brief.md) ;; *) exit 25 ;; esac
[ -f "$6" ]
pi --mode json --no-session </dev/null >/dev/null
head=$(git rev-parse HEAD)
cat > outcome.json <<JSON
{"schema":"no-mistakes.worker-step-outcome/v1","step":"review","needs_approval":false,"auto_fixable":false,"exit_code":0,"skipped":false,"skip_remaining":false,"review_approved_head_sha":"$head"}
JSON
SH
chmod 755 "$TMP_ROOT/node" "$TMP_ROOT/no-mistakes" "$PI_PACKAGE/dist/cli.js"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' \
  || fail "credential-free Pi runtime did not execute the worker through its bundled Node"
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile

root, temporary = Path(sys.argv[1]), Path(sys.argv[2])

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

builder = load("runtime_builder", root / "bin/fm-no-mistakes-runtime.py")
supervisor = load("worker_supervisor", root / "bin/fm-worker-supervisor.py")
assert supervisor.MAX_NO_MISTAKES_RUNTIME_FILES == builder.MAX_FILES, (
    supervisor.MAX_NO_MISTAKES_RUNTIME_FILES, builder.MAX_FILES)
bundle = temporary / "runtime.tar.gz"
args = argparse.Namespace(
    no_mistakes=str(temporary / "no-mistakes"), node=str(temporary / "node"),
    pi_package=str(temporary / "pi"), fast_mode_package=str(temporary / "fast"),
    fast_mode_fleet_extension=str(temporary / "fast-fleet.ts"),
    ketch_package=str(temporary / "ketch"), no_mistakes_version="test-1",
    no_mistakes_source_commit="1" * 40, output=str(bundle),
)
manifest = builder.build(args, enforce_linux=False)
assert manifest["provider"] == "pi"
assert manifest["provider_path"] == "bin/pi"
assert manifest["node_path"] == "bin/node"
with tarfile.open(bundle, "r:gz") as archive:
    names = {item.name for item in archive.getmembers()}
assert not any(Path(name).name in {"auth.json", ".npmrc", ".env"} for name in names)

guest = temporary / "guest"
repo = guest / "repo"
account = temporary / "assigned-account"
(account / "pi-agent").mkdir(parents=True)
(account / "pi-agent/auth.json").write_text('{"openai-codex":{"type":"oauth","access":"fixture"}}\n')
guest.mkdir()
subprocess.run(["git", "init", "-q", str(repo)], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "fixture"], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"], check=True)
(repo / "file.txt").write_text("base\n")
subprocess.run(["git", "-C", str(repo), "add", "file.txt"], check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
supervisor.stage_no_mistakes_runtime(bundle, guest / ".fm-runtime", enforce_linux=False)
(guest / ".fm-task").mkdir()
(guest / ".fm-task" / "brief.md").write_text("review this exact head\n")
os.environ["FM_WORKER_ACCOUNT_HOME"] = str(account)
os.environ["FM_WORKER_OUTCOME_FILE"] = str(temporary / "outcome.bundle")
request = {
    "task": "runtime-e2e", "task_generation": "generation-e2e",
    "assignment_generation": "asg-e2e", "request_digest": "2" * 64,
    "cloud_instance_id": "vm-e2e", "repository_binding": "3" * 64,
    "repository_generation": head, "worker_role": "no-mistakes",
    "outcome_expected": True,
    "argv": ["no-mistakes", "worker", "run", "--role", "review",
             "--brief", "brief.md", "--result", "outcome.json"],
    "wall_seconds": 30,
    "service_return_contract": {
        "schema": "fm.no-mistakes-worker-return/v1",
        "step_outcome_path": "outcome.json", "step_outcome_max_bytes": 1048576,
    },
}
result = supervisor.execute(request, repo, guest)
stderr = (guest / ".fm-worker" / (("2" * 32) + "-stderr.log")).read_text()
assert result["exit_code"] == 0, (result, stderr)
assert result.get("service_return_present") is True, result
status = subprocess.check_output(
    ["git", "-C", str(repo), "status", "--porcelain"], text=True,
)
assert status == "?? outcome.json\n", status
assert (account / "pi-started-under-home").read_text().strip() == str(account)
assert (account / "pi-agent/extensions/pi-openai-fast-mode/config.json").is_file()
assert not (guest / ".fm-runtime/auth.json").exists()
PY
pass "credential-free Pi bundle runs no-mistakes under the lifecycle-selected account HOME"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' \
  || fail "production builder did not refuse host-native Node"
import argparse
import importlib.util
from pathlib import Path
import sys
root, temporary = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("runtime_builder", root / "bin/fm-no-mistakes-runtime.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
args = argparse.Namespace(
    no_mistakes=str(temporary / "no-mistakes"), node=str(temporary / "node"),
    pi_package=str(temporary / "pi"), fast_mode_package=str(temporary / "fast"),
    fast_mode_fleet_extension=str(temporary / "fast-fleet.ts"),
    ketch_package=str(temporary / "ketch"), no_mistakes_version="test-1",
    no_mistakes_source_commit="1" * 40, output=str(temporary / "must-refuse.tar.gz"),
)
try:
    module.build(args)
except module.RuntimeError as exc:
    assert "Linux amd64 ELF" in str(exc)
else:
    raise AssertionError("host-native fixture was accepted as a production runtime")
PY
pass "production builder refuses an unpinned host Node/runtime pairing"

fm_assert_no_cloud_reach "no-mistakes Pi runtime tests remain hermetic"
