---
name: retire-doc
description: Guided, safe procedure for retiring a document from a firstmate home's data/ corpus - archive it, correct a stale claim, or delete it - with a backup taken first and a captain sign-off gate for anything that changes what the corpus asserts. Use when the captain invokes /retire-doc (e.g. "/retire-doc", "retire that doc", "archive the old runbook").
user-invocable: true
metadata:
  internal: true
---

# retire-doc

Retire a document from this home's `data/` corpus safely.
The `data/` corpus is captain-private and gitignored, so it has no version history to fall back on: every retirement is unversioned and potentially unrecoverable unless this skill's backup step runs first.
The goal is a corpus that no longer carries the retired material, with a durable backup, an intact index, and no silent loss of anything the corpus still relies on.

## 0. Local SOP first

If this home keeps its own document-lifecycle SOP in `data/` (for example a `data/doc-map.md`, a librarian charter, or a stated retirement procedure), read it first and let it refine or strengthen the procedure below.
A local SOP must never waive or weaken this skill's required scoped backup, valid recorded SHA-256, captain sign-off gate, former-path consolidation pointer, atomic index update, or final retirement report.

## 1. Back up before any destructive step

Before moving, rewriting, or deleting anything, snapshot the affected files so an unversioned corpus stays recoverable.
- Write a dated tarball of every affected path under `data/backups/`, creating that directory if it does not exist.
- Record the tarball's hash so the backup is verifiable later.
- Keep the tarball scoped to the files this retirement touches, not the whole corpus, so the backup is small and its provenance is clear.

Example:

```
mkdir -p data/backups
ts="$(date +%Y%m%d-%H%M%S)"
backup="data/backups/retire-<slug>-${ts}.tar.gz"
if ! tar czf "$backup" <affected-path> [<affected-path> ...]; then
  rm -f "$backup"
  printf '%s\n' 'The scoped backup failed; stop before retiring anything.' >&2
  exit 1
fi
if command -v shasum >/dev/null 2>&1; then
  if ! hash_output="$(shasum -a 256 "$backup")"; then
    printf '%s\n' 'SHA-256 hashing failed; stop before retiring anything.' >&2
    exit 1
  fi
elif command -v sha256sum >/dev/null 2>&1; then
  if ! hash_output="$(sha256sum "$backup")"; then
    printf '%s\n' 'SHA-256 hashing failed; stop before retiring anything.' >&2
    exit 1
  fi
else
  printf '%s\n' 'No SHA-256 command is available; stop before retiring anything.' >&2
  exit 1
fi
hash="${hash_output%%[[:space:]]*}"
if [ "${#hash}" -ne 64 ]; then
  printf '%s\n' 'The SHA-256 digest is invalid; stop before retiring anything.' >&2
  exit 1
fi
case "$hash" in
  *[!0123456789abcdefABCDEF]*)
    printf '%s\n' 'The SHA-256 digest is invalid; stop before retiring anything.' >&2
    exit 1
    ;;
esac
printf '%s  %s\n' "$hash" "$backup"
```

Carry the tarball path and its hash forward; the final report cites them.

## 2. Classify the retirement

Decide which of three kinds this is, because each has a different safe procedure and a different sign-off requirement.

- **archive** - the document is superseded or no longer active, but retains provenance value.
  Move it to a dated archive location under `data/` (for example `data/archive/<YYYY-MM-DD>/`) and leave a one-line tombstone pointer where it used to live, or record the move as an index note, so anything looking for the old path finds where it went.
- **rewrite-claim** - the document stays in place, but a stale or misleading claim inside it must be corrected or clearly bannered as no longer true.
  The document is not removed; only the specific assertion changes.
- **delete** - the material has no provenance value (a scratch note, a true duplicate with nothing unique, a mistaken file) and can be removed outright.
  Delete is the narrowest kind; when in doubt, archive instead.

## 3. Provenance gate - present, then wait for the captain

Any retirement that changes what the corpus *asserts* requires the captain's explicit sign-off before you act.
That includes deleting evidence, retiring or correcting a claim, and removing a document that other documents cite.
Routine archival of a plainly superseded duplicate - where the same material lives authoritatively elsewhere and nothing unique is lost - does not need sign-off.

When the gate applies, present to the captain, then stop and wait for their word:
- the item being retired (path and what it is),
- the classification from step 2,
- the consequence - what the corpus will no longer assert, and who or what cites it.

Do not act on a gated retirement until the captain answers.
If you are a crewmate rather than firstmate itself, surface this as a decision for the captain rather than deciding it yourself.

## 4. Consolidation - keep a single source of truth

When the retirement is really a consolidation - the same information living in two places - merge it into the one authoritative home and replace the other copy with a pointer to that home.
Never leave two full copies: the moment only one is edited, they drift.
Choose the authoritative home deliberately (the more discoverable, more maintained, or index-referenced location), fold in anything unique from the copy being retired, then reduce the retired document at its former path to a one-line pointer to that authoritative home.

## 5. Update the index in the same action

If this home keeps a master document index in `data/` (many do - for example a `data/doc-map.md` or similar registry), update it in the same action that retires the document, so the index never points at a retired path.
Fix the entry to the new archive path, the pointer, or remove it, matching what step 2 did to the file.
An index left pointing at a moved or deleted document is exactly the silent breakage this step prevents.

## 6. Report

Summarize the outcome in plain language:
- what moved, was rewritten, or was deleted, with `old -> new` paths for anything relocated,
- the classification applied,
- the backup tarball path and its hash,
- the index entry updated, if any,
- for a gated retirement, a note that the captain signed off.
