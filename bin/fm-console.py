#!/usr/bin/env python3
"""Local, deterministic Firstmate operator console."""

from __future__ import annotations

import argparse
import datetime
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.parse
import webbrowser
from pathlib import Path


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAX_ANSWER = 8192
PR_QUERY = """query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      url
      state
      isDraft
      merged
      mergedAt
      reviewDecision
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                totalCount
                pageInfo { hasNextPage }
                nodes {
                  __typename
                  ... on CheckRun { name status conclusion }
                  ... on StatusContext { context state }
                }
              }
            }
          }
        }
      }
    }
  }
}"""


def run(command: list[str], *, cwd: Path, env: dict[str, str], timeout: int = 30,
        input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout, input=input_text)


def snapshot_epoch(value: dict) -> int:
    epoch = value.get("generated_epoch")
    if isinstance(epoch, (int, float)) and not isinstance(epoch, bool):
        return int(epoch)
    generated = value.get("generated")
    if not isinstance(generated, str) or not generated:
        raise ValueError("fleet snapshot has no valid generation timestamp")
    try:
        parsed = datetime.datetime.fromisoformat(generated.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("fleet snapshot generation timestamp is invalid") from exc
    if parsed.tzinfo is None:
        raise ValueError("fleet snapshot generation timestamp has no timezone")
    return int(parsed.timestamp())


def registered_projects(home: Path) -> list[str]:
    path = home / "data" / "projects.md"
    names = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) > 1 and parts[0] == "-" and PROJECT_RE.fullmatch(parts[1]):
                names.append(parts[1])
    except OSError:
        pass
    return sorted(set(names))


