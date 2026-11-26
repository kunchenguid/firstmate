#!/usr/bin/env bash
# Exercise the cleanup CLI against real Git worktrees and real cwd holders, in a
# schema v4 pool and a pool whose reservation state has no version.
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
import time
from unittest.mock import patch

script, scratch = Path(sys.argv[1]), Path(sys.argv[2])
root = scratch / "pools"
pool = root / "fixture-f88f42"
legacy = root / "legacy-0a1b2c"
state = scratch / "state"
extra_state = scratch / "state-extra"
checkout = scratch / "source"
for path in (pool, legacy, state, extra_state, checkout):
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

rows, legacy_rows = [], []


def make_slot(**reservation):
    return add_slot(pool, rows, seed_inventory_known=True, seed_inventory_digest="a" * 64, **reservation)


def add_slot(pool, rows, **record):
    number = str(len(rows) + 1)
    slot = pool / number / "project with space"
    slot.parent.mkdir()
    git(checkout, "worktree", "add", "--quiet", "--detach", str(slot))
    write(slot / "node_modules/package/index.js", "generated\n" * 1000)
    rows.append(dict(name=number, path=str(slot), **record))
    return slot


def age(slot, hours=25):
    # Backdate everything the idle rule reads: the slot, its top level, and the index.
    when = time.time() - hours * 3600
    index = Path(git(slot, "rev-parse", "--path-format=absolute", "--git-path", "index").decode().strip())
    for path in [slot, index, *slot.iterdir()]:
        os.utime(path, (when, when), follow_symlinks=False)


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

aged = make_slot()  # Idle 24 hours, so a hidden same-user cwd does not block it.
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

# Without reservation records, every slot gate plus 24 idle hours must hold.
legacy_idle = add_slot(legacy, legacy_rows)
legacy_fresh = add_slot(legacy, legacy_rows)
legacy_index = add_slot(legacy, legacy_rows)
legacy_entry = add_slot(legacy, legacy_rows)
legacy_owner = add_slot(legacy, legacy_rows, owner_pid=12345, owner_started_at=100)
legacy_seeded = add_slot(legacy, legacy_rows, seeded_paths=["node_modules/package/index.js"])
legacy_claimed = add_slot(legacy, legacy_rows)
write(legacy_claimed.parent / ".fm-slot-owner")
legacy_meta = add_slot(legacy, legacy_rows)
write(state / "legacy.meta", f"endpoint_task_id=demo\nworktree={legacy_meta}\n")
legacy_cwd = add_slot(legacy, legacy_rows)
legacy_dirty = add_slot(legacy, legacy_rows)
write(legacy_dirty / "source.txt", "modified\n")
for slot in [aged, *(Path(row["path"]) for row in legacy_rows)]:
    age(slot)
age(legacy_fresh, hours=23)
os.utime(Path(git(legacy_index, "rev-parse", "--path-format=absolute", "--git-path", "index").decode().strip()))
os.utime(legacy_entry / "node_modules")
legacy_checked = [legacy_idle / "node_modules"]
legacy_lock = legacy / "treehouse-state.lock"
legacy_lock.touch()
legacy_inventory = legacy / "treehouse-state.json"
legacy_authority = json.dumps({"worktrees": legacy_rows})
write(legacy_inventory, legacy_authority)

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


real_open = open
other_uid = os.geteuid() + 1
hidden_owner = {"same": f"Uid:\t{other_uid}\t{os.geteuid()}\t{other_uid}\t{other_uid}\n",
                "other": f"Uid:\t{other_uid}\t{other_uid}\t{other_uid}\t{other_uid}\n"}


def cli(*args, pids=(), denied=None, rc=0):
    # denied: a hidden cwd whose status names our uid ("same"), only other uids
    # ("other"), or cannot be read ("unknown").
    unknown = "2147483647"
    fixture_pids = [str(os.getpid()), *(str(pid) for pid in pids)] + ([unknown] if denied else [])

    def fixture_link(path, *args, **kwargs):
        if path == f"/proc/{unknown}/cwd":
            raise PermissionError(path)
        return readlink(path, *args, **kwargs)

    def fixture_open(path, *args, **kwargs):
        if path == f"/proc/{unknown}/status":
            if denied not in hidden_owner:
                raise PermissionError(path)
            return io.BytesIO(f"Name:\tfixture\n{hidden_owner[denied]}".encode())
        return real_open(path, *args, **kwargs)

    stdout = io.StringIO()
    with patch.object(sys, "argv", argv + list(args)), contextlib.redirect_stdout(stdout), \
            patch.object(os, "listdir", lambda path: fixture_pids if path == "/proc" else listdir(path)), \
            patch.object(os, "readlink", fixture_link), patch("builtins.open", fixture_open):
        try:
            runpy.run_path(str(script), run_name="__main__")
        except SystemExit as exc:
            assert exc.code == rc, (exc.code, stdout.getvalue())
        else:
            raise AssertionError("CLI did not exit")
    return stdout.getvalue()


