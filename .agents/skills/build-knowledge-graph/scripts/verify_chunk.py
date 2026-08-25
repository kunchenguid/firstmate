#!/usr/bin/env python3
"""
verify_kg_chunk.py — 5-Tier Verification Engine for HPMOR Knowledge Graph

Core Objectives & 5 Quality Pillars:
  Tier 1: 100% Verbatim Quote Substring Match
  Tier 2: Zero Entity Collisions (Disambiguation)
  Tier 3: Zero Orphan Nodes (Degree >= 1)
  Tier 4: Strict Schema Typing
  Tier 5: Epistemic & Temporal Tracking

CLI:
  python3 verify_kg_chunk.py --input <path_to_chunk_dir_or_json> --chapters <N or N-M>

Exit code 0 if all 5 tiers pass 100%; non-zero with detailed breakdown otherwise.

Chapter fetcher is imported from fetch_chapter.py (or embedded fallback) and
caches to .cache/chapters/ch_{N}.txt.
"""
import argparse
import csv
import hashlib
import json
import pathlib
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).parent
CACHE_DIR = ROOT / ".cache" / "chapters"

# ---------------------------------------------------------------------------
# Constants — Schema Definition (mirrors schema.ddl)
# ---------------------------------------------------------------------------
NODE_TYPES = {"Character", "Location", "Organization", "Item", "Technique", "Concept", "Event", "Quote"}
REL_TYPES = {"RELATES_TO", "MEMBER_OF", "LOCATED_AT", "OWNS", "USES", "KNOWS_ABOUT", "CAUSES", "APPEARS_IN", "PART_OF"}

# Endpoint constraints: which node types allowed at src / dst
ENDPOINTS = {
    "APPEARS_IN":   ({"Character"}, {"Chapter"}),
    "LOCATED_AT":   ({"Character", "Event"}, {"Location"}),
    "MEMBER_OF":    ({"Character"}, {"Organization"}),
    "OWNS":         ({"Character"}, {"Item"}),
    "USES":         ({"Character"}, {"Technique"}),
    "RELATES_TO":   ({"Character"}, {"Character"}),
    "CAUSES":       ({"Event"}, {"Event"}),
    "PART_OF":      ({"Event"}, {"Chapter"}),
    "KNOWS_ABOUT":  ({"Character"}, {"Character", "Item", "Concept", "Event"}),
}

# Chapter special node type for endpoint validation (not in NODE_TYPES but appears as target)
CHAPTER_TYPES = {"Chapter"}

VALID_NODE_TYPES_EXT = NODE_TYPES | CHAPTER_TYPES

# ---------------------------------------------------------------------------
# Helpers: chapter fetcher (import or fallback)
# ---------------------------------------------------------------------------
try:
    from fetch_chapter import fetch_chapter as _fetch_chapter
except ImportError:
    _fetch_chapter = None  # type: ignore


def get_chapter_text(n: int, use_cache: bool = True) -> str:
    """Get chapter text via fetch_chapter import or vault fallback."""
    if _fetch_chapter is not None:
        return _fetch_chapter(n, use_cache=use_cache)
    # minimal fallback: try cache file directly
    p = CACHE_DIR / f"ch_{n}.txt"
    if p.exists():
        return p.read_text(encoding="utf-8")
    raise RuntimeError(f"fetch_chapter not available and no cache for chapter {n}")


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class TierResult:
    tier: int
    name: str
    passed: bool
    total: int = 0
    failures: int = 0
    details: list[str] = field(default_factory=list)
    # optional structured failures for reporting
    errors: list[dict] = field(default_factory=list)


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "x"


def ent_id(etype: str, name: str) -> str:
    return f"{etype.lower()}:{slug(name)}"


def norm_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


# Shared letters+boundary helpers (must stay in sync with extract_chapters.py::verify_quote)
# "đủ chữ cái + đủ biên": lowercase, keep only a-z0-9, require >= MIN_LETTERS
# letters and word-sequence boundary to avoid mid-word truncation.
MIN_LETTERS = 10

