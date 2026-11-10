#!/usr/bin/env python3
"""fm-hold-scan.py - deterministic classifier for tasks held for the captain.

Layer 1 of the decider lane. No model, no tokens, no network: it reads the
active home's backlog, extracts every active captain hold, and classifies each
one on two independent axes. Every row carries the rule that fired, so a bad
classification is visible and fixable rather than silent.

Axis 1 - readiness. Is the deliverable finished with one captain act left, or
is work still owed?

  ready    the reason describes a finished artifact plus one captain act
  work     the reason describes work still owed
  unknown  neither pattern fired; the lane must resolve it by reading the task

Axis 2 - class. Is the remaining act the captain's alone (Class B), or is it
the fleet's to decide (Class A)?

  B  the closed Class B list: new spend or a vendor contract; logins or
     credentials only the captain holds; legal signatures or sends under his
     name; irreversible customer-data destruction; a security change judged
     risky. The rule table is deliberately biased toward B: a false B costs one
     digest line, a false A sends the captain's own call to the fleet.
  A  everything else, which the lane rules and executes.

A hold also carries a `hold-until` date when it was set as a time gate. A hold
whose date has passed is expired, not live: the gate opened and nobody walked
through it. Expired holds are excluded by default because counting them inflates
the queue and would have the lane rule items that are no longer held; pass
--include-expired to see them. A `hold-kind: future` hold is a dated reminder
rather than a captain call, so it is Class A with rule `dated-reminder`.

The rule table is data, not code. Widening or narrowing Class B is a reviewed
diff to CLASS_B_RULES below, never a runtime decision.

Usage:
  fm-hold-scan.py [--backlog PATH] [--json | --summary] [--class A|B]
                  [--readiness ready|work|unknown] [--ids]

  --json       one JSON object per line, oldest hold first (default)
  --summary    one-line counts plus per-rule and per-readiness breakdowns
  --class      keep only rows of that class
  --readiness  keep only rows of that readiness
  --ids        print only the matching task ids, one per line
  --include-expired  also report holds whose hold-until date has passed

The backlog path defaults to $FM_DATA_OVERRIDE/backlog.md when that variable is
set, else $FM_HOME/data/backlog.md, else the repo's own data/backlog.md, which
is how every other firstmate script resolves the active home.

Exit status is 0 whether or not any hold exists; a scan that finds nothing is a
valid answer, not a failure. Exit 2 means the backlog could not be read.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ordered: the first matching rule wins, so a money or legal item that also
# happens to say "ruled" stays Class B.
CLASS_B_RULES: list[tuple[str, re.Pattern[str]]] = [
    (
        "money",
        re.compile(
            r"\$\s?\d|\bdollars?\b|\bmoney\b|\bspend\b|\bprocure\b|\brefund\b"
            r"|\bprice\b|\bpricing\b|\bbudget\b|\binvoice\b|\bcharge\b"
            r"|\btop[- ]?up\b|\brenew\b|\bper month\b|\b/mo\b"
            r"|\border (?:the|a|both|one|new)\b|\bnew spend\b"
            r"|\b\d[\d,]*\s?(?:USD|EUR|GBP|dollars?)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "legal",
        re.compile(
            r"\blegal\b|\bcounsel\b|\bletter\b|\bsignature\b|\bsign[- ]?off\b"
            r"|\bsigned\b|\bterms\b|\bprivacy policy\b|\bDMCA\b|\bC&D\b"
            r"|\blawsuit\b|\battorney\b|\bformal request\b|\bdisclosure\b",
            re.IGNORECASE,
        ),
    ),
    (
        "secrets",
        re.compile(
            r"\bsecret\b|\bapi key\b|\brotate\b|\brekey\b|\bcredential\b"
            r"|\bpassword\b|\bunseal\b|\broot token\b",
            re.IGNORECASE,
        ),
    ),
    (
        "destructive",
        re.compile(
            r"\bdelete\b|\bdestroy\b|\berase\b|\bpurge\b|\bGDPR\b|\berasure\b"
            r"|\bdrop table\b|\birreversible\b|\bhard delete\b|\bwipe\b",
            re.IGNORECASE,
        ),
    ),
    (
        "customer-facing",
        re.compile(
            r"\bcustomer copy\b|\buser-facing copy\b|\bemail to\b"
            r"|\bsend (?:the )?(?:email|note|message|notice)\b|\bannounce\b"
            r"|\bnotify (?:all|every|users|customers)\b|\bmarketing copy\b"
            r"|\bemails? (?:real )?(?:customers|users)\b"
            r"|\b(?:users|customers) (?:are|will be) (?:told|notified|emailed)\b"
            r"|\bcopy block\b|\bclosing-explanation copy\b|\bapproved copy\b"
            r"|\bnew copy\b|\bnotices?\b|\bwording\b|\bverbatim text\b"
            r"|\bfeedback drafts?\b|\bsend\b[^.;]{0,60}\b(?:notes?|drafts?)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "edge",
        re.compile(
            r"\bcloudflare\b|\bDNS\b|\bWAF\b|\bfirewall\b|\bzone\b",
            re.IGNORECASE,
        ),
    ),
    (
        # An explicit captain instruction, or a switch the record names as his,
        # is the captain's even when the surrounding work is ordinary. Kept
        # narrow on purpose: "the captain's standing grant covers this" is a
        # grant the fleet already holds, not a call it must return.
        "captain-instruction",
        re.compile(
            r"\bcaptain said\b|\bwaiting on aaron\b|\bonly aaron\b"
            r"|\bdo not (?:merge|turn it on|enable|deploy|send)\b"
            r"|\bare the captain'?s\b|\bcaptain'?s call\b"
            r"|\bcaptain'?s to (?:decide|own|make)\b"
            r"|\bnames the captain as owner\b",
            re.IGNORECASE,
        ),
    ),
    (
        "his-accounts",
        re.compile(
            r"\bclick\b|\bconsole\b|\bdashboard\b|\blog ?in\b|\bsign ?in\b"
            r"|\bbrowser\b|\bworkspace admin\b|\bgoogle admin\b"
            r"|\bstripe dashboard\b|\bnamed human\b|\bapproval_ref\b"
            r"|\brecorded approval\b|\byour (?:recorded )?approval\b"
            r"|\bphone (?:number|no)\b|\bcontact info\b",
            re.IGNORECASE,
        ),
    ),
]

# A hold whose reason already carries a ruling is pure cleanup: the decision is
# made and only the unhold is owed. Checked after the Class B table so a money
# or legal item that says "ruled" is still the captain's.
ALREADY_DECIDED = re.compile(
    r"\bapproved\b.*\bby fable\b|\bfable (?:go|approved|ruled)\b|\bruled\b"
    r"|\bruling\b|\bdecided\b",
    re.IGNORECASE,
)

WORK_REMAINS = re.compile(
    r"\bneeds? to\b|\bmust (?:be|still)\b|\bnot yet\b|\bin progress\b"
    r"|\bto be built\b|\bwe need\b|\bstill (?:open|running|failing|red)\b"
    r"|\bunbuilt\b|\bnot started\b|\bblocked on\b"
    r"|\bwaiting on (?:a|the) (?:build|fix|pr|deploy)\b",
    re.IGNORECASE,
)

WORK_DONE = re.compile(
    r"\bbuilt\b|\bgreen\b|\bmerged\b|\bready\b|\bdrafted\b|\bmeasured\b"
    r"|\bcomplete\b|\bdeployed\b|\bverified\b|\boptions?\s*:",
    re.IGNORECASE,
)

QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")

TASK_RE = re.compile(r"^- \[[ x]\] (?P<id>[A-Za-z0-9._-]+) - (?P<rest>.*)$")
HOLD_RE = re.compile(
    r"\(hold: (?P<reason>.*?)\) \(hold-kind: (?P<kind>[a-z]+)\)"
)
SET_RE = re.compile(r"^\s+Captain hold set: (?P<ts>[0-9T:Z.+-]+)")
UNTIL_RE = re.compile(r"\(hold-until: (?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\)")


def default_backlog() -> Path:
    override = os.environ.get("FM_DATA_OVERRIDE")
    if override:
        return Path(override) / "backlog.md"
    home = os.environ.get("FM_HOME")
    if home:
        return Path(home) / "data" / "backlog.md"
    return Path(__file__).resolve().parent.parent / "data" / "backlog.md"


def classify_class(reason: str, hold_kind: str = "") -> tuple[str, str]:
    """Return (class, rule) for a hold reason.

    Class B is checked first so a money or legal item stays the captain's even
    when it also reads as already decided or as a dated reminder.
    """
    for name, pattern in CLASS_B_RULES:
        if pattern.search(reason):
            return "B", name
    if ALREADY_DECIDED.search(reason):
        return "A", "already-decided"
    if hold_kind == "future":
        return "A", "dated-reminder"
    return "A", "no-class-b-rule"


def classify_readiness(reason: str) -> str:
    """Return ready, work, or unknown for a hold reason.

    Position decides when both patterns fire, because English puts the state
    before the ask: "needs to be built" is work, while "built and green, needs
    your click" is ready. Whichever pattern appears first describes the item.
    """
    # A quoted option value ("say 'not yet'") describes a choice, not the state
    # of the work, so it must not decide readiness.
    unquoted = QUOTED_RE.sub(" ", reason)
    remains = WORK_REMAINS.search(unquoted)
    done = WORK_DONE.search(unquoted)
    if remains and done:
        return "work" if remains.start() < done.start() else "ready"
    if remains:
        return "work"
    if done:
        return "ready"
    return "unknown"


def parse_age(hold_set_at: str | None, now: datetime) -> float | None:
    if not hold_set_at:
        return None
    text = hold_set_at.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return round((now - stamp).total_seconds() / 86400.0, 1)


def scan(backlog: Path, include_expired: bool = False) -> list[dict]:
    try:
        lines = backlog.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        print(f"fm-hold-scan: cannot read {backlog}: {exc}", file=sys.stderr)
        raise SystemExit(2)

    now = datetime.now(timezone.utc)
    rows: list[dict] = []
    current: dict | None = None

    for line in lines:
        task = TASK_RE.match(line)
        if task:
            current = {"id": task.group("id"), "rest": task.group("rest")}
            hold = HOLD_RE.search(task.group("rest"))
            if hold:
                rows.append(_row(current, hold, now))
            continue
        if current is None:
            continue
        hold = HOLD_RE.search(line)
        if hold:
            rows.append(_row(current, hold, now))
            continue
        stamp = SET_RE.match(line)
        if stamp and rows and rows[-1]["id"] == current["id"]:
            rows[-1]["hold_set_at"] = stamp.group("ts")
            rows[-1]["age_days"] = parse_age(stamp.group("ts"), now)

    if not include_expired:
        rows = [r for r in rows if not r["expired"]]
    rows.sort(key=lambda r: (r["age_days"] is None, -(r["age_days"] or 0.0)))
    return rows


def _row(task: dict, hold: re.Match[str], now: datetime) -> dict:
    reason = hold.group("reason")
    kind = hold.group("kind")
    klass, rule = classify_class(reason, kind)
    until = UNTIL_RE.search(task["rest"])
    hold_until = until.group("date") if until else None
    return {
        "id": task["id"],
        "class": klass,
        "rule": rule,
        "readiness": classify_readiness(reason),
        "hold_kind": kind,
        "hold_set_at": None,
        "hold_until": hold_until,
        "expired": bool(hold_until and hold_until < now.strftime("%Y-%m-%d")),
        "age_days": None,
        "title": task["rest"][:160],
        "reason": reason[:2000],
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-hold-scan.py",
        description="Classify every task held for the captain by readiness and class.",
    )
    parser.add_argument("--backlog", type=Path, default=None)
    parser.add_argument("--json", action="store_true", help="JSONL output (default)")
    parser.add_argument("--summary", action="store_true", help="counts only")
    parser.add_argument("--class", dest="klass", choices=["A", "B"])
    parser.add_argument(
        "--readiness", choices=["ready", "work", "unknown"]
    )
    parser.add_argument("--ids", action="store_true", help="print ids only")
    parser.add_argument(
        "--include-expired",
        action="store_true",
        help="also report holds whose hold-until date has passed",
    )
    args = parser.parse_args(argv)

    rows = scan(args.backlog or default_backlog(), args.include_expired)
    if args.klass:
        rows = [r for r in rows if r["class"] == args.klass]
    if args.readiness:
        rows = [r for r in rows if r["readiness"] == args.readiness]

    if args.ids:
        for row in rows:
            print(row["id"])
        return 0

    if args.summary:
        class_a = sum(1 for r in rows if r["class"] == "A")
        print(f"held={len(rows)} class_a={class_a} class_b={len(rows) - class_a}")
        rules: dict[str, int] = {}
        for row in rows:
            if row["class"] == "B":
                rules[row["rule"]] = rules.get(row["rule"], 0) + 1
        for name, count in sorted(rules.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  rule {name}={count}")
        readiness: dict[str, int] = {}
        for row in rows:
            readiness[row["readiness"]] = readiness.get(row["readiness"], 0) + 1
        for name in ("ready", "work", "unknown"):
            if name in readiness:
                print(f"  readiness {name}={readiness[name]}")
        missing = sum(1 for r in rows if r["age_days"] is None)
        if missing:
            print(f"  missing_hold_timestamp={missing}")
        expired = sum(1 for r in rows if r["expired"])
        if expired:
            print(f"  expired={expired}")
        return 0

    for row in rows:
        print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
