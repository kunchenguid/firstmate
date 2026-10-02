# Skill system

Firstmate uses a two-part skill system for cross-repo skill reuse.

`bin/fm-skill-map.sh` generates the private discovery map at `data/skill-map.md`.
`bin/fm-skill-compose.sh` composes a curated subset from that map into one mate or one launch.

## Skill map

The map is a flat, regenerated index.
It is private operational state and is not committed.
It scans only `SKILL.md` frontmatter so refresh stays cheap.
It does not read skill bodies, and it stops reading a `SKILL.md` at a bounded prefix, so an unclosed frontmatter block cannot pull a whole skill body into the map.
It records the skill name, one-line description, source group, and absolute canonical skill-folder path.
Each canonical skill-folder path appears at most once, even when symlinked source trees discover it more than once.

A skill is skipped when its folder or `SKILL.md` cannot be read, its frontmatter never closes within the bound, it carries no usable name, or its name contains the map's own field separator.
A closing delimiter is trusted only on a complete line, so the byte bound cannot truncate a longer run of dashes into the delimiter it is supposed to require.
A name carrying the field separator is refused rather than written, because reading such a record back would shadow or redirect another skill.
The recorded path is refused the same way, before it is used for anything, when a skill folder's own name carries a tab or a newline.
Such a path would reframe the record, and because the path is also the de-duplication key, a newline in it would erase a real skill that shares its leading portion and leave a duplicate alone on that name.
An em dash in a path is not refused, because the field separator is read left to right and one inside the path stays part of the path.
Every path a skip names is printed quoted, so a name carrying a newline cannot forge a second diagnostic line in the session digest.
The scanner reads each `SKILL.md` exactly once, so a file that changes between reads cannot be parsed as if it had not been truncated.
Trailing whitespace on a frontmatter delimiter is accepted.
Every skip names the offending path on stderr, and the generator exits non-zero after still writing the map for the skills that did parse.
The `fm-skill-map.sh` header owns that exit status.
Composition treats a reported skip as a gap rather than a refresh failure, so the skills that did parse still compose, and a skipped name is refused by name when it is requested.

The scanner reads these sources:

