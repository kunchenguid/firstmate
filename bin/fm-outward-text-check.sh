#!/usr/bin/env bash
# fm-outward-text-check.sh - find identifiers that do not belong to the
# repository under change in text that is about to be published outward.
#
# Outward-facing published text is anything a reader of the destination
# repository keeps: a PR title, a PR description (which `no-mistakes axi run`
# composes from `--intent`), a commit message, and tracked repository content.
# Publication is not retractable - closing a PR leaves its description readable -
# so the scan belongs before the text is published, not after.
#
# The rule this check enforces is a scoping rule, never a length rule: an
# identifier may appear only when a reader holding just the repository under
# change can resolve it. The accepted requirements themselves are exactly what
# such text is for, so nothing here asks for shorter text.
# docs/outward-facing-text.md owns the contract and the categories' rationale.
#
# Usage:
#   bin/fm-outward-text-check.sh [options] <file>...   # scan files ("-" is stdin)
#   bin/fm-outward-text-check.sh [options] --diff      # scan prose lines this branch adds
#
# Options:
#   --repo <dir>     repository under change (default: the git toplevel of the cwd)
#   --home <dir>     firstmate home whose OTHER task and project names are foreign
#                    here (default: $FM_HOME; without one, those two categories
#                    are skipped and the skip is reported, never silent)
#   --task <id>      the task under change; its own id is already outward-facing
#                    through the branch name, so it is not reported
#   --base <ref>     with --diff, the ref to compare against (default: the first
#                    resolvable of origin/HEAD, origin/main, origin/master, main, master)
#   --include <glob> with --diff, a pathspec to scan instead of the prose default
#                    (repeatable; default: *.md *.mdx *.rst *.txt docs/examples/*)
#   --allow <token>  exempt one exact literal token, repeatable, for an
#                    identifier that is genuinely resolvable to this audience
#   --block-only     exit non-zero for blocking findings only, still printing
#                    the reviewable ones; for an unattended gate
#   --json           machine-readable findings
#
# An identifier a reader really can resolve - an upstream vendor's release id or
# a named upstream project's commit in a verification record - is exempted by
# listing it in the repository's tracked `.fm-outward-allow` file, one token per
# line with `#` comments. That keeps the exception explicit and reviewable in the
# same change that introduces the reference, instead of silent.
#
# Exit status: 0 clean, 1 findings reported, 2 usage or environment error.
#
# Categories, all decided against the repository under change rather than by
# keyword heuristics, so legitimate prose about dates, versions, commands, and
# relative paths is never matched. Severity is what an unattended gate can
# safely act on alone, not how bad a leak is:
#
#   blocking - nothing outside this machine or this fleet can ever resolve these,
#   so no published text has a legitimate use for them:
#     machine-local-path  an absolute path under a user home or a per-run temp root
#     foreign-task-id     a task id from the firstmate home other than --task
#     foreign-project     a project name from the firstmate home other than this repo
#
#   reviewable - a reader can resolve these when the text names the upstream they
#   come from, which no check can confirm, so they are reported for judgment and
#   settled once in `.fm-outward-allow`:
#     foreign-object      a hex object id that does not resolve in this repository
#     foreign-repo-url    a forge URL naming a repository other than this origin
#
# Known bounds, deliberate so the check stays high-precision:
#   - A hex token is treated as an identifier only when it mixes digits and
#     letters, or is at least 32 characters. A short abbreviation drawn entirely
#     from [a-f] or entirely from [0-9] reads as a word or a number here.
#   - --diff scans committed prose only. Functional hashes in code (a pinned
#     download checksum, a fixture digest) are legitimate and out of scope.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# The implementation below is fed to python3 on stdin, so a "-" input has to be
# captured here, before that redirect, or the scan would silently read the
# program text instead of the caller's piped text.
STDIN_FILE=
# shellcheck disable=SC2329 # Invoked indirectly by the traps below.
cleanup() {
  if [ -n "$STDIN_FILE" ]; then
    rm -f "$STDIN_FILE"
  fi
  return 0
}
trap cleanup EXIT INT TERM
for arg in "$@"; do
  if [ "$arg" = "-" ]; then
    STDIN_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-outward-stdin.XXXXXX") || exit 2
    cat > "$STDIN_FILE"
    break
  fi
