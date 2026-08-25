#!/usr/bin/env python3
"""gold/run_eval.py — run all gold questions through the KG, print a report.

Each entry in questions.yaml:
  id, question (VN), type: fact|multihop|knowledge, cypher, expect:
    - any_of: [substrings]  → at least one must appear in the result text
    - chapter: N            → N must appear in some chapter-ish column
    - min_rows: k           → row count floor (default 1)
Exit code 0 if pass-rate >= 80%, else 1. Misses are named, never silent.
"""
import pathlib, sys
import yaml
import ladybug

ROOT = pathlib.Path(__file__).parent.parent
DB_PATH = ROOT / "data" / "kg.lbug"


def run():
    qs = yaml.safe_load((ROOT / "gold" / "questions.yaml").read_text())
    db = ladybug.Database(str(DB_PATH))
    conn = ladybug.Connection(db)
    passed, failed = [], []
    for q in qs:
        exp = q.get("expect", {})
        try:
            r = conn.execute(q["cypher"])
            cols = r.get_column_names()
            rows = [list(map(str, row)) for row in r.get_all()]
        except Exception as e:
            failed.append((q["id"], f"cypher error: {str(e)[:120]}"))
            continue
        text = " ".join(" ".join(row) for row in rows).lower()
        ok = len(rows) >= exp.get("min_rows", 1)
        why = []
        if not rows:
            why.append("0 rows")
        if "any_of" in exp and ok:
            if not any(s.lower() in text for s in exp["any_of"]):
                ok = False
                why.append(f"none of {exp['any_of']} in result")
        if "chapter" in exp and ok:
            chcols = [i for i, c in enumerate(cols) if "ch" in c.lower()]
            chvals = {row[i] for row in rows for i in chcols} | {w for w in text.split() if w.isdigit()}
            if str(exp["chapter"]) not in {str(v) for v in chvals}:
                ok = False
                why.append(f"chapter {exp['chapter']} not found (saw {sorted(chvals)[:8]})")
        (passed if ok else failed).append((q["id"], "; ".join(why) if why else "ok"))

    total = len(qs)
    rate = 100 * len(passed) / total if total else 0
    print(f"{'='*60}\nGOLD EVAL: {len(passed)}/{total} passed ({rate:.0f}%)\n{'='*60}")
    for qid, note in failed:
        q = next(x for x in qs if x["id"] == qid)
        print(f"MISS {qid} [{q.get('type','?')}]: {q['question']}")
        print(f"     reason: {note}\n")
    print(f"pass-rate {'≥' if rate >= 80 else '<'} 80% target")
    sys.exit(0 if rate >= 80 else 1)


if __name__ == "__main__":
    run()
