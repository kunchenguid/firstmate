import json, os, sys
DOMAIN_ORDER = ["firstmate", "platform", "marut", "auditless", "MBCA", "agents", "oath",
                "usga", "garuda", "wiki", "bridge", "gitrank", "kg"]
def domain(labels):
    lowered = {l.lower() for l in labels or []}
    for d in DOMAIN_ORDER:
        if d.lower() in lowered:
            return d.lower()
    return None
def classify(labels):
    s = {l.lower() for l in labels or []}
    if "captain" in s:
        return "captain"
    if s & {"research", "wayfinder:research", "investigate", "plan"}:
        return "scout"
    return "ship"

ready_ids = {b["id"] for b in json.loads(os.environ["READY_JSON"])}
by_id = {i["id"]: i for i in json.loads(os.environ["OPEN_JSON"])}
deferred = json.loads(os.environ["DEFERRED_JSON"])
backlog = {t.strip().strip('"') for t in os.environ["BACKLOG_TITLES"].splitlines()
           if t and not t.startswith(("count:", "tasks[", "help["))}
backlog = {t.rsplit(",", 1)[-1].strip().strip('"') if t.count(",") >= 4
           else t for t in backlog}
roster = json.loads(os.environ["ROSTER_JSON"])
only = {t for t in os.environ["ONLY_TASKS"].split(",") if t}
HARNESS = "omp"
MODEL = "f2-stage-gateway/marutai/MAI-Pro"
state_dir = os.environ["STATE"]
work_underway = {os.path.splitext(n)[0] for n in os.listdir(state_dir) if n.endswith(".meta")} \
    if os.path.isdir(state_dir) else set()

# New roster schema: agents have `kind`, `posture` (parked > blocked > working
# > idle-stale > idle), `activity`, `open_keys` (already deterministic).
# Old schema: `resolution`, `work_evidence`, `report.open_keys`. Both join the
# same way - free for dispatch iff herdr sees the tab live, the peer has no
# unresolved decision, and nothing is hiding in the free-text keys.
agents = roster.get("agents") or roster.get("peers") or []
free_panes = [
    a["name"] for a in agents
    if a.get("kind", "peer") == "peer"
    and a.get("posture", a.get("work_evidence", "unknown")) not in ("parked", "blocked")
    and a.get("activity") == "idle"
    and not (a.get("open_keys") or a.get("report", {}).get("open_keys"))
]
capacity_full = (roster.get("sources") or {}).get("herdr") == "ok" and not free_panes
secondmate_scopes = {s.strip() for s in os.environ["SECONDMATE_SCOPES"].splitlines() if s.strip()}

def open_blocker(dep):
    bd = dep.get("depends_on_id") or dep.get("id")
    status = by_id.get(bd, {}).get("status") if bd in by_id else (dep.get("status") or "")
    return bd if status == "open" else None

def model_override(labels):
    return next((l[len("model:"):] for l in (labels or []) if l.lower().startswith("model:")), None)

candidates = []
for b in by_id.values():
    if b.get("status") != "open":
        continue
    blocker_ids = [open_blocker(d) for d in (b.get("dependencies") or [])
                   if (d.get("dependency_type") or d.get("type")) in ("blocks", "waits-for")]
    blockers = [x for x in blocker_ids if x]
    if b["id"] in ready_ids and not blockers:
        candidates.append(b)
    elif blockers:
        # A ready-shouldn't waiter is a waiter still: its actionable item is the
        # open blocker, and the waiter keeps waiting by contract.
        actions_deferred = dict(bead=b["id"], kind="route-blocker", blocker=blockers[0],
                                detail="route the blocker; the waiter keeps waiting")
        candidates.append(("__route__", actions_deferred))

actions = []
spawn_used = 0
real_candidates = []
for item in candidates:
    if isinstance(item, tuple) and item[0] == "__route__":
        actions.append(item[1])
    else:
        real_candidates.append(item)
real_candidates.sort(key=lambda b: (b.get("priority", 1), b["id"]))
for b in real_candidates:
    bid, title = b["id"], (b.get("title") or "")
    if only and bid not in only:
        continue
    if title in backlog:
        actions.append(dict(bead=bid, kind="skip", reason="title-in-flight-or-queued"))
        continue
    if any(tid and (tid in title or title in tid) for tid in work_underway for _ in [0]
           if len(tid) > 7):
        actions.append(dict(bead=bid, kind="skip", reason="work-underway-in-a-home"))
        continue
    klass = classify(b.get("labels"))
    override = model_override(b.get("labels"))
    if klass == "captain":
        actions.append(dict(bead=bid, kind="captain", decision=title[:90]))
        continue
    if override:
        actions.append(dict(bead=bid, kind="captain",
                            decision=(f"requires model {override}, not {MODEL}: {title[:70]}")))
        continue
    if b.get("defer_until") or b.get("status") == "deferred":
        actions.append(dict(bead=bid, kind="time-gate",
                            until=b.get("defer_until") or "deferred"))
        continue
    if capacity_full:
        actions.append(dict(bead=bid, kind="skip", reason="roster-capacity-gate; not an external wait"))
        continue
    dom = domain(b.get("labels"))
    harness = f"{HARNESS} {MODEL}"
    if dom == "platform" and any("platform" in s.lower() for s in secondmate_scopes):
        actions.append(dict(bead=bid, kind="secondmate", assignee="platform",
                            harness=harness, domain=dom, title=title[:80], klass=klass))
        continue
    if free_panes:
        actions.append(dict(bead=bid, kind="roster", assignee=free_panes[0],
                            harness=harness, domain=dom, title=title[:80], klass=klass))
        free_panes = free_panes[1:]
        continue
    if spawn_used:
        actions.append(dict(bead=bid, kind="skip", reason="one-worker-per-run-limit"))
        continue
    spawn_used = 1
    actions.append(dict(bead=bid, kind="crewmate", assignee="spawn", harness=harness,
                        domain=dom, title=title[:80], klass=klass, limit=1))

# Deferred beads form the external-wait surface, announced once per gate date.
time_gates = [dict(bead=d["id"], until=d.get("defer_until") or "deferred",
                   title=(d.get("title") or "")[:80]) for d in deferred
              if not only or d["id"] in only]
print(json.dumps(dict(board=os.environ["BOARD"], ready=sorted(ready_ids),
                      actions=actions, time_gates=time_gates,
                      harness=HARNESS if any(a.get("harness") for a in actions) else None,
                      model=MODEL, free_panes=free_panes)))
