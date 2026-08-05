# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports the active bounded-memory and whole-file curation guarantees for Firstmate's internal `/stow` skill.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing setting and estimate.
The internal skill owns curation and completion-receipt behavior.
Task chronology, fixture paths, and delivery evidence remain outside this record.

Each pass below is a dated historical record of what that run observed.
Earlier records are never rewritten when the skill contract changes; a contract change gets a new dated pass appended instead.

## Synthetic real-agent pass

The development-only real-agent pass ran on 2026-07-30 with Pi 0.82.0 on `openai-codex/gpt-5.6-terra` at medium thinking.
It used disposable primary and secondmate-shaped `FM_HOME` directories under the repository worktree only.
No live Firstmate memory, project data, credential content, or external system was placed in either fixture or prompt.
The following exact Bash shell body created the sanitized fixtures, invoked the model-qualified skill twice per home, and captured reports, hashes, and file modes:

```bash
set -eu
VERIFY_ROOT=$(mktemp -d "$PWD/.stow-verification.XXXXXX")
RUNTIME_ROOT="$VERIFY_ROOT/runtime-root"
PRIMARY="$VERIFY_ROOT/primary"
SECONDMATE="$VERIFY_ROOT/secondmate"
SECONDMATE_ID=stow-verification
mkdir -p "$RUNTIME_ROOT" "$PRIMARY/config" "$PRIMARY/data" \
  "$SECONDMATE/bin" "$SECONDMATE/config" "$SECONDMATE/data"
printf '%s\n' 350 >"$PRIMARY/config/startup-memory-budget"
printf '%s\n' "$SECONDMATE_ID" >"$SECONDMATE/.fm-secondmate-home"
printf '%s\n' '# Synthetic Firstmate home' >"$SECONDMATE/AGENTS.md"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

record_shared_state() {
  label=$1
  path=$2
  printf '%s sha256=%s mode=%s\n' "$label" \
    "$(shasum -a 256 "$path" | awk '{print $1}')" \
    "$(file_mode "$path")"
}

cat >"$PRIMARY/data/captain.md" <<'EOF'
# Captain

## Current preferences

- Prefer the simplest direct end-to-end operational path.
- Preserve unique current facts when compacting memory.
- Use plain dashes in prose.

## Duplicate and superseded material

- Prefer the simplest direct end-to-end operational path.
- Old policy: build a wrapper before every one-off operation.
- Old policy copy: always build a wrapper for one-off work.
- Stale tool path: `/opt/old-firstmate/bin/fm`.
- Stale release version: 0.41.0.
- Completed task: migrated the demo fixture on Monday.
- Completed task detail: checked the demo fixture again on Tuesday.
- Metric from the completed task: 47 records moved.
EOF

cat >"$PRIMARY/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.

- Never expose secrets or weaken an accepted safety boundary.
- Prefer the simplest direct end-to-end operational path.
- Superseded policy: secondmates may rewrite shared memory when convenient.
- Duplicate safety note: do not expose secrets.
EOF

cat >"$PRIMARY/data/learnings.md" <<'EOF'
# Learnings

- Stable fact: startup-memory configuration is documented in `docs/configuration.md`.
- Authoritative pointer: incident detail belongs in `data/reports/synthetic-incident.md`.
- Stable fact copy: consult `docs/configuration.md` for startup-memory configuration.
- Completed chronology: first the synthetic incident was detected, then triaged, then assigned.
- Completed chronology continued: a patch was drafted, reviewed, merged, and announced.
- Old metric: the discarded prototype used 812 estimated tokens.
- Stale path: the discarded prototype lived at `/tmp/old-memory-prototype`.
- Superseded alternative: maintain both a JSON memory database and Markdown files.
- Report-sized procedure: create a staging directory, enumerate every file, copy each file, compare every line, write a status ledger, notify all operators, archive the ledger, and repeat the entire sequence after every prompt.
EOF

FM_HOME="$PRIMARY" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.before.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.before.sha256"

FM_HOME="$PRIMARY" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/stow/SKILL.md \
  'Invoke /stow now against only the disposable synthetic Firstmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, preserve the complete main-authoritative routing header in data/captain-shared.md, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, preserve every unique current preference, authority or safety boundary, stable fact, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, and report-sized material. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/primary.pass1.out"
FM_HOME="$PRIMARY" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.after.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.after.sha256"

FM_HOME="$PRIMARY" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/stow/SKILL.md \
  'Invoke /stow now against only the disposable synthetic Firstmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, preserve the complete main-authoritative routing header in data/captain-shared.md, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, preserve every unique current preference, authority or safety boundary, stable fact, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, and report-sized material. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/primary.pass2.out"
FM_HOME="$PRIMARY" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.repeat.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.repeat.sha256"

cat >"$SECONDMATE/data/captain.md" <<'EOF'
# Secondmate captain memory

- Current preference: report concrete blockers instead of guessing.
- Current preference copy: never guess when a concrete blocker can be reported.
- Shared overlap: never expose secrets.
- Superseded preference: silently infer missing configuration.
- Stale version: the fleet uses 0.41.0.
- Completed task: inspected the synthetic queue yesterday.
- Completed task detail: closed the synthetic queue inspection after 19 checks.
EOF

cat >"$SECONDMATE/data/learnings.md" <<'EOF'
# Secondmate learnings

- Unique current learning: inherited shared memory counts against the local total.
- Authoritative pointer: startup-memory behavior is documented in `docs/configuration.md`.
- Duplicate learning: include inherited shared memory in the local total.
- Stale path: `/tmp/secondmate-memory-v1`.
- Superseded alternative: copy shared facts into every local file.
- Completed chronology: opened the sample, measured it, discussed it, revised it, remeasured it, and closed it.
- Old metric: the sample once measured 604 estimated tokens.
- Report-sized procedure: take a snapshot, copy it to a ledger, annotate every old measurement, preserve every discarded alternative, append a timestamp, and repeat after each completed task.
EOF

FM_ROOT="$RUNTIME_ROOT"
FM_HOME="$PRIMARY"
. bin/fm-ff-lib.sh
. bin/fm-config-inherit-lib.sh
validate_secondmate_home "$SECONDMATE_ID" "$SECONDMATE"
printf 'secondmate_validation=accepted id=%s home=%s\n' \
  "$SECONDMATE_ID" "$VALIDATED_HOME" >"$VERIFY_ROOT/inheritance.out"
FM_CONFIG_INHERIT_REPORT="$VERIFY_ROOT/inheritance.report" \
  propagate_secondmate_inheritance \
    "$PRIMARY" "$VALIDATED_HOME" "$PRIMARY/config" "$PRIMARY/data"
cat "$VERIFY_ROOT/inheritance.report" >>"$VERIFY_ROOT/inheritance.out"
cmp -s "$PRIMARY/data/captain-shared.md" \
  "$SECONDMATE/data/captain-shared.md"
record_shared_state inherited "$SECONDMATE/data/captain-shared.md" \
  >>"$VERIFY_ROOT/inheritance.out"

FM_HOME="$SECONDMATE" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/secondmate.before.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$SECONDMATE/data/$file"
done >"$VERIFY_ROOT/secondmate.before.sha256"
record_shared_state before "$SECONDMATE/data/captain-shared.md" \
  >"$VERIFY_ROOT/secondmate.shared-state"

FM_HOME="$SECONDMATE" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/stow/SKILL.md \
  'Invoke /stow now against only the validated disposable synthetic secondmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, keep data/captain-shared.md byte-identical and filesystem read-only because it was installed through primary-authoritative inheritance, preserve every unique current preference, stable learning, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, overlap, and report-sized material in editable local memory. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/secondmate.pass1.out"
FM_HOME="$SECONDMATE" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/secondmate.after.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$SECONDMATE/data/$file"
done >"$VERIFY_ROOT/secondmate.after.sha256"
record_shared_state after "$SECONDMATE/data/captain-shared.md" \
  >>"$VERIFY_ROOT/secondmate.shared-state"

FM_HOME="$SECONDMATE" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/stow/SKILL.md \
  'Invoke /stow now against only the validated disposable synthetic secondmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, keep data/captain-shared.md byte-identical and filesystem read-only because it was installed through primary-authoritative inheritance, preserve every unique current preference, stable learning, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, overlap, and report-sized material in editable local memory. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/secondmate.pass2.out"
FM_HOME="$SECONDMATE" bin/fm-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/secondmate.repeat.report"
for file in captain.md captain-shared.md learnings.md; do
  shasum -a 256 "$SECONDMATE/data/$file"
done >"$VERIFY_ROOT/secondmate.repeat.sha256"
record_shared_state repeat "$SECONDMATE/data/captain-shared.md" \
  >>"$VERIFY_ROOT/secondmate.shared-state"
```