done

STATUS=0
python3 - --stdin-file "$STDIN_FILE" "$@" <<'PY' || STATUS=$?
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

PROSE_PATHSPEC = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]
BASE_CANDIDATES = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]
ALLOW_FILE = ".fm-outward-allow"
BLOCKING = {"machine-local-path", "foreign-task-id", "foreign-project"}

# A hex run bounded by non-identifier characters. "0xdeadbeef" and "v1.2.3" do
# not match because the preceding character is part of the same word.
HEX_RE = re.compile(r"(?<![0-9A-Za-z_])([0-9a-fA-F]{7,40})(?![0-9A-Za-z_])")
FORGE_URL_RE = re.compile(
    r"https?://(?:www\.)?(github\.com|gitlab\.com|bitbucket\.org)/"
    r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"
)
# Absolute paths that name a machine and usually a user. A generic /tmp/<name>
# is deliberately absent: it identifies nobody, while a per-run temp root such
# as /var/folders/... or a clone id under it does.
MACHINE_LOCAL_RE = re.compile(
    r"(?<![A-Za-z0-9_.\-])"
    r"((?:/home/|/Users/|/root/|/var/folders/|/private/var/folders/)"
    r"[^\s'\"`)\]}>,;:]+)"
)
MIN_PRIVATE_NAME = 4
MIN_PROJECT_NAME = 6


class CheckError(Exception):
    """One environment or usage failure that stops the scan."""


def git(repo: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def resolve_repo(raw: str | None) -> Path:
    start = Path(raw).expanduser() if raw else Path.cwd()
    if not start.is_dir():
        raise CheckError(f"repository under change is not a directory: {start}")
    code, out = git(start, "rev-parse", "--show-toplevel")
    if code != 0 or not out.strip():
        raise CheckError(f"not inside a git repository: {start}")
    return Path(out.strip())


def origin_slug(repo: Path) -> tuple[str, str] | None:
    code, out = git(repo, "remote", "get-url", "origin")
    if code != 0 or not out.strip():
        return None
    url = out.strip()
    url = url[:-4] if url.endswith(".git") else url
    match = re.search(r"[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$", url)
    if not match:
        return None
    return match.group(1), match.group(2)


class ObjectResolver:
    """Answers 'does this hex id name an object in the repository under change'."""

    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self.cache: dict[str, bool] = {}

    def resolves(self, token: str) -> bool:
        cached = self.cache.get(token)
        if cached is not None:
            return cached
        code, _ = git(self.repo, "rev-parse", "--verify", "--quiet", f"{token}^{{object}}")
        found = code == 0
        if not found:
            # An ambiguous prefix fails --verify precisely because several local
            # objects share it, which still makes the id resolvable here.
            code, out = git(self.repo, "rev-parse", "--disambiguate", token.lower())
            found = code == 0 and bool(out.strip())
        self.cache[token] = found
        return found


def read_home(raw: str | None) -> Path | None:
    if not raw:
        return None
    home = Path(raw).expanduser()
    if not home.is_dir():
        raise CheckError(f"firstmate home is not a directory: {home}")
    return home


def home_task_ids(home: Path, current: str | None) -> list[str]:
    ids: set[str] = set()
    data = home / "data"
    if data.is_dir():
        ids.update(p.name for p in data.iterdir() if p.is_dir() and (p / "brief.md").is_file())
    state = home / "state"
    if state.is_dir():
        ids.update(p.name[: -len(".meta")] for p in state.glob("*.meta"))
    ids.discard(current or "")
    return sorted(i for i in ids if len(i) >= MIN_PRIVATE_NAME)


def home_projects(home: Path, repo: Path, slug: tuple[str, str] | None) -> list[str]:
    projects = home / "projects"
    if not projects.is_dir():
        return []
    own = {repo.name}
    if slug:
        own.add(slug[1])
    names = {p.name for p in projects.iterdir() if p.is_dir()} - own
    return sorted(n for n in names if len(n) >= MIN_PROJECT_NAME)


def read_allow_file(repo: Path) -> set[str]:
    path = repo / ALLOW_FILE
    if not path.is_file():
        return set()
    try:
        body = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CheckError(f"cannot read {ALLOW_FILE}: {exc}") from exc
    tokens = set()
    for line in body.splitlines():
        token = line.split("#", 1)[0].strip()
        if token:
            tokens.add(token)
    return tokens


def literal_re(name: str) -> re.Pattern[str]:
    return re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(name)}(?![A-Za-z0-9_-])")


