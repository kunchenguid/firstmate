#!/usr/bin/env python3
"""fm_voice_records.py - what the voice agent is allowed to know, and how it hands work over.

The voice agent answers status questions from firstmate's durable records and
queues everything else. This module owns both halves, because both halves are
where a mistake is expensive: one sends the captain's records to a model in
another region, and the other writes to firstmate's wake queue.

WHAT IS NEVER READ. Two whole classes of record are excluded at every scope,
not filtered at the end:

  Done history, because a spoken "what is happening" answer is about open work,
  and the finished items are where old engagements accumulate.
  Free-form note bodies under a task, because they are long, they are written
  for a reader with the whole file in front of them, and they are where
  commercial detail gets quoted.

Only open task lines and this home's own runtime records are ever assembled.
That is a confidentiality boundary as much as a brevity one. Verified on the
captain's live records on 2026-08-21: every occurrence of the one engagement
identifier those records contain sits in Done history or a note body, so
nothing in a full status answer named a customer. tests/fm-voice-relay.test.sh
holds that boundary as an executable check, so widening the reader later fails
the test rather than quietly widening what is sent.

Runtime records outlive the work they describe: a task keeps its state/<id>.meta
until teardown removes it, which happens separately from marking the item done.
Two readings here treat that differently, on purpose.

  Pull requests, the count and the list, cover OPEN ids only. They name work, and
  they feed the deny decision, which needs an open item to take a title from. A
  finished task's pull request is therefore not counted and not named, and that
  lost count is a deliberate cost: the alternative names finished work and puts
  it out of reach of the deny list, which has no title to match without an open
  item to take it from.

  The worker count and the state histogram cover every live runtime record,
  finished ids included, because a task with a meta file still on disk is still
  on deck and still needs tearing down. That is the question those two figures
  answer, and it is the same meaning bin/fm-inbox.sh gives "workers" in the human
  rendering. Neither can carry record free text: one is an integer, and the
  other's keys are the state verb folded through the closed set below.

READ SCOPE. config/voice-read-scope selects what a status answer may contain:

  counts (the default, and the value used when the file is absent)
      Counts, states and one basis note, with no record free text assembled at
      all. Safe by construction rather than by filtering: the agent can say how
      much is waiting without saying what it is. This is the default because a
      home that has configured nothing has granted nothing, and sending task
      identifiers, titles and pull request links to a model in another region is
      not something to inherit from somebody else's settings file.

  full
      Counts plus the identifiers, titles and pull request links of open work.
      A home widens to this by writing `full` into config/voice-read-scope,
      which is the access being granted deliberately by the captain whose
      records they are.

DENY LIST. config/voice-read-deny holds anything that must never leave this
host even in full scope: one plain case-insensitive substring per line, `#`
starts a comment, blank lines ignored. Substrings rather than regular
expressions, because a confidentiality list is the wrong place for a pattern
that can match more or less than it looks like it matches. Each open item is
matched once, against its identifier, its title, its tag values and its pull
request link together, and a match is then withheld from every list it could
have appeared in and reduced to a withheld count. One decision per item rather
than one per list, because an item named in any list is an item that left this
host. The agent still says how much is waiting without saying what it is. The
file is optional and an absent file means an empty list; it exists so that a
future open task carrying a customer name can be excluded in one line rather
than by turning the whole feature down.

WORKER STATE. This module reports the last recorded event verb, which is
history rather than a live check, and labels it that way in its own output so
the model cannot present it as current truth. bin/fm-crew-state.sh remains the
owner of real current-state reconciliation and is far too slow for a spoken
answer. The verb is folded through the closed STATE_VERBS vocabulary below, and
anything outside it becomes "note": a status line is free text, and this verb is
the only thing derived from a record that a counts-scope answer says out loud.

bin/fm-inbox.sh `status` is the human rendering of the same records and stays
the owner of that. This module exists because a spoken answer needs a machine
shape and a read scope that the human rendering has no reason to carry.

Usage:
  fm_voice_records.py status [--home <dir>] [--scope counts|full]
  fm_voice_records.py queue <text>... [--home <dir>]

Both subcommands print JSON, which is exactly what the relay hands to the model
as a tool result, so the shell form is the same interface the relay uses.
"""

