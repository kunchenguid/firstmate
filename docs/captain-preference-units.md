# Captain preference units

## Working hypothesis (confirmed)

A captain preference is a decision whose `retrigger` condition is indefinite.
"Do not address me as captain" is a decision that fires on every captain-facing message.

The per-unit decision record form already designed in agent-harness therefore covers preferences unchanged.
No second preference-only format is invented here.

Authoritative unit and relation field lists live in agent-harness:

- `harness/global/reference/doc-governance-detail.md` (section "per-unit decision record")
- `docs/decisions/README.md` and `docs/decisions/relations/README.md` on agent-harness (adoption freeze pointer)

Firstmate does not restate those fields.
It adopts them by reference and only owns the home layout, the digest generator, and the session-start cutover rules below.

## Why a digest exists

Session start currently prints `data/captain.md` whole.
Forty separate unit files cannot be read that way without exploding context cost.
The unit tree is the source of truth; a generated digest is the cheap projection for later session-start use.

This mirrors the proven agent-harness pattern: `scripts/render_harness.py` renders `harness/generated/AGENTS.md` from `harness/global/CLAUDE.md`.
Matching that pattern (source units, generated projection, loud generated banner, write and `--check` modes) is deliberate.

## Home layout (forward-only; not cut over yet)

Private to each firstmate home (gitignored `data/`), when a home adopts units:

```text
data/captain.md                 existing prose file; still what session start reads today
data/captain-units/
  units/{id}.md                 one preference unit per file (decision form unchanged)
  relations/{id}.md             optional edges (supersedes | constrained-by | enabled-by)
  digest.md                     GENERATED; never hand-edit
```

`data/captain.md` keeps its name and path so session start stays byte-stable until a separate cutover task switches the read path.
Units live under `data/captain-units/` so they never collide with the existing `captain.md` file.

Namespace for home-local preference units: `d-cap-` (decision, captain-preference), date and sequence, e.g. `d-cap-20260726-001`.
Relation ids: `r-cap-` with the same date and sequence shape.
Fixture ids in this repo use the `d-fixture-` / `r-fixture-` prefixes so they cannot be mistaken for a real captain preference.

## Generator

```sh
bin/fm-render-captain-digest.py \
  --units-dir data/captain-units/units \
  --relations-dir data/captain-units/relations \
  --out data/captain-units/digest.md

bin/fm-render-captain-digest.py ... --check   # exit 1 when out is missing or stale
```

- `--relations-dir` is optional; when omitted, a sibling `relations` directory next to `units` is used if present.
  Only that implicit default may be absent.
  A `--relations-dir` named on the command line must exist and be a directory, or the render exits 2 - a typo'd or unmounted path must not silently degrade to "no relations" and republish retired preferences as active.
- The relation graph is validated as a whole before the active set is computed, because the active set is only a projection of that graph and an ill-formed graph silently changes which preferences an agent is shown.
  All three of these are hard errors (exit 2):
  - an endpoint that names no unit: a `subject` or an `object` outside the unit set, for all three relation types.
    This matches agent-harness `scripts/check_decision_records.py`, so the two tools never disagree about one format, and it stops a mistyped edge from leaving a retired preference in the digest.
  - a self edge: `subject` equal to `object`, for all three relation types.
  - a cycle of `supersedes` edges of any length, mutual pairs included; every unit on a cycle would otherwise retire every other one and vanish from the digest.
- Active preferences are units that are not the `object` of a `supersedes` edge.
- An empty input tree and an empty result are not the same thing:
  - zero unit files is a legitimate empty tree and renders normally.
  - units present but no active unit left is a data error and exits 2 rather than writing a blank digest, because a blank preferences digest at session start reads exactly like "the captain has no preferences" while the unit files still hold them.
- Each field appears at most once per file; a repeated field name is a hard error rather than a silent last-wins overwrite.
- The digest is lean: id, question, choice, retrigger only.
  Rejected options, unknown-then, and provenance stay in the unit files.
  A field recorded as nested bullets keeps its nesting in the digest, so continuation lines can never be read as separate fields.
- Banner source paths are written relative to the digest's own directory, so the rendered bytes do not depend on the directory the generator ran from and `--check` gives the same verdict from anywhere.
- The generated file opens with a loud DO-NOT-EDIT banner (HTML comment plus a first markdown heading) so a hand edit is obviously wrong even before the next render discards it.

## Explicit non-goals of this adoption (do not bundle)

- Migrating existing `data/captain.md` prose into units (forward before backward; separate pass).
- Changing what `bin/fm-session-start.sh` reads (session-start digest must stay byte-identical until a dedicated cutover).
- Touching `data/learnings.md`, `data/projects.md`, or `data/secondmates.md`.
- Committing any real captain preference content into this repository.
  Tracked examples under `docs/examples/captain-preference-units/` are fixtures only.

## Worked example

See `docs/examples/captain-preference-units/`.
Render or check that tree with:

```sh
bin/fm-render-captain-digest.py \
  --units-dir docs/examples/captain-preference-units/units \
  --relations-dir docs/examples/captain-preference-units/relations \
  --out docs/examples/captain-preference-units/digest.md

bin/fm-render-captain-digest.py \
  --units-dir docs/examples/captain-preference-units/units \
  --relations-dir docs/examples/captain-preference-units/relations \
  --out docs/examples/captain-preference-units/digest.md \
  --check
```
