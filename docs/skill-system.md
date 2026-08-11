# Skill system

Firstmate uses a two-part skill system for cross-repo skill reuse.

`bin/fm-skill-map.sh` generates the private discovery map at `data/skill-map.md`.
`bin/fm-skill-compose.sh` composes a curated subset from that map into one mate or one launch.

## Skill map

The map is a flat, regenerated index.
It is private operational state and is not committed.
It scans only `SKILL.md` frontmatter so refresh stays cheap.
It does not read skill bodies.
It records the skill name, one-line description, source group, and absolute canonical skill-folder path.

The scanner reads these sources:

- This Firstmate repo's `.agents/skills/` directory.
- Each registered project clone's `.claude/skills/` and `.agents/skills/` directories under the active home's `projects/` directory.
- The Claude user skill directory at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`.

Regenerate it with:

```sh
bin/fm-skill-map.sh
```

Session start refreshes the map when the session holds the home lock.
A read-only session skips the refresh because the map is a mutable `data/` record.

The map format is intentionally thin:

```markdown
## <source>
- <skill-name> - <one-line-description> - <absolute canonical skill folder>
```

The final path is the source of truth for composition.
Do not edit `data/skill-map.md` by hand.
Fix the source skill's frontmatter and regenerate the map instead.

## Skill composition

Composition symlinks selected skill folders from their canonical locations into a per-home overlay.
It never copies a skill folder.
It never clones a repository.
It never writes through the symlink target.

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
Non-symlink entries are refused instead of being overwritten.

## Claude load point

Claude Code reads project skills from `.claude/skills/` and user skills from the Claude config directory.
It also loads `.claude/skills/` found under a directory passed with `claude --add-dir`.
Firstmate uses that `--add-dir` mechanism for composed skills.

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

For a secondmate launch, the same flag composes into that secondmate home's `home` set and launches Claude with the overlay directory.
For a crewmate or scout launch, the flag composes into the active home's task-specific set and launches Claude with that overlay directory.

Other harnesses do not yet have a verified per-home composition load point.
`fm-spawn.sh --skills` and `fm-skill-compose.sh --harness` therefore refuse non-Claude composition until that load point is verified.

## Provisioning use

Secondmate provisioning may include an explicit skill-composition step after the home is seeded and before it is launched.
Use the map to choose only the skills that match the secondmate's charter.
Do not compose every skill by default.

For manual provisioning:

```sh
bin/fm-skill-map.sh
bin/fm-skill-compose.sh --target-home /path/to/secondmate-home --set home skill-a skill-b
bin/fm-spawn.sh <secondmate-id> /path/to/secondmate-home --secondmate --harness claude --skills skill-a,skill-b
```

The direct `fm-spawn.sh --skills` path is the usual path because it composes and launches in one operation.
The separate helper remains useful for inspecting or preparing a home before launch.

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
