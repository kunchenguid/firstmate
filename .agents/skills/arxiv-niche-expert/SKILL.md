---
name: arxiv-niche-expert
description: >-
  Build a persistent, evidence-backed niche expert from a topic, claim, or opinion.
  Load when the captain asks to turn a subject, claim, or opinion into an evidence-backed expert that ingests papers (default 20, deep 50) and stays available for discussion, run by a scout (one-off briefing) or a persistent secondmate (ongoing expert).
user-invocable: false
metadata:
  internal: true
---

# arxiv-niche-expert

Turn a topic, claim, or opinion into a persistent, evidence-backed niche expert.
The expert ingests papers, ranks them by relevance and citations, and answers ongoing questions with cited evidence.

This skill reuses existing substrates and is grounded in two scouts: `data/arxiv-skill-market/report.md` (reuse-first build; no existing tool offers a persistent per-niche expert or the 20/50 ingest modes) and `data/free-paper-sources/report.md` (free source set and the pluggable adapter model).

## Invocation

The captain gives a subject and a mode, and firstmate runs this skill through a scout or a secondmate.

- `topic` / `claim` / `opinion` - the subject or thesis to investigate.
- `mode` - `default` ingests `paper_count=20`; `deep` ingests `paper_count=50`.
- `sources` - optional ordered override of source adapters (defaults below).

Run the skill as a scout for a one-off evidence briefing, or as a persistent secondmate for ongoing Q&A.

## Parameters

`paper_count` and `sources` are parameters, not constants; 20 and 50 are defaults only.

- `paper_count` (int) - cap on ingested papers after ranking; default 20, deep 50.
- `sources` (list of adapter ids) - ordered search/resolver adapters; default v1 set below.
- `topic` / `claim` / `opinion` (string) - the subject the expert covers.

## Workflow

Follow the pipeline in order, one stage per step.

1. Search the enabled `sources` for the subject query.
2. Download the candidate papers through the substrate's read tools.
3. Extract title, authors, abstract, and key sections from each paper.
4. Dedupe records by `doi`, then by normalized `title` + `authors`.
5. Rank the survivors by relevance, citations, and recency, with provenance.
6. Cap the ranked set to `paper_count`.
7. Synthesize an evidence-backed briefing with inline citations.
8. Seed a per-niche secondmate home for ongoing Q&A (see charter template).

For a one-off briefing, run steps 1-7 as a scout and stop at the report.
For an ongoing expert, run step 8 to seed the persistent secondmate.

## Reusable substrates (do not reinvent)

Use a mature search/download/read substrate; never build PDF parsing or LaTeX extraction yourself.

- `arxiv-mcp-server` (Apache-2.0 MCP server) - tools `search_papers`, `download_paper`, `read_paper` (bounded), `list_paper_latex_sections`, `get_paper_latex_section`, `citation_graph`, `semantic_search`; bundled prompts `literature_review`, `deep-paper-analysis`, `literature-synthesis`.
  Reach it from any MCP-aware runtime (Pi/Codex/Claude).
- `pi-arxiv` (MIT Pi extension) - `arxiv_search`, `arxiv_paper`, `arxiv_fetch2md` (Markdown via arxiv2md).
  Install with `pi install npm:@wienerberliner/pi-arxiv`.
- `paper-qa` (Apache-2.0) - citation-grounded RAG over PDFs; `pqa ask "..."` or the library API returns answers with inline citations such as `Author2011 pages 1-2`.
  Use it for the persistent expert's evidence-first discussion grounding.

The `arxiv-skill-market` scout recommends this reuse-first build over forking: the mechanics are licensed and maintained, while the persistent-expert behavior and 20/50 modes are the novel layer to add.

## Pluggable source adapters

Model sources as adapters so each per-niche expert tunes coverage without code changes.
`free-paper-sources` defines this model and the v1 set.

Each adapter declares the following fields:

- `endpoint` (URL) - the source's API base.
- `auth` (`none` | `email` | `api_key`) - use the matching value.
- `rate_limit` (calls/sec or calls/day) - honor it; add backoff.
- `quality` tag (`peer_reviewed` | `preprint` | `mixed`) - set per source.
- `dedup_key` - prefer `doi`; fall back to normalized `title` + `authors`.
- `normalize()` - map the source's record to the common schema below.

Common record schema:

```json
{
  "title": "...",
  "authors": ["..."],
  "abstract": "...",
  "url": "...",
  "pdf_url": "...",
  "doi": "...",
  "year": 2026,
  "citations": 42,
  "source": "openalex",
  "quality": "peer_reviewed"
}
```