- This Firstmate repo's `.agents/skills/` directory.
- Each registered project clone's `.claude/skills/` and `.agents/skills/` directories under the active home's `projects/` directory, including a project whose name begins with a dot.
- The Claude user skill directory at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`, which is scanned from `CLAUDE_CONFIG_DIR` alone when `HOME` is unset.

Regenerate it with:

```sh
bin/fm-skill-map.sh
```

Session start refreshes the map when the session holds the home lock, in the deferred startup stage (`bin/fm-startup-network.sh`), so the scan never blocks the digest.
A read-only session skips the refresh because the map is a mutable `data/` record.

The map groups entries under source headings; each skill line contains its name, description, and canonical path.
The `fm-skill-map.sh` header and `--help` output own the exact generated format.
The final path is the source of truth for composition.
Do not edit `data/skill-map.md` by hand.
Fix the source skill's frontmatter and regenerate the map instead.

## Skill composition

Composition symlinks selected skill folders from their canonical locations into a per-home overlay.
It never copies a skill folder.
It never clones a repository.
It never writes through the symlink target.
Every managed path from the target home's `config/` directory down to the set's `.claude/skills` directory must be a real directory.
A symlink anywhere in that ancestry is refused before any mutation, so composition can never reconcile through one into a tracked `.agents/skills` tree.
The ancestry and the existing entries are both re-checked immediately before the first mutation, because resolving names and refreshing the map in between takes long enough for either to change.
Nothing removes the managed directories above a set, so a refused or no-op run can leave them behind in a home that had none.
That is deliberate: a path-based removal resolves through a symlinked ancestor and would reach outside the target home, and removing a shared parent races a concurrent run composing a different set.
Every entry name and every mapped path a refusal prints is quoted, because the composed worker writes into that overlay and a recorded path comes from a scanned source.
An unquoted one could carry a control sequence that rewrites the refusal an operator reads.

The scanner reads one level of each source directory, so a skill nested deeper than `<source>/<skill>/SKILL.md` is not discovered.
Claude Code's own `skills/synced/<id>/<skill>/` layout is nested that way and is therefore not mapped.

Compose a curated set with:

```sh
bin/fm-skill-compose.sh --target-home /path/to/home skill-a skill-b
```

Remove a skill from that set with:

```sh
bin/fm-skill-compose.sh --target-home /path/to/home --remove skill-a
```

Clear the set with:

```sh
bin/fm-skill-compose.sh --target-home /path/to/home --clear
```

Re-running compose with a new list reconciles the set exactly.
Requested symlinks are created or corrected.
Stale symlinks in that set are removed.
Exact skill names must resolve to one map entry; missing or ambiguous names are refused.
Non-symlink entries are refused instead of being overwritten.

## Claude load point

Claude Code reads project skills from `.claude/skills/` and user skills from the Claude config directory.
It also loads `.claude/skills/` found under a directory passed with `claude --add-dir`.
Firstmate uses that `--add-dir` mechanism for composed skills.
`FM_SKILL_OVERLAY_LOAD_LIVE_E2E=1 tests/fm-skill-overlay-load-live-e2e.test.sh` re-proves that load against the installed Claude binary.

The helper writes Claude overlays under:

```text
<target-home>/config/skill-compose/claude/<set>/.claude/skills/
```

The directory passed to Claude is:

```text
<target-home>/config/skill-compose/claude/<set>
```

This is the non-polluting point for a firstmate-home mate.
It keeps composed skills out of the tracked `.agents/skills/` directory.
It also avoids replacing the tracked `.claude/skills -> .agents/skills` compatibility symlink.

For a Claude-backed spawn, pass a curated subset directly:

```sh
bin/fm-spawn.sh <id> <project> --mode no-mistakes --yolo off --harness claude --skills skill-a,skill-b
```

For a local secondmate launch, the same flag composes into that secondmate home's `home` set and launches Claude with the overlay directory.
For a crewmate or scout launch, the flag composes into the active home's task-specific set and launches Claude with that overlay directory.
Batch dispatch forwards the same curated list into each task's own overlay.
`--skills` is fresh-spawn only; relaunches and raw launch commands are refused because they do not expose this verified overlay injection point.

Remote secondmates are refused because local canonical skill folders cannot be symlinked into a remote home through this load path.
Other harnesses do not yet have a verified per-home composition load point.
`fm-spawn.sh --skills` and `fm-skill-compose.sh --harness` therefore refuse those composition requests until their load points are verified.

## Provisioning use

Use the map to choose only the skills that match the secondmate's charter.
Do not compose every skill by default.

The usual local Claude provisioning path composes and loads the overlay in one fresh launch:

```sh
bin/fm-spawn.sh <secondmate-id> /path/to/secondmate-home --secondmate --harness claude --skills skill-a,skill-b
```

The standalone helper is useful for reconciling or inspecting the overlay before that launch:

```sh
bin/fm-skill-map.sh
bin/fm-skill-compose.sh --target-home /path/to/secondmate-home --set home skill-a skill-b
```

Running the helper alone does not alter a later launch command.
A later `fm-spawn.sh` launch must still receive `--skills` so it injects the overlay with `--add-dir`.

If a mate needs repository data or project files beyond the skill instructions, provision that project separately.
Skill composition is only a way to share instruction packages.
It is not a project clone, data sync, or dependency manager.

## Deliberately skipped patterns

Firstmate does not copy skills into each consumer.
Copies drift and make the same edit necessary in many places.

Firstmate does not version-pin composed skills.
Version pinning is useful for independent consumers that need deliberate upgrades.
Firstmate's homes are a single-operator fleet that is supposed to converge on the same canonical instructions.

Firstmate does not perform semantic skill routing.
Semantic routing helps at hundreds or thousands of similar skills.
The current fleet needs a cheap flat map plus human or firstmate curation.

Firstmate does not compose every discovered skill into every mate.
Over-broad skill sets make the agent slower and increase the chance that the wrong skill fires.
Curate the smallest subset that matches the mate's job.
