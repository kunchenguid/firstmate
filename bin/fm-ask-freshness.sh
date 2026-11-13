#!/usr/bin/env bash
# fm-ask-freshness.sh - the freshness gate for a captain ask drawn from a
# triage list: before a row of a report is put to the captain, prove that what
# the row says was checked recently enough to still be true.
#
# Usage: fm-ask-freshness.sh <report.md> [--column <name>] [--max-age <duration>]
#        fm-ask-freshness.sh -h | --help
#
# Reads every markdown table in <report.md> (a header row, a `|---|` separator
# row, then body rows) and checks each table whose header has the timestamp
# column, matched case-insensitively with surrounding backticks or emphasis
# ignored. A table's body runs to the next blank line, so a row with no outer
# pipes or fewer cells than the header is still checked, and a missing
# timestamp cell is unreadable. Every table must have that column: a table
# without it holds rows nobody dated, so each such table is named on stderr
# and the report is an input error, as is a report with no table or no row.
#
#   --column <name>       timestamp column (default checked_at)
#   --max-age <duration>  oldest acceptable age (default 2h): a whole number of
#                         seconds, or one or more <n><unit> parts with units
#                         s, m, h, d, such as 90m or 1h30m
#
# A timestamp is ISO 8601 date and time (`2026-11-13T09:30Z`,
# `2026-11-13T09:30:00+01:00`, seconds and fractions optional) or
# `YYYY-MM-DD HH:MM[:SS]`. A value with no Z or offset is read in the local
# timezone (TZ). A date with no time, an empty cell, an offset beyond 23:59,
# or any other shape is unreadable, and so is a time more than five minutes
# in the future.
#
# Prints every checked row with its age, then exits:
#   0  every checked row is within --max-age
#   1  at least one row is older than --max-age or has an unreadable timestamp;
#      those rows are named again on stderr - re-check them rather than
#      presenting them
#   2  usage error, unreadable report, no table, no body row, or a table
#      without the timestamp column
#
# The report is only read, never edited. Requires python3.
#
# Environment:
#   FM_ASK_FRESHNESS_NOW  epoch seconds to measure ages from (default: now);
#                         for tests
set -eu

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {  # <message>
  echo "error: $1" >&2
  echo "usage: fm-ask-freshness.sh <report.md> [--column <name>] [--max-age <duration>]" >&2
  exit 2
}

REPORT=
COLUMN=checked_at
MAX_AGE=2h
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --column)
      [ "$#" -ge 2 ] || die_usage "--column requires a value"
      COLUMN=$2; shift 2 ;;
    --column=*) COLUMN=${1#--column=}; shift ;;
    --max-age)
      [ "$#" -ge 2 ] || die_usage "--max-age requires a value"
      MAX_AGE=$2; shift 2 ;;
    --max-age=*) MAX_AGE=${1#--max-age=}; shift ;;
    -*) die_usage "unexpected option '$1'" ;;
    *)
      [ -z "$REPORT" ] || die_usage "unexpected argument '$1'"
      REPORT=$1; shift ;;
  esac
