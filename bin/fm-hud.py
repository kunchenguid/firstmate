#!/usr/bin/env python3
"""fm-hud.py - the collector/normalizer/renderer behind bin/fm-hud.sh.

Captain HUD: a read-only, project-agnostic snapshot of whatever this
firstmate home is doing right now - mission, worker health, banked
checkpoints, and AI subscription quota - derived entirely from local,
durable evidence (backlog, state/<id>.meta, git, tmux, ps, quota-axi).

Zero model calls. Zero mutation. Never acknowledges a wake, never touches
git, never restarts a worker. If a collector fails or a source is absent,
the affected field reports UNKNOWN/UNAVAILABLE rather than a fabricated
value - see collect_state()'s per-collector try/except boundaries.

Nothing here is keyed to a specific project, task id, branch, or slice
name: task discovery reads data/backlog.md and state/*.meta generically,
and the only two structural conventions it leans on are ones already used
by existing tasks in this repo, not invented for one project:
  - a meta key "<label>_run=..." paired optionally with "<label>_banked=YES"
    is read as one named checkpoint (used today by the banked-progress-policy
    slice convention; a task that never writes such keys just reports
    Progress: UNKNOWN, which is correct, not a bug).
  - a meta value containing "tmux <session-name>" is read as a recorded
    tmux session to probe for liveness.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

FM_GUARD_GRACE_DEFAULT = 300  # mirrors bin/fm-guard.sh's FM_GUARD_GRACE default


# --------------------------------------------------------------------------
# small utilities
# --------------------------------------------------------------------------

def _run(cmd, timeout=6, cwd=None):
    """Run a read-only subprocess. Returns (ok, stdout) - never raises."""
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode == 0, proc.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False, ""


def _now():
    return datetime.now(timezone.utc)


def _parse_iso(ts):
    if not ts:
        return None
    try:
        ts = ts.replace("Z", "+00:00")
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def _fmt_countdown(target, now=None):
    if target is None:
        return "UNKNOWN"
    now = now or _now()
    delta = (target - now).total_seconds()
    if delta <= 0:
        return "due"
    days, rem = divmod(int(delta), 86400)
    hours, rem = divmod(rem, 3600)
    minutes, seconds = divmod(rem, 60)
    if days:
        return f"{days}d {hours:02d}h {minutes:02d}m"
    if hours:
        return f"{hours:02d}h {minutes:02d}m {seconds:02d}s"
    return f"{minutes:02d}m {seconds:02d}s"


def _fmt_age(seconds):
    if seconds is None:
        return "UNKNOWN"
    if seconds < 0:
        seconds = 0
    if seconds < 90:
        return f"{int(seconds)}s ago"
    minutes = seconds / 60
    if minutes < 90:
        return f"{int(minutes)}m ago"
    hours = minutes / 60
    return f"{hours:.1f}h ago"


def _bar(percent, width=20, fill_char="#", empty_char="-"):
    if percent is None:
        return "[" + "?" * width + "]"
    percent = max(0, min(100, percent))
    filled = round(percent / 100 * width)
    return "[" + fill_char * filled + empty_char * (width - filled) + "]"


def _bar_unicode(percent, width=20):
    return _bar(percent, width, fill_char="█", empty_char="░")


# --------------------------------------------------------------------------
# backlog + meta parsing (generic - no project/task names encoded)
# --------------------------------------------------------------------------

_BACKLOG_ITEM_RE = re.compile(
    r"^- \[.\] (?P<id>\S+) - (?P<title>.+?) \(kind: (?P<kind>[a-z-]+)\)"
)
_BACKLOG_HOLD_RE = re.compile(r"\(hold: (?P<hold>[^)]*)\)")
_BACKLOG_HOLD_KIND_RE = re.compile(r"\(hold-kind: (?P<hold_kind>[^)]*)\)")
_BACKLOG_SINCE_RE = re.compile(r"\(since (?P<since>[^)]*)\)")


def parse_backlog(home):
    """Generic parser for data/backlog.md's '## <Section>' / '- [ ] id - title (kind: X) ...' shape."""
    path = os.path.join(home, "data", "backlog.md")
    if not os.path.isfile(path):
        return None
    items = []
    section = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("## "):
                section = line[3:].strip()
                continue
            m = _BACKLOG_ITEM_RE.match(line)
            if not m:
                continue
            hold_m = _BACKLOG_HOLD_RE.search(line)
            hold_kind_m = _BACKLOG_HOLD_KIND_RE.search(line)
            since_m = _BACKLOG_SINCE_RE.search(line)
            items.append(
                {
                    "id": m.group("id"),
                    "title": m.group("title"),
                    "kind": m.group("kind"),
                    "section": section,
                    "hold": hold_m.group("hold") if hold_m else None,
                    "hold_kind": hold_kind_m.group("hold_kind") if hold_kind_m else None,
                    "since": since_m.group("since") if since_m else None,
                }
            )
    return items


