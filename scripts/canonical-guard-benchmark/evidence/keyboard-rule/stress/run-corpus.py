#!/usr/bin/env python3
"""Run every labelled evasion case against `pnpm check:canonical` in a scratch checkout.

Each case gets its own throwaway branch off the pinned head, so no case can see
another's files. The recorded verdict is the observed exit code and output of
the project's own command; nothing here predicts or interprets the rule.
"""

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys

RESULT_VERSION = "keyboard-rule-evasion-result/v1"


def git(repo: pathlib.Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed in {repo}: {result.stderr.strip()}")
    return result.stdout.strip()


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def commit_environment() -> dict[str, str]:
    # Lefthook's pre-commit rewrites staged files with biome; a corpus case must
    # reach the guard exactly as written, so the hook manager is switched off
    # rather than the commit's own verification bypassed.
    return {
        **os.environ,
        "LEFTHOOK": "0",
        "GIT_AUTHOR_NAME": "Evasion Corpus",
        "GIT_AUTHOR_EMAIL": "corpus@example.invalid",
        "GIT_COMMITTER_NAME": "Evasion Corpus",
        "GIT_COMMITTER_EMAIL": "corpus@example.invalid",
        "GIT_AUTHOR_DATE": "2026-09-02T00:00:00Z",
        "GIT_COMMITTER_DATE": "2026-09-02T00:00:00Z",
    }


def contained(repo: pathlib.Path, path: str) -> pathlib.Path:
    """A corpus path resolved inside the checkout, or a refusal.

    Corpus files are data. A case that names `../x` would otherwise be written
    outside the checkout the runner is about to reset, so containment is checked
    before anything is created rather than trusted.
    """
    if pathlib.PurePosixPath(path).is_absolute() or path.startswith("/"):
        raise SystemExit(f"corpus path is absolute: {path}")
    destination = (repo / path).resolve()
    if not destination.is_relative_to(repo.resolve()):
        raise SystemExit(f"corpus path escapes the checkout: {path}")
    if ".git" in pathlib.PurePosixPath(path).parts:
        raise SystemExit(f"corpus path reaches into the repository's own metadata: {path}")
    return destination


def apply_commit(repo: pathlib.Path, commit: dict, env: dict[str, str]) -> None:
    for path, source in commit.get("write", {}).items():
        destination = contained(repo, path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(source)
        git(repo, "add", "--", path)
    for old, new in commit.get("rename", {}).items():
        contained(repo, old)
        contained(repo, new)
        (repo / new).parent.mkdir(parents=True, exist_ok=True)
        git(repo, "mv", "--", old, new)
    result = subprocess.run(
        ["git", "commit", "-m", commit["message"]],
        cwd=repo, text=True, capture_output=True, env=env,
    )
    if result.returncode != 0:
        raise SystemExit(f"commit failed: {result.stdout}\n{result.stderr}")


def check_canonical(repo: pathlib.Path) -> dict:
    result = subprocess.run(
        ["pnpm", "check:canonical"], cwd=repo, text=True, capture_output=True,
        env={**os.environ, "CI": "1"},
    )
    return {"exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


SCRATCH_MARKER = ".keyboard-rule-corpus-scratch"


def require_scratch(repo: pathlib.Path) -> None:
    """Refuse any checkout that has not been declared disposable.

    Every case ends in `reset --hard` and `clean -fdq`. Pointed at an ordinary
    working copy that would destroy uncommitted work, so the runner requires a
    marker file the operator had to create on purpose.
    """
    if not (repo / SCRATCH_MARKER).is_file():
        raise SystemExit(
            f"{repo} is not a declared corpus scratch checkout. This runner resets and cleans the tree "
            f"between cases and will not do that to a checkout that has not opted in. "
            f"Create {SCRATCH_MARKER} in it if it is disposable."
        )


def dirt(repo: pathlib.Path) -> str:
    """Working-tree state that is not the opt-in scratch marker."""
    return "\n".join(line for line in git(repo, "status", "--porcelain").splitlines()
                      if SCRATCH_MARKER not in line)


def restore(repo: pathlib.Path, head: str, branch: str) -> None:
    """Put the checkout back on the pinned head, or stop.

    A restoration that silently failed would let one case's files reach the
    next, so every step is checked and a failure ends the run.
    """
    git(repo, "checkout", "--detach", head)
    git(repo, "reset", "--hard", head)
    git(repo, "clean", "-fdq", "-e", SCRATCH_MARKER)
    git(repo, "branch", "-D", branch, check=False)
    if dirt(repo):
        raise SystemExit(f"checkout did not return to {head} after a case; refusing to continue")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--head", required=True, help="pinned commit every case branches from")
    arguments = parser.parse_args()

    repo = pathlib.Path(arguments.repo).resolve()
    corpus = json.loads(pathlib.Path(arguments.corpus).read_text())
    out = pathlib.Path(arguments.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    head = git(repo, "rev-parse", "--verify", f"{arguments.head}^{{commit}}")
    require_scratch(repo)
    if dirt(repo):
        raise SystemExit(f"scratch checkout is dirty, refusing to run: {repo}")
    # Each case is undone with `reset --hard`, which rewrites tracked files even
    # when they are marked assume-unchanged. A prepared GUARD-OFF template hides
    # its arm difference exactly that way, so running here would silently restore
    # the rule it removed.
    if any(line[:1].islower() for line in git(repo, "ls-files", "-v").splitlines()):
        raise SystemExit(f"checkout hides tracked changes, refusing to run: {repo}")

    env = commit_environment()
    marker = f"[{corpus['rule_id']}]"
    records = []

    git(repo, "checkout", "--detach", head)
    baseline = check_canonical(repo)
    records.append({
        "schema_version": RESULT_VERSION,
        "id": "__baseline__",
        "label": "Unmodified pinned head, no case applied",
        "pattern": "none",
        "head": head,
        "recorded_at": utc_now(),
        "rule_fired": marker in baseline["stderr"],
        "verdict": "baseline",
        "evidence": [line for line in baseline["stderr"].splitlines() if marker in line],
        "paths": [],
        "commits": [],
        "check": baseline,
    })

    for case in corpus["cases"]:
        branch = f"evasion/{case['id']}"
        git(repo, "checkout", "-B", branch, head)
        try:
            for commit in case["commits"]:
                apply_commit(repo, commit, env)
            outcome = check_canonical(repo)
            fired = marker in outcome["stderr"]
            expected = case.get("expected", "fire")
            records.append({
                "schema_version": RESULT_VERSION,
                "id": case["id"],
                "label": case["label"],
                "pattern": case["pattern"],
                "head": head,
                "branch": branch,
                "recorded_at": utc_now(),
                "commits": [item["message"].splitlines()[0] for item in case["commits"]],
                "paths": sorted(
                    {path for item in case["commits"] for path in item.get("write", {})}
                    | {new for item in case["commits"] for new in item.get("rename", {}).values()}
                ),
                "rule_fired": fired,
                "expected": expected,
                # An evasion case is judged by whether the guard spoke; a
                # legitimate case by whether it stayed quiet. One scorer, two
                # vocabularies, so a false alarm cannot read as a catch.
                "verdict": ("caught" if fired else "missed") if expected == "fire"
                           else ("false-alarm" if fired else "quiet"),
                "evidence": [line for line in outcome["stderr"].splitlines() if marker in line],
                "check": outcome,
            })
        finally:
            restore(repo, head, branch)

    out.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in records))
    tally = {name: sum(1 for row in records if row.get("verdict") == name)
             for name in ("caught", "missed", "quiet", "false-alarm")}
    print(json.dumps({
        "cases": len(corpus["cases"]), **tally,
        "baseline_exit": baseline["exit_code"], "head": head, "results": str(out),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
