#!/usr/bin/env python3
"""fm-spend-ledger.py - the Firstmate spend ledger over workers' Pi session logs.

Usage:
  fm-spend-ledger.py scan                        refresh the session cache and fleet rollup
  fm-spend-ledger.py task <task-id>              refresh state/<id>.spend and print it
  fm-spend-ledger.py rollup                      print (and write) state/spend-rollup.json
  fm-spend-ledger.py model                       write state/spend-model.json (median task burn)
  fm-spend-ledger.py predict --quota <file>      print the dispatch prediction document
  fm-spend-ledger.py week [--hours <n>]          print trailing-window family totals

What it measures. Every Pi session is a JSONL file under the sessions root
(default ${PI_CODING_AGENT_DIR:-~/.pi/agent}/sessions; override with
--sessions-root or FM_SPEND_SESSIONS). The directory name encodes the session
working directory; each file's leading {"type":"session"} record carries the
authoritative "cwd", "id" and creation "timestamp". Assistant "message" records
carry usage per turn: input/output/cacheRead/cacheWrite/reasoning/totalTokens,
a cost object, plus provider and model. "thinking_level_change" records carry
the reasoning effort in effect from that point in the file, so each usage row
is attributed to the effort class active when it was written.

Nested sub-agents (the fm-orchestrated-* role agents and any other Pi
subagent) are separate session files. A session's artifacts directory holds
artifacts/<session-id>/subagent-registry.json mapping role names to child
sessionFile paths; children linked from a bound session inherit that session's
task attribution even when their own cwd or time would bind them elsewhere.
Each file is counted once, so a child that also matches the task's own
worktree window is never double counted.

Task attribution. state/<id>.meta records worktree= and spawn_gen=
(s<epoch>.<pid>.<rand>). A session binds to the task on its cwd whose spawn
epoch is the latest not after the session's own start timestamp, so treehouse
slot reuse splits cleanly at spawn boundaries. Sessions that predate every
known spawn on their worktree, and sessions on worktrees with no meta, fall
into the rollup's "unattributed" bucket. A relaunched task only records its
latest spawn_gen, so pre-relaunch sessions of that task id are unattributed;
that limitation is stated rather than hidden.

Lanes and families. The raw "provider" on each usage record (openai-codex,
xai, opencode-go, openrouter, ...) is the observed lane. For quota comparison
the rollup also publishes the mapped family: openai-codex -> codex and xai ->
grok are the only mappings, because those are the observed pairs; every other
provider stays under its own name so the ledger never invents a quota row for
a lane quota-axi does not measure. "deepseek" is a model family, not a lane:
any model whose name contains "deepseek" rolls up under the deepseek family in
addition to its provider.

Cost honesty. usage.cost.total is summed as reported. Records carrying tokens
with a missing or zero cost are counted as unpricedTokens: a plan-metered lane
such as openai-codex reports cost 0 while still consuming quota, so a zero
sum is "unmeasured", never "free". Buckets report costStatus known | partial |
none accordingly.

Outputs (all under the effective state dir - --state, FM_STATE_OVERRIDE, or
$FM_HOME/state):
  state/<id>.spend        per-task JSON: totals, byLane, byModel, byEffort,
                          session list, costStatus, and the binding window
  state/spend-rollup.json fleet rollup: all-time and trailing-7d family totals,
                          provider/day series, per-task totals, unattributed
  state/spend-model.json  median task burn by (quota provider, effort) plus the
                          global ladder used by "predict"
  state/.spend-cache.json per-file summaries keyed by path+size+mtime; append
                          growth re-parses only the changed tail files

predict reads one quota-axi --json snapshot and emits, per measured provider,
tokensPerPoint: tokens the ledger observed inside the provider's current
weekly window divided by the percent the window reports consumed. That ratio
is an estimate - session timestamps are bucketed by day - so the document
carries the inputs (windowStart, windowTokens, percentConsumed) for inspection.
Only windows whose kind is "weekly" are calibrated (resetsAt - 7 days is exact);
other kinds stay unmeasured. Median task burn comes from spend-model.json when
fresh enough (--model-max-age seconds, default 900) or is rebuilt in place.

A missing or unreadable sessions root is status "unavailable", never an empty
zero. All state writes are atomic (temp file + rename, mode 0600).
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

VERSION = 1
EFFORT_CLASSES = ("low", "medium", "high", "xhigh", "max")
# Observed Pi log provider -> quota-axi provider family. Only pairs observed in
# the real fleet are mapped; anything else keeps its own name.
LOG_TO_QUOTA_PROVIDER = {"openai-codex": "codex", "xai": "grok"}
WEEK_SECONDS = 604800
MODEL_MAX_AGE = 900


def eprint(*args):
    print(*args, file=sys.stderr)


def parse_iso(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def iso_of(epoch):
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def encode_cwd(cwd):
    """Pi session dir name for an absolute cwd: --<path with / \\ : -> ->--."""
    return "--" + re.sub(r"[/\\:]", "-", cwd.lstrip("/")) + "--"


def atomic_write_json(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".spend-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(doc, stream, indent=1, sort_keys=True)
            stream.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def empty_bucket():
    return {
        "messages": 0,
        "tokens": 0,
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "reasoning": 0,
        "cost": 0.0,
        "pricedTokens": 0,
        "unpricedTokens": 0,
    }


def bucket_add(bucket, usage):
    tokens = usage.get("totalTokens")
    if not isinstance(tokens, (int, float)) or tokens <= 0:
        tokens = sum(
            usage.get(k) or 0
            for k in ("input", "output", "cacheRead", "cacheWrite", "reasoning")
        )
    bucket["messages"] += 1
    bucket["tokens"] += int(tokens)
    for key in ("input", "output", "cacheRead", "cacheWrite", "reasoning"):
        value = usage.get(key)
        if isinstance(value, (int, float)):
            bucket[key] += int(value)
    cost = usage.get("cost")
    total = cost.get("total") if isinstance(cost, dict) else None
    if isinstance(total, (int, float)) and total > 0:
        bucket["cost"] += float(total)
        bucket["pricedTokens"] += int(tokens)
    elif tokens > 0:
        # Zero or absent cost on a token-bearing record is unmeasured spend,
        # not evidence of a free lane.
        bucket["unpricedTokens"] += int(tokens)
    return int(tokens)


def parse_session_file(path):
    """Summarize one Pi session JSONL: header facts plus usage buckets keyed
    by provider|model|effort. Returns None for unreadable or non-session files."""
    info = {
        "sessionId": None,
        "startTs": None,
        "endTs": None,
        "cwd": None,
        "rows": {},
        "dayTokens": {},
        "error": None,
    }
    effort = "unset"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(rec, dict):
                    continue
                rtype = rec.get("type")
                ts = parse_iso(rec.get("timestamp"))
                if ts is not None:
                    info["endTs"] = ts
                    if info["startTs"] is None:
                        info["startTs"] = ts
                if rtype == "session":
                    info["sessionId"] = rec.get("id")
                    info["cwd"] = rec.get("cwd")
                    info["startTs"] = parse_iso(rec.get("timestamp")) or info["startTs"]
                elif rtype == "thinking_level_change":
                    level = rec.get("thinkingLevel")
                    effort = level if isinstance(level, str) and level else "unset"
                elif rtype == "message":
                    msg = rec.get("message")
                    if not isinstance(msg, dict) or msg.get("role") != "assistant":
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    provider = msg.get("provider") or "unknown"
                    model = msg.get("model") or "unknown"
                    key = f"{provider}|{model}|{effort}"
                    row = info["rows"].get(key)
                    if row is None:
                        row = info["rows"][key] = empty_bucket()
                    tokens = bucket_add(row, usage)
                    # Usage belongs to the day its record was written, not the
                    # session start day; long sessions span quota windows.
                    when = ts if ts is not None else info["startTs"]
                    if when is not None and tokens > 0:
                        day = datetime.fromtimestamp(when, tz=timezone.utc).strftime("%Y-%m-%d")
                        day_key = f"{provider}|{model}|{day}"
                        day_row = info["dayTokens"].get(day_key)
                        if day_row is None:
                            day_row = info["dayTokens"][day_key] = {
                                "tokens": 0,
                                "cost": 0.0,
                                "pricedTokens": 0,
                                "unpricedTokens": 0,
                            }
                        day_row["tokens"] += tokens
                        cost = usage.get("cost")
                        total = cost.get("total") if isinstance(cost, dict) else None
                        if isinstance(total, (int, float)) and total > 0:
                            day_row["cost"] += float(total)
                            day_row["pricedTokens"] += tokens
                        else:
                            day_row["unpricedTokens"] += tokens
    except OSError as exc:
        info["error"] = str(exc)
        return None
    if info["sessionId"] is None:
        info["sessionId"] = Path(path).stem.split("_", 1)[-1]
    # The directory name IS the encoded cwd; keep it so binding can fall back
    # to it when the session header carries no cwd.
    info["dirName"] = Path(path).parent.name
    return info


def load_metas(state_dir):
    """Task facts from state/*.meta: worktree, spawn epoch, harness, effort."""
    tasks = []
    state = Path(state_dir)
    if not state.is_dir():
        return tasks
    for meta in sorted(state.glob("*.meta")):
        fields = {}
        try:
            for line in meta.read_text(encoding="utf-8", errors="replace").splitlines():
                if "=" in line:
                    key, _, value = line.partition("=")
                    fields.setdefault(key.strip(), value.strip())
        except OSError:
            continue
        task_id = fields.get("endpoint_task_id") or meta.stem
        worktree = fields.get("worktree")
        spawn = fields.get("spawn_gen") or ""
        match = re.match(r"s(\d+)\.", spawn)
        spawn_epoch = int(match.group(1)) if match else None
        tasks.append(
            {
                "id": task_id,
                "metaStem": meta.stem,
                "worktree": worktree,
                "cwdKey": encode_cwd(worktree) if worktree else None,
                "spawnEpoch": spawn_epoch,
                "harness": fields.get("harness"),
                "model": fields.get("model"),
                "effort": fields.get("effort"),
                "kind": fields.get("kind"),
            }
        )
    return tasks


def load_cache(state_dir):
    path = Path(state_dir) / ".spend-cache.json"
    try:
        doc = json.loads(path.read_text())
        if doc.get("version") == VERSION and isinstance(doc.get("files"), dict):
            return doc["files"]
    except (OSError, json.JSONDecodeError):
        pass
    return {}


def save_cache(state_dir, files):
    atomic_write_json(Path(state_dir) / ".spend-cache.json", {"version": VERSION, "files": files})


def iter_session_files(sessions_root):
    root = Path(sessions_root)
    if not root.is_dir():
        return
    for entry in sorted(root.iterdir()):
        if not entry.is_dir() or not entry.name.startswith("--"):
            continue
        try:
            children = sorted(entry.iterdir())
        except OSError:
            continue
        for child in children:
            if child.suffix == ".jsonl" and child.is_file():
                yield child


def refresh_cache(sessions_root, state_dir, budget_seconds=None):
    """Incremental scan: parse only new or changed session files.
    Returns (files_map, scanned, remaining, seconds_used)."""
    start = time.time()
    files = load_cache(state_dir)
    scanned = 0
    remaining = 0
    seen = set()
    for path in iter_session_files(sessions_root):
        spath = str(path)
        seen.add(spath)
        try:
            st = path.stat()
        except OSError:
            continue
        cached = files.get(spath)
        if cached and cached.get("size") == st.st_size and cached.get("mtime") == st.st_mtime:
            continue
        if budget_seconds is not None and time.time() - start > budget_seconds:
            remaining += 1
            continue
        info = parse_session_file(path)
        if info is not None:
            files[spath] = {"size": st.st_size, "mtime": st.st_mtime, "summary": info}
            scanned += 1
    for gone in set(files) - seen:
        del files[gone]
    save_cache(state_dir, files)
    return files, scanned, remaining, time.time() - start


def registries(sessions_root):
    """Map child session file path -> parent session id, and parent session id
    -> list of child paths, from artifacts/<session-id>/subagent-registry.json."""
    child_to_parent = {}
    root = Path(sessions_root)
    if not root.is_dir():
        return child_to_parent
    for registry in root.glob("--*--/artifacts/*/subagent-registry.json"):
        try:
            doc = json.loads(registry.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(doc, dict):
            continue
        parent_id = registry.parent.name
        for entry in doc.values():
            if not isinstance(entry, dict):
                continue
            child = entry.get("sessionFile")
            if isinstance(child, str) and child:
                child_to_parent[os.path.realpath(child)] = parent_id
    return child_to_parent


def bind_tasks(files, tasks, sessions_root):
    """Attribute every cached session to a task id or None.
    Registry children inherit their parent's binding. Returns
    (path -> task_id_or_None, path -> parent_session_id_or_None)."""
    child_to_parent = registries(sessions_root)
    by_cwd = {}
    for task in tasks:
        if task["cwdKey"] and task["spawnEpoch"] is not None:
            by_cwd.setdefault(task["cwdKey"], []).append(task)
    for listing in by_cwd.values():
        listing.sort(key=lambda t: t["spawnEpoch"])

    def dir_task(cwd, dir_name, start_ts):
        if start_ts is None:
            return None
        key = encode_cwd(cwd) if cwd else dir_name
        listing = by_cwd.get(key) if key else None
        if listing is None and dir_name and dir_name != key:
            # The record's cwd may differ from the directory name (symlink
            # resolution, relative paths); the directory name is the store's
            # own encoding, so trust it second.
            listing = by_cwd.get(dir_name)
        if not listing:
            return None
        chosen = None
        for task in listing:
            if task["spawnEpoch"] <= start_ts:
                chosen = task["id"]
            else:
                break
        return chosen

    binding = {}
    parent_of = {}
    id_to_path = {}
    for path, entry in files.items():
        summary = entry.get("summary") or {}
        if summary.get("sessionId"):
            id_to_path[summary["sessionId"]] = path
        binding[path] = dir_task(
            summary.get("cwd"), summary.get("dirName"), summary.get("startTs")
        )
    for path in files:
        real = os.path.realpath(path)
        parent_id = child_to_parent.get(real)
        if parent_id is None:
            continue
        parent_of[path] = parent_id
        parent_path = id_to_path.get(parent_id)
        if parent_path is not None and binding.get(parent_path) is not None:
            binding[path] = binding[parent_path]
    return binding, parent_of


def bucket_merge(bucket, row):
    for field, value in row.items():
        if field == "costStatus":
            continue
        bucket[field] = bucket.get(field, 0) + value


def add_bucket(into, key, row):
    bucket_merge(into.setdefault(key, empty_bucket()), row)


def cost_status(bucket):
    if bucket["tokens"] == 0:
        return "none"
    if bucket["unpricedTokens"] == 0 and bucket["cost"] >= 0:
        return "known" if bucket["pricedTokens"] > 0 else "none"
    if bucket["pricedTokens"] > 0:
        return "partial"
    return "none"


def family_of(provider, model):
    if isinstance(model, str) and "deepseek" in model.lower():
        return "deepseek"
    return LOG_TO_QUOTA_PROVIDER.get(provider, provider)


def summarize_files(files, binding=None, parent_of=None, only_task=None):
    """Aggregate rows into totals + byLane + byModel + byEffort.
    When only_task is set, binding decides membership."""
    out = {
        "totals": empty_bucket(),
        "byLane": {},
        "byProvider": {},
        "byModel": {},
        "byEffort": {},
        "sessions": [],
    }
    for path, entry in files.items():
        summary = entry.get("summary") or {}
        if only_task is not None and (binding or {}).get(path) != only_task:
            continue
        rows = summary.get("rows") or {}
        file_tokens = 0
        for key, row in rows.items():
            provider, model, effort = key.split("|", 2)
            lane = LOG_TO_QUOTA_PROVIDER.get(provider, provider)
            bucket_merge(out["totals"], row)
            add_bucket(out["byLane"], lane, row)
            add_bucket(out["byProvider"], provider, row)
            add_bucket(out["byModel"], f"{provider}/{model}", row)
            add_bucket(out["byEffort"], effort, row)
            file_tokens += row["tokens"]
        if only_task is not None:
            out["sessions"].append(
                {
                    "file": path,
                    "id": summary.get("sessionId"),
                    "start": iso_of(summary.get("startTs")),
                    "tokens": file_tokens,
                    "nested": path in (parent_of or {}),
                }
            )
    out["totals"]["sessions"] = len(out["sessions"]) if only_task is not None else len(
        [p for p, e in files.items() if (e.get("summary") or {}).get("rows")]
    )
    out["totals"]["nestedSessions"] = len(parent_of or {}) if only_task is None else sum(
        1 for s in out["sessions"] if s["nested"]
    )
    out["totals"]["costStatus"] = cost_status(out["totals"])
    return out


def cmd_task(args, state_dir, sessions_root):
    if "/" in args.id or args.id in ("", ".", ".."):
        eprint(f"fm-spend-ledger: unsafe task id {args.id!r}")
        return 2
    tasks = load_metas(state_dir)
    meta = next(
        (t for t in tasks if t["id"] == args.id or t["metaStem"] == args.id), None
    )
    files, scanned, remaining, _secs = refresh_cache(
        sessions_root, state_dir, budget_seconds=args.scan_budget
    )
    binding, parent_of = bind_tasks(files, tasks, sessions_root)
    if meta is None:
        doc = {
            "version": VERSION,
            "task": args.id,
            "generatedAt": iso_of(time.time()),
            "status": "unavailable",
            "reason": f"no state/{args.id}.meta",
            "totals": empty_bucket(),
        }
    elif meta["cwdKey"] is None or meta["spawnEpoch"] is None:
        doc = {
            "version": VERSION,
            "task": args.id,
            "generatedAt": iso_of(time.time()),
            "status": "unavailable",
            "reason": "task meta lacks worktree or spawn_gen",
            "worktree": meta["worktree"],
            "totals": empty_bucket(),
        }
    else:
        summary = summarize_files(files, binding, parent_of, only_task=args.id)
        status = "ok" if summary["sessions"] else "empty"
        doc = {
            "version": VERSION,
            "task": args.id,
            "generatedAt": iso_of(time.time()),
            "status": status,
            "worktree": meta["worktree"],
            "harness": meta["harness"],
            "spawnEpoch": meta["spawnEpoch"],
            "partial": remaining > 0,
            "totals": summary["totals"],
            "byLane": summary["byLane"],
            "byProvider": summary["byProvider"],
            "byModel": summary["byModel"],
            "byEffort": summary["byEffort"],
            "sessions": sorted(summary["sessions"], key=lambda s: s["start"] or ""),
        }
        if status == "empty":
            doc["reason"] = "no Pi session files bound to this task yet"
    atomic_write_json(Path(state_dir) / f"{args.id}.spend", doc)
    print(json.dumps(doc, indent=1, sort_keys=True))
    return 0


def provider_day_series(files):
    """tokens per quota-mapped provider per UTC day, from per-record days."""
    series = {}
    for entry in files.values():
        summary = entry.get("summary") or {}
        for key, day_row in (summary.get("dayTokens") or {}).items():
            provider, _model, day = key.split("|", 2)
            lane = LOG_TO_QUOTA_PROVIDER.get(provider, provider)
            days = series.setdefault(lane, {})
            days[day] = days.get(day, 0) + day_row["tokens"]
    return series


def build_rollup(files, tasks, sessions_root, now=None):
    now = now or time.time()
    binding, parent_of = bind_tasks(files, tasks, sessions_root)
    all_summary = summarize_files(files, binding, parent_of)
    families = {}
    week = {"hours": 168, "byFamily": {}, "totalTokens": 0}
    cutoff = now - 168 * 3600
    task_docs = {}
    unattributed = {"tokens": 0, "sessions": 0}
    for path, entry in files.items():
        summary = entry.get("summary") or {}
        rows = summary.get("rows") or {}
        for key, row in rows.items():
            provider, model, _effort = key.split("|", 2)
            fam = family_of(provider, model)
            add_bucket(families, fam, row)
        for key, day_row in (summary.get("dayTokens") or {}).items():
            provider, model, day = key.split("|", 2)
            day_ts = parse_iso(day + "T00:00:00Z")
            if day_ts is None or day_ts + 86400 <= cutoff:
                continue
            fam = family_of(provider, model)
            fam_bucket = week["byFamily"].setdefault(fam, empty_bucket())
            fam_bucket["tokens"] += day_row["tokens"]
            fam_bucket["cost"] += day_row["cost"]
            fam_bucket["pricedTokens"] += day_row["pricedTokens"]
            fam_bucket["unpricedTokens"] += day_row["unpricedTokens"]
            week["totalTokens"] += day_row["tokens"]
        task_id = binding.get(path)
        if task_id is None:
            if rows:
                unattributed["sessions"] += 1
                unattributed["tokens"] += sum(r["tokens"] for r in rows.values())
            continue
        doc = task_docs.setdefault(task_id, {"tokens": 0, "cost": 0.0, "sessions": 0, "seconds": 0.0})
        doc["tokens"] += sum(r["tokens"] for r in rows.values())
        doc["cost"] += sum(r["cost"] for r in rows.values())
        doc["sessions"] += 1
        if summary.get("startTs") is not None and summary.get("endTs") is not None:
            doc["seconds"] += max(0.0, summary["endTs"] - summary["startTs"])
    for fam, bucket in week["byFamily"].items():
        bucket["costStatus"] = cost_status(bucket)
    for fam, bucket in families.items():
        bucket["costStatus"] = cost_status(bucket)
    return {
        "version": VERSION,
        "generatedAt": iso_of(now),
        "sessionsRoot": str(sessions_root),
        "all": all_summary["totals"],
        "byFamily": families,
        "trailing168h": week,
        "byProviderDay": provider_day_series(files),
        "tasks": task_docs,
        "unattributed": unattributed,
    }


def median(values):
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def build_model(files, tasks, sessions_root):
    """Median task burn per (quota provider, dominant effort) and the global
    fallback ladder the resolver reads."""
    binding, parent_of = bind_tasks(files, tasks, sessions_root)
    per_task = {}
    for path, entry in files.items():
        task_id = binding.get(path)
        if task_id is None:
            continue
        summary = entry.get("summary") or {}
        doc = per_task.setdefault(task_id, {"tokens": 0, "seconds": 0.0, "effortTokens": {}, "providerTokens": {}})
        if summary.get("startTs") is not None and summary.get("endTs") is not None:
            doc["seconds"] += max(0.0, summary["endTs"] - summary["startTs"])
        for key, row in (summary.get("rows") or {}).items():
            provider, _model, effort = key.split("|", 2)
            quota = LOG_TO_QUOTA_PROVIDER.get(provider)
            if quota:
                doc["providerTokens"][quota] = doc["providerTokens"].get(quota, 0) + row["tokens"]
            if effort in EFFORT_CLASSES:
                doc["effortTokens"][effort] = doc["effortTokens"].get(effort, 0) + row["tokens"]
            doc["tokens"] += row["tokens"]

    def stat(rows):
        return {
            "tokens": median([r["tokens"] for r in rows]),
            "seconds": median([r["seconds"] for r in rows]),
            "tasks": len(rows),
        }

    median_doc = {}
    global_effort = {}
    global_all = []
    for task_id, doc in per_task.items():
        if doc["tokens"] <= 0 or not doc["providerTokens"]:
            continue
        provider = max(doc["providerTokens"], key=doc["providerTokens"].get)
        effort = (
            max(doc["effortTokens"], key=doc["effortTokens"].get) if doc["effortTokens"] else "unset"
        )
        row = {"tokens": doc["tokens"], "seconds": doc["seconds"]}
        median_doc.setdefault(provider, {}).setdefault(effort, []).append(row)
        median_doc[provider].setdefault("all", []).append(row)
        if effort in EFFORT_CLASSES:
            global_effort.setdefault(effort, []).append(row)
        global_all.append(row)
    return {
        "version": VERSION,
        "generatedAt": iso_of(time.time()),
        "median": {p: {e: stat(rows) for e, rows in efforts.items()} for p, efforts in median_doc.items()},
        "anyProvider": {e: stat(rows) for e, rows in global_effort.items()} | {"all": stat(global_all)},
    }


def load_json_file(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def cmd_predict(args, state_dir, sessions_root):
    quota = load_json_file(args.quota)
    if not isinstance(quota, dict) or not isinstance(quota.get("providers"), list):
        print(json.dumps({"status": "unavailable", "reason": "quota snapshot unreadable"}))
        return 0
    model_path = Path(state_dir) / "spend-model.json"
    model = load_json_file(model_path)
    model_age = None
    if isinstance(model, dict):
        model_age = time.time() - (parse_iso(model.get("generatedAt")) or 0)
    files, _scanned, remaining, secs = refresh_cache(
        sessions_root, state_dir, budget_seconds=args.scan_budget
    )
    tasks = load_metas(state_dir)
    if not isinstance(model, dict) or model.get("version") != VERSION or (
        model_age is not None and model_age > args.model_max_age
    ):
        model = build_model(files, tasks, sessions_root)
        atomic_write_json(model_path, model)
    day_series = provider_day_series(files)
    providers = {}
    now = time.time()
    for provider in quota.get("providers") or []:
        name = provider.get("provider")
        windows = provider.get("windows") or []
        window = next((w for w in windows if w.get("kind") == "weekly"), None)
        if window is None:
            continue
        resets = parse_iso(window.get("resetsAt"))
        percent_remaining = window.get("percentRemaining")
        if resets is None or not isinstance(percent_remaining, (int, float)):
            continue
        consumed = 100.0 - float(percent_remaining)
        window_start = resets - WEEK_SECONDS
        tokens_in_window = 0
        for day, tokens in (day_series.get(name) or {}).items():
            day_ts = parse_iso(day + "T00:00:00Z")
            if day_ts is not None and day_ts + 86400 > window_start:
                tokens_in_window += tokens
        entry = {
            "windowKind": window.get("kind"),
            "windowStart": iso_of(window_start),
            "windowTokens": tokens_in_window,
            "percentConsumed": consumed,
        }
        if consumed > 0 and tokens_in_window > 0:
            entry["tokensPerPoint"] = tokens_in_window / consumed
        providers[name] = entry
    doc = {
        "status": "ok",
        "version": VERSION,
        "generatedAt": iso_of(now),
        "partial": remaining > 0,
        "scanSeconds": round(secs, 3),
        "providers": providers,
        "median": model.get("median", {}),
        "anyProvider": model.get("anyProvider", {}),
    }
    print(json.dumps(doc, indent=1, sort_keys=True))
    return 0


def cmd_week(args, state_dir, sessions_root):
    files, _s, remaining, _secs = refresh_cache(sessions_root, state_dir, budget_seconds=None)
    now = time.time()
    cutoff = now - args.hours * 3600
    families = {}
    for entry in files.values():
        summary = entry.get("summary") or {}
        for key, day_row in (summary.get("dayTokens") or {}).items():
            provider, model, day = key.split("|", 2)
            day_ts = parse_iso(day + "T00:00:00Z")
            if day_ts is None or day_ts + 86400 <= cutoff:
                continue
            fam = family_of(provider, model)
            bucket = families.setdefault(fam, empty_bucket())
            bucket["tokens"] += day_row["tokens"]
            bucket["cost"] += day_row["cost"]
            bucket["pricedTokens"] += day_row["pricedTokens"]
            bucket["unpricedTokens"] += day_row["unpricedTokens"]
    for bucket in families.values():
        bucket["costStatus"] = cost_status(bucket)
    doc = {
        "version": VERSION,
        "generatedAt": iso_of(now),
        "hours": args.hours,
        "families": families,
        "totalTokens": sum(b["tokens"] for b in families.values()),
        "partial": remaining > 0,
    }
    print(json.dumps(doc, indent=1, sort_keys=True))
    return 0


def cmd_rollup(args, state_dir, sessions_root):
    files, _s, remaining, _secs = refresh_cache(sessions_root, state_dir, budget_seconds=None)
    doc = build_rollup(files, load_metas(state_dir), sessions_root)
    doc["partial"] = remaining > 0
    atomic_write_json(Path(state_dir) / "spend-rollup.json", doc)
    print(json.dumps(doc, indent=1, sort_keys=True))
    return 0


def cmd_model(args, state_dir, sessions_root):
    files, _s, remaining, _secs = refresh_cache(sessions_root, state_dir, budget_seconds=None)
    doc = build_model(files, load_metas(state_dir), sessions_root)
    atomic_write_json(Path(state_dir) / "spend-model.json", doc)
    print(json.dumps(doc, indent=1, sort_keys=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="fm-spend-ledger.py", description=__doc__.splitlines()[0])
    parser.add_argument("--state", default=os.environ.get("FM_STATE_OVERRIDE") or os.path.join(os.environ.get("FM_HOME", str(Path(__file__).resolve().parent.parent)), "state"))
    parser.add_argument("--sessions-root", default=os.environ.get("FM_SPEND_SESSIONS") or os.path.join(os.environ.get("PI_CODING_AGENT_DIR", os.path.expanduser("~/.pi/agent")), "sessions"))
    parser.add_argument("--scan-budget", type=float, default=None)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("scan", help="refresh the session cache")
    p.add_argument("--scan-budget", type=float, default=None)

    p = sub.add_parser("task", help="write state/<id>.spend and print it")
    p.add_argument("id")
    p.add_argument("--scan-budget", type=float, default=None)

    p = sub.add_parser("rollup", help="write and print state/spend-rollup.json")

    p = sub.add_parser("model", help="write and print state/spend-model.json")

    p = sub.add_parser("predict", help="print the dispatch prediction document")
    p.add_argument("--quota", required=True)
    p.add_argument("--model-max-age", type=float, default=MODEL_MAX_AGE)
    p.add_argument("--scan-budget", type=float, default=25)

    p = sub.add_parser("week", help="print trailing-window family totals")
    p.add_argument("--hours", type=float, default=168)

    args = parser.parse_args(argv)
    state_dir = args.state
    sessions_root = args.sessions_root
    Path(state_dir).mkdir(parents=True, exist_ok=True)

    if args.cmd == "scan":
        files, scanned, remaining, secs = refresh_cache(
            sessions_root, state_dir, budget_seconds=args.scan_budget
        )
        print(json.dumps({
            "version": VERSION,
            "sessionsRoot": sessions_root,
            "files": len(files),
            "scanned": scanned,
            "remaining": remaining,
            "seconds": round(secs, 3),
        }, indent=1, sort_keys=True))
        return 0
    if args.cmd == "task":
        return cmd_task(args, state_dir, sessions_root)
    if args.cmd == "rollup":
        return cmd_rollup(args, state_dir, sessions_root)
    if args.cmd == "model":
        return cmd_model(args, state_dir, sessions_root)
    if args.cmd == "predict":
        return cmd_predict(args, state_dir, sessions_root)
    if args.cmd == "week":
        return cmd_week(args, state_dir, sessions_root)
    parser.error(f"unknown command {args.cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
