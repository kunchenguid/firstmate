---
name: project-skill-discovery
description: >-
  Discover a captain-named skill local to a resolved project before global or plugin fallback.
  Load when the active catalog does not unequivocally identify a named project skill, or before declaring it absent.
user-invocable: false
metadata:
  internal: true
---

# Project skill discovery

Use this procedure when the captain names a skill for project work and its project-local identity is not already certain.

1. Resolve the project first under `AGENTS.md` section 7.
   Continue only when one canonical project root is selected.
2. Run `bin/fm-project-skill-resolve.sh <project-root> <captain-supplied-skill-name>` and process its documented exit code.
   The resolver's header and `--help` own search roots, normalization, matching, precedence, output, and path safety.
3. On success, use the returned project-local skill for this project even when the active global or plugin catalog has a homonym.
   Read the complete `SKILL.md` and every reference its instructions require before acting.
4. On ambiguity or an unsafe path, stop and relay the resolver's diagnostic.
   Resolution is complete only after one local file is unique and safe.
5. On absence, consult the active global and plugin catalog next.
   Declare the named skill absent only after both the local resolver and that catalog have no match.