import argparse
import json
import os
import re
import subprocess
import sys

SCOPE_COUNTS = "counts"
SCOPE_FULL = "full"
SCOPES = (SCOPE_FULL, SCOPE_COUNTS)
SCOPE_DEFAULT = SCOPE_COUNTS

BASIS = "Last recorded event, which is history and not a live check."

# A spoken answer names a few things and gives a count for the rest. Every row
# sent is input tokens the model reads before it starts speaking, and this whole
# build exists to keep that delay honest, so the lists are capped rather than
# complete. A complete list is a screen, not a sentence.
DETAIL_LIMIT = 5

ITEM = re.compile(r"^- \[(?P<done>[ x])\] (?P<id>\S+) - (?P<rest>.*)$")
TAG = re.compile(r"\((?P<key>[a-z-]+): (?P<value>[^)]*)\)")
# (since 2026-08-21) and (done 2026-08-21) carry no colon, so the tag pattern
# leaves them in the title. A date read aloud in the middle of a sentence is
# noise, so they come out too.
DATE_TAG = re.compile(r"\((?:since|done) [0-9-]+\)")

# The only backlog sections this module will parse. Done history is skipped
# before a line is even split, so widening the answer cannot reach it by
# accident. See "WHAT IS NEVER READ" above.
READ_SECTIONS = ("in flight", "queued")

# The states a worker is asked to report, and the two more that close a decision.
# bin/fm-brief.sh states the first six to every crewmate and bin/fm-classify-lib.sh
# owns resolved and captain-held; this module only recognises them.
#
# A CLOSED set, not a shape. A status line is free text appended by a crewmate,
# and the verb taken off the front of it is the one record-derived string that
# reaches a counts-scope answer, where there are no titles or links for a deny
# list to filter. So an unrecognised token is reported as a note instead of being
# spoken, exactly as a malformed one already was; otherwise a crewmate writing
# "acmecorp-migration: waiting on their review" would put that word in front of a
# model in another region, with nothing in config/voice-read-deny able to stop it.
STATE_VERBS = ("working", "needs-decision", "blocked", "paused", "done",
               "failed", "resolved", "captain-held")
NOTE_VERB = "note"

# Enough tail to hold the last line of a status log. These logs are append-only
# and grow for the life of a task, while every spoken question reads one per
# worker, so the read is bounded and seeks rather than scanning from the top.
STATUS_TAIL_BYTES = 8192


class RecordError(Exception):
    """The records or the read-scope configuration cannot be used as asked."""


def default_home():
    """Return the operational home, matching bin/fm-inbox.sh's resolution."""
    env = os.environ.get("FM_HOME")
    if env:
        return env
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def state_dir(home):
    """Return the runtime state directory, resolved as bin/fm-inbox.sh resolves it.

    fm-inbox.sh reads ${FM_STATE_OVERRIDE:-$FM_HOME/state}, and the handover
    below queues through fm-inbox.sh with the ambient environment. A reader that
    ignored the override would count notes in one directory while the queue wrote
    them to another, so the agent would tell the captain their request was queued
    and then, asked what is waiting, report nothing.
    """
    override = os.environ.get("FM_STATE_OVERRIDE")
    if override:
        return override
    return os.path.join(home, "state")


def data_dir(home):
    """Return the durable records directory, the other half of the same pair.

    Every script that sets FM_DATA_OVERRIDE for a child sets FM_STATE_OVERRIDE
    beside it, so resolving one and not the other would answer one question from
    two different homes: counts of workers and notes from the overridden state
    directory, counts of in-flight and queued work from the home's own backlog.
    A spliced answer is worse than a wrong one, because nothing about it looks
    wrong.
    """
    override = os.environ.get("FM_DATA_OVERRIDE")
    if override:
        return override
    return os.path.join(home, "data")


