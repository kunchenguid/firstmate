#!/usr/bin/env bash
# Cortana firstmate-captain bootstrap.
# Emitted into every Claude Code session via a global SessionStart hook so this
# harness always boots AS the captain — knowing the spawn lifecycle and live
# fleet state without rediscovering them mid-task.
#
# REHYDRATE (context watchdog): if a handoff doc for THIS pane's window exists
# (state/handoff-<window>.md), this session is a watchdog-driven restart — inject
# the leave-off doc (or a pointer to it if it exceeds the 10k inject cap) as
# additionalContext, then archive the handoff so it fires exactly once. The handoff
# is keyed by the SAME window key the statusline used (fm-ctx-lib.sh window logic),
# so the pre-/clear writer and this post-/clear reader agree. Presence of the
# handoff is itself the trigger (a handoff only exists because the watchdog ran the
# checkpoint cycle), which sidesteps relying on the exact SessionStart `source`
# string; `source` is logged but not gated on. Without a handoff, behavior is
# unchanged: a captain pane gets the normal captain context, any other pane gets
# nothing.
FM="${FM_HOME:-$HOME/firstmate}"
# Helper scripts (fm-watch-arm.sh --status, fm-lock.sh status) resolve through
# this script's own bin dir; FM_BOOTSTRAP_BIN overrides it (the test stub seam).
FM_BIN="${FM_BOOTSTRAP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# Capture the SessionStart hook payload from stdin into an env var: the python
# program itself arrives on python's stdin via the heredoc, so the program reads
# the hook JSON from the environment, not sys.stdin.
FM_HOOK_JSON="$(cat)" FM_BOOTSTRAP_FM="$FM" FM_BOOTSTRAP_BIN="$FM_BIN" python3 - <<'PY'
import os, json, glob, subprocess, time, shutil
fm = os.environ["FM_BOOTSTRAP_FM"]
bindir = os.environ.get("FM_BOOTSTRAP_BIN", "")

# --- read the SessionStart hook payload (cwd, source, session_id, transcript) ---
raw = os.environ.get("FM_HOOK_JSON", "")
try:
    hook = json.loads(raw) if raw.strip() else {}
except Exception:
    hook = {}
source = hook.get("source", "")
cwd = hook.get("cwd") or os.environ.get("PWD", "")
session_id = hook.get("session_id", "") or ""

def read(p, limit=None):
    try:
        t = open(p).read()
        return t[:limit] if limit else t
    except Exception:
        return ""

# --- window key (mirrors fm-ctx-lib.sh fm_ctx_window_key) ---------------------
def sanitize(s):
    for ch in (":", "/", ".", " "):
        s = s.replace(ch, "_")
    return s

def window_key():
    ov = os.environ.get("FM_CTX_WINDOW")
    if ov:
        return sanitize(ov)
    pane = os.environ.get("TMUX_PANE")
    if pane:
        try:
            w = subprocess.run(
                ["tmux", "display-message", "-p", "-t", pane, "#{session_name}:#{window_name}"],
                capture_output=True, text=True, timeout=3).stdout.strip()
            if w:
                return sanitize(w)
        except Exception:
            pass
    return sanitize(session_id) if session_id else "unknown"

# --- role (mirrors fm-ctx-lib.sh fm_ctx_role) --------------------------------
# Deterministic override (additive): FIRSTMATE_ROLE forces the role regardless of
# cwd, so a Hermes-launched / "be Cortana" session is captain by signal, not by the
# accident of where it happens to be. Only the two valid values force; anything else
# (including an empty/unset var) falls through to the existing behavior unchanged.
# FM_CTX_ROLE stays honored as the prior test/explicit-tagging override. Precedence:
# FIRSTMATE_ROLE (validated) > FM_CTX_ROLE (legacy passthrough) > cwd default.
_fr = (os.environ.get("FIRSTMATE_ROLE") or "").strip().lower()
if _fr in ("captain", "crew"):
    role = _fr
else:
    role = os.environ.get("FM_CTX_ROLE") or (
        "captain" if cwd in (os.environ.get("HOME", ""), fm) else "crew")

state = os.path.join(fm, "state")
cap = int(os.environ.get("FM_CTX_INJECT_CAP", "10000"))
key = window_key()
handoff = os.path.join(state, "handoff-%s.md" % key)

blocks = []

