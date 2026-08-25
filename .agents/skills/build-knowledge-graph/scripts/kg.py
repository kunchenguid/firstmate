#!/usr/bin/env python3
"""kg.py — the chat-agent interface to the HPMOR knowledge graph.

  .venv/bin/python kg.py query "MATCH (c:Character) RETURN c.name LIMIT 5"
  .venv/bin/python kg.py update ops.json

`update` applies a JSON list of ops atomically (BEGIN/COMMIT):
  [{"op":"merge_node","type":"Character","id":"character:x","props":{"name":"X"}},
   {"op":"create_rel","type":"OWNS","from":"character:x","to":"item:y",
    "props":{"chapter":5,"quote_id":"q:c0005:abc"}}]
"""
import json, pathlib, sys
import ladybug

ROOT = pathlib.Path(__file__).parent
DB_PATH = ROOT / "data" / "kg.lbug"


def fmt_table(cols, rows, maxw=60):
    def s(v):
        t = "NULL" if v is None else str(v)
        t = t.replace("\n", " ")
        return t[:maxw] + "…" if len(t) > maxw else t
    rows = [[s(v) for v in r] for r in rows]
    w = [len(str(c)) for c in cols]
    for r in rows:
        for i, v in enumerate(r):
            w[i] = max(w[i], len(v))
    line = " | ".join(str(c).ljust(w[i]) for i, c in enumerate(cols))
    sep = "-+-".join("-" * w[i] for i in range(len(cols)))
    out = [line, sep] + [" | ".join(r[i].ljust(w[i]) for i in range(len(r))) for r in rows]
    return "\n".join(out)


def do_query(conn, cypher):
    r = conn.execute(cypher)
    cols = r.get_column_names()
    rows = [list(row) for row in r.get_all()]
    print(fmt_table(cols, rows))
    print(f"({len(rows)} rows)")


def do_update(conn, ops_path):
    ops = json.loads(pathlib.Path(ops_path).read_text())
    if isinstance(ops, dict):
        ops = ops.get("ops", [])
    conn.execute("BEGIN TRANSACTION")
    try:
        for op in ops:
            if op["op"] == "merge_node":
                props = op.get("props", {})
                sets = ", ".join(f"n.{k} = ${k}" for k in props)
                conn.execute(
                    f"MERGE (n:{op['type']} {{id: $id}}) {('SET ' + sets) if sets else ''}",
                    {"id": op["id"], **props})
            elif op["op"] == "create_rel":
                props = op.get("props", {})
                p = ", ".join(f"{k}: ${k}" for k in props)
                conn.execute(
                    f"MATCH (a {{id: $f}}), (b {{id: $t}}) CREATE (a)-[:{op['type']} {{{p}}}]->(b)",
                    {"f": op["from"], "t": op["to"], **props})
            else:
                raise ValueError(f"unknown op {op['op']!r}")
        conn.execute("COMMIT")
        print(f"applied {len(ops)} ops")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("query", "update"):
        sys.exit(__doc__)
    is_query = (sys.argv[1] == "query")
    db = ladybug.Database(str(DB_PATH), read_only=is_query)
    conn = ladybug.Connection(db)
    if is_query:
        do_query(conn, sys.argv[2])
    else:
        do_update(conn, sys.argv[2])


if __name__ == "__main__":
    main()