def config_dir(home):
    """Return the configuration directory, honouring the repo-wide override."""
    override = os.environ.get("FM_CONFIG_OVERRIDE")
    if override:
        return override
    return os.path.join(home, "config")


def _read_config(home, name):
    path = os.path.join(config_dir(home), name)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def read_setting(home, name, env=None):
    """Return a one-line setting from the environment or this home's config, else None.

    The values this feature needs, an AWS profile and a region and a model id,
    name somebody's account and somebody's choices. They belong to the home that
    runs the relay rather than to the repository, so they are read from gitignored
    config/ with an environment override and never carry a tracked default.
    """
    if env:
        value = (os.environ.get(env) or "").strip()
        if value:
            return value
    raw = _read_config(home, name)
    if raw is None:
        return None
    for line in raw.splitlines():
        text = line.split("#", 1)[0].strip()
        if text:
            return text
    return None


def require_setting(home, name, env, what):
    """Return a setting, or refuse naming the file to write and the variable to set."""
    value = read_setting(home, name, env)
    if value is None:
        raise RecordError(
            "no {} is configured: write one line into {} or set {}".format(
                what, os.path.join(config_dir(home), name), env))
    return value


def read_scope(home):
    """Return the configured read scope, defaulting to the narrowest one."""
    raw = _read_config(home, "voice-read-scope")
    if raw is None:
        return SCOPE_DEFAULT
    value = raw.strip()
    if not value:
        return SCOPE_DEFAULT
    if value not in SCOPES:
        raise RecordError(
            "config/voice-read-scope says {!r}; it must be one of {}".format(
                value, " or ".join(SCOPES)))
    return value


def deny_list(home):
    """Return the deny substrings; an absent file means an empty list."""
    raw = _read_config(home, "voice-read-deny")
    if raw is None:
        return []
    out = []
    for line in raw.splitlines():
        text = line.split("#", 1)[0].strip()
        if text:
            out.append(text.lower())
    return out


def _denied(denies, *fields):
    haystack = " ".join(f for f in fields if f).lower()
    return any(needle in haystack for needle in denies)


def _parse_backlog(path):
    """Return (section, item) pairs for every task line in the backlog."""
    items = []
    section = ""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return items
    for line in lines:
        if line.startswith("## "):
            section = line[3:].strip().lower()
            continue
        if section not in READ_SECTIONS:
            continue
        match = ITEM.match(line)
        if not match:
            continue
        rest = match.group("rest")
        tags = {m.group("key"): m.group("value") for m in TAG.finditer(rest)}
        title = re.sub(r"\s+", " ", DATE_TAG.sub("", TAG.sub("", rest))).strip()
        items.append({
            "section": section,
            "id": match.group("id"),
            "title": title,
            "done": match.group("done") == "x",
            "tags": tags,
        })
    return items


def _last_event(state_dir, task_id):
    """Return (verb, line) from the last status event, or (None, None).

    The verb is what precedes the first ':' and the first '[', whichever comes
    first, which is what status_line_verb in bin/fm-classify-lib.sh does and
    that remains the owner of the format. The bracket matters: status metadata
    sits between the verb and the colon, as in "done [token]: shipped it" and
    "needs-decision [key=api-shape]: which shape". A line carrying no colon is
    not a status line, and any token outside STATE_VERBS is reported as a note
    rather than spoken aloud as a state.

    Only the tail of the log is read; see STATUS_TAIL_BYTES.
    """
    path = os.path.join(state_dir, task_id + ".status")
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - STATUS_TAIL_BYTES))
            window = handle.read()
    except OSError:
        return None, None
    lines = [text.strip() for text in
             window.decode("utf-8", errors="replace").splitlines() if text.strip()]
    if not lines:
        return None, None
    line = lines[-1]
    verb = NOTE_VERB
    if ":" in line:
        verb = line.split(":", 1)[0].split("[", 1)[0].strip().lower()
    if verb not in STATE_VERBS:
        verb = NOTE_VERB
    return verb, line