# --- REHYDRATE block (any pane that has a pending handoff) --------------------
# The resume directive (state/resume-<key>.directive) is written by an on-demand
# compact (fm-compact-crewmate.sh --resume frontier|restart) to make the post-/clear
# reset deterministic. "frontier" (default, and the behavior for any watchdog-driven
# fire that wrote no directive) resumes the leave-off Frontier; "restart" tells the
# crewmate to restart the task from the compacted brief instead of mid-frontier.
def read_resume_directive():
    p = os.path.join(state, "resume-%s.directive" % key)
    try:
        v = open(p).read().strip().lower()
    except Exception:
        return "frontier", None
    return (v if v in ("frontier", "restart") else "frontier"), p

if os.path.exists(handoff):
    text = read(handoff)
    if len(text) <= cap:
        body = text
    else:
        body = "[handoff %d chars > %d cap — read it in full at: %s]" % (len(text), cap, handoff)
    resume_mode, resume_path = read_resume_directive()
    if resume_mode == "restart":
        directive = ("This is a deliberate RESTART: do NOT resume mid-frontier — "
                     "re-read the compacted brief below and start the task again from a "
                     "clean footing, using it as the authoritative scope.")
    else:
        directive = "This is exactly where you left off — pick the Frontier back up."
    blocks.append(
        "# Rehydrate — resume from your pre-/clear leave-off doc\n"
        "(You were auto-restarted by the firstmate context watchdog; source=%s. %s)\n\n%s"
        % (source or "?", directive, body))
    # Archive so the rehydrate fires exactly once.
    try:
        arch = os.path.join(state, "handoff-archive")
        os.makedirs(arch, exist_ok=True)
        shutil.move(handoff, os.path.join(arch, "handoff-%s-%d.md" % (key, int(time.time()))))
    except Exception:
        pass
    # Consume the resume directive so it fires exactly once (next boot is frontier).
    if resume_path:
        try:
            os.remove(resume_path)
        except Exception:
            pass

# --- Reconciliation digest (boot-time snapshot; captain only) -----------------
# Section-5 recovery signals visible at boot, so the captain does not burn live
# bash calls rediscovering them before acting. This is a SNAPSHOT, not
# reconciliation: it never drains the queue, never touches suppression markers
# (.seen-*, .stale-*, .last-*), never acquires locks, never archives anything —
# the captain still runs bin/fm-wake-drain.sh before acting (the disclaimer
# below is load-bearing). Watcher and lock lines are verbatim relays of the
# canonical helpers, never re-derived here.
DIGEST_CAP = 2000
DISCLAIMER = "Snapshot as of boot — run bin/fm-wake-drain.sh before acting on the fleet."

def wake_queue_snapshot():
    # Lock-free read: never touch .wake-queue.lock (contending with the live
    # watcher from inside a 10s hook is worse than a stale read). Torn-tail
    # rule: a record is valid iff it ends with a newline AND splits into >=5
    # tab fields (epoch, seq, kind, key, payload); a failing final line is
    # excluded from depth and display and flagged instead.
    try:
        with open(os.path.join(state, ".wake-queue"), "rb") as f:
            raw = f.read()
    except Exception:
        return 0, [], False
    if not raw:
        return 0, [], False
    text = raw.decode("utf-8", "replace")
    ends_nl = text.endswith("\n")
    rows = [r for r in text.split("\n") if r != ""]
    torn = False
    if rows and (not ends_nl or len(rows[-1].split("\t")) < 5):
        rows.pop()
        torn = True
    valid = [r for r in rows if len(r.split("\t")) >= 5]
    return len(valid), valid, torn

def helper_relay(script, args):
    # One sanctioned cheap exec; the helper's line is relayed verbatim.
    try:
        env = dict(os.environ)
        env["FM_HOME"] = fm
        r = subprocess.run([os.path.join(bindir, script)] + args,
                           capture_output=True, text=True, timeout=5, env=env)
        for ln in (r.stdout or "").splitlines():
            if ln.strip():
                return ln.strip()
        return "(%s: no output)" % script
    except Exception:
        return "(%s unavailable)" % script

def inflight_lines():
    out = []
    try:
        metas = sorted(glob.glob(os.path.join(state, "*.meta")))
    except Exception:
        return out
    for mp in metas:
        tid = os.path.basename(mp)[:-len(".meta")]
        meta = {}
        for ln in read(mp).splitlines():
            if "=" in ln:
                k, _, v = ln.partition("=")
                meta.setdefault(k.strip(), v.strip())
        status_lines = [l for l in read(os.path.join(state, tid + ".status")).splitlines() if l.strip()]
        last = status_lines[-1] if status_lines else "(no status yet)"
        out.append("- %s window=%s kind=%s mode=%s — %s"
                   % (tid, meta.get("window", "?"), meta.get("kind", "?"),
                      meta.get("mode", "?"), last))
    return out

