#!/usr/bin/env bash
# fm-boot-context.sh - the strictly READ-ONLY firstmate boot-context emitter.
#
# A SessionStart hook. Reads this home's state/ and data/, reads the shared
# fleet view, and prints one additionalContext block so a firstmate session
# knows what the fleet is doing without spending a single tool call on it.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS SEPARATELY FROM fm-captain-bootstrap.sh
# ---------------------------------------------------------------------------
# bin/fm-captain-bootstrap.sh was registered as a global SessionStart hook and
# was removed, with cause: it mutates durable files on every session start. It
# shutil.move()s the pending handoff into an archive and os.remove()s the resume
# directive, both belonging to the context-watchdog subsystem, whose writer
# (fm-ctx-statusline.sh) is itself unregistered and therefore dead. A hook that
# moves and deletes files on behalf of a dead subsystem has no business in the
# boot path, and the ban on it is correct on its facts.
#
# This script is the answer to that objection rather than an argument with it.
# It reads. It writes nothing, moves nothing, deletes nothing, creates nothing,
# and takes no lock - not even on the paths the rehydrate machinery owns. The
# rehydrate block stays out of the hot path until its writer is revived as its
# own task. That is what makes registering THIS script legal on the merits.
#
# The read-only property is not a promise, it is gate m2: a boot is run with a
# full before/after manifest of the home (path, size, mtime, ctime, inode,
# mode) and the manifest must be identical, and the same boot must still emit
# valid output with the whole tree held read-only via chmod a-w.
#
# ---------------------------------------------------------------------------
# THE TWO TIERS
# ---------------------------------------------------------------------------
# The old captain block was 10,188 chars (~2,550 tokens) - already over the
# 10,000-char additionalContext cap, and paid in full by every session that
# activated it, whether or not it was steering anything. Two tiers instead:
#
#   Tier 1  Universal. Identity, and one line per fleet instance. ~540 chars at
#           4 peers, ~1,000 at 12. A PEER IS NEVER ELIDED - the whole point is
#           that a session can answer "what is the fleet doing" with zero tool
#           calls, and dropping a peer breaks that. Per-task DETAIL may be
#           elided, because drilling into one task always cost a call anyway.
#
#   Tier 2  Only for the session that is actually steering: spawn lifecycle,
#           projects, secondmates, backlog, and the reconciliation digest.
#           Capped, with explicit "... (+N more)" markers.
#
# Steering is decided by the session lock, which needs no new signal: at boot
# the lock is either free or stale (this session is the one about to take it),
# or held by a live harness. If the holder is this process's own ancestor - a
# resume, a compact, a /clear in the steering session - it is still steering.
# Anything else is an incidental session and gets Tier 1 only. If the lock could
# not be read, or the ancestry probe could not RUN, the answer is neither of
# those two: it is "unknown", and it renders as an explicit marker. Tier 2 is
# still withheld - a steering session then pays one tool call, whereas the
# opposite default would charge every incidental session the full block - but
# the block never asserts that another session is steering on evidence it does
# not have.
#
# ---------------------------------------------------------------------------
# THE BUDGET
# ---------------------------------------------------------------------------
# A hook that overruns its declared timeout injects NOTHING, so the real hazard
# is not slowness, it is a boot that silently lost all of its context. The
# design set a 1.5s total ceiling and a 2s-per-helper timeout for two helpers,
# which is 4s and cannot satisfy its own gate; the tracked spec's Erratum
# reconciles it. The total is authoritative:
#
#   FM_BOOT_TOTAL_BUDGET   1.5s hard ceiling for the whole hook (6x headroom
#                          under the declared "timeout": 10 convention)
#   FM_BOOT_HELPER_TIMEOUT 0.45s per helper exec - still 6x the slowest
#                          measured helper (0.07s)
#
# Per-helper caps alone would not bound the total, so the helpers run
# CONCURRENTLY under ONE SHARED DEADLINE, computed once before any of them
# starts. They are independent reads, so the phase costs the MAX of their
# timeouts rather than the sum, and adding a third helper costs no extra
# elapsed time at all. A helper still running at the deadline is killed and
# rendered as a degradation marker rather than waited for.
#
# Serial execution is what made this tight: two 0.45s timeouts is 0.9s of
# deliberate waiting, which put the tail of a wedged boot at 1.52-1.61s against
# the 1.5s ceiling on a loaded machine. Going parallel was preferred over
# shrinking the per-helper allowance, so a slow-but-alive helper keeps the same
# generosity. The design named this option explicitly.
#
# The deadline is only as honest as its start time, and the start is taken in
# the BASH WRAPPER, before the interpreter exists. Starting it inside python
# hides ~0.3s of bash, stdin and interpreter startup from the arithmetic, which
# is enough to overrun a 1.5s ceiling in about a quarter of hostile runs while
# the gate still passes most of the time.
#
# What actually bounds the total is RENDER_RESERVE - see its comment below for
# the inequality.
#
# Two implementation defects, not the ceiling, were what breached it, and both
# are fixed here rather than by moving the threshold:
#
#   1. A LEAK. subprocess killed the helper it started but not what that helper
#      spawned, so every wedged boot orphaned two processes to init. Five per
#      gate run, accumulating: 194 live at once, load average 186, and the boots
#      being timed then took ~2s. The gate was measuring its own side effects
#      and it read as flakiness - one run passed, six in a row did not. Helpers
#      now run in their own process group and are killed as a group.
#   2. EXPENSIVE CLEANUP. Draining the pipes of a killed helper with
#      communicate() costs up to its timeout per helper - 0.4s at two helpers,
#      spent after the deadline was already gone, which put cold runs at
#      1.51-1.62s. The output is not wanted, so the group is killed, reaped, and
#      its fds closed without draining.
#
#   3. A SERIAL HELPER PHASE. Two 0.45s timeouts paid one after the other is
#      0.9s of deliberate waiting; the helpers are independent, so they now run
#      concurrently under one shared deadline and the phase costs the max
#      instead of the sum.
#
# And one defect in the GATE rather than the code, which had been hiding the
# real numbers: it stamped the start of each timed boot with one `python3 -c`
# and the end with another, charging the second interpreter's startup to the
# emitter. Measured over 60 samples at load ~180, against bash's free
# EPOCHREALTIME clock as a control: true boot p50 1.035s / max 1.370s with ZERO
# breaches, while the same boots as measured showed max 1.863s and three
# breaches. Instrumentation alone reached 0.608s.
#
# Measured after all of it, on a machine at load ~150: 10 consecutive gate runs
# green, boots 0.55-1.11s against the 1.5s ceiling, zero processes leaked. The
# ceiling never needed to move; the implementation and the experiment did.
#
# The peer path costs ZERO execs, by construction: reading 12 peer files is
# 0.66ms, while 12 subprocess execs is 373ms and can wedge indefinitely. Peers
# are files, and files are read.
#
# ---------------------------------------------------------------------------
# FAILURE IS NEVER SILENT
# ---------------------------------------------------------------------------
# Every section builds inside its own guard. A section that raises is replaced
# by an explicit "UNAVAILABLE (reason)" marker naming the section - never
# dropped. The predecessor wrapped the whole digest in a bare `except: pass`,
# so a boot that lost all of its fleet context was indistinguishable from a
# healthy one. Gate m5 freezes the replacement.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   FM_HOME                 the firstmate home to report on (default ~/firstmate)
#   FM_BOOT_FLEET_DIR       shared fleet view (default ~/.local/state/firstmate/fleet)
#   FM_BOOTSTRAP_BIN        helper dir; the stub seam gate m4 uses
#   FM_BOOT_TOTAL_BUDGET    seconds, default 1.5
#   FM_BOOT_HELPER_TIMEOUT  seconds, default 0.45
#   FM_CTX_INJECT_CAP       output ceiling in chars, default 10000
#   FM_BOOT_FORCE_FAIL      TEST SEAM. Comma-separated section names (or "all")
#                           forced to raise, so gate m5 can prove an unexpected
#                           exception is still visible. Never set in production.
#   FIRSTMATE_ROLE          captain|crew, as today. Role resolution is unchanged
#                           by this script: the activation-contract inversion is
#                           a separate, later change, and the tiering above is
#                           what makes that change affordable when it lands.
set -u