def _workers(state_dir):
    """Return one record per task with runtime metadata in this home."""
    out = []
    try:
        names = sorted(n for n in os.listdir(state_dir) if n.endswith(".meta"))
    except OSError:
        return out
    for name in names:
        task_id = name[: -len(".meta")]
        meta = {}
        try:
            with open(os.path.join(state_dir, name), encoding="utf-8") as handle:
                for line in handle:
                    if "=" in line:
                        key, value = line.rstrip("\n").split("=", 1)
                        meta[key] = value
        except OSError:
            continue
        verb, line = _last_event(state_dir, task_id)
        out.append({
            "id": task_id,
            "kind": meta.get("kind", ""),
            "mode": meta.get("mode", ""),
            "pr": meta.get("pr", ""),
            "verb": verb or "no events yet",
            "line": line or "",
        })
    return out


def fleet_status(home=None, scope=None):
    """Return the status answer the voice agent is allowed to give."""
    home = home or default_home()
    scope = scope or read_scope(home)
    if scope not in SCOPES:
        raise RecordError("unknown read scope: {!r}".format(scope))
    denies = deny_list(home)

    state = state_dir(home)
    workers = _workers(state)
    items = _parse_backlog(os.path.join(data_dir(home), "backlog.md"))

    open_items = [i for i in items if not i["done"]]
    in_flight = [i for i in open_items if i["section"] == "in flight"]
    queued = [i for i in open_items if i["section"] == "queued"]
    # "What is waiting on me" is the union of decisions filed for the captain
    # and anything explicitly held for them. The two overlap but neither
    # contains the other, because a decision can be filed before it is held.
    held_for_captain = [
        i for i in open_items
        if i["tags"].get("hold-kind") == "captain"
        or i["tags"].get("kind") == "captain"
    ]
    # OPEN work only. _workers lists every state/*.meta in the home, and a task
    # keeps its meta after it is marked done until teardown removes it, so taking
    # every worker with a pull request would count and name finished tasks. That
    # breaks the promise at the top of this file twice over: it reads finished
    # work, and the deny decision below cannot reach those items, because their
    # ids have no open item to supply a title, so a captain substring matching a
    # title would silently fail for exactly them. Losing the count of a pull
    # request on a task already marked done is the accepted cost.
    open_ids = {i["id"] for i in open_items}
    with_pr = [w for w in workers if w["pr"] and w["id"] in open_ids]

    inbox = os.path.join(state, "inbox")
    try:
        waiting = len([n for n in os.listdir(inbox) if n.endswith(".note")])
    except OSError:
        waiting = 0

    states = {}
    for worker in workers:
        states[worker["verb"]] = states.get(worker["verb"], 0) + 1

    answer = {
        "scope": scope,
        "basis": BASIS,
        "workers_on_deck": len(workers),
        "worker_states": states,
        "in_flight": len(in_flight),
        "queued": len(queued),
        "awaiting_captain": len(held_for_captain),
        "open_pull_requests": len(with_pr),
        "captain_notes_waiting": waiting,
    }
    if scope == SCOPE_COUNTS:
        answer["detail"] = (
            "Identifiers, titles and pull request links are withheld at this "
            "read scope. Say that the detail is not available by voice rather "
            "than guessing at it.")
        return answer

    by_id = {w["id"]: w for w in workers}

    # ONE deny decision per item, taken over everything known about that item
    # before any list is built, and then shared by every list it could appear
    # in. The lists overlap by design: a task can be in flight, waiting on the
    # captain and carrying a pull request at once. Deciding per list, from the
    # fields that list happens to use, would withhold an item from one list and
    # name it in another, which is not a narrower answer but a leak with a
    # reassuring count beside it. It also makes the count what it says it is,
    # distinct items rather than refusals.
    #
    # The fields come from every OPEN item, not only the ones a list iterates. A
    # queued item that is not held for the captain still reaches the answer
    # through its pull request link, and assembling its fields only where a list
    # walks past it is how a title match gets missed on exactly that item. What
    # is COUNTED is narrower: an item that no list could have named is not
    # something the captain is having withheld.
    known = {}
    for item in open_items:
        known.setdefault(item["id"], item)
    nameable = ({i["id"] for i in in_flight} | {i["id"] for i in held_for_captain}
                | {w["id"] for w in with_pr})

    withheld_ids = set()
    for item_id in nameable:
        item = known.get(item_id)
        worker = by_id.get(item_id)
        fields = [item_id]
        if item is not None:
            fields.append(item["title"])
            fields.extend(item["tags"].values())
        if worker is not None:
            fields.append(worker["pr"])
        if _denied(denies, *fields):
            withheld_ids.add(item_id)

    def keep(item_id):
        return item_id not in withheld_ids

    detail_in_flight = []
    for item in in_flight:
        if not keep(item["id"]):
            continue
        worker = by_id.get(item["id"])
        detail_in_flight.append({
            "id": item["id"],
            "title": item["title"],
            # The state word only, never the raw event line. The agent speaks to
            # the captain and must not read internal record text aloud.
            "state": worker["verb"] if worker else "not started",
        })

    detail_captain = []
    for item in held_for_captain:
        if not keep(item["id"]):
            continue
        detail_captain.append({"id": item["id"], "title": item["title"]})

    detail_prs = []
    for worker in with_pr:
        if not keep(worker["id"]):
            continue
        detail_prs.append({"id": worker["id"], "url": worker["pr"]})

    def capped(rows, key):
        answer[key] = rows[:DETAIL_LIMIT]
        if len(rows) > DETAIL_LIMIT:
            answer[key + "_not_listed"] = len(rows) - DETAIL_LIMIT

    capped(detail_in_flight, "in_flight_detail")
    capped(detail_captain, "awaiting_captain_detail")
    capped(detail_prs, "pull_request_detail")
    answer["withheld_as_confidential"] = len(withheld_ids)
    answer["detail"] = (
        "The lists name at most {} items each; the counts above are the whole "
        "picture. Give the captain the counts and a couple of names, not every "
        "row.".format(DETAIL_LIMIT))
    return answer


