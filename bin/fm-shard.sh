#!/usr/bin/env bash
# fm-shard.sh - deterministic mechanics for planning-to-Linear story sharding.
#
# The semantic policy is owned once by .agents/skills/story-sharder/SKILL.md.
# This script validates a sharding plan, renders the Linear-resident SPEC/story
# proposal, creates the Linear decision surface, and after approval materializes
# stories as Linear issues, project milestones, dependency links, and tasks-axi
# backlog items. It never runs or supervises the resulting work.
#
# Plan JSON shape:
#   initiative: {key,title,team_key,project_name|project_id,source?}
#   spec: {linear:{type:document|issue_description,title?,id?}, why,
#          capabilities:[{id,text}], constraints:[...], non_goals:[...],
#          success_signal, companions:[{title,url}]}
#   approval_decision: {title?, assignee_id?}
#   milestones: [{id,name,description?,target_date?}]
#   stories: [{id,title,description,acceptance_criteria:[...],
#              verification_contract,dependencies:[story-id...],milestone,
#              worker_kind:ship|scout,target_project,capabilities:[cap-id...],
#              backlog_id?,linear_issue_id?}]
#
# Commands:
#   fm-shard.sh validate <plan.json>
#   fm-shard.sh render-spec <plan.json>
#   fm-shard.sh propose <plan.json> [--dry-run] [--captain-user-id <id>] [--write-result <path>]
#   fm-shard.sh apply <plan.json> [--dry-run] [--write-result <path>]
#
# `propose` creates or updates the SPEC kernel in Linear, then creates one
# captain-assigned Linear issue as the approval surface. `apply` is run only
# after that decision is approved; it creates/updates story issues, creates
# project milestones as needed, links story dependencies, and writes matching
# tasks-axi backlog tasks in the active FM_HOME.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT FM_HOME

case "${1:-}" in
  -h|--help)
    awk '
      NR == 1 { next }
      /^#/ { sub(/^# ?/, ""); print; next }
      { exit }
    ' "$0"
    exit 0
    ;;
esac

exec python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

FM_HOME = Path(os.environ.get("FM_HOME", ".")).resolve()
API_URL = "https://api.linear.app/graphql"
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CAP_RE = re.compile(r"^CAP-[A-Za-z0-9._-]+$")
STORY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class ShardError(Exception):
    pass


def fail(msg):
    raise ShardError(msg)


