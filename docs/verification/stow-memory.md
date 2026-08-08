# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports the active bounded-memory, whole-file curation, and offload-destination discovery guarantees for Firstmate's internal `/stow` skill.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing setting and estimate.
The internal skill owns curation and completion-receipt behavior.
Task chronology, fixture paths, and delivery evidence remain outside this record.

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

## Git-excluded local skill discovery

The internal skill's offload destination relies on the harness discovering a skill directory whose path is listed in the clone's local `.git/info/exclude`.
This check ran on 2026-08-08 with Claude Code 2.1.226 in a disposable scratch repository, with a second probe left ordinarily untracked as the discovery control:

```bash
set -eu
PROBE_ROOT=$(mktemp -d)
cd "$PROBE_ROOT"
git init -q .
mkdir -p .claude/skills/excluded-probe .claude/skills/control-probe
cat >.claude/skills/excluded-probe/SKILL.md <<'EOF'
---
name: excluded-probe
description: Discovery probe whose directory is listed in .git/info/exclude. Never load it.
---
# excluded-probe
Test artifact.
EOF
cat >.claude/skills/control-probe/SKILL.md <<'EOF'
---
name: control-probe
description: Discovery control probe with ordinary untracked git status. Never load it.
---
# control-probe
Test artifact.
EOF
printf '.claude/skills/excluded-probe/\n' >>.git/info/exclude
git check-ignore -v .claude/skills/excluded-probe/SKILL.md
claude --model haiku -p "Inspect the list of skills available to you in this session. Reply with exactly two lines and nothing else: line 1 'CONTROL=YES' if a skill named 'control-probe' is available, else 'CONTROL=NO'. Line 2 'EXCLUDED=YES' if a skill named 'excluded-probe' is available, else 'EXCLUDED=NO'. Do not use any tools."
```

Observed output:

```text
.git/info/exclude:7:.claude/skills/excluded-probe/	.claude/skills/excluded-probe/SKILL.md
CONTROL=YES
EXCLUDED=YES
```

The same day, a `.gitignore`-ignored probe directory under this repository's own `.agents/skills/` was likewise listed by a fresh session alongside the tracked control skill, reached through the `.claude/skills` symlink.
This verifies skill discovery is a filesystem scan that ignores git ignore status, so a user-owned local skill excluded through `.git/info/exclude` is still listed and JIT-loadable.