def queue_request(text, home=None, root=None):
    """Hand real work to firstmate through bin/fm-inbox.sh note."""
    home = home or default_home()
    root = root or os.path.dirname(os.path.abspath(__file__))
    body = (text or "").strip()
    if not body:
        raise RecordError("refusing to queue an empty request")
    inbox = os.path.join(root, "fm-inbox.sh")
    if not os.access(inbox, os.X_OK):
        raise RecordError("cannot run {}".format(inbox))
    env = dict(os.environ, FM_HOME=home)
    done = subprocess.run(
        [inbox, "note", body],
        # The relay's stdin is the captain's audio when this runs under
        # --serve, and fm-inbox.sh reads a body from stdin for an argument of
        # "-", so no child of the relay is given that stream to consume.
        stdin=subprocess.DEVNULL,
        env=env, capture_output=True, text=True, timeout=30, check=False)
    if done.returncode != 0:
        raise RecordError("fm-inbox.sh note failed: {}".format(
            (done.stderr or done.stdout).strip()))
    note_id = ""
    for line in done.stdout.splitlines():
        if line.startswith("queued "):
            note_id = line.split(None, 1)[1].strip()
            break
    return {
        "queued": True,
        "note_id": note_id,
        "queued_text": body,
        "handover": "Firstmate now owns this request and will pick it up at "
                    "its next check. You did not do the work yourself.",
    }


def main(argv):
    parser = argparse.ArgumentParser(
        prog="fm_voice_records.py", description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="print the allowed status answer")
    status.add_argument("--home")
    status.add_argument("--scope", choices=SCOPES)

    queue = sub.add_parser("queue", help="hand a request to firstmate")
    queue.add_argument("text", nargs="+")
    queue.add_argument("--home")

    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            result = fleet_status(home=args.home, scope=args.scope)
        else:
            result = queue_request(" ".join(args.text), home=args.home)
    except RecordError as exc:
        sys.stderr.write("fm_voice_records: {}\n".format(exc))
        return 2
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