def build_digest():
    depth, records, torn = wake_queue_snapshot()
    queue_items = ["  " + r for r in records[-5:]]
    tasks = inflight_lines()
    header    = "## Reconciliation digest (boot-time snapshot)"
    q_summary = "Wake queue: %s" % ("empty" if depth == 0 else "%d queued (most recent last)" % depth)
    torn_line = "  (tail possibly torn)" if torn else None
    watcher   = "Watcher: %s" % helper_relay("fm-watch-arm.sh", ["--status"])
    lock      = "Session lock: %s" % helper_relay("fm-lock.sh", ["status"])
    t_summary = "In-flight tasks: %s" % ("none" if not tasks else str(len(tasks)))
    afk       = "afk: %s" % ("yes" if os.path.exists(os.path.join(state, ".afk")) else "no")
    fixed = [header, q_summary, watcher, lock, t_summary, afk, DISCLAIMER]
    if torn_line:
        fixed.append(torn_line)
    # Budget the two variable lists inside the cap; anything dropped is counted
    # in an explicit "… (+N more)" marker, never silently. 64 chars are
    # reserved for the two potential marker lines.
    budget = DIGEST_CAP - sum(len(l) + 1 for l in fixed) - 64
    def take(items):
        nonlocal budget
        kept = []
        for it in items:
            if budget - (len(it) + 1) < 0:
                break
            kept.append(it)
            budget -= len(it) + 1
        return kept
    q_kept = take(queue_items)
    t_kept = take(tasks)
    q_hidden = depth - len(q_kept)
    t_hidden = len(tasks) - len(t_kept)
    lines = [header, q_summary]
    lines += q_kept
    if q_hidden > 0:
        lines.append("  … (+%d more)" % q_hidden)
    if torn_line:
        lines.append(torn_line)
    lines += [watcher, lock, t_summary]
    lines += t_kept
    if t_hidden > 0:
        lines.append("- … (+%d more)" % t_hidden)
    lines += [afk, DISCLAIMER]
    return "\n".join(lines)

# --- CAPTAIN context block (unchanged behavior) ------------------------------
if role == "captain":
    projects    = read(os.path.join(fm, "data/projects.md")).strip()
    secondmates = read(os.path.join(fm, "data/secondmates.md")).strip()
    backlog     = read(os.path.join(fm, "data/backlog.md"), 1500).strip()
    try:
        wins = subprocess.run(["tmux","list-windows","-t","firstmate","-F","#{window_name}"],
                              capture_output=True, text=True, timeout=3).stdout.strip()
    except Exception:
        wins = ""
    ctx = f"""# You are Cortana — firstmate captain (this session)
Operating manual: {fm}/AGENTS.md — READ IT before any software orchestration (full lifecycle, recovery, harness adapters, delivery modes). Your conversation memory is a cache; truth lives in tmux + {fm}/state + data/backlog.md + treehouse.
You delegate every piece of project work to a crewmate/secondmate you spawn, supervise, and tear down. Never do project work inline.

## Spawn lifecycle (know this cold — do not rediscover live)
1. Project must be registered: a git repo at {fm}/projects/<name> + one line in data/projects.md (name, delivery mode, optional +yolo, one-line desc).
2. Brief:  bin/fm-brief.sh <task-id> <repo-name> [--scout | --secondmate <proj>...]
   then edit data/<task-id>/brief.md, replacing {{TASK}} with task + acceptance criteria + context.
3. Spawn:  bin/fm-spawn.sh <task-id> <project-dir> [claude|codex|opencode|pi] [--scout|--secondmate]
   -> opens tmux window fm-<id> in session 'firstmate', runs `treehouse get` for an isolated worktree, launches the harness on the brief. Peek the pane within ~20s and clear any trust dialog with bin/fm-send.sh <win> --key Enter.
4. Supervise:  bin/fm-watch.sh · peek bin/fm-peek.sh <win> · steer bin/fm-send.sh <win> · teardown bin/fm-teardown.sh <id>
Delivery mode per project (data/projects.md via fm-project-mode.sh): no-mistakes (default: implement -> /no-mistakes -> PR -> captain merge) | direct-PR | local-only.

## Live fleet state
Registered projects:
{projects or '(none)'}

Secondmates:
{secondmates or '(none registered)'}

Open 'firstmate' tmux windows:
{wins or '(none — no session yet)'}

Recent backlog:
{backlog or '(empty)'}
"""
    # Digest degradation is total-by-design: any unexpected failure drops the
    # whole section rather than breaking the hook or the captain block.
    try:
        ctx += "\n" + build_digest() + "\n"
    except Exception:
        pass
    blocks.append(ctx)

# --- emit one combined additionalContext (or nothing) ------------------------
if blocks:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
          "additionalContext": "\n\n".join(blocks)}}))
PY
