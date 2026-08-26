#!/usr/bin/env python3
"""Trim a tasks-axi TOON backlog listing: cap hold_reason at ~200 chars with
the same "show <id> --full" pointer convention already used for titles, and
replace a row's fields with a one-line cross-reference when its id was
already printed in full by an earlier group in this same digest.

Usage: fm-backlog-listing-trim.py <group-label> <seen-ids-file>
Reads one tasks-axi TOON block on stdin, writes the trimmed block on stdout.
Header lines (count:, tasks[N]{...}:, help[...]) pass through unchanged.
Data rows are indented CSV (tasks-axi's own quoting); the last field is
hold_reason. <seen-ids-file> accumulates ids across calls for one digest run
so a later group (e.g. "held") can detect an id already shown in full by an
earlier group (e.g. "in flight") and print a cross-reference instead.
"""
import csv
import io
import sys

HOLD_REASON_CAP = 200


def truncate_hold_reason(task_id, reason):
    if len(reason) <= HOLD_REASON_CAP:
        return reason
    return (
        reason[:HOLD_REASON_CAP]
        + f"\n... (truncated, {len(reason)} chars total - use "
        f"tasks-axi show {task_id} --full to see complete hold reason)"
    )


def main():
    if len(sys.argv) != 3:
        print("usage: fm-backlog-listing-trim.py <group-label> <seen-ids-file>", file=sys.stderr)
        return 2
    group_label, seen_path = sys.argv[1], sys.argv[2]

    seen = {}
    try:
        with open(seen_path, "r", encoding="utf-8") as f:
            for line in f:
                if "\t" in line:
                    tid, label = line.rstrip("\n").split("\t", 1)
                    seen[tid] = label
    except FileNotFoundError:
        pass

    newly_seen = []
    out = sys.stdout
    for line in sys.stdin:
        stripped = line.rstrip("\n")
        if not stripped.startswith("  ") or stripped.startswith("  -"):
            # Header, count, or help line - pass through unchanged.
            out.write(line)
            continue
        row = list(csv.reader(io.StringIO(stripped.strip())))[0]
        if not row:
            out.write(line)
            continue
        task_id = row[0]
        if task_id in seen:
            out.write(f'  {task_id} - see "{seen[task_id]}" above (same hold reason, not repeated)\n')
            continue
        if row:
            row[-1] = truncate_hold_reason(task_id, row[-1])
        buf = io.StringIO()
        csv.writer(buf, quoting=csv.QUOTE_MINIMAL).writerow(row)
        out.write("  " + buf.getvalue().rstrip("\r\n") + "\n")
        newly_seen.append(task_id)

    if newly_seen:
        with open(seen_path, "a", encoding="utf-8") as f:
            for task_id in newly_seen:
                f.write(f"{task_id}\t{group_label}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
