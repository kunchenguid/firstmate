#!/usr/bin/env python3
"""resolve_aliases.py — merge entity surface variants across staging files.

Pass 1 (mechanical, no LLM): union clusters by case-insensitive exact name and by
name ∈ aliases[] cross-membership, within the same entity type.
Pass 2 (LLM adjudication): token-overlap candidate pairs (same type) that pass 1 did
not already merge are batched to the extraction model; only "same" answers merge.

Canonical name = longest surface form in the cluster (per plan §6: prefer the full
canonical name, keep variants in aliases[]). Rewrites staging/ch*.jsonl in place
(idempotent: re-running finds nothing left to merge), writes the audit trail to
staging/alias_map.json, and logs dropped self-edges to staging/self_edges.log.
"""
import json, pathlib, re, sys, urllib.request
from collections import defaultdict

ROOT = pathlib.Path(__file__).parent
STAGING = ROOT / "staging"
MODEL = "deepseek-v4-flash:0731-cloud"
OLLAMA_URL = "http://localhost:11434/api/generate"

STOP = {"the", "a", "an", "of", "s", "mr", "mrs", "madam", "professor", "prof", "dr",
        "sir", "lord", "lady", "aunt", "uncle", "deputy", "headmistress", "headmaster",
        "boy", "man", "woman", "witch", "wizard", "girl", "father", "mother", "mum", "dad",
        "son", "daughter", "brother", "sister", "he", "she", "it", "they", "his", "her",
        "their", "old", "young", "army", "legion", "regiment", "office", "room", "charms",
        "school", "voice", "master", "dear", "bloody", "voice"}


def tokens(name):
    return {t for t in re.split(r"[^a-z0-9]+", name.lower()) if t and t not in STOP}


class UF:
    def __init__(self): self.p = {}
    def find(self, x):
        self.p.setdefault(x, x)
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x
    def union(self, a, b): self.p[self.find(a)] = self.find(b)


