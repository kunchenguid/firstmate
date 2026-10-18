#!/usr/bin/env bash
# fm-velocity.sh - collect velocity metrics and render a Grafana dashboard.
#
# Collects per-project pull requests from GitHub, commits and added and removed
# lines from local clones, and no-mistakes runs from the local state database.
# Writes a JSON store and renders a Grafana dashboard that imports cleanly.
# The dashboard carries a multi-select project variable and per-agent tables.
# It never writes into a project clone and never restarts Grafana.
#
# Usage:
#   bin/fm-velocity.sh [--projects-file FILE] [--projects-dir DIR] [--store FILE] [--dashboard FILE] [--since DATE] [--collect-only] [--render-only] [--help]
#
# Defaults resolve relative to the repository root.
# --since passes a date to git log (for example 2026-07-01).
# --collect-only writes the store without rendering the dashboard.
# --render-only renders the dashboard from an existing store.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PROJECTS_FILE="$ROOT/data/projects.md"
PROJECTS_DIR="$ROOT/projects"
STORE="$ROOT/data/velocity/velocity.json"
DASHBOARD="$ROOT/grafana/velocity-dashboard.json"
SINCE=""
COLLECT_ONLY=0
RENDER_ONLY=0

usage() {
  sed -n 's/^# //p; s/^#$//p' "$0" | head -n 30
}

while [ $# -gt 0 ]; do
  case "$1" in
    --projects-file) PROJECTS_FILE="$2"; shift 2 ;;
    --projects-dir) PROJECTS_DIR="$2"; shift 2 ;;
    --store) STORE="$2"; shift 2 ;;
    --dashboard) DASHBOARD="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --collect-only) COLLECT_ONLY=1; shift ;;
    --render-only) RENDER_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export FM_VELOCITY_PROJECTS_FILE="$PROJECTS_FILE"
export FM_VELOCITY_PROJECTS_DIR="$PROJECTS_DIR"
export FM_VELOCITY_STORE="$STORE"
export FM_VELOCITY_DASHBOARD="$DASHBOARD"
export FM_VELOCITY_SINCE="$SINCE"
export FM_VELOCITY_COLLECT_ONLY="$COLLECT_ONLY"
export FM_VELOCITY_RENDER_ONLY="$RENDER_ONLY"

python3 - "$@" <<'PY'
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone

projects_file = os.environ["FM_VELOCITY_PROJECTS_FILE"]
projects_dir = os.environ["FM_VELOCITY_PROJECTS_DIR"]
store_path = os.environ["FM_VELOCITY_STORE"]
dashboard_path = os.environ["FM_VELOCITY_DASHBOARD"]
since = os.environ["FM_VELOCITY_SINCE"]
collect_only = os.environ["FM_VELOCITY_COLLECT_ONLY"] == "1"
render_only = os.environ["FM_VELOCITY_RENDER_ONLY"] == "1"

def parse_projects(path):
    names = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^- (\S+)\s", line)
            if m:
                names.append(m.group(1))
    return names

def parse_github_repo(remote):
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", remote.strip())
    if not m:
        return None
    return (m.group(1), m.group(2))

def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return out
    except Exception as e:
        print(f"warning: {' '.join(cmd)} failed: {e}", file=sys.stderr)
        return None

def collect_prs(owner, repo):
    cmd = ["gh", "api", f"repos/{owner}/{repo}/pulls?state=all&per_page=100",
           "--paginate", "-q", ".[] | \"\\(.number) \\(.user.login) \\(.draft)\""]
    r = run(cmd)
    if r is None or r.returncode != 0:
        print(f"warning: PR fetch failed for {owner}/{repo}", file=sys.stderr)
        return {"total": 0, "by_author": {}}
    by_author = {}
    total = 0
    for line in (r.stdout or "").splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        user = parts[1] or "unknown"
        by_author[user] = by_author.get(user, 0) + 1
        total += 1
    return {"total": total, "by_author": by_author}