def parse_meta(home, task_id):
    """Generic key=value parser for state/<id>.meta. Unknown keys are kept (raw dict + raw text)."""
    path = os.path.join(home, "state", f"{task_id}.meta")
    if not os.path.isfile(path):
        return None
    fields = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    for line in raw.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key and key not in fields:
            fields[key] = value
    return {"fields": fields, "raw": raw}


_TMUX_MENTION_RE = re.compile(r"\btmux ([A-Za-z0-9_.-]+)")
_RUN_KEY_RE = re.compile(r"^(?P<label>[a-z0-9_]+)_run$")
_COMMIT_RE = re.compile(r"\bCommit ([0-9a-f]{7,40})\b")


def extract_recorded_tmux_sessions(meta_raw):
    return list(dict.fromkeys(_TMUX_MENTION_RE.findall(meta_raw)))  # de-dup, preserve order


def extract_checkpoints(meta_fields):
    """Generic '<label>_run=' / '<label>_banked=' checkpoint convention.

    Returns an ordered list of {label, run, banked, commit} or None when the
    task's meta uses none of this convention (Progress: UNKNOWN is then the
    honest answer, not a bug in this parser).
    """
    labels = []
    for key in meta_fields:
        m = _RUN_KEY_RE.match(key)
        if m and m.group("label") not in labels:
            labels.append(m.group("label"))
    if not labels:
        return None
    checkpoints = []
    for label in labels:
        banked_val = meta_fields.get(f"{label}_banked")
        banked = (banked_val or "").strip().upper().startswith("YES")
        commit = None
        if banked_val:
            cm = _COMMIT_RE.search(banked_val)
            if cm:
                commit = cm.group(1)
        checkpoints.append(
            {"label": label, "banked": banked, "commit": commit, "run": meta_fields.get(f"{label}_run")}
        )
    return checkpoints


# --------------------------------------------------------------------------
# git / worker / gnhf collectors
# --------------------------------------------------------------------------

