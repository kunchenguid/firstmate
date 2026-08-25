# 15 Canonical Cypher Query Patterns

Use with: `.venv/bin/python kg.py query "<cypher>"`

## 1. Characters appearing in Chapter N
```cypher
MATCH (c:Character)-[:APPEARS_IN]->(ch:Chapter {number: N}) RETURN c.name ORDER BY c.name
```

## 2. Who is at what location in Chapter N
```cypher
MATCH (c:Character)-[l:LOCATED_AT {chapter: N}]->(loc:Location) RETURN c.name, loc.name
```

## 3. Members of an Organization / Faction
```cypher
MATCH (c:Character)-[m:MEMBER_OF]->(o:Organization) RETURN o.name, collect(c.name) AS members
```

## 4. Item ownership with verbatim quote and chapter
```cypher
MATCH (c:Character)-[o:OWNS]->(i:Item) MATCH (q:Quote {id: o.quote_id})
RETURN c.name, i.name, o.chapter, q.text ORDER BY o.chapter
```

## 5. Spell or technique usage with quote
```cypher
MATCH (c:Character)-[u:USES]->(t:Technique) MATCH (q:Quote {id: u.quote_id})
RETURN c.name, t.name, u.chapter, q.text ORDER BY u.chapter
```

## 6. Relationships between two characters
```cypher
MATCH (a:Character)-[r:RELATES_TO]->(b:Character)
WHERE a.name CONTAINS "Harry" AND b.name CONTAINS "Draco"
MATCH (q:Quote {id: r.quote_id}) RETURN r.kind, r.chapter, q.text ORDER BY r.chapter
```

## 7. 1-hop ego network
```cypher
MATCH (c:Character {name: "Harry James Potter-Evans-Verres"})-[r]-(other)
RETURN label(r), other.name LIMIT 50
```

## 8. 2-hop traversal (friend of a friend)
```cypher
MATCH (a:Character {name: "Draco Malfoy"})-[:RELATES_TO]->(mid:Character)-[:RELATES_TO]->(b:Character)
WHERE b <> a RETURN DISTINCT mid.name, b.name LIMIT 40
```

## 9. Who knows about X since which chapter (Epistemic belief tracking)
```cypher
MATCH (c:Character)-[k:KNOWS_ABOUT]->(t) WHERE t.name CONTAINS "Time-Turner"
MATCH (q:Quote {id: k.quote_id})
RETURN c.name, k.since_chapter, k.until_chapter, q.text ORDER BY k.since_chapter
```

## 10. Epistemic state at Chapter N ("Who knows what at chapter N")
```cypher
MATCH (c:Character)-[k:KNOWS_ABOUT]->(t)
WHERE k.since_chapter <= N AND (k.until_chapter IS NULL OR k.until_chapter >= N)
RETURN c.name, t.name ORDER BY c.name
```

## 11. Events in Chapter N and their causes
```cypher
MATCH (e:Event)-[:PART_OF]->(ch:Chapter {number: N})
OPTIONAL MATCH (cause:Event)-[:CAUSES]->(e) RETURN e.name, cause.name
```

## 12. Full character timeline ordered by chapter
```cypher
MATCH (c {name: "Severus Snape"})-[r]->(t)
WHERE r.chapter IS NOT NULL
MATCH (q:Quote {id: r.quote_id})
RETURN r.chapter, label(r), t.name, q.text ORDER BY r.chapter
```

## 13. Top characters by PageRank centrality
```cypher
MATCH (c:Character) WHERE c.pagerank_score IS NOT NULL
RETURN c.name, round(c.pagerank_score, 4) AS score
ORDER BY score DESC LIMIT 15
```

## 14. Leiden community / faction teammates
```cypher
MATCH (c:Character {name: "Hermione Jean Granger"})
MATCH (other:Character {community: c.community})
RETURN collect(other.name) AS teammates
```

## 15. Full-text quote search to graph traversal
```cypher
MATCH (q:Quote) WHERE q.text CONTAINS "Patronus"
MATCH (a)-[r {quote_id: q.id}]->(b)
RETURN q.chapter, a.name, label(r), b.name, q.text ORDER BY q.chapter LIMIT 25
```