done
[ -n "$REPORT" ] || die_usage "a report path is required"
[ -n "$COLUMN" ] || die_usage "--column requires a non-empty value"
[ -f "$REPORT" ] && [ -r "$REPORT" ] || { echo "error: report '$REPORT' is not a readable file" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required to read the report's timestamps" >&2; exit 2; }

NOW=${FM_ASK_FRESHNESS_NOW:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "error: FM_ASK_FRESHNESS_NOW must be epoch seconds" >&2; exit 2 ;;
esac

exec python3 - "$REPORT" "$COLUMN" "$MAX_AGE" "$NOW" <<'PY'
import re
import sys
from datetime import datetime, timedelta, timezone

report, column, max_age_text, now_text = sys.argv[1:5]
now = int(now_text)
FUTURE_SKEW = 300


def die(message):
    sys.stderr.write("error: %s\n" % message)
    sys.exit(2)


def parse_duration(text):
    if re.fullmatch(r"[0-9]+", text):
        return int(text)
    parts = re.findall(r"([0-9]+)([smhd])", text)
    if not parts or "".join(n + u for n, u in parts) != text:
        return None
    scale = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return sum(int(n) * scale[u] for n, u in parts)


def fmt_age(seconds):
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return "%s%dd%02dh%02dm" % (sign, days, hours, minutes)
    if hours:
        return "%s%dh%02dm" % (sign, hours, minutes)
    if minutes:
        return "%s%dm" % (sign, minutes)
    return "%s%ds" % (sign, seconds % 60)


TS = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?"
    r"\s*(Z|[+-]\d{2}:?\d{2})?"
)


def parse_ts(text):
    m = TS.fullmatch(text.strip())
    if not m:
        return None
    year, month, day, hour, minute, second, frac, zone = m.groups()
    try:
        moment = datetime(int(year), int(month), int(day), int(hour), int(minute), int(second or 0))
    except ValueError:
        return None
    if zone is None:
        return int(moment.timestamp())
    if zone == "Z":
        offset = timedelta(0)
    else:
        digits = zone[1:].replace(":", "")
        hours, minutes = int(digits[:2]), int(digits[2:])
        if hours > 23 or minutes > 59:
            return None
        offset = timedelta(hours=hours, minutes=minutes)
        if zone[0] == "-":
            offset = -offset
    return int(moment.replace(tzinfo=timezone(offset)).timestamp())


def cells(line):
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", body)]


def is_separator(line):
    if "|" not in line and "-" not in line:
        return False
    parts = cells(line)
    return bool(parts) and all(re.fullmatch(r":?-+:?", p) for p in parts)


def normalize(name):
    return name.strip().strip("`*_").strip().lower()


max_age = parse_duration(max_age_text)
if max_age is None:
    die("--max-age '%s' is not a duration (use seconds, or parts like 2h, 90m, 1h30m)" % max_age_text)

try:
    with open(report, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except (OSError, UnicodeDecodeError) as error:
    die("report '%s' cannot be read: %s" % (report, error))

want = normalize(column)
checked = 0
tables = 0
undated = []
bad = []
i = 0
while i < len(lines):
    line = lines[i]
    if "|" in line and i + 1 < len(lines) and is_separator(lines[i + 1]):
        header = [normalize(c) for c in cells(line)]
        start = i + 1
        i += 2
        rows = []
        while i < len(lines) and lines[i].strip():
            rows.append((i + 1, lines[i]))
            i += 1
        tables += 1
        if want not in header:
            undated.append(start)
            continue
        index = header.index(want)
        for number, row in rows:
            checked += 1
            row_cells = cells(row)
            value = row_cells[index] if index < len(row_cells) else ""
            stamp = parse_ts(value.strip("`"))
            if stamp is None:
                verdict = "UNREADABLE"
                age_text = "unknown age (%s '%s')" % (column, value)
            else:
                age = now - stamp
                age_text = "age %s (%s %s)" % (fmt_age(age), column, value)
                if age < -FUTURE_SKEW:
                    verdict = "UNREADABLE"
                    age_text += " is in the future"
                elif age > max_age:
                    verdict = "STALE"
                else:
                    verdict = "fresh"
            entry = "line %d: %s %s: %s" % (number, verdict, age_text, row.strip())
            print(entry)
            if verdict != "fresh":
                bad.append(entry)
        continue
    i += 1

if tables == 0:
    die("report '%s' has no markdown table" % report)

if checked == 0 and not undated:
    die("report '%s' has no table rows to check" % report)

if undated:
    sys.stderr.write(
        "error: %d table(s) in '%s' have no '%s' column, so their rows were never dated; add the column and re-check them:\n"
        % (len(undated), report, column)
    )
    for start in undated:
        sys.stderr.write("  table at line %d: no '%s' column\n" % (start, column))
    sys.exit(2)

if bad:
    sys.stderr.write(
        "error: %d of %d rows are older than %s or have no readable %s; re-check these before putting them to the captain:\n"
        % (len(bad), checked, max_age_text, column)
    )
    for entry in bad:
        sys.stderr.write("  %s\n" % entry)
    sys.exit(1)
print("all %d rows are within %s" % (checked, max_age_text))
PY
