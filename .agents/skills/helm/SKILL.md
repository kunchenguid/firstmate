---
name: helm
description: >-
  Set how firstmate talks to the captain - chat language and response tone/vibe - as a lighter-weight alternative to hand-editing data/captain.md prose.
  Use when the captain invokes /helm.
user-invocable: true
metadata:
  internal: true
---

# helm

A lightweight, discoverable way to set the two compact captain-style axes firstmate already carries as prose in `data/captain.md`'s "Address and tone" and "Language" sections: `language` and `response_tone`.
It is not a new kind of preference, only a faster way to set the same one; `data/captain.md`'s two sections are short pointers here (`docs/configuration.md` "Captain style preferences").

**Scope, state this back to the captain whenever you write a new value:** `language` governs ONLY firstmate's own personal-facing chat and artifacts written for the captain - this conversation, reports, backlog notes, briefs, status digests.
It never changes a project's tracked code, comments, commit messages, PR descriptions, or checked-in documentation, and never changes what language a crewmate uses in its own work - those stay English always (global captain instruction; this repo's own tracked prose is English throughout).

## Storage

`config/captain-style.json`: local, gitignored, human-editable, same tier as `config/crew-dispatch.json`.
`bin/fm-helm.sh`'s header owns the exact schema, merge semantics, and atomic-write mechanics; its `show` and `set` subcommands are the only way this skill reads or writes the file.
`jq` is a required, accepted hard dependency for `/helm`, matching `config/watched-tools.json` and `config/crew-dispatch.json`; a missing `jq` fails loudly by name rather than silently discarding a valid file.
Not propagated to secondmate homes today (unlike `config/crew-dispatch.json`); a secondmate wanting the same captain-style values needs its own `/helm` invocation in its own home.

## Invocation

1. Run `bin/fm-helm.sh show` and relay the current `language` and `response_tone` in plain terms, or that no preference is set yet (firstmate's built-in defaults apply) when it reports `ABSENT`.
2. Determine the new value(s):
   - If the captain's `/helm` message already states a language and/or a tone/vibe description inline, use those.
   - Otherwise ask for whichever of the two the captain wants to set; setting only one is fine and never touches the other.
3. Run `bin/fm-helm.sh set --language <lang>` and/or `bin/fm-helm.sh set --response-tone <text>` (one `set` call per invocation covers both flags at once).
   A non-empty value is required for any flag passed; the script refuses a whitespace-only value and refuses `set` with neither flag.
4. Confirm back to the captain in plain language exactly what changed (from what, to what), and restate the scope note above once, briefly - this never changes a project's own code or docs language.

`response_tone` is free text, not an enum: write down the vibe as the captain describes it, the same way `data/captain.md`'s existing prose works today.
A deeper narrative preference that does not fit a single tone string (for example, dropping playfulness for bad news or security topics) belongs in `data/captain.md`'s own richer prose rather than being forced into this field; `/helm` covers the compact axes only.