FM="${FM_HOME:-$HOME/firstmate}"
FM_BIN="${FM_BOOTSTRAP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Start the clock HERE, in the wrapper, not inside python. The ceiling is a
# wall-clock promise about the whole hook, and bash startup plus reading stdin
# plus starting a python interpreter is a real 0.25-0.35s of it (more on a cold
# page cache). A clock started after the interpreter is up cannot see that time,
# so the budget would silently overspend by exactly the amount it failed to
# measure - which is how this ceiling got breached in ~28% of hostile runs
# before the start moved out here.
#
# $EPOCHREALTIME is a bash 5 builtin, so the common path costs nothing at all.
# Some locales render it with a comma, hence the substitution. On bash 3.2 it is
# unset and we pay one interpreter start to get an honest number, which is still
# better than mis-measuring the budget.
FM_BOOT_START="${EPOCHREALTIME:-}"
FM_BOOT_START="${FM_BOOT_START/,/.}"
if [ -z "$FM_BOOT_START" ]; then
  FM_BOOT_START="$(python3 -c 'import time; print(time.time())' 2>/dev/null || echo 0)"
fi

# The hook payload arrives on stdin; the python program arrives on python's
# stdin via the heredoc, so the payload is handed over in the environment.
FM_HOOK_JSON="$(cat)" FM_BOOT_FM="$FM" FM_BOOTSTRAP_BIN="$FM_BIN" \
FM_BOOT_START="$FM_BOOT_START" python3 - <<'PY'
import os, sys, json, glob, time, signal, stat, subprocess

# The wrapper's start time, so the ceiling covers interpreter startup too. A
# missing or unusable value falls back to now, which only ever makes the budget
# more generous - never less - so a broken clock cannot cause a hard failure.
try:
    START = float(os.environ.get("FM_BOOT_START") or 0) or time.time()
except Exception:
    START = time.time()
if START > time.time() or START < time.time() - 60:
    START = time.time()

fm = os.environ["FM_BOOT_FM"]
bindir = os.environ.get("FM_BOOTSTRAP_BIN", "")
state = os.path.join(fm, "state")
data = os.path.join(fm, "data")

# Config notes raised while parsing the environment, surfaced in the output.
CONFIG_NOTES = []

# Set by build_fleet: the instance count it actually rendered. Empty when the
# fleet section could not be built at all.
FLEET_COUNT = []