Bounded observed output:

```text
secondmate_validation=accepted id=stow-verification
startup-memory-budget pushed
data/captain-shared.md pushed
inherited sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
primary: 699 -> 219 estimated tokens against a 350-token budget
primary repeat: 219 -> 219; all three files byte-identical
secondmate: 518 -> 192 estimated tokens against a 350-token budget
secondmate repeat: 192 -> 192; all three files byte-identical
before sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
after sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
repeat sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
```

The first pass preserved current preferences, shared-memory and safety authority, a stable operating fact, and authoritative configuration and incident-report pointers while removing duplicate, superseded, stale, and chronological material.
The secondmate fixture passed the production home validator before the existing inheritance owner installed the main-authoritative file read-only.
Both secondmate passes preserved its unique local preference and learning while leaving those inherited bytes and mode untouched.
This verifies the real instruction path consolidates to budget, reports truthful deltas, preserves the primary-owned shared boundary, and does not grow on an identical second pass.

## Synthetic real-agent pass under the healthy-target receipt contract

The record above predates the healthy-target receipt contract, so it verifies the budget guarantee only.
This second development-only real-agent pass ran on 2026-08-04 with Pi 0.83.0 on `openai-codex/gpt-5.6-terra` at medium thinking, against these exact identities:

```text
commit 98e57efc45d72e8b9ba798b5aa8b7487b1c7176f
tree   38195aa193ba9458f27183727f1ad5a2bab2601e
blob   55512df4e1c768eb155fd495cdc8652e7a1255de  .agents/skills/stow/SKILL.md
blob   b5e0968e99beaa41c0906e1d27abd68175042ee5  bin/fm-startup-memory-budget.sh
blob   d2d96d77fd8e01d30f5b969863e37d613a547bab  bin/fm-startup-memory-budget-lib.sh
```