def looks_like_an_id(token: str) -> bool:
    if len(token) >= 32:
        return True
    lowered = token.lower()
    return any(c.isdigit() for c in lowered) and any(c in "abcdef" for c in lowered)


class Scanner:
    def __init__(self, args, repo: Path, home: Path | None) -> None:
        self.repo = repo
        self.allow = set(args.allow or []) | read_allow_file(repo)
        self.seen: set[tuple[str, str, str]] = set()
        self.objects = ObjectResolver(repo)
        self.slug = origin_slug(repo)
        self.task = args.task
        self.checked = ["foreign-object", "machine-local-path"]
        self.skipped: list[str] = []
        self.findings: list[dict] = []

        if self.slug:
            self.checked.append("foreign-repo-url")
        else:
            self.skipped.append("foreign-repo-url (repository under change has no origin remote)")

        if home:
            self.task_ids = [(i, literal_re(i)) for i in home_task_ids(home, self.task)]
            self.projects = [(n, literal_re(n)) for n in home_projects(home, repo, self.slug)]
            self.checked += ["foreign-task-id", "foreign-project"]
        else:
            self.task_ids = []
            self.projects = []
            self.skipped.append("foreign-task-id, foreign-project (no firstmate home; pass --home)")

    def record(self, category: str, value: str, where: str, why: str) -> None:
        if value in self.allow:
            return
        key = (category, value, where)
        if key in self.seen:
            return
        self.seen.add(key)
        self.findings.append(
            {
                "category": category,
                "severity": "blocking" if category in BLOCKING else "reviewable",
                "value": value,
                "location": where,
                "reason": why,
            }
        )

    def scan_line(self, text: str, where: str) -> None:
        for match in HEX_RE.finditer(text):
            token = match.group(1)
            if not looks_like_an_id(token) or self.objects.resolves(token):
                continue
            self.record(
                "foreign-object", token, where, "does not name an object in the repository under change"
            )
        for match in FORGE_URL_RE.finditer(text):
            owner, name = match.group(2), match.group(3)
            name = name[:-4] if name.endswith(".git") else name
            if not self.slug or (owner.lower(), name.lower()) == (
                self.slug[0].lower(),
                self.slug[1].lower(),
            ):
                continue
            self.record("foreign-repo-url", f"{owner}/{name}", where, "names another repository")
        for match in MACHINE_LOCAL_RE.finditer(text):
            # A path at the end of a sentence keeps its own dots but not the
            # sentence's, so the reported value stays copy-pasteable.
            path = match.group(1).rstrip(".")
            if "<" in path or ">" in path:
                # An angle-bracket segment such as /Users/<user>/... is a
                # documented placeholder, which names no machine and no person.
                continue
            self.record("machine-local-path", path, where, "absolute path on this machine only")
        for name, pattern in self.task_ids:
            if pattern.search(text):
                self.record("foreign-task-id", name, where, "private task id from the firstmate home")
        for name, pattern in self.projects:
            if pattern.search(text):
                self.record("foreign-project", name, where, "another project in the firstmate home")


def scan_files(scanner: Scanner, paths: list[str], stdin_file: str | None) -> int:
    count = 0
    for raw in paths:
        if raw == "-":
            if not stdin_file:
                raise CheckError("no piped text was captured for \"-\"")
            label, path = "stdin", Path(stdin_file)
        else:
            label, path = raw, Path(raw)
        try:
            body = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise CheckError(f"cannot read {label}: {exc}") from exc
        count += 1
        for number, line in enumerate(body.splitlines(), start=1):
            scanner.scan_line(line, f"{label}:{number}")
    return count