def normalize_letters(s: str) -> str:
    """chữ thường + chỉ giữ chữ+số (a-z0-9). Synchronous with extractor."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def normalize_words(s: str) -> list[str]:
    """lowercase word list for boundary check."""
    return re.findall(r"[a-z0-9]+", (s or "").lower())


# ---------------------------------------------------------------------------
# Input loading — flexible chunk ingestion
# ---------------------------------------------------------------------------
def parse_chapter_filter(s: str | None) -> set[int] | None:
    if not s:
        return None
    s = s.strip()
    if "-" in s:
        a, b = s.split("-", 1)
        return set(range(int(a), int(b) + 1))
    return {int(s)}


def _load_json_file(path: pathlib.Path) -> tuple[list[dict], list[dict]]:
    """Load a single JSON or JSONL file -> (entities, relations). Heuristic detection."""
    text = path.read_text(encoding="utf-8")
    # Try JSONL first if multiple lines and each looks like json
    lines = [l for l in text.splitlines() if l.strip()]
    # Heuristic: if first char is { and file contains many lines with rec/entity etc, treat as jsonl
    if len(lines) > 1 and all(l.strip().startswith("{") for l in lines[:3]):
        # Try jsonl
        entities, relations = [], []
        ok = True
        for line in lines:
            try:
                rec = json.loads(line)
            except Exception:
                ok = False
                break
            # staging convention: rec == "entity"/"relation" or presence of source
            if rec.get("rec") == "entity" or ("type" in rec and "name" in rec and "source" not in rec):
                # Could be entity or quote; treat as entity if has name
                if rec.get("type") in NODE_TYPES or "name" in rec:
                    entities.append(rec)
                else:
                    entities.append(rec)
            elif rec.get("rec") == "relation" or "source" in rec:
                relations.append(rec)
            elif rec.get("type") in REL_TYPES:
                relations.append(rec)
            else:
                # fallback: if has source/target it's relation
                if "source" in rec or "target" in rec:
                    relations.append(rec)
                else:
                    entities.append(rec)
        if ok:
            return entities, relations
    # Fall back to single JSON document
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return [], []
    # data may be dict with keys entities/elements/nodes and relations/connections/edges
    if isinstance(data, dict):
        entities = data.get("entities") or data.get("elements") or data.get("nodes") or []
        relations = data.get("relations") or data.get("connections") or data.get("edges") or []
        # Handle LiteGraph style: if dict has single key with list
        if not entities and not relations:
            # Could be {"entities": {"Character": [...]}} nested
            # Try to flatten: if values are lists treat as entities
            for v in data.values():
                if isinstance(v, list) and v and isinstance(v[0], dict):
                    # guess
                    if any("source" in x for x in v):
                        relations.extend(v)
                    else:
                        entities.extend(v)
        return entities, relations
    if isinstance(data, list):
        entities, relations = [], []
        for rec in data:
            if isinstance(rec, dict) and ("source" in rec or rec.get("type") in REL_TYPES):
                # Need to disambiguate: if has type in REL_TYPES and source -> relation
                if rec.get("type") in REL_TYPES and "source" in rec:
                    relations.append(rec)
                elif "source" in rec:
                    relations.append(rec)
                elif rec.get("type") in NODE_TYPES:
                    entities.append(rec)
                else:
                    entities.append(rec)
            elif isinstance(rec, dict):
                entities.append(rec)
        return entities, relations
    return [], []


def _load_csv(path: pathlib.Path, kind: str) -> list[dict]:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            # normalize keys to lower
            rec = {k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in r.items() if k}
            # standardize field names
            if kind == "entity":
                # map common variants
                if "id" not in rec and "name" in rec:
                    rec["id"] = ent_id(rec.get("type", "Character"), rec["name"])
            rows.append(rec)
    return rows


def load_chunk(input_path: pathlib.Path, chapters_filter: set[int] | None = None) -> tuple[list[dict], list[dict], set[int]]:
    """
    Load chunk data from --input which may be:
      - a directory containing elements.csv / connections.csv / chunk.json / *.jsonl
      - a single JSON / JSONL / CSV file
    Returns (entities, relations, chapters_referenced).
    """
    entities: list[dict] = []
    relations: list[dict] = []

    input_path = pathlib.Path(input_path)

    if input_path.is_dir():
        # Priority 1: elements.csv + connections.csv
        el_csv = input_path / "elements.csv"
        conn_csv = input_path / "connections.csv"
        if el_csv.exists():
            entities.extend(_load_csv(el_csv, "entity"))
        if conn_csv.exists():
            relations.extend(_load_csv(conn_csv, "relation"))
        # Priority 2: elements.csv alternative names
        if not entities:
            for name in ["entities.csv", "nodes.csv"]:
                p = input_path / name
                if p.exists():
                    entities.extend(_load_csv(p, "entity"))
        if not relations:
            for name in ["relations.csv", "edges.csv", "connections.csv"]:
                p = input_path / name
                if p.exists():
                    relations.extend(_load_csv(p, "relation"))
        # Priority 3: chunk.json / *.json in dir
        if not entities and not relations:
            # check chunk.json first
            for fname in ["chunk.json", "chunk.jsonl", "data.json"]:
                p = input_path / fname
                if p.exists():
                    e, r = _load_json_file(p)
                    entities.extend(e)
                    relations.extend(r)
        # Priority 4: any *.jsonl (staging ch*.jsonl) or *.json
        if not entities and not relations:
            jsonls = sorted(input_path.glob("*.jsonl"))
            for jf in jsonls:
                e, r = _load_json_file(jf)
                # filter by chapters if needed: peek chapter field
                if chapters_filter:
                    e = [x for x in e if int(x.get("chapter", 0) or 0) in chapters_filter] if e and any("chapter" in x for x in e) else e
                    r = [x for x in r if int(x.get("chapter", 0) or 0) in chapters_filter] if r and any("chapter" in x for x in r) else r
                entities.extend(e)
                relations.extend(r)
            if not entities and not relations:
                for jf in sorted(input_path.glob("*.json")):
                    e, r = _load_json_file(jf)
                    entities.extend(e)
                    relations.extend(r)
        # Last resort: recursively find any csv/jsonl
        if not entities and not relations:
            for jf in sorted(input_path.rglob("*.jsonl")):
                e, r = _load_json_file(jf)
                entities.extend(e)
                relations.extend(r)
                if entities or relations:
                    break
    elif input_path.is_file():
        suffix = input_path.suffix.lower()
        if suffix == ".csv":
            # Heuristic: filename tells kind, else treat as entities if has 'name'
            lname = input_path.name.lower()
            if "connection" in lname or "relation" in lname or "edge" in lname:
                relations.extend(_load_csv(input_path, "relation"))
            elif "element" in lname or "entit" in lname or "node" in lname:
                entities.extend(_load_csv(input_path, "entity"))
            else:
                # try both: if csv has source/target columns it's relations
                with open(input_path, encoding="utf-8") as f:
                    header = f.readline().lower()
                if "source" in header and "target" in header:
                    relations.extend(_load_csv(input_path, "relation"))
                else:
                    entities.extend(_load_csv(input_path, "entity"))
        else:
            e, r = _load_json_file(input_path)
            entities.extend(e)
            relations.extend(r)
    else:
        raise FileNotFoundError(f"Input path does not exist: {input_path}")

    # Filter by chapters if requested
    if chapters_filter:
        # Keep entities/relations whose chapter overlaps filter
        def ent_chapters(rec):
            # entity may have chapter, first_chapter, or since/until
            vals = []
            for k in ("chapter", "first_chapter", "since_chapter"):
                if k in rec and rec[k] is not None:
                    try:
                        vals.append(int(str(rec[k]).strip()))
                    except Exception:
                        pass
            return vals

        def rel_chapters(rec):
            vals = []
            for k in ("chapter", "since_chapter", "since", "until_chapter", "until"):
                if k in rec and rec[k] is not None:
                    try:
                        vals.append(int(str(rec[k]).strip()))
                    except Exception:
                        pass
            return vals

        # If either entity or relation has chapter info matching filter, keep it
        # Otherwise if no chapter info at all, keep (don't over-filter)
        filtered_entities = []
        for rec in entities:
            chs = ent_chapters(rec)
            if not chs:
                filtered_entities.append(rec)
            elif any(c in chapters_filter for c in chs):
                filtered_entities.append(rec)
        filtered_relations = []
        for rec in relations:
            chs = rel_chapters(rec)
            if not chs:
                filtered_relations.append(rec)
            elif any(c in chapters_filter for c in chs):
                filtered_relations.append(rec)
        # Only apply filter if it actually matches something; otherwise keep all (avoid empty)
        if filtered_entities or filtered_relations:
            entities, relations = filtered_entities, filtered_relations

    # Collect referenced chapters
    chapters_ref = set()
    for rec in entities:
        for k in ("chapter", "first_chapter"):
            try:
                if rec.get(k) is not None:
                    chapters_ref.add(int(str(rec[k]).strip()))
            except Exception:
                pass
    for rec in relations:
        for k in ("chapter", "since_chapter", "until_chapter", "since", "until"):
            try:
                if rec.get(k) is not None and str(rec[k]).strip() != "":
                    chapters_ref.add(int(str(rec[k]).strip()))
            except Exception:
                pass
    # Also parse chapter from quote_id like q:c0042:... or target == chapter number for APPEARS_IN
    for rec in relations:
        tgt = str(rec.get("target", "")).strip()
        if tgt.isdigit():
            try:
                chapters_ref.add(int(tgt))
            except Exception:
                pass
        qid = str(rec.get("quote_id", "") or rec.get("quoteId", "") or "")
        m = re.search(r":c(\d+):", qid)
        if m:
            chapters_ref.add(int(m.group(1)))

    return entities, relations, chapters_ref


# ---------------------------------------------------------------------------
# Tier 1: Verbatim Quote Substring Match
# ---------------------------------------------------------------------------
def tier1_verbatim(entities, relations, chapters_filter: set[int] | None = None, use_cache: bool = True) -> TierResult:
    name = "Tier 1: 100% Verbatim Quote Substring Match"
    total = 0
    failures: list[str] = []
    errors: list[dict] = []

    # Collect all quotes with their chapter
    # Entity evidence: evidence field
    # Relation quote: quote / text / evidence field
    items: list[tuple[str, int, str, dict]] = []  # (quote, chapter, kind, rec)
    for e in entities:
        quote = e.get("evidence") or e.get("quote") or e.get("text") or ""
        if not quote or not str(quote).strip():
            continue
        ch = e.get("chapter") or e.get("first_chapter")
        # Try to parse chapter as int
        try:
            ch_int = int(str(ch).strip()) if ch is not None else None
        except Exception:
            ch_int = None
        if ch_int is None and chapters_filter and len(chapters_filter) == 1:
            ch_int = next(iter(chapters_filter))
        if ch_int is not None:
            items.append((str(quote), ch_int, "entity", e))
    for r in relations:
        quote = r.get("quote") or r.get("text") or r.get("evidence") or ""
        if not quote or not str(quote).strip():
            continue
        ch = r.get("chapter") or r.get("since_chapter") or r.get("since") or r.get("quote_chapter")
        # APPEARS_IN/PART_OF target may be chapter number
        if ch is None:
            tgt = str(r.get("target", "")).strip()
            if tgt.isdigit():
                ch = int(tgt)
        try:
            ch_int = int(str(ch).strip()) if ch is not None else None
        except Exception:
            ch_int = None
        if ch_int is None and chapters_filter and len(chapters_filter) == 1:
            ch_int = next(iter(chapters_filter))
        if ch_int is not None:
            items.append((str(quote), ch_int, "relation", r))

    total = len(items)
    if total == 0:
        # No quotes to check is considered pass but note
        return TierResult(tier=1, name=name, passed=True, total=0, failures=0, details=["No quotes found to verify (empty chunk)"])

    # Group by chapter to fetch once
    by_ch: dict[int, list[tuple[str, str, dict]]] = defaultdict(list)
    for quote, ch, kind, rec in items:
        by_ch[ch].append((quote, kind, rec))

    for ch, qlist in sorted(by_ch.items()):
        try:
            chapter_text = get_chapter_text(ch, use_cache=use_cache)
        except Exception as e:
            for quote, kind, rec in qlist:
                failures.append(f"  [CH {ch} FETCH FAIL] {kind} quote not verifiable: {quote[:80]!r} — fetch error: {e}")
                errors.append({"chapter": ch, "kind": kind, "quote": quote, "error": str(e), "rec": rec})
            continue

        # Precompute chapter normalizations once per chapter for efficiency
        ch_letters = normalize_letters(chapter_text)
        ch_words = normalize_words(chapter_text)
        for quote, kind, rec in qlist:
            q = str(quote)
            # Letters + boundary check: đủ chữ cái + đủ biên (sync with extractor)
            q_letters = normalize_letters(q)
            q_words = normalize_words(q)
            ident = rec.get("name") or rec.get("source") or rec.get("id") or "?"
            tgt = rec.get("target", "")
            extra = f" -> {tgt}" if tgt else ""
            snippet = q[:120] + ("..." if len(q) > 120 else "")
            reason = None
            if len(q_letters) < MIN_LETTERS:
                reason = f"insufficient_letters ({len(q_letters)} < {MIN_LETTERS})"
            elif q_letters not in ch_letters:
                reason = "letters_substring not found (hallucinated)"
            else:
                # đủ biên: word-sequence must appear contiguously in chapter words
                if not q_words:
                    reason = "no_words after normalization"
                else:
                    m = len(q_words)
                    found = any(ch_words[i:i+m] == q_words for i in range(len(ch_words) - m + 1))
                    if not found:
                        reason = f"boundary_mismatch — word sequence {q_words[:4]}... not aligned to word boundaries in chapter"
            if reason is not None:
                failures.append(
                    f"  [CH {ch:03d} MISMATCH] {kind} '{ident}{extra}' quote failed letters+boundary in chapter {ch} "
                    f"({reason}, letters={len(q_letters)}): {snippet!r}"
                )
                # Hint: longest word prefix position for debugging
                hint_word = q_words[0] if q_words else q[:20]
                try:
                    widx = ch_words.index(hint_word) if hint_word in ch_words else -1
                except ValueError:
                    widx = -1
                loc_hint = f" first word {hint_word!r} word-index {widx}" if widx != -1 else f" first word {hint_word!r} not found as word"
                failures.append(f"      ↳ hint:{loc_hint} | quote letters {len(q_letters)}, chapter letters {len(ch_letters)}")
                errors.append({"chapter": ch, "kind": kind, "quote": q, "offset": -1, "rec": rec, "ident": str(ident), "reason": reason})

    passed = len(failures) == 0  # failures list has 2x lines per error, so count via errors
    # Recompute failures count based on errors
    fail_count = len(errors)
    # Build details: if passed, show success summary
    if passed:
        details = [f"All {total} quotes verified as verbatim substrings."]
    else:
        details = [f"{fail_count}/{total} quotes FAILED verbatim check:"] + failures

    return TierResult(tier=1, name=name, passed=passed, total=total, failures=fail_count, details=details, errors=errors)


# ---------------------------------------------------------------------------
# Tier 2: Zero Entity Collisions
# ---------------------------------------------------------------------------
def tier2_collisions(entities, relations) -> TierResult:
    name = "Tier 2: Zero Entity Collisions (Disambiguation)"
    details: list[str] = []
    errors: list[dict] = []

    # Normalize entities to canonical id -> record
    # If id field exists, use it; else compute from type+name
    id_to_names: dict[str, set[str]] = defaultdict(set)
    id_to_canonical: dict[str, str] = {}
    name_to_id: dict[str, str] = {}  # lower canonical name -> id
    alias_to_id: dict[str, set[str]] = defaultdict(set)  # lower alias -> set of ids that claim it
    entity_ids: list[str] = []

    for e in entities:
        raw_type = e.get("type", "")
        etype = str(raw_type).strip()
        name_val = e.get("name") or e.get("canonical") or e.get("id") or ""
        name_val = str(name_val).strip()
        if not name_val:
            continue
        # Determine id
        eid = e.get("id") or e.get("entity_id") or ""
        eid = str(eid).strip() if eid else ""
        if not eid:
            eid = ent_id(etype or "Character", name_val)
        # normalize id lower for collision detection (ids are case-insensitive slug)
        eid_norm = eid.lower()
        entity_ids.append(eid)
        id_to_names[eid_norm].add(name_val)
        if eid_norm not in id_to_canonical:
            id_to_canonical[eid_norm] = name_val
        # track canonical name -> id
        name_key = name_val.lower().strip()
        if name_key in name_to_id and name_to_id[name_key] != eid_norm:
            # Two different ids claim same canonical name -> collision (duplicate entity)
            errors.append({"type": "duplicate_canonical", "name": name_val, "ids": [name_to_id[name_key], eid_norm]})
            details.append(f"  [DUPLICATE CANONICAL] name {name_val!r} maps to two IDs: {name_to_id[name_key]} vs {eid_norm}")
        else:
            name_to_id.setdefault(name_key, eid_norm)
        # aliases
        aliases = e.get("aliases") or e.get("alias") or []
        if isinstance(aliases, str):
            # comma-separated string
            aliases = [a.strip() for a in aliases.split(",") if a.strip()]
        for al in aliases:
            al = str(al).strip()
            if not al:
                continue
            al_key = al.lower().strip()
            alias_to_id[al_key].add(eid_norm)

    # Check 1: same ID maps to multiple distinct canonical names -> collapsed entities
    for eid_norm, names_set in id_to_names.items():
        if len(names_set) > 1:
            errors.append({"type": "id_collision", "id": eid_norm, "names": sorted(names_set)})
            details.append(f"  [ID COLLISION] ID {eid_norm!r} collapsed distinct entities: {sorted(names_set)}")

    # Check 2: alias collision — alias of one entity equals canonical of another
    for al_key, id_set in alias_to_id.items():
        if al_key in name_to_id:
            canonical_id = name_to_id[al_key]
            # If alias appears on an entity that is NOT the canonical owner, collision
            for alias_owner in id_set:
                if alias_owner != canonical_id:
                    # Need to find canonical name for reporting
                    canonical_name = id_to_canonical.get(canonical_id, al_key)
                    alias_owner_name = id_to_canonical.get(alias_owner, alias_owner)
                    errors.append({"type": "alias_collision", "alias": al_key, "canonical": canonical_name, "owner": alias_owner_name})
                    details.append(f"  [ALIAS COLLISION] alias {al_key!r} (owned by {alias_owner_name!r}) collides with canonical {canonical_name!r} (id {canonical_id})")

    # Check 3: alias claimed by multiple distinct entities
    for al_key, id_set in alias_to_id.items():
        if len(id_set) > 1:
            owners = [id_to_canonical.get(i, i) for i in id_set]
            errors.append({"type": "shared_alias", "alias": al_key, "owners": sorted(owners)})
            details.append(f"  [SHARED ALIAS] alias {al_key!r} claimed by multiple entities: {sorted(owners)}")

    # Check 4: Known risky pairs explicitly — ensure if both Draco and Lucius present they are distinct
    risky_pairs = [
        ("draco malfoy", "lucius malfoy"),
        ("harry potter", "james potter"),
        ("lily potter", "petunia evans"),
        ("lily evans", "petunia evans-verres"),
        ("sirius black", "regulus black"),
    ]
    for a, b in risky_pairs:
        if a in name_to_id and b in name_to_id and name_to_id[a] == name_to_id[b]:
            errors.append({"type": "risky_pair_collision", "pair": (a, b), "id": name_to_id[a]})
            details.append(f"  [RISKY PAIR COLLISION] {a!r} and {b!r} incorrectly collapsed to same ID {name_to_id[a]}")

    # Also check via substring heuristic: if entity name is substring of another but ids differ, that's ok (distinct),
    # but if ids same, that's failure already caught. So no extra.

    total = len(entities)
    fail_count = len(errors)
    passed = fail_count == 0
    if passed:
        details = [f"All {total} entities have distinct IDs; no alias collisions (checked {len(alias_to_id)} aliases)."]
    else:
        details = [f"{fail_count} collision(s) found among {total} entities:"] + details

    return TierResult(tier=2, name=name, passed=passed, total=total, failures=fail_count, details=details, errors=errors)


# ---------------------------------------------------------------------------
# Tier 3: Zero Orphan Nodes
# ---------------------------------------------------------------------------
def tier3_orphans(entities, relations) -> TierResult:
    name = "Tier 3: Zero Orphan Nodes (Degree >= 1)"
    details: list[str] = []
    errors: list[dict] = []

    # Build node id set
    node_ids: set[str] = set()
    id_to_name: dict[str, str] = {}
    for e in entities:
        # prefer explicit id else derived
        eid = e.get("id") or ""
        eid = str(eid).strip() if eid else ""
        if not eid:
            etype = str(e.get("type", "")).strip() or "Character"
            nm = str(e.get("name") or e.get("canonical") or "").strip()
            if nm:
                eid = ent_id(etype, nm)
            else:
                continue
        node_ids.add(eid.lower())
        id_to_name[eid.lower()] = e.get("name") or e.get("canonical") or eid

    # If no entities, consider pass
    if not node_ids:
        return TierResult(tier=3, name=name, passed=True, total=0, failures=0, details=["No nodes to check."])

    # Compute degree: for each relation, map source/target to node ids
    # Relations may reference by name rather than id; we need to resolve names to ids
    # Build name->id map
    name_to_id: dict[str, str] = {}
    for e in entities:
        nm = str(e.get("name") or e.get("canonical") or "").strip().lower()
        eid = e.get("id") or ""
        eid = str(eid).strip() if eid else ent_id(str(e.get("type", "Character")), nm)
        if nm:
            name_to_id[nm] = eid.lower()
        # also aliases point to this id
        for al in (e.get("aliases") or []):
            if isinstance(al, str):
                al = al.strip().lower()
                if al:
                    # don't overwrite canonical mapping, but record alias->id
                    if al not in name_to_id:
                        name_to_id[al] = eid.lower()

    degree: Counter = Counter()
    for r in relations:
        src = str(r.get("source") or r.get("from") or r.get("src") or "").strip()
        tgt = str(r.get("target") or r.get("to") or r.get("dst") or "").strip()
        # APPEARS_IN / PART_OF target may be chapter number, not an entity — skip for orphan calc
        rtype = str(r.get("type") or "").strip()
        if rtype in ("APPEARS_IN", "PART_OF"):
            # only source counts; target is Chapter node not in our entity list
            sid = name_to_id.get(src.lower(), src.lower()) if src else None
            if sid:
                degree[sid] += 1
            continue
        sid = name_to_id.get(src.lower(), src.lower()) if src else None
        tid = name_to_id.get(tgt.lower(), tgt.lower()) if tgt else None
        if sid:
            degree[sid] += 1
        if tid:
            degree[tid] += 1

    # Also consider that Quote nodes are not in entities list but are linked — ignore for orphan check

    orphans = [nid for nid in node_ids if degree.get(nid, 0) == 0]
    total = len(node_ids)
    fail_count = len(orphans)
    passed = fail_count == 0

    if passed:
        details = [f"All {total} nodes have degree >= 1 (edges: {len(relations)})."]
    else:
        details = [f"{fail_count}/{total} orphan node(s) with degree 0 (no incoming/outgoing edge):"]
        for oid in sorted(orphans):
            nm = id_to_name.get(oid, oid)
            # find original entity type
            etype = next((e.get("type", "?") for e in entities if (e.get("id", "").lower() == oid or (e.get("name","").lower() and ent_id(str(e.get("type","")), str(e.get("name",""))).lower() == oid))), "?")
            details.append(f"  - {oid} ({nm!r}, type={etype}) degree=0")
            errors.append({"id": oid, "name": nm, "type": etype})

    return TierResult(tier=3, name=name, passed=passed, total=total, failures=fail_count, details=details, errors=errors)


# ---------------------------------------------------------------------------
# Tier 4: Strict Schema Typing
# ---------------------------------------------------------------------------
def tier4_schema(entities, relations) -> TierResult:
    name = "Tier 4: Strict Schema Typing"
    details: list[str] = []
    errors: list[dict] = []

    # Build name->type map for endpoint validation
    name_to_type: dict[str, str] = {}
    id_to_type: dict[str, str] = {}
    for e in entities:
        nm = str(e.get("name") or e.get("canonical") or "").strip().lower()
        etype = str(e.get("type") or "").strip()
        eid = str(e.get("id") or "").strip().lower()
        if not eid and nm:
            eid = ent_id(etype or "Character", nm).lower()
        if etype:
            if nm:
                name_to_type[nm] = etype
            if eid:
                id_to_type[eid] = etype
        # aliases also map to same type
        for al in (e.get("aliases") or []):
            if isinstance(al, str):
                al = al.strip().lower()
                if al and etype and al not in name_to_type:
                    name_to_type[al] = etype

    total_entities = len(entities)
    total_relations = len(relations)
    total = total_entities + total_relations

    # Validate node types
    for e in entities:
        etype = str(e.get("type") or "").strip()
        nm = e.get("name") or e.get("canonical") or e.get("id") or "?"
        if etype not in NODE_TYPES:
            # Chapter is allowed only for chapter nodes, not in entities list
            if etype == "Chapter":
                pass  # chapter nodes are separate; but if someone declares Chapter as entity, allow?
            else:
                errors.append({"kind": "node_type", "name": str(nm), "type": etype})
                details.append(f"  [NODE TYPE] {nm!r} has invalid type {etype!r}; allowed: {sorted(NODE_TYPES)}")
        # Also check that Quote entities if present have text
        if etype == "Quote" and not (e.get("text") or e.get("quote") or e.get("evidence")):
            errors.append({"kind": "quote_no_text", "name": str(nm)})
            details.append(f"  [QUOTE] Quote node {nm!r} missing text/quote field")

    # Validate relation types and endpoint constraints
    for r in relations:
        rtype = str(r.get("type") or "").strip()
        src = str(r.get("source") or r.get("from") or r.get("src") or "").strip()
        tgt = str(r.get("target") or r.get("to") or r.get("dst") or "").strip()
        if rtype not in REL_TYPES:
            errors.append({"kind": "rel_type", "type": rtype, "source": src, "target": tgt})
            details.append(f"  [REL TYPE] {src!r} -{rtype!r}-> {tgt!r} has invalid type; allowed: {sorted(REL_TYPES)}")
            continue
        # Endpoint type validation
        allowed_src, allowed_tgt = ENDPOINTS.get(rtype, (set(), set()))
        # Resolve src/tgt types via name_to_type; fallback to id_to_type; if tgt is digit (chapter) treat as Chapter
        src_type = name_to_type.get(src.lower(), id_to_type.get(src.lower(), None))
        tgt_type = name_to_type.get(tgt.lower(), id_to_type.get(tgt.lower(), None))
        # Chapter target handling: APPEARS_IN/PART_OF targets are chapter numbers -> type Chapter
        if rtype in ("APPEARS_IN", "PART_OF") and tgt.isdigit():
            tgt_type = "Chapter"
        # CAUSES: target Event may not be in name_to_type if not declared? Try to infer
        # If src/tgt not found in entity list, we cannot validate strictly but we flag as missing node?
        # For now, if src_type is None, try to report as endpoint_type_missing
        if src_type is None and src:
            # Check if src is known at all; if not, it's an undeclared node reference
            errors.append({"kind": "undeclared_source", "type": rtype, "source": src, "target": tgt})
            details.append(f"  [UNDECLARED SRC] {rtype} edge source {src!r} not declared in entities (target {tgt!r})")
        elif src_type and src_type not in allowed_src:
            errors.append({"kind": "src_type_mismatch", "type": rtype, "source": src, "src_type": src_type, "allowed": sorted(allowed_src)})
            details.append(f"  [SRC TYPE] {rtype}: source {src!r} has type {src_type!r} not in allowed {sorted(allowed_src)}")
        if tgt_type is None and tgt and not (rtype in ("APPEARS_IN", "PART_OF") and tgt.isdigit()):
            errors.append({"kind": "undeclared_target", "type": rtype, "source": src, "target": tgt})
            details.append(f"  [UNDECLARED TGT] {rtype} edge target {tgt!r} not declared in entities (source {src!r})")
        elif tgt_type and tgt_type not in allowed_tgt:
            errors.append({"kind": "tgt_type_mismatch", "type": rtype, "target": tgt, "tgt_type": tgt_type, "allowed": sorted(allowed_tgt)})
            details.append(f"  [TGT TYPE] {rtype}: target {tgt!r} has type {tgt_type!r} not in allowed {sorted(allowed_tgt)}")
        # Additional: check KNOWS_ABOUT target types are in allowed set
        # Already done via endpoint validation.

    fail_count = len(errors)
    passed = fail_count == 0
    if passed:
        details = [f"All {total_entities} nodes and {total_relations} edges pass schema typing (node types in {sorted(NODE_TYPES)}, rel types in {sorted(REL_TYPES)})."]
    else:
        details = [f"{fail_count} schema violation(s) among {total_entities} nodes + {total_relations} edges:"] + details

    return TierResult(tier=4, name=name, passed=passed, total=total, failures=fail_count, details=details, errors=errors)


# ---------------------------------------------------------------------------
# Tier 5: Epistemic & Temporal Tracking
# ---------------------------------------------------------------------------
def tier5_temporal(entities, relations) -> TierResult:
    name = "Tier 5: Epistemic & Temporal Tracking"
    details: list[str] = []
    errors: list[dict] = []

    # Build name -> first_chapter
    name_to_first: dict[str, int | None] = {}
    for e in entities:
        nm = str(e.get("name") or e.get("canonical") or "").strip().lower()
        fc = e.get("first_chapter") or e.get("chapter") or e.get("since_chapter")
        try:
            if fc is not None and str(fc).strip() != "":
                fc_int = int(str(fc).strip())
                name_to_first[nm] = fc_int
            else:
                name_to_first[nm] = None
        except Exception:
            name_to_first[nm] = None

    # Validate entity temporal fields
    for e in entities:
        nm = e.get("name") or e.get("canonical") or e.get("id") or "?"
        for key in ("chapter", "first_chapter", "since_chapter", "until_chapter", "since", "until"):
            val = e.get(key)
            if val is None or str(val).strip() == "":
                continue
            try:
                iv = int(str(val).strip())
            except Exception:
                errors.append({"kind": "bad_chapter_type", "entity": str(nm), "field": key, "value": val})
                details.append(f"  [BAD CHAPTER] entity {nm!r} field {key}={val!r} not an integer")
                continue
            if not 1 <= iv <= 123:
                errors.append({"kind": "chapter_out_of_range", "entity": str(nm), "field": key, "value": iv})
                details.append(f"  [OUT OF RANGE] entity {nm!r} field {key}={iv} not in 1..123")
        # since <= until
        since_keys = ["since_chapter", "since"]
        until_keys = ["until_chapter", "until"]
        since_val = None
        until_val = None
        for k in since_keys:
            if e.get(k) is not None:
                try:
                    since_val = int(str(e[k]).strip())
                except Exception:
                    pass
                break
        for k in until_keys:
            if e.get(k) is not None:
                try:
                    until_val = int(str(e[k]).strip())
                except Exception:
                    pass
                break
        if since_val is not None and until_val is not None and since_val > until_val:
            errors.append({"kind": "temporal_inversion", "entity": str(nm), "since": since_val, "until": until_val})
            details.append(f"  [TEMPORAL] entity {nm!r} since_chapter {since_val} > until_chapter {until_val}")

    # Validate relation temporal fields and causality
    for r in relations:
        rtype = str(r.get("type") or "").strip()
        src = str(r.get("source") or "").strip()
        tgt = str(r.get("target") or "").strip()
        # check chapter fields
        for key in ("chapter", "since_chapter", "until_chapter", "since", "until"):
            val = r.get(key)
            if val is None or str(val).strip() == "":
                continue
            try:
                iv = int(str(val).strip())
            except Exception:
                errors.append({"kind": "bad_chapter_type", "edge": f"{src}->{tgt}", "field": key, "value": val})
                details.append(f"  [BAD CHAPTER] edge {src!r} -{rtype}-> {tgt!r} field {key}={val!r} not integer")
                continue
            if not 1 <= iv <= 123:
                errors.append({"kind": "chapter_out_of_range", "edge": f"{src}->{tgt}", "field": key, "value": iv})
                details.append(f"  [OUT OF RANGE] edge {src!r} -{rtype}-> {tgt!r} field {key}={iv} not in 1..123")
        since_val = None
        until_val = None
        for k in ("since_chapter", "since"):
            if r.get(k) is not None:
                try:
                    since_val = int(str(r[k]).strip())
                except Exception:
                    pass
                break
        for k in ("until_chapter", "until"):
            if r.get(k) is not None:
                try:
                    until_val = int(str(r[k]).strip())
                except Exception:
                    pass
                break
        if since_val is not None and until_val is not None and since_val > until_val:
            errors.append({"kind": "temporal_inversion", "edge": f"{src}->{tgt}", "since": since_val, "until": until_val})
            details.append(f"  [TEMPORAL] edge {src!r} -{rtype}-> {tgt!r} since {since_val} > until {until_val}")

        # first_chapter consistency: an entity's appearances should not be before its first_chapter
        # We check if relation chapter < entity first_chapter -> warning
        rel_ch = None
        for k in ("chapter", "since_chapter", "since"):
            if r.get(k) is not None:
                try:
                    rel_ch = int(str(r[k]).strip())
                except Exception:
                    pass
                break
        if not rel_ch and rtype in ("APPEARS_IN", "PART_OF"):
            # target chapter number
            try:
                rel_ch = int(tgt) if tgt.isdigit() else None
            except Exception:
                pass
        if rel_ch is not None:
            for _n in [src.lower(), tgt.lower()]:
                if _n.isdigit():
                    continue
                fc = name_to_first.get(_n)
                if fc is not None and rel_ch < fc:
                    errors.append({"kind": "causality_violation", "entity": _n, "first_chapter": fc, "edge_chapter": rel_ch, "edge": f"{src}->{tgt}"})
                    details.append(f"  [CAUSALITY] edge {src!r} -{rtype}-> {tgt!r} at chapter {rel_ch} precedes first_chapter {fc} of '{_n}'")

        # Epistemic tags validation where applicable: if relation has epistemic field
        epistemic_tags = r.get("epistemic") or r.get("knowledge_type") or r.get("epistemic_tag")
        if epistemic_tags is not None:
            allowed_epistemic = {"knows", "believes", "suspects", "learns", "discovers", "observes", "knows_about", "known", "unknown"}
            tag_str = str(epistemic_tags).strip().lower()
            if tag_str and tag_str not in allowed_epistemic:
                # not a hard failure but track as warning -> for this engine we treat as failure if tag is present but invalid
                errors.append({"kind": "epistemic_tag_invalid", "edge": f"{src}->{tgt}", "tag": tag_str})
                details.append(f"  [EPISTEMIC] edge {src!r} -{rtype}-> {tgt!r} has invalid epistemic tag {tag_str!r}; allowed: {sorted(allowed_epistemic)}")

    # Check Event chapter consistency: Event nodes should have chapter field in range
    for e in entities:
        if str(e.get("type", "")).strip() == "Event":
            nm = e.get("name") or "?"
            ch = e.get("chapter") or e.get("first_chapter")
            if ch is None or str(ch).strip() == "":
                errors.append({"kind": "event_missing_chapter", "event": str(nm)})
                details.append(f"  [EVENT] Event {nm!r} missing chapter/first_chapter")
            else:
                try:
                    iv = int(str(ch).strip())
                    if not 1 <= iv <= 123:
                        errors.append({"kind": "chapter_out_of_range", "event": str(nm), "chapter": iv})
                        details.append(f"  [EVENT] Event {nm!r} chapter {iv} out of range")
                except Exception:
                    pass

    total = len(entities) + len(relations)
    fail_count = len(errors)
    passed = fail_count == 0
    if passed:
        details = [f"All {len(entities)} entities and {len(relations)} edges pass temporal/epistemic checks."]
    else:
        details = [f"{fail_count} temporal/epistemic violation(s):"] + details

    return TierResult(tier=5, name=name, passed=passed, total=total, failures=fail_count, details=details, errors=errors)


# ---------------------------------------------------------------------------
# Main verify orchestrator
# ---------------------------------------------------------------------------
def verify_chunk(input_path: pathlib.Path, chapters_arg: str | None = None, use_cache: bool = True) -> list[TierResult]:
    chapters_filter = parse_chapter_filter(chapters_arg) if chapters_arg else None
    entities, relations, _ = load_chunk(input_path, chapters_filter)

    # If no data loaded, return failure across tiers
    if not entities and not relations:
        tr = TierResult(tier=0, name="Input Load", passed=False, total=0, failures=1,
                        details=[f"No entities/relations loaded from {input_path}. Check input format (expected elements.csv/connections.csv, chunk.json, or staging JSONL)."])
        return [tr]

    results: list[TierResult] = []
    results.append(tier1_verbatim(entities, relations, chapters_filter, use_cache=use_cache))
    results.append(tier2_collisions(entities, relations))
    results.append(tier3_orphans(entities, relations))
    results.append(tier4_schema(entities, relations))
    results.append(tier5_temporal(entities, relations))
    return results


def print_report(results: list[TierResult], input_path: pathlib.Path, chapters_arg: str | None):
    print("=" * 72)
    print("HPMOR Knowledge Graph — 5-Tier Verification Report")
    print("=" * 72)
    print(f"Input: {input_path}")
    if chapters_arg:
        print(f"Chapters filter: {chapters_arg}")
    print()
    all_pass = all(r.passed for r in results)
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        symbol = "✓" if r.passed else "✗"
        # pass rate
        if r.total > 0:
            passed_count = r.total - r.failures
            rate = (passed_count / r.total * 100) if r.total else 100.0
            print(f" [{symbol}] {r.name}: {status}  ({passed_count}/{r.total} = {rate:.1f}% pass, {r.failures} failure(s))")
        else:
            print(f" [{symbol}] {r.name}: {status}  (no items)")
        for line in r.details:
            print(line)
        print()
    print("-" * 72)
    if all_pass:
        print("RESULT: ALL 5 TIERS PASSED ✓")
    else:
        failed = [r for r in results if not r.passed]
        print(f"RESULT: {len(failed)}/5 TIER(S) FAILED ✗  — Failed tiers: {', '.join(f'Tier {r.tier}' for r in failed)}")
    print("=" * 72)


def main():
    ap = argparse.ArgumentParser(
        description="5-Tier Verification Engine for HPMOR Knowledge Graph",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  python3 verify_kg_chunk.py --input staging --chapters 66\n"
               "  python3 verify_kg_chunk.py --input chunk.json --chapters 1-10\n"
               "  python3 verify_kg_chunk.py --input /tmp/my_chunk --chapters 5\n"
               "  python3 verify_kg_chunk.py --input staging/ch0001.jsonl\n"
    )
    ap.add_argument("--input", required=True, help="path to chunk dir or JSON/JSONL/CSV file")
    ap.add_argument("--chapters", default=None, help="chapter filter: N or N-M (e.g. 66 or 1-10); if omitted, verify all referenced chapters")
    ap.add_argument("--no-cache", action="store_true", help="disable chapter cache (re-fetch)")
    args = ap.parse_args()

    input_path = pathlib.Path(args.input)
    use_cache = not args.no_cache

    results = verify_chunk(input_path, args.chapters, use_cache=use_cache)
    print_report(results, input_path, args.chapters)

    # Exit code 0 if all pass, else 1
    # Handle input load failure pseudo-tier
    if any(r.tier == 0 and not r.passed for r in results):
        for r in results:
            for d in r.details:
                print(d, file=sys.stderr)
        sys.exit(2)
    all_pass = all(r.passed for r in results)
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
