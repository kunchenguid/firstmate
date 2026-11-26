#!/usr/bin/env bash
# Exercise the cleanup CLI against real Git worktrees and a real cwd holder.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"
if [ "$(uname -s)" != Linux ]; then
  echo 'skip: disk pool cleanup requires Linux procfs'
  exit 0
fi

scratch=$(fm_test_tmproot fm-disk-pool-safe-cleanup)
python3 - "$ROOT/bin/fm-disk-pool-safe-cleanup.py" "$scratch" <<'PY'
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
from unittest.mock import patch

script, scratch = Path(sys.argv[1]), Path(sys.argv[2])
root = scratch / "pools"
pool = root / "fixture-f88f42"
state = scratch / "state"
extra_state = scratch / "state-extra"
checkout = scratch / "source"
for path in (pool, state, extra_state, checkout):
    path.mkdir(parents=True)


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True).stdout


def write(path, content="fixture\n"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


git(checkout, "init", "--quiet")
write(checkout / ".gitignore", "node_modules/\n.next/\n.venv/\ndbt/target/\ndbt/dbt_packages/\n.terraform/\n.env*\n")
write(checkout / "source.txt")
write(checkout / "apps/site/package.json", "{}\n")
write(checkout / "vendor/node_modules/checked-in.js")
git(checkout, "add", "--all")
git(checkout, "add", "-f", "vendor/node_modules/checked-in.js")
git(checkout, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")

rows = []


def make_slot(**reservation):
    number = str(len(rows) + 1)
    slot = pool / number / "project with space"
    slot.parent.mkdir()
    git(checkout, "worktree", "add", "--quiet", "--detach", str(slot))
    write(slot / "node_modules/package/index.js", "generated\n" * 1000)
    rows.append(dict(name=number, path=str(slot), seed_inventory_known=True,
                     seed_inventory_digest="a" * 64, **reservation))
    return slot


idle = make_slot()
checked = [idle / "node_modules"]
for rel in ("apps/site/.next", ".venv", "dbt/target", "dbt/dbt_packages",
            "terraform/.terraform/providers", "terraform/modules/demo/.terraform/providers"):
    generated = idle / rel
    write(generated / "generated.bin")
    checked.append(generated)
write(idle / "vendor/node_modules/keep.txt")
write(idle / ".env.local")
write(idle / "terraform/.terraform/terraform.tfstate")
write(idle / "apps/site/node_modules/dependency/.env.example")
secret_tree = idle / "apps/site/node_modules"
write(idle / "apps/site/.venv/reserved/.git")
git_tree = idle / "apps/site/.venv"
external = scratch / "outside"
write(external / ".env")
(idle / "node_modules/package/copy").symlink_to(external, target_is_directory=True)
write(idle / "not-terraform/.terraform/providers/keep.bin")
symlink_target = idle / "terraform/modules/linked/.terraform/providers"
symlink_target.parent.mkdir(parents=True)
symlink_target.symlink_to(external, target_is_directory=True)

leased = make_slot(leased=True)
owner = make_slot(owner_pid=12345, owner_started_at=100)
meta_only = make_slot()
write(extra_state / "inflight.meta", f"worktree={meta_only}")  # No final newline.
claimed = make_slot()
write(claimed.parent / ".fm-slot-owner")
cwd_only = make_slot()
dirty = make_slot()
write(dirty / "source.txt", "modified\n")
untracked = make_slot()
write(untracked / "new-source.txt")
seeded = make_slot(seeded_paths=["node_modules/package/index.js"])

lock = pool / "treehouse-state.lock"
lock.touch()
inventory = pool / "treehouse-state.json"
authority = json.dumps({"version": 4, "worktrees": rows})
write(inventory, authority)
argv = [str(script), "--pool-root", str(root), "--state-dir", str(state),
        "--state-dir", str(extra_state)]

# Bound the fixture census to our own process and a real child. Do not weaken
# production CLI checks to accommodate restricted PIDs on shared CI hosts.
listdir, readlink = os.listdir, os.readlink


def cli(*args, pids=(), denied=False, rc=0):
    unknown = "2147483647"
    fixture_pids = [str(os.getpid()), *(str(pid) for pid in pids)] + ([unknown] if denied else [])

    def fixture_link(path, *args, **kwargs):
        if path == f"/proc/{unknown}/cwd":
            raise PermissionError(path)
        return readlink(path, *args, **kwargs)

    stdout = io.StringIO()
    with patch.object(sys, "argv", argv + list(args)), contextlib.redirect_stdout(stdout), \
            patch.object(os, "listdir", lambda path: fixture_pids if path == "/proc" else listdir(path)), \
            patch.object(os, "readlink", fixture_link):
        try:
            runpy.run_path(str(script), run_name="__main__")
        except SystemExit as exc:
            assert exc.code == rc, (exc.code, stdout.getvalue())
        else:
            raise AssertionError("CLI did not exit")
    return stdout.getvalue()


assert "--apply" in cli("--help")
proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                        cwd=cwd_only / "node_modules/package")
try:
    preview = cli(pids=[proc.pid])
    assert "would remove 'node_modules'" in preview, preview
    assert re.search(r"Total estimated bytes reclaimable \(dry-run\): [1-9][0-9]*", preview), preview
    assert all(path.is_dir() for path in checked)

    with lock.open("rb") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        contended = cli("--apply", pids=[proc.pid])
        assert "Treehouse pool lock held" in contended and "Total estimated bytes freed: 0" in contended
        assert all(path.is_dir() for path in checked)

    blocked = cli("--apply", denied=True, pids=[proc.pid])
    assert "cannot verify 1 process cwd(s)" in blocked and "Total estimated bytes freed: 0" in blocked
    assert all(path.is_dir() for path in checked)

    # An ambiguous slot identity must refuse the entire pool, even when one
    # record looks free and the other holds a lease.
    write(inventory, json.dumps({"version": 4, "worktrees": rows + [dict(rows[0], name="duplicate", leased=True)]}))
    ambiguous = cli("--apply", pids=[proc.pid], rc=1)
    assert "duplicate Treehouse slot identity" in ambiguous
    assert all(path.is_dir() for path in checked)
    write(inventory, authority)

    actual = cli("--apply", pids=[proc.pid])
    assert re.search(r"Total estimated bytes freed: [1-9][0-9]*", actual), actual
    assert all(not path.exists() for path in checked), actual
    for slot, reason in ((leased, "Treehouse reservation"), (owner, "Treehouse reservation"),
                         (meta_only, "Firstmate task metadata"), (claimed, "Firstmate slot-owner"),
                         (cwd_only, "process cwd in the slot"), (dirty, "Git status is not clean"),
                         (untracked, "Git status is not clean"), (seeded, "seeded or unverified")):
        assert (slot / "node_modules/package/index.js").is_file(), actual
        assert any(str(slot) in line and reason in line for line in actual.splitlines()), actual
    assert inventory.read_text() == authority
    assert (idle / ".git").is_file() and not git(idle, "status", "--porcelain")
    for kept in (idle / ".env.local", idle / "source.txt", idle / "vendor/node_modules/checked-in.js",
                 idle / "not-terraform/.terraform/providers/keep.bin",
                 idle / "terraform/.terraform/terraform.tfstate", secret_tree / "dependency/.env.example",
                 git_tree / "reserved/.git", external / ".env"):
        assert kept.is_file(), kept
    assert symlink_target.is_symlink()
    print("ok - dry-run, locked apply, refusal gates, and protected paths")
finally:
    proc.terminate()
    proc.wait(timeout=5)
PY