def collect_git(clone, since):
    cmd = ["git", "-C", clone, "log", "--all",
           "--pretty=format:COMMIT|%an|%ae", "--numstat"]
    if since:
        cmd += ["--since", since]
    r = run(cmd)
    if r is None or r.returncode != 0:
        print(f"warning: git log failed for {clone}", file=sys.stderr)
        return {"total": 0, "by_author": {}, "added": 0, "removed": 0,
                "added_by": {}, "removed_by": {}}
    total = 0
    by_author = {}
    added = 0
    removed = 0
    added_by = {}
    removed_by = {}
    author = "unknown"
    for line in (r.stdout or "").splitlines():
        if line.startswith("COMMIT|"):
            parts = line.split("|", 2)
            author = parts[1].strip() if len(parts) > 1 and parts[1].strip() else "unknown"
            total += 1
            by_author[author] = by_author.get(author, 0) + 1
        elif not line.strip():
            continue
        else:
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            a, d = cols[0].strip(), cols[1].strip()
            if a == "-" or d == "-":
                continue
            try:
                ai, di = int(a), int(d)
            except ValueError:
                continue
            added += ai
            removed += di
            added_by[author] = added_by.get(author, 0) + ai
            removed_by[author] = removed_by.get(author, 0) + di
    return {"total": total, "by_author": by_author, "added": added,
            "removed": removed, "added_by": added_by, "removed_by": removed_by}

def normalize_repo_url(url):
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", (url or "").strip(), re.IGNORECASE)
    if not m:
        return None
    return f"{m.group(1).lower()}/{m.group(2).lower()}"

def collect_runs(remote_by_project):
    db = os.path.expanduser("~/.no-mistakes/state.sqlite")
    if not os.path.exists(db):
        alt = "/home/lopezc/.no-mistakes/state.sqlite"
        db = alt if os.path.exists(alt) else db
    if not os.path.exists(db):
        print("warning: no-mistakes database not found", file=sys.stderr)
        return {}
    try:
        con = sqlite3.connect(db)
        rows = con.execute(
            "SELECT repos.upstream_url, count(*) FROM runs "
            "JOIN repos ON runs.repo_id = repos.id GROUP BY repos.upstream_url"
        ).fetchall()
        con.close()
    except Exception as e:
        print(f"warning: runs query failed: {e}", file=sys.stderr)
        return {}
    counts = {}
    for url, n in rows:
        norm = normalize_repo_url(url)
        if norm:
            counts[norm] = counts.get(norm, 0) + n
    out = {}
    for project, remote in remote_by_project.items():
        norm = normalize_repo_url(remote) if remote else None
        out[project] = counts.get(norm, 0) if norm else 0
    return out

