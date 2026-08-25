# Knowledge Graph Schema Guide

## Node Tables

| Table | Description | Required Properties |
|---|---|---|
| `Chapter` | Story unit / container | `number: INT64`, `title: STRING` |
| `Character` | Sentient being / person | `id: STRING`, `name: STRING`, `aliases: STRING[]`, `pagerank_score: FLOAT`, `community: INT64` |
| `Location` | Physical or magical place | `id: STRING`, `name: STRING`, `pagerank_score: FLOAT`, `community: INT64` |
| `Organization` | Faction / School / Family | `id: STRING`, `name: STRING`, `pagerank_score: FLOAT`, `community: INT64` |
| `Item` | Object / Artifact / Weapon | `id: STRING`, `name: STRING`, `pagerank_score: FLOAT`, `community: INT64` |
| `Technique` | Spell / Method / Skill | `id: STRING`, `name: STRING`, `pagerank_score: FLOAT`, `community: INT64` |
| `Concept` | Abstract idea / Philosophy | `id: STRING`, `name: STRING`, `pagerank_score: FLOAT`, `community: INT64` |
| `Event` | Plot incident / Battle | `id: STRING`, `name: STRING`, `chapter: INT64` |
| `Quote` | Verbatim text evidence | `id: STRING`, `text: STRING`, `chapter: INT64` |

---

## Relationship Tables & Endpoint Constraints

| Relationship | Source Node | Target Node | Key Edge Properties |
|---|---|---|---|
| `APPEARS_IN` | `Character` | `Chapter` | — |
| `LOCATED_AT` | `Character`, `Event` | `Location` | `chapter: INT64`, `quote_id: STRING` |
| `MEMBER_OF` | `Character` | `Organization` | `chapter: INT64`, `quote_id: STRING` |
| `OWNS` | `Character` | `Item` | `chapter: INT64`, `quote_id: STRING` |
| `USES` | `Character` | `Technique` | `chapter: INT64`, `quote_id: STRING` |
| `RELATES_TO` | `Character` | `Character` | `kind: STRING`, `chapter: INT64`, `quote_id: STRING` |
| `CAUSES` | `Event` | `Event` | `quote_id: STRING` |
| `PART_OF` | `Event` | `Chapter` | — |
| `KNOWS_ABOUT` | `Character` | `Character`, `Item`, `Concept`, `Event` | `since_chapter: INT64`, `until_chapter: INT64`, `quote_id: STRING` |
