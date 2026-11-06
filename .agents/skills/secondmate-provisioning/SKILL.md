---
name: secondmate-provisioning
description: >-
  Load when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## References

Load a reference with `cat` through Bash (for example `cat .agents/skills/secondmate-provisioning/references/charter-and-seed.md`); shell output is not re-attached after compaction, so read each one when its trigger applies.

| Reference | Read it when |
| --- | --- |
| `references/charter-and-seed.md` | Scaffolding a charter, seeding a local or remote home, and the single owner of the sync and inherited-local-material propagation contract. |
| `references/record-intake.md` | The domain is existing or inherited, before the new mate acts on any inherited plan. |
| `references/backlog-handoff.md` | Moving in-scope queued items to a secondmate. |
| `references/recovery.md` | A secondmate's endpoint is dead, or a live mate needs a new harness, model, or effort. |
| `references/retirement.md` | The captain or main firstmate explicitly decides to retire a secondmate. |

## Hard rules that hold without the references

- `local-only` projects and items stay with the main firstmate; secondmate project lists hold `no-mistakes` and `direct-PR` projects only.
- A remote seed creates nothing in this home beyond the route, the charter brief, and a launch record; never clone a project into `projects/` for it.
- SSH exit 255 means unknown completion: preserve the route and never launch a local replacement for a remote mate.
- The main firstmate reconciles only direct reports and never reconstructs a secondmate's tree; a secondmate's recovery reconciles only work already its own and then idles.
- An empty queue never triggers retirement; retire only on an explicit captain or main-firstmate decision, and never use `--force` unless the captain explicitly said to discard the work.

## Routing table

`data/secondmates.md` has one parser-compatible line per persistent second mate.
A local route uses:
```markdown
- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

A whole-home remote route uses:

```markdown
- <id> - <one-sentence charter summary> (host: <ssh-alias>; root: <absolute-remote-code-root>; home: <absolute-remote-home>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

Each registry entry stays concise and single-line: the summary is one sentence naming the durable charter, `scope:` is the natural-language intake responsibility, `projects:` is the non-exclusive clone list, and any extra prose is limited to genuinely domain-specific hard rules that change routing or safety for that secondmate.
Natural-language summary and `scope:` text may contain parentheses and semicolons; keep the generated `(home: ...; scope: ...; projects: ...; added ...)` suffix intact so operational consumers resolve its explicit field markers.
The `home:` path points to the seeded home containing `data/charter.md`; no extra registry pointer field is needed.
For a remote route, `host:` is an OpenSSH config alias and `root:` is that host's separate tracked Firstmate code root.
See [remote launch and recovery](../../../docs/remote-secondmates.md#launch-or-recover) for backend selection and readiness (Herdr remains the default; Rex requires explicit selection and a ready doctor verdict).
This release places whole secondmate homes remotely and never individual workers.
[`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md) owns current operator setup and transport behavior.
The home-seeded `data/charter.md` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts, so point to that charter rather than restating those contracts in the registry entry.
The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.
