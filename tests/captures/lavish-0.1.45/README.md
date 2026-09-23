# Lavish 0.1.45 YAML-frame capture

`lavish-yaml-capture.result` is a sanitized recording of one real `lavish-axi poll` response, captured from lavish-axi 0.1.45 during a browser review that left six freeform comments.
Every human-readable string was replaced with synthetic text; the frame structure, field names, nesting, quoting, and escapes are unchanged.
It is the regression input for the YAML-frame cases in `../../fm-procevent.test.sh`.

## Why this shape exists

The published poll frames a queued batch one of two ways, and the emission rule was verified live against lavish-axi 0.1.75 on 2026-09-23 by driving the real poll and submitting batches through the same session API route the review client uses:

- A batch whose every prompt is flat renders as `prompts[N]{field,...}:` with N indented CSV rows.
- A batch where ANY prompt carries a nested structure, such as the quoted `target` block of a text-range annotation, renders the WHOLE batch as a YAML-style `prompts[N]:` list of `- key: value` mappings.

The captured review mixed plain annotations with one text-range annotation, so the whole six-prompt batch arrived in the YAML shape.
The reader in `bin/fm-procevent-lavish.sh` then parsed only the CSV frame, reported zero items, and the review was wrongly treated as empty; the regression tests pin that this can no longer happen.

## Observed YAML details

- Scalar values are double-quoted with backslash escapes (`\n`, `\t`, `\"`) when they carry special characters, and plain otherwise.
- Empty strings render as `""`, and `uid` values are quoted even when numeric.
- The `target` block nests `type`, `text`, `selector`, `commonAncestorSelector`, and `start`/`end` sub-blocks whose array paths render as `path[N]: v1,v2`.
- A freeform message row uses `tag: message`, and keyed choice rows can share the same YAML frame, which is why `answers` and `reconciles` read both shapes too.