def load_plan(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fail(f"plan not found: {path}")
    except json.JSONDecodeError as e:
        fail(f"plan is not valid JSON: {e}")


def require_obj(obj, path):
    if not isinstance(obj, dict):
        fail(f"{path} must be an object")
    return obj


def require_list(obj, path):
    if not isinstance(obj, list):
        fail(f"{path} must be a list")
    return obj


def require_text(obj, key, path):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{path}.{key} must be non-empty text")
    if "\n" in value or "\r" in value:
        fail(f"{path}.{key} must be one line")
    return value.strip()


def slugify(text):
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "story"


def validate_plan(plan):
    errors = []

    def collect(fn):
        try:
            return fn()
        except ShardError as e:
            errors.append(str(e))
            return None

    initiative = collect(lambda: require_obj(plan.get("initiative"), "initiative")) or {}
    spec = collect(lambda: require_obj(plan.get("spec"), "spec")) or {}
    linear = collect(lambda: require_obj(spec.get("linear"), "spec.linear")) or {}
    milestones = collect(lambda: require_list(plan.get("milestones"), "milestones")) or []
    stories = collect(lambda: require_list(plan.get("stories"), "stories")) or []

    for key in ("key", "title", "team_key"):
        collect(lambda key=key: require_text(initiative, key, "initiative"))
    if not initiative.get("project_id") and not initiative.get("project_name"):
        errors.append("initiative.project_name or initiative.project_id is required")
    if initiative.get("key") and not SLUG_RE.match(str(initiative.get("key"))):
        errors.append("initiative.key must be a privacy-safe slug")

    storage_type = linear.get("type")
    if storage_type not in ("document", "issue_description"):
        errors.append("spec.linear.type must be document or issue_description")
    if storage_type == "document" and not linear.get("title"):
        errors.append("spec.linear.title is required for Linear Document SPEC kernels")
    if storage_type == "issue_description" and not linear.get("id"):
        errors.append("spec.linear.id is required when the SPEC kernel lives in an issue description")

    for key in ("why", "success_signal"):
        if not isinstance(spec.get(key), str) or not spec.get(key, "").strip():
            errors.append(f"spec.{key} must be non-empty text")
    capabilities = spec.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        errors.append("spec.capabilities must contain at least one capability")
        capabilities = []
    cap_ids = set()
    for idx, cap in enumerate(capabilities):
        if not isinstance(cap, dict):
            errors.append(f"spec.capabilities[{idx}] must be an object")
            continue
        cid = cap.get("id")
        if not isinstance(cid, str) or not CAP_RE.match(cid):
            errors.append(f"spec.capabilities[{idx}].id must look like CAP-...")
        elif cid in cap_ids:
            errors.append(f"duplicate capability id: {cid}")
        else:
            cap_ids.add(cid)
        if not isinstance(cap.get("text"), str) or not cap.get("text", "").strip():
            errors.append(f"spec.capabilities[{idx}].text must be non-empty")
    for key in ("constraints", "non_goals"):
        values = spec.get(key)
        if not isinstance(values, list):
            errors.append(f"spec.{key} must be a list")
        elif any(not isinstance(v, str) or not v.strip() for v in values):
            errors.append(f"spec.{key} entries must be non-empty text")
    companions = spec.get("companions", [])
    if companions is None:
        companions = []
    if not isinstance(companions, list):
        errors.append("spec.companions must be a list when present")
    else:
        for idx, companion in enumerate(companions):
            if not isinstance(companion, dict):
                errors.append(f"spec.companions[{idx}] must be an object")
                continue
            if not isinstance(companion.get("title"), str) or not companion.get("title", "").strip():
                errors.append(f"spec.companions[{idx}].title must be non-empty")
            if not isinstance(companion.get("url"), str) or not companion.get("url", "").strip():
                errors.append(f"spec.companions[{idx}].url must be non-empty")

    milestone_ids = set()
    milestone_names = set()
    for idx, milestone in enumerate(milestones):
        if not isinstance(milestone, dict):
            errors.append(f"milestones[{idx}] must be an object")
            continue
        mid = milestone.get("id")
        name = milestone.get("name")
        if not isinstance(mid, str) or not SLUG_RE.match(mid):
            errors.append(f"milestones[{idx}].id must be a privacy-safe slug")
        elif mid in milestone_ids:
            errors.append(f"duplicate milestone id: {mid}")
        else:
            milestone_ids.add(mid)
        if not isinstance(name, str) or not name.strip():
            errors.append(f"milestones[{idx}].name must be non-empty")
        elif name in milestone_names:
            errors.append(f"duplicate milestone name: {name}")
        else:
            milestone_names.add(name)
        target = milestone.get("target_date")
        if target is not None and not re.match(r"^\d{4}-\d{2}-\d{2}$", str(target)):
            errors.append(f"milestones[{idx}].target_date must be YYYY-MM-DD when present")

    story_ids = set()
    for idx, story in enumerate(stories):
        if not isinstance(story, dict):
            errors.append(f"stories[{idx}] must be an object")
            continue
        sid = story.get("id")
        if not isinstance(sid, str) or not STORY_RE.match(sid):
            errors.append(f"stories[{idx}].id must be a privacy-safe slug")
        elif sid in story_ids:
            errors.append(f"duplicate story id: {sid}")
        else:
            story_ids.add(sid)
        for key in ("title", "description", "verification_contract", "target_project"):
            if not isinstance(story.get(key), str) or not story.get(key, "").strip():
                errors.append(f"stories[{idx}].{key} must be non-empty text")
        if story.get("worker_kind") not in ("ship", "scout"):
            errors.append(f"stories[{idx}].worker_kind must be ship or scout")
        if story.get("milestone") not in milestone_ids:
            errors.append(f"stories[{idx}].milestone must reference a milestone id")
        criteria = story.get("acceptance_criteria")
        if not isinstance(criteria, list) or not criteria:
            errors.append(f"stories[{idx}].acceptance_criteria must contain at least one criterion")
        elif any(not isinstance(v, str) or not v.strip() for v in criteria):
            errors.append(f"stories[{idx}].acceptance_criteria entries must be non-empty text")
        deps = story.get("dependencies", [])
        if not isinstance(deps, list):
            errors.append(f"stories[{idx}].dependencies must be a list")
        caps = story.get("capabilities", [])
        if not isinstance(caps, list) or not caps:
            errors.append(f"stories[{idx}].capabilities must reference at least one CAP id")
        elif any(c not in cap_ids for c in caps):
            errors.append(f"stories[{idx}].capabilities contains an unknown CAP id")
        backlog_id = story.get("backlog_id")
        if backlog_id is not None and (not isinstance(backlog_id, str) or not SLUG_RE.match(backlog_id)):
            errors.append(f"stories[{idx}].backlog_id must be a privacy-safe slug when present")

    for idx, story in enumerate(stories):
        if not isinstance(story, dict):
            continue
        sid = story.get("id")
        deps = story.get("dependencies", [])
        if isinstance(deps, list):
            for dep in deps:
                if dep not in story_ids:
                    errors.append(f"story {sid} depends on unknown story {dep}")
                if dep == sid:
                    errors.append(f"story {sid} cannot depend on itself")
    if stories and all(isinstance(s, dict) and isinstance(s.get("id"), str) for s in stories):
        try:
            topo_stories(stories)
        except ShardError as e:
            errors.append(str(e))

    if errors:
        fail("invalid shard plan:\n- " + "\n- ".join(errors))
    return True


def topo_stories(stories):
    by_id = {story["id"]: story for story in stories}
    visiting = set()
    visited = set()
    ordered = []

    def visit(sid, trail):
        if sid in visited:
            return
        if sid in visiting:
            fail("story dependency cycle: " + " -> ".join(trail + [sid]))
        if sid not in by_id:
            fail(f"unknown story dependency: {sid}")
        visiting.add(sid)
        for dep in by_id[sid].get("dependencies", []):
            visit(dep, trail + [sid])
        visiting.remove(sid)
        visited.add(sid)
        ordered.append(by_id[sid])

    for story in stories:
        visit(story["id"], [])
    return ordered


def line_items(values):
    return "\n".join(f"- {v.strip()}" for v in values) if values else "- None."


def render_spec(plan):
    initiative = plan["initiative"]
    spec = plan["spec"]
    milestones = plan["milestones"]
    stories = plan["stories"]
    companions = spec.get("companions") or []
    out = []
    out.append(f"# {initiative['title']} SPEC kernel")
    out.append("")
    out.append(f"Initiative key: `{initiative['key']}`")
    if initiative.get("source"):
        out.append(f"Source: {initiative['source']}")
    out.append("")
    out.append("## Why")
    out.append("")
    out.append(spec["why"].strip())
    out.append("")
    out.append("## Capabilities")
    out.append("")
    for cap in spec["capabilities"]:
        out.append(f"- `{cap['id']}` - {cap['text'].strip()}")
    out.append("")
    out.append("## Constraints")
    out.append("")
    out.append(line_items(spec.get("constraints", [])))
    out.append("")
    out.append("## Non-goals")
    out.append("")
    out.append(line_items(spec.get("non_goals", [])))
    out.append("")
    out.append("## Success signal")
    out.append("")
    out.append(spec["success_signal"].strip())
    out.append("")
    out.append("## Companion links")
    out.append("")
    if companions:
        for companion in companions:
            out.append(f"- [{companion['title']}]({companion['url']})")
    else:
        out.append("- None.")
    out.append("")
    out.append("## Milestones")
    out.append("")
    for milestone in milestones:
        suffix = f" target {milestone['target_date']}" if milestone.get("target_date") else ""
        desc = milestone.get("description", "").strip()
        out.append(f"- `{milestone['id']}` - {milestone['name']}{suffix}")
        if desc:
            out.append(f"  - {desc}")
    out.append("")
    out.append("## Story proposal")
    out.append("")
    for story in stories:
        deps = story.get("dependencies") or []
        caps = story.get("capabilities") or []
        out.append(f"### `{story['id']}` - {story['title']}")
        out.append("")
        out.append(story["description"].strip())
        out.append("")
        out.append(f"- Milestone: `{story['milestone']}`")
        out.append(f"- Dependencies: {', '.join(f'`{d}`' for d in deps) if deps else 'none'}")
        out.append(f"- Capabilities: {', '.join(f'`{c}`' for c in caps)}")
        out.append(f"- Suggested worker kind: `{story['worker_kind']}`")
        out.append(f"- Target project: `{story['target_project']}`")
        out.append("- Acceptance criteria:")
        for criterion in story["acceptance_criteria"]:
            out.append(f"  - {criterion.strip()}")
        out.append(f"- Verification contract: {story['verification_contract'].strip()}")
        out.append("")
    out.append("## Approval rule")
    out.append("")
    out.append("Captain approval on the linked Linear decision ticket authorizes materializing these stories into Linear issues, milestones, dependencies, and matching firstmate backlog tasks.")
    out.append("Routine in-scope work outside this large-initiative shard continues through the normal firstmate Linear workflow without a new approval gate.")
    return "\n".join(out).rstrip() + "\n"


def render_story_description(plan, story, spec_url=None):
    deps = story.get("dependencies") or []
    caps = story.get("capabilities") or []
    out = []
    out.append(f"Story id: `{story['id']}`")
    out.append("")
    if spec_url:
        out.append(f"SPEC kernel: {spec_url}")
        out.append("")
    out.append(story["description"].strip())
    out.append("")
    out.append("## Planning metadata")
    out.append("")
    out.append(f"- Initiative: `{plan['initiative']['key']}`")
    out.append(f"- Milestone: `{story['milestone']}`")
    out.append(f"- Dependencies: {', '.join(f'`{d}`' for d in deps) if deps else 'none'}")
    out.append(f"- Capabilities: {', '.join(f'`{c}`' for c in caps)}")
    out.append(f"- Suggested worker kind: `{story['worker_kind']}`")
    out.append(f"- Target project: `{story['target_project']}`")
    out.append("")
    out.append("## Acceptance criteria")
    out.append("")
    for criterion in story["acceptance_criteria"]:
        out.append(f"- {criterion.strip()}")
    out.append("")
    out.append("## Verification contract")
    out.append("")
    out.append(story["verification_contract"].strip())
    return "\n".join(out).rstrip() + "\n"


def render_backlog_body(plan, story, issue_url=None, spec_url=None):
    out = []
    out.append(f"Story `{story['id']}` from initiative `{plan['initiative']['key']}`.")
    if issue_url:
        out.append(f"Linear issue: {issue_url}")
    if spec_url:
        out.append(f"SPEC kernel: {spec_url}")
    out.append("")
    out.append(story["description"].strip())
    out.append("")
    out.append("Acceptance criteria:")
    for criterion in story["acceptance_criteria"]:
        out.append(f"- {criterion.strip()}")
    out.append("")
    out.append("Verification contract:")
    out.append(story["verification_contract"].strip())
    return "\n".join(out).rstrip() + "\n"


def graphql(query, variables):
    token = os.environ.get("LINEAR_API_KEY")
    if not token:
        fail("LINEAR_API_KEY is required for non-dry-run Linear mutations")
    payload = json.dumps({"query": query, "variables": variables}).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": token},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        fail(f"Linear API HTTP {e.code}: {body}")
    if data.get("errors"):
        fail("Linear API error: " + json.dumps(data["errors"], ensure_ascii=False))
    return data["data"]


def resolve_context(plan):
    initiative = plan["initiative"]
    if initiative.get("team_id"):
        team = {"id": initiative["team_id"], "key": initiative["team_key"]}
    else:
        data = graphql(
            "query($key:String!){ teams(filter:{key:{eq:$key}}, first:5){ nodes { id key name } } }",
            {"key": initiative["team_key"]},
        )
        nodes = data["teams"]["nodes"]
        if len(nodes) != 1:
            fail(f"expected one Linear team for key {initiative['team_key']}, found {len(nodes)}")
        team = nodes[0]
    if initiative.get("project_id"):
        project = {"id": initiative["project_id"], "name": initiative.get("project_name", "")}
    else:
        data = graphql(
            "query($name:String!){ projects(filter:{name:{eq:$name}}, first:20){ nodes { id name teams(first:20){ nodes { key id } } } } }",
            {"name": initiative["project_name"]},
        )
        matches = [p for p in data["projects"]["nodes"] if any(t["key"] == initiative["team_key"] for t in p.get("teams", {}).get("nodes", []))]
        if len(matches) != 1:
            fail(f"expected one Linear project named {initiative['project_name']} for team {initiative['team_key']}, found {len(matches)}")
        project = matches[0]
    return team, project


def create_or_update_spec(plan, context, dry_run=False):
    rendered = render_spec(plan)
    linear = plan["spec"]["linear"]
    if dry_run:
        return {"operation": "dry-run", "type": linear["type"], "id": linear.get("id"), "url": linear.get("url"), "content": rendered}
    team, project = context
    if linear["type"] == "document":
        if linear.get("id"):
            data = graphql(
                "mutation($id:String!,$input:DocumentUpdateInput!){ documentUpdate(id:$id,input:$input){ success document { id title url } } }",
                {"id": linear["id"], "input": {"title": linear.get("title") or plan["initiative"]["title"], "content": rendered, "projectId": project["id"]}},
            )
            doc = data["documentUpdate"]["document"]
        else:
            data = graphql(
                "mutation($input:DocumentCreateInput!){ documentCreate(input:$input){ success document { id title url } } }",
                {"input": {"title": linear.get("title") or f"{plan['initiative']['title']} SPEC", "content": rendered, "projectId": project["id"]}},
            )
            doc = data["documentCreate"]["document"]
        return {"type": "document", "id": doc["id"], "title": doc["title"], "url": doc.get("url")}
    data = graphql(
        "mutation($id:String!,$input:IssueUpdateInput!){ issueUpdate(id:$id,input:$input){ success issue { id identifier url } } }",
        {"id": linear["id"], "input": {"description": rendered}},
    )
    issue = data["issueUpdate"]["issue"]
    return {"type": "issue_description", "id": issue["id"], "identifier": issue["identifier"], "url": issue["url"]}


def create_decision_issue(plan, spec_result, context, captain_user_id=None, dry_run=False):
    decision = plan.get("approval_decision") or {}
    title = decision.get("title") or f"Approve shard for {plan['initiative']['title']}"
    assignee_id = decision.get("assignee_id") or captain_user_id
    if not assignee_id and not dry_run:
        fail("approval_decision.assignee_id or --captain-user-id is required for propose")
    body = []
    body.append("This is the captain decision surface for the attached planning shard.")
    body.append("")
    if spec_result.get("url"):
        body.append(f"SPEC/story proposal: {spec_result['url']}")
    else:
        body.append("SPEC/story proposal is in this issue description or the dry-run output.")
    body.append("")
    body.append("Approval authorizes firstmate to create/update the listed Linear stories, project milestones, dependency links, and matching backlog tasks.")
    body.append("This does not add an approval gate for routine in-scope work outside this large-initiative shard.")
    description = "\n".join(body) + "\n"
    if dry_run:
        return {"operation": "dry-run", "title": title, "assignee_id": assignee_id, "description": description}
    team, project = context
    input_obj = {"teamId": team["id"], "projectId": project["id"], "title": title, "description": description}
    if assignee_id:
        input_obj["assigneeId"] = assignee_id
    data = graphql(
        "mutation($input:IssueCreateInput!){ issueCreate(input:$input){ success issue { id identifier url } } }",
        {"input": input_obj},
    )
    issue = data["issueCreate"]["issue"]
    return {"id": issue["id"], "identifier": issue["identifier"], "url": issue["url"]}


def ensure_milestones(plan, context, dry_run=False):
    if dry_run:
        return {m["id"]: {"operation": "dry-run", "name": m["name"], "id": m.get("linear_milestone_id")} for m in plan["milestones"]}
    _team, project = context
    data = graphql(
        "query($id:String!){ project(id:$id){ projectMilestones(first:100){ nodes { id name } } } }",
        {"id": project["id"]},
    )
    existing = {m["name"]: m for m in data["project"]["projectMilestones"]["nodes"]}
    result = {}
    for milestone in plan["milestones"]:
        if milestone.get("linear_milestone_id"):
            result[milestone["id"]] = {"id": milestone["linear_milestone_id"], "name": milestone["name"]}
            continue
        if milestone["name"] in existing:
            found = existing[milestone["name"]]
            result[milestone["id"]] = {"id": found["id"], "name": found["name"], "existing": True}
            continue
        input_obj = {"projectId": project["id"], "name": milestone["name"]}
        for key in ("description", "target_date"):
            if milestone.get(key):
                input_obj["targetDate" if key == "target_date" else key] = milestone[key]
        data = graphql(
            "mutation($input:ProjectMilestoneCreateInput!){ projectMilestoneCreate(input:$input){ success projectMilestone { id name } } }",
            {"input": input_obj},
        )
        created = data["projectMilestoneCreate"]["projectMilestone"]
        result[milestone["id"]] = {"id": created["id"], "name": created["name"], "created": True}
    return result


def find_existing_story_issues(project_id, initiative_key, story_ids):
    wanted = set(story_ids)
    found = {}
    after = None
    initiative_marker = f"- Initiative: `{initiative_key}`"
    while wanted:
        data = graphql(
            "query($id:String!,$after:String){ project(id:$id){ issues(first:100, after:$after){ pageInfo { hasNextPage endCursor } nodes { id identifier url description } } } }",
            {"id": project_id, "after": after},
        )
        conn = data["project"]["issues"]
        for node in conn["nodes"]:
            desc = node.get("description") or ""
            if initiative_marker not in desc:
                continue
            for sid in list(wanted):
                if f"Story id: `{sid}`" in desc:
                    found[sid] = node
                    wanted.discard(sid)
        if not conn["pageInfo"]["hasNextPage"]:
            break
        after = conn["pageInfo"]["endCursor"]
    return found


def create_or_update_story_issues(plan, milestone_map, context, spec_url=None, dry_run=False):
    if dry_run:
        return {s["id"]: {"operation": "dry-run", "title": s["title"], "milestone": s["milestone"], "id": s.get("linear_issue_id")} for s in topo_stories(plan["stories"])}
    team, project = context
    stories = topo_stories(plan["stories"])
    needing_lookup = [s["id"] for s in stories if not s.get("linear_issue_id")]
    existing = find_existing_story_issues(project["id"], plan["initiative"]["key"], needing_lookup) if needing_lookup else {}
    result = {}
    for story in stories:
        desc = render_story_description(plan, story, spec_url=spec_url)
        input_obj = {
            "teamId": team["id"],
            "projectId": project["id"],
            "projectMilestoneId": milestone_map[story["milestone"]]["id"],
            "title": story["title"],
            "description": desc,
        }
        existing_id = story.get("linear_issue_id") or (existing.get(story["id"]) or {}).get("id")
        if existing_id:
            data = graphql(
                "mutation($id:String!,$input:IssueUpdateInput!){ issueUpdate(id:$id,input:$input){ success issue { id identifier url } } }",
                {"id": existing_id, "input": {k: v for k, v in input_obj.items() if k != "teamId"}},
            )
            issue = data["issueUpdate"]["issue"]
            result[story["id"]] = {"id": issue["id"], "identifier": issue["identifier"], "url": issue["url"], "existing": True}
        else:
            data = graphql(
                "mutation($input:IssueCreateInput!){ issueCreate(input:$input){ success issue { id identifier url } } }",
                {"input": input_obj},
            )
            issue = data["issueCreate"]["issue"]
            result[story["id"]] = {"id": issue["id"], "identifier": issue["identifier"], "url": issue["url"], "created": True}
    return result


def create_issue_relations(plan, issue_map, dry_run=False):
    result = []
    for story in topo_stories(plan["stories"]):
        for dep in story.get("dependencies", []):
            entry = {"from": dep, "to": story["id"], "type": "blocks"}
            if dry_run:
                entry["operation"] = "dry-run"
            else:
                data = graphql(
                    "query($id:String!){ issue(id:$id){ relations(first:100){ nodes { id type relatedIssue { id } } } } }",
                    {"id": issue_map[dep]["id"]},
                )
                existing = next(
                    (
                        relation
                        for relation in data["issue"]["relations"]["nodes"]
                        if relation["type"] == "blocks" and relation["relatedIssue"]["id"] == issue_map[story["id"]]["id"]
                    ),
                    None,
                )
                if existing:
                    entry["id"] = existing["id"]
                    entry["existing"] = True
                else:
                    data = graphql(
                        "mutation($input:IssueRelationCreateInput!){ issueRelationCreate(input:$input){ success issueRelation { id type } } }",
                        {"input": {"type": "blocks", "issueId": issue_map[dep]["id"], "relatedIssueId": issue_map[story["id"]]["id"]}},
                    )
                    entry["id"] = data["issueRelationCreate"]["issueRelation"]["id"]
            result.append(entry)
    return result


def tasks_axi_available():
    try:
        subprocess.run(["tasks-axi", "--version"], cwd=FM_HOME, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def task_exists(task_id):
    return subprocess.run(["tasks-axi", "show", task_id], cwd=FM_HOME, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def task_cmd(args, input_text=None):
    proc = subprocess.run(args, cwd=FM_HOME, input=input_text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        fail(f"tasks-axi command failed: {' '.join(args)}\n{proc.stderr}{proc.stdout}")
    return proc.stdout


def materialize_backlog(plan, issue_map, spec_url=None, dry_run=False):
    result = {}
    if dry_run:
        for story in topo_stories(plan["stories"]):
            backlog_id = story.get("backlog_id") or f"{plan['initiative']['key']}-{slugify(story['id'])}"
            result[story["id"]] = {"operation": "dry-run", "id": backlog_id, "blocked_by": [plan_story_backlog_id(plan, d) for d in story.get("dependencies", [])]}
        return result
    if not tasks_axi_available():
        fail("compatible tasks-axi is required to materialize backlog tasks")
    for story in topo_stories(plan["stories"]):
        backlog_id = plan_story_backlog_id(plan, story["id"])
        body = render_backlog_body(plan, story, issue_url=issue_map.get(story["id"], {}).get("url"), spec_url=spec_url)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
            tmp.write(body)
            tmp_path = tmp.name
        try:
            if task_exists(backlog_id):
                task_cmd(["tasks-axi", "update", backlog_id, "--title", story["title"], "--body-file", tmp_path, "--repo", story["target_project"], "--kind", story["worker_kind"]])
                action = "updated"
            else:
                args = ["tasks-axi", "add", backlog_id, story["title"], "--kind", story["worker_kind"], "--repo", story["target_project"], "--body-file", tmp_path]
                for dep in story.get("dependencies", []):
                    args.extend(["--blocked-by", plan_story_backlog_id(plan, dep)])
                task_cmd(args)
                action = "created"
            for dep in story.get("dependencies", []):
                task_cmd(["tasks-axi", "block", backlog_id, "--by", plan_story_backlog_id(plan, dep)])
            result[story["id"]] = {"id": backlog_id, "action": action, "blocked_by": [plan_story_backlog_id(plan, d) for d in story.get("dependencies", [])]}
        finally:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass
    return result


def plan_story_backlog_id(plan, story_id):
    for story in plan["stories"]:
        if story["id"] == story_id:
            return story.get("backlog_id") or f"{plan['initiative']['key']}-{slugify(story_id)}"
    fail(f"unknown story id for backlog: {story_id}")


def write_result(path, result):
    Path(path).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def cmd_validate(args):
    plan = load_plan(args.plan)
    validate_plan(plan)
    print("valid")


def cmd_render_spec(args):
    plan = load_plan(args.plan)
    validate_plan(plan)
    sys.stdout.write(render_spec(plan))


def cmd_propose(args):
    plan = load_plan(args.plan)
    validate_plan(plan)
    context = None if args.dry_run else resolve_context(plan)
    spec = create_or_update_spec(plan, context, dry_run=args.dry_run)
    decision = create_decision_issue(plan, spec, context, captain_user_id=args.captain_user_id, dry_run=args.dry_run)
    result = {"spec": spec, "decision_issue": decision}
    if args.write_result:
        write_result(args.write_result, result)
    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_apply(args):
    plan = load_plan(args.plan)
    validate_plan(plan)
    spec_url = plan.get("spec", {}).get("linear", {}).get("url")
    if not spec_url and plan.get("spec", {}).get("linear", {}).get("id") and plan["spec"]["linear"].get("type") == "issue_description":
        spec_url = plan["spec"]["linear"].get("issue_url")
    context = None if args.dry_run else resolve_context(plan)
    milestones = ensure_milestones(plan, context, dry_run=args.dry_run)
    issues = create_or_update_story_issues(plan, milestones, context, spec_url=spec_url, dry_run=args.dry_run)
    relations = create_issue_relations(plan, issues, dry_run=args.dry_run)
    backlog = materialize_backlog(plan, issues, spec_url=spec_url, dry_run=args.dry_run)
    result = {"milestones": milestones, "issues": issues, "relations": relations, "backlog": backlog}
    if args.write_result:
        write_result(args.write_result, result)
    print(json.dumps(result, indent=2, ensure_ascii=False))


def build_parser():
    parser = argparse.ArgumentParser(prog="fm-shard.sh", description="Planning-to-Linear story sharder mechanics")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("validate")
    p.add_argument("plan")
    p.set_defaults(func=cmd_validate)
    p = sub.add_parser("render-spec")
    p.add_argument("plan")
    p.set_defaults(func=cmd_render_spec)
    p = sub.add_parser("propose")
    p.add_argument("plan")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--captain-user-id")
    p.add_argument("--write-result")
    p.set_defaults(func=cmd_propose)
    p = sub.add_parser("apply")
    p.add_argument("plan")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--write-result")
    p.set_defaults(func=cmd_apply)
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    args.func(args)


try:
    main(sys.argv[1:])
except ShardError as e:
    print(f"fm-shard: {e}", file=sys.stderr)
    sys.exit(1)
PY
