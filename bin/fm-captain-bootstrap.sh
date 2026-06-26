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
# Capture the SessionStart hook payload from stdin into an env var: the python
# program itself arrives on python's stdin via the heredoc, so the program reads
# the hook JSON from the environment, not sys.stdin.
FM_HOOK_JSON="$(cat)" FM_BOOTSTRAP_FM="$FM" python3 - <<'PY'
import os, json, subprocess, time, shutil
fm = os.environ["FM_BOOTSTRAP_FM"]

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
if os.path.exists(handoff):
    text = read(handoff)
    if len(text) <= cap:
        body = text
    else:
        body = "[handoff %d chars > %d cap — read it in full at: %s]" % (len(text), cap, handoff)
    blocks.append(
        "# Rehydrate — resume from your pre-/clear leave-off doc\n"
        "(You were auto-restarted by the firstmate context watchdog; source=%s. "
        "This is exactly where you left off — pick the Frontier back up.)\n\n%s" % (source or "?", body))
    # Archive so the rehydrate fires exactly once.
    try:
        arch = os.path.join(state, "handoff-archive")
        os.makedirs(arch, exist_ok=True)
        shutil.move(handoff, os.path.join(arch, "handoff-%s-%d.md" % (key, int(time.time()))))
    except Exception:
        pass

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
    blocks.append(ctx)

# --- emit one combined additionalContext (or nothing) ------------------------
if blocks:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
          "additionalContext": "\n\n".join(blocks)}}))
PY
