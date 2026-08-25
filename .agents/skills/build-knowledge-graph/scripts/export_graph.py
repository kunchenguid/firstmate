#!/usr/bin/env python3
"""export_graph.py — network algorithms over data/kg.lbug, results written back as node props.

  .venv/bin/python export_graph.py            # pagerank + leiden + write-back + top-10
  .venv/bin/python export_graph.py --dry-run  # print stats without writing

Deterministic: PageRank via networkx (fixed alpha), Leiden via leidenalg with seed=42.
Single-writer DB: one Connection, one transaction for the write-back.
"""
import argparse
import ladybug
import networkx as nx
import igraph as ig
import leidenalg

import pathlib
ROOT = pathlib.Path(__file__).parent
DB_PATH = ROOT / "data" / "kg.lbug"
NODE_TABLES = ["Character", "Location", "Organization", "Item", "Technique", "Concept", "Event"]
SEED = 42


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    db = ladybug.Database(str(DB_PATH))
    conn = ladybug.Connection(db)

    g = nx.Graph()
    for t in NODE_TABLES:
        for (nid,) in conn.execute(f"MATCH (n:{t}) RETURN n.id").get_all():
            g.add_node(nid)
    edge_count = 0
    for t in ["LOCATED_AT", "MEMBER_OF", "OWNS", "USES", "RELATES_TO", "CAUSES", "KNOWS_ABOUT"]:
        for a, b in conn.execute(f"MATCH (a)-[:{t}]->(b) RETURN a.id, b.id").get_all():
            if a in g and b in g and not g.has_edge(a, b):
                g.add_edge(a, b)
                edge_count += 1

    print(f"graph: {g.number_of_nodes()} nodes, {edge_count} unique undirected edges, "
          f"{nx.number_connected_components(g)} components")

    pr = nx.pagerank(g, alpha=0.85) if g.number_of_nodes() else {}

    ig_names = list(g.nodes())
    ig_idx = {nid: i for i, nid in enumerate(ig_names)}
    ig_g = ig.Graph(n=len(ig_names), edges=[(ig_idx[a], ig_idx[b]) for a, b in g.edges()])
    ig_g.vs["name"] = ig_names
    if g.number_of_nodes():
        part = leidenalg.find_partition(ig_g, leidenalg.ModularityVertexPartition, seed=SEED)
        communities = {ig_g.vs[i]["name"]: m for i, m in enumerate(part.membership)}
    else:
        communities = {}

    names = {nid: conn.execute("MATCH (n) WHERE n.id = $id RETURN n.name LIMIT 1", {"id": nid})
             .get_all() for nid in g.nodes()}
    names = {k: (v[0][0] if v else k) for k, v in names.items()}

    top = sorted(pr.items(), key=lambda kv: -kv[1])[:10]
    print("\nTop-10 PageRank:")
    for i, (nid, score) in enumerate(top, 1):
        print(f"  {i:2d}. {names.get(nid, nid):40s} {score:.5f}  (community {communities.get(nid)})")

    n_comm = len(set(communities.values())) if communities else 0
    sizes = {}
    for c in communities.values():
        sizes[c] = sizes.get(c, 0) + 1
    print(f"\nLeiden: {n_comm} communities, sizes: {sorted(sizes.values(), reverse=True)[:10]} …")

    if args.dry_run:
        print("(dry-run: nothing written)")
        return

    conn.execute("BEGIN TRANSACTION")
    written = 0
    for t in NODE_TABLES:
        for (nid,) in conn.execute(f"MATCH (n:{t}) RETURN n.id").get_all():
            if nid in pr:
                conn.execute(
                    f"MATCH (n:{t} {{id: $id}}) SET n.pagerank_score = $pr, n.community = $c",
                    {"id": nid, "pr": float(pr[nid]), "c": int(communities.get(nid, 0))})
                written += 1
    conn.execute("COMMIT")
    print(f"\nwrote pagerank_score + community onto {written} nodes")


if __name__ == "__main__":
    main()