def llm_same(pairs):
    """pairs: [(idx, type, name_a, name_b)] → set of idx judged same entity."""
    if not pairs:
        return set()
    body = {"model": MODEL, "format": "json", "stream": False, "think": False,
            "prompt": (
                "You resolve entity-name variants in the novel HPMOR. For each numbered pair, "
                "decide whether both surface forms refer to THE SAME entity in the story. "
                "Beware distinct characters sharing tokens (e.g. James Potter vs Harry James Potter "
                "are father and son — NOT the same). Answer strict JSON: "
                '{"decisions":[{"i":<index>,"same":true|false}]} for every pair.\n\n'
                + "\n".join(f"{i}: [{t}] {a}  <=>  {b}" for i, t, a, b in pairs)),
            "options": {"temperature": 0.0, "num_predict": 4096}}
    req = urllib.request.Request(OLLAMA_URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        out = json.load(resp)
    txt = out.get("response", "").strip()
    if txt.startswith("```"):
        txt = txt.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        return {d["i"] for d in json.loads(txt)["decisions"] if d.get("same")}
    except Exception:
        print("LLM adjudication failed to parse; skipping LLM merges", file=sys.stderr)
        return set()


def main():
    files = sorted(STAGING.glob("ch*.jsonl"))
    if not files:
        sys.exit("no staging files")

    # collect surface forms
    surface = defaultdict(set)   # (type, lowername) -> {canonical spellings seen}
    aliases_of = defaultdict(set)  # (type, lowername) -> lowercased aliases
    records = []                 # (file, rec)
    for f in files:
        for line in f.read_text().splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if "source" in rec or rec.get("rec") == "relation":
                records.append((f, rec))
                continue
            key = (rec["type"], rec["name"].lower())
            surface[key].add(rec["name"])
            for a in rec.get("aliases") or []:
                aliases_of[key].add(a.lower())
            records.append((f, rec))

    uf = UF()
    keys = list(surface)
    name_owner = defaultdict(list)  # lowercase name -> keys
    for k in keys:
        name_owner[k[1]].append(k)

    def distinctive(s):
        toks = tokens(s)
        return len(s) >= 4 and (len(toks) >= 2 or len(toks) == 1 and len(s.split()) >= 2)

    # pass 1a (mechanical, conservative): a DISTINCTIVE alias of X equals the NAME of Y
    # (same type) → union. Alias↔alias sharing NEVER unions — generic descriptors
    # ("the professor", "boy", "office of …") would chain unrelated entities.
    short_alias_pairs = []
    for k in keys:
        for a in aliases_of[k]:
            if a == k[1]:
                continue
            if distinctive(a):
                for other in name_owner.get(a, []):
                    if other != k and other[0] == k[0]:
                        uf.union(k, other)
            elif len(tokens(a)) == 1:
                # single-content-token aliases (first names) → LLM adjudication candidates
                tok = next(iter(tokens(a)))
                for other in keys:
                    if other[0] != k[0] or other == k or uf.find(k) == uf.find(other):
                        continue
                    if tok in tokens(other[1]):
                        short_alias_pairs.append((k, other, a))

    # pass 1c (typo tolerance): same type, ≥4 tokens each, ≥80% of the smaller token set
    # shared → same entity (catches LLM spelling slips like "Eversion" for "Evans";
    # distinct named characters rarely share 4 of 5 name tokens)
    for i, ka in enumerate(keys):
        for kb in keys[i + 1:]:
            if ka[0] != kb[0] or uf.find(ka) == uf.find(kb):
                continue
            ta, tb = tokens(ka[1]), tokens(kb[1])
            if len(ta) < 4 or len(tb) < 4:
                continue
            if len(ta & tb) / min(len(ta), len(tb)) >= 0.8:
                uf.union(ka, kb)

    # pass 1b: token-overlap candidates not yet merged -> LLM
    cands = []
    for i, ka in enumerate(keys):
        for kb in keys[i + 1:]:
            if ka[0] != kb[0] or uf.find(ka) == uf.find(kb):
                continue
            ta, tb = tokens(ka[1]), tokens(kb[1])
            if not ta or not tb:
                continue
            inter = ta & tb
            if inter and (inter == ta or inter == tb or len(inter) / len(ta | tb) >= 0.34):
                cands.append((len(cands), ka[0], max(surface[ka]), max(surface[kb])))
    seen_pairs = set()
    for k, other, a in short_alias_pairs:
        pair = (k[0], min(k[1], other[1]), max(k[1], other[1]))
        if pair not in seen_pairs:
            seen_pairs.add(pair)
            cands.append((len(cands), k[0], max(surface[k]), max(surface[other])))
    same = llm_same(cands[:250])
    for i, t, a, b in cands[:250]:
        if i in same:
            uf.union((t, a.lower()), (t, b.lower()))

    # canonical per cluster: longest surface form; merged aliases = all names + aliases
    clusters = defaultdict(list)
    for k in keys:
        clusters[uf.find(k)].append(k)
    # sanity guard: an alias chain gone wild shows up as one giant cluster — refuse to write
    for root, members in clusters.items():
        chars = [k for k in members if k[0] == "Character"]
        if len(chars) > 25:
            names = [max(surface[k]) for k in chars[:8]]
            sys.exit(f"ABORT: character cluster with {len(chars)} members looks like a mega-merge "
                     f"(e.g. {names}); fix the resolver before loading")
    canon = {}   # (type, lowername) -> (canonical_name, merged_alias_set)
    for members in clusters.values():
        names = sorted({n for k in members for n in surface[k]}, key=len)
        canonical = names[-1]
        al = set()
        for k in members:
            al |= aliases_of[k]
            al.add(k[1])
        al.discard(canonical.lower())
        al = {a for a in al if tokens(a) or len(a) >= 6}  # drop purely generic descriptors
        for k in members:
            canon[k] = (canonical, al)

    alias_map = {}
    for k, (c, al) in sorted(canon.items()):
        if surface[k] != {c} or al:
            alias_map[max(surface[k])] = {"canonical": c, "type": k[0], "aliases": sorted(al)}

    # rewrite staging
    self_dropped = 0
    for f in files:
        out_ent, out_rel = [], []
        merged = {}
        for line in f.read_text().splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if "source" in rec or rec.get("rec") == "relation":
                rec["source"] = _map(rec["source"], canon)
                rec["target"] = _map(rec["target"], canon)
                if rec["source"].lower() == rec["target"].lower() and rec["target"] != str(rec.get("chapter", "")):
                    self_dropped += 1
                    continue
                out_rel.append(rec)
            else:
                c, al = canon[(rec["type"], rec["name"].lower())]
                key = (rec["type"], c.lower())
                if key in merged:
                    merged[key]["aliases"] = sorted(set(merged[key].get("aliases") or []) | set(al))
                else:
                    e = dict(rec)
                    e["name"], e["aliases"] = c, sorted(al)
                    merged[key] = e
        with open(f, "w") as fh:
            for e in merged.values():
                fh.write(json.dumps(e, ensure_ascii=False) + "\n")
            for r in out_rel:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    (STAGING / "alias_map.json").write_text(json.dumps(alias_map, ensure_ascii=False, indent=1))
    if self_dropped:
        with open(STAGING / "self_edges.log", "a") as fh:
            fh.write(f"{self_dropped} self-edges dropped after merge\n")
    n_merged = len(alias_map)
    sizes = defaultdict(int)
    for v in alias_map.values():
        sizes[v["canonical"]] += 1
    biggest = sorted(sizes.items(), key=lambda kv: -kv[1])[:5]
    print(f"clusters: {len(clusters)} | canonical rewrites: {n_merged} | self-edges dropped: {self_dropped}")
    print(f"biggest clusters: {[(n[:40], c) for n, c in biggest]}")
    print("alias_map.json written; LLM adjudicated pairs:", len(same), "of", len(cands))


def _type_of(rec, side):
    return rec.get("type", "")


def _map(name, canon):
    hits = [v[0] for v in canon.values() if v[0].lower() == name.lower()] or \
           [c for (t, ln), (c, al) in canon.items() if ln == name.lower()] or \
           [c for (t, ln), (c, al) in canon.items() if name.lower() in al]
    return hits[0] if hits else name


if __name__ == "__main__":
    main()