v1 default adapters (ordered):

- `openalex` - backbone across all fields; free, no key at 20/50 scale; returns OA PDF links, citations, and concepts.
  Endpoint `https://api.openalex.org/works`.
- `semantic_scholar` - relevance/abstract/embedding layer; strong in CS/AI/bio.
  Endpoint `https://api.semanticscholar.org/graph/v1/paper/search`; shared-rate-limit caveat, add backoff.
- `europe_pmc` - biomedical/life-sciences depth: peer-reviewed plus 6.5M OA full text and a citation network.
  Endpoint `https://www.ebi.ac.uk/europepmc/webservices/rest/search`.
- `biorxiv_medrxiv` - newest biomedical/clinical preprints, before peer review.
  Endpoint `https://api.biorxiv.org/details/{server}/{interval}/{cursor}/json`.
- `unpaywall` - optional PDF resolver; given DOIs from the searchers, return the best free PDF URL.
  Endpoint `https://api.unpaywall.org/v2/{DOI}`; requires `email` param; 100,000 calls/day.
- `crossref` - internal dedup/metadata backbone only, not a user-facing searcher; most reliable DOI authority.
  Endpoint `https://api.crossref.org/works`.

Per-niche experts override `sources` and `paper_count` by config: a molecular-biology expert may enable `europe_pmc` and `biorxiv_medrxiv` and drop the rest; a CS expert may lean on `semantic_scholar` and skip the biomedical sources.
No code change is needed.

## Evidence-first synthesis

Enforce evidence-first output in the briefing and in every ongoing answer.

- Separate established findings from tentative claims.
- Cite each claim inline with its source (DOI or title plus adapter).
- Surface license and quality tags when the source provides them.
- Rank by relevance, citations, and recency with provenance; do not present preprints as peer-reviewed.
- Use `paper-qa` prompts to ground answers in retrieved text rather than model memory.

## Per-niche secondmate charter (persistent expert)

After the briefing, seed a persistent secondmate home for ongoing Q&A.
The secondmate is idle by default and acts only when firstmate routes a topic to it.
Use `bin/fm-brief.sh <niche-id> --secondmate --no-projects`, fill the charter with `FM_SECONDMATE_CHARTER` and `FM_SECONDMATE_SCOPE`, then `bin/fm-home-seed.sh <niche-id> - --no-projects`.
See `secondmate-provisioning` for the full seed and launch contract.

Example charter and scope:

```sh
export FM_SECONDMATE_CHARTER='You are the persistent evidence-backed expert for <niche>. You ingested <paper_count> papers from <sources> on <date>. Answer ongoing questions about this niche with cited evidence, separating established findings from tentative claims, and surface license/quality when available. You are idle until firstmate routes a topic to you. Do not invent papers; cite only the ingested set and named external sources.'
export FM_SECONDMATE_SCOPE='Ongoing evidence-backed Q&A about <niche>: follow-up questions, claims to verify, and literature gaps, using the ingested paper set plus the named free sources.'
```

## Routing from main firstmate

When the captain asks an ongoing question about the niche, route it to the secondmate by scope (per `data/secondmates.md` and `secondmate-provisioning`).
The secondmate answers with cited evidence and stays available; it never initiates work on its own.
For a one-off briefing only, run the skill as a scout and stop after the report.

## Examples

Default vs deep for the same subject:

```text
Captain: "Build me an expert on retrieval-augmented retrieval, default mode."
→ sources = v1 default set, paper_count = 20, scout briefing then optional secondmate seed.

Captain: "Same topic, deep dive."
→ paper_count = 50, same sources, deeper ingest before the briefing.
```

Biomedical vs CS niche with different sources:

```text
Captain: "Expert on mRNA vaccine delivery, biomedical."
→ sources = [openalex, semantic_scholar, europe_pmc, biorxiv_medrxiv, unpaywall], paper_count = 20.

Captain: "Expert on transformer attention variants, CS."
→ sources = [openalex, semantic_scholar, unpaywall], paper_count = 20 (drop europe_pmc and biorxiv_medrxiv).
```

## References

- `data/arxiv-skill-market/report.md` - reuse-first build recommendation; `arxiv-mcp-server` / `pi-arxiv` substrates; `paper-qa` evidence layer; no existing persistent-expert tool.
- `data/free-paper-sources/report.md` - v1 source set (OpenAlex, Semantic Scholar, Europe PMC, bioRxiv/medRxiv, Unpaywall) and the pluggable adapter model.
- `secondmate-provisioning` - secondmate charter, seed, and routing contract.