assert "--apply" in cli("--help")
holders = [subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], cwd=cwd)
           for cwd in (cwd_only / "node_modules/package", legacy_cwd)]
pids = [holder.pid for holder in holders]
everything = checked + legacy_checked
try:
    preview = cli(pids=pids)
    assert "would remove 'node_modules'" in preview, preview
    assert re.search(r"Total estimated bytes reclaimable \(dry-run\): [1-9][0-9]*", preview), preview
    assert f"{str(legacy)!r}: reservation state is not schema v4" in preview, preview
    assert f"{str(legacy_idle)!r}: would remove 'node_modules'" in preview, preview
    assert all(path.is_dir() for path in everything)

    with lock.open("rb") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        contended = cli("--apply", pool.name, pids=pids)
        assert "Treehouse pool lock held" in contended and "Total estimated bytes freed: 0" in contended
        assert all(path.is_dir() for path in checked)

    # A hidden cwd whose owner cannot be read blocks every slot.
    blocked = cli("--apply", denied="unknown", pids=pids)
    assert "cannot verify 1 process cwd(s)" in blocked and "Total estimated bytes freed: 0" in blocked, blocked
    assert all(path.is_dir() for path in everything + [aged / "node_modules"])

    # A hidden cwd of our own user blocks a slot touched within 24 hours only.
    hidden = cli("--apply", pool.name, denied="same", pids=pids)
    assert f"{str(idle)!r}: skipped: slot touched within 24 hours and 1 same-user process cwd(s) are hidden" \
        in hidden, hidden
    assert f"{str(aged)!r}: removed 'node_modules'" in hidden, hidden
    assert not (aged / "node_modules").exists() and all(path.is_dir() for path in everything)

    # An ambiguous slot identity must refuse the entire pool, even when one
    # record looks free and the other holds a lease, whatever the state version.
    for path, data, name in ((inventory, {"version": 4, "worktrees": rows}, pool.name),
                             (legacy_inventory, {"worktrees": legacy_rows}, legacy.name)):
        original = path.read_text()
        data["worktrees"] = data["worktrees"] + [dict(data["worktrees"][0], name="duplicate", leased=True)]
        write(path, json.dumps(data))
        ambiguous = cli("--apply", name, pids=pids, rc=1)
        assert "duplicate Treehouse slot identity" in ambiguous, ambiguous
        assert all(path.is_dir() for path in everything)
        write(path, original)

    # Another user's hidden cwd does not block, even in a slot touched within 24 hours.
    actual = cli("--apply", denied="other", pids=pids)
    assert re.search(r"Total estimated bytes freed: [1-9][0-9]*", actual), actual
    assert all(not path.exists() for path in everything), actual
    for slot, reason in ((leased, "Treehouse reservation"), (owner, "Treehouse reservation"),
                         (meta_only, "Firstmate task metadata"), (claimed, "Firstmate slot-owner"),
                         (cwd_only, "process cwd in the slot"), (dirty, "Git status is not clean"),
                         (untracked, "Git status is not clean"), (seeded, "seeded or unverified"),
                         (legacy_fresh, "slot touched within 24 hours"),
                         (legacy_index, "slot touched within 24 hours"),
                         (legacy_entry, "slot touched within 24 hours"),
                         (legacy_owner, "Treehouse reservation"), (legacy_seeded, "seeded or unverified"),
                         (legacy_claimed, "Firstmate slot-owner"),
                         (legacy_meta, "Firstmate task metadata"), (legacy_cwd, "process cwd in the slot"),
                         (legacy_dirty, "Git status is not clean")):
        assert (slot / "node_modules/package/index.js").is_file(), actual
        assert any(str(slot) in line and reason in line for line in actual.splitlines()), actual
    assert inventory.read_text() == authority and legacy_inventory.read_text() == legacy_authority
    assert (idle / ".git").is_file() and not git(idle, "status", "--porcelain")
    for kept in (idle / ".env.local", idle / "source.txt", idle / "vendor/node_modules/checked-in.js",
                 idle / "not-terraform/.terraform/providers/keep.bin",
                 idle / "terraform/.terraform/terraform.tfstate", secret_tree / "dependency/.env.example",
                 git_tree / "reserved/.git", external / ".env"):
        assert kept.is_file(), kept
    assert symlink_target.is_symlink()
    print("ok - dry-run, locked apply, refusal gates, unversioned pools, and protected paths")
finally:
    for holder in holders:
        holder.terminate()
        holder.wait(timeout=5)
PY