def resolve_base(repo: Path, requested: str | None) -> str:
    candidates = [requested] if requested else BASE_CANDIDATES
    for candidate in candidates:
        code, out = git(repo, "rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}")
        if code == 0 and out.strip():
            return out.strip()
    if requested:
        raise CheckError(f"--base does not resolve to a commit: {requested}")
    raise CheckError(
        "no default branch to compare against (tried " + ", ".join(BASE_CANDIDATES) + "); pass --base"
    )


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def scan_diff(scanner: Scanner, repo: Path, base: str | None, include: list[str] | None) -> int:
    resolved = resolve_base(repo, base)
    pathspec = include if include else PROSE_PATHSPEC
    code, out = git(
        repo, "diff", "--no-color", "--unified=0", f"{resolved}...HEAD", "--", *pathspec
    )
    if code != 0:
        raise CheckError(f"could not diff HEAD against {resolved}")
    path = ""
    line_number = 0
    files: set[str] = set()
    for line in out.splitlines():
        if line.startswith("+++ "):
            target = line[4:].strip()
            path = "" if target == "/dev/null" else target[2:] if target.startswith("b/") else target
            continue
        hunk = HUNK_RE.match(line)
        if hunk:
            line_number = int(hunk.group(1))
            continue
        if line.startswith("+") and not line.startswith("+++") and path:
            files.add(path)
            scanner.scan_line(line[1:], f"{path}:{line_number}")
            line_number += 1
    return len(files)


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--repo")
    parser.add_argument("--home")
    parser.add_argument("--task")
    parser.add_argument("--base")
    parser.add_argument("--include", action="append")
    parser.add_argument("--allow", action="append")
    parser.add_argument("--diff", action="store_true")
    parser.add_argument("--block-only", dest="block_only", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--stdin-file", dest="stdin_file")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()

    if args.diff and args.files:
        raise CheckError("--diff scans the branch diff and takes no file arguments")
    if not args.diff and not args.files:
        raise CheckError("pass one or more files, \"-\" for stdin, or --diff")
    if args.include and not args.diff:
        raise CheckError("--include applies to --diff only")

    repo = resolve_repo(args.repo)
    home = read_home(args.home if args.home else None)
    scanner = Scanner(args, repo, home)

    if args.diff:
        inputs = scan_diff(scanner, repo, args.base, args.include)
        subject = "changed prose file"
    else:
        inputs = scan_files(scanner, args.files, args.stdin_file)
        subject = "input"

    blocking = [f for f in scanner.findings if f["severity"] == "blocking"]

    if args.json:
        print(
            json.dumps(
                {
                    "repo": str(repo),
                    "inputs": inputs,
                    "checked": scanner.checked,
                    "skipped": scanner.skipped,
                    "findings": scanner.findings,
                },
                indent=2,
            )
        )
    else:
        for finding in scanner.findings:
            print(
                f"{finding['category'].upper().replace('-', '_')}: {finding['value']} "
                f"({finding['location']}) - {finding['reason']}"
            )
        for note in scanner.skipped:
            print(f"SKIPPED: {note}")
        plural = "" if inputs == 1 else "s"
        if scanner.findings:
            counted = f"{len(scanner.findings)} finding(s), {len(blocking)} blocking"
            print(
                f"outward-text-check: {counted} in {inputs} {subject}{plural}; "
                f"remove each one from the text, or justify it in {ALLOW_FILE}, before publishing"
            )
        else:
            print(
                f"outward-text-check: clean ({inputs} {subject}{plural}; "
                f"checked {', '.join(scanner.checked)})"
            )

    if args.block_only:
        return 1 if blocking else 0
    return 1 if scanner.findings else 0


try:
    sys.exit(main())
except CheckError as exc:
    print(f"outward-text-check: {exc}", file=sys.stderr)
    sys.exit(2)
except BrokenPipeError:
    sys.exit(2)
PY
exit "$STATUS"