def build_dashboard(store):
    projects = sorted(store["projects"].keys())
    proj_rows = ["project,prs,commits,added,removed,runs"]
    agent_rows = ["project,agent,prs,commits,added,removed"]
    for p in projects:
        d = store["projects"][p]
        proj_rows.append(f"{p},{d['prs']['total']},{d['commits']['total']},"
                         f"{d['commits']['added']},{d['commits']['removed']},"
                         f"{d['no_mistakes_runs']['total']}")
        agents = set(d["prs"]["by_author"]) | set(d["commits"]["by_author"])
        for a in sorted(agents):
            safe = re.sub(r"[,\"\n]", "_", a)
            agent_rows.append(f"{p},{safe},{d['prs']['by_author'].get(a, 0)},"
                              f"{d['commits']['by_author'].get(a, 0)},"
                              f"{d['commits']['added_by'].get(a, 0)},"
                              f"{d['commits']['removed_by'].get(a, 0)}")
    proj_csv = "\n".join(proj_rows)
    agent_csv = "\n".join(agent_rows)
    var_options = [{"text": "All", "value": "$__all", "selected": True}]
    for p in projects:
        var_options.append({"text": p, "value": p})
    testdata = {"type": "grafana-testdata-datasource", "uid": "testdata"}
    def panel(pid, title, ptype, csv, x, y, extra=None):
        t = {"refId": "A", "scenarioId": "csv_content", "csvContent": csv}
        trans = [{"id": "filterByValue",
                  "options": {"filters": [{"fieldName": "project",
                                           "config": {"id": "regex",
                                                      "options": {"pattern": "$project"}}}],
                              "match": "any"}}]
        p = {"id": pid, "title": title, "type": ptype, "datasource": testdata,
             "targets": [t], "transformations": trans,
             "gridPos": {"h": 8, "w": 12, "x": x, "y": y}}
        if extra:
            p.update(extra)
        return p
    panels = [
        panel(1, "Pull requests", "stat", proj_csv, 0, 0,
              {"options": {"reduceOptions": {"calcs": ["sum"], "fields": "/prs/"}}}),
        panel(2, "Commits", "stat", proj_csv, 12, 0,
              {"options": {"reduceOptions": {"calcs": ["sum"], "fields": "/commits/"}}}),
        panel(3, "Lines added", "stat", proj_csv, 0, 8,
              {"options": {"reduceOptions": {"calcs": ["sum"], "fields": "/added/"}}}),
        panel(4, "Lines removed", "stat", proj_csv, 12, 8,
              {"options": {"reduceOptions": {"calcs": ["sum"], "fields": "/removed/"}}}),
        panel(5, "No-mistakes runs", "stat", proj_csv, 0, 16,
              {"options": {"reduceOptions": {"calcs": ["sum"], "fields": "/runs/"}}}),
        panel(6, "Per project", "table", proj_csv, 12, 16),
        panel(7, "Per agent", "table", agent_csv, 0, 24),
        panel(8, "Commits per project", "barchart", proj_csv, 12, 24),
    ]
    return {
        "uid": "firstmate-velocity",
        "title": "Velocity Dashboard",
        "tags": ["velocity", "firstmate"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 0,
        "templating": {"list": [{
            "name": "project", "label": "Project", "type": "custom",
            "multi": True, "includeAll": True,
            "current": {"text": "All", "value": "$__all"},
            "options": var_options,
            "query": ",".join(projects)}]},
        "panels": panels}

if not render_only:
    projects = parse_projects(projects_file)
    store = {"generated_at": datetime.now(timezone.utc).isoformat(),
             "projects": {}}
    remote_by_project = {}
    git_by_project = {}
    for name in projects:
        clone = os.path.join(projects_dir, name)
        remote = None
        if os.path.isdir(clone):
            r = run(["git", "-C", clone, "remote", "get-url", "origin"])
            if r is not None and r.returncode == 0 and r.stdout.strip():
                remote = r.stdout.strip()
            git_by_project[name] = clone
        else:
            print(f"warning: missing clone for {name}", file=sys.stderr)
        remote_by_project[name] = remote
        prs = {"total": 0, "by_author": {}}
        gh = parse_github_repo(remote) if remote else None
        if gh:
            prs = collect_prs(gh[0], gh[1])
        git = collect_git(clone, since) if os.path.isdir(clone) else \
            {"total": 0, "by_author": {}, "added": 0, "removed": 0,
             "added_by": {}, "removed_by": {}}
        store["projects"][name] = {
            "prs": prs,
            "commits": {"total": git["total"], "by_author": git["by_author"],
                        "added": git["added"], "removed": git["removed"],
                        "added_by": git["added_by"], "removed_by": git["removed_by"]},
            "no_mistakes_runs": {"total": 0},
        }
    runs = collect_runs(remote_by_project)
    for name in store["projects"]:
        store["projects"][name]["no_mistakes_runs"]["total"] = runs.get(name, 0)
    os.makedirs(os.path.dirname(store_path) or ".", exist_ok=True)
    with open(store_path, "w", encoding="utf-8") as f:
        json.dump(store, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {store_path}")
else:
    with open(store_path, encoding="utf-8") as f:
        store = json.load(f)

if not collect_only:
    dash = build_dashboard(store)
    os.makedirs(os.path.dirname(dashboard_path) or ".", exist_ok=True)
    with open(dashboard_path, "w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {dashboard_path}")
PY
