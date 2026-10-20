---
name: codebase-search
description: Use when an agent needs bounded, read-only file discovery, pattern search, context, or basic repository metrics.
user-invocable: false
metadata:
  internal: true
---

# Codebase search

Use `bin/codebase-search` from the repository root for quick, read-only codebase inspection.
The command requires `rg` and does not require `axi-axi`.

## Workflow

Start with `files` to discover relevant paths, then use `search` for a pattern or `context` when surrounding lines matter.
Use `metrics` for a bounded file, byte, and line summary.
Pass `--root PATH` when the repository root is not the current directory.

```bash
bin/codebase-search files --root .
bin/codebase-search search 'pattern' --root . --max-results 25
bin/codebase-search context 'pattern' --root . --before 2 --after 2
bin/codebase-search metrics --root .
```

## Safety and output contract

Every successful invocation prints one compact JSON record to stdout and exits zero.
Empty discovery and search results are successful records with an empty array and `count: 0`.
Output is bounded by default at 50 results; use `--max-results N` for another bound or `--all` for an explicitly unbounded run.
Default exclusions cover `.git`, dependency and vendor directories, common build outputs, virtual environments, `.env*`, private-key names, and common certificate or key extensions.
Use `--all` only when searching those paths is intentional because it opts into generated and potentially sensitive content.
Invalid commands, invalid roots, invalid requests, unavailable `rg`, and search failures print a JSON error record and exit nonzero.
Search records preserve relative filenames, line numbers, columns, and matching line text; context records also include `before` and `after` arrays.