def repository_identity(home: Path, project: str) -> str | None:
    clone = home / "projects" / project
    if not clone.is_dir() or clone.is_symlink():
        return None
    try:
        result = subprocess.run(["git", "-C", str(clone), "config", "--get", "remote.origin.url"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    origin = result.stdout.strip()
    match = re.fullmatch(r"git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", origin)
    if match:
        return match.group(1).lower()
    parsed = urllib.parse.urlsplit(origin)
    path = parsed.path.strip("/").removesuffix(".git")
    if parsed.hostname and parsed.hostname.lower() == "github.com" and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path):
        return path.lower()
    return None


def url_repository(url: str) -> str:
    return "/".join(url.removeprefix("https://github.com/").split("/")[:2]).lower()


def snapshot(home: Path, root: Path) -> dict:
    env = {**os.environ, "FM_HOME": str(home)}
    env.pop("FM_ROOT_OVERRIDE", None)
    result = run([str(root / "bin" / "fm-fleet-snapshot.sh"), "--json"], cwd=root, env=env, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr[-1000:] or "fleet snapshot failed")
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or value.get("schema") != "fm-fleet-snapshot.v1":
        raise RuntimeError("unsupported fleet snapshot schema")
    return value


def issue_urls(record: dict, project_home: Path | None = None) -> list[str]:
    backlog = record.get("backlog") or {}
    values = [record.get("issue"), *(backlog.get("links") or record.get("links") or [])]
    urls = []
    for value in values:
        if isinstance(value, str) and re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*", value):
            urls.append(value)
    text = "\n".join(str(line) for line in (record.get("body_lines") or backlog.get("body_lines") or []))
    text += "\n" + str(backlog.get("body_excerpt") or record.get("body_excerpt") or "")
    urls.extend(re.findall(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*", text))
    if project_home is not None:
        project = record.get("repo") or record.get("project") or backlog.get("repo")
        repository = repository_identity(project_home, project) if isinstance(project, str) else None
        if repository:
            references = str(record.get("title") or backlog.get("title") or "")
            urls.extend(f"https://github.com/{repository}/issues/{number}"
                        for number in re.findall(r"(?<![A-Za-z0-9])#([1-9][0-9]*)", references))
    return sorted(set(urls))


def pr_urls(record: dict) -> list[str]:
    backlog = record.get("backlog") or {}
    values = [backlog.get("pr_url"), record.get("pr_url"), (record.get("pr") or {}).get("url")]
    urls = []
    for value in values:
        if isinstance(value, str) and re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*", value):
            urls.append(value)
    return sorted(set(urls))


def task_records(value: dict) -> list[dict]:
    records = []
    for task in value.get("tasks", []):
        if isinstance(task, dict):
            records.append(task)
    for row in (value.get("backlog") or {}).get("records", []):
        if isinstance(row, dict) and row.get("state") in ("queued", "in_flight", "done"):
            records.append(row)
    for home_record in (value.get("secondmate_current") or {}).get("records", []):
        if not isinstance(home_record, dict):
            continue
        for task in home_record.get("issue_tasks", []):
            if isinstance(task, dict):
                item = dict(task)
                item["id"] = f"{home_record.get('id', 'secondmate')}/{task.get('id', '')}"
                item["owner_home_id"] = home_record.get("id")
                records.append(item)
        for task in home_record.get("active_children", []):
            if isinstance(task, dict):
                item = dict(task)
                item["id"] = f"{home_record.get('id', 'secondmate')}/{task.get('id', '')}"
                item["owner_task_id"] = task.get("id")
                item["owner_home_id"] = home_record.get("id")
                item["owner_home_path"] = home_record.get("home")
                item["owner_remote"] = home_record.get("remote") is True
                item["state"] = task.get("state") or "unknown"
                item["repo"] = task.get("repo") or item.get("project")
                records.append(item)
        for row in home_record.get("queued", []):
            if isinstance(row, dict):
                item = dict(row)
                item["id"] = f"{home_record.get('id', 'secondmate')}/{row.get('id', '')}"
                item["owner_task_id"] = row.get("id")
                item["owner_home_id"] = home_record.get("id")
                item["owner_home_path"] = home_record.get("home")
                item["owner_remote"] = home_record.get("remote") is True
                records.append(item)
    unique: dict[str, dict] = {}
    for record in records:
        task_id = record.get("id")
        if isinstance(task_id, str) and task_id:
            prior = unique.get(task_id)
            if prior is None:
                unique[task_id] = dict(record)
                continue
            prior_backlog = prior.get("backlog") if isinstance(prior.get("backlog"), dict) else {}
            incoming_backlog = record.get("backlog") if isinstance(record.get("backlog"), dict) else record
            prior["backlog"] = {**incoming_backlog, **prior_backlog}
            for field in ("current_state", "pr", "project", "kind", "hints", "generation", "spawn_gen"):
                if field not in prior and field in record:
                    prior[field] = record[field]
    return list(unique.values())


def github_json(root: Path, path: str, home: Path) -> object:
    env = {**os.environ, "FM_HOME": str(home)}
    result = run(["gh", "api", path], cwd=root, env=env, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr[-500:] or "GitHub read failed")
    data = json.loads(result.stdout)
    return data


def github_graphql(root: Path, home: Path, owner: str, repo: str, number: int) -> dict:
    env = {**os.environ, "FM_HOME": str(home)}
    result = run(["gh", "api", "graphql", "-f", f"query={PR_QUERY}", "-F", f"owner={owner}", "-F", f"repo={repo}", "-F", f"number={number}"], cwd=root, env=env, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr[-500:] or "GitHub pull request read failed")
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or value.get("errors"):
        raise RuntimeError("GitHub returned an invalid pull request response")
    return value


def fetch_issue(root: Path, home: Path, url: str) -> dict:
    parts = url.removeprefix("https://github.com/").split("/")
    owner, repo, _, number = parts
    issue = github_json(root, f"repos/{owner}/{repo}/issues/{number}", home)
    if not isinstance(issue, dict):
        raise RuntimeError("GitHub returned an unexpected issue")
    if issue.get("number") != int(number) or str(issue.get("html_url", "")).lower() != url.lower():
        raise RuntimeError("GitHub returned a different issue identity")
    return issue


def fetch_issues(root: Path, home: Path, urls: list[str]) -> dict[str, dict]:
    if not urls:
        return {}
    if len(urls) > 8:
        found = {}
        for offset in range(0, len(urls), 8):
            found.update(fetch_issues(root, home, urls[offset:offset + 8]))
        return found
    aliases = {}
    selections = []
    for index, url in enumerate(urls):
        owner, repo, _, number = url.removeprefix("https://github.com/").split("/")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", owner) or not re.fullmatch(r"[A-Za-z0-9_.-]+", repo):
            continue
        alias = f"issue{index}"
        aliases[alias] = (url, int(number))
        selections.append(f'{alias}:repository(owner:"{owner}",name:"{repo}"){{issue(number:{number}){{number url title milestone{{title}}}}}}')
    if not selections:
        return {}
    query = "query { " + " ".join(selections) + " }"
    env = {**os.environ, "FM_HOME": str(home)}
    result = run(["gh", "api", "graphql", "-f", f"query={query}"], cwd=root, env=env, timeout=30)
    try:
        response = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        response = None
    data = response.get("data") if isinstance(response, dict) else None
    if not isinstance(data, dict):
        data = {}
    if result.returncode and not data and len(urls) > 1:
        midpoint = len(urls) // 2
        found = fetch_issues(root, home, urls[:midpoint])
        found.update(fetch_issues(root, home, urls[midpoint:]))
        return found
    found = {}
    for alias, (url, number) in aliases.items():
        repository = data.get(alias) if isinstance(data, dict) else None
        issue = repository.get("issue") if isinstance(repository, dict) else None
        if (isinstance(issue, dict) and issue.get("number") == number
                and str(issue.get("url", "")).lower() == url.lower()):
            found[url] = issue
        else:
            try:
                found[url] = fetch_issue(root, home, url)
            except (RuntimeError, ValueError, subprocess.SubprocessError):
                found[url] = {"html_url": url, "title": "Issue details unavailable", "milestone": None}
    return found


def repo_concurrency_limit(home: Path) -> int | str | None:
    config = home / "config"
    path = config / "repo-concurrency"
    if config.is_symlink() or path.is_symlink():
        return None
    try:
        if not config.exists():
            return "unlimited"
        if not config.is_dir():
            return None
        if not path.exists():
            return "unlimited"
        if not path.is_file() or path.stat().st_nlink != 1:
            return None
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not re.fullmatch(r"[1-9][0-9]*\n", raw):
        return None
    limit = int(raw[:-1])
    return limit if limit <= 256 else None


def repo_concurrency_lease_count(home: Path) -> int | None:
    state = home / "state"
    root = state / ".repo-concurrency"
    directory = root / "leases"
    if state.is_symlink() or root.is_symlink() or directory.is_symlink():
        return None
    try:
        if not directory.exists():
            return 0
        if not directory.is_dir():
            return None
        files = list(directory.glob("*.lease"))
    except OSError:
        return None
    count = 0
    for path in files:
        if path.is_symlink():
            return None
        try:
            fields = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return None
        parsed = {}
        for field in fields:
            if "=" not in field:
                return None
            key, value = field.split("=", 1)
            if key in parsed:
                return None
            parsed[key] = value
        if (set(parsed) - {"schema", "authority_id", "repo_identity", "task_home", "task_id", "claim_pid", "claim_identity"}
                or ("claim_pid" in parsed) != ("claim_identity" in parsed)
                or parsed.get("schema") != "fm-repo-concurrency-lease.v1"
                or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", parsed.get("authority_id", ""))
                or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", parsed.get("repo_identity", ""))
                or not parsed.get("task_home", "").startswith("/")
                or not ID_RE.fullmatch(parsed.get("task_id", ""))):
            return None
        count += 1
    return count


def fetch_pr(root: Path, home: Path, url: str) -> dict:
    parts = url.removeprefix("https://github.com/").split("/")
    owner, repo, _, number = parts
    response = github_graphql(root, home, owner, repo, int(number))
    pr = (((response.get("data") or {}).get("repository") or {}).get("pullRequest"))
    if not isinstance(pr, dict):
        raise RuntimeError("GitHub returned an unexpected pull request")
    if pr.get("number") != int(number) or str(pr.get("url", "")).lower() != url.lower():
        raise RuntimeError("GitHub returned a different pull request identity")
    rollup = ((pr.get("commits") or {}).get("nodes") or [{}])
    commit = (rollup[0].get("commit") or {}) if rollup and isinstance(rollup[0], dict) else {}
    status = commit.get("statusCheckRollup") or {}
    contexts = ((status.get("contexts") or {}).get("nodes") or [])
    review = pr.get("reviewDecision")
    if review == "APPROVED":
        review_label = "approved"
    elif review == "CHANGES_REQUESTED":
        review_label = "changes requested"
    elif review == "REVIEW_REQUIRED":
        review_label = "review pending"
    else:
        review_label = "review unavailable"
    states = []
    for item in contexts:
        if not isinstance(item, dict):
            continue
        if item.get("__typename") == "CheckRun":
            if item.get("status") != "COMPLETED":
                states.append("pending")
            else:
                states.append(str(item.get("conclusion") or "pending").lower())
        elif item.get("__typename") == "StatusContext":
            states.append(str(item.get("state") or "pending").lower())
    context_page = ((status.get("contexts") or {}).get("pageInfo") or {})
    if context_page.get("hasNextPage"):
        checks_label = "truncated"
    elif any(state in ("failure", "failed", "error", "timed_out", "action_required", "cancelled") for state in states):
        checks_label = "failed"
    elif any(state in ("pending", "queued", "in_progress", "expected") for state in states):
        checks_label = "running"
    elif states and all(state in ("success", "neutral", "skipped") for state in states):
        checks_label = "passed"
    elif not states and status:
        checks_label = "none reported"
    else:
        checks_label = "unknown"
    return {"number": pr["number"], "html_url": pr["url"], "state": str(pr.get("state", "unknown")).lower(),
            "draft": pr.get("isDraft"), "merged": pr.get("merged") is True or bool(pr.get("mergedAt")),
            "merged_at": pr.get("mergedAt"), "review_decision": review_label, "checks": checks_label}


def stage(record: dict, prs: list[dict]) -> str:
    open_prs = [pr for pr in prs if not (pr.get("merged") is True or pr.get("merged_at") or str(pr.get("state", "")).lower() == "closed")]
    if prs and not open_prs:
        return "merged" if all(pr.get("merged") is True or pr.get("merged_at") for pr in prs) else "closed unmerged"
    backlog = record.get("backlog") or record
    state = backlog.get("state")
    if state == "queued":
        return "queued"
    if not open_prs:
        return "in lane"
    if any(pr.get("draft") is True for pr in open_prs):
        return "draft PR"
    if all(pr.get("review_decision") == "approved" and pr.get("checks") == "passed" for pr in open_prs):
        return "ready"
    return "in review"


def secondmate_disclosures(value: dict) -> list[str]:
    section = value.get("secondmate_current") or {}
    warnings = []
    if section.get("truncated"):
        warnings.append(f"{section.get('truncated')} secondmate inventory record(s) were omitted")
    for record in section.get("records", []):
        if not isinstance(record, dict):
            warnings.append("secondmate inventory contains an invalid record")
            continue
        name = record.get("id") or "secondmate"
        current = record.get("current") or {}
        reason = current.get("reason")
        if current.get("state") == "unknown" or reason or record.get("registered") is False:
            warnings.append(f"{name}: {reason or 'secondmate inventory is unavailable or unregistered'}")
        freshness = record.get("freshness") or {}
        if freshness.get("status") == "cached":
            warnings.append(f"{name}: showing cached secondmate data ({freshness.get('age_seconds', 'unknown')} seconds old)")
        omitted = record.get("omitted") or []
        for item in omitted:
            if isinstance(item, dict) and item.get("count"):
                warnings.append(f"{name}: {item.get('count')} {item.get('surface', 'inventory')} record(s) omitted")
    main = value.get("main_inventory") or {}
    if main.get("valid") is False:
        warnings.append(f"Main task inventory is incomplete: {main.get('reason') or 'current inventory could not be verified'}")
    return sorted(set(warnings))


def status_data(home: Path, root: Path, value: dict) -> dict:
    records = task_records(value)
    projects = registered_projects(home)
    repositories = {project: repository_identity(home, project) for project in projects}
    rows: dict[tuple, dict] = {}
    failures = []
    warnings = secondmate_disclosures(value)
    for project, repo in repositories.items():
        if repo is None:
            failures.append(f"{project}: registered GitHub project origin is unavailable or invalid")
    issue_cache: dict[str, dict] = {}
    pr_cache: dict[str, dict] = {}

    def add_unlinked(record: dict, project: str) -> None:
        owner = record.get("owner_home_id") or "main"
        task_id = record.get("owner_task_id") or record.get("id")
        state = (record.get("current_state") or {}).get("state") or record.get("state") or "unknown"
        backlog = record.get("backlog") or record
        if backlog.get("state") != "in_flight" and state not in ("working", "parked", "paused", "blocked"):
            return
        key = (project, "unlinked", owner, task_id)
        rows[key] = {"project": project, "number": None, "title": "No issue link recorded", "url": None,
                     "issue_state": "unknown", "issue_missing": True,
                     "tasks": [{"id": task_id, "owner": owner, "state": state, "stage": stage(record, [])}], "prs": []}

    for record in records:
        backlog = record.get("backlog") or record
        project = backlog.get("repo") or record.get("repo") or record.get("project")
        if project not in projects:
            continue
        linked = []
        for url in issue_urls(record):
            if repositories.get(project) is None or url_repository(url) != repositories[project]:
                failures.append(f"{url}: issue repository does not match registered project {project}")
                continue
            linked.append(url)
        if not linked:
            add_unlinked(record, project)
            continue
        for url in linked:
            try:
                if url not in issue_cache:
                    issue_cache[url] = fetch_issue(root, home, url)
                issue = issue_cache[url]
            except (RuntimeError, ValueError, subprocess.SubprocessError) as exc:
                failures.append(f"{url}: {exc}")
                issue = {"number": int(url.rsplit("/", 1)[1]), "title": "", "html_url": url, "state": "unknown"}
            prs = []
            for pr_url in pr_urls(record):
                if url_repository(pr_url) != repositories.get(project):
                    failures.append(f"{pr_url}: pull request repository does not match registered project {project}")
                    continue
                try:
                    if pr_url not in pr_cache:
                        pr_cache[pr_url] = fetch_pr(root, home, pr_url)
                    prs.append(pr_cache[pr_url])
                except (RuntimeError, ValueError, subprocess.SubprocessError) as exc:
                    failures.append(f"{pr_url}: {exc}")
                    prs.append({"html_url": pr_url, "state": "unknown", "draft": None})
            key = (project, url)
            row = rows.setdefault(key, {"project": project, "number": issue.get("number"), "title": issue.get("title"),
                                        "url": url, "issue_state": issue.get("state", "unknown"),
                                        "issue_missing": False, "tasks": [], "prs": []})
            row["tasks"].append({"id": record.get("owner_task_id") or record.get("id"),
                                  "owner": record.get("owner_home_id") or "main",
                                  "state": (record.get("current_state") or {}).get("state") or record.get("state") or "unknown",
                                  "stage": stage(record, prs)})
            for pr in prs:
                summary = {"url": pr.get("html_url"), "state": pr.get("state", "unknown"), "draft": pr.get("draft"),
                           "merged": pr.get("merged") is True or bool(pr.get("merged_at")),
                           "review": pr.get("review_decision") or "unknown", "checks": pr.get("checks") or "unknown"}
                if summary not in row["prs"]:
                    row["prs"].append(summary)
    result = {"generated_epoch": snapshot_epoch(value), "projects": projects,
              "rows": list(rows.values()), "failures": failures, "warnings": warnings,
              "stale": False, "unavailable": False}
    result["rows"].sort(key=lambda row: (row["project"], row["number"] or 0, row["title"] or ""))
    return result


def decisions(home: Path, root: Path, value: dict) -> list[dict]:
    env = {**os.environ, "FM_HOME": str(home)}
    script = '. "$1/fm-classify-lib.sh"; scan_open_decisions "${FM_STATE_OVERRIDE:-${FM_HOME}/state}"'
    result = run(["/bin/bash", "-c", script, "fm-console-decisions", str(root / "bin")], cwd=root, env=env)
    if result.returncode:
        raise RuntimeError(result.stderr[-500:] or "open decision scan failed")
    out = []
    seen = set()
    for line in result.stdout.splitlines():
        parts = line.split("\t", 3)
        if len(parts) != 4:
            continue
        task, key, verb, note = parts
        if ID_RE.fullmatch(task) and key and verb in ("needs-decision", "blocked"):
            decision = parse_decision(note)
            out.append({"owner": "main", "task": task, "key": key, "verb": verb, "note": note,
                        "decision": decision, "answerable": decision is not None})
            seen.add(("main", task, key))
    main_tasks = [item for item in value.get("tasks", []) if isinstance(item, dict)]
    targets_by_key = {}
    for task in main_tasks:
        endpoint = task.get("endpoint") or {}
        if endpoint.get("exists") is not True:
            continue
        for key in task.get("decision_keys", []):
            targets_by_key.setdefault(key, task.get("id"))
    for row in (value.get("backlog") or {}).get("records", []):
        if not isinstance(row, dict) or row.get("captain_actionable") is not True:
            continue
        key = row.get("id")
        target = row.get("target_task_id") or targets_by_key.get(key) or (key if any(task.get("id") == key for task in main_tasks) else None)
        target_task = next((task for task in main_tasks if task.get("id") == target), None)
        target_live = isinstance(target_task, dict) and (target_task.get("endpoint") or {}).get("exists") is True
        worker = target if target_live else None
        identity = ("main", worker, key)
        if isinstance(key, str) and ID_RE.fullmatch(key) and identity not in seen:
            decision = decision_from_body(row.get("body_lines"))
            out.append({"owner": "main", "task": worker, "key": key, "verb": "captain-hold",
                        "note": row.get("hold_reason") or row.get("title") or "Captain-held task",
                        "decision": decision, "answerable": decision is not None,
                        "direct_hold": worker is None})
            seen.add(identity)
    for home_record in ((value.get("secondmate_current") or {}).get("records") or []):
        if not isinstance(home_record, dict):
            continue
        owner = home_record.get("id")
        remote = home_record.get("remote") is True
        for item in home_record.get("decisions_open", []):
            if not isinstance(item, dict) or item.get("verb") not in ("needs-decision", "blocked", "captain-hold"):
                continue
            key = item.get("key")
            task = item.get("target_task_id") or (item.get("id") if item.get("verb") != "captain-hold" else None)
            direct_hold = False
            if item.get("verb") == "captain-hold":
                children = [child for child in home_record.get("active_children", []) if isinstance(child, dict)]
                if not task and isinstance(key, str):
                    task = next((child.get("id") for child in children if key in (child.get("decision_keys") or [])), None)
                if not any(child.get("id") == task for child in children):
                    task = None
                    direct_hold = True
            identity = (owner, task, key)
            if not isinstance(owner, str) or not ID_RE.fullmatch(owner) or not isinstance(key, str) or not key:
                continue
            if identity not in seen:
                queued_row = next((row for row in home_record.get("queued", [])
                                   if isinstance(row, dict) and row.get("id") == (item.get("id") or task)), {})
                decision = parse_decision(item.get("decision")) or parse_decision(item.get("summary") or item.get("reason")) or decision_from_body(queued_row.get("body_lines"))
                out.append({"owner": owner, "remote": remote, "task": task, "key": key,
                            "verb": item["verb"], "note": item.get("summary") or item.get("reason") or "Open decision",
                            "decision": decision,
                            "answerable": decision is not None and (direct_hold or isinstance(task, str) and ID_RE.fullmatch(task) is not None),
                            "direct_hold": direct_hold})
                seen.add(identity)
    for item in out:
        item["card_id"] = decision_card_id(item)
    return sorted(out, key=lambda item: (item.get("owner") or "", item.get("task") or "", item.get("key") or ""))


def parse_decision(raw: object) -> dict | None:
    if isinstance(raw, str):
        try:
            value = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return None
    else:
        value = raw
    if not isinstance(value, dict) or value.get("schema") != "fm-captain-decision.v1":
        return None
    options = value.get("options")
    if (not isinstance(value.get("question"), str) or not value["question"].strip()
            or not isinstance(value.get("context"), str) or not value["context"].strip()
            or not isinstance(value.get("user_impact"), str) or not value["user_impact"].strip()
            or not isinstance(options, list) or not 2 <= len(options) <= 8
            or not isinstance(value.get("recommendation"), str) or not value["recommendation"].strip()
            or value.get("recommended_option") not in [chr(ord("A") + index) for index in range(len(options))]):
        return None
    for index, option in enumerate(options):
        if (not isinstance(option, dict) or option.get("label") != chr(ord("A") + index)
                or not isinstance(option.get("title"), str) or not option["title"].strip()
                or not isinstance(option.get("pros"), list) or not option["pros"]
                or not all(isinstance(value, str) and value.strip() for value in option["pros"])
                or not isinstance(option.get("cons"), list) or not option["cons"]
                or not all(isinstance(value, str) and value.strip() for value in option["cons"])):
            return None
    return value


def decision_from_body(lines: object) -> dict | None:
    if not isinstance(lines, list):
        return None
    prefix = "Captain decision record v1: "
    for line in lines:
        if isinstance(line, str) and line.startswith(prefix):
            return parse_decision(line[len(prefix):])
    return None


def decision_card_id(item: dict) -> str:
    safe = lambda value: re.sub(r"[^A-Za-z0-9_-]", "_", str(value or ""))
    return "decision-" + "-".join(safe(item.get(field)) for field in ("owner", "task", "key"))


def queue_data(snap: dict, home: Path, root: Path) -> list[dict]:
    out = []
    dependency_states = {}
    for row in (snap.get("backlog") or {}).get("records", []):
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            dependency_states[row["id"]] = row.get("state") or "unknown"
    for task in snap.get("tasks", []):
        if isinstance(task, dict) and isinstance(task.get("id"), str):
            state = (task.get("current_state") or {}).get("state")
            if state in (None, "unknown", "unavailable"):
                backlog = task.get("backlog") if isinstance(task.get("backlog"), dict) else {}
                state = backlog.get("state") or task.get("state") or state
            dependency_states[task["id"]] = state or "unknown"
    for row in (snap.get("backlog") or {}).get("records", []):
        if isinstance(row, dict) and row.get("state") in ("queued", "in_flight"):
            item = {key: row.get(key) for key in ("id", "title", "state", "repo", "blocked_by_ids", "unresolved_blocker_ids", "blocked_reason", "captain_actionable", "hold_until", "hold_kind", "links", "body_lines")}
            item["owner"] = "main"
            out.append(item)
    for home_record in ((snap.get("secondmate_current") or {}).get("records") or []):
        if not isinstance(home_record, dict):
            continue
        owner = home_record.get("id") or "secondmate"
        for child in home_record.get("active_children", []):
            if isinstance(child, dict):
                out.append({"id": f"{owner}/{child.get('id', '')}", "title": child.get("name") or child.get("id"),
                            "state": child.get("state") or "working", "repo": child.get("repo"), "blocked_by_ids": [],
                            "unresolved_blocker_ids": [], "blocked_reason": None, "captain_actionable": False,
                            "hold_until": None, "hold_kind": None, "links": [child.get("issue")] if child.get("issue") else [],
                            "body_lines": child.get("body_lines") or [], "owner": owner})
        for row in home_record.get("queued", []):
            if isinstance(row, dict):
                out.append({"id": f"{owner}/{row.get('id', '')}", "title": row.get("title"), "state": "queued",
                            "repo": row.get("repo"), "blocked_by_ids": row.get("blocked_by_ids") or [],
                            "unresolved_blocker_ids": row.get("unresolved_blocker_ids") or [],
                            "blocked_reason": row.get("blocked_reason") or row.get("hold_reason"),
                            "captain_actionable": row.get("captain_actionable") is True,
                            "hold_until": row.get("hold_until"), "hold_kind": row.get("hold_kind"),
                            "links": row.get("issue_urls") or row.get("links") or [], "body_lines": row.get("body_lines") or [],
                            "dependency_states": row.get("dependencies") or [], "owner": owner,
                            "owner_home_path": home_record.get("home"), "owner_remote": home_record.get("remote") is True})
    decisions_by_key = {(item.get("owner"), item.get("key")): item for item in decisions(home, root, snap)}
    today = datetime.date.today().isoformat()
    local_homes = {record.get("id"): record for record in ((snap.get("secondmate_current") or {}).get("records") or [])
                   if isinstance(record, dict) and isinstance(record.get("id"), str)}
    def item_project_home(item: dict) -> Path | None:
        owner = item.get("owner")
        if not item.get("owner_home_path"):
            return home
        record = local_homes.get(owner)
        if not record or record.get("remote") is True:
            return None
        try:
            return validated_local_secondmate_home(record, owner)
        except (ValueError, OSError):
            return None
    issue_urls_all = sorted({url for item in out for url in issue_urls(item, item_project_home(item))})
    try:
        issue_cache = fetch_issues(root, home, issue_urls_all)
    except (RuntimeError, ValueError, subprocess.SubprocessError):
        issue_cache = {}
    for item in out:
        blockers = item.get("unresolved_blocker_ids") or []
        known_dependencies = {entry.get("id"): entry.get("state") for entry in item.get("dependency_states", [])
                              if isinstance(entry, dict) and isinstance(entry.get("id"), str)}
        if item.get("state") != "queued":
            item["start_reason"] = "Already in progress"
        elif blockers:
            item["start_reason"] = "Waiting for dependencies: " + "; ".join(
                f"{dependency} ({known_dependencies.get(dependency, dependency_states.get(dependency, 'not found'))})"
                for dependency in blockers)
        elif item.get("hold_kind") == "captain":
            decision = decisions_by_key.get((item.get("owner"), item.get("id").split("/", 1)[-1]))
            item["decision_card_id"] = decision.get("card_id") if decision else None
            label = decision.get("decision", {}).get("question") if decision and decision.get("decision") else item.get("title")
            item["start_reason"] = "Waiting for a captain decision: " + str(label or "Open decision")
        elif isinstance(item.get("hold_until"), str) and item["hold_until"] > today:
            item["start_reason"] = "Deferred until " + item["hold_until"]
        elif item.get("owner_remote") is True:
            item["start_reason"] = "Cannot confirm repository lane availability"
        else:
            if item.get("owner_home_path"):
                try:
                    record = next(entry for entry in ((snap.get("secondmate_current") or {}).get("records") or [])
                                  if isinstance(entry, dict) and entry.get("id") == item.get("owner"))
                    item_home = validated_local_secondmate_home(record, item["owner"])
                except (StopIteration, ValueError, OSError):
                    item_home = None
            else:
                item_home = home
            limit = repo_concurrency_limit(item_home) if item_home else None
            lease_count = repo_concurrency_lease_count(item_home) if item_home else None
            if limit is None or (isinstance(limit, int) and lease_count is None):
                item["start_reason"] = "Cannot confirm repository lane availability"
            elif isinstance(limit, int) and lease_count is not None and lease_count >= limit:
                item["start_reason"] = f"Waiting for a free lane (limit {limit}; {lease_count} in use)"
            elif item.get("blocked_reason"):
                item["start_reason"] = str(item["blocked_reason"])
            else:
                item["start_reason"] = "Ready to start now"
        item["issue_urls"] = issue_urls(item, item_project_home(item))
        item["issue_missing"] = not item["issue_urls"]
        item["issues"] = []
        for url in item["issue_urls"]:
            try:
                issue = issue_cache.get(url)
                if issue is None:
                    raise RuntimeError("GitHub issue details are unavailable")
                milestone = issue.get("milestone")
                item["issues"].append({"html_url": url, "title": issue.get("title"),
                                       "milestone": {"title": milestone.get("title")} if isinstance(milestone, dict) else None})
            except (RuntimeError, ValueError, subprocess.SubprocessError) as exc:
                item["issues"].append({"html_url": url, "title": "Issue details unavailable", "milestone": None,
                                       "error": str(exc)})
        item.pop("body_lines", None)
        item.pop("owner_home_path", None)
        item.pop("owner_remote", None)
    out.sort(key=lambda row: (0 if row["start_reason"] == "Ready to start now" else 1,
                              row.get("state") != "queued", row.get("repo") or "", row.get("id") or ""))
    return out


def page(token: str, port: int) -> bytes:
    token_json = json.dumps(token)
    html_page = r"""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Firstmate Console</title>
<style>
:root{font:16px system-ui,sans-serif;color-scheme:light dark}body{max-width:1200px;margin:2rem auto;padding:0 1rem}header{display:flex;align-items:center;gap:1rem;flex-wrap:wrap}h1{margin-right:auto}nav{display:flex;gap:.5rem;border-bottom:1px solid #888;padding:.5rem 0}button{font:inherit;padding:.55rem .8rem;border:1px solid #888;border-radius:.35rem;background:Canvas;color:CanvasText;cursor:pointer}button[aria-selected=true]{border-bottom:3px solid #3978db}.muted{color:GrayText}.error{color:#b42318}.tab{padding-top:1rem}table{border-collapse:collapse;width:100%;margin-top:1rem}th,td{text-align:left;vertical-align:top;padding:.65rem;border-bottom:1px solid #8885}a{color:LinkText}textarea{display:block;width:min(48rem,100%);min-height:5rem;margin:.5rem 0;font:inherit}#status{white-space:pre-wrap}label{display:block;margin:.4rem 0}.decision-card{border:1px solid #8885;border-radius:.65rem;padding:1.2rem;margin:1rem 0;box-shadow:0 1px 3px #0002}.decision-card h2{margin:.1rem 0 .65rem}.decision-context{max-width:75ch;line-height:1.55}.decision-option{border-top:1px solid #8885;padding:.65rem 0}.decision-option h3{margin:.1rem 0 .4rem}.decision-option ul{margin:.35rem 0}.recommendation{border-left:4px solid #39825a;background:color-mix(in srgb,Canvas 92%,#39825a);padding:.8rem 1rem;margin:.8rem 0}.rewrite{color:#8a4b00;font-weight:650}.issue-link{display:block;margin:.2rem 0}
</style><header><h1>Firstmate Console</h1><button id="refresh">Refresh</button></header><p id="status" class="muted" role="status">Loading…</p><nav role="tablist" aria-label="Console sections"><button role="tab" aria-selected="true" aria-controls="status-tab" id="status-button">Status</button><button role="tab" aria-selected="false" aria-controls="decisions-tab" id="decisions-button">Open decisions</button><button role="tab" aria-selected="false" aria-controls="queue-tab" id="queue-button">Queue</button></nav>
<section class="tab" role="tabpanel" id="status-tab" aria-labelledby="status-button"><label>Project <select id="project"></select></label><div id="status-content"></div></section>
<section class="tab" role="tabpanel" id="decisions-tab" aria-labelledby="decisions-button" hidden><div id="decisions-content"></div></section>
<section class="tab" role="tabpanel" id="queue-tab" aria-labelledby="queue-button" hidden><div id="queue-content"></div></section>
<script>
const token=__TOKEN__,tabs=[...document.querySelectorAll('[role=tab]')],status=document.getElementById('status');
const el=id=>document.getElementById(id),node=value=>document.createTextNode(value==null?'':String(value));
function activate(tab){for(const item of tabs){const on=item===tab;item.setAttribute('aria-selected',on);el(item.getAttribute('aria-controls')).hidden=!on}}
tabs.forEach((tab,index)=>{tab.onclick=()=>activate(tab);tab.onkeydown=event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;tabs[next].focus();activate(tabs[next])}});
function link(url,label){const a=document.createElement('a');a.href=url;a.target='_blank';a.textContent=label;a.rel='noopener noreferrer';return a}
function prCell(prs){const root=document.createElement('div');for(const pr of prs||[]){const state=pr.merged?'merged':pr.state==='closed'?'closed unmerged':pr.draft?'draft PR':pr.state;root.append(link(pr.url,`PR · ${state}`),node(` · review ${pr.review}; checks ${pr.checks}`),document.createElement('br'))}if(!prs?.length)root.textContent='No linked PR';return root}
function table(parent,headers,rows){const t=document.createElement('table'),head=document.createElement('thead'),hr=document.createElement('tr');headers.forEach(h=>{const th=document.createElement('th');th.textContent=h;hr.append(th)});head.append(hr);const body=document.createElement('tbody');rows.forEach(row=>{const tr=document.createElement('tr');row.forEach(value=>{const td=document.createElement('td');if(value instanceof Node)td.append(value);else td.append(node(value));tr.append(td)});body.append(tr)});t.append(head,body);parent.replaceChildren(t)}
const drafts=new Map();let latestData=null;
function renderDecision(item){const card=document.createElement('article');card.className='decision-card';card.id=item.card_id;const title=document.createElement('h2');title.textContent=item.decision?.question||'Decision needs rewrite';card.append(title);if(!item.decision){const rewrite=document.createElement('p');rewrite.className='rewrite';rewrite.textContent='Needs rewrite: add a plain-language context, user impact, lettered options with pros and cons, and a recommendation before this can be answered.';card.append(rewrite);return card}const context=document.createElement('p');context.className='decision-context';context.textContent=`${item.decision.context} User impact: ${item.decision.user_impact}`;card.append(context);const options=document.createElement('div');for(const option of item.decision.options){const section=document.createElement('section');section.className='decision-option';const heading=document.createElement('h3');heading.textContent=`${option.label}. ${option.title}`;section.append(heading);for(const [label,values] of [['Pros',option.pros],['Cons',option.cons]]){const strong=document.createElement('strong');strong.textContent=label;const list=document.createElement('ul');values.forEach(value=>{const li=document.createElement('li');li.textContent=value;list.append(li)});section.append(strong,list)}options.append(section)}card.append(options);const recommendation=document.createElement('p');recommendation.className='recommendation';recommendation.textContent=`Recommended: ${item.decision.recommended_option}. ${item.decision.recommendation}`;card.append(recommendation);if(!item.answerable){const notice=document.createElement('p');notice.textContent='Answer unavailable: owning task could not be resolved.';card.append(notice);return card}const identity=JSON.stringify([item.owner,item.task,item.key]),form=document.createElement('form'),label=document.createElement('label'),area=document.createElement('textarea'),send=document.createElement('button');label.textContent='Reply with an option letter or your own answer';area.name='answer';area.maxLength=8192;area.required=true;area.setAttribute('aria-label',`Answer ${item.decision.question}`);area.placeholder=`For example: ${item.decision.recommended_option} or describe another choice`;area.value=drafts.get(identity)||'';area.oninput=()=>drafts.set(identity,area.value);send.textContent='Answer and send';form.append(label,area,send);form.onsubmit=async event=>{event.preventDefault();send.disabled=true;try{const result=await fetch('/api/answer',{method:'POST',headers:{'Content-Type':'application/json','X-FM-Token':token},body:JSON.stringify({owner:item.owner,task:item.task,key:item.key,answer:area.value})}).then(x=>x.json());if(!result.ok)throw Error(result.error||'answer was not delivered');drafts.delete(identity);await load(true)}catch(error){status.className='error';status.textContent='Answer failed: '+error.message;send.disabled=false}};card.append(form);return card}
function render(data){if(data.unavailable){status.className='error';status.textContent='Unavailable: '+data.error;return}const s=data.status||{},d=data.decisions||[],q=data.queue||[];const select=el('project'),prior=select.value;select.replaceChildren(...(s.projects||[]).map(name=>{const o=document.createElement('option');o.value=name;o.textContent=name;return o}));if((s.projects||[]).includes(prior))select.value=prior;const rows=(s.rows||[]).filter(row=>!select.value||row.project===select.value).map(row=>[row.project,row.issue_missing?row.title:link(row.url,`#${row.number} ${row.title||'(title unavailable)'}`),row.issue_state,row.tasks.map(task=>`${task.owner||'main'}/${task.id}: ${task.stage} (${task.state})`).join('\n'),prCell(row.prs)]);if(rows.length)table(el('status-content'),['Project','Issue','Issue state','Lane stage','PR status'],rows);else el('status-content').textContent=select.value?'No admitted issues or unlinked work are recorded for this project.':'No registered projects are available.';const notices=[...(s.failures||[]),...(data.warnings||[])];status.className=s.stale||notices.length?'error':'muted';status.textContent=`${s.stale?'Stale cached':'Updated'} ${new Date(data.generated_epoch*1000).toLocaleString()} · snapshot age ${data.age_seconds}s${data.error?' · '+data.error:''}${notices.length?'\n'+notices.join('\n'):''}`;el('decisions-content').replaceChildren(...d.map(renderDecision));if(!d.length)el('decisions-content').textContent='No open decisions.';const issueCell=item=>{const root=document.createElement('div');if(item.issue_missing){root.textContent='No linked GitHub issue';return root}for(const issue of item.issues||[]){const a=link(issue.html_url,issue.title||issue.html_url);a.className='issue-link';root.append(a);if(issue.milestone?.title)root.append(node(`Milestone: ${issue.milestone.title}`));else root.append(node(issue.title==='Issue details unavailable'?'Milestone unavailable':'No milestone'));root.append(document.createElement('br'))}return root};const reasonCell=item=>{const root=document.createElement('div');root.append(node(item.start_reason));if(item.decision_card_id){root.append(document.createElement('br'));const a=document.createElement('a');a.href=`#${item.decision_card_id}`;a.textContent='View decision';root.append(a)}return root};if(q.length)table(el('queue-content'),['Task','Project','GitHub issue','State','Why it has not started'],q.map(item=>[`${item.id||''} ${item.title||''}`,item.repo||'Home operations',issueCell(item),item.state,reasonCell(item)]));else el('queue-content').textContent='No queued or in-flight work.'}
async function load(force=false){try{const query=force?'?refresh=1':'';const response=await fetch('/api/data'+query),data=await response.json();if(!response.ok&&!data.status)throw Error(data.error||'console data unavailable');latestData=data;render(data)}catch(error){status.className='error';status.textContent='Unavailable: '+error.message}}
el('project').onchange=()=>{if(latestData)render(latestData)};el('refresh').onclick=()=>load(true);load();setInterval(()=>{if(!document.hidden)load()},30000);
</script></html>"""
    return html_page.replace("__TOKEN__", token_json).encode()


def compose_data(home: Path, root: Path, value: dict) -> dict:
    status = status_data(home, root, value)
    generated = snapshot_epoch(value)
    warnings = list(status.get("warnings") or [])
    return {"generated_epoch": generated, "age_seconds": max(0, int(time.time()) - generated),
            "status": status, "decisions": decisions(home, root, value), "queue": queue_data(value, home, root),
            "warnings": warnings, "stale": False, "unavailable": False}


def validated_local_secondmate_home(record: dict, owner: str) -> Path:
    raw = record.get("home")
    if not isinstance(raw, str) or not raw.startswith("/"):
        raise ValueError("secondmate home path is unavailable")
    path = Path(raw)
    marker = path / ".fm-secondmate-home"
    if path.is_symlink() or not path.is_dir() or marker.is_symlink() or not marker.is_file():
        raise ValueError("secondmate home is unavailable or unsafe")
    if marker.read_text(encoding="utf-8").strip() != owner:
        raise ValueError("secondmate home identity changed")
    return path.resolve(strict=True)


def serve(home: Path, root: Path, port: int | None) -> int:
    token = secrets.token_urlsafe(32)
    cached: dict | None = None
    cache_at = 0.0

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "FirstmateConsole/1"

        def log_message(self, fmt: str, *args: object) -> None:
            return

        def send(self, code: int, value: object) -> None:
            body = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def valid_host(self) -> bool:
            return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"

        def do_GET(self) -> None:
            nonlocal cached, cache_at
            if not self.valid_host():
                self.send(403, {"error": "invalid host"})
                return
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/":
                body = page(token, self.server.server_port)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/data":
                query = urllib.parse.parse_qs(parsed.query)
                if query.get("refresh") == ["1"] or cached is None or time.monotonic() - cache_at >= 20:
                    try:
                        snap = snapshot(home, root)
                        cached = compose_data(home, root, snap)
                        cache_at = time.monotonic()
                    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
                        if cached is None:
                            self.send(503, {"unavailable": True, "error": str(exc)})
                            return
                        cached = json.loads(json.dumps(cached))
                        cached["status"]["stale"] = True
                        cached["status"]["error"] = str(exc)
                        cached["warnings"] = sorted(set(cached.get("warnings", []) + [f"Refresh failed; showing cached data: {exc}"]))
                payload = json.loads(json.dumps(cached))
                payload["age_seconds"] = max(0, int(time.time()) - payload["generated_epoch"])
                self.send(200, payload)
                return
            self.send(404, {"error": "not found"})

        def do_POST(self) -> None:
            nonlocal cached, cache_at
            expected_origin = f"http://127.0.0.1:{self.server.server_port}"
            if (self.path != "/api/answer" or not self.valid_host() or self.headers.get("Origin") != expected_origin
                    or not secrets.compare_digest(self.headers.get("X-FM-Token", ""), token)):
                self.send(403, {"error": "request refused"})
                return
            try:
                staged_answer: Path | None = None
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > MAX_ANSWER + 1024:
                    raise ValueError("invalid request size")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict) or set(body) != {"owner", "task", "key", "answer"}:
                    raise ValueError("invalid answer request")
                owner, task, key, answer = body["owner"], body["task"], body["key"], body["answer"]
                if not isinstance(owner, str) or (owner != "main" and not ID_RE.fullmatch(owner)) or (task is not None and (not isinstance(task, str) or not ID_RE.fullmatch(task))) or not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", key):
                    raise ValueError("invalid decision identity")
                if not isinstance(answer, str) or not answer.strip() or len(answer.encode("utf-8")) > MAX_ANSWER or "\x00" in answer:
                    raise ValueError("answer must contain 1 to 8192 bytes")
                current = snapshot(home, root)
                match = next((item for item in decisions(home, root, current)
                              if item.get("owner") == owner and item.get("task") == task and item.get("key") == key), None)
                if not match or not match.get("answerable"):
                    raise ValueError("decision is no longer open")
                answer_input = None
                if match.get("direct_hold") is True:
                    if owner == "main":
                        answer_home = home
                        hold_script = str(root / "bin" / "fm-captain-hold.sh")
                    else:
                        record = next((item for item in ((current.get("secondmate_current") or {}).get("records") or [])
                                       if isinstance(item, dict) and item.get("id") == owner), None)
                        if not record:
                            raise ValueError("decision owner is no longer registered")
                        if record.get("remote") is True:
                            answer_home = home
                            if any(char in answer for char in "\t\r\n"):
                                raise ValueError("remote held-call answers must be a single line")
                            command = [str(root / "bin" / "fm-on.sh"), "--stdin", owner,
                                       "fm-captain-hold.sh", "answers", "--source", "local operator console"]
                            answer_input = f"{key}\t{answer}\tAnswered from the local console\n"
                        else:
                            answer_home = validated_local_secondmate_home(record, owner)
                            hold_script = str(root / "bin" / "fm-captain-hold.sh")
                    if answer_input is None:
                        state_dir = answer_home / "state"
                        if state_dir.is_symlink() or not state_dir.is_dir():
                            raise ValueError("owning home state directory is unavailable or unsafe")
                        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=state_dir,
                                                         prefix=".console-answer-", delete=False) as staged:
                            staged.write(answer)
                            staged_answer = Path(staged.name)
                        command = [hold_script, "answer", key, "--decision-file", str(staged_answer)]
                elif owner == "main":
                    command = [str(root / "bin" / "fm-send.sh"), task, "--resolve-key", key, "--", answer]
                    answer_home = home
                else:
                    record = next((item for item in ((current.get("secondmate_current") or {}).get("records") or [])
                                   if isinstance(item, dict) and item.get("id") == owner), None)
                    if not record:
                        raise ValueError("decision owner is no longer registered")
                    if record.get("remote") is True:
                        command = [str(root / "bin" / "fm-on.sh"), owner, "fm-send.sh", task, "--resolve-key", key, "--", answer]
                        answer_home = home
                    else:
                        answer_home = validated_local_secondmate_home(record, owner)
                        command = [str(root / "bin" / "fm-send.sh"), task, "--resolve-key", key, "--", answer]
                try:
                    result = run(command, cwd=root, env={**os.environ, "FM_HOME": str(answer_home), "FM_ROOT_OVERRIDE": str(root)},
                                 timeout=60, input_text=answer_input)
                finally:
                    if staged_answer is not None:
                        staged_answer.unlink(missing_ok=True)
                if result.returncode:
                    raise RuntimeError(result.stderr[-800:] or "fm-send could not deliver the answer")
                cached = None
                cache_at = 0.0
                self.send(200, {"ok": True, "result": result.stdout[-500:]})
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
                self.send(400, {"ok": False, "error": str(exc)})

    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", port or 0), Handler)
    except OSError as exc:
        print(f"fm-console: cannot bind loopback service: {exc}", file=sys.stderr)
        return 1
    server.daemon_threads = True
    url = f"http://127.0.0.1:{server.server_port}/"
    print(url, flush=True)
    webbrowser.open(url)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        server.shutdown()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="local deterministic Firstmate operator console")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--home", default=os.environ.get("FM_HOME"))
    parser.add_argument("--port", type=int)
    args = parser.parse_args(argv)
    root = Path(args.root).expanduser().resolve()
    home = Path(args.home).expanduser().resolve() if args.home else root
    return serve(home, root, args.port)


if __name__ == "__main__":
    raise SystemExit(main())