def collect_git(worktree):
    if not worktree or not os.path.isdir(worktree):
        return {"available": False}
    out = {"available": True}
    ok, branch = _run(["git", "-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"])
    out["branch"] = branch.strip() if ok else "UNKNOWN"
    ok, head = _run(["git", "-C", worktree, "rev-parse", "--short", "HEAD"])
    out["head"] = head.strip() if ok else "UNKNOWN"
    ok, status = _run(["git", "-C", worktree, "status", "--porcelain"])
    out["dirty_count"] = len([l for l in status.splitlines() if l.strip()]) if ok else None
    ok, upstream = _run(["git", "-C", worktree, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    if ok and upstream.strip():
        ok2, counts = _run(["git", "-C", worktree, "rev-list", "--left-right", "--count", "HEAD...@{u}"])
        if ok2 and counts.strip():
            parts = counts.split()
            if len(parts) == 2:
                out["ahead"], out["behind"] = int(parts[0]), int(parts[1])
    return out


def _worktree_worker_alive(worktree, tmux_sessions):
    """Best-effort liveness: a recorded tmux session, or a process whose argv
    references this worktree path. Never prints the matched argv (no secrets)."""
    for session in tmux_sessions:
        ok, _ = _run(["tmux", "has-session", "-t", session], timeout=3)
        if ok:
            return True, session
    if worktree:
        ok, out = _run(["ps", "-eo", "args"], timeout=3)
        if ok and worktree in out:
            return True, None
    return False, None


def collect_gnhf(worktree, meta_fields, meta_raw):
    if not meta_fields.get("gnhf_enabled", "").strip().lower() == "true":
        return {"enabled": False}
    tmux_sessions = extract_recorded_tmux_sessions(meta_raw)
    alive, session = _worktree_worker_alive(worktree, tmux_sessions)
    out = {"enabled": True, "alive": alive, "tmux_session": session or (tmux_sessions[-1] if tmux_sessions else None)}

    run_id = meta_fields.get("gnhf_run_id")
    run_ids = [run_id] if run_id else []
    for key, value in meta_fields.items():
        if key.endswith("_run") and value:
            v = value.strip().split(" ", 1)[0]
            if v and v not in run_ids:
                run_ids.append(v)

    latest_activity = None
    run_dir = None
    for rid in run_ids:
        candidate = os.path.join(worktree or "", ".gnhf", "runs", rid) if worktree else None
        if candidate and os.path.isdir(candidate):
            run_dir = candidate  # last one wins: run_ids is roughly chronological (meta append order)
            for fname in os.listdir(candidate):
                if fname.endswith(".jsonl") or fname in ("gnhf.log", "notes.md", "end-state.json"):
                    try:
                        mtime = os.path.getmtime(os.path.join(candidate, fname))
                    except OSError:
                        continue
                    if latest_activity is None or mtime > latest_activity:
                        latest_activity = mtime

    out["last_activity_age_s"] = (time.time() - latest_activity) if latest_activity else None

    end_state_status = None
    if run_dir:
        end_state_path = os.path.join(run_dir, "end-state.json")
        if os.path.isfile(end_state_path):
            try:
                with open(end_state_path, encoding="utf-8") as fh:
                    end_state_status = json.load(fh).get("status")
            except (OSError, ValueError):
                end_state_status = "UNKNOWN"
    out["end_state_status"] = end_state_status
    out["iterations_consumed"] = meta_fields.get("gnhf_iterations_consumed")
    out["run_final_status"] = meta_fields.get("gnhf_run_final_status")
    return out


# --------------------------------------------------------------------------
# status state machine
# --------------------------------------------------------------------------

QUIET_THRESHOLD_S = 240  # a live worker with no on-disk activity past this is QUIET, not ACTIVE


def classify_task(task, git_info, gnhf_info):
    fields = task.get("meta_fields") or {}
    hold = task.get("hold")

    if fields.get("pr_url"):
        ci = (fields.get("github_ci_conclusion") or "").lower()
        if ci == "success":
            return "WAITING_FOR_CAPTAIN", "PR open with green checks, awaiting merge decision"
        if ci in ("failure", "failed"):
            return "BLOCKED", "PR open, checks failing"
        return "VERIFYING", "PR open, checks not yet confirmed"

    if fields.get("no_mistakes_run_id") and not fields.get("pr_url"):
        return "VERIFYING", "no-mistakes pipeline recorded, not yet at a PR"

    if gnhf_info.get("enabled"):
        if gnhf_info.get("alive"):
            age = gnhf_info.get("last_activity_age_s")
            if age is not None and age > QUIET_THRESHOLD_S:
                return "QUIET", f"worker process alive, no on-disk activity for {_fmt_age(age)}"
            return "ACTIVE", "worker process alive with recent activity"
        if gnhf_info.get("end_state_status"):
            status = gnhf_info["end_state_status"]
            if status == "stopped":
                return "PAUSED", "run stopped cleanly (e.g. captain shutdown), resumable"
            if status in ("failed", "error"):
                return "BLOCKED", f"run ended with status {status}"
        if hold:
            return "WAITING_FOR_CAPTAIN" if (task.get("hold_kind") or "").lower() != "future" else "PAUSED", hold
        return "PAUSED", "no worker process detected; task parked at its last durable checkpoint"

    if hold:
        return "WAITING_FOR_CAPTAIN" if (task.get("hold_kind") or "").lower() != "future" else "PAUSED", hold

    if task.get("section") == "Queued":
        return "IDLE", "queued, not dispatched"

    return "UNKNOWN", "no worker, pipeline, or hold evidence to classify from"


# --------------------------------------------------------------------------
# quota (quota-axi) - session/weekly windows only, never the all_models row
# --------------------------------------------------------------------------

def collect_quota(timeout=8):
    """quota-axi --json returns providers[].windows[] with a 'kind' of
    'session' or 'weekly' per window, plus quotaSemantics.effectiveAvailability
    for the binding limiter. This intentionally never substitutes the
    composite all_models percentRemaining for a missing named window - see
    the gnhf-profile-preflight-rule / financial-provider-policy history this
    guards against.
    """
    ok, out = _run(["quota-axi", "--json"], timeout=timeout)
    if not ok or not out.strip():
        return {"available": False}
    try:
        data = json.loads(out)
    except ValueError:
        return {"available": False}
    providers = {}
    for prov in data.get("providers", []):
        name = prov.get("provider")
        if not name:
            continue
        windows_by_kind = {}
        id_to_kind = {}
        for win in prov.get("windows", []) or []:
            kind = win.get("kind")
            if kind:
                windows_by_kind[kind] = win
                id_to_kind[win.get("id")] = kind
        binding_kind = None
        avail = (prov.get("quotaSemantics") or {}).get("effectiveAvailability") or []
        runway_seconds = None
        for entry in avail:
            if entry.get("status") != "known":
                continue
            limiting_ids = entry.get("limitingWindowIds")
            if limiting_ids:
                binding_kind = id_to_kind.get(limiting_ids[0], limiting_ids[0])
            runway = entry.get("runway") or {}
            runway_seconds = runway.get("usableRunwaySeconds")
            break
        providers[name] = {
            "windows": windows_by_kind,
            "binding_kind": binding_kind,
            "runway_seconds": runway_seconds,
            "plan": prov.get("plan"),
        }
    return {"available": True, "providers": providers}


def launch_safety(providers):
    """A disclosed threshold heuristic over the binding window's percent
    remaining, never a guarantee and never invented when quota is unavailable."""
    if not providers:
        return "UNKNOWN"
    worst = None
    for info in providers.values():
        binding = info.get("binding_kind")
        win = info.get("windows", {}).get(binding) if binding else None
        if win is None:
            continue
        pct = win.get("percentRemaining")
        if pct is None:
            continue
        if worst is None or pct < worst:
            worst = pct
    if worst is None:
        return "UNKNOWN"
    if worst < 10:
        return "INSUFFICIENT"
    if worst < 25:
        return "MARGINAL"
    return "SAFE"


# --------------------------------------------------------------------------
# provider/review-role policy (config-derived, not hardcoded)
# --------------------------------------------------------------------------

def collect_provider_policy(home):
    out = {"implementer": None, "reviewer": None}
    nm_config = os.path.expanduser("~/.no-mistakes/config.yaml")
    if os.path.isfile(nm_config):
        try:
            with open(nm_config, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            text = ""
        m = re.search(r"reviewer:\s*\n\s*agent:\s*(\S+)", text)
        if m:
            out["reviewer"] = m.group(1)
        m = re.search(r"fixer:\s*\n\s*agent:\s*(\S+)", text)
        if m:
            out["implementer"] = m.group(1)
    dispatch_path = os.path.join(home, "config", "crew-dispatch.json")
    if out["implementer"] is None and os.path.isfile(dispatch_path):
        try:
            with open(dispatch_path, encoding="utf-8") as fh:
                dispatch = json.load(fh)
            default = dispatch.get("default")
            if isinstance(default, list) and default:
                out["implementer"] = default[0].get("harness")
        except (OSError, ValueError):
            pass
    return out


def collect_watcher_beat(home):
    path = os.path.join(home, "state", ".last-watcher-beat")
    if not os.path.isfile(path):
        return {"available": False}
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {"available": False}
    age = time.time() - mtime
    grace = int(os.environ.get("FM_GUARD_GRACE", FM_GUARD_GRACE_DEFAULT))
    return {"available": True, "age_s": age, "grace_s": grace, "healthy": age <= grace}


# --------------------------------------------------------------------------
# top-level state assembly
# --------------------------------------------------------------------------

def collect_state(home, task_filter=None, project_filter=None):
    state = {"generated_at": _now().isoformat(), "home": home}

    backlog_items = parse_backlog(home)
    state["backlog_available"] = backlog_items is not None
    tasks = []
    for item in backlog_items or []:
        meta = parse_meta(home, item["id"])
        meta_fields = meta["fields"] if meta else {}
        task = dict(item)
        task["meta_available"] = meta is not None
        task["meta_fields"] = meta_fields
        task["project_path"] = meta_fields.get("project")
        task["worktree"] = meta_fields.get("worktree")
        task["harness"] = meta_fields.get("harness")
        task["mode"] = meta_fields.get("mode")
        task["yolo"] = meta_fields.get("yolo")
        task["pr_url"] = meta_fields.get("pr_url")
        task["project_display"] = (
            os.path.basename(meta_fields.get("project", "").rstrip("/"))
            if meta_fields.get("project")
            else item["id"]
        )
        task["git"] = collect_git(task["worktree"])
        task["gnhf"] = collect_gnhf(task["worktree"], meta_fields, meta["raw"] if meta else "")
        task["checkpoints"] = extract_checkpoints(meta_fields)
        task["status"], task["status_reason"] = classify_task(task, task["git"], task["gnhf"])
        tasks.append(task)

    if task_filter:
        tasks = [t for t in tasks if t["id"] == task_filter]
    elif project_filter:
        tasks = [t for t in tasks if project_filter.lower() in (t["project_display"] or "").lower()]

    state["tasks"] = tasks

    in_flight_active = [t for t in tasks if t["section"] == "In flight" and t["status"] == "ACTIVE"]
    in_flight = [t for t in tasks if t["section"] == "In flight"]
    selected = None
    ambiguous = False
    if task_filter or project_filter:
        selected = tasks[0] if len(tasks) == 1 else None
        ambiguous = len(tasks) > 1
    elif len(in_flight_active) == 1:
        selected = in_flight_active[0]
    elif len(in_flight_active) == 0 and len(in_flight) == 1:
        selected = in_flight[0]
    elif len(in_flight_active) > 1 or len(in_flight) > 1:
        ambiguous = True
    state["selected_task_id"] = selected["id"] if selected else None
    state["ambiguous"] = ambiguous

    try:
        state["quota"] = collect_quota()
    except Exception:  # collector isolation - a quota failure must not crash the HUD
        state["quota"] = {"available": False}
    state["launch_safety"] = launch_safety(state["quota"].get("providers")) if state["quota"].get("available") else "UNKNOWN"
    state["provider_policy"] = collect_provider_policy(home)
    state["watcher"] = collect_watcher_beat(home)
    return state


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def _supports_unicode():
    enc = (sys.stdout.encoding or "").lower()
    return "utf" in enc


def render_text(state):
    unicode_ok = _supports_unicode()
    bar = _bar_unicode if unicode_ok else _bar
    lines = []
    lines.append("=" * 74)
    lines.append("FIRSTMATE - CAPTAIN HUD".center(74))
    lines.append("=" * 74)

    tasks = state["tasks"]
    if not state["backlog_available"]:
        lines.append("BACKLOG: ABSENT")
    elif not tasks:
        lines.append("STATUS: IDLE - no matching tasks")
    elif state["ambiguous"]:
        lines.append("ACTIVE TASK: AMBIGUOUS - multiple candidates, pass --task <id> to select")
        lines.append("")
        lines.append("TASKS")
        for t in tasks:
            lines.append(f"  {t['project_display']:<28} {t['id']:<32} {t['status']}")
    else:
        selected = next((t for t in tasks if t["id"] == state["selected_task_id"]), None)
        others = [t for t in tasks if t is not selected]
        if selected:
            lines.append("MISSION")
            lines.append(f"  Project      {selected['project_display']}")
            lines.append(f"  Task         {selected['id']} - {selected['title']}")
            lines.append(f"  Status       {selected['status']}  ({selected['status_reason']})")
            git = selected["git"]
            if git.get("available"):
                dirty = git.get("dirty_count")
                line = f"  Branch       {git.get('branch', 'UNKNOWN')} @ {git.get('head', 'UNKNOWN')}"
                if dirty is not None:
                    line += f"  ({dirty} dirty file{'s' if dirty != 1 else ''})"
                lines.append(line)
                if "ahead" in git:
                    lines.append(f"  Upstream     {git['ahead']} ahead / {git['behind']} behind")
            else:
                lines.append("  Git          UNAVAILABLE (no recorded worktree found)")

            checkpoints = selected["checkpoints"]
            lines.append("")
            lines.append("BANKED")
            if checkpoints is None:
                lines.append("  Progress: UNKNOWN (task declares no checkpoint metadata)")
            else:
                done = sum(1 for c in checkpoints if c["banked"])
                lines.append(f"  {bar(100 * done / len(checkpoints) if checkpoints else None)} {done} / {len(checkpoints)} checkpoints")
                # The most recently *recorded* unbanked checkpoint is the
                # actionable one - meta keys are appended chronologically, so
                # an earlier unbanked entry (e.g. an aborted historical
                # attempt superseded by narrower sub-slices) is not "next".
                unbanked = [c["label"] for c in checkpoints if not c["banked"]]
                next_cp = unbanked[-1] if unbanked else None
                for c in checkpoints:
                    mark = "✓" if c["banked"] else (">" if c["label"] == next_cp else " ")
                    commit = f"  {c['commit']}" if c["commit"] else ""
                    lines.append(f"  {mark} {c['label']:<20}{commit}")
                lines.append(f"  Next checkpoint: {next_cp if next_cp else 'UNKNOWN'}")

            gnhf = selected["gnhf"]
            lines.append("")
            lines.append("WORKER")
            if not gnhf.get("enabled"):
                lines.append("  GNHF         not used by this task")
            else:
                lines.append(f"  GNHF worker  {'ALIVE' if gnhf['alive'] else 'NOT RUNNING'}")
                if gnhf.get("tmux_session"):
                    lines.append(f"  tmux         {gnhf['tmux_session']}")
                lines.append(f"  Last activity {_fmt_age(gnhf.get('last_activity_age_s'))}")
                if gnhf.get("end_state_status"):
                    lines.append(f"  Last run ended: {gnhf['end_state_status']}")
        if others:
            lines.append("")
            lines.append("OTHER TASKS")
            for t in others:
                lines.append(f"  {t['project_display']:<28} {t['id']:<32} {t['status']}")

    lines.append("")
    lines.append("-" * 74)
    lines.append("AI ENERGY".center(74))
    quota = state["quota"]
    if not quota.get("available"):
        lines.append("  TELEMETRY UNAVAILABLE (quota-axi did not return usable data)")
    else:
        for provider, info in quota["providers"].items():
            lines.append(f"  {provider.upper()} ({info.get('plan') or 'plan UNKNOWN'})")
            for kind, label in (("session", "SESSION"), ("weekly", "WEEKLY")):
                win = info["windows"].get(kind)
                if not win:
                    lines.append(f"    {label:<8} UNAVAILABLE")
                    continue
                pct = win.get("percentRemaining")
                resets = _parse_iso(win.get("resetsAt"))
                bound = " <- binding" if info.get("binding_kind") == kind else ""
                lines.append(f"    {label:<8} {bar(pct)} {pct}% remaining{bound}")
                if resets:
                    local_resets = resets.astimezone()
                    lines.append(
                        f"             reset {local_resets.strftime('%Y-%m-%d %H:%M %Z')}  (in {_fmt_countdown(resets)})"
                    )
            if info.get("runway_seconds") is not None:
                lines.append(f"    Est. runway  ~{int(info['runway_seconds'] / 60)} model-min (quota-axi projection)")
        lines.append(f"  Launch safety: {state['launch_safety']}")

    lines.append("")
    policy = state["provider_policy"]
    lines.append(f"PROVIDERS   implementer={policy['implementer'] or 'UNKNOWN'}  reviewer={policy['reviewer'] or 'UNKNOWN'}")
    lines.append("            pay-as-you-go API: LOCKED  ·  automatic paid fallback: NONE  (standing workstation policy)")

    watcher = state["watcher"]
    if watcher.get("available"):
        lines.append(
            f"RECOVERY    watcher beat {_fmt_age(watcher['age_s'])} (grace {watcher['grace_s']}s)  ->  "
            + ("ARMED" if watcher["healthy"] else "STALE")
        )
    else:
        lines.append("RECOVERY    watcher beat UNAVAILABLE")

    lines.append("=" * 74)
    lines.append(f"Refreshed: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')}")
    return "\n".join(lines)


def render_json(state):
    return json.dumps(state, indent=2, default=str)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="Firstmate Captain HUD (read-only, zero model cost)")
    parser.add_argument("--once", action="store_true", help="print one snapshot and exit")
    parser.add_argument("--json", action="store_true", help="emit normalized state as JSON and exit")
    parser.add_argument("--task", help="select an explicit task id")
    parser.add_argument("--project", help="filter to a project by display name")
    parser.add_argument("--refresh", type=float, default=7.0, help="screen refresh seconds in watch mode")
    parser.add_argument("--home", default=os.environ.get("FM_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args(argv)

    if args.json:
        state = collect_state(args.home, args.task, args.project)
        print(render_json(state))
        return 0

    if args.once:
        state = collect_state(args.home, args.task, args.project)
        print(render_text(state))
        return 0

    try:
        while True:
            state = collect_state(args.home, args.task, args.project)
            sys.stdout.write("\x1b[2J\x1b[H")
            print(render_text(state))
            sys.stdout.flush()
            time.sleep(max(1.0, args.refresh))
    except KeyboardInterrupt:
        sys.stdout.write("\x1b[?25h\n")
        return 0


if __name__ == "__main__":
    sys.exit(main())