That commit is the final revision of the skill and both executables on this branch; only this record was appended afterwards, so the three blob identities above still resolve unchanged.

The executed shell body was byte-identical to the block in the preceding section except for the two prompt strings quoted below, each used for both passes of its home, and one trailing bookkeeping line that recorded the fixture root for cleanup:

```bash
printf '%s\n' "$VERIFY_ROOT" >.stow-verification-root
```

The primary prompt, used for both primary passes:

```text
Invoke /stow now against only the disposable synthetic Firstmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, preserve the complete main-authoritative routing header in data/captain-shared.md, and make the completion receipt state the effective budget, the healthy target, the healthy-margin status, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, preserve every unique current preference, authority or safety boundary, stable fact, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, and report-sized material. Do not access or modify any other home, credential, project data, or external system.
```

The secondmate prompt, used for both secondmate passes:

```text
Invoke /stow now against only the validated disposable synthetic secondmate home in $FM_HOME. There are no new session facts to file. Follow every requirement in the loaded stow skill. Run the repository-owned bin/fm-startup-memory-budget.sh report command, with the existing FM_HOME environment, before and after curation; that executable is the only permitted path outside $FM_HOME. Retain the exact before total, and make the completion receipt state the effective budget, the healthy target, the healthy-margin status, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, keep data/captain-shared.md byte-identical and filesystem read-only because it was installed through primary-authoritative inheritance, preserve every unique current preference, stable learning, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, overlap, and report-sized material in editable local memory. Do not access or modify any other home, credential, project data, or external system.
```

Both homes were configured with the same 350-token budget as the first record, for which `report` derived a 280-token healthy target.
The observed helper reports, quoted exactly:

```text
primary before:  effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=699 budget_status=over-budget    healthy_margin_status=over-budget
primary after:   effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=238 budget_status=within-budget  healthy_margin_status=healthy-margin
primary repeat:  effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=218 budget_status=within-budget  healthy_margin_status=healthy-margin
second before:   effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=537 budget_status=over-budget    healthy_margin_status=over-budget
second after:    effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=218 budget_status=within-budget  healthy_margin_status=healthy-margin
second repeat:   effective_budget_tokens=350 healthy_target_tokens=280 total_estimated_tokens=218 budget_status=within-budget  healthy_margin_status=healthy-margin
inherited sha256=e97f85369f14230dab10ffec239fe8b2e81e18ff5eccf57ae1d76b91034245e0 mode=444
before    sha256=e97f85369f14230dab10ffec239fe8b2e81e18ff5eccf57ae1d76b91034245e0 mode=444
after     sha256=e97f85369f14230dab10ffec239fe8b2e81e18ff5eccf57ae1d76b91034245e0 mode=444
repeat    sha256=e97f85369f14230dab10ffec239fe8b2e81e18ff5eccf57ae1d76b91034245e0 mode=444
```

The four completion receipts, quoted exactly and in full:

```text
Stow complete for `$FM_HOME`.

- Budget: effective 350; healthy target 280; status `healthy-margin`.
- Totals: before 699; after 238 estimated tokens.
- `data/captain.md`: pruned superseded/stale/completed material.
- `data/captain-shared.md`: pruned duplicates/superseded policy; preserved the complete main-authoritative routing header.
- `data/learnings.md`: rewritten as concise authoritative pointers.
- Durable findings outside memory: none.
- Exceptions: none.
- Reset-safe: yes.
```

```text
Startup-memory curation complete.

- Budget: effective 350; healthy target 280.
- Before: 238 estimated tokens; healthy-margin.
- After: 218 estimated tokens; healthy-margin.
- `data/captain.md`: pruned duplicated preference retained authoritatively in shared memory.
- `data/captain-shared.md`: unchanged; complete main-authoritative routing header preserved.
- `data/learnings.md`: unchanged; concise authoritative pointers retained.
- Durable findings filed outside memory: none.
- Exceptions: none.
- Reset safety: safe to reset.
```

```text
Stow complete in `$FM_HOME`.

- Budget: effective 350; healthy target 280.
- Before: 537 estimated tokens (`over-budget`).
- After: 218 estimated tokens (`healthy-margin`).
- `data/captain.md`: pruned to the unique current preference.
- `data/captain-shared.md`: unchanged, byte-identical, and read-only.
- `data/learnings.md`: pruned to the unique local learning and authoritative pointer.
- Durable findings outside memory: none; no new session facts.
- Exceptions: none.
- Reset-safe: yes.
```

```text
Stow complete.

- Budget: effective 350; healthy target 280; status healthy-margin.
- Totals: before 218; after 218 estimated tokens.
- `data/captain.md`: unchanged.
- `data/captain-shared.md`: unchanged; byte-preserved and filesystem read-only (primary-owned).
- `data/learnings.md`: unchanged.
- No durable session findings to file; no exceptions.
- Reset-safe: yes.
```

Every receipt stated the effective budget, the healthy target, and an explicit healthy-margin status, and each first pass carried a genuinely over-budget home to `healthy-margin` rather than stopping at the hard ceiling.
Both homes preserved their unique current preferences, safety and authority boundaries, stable facts, and authoritative pointers while the supplied duplicate, superseded, stale, chronological, metric, and report-sized material was consolidated.
The secondmate fixture passed the production home validator before the existing inheritance owner installed the main-authoritative file, and both secondmate passes left its bytes and `444` mode untouched.

Observed limitations of this pass:

- The primary second pass was not a no-op: it removed `Prefer the simplest direct end-to-end operational path.` from `data/captain.md` because that exact preference is preserved in the primary-owned `data/captain-shared.md`, moving the total from 238 to 218 tokens.
  The skill permits removing a current fact that a stronger existing owner preserves directly, and the pass did not grow, but only the secondmate home was byte-identical on repeat.
  Repeat-pass stability at the healthy target is therefore observed as non-increasing, not as byte-identical.
- The 350-token fixture budget and 280-token healthy target are a small synthetic scale chosen to make consolidation observable in one pass; they are not the shipped 7,500-token ceiling and 6,000-token healthy target.
- A single pass per home per contract on one model is evidence that the instruction path works, not a statistical claim about every model or memory shape.
- `tests/fm-startup-memory-budget.test.sh` remains the deterministic owner of the healthy-target arithmetic and status classification; this record only verifies that a real agent follows the skill's receipt contract.