def env_num(name, default, cast):
    """Parse a numeric env var, or keep the default and say so out loud.

    These are parsed at import time, outside the try/except around main(), so a
    bare float() here would take the whole hook down with a traceback and zero
    stdout - a boot that lost all its context while looking like nothing ran.
    That is precisely the failure this file exists to prevent, so a malformed or
    empty value degrades to the default and leaves a visible note instead.
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return cast(raw)
    except Exception:
        CONFIG_NOTES.append("%s=%r is not a number; using %s" % (name, raw, default))
        return default


TOTAL_BUDGET = env_num("FM_BOOT_TOTAL_BUDGET", 1.5, float)
HELPER_TIMEOUT = env_num("FM_BOOT_HELPER_TIMEOUT", 0.45, float)
INJECT_CAP = env_num("FM_CTX_INJECT_CAP", 10000, int)
FLEET_DIR = os.environ.get("FM_BOOT_FLEET_DIR") or os.path.join(
    os.path.expanduser("~"), ".local", "state", "firstmate", "fleet")

# A hostile or merely long field in a peer file must not be able to blow the
# injection cap. Tier 1 is deliberately uncapped so that no peer is ever elided;
# bounding each FIELD keeps that promise without letting one peer spend the
# whole budget.
PEER_ID_MAX = 40
PEER_WATCHER_MAX = 24

# Wall-clock held back from the helper phase, and the single number the ceiling
# actually rests on.
#
# The bound, stated so it can be checked rather than trusted:
#
#   total <= startup + granted_helper_time + post_deadline_cost
#   granted <= max(0, TOTAL_BUDGET - startup - RENDER_RESERVE)
#   => total <= TOTAL_BUDGET - RENDER_RESERVE + post_deadline_cost
#
# So the ceiling holds if and only if RENDER_RESERVE exceeds everything that
# happens AFTER the last deadline check: killing and reaping a wedged helper,
# rendering, serialising, and interpreter teardown. Startup cancels out - a cold
# start simply leaves less for helpers, and a very cold one skips them entirely.
#
# 0.3 was too tight. It held locally (worst of 15 wedged runs: 1.378s) and
# breached on a loaded machine, where an independent verifier measured 1.512s
# and 1.587s against the 1.5s ceiling on roughly 40% of runs. Post-deadline cost
# is what stretches under load, so the reserve has to cover its loaded value,
# not its idle one. 0.45 does, with the per-helper cap dropped to match so two
# helpers cannot consume the whole grant on a fast machine either.
RENDER_RESERVE = 0.45
# A helper granted less than this is not worth starting.
MIN_HELPER_SLICE = 0.05
# A peer file older than this renders as stale. Six watcher polls at 15s.
PEER_STALE_AFTER = 90
# Tier 2's share of the output cap. Tier 1 is never charged against it.
TIER2_CAP = 6000

DISCLAIMER = "Snapshot at boot - run bin/fm-wake-drain.sh before acting."


# --- the test seam ----------------------------------------------------------

class FmBootForcedFault(Exception):
    """Raised only by FM_BOOT_FORCE_FAIL, to prove failures stay visible."""


_FORCED = {s.strip() for s in (os.environ.get("FM_BOOT_FORCE_FAIL") or "").split(",") if s.strip()}


def check_forced(section):
    if section in _FORCED or "all" in _FORCED:
        raise FmBootForcedFault("forced fault in section '%s'" % section)


# --- budget -----------------------------------------------------------------

def remaining():
    """Seconds left before the ceiling, holding back the render reserve."""
    return TOTAL_BUDGET - (time.time() - START) - RENDER_RESERVE


# --- read-only primitives ---------------------------------------------------
#
# Every filesystem access in this script goes through these. None creates,
# truncates, moves, or removes anything, and there is deliberately no makedirs
# anywhere: a missing dir is reported, never created.
#
# THE DISTINCTION THAT MATTERS: "could not read it" is not "it is empty".
# Collapsing the two is the worst lie this block can tell, because the thing it
# would be lying about is whether there is anything to reconcile. A boot against
# a home that is absent, or whose state/ is unreadable, previously rendered
# "0 in flight / Wake queue: empty / In-flight tasks: none" with no marker at
# all - byte-identical to a genuinely idle, healthy home. Recovery keys off
# exactly those lines. So every read here returns its problem alongside its
# text, and a problem always becomes a visible UNAVAILABLE marker.

# Ceiling on any single file read. An operational file is orders of magnitude
# smaller; anything larger is a defect or an attack, and reading it whole would
# spend the boot deadline (a 512MB status file measured at 3.6s) or the memory.
# Truncation is reported, never silent.
READ_LIMIT = 256 * 1024


def safe_read(path):
    """(text, problem). Never blocks, and never truncates silently.

    A bare open() is not safe here, for two reasons that were both measured.

    IT CAN BLOCK FOREVER. open() on a FIFO waits for a writer. A FIFO named
    state/.wake-queue, state/<task>.meta or fleet/<peer>.json hung the whole
    hook until the harness killed it - over 30s against a 0.05s normal boot -
    injecting NOTHING, with no marker: the exact zero-context failure this file
    exists to prevent, and it defeats the budget entirely because the deadline
    only ever bounded subprocess helpers, never a blocking read. The fleet
    directory makes it worse than a local footgun: it is written by OTHER
    firstmate instances, so one bad entry there would blind every other
    captain's boot, permanently and silently.

    O_NONBLOCK makes the open itself return immediately even on a FIFO, and the
    fstat that follows rejects anything that is not a regular file. Checking
    with stat() BEFORE opening would leave a window in which the path could be
    swapped; opening first and inspecting the descriptor we actually hold does
    not.

    IT CAN TRUNCATE SILENTLY. Reading exactly READ_LIMIT bytes cannot tell a
    file that ends there from one that does not. A 400KB status file rendered
    with no marker and dropped its real last line - a `done:` - so the boot
    reported a finished task as still running. Confidently incomplete is the
    same lie as "unreadable is not empty". One byte past the limit is requested,
    and its presence is what proves truncation.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return "", None
    except Exception as e:
        return "", "%s unreadable (%s)" % (os.path.basename(path), type(e).__name__)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return "", "%s is not a regular file (%s)" % (
                os.path.basename(path), describe_mode(st.st_mode))
        chunks, got = [], 0
        while got <= READ_LIMIT:
            block = os.read(fd, min(65536, READ_LIMIT + 1 - got))
            if not block:
                break
            chunks.append(block)
            got += len(block)
    except Exception as e:
        return "", "%s unreadable (%s)" % (os.path.basename(path), type(e).__name__)
    finally:
        try:
            os.close(fd)
        except Exception:
            pass

    raw = b"".join(chunks)
    truncated = len(raw) > READ_LIMIT
    text = raw[:READ_LIMIT].decode("utf-8", "replace")
    if truncated:
        return text, "%s is larger than %dKB and was truncated; its last lines are NOT shown" % (
            os.path.basename(path), READ_LIMIT // 1024)
    return text, None


def describe_mode(mode):
    for flag, name in ((stat.S_ISFIFO, "FIFO"), (stat.S_ISDIR, "directory"),
                       (stat.S_ISSOCK, "socket"), (stat.S_ISCHR, "character device"),
                       (stat.S_ISBLK, "block device")):
        if flag(mode):
            return name
    return "not a regular file"


def read(path, limit=None):
    """Text, or an exception. Kept for callers that guard with try/except."""
    text, problem = safe_read(path)
    if problem:
        raise OSError(problem)
    return text


def read_field(path, default=""):
    """(text, problem). problem is None when read, or a short reason string.

    An absent file is NOT a problem - callers know whether absence is ordinary
    (no wake queue means an empty queue) or not. An unreadable file always is.
    """
    text, problem = safe_read(path)
    return (text if text else default), problem


def read_or(path, default="", limit=None):
    """Text only, for reads whose failure the caller reports separately."""
    text, _problem = safe_read(path)
    return text if text else default


def dir_problem(path, label):
    """None if the directory is present and listable, else a reason string.

    A missing or unlistable state/ or data/ means we know nothing about this
    home, which is a completely different statement from "this home is idle".
    """
    if not os.path.isdir(path):
        return "%s is absent (%s)" % (label, path)
    try:
        os.listdir(path)
    except Exception as e:
        return "%s is unreadable (%s)" % (label, type(e).__name__)
    return None


def helper(script, args, label):
    """One bounded, sanctioned exec. Returns its first line verbatim.

    The helper's own line is relayed as-is rather than re-derived here, so
    there is exactly one definition of what "the watcher is healthy" means.
    Every failure mode - missing, wedged, silent, crashed - returns an explicit
    marker; none returns something that could pass for a healthy reading.

    A wedged helper is killed as a PROCESS GROUP, not as a single process.
    Killing only the direct child leaves whatever it spawned running, reparented
    to init, for as long as that child wants - and a boot hook that leaks a
    process every time a helper wedges degrades the machine it runs on. Measured
    before this was fixed: two orphans per hostile boot, 194 of them accumulated
    across one afternoon of test runs, carrying the load average to 186 and
    slowing the very boots the budget gate was measuring. The gate was poisoning
    its own experiment, and the production path had the same leak.
    """
    slice_ = min(HELPER_TIMEOUT, remaining())
    if slice_ < MIN_HELPER_SLICE:
        return "UNAVAILABLE (%s: skipped, boot budget exhausted)" % label
    path = os.path.join(bindir, script)
    env = dict(os.environ)
    env["FM_HOME"] = fm
    # Helpers that source fm-wake-lib.sh create the state dir at source time.
    # Nothing reached from here may create anything, so opt out.
    env["FM_WAKE_LIB_READONLY"] = "1"
    try:
        # start_new_session puts the helper in its own process group, which is
        # what makes killing the whole tree possible below.
        proc = subprocess.Popen([path] + args, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=env,
                                start_new_session=True)
    except Exception as e:
        return "UNAVAILABLE (%s: %s)" % (label, type(e).__name__)
    try:
        out, _ = proc.communicate(timeout=slice_)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()
        # Reap and release the fds, but do NOT drain the pipes. The output is
        # not wanted - this returns UNAVAILABLE either way - and draining is
        # what makes cleanup expensive: communicate() reads until EOF, which
        # costs up to its own timeout PER wedged helper. At two helpers that was
        # 0.4s of pure waiting added after the deadline had already been spent,
        # and it is what pushed cold runs to 1.51-1.62s against a 1.5s ceiling.
        # SIGKILL to the group guarantees exit, so a short wait suffices.
        try:
            proc.wait(timeout=0.05)
        except Exception:
            pass
        for pipe in (proc.stdout, proc.stderr):
            try:
                pipe.close()
            except Exception:
                pass
        return "UNAVAILABLE (%s: no answer within %.2fs)" % (label, slice_)
    except Exception as e:
        return "UNAVAILABLE (%s: %s)" % (label, type(e).__name__)
    for line in (out or "").splitlines():
        if line.strip():
            return line.strip()
    return "UNAVAILABLE (%s: no output)" % label


def helpers(specs):
    """Run the sanctioned helpers CONCURRENTLY under ONE shared deadline.

    Serially, two helpers cost the sum of their timeouts; concurrently they cost
    the max. They are independent reads - a lock status and a watcher status -
    so there is no reason to pay the sum, and paying it is what pushed the tail
    of a wedged boot to 1.52-1.61s against a 1.5s ceiling on a loaded machine.
    The design named this option explicitly ("parallel helpers under a shared
    deadline"); it is taken here instead of shrinking the per-helper allowance,
    so a slow-but-alive helper keeps the same generosity it had before.

    The deadline is computed ONCE, before anything starts, and every helper is
    judged against that same wall-clock instant. Adding a third helper therefore
    costs nothing in elapsed time.
    """
    budget = min(HELPER_TIMEOUT, remaining())
    if budget < MIN_HELPER_SLICE:
        return dict((label, "UNAVAILABLE (%s: skipped, boot budget exhausted)" % label)
                    for _s, _a, label in specs)

    env = dict(os.environ)
    env["FM_HOME"] = fm
    # Helpers that source fm-wake-lib.sh create the state dir at source time.
    # Nothing reached from here may create anything, so opt out.
    env["FM_WAKE_LIB_READONLY"] = "1"

    deadline = time.time() + budget
    running, results = [], {}
    for script, args, label in specs:
        try:
            proc = subprocess.Popen([os.path.join(bindir, script)] + args,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, env=env, start_new_session=True)
            running.append((proc, label))
        except Exception as e:
            results[label] = "UNAVAILABLE (%s: %s)" % (label, type(e).__name__)

    for proc, label in running:
        left = deadline - time.time()
        # A helper that has ALREADY EXITED is not a timeout, whatever the clock
        # says. Results are collected in order, so a first helper that wedges to
        # the deadline would otherwise condemn a second one whose answer is
        # already sitting in the pipe - rendering a healthy watcher UNAVAILABLE
        # because the lock read was slow. Only a process still running when the
        # deadline passes is killed and marked.
        #
        # The floor is MIN_HELPER_SLICE, not merely a positive number: draining
        # an exited process's pipes under a sub-millisecond budget can still
        # raise TimeoutExpired on a loaded machine, which is the same false
        # degradation at a tighter margin.
        if proc.poll() is not None:
            left = max(left, MIN_HELPER_SLICE)
        try:
            if left <= 0:
                raise subprocess.TimeoutExpired(proc.args, budget)
            out, _ = proc.communicate(timeout=left)
        except subprocess.TimeoutExpired:
            reap(proc)
            results[label] = "UNAVAILABLE (%s: no answer within %.2fs)" % (label, budget)
            continue
        except Exception as e:
            reap(proc)
            results[label] = "UNAVAILABLE (%s: %s)" % (label, type(e).__name__)
            continue
        line = next((l.strip() for l in (out or "").splitlines() if l.strip()), "")
        results[label] = line or "UNAVAILABLE (%s: no output)" % label
    return results


def reap(proc):
    """Kill a helper's whole process group and release its fds, without draining.

    Killing only the direct child leaves whatever it spawned running, reparented
    to init - measured at two orphans per wedged boot, 194 live at once, load
    average 186. Draining the pipes afterwards with communicate() would cost up
    to its own timeout per helper; the output is unwanted, and SIGKILL to the
    group guarantees exit, so a short wait suffices.
    """
    # Target the group by the child's OWN pid. start_new_session makes the child
    # its own group leader, so pgid == pid, and using that directly removes a
    # race that os.getpgid() has: between fork and setsid the child still sits
    # in OUR group, so getpgid can return it and the kill would land on this
    # process instead of the helper. killpg(proc.pid) simply fails harmlessly if
    # the group does not exist yet.
    #
    # Then kill the direct child, wait, and sweep the group once more - the
    # second sweep catches a group that formed just after the first attempt,
    # which is the window that let roughly one boot in fifty orphan a process.
    for attempt in (1, 2):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass
        if attempt == 1:
            try:
                proc.kill()
            except Exception:
                pass
            try:
                proc.wait(timeout=0.05)
            except Exception:
                pass
    for pipe in (proc.stdout, proc.stderr):
        try:
            pipe.close()
        except Exception:
            pass


def section(name, build, *args):
    """Build one section, or an explicit marker saying why it could not be.

    This is the whole of the never-silent contract: a section is either its
    content or a marker naming itself and its reason. There is no path on which
    a section simply disappears.
    """
    try:
        check_forced(name)
        return build(*args)
    except Exception as e:
        return "## %s - UNAVAILABLE (%s: %s)" % (
            name, type(e).__name__, str(e)[:120] or "no detail")


# --- own-home facts ---------------------------------------------------------

def meta_of(path):
    """(meta, problem). A meta we could not read is not an empty meta.

    read_or() discards the reason, which would render the task with
    window=? kind=? mode=? and no explanation - degraded, and silent about it.
    """
    text, problem = safe_read(path)
    meta = {}
    for line in text.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            meta.setdefault(k.strip(), v.strip())
    return meta, problem


def own_tasks():
    """(tasks, problems) for every task this home is running.

    An unreadable state/ yields no tasks AND a problem, so the caller can never
    render "0 in flight" off a directory it could not read.
    """
    problem = dir_problem(state, "state/")
    if problem:
        return [], [problem]
    out, problems = [], []
    for mp in sorted(glob.glob(os.path.join(state, "*.meta"))):
        tid = os.path.basename(mp)[: -len(".meta")]
        status_text, status_problem = read_field(os.path.join(state, tid + ".status"))
        if status_problem:
            problems.append(status_problem)
        lines = [l for l in status_text.splitlines() if l.strip()]
        if status_problem:
            last = "UNAVAILABLE (%s)" % status_problem
        else:
            last = lines[-1] if lines else "(no status yet)"
        meta, meta_problem = meta_of(mp)
        if meta_problem:
            problems.append(meta_problem)
        out.append((tid, meta, last))
    return out, problems


def needs_attention(tasks):
    n = 0
    for _tid, _meta, last in tasks:
        head = last.split(":", 1)[0].strip().lower()
        if head in ("needs-decision", "blocked", "failed"):
            n += 1
    return n


def wake_queue():
    """Lock-free read of the wake queue.

    Never touches .wake-queue.lock: contending with the live watcher from
    inside a boot hook is worse than a slightly stale read. Torn-tail rule - a
    record counts only if the file ends in a newline and the line splits into
    at least five tab fields; a failing final line is excluded and flagged.

    Returns (depth, records, torn, problem). An ABSENT queue file genuinely
    means an empty queue and carries no problem; an UNREADABLE one is a problem
    and must never render as "empty".
    """
    path = os.path.join(state, ".wake-queue")
    if not os.path.exists(path):
        return 0, [], False, None
    # Through the safe primitive: a FIFO here hung the entire boot, and a queue
    # past the read limit would otherwise report a confident wrong depth.
    text, problem = safe_read(path)
    if problem:
        return 0, [], False, problem
    if not text:
        return 0, [], False, None
    rows = [r for r in text.split("\n") if r != ""]
    torn = False
    if rows and (not text.endswith("\n") or len(rows[-1].split("\t")) < 5):
        rows.pop()
        torn = True
    valid = [r for r in rows if len(r.split("\t")) >= 5]
    return len(valid), valid, torn, None


# --- steering ---------------------------------------------------------------

def ancestors():
    """(ran, pids, why) - whether the probe ACTUALLY ran, the pids, and if not, why.

    One `ps -eo pid=,ppid=` beats walking the chain with one exec per level,
    and it is bounded by the same deadline as every other exec here.

    The verdict matters more than the set. An empty set means the probe did not
    happen - the shared budget was spent, ps exited non-zero, or its output did
    not contain this process - and collapsing that into one falsy answer is
    what let a degraded boot claim another session was steering. The caller
    cannot recover the difference afterwards, so it is returned rather than
    inferred; ran=False is the only shape that carries "no evidence". Each way
    of not running names itself, because "unknown" is only actionable if the
    reader can tell a spent budget from a broken ps.
    """
    slice_ = min(HELPER_TIMEOUT, remaining())
    if slice_ < MIN_HELPER_SLICE:
        return False, set(), "the ancestry probe could not run within the boot budget"
    r = subprocess.run(["ps", "-eo", "pid=,ppid="], capture_output=True,
                       text=True, timeout=slice_)
    # A ps that exited non-zero did not answer. Without this the walk below
    # still yields our own pid, so an empty process table would read as "the
    # holder is not our ancestor" - an observing verdict built on no evidence,
    # which is the whole thing this pair exists to prevent.
    if r.returncode != 0:
        return False, set(), "the ancestry probe failed (ps exited %d)" % r.returncode
    parent = {}
    for line in (r.stdout or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            parent[int(parts[0])] = int(parts[1])
    # Nor did a ps whose output does not even contain THIS process: an ancestry
    # we are not in cannot be walked, and the one-element chain it would
    # produce is indistinguishable from a real answer.
    if os.getpid() not in parent:
        return False, set(), "the ancestry probe returned no chain for this process"
    seen, pid = set(), os.getpid()
    while pid in parent and pid > 1 and pid not in seen:
        seen.add(pid)
        pid = parent[pid]
    seen.add(pid)
    return True, seen, ""


def steering_state(lock_line):
    """(state, reason) where state is "steering", "observing", or "unknown".

    Free or stale lock: this session is about to take it. Held by a live
    harness: steering only if that pid is in our own ancestry (a resume,
    compact, or /clear inside the steering session).

    "unknown" is a third answer, not a shade of "observing". An unreadable lock
    and an ancestry probe that could not run are both cases where we have no
    evidence about who is steering; rendering "observing" there tells a resuming
    steering session to go ask itself. The lock path already refused that guess,
    and the probe path must refuse it the same way.
    """
    if lock_line.startswith("UNAVAILABLE"):
        # Unwrap the helper's own marker; the caller re-wraps it, and nesting
        # "UNAVAILABLE (UNAVAILABLE (...))" buries the reason a reader needs.
        detail = lock_line[len("UNAVAILABLE ("):-1] if lock_line.endswith(")") else lock_line
        return "unknown", detail
    if "free" in lock_line or "stale" in lock_line:
        return "steering", ""
    digits = "".join(c if c.isdigit() else " " for c in lock_line).split()
    if not digits:
        return "unknown", "the lock line names no holder pid"
    holder = int(digits[-1])
    try:
        ran, pids, why = ancestors()
    except Exception as e:
        return "unknown", "the ancestry probe failed (%s)" % type(e).__name__
    if not ran:
        return "unknown", why
    return ("steering" if holder in pids else "observing"), ""


# --- Tier 1: the fleet ------------------------------------------------------

def peer_line(path):
    """One line per peer. Never raises: a peer can only cost itself a marker."""
    name = os.path.basename(path)[: -len(".json")]
    try:
        age = time.time() - os.path.getmtime(path)
        # A peer file is written by ANOTHER instance, so it is the least
        # trustworthy input here: safe_read refuses a FIFO rather than letting
        # one foreign entry hang every other captain's boot.
        raw, problem = safe_read(path)
        if problem:
            return "- %-14s [UNAVAILABLE: %s]" % (clip(name, PEER_ID_MAX), problem)
        d = json.loads(raw)
        # A record that parses but lacks its required fields is not an idle
        # peer. Defaulting the counts to 0 would report live work as none -
        # the same defect one level down from an unreadable directory.
        missing = [f for f in ("in_flight", "needs_decision") if f not in d]
        if missing:
            return "- %-14s [UNAVAILABLE: record missing %s]" % (
                clip(str(d.get("id") or name), PEER_ID_MAX), ", ".join(missing))
        pid_ = clip(str(d.get("id") or name), PEER_ID_MAX)
        inflight = int(d.get("in_flight") or 0)
        decisions = int(d.get("needs_decision") or 0)
        watcher = clip(str(d.get("watcher") or "unknown"), PEER_WATCHER_MAX)
        if age > PEER_STALE_AFTER:
            watcher = "stale %s" % human_age(age)
        return "- %-14s [%d in flight, %d need a decision] watcher %s" % (
            pid_, inflight, decisions, watcher)
    except Exception:
        # Exactly one marker line. The peer is shown, never dropped: a missing
        # peer would silently shrink the fleet, which is the one thing Tier 1
        # must never do.
        return "- %-14s [unreadable]" % clip(name, PEER_ID_MAX)


def clip(text, limit):
    """Bound one rendered field. Peers are never elided; fields are."""
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def human_age(seconds):
    seconds = int(seconds)
    if seconds < 120:
        return "%ds" % seconds
    if seconds < 7200:
        return "%dm" % (seconds // 60)
    return "%dh" % (seconds // 3600)


def build_fleet(own_summary):
    """The fleet section. Three states, and they must not be conflated.

    An ABSENT fleet dir genuinely means there is no shared view yet - no writer
    exists for it, so that is today's ordinary condition and it says so plainly.
    An UNREADABLE one is a different statement entirely: peers may exist and we
    cannot see them, so reporting "no shared fleet view yet" would claim the
    fleet is just this home when we have no idea. That is the same lie as
    counting an unreadable state/ to zero, in the one section whose entire job
    is answering "what is the fleet doing".
    """
    peers, problem = [], None
    if os.path.exists(FLEET_DIR):
        problem = dir_problem(FLEET_DIR, "fleet view")
        if not problem:
            try:
                peers = sorted(glob.glob(os.path.join(FLEET_DIR, "*.json")))
            except Exception as e:
                problem = "fleet view is unreadable (%s)" % type(e).__name__

    lines = [own_summary] + [peer_line(p) for p in peers]
    # The one authoritative instance count. The injection-cap notice needs it
    # and must not recount "- " lines out of the finished block: registry lines,
    # secondmate entries, backlog items and per-task digest lines all share that
    # shape, so counting them would overstate the fleet in the very diagnostic a
    # reader uses to understand why the cap was breached.
    FLEET_COUNT.append(len(lines))
    head = "## Fleet (%d instance%s)" % (len(lines), "" if len(lines) == 1 else "s")
    tail = ["To act on another instance's work, ask it - do not reach into its home.",
            DISCLAIMER]
    if problem:
        tail.insert(0, "UNAVAILABLE (%s) - peers may exist that are not listed here; "
                       "this is NOT a report that the fleet is only this home." % problem)
    elif not peers:
        tail.insert(0, "(no shared fleet view yet - only this home is reported)")
    return "\n".join([head] + lines + tail)


# --- Tier 2: the steering detail --------------------------------------------

def project_lines():
    """(lines, problem). Generated one-liners, not a verbatim dump.

    The verbatim data/projects.md was 4,108 chars - 40% of the whole block, for
    information that is one line per project once the prose is trimmed.
    """
    text, problem = read_field(os.path.join(data, "projects.md"))
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        out.append(line[:110] + (" ..." if len(line) > 110 else ""))
    return out, problem


def build_digest(tasks, task_problems, watcher_line, lock_line):
    depth, records, torn, queue_problem = wake_queue()
    state_problem = dir_problem(state, "state/")
    lines = ["## Reconciliation digest (boot-time snapshot)"]

    # Every "nothing here" line below is only honest if we could actually look.
    if state_problem:
        lines.append("UNAVAILABLE (%s) - this home's live state could not be read, so "
                     "nothing below is a statement that there is nothing to reconcile."
                     % state_problem)
        lines.append(DISCLAIMER)
        return "\n".join(lines)

    if queue_problem:
        lines.append("Wake queue: UNAVAILABLE (%s)" % queue_problem)
    else:
        lines.append("Wake queue: %s" % ("empty" if depth == 0
                                         else "%d queued (most recent last)" % depth))
    lines += ["  " + r for r in records[-5:]]
    if depth > 5:
        lines.append("  ... (+%d more)" % (depth - 5))
    if torn:
        lines.append("  (tail possibly torn)")
    lines.append("Watcher: %s" % watcher_line)
    lines.append("Session lock: %s" % lock_line)
    # "none" is a claim about the fleet; only make it if every read succeeded.
    for p in task_problems:
        lines.append("UNAVAILABLE (%s)" % p)
    if task_problems:
        lines.append("In-flight tasks: %d readable (some task state could not be read)"
                     % len(tasks))
    else:
        lines.append("In-flight tasks: %s" % (len(tasks) or "none"))
    for tid, meta, last in tasks:
        lines.append("- %s window=%s kind=%s mode=%s - %s" % (
            tid, meta.get("window", "?"), meta.get("kind", "?"),
            meta.get("mode", "?"), last))
    lines.append("afk: %s" % ("yes" if os.path.exists(os.path.join(state, ".afk")) else "no"))
    return "\n".join(lines)


def build_tier2(tasks, task_problems, watcher_line, lock_line):
    problems = []
    data_problem = dir_problem(data, "data/")
    if data_problem:
        problems.append(data_problem)

    projects, projects_problem = project_lines()
    if projects_problem:
        problems.append(projects_problem)

    sm_text, sm_problem = read_field(os.path.join(data, "secondmates.md"))
    if sm_problem:
        problems.append(sm_problem)
    secondmates = [l for l in sm_text.splitlines() if l.strip().startswith("- ")]

    # The backlog is truncated for the block, and truncation is stated. Every
    # other capped path here counts what it dropped; this one used to take the
    # first 1,200 chars silently, which could cut a record mid-line and leave
    # the reader believing they had seen the whole queue.
    BACKLOG_CAP = 1200
    bl_text, bl_problem = read_field(os.path.join(data, "backlog.md"))
    if bl_problem:
        problems.append(bl_problem)
    if len(bl_text) > BACKLOG_CAP:
        head = bl_text[:BACKLOG_CAP]
        head = head[:head.rfind("\n") + 1] if "\n" in head else head
        backlog = head.rstrip() + ("\n... (+%d chars more - read %s/backlog.md)"
                                   % (len(bl_text) - len(head), data))
    else:
        backlog = bl_text.strip()

    parts = ["""## Spawn lifecycle (you are steering this home)
1. Register the project: a git repo at %s/projects/<name> plus one line in data/projects.md.
2. Brief:    bin/fm-brief.sh <id> <repo> [--scout | --secondmate <proj>...]
3. Vet:      bin/fm-intake.sh <id> <project-dir>      (ship briefs; spawn refuses without a proceed)
4. Spawn:    bin/fm-spawn.sh <id> <project-dir> [harness] [--scout|--secondmate]
5. Supervise: bin/fm-watch-arm.sh - peek bin/fm-peek.sh - steer bin/fm-send.sh
6. Verify:   bin/fm-verify.sh <id>  before accepting any done: claim
7. Teardown: bin/fm-teardown.sh <id>  only after the merge is confirmed""" % fm]

    # Anything we could not read is named before the sections that would
    # otherwise render its absence as "(none)".
    if problems:
        parts.append("## steering detail - UNAVAILABLE (%s)" % "; ".join(problems))

    parts.append(cap_list("## Registered projects", projects))
    parts.append(cap_list("## Secondmates", secondmates, empty="(none registered)"))
    if backlog:
        parts.append("## Recent backlog\n" + backlog)
    parts.append(section("digest", build_digest, tasks, task_problems,
                         watcher_line, lock_line))
    return "\n\n".join(parts)


def cap_list(header, items, empty="(none)", budget=1500):
    """Render a list under a char budget, counting anything dropped out loud.

    Per-task and per-project DETAIL may be elided this way. Peers may not - see
    build_fleet, which has no cap at all.
    """
    if not items:
        return header + "\n" + empty
    kept, used = [], 0
    for it in items:
        if used + len(it) + 1 > budget:
            break
        kept.append(it)
        used += len(it) + 1
    hidden = len(items) - len(kept)
    if hidden:
        kept.append("... (+%d more)" % hidden)
    return header + "\n" + "\n".join(kept)


# --- assemble ---------------------------------------------------------------

def role():
    """Unchanged from fm-captain-bootstrap.sh; this script does not move it."""
    hook = {}
    raw = os.environ.get("FM_HOOK_JSON", "")
    try:
        hook = json.loads(raw) if raw.strip() else {}
    except Exception:
        hook = {}
    cwd = hook.get("cwd") or os.environ.get("PWD", "")
    forced = (os.environ.get("FIRSTMATE_ROLE") or "").strip().lower()
    if forced in ("captain", "crew"):
        return forced
    return os.environ.get("FM_CTX_ROLE") or (
        "captain" if cwd in (os.environ.get("HOME", ""), fm) else "crew")


def main():
    if role() != "captain":
        return

    # Two different kinds of not-knowing, and they must not be conflated.
    #
    # STRUCTURAL: the home or its state/ could not be listed at all, so the
    # in-flight COUNT is unknown. Rendering "0 in flight" here is the most
    # consequential lie this block can tell - it says there is nothing to
    # reconcile, which is exactly what recovery keys off.
    #
    # DETAIL: state/ listed fine but one status file would not read. The count
    # is real; only that task's latest line is missing. Mark it, keep the fact.
    structural_problem = None
    if not os.path.isdir(fm):
        structural_problem = "home is absent (%s)" % fm
    else:
        structural_problem = dir_problem(state, "state/")

    tasks, task_problems = [], []
    try:
        tasks, task_problems = own_tasks()
    except Exception as e:
        structural_problem = structural_problem or (
            "state/ could not be read (%s)" % type(e).__name__)
    if structural_problem:
        task_problems = [structural_problem] + [
            p for p in task_problems if p != structural_problem]

    # The two sanctioned execs, in the order that matters: the lock line is
    # needed both for Tier 1 and to decide whether Tier 2 is owed at all.
    relayed = helpers([("fm-lock.sh", ["status"], "session lock"),
                       ("fm-watch-arm.sh", ["--status"], "watcher")])
    lock_line = relayed["session lock"]
    watcher_line = relayed["watcher"]

    steering, steering_reason = steering_state(lock_line)
    steering_word = "steering unknown" if steering == "unknown" else steering

    watcher_word = "unknown"
    if watcher_line.startswith("UNAVAILABLE"):
        watcher_word = "UNAVAILABLE"
    elif "healthy" in watcher_line:
        watcher_word = "healthy"
    elif "stale" in watcher_line:
        watcher_word = "stale"
    elif "none" in watcher_line:
        watcher_word = "none"

    own_name = os.path.basename(fm.rstrip("/")) or "primary"
    if structural_problem:
        # Counting to zero off a directory we could not read would be the most
        # consequential lie this block can tell: it says there is nothing to
        # reconcile, which is exactly what recovery keys off. When the home or
        # its state/ is unreadable the count is not degraded, it is UNKNOWN.
        own_summary = "- %-14s [UNAVAILABLE: %s] watcher %s  (this home)" % (
            own_name, structural_problem, watcher_word)
    else:
        # state/ listed fine, so the counts are real. A detail we could not
        # read degrades the detail and is marked, but does not discard a fact
        # we actually have.
        degraded = "" if not task_problems else " (+%d unreadable)" % len(task_problems)
        own_summary = "- %-14s [%d in flight, %d need a decision%s] watcher %s  (this home)" % (
            own_name, len(tasks), needs_attention(tasks), degraded, watcher_word)

    blocks = ["""# firstmate - fleet (injected at boot; no tool calls needed)
You are a firstmate. Home: %s (%s). Manual: %s/AGENTS.md""" % (
        fm, steering_word, fm)]

    # A misconfigured budget still boots, but never quietly.
    if CONFIG_NOTES:
        blocks.append("## boot config - UNAVAILABLE (%s)" % "; ".join(CONFIG_NOTES))

    # Tier 1. Never elided, never capped.
    blocks.append(section("fleet", build_fleet, own_summary))

    # Tier 2. Only for the session that is actually steering.
    if steering == "steering":
        tier2 = section("steering detail", build_tier2, tasks, task_problems,
                       watcher_line, lock_line)
        room = INJECT_CAP - len("\n\n".join(blocks)) - 200
        room = min(room, TIER2_CAP)
        if room > 0:
            if len(tier2) > room:
                tier2 = tier2[:room] + (
                    "\n... (+%d chars more - read the files directly)" % (len(tier2) - room))
            blocks.append(tier2)
        else:
            # Dropping Tier 2 outright is what keeps `out` under the cap, so the
            # injection-cap notice below can never fire for it: the two guards
            # are mutually exclusive. Without a marker here the steering session
            # loses its whole digest - wake queue, in-flight tasks, watcher,
            # lock - and the block still reads as healthy. That is precisely the
            # silent failure this file refuses.
            blocks.append("## steering detail - UNAVAILABLE (no room under the %d-char "
                          "injection cap; the spawn lifecycle, registered projects, "
                          "secondmates, backlog, and the reconciliation digest were all "
                          "dropped) - run bin/fm-wake-drain.sh and read %s/state directly."
                          % (INJECT_CAP, fm))
    elif steering == "unknown":
        # We do not KNOW who is steering - the lock would not read, or the
        # ancestry probe could not run. Saying another session is would be a
        # confident falsehood of exactly the kind this file exists to prevent,
        # and it is reachable, because a loaded machine can exhaust the helper
        # budget and skip either read entirely.
        blocks.append("## steering - UNAVAILABLE (%s) - could not determine whether "
                      "this session is steering; re-read the lock before acting."
                      % steering_reason)
    else:
        blocks.append("Another session is steering this home; "
                      "this one is observing. Ask it rather than acting.")

    out = "\n\n".join(blocks)

    # Two rules collide once the fleet is absurdly large: a peer is NEVER
    # elided, and the block stays under the injection cap. Below ~145 peers
    # there is no conflict at all - 12 peers costs ~1,000 chars, and Tier 2 is
    # dropped long before Tier 1 is at risk. Past that they genuinely cannot
    # both hold, and the peer rule wins: a session that cannot see a peer has
    # lost the one thing this block exists to give it, whereas an oversized
    # block is a degraded read, not a blind one. What must not happen is
    # choosing silently, so the choice is stated in the output.
    if len(out) > INJECT_CAP:
        instances = ("a fleet of %d" % FLEET_COUNT[-1] if FLEET_COUNT
                     else "a fleet of unknown size")
        out += ("\n\n## injection cap - UNAVAILABLE (%s needs %d chars against a "
                "cap of %d; every instance is listed anyway - a peer is never elided)" % (
                    instances, len(out), INJECT_CAP))

    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart", "additionalContext": out}}))


try:
    main()
except Exception as e:
    # Even a wholly failed build emits, and says why. A boot that lost its
    # context must never be indistinguishable from a healthy one.
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "# firstmate - boot context UNAVAILABLE (%s: %s)\n"
                             "Boot context could not be built. Run bin/fm-wake-drain.sh "
                             "and read state/ directly before acting." % (
                                 type(e).__name__, str(e)[:160])}}))
    sys.exit(0)
PY
